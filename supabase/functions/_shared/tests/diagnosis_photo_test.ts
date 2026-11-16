// SDK transport fixtures for the production photo routes and leased worker.
import { assert, assertEquals } from "@std/assert";
import { createProductionPlantsApiHandler } from "../../plants-api/index.ts";
import { createDiagnosisWorker } from "../../analysis-worker/index.ts";
import { AnthropicAdapter } from "../AnthropicAdapter.ts";
import { AnalysisValidator } from "../AnalysisValidator.ts";
import {
  type CanonicalConditionProfile,
  validateConditionProfileSemantics,
} from "../KnowledgeTypes.ts";
import stagingProfile from "../../../../knowledge-base/releases/staging-diagnosis-v1/monstera-overwatering.json" with {
  type: "json",
};
import type { RequestContext } from "../http.ts";

const owner = "be350000-0000-4000-8000-000000000001";
const other = "be350000-0000-4000-8000-000000000002";
const photo = "be350000-0000-4000-8000-000000000003";
const job = "be350000-0000-4000-8000-000000000004";
const kb = "be350000-0000-4000-8000-000000000005";
const uploadOperation = "be350000-0000-4000-8000-000000000006";
const lease = "be350000-0000-4000-8000-000000000007";
const jobOperation = "be350000-0000-4000-8000-000000000008";
const catalogue = "be350000-0000-4000-8000-000000000009";
const species = "be350000-0000-4000-8000-000000000010";
const savedPlant = "be350000-0000-4000-8000-000000000012";
const outsider = "be350000-0000-4000-8000-000000000011";
const firstAidControl = "be350000-0000-4000-8000-000000000013";
const observation = "be350000-0000-4000-8000-000000000014";
const host = "https://diagnosis.example.test";
const repeatContext = {
  light: "bright_indirect",
  watering_frequency: "less_often",
  drainage: "yes",
  care_history: [{ action_code: "water", occurred_local_date: "2026-11-11" }],
};
const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
const hash = Array.from(
  new Uint8Array(await crypto.subtle.digest("SHA-256", jpeg)),
  (n) => n.toString(16).padStart(2, "0"),
).join("");

Deno.test("Diagnosis status exposes only a valid action bound to the current job and plant", async () => {
  const base = {
    job_id: job,
    target_plant_id: savedPlant,
    photo_asset_id: photo,
    status: "succeeded",
    mode: "diagnosis",
    quota_kind: "starter_diagnosis",
    quota_state: "consumed",
    result: { job_id: job, mode: "diagnosis", diagnosis_status: "problem_detected" },
  };
  const firstAid = {
    job_id: job,
    plant_id: savedPlant,
    action_id: "check_moisture",
    action_code: "check_soil",
    source: { url: "https://example.test/first-aid", locator: "Published action" },
  };
  let row: unknown = base;
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: async () => ({
      ownerId: owner,
      accountState: "active",
      isAnonymous: false,
      locale: "en",
      installationCredential: null,
      operationId: null,
    }),
  }, {
    env: (name) =>
      ({ SUPABASE_URL: host, SUPABASE_SERVICE_ROLE_KEY: "fixture-service-role" })[name],
    fetch: async (input, init) => {
      const request = new Request(input, init);
      assertEquals(request.url, host + "/rest/v1/rpc/read_diagnosis_job");
      assertEquals(await request.json(), { p_owner_id: owner, p_job_id: job });
      return Response.json(row);
    },
  });
  const get = () => handler(new Request(host + "/functions/v1/plants-api/analysis/jobs/" + job));
  assertEquals(await (await get()).json(), base);
  row = { ...base, first_aid_action: firstAid };
  assertEquals(await (await get()).json(), row);
  for (const invalid of [
    { ...firstAid, plant_id: outsider },
    { ...firstAid, job_id: outsider },
    { ...firstAid, source: { ...firstAid.source, url: "http://example.test" } },
  ]) {
    row = { ...base, first_aid_action: invalid };
    assertEquals((await get()).status, 503);
  }
});

