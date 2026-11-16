import { assert, assertEquals } from "@std/assert";
import { createProductionPlantsApiHandler } from "../../plants-api/index.ts";
import { hashInstallationCredential } from "../AnalysisAccess.ts";

const guest = "b5350000-0000-4000-8000-000000000001";
const owner = "b5350000-0000-4000-8000-000000000002";
const other = "b5350000-0000-4000-8000-000000000003";
const photo = "b5350000-0000-4000-8000-000000000004";
const draft = "b5350000-0000-4000-8000-000000000005";
const claim = "b5350000-0000-4000-8000-000000000006";
const plant = "b5350000-0000-4000-8000-000000000007";
const installation = "b5350000-0000-4000-8000-000000000008";
const job = "b5350000-0000-4000-8000-000000000009";
const taxon = "b5350000-0000-4000-8000-000000000010";
const credential = "fixture-guest-photo-installation";
const serviceKey = "fixture-service-key";
const host = "https://guest-photo.example.test";
const mime = "image/jpeg";
const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
const hash = Array.from(
  new Uint8Array(await crypto.subtle.digest("SHA-256", jpeg)),
  (n) => n.toString(16).padStart(2, "0"),
).join("");

Deno.test("Production guest route transfers verified private bytes once and replays the receipt", async () => {
  const original = `${guest}/${photo}`;
  const destination = `${owner}/${photo}`;
  const installationHash = await hashInstallationCredential(credential);
  const receipt = { plant_id: plant, photo_id: photo };
  const credentials = {
    installation_id: installation,
    owner_id: owner,
    starter_identification_consumed: true,
    starter_diagnosis_consumed: false,
    starter_identification_job_id: null,
    starter_diagnosis_job_id: null,
    first_starter_success_at: "2026-11-12T08:00:00Z",
  };
  const upload = (scope: string) => ({
    photo_asset_id: photo,
    owner_id: scope,
    storage_path: `${scope}/${photo}`,
    mime_type: mime,
    byte_size: jpeg.length,
    content_sha256: hash,
    expires_in_seconds: 0,
    state: "ready",
  });
  let published = false;
  let copied = false;
  let expired = false;
  let verifiedPublishes = 0;
  const uploads: string[] = [];
  const downloads: string[] = [];
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: (req) => {
      const identity = req.headers.get("authorization")?.slice(7) ?? null;
      return Promise.resolve({
        ownerId: identity,
        accountState: identity ? "active" : null,
        isAnonymous: identity === guest,
        locale: "en",
        installationCredential: req.headers.get("x-installation-credential"),
        operationId: null,
      });
    },
  }, {
    env: (name) =>
      ({
        SUPABASE_URL: host,
        SUPABASE_SERVICE_ROLE_KEY: serviceKey,
      })[name],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      assertEquals(req.headers.get("authorization"), `Bearer ${serviceKey}`);
      const path = new URL(req.url).pathname;
      if (path.startsWith("/storage/v1/object/")) {
        const key = path.slice("/storage/v1/object/analysis-inputs/".length);
        if (req.method === "GET") {
          downloads.push(key);
          assert(key === original || (copied && key === destination));
          return new Response(jpeg, { headers: { "content-type": mime } });
        }
        assertEquals(req.method, "POST");
        assertEquals(key, destination);
        assertEquals(req.headers.get("x-upsert"), "false");
        assertEquals(new Uint8Array(await req.arrayBuffer()), jpeg);
        copied = true;
        uploads.push(key);
        return Response.json({ Key: `analysis-inputs/${destination}` });
      }
      const data = await req.json();
      switch (path.split("/").at(-1)) {
        case "register_installation_access":
          assertEquals(data.p_owner_id, guest);
          assertEquals(data.p_credential_hash, installationHash);
          return Response.json(credentials);
        case "bind_installation_credential":
          assertEquals(data.p_owner_id, owner);
          assertEquals(data.p_installation_id, installation);
          assertEquals(data.p_credential_hash, installationHash);
          return Response.json(credentials);
        case "create_guest_photo_draft":
          assertEquals(data.p_owner_id, guest);
          assertEquals(data.p_job_id, job);
          assertEquals(data.p_taxon_id, taxon);
          return Response.json({
            draft_id: draft,
            expires_at: "2026-11-19T08:00:00Z",
          });
        case "prepare_guest_photo_claim":
          assertEquals(data.p_draft_id, draft);
          if (expired) {
            return Response.json({ code: "P0002", message: "DRAFT_EXPIRED" }, {
              status: 400,
            });
          }
          assertEquals(data.p_owner_id, owner);
          assertEquals(data.p_credential_hash, installationHash);
          return Response.json({
            claim_id: claim,
            draft_id: draft,
            proof_expires_at: "2026-11-12T08:15:00Z",
          });
        case "process_guest_photo_claim":
          assertEquals(data.p_owner_id, owner);
          assertEquals(data.p_claim_id, claim);
          assertEquals(data.p_credential_hash, installationHash);
          if (published) {
            return Response.json({ receipt, cleanup_draft_id: draft });
          }
          if (data.p_verified_copy) {
            assert(copied);
            assertEquals(downloads, [original, destination]);
            published = true;
            verifiedPublishes++;
            return Response.json({ receipt, cleanup_draft_id: draft });
          }
          return Response.json({ upload: upload(guest), destination });
        case "read_owned_plant_photo":
          return Response.json(
            data.p_owner_id === owner && published ? upload(owner) : null,
          );
        case "read_guest_photo_cleanup":
          return Response.json([]);
        default:
          throw new Error("Unexpected fixture RPC.");
      }
    },
  });

  const request = (
    path: string,
    identity: string,
    body?: Record<string, unknown>,
  ) =>
    handler(
      new Request(host + path, {
        method: body ? "POST" : "GET",
        headers: {
          authorization: `Bearer ${identity}`,
          "x-installation-credential": credential,
        },
        body: body ? JSON.stringify(body) : undefined,
      }),
    );

  const registered = await request("/installations/register", guest, {});
  assertEquals((await registered.json()).installation_id, installation);
  const made = await request("/drafts", guest, {
    operation_id: crypto.randomUUID(),
    identification_job_id: job,
    taxon_id: taxon,
  });
  assertEquals((await made.json()).draft_id, draft);
  const bound = await request("/installations/bind", owner, {
    installation_id: installation,
  });
  assertEquals((await bound.json()).bound, true);
  const prepare = { operation_id: crypto.randomUUID(), draft_id: draft };
  assertEquals(
    (await (await request("/claims/prepare", owner, prepare)).json()).claim_id,
    claim,
  );
  const commit = { operation_id: crypto.randomUUID(), claim_id: claim };
  assertEquals(
    (await request("/claims/commit", owner, {
      ...commit,
      copied_storage_path: original,
    })).status,
    400,
  );
  const result = await request("/claims/commit", owner, commit);
  assertEquals(await result.json(), receipt);
  assertEquals(result.headers.get("cache-control"), "private, no-store");
  assertEquals(
    await (await request("/claims/commit", owner, commit)).json(),
    receipt,
  );
  assertEquals(verifiedPublishes, 1);
  assertEquals(uploads, [destination]);
  assertEquals(
    new Uint8Array(
      await (await request(`/plants/${plant}/photo`, owner)).arrayBuffer(),
    ),
    jpeg,
  );
  assertEquals((await request(`/plants/${plant}/photo`, other)).status, 404);
  expired = true;
  const denied = await request("/claims/prepare", owner, prepare);
  assertEquals(denied.status, 410);
  assertEquals((await denied.json()).error.code, "DRAFT_EXPIRED");
});

