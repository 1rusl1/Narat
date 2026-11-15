import { assertEquals } from "@std/assert";
import { createClient } from "@supabase/supabase-js";
import { createProductionPlantsApiHandler } from "../../plants-api/index.ts";

const host = "https://profile.example.test";
const owner = "19510000-0000-4000-8000-000000000001";
const operation = "19510000-0000-4000-8000-000000000020";
const later = "19510000-0000-4000-8000-000000000021";
const watermark = "2026-11-15T09:10:01.123456+00:00";
type Options = { row?: unknown; code?: string; missing?: boolean; transportFailure?: boolean };

function fixture(options: Options = {}) {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  let hour = 9;
  const receipts = new Map<string, { hour: number; result: unknown }>();
  const mockFetch: typeof fetch = async (input, init) => {
    const req = new Request(input, init);
    const url = new URL(req.url);
    const token = req.headers.get("authorization");
    if (url.pathname === "/auth/v1/user") {
      return Response.json({ id: owner, aud: "authenticated", role: "authenticated" });
    }
    if (url.pathname === "/rest/v1/profiles") {
      assertEquals(url.searchParams.get("id"), "eq." + owner);
      assertEquals(url.searchParams.get("select"), "account_state,anonymous");
      return Response.json({
        account_state: token === "Bearer disabled" ? "deleted" : "active",
        anonymous: token === "Bearer guest",
      });
    }
    assertEquals(req.headers.get("authorization"), "Bearer service-fixture");
    const name = url.pathname.replace("/rest/v1/rpc/", "");
    const args = await req.json();
    calls.push({ name, args });
    if (options.transportFailure) throw new Error("private detail");
    if (options.code) return Response.json({ code: options.code, message: "private detail" }, { status: 400 });
    if (Object.hasOwn(options, "row")) return Response.json(options.row);
    if (name === "read_owner_profile_settings") {
      return Response.json({ preferred_locale: "pl", reminder_hour_local: hour });
    }
    assertEquals(name, "execute_profile_reminder_hour_update");
    const nextHour = args.p_payload.reminder_hour_local;
    const previous = receipts.get(args.p_operation_id);
    if (previous) {
      if (previous.hour !== nextHour) return Response.json({ code: "23505" }, { status: 400 });
      return Response.json(previous.result);
    }
    hour = nextHour;
    const result = { profile: { preferred_locale: "pl", reminder_hour_local: hour }, watermark };
    receipts.set(args.p_operation_id, { hour, result });
    return Response.json(result);
  };
  const handler = createProductionPlantsApiHandler({
    authClientFactory: (token) => createClient(host, "anon-fixture", {
      global: { fetch: mockFetch, headers: { Authorization: "Bearer " + token } }, auth: { persistSession: false, autoRefreshToken: false },
    }),
  }, {
    env: (name) => ({
      SUPABASE_URL: host,
      SUPABASE_SERVICE_ROLE_KEY: options.missing ? "" : "service-fixture",
    })[name],
    fetch: mockFetch,
  });
  return {
    calls,
    get: (path = "/me", token = "owner") => handler(new Request(host + path, {
      headers: token ? { authorization: "Bearer " + token } : {},
    })),
    send: (payload: unknown = { reminder_hour_local: 0 }, extra = {}, headers = {}, path = "/commands", token = "owner") =>
      handler(new Request(host + path, {
        method: "POST",
        headers: { ...(token ? { authorization: "Bearer " + token } : {}), ...headers },
        body: JSON.stringify({
          operation_id: operation, command_name: "profile.update",
          payload_json: JSON.stringify(payload), ...extra,
        }),
      })),
  };
}

async function responseBody(response: Response, status = 200) {
  assertEquals(response.status, status);
  assertEquals(response.headers.get("cache-control"), "private, no-store");
  const body = await response.json();
  if (status === 503) assertEquals(body.error.retryable, true);
  assertEquals(JSON.stringify(body).includes("private detail"), false);
  return body;
}

