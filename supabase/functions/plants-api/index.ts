// supabase/functions/plants-api/index.ts
// T019: Main Edge Function router for Narat plants-api per contracts/api.md.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import {
  ApiHttpError,
  CORS_HEADERS,
  errorResponse,
  extractBearerToken,
  jsonResponse,
  RequestContext,
  requireActiveOwner,
  resolveLocale,
} from "../_shared/http.ts";
import {
  handleNotificationClaim,
  NotificationClaimResponse,
  NotificationClaimRpcAdapter,
} from "./notifications.ts";
import {
  handleInstallationBind,
  handleInstallationRegister,
  InstallationsStoreAdapter,
} from "./installations.ts";
import {
  AnalysisAccessQueryAdapter,
  handleGetAnalysisAccess,
} from "./analysis-access.ts";
import {
  handleMediaUploadTicket,
  MediaStorageAdapter,
} from "./media.ts";
import {
  AnalysisJobStoreAdapter,
  handleCreateAnalysisJob,
  handleGetAnalysisJob,
} from "./analysis.ts";

// The default resolver still authenticates through Supabase; tests can supply
// a real client with a mocked transport without reading credentials or using the network.
export type AuthClientFactory = (token: string) => SupabaseClient | null;

export interface PlantsApiDependencies {
  resolveRequestContext?: (req: Request) => Promise<RequestContext>;
  authClientFactory?: AuthClientFactory;
  notificationAdapter?: NotificationClaimRpcAdapter;
  installationsAdapter?: InstallationsStoreAdapter;
  analysisAccessAdapter?: AnalysisAccessQueryAdapter;
  mediaAdapter?: MediaStorageAdapter;
  analysisJobAdapter?: AnalysisJobStoreAdapter;
  handleSync?: (req: Request, ctx: RequestContext, url: URL) => Promise<Response>;
  handleCommand?: (req: Request, ctx: RequestContext) => Promise<Response>;
}