Deno.test("Draft route accepts only exact identification or diagnosis bodies through one private RPC", async () => {
  const operation = crypto.randomUUID();
  const installationHash = await hashInstallationCredential(credential);
  const receipt = { draft_id: draft, expires_at: "2026-11-19T08:00:00Z" };
  const identification = {
    operation_id: operation,
    identification_job_id: job,
    taxon_id: taxon,
  };
  const diagnosis = { operation_id: operation, diagnosis_job_id: job };
  let expectedRpc = "create_bound_guest_diagnosis_draft";
  let expectedOwner = guest;
  let failure: { code: string; message: string } | null = null;
  const calls: string[] = [];
  const handler = createProductionPlantsApiHandler({
    resolveRequestContext: (req) => {
      const identity = req.headers.get("authorization")?.slice(7) ?? null;
      return Promise.resolve({
        ownerId: identity,
        accountState: identity ? "active" : null,
        isAnonymous: identity === guest || identity === other,
        locale: "en",
        installationCredential: req.headers.get("x-installation-credential"),
        operationId: null,
      });
    },
  }, {
    env: (name) =>
      ({ SUPABASE_URL: host, SUPABASE_SERVICE_ROLE_KEY: serviceKey })[name],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      // Count every outbound request: provider, Storage or extra lookups fail.
      calls.push(req.url);
      assertEquals(req.url, host + "/rest/v1/rpc/" + expectedRpc);
      assertEquals(req.method, "POST");
      assertEquals(req.headers.get("authorization"), "Bearer " + serviceKey);
      assertEquals(await req.json(), {
        p_owner_id: expectedOwner,
        p_credential_hash: installationHash,
        p_operation_id: operation,
        p_job_id: job,
        ...(expectedRpc === "create_guest_photo_draft"
          ? { p_taxon_id: taxon }
          : {}),
      });
      return failure
        ? Response.json(failure, { status: 400 })
        : Response.json(receipt);
    },
  });
  const request = (
    value: unknown,
    identity: string | null = guest,
    installationCredential: string | null = credential,
  ) => {
    const headers = new Headers({ "content-type": "application/json" });
    if (identity !== null) headers.set("authorization", "Bearer " + identity);
    if (installationCredential !== null) {
      headers.set("x-installation-credential", installationCredential);
    }
    return handler(new Request(host + "/drafts", {
      method: "POST",
      headers,
      body: JSON.stringify(value),
    }));
  };
  const expectError = async (
    response: Response,
    status: number,
    code: string,
  ) => {
    assertEquals(response.status, status);
    assertEquals(response.headers.get("cache-control"), "private, no-store");
    const result = await response.json();
    assertEquals(result.error.code, code);
    return result;
  };

  for (const value of [identification, diagnosis, diagnosis]) {
    expectedRpc = Object.hasOwn(value, "diagnosis_job_id")
      ? "create_bound_guest_diagnosis_draft"
      : "create_guest_photo_draft";
    const before = calls.length;
    const response = await request(value);
    assertEquals(response.status, 200);
    assertEquals(await response.json(), receipt);
    assertEquals(response.headers.get("cache-control"), "private, no-store");
    assertEquals(calls.length, before + 1);
  }

  const beforeInvalid = calls.length;
  for (const value of [identification, diagnosis]) {
    await expectError(await request(value, null), 401, "UNAUTHORIZED");
    await expectError(await request(value, guest, null), 400, "VALIDATION_ERROR");
    await expectError(await request(value, guest, "short"), 400, "VALIDATION_ERROR");
  }
  for (const value of [
    null,
    [],
    "invalid",
    {},
    { diagnosis_job_id: job },
    { operation_id: operation },
    { ...diagnosis, operation_id: null },
    { ...diagnosis, operation_id: "invalid" },
    { ...diagnosis, diagnosis_job_id: null },
    { ...diagnosis, diagnosis_job_id: "invalid" },
    { ...diagnosis, taxon_id: taxon },
    { ...diagnosis, identification_job_id: job },
    { ...identification, diagnosis_job_id: job },
    { ...diagnosis, extra: null },
    { ...identification, extra: true },
    { operation_id: operation, identification_job_id: job },
    { ...identification, identification_job_id: null },
    { ...identification, taxon_id: null },
  ]) {
    await expectError(await request(value), 400, "VALIDATION_ERROR");
  }
  assertEquals(calls.length, beforeInvalid);

  // SQL owns scope, revocation, TTL and replay checks; never probe another source.
  expectedRpc = "create_bound_guest_diagnosis_draft";
  const scenarios = [
    [other, "42501", "INSTALLATION_CREDENTIAL_MISMATCH", 403, "FORBIDDEN"],
    [owner, "42501", "ACTIVE_GUEST_REQUIRED", 403, "FORBIDDEN"],
    [guest, "42501", "INSTALLATION_CREDENTIAL_MISMATCH", 403, "FORBIDDEN"],
    [other, "P0002", "DIAGNOSIS_SOURCE_NOT_FOUND", 404, "NOT_FOUND"],
    [guest, "P0002", "DIAGNOSIS_SOURCE_NOT_FOUND", 404, "NOT_FOUND"],
    [guest, "P0002", "DRAFT_EXPIRED", 410, "DRAFT_EXPIRED"],
    [guest, "23505", "IDEMPOTENCY_CONFLICT", 409, "CONFLICT"],
    [guest, "57014", "statement timeout", 503, "INTERNAL_ERROR"],
  ] as const;
  let notFound: unknown;
  for (const [identity, code, message, status, api] of scenarios) {
    expectedOwner = identity;
    failure = { code, message };
    const before = calls.length;
    const result = await expectError(
      await request(diagnosis, identity), status, api,
    );
    assertEquals(calls.length, before + 1);
    assert(!result.error.message.includes(message));
    assert(!JSON.stringify(result).includes(job));
    assertEquals(result.error.retryable, status === 503);
    if (status === 404) {
      if (notFound !== undefined) assertEquals(result, notFound);
      notFound = result;
    }
  }
});

