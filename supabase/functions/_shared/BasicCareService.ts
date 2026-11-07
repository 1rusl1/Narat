import { SupabaseClient } from "@supabase/supabase-js";

export interface BasicCareMembershipDTO {
  plant_id: string;
  enabled: boolean;
  enabled_at: string;
  free_slot: number | null;
}

export interface BasicCareStateDTO {
  has_paid_access: boolean;
  free_selection_explicit: boolean;
  memberships: BasicCareMembershipDTO[];
}

export interface BasicCareCommandInput {
  operation_id: string;
  command_type: "basic_care.enable" | "basic_care.disable" | "free_care.select";
  plant_id?: string;
  selected_plant_ids?: string[];
}

export function resolveActiveFreePlantIds(
  memberships: BasicCareMembershipDTO[],
  freeSelectionExplicit: boolean,
  hasPaidAccess: boolean,
): string[] {
  const enabled = memberships.filter((m) => m.enabled);
  if (hasPaidAccess) {
    return enabled.map((m) => m.plant_id);
  }

  if (freeSelectionExplicit) {
    return enabled
      .filter((m) => m.free_slot !== null && m.free_slot >= 1 && m.free_slot <= 3)
      .sort((a, b) => (a.free_slot ?? 99) - (b.free_slot ?? 99))
      .map((m) => m.plant_id);
  }

  return [...enabled]
    .sort((a, b) => {
      const cmp = a.enabled_at.localeCompare(b.enabled_at);
      return cmp !== 0 ? cmp : a.plant_id.localeCompare(b.plant_id);
    })
    .slice(0, 3)
    .map((m) => m.plant_id);
}

export function canEnableFreeBasicCareWithoutReplacement(
  memberships: BasicCareMembershipDTO[],
  targetPlantId: string,
  hasPaidAccess: boolean,
): boolean {
  if (hasPaidAccess) {
    return true;
  }
  const activeOtherSlots = memberships.filter(
    (m) =>
      m.enabled &&
      m.free_slot !== null &&
      m.free_slot >= 1 &&
      m.free_slot <= 3 &&
      m.plant_id !== targetPlantId,
  );
  return activeOtherSlots.length < 3;
}

export async function executeBasicCareCommand(
  supabaseAdmin: SupabaseClient,
  ownerId: string,
  input: BasicCareCommandInput,
): Promise<{ status: string; command_type: string; state: BasicCareStateDTO }> {
  const payload: Record<string, unknown> = {};
  if (input.plant_id) {
    payload.plant_id = input.plant_id;
  }
  if (input.selected_plant_ids) {
    payload.selected_plant_ids = input.selected_plant_ids;
  }

  const { data, error } = await supabaseAdmin.rpc("execute_basic_care_command", {
    p_owner_id: ownerId,
    p_operation_id: input.operation_id,
    p_command_type: input.command_type,
    p_payload: payload,
  });

  if (error) {
    throw new Error(error.message);
  }

  return data as { status: string; command_type: string; state: BasicCareStateDTO };
}