function createSupabaseAuthClient(token: string): SupabaseClient | null {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  if (!supabaseUrl || !supabaseAnonKey) return null;

  return createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

async function defaultResolveRequestContext(
  req: Request,
  authClientFactory: AuthClientFactory = createSupabaseAuthClient,
): Promise<RequestContext> {
  const locale = resolveLocale(req);
  const installationCredential =
    req.headers.get("x-installation-credential")?.trim() ?? null;
  const operationId = req.headers.get("x-operation-id")?.trim() ?? null;
  const token = extractBearerToken(req);

  const client = token && !/\s/.test(token) ? authClientFactory(token) : null;

  if (!client || !token) {
    return {
      ownerId: null,
      isAnonymous: true,
      accountState: null,
      installationCredential,
      locale,
      operationId,
    };
  }

  const { data: userData, error: userErr } = await client.auth.getUser(token);
  if (userErr || !userData?.user?.id) {
    throw new ApiHttpError(
      401,
      "UNAUTHORIZED",
      locale === "pl"
        ? "Nieprawidłowy lub wygasły token sesji."
        : "Invalid or expired session token.",
    );
  }

  const userId = userData.user.id;
  let profile;
  try {
    const result = await client
      .from("profiles")
      .select("account_state, anonymous")
      .eq("id", userId)
      .maybeSingle();
    if (result.error) throw new Error("Profile lookup failed.");
    profile = result.data;
  } catch {
    throw new ApiHttpError(
      503,
      "INTERNAL_ERROR",
      locale === "pl"
        ? "Weryfikacja konta jest tymczasowo niedostępna. Spróbuj ponownie później."
        : "Account verification is temporarily unavailable. Please try again later.",
      true,
    );
  }

  if (
    !profile || profile.account_state !== "active" ||
    typeof profile.anonymous !== "boolean"
  ) {
    throw new ApiHttpError(
      403,
      "FORBIDDEN",
      locale === "pl"
        ? "Konto jest w trakcie usuwania lub niedostępne."
        : "Account is deleting or unavailable.",
    );
  }

  return {
    ownerId: userId,
    isAnonymous: profile.anonymous,
    accountState: "active",
    installationCredential,
    locale,
    operationId,
  };
}

function createSupabaseNotificationAdapter(): NotificationClaimRpcAdapter {
  return {
    async claimSlot(params): Promise<NotificationClaimResponse> {
      const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
      const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
      const client = createClient(supabaseUrl, serviceRoleKey || "", {
        auth: { persistSession: false, autoRefreshToken: false },
      });

      const { data, error } = await client.rpc("claim_notification_slot", {
        p_owner_id: params.ownerId,
        p_operation_id: params.operationId,
        p_kind: params.kind,
        p_period_key: params.periodKey,
        p_device_installation_id: params.deviceInstallationId,
      });

      if (error) {
        throw new ApiHttpError(
          400,
          "VALIDATION_ERROR",
          error.message,
        );
      }
      return data as NotificationClaimResponse;
    },
  };
}

export function createPlantsApiHandler(deps: PlantsApiDependencies = {}) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") {
      return new Response("ok", { headers: CORS_HEADERS });
    }

    const locale = resolveLocale(req);
    try {
      const url = new URL(req.url);
      const normalizedPath = url.pathname
        .replace(/^\/functions\/v1\/plants-api/, "")
        .replace(/^\/plants-api/, "") || "/";

      if (req.method === "GET" && normalizedPath === "/health") {
        return jsonResponse({ status: "ok", version: "3.0.0", locale }, 200);
      }

      const ctx = deps.resolveRequestContext
        ? await deps.resolveRequestContext(req)
        : await defaultResolveRequestContext(req, deps.authClientFactory);

      if (req.method === "POST" && normalizedPath === "/notifications/claim") {
        const adapter = deps.notificationAdapter ??
          createSupabaseNotificationAdapter();
        return await handleNotificationClaim(req, ctx, adapter);
      }

      if (
        req.method === "POST" &&
        normalizedPath === "/installations/register" &&
        deps.installationsAdapter
      ) {
        return await handleInstallationRegister(req, ctx, deps.installationsAdapter);
      }

      if (
        req.method === "POST" &&
        normalizedPath === "/installations/bind" &&
        deps.installationsAdapter
      ) {
        return await handleInstallationBind(req, ctx, deps.installationsAdapter);
      }

      if (
        req.method === "GET" &&
        normalizedPath === "/analysis/access" &&
        deps.analysisAccessAdapter
      ) {
        return await handleGetAnalysisAccess(req, ctx, deps.analysisAccessAdapter);
      }

      if (
        req.method === "POST" &&
        normalizedPath === "/media/upload-ticket" &&
        deps.mediaAdapter
      ) {
        return await handleMediaUploadTicket(req, ctx, deps.mediaAdapter);
      }

      if (
        req.method === "POST" &&
        normalizedPath === "/analysis/jobs" &&
        deps.analysisJobAdapter
      ) {
        return await handleCreateAnalysisJob(req, ctx, deps.analysisJobAdapter);
      }

      const jobMatch = normalizedPath.match(/^\/analysis\/jobs\/([^/]+)$/);
      if (req.method === "GET" && jobMatch && deps.analysisJobAdapter) {
        return await handleGetAnalysisJob(
          req,
          ctx,
          jobMatch[1],
          deps.analysisJobAdapter,
        );
      }

      if (req.method === "GET" && normalizedPath === "/sync") {
        requireActiveOwner(ctx);
        if (deps.handleSync) {
          return await deps.handleSync(req, ctx, url);
        }
        throw new ApiHttpError(
          503,
          "INTERNAL_ERROR",
          locale === "pl"
            ? "Synchronizacja jest tymczasowo niedostępna. Spróbuj ponownie później."
            : "Synchronization is temporarily unavailable. Please try again later.",
          true,
        );
      }

      if (req.method === "POST" && normalizedPath === "/commands") {
        requireActiveOwner(ctx);
        if (deps.handleCommand) {
          return await deps.handleCommand(req, ctx);
        }
        throw new ApiHttpError(
          503,
          "INTERNAL_ERROR",
          locale === "pl"
            ? "Zapisywanie jest tymczasowo niedostępne. Spróbuj ponownie później."
            : "Saving is temporarily unavailable. Please try again later.",
          true,
        );
      }

      throw new ApiHttpError(
        404,
        "NOT_FOUND",
        locale === "pl"
          ? `Nie znaleziono zasobu: ${req.method} ${normalizedPath}`
          : `Route not found: ${req.method} ${normalizedPath}`,
      );
    } catch (err) {
      return errorResponse(err, locale);
    }
  };
}

if (import.meta.main) {
  Deno.serve(createPlantsApiHandler());
}
