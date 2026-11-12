// supabase/functions/_shared/tests/foundational_services_test.ts
// Unit tests for T019 (plants-api router & http), T020 (EntitlementGate),
// T021 (catalogue/import.ts), and T128 (notifications.ts).

import { assert, assertEquals } from "@std/assert";
import { EntitlementGate, EntitlementSnapshot, ExistingPlanRecord } from "../EntitlementGate.ts";
import { createPlantsApiHandler } from "../../plants-api/index.ts";
import {
  CatalogueSkeletonBundle,
  KbReleaseBundle,
  validateAndProjectSkeletonRelease,
  validateAndStageKbRelease,
  validateCatalogueSkeletonCardContract,
} from "../../../../catalogue/import.ts";

Deno.test("T020: EntitlementGate separates canReadExistingPlan from canGenerateFullPlan and honors verified trial & no-history Free care", () => {
  const now = new Date("2026-11-05T12:00:00Z");

  const activeTrialEntitlement: EntitlementSnapshot = {
    ownerId: "11111111-1111-4111-8111-111111111111",
    accountState: "active",
    subscriptionState: "active",
    offerKind: "trial",
    validUntil: "2026-11-10T12:00:00Z",
    trialEndAt: "2026-11-10T12:00:00Z",
    autoRenewEnabled: true,
    verifiedAt: "2026-11-03T12:00:00Z",
    paidMonthlyConsumed: 100,
    paidMonthlyLimit: 100,
  };

  // Exhausting 100 monthly analysis scans does NOT block generating a full plan
  assertEquals(EntitlementGate.canGenerateFullPlan(activeTrialEntitlement, now), true);

  const expiredEntitlement: EntitlementSnapshot = {
    ...activeTrialEntitlement,
    subscriptionState: "expired",
    validUntil: "2026-11-01T12:00:00Z",
    trialEndAt: "2026-11-01T12:00:00Z",
  };

  assertEquals(EntitlementGate.canGenerateFullPlan(expiredEntitlement, now), false);

  const existingPlan: ExistingPlanRecord = {
    id: "22222222-2222-4222-8222-222222222222",
    ownerId: activeTrialEntitlement.ownerId,
    plantId: "33333333-3333-4333-8333-333333333333",
    accessTier: "full",
    planKind: "recovery",
    state: "active",
    applicabilityStatus: "applicable",
    chemicalMustRevalidateAfter: "2026-11-20",
  };

  // Owner can still read previously published full plan after expiry
  const readAfterExpiry = EntitlementGate.canReadExistingPlan(
    expiredEntitlement,
    existingPlan,
    now,
  );
  assertEquals(readAfterExpiry.allowed, true);
  assertEquals(readAfterExpiry.instructionsApplicable, true);

  // Chemical validity is evaluated independently of subscription state
  const expiredChemicalPlan: ExistingPlanRecord = {
    ...existingPlan,
    chemicalMustRevalidateAfter: "2026-11-01",
  };
  const readExpiredChem = EntitlementGate.canReadExistingPlan(
    activeTrialEntitlement,
    expiredChemicalPlan,
    now,
  );
  assertEquals(readExpiredChem.allowed, true);
  assertEquals(readExpiredChem.instructionsApplicable, false);
  assertEquals(readExpiredChem.chemicalExpired, true);
  assertEquals(readExpiredChem.reason, "chemical_revalidation_required");

  const membership = {
    ownerId: activeTrialEntitlement.ownerId,
    plantId: existingPlan.plantId,
    enabled: true,
    deletedAt: null,
  };
  const free: EntitlementSnapshot = {
    ...expiredEntitlement, subscriptionState: "none", offerKind: "none",
    validUntil: null, trialEndAt: null, verifiedAt: null,
  };
  assertEquals(EntitlementGate.canScheduleBasicCare(free, membership, now), true);
  assertEquals(EntitlementGate.canScheduleBasicCare(activeTrialEntitlement, membership, now), true);
  // No positional selection: all enabled memberships qualify, even in a legacy large collection.
  for (let i = 0; i < 5; i++) {
    assertEquals(EntitlementGate.canScheduleBasicCare(free, {
      ...membership, plantId: `plant-${i}`,
    }, now), true);
  }
  const denied: EntitlementSnapshot[] = [
    expiredEntitlement,
    { ...activeTrialEntitlement, subscriptionState: "revoked" },
    { ...activeTrialEntitlement, subscriptionState: "billing_retry" },
    { ...activeTrialEntitlement, subscriptionState: "grace", validUntil: now.toISOString() },
    { ...activeTrialEntitlement, validUntil: "2026-11-01T00:00:00Z" },
    { ...activeTrialEntitlement, verifiedAt: null },
    { ...free, offerKind: "paid" },
    { ...free, accountState: "deleting" },
  ];
  for (const entitlement of denied) {
    // An old wire slot cannot restore rights after expiry/revocation.
    const legacyMembership = { ...membership, freeSlot: 1 };
    assertEquals(EntitlementGate.canScheduleBasicCare(entitlement, legacyMembership, now), false);
  }
  assertEquals(EntitlementGate.canScheduleBasicCare({
    ...activeTrialEntitlement, subscriptionState: "grace",
  }, membership, now), true);
  for (const invalid of [
    null,
    { ...membership, ownerId: "other-owner" },
    { ...membership, enabled: false },
    { ...membership, deletedAt: now.toISOString() },
  ]) {
    assertEquals(EntitlementGate.canScheduleBasicCare(free, invalid, now), false);
    assertEquals(EntitlementGate.canScheduleBasicCare(activeTrialEntitlement, invalid, now), false);
  }
});

