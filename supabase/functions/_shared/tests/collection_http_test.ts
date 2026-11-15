// T162 fixtures: real Supabase clients and production HTTP composition;
// only the transport/config are mocked. No live Auth, PostgreSQL or Swift proof.
import { assertEquals, assertStrictEquals } from "@std/assert";
import { createClient } from "@supabase/supabase-js";
import {
  createPlantsApiHandler,
  createProductionPlantsApiHandler,
} from "../../plants-api/index.ts";

const ownerA = "11111111-1111-4111-8111-111111111111";
const ownerB = "22222222-2222-4222-8222-222222222222";
const serviceKey = "fixture-service-key";
const backend = "https://sync.example.test";
const until = "2026-11-03T09:00:00.999999+00:00";
const changedAt = "2026-11-02T09:00:00.123456+00:00";
const since = "2026-11-01T09:00:00.000001Z";
const rawFailure = "private SQL / credentials " + serviceKey;
type Locale = "en" | "pl";

function row(id = ownerA, deleted = false) {
  return {
    entity_type: deleted ? "care_entries" : "plants",
    id,
    updated_at: changedAt,
    deleted_at: deleted ? changedAt : null,
    data: deleted ? null : {
      id, personal_name: "Żółta roślina", revision: 7, care_revision: 4,
      main_photo_id: null,
    },
  };
}

function page(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    until,
    has_more: false,
    last_cursor: null,
    next_since: until,
    profile: {
      preferred_locale: "pl",
      reminder_hour_local: 9,
      report_notifications_enabled: true,
      trial_reminder_enabled: false,
    },
    entitlement: {
      product_id: "app.narat.plants.pro.monthly",
      state: "active",
      offer_kind: "paid",
      valid_until: "2026-12-01T00:00:00+00:00",
      grace_until: null,
      trial_end_at: null,
      auto_renew_enabled: true,
    },
    changes: [row()],
    ...overrides,
  };
}

interface FixtureOptions {
  config?: Record<string, string | undefined>;
  authStatus?: number;
  profileStatus?: number;
  profile?: unknown;
  throwProfile?: boolean;
  anonymous?: boolean;
  rpcStatus?: number;
  rpcBody?: unknown;
  rawRpcText?: string;
  throwRpc?: boolean;
  rpc?: (body: Record<string, unknown>) => unknown;
}

function fixture(options: FixtureOptions = {}) {
  const requests: Request[] = [];
  let envCalls = 0;
  const transport: typeof fetch = async (input, init) => {
    const req = new Request(input, init);
    requests.push(req.clone());
    const path = new URL(req.url).pathname;
    let body: unknown;
    let status = 200;
    if (path === "/auth/v1/user") {
      status = options.authStatus ?? 200;
      body = status === 200
        ? {
          id: req.headers.get("authorization") === "Bearer session-b" ? ownerB : ownerA,
          aud: "authenticated", role: "authenticated", is_anonymous: false,
          app_metadata: {}, user_metadata: {}, created_at: since,
        }
        : { code: "bad_jwt", message: rawFailure };
    } else if (path === "/rest/v1/profiles") {
      if (options.throwProfile) throw new Error(rawFailure);
      status = options.profileStatus ?? 200;
      body = Object.hasOwn(options, "profile") ? options.profile : [{
        account_state: "active", anonymous: options.anonymous ?? false,
      }];
    } else if (path === "/rest/v1/rpc/fetch_sync_delta" ||
      path === "/rest/v1/rpc/execute_plant_create_command") {
      if (options.throwRpc) throw new Error(rawFailure);
      status = options.rpcStatus ?? 200;
      if (options.rawRpcText !== undefined) {
        return new Response(options.rawRpcText, { status });
      }
      const parameters = await req.json();
      body = options.rpc
        ? options.rpc(parameters)
        : Object.hasOwn(options, "rpcBody") ? options.rpcBody
        : path.endsWith("/execute_plant_create_command") ? createReceipt() : page();
    } else {
      throw new Error("Unexpected fixture URL: " + req.url);
    }
    return new Response(JSON.stringify(body), {
      status, headers: { "content-type": "application/json" },
    });
  };
  const deps = {
    authClientFactory: (token: string) => createClient(backend, "fixture-public-key", {
      global: { fetch: transport, headers: { Authorization: "Bearer " + token } },
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    }),
  };
  const handler = createProductionPlantsApiHandler(deps, {
    env: (name) => {
      envCalls++;
      const config: Record<string, string | undefined> = options.config ?? {
        SUPABASE_URL: backend, SUPABASE_SERVICE_ROLE_KEY: serviceKey,
      };
      return config[name];
    },
    fetch: transport,
  });
  return {
    handler, deps, requests,
    get envCalls() { return envCalls; },
    get rpcRequests() {
      return requests.filter((req) => new URL(req.url).pathname.includes("/rpc/"));
    },
  };
}

