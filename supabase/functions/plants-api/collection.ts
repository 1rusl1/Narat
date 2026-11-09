// T162: server-only sync/catalogue create. SQL owns projections and receipts.
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

// Catalogue create is the only production command in this slice. Validation
// never rewrites the payload: PostgreSQL owns hashing, receipts and retries.
const commandKeys = new Set(["operation_id", "command_name", "payload_json", "plant_id"]);
const conditionValues: Record<string, readonly string[]> = {
  light_level: ["low", "medium", "bright_indirect", "direct_sun", "unknown"],
  light_code: ["low", "medium", "bright_indirect", "direct_sun", "unknown"],
  light_source: ["manual", "unknown"],
  watering_habit: ["several_weekly", "weekly", "less_often", "frequent", "moderate", "sparse", "unknown"],
  watering_code: ["several_weekly", "weekly", "less_often", "frequent", "moderate", "sparse", "unknown"],
  last_watered: ["yes", "no", "within_7_days", "over_7_days", "unknown"],
  drainage_code: ["yes", "no", "within_7_days", "over_7_days", "unknown"],
  pot_type: ["terracotta", "plastic", "glazed_ceramic", "standard_drainage", "other", "unknown"],
};

function commandError(ctx: RequestContext, kind: "invalid" | "conflict" | "cap" | "unavailable") {
  const messages = {
    invalid: ["Invalid catalogue creation command.", "Nieprawidłowe polecenie dodania rośliny z katalogu."],
    conflict: ["Operation conflicts with an existing request.", "Operacja jest sprzeczna z istniejącym żądaniem."],
    cap: ["Your collection has reached its plant limit.", "Osiągnięto limit roślin w kolekcji."],
    unavailable: ["Saving is temporarily unavailable. Please try again later.", "Zapisywanie jest tymczasowo niedostępne. Spróbuj ponownie później."],
  };
  return new ApiHttpError(
    kind === "invalid" ? 400 : kind === "unavailable" ? 503 : 409,
    kind === "invalid" ? "VALIDATION_ERROR" : kind === "cap"
      ? "COLLECTION_LIMIT_REACHED" : kind === "conflict" ? "CONFLICT" : "INTERNAL_ERROR",
    messages[kind][ctx.locale === "pl" ? 1 : 0],
    kind === "unavailable",
  );
}

function commandForbidden(ctx: RequestContext): ApiHttpError {
  return new ApiHttpError(
    403, "FORBIDDEN",
    ctx.locale === "pl"
      ? "Wymagane jest aktywne, stałe konto."
      : "An active permanent account is required.",
  );
}

function catalogueFields(value: unknown, kind: "payload" | "conditions" | "overrides"): boolean {
  if (!record(value)) return false;
  for (const [key, field] of Object.entries(value)) {
    if (Object.hasOwn(conditionValues, key) && kind !== "payload") {
      if (field !== null && (typeof field !== "string" || !conditionValues[key].includes(field))) return false;
    } else if (key === "light_confirmed" && kind !== "payload") {
      if (field !== null && typeof field !== "boolean") return false;
    } else if (kind !== "conditions" && ["plant_id", "personal_name", "display_name"].includes(key)) {
      if (field !== null && (typeof field !== "string" || (key === "plant_id" && !field.trim()))) return false;
    } else if (kind !== "conditions" && key === "taxon_id") {
      if (field !== null && (typeof field !== "string" || !uuid.test(field))) return false;
    } else if (kind === "payload" && key === "origin_flow_id") {
      if (field !== null && (typeof field !== "string" || !uuid.test(field))) return false;
    } else if (kind === "payload" && key === "photo_id") {
      // SQL does not verify main_photo_id ownership on insert. Keep catalogue
      // creation without media until attachment has an authoritative guard.
      if (field !== null) return false;
    } else if (kind === "payload" && key === "creation_source") {
      if (field !== "catalogue") return false;
    } else if (kind === "payload" && key === "creation_intent") {
      if (field !== "care" && field !== "problem") return false;
    } else if (kind === "payload" && key === "add_method") {
      if (field !== "catalogue") return false;
    } else if (kind === "payload" && (key === "conditions" || key === "overrides")) {
      if (!catalogueFields(field, key)) return false;
    } else {
      // Includes owner injection, draft/fallback, rooms, camera and season inputs.
      return false;
    }
  }
  return true;
}

