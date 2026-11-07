import { SupabaseClient } from "@supabase/supabase-js";
import { ApiHttpError, errorResponse, jsonResponse } from "../_shared/http.ts";
import {
  BasicCareCommandInput,
  executeBasicCareCommand,
} from "../_shared/BasicCareService.ts";

export async function handleBasicCareCommand(
  req: Request,
  supabaseAdmin: SupabaseClient,
  ownerId: string,
): Promise<Response> {
  const body = (await req.json().catch(() => null)) as BasicCareCommandInput | null;
  if (!body || !body.operation_id || !body.command_type) {
    return errorResponse(
      new ApiHttpError(
        400,
        "VALIDATION_ERROR",
        "operation_id and command_type are required",
      ),
    );
  }

  if (
    body.command_type !== "basic_care.enable" &&
    body.command_type !== "basic_care.disable" &&
    body.command_type !== "free_care.select"
  ) {
    return errorResponse(
      new ApiHttpError(400, "VALIDATION_ERROR", "Invalid basic care command_type"),
    );
  }

  if (
    body.command_type === "free_care.select" &&
    (!Array.isArray(body.selected_plant_ids) || body.selected_plant_ids.length > 3)
  ) {
    return errorResponse(
      new ApiHttpError(
        400,
        "VALIDATION_ERROR",
        "free_care.select accepts at most 3 plant IDs",
      ),
    );
  }

  try {
    const result = await executeBasicCareCommand(supabaseAdmin, ownerId, body);
    return jsonResponse(result, 200);
  } catch (err) {
    const msg = err instanceof Error ? err.message : "basic_care_command_failed";
    if (msg.includes("free_limit_reached_select_required")) {
      return errorResponse(
        new ApiHttpError(
          409,
          "CONFLICT",
          "Free basic care is active for 3 plants; use free_care.select to choose up to 3 plants",
        ),
      );
    }
    return errorResponse(new ApiHttpError(400, "VALIDATION_ERROR", msg));
  }
}
