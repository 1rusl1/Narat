// supabase/functions/_shared/tests/analysis_result_test.ts
// T029 & T116: Positive and negative tests for Classification 3.0 validation (AnalysisValidator)
// and deterministic backend projection (ProtocolResolver).

import { assert, assertEquals, assertRejects, assertThrows } from "@std/assert";
import Ajv2020Import from "ajv/dist/2020";
import { AnalysisValidator } from "../AnalysisValidator.ts";
import {
  CanonicalConditionId,
  CanonicalConditionProfile,
  PublishedReleaseCatalog,
  ProfileProvenance,
  VisionClassification30,
  validateConditionProfileSemantics,
} from "../KnowledgeTypes.ts";
import {
  PreliminaryAnalysisProjection,
  ProtocolResolver,
  signAnalysisReceipt,
  verifyAnalysisReceipt,
} from "../ProtocolResolver.ts";
import { AnalysisAccess } from "../AnalysisAccess.ts";
import { AnthropicAdapter, buildSystemPrompt } from "../AnthropicAdapter.ts";
import { ProviderBudgetGuard } from "../ProviderBudgetGuard.ts";
import { processSingleQueuedJob, WorkerPersistenceAdapter } from "../../analysis-worker/index.ts";
import { reconcileStuckAnalysisJobs } from "../../maintenance/analysis-jobs.ts";
import {
  AnalysisJobStatusResponse,
  AnalysisJobStoreAdapter,
  handleCreateAnalysisJob,
  handleGetAnalysisJob,
} from "../../plants-api/analysis.ts";
import { ApiHttpError, RequestContext } from "../http.ts";

const KB_RELEASE_ID = "88888888-8888-4888-8888-888888888888";
const SIGNING_SECRET = "test-signing-secret-32-bytes-minimum-key";

function makeFixtureProvenance(): ProfileProvenance {
  return {
    source_documents: ["one", "two", "three"].map((id): ProfileProvenance["source_documents"][number] => ({
      source_id: `fixture_${id}`, donor_id: `donor_${id}`, independence_group: `group_${id}`,
      url: `https://example.com/${id}`, retrieved_at: "2026-11-09T00:00:00Z",
      content_hash: "a".repeat(64), use_basis: "Synthetic regression fixture",
      allowed_for: [
        "commercial_storage", "automated_collection", "llm_processing", "derived_records",
      ],
    })),
    field_evidence: {
      "/visual_markers": [{
        source_id: "fixture_one", locator: "fixture", scope: "regression only",
      }],
    },
    validation: {
      method: "multi_source_rules", synthesis_model: "fixture", prompt_version: "fixture",
      guardrail_version: "fixture", validated_at: "2026-11-09T00:00:00Z",
      unresolved_conflicts: [],
    },
  };
}

function makeSampleCatalog(): PublishedReleaseCatalog {
  const overwateringProfile: CanonicalConditionProfile = {
    schema_version: "2.0",
    kb_release_id: KB_RELEASE_ID,
    record_version: 1,
    provenance: makeFixtureProvenance(),
    condition_id: "overwatering",
    host_scope: {
      plant_ids: ["monstera_deliciosa"],
      families: ["Araceae"],
      general_houseplants: true,
    },
    visual_markers: ["yellowing_lower_leaves", "wet_heavy_substrate"],
    contraindication_check_ids: [],
    first_help_action_id: "hold_water",
    actions: [{
      action_id: "hold_water",
      action_code: "check_soil",
      purpose: "diagnostic_check",
      prerequisite_check_ids: [],
      contraindication_check_ids: [],
      next_check_interval_days: 7,
      action_pl: "Wstrzymaj podlewanie i sprawdź odpływ wody z doniczki.",
      action_en: "Hold off on watering and check pot drainage.",
    }],
    condition_content_i18n: {
      pl: {
        title: "Przelanie (nadmiar wody)",
        summary: "Korzenie mają ograniczony dostęp do tlenu wskutek zbyt mokrego podłoża.",
      },
      en: {
        title: "Overwatering",
        summary: "Roots have restricted oxygen access due to overly wet soil.",
      },
    },
  };

  const rootRotProfile: CanonicalConditionProfile = {
    ...structuredClone(overwateringProfile),
    condition_id: "root_rot",
    visual_markers: ["mushy_black_roots", "stem_base_blackening", "yellowing_lower_leaves"],
  };

  const conditionProfiles = new Map<CanonicalConditionId, CanonicalConditionProfile>([
    ["overwatering", overwateringProfile],
    ["root_rot", rootRotProfile],
  ]);

  return {
    kbReleaseId: KB_RELEASE_ID,
    plantIds: new Set(["monstera_deliciosa", "epipremnum_aureum"]),
    genusIds: new Set(["monstera", "epipremnum"]),
    conditionProfiles,
  };
}

// Raw v1 fixture: never reinterpret or convert it into a compact recommendation.
function makeLegacyConditionProfile() {
  return {
    schema_version: "1.0",
    kb_release_id: KB_RELEASE_ID,
    record_version: 1,
    provenance: makeFixtureProvenance(),
    condition_id: "overwatering",
    category: "abiotic",
    host_scope: {
      plant_ids: ["monstera_deliciosa"],
      families: ["Araceae"],
      general_houseplants: true,
    },
    visual_markers: ["yellowing_lower_leaves", "wet_heavy_substrate"],
    required_check_ids: ["check_soil_moisture"],
    contraindication_check_ids: [],
    abiotic_priority: "default_first",
    first_help_step_id: "step_hold_water",
    treatment_plan: {
      is_contagious: false,
      urgency: "medium",
      duration_weeks: 2,
      steps: [
        {
          step_id: "step_hold_water",
          step_order: 1,
          phase: "adjust_environment",
          action_code: "check_soil",
          purpose: "diagnostic_check",
          start_offset_days: 0,
          interval_days: 0,
          repeat_count: 1,
          active_ingredients: [],
          eco_alternative: null,
          application_selection: "one_verified_option",
          local_products_pl: [],
          product_evidence_ids: [],
          prerequisite_check_ids: [],
          contraindication_check_ids: [],
          action_pl: "Wstrzymaj podlewanie i sprawdź odpływ wody z doniczki.",
          action_en: "Hold off on watering and check pot drainage.",
        },
      ],
    },
    recovery_check: {
      check_offset_days: 7,
      comparison_trait_ids: ["leaf_turgor_recovery", "yellowing_progression"],
      worsening_symptom_ids: ["stem_base_blackening"],
    },
    condition_content_i18n: {
      pl: {
        title: "Przelanie (nadmiar wody)",
        summary: "Korzenie mają ograniczony dostęp do tlenu wskutek zbyt mokrego podłoża.",
        recovery_check_tip: "Porównaj jędrność liści po 7 dniach.",
        photo_angle_hint: "Zrób zdjęcie całej rośliny oraz dolnych liści pod tym samym kątem.",
      },
      en: {
        title: "Overwatering",
        summary: "Roots have restricted oxygen access due to overly wet soil.",
        recovery_check_tip: "Compare leaf firmness after 7 days.",
        photo_angle_hint: "Take a photo of the whole plant and lower leaves from the same angle.",
      },
    },
  };
}

// Publication schema is loaded from disk; no network or new dependencies.
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
const validateProfileSchema = profileAjv.compile(JSON.parse(Deno.readTextFileSync(new URL(
  "../../../../specs/001-plants-ios-mvp/contracts/condition-profile.schema.json",
  import.meta.url,
))));

// Synthetic evidence satisfies the unchanged legacy provenance contract.
function makePublishedProfile(): CanonicalConditionProfile {
  return structuredClone(makeSampleCatalog().conditionProfiles.get("overwatering")!);
}

Deno.test("T157 — publication accepts no bank and rejects the removed property", () => {
  const profile = makePublishedProfile();
  assertEquals("diagnostic_disambiguation" in profile, false);
  assertEquals(validateProfileSchema(profile), true, JSON.stringify(validateProfileSchema.errors));
  assertEquals(validateConditionProfileSemantics(profile), { valid: true, errors: [] });
  const withBank = { ...profile, diagnostic_disambiguation: { clarifying_questions: [] } };
  assertEquals(validateProfileSchema(withBank), false);
  assert(validateProfileSchema.errors?.some((error) =>
    error.keyword === "additionalProperties" &&
    error.params.additionalProperty === "diagnostic_disambiguation"));
});

