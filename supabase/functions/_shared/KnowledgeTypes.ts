// supabase/functions/_shared/KnowledgeTypes.ts
// T120: Canonical types and semantic validators for ConditionProfile and Vision Classification 3.0.
// Enforces the closed 40 condition IDs (including nutrient_deficiency), top-2 candidates,
// confidence in [0,1], visual_markers membership, and compact EN/PL actions.

import Ajv2020Import from "ajv/dist/2020";
import conditionProfileSchema from "../../../specs/001-plants-ios-mvp/contracts/condition-profile.schema.json" with { type: "json" };
import plantProfileSchema from "../../../specs/001-plants-ios-mvp/contracts/plant-profile.schema.json" with { type: "json" };

export const CANONICAL_CONDITION_IDS = [
  "overwatering",
  "underwatering",
  "poor_drainage",
  "root_rot",
  "low_light",
  "sunburn",
  "cold_stress",
  "heat_stress",
  "low_humidity",
  "fertilizer_burn",
  "nutrient_deficiency",
  "salt_buildup",
  "nitrogen_deficiency",
  "iron_chlorosis",
  "potassium_deficiency",
  "magnesium_deficiency",
  "ph_imbalance",
  "root_bound",
  "transplant_shock",
  "acclimation_stress",
  "edema",
  "mechanical_damage",
  "chemical_phytotoxicity",
  "natural_leaf_senescence",
  "thrips_infestation",
  "spider_mites",
  "mealybugs",
  "scale_insects",
  "aphids",
  "whiteflies",
  "fungus_gnats",
  "broad_mites",
  "powdery_mildew",
  "grey_mould",
  "fungal_leaf_spot",
  "bacterial_leaf_spot",
  "bacterial_soft_rot",
  "crown_rot",
  "sooty_mould",
  "suspected_viral_disease",
] as const;

export type CanonicalConditionId = typeof CANONICAL_CONDITION_IDS[number];

export const CANONICAL_CONDITION_ID_SET = new Set<string>(CANONICAL_CONDITION_IDS);

export const CANONICAL_LIMITATION_CODES = [
  "single_angle",
  "lighting_uncertain",
  "species_uncertain",
  "symptoms_early_or_ambiguous",
  "root_inspection_needed",
  "pest_microscopy_needed",
  "no_visible_plant",
  "blurry_image",
  "too_dark",
  "too_far",
] as const;

export type CanonicalLimitationCode = typeof CANONICAL_LIMITATION_CODES[number];
export const CANONICAL_LIMITATION_CODE_SET = new Set<string>(CANONICAL_LIMITATION_CODES);

export interface VisionIdentificationBlock {
  status: "identified" | "genus_only" | "unknown" | "out_of_scope";
  plant_id: string | null;
  genus_id: string | null;
}

export interface VisionDiagnosisCandidate {
  condition_id: CanonicalConditionId;
  rank: 1 | 2;
  confidence: number;
}

export interface VisionDiagnosisBlock {
  status: "problem_detected" | "healthy" | "insufficient_data" | "out_of_scope";
  candidates: VisionDiagnosisCandidate[];
}

export interface VisionClassification30 {
  schema_version: "3.0";
  kb_release_id: string;
  mode: "identification" | "diagnosis";
  locale: "pl" | "en";
  image_quality: "usable" | "blurred" | "too_dark" | "not_a_plant";
  identification: VisionIdentificationBlock;
  diagnosis: VisionDiagnosisBlock | null;
  limitations: string[];
  visual_markers: string[];
}

export interface ProfileAction {
  action_id: string;
  action_code:
    | "check_soil"
    | "inspect_roots"
    | "inspect_leaves"
    | "observe"
    | "water"
    | "fertilize"
    | "repot"
    | "prune"
    | "isolate"
    | "wash_pests"
    | "treat_pests"
    | "adjust_light"
    | "adjust_humidity"
    | "check_up";
  purpose:
    | "diagnostic_check"
    | "routine_care"
    | "humidity_management"
    | "pest_removal"
    | "treatment"
    | "observation";
  next_check_interval_days: number | null;
  active_ingredients?: string[];
  prerequisite_check_ids: string[];
  contraindication_check_ids: string[];
  action_pl: string;
  action_en: string;
}