Deno.test("T019 & T128: plants-api router and POST /notifications/claim validate report period_key and dedup", async () => {
  const ownerId = "11111111-1111-4111-8111-111111111111";
  const claimedSet = new Map<string, { device: string; state: "claimed" | "cancelled" }>();

  const handler = createPlantsApiHandler({
    resolveRequestContext: async (req) => ({
      ownerId,
      isAnonymous: false,
      accountState: "active",
      installationCredential: req.headers.get("x-installation-credential"),
      locale: "pl",
      operationId: null,
    }),
    notificationAdapter: {
      claimSlot: async (params) => {
        const key = `${params.ownerId}:${params.kind}:${params.periodKey}`;
        const existing = claimedSet.get(key);
        if (existing) {
          if (existing.state === "cancelled") {
            return {
              granted: false,
              kind: params.kind,
              period_key: params.periodKey,
              state: "cancelled",
              reason: "already_cancelled_for_period",
            };
          }
          if (existing.device !== params.deviceInstallationId) {
            return {
              granted: false,
              kind: params.kind,
              period_key: params.periodKey,
              state: "claimed",
              reason: "already_claimed_by_other_device",
            };
          }
        }
        claimedSet.set(key, { device: params.deviceInstallationId, state: "claimed" });
        return {
          granted: true,
          claim_id: "44444444-4444-4444-8444-444444444444",
          kind: params.kind,
          period_key: params.periodKey,
          state: "claimed",
        };
      },
    },
  });

  // Reject monthly_report period_key with timezone suffix
  const badRes = await handler(
    new Request("https://api.narat.app/functions/v1/plants-api/notifications/claim", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Installation-Credential": "device-a",
      },
      body: JSON.stringify({
        operation_id: "55555555-5555-4555-8555-555555555555",
        kind: "monthly_report",
        period_key: "2026-10+02:00",
      }),
    }),
  );
  assertEquals(badRes.status, 400);

  // Valid claim on device A succeeds
  const okRes = await handler(
    new Request("https://api.narat.app/functions/v1/plants-api/notifications/claim", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Installation-Credential": "device-a",
      },
      body: JSON.stringify({
        operation_id: "55555555-5555-4555-8555-555555555556",
        kind: "monthly_report",
        period_key: "2026-10",
      }),
    }),
  );
  assertEquals(okRes.status, 200);
  const okBody = await okRes.json();
  assertEquals(okBody.granted, true);

  // Device B claiming the same period is denied
  const dupRes = await handler(
    new Request("https://api.narat.app/functions/v1/plants-api/notifications/claim", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Installation-Credential": "device-b",
      },
      body: JSON.stringify({
        operation_id: "55555555-5555-4555-8555-555555555557",
        kind: "monthly_report",
        period_key: "2026-10",
      }),
    }),
  );
  const dupBody = await dupRes.json();
  assertEquals(dupBody.granted, false);
  assertEquals(dupBody.reason, "already_claimed_by_other_device");
});

