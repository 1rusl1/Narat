// catalogue/import.ts
// T021: KB release import pipeline (quarantine -> validate -> atomic publish / rollback).
// Validates SHA-256 digests, PlantProfile/ConditionProfile schemas, 300/40 thresholds,
// PL/EN bilingual completeness, alias uniqueness, evidence sources, and 30-day PL indoor commercial rules.
// Ensures public catalogue projection never leaks full protocols or paid plans.

import AjvModule from "ajv";
import catalogueSchema from "../specs/001-plants-ios-mvp/contracts/catalogue-skeleton.schema.json" with { type: "json" };

// Match the existing Deno/Ajv interop used by AnalysisValidator.
// deno-lint-ignore no-explicit-any
const CatalogueAjv: any = (AjvModule as any).default ?? AjvModule;
const catalogueAjv = new CatalogueAjv({ allErrors: true, strict: false });
const validateCardSchema = catalogueAjv.compile(catalogueSchema);
const validateRecordSchema = catalogueAjv.compile({ ...catalogueSchema, $ref: "#/definitions/record" });

export interface LocalizedText {
  pl: string;
  en: string;
}

export interface SafetyEntry {
  status: "safe" | "toxic" | "unknown";
  severity?: "none" | "mild" | "moderate" | "severe" | "unknown";
  notes?: LocalizedText;
  evidence_ids: string[];
}

export interface PlantProfileRecord {
  schema_version: "3.0";
  kb_release_id: string;
  plant_id: string;
  taxon_id: string;
  scientific_name: string;
  genus_id: string;
  family: string;
  status: "published" | "draft" | "deprecated";
  reviewed_by: string;
  reviewed_at: string;
  names: {
    pl: { primary: string; synonyms: string[] };
    en: { primary: string; synonyms: string[] };
  };
  safety: {
    cat: SafetyEntry;
    dog: SafetyEntry;
  };
  care_summary: {
    light: LocalizedText;
    watering: LocalizedText;
    soil_and_pot: LocalizedText;
    water_interval_days: { min: number; max: number; default_days: number };
  };
  routine_plan_template: Record<string, unknown>;
  evidence_ids: string[];
}

export interface CommercialProductRecord {
  option_id: string;
  condition_id: string;
  option_kind: "non_chemical" | "biological" | "commercial_product";
  allowed_in_pl_indoor: boolean;
  verified_at: string;
  valid_until: string;
  evidence_ids: string[];
}

export interface ConditionProfileRecord {
  schema_version: "3.0";
  kb_release_id: string;
  condition_id: string;
  category: "abiotic" | "pest" | "fungal" | "bacterial" | "viral" | "unknown";
  status: "published" | "draft" | "deprecated";
  reviewed_by: string;
  reviewed_at: string;
  names: LocalizedText;
  applicable_plant_ids: string[];
  applicable_genus_ids: string[];
  visual_markers: string[];
  first_aid_protocol: Record<string, unknown>;
  treatment_protocol: Record<string, unknown>;
  evidence_ids: string[];
  treatment_options?: CommercialProductRecord[];
}

export interface KbReleaseBundle {
  kb_release_id: string;
  version: string;
  schema_version: "3.0";
  manifest_sha256: string;
  approved_source_codes: string[];
  evidence_ids: string[];
  plants: PlantProfileRecord[];
  conditions: ConditionProfileRecord[];
}

export interface ImportOptions {
  enforceLaunchThresholds?: boolean;
  now?: Date;
  expectedManifestSha256?: string;
}

export interface PublicCataloguePlantProjection {
  plant_id: string;
  taxon_id: string;
  scientific_name: string;
  genus_id: string;
  family: string;
  names: PlantProfileRecord["names"];
  safety: PlantProfileRecord["safety"];
  care_summary: PlantProfileRecord["care_summary"];
}

export interface ReleaseValidationResult {
  valid: boolean;
  releaseState: "published" | "quarantined" | "rolled_back";
  errors: string[];
  publishedPlantCount: number;
  publishedConditionCount: number;
  publicCatalogueProjection: PublicCataloguePlantProjection[];
}

export interface SkeletonCommonNameEntry {
  name: string;
  source_property: string;
  source_entity?: string;
  source_page_title?: string;
  source_revision?: number | null;
  evidence?: string;
  review_status?: string;
}

export interface SkeletonDescriptionEntry {
  text: string;
  language: "en" | "pl";
  source_url: string;
  source_revision: number;
  article_wikidata_id?: string | null;
  revision_url: string;
  history_url: string;
  attribution: string;
  license: "CC-BY-SA-4.0";
  license_url: string;
  modifications: string;
  translation_source_language?: "en";
  taxon_scope?: string;
  review_status: string;
}