function canonicalCreate(value: unknown): value is Record<string, unknown> {
  return record(value) &&
    typeof value.plant_id === "string" && uuid.test(value.plant_id) &&
    Number.isSafeInteger(value.care_revision) && Number(value.care_revision) >= 1 &&
    typeof value.context_state === "string" && value.context_state.length > 0 &&
    typeof value.next_available_step === "string" && value.next_available_step.length > 0 &&
    typeof value.plan_availability === "string" && value.plan_availability.length > 0 &&
    timestamp(value.watermark) !== null;
}

export async function handlePlantCreate(
  req: Request,
  ctx: RequestContext,
  clientFactory: SyncClientFactory,
): Promise<Response> {
  const ownerId = requireActiveOwner(ctx);
  if (ctx.isAnonymous) throw commandForbidden(ctx);
  if ([...new URL(req.url).searchParams.keys()].length) throw commandError(ctx, "invalid");
  let body: unknown;
  let payload: unknown;
  try {
    body = await req.json();
    if (!record(body) || typeof body.payload_json !== "string") throw new Error();
    payload = JSON.parse(body.payload_json);
  } catch {
    throw commandError(ctx, "invalid");
  }
  if (
    !record(body) || Object.keys(body).some((key) => !commandKeys.has(key)) ||
    typeof body.operation_id !== "string" || !uuid.test(body.operation_id) ||
    body.command_name !== "plant.create" ||
    (body.plant_id !== undefined && body.plant_id !== null) ||
    !record(payload) || payload.creation_source !== "catalogue" ||
    !catalogueFields(payload, "payload")
  ) throw commandError(ctx, "invalid");
  const overrides = record(payload.overrides) ? payload.overrides : {};
  if (![payload.plant_id, payload.taxon_id, overrides.plant_id, overrides.taxon_id]
    .some((value) => typeof value === "string" && value.length > 0)) {
    throw commandError(ctx, "invalid");
  }
  const header = req.headers.get("x-operation-id");
  if (header !== null) {
    if (!uuid.test(header.trim())) throw commandError(ctx, "invalid");
    if (header.trim().toLowerCase() !== body.operation_id.toLowerCase()) {
      throw commandError(ctx, "conflict");
    }
  }

  let result: unknown;
  try {
    const client = clientFactory();
    if (!client) throw commandError(ctx, "unavailable");
    result = await client.rpc("execute_plant_create_command", {
      p_owner_id: ownerId,
      p_operation_id: body.operation_id,
      p_payload: payload,
    });
  } catch {
    throw commandError(ctx, "unavailable");
  }
  if (!record(result)) throw commandError(ctx, "unavailable");
  if (result.error) {
    if (!record(result.error)) throw commandError(ctx, "unavailable");
    const { code, message } = result.error;
    if (
      (code === "42501" && (message === "account_not_active" || message === "owner_forbidden")) ||
      (code === "P0002" && message === "owner_profile_not_found")
    ) throw commandForbidden(ctx);
    if (code === "P0001" && message === "COLLECTION_LIMIT_REACHED") throw commandError(ctx, "cap");
    if (code === "23505" || message === "operation_payload_mismatch") throw commandError(ctx, "conflict");
    if (
      (typeof code === "string" && ["22007", "22008", "22023", "22P02", "23502", "23503", "23514"].includes(code)) ||
      (code === "P0002" && message === "taxon_not_published")
    ) throw commandError(ctx, "invalid");
    throw commandError(ctx, "unavailable");
  }
  if (!canonicalCreate(result.data)) throw commandError(ctx, "unavailable");
  return jsonResponse(result.data);
}