Deno.test("Photo maintenance isolates a scoped cleanup and retries Storage removal before finishing", async () => {
  const source = `${owner}/${photo}`;
  const path = "/internal/guest-drafts/cleanup";
  const scoped = path + "?first_aid_photo_id=" + photo;
  const calls: string[] = [];
  let failedRemoval = true;
  let alreadyCleaned = false;
  const handler = createProductionPlantsApiHandler({}, {
    env: (name) => ({ SUPABASE_URL: host, SUPABASE_SERVICE_ROLE_KEY: serviceKey })[name],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      assertEquals(req.headers.get("authorization"), `Bearer ${serviceKey}`);
      const url = new URL(req.url);
      const body = await req.json();
      const operation = url.pathname.split("/").at(-1)!;
      calls.push(operation);
      switch (operation) {
        case "analysis-inputs":
          assertEquals(req.method, "DELETE");
          assertEquals(body, { prefixes: [source] });
          if (failedRemoval) {
            failedRemoval = false;
            return Response.json({ message: "fixture Storage failure" }, { status: 503 });
          }
          return Response.json([{ name: source }]);
        case "claim_first_aid_photo_cleanup":
          assertEquals(body, { p_photo_id: photo });
          return Response.json(alreadyCleaned ? [] : [{ photo_id: photo, source }]);
        case "finish_first_aid_photo_cleanup":
          assertEquals(body, { p_photo_id: photo });
          alreadyCleaned = true;
          return Response.json(null);
        default:
          throw new Error("Unexpected scoped maintenance operation: " + operation);
      }
    },
  });
  const post = (route: string, bearer = serviceKey) =>
    handler(new Request(host + route, { method: "POST", headers: { authorization: "Bearer " + bearer } }));

  assertEquals((await post(scoped, owner)).status, 401);
  assertEquals((await post(scoped + "&first_aid_photo_id=" + draft)).status, 400);
  assertEquals((await post(path + "?first_aid_photo_id=")).status, 400);
  assertEquals(calls, []);
  assertEquals(await (await post(scoped)).json(), { cleaned: 0 });
  assertEquals(calls, ["claim_first_aid_photo_cleanup", "analysis-inputs"]);
  assertEquals(await (await post(scoped)).json(), { cleaned: 1 });
  assertEquals(calls.slice(-3), ["claim_first_aid_photo_cleanup", "analysis-inputs", "finish_first_aid_photo_cleanup"]);
  assertEquals(await (await post(scoped)).json(), { cleaned: 0 });
});

