import { assertEquals } from "@std/assert";
import { createProductionPlantsApiHandler } from "../../supabase/functions/plants-api/index.ts";

const { owner, plant, before, after } = await new Response(Deno.stdin.readable)
  .json();
const host = "https://v10.example.test";
let projection = before;
const handler = createProductionPlantsApiHandler({
  resolveRequestContext: async () => ({
    ownerId: owner,
    accountState: "active",
    isAnonymous: false,
    locale: "en",
    installationCredential: null,
    operationId: null,
  }),
}, {
  env: (name) =>
    ({ SUPABASE_URL: host, SUPABASE_SERVICE_ROLE_KEY: "fixture-key" })[name],
  fetch: async (input, init) => {
    const req = new Request(input, init);
    assertEquals(req.url, host + "/rest/v1/rpc/read_plant_care_profile");
    assertEquals(await req.json(), { p_owner_id: owner, p_plant_id: plant });
    return Response.json(projection);
  },
});

async function recommendation() {
  const response = await handler(
    new Request(host + "/plants/" + plant + "/care/recommendation"),
  );
  assertEquals(response.status, 200);
  assertEquals(response.headers.get("cache-control"), "private, no-store");
  return await response.json();
}

const prior = await recommendation();
assertEquals(prior.status, "available");
assertEquals(prior.next_check?.due_on, "2025-10-28");
projection = after;
const current = await recommendation();
assertEquals(current, { ...prior, next_check: null });
assertEquals(after.last_watered_on, before.last_watered_on);
