// supabase/functions/_shared/ProtocolResolver.ts
// T116: Deterministic ProtocolResolver mapping validated Classification 3.0 + KB Golden Records
// into backend PreliminaryAnalysis projections and signed analysis_receipts.
// Never uses an LLM to generate advice. Enforces host scope, contraindications, treatment blocks,
// and decision state (resolved -> ConditionProfile first help; pending/uncertain -> safe fallback first help).

import {
  CanonicalConditionId,
  CanonicalConditionProfile,
  PublishedReleaseCatalog,
  VisionClassification30,
} from "./KnowledgeTypes.ts";

export type DecisionResolutionInputState = "resolved" | "pending" | "uncertain";

export interface DecisionStateDTO {
  revision: number;
  state: DecisionResolutionInputState;
  selectedConditionId: CanonicalConditionId | null;
}

export interface PlantHostContext {
  plantId: string | null;
  family?: string | null;
  potType?: string | null;
  lightLevel?: string | null;
  wateringHabit?: string | null;
  activeContraindicationIds?: string[];
  blockedConditionIds?: Set<string>;
}

export interface PreliminaryAnalysisProjection {
  analysis_id: string;
  job_id: string;
  kb_release_id: string;
  mode: "identification" | "diagnosis";
  locale: "pl" | "en";
  identification_status: "identified" | "genus_only" | "unknown" | "out_of_scope";
  plant_id: string | null;
  genus_id: string | null;
  diagnosis_status: "problem_detected" | "healthy" | "insufficient_data" | "out_of_scope" | null;
  decision_state: DecisionResolutionInputState | null;
  selected_condition_id: CanonicalConditionId | null;
  candidates: Array<{
    condition_id: CanonicalConditionId;
    rank: 1 | 2;
    confidence: number;
  }>;
  visual_markers: string[];
  evidence_basis: string[];
  limitations: string[];
  first_action_title: string | null;
  first_action_summary: string | null;
  control_interval_days: number | null;
  plan_availability:
    | "available"
    | "missing_plant_profile"
    | "missing_condition_profile"
    | "diagnosis_unresolved"
    | "context_stale";
  analysis_receipt: string;
}

// Historical GET/replay data only. Never feed a saved result back into classification.
export type LegacyPreliminaryAnalysisProjection =
  Omit<PreliminaryAnalysisProjection, "mode"> & { mode: "follow_up" };

const FALLBACK_SAFE_FIRST_AID = {
  pl: {
    healthyTitle: "Roślina wygląda na zdrową",
    healthyAction:
      "Kontynuuj regularną obserwację liści i sprawdzaj wilgotność podłoża przed kolejnym podlewaniem.",
    uncertainTitle: "Wymagana ostrożna obserwacja",
    uncertainAction:
      "Sprawdź wilgotność górnej warstwy podłoża palcem, ustaw roślinę w miejscu bez przeciągów i powstrzymaj się od nawożenia lub oprysków do czasu potwierdzenia objawów.",
    outOfScopeTitle: "Zdjęcie poza zakresem diagnostyki roślin domowych",
    outOfScopeAction:
      "Zrób wyraźne zdjęcie rośliny doniczkowej oraz widocznego objawu w świetle dziennym.",
  },
  en: {
    healthyTitle: "The plant appears healthy",
    healthyAction:
      "Continue observing the leaves and check top-layer soil moisture before the next watering.",
    uncertainTitle: "Cautious observation recommended",
    uncertainAction:
      "Check top-layer soil moisture with your finger, keep the plant away from drafts, and hold off on fertilizer or sprays until symptoms are confirmed.",
    outOfScopeTitle: "Photo is outside indoor houseplant scope",
    outOfScopeAction:
      "Take a clear daylight photo of your potted houseplant and the visible symptom.",
  },
} as const;

