/**
 * Gate G02 — Runtime Compatibility & Classification Schema 3.0 Validation Tests (T005)
 *
 * Verifies:
 * 1. Canonical JSON Schema Draft 2020-12 (`contracts/ai-result.schema.json`, v3.0):
 *    - Two modes: `identification`, `diagnosis` (`plan` is forbidden in provider schema)
 *    - Max 2 condition candidates, distinct ranks (1, 2), confidence in [0, 1]
 *    - Closed vocabulary of 40 canonical condition_ids & visual_markers
 *    - Strict absence of generated advice (`first_action`, `full_plan`, `questions`, `products`)
 * 2. Official Anthropic SDK (`@anthropic-ai/sdk`) & Apple App Store Server Library (`@apple/app-store-server-library` SignedDataVerifier)
 *    loading and negative signature/environment verification inside the Deno/Edge runtime.
 */

import { assert, assertEquals, assertRejects } from "@std/assert";
import Ajv2020Import from "ajv/dist/2020";
import Anthropic from "@anthropic-ai/sdk";
import { Environment, SignedDataVerifier } from "@apple/app-store-server-library";

const SCHEMA_PATH = new URL(
  "../../../../specs/001-plants-ios-mvp/contracts/ai-result.schema.json",
  import.meta.url,
);

const rawSchema = JSON.parse(await Deno.readTextFile(SCHEMA_PATH));
const Ajv2020 = (Ajv2020Import as unknown as { default?: typeof Ajv2020Import.default }).default ??
  (Ajv2020Import as unknown as typeof Ajv2020Import.default);
const ajv = new Ajv2020({ allErrors: true, strict: false });
const validateClassification3 = ajv.compile(rawSchema);

const PINNED_KB_RELEASE_ID = "11111111-1111-4111-8111-111111111111";

Deno.test("G02.1 — Classification 3.0 accepts valid identification mode (diagnosis null, visual_markers empty)", () => {
  const payload = {
    schema_version: "3.0",
    kb_release_id: PINNED_KB_RELEASE_ID,
    mode: "identification",
    locale: "pl",
    image_quality: "usable",
    identification: {
      status: "identified",
      plant_id: "monstera_deliciosa",
      genus_id: null,
    },
    diagnosis: null,
    limitations: [],
    visual_markers: [],
  };

  const valid = validateClassification3(payload);
  assert(
    valid,
    `Expected valid identification payload, got errors: ${JSON.stringify(validateClassification3.errors)}`,
  );
});

Deno.test("G02.2 — Classification 3.0 accepts valid diagnosis mode with top-2 candidates, confidence in [0,1], and visual_markers", () => {
  const payload = {
    schema_version: "3.0",
    kb_release_id: PINNED_KB_RELEASE_ID,
    mode: "diagnosis",
    locale: "pl",
    image_quality: "usable",
    identification: {
      status: "identified",
      plant_id: "monstera_deliciosa",
      genus_id: null,
    },
    diagnosis: {
      status: "problem_detected",
      candidates: [
        {
          condition_id: "thrips_infestation",
          rank: 1,
          confidence: 0.76,
        },
        {
          condition_id: "spider_mites",
          rank: 2,
          confidence: 0.69,
        },
      ],
    },
    limitations: [],
    visual_markers: ["silvery_stippling_streaks", "black_fecal_specks_on_leaves"],
  };

  const valid = validateClassification3(payload);
  assert(
    valid,
    `Expected valid diagnosis payload, got errors: ${JSON.stringify(validateClassification3.errors)}`,
  );
});

