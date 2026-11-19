import { assert, assertEquals } from "@std/assert";
import profile from "../../../../knowledge-base/releases/staging-monstera-care-v2/monstera-watering.json" with { type: "json" };
import { createCareOverviewHandler } from "../../care-overview/handler.ts";

// Local fixtures only. Production Supabase clients execute both auth and RPC requests.
const base = "https://care.example.test";
const route = "/functions/v1/care-overview";
const owner = "17100000-0000-4000-8000-000000000001";
const foreign = "18100000-0000-4000-8000-000000000001";
const plant = "17100000-0000-4000-8000-000000000011";
const token = "fixture-session-token";
const privateError = "private SQL credentials hint stack fixture";
const source = {
  url: "https://hort.extension.wisc.edu/articles/monstera-deliciosa/",
  locator: "Growing Swiss-Cheese Plant, watering paragraph",
};
// Deliberately mutable JSON transport vectors, including invalid shapes.
type Json = Record<string, any>;
const cardRow = (): Json => ({
  plant_id: plant, plant_slug: "monstera_deliciosa", kb_release_id: profile.kb_release_id,
  profile: structuredClone(profile),
});
const row = (id = plant): Json => ({
  plant_id: id, care_revision: 2,
  care_profile: { ...cardRow(), plant_id: id }, first_aid_controls: [],
});
const control = (): Json => ({
  control_id: "17100000-0000-4000-8000-000000000021",
  action_entry_id: "17100000-0000-4000-8000-000000000022",
  job_id: "17100000-0000-4000-8000-000000000023",
  origin_analysis_id: "17100000-0000-4000-8000-000000000024",
  kb_release_id: "17100000-0000-4000-8000-000000000025",
  protocol_id: "17100000-0000-4000-8000-000000000026",
  context_revision: 2, action_id: "check_monstera_mix_before_watering", action_code: "check_soil",
  policy: { due_on: "2024-02-29", interval_days: 7, source },
});
const envelope = (plants = [row()]): Json => ({
  owner_id: owner, server_now: "2026-11-19T10:00:00.123456+00:00",
  owner_watermark: "2026-11-18T09:00:00.654321Z", publication_fingerprint: "a".repeat(64),
  reminder_hour_local: 9, automation_allowed: true, verified_access_until: null,
  plants, next_after: null,
});
interface FixtureOptions {
  data?: unknown;
  authBody?: unknown;
  authStatus?: number;
  rpcError?: { code: string; message: string };
  throwAuth?: boolean;
  throwRpc?: boolean;
}
function fixture(options: FixtureOptions = {}) {
  const requests: Request[] = [];
  const bodies: unknown[] = [];
  const handler = createCareOverviewHandler({
    env: (key) => ({ SUPABASE_URL: base, SUPABASE_ANON_KEY: "fixture-public-key",
      SUPABASE_SERVICE_ROLE_KEY: "fixture-service-key" } as Record<string, string>)[key],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      requests.push(req);
      if (req.url === base + "/auth/v1/user") {
        assertEquals(req.method, "GET");
        assertEquals(req.headers.get("apikey"), "fixture-public-key");
        assert(req.headers.get("authorization")?.startsWith("Bearer "));
        if (options.throwAuth) throw new Error(privateError);
        return Response.json(options.authBody ?? {
          id: owner, aud: "authenticated", role: "authenticated", is_anonymous: false,
          app_metadata: {}, user_metadata: {}, created_at: "2026-11-01T00:00:00Z",
        }, { status: options.authStatus ?? 200 });
      }
      assertEquals(req.url, base + "/rest/v1/rpc/read_owner_care_overview");
      assertEquals(req.method, "POST");
      assertEquals(req.headers.get("authorization"), "Bearer fixture-service-key");
      assertEquals(req.headers.get("apikey"), "fixture-service-key");
      bodies.push(await req.json());
      if (options.throwRpc) throw new Error(privateError);
      if (options.rpcError) return Response.json({ ...options.rpcError,
        details: privateError, hint: privateError }, { status: 400 });
      return Response.json(Object.hasOwn(options, "data") ? options.data : envelope());
    },
  });
  return {
    requests, bodies,
    request: (suffix = "", init: RequestInit = {}, path = route) => handler(new Request(base + path + suffix, {
      ...init, headers: { authorization: "Bearer " + token, ...init.headers },
    })),
  };
}
async function checked(f: ReturnType<typeof fixture>, status = 200, suffix = "", init: RequestInit = {}, path = route) {
  const response = await f.request(suffix, init, path);
  assertEquals(response.status, status);
  assertEquals(response.headers.get("cache-control"), "private, no-store");
  assertEquals(response.headers.get("access-control-allow-methods"), "GET, OPTIONS");
  if (status === 405) assertEquals(response.headers.get("allow"), "GET, OPTIONS");
  if (status === 204) { assertEquals(await response.text(), ""); return null; }
  const result = await response.json();
  if (status !== 200) {
    assertEquals(Object.keys(result), ["error"]);
    assert(!JSON.stringify(result).includes(privateError));
    assert(!JSON.stringify(result).includes("fixture-service-key"));
    assertEquals(Object.keys(result.error).sort(), ["code", "message", "retryable"]);
  }
  return result;
}
const unavailable = (id = plant) => ({
  plant_id: id, status: "unavailable", recommendation: null, next_check: null,
});
const fixedCard = {
  plant_id: plant, status: "available",
  recommendation: {
    action_id: "check_monstera_mix_before_watering", action_code: "check_soil",
    text: "Check the potting mix. Let it dry slightly between waterings. Once it has dried a little, water thoroughly.",
    next_check_interval_days: null, source,
  },
  next_check: null,
};

