import { assertEquals } from "@std/assert";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  evaluateClaimStaleTransition,
  handlePrepareClaim,
  verifyAnalysisReceiptSignature,
} from "../../plants-api/claims.ts";
import { rankCatalogueSpecies } from "../../plants-api/catalogue.ts";
import {
  canEnableFreeBasicCareWithoutReplacement,
  resolveActiveFreePlantIds,
} from "../BasicCareService.ts";
import { signAnalysisReceipt } from "../ProtocolResolver.ts";

Deno.test("T040: Claim overrides keep context_state=current and care_revision=1 when only display_name changes", () => {
  const original = {
    species_id: "11111111-1111-4111-8111-111111111101",
    watering_habit: "weekly",
    light_level: "bright_indirect",
    recent_changes: "none",
    pot_type: "drainage",
    season_override: "auto",
  };

  const nameOnly = evaluateClaimStaleTransition(original, {
    display_name: "Salon Monstera",
  });
  assertEquals(nameOnly.isStale, false);
  assertEquals(nameOnly.careRevision, 1);
  assertEquals(nameOnly.contextState, "current");
});

Deno.test("T040: Claim overrides transition analysis to stale and care_revision=2 when species or care conditions change", () => {
  const original = {
    species_id: "11111111-1111-4111-8111-111111111101",
    watering_habit: "weekly",
    light_level: "bright_indirect",
    recent_changes: "none",
    pot_type: "drainage",
    season_override: "auto",
  };

  const speciesChanged = evaluateClaimStaleTransition(original, {
    species_id: "11111111-1111-4111-8111-111111111102",
  });
  assertEquals(speciesChanged.isStale, true);
  assertEquals(speciesChanged.careRevision, 2);
  assertEquals(speciesChanged.contextState, "stale");

  const conditionChanged = evaluateClaimStaleTransition(original, {
    light_level: "low",
  });
  assertEquals(conditionChanged.isStale, true);
  assertEquals(conditionChanged.careRevision, 2);
  assertEquals(conditionChanged.contextState, "stale");
});

// Return the same frozen parsed object so writes to the request body cannot be
// hidden by Request.json() producing a separate object for the handler.
function claimRequest(body: object): Request {
  const request = new Request("https://example.test/claims/prepare", {
    method: "POST",
    body: JSON.stringify(body),
  });
  request.json = () => Promise.resolve(body);
  return request;
}

Deno.test("T158: prepare rejects each retired room key, including null, before any RPC without mutation", async () => {
  for (const key of ["room_id", "new_room_name", "create_room_name"]) {
    for (const value of ["legacy-room", null]) {
      const overrides = Object.freeze({
        display_name: "Salon Monstera",
        light_level: "low",
        light_confirmed: false,
        [key]: value,
      });
      const body = Object.freeze({
        operation_id: "operation-1",
        draft_id: "draft-1",
        installation_id: "installation-1",
        installation_credential: "fixture-credential",
        overrides,
      });
      const before = JSON.stringify(body);
      let rpcCalls = 0;
      const adapter = {
        rpc: () => {
          rpcCalls += 1;
          throw new Error("Retired room input must not reach RPC");
        },
      } as unknown as SupabaseClient;
      const response = await handlePrepareClaim(claimRequest(body), adapter, "owner-1");
      assertEquals(response.status, 400);
      assertEquals((await response.json()).error.code, "VALIDATION_ERROR");
      assertEquals(rpcCalls, 0);
      assertEquals(JSON.stringify(body), before);
    }
  }
});

Deno.test("T158: non-room overrides preserve existing prepare RPC arguments and response", async () => {
  const overrides = Object.freeze({
    species_id: "species-1",
    display_name: "Salon Monstera",
    watering_habit: "weekly",
    light_level: "low",
    light_source: "manual_selection",
    light_confirmed: false,
    recent_changes: "none",
    pot_type: "drainage",
    season_override: "auto",
  });
  const body = Object.freeze({
    operation_id: "operation-1",
    draft_id: "draft-1",
    installation_id: "installation-1",
    installation_credential: "fixture-credential",
    overrides,
  });
  const before = JSON.stringify(body);
  const calls: { name: string; args: unknown }[] = [];
  const fixtureResult = { claim_id: "fixture-claim" };
  const adapter = {
    rpc: (name: string, args: unknown) => {
      calls.push({ name, args });
      return Promise.resolve({ data: fixtureResult, error: null });
    },
  } as unknown as SupabaseClient;
  const response = await handlePrepareClaim(claimRequest(body), adapter, "owner-1");
  assertEquals(calls, [{
    name: "prepare_guest_claim",
    args: {
      p_owner_id: "owner-1",
      p_operation_id: body.operation_id,
      p_draft_id: body.draft_id,
      p_installation_id: body.installation_id,
      p_credential_raw: body.installation_credential,
      p_overrides: overrides,
    },
  }]);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), fixtureResult);
  assertEquals(JSON.stringify(body), before);
  // This adapter checks forwarding only; the baseline SQL signature mismatch is T159.
});

