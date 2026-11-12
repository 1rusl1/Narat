import {
  ApiHttpError,
  jsonResponse,
  type RequestContext,
  requireActiveOwner,
  requireUuid,
} from "../_shared/http.ts";
import { handlePlantCreate, type SyncClientFactory } from "./collection.ts";

const envelopeFields = new Set([
  "operation_id",
  "plant_id",
  "command_name",
  "payload_json",
]);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function unavailable() {
  return new ApiHttpError(
    503,
    "INTERNAL_ERROR",
    "The care journal is temporarily unavailable.",
    true,
  );
}

function invalid() {
  return new ApiHttpError(
    400,
    "VALIDATION_ERROR",
    "Invalid manual care command.",
  );
}

export async function handleCollectionCommand(
  req: Request,
  ctx: RequestContext,
  clientFactory: SyncClientFactory,
): Promise<Response> {
  const ownerId = requireActiveOwner(ctx);
  // Retain the existing guard and response for anonymous command callers.
  if (ctx.isAnonymous) return await handlePlantCreate(req, ctx, clientFactory);
  const body: unknown = await req.clone().json().catch(() => null);
  if (
    !record(body) ||
    (body.command_name !== "care.record" && body.command_name !== "care.undo" &&
      body.command_name !== "care.correct_date")
  ) {
    return await handlePlantCreate(req, ctx, clientFactory);
  }

  if (
    new URL(req.url).search ||
    Object.keys(body).some((key) => !envelopeFields.has(key)) ||
    typeof body.payload_json !== "string"
  ) throw invalid();
  const operationId = requireUuid(body.operation_id, "operation_id");
  const plantId = requireUuid(body.plant_id, "plant_id");
  const header = req.headers.get("x-operation-id");
  if (
    header !== null &&
    requireUuid(header.trim(), "x-operation-id") !== operationId
  ) {
    throw new ApiHttpError(409, "CONFLICT", "Operation IDs do not match.");
  }

  let payload: unknown;
  try {
    payload = JSON.parse(body.payload_json);
  } catch {
    throw invalid();
  }
  if (!record(payload)) throw invalid();
  const isRecord = body.command_name === "care.record";
  const isUndo = body.command_name === "care.undo";
  if (
    Object.keys(payload).length !== (isUndo ? 1 : 3) ||
    (isRecord && payload.action_code !== "water") ||
    (!isUndo && (typeof payload.occurred_at !== "string" ||
      typeof payload.timezone !== "string"))
  ) throw invalid();
  const entryId = isRecord ? null : requireUuid(payload.entry_id, "entry_id");

  let response;
  try {
    const client = clientFactory();
    if (!client) throw unavailable();
    response = await client.rpc("execute_manual_care_command", {
      p_owner_id: ownerId,
      p_operation_id: operationId,
      p_plant_id: plantId,
      p_command_name: body.command_name,
      p_payload: payload,
    });
  } catch {
    throw unavailable();
  }
  const { data, error } = response;
  if (error) {
    if (error.code === "42501") {
      throw new ApiHttpError(
        403,
        "FORBIDDEN",
        "An active permanent account is required.",
      );
    }
    if (error.code === "P0002") {
      throw new ApiHttpError(
        404,
        "NOT_FOUND",
        "The plant or care entry was not found.",
      );
    }
    if (error.code === "23505") {
      throw new ApiHttpError(
        409,
        "CONFLICT",
        "The operation conflicts with an existing care entry or receipt.",
      );
    }
    if (["22007", "22008", "22023", "22P02"].includes(error.code)) {
      throw invalid();
    }
    throw unavailable();
  }
  if (
    !record(data) || data.plant_id !== plantId ||
    typeof data.entry_id !== "string" ||
    !uuid.test(data.entry_id) || typeof data.watermark !== "string" ||
    !Number.isFinite(Date.parse(data.watermark)) ||
    (entryId !== null && data.entry_id !== entryId) ||
    (isUndo
      ? data.state !== "voided" || typeof data.reversal_id !== "string" ||
        !uuid.test(data.reversal_id)
      : data.state !== "active" || data.reversal_id !== null)
  ) throw unavailable();

  return jsonResponse(data);
}