Deno.test("overview authenticates by real getUser then one scoped RPC and preserves fixed full card/metadata", async () => {
  for (const path of ["/", "/care-overview", "/care-overview/", route, route + "/"]) {
    const f = fixture();
    const result = await checked(f, 200, "", {}, path);
    assertEquals(f.requests.length, 2);
    assertEquals(f.requests[0].headers.get("authorization"), "Bearer " + token);
    assertEquals(f.bodies, [{ p_owner_id: owner, p_after: null, p_limit: 100 }]);
    assertEquals(result, { ...envelope(), plants: [{
      plant_id: plant, care_revision: 2, care_recommendation: fixedCard, first_aid_controls: [],
    }] });
    assert(!JSON.stringify(result).includes("provenance"));
    assert(!JSON.stringify(result).includes("care_profile"));
  }
  const pl = await checked(fixture(), 200, "", { headers: { "x-client-locale": "pl" } });
  assertEquals(pl.plants[0].care_recommendation.recommendation.text, profile.actions[0].action_pl);
});

Deno.test("overview rejects missing malformed expired and anonymous auth; token payload never supplies owner", async () => {
  for (const authorization of ["", "Basic invalid", "Bearer", "Bearer a b", "Bearer x,y"]) {
    const f = fixture();
    await checked(f, 401, "", { headers: { authorization } });
    assertEquals(f.requests.length, 0);
  }
  for (const status of [400, 401, 403]) {
    const f = fixture({ authStatus: status, authBody: { code: "bad_jwt", message: privateError } });
    await checked(f, 401);
    assertEquals(f.requests.length, 1);
    assertEquals(f.bodies.length, 0);
  }
  const anonymous = fixture({ authBody: { id: owner, is_anonymous: true } });
  await checked(anonymous, 403);
  assertEquals(anonymous.requests.length, 1);
  const forged = "eyJhbGciOiJub25lIn0." + btoa(JSON.stringify({ sub: foreign })) + ".forged";
  const f = fixture();
  await checked(f, 200, "", { headers: { authorization: "Bearer " + forged } });
  assertEquals(f.requests[0].headers.get("authorization"), "Bearer " + forged);
  assertEquals(f.bodies, [{ p_owner_id: owner, p_after: null, p_limit: 100 }]);
  // Absent anonymous metadata must still reach the atomic SQL permanent-owner guard.
  for (const authBody of [{ id: owner }, { id: owner, is_anonymous: false }]) {
    const denied = fixture({ authBody, data: envelope([]),
      rpcError: { code: "42501", message: "ACTIVE_PERMANENT_OWNER_REQUIRED" } });
    await checked(denied, 403);
    assertEquals(denied.bodies.length, 1);
  }
});

