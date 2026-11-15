import { assertEquals } from "@std/assert";
import { createProductionPlantsApiHandler } from "../../plants-api/index.ts";

const host = "https://soil.example.test";
const owner = "19510000-0000-4000-8000-000000000001";
const plant = "19510000-0000-4000-8000-000000000011";
const operation = "19510000-0000-4000-8000-000000000020";
const rule = "19510000-0000-4000-8000-000000000030";
const payload = {
  rule_id: rule, expected_care_revision: 2, due_local_date: "2026-11-15",
  occurred_at: "2026-11-15T09:10:00.123456Z", timezone: "Europe/Warsaw",
};
const receipt = {
  plant_id: plant, rule_id: rule, care_revision: 2,
  occurrence_key: rule + ":2026-11-15", due_local_date: "2026-11-15",
  task_id: operation, entry_id: owner, state: "completed",
  watermark: "2026-11-15T09:10:01.123456Z",
};

function fixture(row: unknown = receipt, code?: string) {
  const calls: unknown[] = [];
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: async (req) => ({
      ownerId: req.headers.has("signed-out") ? null : owner,
      accountState: req.headers.has("disabled") ? "deleted" : "active",
      isAnonymous: req.headers.has("guest"), locale: "en",
      installationCredential: null, operationId: null,
    }),
  }, {
    env: (name) => ({ SUPABASE_URL: host, SUPABASE_SERVICE_ROLE_KEY: "fixture-key" })[name],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      assertEquals(new URL(req.url).pathname, "/rest/v1/rpc/execute_routine_soil_check");
      assertEquals(req.headers.get("authorization"), "Bearer fixture-key");
      calls.push(await req.json());
      return code
        ? Response.json({ code, message: "private detail" }, { status: 400 })
        : Response.json(row);
    },
  });
  return {
    calls,
    send: (value: unknown = payload, extra = {}, headers = {}, suffix = "") => handler(
      new Request(host + "/commands" + suffix, {
        method: "POST", headers,
        body: JSON.stringify({
          command_name: "care.check_soil.complete", operation_id: operation,
          plant_id: plant, payload_json: JSON.stringify(value), ...extra,
        }),
      }),
    ),
  };
}

Deno.test("soil command routes owner values and returns the exact synthetic replay receipt", async () => {
  const f = fixture();
  for (let i = 0; i < 2; i++) {
    const response = await f.send();
    assertEquals(response.status, 200);
    assertEquals(response.headers.get("cache-control"), "private, no-store");
    assertEquals(await response.json(), receipt);
  }
  assertEquals(f.calls, Array(2).fill({
    p_owner_id: owner, p_operation_id: operation, p_plant_id: plant,
    p_rule_id: rule, p_expected_care_revision: 2, p_due_local_date: payload.due_local_date,
    p_occurred_at: payload.occurred_at, p_timezone: payload.timezone,
  }));
});

Deno.test("soil command rejects malformed envelopes and payloads before RPC", async () => {
  const f = fixture();
  for (const change of [
    { rule_id: "bad" }, { expected_care_revision: 0 }, { expected_care_revision: 2147483648 },
    { expected_care_revision: 1.5 }, { due_local_date: "2026-02-30" },
    { due_local_date: "2026-1-15" }, { occurred_at: "2026-11-15" },
    { occurred_at: "infinity" }, { timezone: "Invalid/Zone" }, { timezone: "+03:00" },
    { owner_id: owner }, { rule_id: null },
  ]) assertEquals((await f.send({ ...payload, ...change })).status, 400);
  assertEquals((await f.send({})).status, 400);
  assertEquals((await f.send(payload, { owner_id: owner })).status, 400);
  assertEquals((await f.send(payload, { payload_json: "{" })).status, 400);
  assertEquals((await f.send(payload, {}, {}, "?x=1")).status, 400);
  assertEquals((await f.send(payload, {}, { "x-operation-id": owner })).status, 409);
  assertEquals(f.calls.length, 0);
});

Deno.test("soil command blocks unauthorized and disabled callers before RPC", async () => {
  const f = fixture();
  for (const [header, status] of [["guest", 403], ["signed-out", 401], ["disabled", 403]] as const) {
    assertEquals((await f.send(payload, {}, { [header]: "yes" })).status, status);
  }
  assertEquals(f.calls.length, 0);
});

Deno.test("soil command bounds SQL errors and rejects inconsistent receipts", async () => {
  for (const [code, status] of [
    ["55000", 409], ["23505", 409], ["P0002", 404], ["42501", 403],
    ["22023", 400], ["XX000", 503],
  ] as const) {
    const response = await fixture(receipt, code).send();
    assertEquals(response.status, status);
    assertEquals((await response.text()).includes("private detail"), false);
  }
  for (const change of [
    { plant_id: owner }, { rule_id: owner }, { care_revision: 3 },
    { due_local_date: "2026-11-16" }, { occurrence_key: "" },
    { occurrence_key: "wrong" }, { task_id: "bad" }, { entry_id: null },
    { state: "pending" }, { watermark: "2026-02-30T00:00:00Z" },
  ]) assertEquals((await fixture({ ...receipt, ...change }).send()).status, 503);
});
