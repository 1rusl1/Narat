"""Cost per accepted task, including failed attempts, with explicit unknown usage."""

from collections import defaultdict

TOKEN_KEYS = ("input_tokens", "output_tokens", "cached_input_tokens")


def token_totals(calls):
    """Only aggregate counters with an explicitly guaranteed scope; never guess CLI scope."""
    totals = dict.fromkeys(TOKEN_KEYS, 0)
    cumulative = {}
    for call in calls:
        scope = call.get("usage_scope")
        session = call.get("session_id") or call.get("resumed_session")
        for key in TOKEN_KEYS:
            value = call.get(key)
            if type(value) is not int or value < 0:
                totals[key] = None
                continue
            if scope == "per_turn":
                if totals[key] is not None:
                    totals[key] += value
            elif scope == "session_cumulative" and session:
                identity = (call.get("provider", "codex"), call["model"], session, key)
                old = cumulative.get(identity, 0)
                if value < old:
                    totals[key] = None  # Counter reset/ambiguous session, not negative consumption.
                cumulative[identity] = value
                if totals[key] is not None:
                    totals[key] += value - old
            else:
                totals[key] = None
    return totals


def summarize(records):
    calls = [call for record in records for call in record["calls"]]
    accepted = sum(record["status"] == "COMPLETED" for record in records)
    check_history_available = all("check_runs" in record or not record.get("checks") for record in records)
    values = {
        "calls": len(calls), "retries": sum(bool(call.get("retry")) for call in calls),
        "agent_timeouts": sum(call.get("error_category") == "timeout" for call in calls),
        "check_timeouts": (sum(check.get("error") == "timeout" for record in records
                               for check in record.get("check_runs", [])) if check_history_available else None),
        "prompt_bytes": sum(call.get("prompt_bytes", 0) for call in calls),
        "estimated_prompt_tokens": sum(call.get("estimated_prompt_tokens", 0) for call in calls),
        "agent_elapsed_seconds": (sum(call["elapsed_seconds"] for call in calls)
                                  if all(call.get("elapsed_seconds") is not None for call in calls) else None),
        "check_elapsed_seconds": (sum(check.get("elapsed_seconds") or 0 for record in records
            for check in record.get("check_runs", []))
            if check_history_available else None)}
    tokens = token_totals(calls)
    return {"tasks": len(records), "accepted_tasks": accepted,
            "unaccepted_tasks": len(records) - accepted, "total_including_retries": {**values, **tokens},
            "per_accepted_task": {key: value / accepted if accepted and value is not None else None
                                  for key, value in {**values, **tokens}.items()},
            "unknown_or_ambiguous_usage_calls": sum(
                call.get("usage_scope") not in ("per_turn", "session_cumulative")
                or (call.get("usage_scope") == "session_cumulative" and not call.get("session_id") and not call.get("resumed_session"))
                or any(call.get(key) is None for key in TOKEN_KEYS) for call in calls),
            "unknown_elapsed_calls": sum(call.get("elapsed_seconds") is None for call in calls)}


def metrics_report(data):
    groups = defaultdict(lambda: {"calls": 0, "retries": 0, "prompt_bytes": 0,
                                 "reported_tokens_by_call": [],
                                 "unknown_usage_calls": 0, "elapsed_seconds": 0})
    tasks, cohorts = {}, defaultdict(list)
    for tid, record in data["tasks"].items():
        tasks[tid] = {"status": record["status"], "quality_contract": record.get("quality_contract"),
                      **summarize([record])}
        # Legacy records without a quality contract cannot be compared as one cohort.
        contract = record.get("quality_contract") or "unknown:" + tid
        cohorts[contract].append(record)
        for call in record["calls"]:
            prov = call.get("provider", "codex")
            group = groups[f"{tid}/{call['agent']}/{prov}:{call['model']}"]
            group["calls"] += 1
            group["retries"] += int(call["retry"] > 0)
            group["prompt_bytes"] += call["prompt_bytes"]
            group["elapsed_seconds"] += call.get("elapsed_seconds") or 0
            group["unknown_usage_calls"] += int(any(call.get(k) is None for k in TOKEN_KEYS))
            group["reported_tokens_by_call"].append({"id": call["id"],
                **{key: call.get(key) for key in TOKEN_KEYS}, "scope": call.get("usage_scope", "unspecified")})
    return {"groups": dict(groups), "tasks": tasks,
            "overall": summarize(list(data["tasks"].values())),
            "quality_cohorts": {key: summarize(records) for key, records in cohorts.items()},
            "note": "Per-accepted-task totals include ALL attempts, retries, fallbacks and unaccepted work. "
                    "Compare only matching quality_contract cohorts with the same acceptance/evidence requirements; "
                    "overall mixes quality scopes. Raw CLI counters with ambiguous scope are not summed; "
                    "unknown is null, not zero. Prompt tokens are heuristic. Money/subscription quota is not inferred."}


def compare_reports(reports):
    """Put matching acceptance contracts side by side; do not rank unlike tasks."""
    cohorts = defaultdict(dict)
    for run_id, report in reports.items():
        for contract, summary in report["quality_cohorts"].items():
            if not contract.startswith("unknown:"):
                cohorts[contract][run_id] = summary
    return {"runs": reports, "matching_quality_contracts": {
        contract: values for contract, values in cohorts.items() if len(values) > 1},
        "note": "Only matching task/criteria/constraints/check contracts are compared. "
                "Review/QA gates must pass for acceptance. Matching contracts do not prove equal real-world quality; "
                "live evidence remains separate from fixtures. No savings claim from unlike or unaccepted results."}
