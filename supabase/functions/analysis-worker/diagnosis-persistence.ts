import type { SupabaseClient } from "@supabase/supabase-js";
import {
  type CanonicalConditionId,
  type CanonicalConditionProfile,
  type PublishedReleaseCatalog,
  validateConditionProfileSemantics,
} from "../_shared/KnowledgeTypes.ts";
import {
  DAILY_PROVIDER_BUDGET_CAP_MICRO_USD,
  type DailyBudgetRecord,
  type ProviderBudgetStorageAdapter,
} from "../_shared/ProviderBudgetGuard.ts";
import { DIAGNOSIS_PHOTO_BUCKET } from "../plants-api/diagnosis-media.ts";
import type { LeasedAnalysisJob, WorkerPersistenceAdapter } from "./index.ts";

const CHARGED_MICRO_USD_PER_CALL = 50_000;
const MAX_BYTES = 10 * 1024 * 1024;

interface Lease {
  job_id: string;
  owner_id: string;
  lease_token: string;
  mode: "diagnosis" | "identification";
  locale: "en" | "pl";
  kb_release_id: string | null;
  quota_kind: string;
  deadline_at: string;
  upload: {
    photo_asset_id: string;
    owner_id: string;
    state: string;
    storage_path: string;
    content_sha256: string;
    byte_size: number;
    mime_type: LeasedAnalysisJob["mediaType"];
  } | null;
}