Deno.test("overview rejects query method and route boundaries before privileged calls; OPTIONS is inert", async () => {
  const queries = [
    "?owner_id=" + foreign, "?user_id=" + foreign, "?plant_id=" + plant, "?context=x", "?generation=x",
    "?after=", "?after=invalid", "?after=" + plant + "&after=" + plant,
    "?limit=1&limit=1", "?unknown=x", "?=x",
    ...["", "0", "201", "-1", "+1", "1.0", "1e2", " 1", "1 ", "01", "9007199254740993", "9".repeat(310)]
      .map((value) => "?limit=" + encodeURIComponent(value)),
  ];
  for (const query of queries) {
    const f = fixture();
    await checked(f, 400, query);
    assertEquals(f.requests.length, 0);
  }
  for (const method of ["POST", "PUT", "PATCH", "DELETE", "HEAD"]) {
    const f = fixture();
    const response = await f.request("", { method });
    assertEquals(response.status, 405);
    assertEquals(response.headers.get("allow"), "GET, OPTIONS");
    assertEquals(response.headers.get("cache-control"), "private, no-store");
    assertEquals(f.requests.length, 0);
    await response.text();
  }
  const posted = fixture();
  await checked(posted, 405, "", { method: "POST", body: JSON.stringify({ owner_id: foreign }) });
  assertEquals(posted.requests.length, 0);
  for (const path of [route + "/commands", route + "/internal-account-delete", "/unrelated", "/care-overview//", "/functions/v1/care-overviewx"]) {
    const f = fixture();
    await checked(f, 404, "", {}, path);
    assertEquals(f.requests.length, 0);
  }
  const preflight = fixture();
  await checked(preflight, 204, "", { method: "OPTIONS", headers: { authorization: "" } });
  assertEquals(preflight.requests.length, 0);
  for (const limit of [1, 200]) {
    const f = fixture({ data: envelope([]) });
    await checked(f, 200, "?limit=" + limit + "&after=" + plant);
    assertEquals(f.bodies, [{ p_owner_id: owner, p_after: plant, p_limit: limit }]);
  }
});

Deno.test("overview sanitizes auth and database failures with exact SQL error mapping", async () => {
  for (const options of [
    { throwAuth: true }, { authStatus: 500, authBody: { message: privateError } },
    { authBody: { id: "" } }, { throwRpc: true }, { data: null },
  ]) {
    const f = fixture(options);
    await checked(f, 503);
    if (options.throwAuth || options.authStatus || options.authBody) assertEquals(f.bodies.length, 0);
  }
  for (const [code, message, status] of [
    ["42501", "ACTIVE_PERMANENT_OWNER_REQUIRED", 403],
    ["22023", "INVALID_CARE_OVERVIEW_LIMIT", 400],
    ["42501", privateError, 503], ["22023", privateError, 503], ["XX000", privateError, 503],
    ["42501", "ACTIVE_PERMANENT_OWNER_REQUIRED extra", 503],
  ] as const) {
    const f = fixture({ rpcError: { code, message } });
    await checked(f, status);
    assertEquals(f.requests.length, 2);
    assertEquals(f.bodies.length, 1);
  }
});

Deno.test("overview fails the whole malformed envelope or row rather than dropping plants", async () => {
  const edits: Array<(value: Json) => void> = [
    (v) => { v.owner_id = foreign; }, (v) => { v.owner_id = ""; },
    (v) => { v.server_now = "infinity"; }, (v) => { v.owner_watermark = null; },
    (v) => { v.server_now = "2026-02-30T10:00:00Z"; },
    (v) => { v.server_now = "2026-11-19T24:00:00Z"; },
    (v) => { v.server_now = "2026-11-19T10:00:00+01:00"; },
    (v) => { v.publication_fingerprint = "A".repeat(64); },
    (v) => { v.reminder_hour_local = 24; }, (v) => { v.reminder_hour_local = -1; },
    (v) => { v.reminder_hour_local = 1.5; }, (v) => { v.automation_allowed = null; },
    (v) => { v.verified_access_until = "infinity"; },
    (v) => { v.verified_access_until = v.server_now; },
    (v) => { v.verified_access_until = "2026-11-19T10:00:00.123455Z"; },
    (v) => { v.plants[0].plant_id = "bad"; },
    (v) => { v.plants[0].care_profile.plant_id = foreign; },
    (v) => { v.plants[0].care_profile = null; },
    (v) => { v.plants[0].care_revision = 0; },
    (v) => { v.plants[0].care_revision = 1.5; },
    (v) => { v.plants.push(structuredClone(v.plants[0])); },
    (v) => { v.plants = [row(foreign), row()]; },
    (v) => { v.plants = null; },
    (v) => { v.next_after = foreign; }, (v) => { v.next_after = "invalid"; },
    (v) => { v.next_after = plant; }, // partial page must not claim continuation
    (v) => { v.plants = []; v.next_after = plant; },
  ];
  for (const edit of edits) {
    const data = envelope(); edit(data);
    await checked(fixture({ data }), 503);
  }
  await checked(fixture({ data: envelope([row(), row(foreign)]) }), 503, "?limit=1");
  await checked(fixture(), 503, "?after=" + plant);
  const microsecond = envelope();
  microsecond.verified_access_until = "2026-11-19T10:00:00.123457Z";
  assertEquals((await checked(fixture({ data: microsecond }))).verified_access_until, microsecond.verified_access_until);
  assertEquals((await checked(fixture({ data: envelope([]) }))).plants, []);
});

