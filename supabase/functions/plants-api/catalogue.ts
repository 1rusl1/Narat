import { SupabaseClient } from "@supabase/supabase-js";
import { ApiHttpError, errorResponse, jsonResponse } from "../_shared/http.ts";

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
