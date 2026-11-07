// supabase/functions/_shared/EntitlementGate.ts
// T020: EntitlementGate separating canReadExistingPlan from canGenerateFullPlan,
// paid access (active/grace with verified date including offer_kind=trial), Free slots (1..3),
// and first-aid control. Exhausting 100 monthly analyses never blocks non-scan paid rights.
// Safety/applicability is independent of subscription state. SQL T018 remains authoritative for task INSERTs.

export type SubscriptionState =
  | "active"
  | "grace"
  | "billing_retry"
  | "expired"
  | "revoked"
  | "none";

export type OfferKind = "trial" | "paid" | "none";

export interface EntitlementSnapshot {
  ownerId: string;
  accountState: "active" | "deleting" | "deleted";
  subscriptionState: SubscriptionState;
  offerKind: OfferKind;
  validUntil: string | null;
  trialEndAt: string | null;
  autoRenewEnabled: boolean;
  verifiedAt: string | null;
  paidMonthlyConsumed?: number;
  paidMonthlyLimit?: number;
}

export interface ExistingPlanRecord {
  id: string;
  ownerId: string;
  plantId: string;
  accessTier: "basic" | "full";
  planKind: "routine" | "recovery";
  state: "active" | "superseded" | "archived";
  applicabilityStatus: "applicable" | "reassessment_required" | "revoked";
  chemicalMustRevalidateAfter: string | null;
}

export interface BasicCareMembershipSnapshot {
  ownerId: string;
  plantId: string;
  enabled: boolean;
  freeSlot: number | null;
  deletedAt: string | null;
}

export interface FirstAidFollowupSnapshot {
  ownerId: string;
  plantId: string;
  originAnalysisId: string;
  state: "active" | "completed" | "cancelled" | "superseded";
  firstActionEntryId: string | null;
  controlIntervalDays: number | null;
  deletedAt: string | null;
}

export interface PlanReadEvaluation {
  allowed: boolean;
  instructionsApplicable: boolean;
  chemicalExpired: boolean;
  reason?:
    | "not_owner"
    | "account_inactive"
    | "plan_revoked"
    | "reassessment_required"
    | "chemical_revalidation_required";
}

export class EntitlementGate {
  /**
   * Paid access is active when the owner account is active, subscriptionState is 'active' or 'grace',
   * validUntil is verified and in the future, and if offerKind === 'trial', trialEndAt is also verified
   * and in the future. Exhausting the 100 monthly analysis quota does NOT revoke paid access.
   */
  static hasVerifiedPaidAccess(
    entitlement: EntitlementSnapshot,
    now: Date = new Date(),
  ): boolean {
    if (entitlement.accountState !== "active") {
      return false;
    }
    if (
      entitlement.subscriptionState !== "active" &&
      entitlement.subscriptionState !== "grace"
    ) {
      return false;
    }
    if (!entitlement.verifiedAt || !entitlement.validUntil) {
      return false;
    }
    const validUntilMs = Date.parse(entitlement.validUntil);
    if (Number.isNaN(validUntilMs) || validUntilMs <= now.getTime()) {
      return false;
    }
    if (entitlement.offerKind === "trial") {
      if (!entitlement.trialEndAt) {
        return false;
      }
      const trialEndMs = Date.parse(entitlement.trialEndAt);
      if (Number.isNaN(trialEndMs) || trialEndMs <= now.getTime()) {
        return false;
      }
    }
    return true;
  }

  /**
   * Generating a NEW full (routine or recovery) plan requires verified paid access
   * (active or grace, including verified trial). It does NOT consume or depend on the 100 analysis quota.
   */
  static canGenerateFullPlan(
    entitlement: EntitlementSnapshot,
    now: Date = new Date(),
  ): boolean {
    return EntitlementGate.hasVerifiedPaidAccess(entitlement, now);
  }

  /**
   * Reading an ALREADY published plan (including full_body) is allowed for its active owner
   * even after trial/subscription expiry or refund (FR-020, V50).
   * Safety and applicability are evaluated independently so revoked or expired chemical instructions
   * are never presented as actionable.
   */
  static canReadExistingPlan(
    entitlement: EntitlementSnapshot,
    plan: ExistingPlanRecord,
    now: Date = new Date(),
  ): PlanReadEvaluation {
    if (entitlement.accountState !== "active") {
      return {
        allowed: false,
        instructionsApplicable: false,
        chemicalExpired: false,
        reason: "account_inactive",
      };
    }
    if (plan.ownerId !== entitlement.ownerId) {
      return {
        allowed: false,
        instructionsApplicable: false,
        chemicalExpired: false,
        reason: "not_owner",
      };
    }

    const todayUtc = now.toISOString().slice(0, 10);
    const chemicalExpired = Boolean(
      plan.chemicalMustRevalidateAfter &&
        plan.chemicalMustRevalidateAfter < todayUtc,
    );

    if (plan.applicabilityStatus === "revoked") {
      return {
        allowed: true,
        instructionsApplicable: false,
        chemicalExpired,
        reason: "plan_revoked",
      };
    }

    if (plan.applicabilityStatus === "reassessment_required") {
      return {
        allowed: true,
        instructionsApplicable: false,
        chemicalExpired,
        reason: "reassessment_required",
      };
    }

    if (chemicalExpired) {
      return {
        allowed: true,
        instructionsApplicable: false,
        chemicalExpired: true,
        reason: "chemical_revalidation_required",
      };
    }

    return {
      allowed: true,
      instructionsApplicable: true,
      chemicalExpired: false,
    };
  }

  /**
   * Basic care schedule is eligible when the plant has an enabled membership AND
   * either the owner has verified paid access OR the membership occupies Free slot 1..3.
   * Authoritative INSERT enforcement remains in SQL (T018 can_owner_schedule_rule).
   */
  static canScheduleBasicCare(
    entitlement: EntitlementSnapshot,
    membership: BasicCareMembershipSnapshot | null,
    now: Date = new Date(),
  ): boolean {
    if (entitlement.accountState !== "active" || !membership) {
      return false;
    }
    if (
      membership.ownerId !== entitlement.ownerId ||
      !membership.enabled ||
      membership.deletedAt !== null
    ) {
      return false;
    }
    if (EntitlementGate.hasVerifiedPaidAccess(entitlement, now)) {
      return true;
    }
    return (
      typeof membership.freeSlot === "number" &&
      membership.freeSlot >= 1 &&
      membership.freeSlot <= 3
    );
  }

  /**
   * First-aid control task is eligible once per (owner, plant, originAnalysisId) without requiring
   * paid access or a Free slot, provided the first action was recorded and the protocol defines a control interval.
   */
  static canScheduleFirstAidControl(
    entitlement: EntitlementSnapshot,
    followup: FirstAidFollowupSnapshot | null,
  ): boolean {
    if (entitlement.accountState !== "active" || !followup) {
      return false;
    }
    if (
      followup.ownerId !== entitlement.ownerId ||
      followup.deletedAt !== null ||
      followup.state !== "active"
    ) {
      return false;
    }
    return (
      Boolean(followup.firstActionEntryId) &&
      typeof followup.controlIntervalDays === "number" &&
      followup.controlIntervalDays > 0
    );
  }
}
