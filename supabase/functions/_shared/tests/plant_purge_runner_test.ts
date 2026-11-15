import { assertEquals, assertRejects } from "@std/assert";
import { sweepPlantDeletionQueue } from "../../../../tools/automation/sweep_plant_deletions.ts";

const origin = new URL("https://fixture.example.test");
const key = "sb_secret_fixture";
const cursor = "53000000-0000-4000-8000-000000000010";
const first = {
  processed: 10,
  data_cleared: 8,
  pending: 1,
  failed: 1,
  next_after: cursor,
};
const last = {
  processed: 2,
  data_cleared: 1,
  pending: 1,
  failed: 0,
  next_after: null,
};

Deno.test("scheduled sweep follows the exclusive cursor and reports aggregate outcomes", async () => {
  const cursors: Array<string | null> = [];
  const result = await sweepPlantDeletionQueue(
    origin,
    key,
    async (url, init) => {
      const endpoint = new URL(String(url));
      assertEquals(endpoint.origin, origin.origin);
      assertEquals(
        endpoint.pathname,
        "/functions/v1/plants-api/internal/plant-deletions/sweep",
      );
      assertEquals(init?.method, "POST");
      assertEquals(init?.redirect, "error");
      assertEquals(new Headers(init?.headers).get("apikey"), key);
      cursors.push(endpoint.searchParams.get("after"));
      return Response.json(cursors.length === 1 ? first : last);
    },
  );
  assertEquals(cursors, [null, cursor]);
  assertEquals(result, {
    processed: 12,
    data_cleared: 9,
    pending: 2,
    failed: 1,
  });
});

Deno.test("scheduled sweep rejects invalid origins and repeated pagination without forwarding a key", async () => {
  let calls = 0;
  const fixed: typeof fetch = async () => {
    calls++;
    return Response.json(first);
  };
  await assertRejects(() =>
    sweepPlantDeletionQueue(new URL("http://fixture.example.test"), key, fixed)
  );
  await assertRejects(() =>
    sweepPlantDeletionQueue(
      new URL("https://fixture.example.test/other"),
      key,
      fixed,
    )
  );
  assertEquals(calls, 0);
  await assertRejects(
    () => sweepPlantDeletionQueue(origin, key, fixed),
    Error,
    "cursor did not advance",
  );
  assertEquals(calls, 2);
  await assertRejects(
    () =>
      sweepPlantDeletionQueue(
        origin,
        key,
        async () => Response.json({ ...last, failed: 3 }),
      ),
    Error,
    "Invalid plant deletion sweep response.",
  );
});