export interface SkeletonHeroImageEntry {
  file_title: string;
  source_page: string;
  local_path: string;
  storage_path?: string;
  sha256: string;
  bytes: number;
  width: number;
  height: number;
  mime?: "image/jpeg" | "image/png" | "image/webp";
  license: string;
  license_url: string;
  author: string;
  credit?: string;
  attribution: string;
  modifications: string;
}

export interface SkeletonWateringEntry {
  intervals_days: {
    spring: number | null;
    summer: number | null;
    fall: number | null;
    winter: number | null;
  };
  watering_method: string | null;
  drainage_preference: string | null;
  match_level:
    | "species_exact"
    | "species_synonym"
    | "genus_representative"
    | "botanical_group_representative";
  matched_on: string;
  source: {
    id: string;
    repository: string;
    commit: string;
    snapshot_sha256: string;
    plantfolio_id: string;
    plantfolio_type_name?: string;
    plantfolio_common_examples?: string;
  };
}

export interface CatalogueSkeletonPlantRecord {
  taxon_id?: string | null;
  plant_id: string;
  scientific_name: string;
  scientific_name_status: string;
  wikidata_id: string;
  source_revision: number;
  rank?: "species" | "genus" | "hybrid";
  genus?: string;
  family?: string;
  external_taxon_ids: Record<string, string[]>;
  common_names: {
    en: SkeletonCommonNameEntry[];
    pl: SkeletonCommonNameEntry[];
  };
  search_aliases: {
    en: string[];
    pl: string[];
  };
  descriptions: {
    en: SkeletonDescriptionEntry;
    pl: SkeletonDescriptionEntry | null;
  };
  hero_image: SkeletonHeroImageEntry;
  watering: SkeletonWateringEntry;
  care_profile_available: boolean;
  status: string;
  name_source?: Record<string, unknown> | null;
  gaps?: string[];
}

export interface CatalogueSkeletonBundle {
  schema_version: "catalogue-skeleton-1.1" | "catalogue-skeleton-1.0";
  version: string;
  status: string;
  sources: string[];
  plants: CatalogueSkeletonPlantRecord[];
}

export interface PublicCatalogueSkeletonCard {
  taxon_id: string | null;
  plant_id: string;
  scientific_name: string;
  accepted_scientific_name: string;
  scientific_name_status: string;
  wikidata_id: string;
  rank: "species" | "genus" | "hybrid";
  genus: string;
  family: string;
  external_taxon_ids: Record<string, string[]>;
  localized_name: string | null;
  display_name: string;
  common_names: {
    en: SkeletonCommonNameEntry[];
    pl: SkeletonCommonNameEntry[];
  };
  search_aliases: {
    en: string[];
    pl: string[];
  };
  description: SkeletonDescriptionEntry;
  descriptions: {
    en: SkeletonDescriptionEntry;
    pl: SkeletonDescriptionEntry | null;
  };
  hero_image: SkeletonHeroImageEntry;
  watering: SkeletonWateringEntry;
  care_profile_available: boolean;
  safety: {
    cat: { status: "safe" | "toxic" | "unknown" };
    dog: { status: "safe" | "toxic" | "unknown" };
  };
  name_source: Record<string, unknown> | null;
}

export interface SkeletonValidationResult {
  valid: boolean;
  releaseVersion: string;
  kbReleaseId: null;
  speciesCount: number;
  errors: string[];
  cards: PublicCatalogueSkeletonCard[];
}

const PLANT_ID_REGEX = /^[a-z][a-z0-9_]*$/;
const SHA256_HEX_REGEX = /^[0-9a-f]{64}$/;
const WIKIDATA_ID_REGEX = /^Q[1-9][0-9]*$/;
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ALLOWED_RANKS = new Set(["species", "genus", "hybrid"]);
const ALLOWED_HERO_MIMES = new Set(["image/jpeg", "image/png", "image/webp"]);
const ALLOWED_WATERING_MATCH_LEVELS = new Set([
  "species_exact",
  "species_synonym",
  "genus_representative",
  "botanical_group_representative",
]);
const WATERING_SEASONS = ["spring", "summer", "fall", "winter"] as const;
const CANONICAL_CARD_KEYS = [
  "taxon_id",
  "plant_id",
  "scientific_name",
  "accepted_scientific_name",
  "scientific_name_status",
  "wikidata_id",
  "rank",
  "genus",
  "family",
  "external_taxon_ids",
  "localized_name",
  "display_name",
  "common_names",
  "search_aliases",
  "description",
  "descriptions",
  "hero_image",
  "watering",
  "care_profile_available",
  "safety",
  "name_source",
] as const;

function isPlainObject(val: unknown): val is Record<string, unknown> {
  return Boolean(val) && typeof val === "object" && !Array.isArray(val);
}

function isPositiveInteger(val: unknown): val is number {
  return typeof val === "number" && Number.isInteger(val) && val > 0;
}