Deno.test("T021: validateAndStageKbRelease enforces thresholds, PL/EN completeness, and strips paid protocols from catalogue projection", () => {
  const bundle: KbReleaseBundle = {
    kb_release_id: "66666666-6666-4666-8666-666666666666",
    version: "2026.11.01",
    schema_version: "3.0",
    manifest_sha256: "a".repeat(64),
    approved_source_codes: ["RHS_GARDENING", "POWO_KEW"],
    evidence_ids: ["ev_1"],
    plants: [
      {
        schema_version: "3.0",
        kb_release_id: "66666666-6666-4666-8666-666666666666",
        plant_id: "monstera_deliciosa",
        taxon_id: "77777777-7777-4777-8777-777777777777",
        scientific_name: "Monstera deliciosa",
        genus_id: "monstera",
        family: "Araceae",
        status: "published",
        reviewed_by: "editor@narat.app",
        reviewed_at: "2026-11-01T00:00:00Z",
        names: {
          pl: { primary: "Monstera dziurawa", synonyms: ["Monstera"] },
          en: { primary: "Swiss Cheese Plant", synonyms: ["Monstera"] },
        },
        safety: {
          cat: { status: "toxic", severity: "moderate", evidence_ids: ["ev_1"] },
          dog: { status: "toxic", severity: "moderate", evidence_ids: ["ev_1"] },
        },
        care_summary: {
          light: { pl: "Jasne rozproszone", en: "Bright indirect" },
          watering: { pl: "Gdy верхняя warstwa przeschnie", en: "When top layer dries" },
          soil_and_pot: { pl: "Przepuszczalne podłoże", en: "Well-draining soil" },
          water_interval_days: { min: 5, max: 10, default_days: 7 },
        },
        routine_plan_template: { secret_paid_steps: ["Full step 1"] },
        evidence_ids: ["ev_1"],
      },
    ],
    conditions: [],
  };

  // When launch thresholds (300/40) are enforced, a 1-plant bundle is quarantined
  const strictResult = validateAndStageKbRelease(bundle, { enforceLaunchThresholds: true });
  assertEquals(strictResult.valid, false);
  assertEquals(strictResult.releaseState, "quarantined");

  // Without 300/40 threshold check, the record validates and strips routine_plan_template from projection
  const unitResult = validateAndStageKbRelease(bundle, { enforceLaunchThresholds: false });
  assertEquals(unitResult.valid, true);
  assertEquals(unitResult.releaseState, "published");
  assertEquals(unitResult.publicCatalogueProjection.length, 1);
  assert(!("routine_plan_template" in unitResult.publicCatalogueProjection[0]));
});

Deno.test("T147: validateAndProjectSkeletonRelease validates and projects 606-species basic catalogue without kb_releases or care/condition profiles", async () => {
  const skeletonUrl = new URL(
    "../../../../catalogue/releases/skeleton-300-v1/plants.json",
    import.meta.url,
  );
  const raw = await Deno.readTextFile(skeletonUrl);
  const bundle = JSON.parse(raw) as CatalogueSkeletonBundle;

  const enResult = validateAndProjectSkeletonRelease(bundle, { minSpeciesCount: 300, locale: "en" });
  assertEquals(enResult.valid, true, `Errors: ${enResult.errors.join("; ")}`);
  assertEquals(enResult.kbReleaseId, null);
  assertEquals(enResult.speciesCount, 606);
  assertEquals(enResult.cards.length, 606);

  const plResult = validateAndProjectSkeletonRelease(bundle, { minSpeciesCount: 300, locale: "pl" });
  assertEquals(plResult.valid, true);
  assertEquals(plResult.cards.length, 606);

  const monsteraPl = plResult.cards.find((c) => c.plant_id === "monstera_deliciosa");
  assert(monsteraPl !== undefined);
  assertEquals(monsteraPl.scientific_name, "Monstera deliciosa");
  assertEquals(monsteraPl.accepted_scientific_name, "Monstera deliciosa");
  assertEquals(monsteraPl.genus, "Monstera");
  assertEquals(monsteraPl.rank, "species");
  assertEquals(monsteraPl.description?.language, "pl");
  assert(Boolean(monsteraPl.watering?.intervals_days.spring));
  assertEquals(monsteraPl.care_profile_available, false);
  assertEquals(monsteraPl.safety.cat.status, "unknown");

  // Validate every projected card against the canonical 21-field DTO contract
  for (const card of enResult.cards) {
    assertEquals(validateCatalogueSkeletonCardContract(card), []);
  }
  for (const card of plResult.cards) {
    assertEquals(validateCatalogueSkeletonCardContract(card), []);
  }
});