Deno.test("T040: Fallback receipt verification accepts valid HMAC signature and rejects tampered payload or hash", async () => {
  const secret = "test-receipt-signing-secret";
  const signedToken = await signAnalysisReceipt(
    {
      analysis_id: "33333333-3333-4333-8333-333333333333",
      kb_release_id: "22222222-2222-4222-8222-222222222222",
      mode: "identification",
      plant_id: "11111111-1111-4111-8111-111111111101",
      selected_condition_id: null,
      decision_revision: 1,
      issued_at: "2026-11-01T12:00:00Z",
    },
    secret,
  );

  const valid = await verifyAnalysisReceiptSignature(signedToken, secret);
  assertEquals(valid, true);

  // Tamper with payload part of token
  const parts = signedToken.split(".");
  const tamperedBody = btoa(
    JSON.stringify({
      analysis_id: "33333333-3333-4333-8333-333333333333",
      kb_release_id: "22222222-2222-4222-8222-222222222222",
      mode: "diagnosis",
      plant_id: "11111111-1111-4111-8111-111111111101",
      selected_condition_id: "root_rot",
      decision_revision: 1,
      issued_at: "2026-11-01T12:00:00Z",
    }),
  );
  const invalid = await verifyAnalysisReceiptSignature(`${tamperedBody}.${parts[1]}`, secret);
  assertEquals(invalid, false);
});

Deno.test("T045: Catalogue search ranks PL/EN/Latin/synonyms and falls back to scientific_name when localized name is missing", () => {
  const species = [
    {
      id: "11111111-1111-4111-8111-111111111101",
      plant_key: "monstera_deliciosa",
      scientific_name: "Monstera deliciosa",
      name_en: "Swiss Cheese Plant",
      name_pl: "Monstera dziurawa",
      synonyms_en: ["Split-leaf philodendron"],
      synonyms_pl: ["Filodendron dziurawy"],
      synonyms_latin: ["Tornelia fragrans"],
      care_profile_available: true,
      hero_image_url: "https://example.com/monstera.jpg",
      attribution_author: "Jan Kowalski",
      attribution_license: "CC BY-SA 4.0",
      attribution_source_url: "https://commons.wikimedia.org/wiki/File:Monstera.jpg",
      share_alike_required: true,
    },
    {
      id: "11111111-1111-4111-8111-111111111102",
      plant_key: "hoya_carnosa",
      scientific_name: "Hoya carnosa",
      name_en: "Wax Plant",
      name_pl: null,
      synonyms_en: ["Porcelain flower"],
      synonyms_pl: ["Woskownica"],
      synonyms_latin: [],
      care_profile_available: false,
      hero_image_url: null,
      attribution_author: null,
      attribution_license: null,
      attribution_source_url: null,
      share_alike_required: false,
    },
  ];

  const plMatch = rankCatalogueSpecies(species, "Filodendron", "pl");
  assertEquals(plMatch.length, 1);
  assertEquals(plMatch[0].plant_key, "monstera_deliciosa");
  assertEquals(plMatch[0].matched_synonym, "Filodendron dziurawy");
  assertEquals(plMatch[0].attribution?.license, "CC BY-SA 4.0");

  // Scientific fallback when PL name is null
  const fallbackMatch = rankCatalogueSpecies(species, "woskownica", "pl");
  assertEquals(fallbackMatch.length, 1);
  assertEquals(fallbackMatch[0].display_name, "Hoya carnosa");
  assertEquals(fallbackMatch[0].care_profile_available, false);
});

Deno.test("T129: BasicCareService resolves Free-3 slots deterministically and supports paid unlimited + expiry fallback", () => {
  const memberships = [
    {
      plant_id: "p-4",
      enabled: true,
      enabled_at: "2026-11-01T10:04:00Z",
      free_slot: null,
    },
    {
      plant_id: "p-1",
      enabled: true,
      enabled_at: "2026-11-01T10:01:00Z",
      free_slot: 1,
    },
    {
      plant_id: "p-2",
      enabled: true,
      enabled_at: "2026-11-01T10:02:00Z",
      free_slot: 2,
    },
    {
      plant_id: "p-3",
      enabled: true,
      enabled_at: "2026-11-01T10:03:00Z",
      free_slot: 3,
    },
  ];

  // Free user without explicit selection gets first 3 by enabled_at
  const freeAuto = resolveActiveFreePlantIds(memberships, false, false);
  assertEquals(freeAuto, ["p-1", "p-2", "p-3"]);
  assertEquals(canEnableFreeBasicCareWithoutReplacement(memberships, "p-4", false), false);

  // Paid user gets all 4 enabled plants
  const paidAll = resolveActiveFreePlantIds(memberships, false, true);
  assertEquals(paidAll.length, 4);

  // Explicit selection replaces p-2 with p-4
  const explicitMemberships = [
    { ...memberships[0], free_slot: 2 },
    { ...memberships[1], free_slot: 1 },
    { ...memberships[2], free_slot: null },
    { ...memberships[3], free_slot: 3 },
  ];
  const freeExplicit = resolveActiveFreePlantIds(explicitMemberships, true, false);
  assertEquals(freeExplicit, ["p-1", "p-4", "p-3"]);
});
