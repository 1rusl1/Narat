// supabase/functions/plants-api/index.ts
// T019: Main Edge Function router for Narat plants-api per contracts/api.md.

import { createClient } from "@supabase/supabase-js";
import {
  ApiHttpError,
  CORS_HEADERS,
  errorResponse,
  extractBearerToken,
  jsonResponse,
  RequestContext,
  requireActiveOwner,
  requireUuid,
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

export interface PlantsApiDependencies {
  resolveRequestContext?: (req: Request) => Promise<RequestContext>;
  notificationAdapter?: NotificationClaimRpcAdapter;
  installationsAdapter?: InstallationsStoreAdapter;
  analysisAccessAdapter?: AnalysisAccessQueryAdapter;
  mediaAdapter?: MediaStorageAdapter;
  analysisJobAdapter?: AnalysisJobStoreAdapter;
  handleSync?: (req: Request, ctx: RequestContext, url: URL) => Promise<Response>;
  handleCommand?: (req: Request, ctx: RequestContext) => Promise<Response>;
}

async function defaultResolveRequestContext(req: Request): Promise<RequestContext> {
  const locale = resolveLocale(req);
  const installationCredential =
    req.headers.get("x-installation-credential")?.trim() ?? null;
  const operationId = req.headers.get("x-operation-id")?.trim() ?? null;
  const token = extractBearerToken(req);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

  if (!token || !supabaseUrl || !supabaseAnonKey) {
    return {
      ownerId: null,
      isAnonymous: true,
      accountState: null,
      installationCredential,
      locale,
      operationId,
    };
  }

  const client = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userData, error: userErr } = await client.auth.getUser(token);
  if (userErr || !userData?.user) {
    throw new ApiHttpError(
      401,
      "UNAUTHORIZED",
      locale === "pl"
        ? "Nieprawidłowy lub wygasły token sesji."
        : "Invalid or expired session token.",
    );
  }

  const userId = userData.user.id;
  const isAnonymous = Boolean(userData.user.is_anonymous);

  const { data: profile } = await client
    .from("profiles")
    .select("account_state, anonymous")
    .eq("id", userId)
    .maybeSingle();

  const accountState =
    (profile?.account_state as "active" | "deleting" | "deleted" | undefined) ??
    "active";

  return {
    ownerId: userId,
    isAnonymous: profile?.anonymous ?? isAnonymous,
    accountState,
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
        : await defaultResolveRequestContext(req);

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
        const ownerId = requireActiveOwner(ctx);
        if (deps.handleSync) {
          return await deps.handleSync(req, ctx, url);
        }
        const limitParam = Number(url.searchParams.get("limit") ?? "200");
        const limit = Number.isFinite(limitParam)
          ? Math.max(1, Math.min(500, limitParam))
          : 200;
        return jsonResponse({
          owner_id: ownerId,
          items: [],
          has_more: false,
          next_cursor: null,
          server_watermark: new Date().toISOString(),
          limit,
        });
      }

      if (req.method === "POST" && normalizedPath === "/commands") {
        requireActiveOwner(ctx);
        if (deps.handleCommand) {
          return await deps.handleCommand(req, ctx);
        }
        const body = await req.json().catch(() => null);
        if (!body || typeof body !== "object") {
          throw new ApiHttpError(400, "VALIDATION_ERROR", "Invalid JSON body.");
        }
        const obj = body as Record<string, unknown>;
        const operationId = requireUuid(obj.operation_id, "operation_id");
        return jsonResponse({
          status: "committed",
          operation_id: operationId,
          replayed: false,
        });
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
