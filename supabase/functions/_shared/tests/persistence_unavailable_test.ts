// T152 safety fixtures; these do not verify deployed persistence, outbox, or UI.
import { assertEquals, assertStrictEquals } from "@std/assert";
import { createPlantsApiHandler } from "../../plants-api/index.ts";
import {
  ApiHttpError,
  CORS_HEADERS,
  errorResponse,
  type RequestContext,
} from "../http.ts";

const prefixes = ["", "/plants-api", "/functions/v1/plants-api"];
const routes = [
  { path: "/sync", method: "GET" },
  { path: "/commands", method: "POST" },
] as const;

function context(locale: RequestContext["locale"] = "en"): RequestContext {
  return {
    ownerId: "11111111-1111-4111-8111-111111111111",
    isAnonymous: false,
    accountState: "active",
    installationCredential: null,
    locale,
    operationId: null,
  };
}

function request(
  prefix: string,
  route: typeof routes[number],
  locale: RequestContext["locale"] = "en",
  body = JSON.stringify({
    operation_id: "22222222-2222-4222-8222-222222222222",
    command: "plant.create",
    payload: { name: "Monstera" },
  }),
): Request {
  return new Request(
    `https://api.example.test${prefix}${route.path}?since=2026-11-01&limit=17&page_token=fixture`,
    {
      method: route.method,
      headers: { "x-client-locale": locale, "content-type": "application/json" },
      ...(route.method === "POST" ? { body } : {}),
    },
  );
}