function request(query = "", locale: Locale = "en", token: string | null = "session-a", prefix = "") {
  const headers = new Headers({
    "x-client-locale": locale,
    // Untrusted headers must never override authenticated owner context.
    "x-owner-id": ownerB,
  });
  if (token !== null) headers.set("authorization", "Bearer " + token);
  return new Request("https://api.example.test" + prefix + "/sync?" + query, { headers });
}

function query(values: Record<string, string>): string {
  return new URLSearchParams(values).toString();
}

function envelope(status: number, locale: Locale) {
  return {
    error: {
      code: status === 403 ? "FORBIDDEN" : status === 400 ? "VALIDATION_ERROR" : "INTERNAL_ERROR",
      message: status === 403
        ? locale === "pl"
          ? "Konto jest w trakcie usuwania lub niedostępne."
          : "Account is deleting or unavailable."
        : status === 400
        ? locale === "pl"
          ? "Nieprawidłowe parametry synchronizacji."
          : "Invalid synchronization parameters."
        : locale === "pl"
        ? "Synchronizacja jest tymczasowo niedostępna. Spróbuj ponownie później."
        : "Synchronization is temporarily unavailable. Please try again later.",
      retryable: status === 503,
    },
  };
}

for (const prefix of ["", "/plants-api", "/functions/v1/plants-api"]) {
  Deno.test("T162 production HTTP: canonical SQL projection and real RPC transport " + prefix, async () => {
    const f = fixture();
    const response = await f.handler(request("", "en", "session-a", prefix));
    assertEquals(response.status, 200);
    assertEquals(await response.json(), page());
    assertEquals(response.headers.get("access-control-allow-origin"), "*");
    assertEquals(response.headers.get("content-type"), "application/json; charset=utf-8");
    assertEquals(f.requests.map((req) => new URL(req.url).pathname), [
      "/auth/v1/user", "/rest/v1/profiles", "/rest/v1/rpc/fetch_sync_delta",
    ]);
    assertEquals(f.requests[0].headers.get("authorization"), "Bearer session-a");
    const profileURL = new URL(f.requests[1].url);
    assertEquals(profileURL.searchParams.get("id"), "eq." + ownerA);
    assertEquals(profileURL.searchParams.get("select"), "account_state,anonymous");
    const rpc = f.rpcRequests[0];
    assertEquals(rpc.url, backend + "/rest/v1/rpc/fetch_sync_delta");
    assertEquals(rpc.method, "POST");
    assertEquals(rpc.headers.get("authorization"), "Bearer " + serviceKey);
    assertEquals(rpc.headers.get("apikey"), serviceKey);
    assertEquals(await rpc.json(), {
      p_owner_id: ownerA, p_since: null, p_until: null,
      p_cursor_updated_at: null, p_cursor_entity_type: null, p_cursor_id: null, p_limit: 200,
    });
  });
}

Deno.test("T162 production HTTP: multipage window, microseconds, tombstone and final watermark", async () => {
  const cursor = { since, until, updated_at: changedAt, entity_type: "plants", id: ownerA };
  const first = page({ has_more: true, last_cursor: cursor, next_since: null });
  const second = page({ changes: [row(ownerB, true)] });
  const empty = page({ changes: [], entitlement: null });
  const f = fixture({
    rpc: (params) => params.p_since === until
      ? empty : params.p_cursor_id === null ? first : second,
  });
  let response = await f.handler(request(query({ since, until, limit: "1" })));
  assertEquals(response.status, 200);
  assertEquals(await response.json(), first);
  response = await f.handler(request(query({
    since, until, limit: "1", cursor_updated_at: cursor.updated_at,
    cursor_entity_type: cursor.entity_type, cursor_id: cursor.id,
  })));
  assertEquals(response.status, 200);
  assertEquals(await response.json(), second);
  response = await f.handler(request(query({ since: until })));
  assertEquals(response.status, 200);
  assertEquals(await response.json(), empty);
  assertEquals(await f.rpcRequests[0].json(), {
    p_owner_id: ownerA, p_since: since, p_until: until, p_limit: 1,
    p_cursor_updated_at: null, p_cursor_entity_type: null, p_cursor_id: null,
  });
  assertEquals(await f.rpcRequests[1].json(), {
    p_owner_id: ownerA, p_since: since, p_until: until, p_limit: 1,
    p_cursor_updated_at: changedAt, p_cursor_entity_type: "plants", p_cursor_id: ownerA,
  });
  assertEquals(await f.rpcRequests[2].json(), {
    p_owner_id: ownerA, p_since: until, p_until: null, p_limit: 200,
    p_cursor_updated_at: null, p_cursor_entity_type: null, p_cursor_id: null,
  });
});