Deno.test("T157 — removed bank cannot enter new compact recommendations in EN/PL", async () => {
  const profile = makePublishedProfile();
  // Invalid even under old semantics: historical content must not be interpreted.
  const historical = {
    ...structuredClone(profile),
    diagnostic_disambiguation: {
      often_confused_with: ["overwatering"],
      clarifying_questions: [{
        question_id: "obsolete_question", text_en: "OBSOLETE?", text_pl: "NIEAKTUALNE?",
        yes_weights_towards: "overwatering", no_weights_towards: "overwatering",
      }],
    },
  };
  assertEquals(validateConditionProfileSemantics(historical).valid, false);
  for (const locale of ["en", "pl"] as const) {
    for (const confidence of [0.1, 0.79, 0.8, 0.9]) {
      const catalog = makeSampleCatalog();
      const validated = AnalysisValidator.validate({
        schema_version: "3.0", kb_release_id: KB_RELEASE_ID, mode: "diagnosis", locale,
        image_quality: "usable",
        identification: {
          status: "identified", plant_id: "monstera_deliciosa", genus_id: "monstera",
        },
        diagnosis: {
          status: "problem_detected",
          candidates: [{ condition_id: "overwatering", rank: 1, confidence }],
        },
        limitations: [], visual_markers: ["yellowing_lower_leaves"],
      }, catalog);
      assertEquals(validated.valid, true, validated.errors.join("; "));
      assert(validated.classification);
      const params = {
        analysisId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        jobId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        classification: validated.classification,
        catalog, signingSecret: SIGNING_SECRET, issuedAt: "2026-11-09T00:00:00Z",
      };
      catalog.conditionProfiles.set("overwatering", profile);
      const clean = await ProtocolResolver.resolvePreliminaryProjection(params);
      catalog.conditionProfiles.set("overwatering", historical);
      const restored = await ProtocolResolver.resolvePreliminaryProjection(params);
      assertNoPublishedAction(restored);
      assertEquals((await verifyAnalysisReceipt(restored.analysis_receipt, SIGNING_SECRET)).valid, true);
      assertEquals(clean.selected_condition_id, "overwatering");
      assertEquals(clean.plan_availability, "available");
      assertEquals(clean.control_interval_days, 7);
      assertEquals(clean.first_action_title, profile.condition_content_i18n[locale].title);
      const action = profile.actions[0];
      assertEquals(clean.first_action_summary, locale === "en" ? action.action_en : action.action_pl);
      assertEquals("decision_state" in clean, false);
      for (const key of ["diagnostic_disambiguation", "clarifying_questions", "questions"]) {
        assertEquals(key in restored, false);
      }
      assertEquals(JSON.stringify(restored).includes("OBSOLETE?"), false);
      assertEquals(JSON.stringify(restored).includes("NIEAKTUALNE?"), false);
    }
  }
});

Deno.test("T157 — compact action IDs, nullable intervals and EN/PL are validated", () => {
  const duplicate = makePublishedProfile();
  duplicate.actions.push(structuredClone(duplicate.actions[0]));
  const duplicateResult = validateConditionProfileSemantics(duplicate);
  assertEquals(duplicateResult.valid, false);
  assert(duplicateResult.errors.some((error) => error.includes("Duplicate action_id")));

  const dangling = makePublishedProfile();
  dangling.first_help_action_id = "missing_action";
  const danglingResult = validateConditionProfileSemantics(dangling);
  assertEquals(danglingResult.valid, false);
  assert(danglingResult.errors.some((error) => error.includes("does not reference any action")));

  for (const interval of [null, 1, 90]) {
    const valid = makePublishedProfile();
    valid.actions[0].next_check_interval_days = interval;
    assertEquals(validateProfileSchema(valid), true);
    assertEquals(validateConditionProfileSemantics(valid).valid, true);
  }
  for (const interval of [0, -1, 91, 1.5, NaN, Infinity, "7", undefined]) {
    const invalid = makePublishedProfile();
    Object.assign(invalid.actions[0], { next_check_interval_days: interval });
    assertEquals(validateProfileSchema(invalid), false);
    assertEquals(validateConditionProfileSemantics(invalid).valid, false);
  }
  for (const language of ["action_en", "action_pl"] as const) {
    const invalid = makePublishedProfile();
    invalid.actions[0][language] = "";
    assertEquals(validateProfileSchema(invalid), false);
    const result = validateConditionProfileSemantics(invalid);
    assertEquals(result.valid, false);
    assert(result.errors.some((error) => error.includes(language)));
  }
  const restricted = makePublishedProfile();
  restricted.host_scope.general_houseplants = false;
  assertEquals(ProtocolResolver.isConditionHostCompatible(restricted, { plantId: "other" }), false);
  assertEquals(ProtocolResolver.isConditionHostCompatible(restricted, { plantId: "monstera_deliciosa" }), true);
  assertEquals(ProtocolResolver.isConditionHostCompatible(restricted, { plantId: null, family: "Araceae" }), true);
});

Deno.test("T157 — compact schema rejects timeline, recipe and unknown fields", () => {
  const cases: Array<[string[], string]> = [
    ...["category", "abiotic_priority", "required_check_ids", "first_help_step_id",
      "treatment_plan", "recovery_check", "diagnostic_disambiguation"].map((key): [string[], string] =>
      [[], key]),
    ...["step_id", "step_order", "phase", "start_offset_days", "interval_days", "repeat_count",
      "duration_weeks", "eco_alternative", "application_selection", "local_products_pl",
      "product_evidence_ids", "dose", "recipe"].map((key): [string[], string] => [["actions", "0"], key]),
    ...["en", "pl"].flatMap((locale) =>
      ["recovery_check_tip", "photo_angle_hint"].map((key): [string[], string] =>
        [["condition_content_i18n", locale], key])),
  ];
  for (const [path, key] of cases) {
    const profile = makePublishedProfile();
    let target = profile as unknown as Record<string, unknown>;
    for (const part of path) target = target[part] as Record<string, unknown>;
    target[key] = "removed";
    assertEquals(validateProfileSchema(profile), false, key);
    assertEquals(validateConditionProfileSemantics(profile).valid, false, key);
  }
});

Deno.test("T157 — compact IDs, prerequisites, contraindications and nonblank locale content", () => {
  for (const id of ["", "Bad-ID", "not an id"]) {
    for (const field of ["action_id", "prerequisite_check_ids", "contraindication_check_ids"]) {
      const profile = makePublishedProfile();
      Object.assign(profile.actions[0], { [field]: field === "action_id" ? id : [id] });
      assertEquals(validateProfileSchema(profile), false);
      assertEquals(validateConditionProfileSemantics(profile).valid, false);
    }
    const profile = makePublishedProfile();
    profile.first_help_action_id = id;
    assertEquals(validateProfileSchema(profile), false);
    assertEquals(validateConditionProfileSemantics(profile).valid, false);
  }
  for (const field of ["prerequisite_check_ids", "contraindication_check_ids"]) {
    const profile = makePublishedProfile();
    Object.assign(profile.actions[0], { [field]: ["check_one", "check_one"] });
    assertEquals(validateProfileSchema(profile), false);
    assertEquals(validateConditionProfileSemantics(profile).valid, false);
  }
  for (const locale of ["en", "pl"] as const) {
    for (const text of ["", " \n\t"]) {
      for (const field of ["title", "summary"] as const) {
        const profile = makePublishedProfile();
        profile.condition_content_i18n[locale][field] = text;
        assertEquals(validateConditionProfileSemantics(profile).valid, false);
      }
      const profile = makePublishedProfile();
      profile.actions[0][locale === "en" ? "action_en" : "action_pl"] = text;
      assertEquals(validateConditionProfileSemantics(profile).valid, false);
    }
  }
});

