// Validate real SQL output through the shared schema and compare every EN/PL projection.
import { projectCatalogueSkeletonCard, validateCatalogueSkeletonCardContract } from "../../catalogue/import.ts";
const bundle = JSON.parse(Deno.readTextFileSync(new URL("../../catalogue/releases/skeleton-300-v1/plants.json", import.meta.url)));
const canonical = (value: unknown): string => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(",")}}`;
  return JSON.stringify(value);
};
let checked = 0;
for (const locale of ["en", "pl"] as const) {
  const cards = JSON.parse(Deno.readTextFileSync(`${Deno.args[0]}/sql-cards-${locale}.json`));
  if (cards.length !== bundle.plants.length) throw new Error("SQL card count mismatch");
  for (const card of cards) {
    const errors = validateCatalogueSkeletonCardContract(card);
    if (errors.length) throw new Error(`${card.plant_id}: ${errors.join("; ")}`);
    const plant = bundle.plants.find((p: { plant_id: string }) => p.plant_id === card.plant_id);
    const expected = projectCatalogueSkeletonCard({ ...plant, taxon_id: card.taxon_id }, locale);
    if (canonical(card) !== canonical(expected)) throw new Error(`${card.plant_id}/${locale}: SQL/TS mismatch`);
    checked++;
  }
}
console.log(`SQL/TS schema and projection parity: ${checked} cards PASS`);
