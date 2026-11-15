import type { SupabaseClient } from "@supabase/supabase-js";
import { DIAGNOSIS_PHOTO_BUCKET } from "../plants-api/diagnosis-media.ts";

const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const holds = [
  "blocked", "waiting", "orphan_objects", "guest_draft_sources",
  "guest_identification_sources", "incoming_claims",
] as const;
type Hold = typeof holds[number];
type Plan = Record<Hold, number> & {
  owner_id: string;
  photo_ids: string[];
  storage_ready: boolean;
};
export type AccountStoragePurgeResult =
  | { state: "not_found" }
  | (Record<Hold, number> & { state: "pending" | "ready" });

function validate(value: unknown, owner: string): Plan {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("Invalid account storage plan.");
  }
  const plan = value as Record<string, unknown>;
  const keys = ["owner_id", "photo_ids", "storage_ready", ...holds];
  if (
    Object.keys(plan).length !== keys.length ||
    !keys.every((key) => Object.hasOwn(plan, key)) ||
    plan.owner_id !== owner || !Array.isArray(plan.photo_ids) ||
    plan.photo_ids.length > 20 ||
    !plan.photo_ids.every((id: unknown, index: number) =>
      typeof id === "string" && uuid.test(id) &&
      (index === 0 || id > (plan.photo_ids as string[])[index - 1])
    ) ||
    !holds.every((key) =>
      typeof plan[key] === "number" && Number.isSafeInteger(plan[key]) &&
      (plan[key] as number) >= 0
    ) ||
    typeof plan.storage_ready !== "boolean" ||
    (plan.storage_ready &&
      (plan.photo_ids.length !== 0 || holds.some((key) => plan[key] !== 0)))
  ) throw new Error("Invalid account storage plan.");
  // Empty work with storage_ready=false is valid: the private bucket may be absent.
  return plan as Plan;
}

/** Internal, one account and at most one remove; no account/DB state transitions. */
export async function runAccountStoragePurge(
  client: SupabaseClient,
  ownerId: string,
): Promise<AccountStoragePurgeResult> {
  if (typeof ownerId !== "string" || !uuid.test(ownerId)) {
    throw new Error("Invalid account storage owner ID.");
  }
  const read = async (): Promise<unknown> => {
    try {
      const { data, error } = await client.rpc(
        "read_account_deletion_storage_work_plan",
        { p_owner_id: ownerId },
      );
      if (error) throw new Error();
      return data;
    } catch {
      throw new Error("Could not read account storage plan; retry.");
    }
  };
  const initial = await read();
  if (initial === null) return { state: "not_found" };
  const plan = validate(initial, ownerId);
  if (plan.photo_ids.length > 0) {
    try {
      const { error } = await client.storage.from(DIAGNOSIS_PHOTO_BUCKET).remove(
        plan.photo_ids.map((id) => `${ownerId}/${id}`),
      );
      if (error) throw new Error();
    } catch {
      throw new Error("Could not remove account photos from private storage; retry.");
    }
  }
  // Always reread from the start, even for an initially empty/ready plan.
  // A successful remove response is not evidence that objects disappeared.
  const fresh = validate(await read(), ownerId);
  return {
    state: fresh.storage_ready ? "ready" : "pending",
    blocked: fresh.blocked,
    waiting: fresh.waiting,
    orphan_objects: fresh.orphan_objects,
    guest_draft_sources: fresh.guest_draft_sources,
    guest_identification_sources: fresh.guest_identification_sources,
    incoming_claims: fresh.incoming_claims,
  };
}
