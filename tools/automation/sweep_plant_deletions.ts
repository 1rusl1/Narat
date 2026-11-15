const uuid =
  /^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;

interface SweepPage {
  processed: number;
  data_cleared: number;
  pending: number;
  failed: number;
  next_after: string | null;
}

function page(value: unknown): SweepPage {
  if (typeof value !== "object" || value === null) {
    throw new Error("Invalid plant deletion sweep response.");
  }
  const result = value as SweepPage;
  const counts = [
    result.processed,
    result.data_cleared,
    result.pending,
    result.failed,
  ];
  if (
    !counts.every((count) =>
      Number.isInteger(count) && count >= 0 && count <= 10
    ) ||
    result.data_cleared + result.pending + result.failed > result.processed ||
    (result.next_after !== null &&
      (result.processed !== 10 || typeof result.next_after !== "string" ||
        !uuid.test(result.next_after)))
  ) throw new Error("Invalid plant deletion sweep response.");
  return result;
}

export async function sweepPlantDeletionQueue(
  url: URL,
  key: string,
  fetchPage: typeof fetch = fetch,
) {
  if (
    url.protocol !== "https:" || url.username || url.password || url.search ||
    url.hash || url.pathname !== "/" || !key.startsWith("sb_secret_")
  ) throw new Error("Expected an HTTPS project origin and project secret key.");

  const endpoint = new URL(
    "/functions/v1/plants-api/internal/plant-deletions/sweep",
    url,
  );
  const totals = { processed: 0, data_cleared: 0, pending: 0, failed: 0 };
  let after: string | null = null;
  do {
    if (after) endpoint.searchParams.set("after", after);
    const response = await fetchPage(endpoint, {
      method: "POST",
      headers: { apikey: key },
      redirect: "error",
      signal: AbortSignal.timeout(75_000),
    });
    if (!response.ok) {
      throw new Error(`Plant deletion sweep returned HTTP ${response.status}.`);
    }
    const result = page(await response.json());
    if (
      result.next_after !== null && after !== null && result.next_after <= after
    ) {
      throw new Error("Plant deletion sweep cursor did not advance.");
    }
    totals.processed += result.processed;
    totals.data_cleared += result.data_cleared;
    totals.pending += result.pending;
    totals.failed += result.failed;
    after = result.next_after;
  } while (after !== null);
  return totals;
}

if (import.meta.main) {
  const projectOrigin = Deno.env.get("NARAT_PLANT_PURGE_ORIGIN");
  const secretKey = Deno.env.get("NARAT_PLANT_PURGE_KEY");
  if (!projectOrigin || !secretKey) {
    console.error("Set NARAT_PLANT_PURGE_ORIGIN and NARAT_PLANT_PURGE_KEY.");
    Deno.exit(2);
  }
  try {
    const totals = await sweepPlantDeletionQueue(
      new URL(projectOrigin),
      secretKey,
    );
    console.log(JSON.stringify(totals));
    if (totals.failed > 0) Deno.exit(1);
  } catch {
    console.error(
      "Plant deletion sweep did not finish. Retry from the first page.",
    );
    Deno.exit(1);
  }
}
