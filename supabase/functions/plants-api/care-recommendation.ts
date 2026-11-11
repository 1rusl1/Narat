import {
  ApiHttpError,
  jsonResponse,
  type RequestContext,
  requireActiveOwner,
  requireUuid,
} from "../_shared/http.ts";
import { validatePublishedPlantCare } from "../_shared/KnowledgeTypes.ts";
import type { SyncClientFactory } from "./collection.ts";

export async function handleCareRecommendation(
  req: Request,
  ctx: RequestContext,
  target: string,
  clientFactory: SyncClientFactory,
): Promise<Response> {
  const owner = requireActiveOwner(ctx);
  if (ctx.isAnonymous) {
    throw new ApiHttpError(
      403,
      "FORBIDDEN",
      "An active permanent account is required.",
    );
  }
  if (new URL(req.url).search) {
    throw new ApiHttpError(
      400,
      "VALIDATION_ERROR",
      "Unexpected query parameters.",
    );
  }
  const plant = requireUuid(target, "plant_id");
  const unavailable = () =>
    new ApiHttpError(
      503,
      "INTERNAL_ERROR",
      "Care recommendations are temporarily unavailable.",
      true,
    );

  let response;
  try {
    const client = clientFactory();
    if (!client) throw unavailable();
    response = await client.rpc("read_plant_care_profile", {
      p_owner_id: owner,
      p_plant_id: plant,
    });
  } catch {
    throw unavailable();
  }
  const { data, error } = response;
  if (error) throw unavailable();
  if (data === null) {
    throw new ApiHttpError(404, "NOT_FOUND", "The plant was not found.");
  }
  if (data?.plant_id !== plant) throw unavailable();

  const absent = () =>
    jsonResponse(
      { plant_id: plant, status: "unavailable", recommendation: null },
    );
  const profile: unknown = data.profile;
  if (
    !validatePublishedPlantCare(profile) ||
    profile.kb_release_id !== data.kb_release_id ||
    profile.plant_id !== data.plant_slug
  ) return absent();

  const index = profile.actions.findIndex((action) =>
    action.action_code === "check_soil" && action.purpose === "routine_care" &&
    action.prerequisite_check_ids.length === 0 &&
    action.contraindication_check_ids.length === 0 &&
    !action.active_ingredients?.length &&
    action.next_check_interval_days === null
  );
  if (index < 0) return absent();
  const evidence = profile.provenance.field_evidence["/actions/" + index]?.[0];
  const source = profile.provenance.source_documents.find((item) =>
    item.source_id === evidence?.source_id &&
    item.allowed_for.includes("derived_records")
  );
  if (!evidence || !source) return absent();
  const url = new URL(source.url);
  if (url.protocol !== "https:" || url.username || url.password) {
    return absent();
  }

  const action = profile.actions[index];
  return jsonResponse(
    {
      plant_id: plant,
      status: "available",
      recommendation: {
        action_id: action.action_id,
        action_code: action.action_code,
        text: ctx.locale === "pl" ? action.action_pl : action.action_en,
        next_check_interval_days: action.next_check_interval_days,
        source: { url: source.url, locator: evidence.locator },
      },
    },
  );
}
