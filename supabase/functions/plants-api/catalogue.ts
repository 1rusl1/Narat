import { type SupabaseClient } from "@supabase/supabase-js";
import { ApiHttpError, errorResponse, jsonResponse, type SupportedLocale } from "../_shared/http.ts";

export interface CatalogueSpeciesRow {
  id: string;
  plant_key: string;
  scientific_name: string;
  name_en: string;
  name_pl: string | null;
  synonyms_en: string[];
  synonyms_pl: string[];
  synonyms_latin: string[];
  care_profile_available: boolean;
  hero_image_url: string | null;
  attribution_author: string | null;
  attribution_license: string | null;
  attribution_source_url: string | null;
  share_alike_required: boolean;
}

export interface CatalogueItemDTO {
  species_id: string;
  plant_key: string;
  display_name: string;
  scientific_name: string;
  matched_synonym: string | null;
  care_profile_available: boolean;
  hero_image_url: string | null;
  attribution: {
    author: string | null;
    license: string | null;
    source_url: string | null;
    share_alike_required: boolean;
  } | null;
}

export function normalizeSearchQuery(raw: string): string {
  return raw
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/ł/g, "l");
}

export function rankCatalogueSpecies(
  rows: CatalogueSpeciesRow[],
  query: string,
  locale: "pl" | "en",
): CatalogueItemDTO[] {
  const normQuery = normalizeSearchQuery(query);
  const scored: { score: number; dto: CatalogueItemDTO }[] = [];

  for (const row of rows) {
    // Fallback to scientific_name if localized name is missing (FR-042)
    const primaryLocalized =
      locale === "pl"
        ? (row.name_pl && row.name_pl.trim().length > 0 ? row.name_pl : row.scientific_name)
        : (row.name_en && row.name_en.trim().length > 0 ? row.name_en : row.scientific_name);

    const attribution =
      row.attribution_author || row.attribution_license || row.attribution_source_url
        ? {
            author: row.attribution_author,
            license: row.attribution_license,
            source_url: row.attribution_source_url,
            share_alike_required: row.share_alike_required,
          }
        : null;

    if (!normQuery) {
      scored.push({
        score: 1,
        dto: {
          species_id: row.id,
          plant_key: row.plant_key,
          display_name: primaryLocalized,
          scientific_name: row.scientific_name,
          matched_synonym: null,
          care_profile_available: row.care_profile_available,
          hero_image_url: row.hero_image_url,
          attribution,
        },
      });
      continue;
    }

    const candidates = [
      { text: primaryLocalized, weight: 100, isSynonym: false },
      { text: row.scientific_name, weight: 95, isSynonym: false },
      { text: row.name_en, weight: 90, isSynonym: false },
      ...(row.name_pl ? [{ text: row.name_pl, weight: 90, isSynonym: false }] : []),
      ...(row.synonyms_pl ?? []).map((s) => ({ text: s, weight: 80, isSynonym: true })),
      ...(row.synonyms_en ?? []).map((s) => ({ text: s, weight: 80, isSynonym: true })),
      ...(row.synonyms_latin ?? []).map((s) => ({ text: s, weight: 85, isSynonym: true })),
    ];

    let bestScore = 0;
    let matchedSynonym: string | null = null;

    for (const candidate of candidates) {
      const normCandidate = normalizeSearchQuery(candidate.text);
      if (normCandidate === normQuery) {
        if (candidate.weight + 20 > bestScore) {
          bestScore = candidate.weight + 20;
          matchedSynonym = candidate.isSynonym ? candidate.text : null;
        }
      } else if (normCandidate.startsWith(normQuery)) {
        if (candidate.weight + 10 > bestScore) {
          bestScore = candidate.weight + 10;
          matchedSynonym = candidate.isSynonym ? candidate.text : null;
        }
      } else if (normCandidate.includes(normQuery)) {
        if (candidate.weight > bestScore) {
          bestScore = candidate.weight;
          matchedSynonym = candidate.isSynonym ? candidate.text : null;
        }
      }
    }

    if (bestScore > 0) {
      scored.push({
        score: bestScore,
        dto: {
          species_id: row.id,
          plant_key: row.plant_key,
          display_name: primaryLocalized,
          scientific_name: row.scientific_name,
          matched_synonym: matchedSynonym,
          care_profile_available: row.care_profile_available,
          hero_image_url: row.hero_image_url,
          attribution,
        },
      });
    }
  }

  scored.sort((a, b) =>
    b.score !== a.score
      ? b.score - a.score
      : a.dto.display_name.localeCompare(b.dto.display_name)
  );
  return scored.map((entry) => entry.dto);
}