Deno.test("overview returns two pages totaling 205 including unavailable/no-schedule plants without a Free cap", async () => {
  const ids = Array.from({ length: 205 }, (_, index) => "17100000-0000-4000-8000-" + (index + 100).toString(16).padStart(12, "0"));
  const first = envelope(ids.slice(0, 200).map((id) => {
    const item = row(id); item.care_profile.profile = null; return item;
  }));
  first.next_after = ids[199];
  const second = envelope(ids.slice(200).map(row));
  const f = fixture({ data: first });
  const a = await checked(f, 200, "?limit=200");
  const g = fixture({ data: second });
  const b = await checked(g, 200, "?limit=200&after=" + a.next_after);
  assertEquals([...a.plants, ...b.plants].map((p: Json) => p.plant_id), ids);
  assertEquals(a.plants[0].care_recommendation, unavailable(ids[0]));
  assertEquals(b.next_after, null);
  assertEquals(g.bodies, [{ p_owner_id: owner, p_after: ids[199], p_limit: 200 }]);
});

function dated(): Json {
  const raw = cardRow();
  raw.profile.actions[0].next_check_interval_days = 7;
  raw.profile.provenance.source_documents.push({
    ...raw.profile.provenance.source_documents[0], source_id: "fixture_interval", url: "https://example.test/reviewed-rule",
  });
  raw.profile.provenance.field_evidence["/actions/0/next_check_interval_days"] = [{
    source_id: "fixture_interval", locator: "Calendar interval", scope: "Synthetic check-only interval fixture",
  }];
  raw.calendar_eligible = true;
  raw.last_watered_on = "2024-02-26";
  return raw;
}

Deno.test("overview fixed EN/PL leap-day/routine projection retains overdue days and applies only envelope clamp", async () => {
  for (const locale of ["en", "pl"]) {
    const item = row(); item.care_profile = dated();
    const data = envelope([item]);
    const result = await checked(fixture({ data }), 200, "", { headers: { "accept-language": locale } });
    const card = result.plants[0].care_recommendation;
    assertEquals(card.next_check, {
      due_on: "2024-03-04", anchor_on: "2024-02-26", interval_days: 7,
      basis: locale === "pl"
        ? "Na podstawie ostatniego zapisanego podlewania i opublikowanego odstępu (7 dni)."
        : "Based on the last recorded watering and the published 7-day interval.",
      source: { url: "https://example.test/reviewed-rule", locator: "Calendar interval" },
    });
    for (const anchor of ["water", "check_soil"]) {
      item.care_profile.routine_check = {
        rule_id: "17100000-0000-4000-8000-000000000031", care_revision: 2,
        anchor_kind: anchor, anchor_local_date: "2024-02-29", due_local_date: "2024-03-07",
      };
      const f = fixture({ data });
      const routine = (await checked(f, 200, "", { headers: { "x-client-locale": locale } })).plants[0].care_recommendation;
      assertEquals(routine.routine_check, item.care_profile.routine_check);
      assertEquals(routine.next_check.due_on, "2024-03-07");
      assertEquals(routine.next_check.anchor_on, "2024-02-29");
      assertEquals(routine.next_check.basis, anchor === "check_soil"
        ? locale === "pl" ? "Na podstawie ostatniej zapisanej kontroli podłoża i opublikowanego odstępu (7 dni)."
          : "Based on the last recorded soil check and the published 7-day interval."
        : locale === "pl" ? "Na podstawie ostatniego zapisanego podlewania i opublikowanego odstępu (7 dni)."
          : "Based on the last recorded watering and the published 7-day interval.");
    }
    item.first_aid_controls = [control()];
    data.automation_allowed = false;
    for (const deadline of [null, "2026-11-18T00:00:00Z"]) {
      data.verified_access_until = deadline;
      const clamped = (await checked(fixture({ data }), 200, "", { headers: { "x-client-locale": locale } })).plants[0];
      assertEquals(clamped.care_recommendation.next_check, null);
      assertEquals(Object.hasOwn(clamped.care_recommendation, "routine_check"), false);
      assertEquals(clamped.first_aid_controls, []);
      assertEquals(clamped.care_recommendation.recommendation, {
        ...fixedCard.recommendation, text: locale === "pl" ? profile.actions[0].action_pl : fixedCard.recommendation.text,
        next_check_interval_days: 7,
      });
    }
  }
});

