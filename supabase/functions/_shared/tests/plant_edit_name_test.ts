import { assertEquals } from "@std/assert";
import { createProductionPlantsApiHandler } from "../../plants-api/index.ts";

const owner = "53000000-0000-4000-8000-000000000001";
const other = "53000000-0000-4000-8000-000000000002";
const plant = "53000000-0000-4000-8000-000000000010";
const operation = "53000000-0000-4000-8000-000000000013";
const snapshot = "53000000-0000-4000-8000-000000000017";
const host = "https://rename.example.test";
const body = {
  operation_id: operation,
  command_name: "plant.edit",
  plant_id: plant,
  payload_json: '{"personal_name":" Kitchen Monstera "}',
};
const receipt = {
  plant_id: plant,
  revision: 2,
  care_revision: 1,
  condition_snapshot_id: snapshot,
  watermark: "2026-11-13T15:30:00.123456+00:00",
};

function fixture(result = receipt) {
  const calls: unknown[] = [];
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: async (req) => {
      const identity = req.headers.get("fixture-owner");
      return {
        ownerId: identity === "none"
          ? null
          : identity === "other"
          ? other
          : owner,
        accountState: identity === "inactive" ? "deleting" : "active",
        isAnonymous: identity === "guest",
        installationCredential: null,
        locale: "en",
        operationId: null,
      };
    },
  }, {
    env: (name) =>
      ({ SUPABASE_URL: host, SUPABASE_SERVICE_ROLE_KEY: "fixture-key" })[name],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      assertEquals(req.headers.get("authorization"), "Bearer fixture-key");
      assertEquals(
        new URL(req.url).pathname,
        "/rest/v1/rpc/execute_plant_edit_command",
      );
      const data = await req.json();
      calls.push(data);
      if (data.p_owner_id === other) {
        return Response.json({ code: "P0002", message: "PLANT_NOT_FOUND" }, {
          status: 400,
        });
      }
      if (data.p_payload.personal_name === "Conflict") {
        return Response.json(
          { code: "23505", message: "IDEMPOTENCY_CONFLICT" },
          { status: 400 },
        );
      }
      return Response.json(result);
    },
  });
  const run = (
    payload = body,
    identity = "owner",
    suffix = "",
    operationHeader?: string,
  ) =>
    handler(
      new Request(host + "/functions/v1/plants-api/commands" + suffix, {
        method: "POST",
        headers: {
          "fixture-owner": identity,
          ...(operationHeader && { "X-Operation-Id": operationHeader }),
        },
        body: JSON.stringify(payload),
      }),
    );
  return { calls, run };
}

Deno.test("plant.edit forwards the exact name and returns a private immutable receipt", async () => {
  const f = fixture();
  for (let i = 0; i < 2; i++) {
    const response = await f.run();
    assertEquals(response.status, 200);
    assertEquals(response.headers.get("cache-control"), "private, no-store");
    assertEquals(await response.json(), receipt);
  }
  const args = {
    p_owner_id: owner,
    p_operation_id: operation,
    p_plant_id: plant,
    p_payload: { personal_name: " Kitchen Monstera " },
  };
  assertEquals(f.calls, [args, args]);
});

Deno.test("plant.edit rejects guests, foreign owners, conflicts and unsupported changes", async () => {
  const f = fixture();
  assertEquals((await f.run(body, "none")).status, 401);
  assertEquals((await f.run(body, "guest")).status, 403);
  assertEquals((await f.run(body, "inactive")).status, 403);
  assertEquals((await f.run(body, "owner", "?owner_id=bad")).status, 400);
  assertEquals((await f.run(body, "owner", "", other)).status, 409);
  for (
    const payload_json of [
      '{"taxon_id":null}',
      '{"conditions":{}}',
      '{"personal_name":null}',
      '{"personal_name":"Valid","photo_id":null}',
      '{"personal_name":"Valid","room_id":null}',
    ]
  ) {
    assertEquals((await f.run({ ...body, payload_json })).status, 400);
  }
  assertEquals(f.calls, []);
  assertEquals((await f.run(body, "other")).status, 404);
  assertEquals(
    (await f.run({ ...body, payload_json: '{"personal_name":"Conflict"}' }))
      .status,
    409,
  );
});

Deno.test("plant.edit rejects a malformed SQL receipt", async () => {
  for (
    const result of [
      { ...receipt, watermark: "2026-02-31T00:00:00Z" },
      { ...receipt, revision: 0 },
      { ...receipt, care_revision: 0.5 },
      { ...receipt, condition_snapshot_id: "bad" },
    ]
  ) {
    assertEquals((await fixture(result).run()).status, 503);
  }
});

Deno.test("plant.edit forwards partial conditions and rejects mixed or retired fields", async () => {
  const f = fixture();
  const conditions = { light_code: "unknown", drainage_code: "yes" };
  const response = await f.run({
    ...body,
    payload_json: JSON.stringify({ conditions }),
  });
  assertEquals(response.status, 200);
  assertEquals(await response.json(), receipt);
  assertEquals(f.calls, [{
    p_owner_id: owner,
    p_operation_id: operation,
    p_plant_id: plant,
    p_payload: { conditions },
  }]);
  for (
    const payload of [
      { conditions, personal_name: "Mixed" },
      { conditions, taxon_id: snapshot },
      { conditions: { light_source: "camera_estimate" } },
      { conditions: { season_override: "summer" } },
      { conditions: { drainage_code: null } },
    ]
  ) {
    assertEquals(
      (await f.run({ ...body, payload_json: JSON.stringify(payload) })).status,
      400,
    );
  }
  assertEquals(f.calls.length, 1);
});
