import { assertEquals } from "@std/assert";
import { createProductionPlantsApiHandler } from "../../plants-api/index.ts";

const owner = "17000000-0000-4000-8000-000000000001";
const plant = "17000000-0000-4000-8000-000000000011";
const recordOp = "17000000-0000-4000-8000-000000000021";
const undoOp = "17000000-0000-4000-8000-000000000022";
const correctionOp = "17000000-0000-4000-8000-000000000023";
const entry = "17000000-0000-4000-8000-000000000031";
const reversal = "17000000-0000-4000-8000-000000000032";
const payload = {
  action_code: "water",
  occurred_at: "2025-10-11T23:30:00Z",
  timezone: "Europe/Warsaw",
};
const recordBody = {
  operation_id: recordOp,
  plant_id: plant,
  command_name: "care.record",
  payload_json: JSON.stringify(payload),
};
const undoBody = {
  operation_id: undoOp,
  plant_id: plant,
  command_name: "care.undo",
  payload_json: JSON.stringify({ entry_id: entry }),
};
const correctionPayload = {
  entry_id: entry,
  occurred_at: "2025-10-10T23:30:00Z",
  timezone: "Europe/Warsaw",
};
const correctionBody = {
  operation_id: correctionOp,
  plant_id: plant,
  command_name: "care.correct_date",
  payload_json: JSON.stringify(correctionPayload),
};

function fixture(options: { anonymous?: boolean; errorCode?: string } = {}) {
  const calls: Record<string, unknown>[] = [];
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: async () => ({
      ownerId: owner,
      isAnonymous: options.anonymous ?? false,
      accountState: "active",
      locale: "en",
      installationCredential: null,
      operationId: null,
    }),
  }, {
    env: (name) =>
      ({
        SUPABASE_URL: "https://care.example.test",
        SUPABASE_SERVICE_ROLE_KEY: "fixture-service-key",
      })[name],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      assertEquals(
        req.url,
        "https://care.example.test/rest/v1/rpc/execute_manual_care_command",
      );
      assertEquals(
        req.headers.get("authorization"),
        "Bearer fixture-service-key",
      );
      const body = await req.json();
      calls.push(body);
      if (options.errorCode) {
        return Response.json({
          code: options.errorCode,
          message: "private database error",
        }, { status: 400 });
      }
      const undo = body.p_command_name === "care.undo";
      const firstAid = body.p_command_name === "care.first_aid.record";
      return Response.json({
        plant_id: plant,
        entry_id: entry,
        reversal_id: undo ? reversal : null,
        state: undo ? "voided" : "active",
        watermark: "2026-11-11T19:40:00.123456+03:00",
        ...(firstAid && { control_id: null }),
      });
    },
  });
  return {
    calls,
    send: (body: unknown, headers?: HeadersInit) =>
      handler(
        new Request(
          "https://care.example.test/functions/v1/plants-api/commands",
          {
            method: "POST",
            headers,
            body: JSON.stringify(body),
          },
        ),
      ),
  };
}

Deno.test("Manual care record and undo reuse the command wire and canonical SQL receipts", async () => {
  const f = fixture();
  const created = await f.send(recordBody, { "x-operation-id": recordOp });
  assertEquals(created.status, 200);
  const createdReceipt = await created.json();
  assertEquals(createdReceipt, {
    plant_id: plant,
    entry_id: entry,
    reversal_id: null,
    state: "active",
    watermark: "2026-11-11T19:40:00.123456+03:00",
  });
  assertEquals(await (await f.send(recordBody)).json(), createdReceipt);
  const undone = await f.send(undoBody);
  assertEquals(undone.status, 200);
  const undoReceipt = await undone.json();
  assertEquals(undoReceipt, {
    plant_id: plant,
    entry_id: entry,
    reversal_id: reversal,
    state: "voided",
    watermark: "2026-11-11T19:40:00.123456+03:00",
  });
  assertEquals(await (await f.send(undoBody)).json(), undoReceipt);
  assertEquals(f.calls[0], {
    p_owner_id: owner,
    p_plant_id: plant,
    p_operation_id: recordOp,
    p_command_name: "care.record",
    p_payload: payload,
  });
  assertEquals(f.calls[1], f.calls[0]);
  assertEquals(f.calls[2], {
    p_owner_id: owner,
    p_plant_id: plant,
    p_operation_id: undoOp,
    p_command_name: "care.undo",
    p_payload: { entry_id: entry },
  });
  assertEquals(f.calls[3], f.calls[2]);
});