function fixture(
  options: {
    providerFailure?: boolean;
    provider?: string;
    providerHttpStatus?: number;
    missingKey?: boolean;
    registrationRequired?: boolean;
    repeatDiagnosis?: boolean;
    identificationReply?: {
      text: string;
      stopReason?: string;
      errorCode?: string;
    };
  } = {},
) {
  const key = "fixture-service-role";
  const variables: Record<string, string> = {
    SUPABASE_URL: host,
    SUPABASE_SERVICE_ROLE_KEY: key,
    ANALYSIS_RECEIPT_SIGNING_KEY: "fixture-signing-key-at-least-32-bytes",
  };
  if (!options.missingKey || options.provider === "openrouter") {
    variables.ANTHROPIC_API_KEY = "fixture-anthropic";
  }
  if (!options.missingKey) variables.OPENROUTER_API_KEY = "fixture-openrouter";
  if (options.provider) variables.ANALYSIS_PROVIDER = options.provider;
  const openRouter = options.provider === "openrouter";
  const identification = options.identificationReply;
  const mode = identification ? "identification" : "diagnosis";
  const repeatBinding = options.repeatDiagnosis
    ? { target_plant_id: savedPlant, photo_asset_id: photo }
    : {};
  const expectedError = identification?.errorCode ??
    (options.providerHttpStatus
      ? "PROVIDER_TIMEOUT_OR_ERROR"
      : options.providerFailure
      ? "PROVIDER_REFUSAL"
      : null);
  const env = (name: string) => variables[name];
  let expired = false;
  let plantSaved = false;
  let ticketIssued = false;
  let ready = false, created = false, leased = false, providerStarted = false;
  let providerCalls = 0, uploads = 0;
  let stored: Uint8Array<ArrayBuffer> | null = null;
  let projection: Record<string, unknown> | null = null;
  let outcome = "queued";
  let quotaState = "reserved";
  const rpcNames: string[] = [];
  const work: Promise<unknown>[] = [];
  const row = () => ({
    photo_asset_id: photo,
    owner_id: owner,
    storage_path: `${owner}/${photo}`,
    mime_type: "image/jpeg",
    byte_size: jpeg.length,
    content_sha256: hash,
    expires_in_seconds: expired ? 0 : 60,
    state: ready ? "ready" : "initialized",
  });
  const status = () => ({
    ...repeatBinding,
    job_id: job,
    mode,
    quota_kind: `starter_${mode}`,
    quota_state: quotaState,
    status: outcome,
    result: projection,
    error_code: outcome === "failed" ? expectedError : null,
    error_message: outcome === "failed"
      ? "The analysis could not be completed."
      : null,
  });

  const transport: typeof fetch = async (input, init) => {
    const req = new Request(input, init);
    if (new URL(req.url).origin !== host) {
      providerCalls++;
      assert(providerStarted);
      assertEquals(req.method, "POST");
      if (openRouter) {
        assertEquals(req.url, "https://openrouter.ai/api/v1/messages");
        assertEquals(
          req.headers.get("authorization"),
          "Bearer fixture-openrouter",
        );
        assertEquals(req.headers.get("x-api-key"), null);
        assertEquals(req.redirect, "error");
      } else {
        assertEquals(req.url, "https://api.anthropic.com/v1/messages");
        assertEquals(req.headers.get("x-api-key"), "fixture-anthropic");
        assertEquals(req.headers.get("authorization"), null);
      }
      assert(init?.signal instanceof AbortSignal);
      const body = await req.json();
      assertEquals(
        body.model,
        openRouter ? "anthropic/claude-haiku-5.5" : "claude-haiku-5-5",
      );
      assertEquals(body.max_tokens, 2048);
      assertEquals(
        body.output_config,
        identification
          ? {
            effort: "low",
            format: {
              type: "json_schema",
              schema: {
                type: "object",
                properties: {
                  status: {
                    type: "string",
                    enum: ["identified", "unknown", "unusable"],
                  },
                  plant_id: { type: ["string", "null"] },
                },
                required: ["status", "plant_id"],
                additionalProperties: false,
              },
            },
          }
          : { effort: "low" },
      );
      assertEquals(
        body.thinking,
        openRouter ? { type: "disabled" } : undefined,
      );
      assertEquals(
        body.provider,
        openRouter ? { allow_fallbacks: false } : undefined,
      );
      assert(
        !("temperature" in body) && !("top_p" in body) && !("top_k" in body),
      );
      const [image, text] = body.messages[0].content;
      assertEquals(body.messages[0].content.length, 2);
      assertEquals(image, {
        type: "image",
        source: {
          type: "base64",
          media_type: "image/jpeg",
          data: btoa(String.fromCharCode(...jpeg)),
        },
      });
      if (identification) {
        assertEquals(JSON.parse(text.text), {
          allowed_plants: [[species, "Monstera deliciosa"]],
        });
        return Response.json({
          stop_reason: identification.stopReason ?? "end_turn",
          content: [{ type: "text", text: identification.text }],
        });
      }
      const providerContext = JSON.parse(text.text);
      assertEquals(providerContext.repeat_context, options.repeatDiagnosis ? repeatContext : undefined);
      if (options.repeatDiagnosis) {
        assert(body.system.includes("Do not compare images"));
        assert(!text.text.includes(savedPlant) && !text.text.includes(owner));
      }
      assertEquals(providerContext.allowed_plants, [[
        "monstera_deliciosa",
        "Monstera deliciosa",
      ]]);
      if (options.providerHttpStatus) {
        return Response.json(
          { error: { message: "fixture upstream failure" } },
          { status: options.providerHttpStatus },
        );
      }
      if (options.providerFailure) {
        return Response.json({ stop_reason: "refusal", content: [] });
      }
      return Response.json({
        stop_reason: "end_turn",
        usage: { input_tokens: 801, output_tokens: 143 },
        content: [{
          type: "text",
          text: JSON.stringify({
            schema_version: "3.0",
            kb_release_id: kb,
            mode: "diagnosis",
            locale: "en",
            image_quality: "usable",
            identification: {
              status: "identified",
              plant_id: "monstera_deliciosa",
              genus_id: "monstera",
            },
            diagnosis: { status: "insufficient_data", candidates: [] },
            limitations: ["single_angle"],
            visual_markers: [],
          }),
        }],
      });
    }
    assertEquals(req.headers.get("authorization"), `Bearer ${key}`);
    const path = new URL(req.url).pathname;
    if (path.startsWith("/storage/v1/object/")) {
      assert(path.endsWith(`/analysis-inputs/${owner}/${photo}`));
      if (req.method === "GET") {
        return stored
          ? new Response(stored, { headers: { "content-type": "image/jpeg" } })
          : Response.json({ statusCode: "404", message: "not found" }, {
            status: 404,
          });
      }
      uploads++;
      assertEquals(req.headers.get("x-upsert"), "false");
      stored = new Uint8Array(await req.arrayBuffer());
      assertEquals(stored, jpeg);
      return Response.json({ Key: `analysis-inputs/${owner}/${photo}` });
    }
    const rpc = path.split("/").at(-1)!;
    rpcNames.push(rpc);
    const body = await req.json();
    switch (rpc) {
      case "execute_plant_create_command":
        assertEquals(body.p_owner_id, owner);
        assertEquals(body.p_payload, {
          creation_source: "catalogue",
          add_method: "scan",
          creation_intent: "care",
          identification_job_id: job,
          taxon_id: species,
        });
        assertEquals(outcome, "succeeded");
        plantSaved = true;
        return Response.json({
          plant_id: savedPlant,
          photo_id: photo,
          care_revision: 1,
          context_state: "current",
          next_available_step: "enable_basic_care",
          plan_availability: "available",
          watermark: "2026-11-12T08:00:00.000000Z",
        });
      case "read_owned_plant_photo":
        return Response.json(
          plantSaved && body.p_owner_id === owner &&
            body.p_plant_id === savedPlant
            ? row()
            : null,
        );
      case "create_diagnosis_upload":
      case "create_first_aid_photo_upload":
        assertEquals(body.p_owner_id, owner);
        assertEquals(body.p_operation_id, uploadOperation);
        assertEquals(body.p_content_sha256, hash);
        if (rpc === "create_first_aid_photo_upload") {
          assertEquals(body.p_plant_id, savedPlant);
          assertEquals(body.p_control_id, firstAidControl);
        }
        ticketIssued = true;
        return Response.json(row());
      case "read_diagnosis_upload":
      case "read_first_aid_photo_upload":
        return Response.json(body.p_owner_id === owner ? row() : null);
      case "mark_diagnosis_upload_ready":
      case "mark_first_aid_photo_ready":
        assert(stored);
        assertEquals(body.p_content_sha256, hash);
        ready = true;
        return Response.json(row());
      case "read_owned_first_aid_observation_photo":
        return Response.json(
          body.p_owner_id === owner && body.p_observation_id === observation && ready ? row() : null,
        );
      case "create_photo_analysis_job":
      case "create_plant_diagnosis_job":
      case "create_diagnosis_job": {
        const requested = path.endsWith("/create_photo_analysis_job")
          ? body.p_mode
          : "diagnosis";
        if (created && requested !== mode) {
          return Response.json({
            code: "23505",
            message: "IDEMPOTENCY_CONFLICT",
          }, { status: 409 });
        }
        assertEquals(requested, mode);
        if (options.repeatDiagnosis) {
          assert(path.endsWith("/create_plant_diagnosis_job"));
          if (body.p_target_plant_id !== savedPlant || body.p_owner_id !== owner) {
            return Response.json({ code: "P0002", message: "PLANT_NOT_FOUND" }, { status: 400 });
          }
          if (created && body.p_operation_id !== jobOperation) {
            return Response.json({ code: "23505", message: "PHOTO_ALREADY_USED" }, { status: 409 });
          }
        }
        assertEquals(body.p_owner_id, owner);
        assertEquals(body.p_photo_asset_id, photo);
        if (ticketIssued && body.p_operation_id === uploadOperation) {
          return Response.json({
            code: "23505",
            message: "IDEMPOTENCY_CONFLICT",
          }, { status: 409 });
        }
        assertEquals(body.p_operation_id, jobOperation);
        assert(ready);
        if (options.registrationRequired) {
          return Response.json({
            code: "P0001",
            message: "QUOTA_DENIED",
            details: "quota_registration_required",
          }, { status: 400 });
        }
        if (!body.p_can_dispatch) {
          return Response.json({
            code: "P0001",
            message: "PROVIDER_UNAVAILABLE",
          }, { status: 400 });
        }
        const replayed = created;
        created = true;
        return Response.json({
          replayed,
          job: {
            ...status(),
            status: "queued",
            result: null,
            quota_state: "reserved",
          },
        });
      }
      case "lease_diagnosis_job":
        assertEquals(body.p_job_id, job);
        if (leased) return Response.json(null);
        leased = true;
        outcome = "running";
        return Response.json({
          job_id: job,
          owner_id: owner,
          lease_token: lease,
          kb_release_id: identification ? null : kb,
          mode,
          locale: "en",
          quota_kind: `starter_${mode}`,
          deadline_at: new Date(Date.now() + 55_000).toISOString(),
          upload: row(),
          ...(options.repeatDiagnosis && {
            repeat_context: {
              ...repeatContext,
              target_plant_id: savedPlant,
              care_history: repeatContext.care_history.map((entry) => ({ ...entry, owner_id: owner })),
            },
          }),
        });
      case "read_identification_catalog":
        assert(identification);
        assertEquals(body.p_lease_token, lease);
        return Response.json({
          catalogue_release_id: catalogue,
          plants: [{
            plant_id: species,
            scientific_name: "Monstera deliciosa",
            display_name: "Swiss cheese plant",
          }],
        });
      case "read_diagnosis_catalog":
        assert(!identification);
        assertEquals(body.p_lease_token, lease);
        return Response.json({
          kb_release_id: kb,
          plants: [{
            plant_id: "monstera_deliciosa",
            genus: "Monstera",
            scientific_name: "Monstera deliciosa",
            display_name: "Swiss cheese plant",
          }],
          conditions: [],
        });
      case "start_diagnosis_provider":
        assertEquals(body.p_lease_token, lease);
        assert(!providerStarted);
        providerStarted = true;
        return Response.json({
          allowed: true,
          budget_date: "2026-11-11",
          started_calls: 1,
        });
      case "finish_diagnosis_job":
        assertEquals(body.p_lease_token, lease);
        projection = body.p_result;
        outcome = projection ? "succeeded" : "failed";
        quotaState = body.p_non_billable ? "released" : "consumed";
        assertEquals(
          body.p_error_code,
          expectedError,
        );
        return Response.json({
          already_finalized: false,
          quota_state: quotaState,
        });
      case "read_diagnosis_job":
        return Response.json(body.p_owner_id === owner ? status() : null);
      default:
        throw new Error(`Unexpected fixture route: ${path}`);
    }
  };

  const worker = createDiagnosisWorker(env, { fetch: transport });
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: async (req): Promise<RequestContext> => ({
      ownerId: req.headers.get("authorization") === "Bearer fixture-other"
        ? other
        : owner,
      accountState: "active",
      isAnonymous: false,
      locale: "en",
      installationCredential: null,
      operationId: null,
    }),
  }, {
    env,
    fetch: transport,
    diagnosisWorker: worker,
    scheduleDiagnosis: (p) => work.push(p),
  });
  const api = (path: string, body?: unknown, session = "fixture-owner") =>
    handler(
      new Request(
        host + "/functions/v1/plants-api" + path,
        {
          method: body === undefined ? "GET" : "POST",
          headers: { authorization: "Bearer " + session },
          body: body === undefined ? undefined : JSON.stringify(body),
        },
      ),
    );
  const ticket = () =>
    api("/media/upload-ticket", {
      operation_id: uploadOperation,
      mime_type: "image/jpeg",
      byte_size: jpeg.length,
      content_sha256: hash,
    });
  const put = (url: string, bytes = jpeg, session = "fixture-owner") =>
    handler(
      new Request(url, {
        method: "PUT",
        headers: {
          authorization: "Bearer " + session,
          "content-type": "image/jpeg",
        },
        body: bytes,
      }),
    );
  return {
    api,
    ticket,
    put,
    work,
    rpcNames,
    expire: () => {
      expired = true;
    },
    providerCalls: () => providerCalls,
    uploads: () => uploads,
    corruptPhoto: () => {
      stored = new Uint8Array(jpeg.length);
    },
  };
}