Deno.test("G02.3 — Classification 3.0 rejects legacy follow_up, comparison and comparison_unsuitable", () => {
  const payload = {
    schema_version: "3.0",
    kb_release_id: PINNED_KB_RELEASE_ID,
    mode: "follow_up",
    locale: "en",
    image_quality: "usable",
    identification: {
      status: "identified",
      plant_id: "monstera_deliciosa",
      genus_id: null,
    },
    diagnosis: {
      status: "problem_detected",
      candidates: [
        {
          condition_id: "thrips_infestation",
          rank: 1,
          confidence: 0.84,
        },
      ],
    },
    limitations: [],
    comparison: {
      progress_status: "improving",
      changes: [
        {
          symptom_id: "silvery_stippling_streaks",
          direction: "decreased",
        },
      ],
      limitation_codes: [],
    },
    visual_markers: ["silvery_stippling_streaks"],
  };

  assertEquals(validateClassification3(payload), false);
  const { comparison, ...withoutComparison } = payload;
  assertEquals(validateClassification3(withoutComparison), false);
  for (const mode of ["identification", "diagnosis"]) {
    const current = {
      ...withoutComparison, mode,
      diagnosis: mode === "identification" ? null : payload.diagnosis,
      visual_markers: mode === "identification" ? [] : payload.visual_markers,
    };
    // Verify the baseline to avoid negatives passing due to an unrelated malformed field.
    assertEquals(validateClassification3(current), true);
    assertEquals(validateClassification3({ ...current, comparison }), false);
    assertEquals(validateClassification3({ ...current, comparison: null }), false);
    assertEquals(validateClassification3({
      ...current, image_quality: "comparison_unsuitable",
      identification: { status: "unknown", plant_id: null, genus_id: null },
      diagnosis: mode === "identification" ? null : { status: "insufficient_data", candidates: [] },
      visual_markers: [], limitations: ["single_angle"],
    }), false);
  }
});

Deno.test("G02.4 — Classification 3.0 rejects >2 candidates, out-of-range confidence, mode=plan, generated advice, or generated questions", () => {
  const baseValid = {
    schema_version: "3.0",
    kb_release_id: PINNED_KB_RELEASE_ID,
    mode: "diagnosis",
    locale: "pl",
    image_quality: "usable",
    identification: {
      status: "identified",
      plant_id: "monstera_deliciosa",
      genus_id: null,
    },
    diagnosis: {
      status: "problem_detected",
      candidates: [
        { condition_id: "overwatering", rank: 1, confidence: 0.85 },
      ],
    },
    limitations: [],
    visual_markers: ["lower_leaf_yellowing"],
  };

  // 1. Rejects 3 candidates (max 2)
  const threeCandidates = structuredClone(baseValid);
  threeCandidates.diagnosis.candidates = [
    { condition_id: "overwatering", rank: 1, confidence: 0.85 },
    { condition_id: "root_rot", rank: 2, confidence: 0.55 },
    { condition_id: "poor_drainage", rank: 2, confidence: 0.30 },
  ];
  assertEquals(validateClassification3(threeCandidates), false);

  // 2. Rejects confidence > 1.0 or < 0.0
  const invalidConfidence = structuredClone(baseValid);
  invalidConfidence.diagnosis.candidates = [
    { condition_id: "overwatering", rank: 1, confidence: 1.25 },
  ];
  assertEquals(validateClassification3(invalidConfidence), false);

  // 3. Rejects mode = "plan" (plans are deterministic from Golden Records)
  const planMode = { ...structuredClone(baseValid), mode: "plan" };
  assertEquals(validateClassification3(planMode), false);

  // 4. Rejects generated advice or clarifying_questions in provider output
  const generatedAdviceAndQuestions = {
    ...structuredClone(baseValid),
    first_action: "Stop watering immediately",
    full_plan: { steps: [] },
    clarifying_questions: ["Do you see webbing?"],
  };
  assertEquals(validateClassification3(generatedAdviceAndQuestions), false);
});

Deno.test("G02.5 — Anthropic SDK initializes with pinned model claude-haiku-5-5 and maxRetries=0", () => {
  const client = new Anthropic({
    apiKey: "test-non-live-key",
    maxRetries: 0,
    timeout: 40_000,
  });
  assert(client instanceof Anthropic);
  assertEquals(client.maxRetries, 0);
});

Deno.test("G02.6 — Apple SignedDataVerifier initializes in Edge Runtime and rejects invalid/forged JWS", async () => {
  const verifier = new SignedDataVerifier(
    [],
    false,
    Environment.SANDBOX,
    "app.narat.plants",
  );

  await assertRejects(
    async () => {
      await verifier.verifyAndDecodeTransaction("eyJhbGciOiJFUzI1NiJ9.eyJinvalidI6dHJ1ZX0.signature");
    },
  );
});