function isHttpsUrl(val: unknown): val is string {
  return typeof val === "string" && /^https:\/\/\S+$/.test(val.trim());
}

function isHttpOrHttpsUrl(val: unknown): val is string {
  return typeof val === "string" && /^https?:\/\/\S+$/.test(val.trim());
}

function validateDescriptionEntry(
  plantId: string,
  fieldLabel: string,
  expectedLang: "en" | "pl" | null,
  desc: unknown,
): string[] {
  const errs: string[] = [];
  if (!isPlainObject(desc)) {
    return [`Plant '${plantId}' ${fieldLabel} must be an object.`];
  }
  if (typeof desc.text !== "string" || !desc.text.trim()) {
    errs.push(`Plant '${plantId}' ${fieldLabel}.text must be a non-empty string.`);
  }
  if (expectedLang !== null) {
    if (desc.language !== expectedLang) {
      errs.push(
        `Plant '${plantId}' ${fieldLabel}.language must be '${expectedLang}', got '${String(desc.language)}'.`,
      );
    }
  } else if (desc.language !== "en" && desc.language !== "pl") {
    errs.push(`Plant '${plantId}' ${fieldLabel}.language must be 'en' or 'pl'.`);
  }
  if (!isPositiveInteger(desc.source_revision)) {
    errs.push(`Plant '${plantId}' ${fieldLabel}.source_revision must be a positive integer.`);
  }
  if (desc.license !== "CC-BY-SA-4.0" || !isHttpsUrl(desc.license_url)) {
    errs.push(`Plant '${plantId}' ${fieldLabel} has invalid license metadata.`);
  }
  if (!isHttpsUrl(desc.source_url) || !isHttpsUrl(desc.revision_url) || !isHttpsUrl(desc.history_url)) {
    errs.push(`Plant '${plantId}' ${fieldLabel} has invalid provenance URLs.`);
  }
  if (typeof desc.attribution !== "string" || !desc.attribution.trim()) {
    errs.push(`Plant '${plantId}' ${fieldLabel} is missing attribution.`);
  }
  if (typeof desc.modifications !== "string" || !desc.modifications.trim()) {
    errs.push(`Plant '${plantId}' ${fieldLabel} is missing modifications.`);
  }
  if (typeof desc.review_status !== "string" || !desc.review_status.trim()) {
    errs.push(`Plant '${plantId}' ${fieldLabel} is missing review_status.`);
  }
  return errs;
}

function validateHeroImageEntry(plantId: string, hero: unknown): string[] {
  const errs: string[] = [];
  if (!isPlainObject(hero)) {
    return [`Plant '${plantId}' is missing hero_image.`];
  }
  if (typeof hero.sha256 !== "string" || !SHA256_HEX_REGEX.test(hero.sha256)) {
    errs.push(`Plant '${plantId}' has invalid hero_image.sha256 '${String(hero.sha256)}'.`);
  }
  if (!isPositiveInteger(hero.bytes) || !isPositiveInteger(hero.width) || !isPositiveInteger(hero.height)) {
    errs.push(`Plant '${plantId}' has invalid hero_image dimensions or byte size.`);
  }
  if (hero.mime !== undefined && hero.mime !== null && !ALLOWED_HERO_MIMES.has(String(hero.mime))) {
    errs.push(`Plant '${plantId}' has unsupported hero_image.mime '${String(hero.mime)}'.`);
  }
  if (
    typeof hero.author !== "string" ||
    !hero.author.trim() ||
    typeof hero.attribution !== "string" ||
    !hero.attribution.trim() ||
    typeof hero.file_title !== "string" ||
    !hero.file_title.trim() ||
    typeof hero.local_path !== "string" ||
    !/\.(jpe?g|png|webp)$/i.test(hero.local_path.trim()) ||
    typeof hero.license !== "string" ||
    !hero.license.trim() ||
    typeof hero.modifications !== "string" ||
    !hero.modifications.trim() ||
    !isHttpsUrl(hero.source_page) ||
    !isHttpOrHttpsUrl(hero.license_url)
  ) {
    errs.push(`Plant '${plantId}' has incomplete hero_image attribution or URLs.`);
  }
  return errs;
}

function validateWateringIntervals(
  plantId: string,
  watering: SkeletonWateringEntry | Record<string, unknown> | null | undefined,
): string[] {
  const errs: string[] = [];
  if (!isPlainObject(watering)) {
    return [`Plant '${plantId}' is missing watering.`];
  }
  const intervals = watering.intervals_days;
  if (!isPlainObject(intervals)) {
    return [`Plant '${plantId}' is missing watering.intervals_days.`];
  }
  let positiveCount = 0;
  for (const season of WATERING_SEASONS) {
    const val = intervals[season];
    if (val === null) {
      continue;
    }
    if (!isPositiveInteger(val) || val > 365) {
      errs.push(
        `Plant '${plantId}' has invalid watering.intervals_days.${season} '${String(val)}'.`,
      );
    } else {
      positiveCount += 1;
    }
  }
  const method = watering.watering_method;
  if (method !== "immersion" && positiveCount < 2) {
    errs.push(
      `Plant '${plantId}' watering.intervals_days requires at least 2 active seasonal intervals (got ${positiveCount}).`,
    );
  }
  return errs;
}