Deno.test("First-aid photo reuses private bytes and rejects a ticket on the diagnosis route", async () => {
  const f = fixture();
  const body = {
    operation_id: uploadOperation,
    mime_type: "image/jpeg",
    byte_size: jpeg.length,
    content_sha256: hash,
    plant_id: savedPlant,
    control_id: firstAidControl,
  };
  assertEquals((await f.api("/media/first-aid/upload-ticket", { ...body, control_id: null })).status, 400);
  const response = await f.api("/media/first-aid/upload-ticket", body);
  assertEquals(response.status, 200);
  const ticket = await response.json();
  assertEquals(ticket.photo_asset_id, photo);
  assertEquals(ticket.expires_in_seconds, 60);
  const url = new URL(ticket.signed_upload_url);
  assertEquals(url.origin, host);
  assertEquals(url.pathname, "/functions/v1/plants-api/media/first-aid/uploads/" + photo);
  assertEquals((await f.put(url.toString().replace("/first-aid/", "/"))).status, 404);
  assertEquals((await f.put(url.toString(), jpeg, "fixture-other")).status, 404);
  assertEquals((await f.put(url.toString(), new Uint8Array([0xff, 0xd8, 0xff, 0x00]))).status, 400);
  assertEquals(await (await f.put(url.toString())).json(), { photo_asset_id: photo, state: "ready" });
  assertEquals(await (await f.api("/media/first-aid/complete", { photo_asset_id: photo })).json(), {
    photo_asset_id: photo, state: "ready",
  });
  const path = "/care/observations/" + observation + "/photo";
  const bytes = await f.api(path);
  assertEquals(bytes.status, 200);
  assertEquals(bytes.headers.get("cache-control"), "private, no-store");
  assertEquals(new Uint8Array(await bytes.arrayBuffer()), jpeg);
  const denied = await f.api(path, undefined, "fixture-other");
  assertEquals(denied.status, 404);
  assertEquals(denied.headers.get("cache-control"), "private, no-store");
});