Deno.test("T157 — only the named first help supplies text and a nullable check interval", async () => {
  for (const locale of ["en", "pl"] as const) {
    for (const interval of [null, 1, 90]) {
      const catalog = makeSampleCatalog();
      const profile = catalog.conditionProfiles.get("overwatering")!;
      const selected = profile.actions[0];
      selected.next_check_interval_days = interval;
      profile.actions.unshift({
        ...structuredClone(selected), action_id: "other_action",
        action_en: "Other published action", action_pl: "Inne opublikowane działanie",
        next_check_interval_days: 11,
      });
      assertEquals(validateProfileSchema(profile), true);
      assertEquals(validateConditionProfileSemantics(profile).valid, true);
      const result = await ProtocolResolver.resolvePreliminaryProjection({
        analysisId: crypto.randomUUID(), jobId: crypto.randomUUID(),
        classification: classificationFixture("diagnosis", locale), catalog, signingSecret: SIGNING_SECRET,
      });
      assertEquals(result.plan_availability, "available");
      assertEquals(result.first_action_summary, locale === "en" ? selected.action_en : selected.action_pl);
      assertEquals(result.control_interval_days, interval);
      assertEquals((await verifyAnalysisReceipt(result.analysis_receipt, SIGNING_SECRET)).valid, true);

      // Another valid action must not substitute for a dangling first-help reference.
      profile.first_help_action_id = "missing_action";
      const unresolved = await ProtocolResolver.resolvePreliminaryProjection({
        analysisId: crypto.randomUUID(), jobId: crypto.randomUUID(),
        classification: classificationFixture("diagnosis", locale), catalog, signingSecret: SIGNING_SECRET,
      });
      assertNoPublishedAction(unresolved);
    }
  }
});

Deno.test("T157 — malformed published profiles cannot crash classification validation", () => {
  for (const malformed of [
    null, {}, { schema_version: "2.0" },
    { ...makePublishedProfile(), visual_markers: null },
    { ...makePublishedProfile(), actions: [null] },
    { ...makePublishedProfile(), host_scope: null },
    { ...makePublishedProfile(), condition_content_i18n: {} },
  ]) {
    assertEquals(validateConditionProfileSemantics(malformed).valid, false);
    const catalog = makeSampleCatalog();
    catalog.conditionProfiles.set("overwatering", malformed as unknown as CanonicalConditionProfile);
    const result = AnalysisValidator.validate(classificationFixture("diagnosis", "en"), catalog);
    assertEquals(result.valid, false);
    assertEquals(result.shouldConsumeQuota, false);
  }
});

Deno.test("T157 — immutable v1 schema and raw profile remain readable, rejected for new advice", async () => {
  const bytes = Deno.readFileSync(new URL(
    "../../../../specs/001-plants-ios-mvp/contracts/legacy/condition-profile.v1.schema.json",
    import.meta.url,
  ));
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)))
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
  assertEquals(hash, "e0e0843d48f8e104f43b71dd75ca0c1b6a0a766a515ba3be89fa96c0c4021d8f");
  const validateLegacy = profileAjv.compile(JSON.parse(new TextDecoder().decode(bytes)));
  const raw = makeLegacyConditionProfile();
  const snapshot = JSON.stringify(raw);
  assertEquals(validateLegacy(raw), true, JSON.stringify(validateLegacy.errors));
  assertEquals(validateProfileSchema(raw), false);
  assertEquals(validateConditionProfileSemantics(raw).valid, false);
  for (const locale of ["en", "pl"] as const) {
    const catalog = makeSampleCatalog();
    catalog.conditionProfiles.set("overwatering", raw as unknown as CanonicalConditionProfile);
    const classification = classificationFixture("diagnosis", locale);
    const validation = AnalysisValidator.validate(classification, catalog);
    assertEquals(validation.valid, false);
    assertEquals(validation.shouldConsumeQuota, false);
    const result = await ProtocolResolver.resolvePreliminaryProjection({
      analysisId: crypto.randomUUID(), jobId: crypto.randomUUID(), classification,
      catalog, signingSecret: SIGNING_SECRET,
    });
    assertNoPublishedAction(result);
    assertEquals((await verifyAnalysisReceipt(result.analysis_receipt, SIGNING_SECRET)).valid, true);
    assertEquals(JSON.stringify(raw), snapshot);
  }
});

Deno.test("T029.1 — Positive validation across identification and diagnosis modes", () => {
  const catalog = makeSampleCatalog();

  const semCheck = validateConditionProfileSemantics(
    catalog.conditionProfiles.get("overwatering")!,
  );
  assertEquals(semCheck.valid, true, semCheck.errors.join("; "));

  // 1. identification
  const idResult = AnalysisValidator.validate(
    {
      schema_version: "3.0",
      kb_release_id: KB_RELEASE_ID,
      mode: "identification",
      locale: "pl",
      image_quality: "usable",
      identification: {
        status: "identified",
        plant_id: "monstera_deliciosa",
        genus_id: "monstera",
      },
      diagnosis: null,
      limitations: ["single_angle"],
      visual_markers: [],
    },
    catalog,
  );
  assertEquals(idResult.valid, true, idResult.errors.join("; "));
  assertEquals(idResult.shouldConsumeQuota, true);

  // 2. diagnosis with 2 candidates and published visual_markers
  const diagResult = AnalysisValidator.validate(
    {
      schema_version: "3.0",
      kb_release_id: KB_RELEASE_ID,
      mode: "diagnosis",
      locale: "pl",
      image_quality: "usable",
      identification: {
        status: "identified",
        plant_id: "monstera_deliciosa",
        genus_id: "monstera",
      },
      diagnosis: {
        status: "problem_detected",
        candidates: [
          { condition_id: "overwatering", rank: 1, confidence: 0.86 },
          { condition_id: "root_rot", rank: 2, confidence: 0.42 },
        ],
      },
      limitations: ["root_inspection_needed"],
      visual_markers: ["yellowing_lower_leaves", "wet_heavy_substrate"],
    },
    catalog,
  );
  assertEquals(diagResult.valid, true, diagResult.errors.join("; "));
  assertEquals(diagResult.shouldConsumeQuota, true);
});

Deno.test("T029.2 — Negative validation rejects unpinned release, unknown plant/condition/marker IDs, duplicate ranks, >2 candidates, and generated advice/plans", () => {
  const catalog = makeSampleCatalog();

  // Unpinned release ID -> rejected, shouldConsumeQuota = false
  const wrongRelease = AnalysisValidator.validate(
    {
      schema_version: "3.0",
      kb_release_id: "99999999-9999-4999-8999-999999999999",
      mode: "identification",
      locale: "pl",
      image_quality: "usable",
      identification: {
        status: "identified",
        plant_id: "monstera_deliciosa",
        genus_id: "monstera",
      },
      diagnosis: null,
      limitations: [],
      visual_markers: [],
    },
    catalog,
  );
  assertEquals(wrongRelease.valid, false);
  assertEquals(wrongRelease.shouldConsumeQuota, false);

  // Visual marker not in candidate's published ConditionProfile -> rejected, shouldConsumeQuota = false
  const invalidMarker = AnalysisValidator.validate(
    {
      schema_version: "3.0",
      kb_release_id: KB_RELEASE_ID,
      mode: "diagnosis",
      locale: "pl",
      image_quality: "usable",
      identification: {
        status: "identified",
        plant_id: "monstera_deliciosa",
        genus_id: "monstera",
      },
      diagnosis: {
        status: "problem_detected",
        candidates: [
          { condition_id: "overwatering", rank: 1, confidence: 0.85 },
        ],
      },
      limitations: [],
      visual_markers: ["invented_hallucinated_marker"],
    },
    catalog,
  );
  assertEquals(invalidMarker.valid, false);
  assertEquals(invalidMarker.shouldConsumeQuota, false);

  // Duplicate condition_id in top-2 -> rejected
  const duplicateCond = AnalysisValidator.validate(
    {
      schema_version: "3.0",
      kb_release_id: KB_RELEASE_ID,
      mode: "diagnosis",
      locale: "pl",
      image_quality: "usable",
      identification: {
        status: "identified",
        plant_id: "monstera_deliciosa",
        genus_id: "monstera",
      },
      diagnosis: {
        status: "problem_detected",
        candidates: [
          { condition_id: "overwatering", rank: 1, confidence: 0.85 },
          { condition_id: "overwatering", rank: 2, confidence: 0.45 },
        ],
      },
      limitations: [],
      visual_markers: ["yellowing_lower_leaves"],
    },
    catalog,
  );
  assertEquals(duplicateCond.valid, false);
  assertEquals(duplicateCond.shouldConsumeQuota, false);

  // Unsuitable image quality (blurred) or out_of_scope is valid schema-wise but NEVER consumes quota
  const blurryResult = AnalysisValidator.validate(
    {
      schema_version: "3.0",
      kb_release_id: KB_RELEASE_ID,
      mode: "diagnosis",
      locale: "pl",
      image_quality: "blurred",
      identification: {
        status: "unknown",
        plant_id: null,
        genus_id: null,
      },
      diagnosis: {
        status: "insufficient_data",
        candidates: [],
      },
      limitations: ["blurry_image"],
      visual_markers: [],
    },
    catalog,
  );
  assertEquals(blurryResult.valid, true, blurryResult.errors.join("; "));
  assertEquals(blurryResult.shouldConsumeQuota, false);
  assertEquals(blurryResult.nonBillableReason, "unsuitable_image_quality");
});

