// supabase/functions/maintenance/analysis-jobs.ts
// T034: Reconciler for analysis_jobs that exceeded the 55s deadline or whose worker lease expired.
// Releases reserved quota exactly once in the original reserved period.

import { JOB_TOTAL_DEADLINE_MS } from "../analysis-worker/index.ts";

export interface StuckAnalysisJobRecord {
  id: string;
  status: "queued" | "running";
  quotaKind: string;
  quotaState: "reserved" | "consumed" | "released" | "not_required";
  monthlyQuotaId: string | null;
  createdAt: string;
  leaseExpiresAt: string | null;
}

export interface JobReconcilerAdapter {
  findStuckJobs(params: {
    now: Date;
    deadlineMs: number;
  }): Promise<StuckAnalysisJobRecord[]>;

  releaseStuckJobQuotaOnce(params: {
    jobId: string;
    now: Date;
  }): Promise<{ alreadyFinalized: boolean; quotaState: "consumed" | "released" }>;
}

export async function reconcileStuckAnalysisJobs(
  adapter: JobReconcilerAdapter,
  now: Date = new Date(),
): Promise<{
  checkedCount: number;
  releasedCount: number;
  skippedAlreadyFinalizedCount: number;
}> {
  const stuckJobs = await adapter.findStuckJobs({
    now,
    deadlineMs: JOB_TOTAL_DEADLINE_MS,
  });

  let releasedCount = 0;
  let skippedAlreadyFinalizedCount = 0;

  for (const job of stuckJobs) {
    const res = await adapter.releaseStuckJobQuotaOnce({
      jobId: job.id,
      now,
    });
    if (res.alreadyFinalized) {
      skippedAlreadyFinalizedCount += 1;
    } else if (res.quotaState === "released") {
      releasedCount += 1;
    }
  }

  return {
    checkedCount: stuckJobs.length,
    releasedCount,
    skippedAlreadyFinalizedCount,
  };
}
