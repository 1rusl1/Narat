import { assertEquals } from "@std/assert";
import { createProductionPlantsApiHandler } from "../../plants-api/index.ts";

const owner = "53000000-0000-4000-8000-000000000001";
const photo = "53000000-0000-4000-8000-000000000011";
const job = "53000000-0000-4000-8000-000000000015";
const host = "https://purge.example.test";
const service = "fixture-service-role";
const secret = "sb_secret_fixture";

function fixture(dataResult?: unknown) {
  const calls: string[] = [];
  let present = true;
  let fail = false;
  let invisibleJob = false;
  let falseSuccess = false;
  let malformed = false;
  const handler = createProductionPlantsApiHandler({}, {
    env: (name) =>
      ({
        SUPABASE_URL: host,
        SUPABASE_SERVICE_ROLE_KEY: service,
        SUPABASE_SECRET_KEYS: JSON.stringify({ default: secret }),
      })[name],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      assertEquals(req.headers.get("authorization"), `Bearer ${service}`);
      const path = new URL(req.url).pathname;
      calls.push(path);
      if (path === "/storage/v1/object/analysis-inputs") {
        assertEquals(req.method, "DELETE");
        assertEquals(await req.json(), { prefixes: [`${owner}/${photo}`] });
        if (fail) {
          return Response.json({ message: "simulated Storage failure" }, {
            status: 503,
          });
        }
        if (!falseSuccess) present = false;
        return Response.json([]);
      }
      assertEquals(await req.json(), { p_job_id: job });
      if (path === "/rest/v1/rpc/purge_plant_deletion_data") {
        return Response.json(dataResult);
      }
      if (path === "/rest/v1/rpc/read_plant_deletion_storage") {
        if (invisibleJob) return Response.json(null);
        return Response.json({
          owner_id: owner,
          photo_ids: malformed ? ["../shared.jpg"] : present ? [photo] : [],
          blocked: 0,
          waiting: 0,
        });
      }
      assertEquals(path, "/rest/v1/rpc/finish_plant_deletion_storage");
      return Response.json(present ? "purge_storage" : "purge_data");
    },
  });
  const run = (headers: HeadersInit, id = job, phase = "storage") =>
    handler(
      new Request(
        `${host}/functions/v1/plants-api/internal/plant-deletions/${id}/${phase}`,
        {
          method: "POST",
          headers,
        },
      ),
    );
  return {
    calls,
    run,
    failRemoval: () => {
      fail = true;
    },
    restoreRemoval: () => {
      fail = false;
    },
    pretendRemoved: () => {
      falseSuccess = true;
    },
    hideJob: () => {
      invisibleJob = true;
    },
    breakPlan: () => {
      malformed = true;
    },
  };
}

const auth = { authorization: `Bearer ${service}` };
const read = "/rest/v1/rpc/read_plant_deletion_storage";
const remove = "/storage/v1/object/analysis-inputs";
const finish = "/rest/v1/rpc/finish_plant_deletion_storage";

Deno.test("storage purge requires a service credential before touching SQL or Storage", async () => {
  const f = fixture();
  const response = await f.run({ authorization: "Bearer owner-session" });
  assertEquals(response.status, 401);
  assertEquals(response.headers.get("cache-control"), "private, no-store");
  assertEquals((await f.run(auth, "not-a-job")).status, 400);
  assertEquals(f.calls, []);
  f.hideJob();
  assertEquals((await f.run({ apikey: secret })).status, 404);
  assertEquals(f.calls, [read]);
});

Deno.test("storage purge retries a Storage failure and exact replay avoids a second removal", async () => {
  const f = fixture();
  f.failRemoval();
  assertEquals((await f.run(auth)).status, 503);
  assertEquals(f.calls, [read, remove]);
  f.restoreRemoval();
  const first = await f.run(auth);
  assertEquals(first.status, 200);
  assertEquals(await first.json(), {
    state: "purge_data",
    blocked: 0,
    waiting: 0,
  });
  assertEquals(await (await f.run(auth)).json(), {
    state: "purge_data",
    blocked: 0,
    waiting: 0,
  });
  assertEquals(f.calls, [read, remove, read, remove, finish, read, finish]);
});

Deno.test("storage purge trusts SQL verification after remove and rejects an invalid inventory", async () => {
  const f = fixture();
  f.pretendRemoved();
  assertEquals(await (await f.run(auth)).json(), {
    state: "purge_storage",
    blocked: 0,
    waiting: 0,
  });
  assertEquals(f.calls, [read, remove, finish]);
  f.breakPlan();
  assertEquals((await f.run(auth)).status, 503);
  assertEquals(f.calls, [read, remove, finish, read]);
});

Deno.test("data cleanup only invokes its service RPC and validates its result", async () => {
  const phase = "data";
  const rpc = "/rest/v1/rpc/purge_plant_deletion_data";
  const f = fixture({ state: "cleared", cleared: 2 });
  const unauthorized = await f.run(
    { authorization: "Bearer owner-session" },
    job,
    phase,
  );
  assertEquals(unauthorized.status, 401);
  assertEquals(f.calls, []);
  const response = await f.run({ apikey: secret }, job, phase);
  assertEquals(response.status, 200);
  assertEquals(response.headers.get("cache-control"), "private, no-store");
  assertEquals(await response.json(), { state: "cleared", cleared: 2 });
  assertEquals(f.calls, [rpc]);

  const pending = fixture({ state: "pending", cleared: 0 });
  assertEquals(await (await pending.run(auth, job, phase)).json(), {
    state: "pending",
    cleared: 0,
  });
  assertEquals((await fixture(null).run(auth, job, phase)).status, 404);
  assertEquals(
    (await fixture({ state: "pending", cleared: 2 }).run(auth, job, phase))
      .status,
    503,
  );
});
