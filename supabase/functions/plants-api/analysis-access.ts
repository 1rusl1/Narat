// B2: one authoritative SQL snapshot. No client/calendar quota forecasting.
import { type SupabaseClient } from "@supabase/supabase-js";
import {
  ApiHttpError,
  jsonResponse,
  type RequestContext,
  requireActiveOwner,
} from "../_shared/http.ts";
import {
  hashInstallationCredential,
  parseAnalysisAccessSnapshot,
} from "../_shared/AnalysisAccess.ts";
export interface AnalysisAccessQueryAdapter {
  fetchSnapshot(
    params: { ownerId: string; credentialHash: string | null },
  ): Promise<unknown>;
}
export function quotaAccessError(
  ctx: RequestContext,
  error: unknown,
): ApiHttpError {
  const value = error && typeof error === "object"
    ? error as Record<string, unknown>
    : {};
  if (
    value.code === "42501" &&
    [
      "INSTALLATION_CREDENTIAL_MISMATCH",
      "ACTIVE_OWNER_REQUIRED",
      "ACTIVE_PERMANENT_OWNER_REQUIRED",
    ].includes(value.message as string)
  ) {
    return new ApiHttpError(
      403,
      "FORBIDDEN",
      ctx.locale === "pl"
        ? "Konto lub instalacja nie ma dostępu."
        : "Account or installation access is denied.",
    );
  }
  if (
    value.code === "22023" &&
    ["INSTALLATION_REQUIRED", "INVALID_INSTALLATION_CREDENTIAL"].includes(
      value.message as string,
    )
  ) {
    return new ApiHttpError(
      400,
      "VALIDATION_ERROR",
      ctx.locale === "pl"
        ? "Brak lub nieprawidłowy identyfikator instalacji."
        : "Missing or invalid installation credential.",
    );
  }
  if (
    value.code === "23514" && value.message === "STARTER_RESERVATION_CONFLICT"
  ) {
    return new ApiHttpError(
      409,
      "CONFLICT",
      ctx.locale === "pl"
        ? "Analiza startowa jest już w toku."
        : "A starter analysis is already in progress.",
    );
  }
  return new ApiHttpError(
    503,
    "INTERNAL_ERROR",
    ctx.locale === "pl"
      ? "Dostęp do analiz jest tymczasowo niedostępny. Spróbuj ponownie później."
      : "Analysis access is temporarily unavailable. Please try again later.",
    true,
  );
}
export async function installationCredentialHash(
  ctx: RequestContext,
  required: boolean,
): Promise<string | null> {
  const raw = ctx.installationCredential?.trim();
  if (ctx.installationCredential === null && !required) return null;
  if (!raw || raw.length < 16) {
    throw new ApiHttpError(
      400,
      "VALIDATION_ERROR",
      ctx.locale === "pl"
        ? "Brak lub nieprawidłowy identyfikator instalacji."
        : "Missing or invalid installation credential.",
    );
  }
  return await hashInstallationCredential(raw);
}
export function createAnalysisAccessQueryAdapter(
  clientFactory: () => SupabaseClient | null,
): AnalysisAccessQueryAdapter {
  return {
    async fetchSnapshot(params) {
      const client = clientFactory();
      if (!client) throw new Error("Quota transport unavailable");
      const { data, error } = await client.rpc("get_analysis_access_snapshot", {
        p_owner_id: params.ownerId,
        p_installation_credential_hash: params.credentialHash,
      });
      if (error) throw error;
      return data;
    },
  };
}
export async function handleGetAnalysisAccess(
  _req: Request,
  ctx: RequestContext,
  adapter: AnalysisAccessQueryAdapter,
): Promise<Response> {
  const ownerId = requireActiveOwner(ctx);
  const credentialHash = await installationCredentialHash(ctx, ctx.isAnonymous);
  let raw: unknown;
  try {
    raw = await adapter.fetchSnapshot({ ownerId, credentialHash });
  } catch (error) {
    throw quotaAccessError(ctx, error);
  }
  const snapshot = parseAnalysisAccessSnapshot(raw, ownerId, ctx.isAnonymous);
  if (!snapshot) throw quotaAccessError(ctx, null);
  return jsonResponse(snapshot, 200);
}