Deno.test("Unscoped photo maintenance keeps guest cleanup and runs the bounded first-aid sweep", async () => {
  const calls: string[] = [];
  const handler = createProductionPlantsApiHandler({}, {
    env: (name) => ({ SUPABASE_URL: host, SUPABASE_SERVICE_ROLE_KEY: serviceKey })[name],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      const rpc = new URL(req.url).pathname.split("/").at(-1)!;
      calls.push(rpc);
      assertEquals(await req.json(), rpc === "read_guest_photo_cleanup" ? { p_draft_id: null } : { p_photo_id: null });
      return Response.json([]);
    },
  });
  const response = await handler(new Request(host + "/internal/guest-drafts/cleanup", {
    method: "POST", headers: { authorization: "Bearer " + serviceKey },
  }));
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { cleaned: 0 });
  assertEquals(calls, ["read_guest_photo_cleanup", "claim_first_aid_photo_cleanup"]);
});

Deno.test("Photo maintenance accepts the configured default secret only via apikey", async () => {
  const secret = "sb_secret_fixture_default";
  const named = "sb_secret_fixture_named__";
  let calls = 0;
  const handler = createProductionPlantsApiHandler({}, {
    env: (name) => ({
      SUPABASE_URL: host,
      SUPABASE_SERVICE_ROLE_KEY: serviceKey,
      SUPABASE_SECRET_KEYS: JSON.stringify({ default: secret, named }),
    })[name],
    fetch: async (input, init) => {
      const req = new Request(input, init);
      assertEquals(new URL(req.url).pathname, "/rest/v1/rpc/claim_first_aid_photo_cleanup");
      assertEquals(await req.json(), { p_photo_id: photo });
      calls++;
      return Response.json([]);
    },
  });
  const post = (headers: HeadersInit) => handler(new Request(
    host + "/internal/guest-drafts/cleanup?first_aid_photo_id=" + photo,
    { method: "POST", headers },
  ));
  assertEquals((await post({ apikey: "sb_publishable_fixture" })).status, 401);
  assertEquals((await post({ apikey: named })).status, 401);
  assertEquals((await post({ authorization: "Bearer " + secret })).status, 401);
  assertEquals(calls, 0);
  assertEquals(await (await post({ apikey: secret })).json(), { cleaned: 0 });
  assertEquals(calls, 1);
});