Deno.test("saved plant repeat diagnosis sends one new photo and factual context through the ordinary worker", async () => {
  const f = fixture({ repeatDiagnosis: true });
  const upload = await f.ticket();
  assertEquals(upload.status, 200);
  assertEquals((await f.put((await upload.json()).signed_upload_url)).status, 200);

  const body = {
    operation_id: jobOperation,
    mode: "diagnosis",
    photo_asset_id: photo,
    target_plant_id: savedPlant,
  };
  assertEquals((await f.api("/analysis/jobs", { ...body, mode: "identification" })).status, 400);
  assertEquals((await f.api("/analysis/jobs", { ...body, target_plant_id: null })).status, 400);
  assertEquals((await f.api("/analysis/jobs", { ...body, care_history: [] })).status, 400);
  assertEquals((await f.api("/analysis/jobs", body, "fixture-other")).status, 404);

  const accepted = await f.api("/analysis/jobs", body);
  assertEquals(accepted.status, 202);
  const admission = await accepted.json();
  assertEquals(admission.target_plant_id, savedPlant);
  assertEquals(admission.photo_asset_id, photo);
  const replay = await f.api("/analysis/jobs", body);
  assertEquals(replay.status, 200);
  assertEquals(await replay.json(), admission);
  const reuse = await f.api("/analysis/jobs", { ...body, operation_id: crypto.randomUUID() });
  assertEquals(reuse.status, 409);
  assertEquals((await reuse.json()).error.code, "PHOTO_ALREADY_USED");
  await Promise.all(f.work);
  assertEquals(f.providerCalls(), 1);
  assertEquals((await f.api("/analysis/jobs/" + job, undefined, "fixture-other")).status, 404);
  const status = await f.api("/analysis/jobs/" + job);
  assertEquals(status.status, 200);
  const result = await status.json();
  assertEquals(result.status, "succeeded");
  assertEquals(result.target_plant_id, savedPlant);
  assertEquals(result.photo_asset_id, photo);
  assertEquals(result.result.plant_id, "monstera_deliciosa");
  assert(!("repeat_context" in result));
});