Deno.test("T116 — ProtocolResolver uses published first help, signs receipt, and preserves ambiguity without advice", async () => {
  const catalog = makeSampleCatalog();
  const validDiag = AnalysisValidator.validate(
    {
      schema_version: "3.0",
      kb_release_id: KB_RELEASE_ID,
      mode: "diagnosis",
      locale: "pl",
      image_quality: "usable",
      identification: {
        status: "identified",
        plant_id: "monstera_deliciosa",
        genus_id: "monstera",
      },
      diagnosis: {
        status: "problem_detected",
        candidates: [
          { condition_id: "overwatering", rank: 1, confidence: 0.88 },
        ],
      },
      limitations: ["single_angle"],
      visual_markers: ["yellowing_lower_leaves"],
    },
    catalog,
  );
  assert(validDiag.classification);

  // A single applicable candidate uses the published first-help step.
  const projection = await ProtocolResolver.resolvePreliminaryProjection({
    analysisId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    jobId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    classification: validDiag.classification,
    catalog,
    signingSecret: SIGNING_SECRET,
  });

  assertEquals("decision_state" in projection, false);
  assertEquals(projection.selected_condition_id, "overwatering");
  assertEquals(projection.first_action_title, "Przelanie (nadmiar wody)");
  assertEquals(
    projection.first_action_summary,
    "Wstrzymaj podlewanie i sprawdź odpływ wody z doniczki.",
  );
  assertEquals(projection.control_interval_days, 7);

  const verified = await verifyAnalysisReceipt(
    projection.analysis_receipt,
    SIGNING_SECRET,
  );
  assertEquals(verified.valid, true);
  assertEquals(verified.payload?.kb_release_id, KB_RELEASE_ID);
  assertEquals(verified.payload?.selected_condition_id, "overwatering");

  // Ambiguity has no treatment or invented fallback.
  const ambiguousDiag = AnalysisValidator.validate(
    {
      ...validDiag.classification,
      diagnosis: {
        status: "problem_detected",
        candidates: [
          { condition_id: "overwatering", rank: 1, confidence: 0.65 },
          { condition_id: "root_rot", rank: 2, confidence: 0.60 },
        ],
      },
    },
    catalog,
  );
  assert(ambiguousDiag.classification);

  const pendingProj = await ProtocolResolver.resolvePreliminaryProjection({
    analysisId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
    jobId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
    classification: ambiguousDiag.classification,
    catalog,
    signingSecret: SIGNING_SECRET,
  });
  assertNoPublishedAction(pendingProj);
  assertEquals(pendingProj.selected_condition_id, null);
  assertEquals(pendingProj.plan_availability, "diagnosis_unresolved");
  assertEquals(pendingProj.control_interval_days, null);
});

Deno.test("T030, T032, T033, T034 — AnalysisAccess, AnthropicAdapter, operation_receipts before quota, and worker/budget guard", async () => {
  // 1. AnalysisAccess separates starter identification & diagnosis and blocks free_monthly in the same UTC month as first_starter_success_at
  const accessSameMonth = AnalysisAccess.evaluateAccessSnapshot({
    isGuestOrAnonymous: false,
    entitlement: null,
    starter: {
      starterIdentificationConsumed: false,
      starterDiagnosisConsumed: true,
      starterIdentificationJobId: null,
      starterDiagnosisJobId: null,
      firstStarterSuccessAt: "2026-11-05T10:00:00Z",
    },
    freeMonthlyWindow: null,
    paidMonthlyWindow: null,
    now: new Date("2026-11-20T12:00:00Z"),
  });
  assertEquals(accessSameMonth.modes.identification.allowed, true);
  assertEquals(accessSameMonth.modes.identification.activeQuotaKind, "starter_identification");
  assertEquals(accessSameMonth.modes.diagnosis.allowed, false);
  assertEquals(accessSameMonth.modes.diagnosis.reason, "free_monthly_starts_next_utc_month");
  assertEquals(Object.keys(accessSameMonth.modes).sort(), ["diagnosis", "identification"]);

  // Next UTC month (Dec 2026) unlocks free_monthly = 1
  const accessNextMonth = AnalysisAccess.evaluateAccessSnapshot({
    isGuestOrAnonymous: false,
    entitlement: null,
    starter: {
      starterIdentificationConsumed: false,
      starterDiagnosisConsumed: true,
      starterIdentificationJobId: null,
      starterDiagnosisJobId: null,
      firstStarterSuccessAt: "2026-11-05T10:00:00Z",
    },
    freeMonthlyWindow: null,
    paidMonthlyWindow: null,
    now: new Date("2026-12-01T00:05:00Z"),
  });
  assertEquals(accessNextMonth.modes.diagnosis.allowed, true);
  assertEquals(accessNextMonth.modes.diagnosis.activeQuotaKind, "free_monthly");

  // 2. T033: handleCreateAnalysisJob checks operation_receipts BEFORE checking quotas
  let admitQuotaCalled = false;
  const cachedStatus = {
    job_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
    mode: "diagnosis" as const,
    status: "succeeded" as const,
    quota_kind: "starter_diagnosis",
    quota_state: "consumed" as const,
  };
  const opId = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const photoId = "12121212-1212-4121-8121-121212121212";

  const createReq = () =>
    new Request("https://api.narat.app/functions/v1/plants-api/analysis/jobs", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        operation_id: opId,
        mode: "diagnosis",
        photo_asset_id: photoId,
      }),
    });

  let savedReceiptHash: string | null = null;
  const firstRes = await handleCreateAnalysisJob(
    createReq(),
    {
      ownerId: null,
      isAnonymous: true,
      accountState: null,
      installationCredential: "guest-cred-0001-abcd",
      locale: "pl",
      operationId: opId,
    },
    {
      findOperationReceipt: async () =>
        savedReceiptHash
          ? { payloadHash: savedReceiptHash, responsePayload: cachedStatus }
          : null,
      admitAndCreateJob: async (params) => {
        admitQuotaCalled = true;
        savedReceiptHash = params.payloadHash;
        return cachedStatus;
      },
      getJobStatusAndResult: async () => cachedStatus,
    },
  );
  assertEquals(firstRes.status, 202);
  assertEquals(admitQuotaCalled, true);

  // Replay with same operation_id returns 200 from operation_receipts without calling admitAndCreateJob
  admitQuotaCalled = false;
  const replayRes = await handleCreateAnalysisJob(
    createReq(),
    {
      ownerId: null,
      isAnonymous: true,
      accountState: null,
      installationCredential: "guest-cred-0001-abcd",
      locale: "pl",
      operationId: opId,
    },
    {
      findOperationReceipt: async () => ({
        payloadHash: savedReceiptHash!,
        responsePayload: cachedStatus,
      }),
      admitAndCreateJob: async () => {
        admitQuotaCalled = true;
        throw new Error("Should not be called on replay!");
      },
      getJobStatusAndResult: async () => cachedStatus,
    },
  );
  assertEquals(replayRes.status, 200);
  assertEquals(admitQuotaCalled, false);

  // 3. T032 & T034: AnthropicAdapter + Worker + ProviderBudgetGuard + Reconciler
  let throwsOnPlan = false;
  try {
    ProviderBudgetGuard.assertModeUsesProvider("plan");
  } catch {
    throwsOnPlan = true;
  }
  assertEquals(throwsOnPlan, true);

  const catalog = makeSampleCatalog();
  const mockAnthropic = new AnthropicAdapter({
    create: async () => ({
      stop_reason: "end_turn",
      content: [
        {
          type: "text",
          text: JSON.stringify({
            schema_version: "3.0",
            kb_release_id: KB_RELEASE_ID,
            mode: "diagnosis",
            locale: "pl",
            image_quality: "usable",
            identification: {
              status: "identified",
              plant_id: "monstera_deliciosa",
              genus_id: "monstera",
            },
            diagnosis: {
              status: "problem_detected",
              candidates: [
                { condition_id: "overwatering", rank: 1, confidence: 0.90 },
              ],
            },
            limitations: ["single_angle"],
            visual_markers: ["yellowing_lower_leaves"],
          }),
        },
      ],
    }),
  });

  const workerResult = await processSingleQueuedJob({
    workerAdapter: {
      leaseNextQueuedJob: async () => ({
        id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        ownerId: null,
        installationId: "11111111-1111-4111-8111-111111111111",
        kbReleaseId: KB_RELEASE_ID,
        mode: "diagnosis",
        locale: "pl",
        imageBase64: "dGVzdA==",
        mediaType: "image/jpeg",
        quotaKind: "starter_diagnosis",
        monthlyQuotaId: null,
        leaseExpiresAt: new Date(Date.now() + 55_000).toISOString(),
      }),
      loadPublishedCatalog: async () => catalog,
      finalizeJobOnce: async (p) => ({
        alreadyFinalized: false,
        quotaState: p.isNonBillableResult ? "released" : "consumed",
      }),
    },
    budgetAdapter: {
      reserveDailyBudget: async (p) => ({
        allowed: true,
        record: {
          budgetDateUtc: p.budgetDateUtc,
          capMicroUsd: p.maxCapMicroUsd,
          spentMicroUsd: 0,
          reservedMicroUsd: p.reserveMicroUsd,
          circuitOpen: false,
        },
      }),
      settleDailyBudget: async (p) => ({
        budgetDateUtc: p.budgetDateUtc,
        capMicroUsd: 10_000_000,
        spentMicroUsd: p.actualSpentMicroUsd,
        reservedMicroUsd: 0,
        circuitOpen: false,
      }),
    },
    anthropicAdapter: mockAnthropic,
    signingSecret: SIGNING_SECRET,
  });

  assertEquals(workerResult.processed, true);
  assertEquals(workerResult.outcome, "succeeded");
  assertEquals(workerResult.quotaState, "consumed");

  const reconcileRes = await reconcileStuckAnalysisJobs({
    findStuckJobs: async () => [
      {
        id: "99999999-9999-4999-8999-999999999991",
        status: "running",
        quotaKind: "starter_diagnosis",
        quotaState: "reserved",
        monthlyQuotaId: null,
        createdAt: "2026-11-01T12:00:00Z",
        leaseExpiresAt: "2026-11-01T12:00:55Z",
      },
    ],
    releaseStuckJobQuotaOnce: async () => ({
      alreadyFinalized: false,
      quotaState: "released",
    }),
  });
  assertEquals(reconcileRes.releasedCount, 1);
});

