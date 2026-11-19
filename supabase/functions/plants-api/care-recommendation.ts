import {
  ApiHttpError,
  jsonResponse,
  type RequestContext,
  requireActiveOwner,
  requireUuid,
} from "../_shared/http.ts";
import { projectCareRecommendation } from "../_shared/care-recommendation-projection.ts";
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

  return jsonResponse(projectCareRecommendation(plant, data, ctx.locale));
}
