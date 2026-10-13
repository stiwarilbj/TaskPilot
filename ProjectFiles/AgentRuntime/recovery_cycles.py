"""Bounded, task-local recovery memory. No requests, polling or execution."""
from __future__ import annotations

from collections import deque
from copy import deepcopy
import hashlib
import json
from pathlib import Path
from typing import Any

from observation_context import ancestor_ids, coordinate_targets, structural_identity

RECOVERY_CYCLE_VERSION = 1
HISTORY_LIMIT = 24
MAX_CYCLE_LENGTH = 6
LOCAL_ACTIONS = {"none", "wait", "read_file"}


def digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                    ensure_ascii=True, allow_nan=False).encode()).hexdigest()


def target_for(action: dict, observation: dict) -> dict | None:
    elements = [e for e in observation.get("elements", []) if isinstance(e, dict)]
    if action.get("element_id"):
        return next((e for e in elements if e.get("id") == action["element_id"]), None)
    if action.get("type") in {"key", "type_text"}:
        fields = [e for e in elements if e.get("pid") == action.get("pid") and e.get("focused") is True
                  and e.get("role") in {"AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"}]
        return fields[0] if len(fields) == 1 else None
    targets = coordinate_targets(action, observation)
    return targets[0] if targets else None


def state_key(observation: dict, pid: int | None, image_digest: str | None = None) -> str:
    """Compare semantic layouts, not image animation or revision-scoped IDs."""
    elements = [e for e in observation.get("elements", []) if isinstance(e, dict)
                and (pid is None or e.get("pid") == pid)]
    by_id = {e["id"]: e for e in elements if isinstance(e.get("id"), str)}
    controls = []
    for element in elements:
        row = {k: element[k] for k in ("pid", "role", "subrole", "title", "label", "window_title", "frame",
               "enabled", "focused", "selection_range", "sort_direction", "busy") if k in element}
        secure = "secure" in (str(element.get("role", "")) + str(element.get("subrole", ""))).casefold()
        if not secure and element.get("role") != "AXProgressIndicator":
            row.update({k: element[k] for k in ("value", "value_complete") if k in element})
        if isinstance(element.get("actions"), list):
            row["actions"] = sorted(value for value in element["actions"] if isinstance(value, str))
        row["parents"] = [{k: by_id[p].get(k) for k in ("role", "title", "frame")}
                          for p in reversed(ancestor_ids(element, by_id))]
        controls.append(row)
    apps = []
    for app in observation.get("applications", []):
        if not isinstance(app, dict) or (pid is not None and app.get("pid") != pid): continue
        row = {k: app[k] for k in ("pid", "name", "bundle_id", "version", "accessibility_available") if k in app}
        # Graphics-only apps still contribute window identity/layout. AX and
        # CG scoped IDs and foreground restoration are incidental here.
        for kind in ("windows", "graphics_windows"):
            row[kind] = sorted([{k: w[k] for k in ("title", "frame", "source", "layer") if k in w}
                                for w in app.get(kind, []) if isinstance(w, dict)], key=digest)
        apps.append(row)
    text = [{k: row[k] for k in ("pid", "text", "frame") if k in row}
            for row in observation.get("text_recognition", {}).get("targets", [])
            if isinstance(row, dict) and (pid is None or row.get("pid") == pid) and row.get("confidence", 0) >= 0.8]
    content_roles = {"AXApplication", "AXWindow", "AXGroup", "AXScrollArea", "AXWebArea", "AXProgressIndicator"}
    opaque = None
    if not text and not any(e.get("role") not in content_roles for e in elements):
        # A graphics-only page may change without changing its window bounds.
        # Exact pixels are a conservative fallback when semantic content is
        # absent. Unknown captures cannot establish a repeated state.
        path = Path(str(observation.get("screenshot_path") or ""))
        if image_digest is None and path.is_file():
            image_digest = hashlib.blake2b(path.read_bytes(), digest_size=16).hexdigest()
        opaque = image_digest or ["unknown", observation.get("observation_revision")]
    return digest({"display": {k: observation.get("display", {}).get(k) for k in
                              ("id", "x", "y", "width", "height", "scale")},
                   "apps": sorted(apps, key=digest), "controls": sorted(controls, key=digest),
                   "text": sorted(text, key=digest), "opaque_image": opaque})


def approach(action: dict, observation: dict) -> tuple[int | None, str, dict]:
    target = target_for(action, observation)
    pid = target.get("pid") if target else action.get("pid")
    parameters = {k: v for k, v in action.items() if k not in {"element_id", "observation_revision"}
                  and not (target and k in {"pid", "x", "y"})}
    identity = ({k: target.get(k) for k in ("pid", "role", "title", "window_title", "frame")}
                | {"structure": structural_identity(target, observation)}) if target else None
    app = next((a for a in observation.get("applications", []) if isinstance(a, dict) and a.get("pid") == pid), {})
    summary = {"action_type": action["type"]}
    if target:
        summary["target"] = {k: str(v)[:120] for k, v in
                             {"app": app.get("name"), "window": target.get("window_title"),
                              "role": target.get("role"), "label": target.get("title")}.items() if v}
        if identity["structure"]["containers"]:
            summary["target"]["containers"] = [{k: str(v)[:120] for k, v in container.items() if v}
                                                 for container in identity["structure"]["containers"][-6:]]
    # Literal parameters influence identity, but never appear in diagnostics
    # or strategy summaries. Changing an incidental coordinate is no new method.
    return pid, digest([parameters, identity]), summary