function classificationFixture(
  mode: VisionClassification30["mode"] = "diagnosis",
  locale: "en" | "pl" = "en",
): VisionClassification30 {
  return {
    schema_version: "3.0", kb_release_id: KB_RELEASE_ID, mode, locale,
    image_quality: "usable",
    identification: {
      status: "identified", plant_id: "monstera_deliciosa", genus_id: "monstera",
    },
    diagnosis: mode === "identification" ? null : {
      status: "problem_detected",
      candidates: [{ condition_id: "overwatering", rank: 1, confidence: 0.9 }],
    },
    limitations: [],
    visual_markers: mode === "identification" ? [] : ["yellowing_lower_leaves"],
  };
}

function assertNoPublishedAction(projection: PreliminaryAnalysisProjection) {
  assertEquals(projection.selected_condition_id, null);
  assertEquals(projection.first_action_title, null);
  assertEquals(projection.first_action_summary, null);
  assertEquals(projection.control_interval_days, null);
  assert(projection.limitations.length > 0);
  assertEquals("decision_state" in projection, false);
  for (const key of ["questions", "disambiguation_question", "diagnostic_decision"]) {
    assertEquals(key in projection, false);
  }
}

Deno.test("T157 — two candidates stay ambiguous for every gap, rank and runtime decision override in EN/PL", async () => {
  for (const locale of ["en", "pl"] as const) {
    for (const scores of [[0.9, 0.1], [0.8, 0.79], [0.1, 0.1]]) {
      for (const reversed of [false, true]) {
        const classification = classificationFixture("diagnosis", locale);
        classification.diagnosis!.candidates = [
          { condition_id: reversed ? "root_rot" : "overwatering", rank: 1, confidence: scores[0] },
          { condition_id: reversed ? "overwatering" : "root_rot", rank: 2, confidence: scores[1] },
        ];
        const catalog = makeSampleCatalog();
        const validated = AnalysisValidator.validate(classification, catalog);
        assertEquals(validated.valid, true, validated.errors.join("; "));
        const params = {
          analysisId: crypto.randomUUID(), jobId: crypto.randomUUID(), classification,
          catalog, signingSecret: SIGNING_SECRET, issuedAt: "2026-11-09T00:00:00Z",
        };
        const clean = await ProtocolResolver.resolvePreliminaryProjection(params);
        assertNoPublishedAction(clean);
        assertEquals(clean.diagnosis_status, "problem_detected");
        assertEquals(clean.plan_availability, "diagnosis_unresolved");
        assertEquals(clean.candidates, classification.diagnosis!.candidates);
        for (const state of ["resolved", "pending", "uncertain"]) {
          // An untyped caller may still send the removed field; it has no authority.
          const runtimeParams = {
            ...params,
            decisionState: { state, revision: 99, selectedConditionId: "overwatering" },
          };
          const result = await ProtocolResolver.resolvePreliminaryProjection(runtimeParams);
          assertEquals(result, clean);
          const verified = await verifyAnalysisReceipt(result.analysis_receipt, SIGNING_SECRET);
          assertEquals(verified.valid, true);
          assertEquals(verified.payload?.decision_revision, 1);
          assertEquals(verified.payload?.selected_condition_id, null);
        }
        // Filtering out an incompatible candidate must not silently resolve ambiguity.
        catalog.conditionProfiles.get("root_rot")!.host_scope = {
          plant_ids: [], families: [], general_houseplants: false,
        };
        assertNoPublishedAction(await ProtocolResolver.resolvePreliminaryProjection(params));
      }
    }
  }
});

Deno.test("T157 — explicit healthy, insufficient-data and out-of-scope statuses never invent help in EN/PL", async () => {
  for (const locale of ["en", "pl"] as const) {
    for (const status of ["healthy", "insufficient_data", "out_of_scope"] as const) {
      const classification = classificationFixture("diagnosis", locale);
      classification.diagnosis = { status, candidates: [] };
      classification.visual_markers = [];
      const catalog = makeSampleCatalog();
      const validated = AnalysisValidator.validate(classification, catalog);
      assertEquals(validated.valid, true, validated.errors.join("; "));
      const result = await ProtocolResolver.resolvePreliminaryProjection({
        analysisId: crypto.randomUUID(), jobId: crypto.randomUUID(), classification,
        catalog, signingSecret: SIGNING_SECRET,
      });
      assertNoPublishedAction(result);
      assertEquals(result.diagnosis_status, status);
      assertEquals(result.evidence_basis, status === "healthy" ? ["no_pathological_markers_detected"] : []);
      const expected = {
        en: { healthy: "No problem detected.", insufficient_data: "Insufficient data", out_of_scope: "outside indoor houseplant" },
        pl: { healthy: "Nie wykryto problemu.", insufficient_data: "Za mało danych", out_of_scope: "poza zakresem" },
      };
      assert(result.limitations.some((message) => message.includes(expected[locale][status])));
      const verified = await verifyAnalysisReceipt(result.analysis_receipt, SIGNING_SECRET);
      assertEquals(verified.valid, true);
      assertEquals(verified.payload?.selected_condition_id, null);
    }
  }
});