function validateWateringEntry(plantId: string, watering: unknown): string[] {
  const errs = validateWateringIntervals(
    plantId,
    watering as Record<string, unknown> | null | undefined,
  );
  if (!isPlainObject(watering)) {
    return errs;
  }
  if (!ALLOWED_WATERING_MATCH_LEVELS.has(String(watering.match_level ?? ""))) {
    errs.push(
      `Plant '${plantId}' has invalid watering.match_level '${String(watering.match_level)}'.`,
    );
  }
  if (typeof watering.matched_on !== "string" || !watering.matched_on.trim()) {
    errs.push(`Plant '${plantId}' is missing watering.matched_on.`);
  }
  if (
    watering.watering_method !== null &&
    watering.watering_method !== undefined &&
    (typeof watering.watering_method !== "string" || !watering.watering_method.trim())
  ) {
    errs.push(`Plant '${plantId}' has invalid watering.watering_method.`);
  }
  if (
    watering.drainage_preference !== null &&
    watering.drainage_preference !== undefined &&
    (typeof watering.drainage_preference !== "string" || !watering.drainage_preference.trim())
  ) {
    errs.push(`Plant '${plantId}' has invalid watering.drainage_preference.`);
  }
  const source = watering.source;
  if (
    !isPlainObject(source) ||
    typeof source.id !== "string" ||
    !source.id.trim() ||
    !isHttpsUrl(source.repository) ||
    typeof source.commit !== "string" ||
    !source.commit.trim() ||
    typeof source.snapshot_sha256 !== "string" ||
    !SHA256_HEX_REGEX.test(source.snapshot_sha256) ||
    typeof source.plantfolio_id !== "string" ||
    !source.plantfolio_id.trim()
  ) {
    errs.push(`Plant '${plantId}' has invalid watering.source metadata.`);
  }
  return errs;
}

function validateCommonNames(plantId: string, commonNames: unknown): string[] {
  if (!isPlainObject(commonNames)) {
    return [`Plant '${plantId}' common_names must be an object with 'en' and 'pl' arrays.`];
  }
  const errs: string[] = [];
  for (const lang of ["en", "pl"] as const) {
    const list = commonNames[lang];
    if (!Array.isArray(list)) {
      errs.push(`Plant '${plantId}' common_names.${lang} must be an array.`);
      continue;
    }
    for (const item of list) {
      if (
        !isPlainObject(item) ||
        typeof item.name !== "string" ||
        !item.name.trim() ||
        typeof item.source_property !== "string" ||
        !item.source_property.trim()
      ) {
        errs.push(`Plant '${plantId}' common_names.${lang} contains an invalid entry.`);
      }
    }
  }
  return errs;
}

function validateSearchAliases(plantId: string, searchAliases: unknown): string[] {
  if (!isPlainObject(searchAliases)) {
    return [`Plant '${plantId}' search_aliases must be an object with 'en' and 'pl' arrays.`];
  }
  const errs: string[] = [];
  for (const lang of ["en", "pl"] as const) {
    const list = searchAliases[lang];
    if (!Array.isArray(list) || list.some((v) => typeof v !== "string" || !v.trim())) {
      errs.push(`Plant '${plantId}' search_aliases.${lang} must be an array of non-empty strings.`);
    }
  }
  return errs;
}

function validateExternalTaxonIds(plantId: string, externalIds: unknown): string[] {
  if (!isPlainObject(externalIds)) {
    return [`Plant '${plantId}' external_taxon_ids must be an object.`];
  }
  const errs: string[] = [];
  for (const [key, val] of Object.entries(externalIds)) {
    if (!Array.isArray(val) || val.some((v) => typeof v !== "string" || !v.trim())) {
      errs.push(`Plant '${plantId}' external_taxon_ids.${key} must be an array of non-empty strings.`);
    }
  }
  return errs;
}

function hasNonEmptyLocalizedText(value: LocalizedText | undefined): boolean {
  return Boolean(
    value &&
      typeof value.pl === "string" &&
      value.pl.trim().length > 0 &&
      typeof value.en === "string" &&
      value.en.trim().length > 0,
  );
}