for (
  const scenario of [
    { name: "direct Anthropic success" },
    { name: "direct Anthropic refusal", providerFailure: true },
    { name: "OpenRouter success", provider: "openrouter" },
    {
      name: "OpenRouter authentication error",
      provider: "openrouter",
      providerHttpStatus: 401,
    },
    {
      name: "OpenRouter rate limit",
      provider: "openrouter",
      providerHttpStatus: 429,
    },
  ]
) {
  Deno.test(`Diagnosis production photo, job, worker and settlement: ${scenario.name}`, async () => {
    const f = fixture(scenario);
    const failed = Boolean(
      scenario.providerFailure || scenario.providerHttpStatus,
    );
    const ticket = await f.ticket();
    assertEquals(ticket.status, 200);
    const details = await ticket.json();
    assertEquals(details.expires_in_seconds, 60);
    assertEquals(details.storage_bucket, "analysis-inputs");
    assertEquals((await f.put(details.signed_upload_url)).status, 200);
    assertEquals(
      (await f.api("/media/complete", { photo_asset_id: photo })).status,
      200,
    );
    const body = {
      operation_id: jobOperation,
      mode: "diagnosis",
      photo_asset_id: photo,
    };
    const conflict = await f.api("/analysis/jobs", {
      ...body,
      operation_id: uploadOperation,
    });
    assertEquals(conflict.status, 409);
    assertEquals((await conflict.json()).error.code, "IDEMPOTENCY_CONFLICT");
    assertEquals(f.work.length, 0);
    const created = await f.api("/analysis/jobs", body);
    assertEquals(created.status, 202);
    assertEquals((await created.json()).job_id, job);
    const repeat = await f.api("/analysis/jobs", body);
    assertEquals(repeat.status, 200);
    assertEquals((await repeat.json()).job_id, job);
    await Promise.all(f.work);
    assertEquals(f.providerCalls(), 1);
    const result = await f.api(`/analysis/jobs/${job}`);
    assertEquals(result.status, 200);
    const status = await result.json();
    assertEquals(status.status, failed ? "failed" : "succeeded");
    assertEquals(status.quota_state, failed ? "released" : "consumed");
    if (failed) assertEquals(status.result, null);
    else {
      assertEquals(status.result.plant_display_name, "Swiss cheese plant");
      assertEquals(status.result.diagnosis_status, "insufficient_data");
      assert(typeof status.result.analysis_receipt === "string");
    }
    assertEquals(
      (await f.api(`/analysis/jobs/${job}`, undefined, "fixture-other")).status,
      404,
    );
  });
}