Deno.test("T165 production sync accepts the current profile and an in-flight historical claim cursor", async () => {
  const current = page({
    profile: { preferred_locale: "en", reminder_hour_local: 9, trial_reminder_enabled: true },
  });
  const f = fixture({ rpc: () => current });
  const response = await f.handler(request(query({
    since, until, limit: "1", cursor_updated_at: changedAt,
    cursor_entity_type: "notification_claim_summaries", cursor_id: ownerB,
  })));
  assertEquals(response.status, 200);
  assertEquals(await response.json(), current);
  assertEquals(await f.rpcRequests[0].json(), {
    p_owner_id: ownerA, p_since: since, p_until: until, p_limit: 1,
    p_cursor_updated_at: changedAt, p_cursor_entity_type: "notification_claim_summaries", p_cursor_id: ownerB,
  });
});

Deno.test("T162 production HTTP: A/B/A identity isolation and active anonymous owner", async () => {
  const f = fixture({
    anonymous: true,
    rpc: (params) => page({ changes: [row(String(params.p_owner_id))] }),
  });
  for (const [token, owner] of [
    ["session-a", ownerA], ["session-b", ownerB], ["session-a", ownerA],
  ]) {
    const response = await f.handler(request("limit=500", "en", token));
    assertEquals(response.status, 200);
    assertEquals(await response.json(), page({ changes: [row(owner)] }));
  }
  assertEquals(await Promise.all(f.rpcRequests.map(async (req) => (await req.json()).p_owner_id)), [
    ownerA, ownerB, ownerA,
  ]);
  const profiles = f.requests.filter((req) => new URL(req.url).pathname.endsWith("/profiles"));
  assertEquals(profiles.map((req) => new URL(req.url).searchParams.get("id")), [
    "eq." + ownerA, "eq." + ownerB, "eq." + ownerA,
  ]);
  for (const rpc of f.rpcRequests) {
    assertEquals(rpc.headers.get("authorization"), "Bearer " + serviceKey);
  }
});

Deno.test("T162 production HTTP: invalid/duplicate/spoofed parameters fail before service client/RPC", async () => {
  const complete = {
    until, cursor_updated_at: changedAt, cursor_entity_type: "plants", cursor_id: ownerA,
  };
  const invalid = [
    "since=", "until=", "since=2026-02-30T00:00:00Z",
    "since=2025-02-29T00:00:00Z", "since=2026-11-01",
    "since=2026-11-01T00:00:00", "since=2026-11-01T24:00:00Z",
    "since=2026-11-01T00:60:00Z", "since=2026-11-01T00:00:60Z",
    "since=2026-11-01T00:00:00.1234567Z",
    "limit=", "limit=0", "limit=-1", "limit=501", "limit=1.5", "limit=1e2", "limit=NaN",
    "limit=2&%6cimit=3", "since=" + since + "&since=" + since,
    "owner=" + ownerB, "owner_id=" + ownerB, "p_owner_id=" + ownerB,
    "user_id=" + ownerB, "page_token=forged",
    query({ cursor_updated_at: changedAt }), query({ cursor_entity_type: "plants" }),
    query({ cursor_id: ownerA }),
    query({ cursor_updated_at: changedAt, cursor_entity_type: "plants", cursor_id: ownerA }),
    query({ ...complete, cursor_id: "invalid" }),
    query({ ...complete, cursor_entity_type: "rooms" }),
    query({ ...complete, cursor_updated_at: "invalid" }),
    query({ ...complete, cursor_entity_type: "" }),
    query({ since: until, until: since }),
    query({ ...complete, since: until }),
    query({ ...complete, until: since }),
    query({ ...complete, cursor_updated_at: changedAt.replace("123456", "123455"), since: changedAt }),
    query({ ...complete }) + "&cursor_id=" + ownerA,
  ];
  for (const locale of ["en", "pl"] as const) {
    const f = fixture();
    for (const value of invalid) {
      const response = await f.handler(request(value, locale));
      assertEquals(response.status, 400, value);
      assertEquals(await response.json(), envelope(400, locale), value);
    }
    assertEquals(f.rpcRequests.length, 0);
    assertEquals(f.envCalls, 0);
  }
});