Deno.test("overview source withdrawal and null profile preserve unavailable card semantics", async () => {
  for (const edit of [
    (r: Json) => { r.profile = null; },
    (r: Json) => { r.profile.provenance.field_evidence = {}; },
    (r: Json) => { r.profile.provenance.source_documents[0].url = "https://user:secret@example.test/source"; },
    (r: Json) => { r.plant_slug = "ficus_elastica"; },
  ]) {
    const item = row(); edit(item.care_profile);
    const result = await checked(fixture({ data: envelope([item]) }));
    assertEquals(result.plants[0].care_recommendation, unavailable());
  }
  const item = row(); item.care_profile = dated();
  delete item.care_profile.profile.provenance.field_evidence["/actions/0/next_check_interval_days"];
  const result = (await checked(fixture({ data: envelope([item]) }))).plants[0].care_recommendation;
  assertEquals(result.next_check, null);
  assertEquals(result.recommendation.next_check_interval_days, null);
});

Deno.test("overview validates compact firstaid controls even under disabled automation and returns only known fields", async () => {
  const item = row(); const valid = control();
  item.first_aid_controls = [{ ...valid, private_snapshot: privateError,
    policy: { ...valid.policy, private_snapshot: privateError } }];
  const result = (await checked(fixture({ data: envelope([item]) }))).plants[0];
  assertEquals(result.first_aid_controls, [valid]);
  const edits: Array<(c: Json) => void> = [
    ...["control_id", "action_entry_id", "job_id", "origin_analysis_id", "kb_release_id", "protocol_id"]
      .map((key) => (c: Json) => { c[key] = "invalid"; }),
    (c) => { c.context_revision = 1; }, (c) => { c.context_revision = 2.5; },
    (c) => { c.action_id = ""; }, (c) => { c.action_code = "water"; },
    (c) => { c.policy = null; },
    ...["2023-02-29", "2024-02-30", "2024-2-29", "0000-01-01", "infinity"]
      .map((value) => (c: Json) => { c.policy.due_on = value; }),
    ...[0, 91, 1.5, "7"].map((value) => (c: Json) => { c.policy.interval_days = value; }),
    ...["http://example.test", "https://user:secret@example.test", "invalid"]
      .map((value) => (c: Json) => { c.policy.source.url = value; }),
    (c) => { c.policy.source.locator = " "; }, (c) => { c.policy.source = null; },
  ];
  for (const edit of edits) {
    for (const enabled of [true, false]) {
      const c = control(); edit(c);
      const bad = row(); bad.first_aid_controls = [c];
      const data = envelope([bad]); data.automation_allowed = enabled;
      await checked(fixture({ data }), 503);
    }
  }
  for (const controls of [null, {}, [null], [control(), control()]]) {
    const bad = row(); bad.first_aid_controls = controls;
    await checked(fixture({ data: envelope([bad]) }), 503);
  }
  const other = row(foreign);
  other.first_aid_controls = [control()];
  await checked(fixture({ data: envelope([item, other]) }), 503);
});
