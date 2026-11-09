// T019 auth/profile fixtures: real Supabase client, mocked HTTP transport only.
// These tests do not establish live auth, command persistence, or client save readiness.
import { assertEquals, assertStrictEquals } from "@std/assert";
import { createClient } from "@supabase/supabase-js";
import {
  type AuthClientFactory,
  createPlantsApiHandler,
} from "../../plants-api/index.ts";
import { type RequestContext } from "../http.ts";

const ownerId = "11111111-1111-4111-8111-111111111111";
const forgedOwnerId = "22222222-2222-4222-8222-222222222222";
const operationId = "33333333-3333-4333-8333-333333333333";
const token = "fixture-session-token";
const rawFailure = "private SQL profiles / network secret fixture";
const prefixes = ["", "/plants-api", "/functions/v1/plants-api"];
const routes = [
  { path: "/commands", method: "POST" },
  { path: "/sync", method: "GET" },
] as const;
type Locale = RequestContext["locale"];

interface AuthFixture {
  authStatus?: number;
  authBody?: unknown;
  authAnonymous?: boolean;
  profileBody?: unknown;
  profileStatus?: number;
  throwProfile?: boolean;
}

function transportFixture(options: AuthFixture = {}) {
  const requests: Request[] = [];
  let clients = 0;
  const factory: AuthClientFactory = (bearer) => {
    clients++;
    return createClient("https://auth.example.test", "fixture-public-key", {
      global: {
        headers: { Authorization: "Bearer " + bearer },
        fetch: (input, init) => {
          const req = new Request(input, init);
          requests.push(req);
          const url = new URL(req.url);
          let body: unknown;
          let status = 200;
          if (url.pathname === "/auth/v1/user") {
            status = options.authStatus ?? 200;
            body = options.authBody ?? (status === 200
              ? {
                id: ownerId,
                aud: "authenticated",
                role: "authenticated",
                is_anonymous: options.authAnonymous ?? false,
                app_metadata: {},
                user_metadata: {},
                created_at: "2026-11-01T00:00:00Z",
              }
              : { code: "bad_jwt", message: rawFailure });
          } else if (url.pathname === "/rest/v1/profiles") {
            if (options.throwProfile) throw new Error(rawFailure);
            status = options.profileStatus ?? 200;
            body = Object.hasOwn(options, "profileBody")
              ? options.profileBody
              : [{ account_state: "active", anonymous: false }];
          } else {
            throw new Error("Unexpected mocked transport URL: " + req.url);
          }
          return Promise.resolve(new Response(JSON.stringify(body), {
            status,
            headers: { "content-type": "application/json" },
          }));
        },
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
      },
    });
  };
  return { factory, requests, get clients() { return clients; } };
}

function request(
  prefix: string,
  route: typeof routes[number],
  locale: Locale,
  authorization: string | null = "Bearer " + token,
): Request {
  const headers = new Headers({
    "content-type": "application/json",
    "x-client-locale": locale,
    "x-installation-credential": "fixture-installation",
    "x-operation-id": operationId,
  });
  if (authorization !== null) headers.set("authorization", authorization);
  return new Request(
    "https://api.example.test" + prefix + route.path +
      "?owner_id=" + forgedOwnerId,
    {
      method: route.method,
      headers,
      ...(route.method === "POST"
        ? {
          body: JSON.stringify({
            owner_id: forgedOwnerId,
            user_id: forgedOwnerId,
            payload: { owner_id: forgedOwnerId },
          }),
        }
        : {}),
    },
  );
}

function assertTransport(
  fixture: ReturnType<typeof transportFixture>,
  profileRequested: boolean,
  bearer = token,
) {
  assertEquals(fixture.clients, 1);
  assertEquals(
    fixture.requests.map((req) => new URL(req.url).pathname),
    profileRequested
      ? ["/auth/v1/user", "/rest/v1/profiles"]
      : ["/auth/v1/user"],
  );
  for (const req of fixture.requests) {
    assertEquals(req.method, "GET");
    assertEquals(new URL(req.url).origin, "https://auth.example.test");
    assertEquals(req.headers.get("authorization"), "Bearer " + bearer);
    assertEquals(req.headers.get("apikey"), "fixture-public-key");
  }
  if (profileRequested) {
    const url = new URL(fixture.requests[1].url);
    assertEquals(url.searchParams.get("id"), "eq." + ownerId);
    assertEquals(url.searchParams.get("select"), "account_state,anonymous");
  }
}

