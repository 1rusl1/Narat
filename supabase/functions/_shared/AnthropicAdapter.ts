// supabase/functions/_shared/AnthropicAdapter.ts
// T032: Classification-only AnthropicAdapter pinned to claude-haiku-5-5 with 40s timeout and maxRetries=0.
// Uses separate prompts for identification vs diagnosis, enforces stop_reason === 'end_turn',
// validates against AnalysisValidator (Schema 3.0 + KB membership), and delegates advice/receipts to ProtocolResolver.

import Anthropic from "@anthropic-ai/sdk";
import {
  AnalysisValidator,
  ValidatedAnalysisClassification,
} from "./AnalysisValidator.ts";
import {
  PublishedReleaseCatalog,
  VisionClassification30,
} from "./KnowledgeTypes.ts";
import {
  PreliminaryAnalysisProjection,
  ProtocolResolver,
} from "./ProtocolResolver.ts";

export const PINNED_ANTHROPIC_MODEL = "claude-haiku-5-5";
export const PROVIDER_CALL_TIMEOUT_MS = 40_000;

export interface AnthropicClassificationInput {
  analysisId: string;
  jobId: string;
  mode: "identification" | "diagnosis";
  locale: "pl" | "en";
  imageBase64: string;
  mediaType: "image/jpeg" | "image/png" | "image/webp";
  careContext?: {
    light_level: string;
    watering_habit: string;
    last_watered: string;
    pot_type?: string;
    season_override?: string;
  };
  catalog: PublishedReleaseCatalog;
  signingSecret: string;
  signal?: AbortSignal;
}

export interface AnthropicAdapterResult {
  ok: boolean;
  stopReason?: string | null;
  validation?: ValidatedAnalysisClassification;
  projection?: PreliminaryAnalysisProjection;
  shouldConsumeQuota: boolean;
  errorCode?:
    | "UNSUPPORTED_ANALYSIS_MODE"
    | "PROVIDER_REFUSAL"
    | "PROVIDER_TRUNCATED"
    | "PROVIDER_INVALID_JSON"
    | "SCHEMA_VALIDATION_FAILED"
    | "PROVIDER_TIMEOUT_OR_ERROR";
  errorMessage?: string;
}

export interface AnthropicMessagesClient {
  create(params: {
    model: string;
    max_tokens: number;
    output_config: { effort: "low" };
    system: string;
    messages: Array<{
      role: "user";
      content: Array<
        | {
          type: "image";
          source: {
            type: "base64";
            media_type: "image/jpeg" | "image/png" | "image/webp";
            data: string;
          };
        }
        | { type: "text"; text: string }
      >;
    }>;
  }, options?: { signal?: AbortSignal }): Promise<{
    stop_reason: string | null;
    content: Array<{ type: string; text?: string }>;
  }>;
}

export function buildSystemPrompt(
  mode: "identification" | "diagnosis",
  kbReleaseId: string,
  locale: "pl" | "en",
): string {
  if (mode !== "identification" && mode !== "diagnosis") {
    throw new Error("Unsupported analysis mode.");
  }
  if (mode === "identification") {
    return [
      `You are a strict botanical species classifier for indoor houseplants (schema_version="3.0", kb_release_id="${kbReleaseId}", mode="identification", locale="${locale}").`,
      "Perform ONLY species/genus identification using closed KB plant_id and genus_id identifiers.",
      "Set diagnosis=null and visual_markers=[].",
      "Do NOT diagnose diseases, do NOT generate care advice, plans, product names, or clarifying questions.",
      "Use output_shape as the required fields. Choose only IDs in allowed_plants, allowed_genera and allowed_conditions.",
    "For a usable image use image_quality=usable, otherwise blurred, too_dark or not_a_plant. Use unknown or out_of_scope identification if necessary.",
    "Return ONLY a single valid JSON object conforming to Classification 3.0.",
    ].join(" ");
  }

  return [
    `You are a strict plant pathology visual classifier (schema_version="3.0", kb_release_id="${kbReleaseId}", mode="diagnosis", locale="${locale}").`,
    "Classify species/genus, up to 2 candidate condition_ids from the closed 40 condition IDs with rank (1..2) and confidence (0..1), and visual_markers from the published ConditionProfile.",
    "Do NOT generate care advice, first-aid text, plans, product names, or clarifying questions.",
    "Use output_shape as the required fields. Choose only IDs in allowed_plants, allowed_genera and allowed_conditions.",
    "For a usable image use image_quality=usable, otherwise blurred, too_dark or not_a_plant. Use unknown or out_of_scope identification if necessary.",
    "For diagnosis use problem_detected with ranked candidates only for a supported visible issue within the condition's host scope.",
    "Do not infer moisture from leaf yellowing alone. Use healthy when no problem is visible or insufficient_data when the evidence is insufficient. Use out_of_scope for non-plants. Leave limitations empty unless single_angle is applicable.",
    "Return ONLY a single valid JSON object conforming to Classification 3.0.",
  ].join(" ");
}

export class AnthropicAdapter {
  private readonly messagesClient: AnthropicMessagesClient;

