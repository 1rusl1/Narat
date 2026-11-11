import type { SupabaseClient } from "@supabase/supabase-js";
import {
  ApiHttpError,
  jsonResponse,
  type RequestContext,
  requireActiveOwner,
  requireUuid,
} from "../_shared/http.ts";
import {
  handleMediaUploadTicket,
  MAX_NORMALIZED_PHOTO_BYTES,
  UPLOAD_TICKET_TTL_SECONDS,
} from "./media.ts";

export const DIAGNOSIS_PHOTO_BUCKET = "analysis-inputs";

interface Upload {
  photo_asset_id: string;
  owner_id: string;
  storage_path: string;
  mime_type: string;
  byte_size: number;
  content_sha256: string;
  expires_in_seconds: number;
  state: "initialized" | "ready";
}

const hex = (bytes: ArrayBuffer) =>
  Array.from(new Uint8Array(bytes), (n) => n.toString(16).padStart(2, "0"))
    .join("");

function unavailable(ctx: RequestContext) {
  return new ApiHttpError(
    503,
    "INTERNAL_ERROR",
    ctx.locale === "pl"
      ? "Przesyłanie zdjęć jest tymczasowo niedostępne."
      : "Photo upload is temporarily unavailable.",
    true,
  );
}

function badPhoto(ctx: RequestContext) {
  return new ApiHttpError(
    400,
    "VALIDATION_ERROR",
    ctx.locale === "pl" ? "Nieprawidłowe dane zdjęcia." : "Invalid photo data.",
  );
}

function notFound(ctx: RequestContext) {
  return new ApiHttpError(
    404,
    "NOT_FOUND",
    ctx.locale === "pl" ? "Nie znaleziono zdjęcia." : "Photo not found.",
  );
}

function incomplete(ctx: RequestContext) {
  return new ApiHttpError(
    409,
    "CONFLICT",
    ctx.locale === "pl"
      ? "Przesyłanie zdjęcia nie zostało ukończone."
      : "Photo upload is incomplete.",
    true,
  );
}

function parseUpload(
  value: unknown,
  owner: string,
  ctx: RequestContext,
): Upload {
  if (value === null) throw notFound(ctx);
  if (!value || typeof value !== "object") throw unavailable(ctx);
  const upload = value as Upload;
  if (
    upload.owner_id !== owner || typeof upload.photo_asset_id !== "string" ||
    upload.storage_path !== `${owner}/${upload.photo_asset_id}` ||
    !/^[a-f0-9]{64}$/.test(upload.content_sha256) ||
    !["image/jpeg", "image/png", "image/webp"].includes(upload.mime_type) ||
    !Number.isInteger(upload.byte_size) || upload.byte_size < 1 ||
    upload.byte_size > MAX_NORMALIZED_PHOTO_BYTES ||
    !Number.isInteger(upload.expires_in_seconds) ||
    upload.expires_in_seconds < 0 ||
    !["initialized", "ready"].includes(upload.state)
  ) {
    throw unavailable(ctx);
  }
  return upload;
}

async function ticketSignature(
  key: string,
  owner: string,
  asset: string,
): Promise<string> {
  const encoder = new TextEncoder();
  const signingKey = await crypto.subtle.importKey(
    "raw",
    encoder.encode(key),
    {
      name: "HMAC",
      hash: "SHA-256",
    },
    false,
    ["sign"],
  );
  return hex(
    await crypto.subtle.sign(
      "HMAC",
      signingKey,
      encoder.encode(`diagnosis-upload-v1:${owner}:${asset}`),
    ),
  );
}

function equalSignature(expected: string, supplied: string | null): boolean {
  if (!supplied || supplied.length !== expected.length) return false;
  let difference = 0;
  for (let i = 0; i < expected.length; i++) {
    difference |= expected.charCodeAt(i) ^ supplied.charCodeAt(i);
  }
  return difference === 0;
}

