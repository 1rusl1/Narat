// Runs only inside the isolated PostgreSQL gate. The injected transport uses the
// RPC outcomes recorded by real concurrent transactions in the same test.
import { assertEquals } from "@std/assert";
import { createProductionPlantsApiHandler } from "../../supabase/functions/plants-api/index.ts";

const scenario = await new Response(Deno.stdin.readable).json();
const host = "https://v05.example.test";
const jobs = host + "/functions/v1/plants-api/analysis/jobs";
const serviceKey = "v05-fixture-service-key";
const dispatches: string[] = [];
let canDispatch = true;
let reply: {
  rpc: string;
  input: Record<string, unknown>;
  output: unknown;
  status: number;
};

const handler = createProductionPlantsApiHandler({
  resolveRequestContext: async () => ({
    ownerId: scenario.owner,
    accountState: "active",
    isAnonymous: false,
    locale: "en",
    installationCredential: null,
    operationId: null,
  }),
}, {
  env: (name) =>
    ({ SUPABASE_URL: host, SUPABASE_SERVICE_ROLE_KEY: serviceKey })[name],
  fetch: async (input, init) => {
    const request = new Request(input, init);
    assertEquals(request.url, host + "/rest/v1/rpc/" + reply.rpc);
    assertEquals(request.headers.get("authorization"), "Bearer " + serviceKey);
    assertEquals(await request.json(), reply.input);
    return Response.json(reply.output, { status: reply.status });
  },
  diagnosisWorker: {
    ready: () => canDispatch,
    run: (jobId) => {
      dispatches.push(jobId);
      return Promise.resolve();
    },
  },
  scheduleDiagnosis: () => {},
});

async function create(
  operation: string,
  photo: string,
  sqlOutcome: unknown,
  httpStatus: number,
  workerReady = true,
) {
  canDispatch = workerReady;
  reply = {
    rpc: "create_plant_diagnosis_job",
    input: {
      p_owner_id: scenario.owner,
      p_operation_id: operation,
      p_photo_asset_id: photo,
      p_flow_id: scenario.flow,
      p_locale: "en",
      p_can_dispatch: workerReady,
      p_target_plant_id: scenario.plant,
    },
    output: sqlOutcome,
    status: httpStatus === 429 ? 400 : 200,
  };
  const response = await handler(
    new Request(jobs, {
      method: "POST",
      body: JSON.stringify({
        mode: "diagnosis",
        operation_id: operation,
        photo_asset_id: photo,
        target_plant_id: scenario.plant,
        flow_id: scenario.flow,
      }),
    }),
  );
  assertEquals(response.status, httpStatus);
  return await response.json();
}

async function read(
  job: { job_id: string; status: string; quota_state: string },
) {
  reply = {
    rpc: "read_diagnosis_job",
    input: { p_owner_id: scenario.owner, p_job_id: job.job_id },
    output: job,
    status: 200,
  };
  const response = await handler(new Request(jobs + "/" + job.job_id));
  assertEquals(response.status, 200);
  assertEquals(await response.json(), job);
}

const {
  winner,
  distinct,
  retry,
  original_photo: original,
  other_photo: other,
} = scenario;
const accepted = await create(winner, original, scenario.accepted, 202);
assertEquals(accepted, scenario.accepted.job);
assertEquals(
  await create(winner, original, scenario.concurrent_replay, 200, false),
  accepted,
);
assertEquals(
  (await create(distinct, other, scenario.concurrent_denial, 429)).error.code,
  "QUOTA_EXHAUSTED",
);
await read(scenario.failed);
assertEquals(
  await create(winner, original, scenario.failed_replay, 200, false),
  accepted,
);
const retried = await create(retry, original, scenario.retried, 202);
assertEquals(retried, scenario.retried.job);
await read(scenario.terminal);
assertEquals(
  (await create(distinct, other, scenario.terminal_denial, 429)).error.code,
  "QUOTA_EXHAUSTED",
);
assertEquals(
  await create(retry, original, scenario.terminal_replay, 200, false),
  retried,
);
assertEquals(dispatches, [accepted.job_id, retried.job_id]);
