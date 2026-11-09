import { SupabaseClient } from "@supabase/supabase-js";

export interface BasicCareMembershipDTO {
  plant_id: string;
  enabled: boolean;
  enabled_at: string;
}

export interface BasicCareStateDTO {
  has_paid_access: boolean;
  memberships: BasicCareMembershipDTO[];
}

export interface BasicCareCommandInput {
  operation_id: string;
  command_type: "basic_care.enable" | "basic_care.disable";
  plant_id: string;
}

async function executeRpc(
  supabaseAdmin: SupabaseClient,
  ownerId: string,
  operationId: string,
  commandType: string,
  payload: Record<string, unknown>,
): Promise<unknown> {
  const { data, error } = await supabaseAdmin.rpc("execute_basic_care_command", {
    p_owner_id: ownerId,
    p_operation_id: operationId,
    p_command_type: commandType,
    p_payload: payload,
  });
  if (error) throw new Error(error.message);
  if (data === null || data === undefined) throw new Error("basic_care_empty_response");
  return data;
}

export async function executeBasicCareCommand(
  supabaseAdmin: SupabaseClient,
  ownerId: string,
  input: BasicCareCommandInput,
): Promise<{ status: string; command_type: string; state: BasicCareStateDTO }> {
  return await executeRpc(
    supabaseAdmin, ownerId, input.operation_id, input.command_type,
    { plant_id: input.plant_id },
  ) as { status: string; command_type: string; state: BasicCareStateDTO };
}

/**
 * Replay-only compatibility boundary. SQL looks up the receipt before rejecting
 * a new select. Match the old adapter's truthy-field projection exactly; do not
 * normalize arrays or project the historical response into the current DTO.
 */
export function replayRetiredFreeCareSelection(
  supabaseAdmin: SupabaseClient,
  ownerId: string,
  operationId: string,
  body: Record<string, unknown>,
): Promise<unknown> {
  const payload: Record<string, unknown> = {};
  if (body.plant_id) payload.plant_id = body.plant_id;
  if (body.selected_plant_ids) payload.selected_plant_ids = body.selected_plant_ids;
  return executeRpc(supabaseAdmin, ownerId, operationId, "free_care.select", payload);
}