export interface ProfileProvenance {
  source_documents: Array<{
    source_id: string;
    donor_id?: string;
    independence_group?: string;
    url: string;
    retrieved_at: string;
    content_hash: string;
    use_basis: string;
    allowed_for: Array<
      "commercial_storage" | "automated_collection" | "llm_processing" | "derived_records"
    >;
  }>;
  field_evidence: Record<string, Array<{ source_id: string; locator: string; scope: string }>>;
  validation: {
    method: "manual_review" | "multi_source_rules";
    synthesis_model?: string;
    prompt_version?: string;
    guardrail_version?: string;
    validated_at: string;
    unresolved_conflicts: string[];
  };
}

export interface CanonicalConditionProfile {
  schema_version: "2.0";
  kb_release_id: string;
  record_version: number;
  provenance: ProfileProvenance;
  condition_id: CanonicalConditionId;
  host_scope: {
    plant_ids: string[];
    families: string[];
    general_houseplants: boolean;
  };
  visual_markers: string[];
  contraindication_check_ids: string[];
  first_help_action_id: string;
  actions: ProfileAction[];
  condition_content_i18n: {
    en: {
      title: string;
      summary: string;
    };
    pl: {
      title: string;
      summary: string;
    };
  };
}

export interface CanonicalPlantCareProfile {
  schema_version: "2.0";
  kb_release_id: string;
  record_version: number;
  plant_id: string;
  provenance: ProfileProvenance;
  actions: ProfileAction[];
}

export interface PublishedReleaseCatalog {
  kbReleaseId: string;
  plantIds: Set<string>;
  plantScientificNames?: Map<string, string>;
  genusIds: Set<string>;
  conditionProfiles: Map<CanonicalConditionId, CanonicalConditionProfile>;
}

export interface ValidationOutcome {
  valid: boolean;
  errors: string[];
  isNonBillablePhotoOrOutOfScope: boolean;
}

// Use the publication schema at the runtime boundary too: legacy/malformed records
// must fail before the resolver reads compact fields. No v1 conversion is performed.
const Ajv2020 = (Ajv2020Import as unknown as { default?: typeof Ajv2020Import.default }).default ??
  (Ajv2020Import as unknown as typeof Ajv2020Import.default);
const profileAjv = new Ajv2020({ allErrors: true, strict: false });
profileAjv.addFormat("uuid", /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
profileAjv.addFormat("uri", (value: string) => {
  try {
    return Boolean(new URL(value).protocol);
  } catch {
    return false;
  }
});
profileAjv.addFormat("date-time", (value: string) =>
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/i.test(value) &&
  Number.isFinite(Date.parse(value)));
const validatePublishedCondition = profileAjv.compile<CanonicalConditionProfile>(conditionProfileSchema);
export const validatePublishedPlantCare = profileAjv.compile<CanonicalPlantCareProfile>(plantProfileSchema);

export function validateConditionProfileSemantics(
  raw: unknown,
): { valid: boolean; errors: string[] } {
  if (!validatePublishedCondition(raw)) {
    return {
      valid: false,
      errors: (validatePublishedCondition.errors ?? []).map((error) =>
        `${error.instancePath || "/"}: ${error.message ?? "schema violation"}`
      ),
    };
  }
  const profile = raw;
  const errors: string[] = [];
  const actionIds = new Set<string>();
  for (const action of profile.actions) {
    if (actionIds.has(action.action_id)) {
      errors.push(`Duplicate action_id '${action.action_id}' in '${profile.condition_id}'.`);
    }
    actionIds.add(action.action_id);
    if (!action.action_pl.trim() || !action.action_en.trim()) {
      errors.push(`Action '${action.action_id}' is missing PL or EN action text.`);
    }
  }
  if (!actionIds.has(profile.first_help_action_id)) {
    errors.push(
      `first_help_action_id '${profile.first_help_action_id}' does not reference any action.`,
    );
  }
  for (const locale of ["en", "pl"] as const) {
    const content = profile.condition_content_i18n[locale];
    if (!content.title.trim() || !content.summary.trim()) {
      errors.push(`Condition '${profile.condition_id}' is missing ${locale} title or summary.`);
    }
  }
  return { valid: errors.length === 0, errors };
}