export async function computeBundleSha256(payload: string): Promise<string> {
  const bytes = new TextEncoder().encode(payload);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Projects a PlantProfile into the public catalogue representation,
 * strictly excluding full routine/recovery plan templates and paid protocols.
 */
export function buildPublicCatalogueProjection(
  plant: PlantProfileRecord,
): PublicCataloguePlantProjection {
  return {
    plant_id: plant.plant_id,
    taxon_id: plant.taxon_id,
    scientific_name: plant.scientific_name,
    genus_id: plant.genus_id,
    family: plant.family,
    names: structuredClone(plant.names),
    safety: structuredClone(plant.safety),
    care_summary: structuredClone(plant.care_summary),
  };
}

/**
 * Quarantine -> Validate -> Atomic Publish / Rollback pipeline for KB releases.
 */
export function validateAndStageKbRelease(
  bundle: KbReleaseBundle,
  options: ImportOptions = {},
): ReleaseValidationResult {
  const errors: string[] = [];
  const now = options.now ?? new Date();
  const enforceThresholds = options.enforceLaunchThresholds ?? true;

  if (bundle.schema_version !== "3.0") {
    errors.push(`Unsupported schema_version '${bundle.schema_version}'. Expected '3.0'.`);
  }

  if (
    options.expectedManifestSha256 &&
    options.expectedManifestSha256.toLowerCase() !== bundle.manifest_sha256.toLowerCase()
  ) {
    errors.push("Manifest SHA-256 mismatch against expected release digest.");
  }

  const knownEvidenceIds = new Set(bundle.evidence_ids);
  const seenPlantIds = new Set<string>();
  const seenTaxonIds = new Set<string>();
  const seenAliasesPl = new Set<string>();
  const seenAliasesEn = new Set<string>();

  const publishedPlants = bundle.plants.filter((p) => p.status === "published");
  const publishedConditions = bundle.conditions.filter((c) => c.status === "published");

  if (enforceThresholds) {
    if (publishedPlants.length < 300) {
      errors.push(
        `Launch threshold not met: ${publishedPlants.length} published PlantProfiles (< 300).`,
      );
    }
    if (publishedConditions.length < 40) {
      errors.push(
        `Launch threshold not met: ${publishedConditions.length} published ConditionProfiles (< 40).`,
      );
    }
  }

  for (const plant of publishedPlants) {
    if (!PLANT_ID_REGEX.test(plant.plant_id)) {
      errors.push(`Invalid plant_id '${plant.plant_id}'.`);
    }
    if (plant.kb_release_id !== bundle.kb_release_id) {
      errors.push(`Plant '${plant.plant_id}' kb_release_id mismatch.`);
    }
    if (seenPlantIds.has(plant.plant_id)) {
      errors.push(`Duplicate plant_id '${plant.plant_id}'.`);
    }
    seenPlantIds.add(plant.plant_id);

    if (seenTaxonIds.has(plant.taxon_id)) {
      errors.push(`Duplicate taxon_id '${plant.taxon_id}'.`);
    }
    seenTaxonIds.add(plant.taxon_id);

    if (!plant.reviewed_by || !plant.reviewed_at) {
      errors.push(`Plant '${plant.plant_id}' is missing editorial review metadata.`);
    }

    if (
      !plant.names?.pl?.primary?.trim() ||
      !plant.names?.en?.primary?.trim()
    ) {
      errors.push(`Plant '${plant.plant_id}' is missing primary PL or EN name.`);
    }

    for (const alias of [plant.names.pl.primary, ...(plant.names.pl.synonyms ?? [])]) {
      const norm = alias.trim().toLowerCase();
      if (seenAliasesPl.has(norm)) {
        errors.push(`Ambiguous PL name/synonym '${alias}' on '${plant.plant_id}'.`);
      }
      seenAliasesPl.add(norm);
    }

    for (const alias of [plant.names.en.primary, ...(plant.names.en.synonyms ?? [])]) {
      const norm = alias.trim().toLowerCase();
      if (seenAliasesEn.has(norm)) {
        errors.push(`Ambiguous EN name/synonym '${alias}' on '${plant.plant_id}'.`);
      }
      seenAliasesEn.add(norm);
    }

    if (
      !hasNonEmptyLocalizedText(plant.care_summary?.light) ||
      !hasNonEmptyLocalizedText(plant.care_summary?.watering) ||
      !hasNonEmptyLocalizedText(plant.care_summary?.soil_and_pot)
    ) {
      errors.push(`Plant '${plant.plant_id}' has incomplete PL/EN care_summary.`);
    }

    for (const species of ["cat", "dog"] as const) {
      const safety = plant.safety?.[species];
      if (!safety || !["safe", "toxic", "unknown"].includes(safety.status)) {
        errors.push(`Plant '${plant.plant_id}' has invalid safety.${species}.status.`);
      } else if (safety.status !== "unknown" && (!safety.evidence_ids || safety.evidence_ids.length === 0)) {
        errors.push(
          `Plant '${plant.plant_id}' safety.${species} status '${safety.status}' requires evidence_ids.`,
        );
      }
    }

    if (!plant.evidence_ids || plant.evidence_ids.length === 0) {
      errors.push(`Plant '${plant.plant_id}' has no evidence_ids.`);
    } else {
      for (const eid of plant.evidence_ids) {
        if (!knownEvidenceIds.has(eid)) {
          errors.push(`Plant '${plant.plant_id}' references unknown evidence_id '${eid}'.`);
        }
      }
    }
  }

  const seenConditionIds = new Set<string>();
  for (const cond of publishedConditions) {
    if (!PLANT_ID_REGEX.test(cond.condition_id)) {
      errors.push(`Invalid condition_id '${cond.condition_id}'.`);
    }
    if (cond.kb_release_id !== bundle.kb_release_id) {
      errors.push(`Condition '${cond.condition_id}' kb_release_id mismatch.`);
    }
    if (seenConditionIds.has(cond.condition_id)) {
      errors.push(`Duplicate condition_id '${cond.condition_id}'.`);
    }
    seenConditionIds.add(cond.condition_id);

    if (!hasNonEmptyLocalizedText(cond.names)) {
      errors.push(`Condition '${cond.condition_id}' is missing PL/EN names.`);
    }

    if (!cond.evidence_ids || cond.evidence_ids.length === 0) {
      errors.push(`Condition '${cond.condition_id}' has no evidence_ids.`);
    }

    for (const opt of cond.treatment_options ?? []) {
      if (opt.option_kind === "commercial_product") {
        if (!opt.allowed_in_pl_indoor) {
          errors.push(
            `Commercial product option '${opt.option_id}' on '${cond.condition_id}' is not approved for indoor use in Poland.`,
          );
        }
        const verifiedMs = Date.parse(opt.verified_at);
        const validUntilMs = Date.parse(opt.valid_until);
        const maxWindowMs = 30 * 24 * 60 * 60 * 1000;
        if (
          Number.isNaN(verifiedMs) ||
          Number.isNaN(validUntilMs) ||
          validUntilMs <= now.getTime() ||
          validUntilMs - verifiedMs > maxWindowMs
        ) {
          errors.push(
            `Commercial product option '${opt.option_id}' on '${cond.condition_id}' exceeds the 30-day freshness window or is expired.`,
          );
        }
      }
    }
  }

  if (errors.length > 0) {
    return {
      valid: false,
      releaseState: "quarantined",
      errors,
      publishedPlantCount: publishedPlants.length,
      publishedConditionCount: publishedConditions.length,
      publicCatalogueProjection: [],
    };
  }

  return {
    valid: true,
    releaseState: "published",
    errors: [],
    publishedPlantCount: publishedPlants.length,
    publishedConditionCount: publishedConditions.length,
    publicCatalogueProjection: publishedPlants.map(buildPublicCatalogueProjection),
  };
}

/**
 * T147: Projects and validates a basic catalogue skeleton release (`catalogue-skeleton-1.1`)
 * independently of any `kb_releases` or `ConditionProfile` records.
 */
export function projectCatalogueSkeletonCard(
  plant: CatalogueSkeletonPlantRecord,
  locale: "en" | "pl" = "en",
): PublicCatalogueSkeletonCard {
  const locNames = plant.common_names?.[locale] ?? [];
  const primaryCommon = locNames.find((n) => n?.name?.trim())?.name?.trim() ?? null;
  const localizedDesc =
    (plant.descriptions?.[locale]?.text?.trim() ? plant.descriptions[locale] : null) ??
    plant.descriptions.en;
  const sciName = plant.scientific_name.trim();
  const genus = plant.genus?.trim() || sciName.split(/\s+/)[0] || sciName;

  return {
    taxon_id: plant.taxon_id ?? null,
    plant_id: plant.plant_id,
    scientific_name: sciName,
    accepted_scientific_name: sciName,
    scientific_name_status: plant.scientific_name_status,
    wikidata_id: plant.wikidata_id ?? null,
    rank: plant.rank ?? "species",
    genus,
    family: plant.family?.trim() || "unknown",
    external_taxon_ids: structuredClone(plant.external_taxon_ids ?? {}),
    localized_name: primaryCommon,
    display_name: primaryCommon ?? sciName,
    common_names: structuredClone(plant.common_names),
    search_aliases: structuredClone(plant.search_aliases),
    description: structuredClone(localizedDesc),
    descriptions: structuredClone(plant.descriptions),
    hero_image: structuredClone(plant.hero_image),
    watering: structuredClone(plant.watering),
    care_profile_available: plant.care_profile_available,
    safety: {
      cat: { status: "unknown" },
      dog: { status: "unknown" },
    },
    name_source: plant.name_source ? structuredClone(plant.name_source) : null,
  };
}

/**
 * Validates that a projected card (from either TS `projectCatalogueSkeletonCard`
 * or SQL `project_catalogue_species_card`) matches the canonical 21-field DTO contract.
 */
export function validateCatalogueSkeletonCardContract(card: unknown): string[] {
  const errors: string[] = [];
  if (!isPlainObject(card)) {
    return ["Card must be a non-null object."];
  }
  if (!validateCardSchema(card)) {
    for (const error of validateCardSchema.errors ?? []) {
      errors.push(`Card schema ${error.instancePath}: ${error.message}`);
    }
  }
  const obj = card;
  const plantId = typeof obj.plant_id === "string" && obj.plant_id ? obj.plant_id : "unknown";
  for (const key of CANONICAL_CARD_KEYS) {
    if (!(key in obj)) {
      errors.push(`Card is missing required key '${key}'.`);
    }
  }
  for (const key of Object.keys(obj)) {
    if (!(CANONICAL_CARD_KEYS as readonly string[]).includes(key)) {
      errors.push(`Card contains unexpected key '${key}'.`);
    }
  }
  if (obj.taxon_id !== null && (typeof obj.taxon_id !== "string" || !UUID_REGEX.test(obj.taxon_id))) {
    errors.push(`Invalid card.taxon_id '${String(obj.taxon_id)}'.`);
  }
  if (typeof obj.plant_id !== "string" || !PLANT_ID_REGEX.test(obj.plant_id)) {
    errors.push(`Invalid card.plant_id '${String(obj.plant_id)}'.`);
  }
  if (typeof obj.scientific_name !== "string" || !obj.scientific_name.trim()) {
    errors.push("Invalid card.scientific_name.");
  }
  if (obj.accepted_scientific_name !== obj.scientific_name) {
    errors.push("card.accepted_scientific_name must match card.scientific_name.");
  }
  if (typeof obj.scientific_name_status !== "string" || !obj.scientific_name_status.trim()) {
    errors.push("Invalid card.scientific_name_status.");
  }
  if (typeof obj.wikidata_id !== "string" || !WIKIDATA_ID_REGEX.test(obj.wikidata_id)) {
    errors.push(`Invalid card.wikidata_id '${String(obj.wikidata_id)}'.`);
  }
  if (typeof obj.rank !== "string" || !ALLOWED_RANKS.has(obj.rank)) {
    errors.push(`Invalid card.rank '${String(obj.rank)}'.`);
  }
  if (typeof obj.genus !== "string" || !obj.genus.trim()) {
    errors.push("Invalid card.genus.");
  }
  if (typeof obj.family !== "string" || !obj.family.trim()) {
    errors.push("Invalid card.family.");
  }
  errors.push(...validateExternalTaxonIds(plantId, obj.external_taxon_ids));
  if (
    obj.localized_name !== null &&
    (typeof obj.localized_name !== "string" || !obj.localized_name.trim())
  ) {
    errors.push("Invalid card.localized_name.");
  }
  if (typeof obj.display_name !== "string" || !obj.display_name.trim()) {
    errors.push("Invalid card.display_name.");
  } else if (obj.display_name !== (obj.localized_name ?? obj.scientific_name)) {
    errors.push("card.display_name must equal card.localized_name ?? card.scientific_name.");
  }
  errors.push(...validateCommonNames(plantId, obj.common_names));
  errors.push(...validateSearchAliases(plantId, obj.search_aliases));
  errors.push(...validateDescriptionEntry(plantId, "card.description", null, obj.description));
  if (!isPlainObject(obj.descriptions)) {
    errors.push("card.descriptions must be an object with 'en' and 'pl' entries.");
  } else {
    errors.push(
      ...validateDescriptionEntry(plantId, "card.descriptions.en", "en", obj.descriptions.en),
    );
    if (obj.descriptions.pl !== null) {
      errors.push(
        ...validateDescriptionEntry(plantId, "card.descriptions.pl", "pl", obj.descriptions.pl),
      );
    }
  }
  errors.push(...validateHeroImageEntry(plantId, obj.hero_image));
  errors.push(...validateWateringEntry(plantId, obj.watering));
  if (typeof obj.care_profile_available !== "boolean") {
    errors.push("card.care_profile_available must be a boolean.");
  }
  const safety = obj.safety;
  if (!isPlainObject(safety)) {
    errors.push("card.safety must be an object.");
  } else {
    for (const pet of ["cat", "dog"] as const) {
      const petObj = safety[pet];
      if (!isPlainObject(petObj) || !["safe", "toxic", "unknown"].includes(String(petObj.status))) {
        errors.push(`card.safety.${pet}.status must be 'safe' | 'toxic' | 'unknown'.`);
      }
    }
  }
  if (obj.name_source !== null && !isPlainObject(obj.name_source)) {
    errors.push("card.name_source must be an object or null.");
  }
  return errors;
}

export function validateAndProjectSkeletonRelease(
  bundle: CatalogueSkeletonBundle,
  options: { minSpeciesCount?: number; locale?: "en" | "pl" } = {},
): SkeletonValidationResult {
  const errors: string[] = [];
  const minCount = options.minSpeciesCount ?? 0;
  const locale = options.locale ?? "en";

  if (
    bundle.schema_version !== "catalogue-skeleton-1.1" &&
    bundle.schema_version !== "catalogue-skeleton-1.0"
  ) {
    errors.push(`Unsupported skeleton schema_version '${bundle.schema_version}'.`);
  }

  if (!Array.isArray(bundle.plants) || bundle.plants.length < minCount) {
    errors.push(
      `Skeleton species count ${bundle.plants?.length ?? 0} is below required minimum ${minCount}.`,
    );
  }

  const seenPlantIds = new Set<string>();
  const seenWikidataIds = new Set<string>();
  const seenScientificNames = new Set<string>();

  for (const plant of bundle.plants ?? []) {
    const pid = plant?.plant_id ?? "unknown";
    if (!validateRecordSchema(plant)) {
      for (const error of validateRecordSchema.errors ?? []) {
        errors.push(`Plant '${pid}' schema ${error.instancePath}: ${error.message}`);
      }
      if (!isPlainObject(plant)) continue;
    }
    if (typeof plant.plant_id !== "string" || !PLANT_ID_REGEX.test(plant.plant_id)) {
      errors.push(`Invalid plant_id '${String(plant.plant_id)}'.`);
    }
    if (seenPlantIds.has(plant.plant_id)) {
      errors.push(`Duplicate plant_id '${plant.plant_id}'.`);
    }
    seenPlantIds.add(plant.plant_id);

    if (
      typeof plant.wikidata_id !== "string" ||
      !WIKIDATA_ID_REGEX.test(plant.wikidata_id) ||
      seenWikidataIds.has(plant.wikidata_id)
    ) {
      errors.push(`Invalid, duplicate, or missing wikidata_id on '${pid}'.`);
    }
    seenWikidataIds.add(plant.wikidata_id);

    if (!isPositiveInteger(plant.source_revision)) {
      errors.push(`Plant '${pid}' has invalid source_revision.`);
    }

    const sciNorm = typeof plant.scientific_name === "string" ? plant.scientific_name.trim().toLowerCase() : "";
    if (!sciNorm || seenScientificNames.has(sciNorm)) {
      errors.push(`Duplicate or missing scientific_name on '${pid}'.`);
    }
    seenScientificNames.add(sciNorm);

    if (typeof plant.scientific_name_status !== "string" || !plant.scientific_name_status.trim()) {
      errors.push(`Plant '${pid}' is missing scientific_name_status.`);
    }
    if (plant.rank !== undefined && !ALLOWED_RANKS.has(plant.rank)) {
      errors.push(`Plant '${pid}' has invalid rank '${String(plant.rank)}'.`);
    }
    if (plant.family !== undefined && (typeof plant.family !== "string" || !plant.family.trim())) {
      errors.push(`Plant '${pid}' has invalid family.`);
    }
    if (typeof plant.care_profile_available !== "boolean") {
      errors.push(`Plant '${pid}' care_profile_available must be a boolean.`);
    }

    errors.push(...validateExternalTaxonIds(pid, plant.external_taxon_ids));
    errors.push(...validateCommonNames(pid, plant.common_names));
    errors.push(...validateSearchAliases(pid, plant.search_aliases));

    for (const lang of ["en", "pl"] as const) {
      const desc = plant.descriptions?.[lang];
      if (lang === "pl" && desc === null) continue;
      if (!desc || typeof desc !== "object") {
        errors.push(`Plant '${pid}' is missing ${lang.toUpperCase()} description.`);
        continue;
      }
      errors.push(...validateDescriptionEntry(pid, `descriptions.${lang}`, lang, desc));
    }

    errors.push(...validateHeroImageEntry(pid, plant.hero_image));
    errors.push(...validateWateringEntry(pid, plant.watering));
  }

  if (errors.length > 0) {
    return {
      valid: false,
      releaseVersion: bundle.version,
      kbReleaseId: null,
      speciesCount: bundle.plants?.length ?? 0,
      errors,
      cards: [],
    };
  }

  const cards = bundle.plants.map((p) => projectCatalogueSkeletonCard(p, locale));
  for (const card of cards) {
    errors.push(...validateCatalogueSkeletonCardContract(card));
  }
  if (errors.length > 0) {
    return {
      valid: false,
      releaseVersion: bundle.version,
      kbReleaseId: null,
      speciesCount: bundle.plants.length,
      errors,
      cards: [],
    };
  }

  return {
    valid: true,
    releaseVersion: bundle.version,
    kbReleaseId: null,
    speciesCount: bundle.plants.length,
    errors: [],
    cards,
  };
}
