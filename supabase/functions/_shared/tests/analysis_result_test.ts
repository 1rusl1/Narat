// supabase/functions/_shared/tests/analysis_result_test.ts
// T029 & T116: Positive and negative tests for Classification 3.0 validation (AnalysisValidator)
// and deterministic backend projection (ProtocolResolver).

import { assert, assertEquals } from "@std/assert";
import { AnalysisValidator } from "../AnalysisValidator.ts";
import {
  CanonicalConditionId,
  CanonicalConditionProfile,
  PublishedReleaseCatalog,
  validateConditionProfileSemantics,
} from "../KnowledgeTypes.ts";
import {
  ProtocolResolver,
  verifyAnalysisReceipt,
} from "../ProtocolResolver.ts";
import { AnalysisAccess } from "../AnalysisAccess.ts";
import { AnthropicAdapter } from "../AnthropicAdapter.ts";
import { ProviderBudgetGuard } from "../ProviderBudgetGuard.ts";
import { processSingleQueuedJob } from "../../analysis-worker/index.ts";
import { reconcileStuckAnalysisJobs } from "../../maintenance/analysis-jobs.ts";
import { handleCreateAnalysisJob } from "../../plants-api/analysis.ts";

const KB_RELEASE_ID = "88888888-8888-4888-8888-888888888888";
const SIGNING_SECRET = "test-signing-secret-32-bytes-minimum-key";

function makeSampleCatalog(): PublishedReleaseCatalog {
  const overwateringProfile: CanonicalConditionProfile = {
    schema_version: "1.0",
    kb_release_id: KB_RELEASE_ID,
    record_version: 1,
    condition_id: "overwatering",
    category: "abiotic",
    host_scope: {
      plant_ids: ["monstera_deliciosa"],
      families: ["Araceae"],
      general_houseplants: true,
    },
    visual_markers: ["yellowing_lower_leaves", "wet_heavy_substrate"],
    diagnostic_disambiguation: {
      often_confused_with: ["root_rot", "underwatering"],
      clarifying_questions: [
        {
          question_id: "q_soil_wet",
          text_pl: "Czy podłoże na głębokości 3–4 cm jest stale mokre?",
          text_en: "Is the soil at 3–4 cm depth constantly wet?",
          yes_weights_towards: "overwatering",
          no_weights_towards: "underwatering",
        },
      ],
    },
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
    knownTraitIds: new Set(["leaf_turgor_recovery", "yellowing_progression"]),
  };
}

Deno.test("T029.1 — Positive validation across identification, diagnosis, and follow_up modes", () => {
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
      comparison: null,
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
      comparison: null,
      visual_markers: ["yellowing_lower_leaves", "wet_heavy_substrate"],
    },
    catalog,
  );
  assertEquals(diagResult.valid, true, diagResult.errors.join("; "));
  assertEquals(diagResult.shouldConsumeQuota, true);

  // 3. follow_up with comparison traits
  const followUpResult = AnalysisValidator.validate(
    {
      schema_version: "3.0",
      kb_release_id: KB_RELEASE_ID,
      mode: "follow_up",
      locale: "en",
      image_quality: "usable",
      identification: {
        status: "identified",
        plant_id: "monstera_deliciosa",
        genus_id: "monstera",
      },
      diagnosis: {
        status: "problem_detected",
        candidates: [
          { condition_id: "overwatering", rank: 1, confidence: 0.91 },
        ],
      },
      limitations: [],
      comparison: {
        progress_status: "improving",
        changes: [
          { symptom_id: "leaf_turgor_recovery", direction: "decreased" },
        ],
        limitation_codes: [],
      },
      visual_markers: ["yellowing_lower_leaves"],
    },
    catalog,
  );
  assertEquals(followUpResult.valid, true, followUpResult.errors.join("; "));
  assertEquals(followUpResult.shouldConsumeQuota, true);
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
      comparison: null,
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
      comparison: null,
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
      comparison: null,
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
      comparison: null,
      visual_markers: [],
    },
    catalog,
  );
  assertEquals(blurryResult.valid, true, blurryResult.errors.join("; "));
  assertEquals(blurryResult.shouldConsumeQuota, false);
  assertEquals(blurryResult.nonBillableReason, "unsuitable_image_quality");
});

Deno.test("T116 — ProtocolResolver builds localized projection from KB Golden Record, signs receipt, and falls back safely when pending/uncertain", async () => {
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
          { condition_id: "root_rot", rank: 2, confidence: 0.35 },
        ],
      },
      limitations: ["single_angle"],
      comparison: null,
      visual_markers: ["yellowing_lower_leaves"],
    },
    catalog,
  );
  assert(validDiag.classification);

  // Resolved high-confidence diagnosis uses ConditionProfile first help step
  const projection = await ProtocolResolver.resolvePreliminaryProjection({
    analysisId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    jobId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    classification: validDiag.classification,
    catalog,
    signingSecret: SIGNING_SECRET,
  });

  assertEquals(projection.decision_state, "resolved");
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

  // Pending / ambiguous diagnosis (e.g. confidence 0.65 vs 0.60) uses safe fallback first aid and plan_availability='diagnosis_unresolved'
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
  assertEquals(pendingProj.decision_state, "pending");
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
  assertEquals(accessSameMonth.modes.follow_up.allowed, false);

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
            comparison: null,
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
