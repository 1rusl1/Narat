import { assert, assertEquals } from "@std/assert";
import Ajv2020Import from "ajv/dist/2020";

const Ajv2020 = (Ajv2020Import as unknown as { default?: typeof Ajv2020Import.default }).default ??
  (Ajv2020Import as unknown as typeof Ajv2020Import.default);
const ajv = new Ajv2020({ allErrors: true, strict: false });
ajv.addFormat("uuid", /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
ajv.addFormat("uri", (value: string) => {
  try {
    return Boolean(new URL(value).protocol);
  } catch {
    return false;
  }
});
ajv.addFormat("date-time", (value: string) =>
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/i.test(value) &&
  Number.isFinite(Date.parse(value)));

// Entire profiles and evidence are synthetic, local regression fixtures.
// Schema acceptance proves neither factual review nor registry/pipeline permission.
// In particular, derived_records does not grant automated collection or LLM use.
function source(id = "one") {
  return {
    source_id: `synthetic_${id}`,
    url: `https://example.invalid/synthetic-evidence/${id}`,
    retrieved_at: "2026-11-09T00:00:00Z",
    content_hash: "a".repeat(64),
    use_basis: "Synthetic fixture only; no verified recommendations or real use rights",
    allowed_for: ["derived_records"],
  };
}

function provenance(field: string) {
  return {
    source_documents: [source()],
    field_evidence: {
      [field]: [{
        source_id: "synthetic_one",
        locator: "Synthetic fixture section 1",
        scope: "Regression only; not verified plant advice",
      }],
    },
    validation: {
      method: "manual_review",
      validated_at: "2026-11-09T00:00:00Z",
      unresolved_conflicts: [] as string[],
    },
  };
}

function conditionProfile() {
  const content = {
    title: "Synthetic condition",
    summary: "Synthetic fixture; not advice",
    recovery_check_tip: "Synthetic observation",
    photo_angle_hint: "Synthetic photo hint",
  };
  return {
    schema_version: "1.0",
    kb_release_id: "88888888-8888-4888-8888-888888888888",
    record_version: 1,
    provenance: provenance("/visual_markers"),
    condition_id: "overwatering",
    category: "abiotic",
    host_scope: {
      plant_ids: ["synthetic_plant"], families: [], general_houseplants: false,
    },
    visual_markers: ["synthetic_marker"],
    required_check_ids: [],
    contraindication_check_ids: [],
    abiotic_priority: "default_first",
    first_help_step_id: "synthetic_step",
    treatment_plan: {
      is_contagious: null,
      urgency: "unknown",
      duration_weeks: null,
      steps: [{
        step_id: "synthetic_step", step_order: 1, phase: "monitoring",
        action_code: "observe", purpose: "observation", start_offset_days: 0,
        interval_days: 0, repeat_count: 1, active_ingredients: [], eco_alternative: null,
        application_selection: "one_verified_option", local_products_pl: [],
        product_evidence_ids: [], prerequisite_check_ids: [], contraindication_check_ids: [],
        action_en: "Synthetic observation only", action_pl: "Wyłącznie fikcyjna obserwacja",
      }],
    },
    recovery_check: {
      check_offset_days: 1,
      comparison_trait_ids: ["synthetic_trait"],
      worsening_symptom_ids: ["synthetic_symptom"],
    },
    condition_content_i18n: { en: content, pl: { ...content } },
  };
}

function plantProfile() {
  const content = {
    watering_tip: "Synthetic fixture; not advice",
    soil_recipe: "Synthetic fixture; not advice",
    light_tip: "Synthetic fixture; not advice",
    fertilizing_tip: "Synthetic fixture; not advice",
    safety_note: "Unknown; synthetic fixture",
  };
  return {
    schema_version: "1.0",
    kb_release_id: "88888888-8888-4888-8888-888888888888",
    record_version: 1,
    provenance: provenance("/taxonomy/scientific_name"),
    plant_id: "synthetic_plant",
    taxonomy: {
      scientific_name: "Synthetic plant", synonyms: [], family: "Synthetic family",
      common_names: { en: ["Synthetic plant"], pl: ["Fikcyjna roślina"] },
    },
    safety: {
      is_toxic_to_pets: null, toxin_type: null, severity: "unknown",
      pet_specific: {
        cat: { status: "unknown", source_ids: [] },
        dog: { status: "unknown", source_ids: [] },
      },
      unknown_reason_code: "synthetic_fixture",
    },
    care_algorithm_params: {
      watering_strategy: "unknown", dry_depth_cm: null,
      base_watering_interval_days: { summer: null, winter: null },
      environment_modifiers: {
        low_light_multiplier: null, terracotta_pot_multiplier: null,
        heating_season_multiplier: null,
      },
      watering_schedule_policy: {
        locality: "PL", summer_months: [6, 7, 8], winter_months: [12, 1, 2],
        min_check_interval_days: null, max_check_interval_days: null,
        unknown_conditions_protocol_id: "synthetic_unknown",
      },
      light_requirements: {
        ideal_fc_range: null, min_survival_fc: null, direct_sun_tolerance: "unknown",
      },
      soil_preset: "chunky_aroid_mix",
      fertilizing: { active_months: [], frequency_days: null, recommended_npk: null },
    },
    common_vulnerabilities: [],
    care_content_i18n: { en: content, pl: { ...content } },
  };
}

function changed(profile: unknown, path: string[], value: unknown): unknown {
  const result = structuredClone(profile) as Record<string, unknown>;
  let target = result;
  for (const key of path.slice(0, -1)) {
    target = target[key] as Record<string, unknown>;
  }
  const key = path[path.length - 1];
  if (value === undefined) delete target[key];
  else target[key] = value;
  return result;
}

for (const [name, makeProfile] of [
  ["condition-profile", conditionProfile],
  ["plant-profile", plantProfile],
] as const) {
  const validate = ajv.compile(JSON.parse(Deno.readTextFileSync(new URL(
    `../../../../specs/001-plants-ios-mvp/contracts/${name}.schema.json`,
    import.meta.url,
  ))));

  Deno.test(`T157 ${name}: single-source manual review without synthesis metadata`, () => {
    const profile = makeProfile();
    assertEquals(validate(profile), true, JSON.stringify(validate.errors));
    assertEquals(profile.provenance.source_documents.length, 1);
    for (const key of ["donor_id", "independence_group"]) {
      assertEquals(key in profile.provenance.source_documents[0], false);
    }
    for (const key of ["synthesis_model", "prompt_version", "guardrail_version"]) {
      assertEquals(key in profile.provenance.validation, false);
    }
  });

  Deno.test(`T157 ${name}: historical multi-source with full metadata`, () => {
    const profile = makeProfile();
    const historical = {
      ...profile,
      provenance: {
        ...profile.provenance,
        source_documents: ["one", "two", "three"].map((id) => ({
          ...source(id), donor_id: `synthetic_donor_${id}`,
          independence_group: `synthetic_group_${id}`,
          allowed_for: [
            "commercial_storage", "automated_collection", "llm_processing", "derived_records",
          ],
        })),
        validation: {
          ...profile.provenance.validation, method: "multi_source_rules",
          synthesis_model: "synthetic_model", prompt_version: "synthetic_prompt",
          guardrail_version: "synthetic_guardrail",
        },
      },
    };
    assertEquals(validate(historical), true, JSON.stringify(validate.errors));
  });

  const p = ["provenance"];
  const s = [...p, "source_documents", "0"];
  const v = [...p, "validation"];
  const invalidCases: [string, string[], unknown, string][] = [
    ["missing provenance", p, undefined, "required"],
    ["missing sources", [...p, "source_documents"], undefined, "required"],
    ["zero sources", [...p, "source_documents"], [], "minItems"],
    ["missing rights", [...s, "use_basis"], undefined, "required"],
    ["empty rights", [...s, "use_basis"], "", "minLength"],
    ["missing permissions", [...s, "allowed_for"], undefined, "required"],
    ["empty permissions", [...s, "allowed_for"], [], "minItems"],
    ["invalid permission", [...s, "allowed_for"], ["unrestricted"], "enum"],
    ["duplicate permissions", [...s, "allowed_for"], ["derived_records", "derived_records"], "uniqueItems"],
    ["missing URL", [...s, "url"], undefined, "required"],
    ["invalid URL", [...s, "url"], "not a URI", "format"],
    ["invalid hash", [...s, "content_hash"], "invalid", "pattern"],
    ["missing field evidence", [...p, "field_evidence"], undefined, "required"],
    ["empty field evidence", [...p, "field_evidence"], {}, "minProperties"],
    ["missing review", v, undefined, "required"],
    ["missing review date", [...v, "validated_at"], undefined, "required"],
    ["invalid review date", [...v, "validated_at"], "invalid", "format"],
    ["invalid method", [...v, "method"], "llm_only", "enum"],
    ["missing conflicts declaration", [...v, "unresolved_conflicts"], undefined, "required"],
    ["unresolved conflict", [...v, "unresolved_conflicts"], ["synthetic conflict"], "maxItems"],
    ["invalid optional donor", [...s, "donor_id"], "", "pattern"],
    ["invalid optional group", [...s, "independence_group"], "", "pattern"],
    ["empty optional model", [...v, "synthesis_model"], "", "minLength"],
    ["empty optional prompt", [...v, "prompt_version"], "", "minLength"],
    ["empty optional guardrail", [...v, "guardrail_version"], "", "minLength"],
  ];
  for (const [label, path, value, keyword] of invalidCases) {
    Deno.test(`T157 ${name}: rejects ${label}`, () => {
      assertEquals(validate(changed(makeProfile(), path, value)), false, label);
      assert(validate.errors?.some((error) => error.keyword === keyword),
        JSON.stringify(validate.errors));
    });
  }
}
