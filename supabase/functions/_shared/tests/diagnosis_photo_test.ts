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
const host = "https://diagnosis.example.test";
const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
const hash = Array.from(
  new Uint8Array(await crypto.subtle.digest("SHA-256", jpeg)),
  (n) => n.toString(16).padStart(2, "0"),
).join("");

function fixture(
  options: {
    providerFailure?: boolean;
    missingKey?: boolean;
  } = {},
) {
  const key = "fixture-service-role";
  const variables: Record<string, string> = {
    SUPABASE_URL: host,
    SUPABASE_SERVICE_ROLE_KEY: key,
    ANALYSIS_RECEIPT_SIGNING_KEY: "fixture-signing-key-at-least-32-bytes",
  };
  if (!options.missingKey) variables.ANTHROPIC_API_KEY = "fixture-anthropic";
  const env = (name: string) => variables[name];
  let expired = false;
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
    job_id: job,
    mode: "diagnosis",
    quota_kind: "starter_diagnosis",
    quota_state: quotaState,
    status: outcome,
    result: projection,
    error_code: outcome === "failed" ? "PROVIDER_REFUSAL" : null,
    error_message: outcome === "failed"
      ? "The analysis could not be completed."
      : null,
  });

  const transport: typeof fetch = async (input, init) => {
    const req = new Request(input, init);
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
      case "create_diagnosis_upload":
        assertEquals(body.p_owner_id, owner);
        assertEquals(body.p_operation_id, uploadOperation);
        assertEquals(body.p_content_sha256, hash);
        ticketIssued = true;
        return Response.json(row());
      case "read_diagnosis_upload":
        return Response.json(body.p_owner_id === owner ? row() : null);
      case "mark_diagnosis_upload_ready":
        assert(stored);
        assertEquals(body.p_content_sha256, hash);
        ready = true;
        return Response.json(row());
      case "create_diagnosis_job": {
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
          kb_release_id: kb,
          mode: "diagnosis",
          locale: "en",
          quota_kind: "starter_diagnosis",
          deadline_at: new Date(Date.now() + 55_000).toISOString(),
          upload: row(),
        });
      case "read_diagnosis_catalog":
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
          options.providerFailure ? "PROVIDER_REFUSAL" : null,
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

  const anthropic = new AnthropicAdapter({
    create: async (body, options_) => {
      providerCalls++;
      assert(providerStarted);
      assertEquals(body.model, "claude-haiku-5-5");
      assert(
        !("temperature" in body) && !("top_p" in body) && !("top_k" in body),
      );
      assertEquals(body.output_config.effort, "low");
      assert(options_?.signal instanceof AbortSignal);
      const image = body.messages[0].content[0];
      assert(image.type === "image");
      assertEquals(image.source.data, btoa(String.fromCharCode(...jpeg)));
      const text = body.messages[0].content[1];
      assert(text.type === "text");
      assertEquals(JSON.parse(text.text).allowed_plants, [[
        "monstera_deliciosa",
        "Monstera deliciosa",
      ]]);
      if (options.providerFailure) {
        return { stop_reason: "refusal", content: [] };
      }
      return {
        stop_reason: "end_turn",
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
      };
    },
  });
  const worker = createDiagnosisWorker(env, {
    fetch: transport,
    anthropicAdapter: anthropic,
  });
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
  };
}

for (const providerFailure of [false, true]) {
  Deno.test(`Diagnosis production photo, job, worker and settlement fixture, refusal=${providerFailure}`, async () => {
    const f = fixture({ providerFailure });
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
    assertEquals(status.status, providerFailure ? "failed" : "succeeded");
    assertEquals(status.quota_state, providerFailure ? "released" : "consumed");
    if (providerFailure) assertEquals(status.result, null);
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

Deno.test("Diagnosis missing provider credential fails closed before dispatch", async () => {
  const f = fixture({ missingKey: true });
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
