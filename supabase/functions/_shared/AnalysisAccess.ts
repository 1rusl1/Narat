// supabase/functions/_shared/AnalysisAccess.ts
// T030: Mode-specific quota calculation, starter/Free/Paid access resolution, and installation credential hashing.
// Implements the exact algorithm from data-model.md §4.

import { EntitlementGate, EntitlementSnapshot } from "./EntitlementGate.ts";

export type AnalysisQuotaKind =
  | "starter_identification"
  | "starter_diagnosis"
  | "free_monthly"
  | "paid_monthly"
  | "none";

export interface StarterLedgerState {
  starterIdentificationConsumed: boolean;
  starterDiagnosisConsumed: boolean;
  starterIdentificationJobId: string | null;
  starterDiagnosisJobId: string | null;
  firstStarterSuccessAt: string | null;
}

export interface MonthlyQuotaWindowState {
  id: string;
  quotaKind: "free_monthly" | "paid_monthly";
  periodStart: string;
  periodEnd: string;
  limitCount: number;
  consumedCount: number;
  reservedCount: number;
}

export interface ModeAccessSummary {
  mode: "identification" | "diagnosis" | "follow_up";
  allowed: boolean;
  activeQuotaKind: AnalysisQuotaKind;
  remaining: number;
  limit: number;
  inProgressJobId: string | null;
  nextResetAt: string | null;
  reason?:
    | "starter_in_progress"
    | "starter_exhausted"
    | "free_monthly_starts_next_utc_month"
    | "free_monthly_exhausted"
    | "paid_monthly_exhausted"
    | "paid_subscription_required_for_follow_up";
}

export interface AnalysisAccessSnapshotResponse {
  is_guest: boolean;
  starter: {
    identification_remaining: number;
    diagnosis_remaining: number;
    identification_in_progress_job_id: string | null;
    diagnosis_in_progress_job_id: string | null;
    first_starter_success_at: string | null;
  };
  modes: {
    identification: ModeAccessSummary;
    diagnosis: ModeAccessSummary;
    follow_up: ModeAccessSummary;
  };
}

export async function hashInstallationCredential(
  rawCredential: string,
): Promise<string> {
  const bytes = new TextEncoder().encode(rawCredential.trim());
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export function mergeStarterLedgers(
  installation: StarterLedgerState | null,
  profile: StarterLedgerState | null,
): StarterLedgerState {
  const idConsumed = Boolean(
    installation?.starterIdentificationConsumed ||
      profile?.starterIdentificationConsumed,
  );
  const diagConsumed = Boolean(
    installation?.starterDiagnosisConsumed ||
      profile?.starterDiagnosisConsumed,
  );
  const idJobId = profile?.starterIdentificationJobId ??
    installation?.starterIdentificationJobId ?? null;
  const diagJobId = profile?.starterDiagnosisJobId ??
    installation?.starterDiagnosisJobId ?? null;

  let earliest: string | null = null;
  const instTime = installation?.firstStarterSuccessAt
    ? Date.parse(installation.firstStarterSuccessAt)
    : NaN;
  const profTime = profile?.firstStarterSuccessAt
    ? Date.parse(profile.firstStarterSuccessAt)
    : NaN;

  if (!Number.isNaN(instTime) && !Number.isNaN(profTime)) {
    earliest = new Date(Math.min(instTime, profTime)).toISOString();
  } else if (!Number.isNaN(instTime)) {
    earliest = installation!.firstStarterSuccessAt;
  } else if (!Number.isNaN(profTime)) {
    earliest = profile!.firstStarterSuccessAt;
  }

  return {
    starterIdentificationConsumed: idConsumed,
    starterDiagnosisConsumed: diagConsumed,
    starterIdentificationJobId: idJobId,
    starterDiagnosisJobId: diagJobId,
    firstStarterSuccessAt: earliest,
  };
}

export function startOfUtcMonth(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1, 0, 0, 0, 0));
}

export function startOfNextUtcMonth(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1, 0, 0, 0, 0));
}

