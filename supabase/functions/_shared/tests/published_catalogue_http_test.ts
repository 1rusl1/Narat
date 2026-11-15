import { assertEquals } from "@std/assert";
import { createProductionPlantsApiHandler } from "../../plants-api/index.ts";

const base = "https://catalogue.example.test";
const prefix = "/functions/v1/plants-api/catalogue";
const taxon = "17100000-0000-4000-8000-000000000031";
const card = {
  taxon_id: taxon,
  plant_id: "monstera_deliciosa",
  scientific_name: "Monstera deliciosa",
  display_name: "Swiss cheese plant",
  care_profile_available: true,
  hero_image: {
    author: "Fixture photographer",
    license: "CC BY-SA 3.0",
    source_page: "https://example.test/fixture",
  },
};

function fixture(
  options: { detail?: unknown; rpcFailure?: boolean; malformed?: boolean } = {},
) {
  const calls: { name: string; body: Record<string, unknown> }[] = [];
  let authCalls = 0;
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: async () => {
      authCalls++;
      throw new Error("Public catalogue should not resolve Auth");
    },
  }, {
    env: (name) =>
      ({
        SUPABASE_URL: base,
        SUPABASE_ANON_KEY: "fixture-anon-key",
        SUPABASE_SERVICE_ROLE_KEY: "fixture-service-key",
      })[name],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      const name = new URL(req.url).pathname.split("/").at(-1)!;
      assertEquals(req.headers.get("authorization"), "Bearer fixture-anon-key");
      assertEquals(req.headers.get("apikey"), "fixture-anon-key");
      const body = await req.json();
      calls.push({ name, body });
      if (options.rpcFailure) {
        return Response.json({
          code: "XX000",
          message: "Private SQL diagnostic",
        }, { status: 500 });
      }
      if (name === "get_catalogue_species_card") {
        return Response.json(
          options.detail === undefined ? card : options.detail,
        );
      }
      assertEquals(name, "search_catalogue_species");
      const empty = body.p_query === "no match";
      return Response.json({
        release_version: "fixture-catalogue",
        kb_release_id: null,
        locale: body.p_locale,
        total: empty ? 0 : Number(body.p_offset) + 1,
        limit: body.p_limit,
        offset: body.p_offset,
        items: empty ? [] : options.malformed ? [{}] : [card],
      });
    },
  });
  return {
    calls,
    authCalls: () => authCalls,
    get: (suffix = "", headers?: HeadersInit) =>
      handler(new Request(base + prefix + suffix, { headers })),
  };
}

Deno.test("Published catalogue search works before sign-in and preserves the SQL result and attribution", async () => {
  const f = fixture();
  const response = await f.get("?q=Swiss+cheese&limit=10&offset=1", {
    authorization: "Bearer unused-user-token",
  });
  assertEquals(response.status, 200);
  assertEquals(
    response.headers.get("Vary"),
    "X-Client-Locale, Accept-Language",
  );
  assertEquals(f.authCalls(), 0);
  assertEquals(f.calls, [{
    name: "search_catalogue_species",
    body: { p_query: "Swiss cheese", p_locale: "en", p_limit: 10, p_offset: 1 },
  }]);
  assertEquals(await response.json(), {
    release_version: "fixture-catalogue",
    kb_release_id: null,
    locale: "en",
    total: 2,
    limit: 10,
    offset: 1,
    items: [card],
  });
  const empty = await f.get("?q=no+match", { "x-client-locale": "pl" });
  assertEquals(empty.status, 200);
  assertEquals((await empty.json()).items, []);
  assertEquals(f.calls[1].body, {
    p_query: "no match",
    p_locale: "pl",
    p_limit: 50,
    p_offset: 0,
  });
});

Deno.test("Published catalogue returns the same card by species slug and taxon UUID", async () => {
  const f = fixture();
  for (const identifier of [card.plant_id, taxon]) {
    const response = await f.get("/" + identifier);
    assertEquals(response.status, 200);
    assertEquals(await response.json(), card);
  }
  assertEquals(
    f.calls,
    [card.plant_id, taxon].map((identifier) => ({
      name: "get_catalogue_species_card",
      body: { p_identifier: identifier, p_locale: "en" },
    })),
  );
  assertEquals(
    (await fixture({ detail: null }).get("/not_published")).status,
    404,
  );
});

Deno.test("Published catalogue validates inputs and sanitizes RPC failures", async () => {
  const f = fixture();
  for (
    const suffix of [
      "?limit=0",
      "?limit=201",
      "?offset=-1",
      "?q=a&q=b",
      "?owner_id=x",
      "/%",
      "/monstera?q=x",
    ]
  ) {
    assertEquals((await f.get(suffix)).status, 400);
  }
  assertEquals(f.calls, []);
  const failure = await fixture({ rpcFailure: true }).get();
  assertEquals(failure.status, 503);
  assertEquals(
    (await failure.json()).error.message,
    "The catalogue is temporarily unavailable.",
  );
  assertEquals((await fixture({ malformed: true }).get()).status, 503);
});
