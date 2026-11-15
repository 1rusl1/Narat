import {
  ApiHttpError,
  jsonResponse,
  type RequestContext,
  requireActiveOwner,
  requireUuid,
} from "../_shared/http.ts";
import {
  type ProfileProvenance,
  validatePublishedPlantCare,
} from "../_shared/KnowledgeTypes.ts";
import type { SyncClientFactory } from "./collection.ts";

function sourceFor(provenance: ProfileProvenance, path: string) {
  const evidence = provenance.field_evidence[path]?.[0];
  const source = provenance.source_documents.find((item) =>
    item.source_id === evidence?.source_id &&
    item.allowed_for.includes("derived_records")
  );
  if (!evidence || !source) return null;
  try {
    const url = new URL(source.url);
    if (url.protocol === "https:" && !url.username && !url.password) {
      return { url: source.url, locator: evidence.locator };
    }
  } catch {
    // A malformed provenance URL cannot support a recommendation.
  }
  return null;
}

function addCalendarDays(anchor: unknown, interval: number) {
  if (typeof anchor !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(anchor)) return null;
  const date = new Date(anchor + "T00:00:00Z");
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== anchor) {
    return null;
  }
  date.setUTCDate(date.getUTCDate() + interval);
  const due = date.toISOString().split("T")[0];
  return due.length === 10 ? due : null;
}

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
      { plant_id: plant, status: "unavailable", recommendation: null, next_check: null },
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
    !action.active_ingredients?.length
  );
  if (index < 0) return absent();
  const actionPath = "/actions/" + index;
  const source = sourceFor(profile.provenance, actionPath);
  if (!source) return absent();
  const action = profile.actions[index];
  const ruleSource = sourceFor(
    profile.provenance,
    actionPath + "/next_check_interval_days",
  );
  const interval = ruleSource ? action.next_check_interval_days : null;
  const routine = data.routine_check;
  if (routine != null) {
    if (
      typeof routine !== "object" || Array.isArray(routine) ||
      Object.keys(routine).length !== 5 ||
      !Number.isSafeInteger(routine.care_revision) || routine.care_revision < 1 ||
      (routine.anchor_kind !== "water" && routine.anchor_kind !== "check_soil") ||
      data.calendar_eligible !== true || interval === null ||
      typeof routine.due_local_date !== "string" ||
      addCalendarDays(routine.anchor_local_date, interval) !== routine.due_local_date
    ) return absent();
    try {
      requireUuid(routine.rule_id, "rule_id");
    } catch {
      return absent();
    }
  }
  const anchor = routine?.anchor_local_date ?? data.last_watered_on;
  const due = data.calendar_eligible === true && interval !== null
    ? addCalendarDays(anchor, interval)
    : null;
  return jsonResponse(
    {
      plant_id: plant,
      status: "available",
      recommendation: {
        action_id: action.action_id,
        action_code: action.action_code,
        text: ctx.locale === "pl" ? action.action_pl : action.action_en,
        next_check_interval_days: interval,
        source,
      },
      ...(routine == null ? {} : { routine_check: routine }),
      next_check: due === null ? null : {
        due_on: due,
        anchor_on: anchor,
        interval_days: interval,
        basis: routine?.anchor_kind === "check_soil"
          ? ctx.locale === "pl"
            ? `Na podstawie ostatniej zapisanej kontroli podłoża i opublikowanego odstępu (${interval} dni).`
            : `Based on the last recorded soil check and the published ${interval}-day interval.`
          : ctx.locale === "pl"
          ? `Na podstawie ostatniego zapisanego podlewania i opublikowanego odstępu (${interval} dni).`
          : `Based on the last recorded watering and the published ${interval}-day interval.`,
        source: ruleSource,
      },
    },
  );
}
