// T162: server-only GET /sync. SQL owns the projection and pagination.
import { type SupabaseClient } from "@supabase/supabase-js";
import {
  ApiHttpError,
  jsonResponse,
  type RequestContext,
  requireActiveOwner,
} from "../_shared/http.ts";

export type SyncClientFactory = () => SupabaseClient | null;

const entityTypes = new Set([
  "plants", "condition_snapshots", "photo_assets", "analysis_summaries",
  "care_plan_summaries", "care_tasks", "care_entries", "care_reversals",
  "schedule_changes", "basic_care_memberships", "first_aid_followups",
  "care_observations", "recovery_transitions", "notification_claim_summaries",
]);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const queryKeys = new Set([
  "since", "until", "limit", "cursor_updated_at", "cursor_entity_type", "cursor_id",
]);

// Validate calendar dates, require a timezone, and compare at PostgreSQL's
// microsecond precision. Never round/serialize a caller's watermark through Date.
function timestamp(value: unknown): bigint | null {
  if (typeof value !== "string") return null;
  const match = value.match(
    /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$/,
  );
  if (!match) return null;
  const [, year, month, day, hour, minute, second, fraction, zone] = match;
  const y = Number(year), m = Number(month), d = Number(day);
  const leap = y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (
    y < 1 || m < 1 || m > 12 || d < 1 || d > days[m - 1] ||
    Number(hour) > 23 || Number(minute) > 59 || Number(second) > 59 ||
    (zone !== "Z" && (Number(zone.slice(1, 3)) > 15 || Number(zone.slice(4)) > 59))
  ) return null;
  const millis = Date.parse(
    year + "-" + month + "-" + day + "T" + hour + ":" + minute + ":" + second + zone,
  );
  return Number.isFinite(millis)
    ? BigInt(millis) * 1000n + BigInt((fraction ?? "").padEnd(6, "0"))
    : null;
}

function invalidQuery(ctx: RequestContext): ApiHttpError {
  return new ApiHttpError(
    400, "VALIDATION_ERROR",
    ctx.locale === "pl"
      ? "Nieprawidłowe parametry synchronizacji."
      : "Invalid synchronization parameters.",
  );
}

function unavailable(ctx: RequestContext): ApiHttpError {
  return new ApiHttpError(
    503, "INTERNAL_ERROR",
    ctx.locale === "pl"
      ? "Synchronizacja jest tymczasowo niedostępna. Spróbuj ponownie później."
      : "Synchronization is temporarily unavailable. Please try again later.",
    true,
  );
}

function syncParameters(url: URL, ctx: RequestContext) {
  const query = url.searchParams;
  for (const key of query.keys()) {
    if (!queryKeys.has(key) || query.getAll(key).length !== 1) throw invalidQuery(ctx);
  }
  const since = query.get("since");
  const until = query.get("until");
  const updatedAt = query.get("cursor_updated_at");
  const entityType = query.get("cursor_entity_type");
  const id = query.get("cursor_id");
  const limit = query.get("limit");
  for (const value of [since, until, updatedAt]) {
    if (value !== null && timestamp(value) === null) throw invalidQuery(ctx);
  }
  if (
    limit !== null && (!/^[1-9]\d*$/.test(limit) || Number(limit) > 500)
  ) throw invalidQuery(ctx);

  const cursorFields = [updatedAt, entityType, id].filter((value) => value !== null).length;
  if (cursorFields !== 0) {
    if (
      cursorFields !== 3 || until === null || !entityTypes.has(entityType!) ||
      !uuid.test(id!) ||
      timestamp(updatedAt)! > timestamp(until)! ||
      (since !== null && timestamp(updatedAt)! <= timestamp(since)!)
    ) throw invalidQuery(ctx);
  }
  if (since !== null && until !== null && timestamp(since)! > timestamp(until)!) {
    throw invalidQuery(ctx);
  }
  return {
    p_since: since,
    p_until: until,
    p_cursor_updated_at: updatedAt,
    p_cursor_entity_type: entityType,
    p_cursor_id: id,
    // Passing SQL NULL for p_limit would remove LIMIT. Match SQL's default.
    p_limit: limit === null ? 200 : Number(limit),
  };
}

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function nullableTimestamp(value: unknown): boolean {
  return value === null || timestamp(value) !== null;
}

