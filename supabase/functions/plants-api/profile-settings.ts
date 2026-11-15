import {
  ApiHttpError, jsonResponse, type RequestContext, requireActiveOwner, requireUuid,
} from "../_shared/http.ts";
import { type SyncClientFactory, timestamp } from "./collection.ts";

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function closed(value: Record<string, unknown>, keys: string[]): boolean {
  return Object.keys(value).length === keys.length && keys.every((key) => Object.hasOwn(value, key));
}

function settings(value: unknown): boolean {
  return record(value) && closed(value, ["preferred_locale", "reminder_hour_local"]) &&
    (value.preferred_locale === "pl" || value.preferred_locale === "en") &&
    typeof value.reminder_hour_local === "number" &&
    Number.isInteger(value.reminder_hour_local) &&
    value.reminder_hour_local >= 0 && value.reminder_hour_local <= 23;
}

function unavailable() {
  return new ApiHttpError(503, "INTERNAL_ERROR", "Profile settings are temporarily unavailable.", true);
}

function invalid() {
  return new ApiHttpError(400, "VALIDATION_ERROR", "Invalid profile settings request.");
}

function owner(ctx: RequestContext): string {
  const id = requireActiveOwner(ctx);
  if (ctx.isAnonymous) throw new ApiHttpError(403, "FORBIDDEN", "An active permanent account is required.");
  return id;
}

async function rpc(
  clientFactory: SyncClientFactory, name: string, args: Record<string, unknown>,
): Promise<unknown> {
  let response;
  try {
    const client = clientFactory();
    if (!client) throw unavailable();
    response = await client.rpc(name, args);
  } catch {
    throw unavailable();
  }
  const { data, error } = response;
  if (error) {
    if (error.code === "42501") {
      throw new ApiHttpError(403, "FORBIDDEN", "An active permanent account is required.");
    }
    if (name === "execute_profile_reminder_hour_update" && error.code === "23505") throw new ApiHttpError(409, "CONFLICT", "Operation receipt mismatch.");
    if (name === "execute_profile_reminder_hour_update" && ["22023", "22P02"].includes(error.code)) throw invalid();
    throw unavailable();
  }
  return data;
}

export async function handleGetProfileSettings(
  req: Request, ctx: RequestContext, clientFactory: SyncClientFactory,
): Promise<Response> {
  const ownerId = owner(ctx);
  if (new URL(req.url).search) throw invalid();
  const data = await rpc(clientFactory, "read_owner_profile_settings", { p_owner_id: ownerId });
  if (!settings(data)) throw unavailable();
  return jsonResponse({ profile: data }, 200, { "Cache-Control": "private, no-store" });
}

export async function handleProfileUpdate(
  req: Request, ctx: RequestContext, body: Record<string, unknown>, clientFactory: SyncClientFactory,
): Promise<Response> {
  const ownerId = owner(ctx);
  if (
    new URL(req.url).search ||
    Object.keys(body).some((key) => !["operation_id", "plant_id", "command_name", "payload_json"].includes(key)) ||
    body.command_name !== "profile.update" ||
    (body.plant_id !== undefined && body.plant_id !== null) ||
    typeof body.payload_json !== "string"
  ) throw invalid();
  const operationId = requireUuid(body.operation_id, "operation_id");
  for (const header of [req.headers.get("x-operation-id"), ctx.operationId]) {
    if (header !== null && requireUuid(header.trim(), "x-operation-id") !== operationId) {
      throw new ApiHttpError(409, "CONFLICT", "Operation IDs do not match.");
    }
  }
  let payload: unknown;
  try {
    payload = JSON.parse(body.payload_json);
  } catch {
    throw invalid();
  }
  if (
    !record(payload) || !closed(payload, ["reminder_hour_local"]) ||
    typeof payload.reminder_hour_local !== "number" || !Number.isInteger(payload.reminder_hour_local) ||
    payload.reminder_hour_local < 0 || payload.reminder_hour_local > 23
  ) throw invalid();
  const data = await rpc(clientFactory, "execute_profile_reminder_hour_update", {
    p_owner_id: ownerId, p_operation_id: operationId, p_payload: payload,
  });
  if (
    !record(data) || !closed(data, ["profile", "watermark"]) ||
    !settings(data.profile) || timestamp(data.watermark) === null ||
    !record(data.profile) || data.profile.reminder_hour_local !== payload.reminder_hour_local
  ) throw unavailable();
  // Preserve the SQL receipt, including its original locale and watermark on retry.
  return jsonResponse(data, 200, { "Cache-Control": "private, no-store" });
}