for (const prefix of prefixes) {
  Deno.test(`T152: ${prefix || "/"} missing persistence refuses sync and repeated commands in EN/PL`, async () => {
    for (const locale of ["en", "pl"] as const) {
      const handler = createPlantsApiHandler({
        resolveRequestContext: async () => context(locale),
      });
      for (const route of routes) {
        // Same operation_id on both attempts must never produce a receipt.
        for (let attempt = 0; attempt < 2; attempt++) {
          const req = request(prefix, route, locale);
          const response = await handler(req);
          assertEquals(response.status, 503);
          const message = route.path === "/sync"
            ? locale === "pl"
              ? "Synchronizacja jest tymczasowo niedostępna. Spróbuj ponownie później."
              : "Synchronization is temporarily unavailable. Please try again later."
            : locale === "pl"
            ? "Zapisywanie jest tymczasowo niedostępne. Spróbuj ponownie później."
            : "Saving is temporarily unavailable. Please try again later.";
          // Exact envelope also excludes fabricated success data and cursors.
          assertEquals(await response.json(), {
            error: { code: "INTERNAL_ERROR", message, retryable: true },
          });
          assertEquals(req.bodyUsed, false);
        }
      }
      for (const body of ["{", "null", "{}", ""]) {
        const req = request(prefix, routes[1], locale, body);
        const response = await handler(req);
        assertEquals(response.status, 503);
        assertEquals((await response.json()).error.code, "INTERNAL_ERROR");
        assertEquals(req.bodyUsed, false);
      }
    }
  });

  Deno.test(`T152: ${prefix || "/"} auth/account guards precede handlers and unavailable fallback`, async () => {
    for (const locale of ["en", "pl"] as const) {
      const denied: RequestContext[] = [
        { ...context(locale), ownerId: null, accountState: null },
        { ...context(locale), accountState: "deleting" },
        { ...context(locale), accountState: "deleted" },
      ];
      for (const ctx of denied) {
        for (const supplied of [false, true]) {
          let calls = 0;
          const unexpectedHandler = async () => {
            calls++;
            return new Response("unexpected");
          };
          const handler = createPlantsApiHandler({
            resolveRequestContext: async () => ctx,
            ...(supplied
              ? {
                handleSync: unexpectedHandler,
                handleCommand: unexpectedHandler,
              }
              : {}),
          });
          for (const route of routes) {
            const req = request(prefix, route, locale, "{");
            const response = await handler(req);
            assertEquals(response.status, ctx.ownerId ? 403 : 401);
            const body = await response.json();
            assertEquals(body.error.code, ctx.ownerId ? "FORBIDDEN" : "UNAUTHORIZED");
            assertEquals(body.error.retryable, false);
            assertEquals(req.bodyUsed, false);
          }
          assertEquals(calls, 0);
        }
      }
    }
  });

  Deno.test(`T152: ${prefix || "/"} explicit handlers receive original inputs and return their response`, async () => {
    for (const route of routes) {
      const ctx = context("pl");
      const req = request(prefix, route, "pl");
      const expectedBody = route.method === "POST" ? await req.clone().text() : null;
      const response = new Response("persisted fixture response", {
        status: 202,
        headers: { "x-fixture": "unchanged" },
      });
      let calls = 0;
      const delegate = async (received: Request, receivedCtx: RequestContext) => {
        calls++;
        assertStrictEquals(received, req);
        assertStrictEquals(receivedCtx, ctx);
        assertEquals(received.bodyUsed, false);
        if (expectedBody !== null) assertEquals(await received.text(), expectedBody);
        return response;
      };
      const handler = createPlantsApiHandler({
        resolveRequestContext: async () => ctx,
        handleCommand: delegate,
        handleSync: async (received, receivedCtx, url) => {
          assertEquals(url.href, req.url);
          assertEquals(url.pathname, `${prefix}/sync`);
          assertEquals(url.searchParams.get("limit"), "17");
          assertEquals(url.searchParams.get("page_token"), "fixture");
          return await delegate(received, receivedCtx);
        },
      });
      assertStrictEquals(await handler(req), response);
      assertEquals(calls, 1);
      assertEquals(response.headers.get("x-fixture"), "unchanged");
      assertEquals(await response.text(), "persisted fixture response");
    }
  });

  Deno.test(`T152: ${prefix || "/"} explicit handler errors retain existing error mapping`, async () => {
    for (const route of routes) {
      for (const locale of ["en", "pl"] as const) {
        for (const error of [
          new ApiHttpError(409, "CONFLICT", "fixture conflict", false, { revision: 7 }),
          new Error("fixture persistence failure"),
        ]) {
          const fail = async () => { throw error; };
          const handler = createPlantsApiHandler({
            resolveRequestContext: async () => context(locale),
            handleSync: fail,
            handleCommand: fail,
          });
          const response = await handler(request(prefix, route, locale));
          const expected = errorResponse(error, locale);
          assertEquals(response.status, expected.status);
          assertEquals(await response.json(), await expected.json());
        }
      }
    }
  });

  Deno.test(`T152: ${prefix || "/"} health and OPTIONS bypass persistence and auth`, async () => {
    let calls = 0;
    const unexpected = async (): Promise<never> => {
      calls++;
      throw new Error("unexpected dependency call");
    };
    const handler = createPlantsApiHandler({
      resolveRequestContext: unexpected,
      handleSync: unexpected,
      handleCommand: unexpected,
    });
    for (const locale of ["en", "pl"] as const) {
      const response = await handler(new Request(
        `https://api.example.test${prefix}/health`,
        { headers: { "x-client-locale": locale } },
      ));
      assertEquals(response.status, 200);
      assertEquals(await response.json(), { status: "ok", version: "3.0.0", locale });
      for (const [key, value] of Object.entries(CORS_HEADERS)) {
        assertEquals(response.headers.get(key), value);
      }
    }
    for (const route of routes) {
      const response = await handler(new Request(
        `https://api.example.test${prefix}${route.path}`,
        { method: "OPTIONS" },
      ));
      assertEquals(response.status, 200);
      assertEquals(await response.text(), "ok");
      for (const [key, value] of Object.entries(CORS_HEADERS)) {
        assertEquals(response.headers.get(key), value);
      }
    }
    assertEquals(calls, 0);
  });
}