function sameTimestamp(a: unknown, b: unknown): boolean {
  const parsed = timestamp(a);
  return parsed !== null && parsed === timestamp(b);
}

// Check the canonical envelope, not a Swift DTO. Return the original object:
// timestamps, nested data, null tombstones and SQL cursors must stay intact.
function canonicalPage(value: unknown): value is Record<string, unknown> {
  if (
    !record(value) || timestamp(value.until) === null ||
    typeof value.has_more !== "boolean" || !Array.isArray(value.changes) ||
    !record(value.profile)
  ) return false;
  const profile = value.profile;
  if (
    (profile.preferred_locale !== "en" && profile.preferred_locale !== "pl") ||
    !Number.isInteger(profile.reminder_hour_local) ||
    Number(profile.reminder_hour_local) < 0 || Number(profile.reminder_hour_local) > 23 ||
    typeof profile.report_notifications_enabled !== "boolean" ||
    typeof profile.trial_reminder_enabled !== "boolean"
  ) return false;
  if (value.entitlement !== null) {
    const entitlement = value.entitlement;
    if (
      !record(entitlement) ||
      typeof entitlement.product_id !== "string" || !entitlement.product_id ||
      typeof entitlement.state !== "string" || !entitlement.state ||
      (entitlement.offer_kind !== "trial" && entitlement.offer_kind !== "paid") ||
      !nullableTimestamp(entitlement.valid_until) ||
      !nullableTimestamp(entitlement.grace_until) ||
      !nullableTimestamp(entitlement.trial_end_at) ||
      typeof entitlement.auto_renew_enabled !== "boolean"
    ) return false;
  }
  for (const item of value.changes) {
    if (
      !record(item) || typeof item.entity_type !== "string" ||
      !entityTypes.has(item.entity_type) || typeof item.id !== "string" ||
      !uuid.test(item.id) || timestamp(item.updated_at) === null ||
      !nullableTimestamp(item.deleted_at) ||
      (item.deleted_at === null ? !record(item.data) : item.data !== null)
    ) return false;
  }
  if (!value.has_more) {
    return value.last_cursor === null && sameTimestamp(value.next_since, value.until);
  }
  const cursor = value.last_cursor;
  return value.changes.length > 0 && value.next_since === null &&
    record(cursor) && nullableTimestamp(cursor.since) &&
    sameTimestamp(cursor.until, value.until) && value.changes.some((item) =>
      item.id === cursor.id && item.entity_type === cursor.entity_type &&
      sameTimestamp(item.updated_at, cursor.updated_at)
    );
}

export async function handleGetSync(
  _req: Request,
  ctx: RequestContext,
  url: URL,
  clientFactory: SyncClientFactory,
): Promise<Response> {
  const ownerId = requireActiveOwner(ctx);
  const parameters = syncParameters(url, ctx);
  let result;
  try {
    const client = clientFactory();
    if (!client) throw unavailable(ctx);
    result = await client.rpc("fetch_sync_delta", { p_owner_id: ownerId, ...parameters });
  } catch {
    throw unavailable(ctx);
  }
  if (result.error) {
    const { code, message } = result.error;
    if (code === "42501" && message === "owner_forbidden") {
      throw new ApiHttpError(
        403, "FORBIDDEN",
        ctx.locale === "pl"
          ? "Konto jest w trakcie usuwania lub niedostępne."
          : "Account is deleting or unavailable.",
      );
    }
    if (["22007", "22008", "22023", "22P02"].includes(code)) throw invalidQuery(ctx);
    throw unavailable(ctx);
  }
  if (!canonicalPage(result.data)) throw unavailable(ctx);
  return jsonResponse(result.data);
}
