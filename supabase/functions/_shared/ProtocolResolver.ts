// supabase/functions/_shared/ProtocolResolver.ts
// T116: Deterministic ProtocolResolver mapping validated Classification 3.0 + KB Golden Records
// into backend PreliminaryAnalysis projections and signed analysis_receipts.
// Never uses an LLM to generate advice. Enforces host scope, contraindications, treatment blocks,
// and explicit diagnosis status. Ambiguity never selects treatment by score or rank.

import {
  CanonicalConditionId,
  CanonicalConditionProfile,
  PublishedReleaseCatalog,
  VisionClassification30,
  validateConditionProfileSemantics,
} from "./KnowledgeTypes.ts";

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

// Explanations only: this catalog has no published basic-care fallback.
const NO_ACTION_LIMITATIONS = {
  pl: {
    healthy: "Nie wykryto problemu. Brak opublikowanego działania podstawowej pielęgnacji w tym wyniku.",
    outOfScope: "Wynik poza zakresem diagnostyki roślin domowych; brak zalecenia.",
    insufficient: "Za mało danych do wyboru odpowiedniego działania.",
    ambiguous: "Niejednoznaczny wynik; nie wybrano leczenia.",
    unavailable: "Brak opublikowanej, mającej zastosowanie pierwszej pomocy i terminu kontroli.",
  },
  en: {
    healthy: "No problem detected. No published basic-care action is provided in this result.",
    outOfScope: "Result is outside indoor houseplant diagnosis scope; no recommendation is available.",
    insufficient: "Insufficient data to select an applicable action.",
    ambiguous: "The result is ambiguous; no treatment has been selected.",
    unavailable: "No published, applicable first aid or check interval is available.",
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
    if (!validateConditionProfileSemantics(profile).valid) return false;
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
    const host: PlantHostContext = params.hostContext ?? { plantId: classification.identification.plant_id };
    const locale = classification.locale;
    const issuedAt = params.issuedAt ?? new Date().toISOString();
    const noAction = NO_ACTION_LIMITATIONS[locale];

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
    // The signed historical field remains stable; new results need no question revisions.
    const decisionRevision = 1;

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
        selected_condition_id: null,
        candidates: [],
        visual_markers: [],
        evidence_basis: [],
        limitations: [...classification.limitations, noAction.outOfScope],
        first_action_title: null,
        first_action_summary: null,
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
        selected_condition_id: null,
        candidates: [],
        visual_markers: [],
        evidence_basis: ["no_pathological_markers_detected"],
        limitations: [...classification.limitations, noAction.healthy],
        first_action_title: null,
        first_action_summary: null,
        control_interval_days: null,
        plan_availability: hasPlantProfile ? "missing_condition_profile" : "missing_plant_profile",
        analysis_receipt: receipt,
      };
    }

    // Two candidates remain ambiguous, even when only one is host-compatible.
    const candidate = diag.status === "problem_detected" && diag.candidates.length === 1
      ? diag.candidates[0]
      : null;
    const profile = candidate
      ? catalog.conditionProfiles.get(candidate.condition_id) ?? null
      : null;
    const hostCompatible = profile !== null &&
      ProtocolResolver.isConditionHostCompatible(profile, host) &&
      profile.condition_id === candidate?.condition_id &&
      profile.kb_release_id === catalog.kbReleaseId;
    // Host compatibility validates v2 before any compact fields are accessed.
    // Use only the published first-help entry point, never an arbitrary action.
    // Unconfirmed prerequisites cannot be inferred from a classification score.
    const activeContras = new Set(host.activeContraindicationIds ?? []);
    const firstHelpAction = hostCompatible && profile
      ? profile.actions.find((action) =>
        action.action_id === profile.first_help_action_id &&
        action.prerequisite_check_ids.length === 0 &&
        !action.contraindication_check_ids.some((id) => activeContras.has(id))
      )
      : undefined;

    if (profile && firstHelpAction) {
      const localizedContent = profile.condition_content_i18n[locale];
      const firstActionText = locale === "pl"
        ? firstHelpAction.action_pl
        : firstHelpAction.action_en;

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
        selected_condition_id: profile.condition_id,
        candidates: diag.candidates.map((c) => ({ ...c })),
        visual_markers: [...classification.visual_markers],
        evidence_basis: [...classification.visual_markers],
        limitations: [...classification.limitations],
        first_action_title: localizedContent.title,
        first_action_summary: firstActionText,
        control_interval_days: firstHelpAction.next_check_interval_days,
        plan_availability: "available",
        analysis_receipt: receipt,
      };
    }

    // Preserve a saveable signed result without inventing advice or a check date.
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
      selected_condition_id: null,
      candidates: diag.candidates.map((c) => ({ ...c })),
      visual_markers: [...classification.visual_markers],
      evidence_basis: [...classification.visual_markers],
      limitations: [
        ...classification.limitations,
        diag.status === "insufficient_data" ? noAction.insufficient
          : diag.candidates.length > 1 ? noAction.ambiguous : noAction.unavailable,
      ],
      first_action_title: null,
      first_action_summary: null,
      control_interval_days: null,
      plan_availability: candidate ? "missing_condition_profile" : "diagnosis_unresolved",
      analysis_receipt: receipt,
    };
  }
}