Deno.test("T162 production HTTP: valid leap day, timezone offsets, inclusive until and limit boundaries", async () => {
  const f = fixture({ rpcBody: page({ changes: [] }) });
  for (const limit of ["1", "500"]) {
    const response = await f.handler(request(query({
      since: "2024-02-29T10:00:00.000001+01:00",
      until, limit, cursor_updated_at: until,
      cursor_entity_type: "plants", cursor_id: ownerA,
    })));
    assertEquals(response.status, 200);
    assertEquals(await response.json(), page({ changes: [] }));
  }
  assertEquals((await f.rpcRequests[0].json()).p_since, "2024-02-29T10:00:00.000001+01:00");
  assertEquals((await f.rpcRequests[1].json()).p_limit, 500);
});

Deno.test("T162 production HTTP: null/malformed RPC and SQL/network errors are sanitized EN/PL", async () => {
  const malformed: unknown[] = [
    null, [], "private", {}, page({ until: "bad" }), page({ profile: null }),
    page({ profile: { preferred_locale: "en" } }), page({ entitlement: {} }),
    page({ changes: null }), page({ changes: [{}] }),
    page({ changes: [{ ...row(), deleted_at: changedAt }] }),
    page({ changes: [{ ...row(), data: null }] }),
    page({ has_more: "false" }), page({ next_since: null }),
    page({ has_more: true, next_since: null, last_cursor: null }),
    page({ has_more: true, next_since: null, last_cursor: {
      since, until, updated_at: changedAt, entity_type: "plants", id: ownerB,
    } }),
  ];
  const failures: { options: FixtureOptions; status: number }[] = [
    ...malformed.map((rpcBody) => ({ options: { rpcBody }, status: 503 })),
    { options: { rawRpcText: rawFailure }, status: 503 },
    { options: { throwRpc: true }, status: 503 },
    { options: { rpcStatus: 500, rpcBody: {
      code: "XX000", message: rawFailure, details: rawFailure, hint: rawFailure,
    } }, status: 503 },
    { options: { rpcStatus: 403, rpcBody: { code: "42501", message: rawFailure } }, status: 503 },
    { options: { rpcStatus: 403, rpcBody: { code: "42501", message: "owner_forbidden" } }, status: 403 },
    { options: { rpcStatus: 400, rpcBody: { code: "22023", message: rawFailure } }, status: 400 },
  ];
  for (const locale of ["en", "pl"] as const) {
    for (const failure of failures) {
      const f = fixture(failure.options);
      const response = await f.handler(request("", locale));
      assertEquals(response.status, failure.status);
      assertEquals(await response.json(), envelope(failure.status, locale));
      assertEquals(f.rpcRequests.length, 1);
    }
  }
});

Deno.test("T162 production HTTP: auth/profile guards precede query validation and privileged RPC", async () => {
  const cases: { options: FixtureOptions; token?: string | null; status: number; paths: number }[] = [
    { options: {}, token: null, status: 401, paths: 0 },
    { options: { authStatus: 401 }, status: 401, paths: 1 },
    { options: { profile: [] }, status: 403, paths: 2 },
    { options: { profile: [{ account_state: "deleting", anonymous: false }] }, status: 403, paths: 2 },
    { options: { profile: [{ account_state: "deleted", anonymous: false }] }, status: 403, paths: 2 },
    { options: { profile: [{ account_state: "active", anonymous: "false" }] }, status: 403, paths: 2 },
    { options: { profileStatus: 500, profile: { code: "XX000", message: rawFailure } }, status: 503, paths: 2 },
    { options: { throwProfile: true }, status: 503, paths: 2 },
  ];
  for (const locale of ["en", "pl"] as const) {
    for (const denied of cases) {
      const f = fixture(denied.options);
      const response = await f.handler(request("owner_id=" + ownerB, locale,
        denied.token === undefined ? "session-a" : denied.token));
      assertEquals(response.status, denied.status);
      const text = await response.text();
      assertEquals(text.includes(rawFailure), false);
      assertEquals(f.requests.length, denied.paths);
      assertEquals(f.rpcRequests.length, 0);
      assertEquals(f.envCalls, 0);
    }
  }
});

Deno.test("T162 production HTTP: lazy missing/invalid service configuration fails closed", async () => {
  for (const config of [
    {}, { SUPABASE_URL: backend }, { SUPABASE_SERVICE_ROLE_KEY: serviceKey },
    { SUPABASE_URL: " ", SUPABASE_SERVICE_ROLE_KEY: serviceKey },
    { SUPABASE_URL: "invalid-url", SUPABASE_SERVICE_ROLE_KEY: serviceKey },
  ]) {
    for (const locale of ["en", "pl"] as const) {
      const f = fixture({ config });
      const response = await f.handler(request("", locale));
      assertEquals(response.status, 503);
      assertEquals(await response.json(), envelope(503, locale));
      assertEquals(f.rpcRequests.length, 0);
    }
  }
  const f = fixture({ config: {} });
  for (const req of [
    new Request("https://api.example.test/health"),
    new Request("https://api.example.test/sync", { method: "OPTIONS" }),
  ]) {
    const response = await f.handler(req);
    assertEquals(response.status, 200);
    await response.text();
  }
  assertEquals(f.requests.length, 0);
  assertEquals(f.envCalls, 0);
});

