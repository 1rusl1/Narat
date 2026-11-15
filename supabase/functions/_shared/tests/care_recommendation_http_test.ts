import { assert, assertEquals } from "@std/assert";
import profile from "../../../../knowledge-base/releases/staging-monstera-care-v2/monstera-watering.json" with {
  type: "json",
};
import { createProductionPlantsApiHandler } from "../../plants-api/index.ts";
import { ApiHttpError } from "../http.ts";
import { validatePublishedPlantCare } from "../KnowledgeTypes.ts";

const owner = "17100000-0000-4000-8000-000000000001";
const plant = "17100000-0000-4000-8000-000000000011";
const base = "https://care.example.test";
const path = `/functions/v1/plants-api/plants/${plant}/care/recommendation`;
const published = {
  plant_id: plant,
  plant_slug: "monstera_deliciosa",
  kb_release_id: profile.kb_release_id,
  profile,
};

function fixture(
  options: {
    row?: unknown;
    guest?: boolean;
    signedOut?: boolean;
    authRejected?: boolean;
    rpcUnavailable?: boolean;
    polish?: boolean;
  } = {},
) {
  const calls: unknown[] = [];
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: async () => {
      if (options.authRejected) {
        throw new ApiHttpError(401, "UNAUTHORIZED", "Invalid session.");
      }
      return {
        ownerId: options.signedOut ? null : owner,
        accountState: "active",
        isAnonymous: options.guest ?? false,
        locale: options.polish ? "pl" : "en",
        installationCredential: null,
        operationId: null,
      };
    },
  }, {
    env: (name) =>
      ({ SUPABASE_URL: base, SUPABASE_SERVICE_ROLE_KEY: "fixture-key" })[name],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      assertEquals(req.url, base + "/rest/v1/rpc/read_plant_care_profile");
      assertEquals(req.headers.get("authorization"), "Bearer fixture-key");
      calls.push(await req.json());
      if (options.rpcUnavailable) {
        return Response.json({ code: "XX000", message: "Private RPC error" }, {
          status: 500,
        });
      }
      return Response.json(options.row === undefined ? published : options.row);
    },
  });
  return {
    calls,
    get: (suffix = "") => handler(new Request(base + path + suffix)),
  };
}

Deno.test("Published Monstera v2 profile returns the exact sourced conditional rule and no calendar date", async () => {
  assert(validatePublishedPlantCare(profile));
  const f = fixture();
  const response = await f.get();
  assertEquals(response.status, 200);
  assertEquals(response.headers.get("cache-control"), "private, no-store");
  assertEquals(f.calls, [{ p_owner_id: owner, p_plant_id: plant }]);
  assertEquals(await response.json(), {
    plant_id: plant,
    status: "available",
    recommendation: {
      action_id: "check_monstera_mix_before_watering",
      action_code: "check_soil",
      text:
        "Check the potting mix. Let it dry slightly between waterings. Once it has dried a little, water thoroughly.",
      next_check_interval_days: null,
      source: {
        url: "https://hort.extension.wisc.edu/articles/monstera-deliciosa/",
        locator: "Growing Swiss-Cheese Plant, watering paragraph",
      },
    },
    next_check: null,
  });
  const pl = await (await fixture({ polish: true }).get()).json();
  assertEquals(pl.recommendation.text, profile.actions[0].action_pl);
});

Deno.test("No recommendation is substituted for missing, mismatched or unsupported profile evidence", async () => {
  for (
    const row of [
      { ...published, profile: null },
      { ...published, kb_release_id: owner },
      { ...published, plant_slug: "ficus_elastica" },
      {
        ...published,
        profile: {
          ...profile,
          provenance: {
            ...profile.provenance,
            field_evidence: {
              "/wrong": Object.values(profile.provenance.field_evidence)[0],
            },
          },
        },
      },
    ]
  ) {
    const response = await fixture({ row }).get();
    assertEquals(response.status, 200);
    assertEquals(response.headers.get("cache-control"), "private, no-store");
    assertEquals(await response.json(), {
      plant_id: plant,
      status: "unavailable",
      recommendation: null,
      next_check: null,
    });
  }
});

