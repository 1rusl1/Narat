import { assert, assertEquals } from "@std/assert";
import profile from "../../../../knowledge-base/releases/staging-monstera-care-v2/monstera-watering.json" with {
  type: "json",
};
import { createProductionPlantsApiHandler } from "../../plants-api/index.ts";
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
    polish?: boolean;
  } = {},
) {
  const calls: unknown[] = [];
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: async () => ({
      ownerId: options.signedOut ? null : owner,
      accountState: "active",
      isAnonymous: options.guest ?? false,
      locale: options.polish ? "pl" : "en",
      installationCredential: null,
      operationId: null,
    }),
  }, {
    env: (name) =>
      ({ SUPABASE_URL: base, SUPABASE_SERVICE_ROLE_KEY: "fixture-key" })[name],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      assertEquals(req.url, base + "/rest/v1/rpc/read_plant_care_profile");
      assertEquals(req.headers.get("authorization"), "Bearer fixture-key");
      calls.push(await req.json());
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
          actions: [{ ...profile.actions[0], next_check_interval_days: 7 }],
        },
      },
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
    assertEquals(await response.json(), {
      plant_id: plant,
      status: "unavailable",
      recommendation: null,
    });
  }
});

Deno.test("Owner recommendation hides foreign and deleted plants and rejects unsupported access", async () => {
  assertEquals((await fixture({ row: null }).get()).status, 404);
  const guest = fixture({ guest: true });
  assertEquals((await guest.get()).status, 403);
  assertEquals(guest.calls, []);
  const signedOut = fixture({ signedOut: true });
  assertEquals((await signedOut.get()).status, 401);
  assertEquals(signedOut.calls, []);
  const query = fixture();
  assertEquals((await query.get("?owner_id=" + owner)).status, 400);
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