async function readBytes(
  stream: ReadableStream<Uint8Array> | null,
  size: number,
  ctx: RequestContext,
) {
  if (!stream) throw badPhoto(ctx);
  const output = new Uint8Array(size);
  const reader = stream.getReader();
  let offset = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (offset + value.length > size) {
        await reader.cancel();
        throw badPhoto(ctx);
      }
      output.set(value, offset);
      offset += value.length;
    }
  } finally {
    reader.releaseLock();
  }
  if (offset !== size) throw badPhoto(ctx);
  return output;
}

function hasImageSignature(bytes: Uint8Array, mime: string): boolean {
  const starts = (signature: number[], offset = 0) =>
    bytes.length >= offset + signature.length &&
    signature.every((n, i) => bytes[offset + i] === n);
  if (mime === "image/jpeg") return starts([0xff, 0xd8, 0xff]);
  if (mime === "image/png") {
    return starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  }
  return starts([0x52, 0x49, 0x46, 0x46]) &&
    starts([0x57, 0x45, 0x42, 0x50], 8);
}

async function verifyBytes(
  bytes: Uint8Array<ArrayBuffer>,
  upload: Upload,
  ctx: RequestContext,
) {
  if (
    !hasImageSignature(bytes, upload.mime_type) ||
    hex(await crypto.subtle.digest("SHA-256", bytes)) !== upload.content_sha256
  ) throw badPhoto(ctx);
}

