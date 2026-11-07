// supabase/functions/_shared/AnalysisValidator.ts
// T032 & T029: Canonical Schema 3.0 + KB release semantic validator for Vision classifications.
// Rejects any generated advice/products/plans/questions, enforces closed plant/condition/marker IDs,
// distinct ranks 1..2, confidence in [0,1], and marks unsuitable/out-of-scope or invalid outputs non-billable.

import Ajv2020Module from "ajv/dist/2020";
import {
  CANONICAL_CONDITION_ID_SET,
  CANONICAL_LIMITATION_CODE_SET,
  CanonicalConditionId,
  PublishedReleaseCatalog,
  ValidationOutcome,
  VisionClassification30,
} from "./KnowledgeTypes.ts";

// deno-lint-ignore no-explicit-any
const Ajv2020: any = (Ajv2020Module as any).default ?? Ajv2020Module;

const schemaUrl = new URL(
  "../../../specs/001-plants-ios-mvp/contracts/ai-result.schema.json",
  import.meta.url,
);
const canonicalAiResultSchema = JSON.parse(Deno.readTextFileSync(schemaUrl));

const ajv = new Ajv2020({ allErrors: true, strict: false });
const validateJsonSchema = ajv.compile(canonicalAiResultSchema);

export interface ValidatedAnalysisClassification {
  valid: boolean;
  errors: string[];
  classification: VisionClassification30 | null;
  shouldConsumeQuota: boolean;
  nonBillableReason?:
    | "invalid_schema_or_semantics"
    | "unsuitable_image_quality"
    | "out_of_scope";
}

