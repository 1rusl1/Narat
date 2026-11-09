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
    } else if (path === "/rest/v1/rpc/fetch_sync_delta") {
      if (options.throwRpc) throw new Error(rawFailure);
      status = options.rpcStatus ?? 200;
      if (options.rawRpcText !== undefined) {
        return new Response(options.rawRpcText, { status });
      }
      const parameters = await req.json();
      body = options.rpc
        ? options.rpc(parameters)
        : Object.hasOwn(options, "rpcBody") ? options.rpcBody : page();
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

Deno.test("T162 composition: bare T152 fallback, unchanged command and explicit delegates", async () => {
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
    const commandResponse = await f.handler(req);
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