  constructor(messagesClient?: AnthropicMessagesClient, apiKey?: string) {
    if (messagesClient) {
      this.messagesClient = messagesClient;
    } else {
      const sdk = new Anthropic({
        apiKey: apiKey ?? Deno.env.get("ANTHROPIC_API_KEY") ?? "missing-key",
        maxRetries: 0,
        timeout: PROVIDER_CALL_TIMEOUT_MS,
      });
      this.messagesClient = sdk.messages as unknown as AnthropicMessagesClient;
    }
  }

  async classifyAndResolve(
    input: AnthropicClassificationInput,
  ): Promise<AnthropicAdapterResult> {
    // Inputs crossing an adapter boundary still require runtime validation.
    if (input.mode !== "identification" && input.mode !== "diagnosis") {
      return {
        ok: false,
        shouldConsumeQuota: false,
        errorCode: "UNSUPPORTED_ANALYSIS_MODE",
        errorMessage: "Unsupported analysis mode.",
      };
    }
    const systemPrompt = buildSystemPrompt(
      input.mode,
      input.catalog.kbReleaseId,
      input.locale,
    );

    const contextPayload = {
      kb_release_id: input.catalog.kbReleaseId,
      mode: input.mode,
      locale: input.locale,
      care_context: input.careContext ?? null,
      allowed_plants: Array.from(input.catalog.plantIds, (id) =>
        [id, input.catalog.plantScientificNames?.get(id) ?? id]),
      allowed_genera: Array.from(input.catalog.genusIds),
      allowed_conditions: input.mode === "diagnosis"
        ? Array.from(input.catalog.conditionProfiles.values(), (profile) =>
          ({
            condition_id: profile.condition_id, visual_markers: profile.visual_markers,
            host_scope: profile.host_scope,
          }))
        : [],
      output_shape: {
        schema_version: "3.0",
        kb_release_id: input.catalog.kbReleaseId,
        mode: input.mode,
        locale: input.locale,
        image_quality: "usable",
        identification: { status: "unknown", plant_id: null, genus_id: null },
        diagnosis: input.mode === "diagnosis"
          ? { status: "insufficient_data", candidates: [] }
          : null,
        limitations: [],
        visual_markers: [],
      },
    };

    try {
      const response = await this.messagesClient.create({
        model: PINNED_ANTHROPIC_MODEL,
        max_tokens: 2048,
        output_config: { effort: "low" },
        system: systemPrompt,
        messages: [
          {
            role: "user",
            content: [
              {
                type: "image",
                source: {
                  type: "base64",
                  media_type: input.mediaType,
                  data: input.imageBase64,
                },
              },
              {
                type: "text",
                text: JSON.stringify(contextPayload),
              },
            ],
          },
        ],
      }, { signal: input.signal });

      if (response.stop_reason === "refusal") {
        return {
          ok: false,
          stopReason: response.stop_reason,
          shouldConsumeQuota: false,
          errorCode: "PROVIDER_REFUSAL",
          errorMessage: "Model refused to classify image.",
        };
      }

      if (response.stop_reason !== "end_turn") {
        return {
          ok: false,
          stopReason: response.stop_reason,
          shouldConsumeQuota: false,
          errorCode: "PROVIDER_TRUNCATED",
          errorMessage: "Provider did not complete its classification response.",
        };
      }

      const textBlock = response.content.find((b) => b.type === "text" && b.text);
      if (!textBlock?.text) {
        return {
          ok: false,
          stopReason: response.stop_reason,
          shouldConsumeQuota: false,
          errorCode: "PROVIDER_INVALID_JSON",
          errorMessage: "No text content returned by provider.",
        };
      }

      let parsed: unknown;
      try {
        const cleaned = textBlock.text
          .trim()
          .replace(/^```json\s*/i, "")
          .replace(/```$/i, "")
          .trim();
        parsed = JSON.parse(cleaned);
      } catch {
        return {
          ok: false,
          stopReason: response.stop_reason,
          shouldConsumeQuota: false,
          errorCode: "PROVIDER_INVALID_JSON",
          errorMessage: "Provider output is not valid JSON.",
        };
      }

      const validation = AnalysisValidator.validate(parsed, input.catalog);
      if (!validation.valid || !validation.classification ||
        validation.classification.mode !== input.mode || validation.classification.locale !== input.locale) {
        return {
          ok: false,
          stopReason: response.stop_reason,
          validation,
          shouldConsumeQuota: false,
          errorCode: "SCHEMA_VALIDATION_FAILED",
          errorMessage: validation.errors.join("; "),
        };
      }

      const projection = await ProtocolResolver.resolvePreliminaryProjection({
        analysisId: input.analysisId,
        jobId: input.jobId,
        classification: validation.classification as VisionClassification30,
        catalog: input.catalog,
        signingSecret: input.signingSecret,
      });

      return {
        ok: true,
        stopReason: response.stop_reason,
        validation,
        projection,
        shouldConsumeQuota: validation.shouldConsumeQuota,
      };
    } catch (err) {
      return {
        ok: false,
        shouldConsumeQuota: false,
        errorCode: "PROVIDER_TIMEOUT_OR_ERROR",
        errorMessage: err instanceof Error ? err.message : String(err),
      };
    }
  }
}
