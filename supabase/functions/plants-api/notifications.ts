// supabase/functions/plants-api/notifications.ts
// T128: POST /notifications/claim handler with opt-in false by default, (owner, kind, period_key)
// deduplication, verified trial date check, and monthly_report YYYY-MM key without timezone.

import {
  ApiHttpError,
  jsonResponse,
  RequestContext,
  requireActiveOwner,
  requireUuid,
} from "../_shared/http.ts";
import {
  EntitlementGate,
  EntitlementSnapshot,
} from "../_shared/EntitlementGate.ts";

export type NotificationClaimKind = "trial_ending_24h" | "monthly_report";

export interface NotificationClaimRequest {
  operation_id: string;
  kind: NotificationClaimKind;
  period_key: string;
  device_installation_id?: string;
}

export interface NotificationClaimResponse {
  granted: boolean;
  claim_id?: string;
  kind: NotificationClaimKind;
  period_key: string;
  state?: "claimed" | "cancelled";
  scheduled_for?: string;
  reason?:
    | "opt_in_disabled"
    | "no_verified_active_trial"
    | "already_claimed_by_other_device"
    | "already_cancelled_for_period";
}

export interface NotificationClaimRpcAdapter {
  claimSlot(params: {
    ownerId: string;
    operationId: string;
    kind: NotificationClaimKind;
    periodKey: string;
    deviceInstallationId: string;
  }): Promise<NotificationClaimResponse>;
}

const REPORT_MONTH_REGEX = /^\d{4}-(0[1-9]|1[0-2])$/;

export function validateNotificationClaimPayload(
  raw: unknown,
  fallbackInstallationId: string | null,
): {
  operationId: string;
  kind: NotificationClaimKind;
  periodKey: string;
  deviceInstallationId: string;
} {
  if (!raw || typeof raw !== "object") {
    throw new ApiHttpError(
      400,
      "VALIDATION_ERROR",
      "Request body must be a JSON object.",
    );
  }
  const obj = raw as Record<string, unknown>;
  const operationId = requireUuid(obj.operation_id, "operation_id");

  const kind = obj.kind;
  if (kind !== "trial_ending_24h" && kind !== "monthly_report") {
    throw new ApiHttpError(
      400,
      "VALIDATION_ERROR",
      "Field 'kind' must be 'trial_ending_24h' or 'monthly_report'.",
      false,
      { field: "kind" },
    );
  }

  const periodKey = typeof obj.period_key === "string"
    ? obj.period_key.trim()
    : "";
  if (!periodKey) {
    throw new ApiHttpError(
      400,
      "VALIDATION_ERROR",
      "Field 'period_key' is required.",
      false,
      { field: "period_key" },
    );
  }

  if (kind === "monthly_report" && !REPORT_MONTH_REGEX.test(periodKey)) {
    throw new ApiHttpError(
      400,
      "VALIDATION_ERROR",
      "Monthly report 'period_key' must be 'YYYY-MM' without timezone.",
      false,
      { field: "period_key" },
    );
  }

  const deviceInstallationId =
    (typeof obj.device_installation_id === "string" &&
      obj.device_installation_id.trim()) ||
    fallbackInstallationId ||
    "";

  if (!deviceInstallationId) {
    throw new ApiHttpError(
      400,
      "VALIDATION_ERROR",
      "Missing device installation identifier.",
      false,
      { field: "device_installation_id" },
    );
  }

  return {
    operationId,
    kind,
    periodKey,
    deviceInstallationId,
  };
}

export function evaluateTrialNotificationEligibility(
  entitlement: EntitlementSnapshot,
  trialReminderOptIn: boolean,
  now: Date = new Date(),
): { eligible: boolean; scheduledFor?: string; reason?: NotificationClaimResponse["reason"] } {
  if (!trialReminderOptIn) {
    return { eligible: false, reason: "opt_in_disabled" };
  }
  if (
    !EntitlementGate.hasVerifiedPaidAccess(entitlement, now) ||
    entitlement.offerKind !== "trial" ||
    !entitlement.trialEndAt
  ) {
    return { eligible: false, reason: "no_verified_active_trial" };
  }
  const trialEndMs = Date.parse(entitlement.trialEndAt);
  const scheduledFor = new Date(trialEndMs - 24 * 60 * 60 * 1000).toISOString();
  return { eligible: true, scheduledFor };
}

export async function handleNotificationClaim(
  req: Request,
  ctx: RequestContext,
  adapter: NotificationClaimRpcAdapter,
): Promise<Response> {
  const ownerId = requireActiveOwner(ctx);
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    throw new ApiHttpError(
      400,
      "VALIDATION_ERROR",
      "Invalid JSON body.",
    );
  }

  const validated = validateNotificationClaimPayload(
    body,
    ctx.installationCredential,
  );

  const result = await adapter.claimSlot({
    ownerId,
    operationId: validated.operationId,
    kind: validated.kind,
    periodKey: validated.periodKey,
    deviceInstallationId: validated.deviceInstallationId,
  });

  return jsonResponse(result, 200);
}
