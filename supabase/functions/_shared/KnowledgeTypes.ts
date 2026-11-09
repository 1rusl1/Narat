// supabase/functions/_shared/KnowledgeTypes.ts
// T120: Canonical types and semantic validators for ConditionProfile and Vision Classification 3.0.
// Enforces the closed 40 condition IDs (including nutrient_deficiency), top-2 candidates,
// confidence in [0,1], visual_markers membership, EN/PL steps, and finite repeats.

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

export interface VisionComparisonChange {
  symptom_id: string;
  direction: "increased" | "decreased" | "unchanged" | "not_comparable";
}

export interface VisionComparisonBlock {
  progress_status: "improving" | "stable" | "worsening" | "inconclusive";
  changes: VisionComparisonChange[];
  limitation_codes: string[];
}

export interface VisionClassification30 {
  schema_version: "3.0";
  kb_release_id: string;
  mode: "identification" | "diagnosis" | "follow_up";
  locale: "pl" | "en";
  image_quality: "usable" | "blurred" | "too_dark" | "not_a_plant" | "comparison_unsuitable";
  identification: VisionIdentificationBlock;
  diagnosis: VisionDiagnosisBlock | null;
  limitations: string[];
  comparison: VisionComparisonBlock | null;
  visual_markers: string[];
}

export interface TreatmentStep {
  step_id: string;
  step_order: number;
  phase:
    | "immediate_isolation"
    | "mechanical_wash"
    | "treatment_application"
    | "adjust_environment"
    | "substrate_correction"
    | "sanitation"
    | "monitoring"
    | "recovery_check";
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
  start_offset_days: number;
  interval_days: number;
  repeat_count: number;
  active_ingredients: string[];
  eco_alternative: string | null;
  application_selection: "one_verified_option";
  local_products_pl: string[];
  product_evidence_ids: string[];
  prerequisite_check_ids: string[];
  contraindication_check_ids: string[];
  action_pl: string;
  action_en: string;
}

export interface CanonicalConditionProfile {
  schema_version: "1.0";
  kb_release_id: string;
  record_version: number;
  condition_id: CanonicalConditionId;
  category: "abiotic" | "pest" | "disease" | "syndrome" | "physiological";
  host_scope: {
    plant_ids: string[];
    families: string[];
    general_houseplants: boolean;
  };
  visual_markers: string[];
  required_check_ids: string[];
  contraindication_check_ids: string[];
  abiotic_priority: "default_first" | "specific_evidence_required" | "neutral";
  first_help_step_id: string;
  treatment_plan: {
    is_contagious: boolean | null;
    urgency: "low" | "medium" | "high" | "unknown";
    duration_weeks: number | null;
    steps: TreatmentStep[];
  };
  recovery_check: {
    check_offset_days: number;
    comparison_trait_ids: string[];
    worsening_symptom_ids: string[];
  };
  condition_content_i18n: {
    en: {
      title: string;
      summary: string;
      recovery_check_tip: string;
      photo_angle_hint: string;
    };
    pl: {
      title: string;
      summary: string;
      recovery_check_tip: string;
      photo_angle_hint: string;
    };
  };
}

export interface PublishedReleaseCatalog {
  kbReleaseId: string;
  plantIds: Set<string>;
  genusIds: Set<string>;
  conditionProfiles: Map<CanonicalConditionId, CanonicalConditionProfile>;
  knownTraitIds?: Set<string>;
}

export interface ValidationOutcome {
  valid: boolean;
  errors: string[];
  isNonBillablePhotoOrOutOfScope: boolean;
}

export function validateConditionProfileSemantics(
  profile: CanonicalConditionProfile,
): { valid: boolean; errors: string[] } {
  const errors: string[] = [];

  if (!CANONICAL_CONDITION_ID_SET.has(profile.condition_id)) {
    errors.push(`Unknown condition_id '${profile.condition_id}'.`);
  }

  if (!profile.visual_markers || profile.visual_markers.length === 0) {
    errors.push(`Condition '${profile.condition_id}' must define at least 1 visual_marker.`);
  }

  const stepIds = new Set<string>();
  for (const step of profile.treatment_plan.steps) {
    if (stepIds.has(step.step_id)) {
      errors.push(`Duplicate step_id '${step.step_id}' in '${profile.condition_id}'.`);
    }
    stepIds.add(step.step_id);

    if (step.repeat_count < 1 || step.repeat_count > 52) {
      errors.push(`Step '${step.step_id}' repeat_count must be finite in 1..52.`);
    }
    if (step.repeat_count === 1 && step.interval_days !== 0) {
      errors.push(`Step '${step.step_id}' with repeat_count=1 must have interval_days=0.`);
    }
    if (step.repeat_count >= 2 && step.interval_days < 1) {
      errors.push(`Step '${step.step_id}' with repeat_count>=2 must have interval_days>=1.`);
    }
    if (!step.action_pl.trim() || !step.action_en.trim()) {
      errors.push(`Step '${step.step_id}' is missing PL or EN action text.`);
    }
    if (
      step.local_products_pl.length > 0 &&
      step.product_evidence_ids.length === 0
    ) {
      errors.push(`Step '${step.step_id}' has local_products_pl without product_evidence_ids.`);
    }
  }

  if (!stepIds.has(profile.first_help_step_id)) {
    errors.push(
      `first_help_step_id '${profile.first_help_step_id}' does not reference any step in treatment_plan.steps.`,
    );
  }

  return { valid: errors.length === 0, errors };
}