export async function signAnalysisReceipt(
  payload: {
    analysis_id: string;
    kb_release_id: string;
    mode: string;
    plant_id: string | null;
    selected_condition_id: string | null;
    decision_revision: number;
    issued_at: string;
  },
  secret: string,
): Promise<string> {
  const canonical = JSON.stringify({
    analysis_id: payload.analysis_id,
    kb_release_id: payload.kb_release_id,
    mode: payload.mode,
    plant_id: payload.plant_id,
    selected_condition_id: payload.selected_condition_id,
    decision_revision: payload.decision_revision,
    issued_at: payload.issued_at,
  });
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sigBuffer = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(canonical),
  );
  const sigHex = Array.from(new Uint8Array(sigBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  const bodyB64 = btoa(canonical);
  return `${bodyB64}.${sigHex}`;
}

export async function verifyAnalysisReceipt(
  receipt: string,
  secret: string,
): Promise<{
  valid: boolean;
  payload?: {
    analysis_id: string;
    kb_release_id: string;
    mode: string;
    plant_id: string | null;
    selected_condition_id: string | null;
    decision_revision: number;
    issued_at: string;
  };
}> {
  const parts = receipt.split(".");
  if (parts.length !== 2) return { valid: false };
  try {
    const jsonStr = atob(parts[0]);
    const parsed = JSON.parse(jsonStr);
    const expected = await signAnalysisReceipt(parsed, secret);
    if (expected !== receipt) {
      return { valid: false };
    }
    return { valid: true, payload: parsed };
  } catch {
    return { valid: false };
  }
}

export class ProtocolResolver {
  static isConditionHostCompatible(
    profile: CanonicalConditionProfile,
    host: PlantHostContext,
  ): boolean {
    if (host.blockedConditionIds?.has(profile.condition_id)) {
      return false;
    }
    const activeContras = new Set(host.activeContraindicationIds ?? []);
    for (const contra of profile.contraindication_check_ids) {
      if (activeContras.has(contra)) {
        return false;
      }
    }
    if (profile.host_scope.general_houseplants) {
      return true;
    }
    if (host.plantId && profile.host_scope.plant_ids.includes(host.plantId)) {
      return true;
    }
    if (host.family && profile.host_scope.families.includes(host.family)) {
      return true;
    }
    return false;
  }

  static async resolvePreliminaryProjection(params: {
    analysisId: string;
    jobId: string;
    classification: VisionClassification30;
    catalog: PublishedReleaseCatalog;
    hostContext?: PlantHostContext;
    decisionState?: DecisionStateDTO;
    signingSecret: string;
    issuedAt?: string;
  }): Promise<PreliminaryAnalysisProjection> {
    const {
      analysisId,
      jobId,
      classification,
      catalog,
      signingSecret,
    } = params;
    if (classification.mode !== "identification" && classification.mode !== "diagnosis") {
      throw new Error("Unsupported analysis mode.");
    }
    const host = params.hostContext ?? { plantId: classification.identification.plant_id };
    const locale = classification.locale;
    const issuedAt = params.issuedAt ?? new Date().toISOString();
    const fallbackStrings = FALLBACK_SAFE_FIRST_AID[locale];

    const hasPlantProfile = Boolean(
      classification.identification.plant_id &&
        catalog.plantIds.has(classification.identification.plant_id),
    );

    // 1. Identification-only mode (Care scan)
    if (classification.mode === "identification") {
      const receipt = await signAnalysisReceipt(
        {
          analysis_id: analysisId,
          kb_release_id: catalog.kbReleaseId,
          mode: classification.mode,
          plant_id: classification.identification.plant_id,
          selected_condition_id: null,
          decision_revision: 1,
          issued_at: issuedAt,
        },
        signingSecret,
      );

      return {
        analysis_id: analysisId,
        job_id: jobId,
        kb_release_id: catalog.kbReleaseId,
        mode: "identification",
        locale,
        identification_status: classification.identification.status,
        plant_id: classification.identification.plant_id,
        genus_id: classification.identification.genus_id,
        diagnosis_status: null,
        decision_state: null,
        selected_condition_id: null,
        candidates: [],
        visual_markers: [],
        evidence_basis: [],
        limitations: [...classification.limitations],
        first_action_title: null,
        first_action_summary: null,
        control_interval_days: null,
        plan_availability: hasPlantProfile ? "available" : "missing_plant_profile",
        analysis_receipt: receipt,
      };
    }

    // 2. Diagnosis mode (including a new photo of the same plant)
    const diag = classification.diagnosis!;
    const decisionRevision = params.decisionState?.revision ?? 1;

    // Determine effective decision state from explicit DTO or top-2 confidence routing rules (threshold 0.80, gap 0.10)
    let effectiveDecisionState: DecisionResolutionInputState = "uncertain";
    let selectedConditionId: CanonicalConditionId | null = null;

    if (params.decisionState) {
      effectiveDecisionState = params.decisionState.state;
      selectedConditionId = params.decisionState.selectedConditionId;
    } else if (diag.status === "problem_detected" && diag.candidates.length > 0) {
      const top1 = diag.candidates[0];
      const top2 = diag.candidates[1];
      const gap = top2 ? top1.confidence - top2.confidence : top1.confidence;
      if (top1.confidence >= 0.8 && gap >= 0.1) {
        effectiveDecisionState = "resolved";
        selectedConditionId = top1.condition_id;
      } else {
        effectiveDecisionState = "pending";
        selectedConditionId = null;
      }
    }

    if (diag.status === "out_of_scope" || classification.identification.status === "out_of_scope") {
      const receipt = await signAnalysisReceipt(
        {
          analysis_id: analysisId,
          kb_release_id: catalog.kbReleaseId,
          mode: classification.mode,
          plant_id: null,
          selected_condition_id: null,
          decision_revision: decisionRevision,
          issued_at: issuedAt,
        },
        signingSecret,
      );

      return {
        analysis_id: analysisId,
        job_id: jobId,
        kb_release_id: catalog.kbReleaseId,
        mode: classification.mode,
        locale,
        identification_status: classification.identification.status,
        plant_id: null,
        genus_id: null,
        diagnosis_status: "out_of_scope",
        decision_state: "uncertain",
        selected_condition_id: null,
        candidates: [],
        visual_markers: [],
        evidence_basis: [],
        limitations: [...classification.limitations],
        first_action_title: fallbackStrings.outOfScopeTitle,
        first_action_summary: fallbackStrings.outOfScopeAction,
        control_interval_days: null,
        plan_availability: "diagnosis_unresolved",
        analysis_receipt: receipt,
      };
    }

    if (diag.status === "healthy") {
      const receipt = await signAnalysisReceipt(
        {
          analysis_id: analysisId,
          kb_release_id: catalog.kbReleaseId,
          mode: classification.mode,
          plant_id: classification.identification.plant_id,
          selected_condition_id: null,
          decision_revision: decisionRevision,
          issued_at: issuedAt,
        },
        signingSecret,
      );

      return {
        analysis_id: analysisId,
        job_id: jobId,
        kb_release_id: catalog.kbReleaseId,
        mode: classification.mode,
        locale,
        identification_status: classification.identification.status,
        plant_id: classification.identification.plant_id,
        genus_id: classification.identification.genus_id,
        diagnosis_status: "healthy",
        decision_state: "resolved",
        selected_condition_id: null,
        candidates: [],
        visual_markers: [],
        evidence_basis: ["no_pathological_markers_detected"],
        limitations: [...classification.limitations],
        first_action_title: fallbackStrings.healthyTitle,
        first_action_summary: fallbackStrings.healthyAction,
        control_interval_days: null,
        plan_availability: hasPlantProfile ? "available" : "missing_plant_profile",
        analysis_receipt: receipt,
      };
    }

    // Check if resolved condition is present and host-compatible
    const profile = selectedConditionId
      ? catalog.conditionProfiles.get(selectedConditionId) ?? null
      : null;

    const hostCompatible = profile
      ? ProtocolResolver.isConditionHostCompatible(profile, host)
      : false;

    if (effectiveDecisionState === "resolved" && profile && hostCompatible) {
      const firstHelpStep = profile.treatment_plan.steps.find(
        (s) => s.step_id === profile.first_help_step_id,
      ) ?? profile.treatment_plan.steps[0];

      const localizedContent = profile.condition_content_i18n[locale];
      const firstActionText = locale === "pl"
        ? firstHelpStep.action_pl
        : firstHelpStep.action_en;

      const receipt = await signAnalysisReceipt(
        {
          analysis_id: analysisId,
          kb_release_id: catalog.kbReleaseId,
          mode: classification.mode,
          plant_id: classification.identification.plant_id,
          selected_condition_id: profile.condition_id,
          decision_revision: decisionRevision,
          issued_at: issuedAt,
        },
        signingSecret,
      );

      return {
        analysis_id: analysisId,
        job_id: jobId,
        kb_release_id: catalog.kbReleaseId,
        mode: classification.mode,
        locale,
        identification_status: classification.identification.status,
        plant_id: classification.identification.plant_id,
        genus_id: classification.identification.genus_id,
        diagnosis_status: "problem_detected",
        decision_state: "resolved",
        selected_condition_id: profile.condition_id,
        candidates: diag.candidates.map((c) => ({ ...c })),
        visual_markers: [...classification.visual_markers],
        evidence_basis: [...classification.visual_markers],
        limitations: [...classification.limitations],
        first_action_title: localizedContent.title,
        first_action_summary: firstActionText,
        control_interval_days: profile.recovery_check.check_offset_days,
        plan_availability: "available",
        analysis_receipt: receipt,
      };
    }

    // Pending / uncertain / host-incompatible / unknown -> safe non-destructive fallback first aid
    const receipt = await signAnalysisReceipt(
      {
        analysis_id: analysisId,
        kb_release_id: catalog.kbReleaseId,
        mode: classification.mode,
        plant_id: classification.identification.plant_id,
        selected_condition_id: null,
        decision_revision: decisionRevision,
        issued_at: issuedAt,
      },
      signingSecret,
    );

    return {
      analysis_id: analysisId,
      job_id: jobId,
      kb_release_id: catalog.kbReleaseId,
      mode: classification.mode,
      locale,
      identification_status: classification.identification.status,
      plant_id: classification.identification.plant_id,
      genus_id: classification.identification.genus_id,
      diagnosis_status: diag.status,
      decision_state: effectiveDecisionState === "pending" ? "pending" : "uncertain",
      selected_condition_id: null,
      candidates: diag.candidates.map((c) => ({ ...c })),
      visual_markers: [...classification.visual_markers],
      evidence_basis: [...classification.visual_markers],
      limitations: [...classification.limitations],
      first_action_title: fallbackStrings.uncertainTitle,
      first_action_summary: fallbackStrings.uncertainAction,
      control_interval_days: null,
      plan_availability: profile && !hostCompatible
        ? "missing_condition_profile"
        : "diagnosis_unresolved",
      analysis_receipt: receipt,
    };
  }
}
