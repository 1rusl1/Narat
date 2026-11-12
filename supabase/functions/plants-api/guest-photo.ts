import type { SupabaseClient } from "@supabase/supabase-js";
import {
  ApiHttpError,
  jsonResponse,
  type RequestContext,
  requireActiveOwner,
  requireUuid,
} from "../_shared/http.ts";
import { installationCredentialHash } from "./analysis-access.ts";
import { DIAGNOSIS_PHOTO_BUCKET } from "./diagnosis-media.ts";

const objectKey = /^[a-f0-9-]{36}\/[a-f0-9-]{36}$/;

export function createGuestPhotoApi(
  clientFactory: () => SupabaseClient | null,
  copy: (
    ctx: RequestContext,
    upload: unknown,
    destination: unknown,
  ) => Promise<void>,
) {
  function unavailable() {
    return new ApiHttpError(
      503,
      "INTERNAL_ERROR",
      "The photo transfer is temporarily unavailable.",
      true,
    );
  }

  function client() {
    const result = clientFactory();
    if (!result) throw unavailable();
    return result;
  }

  async function rpc(name: string, args: Record<string, unknown>) {
    let response;
    try {
      response = await client().rpc(name, args);
    } catch {
      throw unavailable();
    }
    const { data, error } = response;
    if (!error) return data;
    if (error.message === "DRAFT_EXPIRED") {
      throw new ApiHttpError(
        410,
        "DRAFT_EXPIRED",
        "This guest draft is no longer available.",
      );
    }
    if (error.message === "IDENTIFICATION_SOURCE_NOT_FOUND") {
      throw new ApiHttpError(
        404,
        "NOT_FOUND",
        "Completed identification not found.",
      );
    }
    if (error.code === "42501") {
      throw new ApiHttpError(
        403,
        "FORBIDDEN",
        "This account or installation cannot perform the operation.",
      );
    }
    if (error.message === "COLLECTION_LIMIT_REACHED") {
      throw new ApiHttpError(
        409,
        "COLLECTION_LIMIT_REACHED",
        "Your collection has reached its plant limit.",
      );
    }
    if (error.message === "CLAIM_PROOF_EXPIRED") {
      throw new ApiHttpError(
        409,
        "CONFLICT",
        "Prepare the claim again to refresh its proof.",
        true,
      );
    }
    if (error.code === "23505") {
      throw new ApiHttpError(
        409,
        "CONFLICT",
        "Operation conflicts with an existing request.",
      );
    }
    if (error.code === "22023" || error.code === "22P02") {
      throw new ApiHttpError(
        400,
        "VALIDATION_ERROR",
        "Invalid guest photo request.",
      );
    }
    throw unavailable();
  }

  async function body(req: Request, keys: string[]) {
    const value = await req.json().catch(() => null);
    if (
      !value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).length !== keys.length ||
      keys.some((key) => !Object.hasOwn(value, key))
    ) {
      throw new ApiHttpError(
        400,
        "VALIDATION_ERROR",
        "Invalid guest photo request.",
      );
    }
    return value as Record<string, unknown>;
  }

  async function identity(ctx: RequestContext) {
    return {
      p_owner_id: requireActiveOwner(ctx),
      p_credential_hash: await installationCredentialHash(ctx, true),
    };
  }

  async function removeStoredPhotos(paths: string[]) {
    const { error } = await client().storage.from(DIAGNOSIS_PHOTO_BUCKET).remove(paths);
    return !error;
  }

  async function cleanup(draftId: string | null) {
    const entries = await rpc("read_guest_photo_cleanup", {
      p_draft_id: draftId,
    });
    if (!Array.isArray(entries)) throw unavailable();
    let cleaned = 0;
    for (const entry of entries) {
      if (
        !entry || typeof entry.source !== "string" ||
        !objectKey.test(entry.source) ||
        (entry.abandoned_target !== null &&
          (typeof entry.abandoned_target !== "string" ||
            !objectKey.test(entry.abandoned_target)))
      ) {
        throw unavailable();
      }
      const paths = [entry.source];
      if (entry.abandoned_target) paths.push(entry.abandoned_target);
      if (!await removeStoredPhotos(paths)) continue;
      if (
        typeof entry.draft_id === "string" && entry.source_photo_id === null
      ) {
        await rpc("finish_guest_photo_cleanup", { p_draft_id: entry.draft_id });
      } else if (
        entry.draft_id === null && typeof entry.source_photo_id === "string"
      ) {
        await rpc("finish_guest_source_cleanup", {
          p_photo_id: entry.source_photo_id,
        });
      } else {
        throw unavailable();
      }
      cleaned++;
    }
    return cleaned;
  }

  async function cleanupFirstAid(photoId: string | null) {
    const entries = await rpc("claim_first_aid_photo_cleanup", { p_photo_id: photoId });
    if (!Array.isArray(entries)) throw unavailable();
    let cleaned = 0;
    for (const entry of entries) {
      if (
        !entry || typeof entry.photo_id !== "string" ||
        (photoId !== null && entry.photo_id !== photoId) ||
        typeof entry.source !== "string" || !objectKey.test(entry.source) ||
        !entry.source.endsWith("/" + entry.photo_id)
      ) throw unavailable();
      if (!await removeStoredPhotos([entry.source])) continue;
      await rpc("finish_first_aid_photo_cleanup", { p_photo_id: entry.photo_id });
      cleaned++;
    }
    return cleaned;
  }

  function scheduleCleanup(draftId: string) {
    const edge =
      (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } })
        .EdgeRuntime;
    const task = cleanup(draftId).catch(() => undefined);
    edge?.waitUntil(task);
  }

  function starter(data: {
    starter_identification_consumed: boolean;
    starter_diagnosis_consumed: boolean;
    starter_identification_job_id: string | null;
    starter_diagnosis_job_id: string | null;
    first_starter_success_at: string | null;
  }) {
    return {
      identification_remaining: data.starter_identification_consumed ||
          data.starter_identification_job_id
        ? 0
        : 1,
      diagnosis_remaining:
        data.starter_diagnosis_consumed || data.starter_diagnosis_job_id
          ? 0
          : 1,
      identification_in_progress_job_id: data.starter_identification_job_id,
      diagnosis_in_progress_job_id: data.starter_diagnosis_job_id,
      first_starter_success_at: data.first_starter_success_at,
    };
  }

  return {
    async registerInstallation(ctx: RequestContext) {
      const data = await rpc(
        "register_installation_access",
        await identity(ctx),
      );
      return jsonResponse({
        installation_id: data.installation_id,
        starter: starter(data),
      });
    },

    async bindInstallation(req: Request, ctx: RequestContext) {
      if (ctx.isAnonymous) {
        throw new ApiHttpError(
          403,
          "FORBIDDEN",
          "An active permanent account is required.",
        );
      }
      const value = await body(req, ["installation_id"]);
      const data = await rpc("bind_installation_credential", {
        ...await identity(ctx),
        p_installation_id: requireUuid(
          value.installation_id,
          "installation_id",
        ),
      });
      return jsonResponse({
        bound: true,
        owner_id: data.owner_id,
        installation_id: data.installation_id,
        starter: starter(data),
      });
    },

    async draft(req: Request, ctx: RequestContext) {
      const who = await identity(ctx);
      const value = await body(req, [
        "operation_id",
        "identification_job_id",
        "taxon_id",
      ]);
      return jsonResponse(
        await rpc("create_guest_photo_draft", {
          ...who,
          p_operation_id: requireUuid(value.operation_id, "operation_id"),
          p_job_id: requireUuid(
            value.identification_job_id,
            "identification_job_id",
          ),
          p_taxon_id: requireUuid(value.taxon_id, "taxon_id"),
        }),
      );
    },

    async deleteDraft(ctx: RequestContext, id: string) {
      const who = await identity(ctx);
      const draftId = requireUuid(id, "draft_id");
      if (
        await rpc("delete_guest_photo_draft", {
          ...who,
          p_draft_id: draftId,
        }) !== true
      ) {
        throw new ApiHttpError(
          410,
          "DRAFT_EXPIRED",
          "This guest draft is no longer available.",
        );
      }
      scheduleCleanup(draftId);
      return new Response(null, { status: 204 });
    },

    async prepare(req: Request, ctx: RequestContext) {
      const who = await identity(ctx);
      const value = await body(req, ["operation_id", "draft_id"]);
      const draftId = requireUuid(value.draft_id, "draft_id");
      try {
        return jsonResponse(
          await rpc("prepare_guest_photo_claim", {
            ...who,
            p_operation_id: requireUuid(value.operation_id, "operation_id"),
            p_draft_id: draftId,
          }),
        );
      } catch (error) {
        if (error instanceof ApiHttpError && error.status === 410) {
          scheduleCleanup(draftId);
        }
        throw error;
      }
    },

    async status(ctx: RequestContext, id: string) {
      const data = await rpc("read_guest_photo_claim", {
        ...await identity(ctx),
        p_claim_id: requireUuid(id, "claim_id"),
      });
      if (!data) {
        throw new ApiHttpError(
          410,
          "DRAFT_EXPIRED",
          "This guest draft is no longer available.",
        );
      }
      return jsonResponse(data);
    },

    async commit(req: Request, ctx: RequestContext) {
      const who = await identity(ctx);
      const value = await body(req, ["operation_id", "claim_id"]);
      const args = {
        ...who,
        p_operation_id: requireUuid(value.operation_id, "operation_id"),
        p_claim_id: requireUuid(value.claim_id, "claim_id"),
      };
      let data = await rpc("process_guest_photo_claim", {
        ...args,
        p_verified_copy: false,
      });
      if (!data?.receipt) {
        try {
          await copy(ctx, data?.upload, data?.destination);
        } catch (error) {
          // Another request may have published and removed the guest source.
          data = await rpc("process_guest_photo_claim", {
            ...args,
            p_verified_copy: false,
          });
          if (!data?.receipt) throw error;
        }
        if (!data?.receipt) {
          data = await rpc("process_guest_photo_claim", {
            ...args,
            p_verified_copy: true,
          });
        }
      }
      if (!data?.receipt) throw unavailable();
      if (typeof data.cleanup_draft_id === "string") {
        scheduleCleanup(data.cleanup_draft_id);
      }
      return jsonResponse(data.receipt);
    },

    async maintenance(req: Request, key: string | undefined) {
      const expected = key ? `Bearer ${key}` : "";
      const auth = req.headers.get("authorization") ?? "";
      if (!expected || auth.length !== expected.length) {
        throw new ApiHttpError(401, "UNAUTHORIZED", "Unauthorized.");
      }
      let difference = 0;
      for (let i = 0; i < expected.length; i++) {
        difference |= auth.charCodeAt(i) ^ expected.charCodeAt(i);
      }
      if (difference) {
        throw new ApiHttpError(401, "UNAUTHORIZED", "Unauthorized.");
      }
      const query = new URL(req.url).searchParams;
      if (query.size === 0) {
        return jsonResponse({ cleaned: await cleanup(null) + await cleanupFirstAid(null) });
      }
      if (query.size !== 1 || !query.has("first_aid_photo_id")) {
        throw new ApiHttpError(400, "VALIDATION_ERROR", "Invalid photo cleanup scope.");
      }
      const photoId = requireUuid(query.get("first_aid_photo_id"), "first_aid_photo_id");
      return jsonResponse({ cleaned: await cleanupFirstAid(photoId) });
    },
  };
}
