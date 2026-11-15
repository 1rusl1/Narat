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
const conditionFields = new Set(["light_code", "watering_code", "drainage_code", "pot_type"]);
const observationStatuses = new Set(["improved", "unchanged", "worse", "unknown"]);

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

const enableBasicCareCommand = "basic_care.enable";
const soilCommand = "care.check_soil.complete";
const soilUndoCommand = "care.check_soil.undo";
const refreshCommand = "care.recommendation.refresh";
const refreshReasons = new Set([
  "insufficient_evidence",
  "missing_watering_anchor",
  "automatic_care_unavailable",
]);
type PlantCommand = "plant.delete" | "plant.edit" | typeof refreshCommand | typeof enableBasicCareCommand;

function unavailable(plantCommand?: PlantCommand) {
  return new ApiHttpError(
    503,
    "INTERNAL_ERROR",
    plantCommand === "plant.edit" ? "Plant editing is temporarily unavailable."
      : plantCommand === "plant.delete" ? "Plant deletion is temporarily unavailable."
      : plantCommand === refreshCommand ? "Recommendation refresh is temporarily unavailable."
      : plantCommand === enableBasicCareCommand ? "Basic care is temporarily unavailable."
      : "The care journal is temporarily unavailable.",
    true,
  );
}

function invalid(plantCommand?: PlantCommand) {
  return new ApiHttpError(
    400,
    "VALIDATION_ERROR",
    plantCommand === "plant.edit" ? "Invalid plant editing command."
      : plantCommand === "plant.delete" ? "Invalid plant deletion command."
      : plantCommand === refreshCommand ? "Invalid recommendation refresh command."
      : plantCommand === enableBasicCareCommand ? "Invalid basic care command."
      : "Invalid manual care command.",
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
      body.command_name !== "care.first_aid.observe" &&
      body.command_name !== "plant.delete" && body.command_name !== "plant.edit" &&
      body.command_name !== soilCommand && body.command_name !== soilUndoCommand &&
      body.command_name !== refreshCommand && body.command_name !== enableBasicCareCommand)
  ) {
    return await handlePlantCreate(req, ctx, clientFactory);
  }

  const isSoil = body.command_name === soilCommand;
  const isSoilUndo = body.command_name === soilUndoCommand;
  const isDeletion = body.command_name === "plant.delete";
  const isEdit = body.command_name === "plant.edit";
  const isRefresh = body.command_name === refreshCommand;
  const isEnableBasicCare = body.command_name === enableBasicCareCommand;
  const plantCommand = isEdit ? "plant.edit"
    : isDeletion ? "plant.delete"
    : isRefresh ? refreshCommand
    : isEnableBasicCare ? enableBasicCareCommand
    : undefined;
  if (
    new URL(req.url).search ||
    Object.keys(body).some((key) => !envelopeFields.has(key)) ||
    typeof body.payload_json !== "string"
  ) throw invalid(plantCommand);
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
    throw invalid(plantCommand);
  }
  if (!record(payload)) throw invalid(plantCommand);
  const isRecord = body.command_name === "care.record";
  const isFirstAid = body.command_name === "care.first_aid.record";
  const isUndo = body.command_name === "care.undo";
  const isObservation = body.command_name === "care.first_aid.observe";
  let controlId: string | null = null;
  let entryId: string | null = null;
  if (isDeletion || isEnableBasicCare) {
    if (Object.keys(payload).length !== 0) throw invalid(plantCommand);
  } else if (isEdit) {
    const conditions = payload.conditions;
    const validConditions = record(conditions) && Object.keys(conditions).length > 0 &&
      Object.entries(conditions).every(([key, value]) =>
        conditionFields.has(key) && typeof value === "string"
      );
    if (
      Object.keys(payload).length !== 1 ||
      (typeof payload.personal_name !== "string" && !validConditions &&
        typeof payload.taxon_id !== "string")
    ) throw invalid(plantCommand);
    if ("taxon_id" in payload) payload.taxon_id = requireUuid(payload.taxon_id, "taxon_id");
  } else if (isRefresh) {
    if (
      Object.keys(payload).length !== 1 ||
      typeof payload.expected_care_revision !== "number" ||
      !Number.isInteger(payload.expected_care_revision) ||
      payload.expected_care_revision < 1 || payload.expected_care_revision > 2147483647
    ) throw invalid(plantCommand);
  } else if (isSoil) {
    if (
      Object.keys(payload).length !== 5 ||
      Object.keys(payload).some((key) =>
        !["rule_id", "expected_care_revision", "due_local_date", "occurred_at", "timezone"].includes(key)
      ) ||
      typeof payload.expected_care_revision !== "number" ||
      !Number.isInteger(payload.expected_care_revision) ||
      payload.expected_care_revision < 1 || payload.expected_care_revision > 2147483647 ||
      typeof payload.due_local_date !== "string" ||
      !/^\d{4}-\d{2}-\d{2}$/.test(payload.due_local_date) ||
      timestamp(payload.due_local_date + "T00:00:00Z") === null ||
      timestamp(payload.occurred_at) === null ||
      typeof payload.timezone !== "string" || payload.timezone.length > 128 ||
      !/^[A-Za-z_]+(?:\/[A-Za-z0-9_+.-]+)*$/.test(payload.timezone)
    ) throw invalid();
    payload.rule_id = requireUuid(payload.rule_id, "rule_id");
    try {
      new Intl.DateTimeFormat("en", { timeZone: payload.timezone });
    } catch {
      throw invalid();
    }
  } else if (isSoilUndo) {
    if (Object.keys(payload).length !== 1 || !("entry_id" in payload)) throw invalid();
    entryId = requireUuid(payload.entry_id, "entry_id");
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
    if (!client) throw unavailable(plantCommand);
    const rpc = isSoilUndo ? "execute_routine_soil_check_undo"
      : isSoil ? "execute_routine_soil_check"
      : isEdit ? "execute_plant_edit_command"
      : isDeletion ? "execute_plant_delete_command"
      : isRefresh ? "execute_care_recommendation_refresh"
      : isEnableBasicCare ? "execute_basic_care_command"
      : isObservation
      ? "complete_first_aid_control"
      : "execute_manual_care_command";
    response = await client.rpc(rpc, {
      p_owner_id: ownerId,
      p_operation_id: operationId,
      ...(isSoilUndo
        ? { p_plant_id: plantId, p_entry_id: entryId }
        : isSoil
        ? {
          p_plant_id: plantId,
          p_rule_id: payload.rule_id,
          p_expected_care_revision: payload.expected_care_revision,
          p_due_local_date: payload.due_local_date,
          p_occurred_at: payload.occurred_at,
          p_timezone: payload.timezone,
        }
        : isEnableBasicCare
        ? { p_command_type: enableBasicCareCommand, p_payload: { plant_id: plantId } }
        : {
          p_plant_id: plantId,
          ...(!isObservation && !plantCommand && { p_command_name: body.command_name }),
          p_payload: payload,
        }),
    });
  } catch {
    throw unavailable(plantCommand);
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
        plantCommand ? "The plant was not found." : isObservation ? "The plant, first-aid control or photo was not found." : isFirstAid
          ? "The plant or first-aid action was not found."
          : "The plant or care entry was not found.",
      );
    }
    if (error.code === "23505" || ((isSoil || isSoilUndo) && error.code === "55000")) {
      throw new ApiHttpError(
        409,
        "CONFLICT",
        isSoil ? "The soil check is unavailable or the occurrence has changed."
          : isEdit ? "The operation conflicts with an existing receipt."
          : isDeletion ? "The plant is already deleted or the operation conflicts with an existing receipt."
          : isRefresh ? "The care revision has changed or the operation conflicts with an existing receipt."
          : isObservation
          ? "The first-aid control is unavailable or the operation conflicts with an existing receipt."
          : "The operation conflicts with an existing care entry or receipt.",
      );
    }
    if (["22007", "22008", "22023", "22P02"].includes(error.code)) {
      throw invalid(plantCommand);
    }
    throw unavailable(plantCommand);
  }
  if (isSoilUndo) {
    if (
      !record(data) || data.plant_id !== plantId || data.entry_id !== entryId ||
      typeof data.task_id !== "string" || !uuid.test(data.task_id) ||
      typeof data.reversal_id !== "string" || !uuid.test(data.reversal_id) ||
      data.state !== "voided" || timestamp(data.watermark) === null
    ) throw unavailable();
    return jsonResponse(data, 200, { "Cache-Control": "private, no-store" });
  }
  if (isSoil) {
    if (
      !record(data) || data.plant_id !== plantId || data.rule_id !== payload.rule_id ||
      data.care_revision !== payload.expected_care_revision ||
      data.due_local_date !== payload.due_local_date ||
      data.occurrence_key !== `${payload.rule_id}:${payload.due_local_date}` ||
      typeof data.task_id !== "string" || !uuid.test(data.task_id) ||
      typeof data.entry_id !== "string" || !uuid.test(data.entry_id) ||
      data.state !== "completed" || timestamp(data.watermark) === null
    ) throw unavailable();
    return jsonResponse(data, 200, { "Cache-Control": "private, no-store" });
  }
  if (isEdit) {
    if (
      !record(data) || data.plant_id !== plantId ||
      typeof data.revision !== "number" || !Number.isInteger(data.revision) || data.revision < 1 ||
      typeof data.care_revision !== "number" || !Number.isInteger(data.care_revision) || data.care_revision < 1 ||
      (data.condition_snapshot_id !== null &&
        (typeof data.condition_snapshot_id !== "string" || !uuid.test(data.condition_snapshot_id))) ||
      timestamp(data.watermark) === null
    ) throw unavailable(plantCommand);
    return jsonResponse(data, 200, { "Cache-Control": "private, no-store" });
  }
  if (isEnableBasicCare) {
    if (
      !record(data) || data.command_type !== enableBasicCareCommand || data.status !== "committed" ||
      !record(data.state) || !Array.isArray(data.state.memberships)
    ) throw unavailable(plantCommand);
    const membership = data.state.memberships.find((item: unknown) =>
      record(item) && item.plant_id === plantId
    );
    if (!record(membership) || membership.enabled !== true || timestamp(membership.enabled_at) === null) {
      throw unavailable(plantCommand);
    }
    return jsonResponse(
      { plant_id: plantId, enabled: true, enabled_at: membership.enabled_at },
      200,
      { "Cache-Control": "private, no-store" },
    );
  }
  if (isRefresh) {
    if (
      !record(data) || data.plant_id !== plantId ||
      data.care_revision !== payload.expected_care_revision ||
      timestamp(data.watermark) === null ||
      !(data.state === "refreshed" && data.reason === null ||
        data.state === "paused" && typeof data.reason === "string" && refreshReasons.has(data.reason))
    ) throw unavailable(plantCommand);
    return jsonResponse(data, 200, { "Cache-Control": "private, no-store" });
  }
  if (isDeletion) {
    if (
      !record(data) || data.plant_id !== plantId || data.state !== "deleting" ||
      typeof data.deletion_job_id !== "string" || !uuid.test(data.deletion_job_id) ||
      timestamp(data.watermark) === null
    ) throw unavailable(plantCommand);
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
