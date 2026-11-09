import { assertEquals } from "@std/assert";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  evaluateClaimStaleTransition,
  handlePrepareClaim,
  verifyAnalysisReceiptSignature,
} from "../../plants-api/claims.ts";
import { rankCatalogueSpecies } from "../../plants-api/catalogue.ts";
import type { BasicCareStateDTO } from "../BasicCareService.ts";
import { handleBasicCareCommand } from "../../plants-api/basic-care.ts";
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

Deno.test("T161: basic-care HTTP forwards no-slot commands and preserves legacy receipt boundaries", async () => {
  const ownerId = "11111111-1111-4111-8111-111111111111";
  const plantId = "22222222-2222-4222-8222-222222222222";
  const state: BasicCareStateDTO = {
    has_paid_access: false,
    memberships: Array.from({ length: 4 }, (_, i) => ({
      plant_id: `plant-${i}`, enabled: i !== 1, enabled_at: "2026-11-01T00:00:00Z",
    })),
  };
  const legacyPayload = { plant_id: plantId, selected_plant_ids: ["p-2", "p-1"] };
  const legacyResponse = {
    status: "committed", command_type: "free_care.select",
    state: {
      has_paid_access: false, free_selection_explicit: true,
      memberships: [{ plant_id: "p-2", enabled: true, enabled_at: "old", free_slot: 1 }],
    },
  };
  // Fixture receipt lookup only; SQL tests own PostgreSQL jsonb hashing/atomicity.
  const receipts = new Map([
    ["legacy", { payload: legacyPayload, response: legacyResponse }],
    ["legacy-null", { payload: {}, response: legacyResponse }],
  ]);
  const calls: Record<string, unknown>[] = [];
  const fake = {
    rpc: (name: string, args: Record<string, unknown>) => {
      assertEquals(name, "execute_basic_care_command");
      assertEquals(Object.keys(args).sort(), [
        "p_command_type", "p_operation_id", "p_owner_id", "p_payload",
      ]);
      assertEquals(args.p_owner_id, ownerId);
      calls.push(args);
      const cached = receipts.get(args.p_operation_id as string);
      if (cached) {
        if (
          args.p_command_type !== "free_care.select" ||
          JSON.stringify(args.p_payload) !== JSON.stringify(cached.payload)
        ) return Promise.resolve({ data: null, error: { message: "operation_payload_mismatch" } });
        return Promise.resolve({ data: cached.response, error: null });
      }
      if (args.p_command_type === "free_care.select") {
        return Promise.resolve({ data: null, error: { message: "FREE_SELECTION_RETIRED" } });
      }
      if (args.p_operation_id === "rpc-failure") {
        return Promise.resolve({ data: null, error: { message: "rpc unavailable" } });
      }
      if (args.p_operation_id === "rpc-empty") {
        return Promise.resolve({ data: null, error: null });
      }
      return Promise.resolve({
        data: { status: "committed", command_type: args.p_command_type, state }, error: null,
      });
    },
  } as unknown as SupabaseClient;
  const request = (body: unknown) => handleBasicCareCommand(new Request(
    "https://fixture.invalid/basic-care", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    },
  ), fake, ownerId);

  for (const command_type of ["basic_care.enable", "basic_care.disable"]) {
    const response = await request({ operation_id: command_type, command_type, plant_id: plantId });
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { status: "committed", command_type, state });
    assertEquals(calls.at(-1), {
      p_owner_id: ownerId, p_operation_id: command_type, p_command_type: command_type,
      p_payload: { plant_id: plantId },
    });
  }
  // New select always reaches SQL, including malformed/null arrays; no fallback success.
  for (const selection of [null, "invalid", [], ["1", "2", "3", "4"], ["p-1"]]) {
    const before = calls.length;
    const response = await request({
      operation_id: "new-select", command_type: "free_care.select",
      selected_plant_ids: selection,
    });
    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, {
      code: "VALIDATION_ERROR", message: "FREE_SELECTION_RETIRED", retryable: false,
    });
    assertEquals(calls.length, before + 1);
    assertEquals(calls.at(-1)?.p_payload, selection ? { selected_plant_ids: selection } : {});
  }
  for (const [operation_id, payload] of [
    ["legacy", legacyPayload],
    ["legacy-null", { selected_plant_ids: null }],
  ] as const) {
    const response = await request({ operation_id, command_type: "free_care.select", ...payload });
    assertEquals(response.status, 200);
    // Historical fields remain in historical receipts, never projected into a new DTO.
    assertEquals(await response.json(), legacyResponse);
  }
  for (const payload of [
    { ...legacyPayload, selected_plant_ids: ["p-1", "p-2"] },
    { selected_plant_ids: legacyPayload.selected_plant_ids },
    { ...legacyPayload, selected_plant_ids: null },
    { ...legacyPayload, selected_plant_ids: "invalid" },
  ]) {
    const response = await request({
      operation_id: "legacy", command_type: "free_care.select", ...payload,
    });
    assertEquals(response.status, 409);
    assertEquals((await response.json()).error.code, "CONFLICT");
  }
  const wrongCommand = await request({
    operation_id: "legacy", command_type: "basic_care.enable", plant_id: plantId,
  });
  assertEquals(wrongCommand.status, 409);
  assertEquals((await wrongCommand.json()).error.code, "CONFLICT");

  for (const body of [
    null, [], 1, {}, { operation_id: 1, command_type: "free_care.select" },
    { operation_id: "unknown", command_type: "unknown" },
    { operation_id: "missing-plant", command_type: "basic_care.enable" },
    { operation_id: "bad-plant", command_type: "basic_care.disable", plant_id: [] },
    { operation_id: "extra", command_type: "basic_care.enable", plant_id: plantId, selected_plant_ids: [] },
  ]) {
    const before = calls.length;
    const response = await request(body);
    assertEquals(response.status, 400);
    assertEquals((await response.json()).error.code, "VALIDATION_ERROR");
    assertEquals(calls.length, before);
  }
  const before = calls.length;
  const invalidJson = await handleBasicCareCommand(new Request("https://fixture.invalid/basic-care", {
    method: "POST", body: "{",
  }), fake, ownerId);
  assertEquals(invalidJson.status, 400);
  assertEquals((await invalidJson.json()).error.code, "VALIDATION_ERROR");
  assertEquals(calls.length, before);
  for (const operation_id of ["rpc-failure", "rpc-empty"]) {
    const response = await request({
      operation_id, command_type: "basic_care.enable", plant_id: plantId,
    });
    assertEquals(response.status, 400);
    assertEquals((await response.json()).error.code, "VALIDATION_ERROR");
  }
  assertEquals(receipts.size, 2);
});
