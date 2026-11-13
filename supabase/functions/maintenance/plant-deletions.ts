import type { SupabaseClient } from "@supabase/supabase-js";
import { DIAGNOSIS_PHOTO_BUCKET } from "../plants-api/diagnosis-media.ts";

const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;

function isUuid(value: unknown): value is string {
  return typeof value === "string" && uuid.test(value);
}

function isCount(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

type StoragePurgeResult =
  | { state: "not_found" }
  | { state: "purge_storage" | "purge_data"; blocked: number; waiting: number };

export async function runPlantStoragePurge(
  client: SupabaseClient,
  jobId: string,
): Promise<StoragePurgeResult> {
  if (!isUuid(jobId)) throw new Error("Invalid plant deletion job ID.");
  const args = { p_job_id: jobId };
  const { data: plan, error } = await client.rpc(
    "read_plant_deletion_storage",
    args,
  );
  if (error) throw new Error("Could not read the plant deletion storage plan.");
  if (plan === null) return { state: "not_found" };
  if (
    !isUuid(plan?.owner_id) || !Array.isArray(plan.photo_ids) ||
    plan.photo_ids.length > 20 ||
    !plan.photo_ids.every(isUuid) || !isCount(plan.blocked) ||
    !isCount(plan.waiting)
  ) {
    throw new Error("Invalid plant deletion storage plan.");
  }

  if (plan.photo_ids.length > 0) {
    const paths = plan.photo_ids.map((id: string) => `${plan.owner_id}/${id}`);
    const { error } = await client.storage.from(DIAGNOSIS_PHOTO_BUCKET).remove(
      paths,
    );
    if (error) {
      throw new Error("Could not remove plant photos from private storage.");
    }
  }

  const { data: state, error: finishError } = await client.rpc(
    "finish_plant_deletion_storage",
    args,
  );
  if (finishError || (state !== "purge_storage" && state !== "purge_data")) {
    throw new Error("Could not verify plant storage deletion.");
  }
  return { state, blocked: plan.blocked, waiting: plan.waiting };
}

type DataPurgeResult = { state: "pending" | "cleared"; cleared: number };

export async function runPlantDataPurge(
  client: SupabaseClient,
  jobId: string,
): Promise<DataPurgeResult | null> {
  if (!isUuid(jobId)) throw new Error("Invalid plant deletion job ID.");
  const { data, error } = await client.rpc(
    "purge_plant_deletion_data",
    {
      p_job_id: jobId,
    },
  );
  if (error) throw new Error("Could not clear deleted plant data.");
  if (data === null) return null;
  if (
    (data?.state !== "pending" && data?.state !== "cleared") ||
    !isCount(data.cleared) || (data.state === "pending" && data.cleared !== 0)
  ) {
    throw new Error("Invalid plant data deletion result.");
  }
  return { state: data.state, cleared: data.cleared };
}