export function createDiagnosisPersistence(
  client: SupabaseClient,
  jobId: string,
): {
  workerAdapter: WorkerPersistenceAdapter;
  budgetAdapter: ProviderBudgetStorageAdapter;
} {
  let lease: Lease | null = null;
  let budgetRecord: DailyBudgetRecord | null = null;
  const names = new Map<string, string>();
  const conditions = new Map<CanonicalConditionId, CanonicalConditionProfile>();

  async function call(name: string, args: Record<string, unknown>) {
    const { data, error } = await client.rpc(name, args);
    if (error) throw new Error("Diagnosis persistence failed.");
    return data;
  }
  function identity() {
    if (!lease) throw new Error("Missing analysis lease.");
    return { p_job_id: lease.job_id, p_lease_token: lease.lease_token };
  }

  const workerAdapter: WorkerPersistenceAdapter = {
    async leaseNextQueuedJob() {
      lease = await call("lease_diagnosis_job", { p_job_id: jobId });
      if (!lease) return null;
      if (
        lease.job_id !== jobId || !lease.lease_token ||
        (lease.mode !== "diagnosis" && lease.mode !== "identification") ||
        !["en", "pl"].includes(lease.locale) ||
        !Number.isFinite(Date.parse(lease.deadline_at))
      ) {
        throw new Error("Invalid diagnosis lease.");
      }
      return {
        id: lease.job_id,
        ownerId: lease.owner_id,
        installationId: null,
        kbReleaseId: lease.kb_release_id,
        mode: lease.mode,
        locale: lease.locale,
        imageBase64: "",
        mediaType: lease.upload?.mime_type ?? "image/jpeg",
        quotaKind: lease.quota_kind,
        monthlyQuotaId: null,
        leaseExpiresAt: lease.deadline_at,
      };
    },

    async loadJobImage() {
      const upload = lease?.upload;
      if (
        !upload || upload.state !== "ready" ||
        upload.owner_id !== lease?.owner_id ||
        upload.storage_path !== `${upload.owner_id}/${upload.photo_asset_id}` ||
        !Number.isInteger(upload.byte_size) || upload.byte_size < 1 ||
        upload.byte_size > MAX_BYTES ||
        !["image/jpeg", "image/png", "image/webp"].includes(upload.mime_type)
      ) {
        throw new Error("The verified photo is unavailable.");
      }
      const { data, error } = await client.storage.from(DIAGNOSIS_PHOTO_BUCKET)
        .download(upload.storage_path);
      if (error || !data || data.size !== upload.byte_size) {
        throw new Error("Photo download failed.");
      }
      const buffer = await data.arrayBuffer();
      const hash = Array.from(
        new Uint8Array(await crypto.subtle.digest("SHA-256", buffer)),
        (n) => n.toString(16).padStart(2, "0"),
      ).join("");
      if (hash !== upload.content_sha256) {
        throw new Error("The photo no longer matches its upload.");
      }
      const bytes = new Uint8Array(buffer);
      const parts: string[] = [];
      for (let offset = 0; offset < bytes.length; offset += 32768) {
        parts.push(
          String.fromCharCode(...bytes.subarray(offset, offset + 32768)),
        );
      }
      return btoa(parts.join(""));
    },

    async loadPublishedCatalog(kbReleaseId) {
      const data = await call("read_diagnosis_catalog", identity());
      if (
        data?.kb_release_id !== kbReleaseId || !Array.isArray(data.plants) ||
        !data.plants.length ||
        !Array.isArray(data.conditions)
      ) throw new Error("The pinned release is unavailable.");
      const catalog: PublishedReleaseCatalog = {
        kbReleaseId,
        plantIds: new Set(),
        genusIds: new Set(),
        plantScientificNames: new Map(),
        conditionProfiles: conditions,
      };
      for (const plant of data.plants) {
        if (
          typeof plant.plant_id !== "string" ||
          typeof plant.genus !== "string" ||
          typeof plant.scientific_name !== "string" ||
          typeof plant.display_name !== "string"
        ) {
          throw new Error("Invalid published plant.");
        }
        catalog.plantIds.add(plant.plant_id);
        catalog.genusIds.add(
          plant.genus.toLowerCase().replace(/[^a-z0-9]+/g, "_"),
        );
        catalog.plantScientificNames!.set(
          plant.plant_id,
          plant.scientific_name,
        );
        names.set(plant.plant_id, plant.display_name);
      }
      for (const raw of data.conditions) {
        if (
          !validateConditionProfileSemantics(raw).valid ||
          raw.kb_release_id !== kbReleaseId
        ) {
          throw new Error("Invalid published condition.");
        }
        const profile = raw as CanonicalConditionProfile;
        conditions.set(profile.condition_id, profile);
      }
      return catalog;
    },

    async loadIdentificationCatalog() {
      const data = await call("read_identification_catalog", identity());
      if (
        typeof data?.catalogue_release_id !== "string" ||
        !Array.isArray(data.plants) || !data.plants.length
      ) throw new Error("The pinned identification catalogue is unavailable.");

      const species = new Map<
        string,
        { scientificName: string; displayName: string }
      >();
      for (const plant of data.plants) {
        if (
          typeof plant.plant_id !== "string" ||
          typeof plant.scientific_name !== "string" ||
          typeof plant.display_name !== "string"
        ) throw new Error("Invalid published species.");
        species.set(plant.plant_id, {
          scientificName: plant.scientific_name,
          displayName: plant.display_name,
        });
      }
      return { releaseId: data.catalogue_release_id, species };
    },

    async finalizeJobOnce(params) {
      const projection = params.projection;
      const condition = projection?.selected_condition_id ??
        projection?.candidates[0]?.condition_id;
      const result = params.identification ?? (projection
        ? {
          ...projection,
          plant_display_name: projection.plant_id
            ? names.get(projection.plant_id) ?? null
            : null,
          condition_display_name: condition && lease
            ? conditions.get(condition)?.condition_content_i18n[lease.locale]
              .title ?? null
            : null,
        }
        : null);
      const data = await call("finish_diagnosis_job", {
        ...identity(),
        p_result: result,
        p_non_billable: params.isNonBillableResult,
        p_error_code: params.errorCode ?? null,
      });
      if (
        !data || !["consumed", "released"].includes(data.quota_state) ||
        typeof data.already_finalized !== "boolean"
      ) throw new Error("Invalid diagnosis settlement.");
      return {
        alreadyFinalized: data.already_finalized,
        quotaState: data.quota_state,
      };
    },
  };

  const budgetAdapter: ProviderBudgetStorageAdapter = {
    async reserveDailyBudget(params) {
      const data = await call("start_diagnosis_provider", identity());
      const allowed = data?.allowed === true &&
        Number.isInteger(data.started_calls);
      budgetRecord = {
        budgetDateUtc: allowed ? data.budget_date : params.budgetDateUtc,
        capMicroUsd: DAILY_PROVIDER_BUDGET_CAP_MICRO_USD,
        spentMicroUsd: allowed
          ? data.started_calls * CHARGED_MICRO_USD_PER_CALL
          : 0,
        reservedMicroUsd: 0,
        circuitOpen: !allowed,
      };
      return { allowed, record: budgetRecord };
    },
    // The database charges the conservative allowance once before the call.
    // An uncertain network response cannot refund it or start another provider call.
    async settleDailyBudget() {
      if (!budgetRecord) throw new Error("Missing provider allowance.");
      return budgetRecord;
    },
  };
  return { workerAdapter, budgetAdapter };
}
