// supabase/functions/_shared/AnthropicAdapter.ts
// T032: Classification-only Anthropic Messages adapter with a 40s timeout and maxRetries=0.
// Uses separate prompts for identification vs diagnosis, enforces stop_reason === 'end_turn',
// validates against AnalysisValidator (Schema 3.0 + KB membership), and delegates advice/receipts to ProtocolResolver.

import { validInitialContext } from "./initial-diagnosis-context.ts";
import Anthropic, { type ClientOptions } from "@anthropic-ai/sdk";
import {
  AnalysisValidator,
  ValidatedAnalysisClassification,
} from "./AnalysisValidator.ts";
import {
  type PhotoIdentificationCatalogue,
  type PhotoIdentificationResult,
  PublishedReleaseCatalog,
  VisionClassification30,
} from "./KnowledgeTypes.ts";
import {
  PreliminaryAnalysisProjection,
  ProtocolResolver,
} from "./ProtocolResolver.ts";

export const PINNED_ANTHROPIC_MODEL = "claude-haiku-5-5";
export const PINNED_OPENROUTER_MODEL = "anthropic/claude-haiku-5.5";
export const PROVIDER_CALL_TIMEOUT_MS = 40_000;
export type AnalysisProvider = "anthropic" | "openrouter";

export interface RepeatDiagnosisContext {
  light: string;
  watering_frequency: string;
  drainage: string;
  care_history: Array<{ action_code: string; occurred_local_date: string }>;
}

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
  repeatContext?: RepeatDiagnosisContext;
  initialContext?: unknown;
  catalog: PublishedReleaseCatalog;
  signingSecret: string;
  signal?: AbortSignal;
}

export interface AnthropicAdapterResult {
  ok: boolean;
  stopReason?: string | null;
  validation?: ValidatedAnalysisClassification;
  projection?: PreliminaryAnalysisProjection;
  identification?: PhotoIdentificationResult;
  shouldConsumeQuota: boolean;
  errorCode?:
    | "UNSUPPORTED_ANALYSIS_MODE"
    | "INVALID_INITIAL_CONTEXT"
    | "PROVIDER_REFUSAL"
    | "PROVIDER_TRUNCATED"
    | "PROVIDER_INVALID_JSON"
    | "SCHEMA_VALIDATION_FAILED"
    | "PROVIDER_TIMEOUT_OR_ERROR";
  errorMessage?: string;
}

interface JsonOutputFormat {
  type: "json_schema";
  schema: Record<string, unknown>;
}

const IDENTIFICATION_OUTPUT_FORMAT: JsonOutputFormat = {
  type: "json_schema",
  schema: {
    type: "object",
    properties: {
      status: { type: "string", enum: ["identified", "unknown", "unusable"] },
      plant_id: { type: ["string", "null"] },
    },
    required: ["status", "plant_id"],
    additionalProperties: false,
  },
};

export interface AnthropicMessagesClient {
  create(params: {
    model: string;
    max_tokens: number;
    output_config: { effort: "low"; format?: JsonOutputFormat };
    thinking?: { type: "disabled" };
    provider?: { allow_fallbacks: false };
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
    usage?: { input_tokens?: number; output_tokens?: number };
  }>;
}

function tokenCount(value?: number): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
    ? value
    : undefined;
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
  private readonly provider: AnalysisProvider;