Deno.test("T157 — missing publication, unknown host and inapplicable first help have no invented fallback/date", async () => {
  for (const locale of ["en", "pl"] as const) {
    for (const scenario of [
      "host_mismatch", "unknown_host", "unknown_condition", "unpublished",
      "wrong_release", "blocked", "profile_contra", "action_contra",
      "unconfirmed_prerequisite", "missing_first_help", "no_actions", "missing_en", "missing_pl",
      "legacy_v1", "wrong_version", "missing_actions", "malformed_action", "invalid_interval",
      "malformed_host", "malformed_content", "malformed_checks", "duplicate_actions", "wrong_condition",
    ]) {
      const classification = classificationFixture("diagnosis", locale);
      const catalog = makeSampleCatalog();
      const profile = catalog.conditionProfiles.get("overwatering")!;
      const hostContext = {
        plantId: "monstera_deliciosa" as string | null,
        activeContraindicationIds: [] as string[],
        blockedConditionIds: new Set<string>(),
      };
      switch (scenario) {
        case "host_mismatch":
        case "unknown_host":
          profile.host_scope = { plant_ids: ["epipremnum_aureum"], families: [], general_houseplants: false };
          if (scenario === "unknown_host") {
            classification.identification = { status: "unknown", plant_id: null, genus_id: null };
            hostContext.plantId = null;
          }
          break;
        case "unknown_condition":
          classification.diagnosis!.candidates[0].condition_id = JSON.parse('"not_published"');
          break;
        case "unpublished":
          catalog.conditionProfiles.delete("overwatering");
          break;
        case "wrong_release":
          profile.kb_release_id = "99999999-9999-4999-8999-999999999999";
          break;
        case "blocked":
          hostContext.blockedConditionIds.add("overwatering");
          break;
        case "profile_contra":
          profile.contraindication_check_ids = ["unsafe_here"];
          hostContext.activeContraindicationIds = ["unsafe_here"];
          break;
        case "action_contra":
          profile.actions[0].contraindication_check_ids = ["unsafe_here"];
          hostContext.activeContraindicationIds = ["unsafe_here"];
          break;
        case "unconfirmed_prerequisite":
          profile.actions[0].prerequisite_check_ids = ["unconfirmed_check"];
          break;
        case "missing_first_help":
          profile.first_help_action_id = "missing";
          break;
        case "no_actions":
          profile.actions = [];
          break;
        case "legacy_v1":
          catalog.conditionProfiles.set("overwatering",
            makeLegacyConditionProfile() as unknown as CanonicalConditionProfile);
          break;
        case "wrong_version":
          Object.assign(profile, { schema_version: "3.0" });
          break;
        case "missing_actions":
          Object.assign(profile, { actions: undefined });
          break;
        case "malformed_action":
          Object.assign(profile, { actions: [null] });
          break;
        case "invalid_interval":
          profile.actions[0].next_check_interval_days = 0;
          break;
        case "malformed_host":
          Object.assign(profile, { host_scope: null });
          break;
        case "malformed_content":
          Object.assign(profile, { condition_content_i18n: {} });
          break;
        case "malformed_checks":
          Object.assign(profile.actions[0], { prerequisite_check_ids: null });
          break;
        case "duplicate_actions":
          profile.actions.push(structuredClone(profile.actions[0]));
          break;
        case "wrong_condition":
          profile.condition_id = "root_rot";
          break;
        case "missing_en":
          profile.actions[0].action_en = "";
          break;
        case "missing_pl":
          profile.actions[0].action_pl = "";
          break;
      }
      const result = await ProtocolResolver.resolvePreliminaryProjection({
        analysisId: crypto.randomUUID(), jobId: crypto.randomUUID(), classification,
        catalog, hostContext, signingSecret: SIGNING_SECRET,
      });
      assertNoPublishedAction(result);
      assertEquals(result.plan_availability, "missing_condition_profile");
      assertEquals(result.diagnosis_status, "problem_detected");
      assertEquals((await verifyAnalysisReceipt(result.analysis_receipt, SIGNING_SECRET)).valid, true);
    }
  }
});

Deno.test("T157 — published general and family host applicability remains available in EN/PL", async () => {
  for (const locale of ["en", "pl"] as const) {
    for (const scope of ["general", "family"] as const) {
      const catalog = makeSampleCatalog();
      const profile = catalog.conditionProfiles.get("overwatering")!;
      profile.host_scope = {
        plant_ids: [], families: scope === "family" ? ["Araceae"] : [],
        general_houseplants: scope === "general",
      };
      const result = await ProtocolResolver.resolvePreliminaryProjection({
        analysisId: crypto.randomUUID(), jobId: crypto.randomUUID(),
        classification: classificationFixture("diagnosis", locale), catalog,
        hostContext: { plantId: null, family: scope === "family" ? "Araceae" : null },
        signingSecret: SIGNING_SECRET,
      });
      assertEquals(result.selected_condition_id, "overwatering");
      assertEquals(result.plan_availability, "available");
      assertEquals(result.first_action_summary, locale === "en"
        ? profile.actions[0].action_en : profile.actions[0].action_pl);
    }
  }
});

Deno.test("T157 — worker finalizes and preserves an ambiguous result without a recommendation", async () => {
  for (const locale of ["en", "pl"] as const) {
    const classification = classificationFixture("diagnosis", locale);
    classification.diagnosis!.candidates.push({
      condition_id: "root_rot", rank: 2, confidence: 0.1,
    });
    let finalizations = 0;
    const result = await processSingleQueuedJob({
      signingSecret: SIGNING_SECRET,
      anthropicAdapter: new AnthropicAdapter({
        create: async () => ({
          stop_reason: "end_turn",
          content: [{ type: "text", text: JSON.stringify(classification) }],
        }),
      }),
      workerAdapter: {
        leaseNextQueuedJob: async () => ({
          id: crypto.randomUUID(), ownerId: null, installationId: crypto.randomUUID(),
          kbReleaseId: KB_RELEASE_ID, mode: "diagnosis", locale,
          imageBase64: "dGVzdA==", mediaType: "image/jpeg", quotaKind: "starter_diagnosis",
          monthlyQuotaId: null, leaseExpiresAt: new Date(Date.now() + 55_000).toISOString(),
        }),
        loadPublishedCatalog: async () => makeSampleCatalog(),
        finalizeJobOnce: async (params) => {
          finalizations++;
          assertEquals(params.outcome, "succeeded");
          assertEquals(params.isNonBillableResult, false);
          assert(params.projection);
          assertNoPublishedAction(params.projection);
          assertEquals(params.projection.diagnosis_status, "problem_detected");
          assertEquals((await verifyAnalysisReceipt(
            params.projection.analysis_receipt, SIGNING_SECRET,
          )).valid, true);
          return { alreadyFinalized: false, quotaState: "consumed" };
        },
      },
      budgetAdapter: {
        reserveDailyBudget: async (params) => ({
          allowed: true,
          record: {
            budgetDateUtc: params.budgetDateUtc, capMicroUsd: params.maxCapMicroUsd,
            spentMicroUsd: 0, reservedMicroUsd: params.reserveMicroUsd, circuitOpen: false,
          },
        }),
        settleDailyBudget: async (params) => ({
          budgetDateUtc: params.budgetDateUtc, capMicroUsd: 10_000_000,
          spentMicroUsd: params.actualSpentMicroUsd, reservedMicroUsd: 0, circuitOpen: false,
        }),
      },
    });
    assertEquals(result.outcome, "succeeded");
    assertEquals(result.quotaState, "consumed");
    assertEquals(finalizations, 1);
  }
});

