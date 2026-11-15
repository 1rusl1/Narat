import { assertEquals, assertRejects } from "@std/assert";
import { createClient } from "@supabase/supabase-js";
import { createProductionPlantsApiHandler } from "../../plants-api/index.ts";
import { runAccountStoragePurge } from "../../maintenance/account-deletion-storage.ts";

const owner = "53000000-0000-4000-8000-000000000001";
const photo = (n: number) =>
  `53000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const counts = {
  blocked: 0,
  waiting: 0,
  orphan_objects: 0,
  guest_draft_sources: 0,
  guest_identification_sources: 0,
  incoming_claims: 0,
};
function plan(ids: string[] = [], extra: Record<string, unknown> = {}) {
  return {
    owner_id: owner, photo_ids: ids, ...counts,
    storage_ready: ids.length === 0, ...extra,
  };
}
const read = "/rest/v1/rpc/read_account_deletion_storage_work_plan";
const remove = "/storage/v1/object/analysis-inputs";
const raw = "private-owner credentials raw storage object";
function fixture(
  plans: unknown[],
  options: { removeFailure?: boolean; throwRemove?: boolean; failRead?: number } = {},
) {
  const calls: string[] = [];
  const keys: string[][] = [];
  let reads = 0;
  const client = createClient("https://account-storage.example.test", "fixture-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: async (input, init) => {
        const req = new Request(input, init);
        const path = new URL(req.url).pathname;
        calls.push(path);
        if (path === read) {
          assertEquals(req.method, "POST");
          assertEquals(await req.json(), { p_owner_id: owner });
          if (++reads === options.failRead) {
            return Response.json({ message: raw }, { status: 503 });
          }
          assertEquals(reads <= plans.length, true);
          return Response.json(plans[reads - 1]);
        }
        assertEquals(path, remove);
        assertEquals(req.method, "DELETE");
        const body = await req.json();
        assertEquals(Object.keys(body), ["prefixes"]);
        keys.push(body.prefixes);
        if (options.throwRemove) throw new Error(raw);
        return options.removeFailure
          ? Response.json({ message: raw }, { status: 503 })
          : Response.json([]);
      },
    },
  });
  return { calls, keys, run: (id = owner) => runAccountStoragePurge(client, id) };
}

Deno.test("account storage absent plan is no work; ready requires an independent read", async () => {
  const absent = fixture([null]);
  assertEquals(await absent.run(), { state: "not_found" });
  assertEquals(absent.calls, [read]);
  const ready = fixture([plan(), plan()]);
  assertEquals(await ready.run(), { state: "ready", ...counts });
  assertEquals(ready.calls, [read, read]);
});

Deno.test("account storage removes one bounded exact batch and continues from the start", async () => {
  const ids = Array.from({ length: 20 }, (_, i) => photo(i + 10));
  const next = [photo(30)];
  const f = fixture([plan(ids), plan(next), plan(next), plan(), plan(), plan()]);
  assertEquals(await f.run(), { state: "pending", ...counts });
  assertEquals(f.calls, [read, remove, read]);
  assertEquals(f.keys, [ids.map((id) => `${owner}/${id}`)]);
  assertEquals(await f.run(), { state: "ready", ...counts });
  assertEquals(await f.run(), { state: "ready", ...counts });
  assertEquals(f.calls, [read, remove, read, read, remove, read, read, read]);
  assertEquals(f.keys, [
    ids.map((id) => `${owner}/${id}`), [`${owner}/${photo(30)}`],
  ]);
});

Deno.test("account storage rejects malformed plans before any remove", async () => {
  const missing = plan();
  const { waiting: _waiting, ...withoutWaiting } = missing;
  const bad: unknown[] = [
    [], "invalid", {}, withoutWaiting,
    plan([], { owner_id: photo(99) }),
    plan([], { next_cursor: null }),
    plan([], { storage_path: "other/path" }),
    plan([], { photo_ids: null }),
    plan(Array.from({ length: 21 }, (_, i) => photo(i + 10))),
    plan([photo(10), photo(10)]),
    plan([photo(11), photo(10)]),
    plan(["../outside"]),
    plan(["AAAAAAAA-0000-4000-8000-000000000001"]),
    plan([photo(10)], { storage_ready: true }),
    plan([], { storage_ready: "true" }),
  ];
  for (const key of Object.keys(counts)) {
    for (const value of [-1, 0.5, Number.MAX_SAFE_INTEGER + 1, "0", null]) {
      bad.push(plan([], { [key]: value, storage_ready: false }));
    }
    bad.push(plan([], { [key]: 1 }));
  }
  for (const value of bad) {
    const f = fixture([value]);
    await assertRejects(f.run, Error, "Invalid account storage plan.");
    assertEquals(f.calls, [read]);
  }
  for (const id of ["bad", owner + "/", owner.replace("53000000", "ABCDEF00")]) {
    const f = fixture([]);
    await assertRejects(() => f.run(id), Error, "Invalid account storage owner ID.");
    assertEquals(f.calls, []);
  }
});

Deno.test("account storage failure is sanitized and retryable without verification", async () => {
  for (const options of [{ removeFailure: true }, { throwRemove: true }]) {
    const f = fixture([plan([photo(10)])], options);
    const error = await assertRejects(f.run, Error, "private storage; retry.");
    assertEquals(error.message.includes(raw), false);
    assertEquals(f.calls, [read, remove]);
  }
  for (const failRead of [1, 2]) {
    const f = fixture([plan([photo(10)]), plan()], { failRead });
    const error = await assertRejects(f.run, Error, "storage plan; retry.");
    assertEquals(error.message.includes(raw), false);
    assertEquals(f.calls, failRead === 1 ? [read] : [read, remove, read]);
  }
});

Deno.test("account storage keeps surviving objects and every namespace hold pending", async () => {
  const survivors = [
    plan([photo(10)]),
    plan([], { storage_ready: false }),
    ...Object.keys(counts).map((key) =>
      plan([], { [key]: 1, storage_ready: false })
    ),
  ];
  for (const fresh of survivors) {
    const f = fixture([plan([photo(10)]), fresh]);
    const result = await f.run();
    assertEquals(result.state, "pending");
    assertEquals(result, {
      state: "pending",
      ...counts,
      ...Object.fromEntries(Object.keys(counts).map((key) => [key, fresh[key as keyof typeof fresh]])),
    });
    assertEquals(f.calls, [read, remove, read]);
  }
  const changed = fixture([plan(), plan([photo(10)])]);
  assertEquals((await changed.run()).state, "pending");
  assertEquals(changed.calls, [read, read]);
});

Deno.test("account storage disappearing or malformed fresh plan is an error after remove", async () => {
  for (const fresh of [null, {}, plan([], { owner_id: photo(99) }), plan([photo(10)], { storage_ready: true })]) {
    const f = fixture([plan([photo(10)]), fresh]);
    await assertRejects(f.run, Error, "Invalid account storage plan.");
    assertEquals(f.calls, [read, remove, read]);
  }
});

// Production composition and the real helper use only a mocked transport.
function routeFixture(plans: unknown[], failAt = 0) {
  const calls: string[] = [];
  let reads = 0;
  let publicAuth = 0;
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: () => {
      publicAuth++;
      throw new Error("Unexpected public Auth.");
    },
  }, {
    env: (name) => ({
      SUPABASE_URL: "https://account-storage.example.test",
      SUPABASE_SERVICE_ROLE_KEY: "legacy-service",
      SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_fixture" }),
    } as Record<string, string>)[name],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      const path = new URL(req.url).pathname;
      calls.push(path);
      if (calls.length === failAt) return Response.json({ message: raw }, { status: 503 });
      if (path === read) {
        assertEquals(await req.json(), { p_owner_id: owner });
        assertEquals(reads < plans.length, true);
        return Response.json(plans[reads++]);
      }
      assertEquals(path, remove);
      assertEquals(req.method, "DELETE");
      assertEquals(await req.json(), { prefixes: [owner + "/" + photo(10)] });
      return Response.json([]);
    },
  });
  return {
    calls,
    publicAuth: () => publicAuth,
    request: async (
      id = owner,
      headers: Record<string, string> = { authorization: "Bearer legacy-service" },
      body?: string,
      query = "",
      method = "POST",
    ) => {
      const response = await handler(new Request(
        "https://api.example.test/functions/v1/plants-api/internal/account-deletions/" + id + "/storage" + query,
        { method, headers, body },
      ));
      assertEquals(response.headers.get("cache-control"), "private, no-store");
      return response;
    },
  };
}

Deno.test("account route authenticates before validation, public Auth and any work", async () => {
  const f = routeFixture([]);
  const invalidHeaders: Record<string, string>[] = [
    {}, { authorization: "Bearer owner-token" }, { apikey: "anon-key" },
    { authorization: "Bearer sb_secret_fixture" }, { apikey: "legacy-service" },
  ];
  for (const headers of invalidHeaders) {
    assertEquals((await f.request("invalid", headers, '{"path":"other"}', "?path=other")).status, 401);
  }
  for (const id of ["invalid", owner.replace("53000000", "ABCDEF00"), owner + "%2Fother"]) {
    assertEquals((await f.request(id)).status, 400);
  }
  for (const body of ['{"path":"other"}', "{}", "null", " "]) {
    assertEquals((await f.request(owner, undefined, body)).status, 400);
  }
  for (const query of ["?path=other", "?owner_id=other"]) {
    assertEquals((await f.request(owner, undefined, undefined, query)).status, 400);
  }
  assertEquals((await f.request(owner, undefined, undefined, "", "GET")).status, 404);
  assertEquals((await f.request(owner, {}, undefined, "", "OPTIONS")).status, 200);
  assertEquals(f.calls, []);
  assertEquals(f.publicAuth(), 0);
});

Deno.test("account route accepts established service credentials and returns exact helper results", async () => {
  const credentials: Record<string, string>[] = [
    { authorization: "Bearer legacy-service" },
    { apikey: "sb_secret_fixture", authorization: "Bearer owner-token" },
  ];
  for (const headers of credentials) {
    const f = routeFixture([plan([photo(10)]), plan([], { blocked: 1, storage_ready: false }), plan(), plan()]);
    const pending = await f.request(owner, headers);
    assertEquals(pending.status, 200);
    assertEquals(await pending.json(), { state: "pending", ...counts, blocked: 1 });
    const ready = await f.request(owner, headers, "");
    assertEquals(ready.status, 200);
    assertEquals(await ready.json(), { state: "ready", ...counts });
    assertEquals(f.calls, [read, remove, read, read, read]);
    assertEquals(f.publicAuth(), 0);
  }
  const absent = routeFixture([null]);
  const response = await absent.request();
  assertEquals(response.status, 404);
  assertEquals((await response.text()).includes(owner), false);
  assertEquals(absent.calls, [read]);
});

Deno.test("account route sanitizes failures and retries from a fresh plan", async () => {
  for (const failAt of [1, 2, 3]) {
    const f = routeFixture([
      ...(failAt === 1 ? [] : [plan([photo(10)])]),
      plan([photo(10)]), plan(),
    ], failAt);
    const failed = await f.request();
    assertEquals(failed.status, 503);
    const error = await failed.json();
    assertEquals(error.error.retryable, true);
    assertEquals(JSON.stringify(error).includes(raw), false);
    assertEquals(JSON.stringify(error).includes(owner), false);
    const retry = await f.request();
    assertEquals(retry.status, 200);
    assertEquals(await retry.json(), { state: "ready", ...counts });
    assertEquals(f.calls.slice(failAt), [read, remove, read]);
  }
});

Deno.test("account route preserves established internal maintenance dispatch", async () => {
  const calls: unknown[] = [];
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: () => { throw new Error("Unexpected public Auth."); },
    handlePlantPurge: (_req, id, phase) => {
      calls.push([id, phase]);
      return Promise.resolve(Response.json({ state: phase }));
    },
    handleGuestPhotoMaintenance: () => {
      calls.push("guest");
      return Promise.resolve(Response.json({ state: "guest" }));
    },
  }, { env: () => undefined });
  for (const path of [
    "plant-deletions/" + owner + "/storage", "plant-deletions/" + owner + "/data",
    "plant-deletions/sweep", "guest-drafts/cleanup",
  ]) {
    const response = await handler(new Request("https://api.example.test/internal/" + path, { method: "POST" }));
    assertEquals(response.status, 200);
    assertEquals(response.headers.get("cache-control"), "private, no-store");
  }
  assertEquals(calls, [[owner, "storage"], [owner, "data"], [null, "sweep"], "guest"]);
});