Deno.test("Calendar check adds published days to the factual local day and cites interval evidence", async () => {
  const ruleUrl = "https://example.test/reviewed-rule";
  const datedProfile = {
    ...profile,
    actions: [{ ...profile.actions[0], next_check_interval_days: 7 }],
    provenance: {
      ...profile.provenance,
      source_documents: [...profile.provenance.source_documents, {
        ...profile.provenance.source_documents[0],
        source_id: "fixture_interval",
        url: ruleUrl,
      }],
      field_evidence: {
        ...profile.provenance.field_evidence,
        "/actions/0/next_check_interval_days": [{
          source_id: "fixture_interval",
          locator: "Calendar interval",
          scope: "Synthetic check-only interval fixture",
        }],
      },
    },
  };
  const row = {
    ...published,
    profile: datedProfile,
    calendar_eligible: true,
    last_watered_on: "2024-02-26",
  };
  const response = await (await fixture({ row }).get()).json();
  assertEquals(response.recommendation.next_check_interval_days, 7);
  assertEquals(response.next_check, {
    due_on: "2024-03-04",
    anchor_on: "2024-02-26",
    interval_days: 7,
    basis: "Based on the last recorded watering and the published 7-day interval.",
    source: { url: ruleUrl, locator: "Calendar interval" },
  });
  const corrected = await (await fixture({
    polish: true,
    row: { ...row, last_watered_on: "2024-03-01" },
  }).get()).json();
  assertEquals(corrected.next_check.due_on, "2024-03-08");
  assert(corrected.next_check.basis.startsWith("Na podstawie"));

  // Match the before/after factual anchors from plant_next_check.test.sql.
  const repeatState = { row: { ...row, last_watered_on: "2025-10-11" } };
  const repeated = fixture(repeatState);
  const overdue = (await (await repeated.get()).json()).next_check;
  assertEquals(overdue.due_on, "2025-10-18");
  assertEquals((await (await repeated.get()).json()).next_check, overdue);
  repeatState.row.last_watered_on = "2025-10-21";
  const next = (await (await repeated.get()).json()).next_check;
  assertEquals(next, { ...overdue, anchor_on: "2025-10-21", due_on: "2025-10-28" });
  repeatState.row = { ...repeatState.row, calendar_eligible: false, last_watered_on: "2025-10-30" };
  const expired = await (await repeated.get()).json();
  assertEquals(expired.next_check, null);
  assertEquals(expired.status, "available");

  const routine = {
    rule_id: "17100000-0000-4000-8000-000000000021",
    care_revision: 2,
    due_local_date: "2026-11-23",
    anchor_local_date: "2026-11-16",
    anchor_kind: "check_soil",
  };
  for (const anchorKind of ["check_soil", "water"]) {
    for (const polish of [false, true]) {
      const projection = { ...routine, anchor_kind: anchorKind };
      const http = await fixture({
        polish,
        row: { ...row, routine_check: projection },
      }).get();
      assertEquals(http.status, 200);
      assertEquals(http.headers.get("cache-control"), "private, no-store");
      const result = await http.json();
      assertEquals(result.routine_check, projection);
      assertEquals(result.recommendation, {
        ...response.recommendation,
        text: polish ? datedProfile.actions[0].action_pl : datedProfile.actions[0].action_en,
      });
      const basis = anchorKind === "check_soil"
        ? polish
          ? "Na podstawie ostatniej zapisanej kontroli podłoża i opublikowanego odstępu (7 dni)."
          : "Based on the last recorded soil check and the published 7-day interval."
        : polish
        ? "Na podstawie ostatniego zapisanego podlewania i opublikowanego odstępu (7 dni)."
        : "Based on the last recorded watering and the published 7-day interval.";
      assertEquals(result.next_check, {
        ...response.next_check,
        due_on: projection.due_local_date,
        anchor_on: projection.anchor_local_date,
        basis,
      });
    }
  }
  for (const malformed of [
    false, 7, "invalid", [], {},
    { ...routine, rule_id: "invalid" },
    { ...routine, care_revision: "2" },
    { ...routine, care_revision: 0 },
    { ...routine, care_revision: 1.5 },
    { ...routine, care_revision: 9007199254740992 },
    { ...routine, anchor_kind: "observe" },
    { ...routine, anchor_local_date: "2026-02-30" },
    { ...routine, anchor_local_date: null },
    { ...routine, due_local_date: null },
    { ...routine, due_local_date: "2026-11-24" },
    { ...routine, due_local_date: "2026-11-23T00:00:00Z" },
    { ...routine, extra: true },
  ]) {
    const http = await fixture({ row: { ...row, routine_check: malformed } }).get();
    assertEquals(http.status, 200);
    assertEquals(http.headers.get("cache-control"), "private, no-store");
    assertEquals(await http.json(), {
      plant_id: plant, status: "unavailable", recommendation: null, next_check: null,
    });
  }
  for (const unsupported of [
    { ...row, calendar_eligible: false },
    { ...row, calendar_eligible: undefined },
    { ...row, kb_release_id: owner },
    { ...row, profile: { ...datedProfile, actions: [] } },
    { ...row, profile },
    {
      ...row,
      profile: {
        ...datedProfile,
        provenance: {
          ...datedProfile.provenance,
          field_evidence: profile.provenance.field_evidence,
        },
      },
    },
  ]) {
    const result = await (await fixture({
      row: { ...unsupported, routine_check: routine },
    }).get()).json();
    assertEquals(result, {
      plant_id: plant, status: "unavailable", recommendation: null, next_check: null,
    });
  }
  const legacy = await (await fixture({ row: { ...row, routine_check: null } }).get()).json();
  assertEquals(legacy, response);

  for (const fallback of [
    { ...row, last_watered_on: null },
    { ...row, last_watered_on: "2024-02-30" },
    { ...row, calendar_eligible: false },
    { ...row, calendar_eligible: undefined },
    {
      ...row,
      profile: {
        ...datedProfile,
        provenance: {
          ...datedProfile.provenance,
          field_evidence: profile.provenance.field_evidence,
        },
      },
    },
  ]) {
    const result = await (await fixture({ row: fallback }).get()).json();
    assertEquals(result.status, "available");
    assertEquals(result.next_check, null);
  }
});