export function createDiagnosisMedia(
  clientFactory: () => SupabaseClient | null,
  env: (name: string) => string | undefined,
) {
  function client(ctx: RequestContext) {
    try {
      const value = clientFactory();
      if (value) return value;
    } catch {
      // The public error never includes SDK/configuration details.
    }
    throw unavailable(ctx);
  }

  async function rpc(
    ctx: RequestContext,
    name: string,
    params: Record<string, unknown>,
  ) {
    let response;
    try {
      response = await client(ctx).rpc(name, params);
    } catch {
      throw unavailable(ctx);
    }
    const { data, error } = response;
    if (error?.code === "42501") {
      throw new ApiHttpError(
        403,
        "FORBIDDEN",
        ctx.locale === "pl"
          ? "Wymagane jest aktywne konto."
          : "An active permanent account is required.",
      );
    }
    if (error?.message === "IDEMPOTENCY_CONFLICT") {
      throw new ApiHttpError(
        409,
        "IDEMPOTENCY_CONFLICT",
        ctx.locale === "pl"
          ? "Identyfikator operacji jest już użyty."
          : "Operation ID is already in use.",
      );
    }
    if (error?.code === "P0002") throw notFound(ctx);
    if (error) throw unavailable(ctx);
    return data;
  }

  function signingKey(ctx: RequestContext) {
    const key = env("SUPABASE_SERVICE_ROLE_KEY")?.trim();
    if (!key) throw unavailable(ctx);
    return key;
  }

  async function load(ctx: RequestContext, owner: string, asset: string) {
    const value = parseUpload(
      await rpc(ctx, "read_diagnosis_upload", {
        p_owner_id: owner,
        p_photo_asset_id: asset,
      }),
      owner,
      ctx,
    );
    if (value.photo_asset_id !== asset) throw unavailable(ctx);
    return value;
  }

  async function markReady(ctx: RequestContext, upload: Upload) {
    const value = parseUpload(
      await rpc(ctx, "mark_diagnosis_upload_ready", {
        p_owner_id: upload.owner_id,
        p_photo_asset_id: upload.photo_asset_id,
        p_content_sha256: upload.content_sha256,
      }),
      upload.owner_id,
      ctx,
    );
    if (
      value.photo_asset_id !== upload.photo_asset_id || value.state !== "ready"
    ) throw unavailable(ctx);
    return jsonResponse({
      photo_asset_id: value.photo_asset_id,
      state: value.state,
    });
  }

  async function confirmStored(ctx: RequestContext, upload: Upload) {
    if (upload.state === "ready") {
      return jsonResponse({
        photo_asset_id: upload.photo_asset_id,
        state: "ready",
      });
    }
    const bucket = client(ctx).storage.from(DIAGNOSIS_PHOTO_BUCKET);
    let response;
    try {
      response = await bucket.download(upload.storage_path);
    } catch {
      throw unavailable(ctx);
    }
    if (response.error || !response.data) throw incomplete(ctx);
    const bytes = await readBytes(
      response.data.stream(),
      upload.byte_size,
      ctx,
    );
    await verifyBytes(bytes, upload, ctx);
    return await markReady(ctx, upload);
  }

  return {
    async ticket(req: Request, ctx: RequestContext) {
      const owner = requireActiveOwner(ctx);
      const key = signingKey(ctx);
      let base: URL;
      try {
        base = new URL(
          env("NARAT_PUBLIC_SUPABASE_URL") ?? env("SUPABASE_URL") ?? "",
        );
        if (
          !["https:", "http:"].includes(base.protocol) || base.username ||
          base.password
        ) throw new Error();
      } catch {
        throw unavailable(ctx);
      }
      return await handleMediaUploadTicket(req, ctx, {
        async createSignedUploadTicket(params) {
          if (
            params.draftId || params.plantId || !params.contentSha256 ||
            !/^[a-f0-9]{64}$/.test(params.contentSha256)
          ) throw badPhoto(ctx);
          const upload = parseUpload(
            await rpc(ctx, "create_diagnosis_upload", {
              p_owner_id: owner,
              p_operation_id: params.operationId,
              p_mime_type: params.mimeType,
              p_byte_size: params.byteSize,
              p_content_sha256: params.contentSha256,
            }),
            owner,
            ctx,
          );
          if (upload.expires_in_seconds === 0 && upload.state !== "ready") {
            throw incomplete(ctx);
          }
          const url = new URL(
            `/functions/v1/plants-api/media/uploads/${upload.photo_asset_id}`,
            base,
          );
          url.searchParams.set(
            "sig",
            await ticketSignature(key, owner, upload.photo_asset_id),
          );
          return {
            photo_asset_id: upload.photo_asset_id,
            storage_bucket: DIAGNOSIS_PHOTO_BUCKET,
            storage_path: upload.storage_path,
            signed_upload_url: url.toString(),
            expires_in_seconds: Math.min(
              UPLOAD_TICKET_TTL_SECONDS,
              upload.expires_in_seconds,
            ),
            max_byte_size: MAX_NORMALIZED_PHOTO_BYTES,
          };
        },
      });
    },
    async upload(req: Request, ctx: RequestContext, id: string) {
      const owner = requireActiveOwner(ctx);
      const asset = requireUuid(id, "photo_asset_id");
      if (
        !equalSignature(
          await ticketSignature(signingKey(ctx), owner, asset),
          new URL(req.url).searchParams.get("sig"),
        )
      ) {
        throw notFound(ctx);
      }
      const upload = await load(ctx, owner, asset);
      if (upload.state === "ready") {
        return jsonResponse({ photo_asset_id: asset, state: "ready" });
      }
      if (upload.expires_in_seconds === 0) throw incomplete(ctx);
      if (req.headers.get("content-type")?.toLowerCase() !== upload.mime_type) {
        throw badPhoto(ctx);
      }
      const bytes = await readBytes(req.body, upload.byte_size, ctx);
      await verifyBytes(bytes, upload, ctx);
      const bucket = client(ctx).storage.from(DIAGNOSIS_PHOTO_BUCKET);
      let response;
      try {
        response = await bucket.upload(upload.storage_path, bytes, {
          contentType: upload.mime_type,
          upsert: false,
        });
      } catch {
        throw unavailable(ctx);
      }
      if (response.error) return await confirmStored(ctx, upload);
      return await markReady(ctx, upload);
    },
    async complete(req: Request, ctx: RequestContext) {
      const owner = requireActiveOwner(ctx);
      const body = await req.json().catch(() => null);
      const asset = requireUuid(body?.photo_asset_id, "photo_asset_id");
      return await confirmStored(ctx, await load(ctx, owner, asset));
    },
  };
}
