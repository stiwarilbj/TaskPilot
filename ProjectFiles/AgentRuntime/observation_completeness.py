"""Private observation coverage, independent of action validity and proof."""
from __future__ import annotations

from typing import Any

OBSERVATION_COMPLETENESS_VERSION = 1
SCOPE = "exposed_accessibility_tree_on_assigned_display"


class ObservationCompletenessError(ValueError):
    pass


def count(value: Any) -> int:
    if type(value) is not int or not 0 <= value <= 10_000_000:
        raise ObservationCompletenessError("Observation coverage counts must be nonnegative integers")
    return value


def validate_completeness(observation: dict, *, required: bool = False) -> dict | None:
    coverage = observation.get("observation_completeness")
    if coverage is None and not required:
        return None  # Older sanitized fixtures have unknown coverage, never proven absence.
    if not isinstance(coverage, dict):
        raise ObservationCompletenessError("The observation lacks its native completeness report")
    if type(coverage.get("version")) is not int or coverage["version"] != OBSERVATION_COMPLETENESS_VERSION:
        raise ObservationCompletenessError("Observation completeness versions do not match")
    if coverage.get("scope") != SCOPE or coverage.get("state") not in ("complete", "partial"):
        raise ObservationCompletenessError("Unsupported observation completeness scope or state")
    elements = observation.get("elements", [])
    if not isinstance(elements, list) or count(coverage.get("collected_controls")) != len(elements):
        raise ObservationCompletenessError("Observation completeness disagrees with its collected controls")
    reasons = coverage.get("reason_counts")
    if not isinstance(reasons, dict) or any(not isinstance(k, str) or not k or len(k) > 64 or count(v) == 0 for k, v in reasons.items()):
        raise ObservationCompletenessError("Observation completeness needs valid nonzero reason counts")
    if (coverage["state"] == "complete") != (not reasons):
        raise ObservationCompletenessError("Partial collection cannot be reported as complete")
    scopes = coverage.get("limitations")
    if not isinstance(scopes, list) or len(scopes) > 32:
        raise ObservationCompletenessError("Observation completeness scopes must be a bounded list")
    ids = {e["id"]: e for e in elements if isinstance(e, dict) and isinstance(e.get("id"), str)}
    for row in scopes:
        if not isinstance(row, dict) or not isinstance(row.get("reason"), str) or row["reason"] not in reasons or type(row.get("pid")) is not int or row["pid"] <= 0:
            raise ObservationCompletenessError("Invalid observation completeness scope")
        if "element_id" in row:
            if not isinstance(row["element_id"], str) or row["element_id"] not in ids or ids[row["element_id"]].get("pid") != row["pid"]:
                raise ObservationCompletenessError("Observation completeness references a stale subtree")
        if "window_id" in row and (not isinstance(row["window_id"], str) or not row["window_id"]):
            raise ObservationCompletenessError("Invalid observation completeness window")
        if "omitted_child_roots_at_least" in row: count(row["omitted_child_roots_at_least"])
    if count(coverage.get("limitation_scopes_omitted")) + len(scopes) != sum(reasons.values()):
        raise ObservationCompletenessError("Observation completeness scope counts do not match")
    expansion = coverage.get("local_expansion")
    if not isinstance(expansion, dict):
        raise ObservationCompletenessError("Observation completeness lacks its local expansion summary")
    for field in ("subtrees_attempted", "controls_added", "read_retries"): count(expansion.get(field))
    if expansion["controls_added"] > coverage["collected_controls"]:
        raise ObservationCompletenessError("Observation expansion exceeds its collected controls")
    return coverage


def prompt_coverage(observation: dict, selected: list[dict], limit: int) -> dict:
    coverage = validate_completeness(observation)
    result = {k: v for k, v in coverage.items() if k != "local_expansion" and (v or k in {"version", "state", "collected_controls"})} if coverage else {"state": "unknown"}
    total = len(observation.get("elements", []))
    omitted = max(0, total - len(selected))
    if not total and coverage is None: return result
    result["prompt_selection"] = {"included": len(selected), "omitted": omitted, "limit": limit}
    if omitted:
        result["prompt_selection"]["reason"] = "prompt_budget_or_context_filter"
    # Native limitations may name a subtree omitted by prompt compaction.
    # Keep app/window scopes while never advertising an unavailable target ID.
    selected_ids = {row.get("id") for row in selected}
    if coverage and coverage["limitations"]:
        result["limitations"] = [dict(row) if row.get("element_id") in selected_ids else
            {k: v for k, v in row.items() if k != "element_id"} for row in coverage["limitations"]]
    return result


def coverage_cache_input(observation: dict | None) -> dict | None:
    """Expansion counters are diagnostics, not changed task evidence."""
    if not observation or not isinstance(observation.get("observation_completeness"), dict): return observation
    return {**observation, "observation_completeness":
            {k: v for k, v in observation["observation_completeness"].items() if k != "local_expansion"}}
