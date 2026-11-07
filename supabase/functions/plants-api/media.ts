// supabase/functions/plants-api/media.ts
// T031: POST /media/upload-ticket endpoint validating MIME type, normalized size <= 10 MB,
// and issuing a 60-second signed upload URL.

import {
  ApiHttpError,
  jsonResponse,
  RequestContext,
  requireUuid,
} from "../_shared/http.ts";

export const MAX_NORMALIZED_PHOTO_BYTES = 10 * 1024 * 1024; // 10 MB
export const UPLOAD_TICKET_TTL_SECONDS = 60;
const ALLOWED_MIME_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);

export interface UploadTicketRequest {
  operation_id: string;
  mime_type: string;
  byte_size: number;
  width_px?: number;
  height_px?: number;
  draft_id?: string;
  plant_id?: string;
  capture_at?: string | null;
}

export interface UploadTicketResponse {
  photo_asset_id: string;
  storage_bucket: string;
  storage_path: string;
  signed_upload_url: string;
  expires_in_seconds: number;
  max_byte_size: number;
}

export interface MediaStorageAdapter {
  createSignedUploadTicket(params: {
    ownerId: string | null;
    draftId: string | null;
    plantId: string | null;
    mimeType: string;
    byteSize: number;
    captureAt: string | null;
    ttlSeconds: number;
  }): Promise<UploadTicketResponse>;
}

export async function handleMediaUploadTicket(
  req: Request,
  ctx: RequestContext,
  adapter: MediaStorageAdapter,
): Promise<Response> {
  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object") {
    throw new ApiHttpError(400, "VALIDATION_ERROR", "Invalid JSON body.");
  }

  const obj = body as Record<string, unknown>;
  requireUuid(obj.operation_id, "operation_id");

  const mimeType = typeof obj.mime_type === "string"
    ? obj.mime_type.trim().toLowerCase()
    : "";
  if (!ALLOWED_MIME_TYPES.has(mimeType)) {
    throw new ApiHttpError(
      400,
      "VALIDATION_ERROR",
      ctx.locale === "pl"
        ? "Nieobsługiwany format obrazu. Dozwolone: JPEG, PNG, WebP."
        : "Unsupported image format. Allowed: JPEG, PNG, WebP.",
      false,
      { field: "mime_type" },
    );
  }

  const byteSize = typeof obj.byte_size === "number" ? obj.byte_size : NaN;
  if (
    !Number.isFinite(byteSize) ||
    byteSize <= 0 ||
    byteSize > MAX_NORMALIZED_PHOTO_BYTES
  ) {
    throw new ApiHttpError(
      400,
      "VALIDATION_ERROR",
      ctx.locale === "pl"
        ? "Rozmiar znormalizowanego pliku musi wynosić od 1B do 10 MB."
        : "Normalized file size must be between 1 byte and 10 MB.",
      false,
      { field: "byte_size", max_bytes: MAX_NORMALIZED_PHOTO_BYTES },
    );
  }

  const draftId = obj.draft_id !== undefined && obj.draft_id !== null
    ? requireUuid(obj.draft_id, "draft_id")
    : null;
  const plantId = obj.plant_id !== undefined && obj.plant_id !== null
    ? requireUuid(obj.plant_id, "plant_id")
    : null;

  if (!ctx.ownerId && !draftId) {
    throw new ApiHttpError(
      401,
      "UNAUTHORIZED",
      ctx.locale === "pl"
        ? "Gość musi podać identyfikator wersji roboczej (draft_id)."
        : "Guest upload requires a draft_id.",
    );
  }

  const captureAt = typeof obj.capture_at === "string" ? obj.capture_at : null;

  const ticket = await adapter.createSignedUploadTicket({
    ownerId: ctx.ownerId,
    draftId,
    plantId,
    mimeType,
    byteSize,
    captureAt,
    ttlSeconds: UPLOAD_TICKET_TTL_SECONDS,
  });

  return jsonResponse(ticket, 200);
}