for (
  const scenario of [
    {
      name: "catalogue species",
      fields: { status: "identified", plant_id: species },
      status: "identified",
      consumed: true,
    },
    {
      name: "explicit unknown",
      fields: { status: "unknown", plant_id: null },
      status: "unknown",
      consumed: true,
    },
    {
      name: "unknown ID",
      fields: { status: "identified", plant_id: outsider },
      status: "unknown",
      consumed: true,
    },
    {
      name: "unusable photo",
      fields: { status: "unusable", plant_id: null },
      status: "unknown",
      consumed: false,
    },
    {
      name: "refusal",
      fields: {},
      stopReason: "refusal",
      errorCode: "PROVIDER_REFUSAL",
    },
    {
      name: "truncation",
      fields: {},
      stopReason: "max_tokens",
      errorCode: "PROVIDER_TRUNCATED",
    },
    {
      name: "invalid JSON",
      fields: {},
      text: "{",
      errorCode: "PROVIDER_INVALID_JSON",
    },
    {
      name: "extra diagnosis data",
      fields: { status: "unknown", plant_id: null, diagnosis: null },
      errorCode: "SCHEMA_VALIDATION_FAILED",
    },
  ]
) {
  Deno.test(`Identification production photo/worker: ${scenario.name}`, async () => {
    const f = fixture({
      provider: "openrouter",
      identificationReply: {
        text: scenario.text ?? JSON.stringify(scenario.fields),
        stopReason: scenario.stopReason,
        errorCode: scenario.errorCode,
      },
    });
    const ticket = await (await f.ticket()).json();
    assertEquals((await f.put(ticket.signed_upload_url)).status, 200);
    const createBody = {
      operation_id: jobOperation,
      photo_asset_id: photo,
      mode: "identification",
    };
    assertEquals((await f.api("/analysis/jobs", createBody)).status, 202);
    await Promise.all(f.work);
    const path = `/analysis/jobs/${job}`;
    const terminal = await (await f.api(path)).json();
    assertEquals(terminal.mode, "identification");
    assertEquals(terminal.quota_kind, "starter_identification");
    assertEquals(terminal.status, scenario.errorCode ? "failed" : "succeeded");
    assertEquals(terminal.error_code, scenario.errorCode ?? null);
    assertEquals(
      terminal.quota_state,
      scenario.consumed ? "consumed" : "released",
    );
    assertEquals(
      terminal.result,
      scenario.errorCode ? null : {
        schema_version: "1.0",
        mode: "identification",
        job_id: job,
        catalogue_release_id: catalogue,
        identification_status: scenario.status,
        plant_id: scenario.status === "identified" ? species : null,
        plant_display_name: scenario.status === "identified"
          ? "Swiss cheese plant"
          : null,
      },
    );
    const replay = await f.api("/analysis/jobs", createBody);
    assertEquals(replay.status, 200);
    assertEquals((await replay.json()).job_id, job);
    assertEquals(
      (await f.api("/analysis/jobs", { ...createBody, mode: "diagnosis" }))
        .status,
      409,
    );
    assertEquals((await f.api(path, undefined, "fixture-other")).status, 404);
    await Promise.all(f.work);
    assertEquals(f.providerCalls(), 1);
    assertEquals(await (await f.api(path)).json(), terminal);
  });
}

Deno.test("Identification saves the original photo and privately reads identical bytes", async () => {
  const f = fixture({
    identificationReply: {
      text: JSON.stringify({ status: "identified", plant_id: species }),
    },
  });
  const ticket = await (await f.ticket()).json();
  assertEquals((await f.put(ticket.signed_upload_url)).status, 200);
  assertEquals(
    (await f.api("/analysis/jobs", {
      operation_id: jobOperation,
      photo_asset_id: photo,
      mode: "identification",
    })).status,
    202,
  );
  await Promise.all(f.work);
  const payload = {
    creation_source: "catalogue",
    add_method: "scan",
    creation_intent: "care",
    identification_job_id: job,
    taxon_id: species,
  };
  const save = (data: Record<string, unknown>) =>
    f.api("/commands", {
      command_name: "plant.create",
      operation_id: outsider,
      payload_json: JSON.stringify(data),
    });
  assertEquals((await save({ ...payload, photo_id: outsider })).status, 400);
  assertEquals(
    (await save({ ...payload, add_method: "catalogue" })).status,
    400,
  );
  const first = await save(payload);
  assertEquals(first.status, 200);
  const receipt = await first.json();
  assertEquals(receipt.photo_id, photo);
  assertEquals(await (await save(payload)).json(), receipt);

  const path = `/plants/${receipt.plant_id}/photo`;
  const ownerRead = await f.api(path);
  assertEquals(ownerRead.status, 200);
  assertEquals(ownerRead.headers.get("content-type"), "image/jpeg");
  assertEquals(ownerRead.headers.get("cache-control"), "private, no-store");
  assertEquals(new Uint8Array(await ownerRead.arrayBuffer()), jpeg);
  const otherRead = await f.api(path, undefined, "fixture-other");
  assertEquals(otherRead.status, 404);
  assertEquals(otherRead.headers.get("cache-control"), "private, no-store");
  assertEquals(f.uploads(), 1);

  f.corruptPhoto();
  const corruptRead = await f.api(path);
  assertEquals(corruptRead.status, 503);
  assertEquals(corruptRead.headers.get("cache-control"), "private, no-store");
});

