// supabase/functions/plants-api/analysis-access.ts
// T030: GET /analysis/access endpoint returning mode-specific remaining quotas and reset dates.

import {
  jsonResponse,
  RequestContext,
} from "../_shared/http.ts";
import {
  AnalysisAccess,
  hashInstallationCredential,
  mergeStarterLedgers,
  MonthlyQuotaWindowState,
  StarterLedgerState,
} from "../_shared/AnalysisAccess.ts";
import { EntitlementSnapshot } from "../_shared/EntitlementGate.ts";

export interface AnalysisAccessQueryAdapter {
  fetchInstallationByCredentialHash(
    credentialHash: string,
  ): Promise<StarterLedgerState | null>;
  fetchOwnerProfileStarter(ownerId: string): Promise<StarterLedgerState | null>;
  fetchOwnerEntitlement(ownerId: string): Promise<EntitlementSnapshot | null>;
  fetchActiveMonthlyQuota(
    ownerId: string,
    quotaKind: "free_monthly" | "paid_monthly",
    now: Date,
  ): Promise<MonthlyQuotaWindowState | null>;
}

export async function handleGetAnalysisAccess(
  _req: Request,
  ctx: RequestContext,
  adapter: AnalysisAccessQueryAdapter,
  now: Date = new Date(),
): Promise<Response> {
  const isGuestOrAnonymous = !ctx.ownerId || ctx.isAnonymous;

  let installationStarter: StarterLedgerState | null = null;
  if (ctx.installationCredential) {
    const hash = await hashInstallationCredential(ctx.installationCredential);
    installationStarter = await adapter.fetchInstallationByCredentialHash(hash);
  }

  let profileStarter: StarterLedgerState | null = null;
  let entitlement: EntitlementSnapshot | null = null;
  let freeWindow: MonthlyQuotaWindowState | null = null;
  let paidWindow: MonthlyQuotaWindowState | null = null;

  if (ctx.ownerId) {
    profileStarter = await adapter.fetchOwnerProfileStarter(ctx.ownerId);
    if (!ctx.isAnonymous) {
      entitlement = await adapter.fetchOwnerEntitlement(ctx.ownerId);
      freeWindow = await adapter.fetchActiveMonthlyQuota(
        ctx.ownerId,
        "free_monthly",
        now,
      );
      paidWindow = await adapter.fetchActiveMonthlyQuota(
        ctx.ownerId,
        "paid_monthly",
        now,
      );
    }
  }

  const mergedStarter = mergeStarterLedgers(
    installationStarter,
    profileStarter,
  );

  const snapshot = AnalysisAccess.evaluateAccessSnapshot({
    isGuestOrAnonymous,
    entitlement,
    starter: mergedStarter,
    freeMonthlyWindow: freeWindow,
    paidMonthlyWindow: paidWindow,
    now,
  });

  return jsonResponse(snapshot, 200);
}