const deniedProfiles: {
  name: string;
  fixture: AuthFixture;
  status: 403 | 503;
}[] = [
  { name: "missing profile", fixture: { profileBody: [] }, status: 403 },
  { name: "null profile", fixture: { profileBody: null }, status: 403 },
  { name: "malformed profile", fixture: { profileBody: ["invalid"] }, status: 403 },
  { name: "missing state", fixture: { profileBody: [{ anonymous: false }] }, status: 403 },
  { name: "null state", fixture: { profileBody: [{ account_state: null, anonymous: false }] }, status: 403 },
  { name: "unknown state", fixture: { profileBody: [{ account_state: "unknown", anonymous: false }] }, status: 403 },
  { name: "invalid state type", fixture: { profileBody: [{ account_state: true, anonymous: false }] }, status: 403 },
  { name: "deleting", fixture: { profileBody: [{ account_state: "deleting", anonymous: false }] }, status: 403 },
  { name: "deleted", fixture: { profileBody: [{ account_state: "deleted", anonymous: false }] }, status: 403 },
  { name: "missing anonymous flag", fixture: { profileBody: [{ account_state: "active" }] }, status: 403 },
  { name: "invalid anonymous flag", fixture: { profileBody: [{ account_state: "active", anonymous: "false" }] }, status: 403 },
  {
    name: "profile SQL error",
    fixture: {
      profileStatus: 500,
      profileBody: { code: "XX000", message: rawFailure, details: rawFailure, hint: rawFailure },
    },
    status: 503,
  },
  {
    name: "profile permission error",
    fixture: {
      profileStatus: 403,
      profileBody: { code: "42501", message: rawFailure },
    },
    status: 503,
  },
  { name: "profile network error", fixture: { throwProfile: true }, status: 503 },
  {
    name: "multiple profiles",
    fixture: { profileBody: [
      { account_state: "active", anonymous: false },
      { account_state: "active", anonymous: false },
    ] },
    status: 503,
  },
];

