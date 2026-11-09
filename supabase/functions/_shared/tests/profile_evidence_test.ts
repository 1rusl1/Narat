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
  };
  return {
    schema_version: "2.0",
    kb_release_id: "88888888-8888-4888-8888-888888888888",
    record_version: 1,
    provenance: provenance("/visual_markers"),
    condition_id: "overwatering",
    host_scope: {
      plant_ids: ["synthetic_plant"], families: [], general_houseplants: false,
    },
    visual_markers: ["synthetic_marker"],
    contraindication_check_ids: [],
    first_help_action_id: "synthetic_action",
    actions: [{
      action_id: "synthetic_action", action_code: "observe", purpose: "observation",
      next_check_interval_days: null,
      prerequisite_check_ids: [], contraindication_check_ids: [],
      action_en: "Synthetic observation only", action_pl: "Wyłącznie fikcyjna obserwacja",
    }],
    condition_content_i18n: { en: content, pl: { ...content } },
  };
}

function plantProfile() {
  return {
    schema_version: "2.0",
    kb_release_id: "88888888-8888-4888-8888-888888888888",
    record_version: 1,
    provenance: provenance("/actions/0"),
    plant_id: "synthetic_plant",
    actions: [{
      action_id: "synthetic_check", action_code: "check_soil", purpose: "diagnostic_check",
      next_check_interval_days: null,
      prerequisite_check_ids: [], contraindication_check_ids: [],
      action_en: "Synthetic check only", action_pl: "Wyłącznie fikcyjna kontrola",
    }],
  };
}

function safetyOnlyProfile() {
  return {
    ...plantProfile(),
    provenance: provenance("/safety"),
    actions: [],
    safety: legacyPlantProfile().safety,
  };
}

