import { assertEquals } from "@std/assert";
import { createProductionPlantsApiHandler } from "../../plants-api/index.ts";

const owner = "53000000-0000-4000-8000-000000000001";
const other = "53000000-0000-4000-8000-000000000002";
const plant = "53000000-0000-4000-8000-000000000010";
const photo = "53000000-0000-4000-8000-000000000011";
const job = "53000000-0000-4000-8000-000000000012";
const operation = "53000000-0000-4000-8000-000000000013";
const observation = "53000000-0000-4000-8000-000000000014";
const deletion = "53000000-0000-4000-8000-000000000015";
const host = "https://delete.example.test";
const receipt = {
  plant_id: plant,
  deletion_job_id: deletion,
  state: "deleting",
  watermark: "2026-11-13T15:30:00.123456+00:00",
};
const envelope = {
  operation_id: operation,
  command_name: "plant.delete",
  plant_id: plant,
  payload_json: "{}",
};

function fixture(receiptOverride?: unknown) {
  let deleted = false;
  let storageReads = 0;
  const calls: string[] = [];
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: async (req) => {
      const identity = req.headers.get("x-fixture-user");
      return {
        ownerId: identity === "none"
          ? null
          : identity === "foreign"
          ? other
          : owner,
        accountState: identity === "inactive" ? "deleting" : "active",
        isAnonymous: identity === "guest",
        locale: "en",
        operationId: null,
        installationCredential: null,
      };
    },
  }, {
    env: (name) =>
      ({ SUPABASE_URL: host, SUPABASE_SERVICE_ROLE_KEY: "fixture-key" })[name],
    diagnosisWorker: {
      ready: () => true,
      run: async () => {
        throw new Error("unexpected dispatch");
      },
    },
    scheduleDiagnosis: () => {
      calls.push("dispatch");
    },
    fetch: async (input, init) => {
      const req = new Request(input, init);
      assertEquals(req.headers.get("authorization"), "Bearer fixture-key");
      const path = new URL(req.url).pathname;
      if (path.startsWith("/storage/")) {
        storageReads++;
        throw new Error("revoked read must stop before Storage");
      }
      const name = path.split("/").at(-1)!;
      calls.push(name);
      const data = await req.json();
      const fail = (code: string, message: string) =>
        Response.json({ code, message }, { status: 400 });
      switch (name) {
        case "execute_plant_delete_command":
          assertEquals(data, {
            p_owner_id: data.p_owner_id,
            p_plant_id: plant,
            p_operation_id: data.p_operation_id,
            p_payload: {},
          });
          if (data.p_owner_id !== owner) {
            return fail("P0002", "PLANT_NOT_FOUND");
          }
          if (deleted && data.p_operation_id !== operation) {
            return fail("23505", "PLANT_ALREADY_DELETED");
          }
          deleted = true;
          return Response.json(
            receiptOverride === undefined ? receipt : receiptOverride,
          );
        case "read_owned_plant_photo":
          assertEquals(data, { p_owner_id: owner, p_plant_id: plant });
          break;
        case "read_owned_first_aid_observation_photo":
          assertEquals(data, {
            p_owner_id: owner,
            p_observation_id: observation,
          });
          break;
        case "read_plant_care_profile":
          assertEquals(data, { p_owner_id: owner, p_plant_id: plant });
          break;
        case "read_diagnosis_job":
          assertEquals(data, { p_owner_id: owner, p_job_id: job });
          break;
        case "create_plant_diagnosis_job":
          assertEquals(data.p_target_plant_id, plant);
          assertEquals(data.p_photo_asset_id, photo);
          assertEquals(deleted, true);
          return fail("P0002", "PLANT_NOT_FOUND");
        default:
          throw new Error("unexpected RPC " + name);
      }
      assertEquals(deleted, true);
      return Response.json(null);
    },
  });
  const request = (
    path: string,
    payload?: unknown,
    identity = "owner",
    headers?: HeadersInit,
  ) => {
    const requestHeaders = new Headers(headers);
    requestHeaders.set("x-fixture-user", identity);
    return handler(
      new Request(host + "/functions/v1/plants-api" + path, {
        method: payload === undefined ? "GET" : "POST",
        headers: requestHeaders,
        body: payload === undefined ? undefined : JSON.stringify(payload),
      }),
    );
  };
  return { request, calls, storageReads: () => storageReads };
}

Deno.test("plant.delete validates auth, command and exact receipt before advancing sync", async () => {
  const f = fixture();
  const post = (
    body: unknown = envelope,
    identity?: string,
    headers?: HeadersInit,
  ) => f.request("/commands", body, identity, headers);
  assertEquals((await post(envelope, "none")).status, 401);
  for (const identity of ["guest", "inactive"]) {
    assertEquals((await post(envelope, identity)).status, 403);
  }
  for (
    const body of [
      { ...envelope, plant_id: null },
      { ...envelope, payload_json: "{}x" },
      { ...envelope, payload_json: {} },
      { ...envelope, payload_json: '{"owner_id":null}' },
      { ...envelope, owner_id: owner },
    ]
  ) assertEquals((await post(body)).status, 400);
  assertEquals(
    (await f.request("/commands?owner_id=" + owner, envelope)).status,
    400,
  );
  assertEquals(
    (await post(envelope, "owner", { "X-Operation-Id": photo })).status,
    409,
  );
  assertEquals(f.calls, []);
  assertEquals((await post(envelope, "foreign")).status, 404);
  const accepted = await post(envelope, "owner", {
    "X-Operation-Id": operation.toUpperCase(),
  });
  assertEquals(accepted.status, 200);
  assertEquals(accepted.headers.get("cache-control"), "private, no-store");
  assertEquals(await accepted.json(), receipt);
  assertEquals(await (await post(envelope)).json(), receipt);
  assertEquals((await post({ ...envelope, operation_id: photo })).status, 409);
  const invalid = fixture({
    ...receipt,
    watermark: "2026-02-30T00:00:00.123456Z",
  });
  const failure = await invalid.request("/commands", envelope);
  assertEquals(failure.status, 503);
  assertEquals((await failure.json()).error.retryable, true);
});

Deno.test("revoked card photo, observation photo, recommendation and diagnosis stop on the owner API", async () => {
  const f = fixture();
  assertEquals((await f.request("/commands", envelope)).status, 200);
  for (
    const path of [
      "/plants/" + plant + "/photo",
      "/care/observations/" + observation + "/photo",
      "/plants/" + plant + "/care/recommendation",
      "/analysis/jobs/" + job,
    ]
  ) assertEquals((await f.request(path)).status, 404);
  const replay = await f.request("/analysis/jobs", {
    mode: "diagnosis",
    operation_id: job,
    photo_asset_id: photo,
    target_plant_id: plant,
  });
  assertEquals(replay.status, 404);
  assertEquals(f.storageReads(), 0);
  assertEquals(f.calls.includes("dispatch"), false);
});