Deno.test("T147: validateAndProjectSkeletonRelease rejects invalid sha256, watering intervals, wikidata_id, and description metadata", async () => {
  const skeletonUrl = new URL(
    "../../../../catalogue/releases/skeleton-300-v1/plants.json",
    import.meta.url,
  );
  const raw = await Deno.readTextFile(skeletonUrl);
  const bundle = JSON.parse(raw) as CatalogueSkeletonBundle;

  // 1. Reproduce audit probe: sha256='not-a-hash' and intervals {spring:-7, summer:'bad', fall:0, winter:null}
  const corrupted = structuredClone(bundle);
  corrupted.plants[0].hero_image.sha256 = "not-a-hash";
  corrupted.plants[0].watering!.intervals_days = {
    spring: -7,
    summer: "bad" as unknown as number,
    fall: 0,
    winter: null,
  };

  const res = validateAndProjectSkeletonRelease(corrupted, { minSpeciesCount: 300 });
  assertEquals(res.valid, false);
  assertEquals(res.cards.length, 0);
  assert(res.errors.some((e) => e.includes("invalid hero_image.sha256")));
  assert(res.errors.some((e) => e.includes("watering.intervals_days.spring")));
  assert(res.errors.some((e) => e.includes("watering.intervals_days.summer")));
  assert(res.errors.some((e) => e.includes("watering.intervals_days.fall")));
  assert(res.errors.some((e) => e.includes("requires at least 2 active seasonal intervals")));

  // 2. Reject invalid wikidata_id, mismatched description.language, and invalid match_level
  const badMeta = structuredClone(bundle);
  badMeta.plants[1].wikidata_id = "NOT_A_QID";
  badMeta.plants[1].descriptions.pl!.language = "en";
  badMeta.plants[1].watering!.match_level = "guessed" as unknown as "species_exact";

  const resMeta = validateAndProjectSkeletonRelease(badMeta, { minSpeciesCount: 300 });
  assertEquals(resMeta.valid, false);
  assert(resMeta.errors.some((e) => e.includes("wikidata_id")));
  assert(resMeta.errors.some((e) => e.includes("descriptions.pl.language")));
  assert(resMeta.errors.some((e) => e.includes("watering.match_level")));

  // 3. Reproduce Audit 2 probe on validateCatalogueSkeletonCardContract:
  //    hero_image.width=-1, wikidata_id='not-wikidata', descriptions.en.language='fr',
  //    plus taxon_id=42, common_names='oops', care_profile_available='yes'
  const validEn = validateAndProjectSkeletonRelease(bundle, { minSpeciesCount: 300, locale: "en" });
  const baseCard = structuredClone(validEn.cards[0]) as unknown as Record<string, unknown>;

  const probe1 = structuredClone(baseCard);
  (probe1.hero_image as Record<string, unknown>).width = -1;
  probe1.wikidata_id = "not-wikidata";
  ((probe1.descriptions as Record<string, unknown>).en as Record<string, unknown>).language = "fr";
  const errs1 = validateCatalogueSkeletonCardContract(probe1);
  assert(errs1.some((e) => e.includes("invalid hero_image dimensions")));
  assert(errs1.some((e) => e.includes("Invalid card.wikidata_id")));
  assert(errs1.some((e) => e.includes("card.descriptions.en.language")));

  const probe2 = structuredClone(baseCard);
  probe2.taxon_id = 42;
  probe2.common_names = "oops";
  probe2.care_profile_available = "yes";
  const errs2 = validateCatalogueSkeletonCardContract(probe2);
  assert(errs2.some((e) => e.includes("Invalid card.taxon_id")));
  assert(errs2.some((e) => e.includes("common_names must be an object")));
  assert(errs2.some((e) => e.includes("card.care_profile_available must be a boolean")));
});

