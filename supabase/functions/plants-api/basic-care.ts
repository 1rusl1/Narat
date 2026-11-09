import { SupabaseClient } from "@supabase/supabase-js";
import { ApiHttpError, errorResponse, jsonResponse } from "../_shared/http.ts";
import {
  executeBasicCareCommand,
  replayRetiredFreeCareSelection,
} from "../_shared/BasicCareService.ts";

export async function handleBasicCareCommand(
  req: Request,
  supabaseAdmin: SupabaseClient,
  ownerId: string,
): Promise<Response> {
  const raw: unknown = await req.json().catch(() => null);
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return errorResponse(new ApiHttpError(400, "VALIDATION_ERROR", "Invalid command body"));
  }
  const body = raw as Record<string, unknown>;
  if (
    typeof body.operation_id !== "string" || !body.operation_id.trim() ||
    typeof body.command_type !== "string"
  ) {
    return errorResponse(new ApiHttpError(
      400, "VALIDATION_ERROR", "operation_id and command_type are required",
    ));
  }

  try {
    if (body.command_type === "free_care.select") {
      // Even null/malformed selections must reach SQL's historical receipt lookup.
      return jsonResponse(await replayRetiredFreeCareSelection(
        supabaseAdmin, ownerId, body.operation_id, body,
      ));
    }
    if (
      body.command_type !== "basic_care.enable" &&
      body.command_type !== "basic_care.disable"
    ) {
      throw new ApiHttpError(400, "VALIDATION_ERROR", "Invalid basic care command_type");
    }
    if (
      typeof body.plant_id !== "string" || !body.plant_id.trim() ||
      Object.keys(body).some((key) =>
        !["operation_id", "command_type", "plant_id"].includes(key)
      )
    ) {
      throw new ApiHttpError(400, "VALIDATION_ERROR", "Expected plant_id only");
    }
    const result = await executeBasicCareCommand(supabaseAdmin, ownerId, {
      operation_id: body.operation_id,
      command_type: body.command_type,
      plant_id: body.plant_id,
    });
    return jsonResponse(result);
  } catch (err) {
    if (err instanceof ApiHttpError) return errorResponse(err);
    const msg = err instanceof Error ? err.message : "basic_care_command_failed";
    if (msg.includes("operation_payload_mismatch")) {
      return errorResponse(new ApiHttpError(409, "CONFLICT", msg));
    }
    return errorResponse(new ApiHttpError(400, "VALIDATION_ERROR", msg));
  }
}
