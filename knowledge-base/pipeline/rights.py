"""Operation-level ingestion gate. Candidate/unknown/expired rights never allow a fetch."""
from datetime import date


class RightsError(ValueError):
    pass


def require_operations(registry, source_id, operations, *, today=None):
    today = today or date.today()
    matches = [s for s in registry.get("sources", []) if s.get("id") == source_id]
    if len(matches) != 1:
        raise RightsError(f"Unknown or duplicate source: {source_id}")
    source = matches[0]
    if source.get("status") != "allowed":
        raise RightsError(f"Source is not allowed: {source_id}")
    checked = source.get("checked_at")
    if not checked or date.fromisoformat(checked) > today:
        raise RightsError(f"Missing/future rights review: {source_id}")
    review_after = source.get("review_after")
    if not review_after or date.fromisoformat(review_after) <= today:
        raise RightsError(f"Rights review must be renewed: {source_id}")
    if not source.get("terms_urls"):
        raise RightsError(f"Missing terms evidence: {source_id}")
    allowed = source.get("allowed_operations", {})
    for operation in operations:
        if allowed.get(operation) is not True:
            raise RightsError(f"Operation {operation} is not allowed for {source_id}")
    return source