def failed(result: dict) -> bool:
    return (bool(result.get("error_code")) or result.get("outcome") in {"rejected", "delivered_unconfirmed"}
            or result.get("verified") is False or result.get("timed_out") is True
            or (type(result.get("exit_code")) is int and result["exit_code"] != 0)
            or (isinstance(result.get("expected_effect"), dict)
                and result["expected_effect"].get("outcome") != "verified"))


class RecoveryCycles:
    def __init__(self, rejection_limit: int = 3) -> None:
        self.history: deque[dict] = deque(maxlen=HISTORY_LIMIT)
        self.pending: dict | None = None
        self.blocked: dict[tuple, dict] = {}
        self.seen_progress: set[str] = set()
        self.rejection_limit = rejection_limit
        self.epoch_rejections = 0
        self.detections = self.suppressions = 0

    def progress(self, ledger: Any) -> None:
        # Claims, delivery acknowledgements and fresh evidence IDs are not
        # progress. Re-proving the same requirement cannot reset a loop budget.
        current = {digest(entry["check"]) for identifier, entry in ledger.requirements.items()
                   if entry["state"] == "proven" and any(
                       ledger.requirement_matches(identifier, ledger.evidence[ref])
                       for ref in entry["evidence_ids"])}
        if current - self.seen_progress:
            self.history.clear()
            self.pending = None
            self.blocked.clear()
            self.epoch_rejections = 0
        self.seen_progress.update(current)

    def record(self, action: dict, before: dict, result: dict, ledger: Any, image_digest: str | None = None) -> None:
        self.progress(ledger)
        if action["type"] in LOCAL_ACTIONS: return
        pid, key, summary = approach(action, before)
        summary["outcome"] = result.get("outcome", "unconfirmed")
        if isinstance(result.get("delivery_method"), str):
            summary["delivery_method"] = result["delivery_method"]
        self.pending = {"pid": pid, "before": state_key(before, pid, image_digest), "key": key,
                        "failed": failed(result), "summary": summary}

    def report(self, entries: list[dict], kind: str) -> dict:
        states: dict[str, str] = {}
        def name(key):
            if key not in states: states[key] = f"state_{len(states) + 1}"
            return states[key]
        path = [name(entries[0]["before"])] + [name(e["after"]) for e in entries]
        report = {"outcome": "recovery_required", "error_code": "recovery_cycle", "cycle_kind": kind,
                  "message": "These approaches returned to prior states without new verified task progress. Choose a different supported strategy; inspect uncertain effects instead of replaying them.",
                  "state_sequence": path, "approaches_tried": [e["summary"] for e in entries]}
        pairs = {(e["pid"], e["before"], e["key"]) for e in entries}
        if not pairs.issubset(self.blocked): self.detections += 1
        for pair in pairs: self.blocked[pair] = report
        # At most a bounded task-local window of blocked approaches is retained.
        while len(self.blocked) > HISTORY_LIMIT * 2: del self.blocked[next(iter(self.blocked))]
        return deepcopy(report)

    def observe(self, observation: dict, ledger: Any) -> dict | None:
        self.progress(ledger)
        if self.pending is None: return None
        entry, self.pending = self.pending, None
        entry["after"] = state_key(observation, entry["pid"])
        self.history.append(entry)
        relevant = [e for e in self.history if e["pid"] == entry["pid"]]
        for length in range(2, min(MAX_CYCLE_LENGTH, len(relevant) // 2) + 1):
            first, second = relevant[-2 * length:-length], relevant[-length:]
            signatures = lambda rows: [(e["before"], e["key"], e["after"]) for e in rows]
            if (first[0]["before"] == first[-1]["after"] and signatures(first) == signatures(second)
                    and len({(e["before"], e["key"]) for e in first}) > 1
                    and all(a["after"] == b["before"] for a, b in zip(first, first[1:]))):
                pairs = {(e["pid"], e["before"], e["key"]) for e in first}
                if pairs.issubset(self.blocked): return None
                return self.report(second, "repeated_state_path")
        return None

    def check(self, action: dict, observation: dict, ledger: Any, image_digest: str | None = None) -> dict | None:
        self.progress(ledger)
        if action["type"] in LOCAL_ACTIONS: return None
        pid, key, _ = approach(action, observation)
        state = state_key(observation, pid, image_digest)
        pair = (pid, state, key)
        report = self.blocked.get(pair)
        if report is None:
            # Two explicitly unsuccessful approaches on the same unchanged
            # state must not alternate back to an already-tried one. Ignore
            # unrelated successful steps rather than treating them as failures.
            unsuccessful = [e for e in self.history if e["pid"] == pid and e["before"] == e["after"] == state and e["failed"]]
            if key in {e["key"] for e in unsuccessful} and len({e["key"] for e in unsuccessful}) >= 2:
                report = self.report(unsuccessful[-MAX_CYCLE_LENGTH:], "unsuccessful_methods")
        if report is None: return None
        self.suppressions += 1
        self.epoch_rejections += 1
        if self.epoch_rejections >= self.rejection_limit:
            raise RuntimeError("TaskPilot stopped after repeated recovery-cycle proposals without a different strategy or new verified task progress; no repeated action was delivered")
        return {**deepcopy(report), "outcome": "suppressed"}
