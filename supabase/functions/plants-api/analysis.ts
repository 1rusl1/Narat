// supabase/functions/plants-api/analysis.ts
// T033: POST /analysis/jobs and GET /analysis/jobs/:id (status/result).
// Checks operation_receipts BEFORE quota admission so idempotent retries never consume or fail on quotas.

import {
  ApiHttpError,
  jsonResponse,
  RequestContext,
  requireUuid,
} from "../_shared/http.ts";
import {
  LegacyPreliminaryAnalysisProjection,
  PreliminaryAnalysisProjection,
} from "../_shared/ProtocolResolver.ts";

export interface CreateAnalysisJobRequest {
  operation_id: string;
  mode: "identification" | "diagnosis";
  photo_asset_id: string;
  flow_id?: string;
  intent?: "problem" | "care";
  add_method?: "scan" | "catalogue";
  draft_id?: string;
  plant_id?: string;
  conditions?: {
    light_level?: string;
    light_source?: string;
    light_confirmed?: boolean;
    watering_habit?: string;
    last_watered?: string;
    pot_type?: string;
    season_override?: string;
  };
}

// Read model retains the original mode and signed result for historical GET/replays.
export interface AnalysisJobStatusResponse {
  job_id: string;
  mode: PreliminaryAnalysisProjection["mode"] | LegacyPreliminaryAnalysisProjection["mode"];
  status: "queued" | "running" | "succeeded" | "failed" | "expired";
  quota_kind: string;
  quota_state: "reserved" | "consumed" | "released" | "not_required";
  result?: PreliminaryAnalysisProjection | LegacyPreliminaryAnalysisProjection | null;
  error_code?: string | null;
  error_message?: string | null;
}

export interface AnalysisJobStoreAdapter {
  findOperationReceipt(params: {
    ownerScopeId: string;
    operationId: string;
    commandName: string;
  }): Promise<{ payloadHash: string; responsePayload: AnalysisJobStatusResponse } | null>;

  admitAndCreateJob(params: {
    ownerId: string | null;
    installationCredential: string | null;
    operationId: string;
    payloadHash: string;
    mode: "identification" | "diagnosis";
    photoAssetId: string;
    flowId: string | null;
    intent: "problem" | "care" | null;
    addMethod: "scan" | "catalogue" | null;
    draftId: string | null;
    plantId: string | null;
    locale: "pl" | "en";
    conditions: Record<string, unknown> | null;
  }): Promise<AnalysisJobStatusResponse>;

  getJobStatusAndResult(params: {
    jobId: string;
    ownerId: string | null;
    installationCredential: string | null;
  }): Promise<AnalysisJobStatusResponse | null>;
}

async function computePayloadHash(raw: unknown): Promise<string> {
  const bytes = new TextEncoder().encode(JSON.stringify(raw));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export async function handleCreateAnalysisJob(
  req: Request,
  ctx: RequestContext,
  adapter: AnalysisJobStoreAdapter,
): Promise<Response> {
  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object") {
    throw new ApiHttpError(400, "VALIDATION_ERROR", "Invalid JSON body.");
  }

  const obj = body as Record<string, unknown>;
  const operationId = requireUuid(obj.operation_id, "operation_id");

  const mode = obj.mode;
  if (
    mode !== "identification" &&
    mode !== "diagnosis"
  ) {
    throw new ApiHttpError(
      400,
      "VALIDATION_ERROR",
      "Field 'mode' must be 'identification' or 'diagnosis'.",
      false,
      { field: "mode" },
    );
  }

  const photoAssetId = requireUuid(obj.photo_asset_id, "photo_asset_id");
  const flowId = obj.flow_id ? requireUuid(obj.flow_id, "flow_id") : null;
  const draftId = obj.draft_id ? requireUuid(obj.draft_id, "draft_id") : null;
  const plantId = obj.plant_id ? requireUuid(obj.plant_id, "plant_id") : null;

  const ownerScopeId = ctx.ownerId ?? ctx.installationCredential ?? "";
  if (!ownerScopeId) {
    throw new ApiHttpError(
      401,
      "UNAUTHORIZED",
      ctx.locale === "pl"
        ? "Wymagany identyfikator konta lub instalacji."
        : "Owner or installation credential is required.",
    );
  }

  const canonicalPayload = {
    mode,
    photo_asset_id: photoAssetId,
    flow_id: flowId,
    draft_id: draftId,
    plant_id: plantId,
  };
  const payloadHash = await computePayloadHash(canonicalPayload);

  // 1. Check operation_receipts BEFORE checking quotas!
  const existingReceipt = await adapter.findOperationReceipt({
    ownerScopeId,
    operationId,
    commandName: "analysis.job.create",
  });

  if (existingReceipt) {
    if (existingReceipt.payloadHash !== payloadHash) {
      throw new ApiHttpError(
        409,
        "IDEMPOTENCY_CONFLICT",
        "operation_id was already used with a different payload.",
      );
    }
    return jsonResponse(existingReceipt.responsePayload, 200);
  }

  // 2. Admit quota & create job atomically
  const created = await adapter.admitAndCreateJob({
    ownerId: ctx.ownerId,
    installationCredential: ctx.installationCredential,
    operationId,
    payloadHash,
    mode,
    photoAssetId,
    flowId,
    intent: (obj.intent as "problem" | "care" | undefined) ?? null,
    addMethod: (obj.add_method as "scan" | "catalogue" | undefined) ?? null,
    draftId,
    plantId,
    locale: ctx.locale,
    conditions:
      obj.conditions && typeof obj.conditions === "object"
        ? (obj.conditions as Record<string, unknown>)
        : null,
  });

  return jsonResponse(created, 202);
}

export async function handleGetAnalysisJob(
  _req: Request,
  ctx: RequestContext,
  jobIdRaw: string,
  adapter: AnalysisJobStoreAdapter,
): Promise<Response> {
  const jobId = requireUuid(jobIdRaw, "job_id");
  const status = await adapter.getJobStatusAndResult({
    jobId,
    ownerId: ctx.ownerId,
    installationCredential: ctx.installationCredential,
  });

  if (!status) {
    throw new ApiHttpError(
      404,
      "NOT_FOUND",
      ctx.locale === "pl"
        ? "Nie znaleziono zadania analizy."
        : "Analysis job not found.",
    );
  }

  return jsonResponse(status, 200);
}