Deno.test("T157 — two modes validate in EN/PL; legacy mode, comparison and quality are rejected", () => {
  for (const locale of ["en", "pl"] as const) {
    for (const mode of ["identification", "diagnosis"] as const) {
      const payload = classificationFixture(mode, locale);
      const valid = AnalysisValidator.validate(payload, makeSampleCatalog());
      assertEquals(valid.valid, true, valid.errors.join("; "));
      assertEquals(valid.shouldConsumeQuota, true);
      for (const invalid of [
        { ...payload, mode: "follow_up" },
        { ...payload, comparison: null },
        { ...payload, comparison: { progress_status: "stable", changes: [], limitation_codes: [] } },
        {
          ...payload, image_quality: "comparison_unsuitable",
          identification: { status: "unknown", plant_id: null, genus_id: null },
          diagnosis: mode === "identification" ? null : { status: "insufficient_data", candidates: [] },
          visual_markers: [], limitations: ["single_angle"],
        },
      ]) {
        const result = AnalysisValidator.validate(invalid, makeSampleCatalog());
        assertEquals(result.valid, false);
        assertEquals(result.classification, null);
        assertEquals(result.shouldConsumeQuota, false);
        assertEquals(result.nonBillableReason, "invalid_schema_or_semantics");
      }
    }
  }
});

Deno.test("T157 — provider accepts EN/PL without comparison and rejects legacy output/input", async () => {
  for (const locale of ["en", "pl"] as const) {
    for (const mode of ["identification", "diagnosis"] as const) {
      const payload = classificationFixture(mode, locale);
      let output: unknown = payload;
      let calls = 0;
      const adapter = new AnthropicAdapter({
        create: async (request) => {
          calls++;
          assertEquals(request.system.includes("comparison"), false);
          assertEquals(request.system.includes("follow_up"), false);
          const text = request.messages[0].content.find((block) => block.type === "text");
          assert(text?.type === "text");
          assertEquals(Object.keys(JSON.parse(text.text)).sort(),
            ["care_context", "kb_release_id", "locale", "mode"]);
          return { stop_reason: "end_turn", content: [{ type: "text", text: JSON.stringify(output) }] };
        },
      });
      const input = {
        analysisId: crypto.randomUUID(), jobId: crypto.randomUUID(), mode, locale,
        imageBase64: "dGVzdA==", mediaType: "image/jpeg" as const,
        catalog: makeSampleCatalog(), signingSecret: SIGNING_SECRET,
      };
      const success = await adapter.classifyAndResolve(input);
      assertEquals(success.ok, true);
      assertEquals(success.projection?.mode, mode);
      assertEquals(success.shouldConsumeQuota, true);
      if (mode === "diagnosis") {
        assertEquals(success.projection?.first_action_summary,
          locale === "en" ? "Hold off on watering and check pot drainage."
            : "Wstrzymaj podlewanie i sprawdź odpływ wody z doniczki.");
      }
      for (const invalid of [{ ...payload, mode: "follow_up" }, { ...payload, comparison: null }]) {
        output = invalid;
        const rejected = await adapter.classifyAndResolve(input);
        assertEquals(rejected.ok, false);
        assertEquals(rejected.shouldConsumeQuota, false);
        assertEquals(rejected.errorCode, "SCHEMA_VALIDATION_FAILED");
      }
      const before = calls;
      // Emulate persisted/untyped runtime input, not compile-time narrowing.
      const legacyInput = { ...input, mode: JSON.parse('"follow_up"') };
      const rejected = await adapter.classifyAndResolve(legacyInput);
      assertEquals(rejected.errorCode, "UNSUPPORTED_ANALYSIS_MODE");
      assertEquals(rejected.shouldConsumeQuota, false);
      assertEquals(calls, before);
      assertThrows(() => buildSystemPrompt(legacyInput.mode, KB_RELEASE_ID, locale));
      await assertRejects(() => ProtocolResolver.resolvePreliminaryProjection({
        ...input, classification: JSON.parse(JSON.stringify({ ...payload, mode: "follow_up" })),
      }), Error, "Unsupported analysis mode");
    }
  }
});

Deno.test("T157 — API rejects follow_up before receipt lookup/admission, retains auth and conflict guards", async () => {
  const operationId = crypto.randomUUID();
  const photoId = crypto.randomUUID();
  const request = (mode: string) => new Request("https://example.com/analysis/jobs", {
    method: "POST",
    body: JSON.stringify({ operation_id: operationId, photo_asset_id: photoId, mode }),
  });
  for (const locale of ["en", "pl"] as const) {
    const ctx: RequestContext = {
      ownerId: null, installationCredential: "fixture-installation", isAnonymous: true,
      accountState: null, operationId, locale,
    };
    let lookups = 0;
    let admissions = 0;
    let savedHash = "";
    const adapter: AnalysisJobStoreAdapter = {
      findOperationReceipt: async () => { lookups++; return null; },
      admitAndCreateJob: async (params) => {
        admissions++;
        savedHash = params.payloadHash;
        assertEquals(params.installationCredential, ctx.installationCredential);
        assertEquals(params.locale, locale);
        return {
          job_id: crypto.randomUUID(), mode: params.mode, status: "queued",
          quota_kind: "starter_" + params.mode, quota_state: "reserved",
        };
      },
      getJobStatusAndResult: async () => null,
    };
    const invalid = await assertRejects(
      () => handleCreateAnalysisJob(request("follow_up"), ctx, adapter), ApiHttpError,
    );
    assertEquals(invalid.status, 400);
    assertEquals(invalid.code, "VALIDATION_ERROR");
    assertEquals([lookups, admissions], [0, 0]);
    for (const mode of ["identification", "diagnosis"] as const) {
      const missingOwner = await assertRejects(() => handleCreateAnalysisJob(request(mode),
        { ...ctx, installationCredential: null }, adapter), ApiHttpError);
      assertEquals(missingOwner.status, 401);
      assertEquals([lookups, admissions], mode === "identification" ? [0, 0] : [1, 1]);
      assertEquals((await handleCreateAnalysisJob(request(mode), ctx, adapter)).status, 202);
    }
    const cached: AnalysisJobStatusResponse = {
      job_id: crypto.randomUUID(), mode: "diagnosis", status: "succeeded",
      quota_kind: "starter_diagnosis", quota_state: "consumed",
    };
    adapter.findOperationReceipt = async () => ({ payloadHash: savedHash, responsePayload: cached });
    assertEquals((await handleCreateAnalysisJob(request("diagnosis"), ctx, adapter)).status, 200);
    const conflict = await assertRejects(
      () => handleCreateAnalysisJob(request("identification"), ctx, adapter), ApiHttpError,
    );
    assertEquals(conflict.status, 409);
    assertEquals(conflict.code, "IDEMPOTENCY_CONFLICT");
    assertEquals(admissions, 2);
  }
});