Deno.test("First-aid record sends the canonical job reference and accepts a null control", async () => {
  const f = fixture();
  const job = "17000000-0000-4000-8000-000000000041";
  const payload = { job_id: job, occurred_at: "2025-10-11T23:30:00Z", timezone: "Europe/Warsaw" };
  const body = {
    operation_id: recordOp,
    plant_id: plant,
    command_name: "care.first_aid.record",
    payload_json: JSON.stringify(payload),
  };
  const response = await f.send(body);
  assertEquals(response.status, 200);
  assertEquals((await response.json()).control_id, null);
  assertEquals(f.calls[0], {
    p_owner_id: owner, p_plant_id: plant, p_operation_id: recordOp,
    p_command_name: "care.first_aid.record", p_payload: payload,
  });
  assertEquals((await f.send({ ...body, payload_json: JSON.stringify({ ...payload, job_id: null }) })).status, 400);
  assertEquals((await fixture({ errorCode: "P0002" }).send(body)).status, 404);
});

Deno.test("Manual care rejects injected owner, invalid payload and guest before creating a receipt", async () => {
  const f = fixture();
  assertEquals((await f.send({ ...recordBody, owner_id: owner })).status, 400);
  assertEquals(
    (await f.send({ ...recordBody, payload_json: payload })).status,
    400,
  );
  assertEquals(
    (await f.send({ ...undoBody, payload_json: '{"entry_id":null}' })).status,
    400,
  );
  assertEquals(
    (await f.send(recordBody, { "x-operation-id": undoOp })).status,
    409,
  );
  assertEquals(f.calls, []);
  const guest = fixture({ anonymous: true });
  assertEquals((await guest.send(recordBody)).status, 403);
  assertEquals(guest.calls, []);
});

Deno.test("Manual care correction uses the original entry and preserves its replay envelope", async () => {
  const f = fixture();
  const response = await f.send(correctionBody, { "x-operation-id": correctionOp });
  assertEquals(response.status, 200);
  const receipt = await response.json();
  assertEquals(receipt, {
    plant_id: plant,
    entry_id: entry,
    reversal_id: null,
    state: "active",
    watermark: "2026-11-11T19:40:00.123456+03:00",
  });
  assertEquals(await (await f.send(correctionBody)).json(), receipt);
  assertEquals(f.calls[0], {
    p_owner_id: owner,
    p_plant_id: plant,
    p_operation_id: correctionOp,
    p_command_name: "care.correct_date",
    p_payload: correctionPayload,
  });
  assertEquals(f.calls[1], f.calls[0]);

  const malformed = await f.send({
    ...correctionBody,
    payload_json: JSON.stringify({ ...correctionPayload, entry_id: null }),
  });
  assertEquals(malformed.status, 400);
  assertEquals(f.calls.length, 2);
  assertEquals((await fixture({ anonymous: true }).send(correctionBody)).status, 403);
  assertEquals((await fixture({ errorCode: "23505" }).send(correctionBody)).status, 409);
});

Deno.test("Manual care maps SQL errors without exposing the original message", async () => {
  for (
    const [sql, status, code] of [
      ["22008", 400, "VALIDATION_ERROR"],
      ["42501", 403, "FORBIDDEN"],
      ["P0002", 404, "NOT_FOUND"],
      ["23505", 409, "CONFLICT"],
      ["XX000", 503, "INTERNAL_ERROR"],
    ] as const
  ) {
    const response = await fixture({ errorCode: sql }).send(recordBody);
    assertEquals(response.status, status);
    const body = await response.json();
    assertEquals(body.error.code, code);
    assertEquals(body.error.message.includes("private database error"), false);
  }
});