Deno.test("Analysis explicitly blocks a legacy monthly account without a verified registration date", async () => {
  const f = fixture({ registrationRequired: true });
  const ticket = await (await f.ticket()).json();
  assertEquals((await f.put(ticket.signed_upload_url)).status, 200);
  const response = await f.api("/analysis/jobs", {
    operation_id: jobOperation,
    photo_asset_id: photo,
    mode: "diagnosis",
  });
  assertEquals(response.status, 409);
  assertEquals(
    (await response.json()).error.code,
    "QUOTA_REGISTRATION_REQUIRED",
  );
  assertEquals(f.providerCalls(), 0);
});

Deno.test("Diagnosis rejects another owner and tampered image before writing Storage", async () => {
  const f = fixture();
  const details = await (await f.ticket()).json();
  assertEquals(
    (await f.put(details.signed_upload_url, jpeg, "fixture-other")).status,
    404,
  );
  assertEquals(
    (await f.put(
      details.signed_upload_url,
      new Uint8Array([0xff, 0xd8, 0xff, 0]),
    )).status,
    400,
  );
  f.expire();
  assertEquals((await f.put(details.signed_upload_url)).status, 409);
  assertEquals(f.uploads(), 0);
  assertEquals(
    (await f.api("/media/complete", { photo_asset_id: photo })).status,
    409,
  );
});

for (const provider of [undefined, "openrouter", "typo"]) {
  Deno.test(`Diagnosis unavailable provider fails before dispatch: ${provider ?? "default"}`, async () => {
    const f = fixture({ provider, missingKey: provider !== "typo" });
    const details = await (await f.ticket()).json();
    assertEquals((await f.put(details.signed_upload_url)).status, 200);
    const response = await f.api("/analysis/jobs", {
      operation_id: jobOperation,
      photo_asset_id: photo,
      mode: "diagnosis",
    });
    assertEquals(response.status, 503);
    assertEquals(f.rpcNames.at(-1), "create_diagnosis_job");
    assertEquals(f.providerCalls(), 0);
    assertEquals(f.work.length, 0);
  });
}

Deno.test("OpenRouter caller cancellation aborts the sole SDK transport request", async () => {
  const deadline = new AbortController();
  let calls = 0;
  const adapter = new AnthropicAdapter(undefined, "fixture-openrouter", {
    provider: "openrouter",
    fetch: (_input, init) => {
      calls++;
      const signal = init?.signal;
      assert(signal);
      return new Promise((_resolve, reject) => {
        signal.addEventListener("abort", () => reject(signal.reason), {
          once: true,
        });
        deadline.abort();
      });
    },
  });
  const result = await adapter.classifyAndResolve({
    analysisId: job,
    jobId: job,
    mode: "diagnosis",
    locale: "en",
    imageBase64: btoa(String.fromCharCode(...jpeg)),
    mediaType: "image/jpeg",
    catalog: {
      kbReleaseId: kb,
      plantIds: new Set(),
      genusIds: new Set(),
      conditionProfiles: new Map(),
    },
    signingSecret: "fixture-signing-key-at-least-32-bytes",
    signal: deadline.signal,
  });
  assertEquals(calls, 1);
  assertEquals(result.errorCode, "PROVIDER_TIMEOUT_OR_ERROR");
  assertEquals(result.shouldConsumeQuota, false);
});

Deno.test("Staging published diagnosis profile validates and applies to Monstera only", () => {
  const profile = stagingProfile as CanonicalConditionProfile;
  assert(validateConditionProfileSemantics(profile).valid);
  assertEquals(
    new Set(
      profile.provenance.source_documents.map((doc) => doc.independence_group),
    ).size,
    3,
  );
  const catalog = {
    kbReleaseId: profile.kb_release_id,
    plantIds: new Set(["monstera_deliciosa", "ficus_elastica"]),
    genusIds: new Set(["monstera", "ficus"]),
    conditionProfiles: new Map([[profile.condition_id, profile]]),
  };
  const classification = {
    schema_version: "3.0",
    kb_release_id: profile.kb_release_id,
    mode: "diagnosis",
    locale: "en",
    image_quality: "usable",
    limitations: ["single_angle"],
    visual_markers: ["standing_water_in_saucer"],
    identification: {
      status: "identified",
      plant_id: "monstera_deliciosa",
      genus_id: "monstera",
    },
    diagnosis: {
      status: "problem_detected",
      candidates: [{ condition_id: "overwatering", rank: 1, confidence: 0.8 }],
    },
  };
  assert(AnalysisValidator.validate(classification, catalog).valid);
  classification.identification = {
    status: "identified",
    plant_id: "ficus_elastica",
    genus_id: "ficus",
  };
  assert(!AnalysisValidator.validate(classification, catalog).valid);
});

