import { assertEquals } from "@std/assert";
import { createProductionPlantsApiHandler } from "../../plants-api/index.ts";

const host = "https://basic-care.example.test";
const owner = "17300000-0000-4000-8000-000000000001";
const plant = "17300000-0000-4000-8000-000000000011";
const operation = "17300000-0000-4000-8000-000000000020";
const enabledAt = "2026-11-15T09:10:00.123456Z";

Deno.test("basic_care.enable validates the envelope and returns only the owner's requested membership", async () => {
  let rpcCalls = 0;
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: async (request) => ({
      ownerId: owner,
      accountState: "active",
      isAnonymous: request.headers.get("fixture-guest") === "yes",
      locale: "en",
      installationCredential: null,
      operationId: null,
    }),
  }, {
    env: (name) =>
      ({ SUPABASE_URL: host, SUPABASE_SERVICE_ROLE_KEY: "fixture-key" })[name],
    fetch: async (input, init) => {
      const request = new Request(input, init);
      assertEquals(
        new URL(request.url).pathname,
        "/rest/v1/rpc/execute_basic_care_command",
      );
      assertEquals(await request.json(), {
        p_owner_id: owner,
        p_operation_id: operation,
        p_command_type: "basic_care.enable",
        p_payload: { plant_id: plant },
      });
      rpcCalls += 1;
      return Response.json({
        command_type: "basic_care.enable",
        status: "committed",
        state: {
          memberships: [
            { plant_id: owner, enabled: true, enabled_at: enabledAt },
            { plant_id: plant, enabled: true, enabled_at: enabledAt },
          ],
        },
      });
    },
  });

  function send(payload = "{}", guest = false) {
    return handler(
      new Request(host + "/commands", {
        method: "POST",
        headers: {
          "X-Operation-Id": operation,
          "fixture-guest": guest ? "yes" : "no",
        },
        body: JSON.stringify({
          operation_id: operation,
          plant_id: plant,
          command_name: "basic_care.enable",
          payload_json: payload,
        }),
      }),
    );
  }
  assertEquals((await send('{"plant_id":"wrong"}')).status, 400);
  assertEquals((await send("{}", true)).status, 403);
  assertEquals(rpcCalls, 0);
  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await send();
    assertEquals(response.status, 200);
    assertEquals(response.headers.get("cache-control"), "private, no-store");
    assertEquals(await response.json(), {
      plant_id: plant,
      enabled: true,
      enabled_at: enabledAt,
    });
  }
  assertEquals(rpcCalls, 2);
});
