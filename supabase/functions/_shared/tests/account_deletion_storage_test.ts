import { assertEquals, assertRejects } from "@std/assert";
import { createClient } from "@supabase/supabase-js";
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