Deno.test("T147: each DTO field independently rejects missing keys and wrong types", () => {
  const bundle = JSON.parse(Deno.readTextFileSync(new URL(
    "../../../../catalogue/releases/skeleton-300-v1/plants.json", import.meta.url,
  ))) as CatalogueSkeletonBundle;
  const result = validateAndProjectSkeletonRelease(bundle);
  assert(result.valid, result.errors.join("; "));
  const base = result.cards[0] as unknown as Record<string, unknown>;
  for (const key of Object.keys(base)) {
    const missing = structuredClone(base);
    delete missing[key];
    assert(validateCatalogueSkeletonCardContract(missing).length > 0, `missing ${key}`);
    const wrong = structuredClone(base);
    wrong[key] = [];
    assert(validateCatalogueSkeletonCardContract(wrong).length > 0, `wrong type ${key}`);
  }
  const cases = JSON.parse(Deno.readTextFileSync(new URL(
    "../../../../catalogue/contract-negative-cases.json", import.meta.url,
  ))) as { path: string[]; value: unknown }[];
  for (const { path, value } of cases) {
    const card = structuredClone(base);
    let parent = card;
    for (const part of path.slice(0, -1)) parent = parent[part] as Record<string, unknown>;
    parent[path.at(-1)!] = value;
    assert(validateCatalogueSkeletonCardContract(card).length > 0, `DTO ${path.join(".")}`);
    // Same one-field mutation must also fail import; no other corruption masks it.
    const record = structuredClone(bundle.plants[0]) as unknown as Record<string, unknown>;
    parent = record;
    for (const part of path.slice(0, -1)) parent = parent[part] as Record<string, unknown>;
    parent[path.at(-1)!] = value;
    assertEquals(validateAndProjectSkeletonRelease({ ...bundle, plants: [record] } as unknown as CatalogueSkeletonBundle,
      { minSpeciesCount: 1 }).valid, false, `import ${path.join(".")}`);
  }
  const nullable = structuredClone(bundle.plants[0]);
  nullable.watering!.intervals_days.winter = null;
  assert(validateAndProjectSkeletonRelease({ ...bundle, plants: [nullable] }, { minSpeciesCount: 1 }).valid);
  for (const season of ["spring", "summer", "fall", "winter"] as const) nullable.watering!.intervals_days[season] = null;
  assertEquals(validateAndProjectSkeletonRelease({ ...bundle, plants: [nullable] }, { minSpeciesCount: 1 }).valid, false);
  nullable.watering!.watering_method = "immersion";
  assert(validateAndProjectSkeletonRelease({ ...bundle, plants: [nullable] }, { minSpeciesCount: 1 }).valid);
});

Deno.test("T148: an explicit Polish gap preserves the original English description", () => {
  const bundle = JSON.parse(Deno.readTextFileSync(new URL(
    "../../../../catalogue/releases/skeleton-300-v1/plants.json",
    import.meta.url,
  ))) as CatalogueSkeletonBundle;
  const plant = structuredClone(bundle.plants[0]);
  const options = { locale: "pl" as const };
  const historical = validateAndProjectSkeletonRelease({ ...bundle, plants: [plant] }, options);
  assert(historical.valid);
  assertEquals(historical.cards[0].description, plant.descriptions.pl);

  plant.descriptions.pl = null;
  const fallback = validateAndProjectSkeletonRelease({ ...bundle, plants: [plant] }, options);
  assert(fallback.valid, fallback.errors.join("; "));
  assertEquals(fallback.cards[0].description, plant.descriptions.en);
  assertEquals(fallback.cards[0].descriptions.pl, null);
  assertEquals(validateCatalogueSkeletonCardContract(fallback.cards[0]), []);

  const withoutKey = { ...plant, descriptions: { en: plant.descriptions.en } };
  const incomplete = { ...bundle, plants: [withoutKey] } as CatalogueSkeletonBundle;
  assertEquals(validateAndProjectSkeletonRelease(incomplete, options).valid, false);
});