export async function handleSearchCatalogue(
  req: Request,
  supabaseAdmin: SupabaseClient,
  locale: "pl" | "en",
): Promise<Response> {
  const url = new URL(req.url);
  const query = url.searchParams.get("q") ?? "";
  const limit = Math.min(Math.max(Number(url.searchParams.get("limit") ?? "30"), 1), 100);

  const { data, error } = await supabaseAdmin
    .from("plant_species")
    .select(
      "id, plant_key, scientific_name, name_en, name_pl, synonyms_en, synonyms_pl, synonyms_latin, care_profile_available, hero_image_url, attribution_author, attribution_license, attribution_source_url, share_alike_required",
    )
    .limit(300);

  if (error) {
    return errorResponse(new ApiHttpError(500, "INTERNAL_ERROR", error.message));
  }

  const ranked = rankCatalogueSpecies((data ?? []) as CatalogueSpeciesRow[], query, locale).slice(
    0,
    limit,
  );

  return jsonResponse({
    items: ranked,
    locale,
    query,
  }, 200);
}

const catalogueSlug = /^[a-z][a-z0-9_]*$/i;
const taxonUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const searchParams = new Set(["q", "limit", "offset"]);

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isPublishedCard(value: unknown): boolean {
  return record(value) && typeof value.taxon_id === "string" && taxonUuid.test(value.taxon_id) &&
    typeof value.plant_id === "string" && catalogueSlug.test(value.plant_id) &&
    typeof value.scientific_name === "string" && value.scientific_name.length > 0 &&
    typeof value.display_name === "string" && value.display_name.length > 0 &&
    typeof value.care_profile_available === "boolean";
}

function invalidCatalogueRequest() {
  return new ApiHttpError(400, "VALIDATION_ERROR", "Invalid catalogue request.");
}

function unavailableCatalogue() {
  return new ApiHttpError(503, "INTERNAL_ERROR", "The catalogue is temporarily unavailable.", true);
}

function integer(raw: string | null, fallback: number, min: number, max: number) {
  if (raw === null) return fallback;
  const value = Number(raw);
  if (!/^\d+$/.test(raw) || !Number.isSafeInteger(value) || value < min || value > max) {
    throw invalidCatalogueRequest();
  }
  return value;
}

export async function handlePublishedCatalogue(
  req: Request,
  locale: SupportedLocale,
  clientFactory: () => SupabaseClient | null,
  segment?: string,
): Promise<Response> {
  const params = new URL(req.url).searchParams;
  const keys = [...params.keys()];
  if (keys.some((key) => !searchParams.has(key)) || new Set(keys).size !== keys.length ||
    (segment !== undefined && keys.length > 0)) throw invalidCatalogueRequest();

  let identifier: string | undefined;
  if (segment !== undefined) {
    try {
      identifier = decodeURIComponent(segment);
    } catch {
      throw invalidCatalogueRequest();
    }
    if (!catalogueSlug.test(identifier) && !taxonUuid.test(identifier)) throw invalidCatalogueRequest();
  }

  const limit = integer(params.get("limit"), 50, 1, 200);
  const offset = integer(params.get("offset"), 0, 0, 2_147_483_647);
  let response;
  try {
    const client = clientFactory();
    if (!client) throw unavailableCatalogue();
    response = identifier === undefined
      ? await client.rpc("search_catalogue_species", {
        p_query: params.get("q") ?? "", p_locale: locale, p_limit: limit, p_offset: offset,
      })
      : await client.rpc("get_catalogue_species_card", { p_identifier: identifier, p_locale: locale });
  } catch {
    throw unavailableCatalogue();
  }
  const { data, error } = response;
  if (error) throw unavailableCatalogue();
  if (identifier !== undefined) {
    if (data === null) throw new ApiHttpError(404, "NOT_FOUND", "The published species was not found.");
    if (!isPublishedCard(data)) throw unavailableCatalogue();
  } else if (!record(data) || data.locale !== locale || data.limit !== limit || data.offset !== offset ||
    !Number.isSafeInteger(data.total) || Number(data.total) < 0 || !Array.isArray(data.items) ||
    data.items.length > Math.min(limit, Math.max(0, Number(data.total) - offset)) ||
    !data.items.every(isPublishedCard)) {
    throw unavailableCatalogue();
  }
  return jsonResponse(data, 200, { Vary: "X-Client-Locale, Accept-Language" });
}