export class AnalysisValidator {
  static validate(
    rawOutput: unknown,
    catalog: PublishedReleaseCatalog,
  ): ValidatedAnalysisClassification {
    const errors: string[] = [];

    if (!rawOutput || typeof rawOutput !== "object") {
      return {
        valid: false,
        errors: ["Classification output must be a JSON object."],
        classification: null,
        shouldConsumeQuota: false,
        nonBillableReason: "invalid_schema_or_semantics",
      };
    }

    const schemaOk = validateJsonSchema(rawOutput);
    if (!schemaOk) {
      for (const err of validateJsonSchema.errors ?? []) {
        errors.push(`${err.instancePath || "/"}: ${err.message ?? "schema violation"}`);
      }
      return {
        valid: false,
        errors,
        classification: null,
        shouldConsumeQuota: false,
        nonBillableReason: "invalid_schema_or_semantics",
      };
    }

    const data = rawOutput as VisionClassification30;

    // 1. Pinned kb_release_id check
    if (data.kb_release_id.toLowerCase() !== catalog.kbReleaseId.toLowerCase()) {
      errors.push(
        `kb_release_id '${data.kb_release_id}' does not match pinned release '${catalog.kbReleaseId}'.`,
      );
    }

    // 2. Closed limitation codes check
    for (const lim of data.limitations) {
      if (!CANONICAL_LIMITATION_CODE_SET.has(lim)) {
        errors.push(`Unknown limitation code '${lim}'.`);
      }
    }

    // 3. Identification membership checks
    if (data.identification.status === "identified") {
      if (!data.identification.plant_id || !catalog.plantIds.has(data.identification.plant_id)) {
        errors.push(
          `Identified plant_id '${data.identification.plant_id}' is not in published KB release.`,
        );
      }
      if (!data.identification.genus_id || !catalog.genusIds.has(data.identification.genus_id)) {
        errors.push(
          `Identified genus_id '${data.identification.genus_id}' is not in published KB release.`,
        );
      }
    } else if (data.identification.status === "genus_only") {
      if (data.identification.plant_id !== null) {
        errors.push("genus_only status requires plant_id to be null.");
      }
      if (!data.identification.genus_id || !catalog.genusIds.has(data.identification.genus_id)) {
        errors.push(
          `genus_only genus_id '${data.identification.genus_id}' is not in published KB release.`,
        );
      }
    } else {
      if (data.identification.plant_id !== null || data.identification.genus_id !== null) {
        errors.push(
          `Identification status '${data.identification.status}' requires plant_id and genus_id to be null.`,
        );
      }
    }

    // 4. Mode-specific & Diagnosis candidate / visual_markers checks
    if (data.mode === "identification") {
      if (data.diagnosis !== null) {
        errors.push("mode='identification' requires diagnosis to be null.");
      }
      if (data.comparison !== null) {
        errors.push("mode='identification' requires comparison to be null.");
      }
      if (data.visual_markers.length > 0) {
        errors.push("mode='identification' requires visual_markers to be empty.");
      }
    } else {
      if (!data.diagnosis) {
        errors.push(`mode='${data.mode}' requires a non-null diagnosis object.`);
      } else if (data.diagnosis.status === "problem_detected") {
        const candidates = data.diagnosis.candidates;
        if (candidates.length < 1 || candidates.length > 2) {
          errors.push("diagnosis.status='problem_detected' requires 1 or 2 candidates.");
        }

        const allowedVisualMarkers = new Set<string>();
        const seenConditions = new Set<string>();

        for (let i = 0; i < candidates.length; i++) {
          const cand = candidates[i];
          const expectedRank = i + 1;
          if (cand.rank !== expectedRank) {
            errors.push(
              `Candidate at index ${i} must have rank=${expectedRank}, got ${cand.rank}.`,
            );
          }
          if (
            typeof cand.confidence !== "number" ||
            Number.isNaN(cand.confidence) ||
            cand.confidence < 0 ||
            cand.confidence > 1
          ) {
            errors.push(`Candidate '${cand.condition_id}' has invalid confidence ${cand.confidence}.`);
          }
          if (i > 0 && cand.confidence > candidates[i - 1].confidence) {
            errors.push("Candidates must be ordered by non-increasing confidence.");
          }
          if (seenConditions.has(cand.condition_id)) {
            errors.push(`Duplicate candidate condition_id '${cand.condition_id}'.`);
          }
          seenConditions.add(cand.condition_id);

          if (!CANONICAL_CONDITION_ID_SET.has(cand.condition_id)) {
            errors.push(`Candidate condition_id '${cand.condition_id}' is not in the closed 40 set.`);
          } else {
            const profile = catalog.conditionProfiles.get(
              cand.condition_id as CanonicalConditionId,
            );
            if (!profile) {
              errors.push(
                `Candidate condition_id '${cand.condition_id}' is not published in KB release '${catalog.kbReleaseId}'.`,
              );
            } else {
              for (const marker of profile.visual_markers) {
                allowedVisualMarkers.add(marker);
              }
            }
          }
        }

        for (const marker of data.visual_markers) {
          if (!allowedVisualMarkers.has(marker)) {
            errors.push(
              `visual_marker '${marker}' does not belong to the published ConditionProfile(s) of the candidate(s).`,
            );
          }
        }
      } else {
        if (data.diagnosis.candidates.length > 0) {
          errors.push(
            `diagnosis.status='${data.diagnosis.status}' requires candidates to be empty.`,
          );
        }
        if (data.visual_markers.length > 0) {
          errors.push(
            `diagnosis.status='${data.diagnosis.status}' requires visual_markers to be empty.`,
          );
        }
      }

      if (data.mode === "follow_up") {
        if (!data.comparison) {
          errors.push("mode='follow_up' requires a non-null comparison object.");
        } else if (catalog.knownTraitIds) {
          for (const ch of data.comparison.changes) {
            if (!catalog.knownTraitIds.has(ch.symptom_id)) {
              errors.push(`Unknown comparison symptom_id '${ch.symptom_id}'.`);
            }
          }
        }
      } else if (data.comparison !== null) {
        errors.push("mode='diagnosis' requires comparison to be null.");
      }
    }

    if (errors.length > 0) {
      return {
        valid: false,
        errors,
        classification: null,
        shouldConsumeQuota: false,
        nonBillableReason: "invalid_schema_or_semantics",
      };
    }

    // Determine whether this valid classification should consume quota
    if (data.image_quality !== "usable") {
      return {
        valid: true,
        errors: [],
        classification: data,
        shouldConsumeQuota: false,
        nonBillableReason: "unsuitable_image_quality",
      };
    }

    if (
      data.identification.status === "out_of_scope" ||
      data.diagnosis?.status === "out_of_scope"
    ) {
      return {
        valid: true,
        errors: [],
        classification: data,
        shouldConsumeQuota: false,
        nonBillableReason: "out_of_scope",
      };
    }

    return {
      valid: true,
      errors: [],
      classification: data,
      shouldConsumeQuota: true,
    };
  }
}