Deno.test("profile routes bind Auth owner, read default/current hours and preserve stale receipt", async () => {
  const f = fixture();
  assertEquals(await responseBody(await f.get("/functions/v1/plants-api/me")), {
    profile: { preferred_locale: "pl", reminder_hour_local: 9 },
  });
  const first = await responseBody(await f.send(undefined, { plant_id: null }, { "x-operation-id": operation }));
  assertEquals(first, { profile: { preferred_locale: "pl", reminder_hour_local: 0 }, watermark });
  assertEquals((await responseBody(await f.send({ reminder_hour_local: 23 }, {
    operation_id: later,
  }, {}, "/plants-api/commands"))).profile.reminder_hour_local, 23);
  assertEquals(await responseBody(await f.send()), first);
  assertEquals((await responseBody(await f.get("/plants-api/me"))).profile.reminder_hour_local, 23);
  assertEquals(f.calls[0], { name: "read_owner_profile_settings", args: { p_owner_id: owner } });
  assertEquals(f.calls[1], {
    name: "execute_profile_reminder_hour_update",
    args: { p_owner_id: owner, p_operation_id: operation, p_payload: { reminder_hour_local: 0 } },
  });
  assertEquals(f.calls.every((call) => call.args.p_owner_id === owner), true);
  await responseBody(await f.send({ reminder_hour_local: 1 }), 409);
});

Deno.test("profile endpoints reject unauthenticated, guest and disabled accounts privately", async () => {
  const f = fixture();
  for (const [token, status] of [["", 401], ["guest", 403], ["disabled", 403]] as const) {
    await responseBody(await f.get("/me", token), status);
    await responseBody(await f.send(undefined, {}, {}, "/commands", token), status);
  }
  assertEquals(f.calls.length, 0);
});

Deno.test("profile endpoints reject query/owner injection and closed invalid envelopes before RPC", async () => {
  const f = fixture();
  for (const payload of [
    null, [], {}, { reminder_hour_local: -1 }, { reminder_hour_local: 24 },
    { reminder_hour_local: 1.5 }, { reminder_hour_local: "9" }, { reminder_hour_local: true },
    { reminder_hour_local: null }, { reminder_hour_local: 9, owner_id: owner },
    { reminder_hour_local: 9, preferred_locale: "en" },
  ]) await responseBody(await f.send(payload), 400);
  for (const extra of [
    { plant_id: owner }, { plant_id: "" }, { owner_id: owner }, { operation_id: "bad" },
    { payload_json: "{" }, { payload_json: {} }, { payload_json: null },
  ]) await responseBody(await f.send(undefined, extra), 400);
  await responseBody(await f.send(undefined, {}, { "x-operation-id": "bad" }), 400);
  await responseBody(await f.send(undefined, {}, { "x-operation-id": later }), 409);
  await responseBody(await f.send(undefined, {}, {}, "/commands?owner_id=" + owner), 400);
  await responseBody(await f.get("/me?owner_id=" + owner), 400);
  assertEquals(f.calls.length, 0);
});

Deno.test("profile RPC failures are bounded and unexpected failures retryable", async () => {
  for (const [code, status] of [
    ["42501", 403], ["23505", 409], ["22023", 400], ["22P02", 400], ["XX000", 503], ["P0002", 503],
  ] as const) await responseBody(await fixture({ code }).send(), status);
  await responseBody(await fixture({ code: "XX000" }).get(), 503);
  for (const options of [{ missing: true }, { transportFailure: true }]) {
    const f = fixture(options);
    await responseBody(await f.get(), 503);
    await responseBody(await f.send(), 503);
  }
});

Deno.test("profile responses reject noncanonical projections and receipts", async () => {
  for (const row of [
    null, [], {}, { preferred_locale: "ru", reminder_hour_local: 9 },
    { preferred_locale: "pl", reminder_hour_local: 24 },
    { preferred_locale: "pl", reminder_hour_local: 0.5 },
    { preferred_locale: "pl", reminder_hour_local: "9" },
    { preferred_locale: "pl", reminder_hour_local: 9, owner_id: owner },
  ]) await responseBody(await fixture({ row }).get(), 503);
  const profile = { preferred_locale: "en", reminder_hour_local: 0 };
  for (const row of [
    null, [], {}, { profile }, { profile, watermark: "infinity" },
    { profile, watermark: "2026-02-30T00:00:00Z" }, { profile, watermark, owner_id: owner },
    { profile: { ...profile, reminder_hour_local: 23 }, watermark },
    { profile: { ...profile, preferred_locale: "ru" }, watermark },
    { profile: { ...profile, owner_id: owner }, watermark },
  ]) await responseBody(await fixture({ row }).send(), 503);
  assertEquals(await responseBody(await fixture({ row: { profile, watermark } }).send()), { profile, watermark });
});