export class AnalysisAccess {
  static evaluateAccessSnapshot(params: {
    isGuestOrAnonymous: boolean;
    entitlement: EntitlementSnapshot | null;
    starter: StarterLedgerState;
    freeMonthlyWindow: MonthlyQuotaWindowState | null;
    paidMonthlyWindow: MonthlyQuotaWindowState | null;
    now?: Date;
  }): AnalysisAccessSnapshotResponse {
    const now = params.now ?? new Date();
    const hasPaid = Boolean(
      !params.isGuestOrAnonymous &&
        params.entitlement &&
        EntitlementGate.hasVerifiedPaidAccess(params.entitlement, now),
    );

    const evaluateMode = (
      mode: "identification" | "diagnosis" | "follow_up",
    ): ModeAccessSummary => {
      if (mode === "follow_up" && !hasPaid) {
        return {
          mode,
          allowed: false,
          activeQuotaKind: "none",
          remaining: 0,
          limit: 0,
          inProgressJobId: null,
          nextResetAt: null,
          reason: "paid_subscription_required_for_follow_up",
        };
      }

      if (hasPaid) {
        const win = params.paidMonthlyWindow;
        const limit = win?.limitCount ?? 100;
        const used = (win?.consumedCount ?? 0) + (win?.reservedCount ?? 0);
        const remaining = Math.max(0, limit - used);
        const nextResetAt = win?.periodEnd ??
          params.entitlement?.validUntil ??
          null;
        return {
          mode,
          allowed: remaining > 0,
          activeQuotaKind: "paid_monthly",
          remaining,
          limit,
          inProgressJobId: null,
          nextResetAt,
          ...(remaining === 0 ? { reason: "paid_monthly_exhausted" } : {}),
        };
      }

      // Starter check for identification / diagnosis
      const isIdentification = mode === "identification";
      const starterConsumed = isIdentification
        ? params.starter.starterIdentificationConsumed
        : params.starter.starterDiagnosisConsumed;
      const inProgressJobId = isIdentification
        ? params.starter.starterIdentificationJobId
        : params.starter.starterDiagnosisJobId;
      const starterKind: AnalysisQuotaKind = isIdentification
        ? "starter_identification"
        : "starter_diagnosis";

      if (inProgressJobId) {
        return {
          mode,
          allowed: false,
          activeQuotaKind: starterKind,
          remaining: 0,
          limit: 1,
          inProgressJobId,
          nextResetAt: null,
          reason: "starter_in_progress",
        };
      }

      if (!starterConsumed) {
        return {
          mode,
          allowed: true,
          activeQuotaKind: starterKind,
          remaining: 1,
          limit: 1,
          inProgressJobId: null,
          nextResetAt: null,
        };
      }

      if (params.isGuestOrAnonymous) {
        return {
          mode,
          allowed: false,
          activeQuotaKind: starterKind,
          remaining: 0,
          limit: 1,
          inProgressJobId: null,
          nextResetAt: null,
          reason: "starter_exhausted",
        };
      }

      // Authenticated Free user -> check free_monthly = 1 starting the UTC month AFTER firstStarterSuccessAt
      if (!params.starter.firstStarterSuccessAt) {
        return {
          mode,
          allowed: false,
          activeQuotaKind: "free_monthly",
          remaining: 0,
          limit: 1,
          inProgressJobId: null,
          nextResetAt: null,
          reason: "starter_exhausted",
        };
      }

      const firstSuccessDate = new Date(params.starter.firstStarterSuccessAt);
      const currentUtcMonthStart = startOfUtcMonth(now);
      const firstSuccessMonthStart = startOfUtcMonth(firstSuccessDate);

      if (currentUtcMonthStart.getTime() <= firstSuccessMonthStart.getTime()) {
        const nextMonth = startOfNextUtcMonth(firstSuccessDate);
        return {
          mode,
          allowed: false,
          activeQuotaKind: "free_monthly",
          remaining: 0,
          limit: 1,
          inProgressJobId: null,
          nextResetAt: nextMonth.toISOString(),
          reason: "free_monthly_starts_next_utc_month",
        };
      }

      const freeWin = params.freeMonthlyWindow;
      const used = (freeWin?.consumedCount ?? 0) + (freeWin?.reservedCount ?? 0);
      const remaining = Math.max(0, 1 - used);
      const nextResetAt = freeWin?.periodEnd ?? startOfNextUtcMonth(now).toISOString();

      return {
        mode,
        allowed: remaining > 0,
        activeQuotaKind: "free_monthly",
        remaining,
        limit: 1,
        inProgressJobId: null,
        nextResetAt,
        ...(remaining === 0 ? { reason: "free_monthly_exhausted" } : {}),
      };
    };

    return {
      is_guest: params.isGuestOrAnonymous,
      starter: {
        identification_remaining:
          params.starter.starterIdentificationConsumed ||
            params.starter.starterIdentificationJobId
            ? 0
            : 1,
        diagnosis_remaining:
          params.starter.starterDiagnosisConsumed ||
            params.starter.starterDiagnosisJobId
            ? 0
            : 1,
        identification_in_progress_job_id:
          params.starter.starterIdentificationJobId,
        diagnosis_in_progress_job_id: params.starter.starterDiagnosisJobId,
        first_starter_success_at: params.starter.firstStarterSuccessAt,
      },
      modes: {
        identification: evaluateMode("identification"),
        diagnosis: evaluateMode("diagnosis"),
        follow_up: evaluateMode("follow_up"),
      },
    };
  }
}
