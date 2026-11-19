import { createClient } from "@supabase/supabase-js";
import { projectCareRecommendation } from "../_shared/care-recommendation-projection.ts";
import { extractBearerToken, jsonResponse, requireUuid, resolveLocale, type SupportedLocale } from "../_shared/http.ts";

export interface CareOverviewOptions {
  env?: (name: string) => string | undefined;
  fetch?: typeof fetch;
}

const headers = {
  "Cache-Control": "private, no-store",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};
class Failure extends Error {
  constructor(readonly status: number) { super("Care overview request failed."); }
}
function fail(status = 503): never { throw new Failure(status); }
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail();
  return value as Record<string, unknown>;
}
function uuid(value: unknown): string {
  try { return requireUuid(value, "id"); } catch { return fail(); }
}
function positive(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) > 0;
}
function day(value: unknown): value is string {
  if (typeof value !== "string" || !/^(?!0000)\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(value + "T00:00:00Z");
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}
// Validate UTC instants without normalizing the public wire or losing SQL microseconds.
function instant(value: unknown): string {
  if (typeof value !== "string") fail();
  const match = /^(\d{4}-\d{2}-\d{2})T([01]\d|2[0-3]):([0-5]\d):([0-5]\d)(?:\.(\d{1,9}))?(?:Z|\+00:00)$/.exec(value);
  if (!match || !day(match[1]) || !Number.isFinite(Date.parse(value))) fail();
  return match[1] + "T" + match[2] + ":" + match[3] + ":" + match[4] + "." + (match[5] ?? "").padEnd(9, "0");
}
function text(value: unknown): string {
  if (typeof value !== "string" || !value.trim()) fail();
  return value;
}
function control(value: unknown, revision: number, seen: Set<string>) {
  const raw = object(value);
  const ids: Record<string, string> = {};
  for (const key of ["control_id", "action_entry_id", "job_id", "origin_analysis_id", "kb_release_id", "protocol_id"]) {
    uuid(raw[key]);
    ids[key] = raw[key] as string;
  }
  const id = uuid(raw.control_id);
  if (seen.has(id)) fail();
  seen.add(id);
  if (!positive(raw.context_revision) || raw.context_revision !== revision || raw.action_code !== "check_soil") fail();
  const policy = object(raw.policy);
  if (!day(policy.due_on) || !positive(policy.interval_days) || policy.interval_days > 90) fail();
  const source = object(policy.source);
  const url = text(source.url);
  let parsed: URL;
  try { parsed = new URL(url); } catch { return fail(); }
  if (parsed.protocol !== "https:" || parsed.username || parsed.password) fail();
  return {
    ...ids,
    context_revision: raw.context_revision,
    action_id: text(raw.action_id),
    action_code: "check_soil",
    policy: {
      due_on: policy.due_on,
      interval_days: policy.interval_days,
      source: { url, locator: text(source.locator) },
    },
  };
}

function page(value: unknown, owner: string, after: string | null, limit: number, locale: SupportedLocale) {
  const raw = object(value);
  if (raw.owner_id !== owner) fail();
  const now = instant(raw.server_now);
  instant(raw.owner_watermark);
  if (typeof raw.publication_fingerprint !== "string" || !/^[0-9a-f]{64}$/.test(raw.publication_fingerprint) ||
      !Number.isInteger(raw.reminder_hour_local) || (raw.reminder_hour_local as number) < 0 ||
      (raw.reminder_hour_local as number) > 23 || typeof raw.automation_allowed !== "boolean") fail();
  if (raw.verified_access_until !== null) {
    const until = instant(raw.verified_access_until);
    if (raw.automation_allowed && until <= now) fail();
  }
  if (!Array.isArray(raw.plants) || raw.plants.length > limit) fail();
  let previous = after;
  const seen = new Set<string>();
  const plants = raw.plants.map((value: unknown) => {
    const row = object(value);
    const id = uuid(row.plant_id);
    if ((previous !== null && id <= previous) || !positive(row.care_revision)) fail();
    previous = id;
    const profile = object(row.care_profile);
    if (profile.plant_id !== row.plant_id || !Object.hasOwn(profile, "profile")) fail();
    if (!Array.isArray(row.first_aid_controls)) fail();
    const controls = row.first_aid_controls.map((item: unknown) => control(item, row.care_revision as number, seen));
    const card = projectCareRecommendation(row.plant_id as string, profile, locale);
    if (!raw.automation_allowed) {
      card.next_check = null;
      if ("routine_check" in card) delete card.routine_check;
    }
    return {
      plant_id: row.plant_id,
      care_revision: row.care_revision,
      care_recommendation: card,
      first_aid_controls: raw.automation_allowed ? controls : [],
    };
  });
  if (raw.next_after !== null) {
    const cursor = uuid(raw.next_after);
    if (plants.length === 0 || plants.length !== limit || raw.next_after !== plants.at(-1)!.plant_id ||
        cursor !== previous || (after !== null && cursor <= after)) fail();
  }
  return {
    owner_id: raw.owner_id,
    server_now: raw.server_now,
    owner_watermark: raw.owner_watermark,
    publication_fingerprint: raw.publication_fingerprint,
    reminder_hour_local: raw.reminder_hour_local,
    automation_allowed: raw.automation_allowed,
    verified_access_until: raw.verified_access_until,
    plants,
    next_after: raw.next_after,
  };
}

/** Independent read-only composition. Tests replace transport, never authentication. */
export function createCareOverviewHandler(options: CareOverviewOptions = {}) {
  const env = options.env ?? ((name: string) => Deno.env.get(name));
  const client = (keyName: string) => {
    const url = env("SUPABASE_URL")?.trim();
    const key = env(keyName)?.trim();
    if (!url || !key) fail();
    return createClient(url, key, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      global: { fetch: options.fetch },
    });
  };
  return async (req: Request): Promise<Response> => {
    try {
      const url = new URL(req.url);
      if (!/^(?:\/|\/care-overview\/?|\/functions\/v1\/care-overview\/?)$/.test(url.pathname)) fail(404);
      if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: { ...headers,
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type, x-client-locale, accept-language",
      } });
      if (req.method !== "GET") fail(405);
      for (const [key, value] of url.searchParams) {
        if (!["after", "limit"].includes(key) || url.searchParams.getAll(key).length !== 1 || !value) fail(400);
      }
      let after: string | null = null;
      if (url.searchParams.has("after")) {
        try { after = requireUuid(url.searchParams.get("after"), "after"); } catch { fail(400); }
      }
      const rawLimit = url.searchParams.get("limit");
      const limit = rawLimit === null ? 100 : Number(rawLimit);
      if ((rawLimit !== null && !/^[1-9][0-9]*$/.test(rawLimit)) || !Number.isSafeInteger(limit) || limit < 1 || limit > 200) fail(400);
      const token = extractBearerToken(req);
      if (!token || !/^[A-Za-z0-9._~+\/-]+=*$/.test(token)) fail(401);
      const auth = await client("SUPABASE_ANON_KEY").auth.getUser(token);
      if (auth.error) {
        const status = auth.error.status;
        fail(status === 400 || status === 401 || status === 403 ? 401 : 503);
      }
      if (!auth.data.user) fail(401);
      const owner = uuid(auth.data.user.id);
      if (auth.data.user.is_anonymous === true) fail(403);
      // Missing is_anonymous is never evidence of permanence: SQL checks it atomically.
      const result = await client("SUPABASE_SERVICE_ROLE_KEY").rpc("read_owner_care_overview", {
        p_owner_id: owner, p_after: after, p_limit: limit,
      });
      if (result.error) {
        if (result.error.code === "42501" && result.error.message === "ACTIVE_PERMANENT_OWNER_REQUIRED") fail(403);
        if (result.error.code === "22023" && result.error.message === "INVALID_CARE_OVERVIEW_LIMIT") fail(400);
        fail();
      }
      return jsonResponse(page(result.data, owner, after, limit, resolveLocale(req)), 200, headers);
    } catch (error) {
      const status = error instanceof Failure ? error.status : 503;
      const code = status === 401 ? "UNAUTHORIZED" : status === 403 ? "FORBIDDEN" :
        status === 400 ? "VALIDATION_ERROR" : status === 404 ? "NOT_FOUND" :
        status === 405 ? "METHOD_NOT_ALLOWED" : "INTERNAL_ERROR";
      return jsonResponse({ error: {
        code,
        message: status === 503 ? "Care overview is temporarily unavailable." : "Care overview request rejected.",
        retryable: status === 503,
      } }, status, { ...headers, ...(status === 405 ? { Allow: "GET, OPTIONS" } : {}) });
    }
  };
}
