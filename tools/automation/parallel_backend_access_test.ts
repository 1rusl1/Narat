// Controller-owned B2 gate: actual production composition + Supabase client,
// mocked transport only. Never live Auth/provider/StoreKit proof.
import {
  assert,
  assertEquals,
  assertFalse,
  assertNotEquals,
} from "@std/assert";
import { createClient } from "@supabase/supabase-js";
import { createProductionPlantsApiHandler } from "../../supabase/functions/plants-api/index.ts";

const fixture = JSON.parse(
  await Deno.readTextFile(
    new URL(
      "../../specs/001-plants-ios-mvp/contracts/fixtures/monthly-access.json",
      import.meta.url,
    ),
  ),
);
const owner = fixture.cases[0].response.owner_id;
const other = "16380000-0000-4000-8000-000000000002";
const installation = "16380000-0000-4000-8000-000000009001";
const credential = "fixture-physical-installation-secret-123456";
const key = "fixture-service-key-never-client";
const url = "https://quota.example.test";
const privateFailure = "private SQL details " + key;
type Locale = "en" | "pl";
interface Options {
  body?: unknown;
  raw?: string;
  rpcStatus?: number;
  throwRpc?: boolean;
  guest?: boolean;
  active?: boolean;
  missingEnv?: boolean;
  caller?: string;
  invalidEnv?: boolean;
}
function setup(options: Options = {}) {
  const requests: Request[] = [];
  const transport: typeof fetch = async (input, init) => {
    const req = new Request(input, init);
    requests.push(req.clone());
    const path = new URL(req.url).pathname;
    if (path === "/auth/v1/user") {
      return Response.json({
        id: options.caller ?? owner,
        aud: "authenticated",
        role: "authenticated",
        app_metadata: {},
        user_metadata: {},
        is_anonymous: options.guest ?? false,
        created_at: "2026-10-31T10:20:00.123456Z",
      });
    }
    if (path === "/rest/v1/profiles") {
      return Response.json([{
        anonymous: options.guest ?? false,
        account_state: options.active === false ? "deleting" : "active",
      }]);
    }
    if (path.startsWith("/rest/v1/rpc/")) {
      if (options.throwRpc) throw new Error(privateFailure);
      return new Response(
        options.raw ??
          JSON.stringify(options.body ?? fixture.cases[0].response),
        {
          status: options.rpcStatus ?? 200,
          headers: { "content-type": "application/json" },
        },
      );
    }
    throw new Error("Unexpected transport URL " + path);
  };
  const handler = createProductionPlantsApiHandler({
    authClientFactory: (token) =>
      createClient(url, "fixture-anon", {
        auth: { persistSession: false, autoRefreshToken: false },
        global: {
          fetch: transport,
          headers: { Authorization: `Bearer ${token}` },
        },
      }),
  }, {
    env: (name) =>
      options.missingEnv
        ? undefined
        : name === "SUPABASE_URL"
        ? (options.invalidEnv ? "not-a-url" : url)
        : name === "SUPABASE_SERVICE_ROLE_KEY"
        ? key
        : undefined,
    fetch: transport,
  });
  const call = (
    path = "/analysis/access",
    locale: Locale = "en",
    init: RequestInit = {},
  ) =>
    handler(
      new Request(
        "https://api.example.test/functions/v1/plants-api" + path,
        {
          ...init,
          headers: {
            authorization: "Bearer fixture-user-session",
            "x-client-locale": locale,
            "x-installation-credential": credential,
            ...Object.fromEntries(new Headers(init.headers)),
          },
        },
      ),
    );
  return {
    handler,
    call,
    requests,
    rpcs: () =>
      requests.filter((r) =>
        new URL(r.url).pathname.startsWith("/rest/v1/rpc/")
      ),
  };
}
async function hash() {
  return Array.from(
    new Uint8Array(
      await crypto.subtle.digest(
        "SHA-256",
        new TextEncoder().encode(credential),
      ),
    ),
  )
    .map((b) => b.toString(16).padStart(2, "0")).join("");
}
for (const item of fixture.cases) {
  Deno.test("B2 production GET canonical " + item.name, async () => {
    const f = setup({ body: item.response, guest: item.response.is_guest });
    const response = await f.call();
    assertEquals(response.status, 200);
    assertEquals(await response.json(), item.response);
    assertEquals(f.rpcs().length, 1);
    const req = f.rpcs()[0];
    assertEquals(
      new URL(req.url).pathname,
      "/rest/v1/rpc/get_analysis_access_snapshot",
    );
    assertEquals(req.headers.get("authorization"), "Bearer " + key);
    assertEquals(req.headers.get("apikey"), key);
    assertEquals(await req.json(), {
      p_owner_id: owner,
      p_installation_credential_hash: await hash(),
    });
  });
}
Deno.test("B2 verified owner and DB clock cannot be query spoofed", async () => {
  const f = setup();
  const response = await f.call(
    "/analysis/access?owner_id=" + other + "&now=2030-01-01T00:00:00Z",
  );
  assertEquals(response.status, 200);
  const body = await f.rpcs()[0].json();
  assertEquals(body, {
    p_owner_id: owner,
    p_installation_credential_hash: await hash(),
  });
  assertFalse(JSON.stringify(body).includes(credential));
  assertFalse("p_now" in body);
});
Deno.test("B2 permanent account-only snapshot uses null credential", async () => {
  const f = setup();
  const response = await f.handler(
    new Request("https://api.example.test/analysis/access", {
      headers: { authorization: "Bearer session" },
    }),
  );
  assertEquals(response.status, 200);
  assertEquals(await f.rpcs()[0].json(), {
    p_owner_id: owner,
    p_installation_credential_hash: null,
  });
});
Deno.test("B2 anonymous snapshot requires installation; unverified account rejected", async () => {
  const guest = setup({ guest: true });
  const response = await guest.handler(
    new Request("https://api.example.test/analysis/access", {
      headers: { authorization: "Bearer session" },
    }),
  );
  assertEquals(response.status, 400);
  assertEquals(guest.rpcs().length, 0);
  const noAuth = setup();
  assertEquals(
    (await noAuth.handler(
      new Request("https://api.example.test/analysis/access"),
    )).status,
    401,
  );
  assertEquals(noAuth.rpcs().length, 0);
  const inactive = setup({ active: false });
  assertEquals((await inactive.call()).status, 403);
  assertEquals(inactive.rpcs().length, 0);
});
for (const locale of ["en", "pl"] as const) {
  for (
    const bad of [
      { missingEnv: true },
      { invalidEnv: true },
      { throwRpc: true },
      { raw: "{bad json" },
      { rpcStatus: 500, body: { message: privateFailure, code: "XX000" } },
      { body: null, raw: "null" },
      { body: [] },
    ]
  ) {
    Deno.test(
      "B2 safe unavailable " + locale + " " + JSON.stringify(bad),
      async () => {
        const f = setup(bad);
        const response = await f.call("/analysis/access", locale);
        assertEquals(response.status, 503);
        const body = await response.json();
        assertEquals(body.error.code, "INTERNAL_ERROR");
        assertEquals(body.error.retryable, true);
        assertFalse(JSON.stringify(body).includes(key));
        assertFalse(JSON.stringify(body).includes("private SQL"));
        assert(
          locale === "pl"
            ? /niedostępn|ponownie/i.test(body.error.message)
            : /unavailable|try again/i.test(body.error.message),
        );
      },
    );
  }
}
const corruptions: Array<[string, (x: any) => void]> = [
  ["wrongowner", (x) => x.owner_id = other],
  ["guest mismatch", (x) => x.is_guest = true],
  ["old DTO", (x) => {
    delete x.monthly;
    delete x.owner_id;
  }],
  ["Free1", (x) => x.monthly.limit = 1],
  ["fabricated ready", (x) => x.monthly.remaining = 3],
  ["missing mode", (x) => delete x.modes.diagnosis],
  ["follow_up", (x) => x.modes.follow_up = x.modes.diagnosis],
  ["stringallowed", (x) => x.modes.identification.allowed = "true"],
  ["bad date", (x) => x.monthly.period_end = "2026-02-30T10:20:00Z"],
  ["unsafe counter", (x) => x.monthly.consumed = 9007199254740992],
  ["monthly mode mismatch", (x) => x.modes.diagnosis.remaining = 2],
  ["unknown fabricated", (x) => {
    x.monthly.status = "registration_required";
    x.monthly.registered_at = null;
  }],
];
for (const [name, change] of corruptions) {
  Deno.test("B2 invalid authoritative response " + name, async () => {
    const body = structuredClone(fixture.cases[0].response);
    change(body);
    const f = setup({ body });
    const response = await f.call();
    assertEquals(response.status, 503);
    assertEquals((await response.json()).error.code, "INTERNAL_ERROR");
  });
}
Deno.test("B2 malformed supplied credential rejects before service RPC", async () => {
  const f = setup();
  const response = await f.call("/analysis/access", "en", {
    headers: { "x-installation-credential": "short" },
  });
  assertEquals(response.status, 400);
  assertEquals(f.rpcs().length, 0);
});
Deno.test("B2 owner B gets exact B response; stale A is denied", async () => {
  const body = structuredClone(fixture.cases[0].response);
  body.owner_id = other;
  const b = setup({ caller: other, body });
  assertEquals((await b.call()).status, 200);
  assertEquals((await b.rpcs()[0].json()).p_owner_id, other);
  const stale = setup({ caller: other });
  assertEquals((await stale.call()).status, 503);
});
Deno.test("B2 credential denial is safe and localized", async () => {
  for (const locale of ["en", "pl"] as const) {
    const f = setup({
      rpcStatus: 403,
      body: {
        code: "42501",
        message: "INSTALLATION_CREDENTIAL_MISMATCH",
        details: privateFailure,
      },
    });
    const response = await f.call("/analysis/access", locale);
    assertEquals(response.status, 403);
    const body = await response.json();
    assertEquals(body.error.code, "FORBIDDEN");
    assertFalse(JSON.stringify(body).includes(privateFailure));
  }
});
if (Deno.args.includes("--installations")) {
  function registration(overrides: Record<string, unknown> = {}) {
    return {
      installation_id: installation,
      owner_id: owner,
      starter_identification_consumed: false,
      starter_diagnosis_consumed: true,
      starter_identification_job_id: null,
      starter_diagnosis_job_id: null,
      first_starter_success_at: "2026-11-01T10:20:00.123456+00:00",
      ...overrides,
    };
  }
  for (const guest of [true, false]) {
    Deno.test("B2 production register owner guest=" + guest, async () => {
      const f = setup({ guest, body: registration() });
      const response = await f.call("/installations/register", "en", {
        method: "POST",
        body: JSON.stringify({ owner_id: other }),
      });
      assertEquals(response.status, 200);
      const body = await response.json();
      assertEquals(body.installation_id, installation);
      assertEquals(body.starter.identification_remaining, 1);
      assertEquals(body.starter.diagnosis_remaining, 0);
      assertEquals(
        body.starter.first_starter_success_at,
        "2026-11-01T10:20:00.123456+00:00",
      );
      assertEquals(f.rpcs().length, 1);
      assertEquals(
        new URL(f.rpcs()[0].url).pathname,
        "/rest/v1/rpc/register_installation_access",
      );
      assertEquals(await f.rpcs()[0].json(), {
        p_owner_id: owner,
        p_credential_hash: await hash(),
      });
    });
  }
  Deno.test("B2 bind uses atomic UUID credential RPC", async () => {
    const f = setup({ body: registration() });
    const response = await f.call("/installations/bind", "pl", {
      method: "POST",
      body: JSON.stringify({ installation_id: installation, owner_id: other }),
    });
    assertEquals(response.status, 200);
    const body = await response.json();
    assertEquals(body.owner_id, owner);
    assertEquals(body.bound, true);
    assertEquals(f.rpcs().length, 1);
    assertEquals(
      new URL(f.rpcs()[0].url).pathname,
      "/rest/v1/rpc/bind_installation_credential",
    );
    assertEquals(await f.rpcs()[0].json(), {
      p_installation_id: installation,
      p_owner_id: owner,
      p_credential_hash: await hash(),
    });
  });
  Deno.test("B2 bind body UUID alone is insufficient; guest forbidden", async () => {
    const f = setup({ body: registration() });
    const response = await f.handler(
      new Request("https://api.example.test/installations/bind", {
        method: "POST",
        headers: { authorization: "Bearer session" },
        body: JSON.stringify({ installation_id: installation }),
      }),
    );
    assertEquals(response.status, 400);
    assertEquals(f.rpcs().length, 0);
    const g = setup({ guest: true, body: registration() });
    assertEquals(
      (await g.call("/installations/bind", "en", {
        method: "POST",
        body: JSON.stringify({ installation_id: installation }),
      })).status,
      403,
    );
    assertEquals(g.rpcs().length, 0);
  });
  for (
    const field of [
      "starter_identification_consumed",
      "starter_diagnosis_consumed",
      "owner_id",
      "installation_id",
    ]
  ) {
    Deno.test("B2 malformed registration data " + field, async () => {
      const body = registration();
      delete (body as any)[field];
      const f = setup({ body });
      const response = await f.call("/installations/register", "en", {
        method: "POST",
      });
      assertEquals(response.status, 503);
    });
  }
  Deno.test("B2 bind rejects wrong returned installation or owner", async () => {
    for (const override of [{ installation_id: other }, { owner_id: other }]) {
      const f = setup({ body: registration(override) });
      const response = await f.call("/installations/bind", "en", {
        method: "POST",
        body: JSON.stringify({ installation_id: installation }),
      });
      assertEquals(response.status, 503);
    }
  });
  for (const locale of ["en", "pl"] as const) {
    Deno.test("B2 unavailable job pipeline safe503 " + locale, async () => {
      const f = setup();
      for (
        const [path, method] of [["/analysis/jobs", "POST"], [
          "/analysis/jobs/" + installation,
          "GET",
        ]]
      ) {
        const response = await f.call(path, locale, { method });
        assertEquals(response.status, 503);
        const body = await response.json();
        assertEquals(body.error.code, "PROVIDER_UNAVAILABLE");
        assertNotEquals(response.status, 202);
        assertFalse(JSON.stringify(body).includes("job_id"));
      }
      assertEquals(f.rpcs().length, 0);
    });
  }
}
