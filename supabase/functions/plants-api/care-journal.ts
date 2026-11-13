import {
  ApiHttpError,
  jsonResponse,
  type RequestContext,
  requireActiveOwner,
  requireUuid,
} from "../_shared/http.ts";
import { handlePlantCreate, type SyncClientFactory, timestamp } from "./collection.ts";

const envelopeFields = new Set([
  "operation_id",
  "plant_id",
  "command_name",
  "payload_json",
]);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const observationStatuses = new Set(["improved", "unchanged", "worse", "unknown"]);

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function unavailable(deletion = false) {
  return new ApiHttpError(
    503,
    "INTERNAL_ERROR",
    deletion ? "Plant deletion is temporarily unavailable." : "The care journal is temporarily unavailable.",
    true,
  );
}

function invalid(deletion = false) {
  return new ApiHttpError(
    400,
    "VALIDATION_ERROR",
    deletion ? "Invalid plant deletion command." : "Invalid manual care command.",
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
      body.command_name !== "care.correct_date" &&
      body.command_name !== "care.first_aid.record" &&
      body.command_name !== "care.first_aid.observe" && body.command_name !== "plant.delete")
  ) {
    return await handlePlantCreate(req, ctx, clientFactory);
  }

  const isDeletion = body.command_name === "plant.delete";
  if (
    new URL(req.url).search ||
    Object.keys(body).some((key) => !envelopeFields.has(key)) ||
    typeof body.payload_json !== "string"
  ) throw invalid(isDeletion);
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
    throw invalid(isDeletion);
  }
  if (!record(payload)) throw invalid(isDeletion);
  const isRecord = body.command_name === "care.record";
  const isFirstAid = body.command_name === "care.first_aid.record";
  const isUndo = body.command_name === "care.undo";
  const isObservation = body.command_name === "care.first_aid.observe";
  let controlId: string | null = null;
  let entryId: string | null = null;
  if (isDeletion) {
    if (Object.keys(payload).length !== 0) throw invalid(true);
  } else if (isObservation) {
    if (
      Object.keys(payload).some((key) => !["control_id", "status_code", "photo_id"].includes(key)) ||
      typeof payload.status_code !== "string" ||
      !observationStatuses.has(payload.status_code)
    ) throw invalid();
    controlId = requireUuid(payload.control_id, "control_id");
    payload.control_id = controlId;
    if ("photo_id" in payload) payload.photo_id = requireUuid(payload.photo_id, "photo_id");
  } else {
    if (
      Object.keys(payload).length !== (isUndo ? 1 : 3) ||
      (isRecord && payload.action_code !== "water") ||
      (!isUndo && (typeof payload.occurred_at !== "string" ||
        typeof payload.timezone !== "string"))
    ) throw invalid();
    if (isFirstAid) requireUuid(payload.job_id, "job_id");
    if (!isRecord && !isFirstAid) entryId = requireUuid(payload.entry_id, "entry_id");
  }

  let response;
  try {
    const client = clientFactory();
    if (!client) throw unavailable(isDeletion);
    const rpc = isDeletion ? "execute_plant_delete_command" : isObservation
      ? "complete_first_aid_control"
      : "execute_manual_care_command";
    response = await client.rpc(rpc, {
      p_owner_id: ownerId,
      p_operation_id: operationId,
      p_plant_id: plantId,
      ...(!isObservation && !isDeletion && { p_command_name: body.command_name }),
      p_payload: payload,
    });
  } catch {
    throw unavailable(isDeletion);
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
        isDeletion ? "The plant was not found." : isObservation ? "The plant, first-aid control or photo was not found." : isFirstAid
          ? "The plant or first-aid action was not found."
          : "The plant or care entry was not found.",
      );
    }
    if (error.code === "23505") {
      throw new ApiHttpError(
        409,
        "CONFLICT",
        isDeletion ? "The plant is already deleted or the operation conflicts with an existing receipt." : isObservation
          ? "The first-aid control is unavailable or the operation conflicts with an existing receipt."
          : "The operation conflicts with an existing care entry or receipt.",
      );
    }
    if (["22007", "22008", "22023", "22P02"].includes(error.code)) {
      throw invalid(isDeletion);
    }
    throw unavailable(isDeletion);
  }
  if (isDeletion) {
    if (
      !record(data) || data.plant_id !== plantId || data.state !== "deleting" ||
      typeof data.deletion_job_id !== "string" || !uuid.test(data.deletion_job_id) ||
      timestamp(data.watermark) === null
    ) throw unavailable(true);
    return jsonResponse(data, 200, { "Cache-Control": "private, no-store" });
  }
  if (
    !record(data) || data.plant_id !== plantId ||
    typeof data.watermark !== "string" || !Number.isFinite(Date.parse(data.watermark))
  ) throw unavailable();
  if (isObservation) {
    if (
      data.control_id !== controlId || data.state !== "completed" ||
      typeof data.observation_id !== "string" || !uuid.test(data.observation_id)
    ) throw unavailable();
    return jsonResponse(data);
  }
  if (
    typeof data.entry_id !== "string" ||
    !uuid.test(data.entry_id) ||
    (isFirstAid && data.control_id !== null &&
      (typeof data.control_id !== "string" || !uuid.test(data.control_id))) ||
    (entryId !== null && data.entry_id !== entryId) ||
    (isUndo
      ? data.state !== "voided" || typeof data.reversal_id !== "string" ||
        !uuid.test(data.reversal_id)
      : data.state !== "active" || data.reversal_id !== null)
  ) throw unavailable();

  return jsonResponse(data);
}
