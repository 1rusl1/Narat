// supabase/functions/plants-api/installations.ts
// T030: POST /installations/register and POST /installations/bind endpoints.

import {
  ApiHttpError,
  jsonResponse,
  RequestContext,
  requireActiveOwner,
  requireUuid,
} from "../_shared/http.ts";
import {
  hashInstallationCredential,
  StarterLedgerState,
} from "../_shared/AnalysisAccess.ts";

export interface InstallationsStoreAdapter {
  registerOrFetchInstallation(params: {
    credentialHash: string;
    boundOwnerId: string | null;
  }): Promise<{
    installationId: string;
    starter: StarterLedgerState;
  }>;

  bindInstallationToOwner(params: {
    installationId: string;
    ownerId: string;
  }): Promise<StarterLedgerState>;
}

export async function handleInstallationRegister(
  req: Request,
  ctx: RequestContext,
  adapter: InstallationsStoreAdapter,
): Promise<Response> {
  const credential = ctx.installationCredential;
  if (!credential || credential.length < 16) {
    throw new ApiHttpError(
      400,
      "VALIDATION_ERROR",
      ctx.locale === "pl"
        ? "Brak lub nieprawidłowy identyfikator instalacji (X-Installation-Credential)."
        : "Missing or invalid X-Installation-Credential header.",
    );
  }

  const credentialHash = await hashInstallationCredential(credential);
  const result = await adapter.registerOrFetchInstallation({
    credentialHash,
    boundOwnerId: ctx.ownerId && !ctx.isAnonymous ? ctx.ownerId : null,
  });

  return jsonResponse({
    installation_id: result.installationId,
    starter: {
      identification_remaining:
        result.starter.starterIdentificationConsumed ||
          result.starter.starterIdentificationJobId
          ? 0
          : 1,
      diagnosis_remaining:
        result.starter.starterDiagnosisConsumed ||
          result.starter.starterDiagnosisJobId
          ? 0
          : 1,
      identification_in_progress_job_id:
        result.starter.starterIdentificationJobId,
      diagnosis_in_progress_job_id:
        result.starter.starterDiagnosisJobId,
      first_starter_success_at: result.starter.firstStarterSuccessAt,
    },
  });
}

export async function handleInstallationBind(
  req: Request,
  ctx: RequestContext,
  adapter: InstallationsStoreAdapter,
): Promise<Response> {
  const ownerId = requireActiveOwner(ctx);
  if (ctx.isAnonymous) {
    throw new ApiHttpError(
      403,
      "FORBIDDEN",
      "Anonymous session cannot bind installation to permanent account.",
    );
  }

  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object") {
    throw new ApiHttpError(400, "VALIDATION_ERROR", "Invalid JSON body.");
  }
  const obj = body as Record<string, unknown>;
  const installationId = requireUuid(obj.installation_id, "installation_id");

  const merged = await adapter.bindInstallationToOwner({
    installationId,
    ownerId,
  });

  return jsonResponse({
    bound: true,
    owner_id: ownerId,
    installation_id: installationId,
    starter: {
      identification_remaining:
        merged.starterIdentificationConsumed ||
          merged.starterIdentificationJobId
          ? 0
          : 1,
      diagnosis_remaining:
        merged.starterDiagnosisConsumed ||
          merged.starterDiagnosisJobId
          ? 0
          : 1,
      identification_in_progress_job_id: merged.starterIdentificationJobId,
      diagnosis_in_progress_job_id: merged.starterDiagnosisJobId,
      first_starter_success_at: merged.firstStarterSuccessAt,
    },
  });
}
