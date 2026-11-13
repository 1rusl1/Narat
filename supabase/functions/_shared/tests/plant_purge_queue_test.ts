import { assertEquals } from "@std/assert";
import { createProductionPlantsApiHandler } from "../../plants-api/index.ts";

const owner = "53000000-0000-4000-8000-000000000001";
const photo = "53000000-0000-4000-8000-000000000002";
const host = "https://sweep.example.test";
const service = "fixture-service-role";
const ids = Array.from(
  { length: 11 },
  (_, index) =>
    `53000000-0000-4000-8000-${String(index + 10).padStart(12, "0")}`,
);

Deno.test("plant deletion queue sweep paginates, retries late objects and isolates failed jobs", async () => {
  const calls: string[] = [];
  const cleared: string[] = [];
  let lateObject = true;
  const handler = createProductionPlantsApiHandler({}, {
    env: (name) =>
      ({ SUPABASE_URL: host, SUPABASE_SERVICE_ROLE_KEY: service })[name],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      const name = new URL(req.url).pathname.split("/").at(-1);
      calls.push(name!);
      const args = await req.json();
      switch (name) {
        case "list_plant_deletion_jobs":
          return Response.json(
            args.p_after === null ? ids.slice(0, 10) : ids.slice(10),
          );
        case "read_plant_deletion_storage":
          if (args.p_job_id === ids[0]) {
            return Response.json({ message: "failed job" }, { status: 503 });
          }
          return Response.json({
            owner_id: owner,
            photo_ids: args.p_job_id === ids[10] && lateObject ? [photo] : [],
            blocked: 0,
            waiting: 0,
          });
        case "analysis-inputs":
          assertEquals(req.method, "DELETE");
          assertEquals(args, { prefixes: [`${owner}/${photo}`] });
          lateObject = false;
          return Response.json([]);
        case "finish_plant_deletion_storage":
          return Response.json(
            args.p_job_id === ids[1] ? "purge_storage" : "purge_data",
          );
        case "purge_plant_deletion_data":
          cleared.push(args.p_job_id);
          return Response.json({ state: "cleared", cleared: 0 });
        default:
          throw new Error("Unexpected route.");
      }
    },
  });
  const sweep = (query = "", authorization = `Bearer ${service}`) =>
    handler(
      new Request(
        `${host}/functions/v1/plants-api/internal/plant-deletions/sweep${query}`,
        {
          method: "POST",
          headers: { authorization },
        },
      ),
    );
  assertEquals((await sweep("", "Bearer owner-session")).status, 401);
  assertEquals((await sweep("?after=invalid")).status, 400);
  assertEquals((await sweep(`?after=${ids[1]}&after=${ids[2]}`)).status, 400);
  assertEquals(calls, []);
  const first = await sweep();
  assertEquals(first.headers.get("cache-control"), "private, no-store");
  assertEquals(await first.json(), {
    processed: 10,
    data_cleared: 8,
    pending: 1,
    failed: 1,
    next_after: ids[9],
  });
  assertEquals(cleared, ids.slice(2, 10));
  assertEquals(await (await sweep(`?after=${ids[9]}`)).json(), {
    processed: 1,
    data_cleared: 1,
    pending: 0,
    failed: 0,
    next_after: null,
  });
  assertEquals(lateObject, false);
  assertEquals(cleared, ids.slice(2));
});
