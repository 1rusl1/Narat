import type { SupabaseClient } from "@supabase/supabase-js";
import {
  ApiHttpError,
  jsonResponse,
  type RequestContext,
  requireActiveOwner,
  requireUuid,
} from "../_shared/http.ts";
import type { PhotoIdentificationResult } from "../_shared/KnowledgeTypes.ts";
import type { AnalysisJobStatusResponse } from "./analysis.ts";

type PhotoJobStatus = Omit<AnalysisJobStatusResponse, "result"> & {
  result: AnalysisJobStatusResponse["result"] | PhotoIdentificationResult;
};

interface DiagnosisWorker {
  ready(): boolean;
  run(jobId: string): Promise<unknown>;
}

function unavailable(ctx: RequestContext) {
  return new ApiHttpError(
    503,
    "PROVIDER_UNAVAILABLE",
    ctx.locale === "pl"
      ? "Analiza jest tymczasowo niedostępna."
      : "Analysis is temporarily unavailable.",
    true,
  );
}

function notFound(ctx: RequestContext) {
  return new ApiHttpError(
    404,
    "NOT_FOUND",
    ctx.locale === "pl"
      ? "Nie znaleziono zdjęcia lub zadania."
      : "Photo or job not found.",
  );
}

function parseJob(
  value: unknown,
  ctx: RequestContext,
): PhotoJobStatus {
  if (value === null) throw notFound(ctx);
  if (!value || typeof value !== "object") throw unavailable(ctx);
  const job = value as PhotoJobStatus;
  if (
    typeof job.job_id !== "string" ||
    !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(
      job.job_id,
    ) ||
    (job.mode !== "diagnosis" && job.mode !== "identification") ||
    !["queued", "running", "succeeded", "failed", "expired"].includes(
      job.status,
    ) ||
    ![`starter_${job.mode}`, "free_monthly", "paid_monthly"].includes(
      job.quota_kind,
    ) ||
    !["reserved", "consumed", "released"].includes(job.quota_state) ||
    (job.status === "succeeded"
      ? !job.result || job.result.job_id !== job.job_id ||
        job.result.mode !== job.mode
      : job.result !== null)
  ) throw unavailable(ctx);
  return job;
}

export function createDiagnosisJobs(
  clientFactory: () => SupabaseClient | null,
  worker: DiagnosisWorker,
  schedule = (promise: Promise<unknown>) => {
    const edge =
      (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } })
        .EdgeRuntime;
    if (edge) edge.waitUntil(promise);
  },
) {
  async function rpc(
    ctx: RequestContext,
    name: string,
    args: Record<string, unknown>,
  ) {
    let response;
    try {
      const client = clientFactory();
      if (!client) throw new Error();
      response = await client.rpc(name, args);
    } catch {
      throw unavailable(ctx);
    }
    const { data, error } = response;
    if (!error) return data;
    if (error.code === "P0002") throw notFound(ctx);
    if (error.code === "42501") {
      throw new ApiHttpError(
        403,
        "FORBIDDEN",
        ctx.locale === "pl"
          ? "Wymagane jest aktywne stałe konto."
          : "An active permanent account is required.",
      );
    }
    if (error.message === "IDEMPOTENCY_CONFLICT") {
      throw new ApiHttpError(
        409,
        "IDEMPOTENCY_CONFLICT",
        ctx.locale === "pl"
          ? "Identyfikator operacji jest już użyty."
          : "Operation ID is already in use.",
      );
    }
    if (error.message === "QUOTA_DENIED") {
      if (error.details === "quota_registration_required") {
        throw new ApiHttpError(
          409,
          "QUOTA_REGISTRATION_REQUIRED",
          ctx.locale === "pl"
            ? "Brakuje potwierdzonej daty rejestracji konta."
            : "A verified account registration date is required for monthly analysis.",
        );
      }
      if (error.details === "starter_in_progress") {
        throw new ApiHttpError(
          409,
          "CONFLICT",
          ctx.locale === "pl"
            ? "Analiza jest już w toku."
            : "An analysis is already in progress.",
          true,
        );
      }
      if (
        [
          "free_monthly_exhausted",
          "paid_monthly_exhausted",
          "starter_exhausted",
        ].includes(error.details)
      ) {
        throw new ApiHttpError(
          429,
          "QUOTA_EXHAUSTED",
          ctx.locale === "pl"
            ? "Limit analiz został wyczerpany."
            : "Analysis quota is exhausted.",
        );
      }
    }
    throw unavailable(ctx);
  }

  return {
    async create(req: Request, ctx: RequestContext) {
      const owner = requireActiveOwner(ctx);
      const body = await req.json().catch(() => null);
      const allowed = new Set([
        "operation_id",
        "mode",
        "photo_asset_id",
        "flow_id",
      ]);
      if (
        !body || typeof body !== "object" || Array.isArray(body) ||
        (body.mode !== "diagnosis" && body.mode !== "identification") ||
        Object.keys(body).some((key) => !allowed.has(key))
      ) {
        throw new ApiHttpError(
          400,
          "VALIDATION_ERROR",
          ctx.locale === "pl"
            ? "Nieprawidłowe żądanie analizy."
            : "Invalid analysis request.",
        );
      }
      const op = requireUuid(body.operation_id, "operation_id");
      const photo = requireUuid(body.photo_asset_id, "photo_asset_id");
      const flow = body.flow_id == null
        ? null
        : requireUuid(body.flow_id, "flow_id");
      const identification = body.mode === "identification";
      const command = identification
        ? "create_photo_analysis_job"
        : "create_diagnosis_job";
      const result = await rpc(ctx, command, {
        p_owner_id: owner,
        p_operation_id: op,
        p_photo_asset_id: photo,
        p_flow_id: flow,
        p_locale: ctx.locale,
        p_can_dispatch: worker.ready(),
        ...(identification && { p_mode: body.mode }),
      });
      if (typeof result?.replayed !== "boolean") throw unavailable(ctx);
      const job = parseJob(result.job, ctx);
      if (job.mode !== body.mode) throw unavailable(ctx);
      if (worker.ready() && job.status === "queued") {
        // A retry can recover an undelivered dispatch. The database grants only one lease.
        const task = worker.run(job.job_id).catch(() => undefined);
        schedule(task);
      }
      return jsonResponse(job, result.replayed ? 200 : 202, {
        "Cache-Control": "no-store",
      });
    },

    async status(ctx: RequestContext, id: string) {
      const owner = requireActiveOwner(ctx);
      const jobId = requireUuid(id, "job_id");
      const job = parseJob(
        await rpc(ctx, "read_diagnosis_job", {
          p_owner_id: owner,
          p_job_id: jobId,
        }),
        ctx,
      );
      if (job.job_id !== jobId) throw unavailable(ctx);
      return jsonResponse(job, 200, { "Cache-Control": "no-store" });
    },
  };
}
