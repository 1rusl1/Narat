import { SupabaseClient } from "@supabase/supabase-js";
import { ApiHttpError, errorResponse, jsonResponse } from "../_shared/http.ts";
import { verifyAnalysisReceipt } from "../_shared/ProtocolResolver.ts";

export interface ClaimOverridesInput {
  species_id?: string | null;
  display_name?: string | null;
  room_id?: string | null;
  create_room_name?: string | null;
  watering_habit?: string | null;
  light_level?: string | null;
  light_source?: "manual_selection" | "camera_estimate" | "unknown" | null;
  light_confirmed?: boolean | null;
  recent_changes?: string | null;
  pot_type?: string | null;
  season_override?: string | null;
}

export interface ClaimPrepareRequest {
  operation_id: string;
  draft_id: string;
  installation_id: string;
  installation_credential: string;
  overrides?: ClaimOverridesInput;
}

export interface ClaimCommitRequest {
  operation_id: string;
  claim_id: string;
  copied_storage_path?: string | null;
  analysis_receipt?: string | null;
}

export async function verifyAnalysisReceiptSignature(
  receiptToken: string,
  secret: string,
): Promise<boolean> {
  const verified = await verifyAnalysisReceipt(receiptToken, secret);
  return verified.valid;
}

export function evaluateClaimStaleTransition(
  originalContext: {
    species_id: string | null;
    watering_habit: string;
    light_level: string;
    recent_changes: string;
    pot_type?: string;
    season_override?: string;
  },
  overrides?: ClaimOverridesInput,
): {
  isStale: boolean;
  careRevision: number;
  contextState: "current" | "stale";
} {
  if (!overrides) {
    return { isStale: false, careRevision: 1, contextState: "current" };
  }

  const speciesChanged =
    overrides.species_id !== undefined &&
    overrides.species_id !== originalContext.species_id;
  const wateringChanged =
    overrides.watering_habit !== undefined &&
    overrides.watering_habit !== null &&
    overrides.watering_habit !== originalContext.watering_habit;
  const lightChanged =
    overrides.light_level !== undefined &&
    overrides.light_level !== null &&
    overrides.light_level !== originalContext.light_level;
  const recentChanged =
    overrides.recent_changes !== undefined &&
    overrides.recent_changes !== null &&
    overrides.recent_changes !== originalContext.recent_changes;
  const potChanged =
    overrides.pot_type !== undefined &&
    overrides.pot_type !== null &&
    overrides.pot_type !== (originalContext.pot_type ?? "unknown");
  const seasonChanged =
    overrides.season_override !== undefined &&
    overrides.season_override !== null &&
    overrides.season_override !== (originalContext.season_override ?? "auto");

  // Room changes alone do NOT make the analysis stale (FR-046 / US2.9)
  const isStale =
    speciesChanged ||
    wateringChanged ||
    lightChanged ||
    recentChanged ||
    potChanged ||
    seasonChanged;

  return {
    isStale,
    careRevision: isStale ? 2 : 1,
    contextState: isStale ? "stale" : "current",
  };
}

export async function handlePrepareClaim(
  req: Request,
  supabaseAdmin: SupabaseClient,
  ownerId: string,
): Promise<Response> {
  const body = (await req.json().catch(() => null)) as ClaimPrepareRequest | null;
  if (
    !body ||
    !body.operation_id ||
    !body.draft_id ||
    !body.installation_id ||
    !body.installation_credential
  ) {
    return errorResponse(
      new ApiHttpError(
        400,
        "VALIDATION_ERROR",
        "operation_id, draft_id, installation_id, and installation_credential are required",
      ),
    );
  }

  const { data, error } = await supabaseAdmin.rpc("prepare_guest_claim", {
    p_owner_id: ownerId,
    p_operation_id: body.operation_id,
    p_draft_id: body.draft_id,
    p_installation_id: body.installation_id,
    p_credential_raw: body.installation_credential,
    p_overrides: body.overrides ?? {},
  });

  if (error) {
    if (error.message.includes("draft_expired_or_missing")) {
      return errorResponse(
        new ApiHttpError(
          410,
          "DRAFT_EXPIRED",
          "Guest draft has expired (24h TTL); use local fallback plant.create",
        ),
      );
    }
    return errorResponse(
      new ApiHttpError(400, "VALIDATION_ERROR", error.message),
    );
  }

  return jsonResponse(data, 200);
}

export async function handleCommitClaim(
  req: Request,
  supabaseAdmin: SupabaseClient,
  ownerId: string,
): Promise<Response> {
  const body = (await req.json().catch(() => null)) as ClaimCommitRequest | null;
  if (!body || !body.operation_id || !body.claim_id) {
    return errorResponse(
      new ApiHttpError(
        400,
        "VALIDATION_ERROR",
        "operation_id and claim_id are required",
      ),
    );
  }

  if (body.analysis_receipt) {
    const secret = Deno.env.get("RECEIPT_SIGNING_SECRET") ?? "dev-receipt-secret";
    const validSig = await verifyAnalysisReceiptSignature(
      body.analysis_receipt,
      secret,
    );
    if (!validSig) {
      return errorResponse(
        new ApiHttpError(
          400,
          "VALIDATION_ERROR",
          "Analysis receipt signature is invalid",
        ),
      );
    }
  }

  const { data, error } = await supabaseAdmin.rpc("commit_guest_claim", {
    p_owner_id: ownerId,
    p_operation_id: body.operation_id,
    p_claim_id: body.claim_id,
    p_copied_storage_path: body.copied_storage_path ?? null,
  });

  if (error) {
    return errorResponse(
      new ApiHttpError(400, "VALIDATION_ERROR", error.message),
    );
  }

  return jsonResponse(data, 200);
}