Deno.test("Owner recommendation errors remain private, including Auth rejection and RPC failures", async () => {
  function assertPrivate(response: Response, status: number) {
    assertEquals(response.status, status);
    assertEquals(response.headers.get("cache-control"), "private, no-store");
  }
  assertPrivate(await fixture({ row: null }).get(), 404);
  const guest = fixture({ guest: true });
  assertPrivate(await guest.get(), 403);
  assertEquals(guest.calls, []);
  const signedOut = fixture({ signedOut: true });
  assertPrivate(await signedOut.get(), 401);
  assertEquals(signedOut.calls, []);
  const authRejected = fixture({ authRejected: true });
  assertPrivate(await authRejected.get(), 401);
  assertEquals(authRejected.calls, []);
  assertPrivate(await fixture({ rpcUnavailable: true }).get(), 503);
  const query = fixture();
  assertPrivate(await query.get("?owner_id=" + owner), 400);
  assertEquals(query.calls, []);
});

Deno.test("Monstera provenance hash covers the retained note and only derived-record use", async () => {
  const notes = await Deno.readTextFile(
    new URL(
      "../../../../knowledge-base/releases/staging-monstera-care-v2/README.md",
      import.meta.url,
    ),
  );
  const note = notes.match(/^> (.+)$/m)?.[1];
  assert(note);
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(note)),
  );
  const sha = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  assertEquals(profile.provenance.source_documents[0].content_hash, sha);
  assertEquals(profile.provenance.source_documents[0].allowed_for, [
    "derived_records",
  ]);
});