Deno.test("Initial diagnosis context is closed, owner-only and uses a dedicated receipt RPC", async () => {
  const context = { light: "low", watering_frequency: "moderate", drainage: "yes" };
  const payload = {
    job_id: job,
    mode: "diagnosis",
    status: "queued",
    quota_kind: "starter_diagnosis",
    quota_state: "reserved",
    result: null,
  };
  let anonymous = false;
  let ready = true;
  let dispatches = 0;
  let calls = 0;
  let accepted: string | null = null;
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: async () => ({
      ownerId: owner,
      accountState: "active",
      isAnonymous: anonymous,
      locale: "en",
      installationCredential: null,
      operationId: null,
    }),
  }, {
    env: (name) =>
      ({ SUPABASE_URL: host, SUPABASE_SERVICE_ROLE_KEY: "fixture-service-role" })[name],
    diagnosisWorker: {
      ready: () => ready,
      run: () => {
        dispatches++;
        return Promise.resolve();
      },
    },
    scheduleDiagnosis: () => {},
    fetch: async (input, init) => {
      const request = new Request(input, init);
      const args = await request.json();
      calls++;
      const hasContext = "p_initial_context" in args;
      assertEquals(request.url, host + "/rest/v1/rpc/" +
        (hasContext ? "create_initial_diagnosis_job" : "create_diagnosis_job"));
      assertEquals(args.p_owner_id, owner);
      assertEquals(args.p_operation_id, jobOperation);
      assertEquals(args.p_photo_asset_id, photo);
      assertEquals(args.p_flow_id, null);
      assertEquals(args.p_locale, "en");
      assertEquals(args.p_can_dispatch, ready);
      const supplied = args.p_initial_context;
      const hash = JSON.stringify(hasContext
        ? [supplied.light, supplied.watering_frequency, supplied.drainage]
        : null);
      if (accepted !== null && hash !== accepted) {
        return Response.json({ code: "23505", message: "IDEMPOTENCY_CONFLICT" }, { status: 409 });
      }
      if (accepted === null && !ready) {
        return Response.json({ code: "P0001", message: "PROVIDER_UNAVAILABLE" }, { status: 400 });
      }
      const replayed = accepted !== null;
      accepted = hash;
      return Response.json({ replayed, job: payload });
    },
  });
  const post = (extra: Record<string, unknown>) => handler(new Request(
    host + "/functions/v1/plants-api/analysis/jobs",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        operation_id: jobOperation,
        photo_asset_id: photo,
        mode: "diagnosis",
        ...extra,
      }),
    },
  ));

  for (const invalid of [
    null, [], {}, "unknown",
    { light: "low", watering_frequency: "moderate" },
    { ...context, light: "LOW" },
    { ...context, watering_frequency: "less_often" },
    { ...context, drainage: true },
    { ...context, drainage: null },
    { ...context, care_history: [] },
    { ...context, target_plant_id: savedPlant },
  ]) {
    assertEquals((await post({ initial_context: invalid })).status, 400);
  }
  assertEquals((await post({ initial_context: context, mode: "identification" })).status, 400);
  assertEquals((await post({ initial_context: context, target_plant_id: savedPlant })).status, 400);
  assertEquals((await post({ initial_context: context, owner_id: other })).status, 400);
  anonymous = true;
  assertEquals((await post({ initial_context: context })).status, 403);
  anonymous = false;
  assertEquals(calls, 0);
  assertEquals(dispatches, 0);

  ready = false;
  assertEquals((await post({ initial_context: context })).status, 503);
  assertEquals(dispatches, 0);
  ready = true;
  const first = await post({ initial_context: context });
  assertEquals(first.status, 202);
  assertEquals(await first.json(), payload);
  assertEquals(dispatches, 1);
  ready = false;
  const replay = await post({
    initial_context: { drainage: "yes", watering_frequency: "moderate", light: "low" },
  });
  assertEquals(replay.status, 200);
  assertEquals(await replay.json(), payload);
  assertEquals(dispatches, 1);
  for (const changed of [
    { ...context, light: "medium" },
    { ...context, watering_frequency: "sparse" },
    { ...context, drainage: "no" },
  ]) {
    assertEquals((await post({ initial_context: changed })).status, 409);
  }
  assertEquals((await post({})).status, 409);
  accepted = null;
  ready = true;
  assertEquals((await post({})).status, 202);
  assertEquals((await post({ initial_context: context })).status, 409);

  // Every supported enum reaches admission through the production HTTP route.
  accepted = null;
  ready = false;
  for (const light of ["low", "medium", "bright_indirect", "direct_sun", "unknown"]) {
    assertEquals((await post({ initial_context: { ...context, light } })).status, 503);
  }
  for (const watering_frequency of ["frequent", "moderate", "sparse", "unknown"]) {
    assertEquals((await post({ initial_context: { ...context, watering_frequency } })).status, 503);
  }
  for (const drainage of ["yes", "no", "unknown"]) {
    assertEquals((await post({ initial_context: { ...context, drainage } })).status, 503);
  }
});
