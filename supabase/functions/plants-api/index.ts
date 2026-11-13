// supabase/functions/plants-api/index.ts
// T019: Main Edge Function router for Narat plants-api per contracts/api.md.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import {
  ApiHttpError,
  CORS_HEADERS,
  errorResponse,
  extractBearerToken,
  jsonResponse,
  matchesSecret,
  RequestContext,
  requireActiveOwner,
  requireUuid,
  resolveLocale,
} from "../_shared/http.ts";
import {
  handleInstallationBind,
  handleInstallationRegister,
  InstallationsStoreAdapter,
} from "./installations.ts";
import {
  AnalysisAccessQueryAdapter,
  createAnalysisAccessQueryAdapter,
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
import { runPlantDataPurge, runPlantPurgePage, runPlantStoragePurge } from "../maintenance/plant-deletions.ts";
import { createDiagnosisWorker } from "../analysis-worker/index.ts";
import { createGuestPhotoApi } from "./guest-photo.ts";
import { createDiagnosisJobs } from "./diagnosis-jobs.ts";
import { createDiagnosisMedia } from "./diagnosis-media.ts";
import { handleGetSync } from "./collection.ts";
import { handleCollectionCommand } from "./care-journal.ts";
import { handleCareRecommendation } from "./care-recommendation.ts";
import { handlePublishedCatalogue } from "./catalogue.ts";

// The default resolver still authenticates through Supabase; tests can supply
// a real client with a mocked transport without reading credentials or using the network.
export type AuthClientFactory = (token: string) => SupabaseClient | null;

export interface PlantsApiDependencies {
  resolveRequestContext?: (req: Request) => Promise<RequestContext>;
  authClientFactory?: AuthClientFactory;
  installationsAdapter?: InstallationsStoreAdapter;
  analysisAccessAdapter?: AnalysisAccessQueryAdapter;
  mediaAdapter?: MediaStorageAdapter;
  diagnosisMedia?: ReturnType<typeof createDiagnosisMedia>;
  analysisJobAdapter?: AnalysisJobStoreAdapter;
  diagnosisJobs?: ReturnType<typeof createDiagnosisJobs>;
  guestPhoto?: ReturnType<typeof createGuestPhotoApi>;
  handlePlantPurge?: (
    req: Request, id: string | null, phase: "storage" | "data" | "sweep",
  ) => Promise<Response>;
  handleGuestPhotoMaintenance?: (req: Request) => Promise<Response>;
  handleSync?: (req: Request, ctx: RequestContext, url: URL) => Promise<Response>;
  handleCommand?: (req: Request, ctx: RequestContext) => Promise<Response>;
  handleCareRecommendation?: (req: Request, ctx: RequestContext, plantId: string) => Promise<Response>;
  handleCatalogue?: (req: Request, locale: RequestContext["locale"], identifier?: string) => Promise<Response>;
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

function privateResponse(response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set("Cache-Control", "private, no-store");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export function createPlantsApiHandler(deps: PlantsApiDependencies = {}) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") {
      return new Response("ok", { headers: CORS_HEADERS });
    }

    const locale = resolveLocale(req);
    const url = new URL(req.url);
    const normalizedPath = url.pathname
      .replace(/^\/functions\/v1\/plants-api/, "")
      .replace(/^\/plants-api/, "") || "/";
    const careMatch = req.method === "GET"
      ? normalizedPath.match(/^\/plants\/([^/]+)\/care\/recommendation$/)
      : null;
    const photoMatch = req.method === "GET"
      ? normalizedPath.match(/^\/plants\/([^/]+)\/photo$/)
      : null;
    const observationPhotoMatch = req.method === "GET"
      ? normalizedPath.match(/^\/care\/observations\/([^/]+)\/photo$/)
      : null;
    const firstAidMedia = normalizedPath.startsWith("/media/first-aid/");
    const guestRoute = /^\/(drafts|claims)(?:\/|$)/.test(normalizedPath);
    const purgeMatch = req.method === "POST"
      ? normalizedPath.match(/^\/internal\/plant-deletions\/([^/]+)\/(storage|data)$/)
      : null;
    const purgeSweep = req.method === "POST" &&
      normalizedPath === "/internal/plant-deletions/sweep";
    try {
      if (purgeSweep && deps.handlePlantPurge) {
        return privateResponse(await deps.handlePlantPurge(req, null, "sweep"));
      }
      if (purgeMatch && deps.handlePlantPurge) {
        const phase = purgeMatch[2] === "storage" ? "storage" : "data";
        return privateResponse(await deps.handlePlantPurge(req, purgeMatch[1], phase));
      }
      if (req.method === "POST" && normalizedPath === "/internal/guest-drafts/cleanup" &&
        deps.handleGuestPhotoMaintenance) {
        return privateResponse(await deps.handleGuestPhotoMaintenance(req));
      }
      if (req.method === "GET" && normalizedPath === "/health") {
        return jsonResponse({ status: "ok", version: "3.0.0", locale }, 200);
      }

      if (req.method === "GET" && deps.handleCatalogue) {
        const catalogue = normalizedPath.match(/^\/catalogue(?:\/([^/]+))?$/);
        if (catalogue) return await deps.handleCatalogue(req, locale, catalogue[1]);
      }

      const ctx = deps.resolveRequestContext
        ? await deps.resolveRequestContext(req)
        : await defaultResolveRequestContext(req, deps.authClientFactory);

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

      if (deps.guestPhoto) {
        const guest = deps.guestPhoto;
        if (req.method === "POST" && normalizedPath === "/installations/register") {
          return privateResponse(await guest.registerInstallation(ctx));
        }
        if (req.method === "POST" && normalizedPath === "/installations/bind") {
          return privateResponse(await guest.bindInstallation(req, ctx));
        }
        if (req.method === "POST" && normalizedPath === "/drafts") {
          return privateResponse(await guest.draft(req, ctx));
        }
        const draft = normalizedPath.match(/^\/drafts\/([^/]+)$/);
        if (req.method === "DELETE" && draft) return privateResponse(await guest.deleteDraft(ctx, draft[1]));
        if (req.method === "POST" && normalizedPath === "/claims/prepare") {
          return privateResponse(await guest.prepare(req, ctx));
        }
        if (req.method === "POST" && normalizedPath === "/claims/commit") {
          return privateResponse(await guest.commit(req, ctx));
        }
        const claim = normalizedPath.match(/^\/claims\/([^/]+)$/);
        if (req.method === "GET" && claim) return privateResponse(await guest.status(ctx, claim[1]));
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

      if (deps.diagnosisMedia) {
        if (photoMatch) {
          return privateResponse(await deps.diagnosisMedia.plantPhoto(ctx, photoMatch[1]));
        }
        if (observationPhotoMatch) {
          return privateResponse(await deps.diagnosisMedia.observationPhoto(ctx, observationPhotoMatch[1]));
        }
        const mediaScope = firstAidMedia ? "first-aid" : "diagnosis";
        const mediaPath = firstAidMedia ? normalizedPath.replace("/media/first-aid/", "/media/") : normalizedPath;
        if (req.method === "POST" && mediaPath === "/media/upload-ticket") {
          return await deps.diagnosisMedia.ticket(req, ctx, mediaScope);
        }
        if (req.method === "POST" && mediaPath === "/media/complete") {
          return await deps.diagnosisMedia.complete(req, ctx, mediaScope);
        }
        const upload = mediaPath.match(/^\/media\/uploads\/([^/]+)$/);
        if (req.method === "PUT" && upload) {
          return await deps.diagnosisMedia.upload(req, ctx, upload[1], mediaScope);
        }
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

      if (deps.diagnosisJobs) {
        if (req.method === "POST" && normalizedPath === "/analysis/jobs") {
          return await deps.diagnosisJobs.create(req, ctx);
        }
        if (req.method === "GET" && jobMatch) {
          return await deps.diagnosisJobs.status(ctx, jobMatch[1]);
        }
      }

      if (careMatch && deps.handleCareRecommendation) {
        return privateResponse(await deps.handleCareRecommendation(req, ctx, careMatch[1]));
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
      const response = errorResponse(err, locale);
      return careMatch || photoMatch || observationPhotoMatch || firstAidMedia || guestRoute || purgeMatch || purgeSweep
        ? privateResponse(response)
        : response;
    }
  };
}

export interface ProductionSyncOptions {
  env?: (name: string) => string | undefined;
  fetch?: typeof fetch;
  diagnosisWorker?: Parameters<typeof createDiagnosisJobs>[1];
  scheduleDiagnosis?: Parameters<typeof createDiagnosisJobs>[2];
}

function defaultServiceSecret(value: string | undefined): string | undefined {
  if (!value) return undefined;
  try {
    const key: unknown = JSON.parse(value)?.default;
    if (typeof key === "string" && key.startsWith("sb_secret_") && key.length > "sb_secret_".length) {
      return key;
    }
  } catch {
    // A missing or malformed secret configuration leaves legacy authentication available.
  }
  return undefined;
}

// Keep the bare handler's T152 fallback. Only the deployed composition enables
// sync and collection commands, and explicit delegates still take precedence.
export function createProductionPlantsApiHandler(
  deps: PlantsApiDependencies = {},
  options: ProductionSyncOptions = {},
) {
  const env = options.env ?? ((name: string) => Deno.env.get(name));
  const apiClient = (keyName: "SUPABASE_SERVICE_ROLE_KEY" | "SUPABASE_ANON_KEY"): SupabaseClient | null => {
    const url = env("SUPABASE_URL")?.trim();
    const key = env(keyName)?.trim();
    if (!url || !key) return null;
    return createClient(url, key, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      global: { fetch: options.fetch },
    });
  };
  const syncClient = () => apiClient("SUPABASE_SERVICE_ROLE_KEY");
  const catalogueClient = () => apiClient("SUPABASE_ANON_KEY");
  const diagnosisMedia = deps.diagnosisMedia ?? createDiagnosisMedia(syncClient, env);
  const guestPhoto = deps.guestPhoto ?? createGuestPhotoApi(syncClient, diagnosisMedia.copyPhotoForClaim);
  return createPlantsApiHandler({
    ...deps,
    diagnosisMedia,
    guestPhoto,
    handlePlantPurge: deps.handlePlantPurge ?? (async (req, id, phase) => {
      const legacyKey = env("SUPABASE_SERVICE_ROLE_KEY")?.trim();
      const secretKey = defaultServiceSecret(env("SUPABASE_SECRET_KEYS"));
      if (
        !matchesSecret(legacyKey && `Bearer ${legacyKey}`, req.headers.get("authorization")) &&
        !matchesSecret(secretKey, req.headers.get("apikey"))
      ) {
        throw new ApiHttpError(401, "UNAUTHORIZED", "Unauthorized.");
      }
      const query = new URL(req.url).searchParams;
      if (phase === "sweep" && query.size > 0 && (query.size !== 1 || !query.has("after"))) {
        throw new ApiHttpError(400, "VALIDATION_ERROR", "Invalid deletion queue cursor.");
      }
      const after = phase === "sweep" && query.has("after")
        ? requireUuid(query.get("after"), "after")
        : null;
      const jobId = phase === "sweep" ? null : requireUuid(id, "deletion_job_id");
      const admin = syncClient();
      if (admin) {
        if (jobId === null) {
          const page = await runPlantPurgePage(admin, after).catch(() => null);
          if (page) return jsonResponse(page);
        } else {
          const runPurge = phase === "storage" ? runPlantStoragePurge : runPlantDataPurge;
          const result = await runPurge(admin, jobId).catch(() => undefined);
          if (result === null || result?.state === "not_found") {
            throw new ApiHttpError(404, "NOT_FOUND", "Plant deletion job not found.");
          }
          if (result) return jsonResponse(result);
        }
      }
      throw new ApiHttpError(503, "INTERNAL_ERROR", "Plant cleanup is temporarily unavailable.", true);
    }),
    handleGuestPhotoMaintenance: deps.handleGuestPhotoMaintenance ??
      ((req) => guestPhoto.maintenance(
        req, env("SUPABASE_SERVICE_ROLE_KEY")?.trim(), defaultServiceSecret(env("SUPABASE_SECRET_KEYS")),
      )),
    diagnosisJobs: deps.diagnosisJobs ?? createDiagnosisJobs(
      syncClient, options.diagnosisWorker ?? createDiagnosisWorker(env, { fetch: options.fetch }),
      options.scheduleDiagnosis,
    ),
    analysisAccessAdapter: deps.analysisAccessAdapter ?? createAnalysisAccessQueryAdapter(syncClient),
    handleSync: deps.handleSync ??
      ((req, ctx, url) => handleGetSync(req, ctx, url, syncClient)),
    handleCommand: deps.handleCommand ??
      ((req, ctx) => handleCollectionCommand(req, ctx, syncClient)),
    handleCareRecommendation: deps.handleCareRecommendation ??
      ((req, ctx, plantId) => handleCareRecommendation(req, ctx, plantId, syncClient)),
    handleCatalogue: deps.handleCatalogue ??
      ((req, locale, identifier) => handlePublishedCatalogue(req, locale, catalogueClient, identifier)),
  });
}

if (import.meta.main) {
  Deno.serve(createProductionPlantsApiHandler());
}