// Frozen synthetic v1 shape for historical-read regression; never used for new advice.
function legacyPlantProfile() {
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

  Deno.test(`T157 ${name}: null interval stays unknown; checked bounds are accepted`, () => {
    const profile = makeProfile();
    const before = structuredClone(profile);
    assertEquals(validate(profile), true, JSON.stringify(validate.errors));
    assertEquals(profile.actions[0].next_check_interval_days, null);
    assertEquals(profile, before);
    for (const days of [1, 90]) {
      assertEquals(validate(changed(profile, ["actions", "0", "next_check_interval_days"], days)),
        true, JSON.stringify(validate.errors));
    }
  });

  Deno.test(`T157 ${name}: old version is rejected without conversion or mutation`, () => {
    const historical = changed(makeProfile(), ["schema_version"], "1.0");
    const before = structuredClone(historical);
    assertEquals(validate(historical), false);
    assert(validate.errors?.some((error) => error.keyword === "const"));
    assertEquals(historical, before);
  });

  if (name === "plant-profile") {
    Deno.test("T157 plant-profile: v1 snapshot stays readable only under its legacy schema", () => {
      const legacyValidate = ajv.compile(JSON.parse(Deno.readTextFileSync(new URL(
        "../../../../specs/001-plants-ios-mvp/contracts/legacy/plant-profile.v1.schema.json",
        import.meta.url,
      ))));
      const historical = legacyPlantProfile();
      const before = structuredClone(historical);
      assertEquals(legacyValidate(historical), true, JSON.stringify(legacyValidate.errors));
      assertEquals(validate(historical), false);
      assert(validate.errors?.some((error) => error.keyword === "const"));
      assertEquals(historical, before);
      assertEquals(legacyValidate(historical), true, JSON.stringify(legacyValidate.errors));
    });

    Deno.test("T157 plant-profile: independent check needs no full profile or safety", () => {
      const profile = plantProfile();
      assertEquals(validate(profile), true, JSON.stringify(validate.errors));
      assertEquals(profile.actions.length, 1);
      assertEquals(profile.actions[0].action_code, "check_soil");
      for (const field of ["safety", "taxonomy", "care_algorithm_params", "soil_preset", "fertilizing"]) {
        assertEquals(field in profile, false);
      }
    });

    Deno.test("T157 plant-profile: safety-only preserves unknown pets and has no care actions", () => {
      const profile = safetyOnlyProfile();
      const before = structuredClone(profile);
      assertEquals(validate(profile), true, JSON.stringify(validate.errors));
      assertEquals(profile.actions, []);
      assertEquals(profile.safety.is_toxic_to_pets, null);
      for (const pet of ["cat", "dog"] as const) {
        assertEquals(profile.safety.pet_specific[pet].status, "unknown");
        assertEquals(profile.safety.pet_specific[pet].source_ids, []);
      }
      assertEquals(profile, before);
    });

    for (const field of ["provenance", "actions", "plant_id"]) {
      Deno.test(`T157 plant-profile: safety-only cannot bypass ${field}`, () => {
        assertEquals(validate(changed(safetyOnlyProfile(), [field], undefined)), false);
      });
    }
    for (const pet of ["cat", "dog"]) {
      Deno.test(`T157 plant-profile: safety-only requires ${pet} declaration`, () => {
        assertEquals(validate(changed(safetyOnlyProfile(), ["safety", "pet_specific", pet], undefined)),
          false);
      });
    }
    for (const safety of [null, {}, { is_toxic_to_pets: false }]) {
      Deno.test(`T157 plant-profile: incomplete safety ${JSON.stringify(safety)} is rejected`, () => {
        assertEquals(validate(changed(safetyOnlyProfile(), ["safety"], safety)), false);
      });
    }
  }

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
  invalidCases.push(
    ["missing actions", ["actions"], undefined, "required"],
    ["empty actions without safety", ["actions"], [], "minItems"],
    ["invalid action code", ["actions", "0", "action_code"], "invent_advice", "enum"],
    ["invalid purpose", ["actions", "0", "purpose"], "instant_cure", "enum"],
    ["invalid action id", ["actions", "0", "action_id"], "", "pattern"],
    ["missing prerequisites", ["actions", "0", "prerequisite_check_ids"], undefined, "required"],
    ["missing contraindications", ["actions", "0", "contraindication_check_ids"], undefined, "required"],
    ["missing interval", ["actions", "0", "next_check_interval_days"], undefined, "required"],
  );
  for (const locale of ["en", "pl"]) {
    invalidCases.push(
      [`missing action ${locale}`, ["actions", "0", `action_${locale}`], undefined, "required"],
      [`empty action ${locale}`, ["actions", "0", `action_${locale}`], "", "minLength"],
    );
    if (name === "condition-profile") {
      invalidCases.push(
        [`missing content ${locale}`, ["condition_content_i18n", locale], undefined, "required"],
      );
    }
  }
  for (const interval of [-1, 0, 91, 1.5, "7", "unknown", false]) {
    invalidCases.push([
      `invalid interval ${JSON.stringify(interval)}`,
      ["actions", "0", "next_check_interval_days"], interval, "anyOf",
    ]);
  }
  // Reject legacy/full-profile and timeline/recipe fields at both object boundaries.
  for (const field of [
    "treatment_plan", "first_help_step_id", "timeline", "duration_days", "steps",
    "repeat_count", "start_offset_days", "order", "soil_recipe", "soil_preset",
    "care_algorithm_params", "environment_modifiers", "fertilizing", "active_months",
    "taxonomy", "care_content_i18n", "base_watering_interval_days",
  ]) {
    for (const path of [[field], ["actions", "0", field]]) {
      invalidCases.push([`banned ${path.join("/")}`, path, {}, "additionalProperties"]);
    }
  }
  for (const [label, path, value, keyword] of invalidCases) {
    if (name === "plant-profile" && path[0] === "provenance") {
      Deno.test(`T157 plant-profile: safety-only rejects ${label}`, () => {
        assertEquals(validate(changed(safetyOnlyProfile(), path, value)), false, label);
        assert(validate.errors?.some((error) => error.keyword === keyword),
          JSON.stringify(validate.errors));
      });
    }
    Deno.test(`T157 ${name}: rejects ${label}`, () => {
      assertEquals(validate(changed(makeProfile(), path, value)), false, label);
      assert(validate.errors?.some((error) => error.keyword === keyword),
        JSON.stringify(validate.errors));
    });
  }
}