Deno.test("T162 composition: bare T152 sync/command fallback and explicit sync delegate", async () => {
  for (const locale of ["en", "pl"] as const) {
    const f = fixture();
    const bare = createPlantsApiHandler(f.deps);
    const response = await bare(request("", locale));
    assertEquals(response.status, 503);
    assertEquals(await response.json(), envelope(503, locale));
    const req = new Request("https://api.example.test/commands", {
      method: "POST", headers: { authorization: "Bearer session-a", "x-client-locale": locale },
      body: "{",
    });
    const commandResponse = await bare(req);
    assertEquals(commandResponse.status, 503);
    assertEquals(await commandResponse.json(), { error: {
      code: "INTERNAL_ERROR", retryable: true,
      message: locale === "pl"
        ? "Zapisywanie jest tymczasowo niedostępne. Spróbuj ponownie później."
        : "Saving is temporarily unavailable. Please try again later.",
    } });
    assertEquals(req.bodyUsed, false);
    assertEquals(f.rpcRequests.length, 0);
    assertEquals(f.envCalls, 0);
  }
  const f = fixture();
  const expected = new Response("explicit delegate", { status: 202 });
  const original = request("owner_id=" + ownerB);
  let calls = 0;
  const handler = createProductionPlantsApiHandler({
    ...f.deps,
    handleSync: async (req, ctx, url) => {
      calls++;
      assertStrictEquals(req, original);
      assertEquals(ctx.ownerId, ownerA);
      assertEquals(url.href, original.url);
      return expected;
    },
  }, { env: () => { throw new Error("must remain lazy"); } });
  assertStrictEquals(await handler(original), expected);
  assertEquals(await expected.text(), "explicit delegate");
  assertEquals(calls, 1);
  assertEquals(f.rpcRequests.length, 0);
});

const operation = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const otherOperation = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const taxon = "33333333-3333-4333-8333-333333333333";

function createPayload(overrides: Record<string, unknown> = {}) {
  return { creation_source: "catalogue", plant_id: "fixture_collection_cap", ...overrides };
}

// Exact execute_plant_create_command JSONB projection after retire_rooms.
// This is SQL-shaped fixture data, not an execution of the SQL function.
function createReceipt(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    plant_id: ownerB, care_revision: 1, context_state: "current",
    next_available_step: "enable_basic_care",
    paid_action: "generate_full_routine_plan",
    plan_availability: "available", watermark: until, ...overrides,
  };
}

function commandEnvelope(payload: unknown = createPayload(), overrides: Record<string, unknown> = {}) {
  return {
    operation_id: operation, command_name: "plant.create",
    payload_json: JSON.stringify(payload), ...overrides,
  };
}