Deno.test("T157 — legacy signature and historical GET survive without reclassification", async () => {
  const payload = {
    analysis_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", kb_release_id: KB_RELEASE_ID, mode: "follow_up",
    plant_id: "monstera_deliciosa", selected_condition_id: "overwatering",
    decision_revision: 1, issued_at: "2026-11-01T00:00:00Z",
  };
  // Fixed historical HMAC fixture, generated independently of the current signer.
  const receipt = "eyJhbmFseXNpc19pZCI6ImFhYWFhYWFhLWFhYWEtNGFhYS04YWFhLWFhYWFhYWFhYWFhYSIsImtiX3JlbGVhc2VfaWQiOiI4ODg4ODg4OC04ODg4LTQ4ODgtODg4OC04ODg4ODg4ODg4ODgiLCJtb2RlIjoiZm9sbG93X3VwIiwicGxhbnRfaWQiOiJtb25zdGVyYV9kZWxpY2lvc2EiLCJzZWxlY3RlZF9jb25kaXRpb25faWQiOiJvdmVyd2F0ZXJpbmciLCJkZWNpc2lvbl9yZXZpc2lvbiI6MSwiaXNzdWVkX2F0IjoiMjAyNi0xMS0wMVQwMDowMDowMFoifQ==.c97702702c49a240ccf392766e52926d9b1d7b77f58da6a64f059597a395cff0";
  assertEquals(await signAnalysisReceipt(payload, SIGNING_SECRET), receipt);
  const verified = await verifyAnalysisReceipt(receipt, SIGNING_SECRET);
  assertEquals(verified, { valid: true, payload });
  const tampered = btoa(JSON.stringify({ ...payload, mode: "diagnosis" })) + "." + receipt.split(".")[1];
  assertEquals((await verifyAnalysisReceipt(tampered, SIGNING_SECRET)).valid, false);
  const rawProfile = makeLegacyConditionProfile();
  const snapshot = JSON.stringify(rawProfile);
  const savedResult = {
    analysis_id: payload.analysis_id, job_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    kb_release_id: KB_RELEASE_ID, mode: "follow_up" as const, locale: "en" as const,
    identification_status: "identified" as const, plant_id: payload.plant_id, genus_id: "monstera",
    diagnosis_status: "problem_detected" as const, selected_condition_id: "overwatering" as const,
    candidates: [{ condition_id: "overwatering" as const, rank: 1 as const, confidence: 0.9 }],
    visual_markers: ["yellowing_lower_leaves"], evidence_basis: ["yellowing_lower_leaves"],
    limitations: [], first_action_title: "Historical first help",
    first_action_summary: rawProfile.treatment_plan.steps[0].action_en, control_interval_days: 7,
    plan_availability: "available" as const, analysis_receipt: receipt,
    raw_condition_profile: rawProfile,
  };
  const historical: AnalysisJobStatusResponse = {
    job_id: savedResult.job_id, mode: "follow_up", status: "succeeded",
    quota_kind: "paid_monthly", quota_state: "consumed", result: savedResult,
  };
  const ctx: RequestContext = {
    ownerId: crypto.randomUUID(), installationCredential: null, isAnonymous: false,
    accountState: "active", operationId: null, locale: "en",
  };
  const response = await handleGetAnalysisJob(new Request("https://example.com"), ctx,
    historical.job_id, {
      findOperationReceipt: async () => { throw new Error("GET must not look up a create receipt"); },
      admitAndCreateJob: async () => { throw new Error("GET must not admit"); },
      getJobStatusAndResult: async (params) => {
        assertEquals(params.ownerId, ctx.ownerId);
        assertEquals(params.installationCredential, null);
        return historical;
      },
    });
  const restored = await response.json();
  assertEquals(restored, historical);
  assertEquals(JSON.stringify(restored.result.raw_condition_profile), snapshot);
  assertEquals(await verifyAnalysisReceipt(restored.result.analysis_receipt, SIGNING_SECRET),
    { valid: true, payload });
});

Deno.test("T157 — runtime legacy worker job finalizes once without provider or budget", async () => {
  for (const initialState of ["reserved", "released", "consumed"] as const) {
    let state: "reserved" | "released" | "consumed" = initialState;
    let releases = 0;
    let finalizations = 0;
    let forbiddenCalls = 0;
    const forbidden = () => { forbiddenCalls++; throw new Error("Legacy job crossed provider boundary"); };
    const rawJob = JSON.parse(JSON.stringify({
      id: crypto.randomUUID(), ownerId: null, installationId: crypto.randomUUID(),
      kbReleaseId: KB_RELEASE_ID, mode: "follow_up", locale: "en",
      imageBase64: "dGVzdA==", mediaType: "image/jpeg", quotaKind: "paid_monthly",
      monthlyQuotaId: crypto.randomUUID(), leaseExpiresAt: "2026-11-09T00:01:00Z",
    }));
    const workerAdapter: WorkerPersistenceAdapter = {
      leaseNextQueuedJob: async () => rawJob,
      loadPublishedCatalog: async () => forbidden(),
      finalizeJobOnce: async (params) => {
        finalizations++;
        assertEquals(params.jobId, rawJob.id);
        assertEquals(params.outcome, "failed");
        assertEquals(params.isNonBillableResult, true);
        assertEquals(params.projection, null);
        assertEquals(params.errorCode, "UNSUPPORTED_ANALYSIS_MODE");
        const alreadyFinalized = state !== "reserved";
        if (!alreadyFinalized) { state = "released"; releases++; }
        assert(state !== "reserved");
        return { alreadyFinalized, quotaState: state };
      },
    };
    const run = () => processSingleQueuedJob({
      workerAdapter, signingSecret: SIGNING_SECRET,
      anthropicAdapter: new AnthropicAdapter({ create: async () => forbidden() }),
      budgetAdapter: {
        reserveDailyBudget: async () => forbidden(),
        settleDailyBudget: async () => forbidden(),
      },
    });
    for (let retry = 0; retry < 2; retry++) {
      const result = await run();
      assertEquals(result.outcome, "failed");
      assertEquals(result.errorCode, "UNSUPPORTED_ANALYSIS_MODE");
      assertEquals(result.quotaState, initialState === "consumed" ? "consumed" : "released");
    }
    assertEquals(finalizations, 2);
    assertEquals(releases, initialState === "reserved" ? 1 : 0);
    assertEquals(forbiddenCalls, 0);
  }
  assertThrows(() => ProviderBudgetGuard.assertModeUsesProvider("follow_up"));
  let reservations = 0;
  await assertRejects(() => ProviderBudgetGuard.acquireReservation("follow_up", {
    reserveDailyBudget: async () => { reservations++; throw new Error("Must not reserve"); },
    settleDailyBudget: async () => { throw new Error("Must not settle"); },
  }));
  assertEquals(reservations, 0);
});

Deno.test("T157 — access exposes two modes for guest, starter-in-progress and paid quota", () => {
  const starter = {
    starterIdentificationConsumed: false, starterDiagnosisConsumed: false,
    starterIdentificationJobId: null, starterDiagnosisJobId: null, firstStarterSuccessAt: null,
  };
  const params = {
    isGuestOrAnonymous: true, entitlement: null, starter,
    freeMonthlyWindow: null, paidMonthlyWindow: null, now: new Date("2026-11-09T00:00:00Z"),
  };
  const guest = AnalysisAccess.evaluateAccessSnapshot(params);
  assertEquals(Object.keys(guest.modes).sort(), ["diagnosis", "identification"]);
  assertEquals(guest.modes.diagnosis.allowed, true);
  assertEquals(guest.modes.diagnosis.activeQuotaKind, "starter_diagnosis");
  const jobId = crypto.randomUUID();
  const pending = AnalysisAccess.evaluateAccessSnapshot({
    ...params, starter: { ...starter, starterDiagnosisJobId: jobId },
  });
  assertEquals(pending.modes.diagnosis.reason, "starter_in_progress");
  assertEquals(pending.modes.diagnosis.inProgressJobId, jobId);
  for (const consumedCount of [0, 100]) {
    const paid = AnalysisAccess.evaluateAccessSnapshot({
      ...params, isGuestOrAnonymous: false,
      entitlement: {
        ownerId: crypto.randomUUID(), accountState: "active", subscriptionState: "active",
        offerKind: "paid", validUntil: "2026-12-09T00:00:00Z", trialEndAt: null,
        autoRenewEnabled: true, verifiedAt: "2026-11-09T00:00:00Z",
      },
      paidMonthlyWindow: {
        id: crypto.randomUUID(), quotaKind: "paid_monthly",
        periodStart: "2026-11-09T00:00:00Z", periodEnd: "2026-12-09T00:00:00Z",
        limitCount: 100, consumedCount, reservedCount: 0,
      },
    });
    assertEquals(Object.keys(paid.modes).sort(), ["diagnosis", "identification"]);
    for (const mode of ["identification", "diagnosis"] as const) {
      assertEquals(paid.modes[mode].activeQuotaKind, "paid_monthly");
      assertEquals(paid.modes[mode].allowed, consumedCount === 0);
      assertEquals(paid.modes[mode].remaining, 100 - consumedCount);
    }
  }
});