for (const prefix of prefixes) {
  for (const denied of deniedProfiles) {
    Deno.test("T019 default auth: " + prefix + " " + denied.name + " blocks commands/sync in EN/PL", async () => {
      for (const locale of ["en", "pl"] as const) {
        for (const route of routes) {
          const fixture = transportFixture(denied.fixture);
          let calls = 0;
          const unexpected = async () => {
            calls++;
            return new Response("unexpected");
          };
          const handler = createPlantsApiHandler({
            authClientFactory: fixture.factory,
            handleCommand: unexpected,
            handleSync: unexpected,
          });
          const req = request(prefix, route, locale);
          const response = await handler(req);
          assertEquals(response.status, denied.status);
          assertEquals(await response.json(), {
            error: {
              code: denied.status === 503 ? "INTERNAL_ERROR" : "FORBIDDEN",
              message: denied.status === 503
                ? locale === "pl"
                  ? "Weryfikacja konta jest tymczasowo niedostępna. Spróbuj ponownie później."
                  : "Account verification is temporarily unavailable. Please try again later."
                : locale === "pl"
                ? "Konto jest w trakcie usuwania lub niedostępne."
                : "Account is deleting or unavailable.",
              retryable: denied.status === 503,
            },
          });
          assertEquals(calls, 0);
          assertEquals(req.bodyUsed, false);
          assertTransport(fixture, true);
        }
      }
    });
  }

  Deno.test("T019 default auth: " + prefix + " missing/malformed/invalid bearer cannot reach handlers or profile", async () => {
    const cases: {
      authorization: string | null;
      reachesAuth: boolean;
      authStatus?: number;
      authBody?: unknown;
    }[] = [
      { authorization: null, reachesAuth: false },
      { authorization: "Basic fixture", reachesAuth: false },
      { authorization: "Bearer", reachesAuth: false },
      { authorization: "Bearer   ", reachesAuth: false },
      { authorization: "Bearer invalid token", reachesAuth: false },
      { authorization: "Bearer expired-token", reachesAuth: true },
      { authorization: "Bearer invalid-user", reachesAuth: true, authStatus: 200, authBody: {} },
    ];
    for (const locale of ["en", "pl"] as const) {
      for (const route of routes) {
        for (const denied of cases) {
          const fixture = transportFixture({
            authStatus: denied.authStatus ?? 401,
            authBody: denied.authBody,
          });
          let calls = 0;
          const unexpected = async () => {
            calls++;
            return new Response("unexpected");
          };
          const handler = createPlantsApiHandler({
            authClientFactory: fixture.factory,
            handleCommand: unexpected,
            handleSync: unexpected,
          });
          const req = request(prefix, route, locale, denied.authorization);
          const response = await handler(req);
          assertEquals(response.status, 401);
          assertEquals(await response.json(), {
            error: {
              code: "UNAUTHORIZED",
              message: denied.reachesAuth
                ? locale === "pl"
                  ? "Nieprawidłowy lub wygasły token sesji."
                  : "Invalid or expired session token."
                : locale === "pl"
                ? "Wymagane jest zalogowanie do konta."
                : "Authentication is required.",
              retryable: false,
            },
          });
          assertEquals(calls, 0);
          assertEquals(req.bodyUsed, false);
          if (denied.reachesAuth) {
            assertTransport(fixture, false, denied.authorization!.slice("Bearer ".length));
          } else {
            assertEquals(fixture.clients, 0);
            assertEquals(fixture.requests, []);
          }
        }
      }
    }
  });

  Deno.test("T019 default auth: " + prefix + " active real profiles supply authoritative identity and boolean anonymous flag", async () => {
    for (const locale of ["en", "pl"] as const) {
      for (const [authAnonymous, anonymous] of [
        [false, false], [true, true], [false, true], [true, false],
      ] as const) {
        for (const route of routes) {
          const fixture = transportFixture({
            authAnonymous,
            profileBody: [{ account_state: "active", anonymous }],
          });
          const req = request(prefix, route, locale);
          const expected = new Response("fixture handler", { status: 202 });
          let calls = 0;
          const delegate = async (received: Request, ctx: RequestContext) => {
            calls++;
            assertStrictEquals(received, req);
            assertEquals(received.bodyUsed, false);
            assertEquals(ctx, {
              ownerId,
              isAnonymous: anonymous,
              accountState: "active",
              installationCredential: "fixture-installation",
              locale,
              operationId,
            });
            return expected;
          };
          const handler = createPlantsApiHandler({
            authClientFactory: fixture.factory,
            handleCommand: delegate,
            handleSync: async (received, ctx, url) => {
              assertEquals(url.href, req.url);
              return await delegate(received, ctx);
            },
          });
          assertStrictEquals(await handler(req), expected);
          assertEquals(await expected.text(), "fixture handler");
          assertEquals(calls, 1);
          assertTransport(fixture, true);
        }
      }
    }
  });

  Deno.test("T019 default auth: " + prefix + " active profile preserves T152 unavailable fallback", async () => {
    for (const locale of ["en", "pl"] as const) {
      for (const route of routes) {
        const fixture = transportFixture();
        const handler = createPlantsApiHandler({ authClientFactory: fixture.factory });
        const req = request(prefix, route, locale);
        const response = await handler(req);
        assertEquals(response.status, 503);
        assertEquals(await response.json(), {
          error: {
            code: "INTERNAL_ERROR",
            message: route.path === "/sync"
              ? locale === "pl"
                ? "Synchronizacja jest tymczasowo niedostępna. Spróbuj ponownie później."
                : "Synchronization is temporarily unavailable. Please try again later."
              : locale === "pl"
              ? "Zapisywanie jest tymczasowo niedostępne. Spróbuj ponownie później."
              : "Saving is temporarily unavailable. Please try again later.",
            retryable: true,
          },
        });
        assertEquals(req.bodyUsed, false);
        assertTransport(fixture, true);
      }
    }
  });

  Deno.test("T019 default auth: " + prefix + " health/OPTIONS never create a client or use the network", async () => {
    const fixture = transportFixture({ authStatus: 401 });
    let calls = 0;
    const unexpected = async () => {
      calls++;
      return new Response("unexpected");
    };
    const handler = createPlantsApiHandler({
      authClientFactory: fixture.factory,
      handleCommand: unexpected,
      handleSync: unexpected,
    });
    for (const locale of ["en", "pl"] as const) {
      const response = await handler(new Request("https://api.example.test" + prefix + "/health", {
        headers: { authorization: "Bearer expired-token", "x-client-locale": locale },
      }));
      assertEquals(response.status, 200);
      assertEquals(await response.json(), { status: "ok", version: "3.0.0", locale });
      for (const route of routes) {
        const response = await handler(new Request("https://api.example.test" + prefix + route.path, {
          method: "OPTIONS",
          headers: { authorization: "Bearer expired-token", "x-client-locale": locale },
        }));
        assertEquals(response.status, 200);
        assertEquals(await response.text(), "ok");
      }
    }
    assertEquals(calls, 0);
    assertEquals(fixture.clients, 0);
    assertEquals(fixture.requests, []);
  });
}
