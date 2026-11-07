import { SupabaseClient } from "@supabase/supabase-js";

export interface PreparedDraftCopyJob {
  claim_id: string;
  draft_id: string;
  owner_id: string;
  plant_id: string;
  source_storage_path: string;
}

export interface GuestClaimsMaintenanceSummary {
  staged_copies_completed: number;
  expired_drafts_cleaned: number;
  failed_copies: number;
}

export async function copyDraftMediaToPlantBucket(
  supabaseAdmin: SupabaseClient,
  job: PreparedDraftCopyJob,
): Promise<{ targetStoragePath: string }> {
  const targetStoragePath = `${job.owner_id}/${job.plant_id}/${job.claim_id}.jpg`;

  const { data: downloaded, error: downloadErr } = await supabaseAdmin.storage
    .from("guest-drafts")
    .download(job.source_storage_path);
  if (downloadErr || !downloaded) {
    throw new Error(`draft_media_download_failed: ${downloadErr?.message ?? "missing"}`);
  }

  const { error: uploadErr } = await supabaseAdmin.storage
    .from("plant-photos")
    .upload(targetStoragePath, downloaded, {
      contentType: "image/jpeg",
      upsert: true,
    });
  if (uploadErr) {
    throw new Error(`plant_photo_upload_failed: ${uploadErr.message}`);
  }

  return { targetStoragePath };
}

export async function runGuestClaimsMaintenance(
  supabaseAdmin: SupabaseClient,
  nowIso: string = new Date().toISOString(),
): Promise<GuestClaimsMaintenanceSummary> {
  let stagedCopiesCompleted = 0;
  let expiredDraftsCleaned = 0;
  let failedCopies = 0;

  // 1. Complete any staged guest_claims that need storage copy
  const { data: preparedClaims } = await supabaseAdmin
    .from("guest_claims")
    .select("id, draft_id, owner_id, target_plant_id, copied_storage_path")
    .eq("status", "prepared")
    .is("copied_storage_path", null)
    .limit(25);

  for (const claim of preparedClaims ?? []) {
    try {
      const { data: draft } = await supabaseAdmin
        .from("guest_drafts")
        .select("photo_storage_path")
        .eq("id", claim.draft_id)
        .maybeSingle();

      if (draft?.photo_storage_path) {
        const { targetStoragePath } = await copyDraftMediaToPlantBucket(supabaseAdmin, {
          claim_id: claim.id,
          draft_id: claim.draft_id,
          owner_id: claim.owner_id,
          plant_id: claim.target_plant_id,
          source_storage_path: draft.photo_storage_path,
        });

        await supabaseAdmin
          .from("guest_claims")
          .update({ copied_storage_path: targetStoragePath, updated_at: nowIso })
          .eq("id", claim.id);
        stagedCopiesCompleted += 1;
      }
    } catch {
      failedCopies += 1;
    }
  }

  // 2. Clean up expired guest_drafts (> 24h TTL) that are not actively being claimed
  const { data: expiredDrafts } = await supabaseAdmin
    .from("guest_drafts")
    .select("id, photo_storage_path")
    .in("status", ["ready", "expired"])
    .lt("expires_at", nowIso)
    .limit(50);

  for (const expired of expiredDrafts ?? []) {
    if (expired.photo_storage_path) {
      await supabaseAdmin.storage
        .from("guest-drafts")
        .remove([expired.photo_storage_path]);
    }
    await supabaseAdmin
      .from("guest_drafts")
      .update({ status: "expired", photo_storage_path: null, updated_at: nowIso })
      .eq("id", expired.id);
    expiredDraftsCleaned += 1;
  }

  return {
    staged_copies_completed: stagedCopiesCompleted,
    expired_drafts_cleaned: expiredDraftsCleaned,
    failed_copies: failedCopies,
  };
}
