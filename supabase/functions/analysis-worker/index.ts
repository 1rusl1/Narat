// supabase/functions/analysis-worker/index.ts
// T034: Background worker for Vision classification jobs (identification, diagnosis, follow_up).
// Enforces 40s provider timeout, 55s total job deadline, daily ProviderBudgetGuard <= $10 USD,
// and settles lease/quota exactly once against the original reserved period.

import {
  AnthropicAdapter,
  PROVIDER_CALL_TIMEOUT_MS,
} from "../_shared/AnthropicAdapter.ts";
import { PublishedReleaseCatalog } from "../_shared/KnowledgeTypes.ts";
import { PreliminaryAnalysisProjection } from "../_shared/ProtocolResolver.ts";
import {
  ESTIMATED_HAIKU_CLASSIFICATION_COST_MICRO_USD,
  ProviderBudgetGuard,
  ProviderBudgetStorageAdapter,
} from "../_shared/ProviderBudgetGuard.ts";
import { jsonResponse } from "../_shared/http.ts";

export const JOB_TOTAL_DEADLINE_MS = 55_000;

export interface LeasedAnalysisJob {
  id: string;
  ownerId: string | null;
  installationId: string | null;
  kbReleaseId: string;
  mode: "identification" | "diagnosis" | "follow_up";
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
  comparisonTraitsHint?: string[];
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

  finalizeJobOnce(params: {
    jobId: string;
    outcome: "succeeded" | "failed";
    isNonBillableResult: boolean;
    projection: PreliminaryAnalysisProjection | null;
    errorCode?: string;
    errorMessage?: string;
    now: Date;
  }): Promise<{ alreadyFinalized: boolean; quotaState: "consumed" | "released" }>;
}

export async function processSingleQueuedJob(params: {
  workerAdapter: WorkerPersistenceAdapter;
  budgetAdapter: ProviderBudgetStorageAdapter;
  anthropicAdapter: AnthropicAdapter;
  signingSecret: string;
  now?: Date;
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

  // Enforce that only Vision classification modes ever invoke the provider
  ProviderBudgetGuard.assertModeUsesProvider(job.mode);

  const budgetRes = await ProviderBudgetGuard.acquireReservation(
    job.mode,
    params.budgetAdapter,
    now,
  );

  if (!budgetRes.allowed) {
    const settled = await params.workerAdapter.finalizeJobOnce({
      jobId: job.id,
      outcome: "failed",
      isNonBillableResult: true,
      projection: null,
      errorCode: "PROVIDER_DAILY_BUDGET_EXCEEDED",
      errorMessage: "Daily provider budget cap ($10 USD) reached.",
      now: new Date(),
    });
    return {
      processed: true,
      jobId: job.id,
      outcome: "failed",
      quotaState: settled.quotaState,
      errorCode: "PROVIDER_DAILY_BUDGET_EXCEEDED",
    };
  }

  let actualSpentMicroUsd = 0;
  try {
    const catalog = await params.workerAdapter.loadPublishedCatalog(job.kbReleaseId);

    // Enforce 40s provider timeout inside the 55s total job deadline
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), PROVIDER_CALL_TIMEOUT_MS);

    let result;
    try {
      result = await params.anthropicAdapter.classifyAndResolve({
        analysisId: crypto.randomUUID(),
        jobId: job.id,
        mode: job.mode,
        locale: job.locale,
        imageBase64: job.imageBase64,
        mediaType: job.mediaType,
        careContext: job.careContext,
        comparisonTraitsHint: job.comparisonTraitsHint,
        catalog,
        signingSecret: params.signingSecret,
      });
    } finally {
      clearTimeout(timeoutId);
    }

    if (result.ok && result.projection) {
      actualSpentMicroUsd = ESTIMATED_HAIKU_CLASSIFICATION_COST_MICRO_USD;
      const settled = await params.workerAdapter.finalizeJobOnce({
        jobId: job.id,
        outcome: "succeeded",
        isNonBillableResult: !result.shouldConsumeQuota,
        projection: result.projection,
        now: new Date(),
      });
      return {
        processed: true,
        jobId: job.id,
        outcome: "succeeded",
        quotaState: settled.quotaState,
      };
    }

    const settled = await params.workerAdapter.finalizeJobOnce({
      jobId: job.id,
      outcome: "failed",
      isNonBillableResult: true,
      projection: null,
      errorCode: result.errorCode ?? "PROVIDER_ERROR",
      errorMessage: result.errorMessage ?? "Classification failed.",
      now: new Date(),
    });

    return {
      processed: true,
      jobId: job.id,
      outcome: "failed",
      quotaState: settled.quotaState,
      errorCode: result.errorCode,
    };
  } finally {
    await ProviderBudgetGuard.settleReservation({
      budgetDateUtc: budgetRes.budgetDateUtc,
      reservedMicroUsd: budgetRes.reservedMicroUsd,
      actualSpentMicroUsd,
      adapter: params.budgetAdapter,
    });
  }
}

if (import.meta.main) {
  Deno.serve(() => jsonResponse({ status: "analysis-worker-ready" }));
}
