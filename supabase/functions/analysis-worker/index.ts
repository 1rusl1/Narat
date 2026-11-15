// supabase/functions/analysis-worker/index.ts
// T034: Background worker for Vision classification jobs (identification, diagnosis).
// Enforces 40s provider timeout, 55s total job deadline, daily ProviderBudgetGuard <= $10 USD,
// and settles lease/quota exactly once against the original reserved period.

import {
  AnthropicAdapter,
  PROVIDER_CALL_TIMEOUT_MS,
  type RepeatDiagnosisContext,
} from "../_shared/AnthropicAdapter.ts";
import type {
  PhotoIdentificationCatalogue,
  PhotoIdentificationResult,
  PublishedReleaseCatalog,
} from "../_shared/KnowledgeTypes.ts";
import { PreliminaryAnalysisProjection } from "../_shared/ProtocolResolver.ts";
import {
  ESTIMATED_HAIKU_CLASSIFICATION_COST_MICRO_USD,
  ProviderBudgetGuard,
  ProviderBudgetStorageAdapter,
} from "../_shared/ProviderBudgetGuard.ts";
import { createClient } from "@supabase/supabase-js";
import { jsonResponse } from "../_shared/http.ts";
import { createDiagnosisPersistence } from "./diagnosis-persistence.ts";

export const JOB_TOTAL_DEADLINE_MS = 55_000;

export interface LeasedAnalysisJob {
  id: string;
  ownerId: string | null;
  installationId: string | null;
  kbReleaseId: string | null;
  // Persisted adapter data is untrusted, including jobs queued before mode removal.
  mode: string;
  locale: "pl" | "en";
  imageBase64: string;
  mediaType: "image/jpeg" | "image/png" | "image/webp";
  careContext?: {
    light_level: string;
    watering_habit: string;
    last_watered: string;
    pot_type?: string;
    season_override?: string;
  };
  repeatContext?: RepeatDiagnosisContext;
  quotaKind: string;
  monthlyQuotaId: string | null;
  leaseExpiresAt: string;
}

export interface WorkerPersistenceAdapter {
  leaseNextQueuedJob(params: {
    now: Date;
    leaseDurationMs: number;
  }): Promise<LeasedAnalysisJob | null>;

  loadPublishedCatalog(kbReleaseId: string): Promise<PublishedReleaseCatalog>;

  loadIdentificationCatalog?(): Promise<PhotoIdentificationCatalogue>;

  loadJobImage?(job: LeasedAnalysisJob): Promise<string>;

  finalizeJobOnce(params: {
    jobId: string;
    outcome: "succeeded" | "failed";
    isNonBillableResult: boolean;
    projection: PreliminaryAnalysisProjection | null;
    identification?: PhotoIdentificationResult;
    errorCode?: string;
    errorMessage?: string;
    now: Date;
  }): Promise<
    { alreadyFinalized: boolean; quotaState: "consumed" | "released" }
  >;
}

export async function processSingleQueuedJob(params: {
  workerAdapter: WorkerPersistenceAdapter;
  budgetAdapter: ProviderBudgetStorageAdapter;
  anthropicAdapter: AnthropicAdapter;
  signingSecret: string;
  now?: Date;
  enforceDeadline?: boolean;
}): Promise<{
  processed: boolean;
  jobId?: string;
  outcome?: "succeeded" | "failed";
  quotaState?: "consumed" | "released";
  errorCode?: string;
}> {
  const now = params.now ?? new Date();
  const job = await params.workerAdapter.leaseNextQueuedJob({
    now,
    leaseDurationMs: JOB_TOTAL_DEADLINE_MS,
  });

  if (!job) {
    return { processed: false };
  }

  // Reject legacy/unknown persisted modes before loading KB or reserving provider budget.
  // The original analysis quota is released only through the normal idempotent finalizer.
  if (job.mode !== "identification" && job.mode !== "diagnosis") {
    const settled = await params.workerAdapter.finalizeJobOnce({
      jobId: job.id,
      outcome: "failed",
      isNonBillableResult: true,
      projection: null,
      errorCode: "UNSUPPORTED_ANALYSIS_MODE",
      errorMessage:
        "This analysis mode is no longer supported. Submit a new diagnosis.",
      now,
    });
    return {
      processed: true,
      jobId: job.id,
      outcome: "failed",
      quotaState: settled.quotaState,
      errorCode: "UNSUPPORTED_ANALYSIS_MODE",
    };
  }

  const remaining = () => Date.parse(job.leaseExpiresAt) - Date.now();
  let budget:
    | Awaited<ReturnType<typeof ProviderBudgetGuard.acquireReservation>>
    | undefined;
  let result:
    | Awaited<ReturnType<AnthropicAdapter["classifyAndResolve"]>>
    | undefined;
  let errorCode = "ANALYSIS_PROCESSING_FAILED";
  try {
    const target = job.mode === "identification"
      ? {
        mode: "identification" as const,
        catalog: await params.workerAdapter.loadIdentificationCatalog?.(),
      }
      : {
        mode: "diagnosis" as const,
        catalog: job.kbReleaseId
          ? await params.workerAdapter.loadPublishedCatalog(job.kbReleaseId)
          : undefined,
      };
    if (!target.catalog) throw new Error("The pinned release is unavailable.");
    const image = params.workerAdapter.loadJobImage
      ? await params.workerAdapter.loadJobImage(job)
      : job.imageBase64;
    if (params.enforceDeadline && remaining() <= 0) {
      errorCode = "ANALYSIS_TIMEOUT";
    } else {
      budget = await ProviderBudgetGuard.acquireReservation(
        job.mode,
        params.budgetAdapter,
        params.enforceDeadline ? new Date() : now,
      );
      if (!budget.allowed) {
        errorCode = "PROVIDER_DAILY_BUDGET_EXCEEDED";
      } else {
        const timeout = params.enforceDeadline
          ? Math.min(
            PROVIDER_CALL_TIMEOUT_MS,
            Math.max(1, Math.floor(remaining())),
          )
          : PROVIDER_CALL_TIMEOUT_MS;
        const imageInput = {
          jobId: job.id,
          imageBase64: image,
          mediaType: job.mediaType,
          signal: AbortSignal.timeout(timeout),
        };
        result = target.mode === "identification"
          ? await params.anthropicAdapter.identifySpecies(
            imageInput,
            target.catalog,
          )
          : await params.anthropicAdapter.classifyAndResolve({
            ...imageInput,
            analysisId: crypto.randomUUID(),
            mode: target.mode,
            locale: job.locale,
            careContext: job.careContext,
            repeatContext: job.repeatContext,
            catalog: target.catalog,
            signingSecret: params.signingSecret,
          });
        errorCode = result.errorCode ?? errorCode;
      }
    }
  } catch {
    // Storage, catalogue and budget failures settle the original reservation.
  }
  try {
    const projection = result?.ok ? result.projection : undefined;
    const identification = result?.ok ? result.identification : undefined;
    const succeeded = job.mode === "identification"
      ? !!identification
      : !!projection;
    const outcome = succeeded ? "succeeded" : "failed";
    const settled = await params.workerAdapter.finalizeJobOnce({
      jobId: job.id,
      outcome,
      isNonBillableResult: !succeeded || !result?.shouldConsumeQuota,
      projection: projection ?? null,
      ...(identification && { identification }),
      errorCode: succeeded ? undefined : errorCode,
      now: new Date(),
    });
    return {
      processed: true,
      jobId: job.id,
      outcome,
      quotaState: settled.quotaState,
      errorCode: succeeded ? undefined : errorCode,
    };
  } finally {
    if (budget?.allowed) {
      await ProviderBudgetGuard.settleReservation({
        budgetDateUtc: budget.budgetDateUtc,
        reservedMicroUsd: budget.reservedMicroUsd,
        actualSpentMicroUsd: result?.ok
          ? ESTIMATED_HAIKU_CLASSIFICATION_COST_MICRO_USD
          : 0,
        adapter: params.budgetAdapter,
      });
    }
  }
}