  constructor(
    messagesClient?: AnthropicMessagesClient,
    apiKey?: string,
    options: { provider?: AnalysisProvider; fetch?: typeof fetch } = {},
  ) {
    this.provider = options.provider ?? "anthropic";
    if (messagesClient) {
      this.messagesClient = messagesClient;
    } else {
      const openRouter = this.provider === "openrouter";
      const request = options.fetch ?? globalThis.fetch;
      const transport: typeof fetch = (url, init) => request(
        url,
        openRouter ? { ...init, redirect: "error" } : init,
      );
      const sdk = new Anthropic({
        baseURL: openRouter
          ? "https://openrouter.ai/api"
          : "https://api.anthropic.com",
        apiKey: openRouter
          ? null
          : apiKey ?? Deno.env.get("ANTHROPIC_API_KEY") ?? "missing-key",
        authToken: openRouter ? apiKey ?? null : null,
        maxRetries: 0,
        timeout: PROVIDER_CALL_TIMEOUT_MS,
        // The SDK declares node-fetch types but accepts Web Fetch on Edge.
        fetch: transport as unknown as ClientOptions["fetch"],
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
    if ("initialContext" in input &&
      (input.mode !== "diagnosis" || input.repeatContext != null ||
        !validInitialContext(input.initialContext))) {
      return {
        ok: false,
        shouldConsumeQuota: false,
        errorCode: "INVALID_INITIAL_CONTEXT",
        errorMessage: "Invalid initial diagnosis context.",
      };
    }
    const initialContext = validInitialContext(input.initialContext)
      ? input.initialContext
      : undefined;
    let systemPrompt = buildSystemPrompt(
      input.mode,
      input.catalog.kbReleaseId,
      input.locale,
    );
    const repeatContext = input.mode === "diagnosis" ? input.repeatContext : undefined;
    if (repeatContext) {
      systemPrompt += " Diagnose only the submitted new photo. Use saved conditions and recorded care as background facts. Missing information remains unknown. Do not compare images, diagnose from the journal alone, or infer improvement or deterioration.";
    }

    if (initialContext) {
      systemPrompt += " Initial observation answers are background only. Unknown remains unknown. Diagnose only the submitted photo using visible evidence and the published catalogue constraints. Do not infer recorded care, last watering dates or history from these answers.";
    }

    const contextPayload = {
      kb_release_id: input.catalog.kbReleaseId,
      mode: input.mode,
      locale: input.locale,
      care_context: input.careContext ?? null,
      ...(initialContext && {
        initial_context: {
          light: initialContext.light,
          watering_frequency: initialContext.watering_frequency,
          drainage: initialContext.drainage,
        },
      }),
      ...(repeatContext && {
        repeat_context: {
          light: repeatContext.light,
          watering_frequency: repeatContext.watering_frequency,
          drainage: repeatContext.drainage,
          care_history: repeatContext.care_history.map(({ action_code, occurred_local_date }) => ({
            action_code,
            occurred_local_date,
          })),
        },
      }),
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

    return await this.classifyPhoto(
      input,
      systemPrompt,
      contextPayload,
      async (parsed, stopReason) => {
        const validation = AnalysisValidator.validate(parsed, input.catalog);
        if (
          !validation.valid || !validation.classification ||
          validation.classification.mode !== input.mode ||
          validation.classification.locale !== input.locale
        ) {
          return {
            ok: false,
            stopReason,
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
          stopReason,
          validation,
          projection,
          shouldConsumeQuota: validation.shouldConsumeQuota,
        };
      },
    );
  }

  async identifySpecies(
    input: Pick<
      AnthropicClassificationInput,
      "jobId" | "imageBase64" | "mediaType" | "signal"
    >,
    catalogue: PhotoIdentificationCatalogue,
  ): Promise<AnthropicAdapterResult> {
    const systemPrompt = [
      "Identify the visible plant at species level using the supplied closed catalogue.",
      'Return exactly a JSON object with "status" and "plant_id".',
      'Use "identified" and the exact allowed UUID only when a single listed species matches confidently.',
      'Use "unknown" and null for an ambiguous plant or a plant outside the list.',
      'Use "unusable" and null for a non-plant or a photo too poor to classify.',
      "Do not identify a genus alone or include any other fields.",
    ].join(" ");
    const contextPayload = {
      allowed_plants: Array.from(
        catalogue.species,
        ([id, plant]) => [id, plant.scientificName],
      ),
    };
    return await this.classifyPhoto(
      input,
      systemPrompt,
      contextPayload,
      (parsed, stopReason) => {
        const fields = parsed as
          | { status?: unknown; plant_id?: unknown }
          | null;
        const id = fields?.plant_id;
        if (
          !fields || typeof fields !== "object" || Array.isArray(fields) ||
          Object.keys(fields).length !== 2 ||
          !(
            (fields.status === "identified" && typeof id === "string" &&
              /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(id)) ||
            ((fields.status === "unknown" || fields.status === "unusable") &&
              id === null)
          )
        ) {
          return {
            ok: false,
            stopReason,
            shouldConsumeQuota: false,
            errorCode: "SCHEMA_VALIDATION_FAILED",
          };
        }
        const plantId = typeof id === "string" ? id.toLowerCase() : null;
        const species = plantId === null
          ? undefined
          : catalogue.species.get(plantId);
        return {
          ok: true,
          stopReason,
          shouldConsumeQuota: fields.status !== "unusable",
          identification: {
            schema_version: "1.0",
            mode: "identification",
            job_id: input.jobId,
            catalogue_release_id: catalogue.releaseId,
            ...(species && plantId
              ? {
                identification_status: "identified",
                plant_id: plantId,
                plant_display_name: species.displayName,
              }
              : {
                identification_status: "unknown",
                plant_id: null,
                plant_display_name: null,
              }),
          },
        };
      },
      IDENTIFICATION_OUTPUT_FORMAT,
    );
  }

  private async classifyPhoto(
    input: Pick<
      AnthropicClassificationInput,
      "jobId" | "imageBase64" | "mediaType" | "signal"
    >,
    systemPrompt: string,
    contextPayload: unknown,
    resolve: (
      parsed: unknown,
      stopReason: string,
    ) => AnthropicAdapterResult | Promise<AnthropicAdapterResult>,
    format?: JsonOutputFormat,
  ): Promise<AnthropicAdapterResult> {
    const openRouter = this.provider === "openrouter";
    const started = performance.now();
    let received = false;
    try {
      const response = await this.messagesClient.create({
        model: openRouter ? PINNED_OPENROUTER_MODEL : PINNED_ANTHROPIC_MODEL,
        max_tokens: 2048,
        output_config: { effort: "low", ...(format && { format }) },
        ...(openRouter && {
          thinking: { type: "disabled" },
          provider: { allow_fallbacks: false },
        }),
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
      received = true;
      if (openRouter) {
        console.info(JSON.stringify({
          event: "analysis_provider_call",
          job_id: input.jobId,
          model: PINNED_OPENROUTER_MODEL,
          outcome: "response",
          elapsed_ms: Math.round(performance.now() - started),
          input_tokens: tokenCount(response.usage?.input_tokens),
          output_tokens: tokenCount(response.usage?.output_tokens),
        }));
      }

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
          errorMessage:
            "Provider did not complete its classification response.",
        };
      }

      const textBlock = response.content.find((b) =>
        b.type === "text" && b.text
      );
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

      return await resolve(parsed, response.stop_reason);
    } catch (err) {
      if (openRouter && !received) {
        console.info(JSON.stringify({
          event: "analysis_provider_call",
          job_id: input.jobId,
          model: PINNED_OPENROUTER_MODEL,
          outcome:
            input.signal?.aborted ||
              err instanceof Anthropic.APIConnectionTimeoutError
              ? "timeout"
              : "error",
          elapsed_ms: Math.round(performance.now() - started),
          http_status: err instanceof Anthropic.APIError
            ? err.status
            : undefined,
        }));
      }
      return {
        ok: false,
        shouldConsumeQuota: false,
        errorCode: "PROVIDER_TIMEOUT_OR_ERROR",
        errorMessage:
          "The classification provider could not complete the request.",
      };
    }
  }
}