function commandRequest(
  body: unknown = commandEnvelope(),
  locale: Locale = "en",
  token: string | null = "session-a",
  header: string | null = operation,
  suffix = "",
  prefix = "",
) {
  const headers = new Headers({
    "content-type": "application/json", "x-client-locale": locale, "x-owner-id": ownerB,
  });
  if (token !== null) headers.set("authorization", "Bearer " + token);
  if (header !== null) headers.set("x-operation-id", header);
  return new Request("https://api.example.test" + prefix + "/commands" + suffix, {
    method: "POST", headers, body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function commandEnvelopeError(
  status: number, locale: Locale, code = status === 403 ? "FORBIDDEN"
    : status === 400 ? "VALIDATION_ERROR" : status === 409 ? "CONFLICT" : "INTERNAL_ERROR",
) {
  const messages: Record<string, [string, string]> = {
    VALIDATION_ERROR: ["Invalid catalogue creation command.", "Nieprawidłowe polecenie dodania rośliny z katalogu."],
    FORBIDDEN: ["An active permanent account is required.", "Wymagane jest aktywne, stałe konto."],
    CONFLICT: ["Operation conflicts with an existing request.", "Operacja jest sprzeczna z istniejącym żądaniem."],
    COLLECTION_LIMIT_REACHED: ["Your collection has reached its plant limit.", "Osiągnięto limit roślin w kolekcji."],
    INTERNAL_ERROR: ["Saving is temporarily unavailable. Please try again later.", "Zapisywanie jest tymczasowo niedostępne. Spróbuj ponownie później."],
  };
  return { error: { code, message: messages[code][locale === "pl" ? 1 : 0], retryable: status === 503 } };
}

Deno.test("T162 catalogue production: exact RPC, SQL receipt and same operation retry without photo/questions", async () => {
  for (const prefix of ["", "/plants-api", "/functions/v1/plants-api"]) {
    for (const locale of ["en", "pl"] as const) {
      const f = fixture();
      const input = commandEnvelope();
      for (let attempt = 0; attempt < 2; attempt++) {
        const response = await f.handler(commandRequest(input, locale, "session-a", operation, "", prefix));
        assertEquals(response.status, 200);
        assertEquals(await response.json(), createReceipt());
        assertEquals(response.headers.get("access-control-allow-origin"), "*");
      }
      assertEquals(f.requests.map((req) => new URL(req.url).pathname), [
        "/auth/v1/user", "/rest/v1/profiles", "/rest/v1/rpc/execute_plant_create_command",
        "/auth/v1/user", "/rest/v1/profiles", "/rest/v1/rpc/execute_plant_create_command",
      ]);
      assertEquals(f.rpcRequests.length, 2);
      for (const rpc of f.rpcRequests) {
        assertEquals(rpc.url, backend + "/rest/v1/rpc/execute_plant_create_command");
        assertEquals(rpc.method, "POST");
        assertEquals(rpc.headers.get("authorization"), "Bearer " + serviceKey);
        assertEquals(rpc.headers.get("apikey"), serviceKey);
        assertEquals(await rpc.json(), {
          p_owner_id: ownerA, p_operation_id: operation, p_payload: createPayload(),
        });
      }
    }
  }
});

Deno.test("T162 catalogue production: preserve SQL inputs, optional header and null paid_action", async () => {
  const payload = createPayload({
    plant_id: null, taxon_id: taxon, personal_name: "  Żółta roślina  ",
    display_name: null, origin_flow_id: otherOperation, photo_id: null,
    creation_intent: "care", add_method: "catalogue",
    conditions: { light_level: "medium", light_source: "manual", light_confirmed: true },
    overrides: { display_name: "Fern", watering_habit: "weekly" },
  });
  const receipt = createReceipt({
    next_available_step: "view_plant", plan_availability: "care_profile_unavailable", paid_action: null,
  });
  const f = fixture({ rpcBody: receipt });
  const response = await f.handler(commandRequest(commandEnvelope(payload, {
    operation_id: operation.toUpperCase(), plant_id: null,
  }), "pl", "session-a", null));
  assertEquals(response.status, 200);
  assertEquals(await response.json(), receipt);
  assertEquals(await f.rpcRequests[0].json(), {
    p_owner_id: ownerA, p_operation_id: operation.toUpperCase(), p_payload: payload,
  });
  const matching = await f.handler(commandRequest(commandEnvelope(payload), "en", "session-a", operation.toUpperCase()));
  assertEquals(matching.status, 200);
  assertEquals(await matching.json(), receipt);
});

Deno.test("T162 catalogue production: A/B/A owner isolation, then canonical sync projection", async () => {
  const projection = (id: string) => page({ changes: [{
    entity_type: "plants", id, updated_at: until, deleted_at: null,
    data: {
      id, origin_flow_id: null, creation_intent: "care", add_method: "catalogue",
      personal_name: "Fern", display_name: "Fern", taxon_id: taxon,
      plant_id: "fixture_collection_cap", cultivar_label: null, main_photo_id: null,
      current_condition_snapshot_id: null, origin_draft_id: null,
      creation_source: "catalogue", revision: 1, care_revision: 1, created_at: until,
    },
  }] });
  const f = fixture({
    rpc: (params) => "p_payload" in params
      ? createReceipt({ plant_id: params.p_owner_id })
      : projection(String(params.p_owner_id)),
  });
  for (const [token, owner] of [["session-a", ownerA], ["session-b", ownerB], ["session-a", ownerA]]) {
    const created = await f.handler(commandRequest(commandEnvelope(createPayload({ taxon_id: taxon, display_name: "Fern" })), "en", token));
    assertEquals(created.status, 200);
    assertEquals(await created.json(), createReceipt({ plant_id: owner }));
    const synced = await f.handler(request(query({ since }), "en", token));
    assertEquals(synced.status, 200);
    assertEquals(await synced.json(), projection(owner));
  }
  assertEquals(await Promise.all(f.rpcRequests.map(async (req) => (await req.json()).p_owner_id)),
    [ownerA, ownerA, ownerB, ownerB, ownerA, ownerA]);
  const profiles = f.requests.filter((req) => new URL(req.url).pathname.endsWith("/profiles"));
  assertEquals(profiles.map((req) => new URL(req.url).searchParams.get("id")),
    [ownerA, ownerA, ownerB, ownerB, ownerA, ownerA].map((owner) => "eq." + owner));
});

Deno.test("T162 catalogue production: invalid envelope/payload/query never reaches privileged RPC", async () => {
  const invalid = [
    "{", "null", "[]",
    commandEnvelope(createPayload(), { operation_id: "bad" }),
    commandEnvelope(createPayload(), { operation_id: null }),
    commandEnvelope(createPayload(), { payload_json: {} }),
    commandEnvelope(createPayload(), { payload_json: "{" }),
    commandEnvelope(createPayload(), { payload_json: "null" }),
    commandEnvelope(createPayload(), { payload_json: "[]" }),
    commandEnvelope(createPayload(), { owner_id: ownerB }),
    commandEnvelope(createPayload(), { p_owner_id: ownerB }),
    commandEnvelope(createPayload(), { plant_id: ownerB }),
    ...["free_care.select", "room.create", "photo.set_main", "unknown"]
      .map((command_name) => commandEnvelope(createPayload(), { command_name })),
    ...[
      {}, { creation_source: "catalogue" }, createPayload({ creation_source: "local_fallback" }),
      createPayload({ creation_source: "guest_claim" }), createPayload({ creation_source: "identification" }),
      createPayload({ taxon_id: "invalid" }), createPayload({ photo_id: "invalid" }),
      createPayload({ photo_id: ownerB }),
      createPayload({ origin_flow_id: 123 }), createPayload({ plant_id: [] }),
      createPayload({ personal_name: {} }), createPayload({ add_method: "scan" }),
      createPayload({ conditions: null }), createPayload({ conditions: [] }),
      createPayload({ overrides: "invalid" }), createPayload({ conditions: { light_confirmed: "true" } }),
      createPayload({ conditions: { light_source: "camera_estimate" } }),
      createPayload({ conditions: { season_override: "summer" } }),
      ...["owner", "owner_id", "p_owner_id", "user_id", "room_id", "new_room_name",
        "create_room_name", "origin_draft_id", "analysis_receipt", "plan_availability",
        "camera_estimate", "season_override"].map((key) => createPayload({ [key]: ownerB })),
      ...["conditions", "overrides"].flatMap((key) =>
        ["owner_id", "p_owner_id", "user_id", "room_id", "season_override"].map((field) =>
          createPayload({ [key]: { [field]: ownerB } }))),
    ].map((payload) => commandEnvelope(payload)),
  ];
  for (const locale of ["en", "pl"] as const) {
    const f = fixture();
    for (const body of invalid) {
      const response = await f.handler(commandRequest(body, locale));
      assertEquals(response.status, 400, JSON.stringify(body));
      assertEquals(await response.json(), commandEnvelopeError(400, locale));
    }
    for (const header of ["invalid", ""]) {
      const response = await f.handler(commandRequest(commandEnvelope(), locale, "session-a", header));
      assertEquals(response.status, 400);
      assertEquals(await response.json(), commandEnvelopeError(400, locale));
    }
    for (const suffix of ["?owner_id=" + ownerB, "?p_owner_id=" + ownerB, "?unknown=1"]) {
      const response = await f.handler(commandRequest(commandEnvelope(), locale, "session-a", operation, suffix));
      assertEquals(response.status, 400);
      assertEquals(await response.json(), commandEnvelopeError(400, locale));
    }
    const conflict = await f.handler(commandRequest(commandEnvelope(), locale, "session-a", otherOperation));
    assertEquals(conflict.status, 409);
    assertEquals(await conflict.json(), commandEnvelopeError(409, locale));
    assertEquals(f.rpcRequests.length, 0);
    assertEquals(f.envCalls, 0);
  }
});

Deno.test("T162 catalogue production: SQL cap/conflicts/owner/validation/transient errors sanitized EN/PL", async () => {
  const failures: { code: string; message: string; status: number; apiCode?: string }[] = [
    { code: "P0001", message: "COLLECTION_LIMIT_REACHED", status: 409, apiCode: "COLLECTION_LIMIT_REACHED" },
    { code: "23505", message: "operation_payload_mismatch", status: 409, apiCode: "CONFLICT" },
    { code: "23505", message: rawFailure, status: 409, apiCode: "CONFLICT" },
    { code: "P0002", message: "owner_profile_not_found", status: 403 },
    { code: "42501", message: "account_not_active", status: 403 },
    { code: "42501", message: "owner_forbidden", status: 403 },
    { code: "P0002", message: "taxon_not_published", status: 400 },
    ...["22023", "22P02", "23503", "23514"].map((code) => ({ code, message: rawFailure, status: 400 })),
    ...["40001", "40P01", "08006", "XX000", "P0001", "42501", "P0002"]
      .map((code) => ({ code, message: rawFailure, status: 503 })),
  ];
  for (const locale of ["en", "pl"] as const) {
    for (const failure of failures) {
      const f = fixture({ rpcStatus: 400, rpcBody: {
        code: failure.code, message: failure.message, details: rawFailure, hint: rawFailure,
      } });
      const response = await f.handler(commandRequest(commandEnvelope(), locale));
      assertEquals(response.status, failure.status);
      assertEquals(await response.json(), commandEnvelopeError(failure.status, locale, failure.apiCode));
      assertEquals(f.rpcRequests.length, 1);
    }
  }
});

Deno.test("T162 catalogue production: null/malformed SQL receipts and transport errors fail closed", async () => {
  const malformed: unknown[] = [null, [], "private", {}, ...[
    ["plant_id", "invalid"], ["care_revision", "1"], ["care_revision", 0],
    ["context_state", null], ["next_available_step", {}], ["plan_availability", false],
    ["watermark", "invalid"],
  ].map(([key, value]) => createReceipt({ [String(key)]: value }))];
  for (const key of ["plant_id", "care_revision", "context_state", "next_available_step", "plan_availability", "watermark"]) {
    const missing = createReceipt();
    delete missing[key];
    malformed.push(missing);
  }
  for (const locale of ["en", "pl"] as const) {
    for (const options of [
      ...malformed.map((rpcBody) => ({ rpcBody })),
      { rawRpcText: rawFailure }, { throwRpc: true },
    ]) {
      const f = fixture(options);
      const response = await f.handler(commandRequest(commandEnvelope(), locale));
      assertEquals(response.status, 503);
      assertEquals(await response.json(), commandEnvelopeError(503, locale));
      assertEquals(f.rpcRequests.length, 1);
    }
  }
});

Deno.test("T162 catalogue production: permanent active owner required before parsing/config/RPC", async () => {
  const cases = [
    { options: {}, token: null, status: 401 },
    { options: { authStatus: 401 }, token: "session-a", status: 401 },
    { options: { anonymous: true }, token: "session-a", status: 403 },
    { options: { profile: [] }, token: "session-a", status: 403 },
    { options: { profile: [{ account_state: "deleting", anonymous: false }] }, token: "session-a", status: 403 },
    { options: { throwProfile: true }, token: "session-a", status: 503 },
  ];
  for (const locale of ["en", "pl"] as const) {
    for (const denied of cases) {
      const f = fixture(denied.options);
      const response = await f.handler(commandRequest("{", locale, denied.token));
      assertEquals(response.status, denied.status);
      const body = await response.json();
      assertEquals(body.error.code, denied.status === 401 ? "UNAUTHORIZED" : denied.status === 403 ? "FORBIDDEN" : "INTERNAL_ERROR");
      assertEquals(body.error.retryable, denied.status === 503);
      assertEquals(JSON.stringify(body).includes(rawFailure), false);
      assertEquals(f.rpcRequests.length, 0);
      assertEquals(f.envCalls, 0);
    }
  }
});

Deno.test("T162 catalogue production: missing/invalid service config is lazy and returns 503", async () => {
  for (const config of [
    {}, { SUPABASE_URL: backend }, { SUPABASE_SERVICE_ROLE_KEY: serviceKey },
    { SUPABASE_URL: " ", SUPABASE_SERVICE_ROLE_KEY: serviceKey },
    { SUPABASE_URL: "invalid-url", SUPABASE_SERVICE_ROLE_KEY: serviceKey },
    { SUPABASE_URL: backend, SUPABASE_SERVICE_ROLE_KEY: " " },
  ]) {
    for (const locale of ["en", "pl"] as const) {
      const f = fixture({ config });
      assertEquals(f.envCalls, 0);
      const response = await f.handler(commandRequest(commandEnvelope(), locale));
      assertEquals(response.status, 503);
      assertEquals(await response.json(), commandEnvelopeError(503, locale));
      assertEquals(f.rpcRequests.length, 0);
    }
  }
});

Deno.test("T162 catalogue composition: explicit command delegate wins without consuming body or config", async () => {
  const f = fixture();
  const original = commandRequest("{");
  const expected = new Response("explicit command", { status: 202 });
  let calls = 0;
  const handler = createProductionPlantsApiHandler({
    ...f.deps,
    handleCommand: async (req, ctx) => {
      calls++;
      assertStrictEquals(req, original);
      assertEquals(ctx.ownerId, ownerA);
      assertEquals(req.bodyUsed, false);
      return expected;
    },
  }, { env: () => { throw new Error("must remain lazy"); } });
  assertStrictEquals(await handler(original), expected);
  assertEquals(await expected.text(), "explicit command");
  assertEquals(calls, 1);
  assertEquals(original.bodyUsed, false);
  assertEquals(f.rpcRequests.length, 0);
});