type Env = (name: string) => string | undefined;

export function createDiagnosisWorker(
  env: Env,
  options: { fetch?: typeof fetch; anthropicAdapter?: AnthropicAdapter } = {},
) {
  const config = () => {
    const url = env("SUPABASE_URL")?.trim();
    const key = env("SUPABASE_SERVICE_ROLE_KEY")?.trim();
    const provider = env("ANALYSIS_PROVIDER")?.trim() || "anthropic";
    if (provider !== "anthropic" && provider !== "openrouter") return null;
    const apiKey = env(
      provider === "openrouter" ? "OPENROUTER_API_KEY" : "ANTHROPIC_API_KEY",
    )?.trim();
    const signingSecret = env("ANALYSIS_RECEIPT_SIGNING_KEY")?.trim();
    if (
      !url || !key || !apiKey || !signingSecret || signingSecret.length < 32
    ) return null;
    try {
      if (!["http:", "https:"].includes(new URL(url).protocol)) return null;
    } catch {
      return null;
    }
    return { url, key, provider, apiKey, signingSecret } as const;
  };
  return {
    ready: () => config() !== null,
    async run(jobId: string) {
      const current = config();
      if (!current) {
        throw new Error("Diagnosis worker configuration is incomplete.");
      }
      const client = createClient(current.url, current.key, {
        auth: {
          persistSession: false,
          autoRefreshToken: false,
          detectSessionInUrl: false,
        },
        global: { fetch: options.fetch },
      });
      return await processSingleQueuedJob({
        ...createDiagnosisPersistence(client, jobId),
        anthropicAdapter: options.anthropicAdapter ??
          new AnthropicAdapter(undefined, current.apiKey, {
            provider: current.provider,
            fetch: options.fetch,
          }),
        signingSecret: current.signingSecret,
        enforceDeadline: true,
      });
    },
  };
}

if (import.meta.main) {
  const env = (name: string) => Deno.env.get(name);
  const worker = createDiagnosisWorker(env);
  Deno.serve(async (req) => {
    if (req.method !== "POST") {
      return jsonResponse({ error: "METHOD_NOT_ALLOWED" }, 405);
    }
    const key = env("SUPABASE_SERVICE_ROLE_KEY")?.trim();
    const auth = req.headers.get("authorization");
    const expected = key ? `Bearer ${key}` : "";
    if (!key || !auth || auth.length !== expected.length) {
      return jsonResponse({ error: "UNAUTHORIZED" }, 401);
    }
    let difference = 0;
    for (let i = 0; i < expected.length; i++) {
      difference |= auth.charCodeAt(i) ^ expected.charCodeAt(i);
    }
    if (difference) return jsonResponse({ error: "UNAUTHORIZED" }, 401);
    if (!worker.ready()) {
      return jsonResponse({ error: "PROVIDER_UNAVAILABLE" }, 503);
    }
    const body = await req.json().catch(() => null);
    if (
      typeof body?.job_id !== "string" ||
      !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(
        body.job_id,
      )
    ) {
      return jsonResponse({ error: "VALIDATION_ERROR" }, 400);
    }
    try {
      return jsonResponse(await worker.run(body.job_id));
    } catch {
      return jsonResponse({ error: "WORKER_UNAVAILABLE" }, 503);
    }
  });
}
