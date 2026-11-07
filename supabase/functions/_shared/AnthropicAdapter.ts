// supabase/functions/_shared/AnthropicAdapter.ts
// T032: Classification-only AnthropicAdapter pinned to claude-haiku-5-5 with 40s timeout and maxRetries=0.
// Uses separate prompts for identification vs diagnosis/follow_up, enforces stop_reason === 'end_turn',
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
  mode: "identification" | "diagnosis" | "follow_up";
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
  comparisonTraitsHint?: string[];
  catalog: PublishedReleaseCatalog;
  signingSecret: string;
}

export interface AnthropicAdapterResult {
  ok: boolean;
  stopReason?: string | null;
  validation?: ValidatedAnalysisClassification;
  projection?: PreliminaryAnalysisProjection;
  shouldConsumeQuota: boolean;
  errorCode?:
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
    temperature: number;
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
  }): Promise<{
    stop_reason: string | null;
    content: Array<{ type: string; text?: string }>;
  }>;
}

export function buildSystemPrompt(
  mode: "identification" | "diagnosis" | "follow_up",
  kbReleaseId: string,
  locale: "pl" | "en",
): string {
  if (mode === "identification") {
    return [
      `You are a strict botanical species classifier for indoor houseplants (schema_version="3.0", kb_release_id="${kbReleaseId}", mode="identification", locale="${locale}").`,
      "Perform ONLY species/genus identification using closed KB plant_id and genus_id identifiers.",
      "Set diagnosis=null, comparison=null, and visual_markers=[].",
      "Do NOT diagnose diseases, do NOT generate care advice, plans, product names, or clarifying questions.",
      "Return ONLY a single valid JSON object conforming to Classification 3.0.",
    ].join(" ");
  }

  if (mode === "follow_up") {
    return [
      `You are a strict plant pathology follow-up classifier (schema_version="3.0", kb_release_id="${kbReleaseId}", mode="follow_up", locale="${locale}").`,
      "Classify species/genus, up to 2 candidate condition_ids with rank (1..2) and confidence (0..1), visual_markers from the published ConditionProfile, and comparison trend + observed_trait_ids.",
      "Do NOT generate care advice, treatment steps, product names, or clarifying questions.",
      "Return ONLY a single valid JSON object conforming to Classification 3.0.",
    ].join(" ");
  }

  return [
    `You are a strict plant pathology visual classifier (schema_version="3.0", kb_release_id="${kbReleaseId}", mode="diagnosis", locale="${locale}").`,
    "Classify species/genus, up to 2 candidate condition_ids from the closed 40 condition IDs with rank (1..2) and confidence (0..1), and visual_markers from the published ConditionProfile.",
    "Set comparison=null. Do NOT generate care advice, first-aid text, plans, product names, or clarifying questions.",
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
      comparison_traits_hint: input.comparisonTraitsHint ?? null,
    };

    try {
      const response = await this.messagesClient.create({
        model: PINNED_ANTHROPIC_MODEL,
        max_tokens: 1024,
        temperature: 0,
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
      });

      if (response.stop_reason === "refusal") {
        return {
          ok: false,
          stopReason: response.stop_reason,
          shouldConsumeQuota: false,
          errorCode: "PROVIDER_REFUSAL",
          errorMessage: "Model refused to classify image.",
        };
      }

      if (response.stop_reason === "max_tokens") {
        return {
          ok: false,
          stopReason: response.stop_reason,
          shouldConsumeQuota: false,
          errorCode: "PROVIDER_TRUNCATED",
          errorMessage: "Model output was truncated at max_tokens.",
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
      if (!validation.valid || !validation.classification) {
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
