"""Local prompt context selection. Does not create actions or model requests."""
from __future__ import annotations

import base64
from collections import Counter, defaultdict
from contextlib import contextmanager
from contextvars import ContextVar
from copy import deepcopy
import hashlib
import json
import math
import re
import unicodedata
from types import MappingProxyType
from typing import Any, Callable
from screen_coordinates import CoordinateMappingError, action_global_point

STOP_WORDS = set("a an the in on at with from to and then for please my me that this it of can could would using use do is as into".split())
CONTROL_ROLES = {"AXApplication", "AXWindow", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                 "AXMenu", "AXMenuItem", "AXMenuBarItem", "AXSheet", "AXTextField", "AXTextArea", "AXSearchField",
                 "AXComboBox", "AXSecureTextField", "AXSlider", "AXTab", "AXLink", "AXRow", "AXOutline", "AXTable"}
LABEL_ROLES = {"AXStaticText", "AXHeading", "AXRow", "AXGroup", "AXCell", "AXColumn", "AXWindow", "AXSheet"}
MAX_PROGRESS_CHARACTERS = 16000
RELATIONSHIPS_VERSION = 1
OBSERVATION_INDEX_VERSION = 1
POINTER_CONTAINERS = {"AXApplication", "AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup",
                      "AXWebArea", "AXLayoutArea", "AXMenuBar", "unknown"}


def ancestor_ids(element: dict[str, Any], by_id: dict[str, dict[str, Any]]) -> list[str]:
    identity = element.get("id")
    chain, seen, parent = [], {identity} if isinstance(identity, str) else set(), element.get("parent_id")
    while isinstance(parent, str) and parent in by_id and parent not in seen and len(chain) < 24:
        node = by_id[parent]
        if element.get("pid") != node.get("pid"): break
        if element.get("window_id") and node.get("window_id") and element["window_id"] != node["window_id"]: break
        chain.append(parent); seen.add(parent); parent = node.get("parent_id")
    return chain


def _immutable(*args, **kwargs):
    raise TypeError("Observation indexes are read-only")


class _IndexedDict(dict):
    __setitem__ = __delitem__ = clear = pop = popitem = setdefault = update = __ior__ = _immutable
    def __deepcopy__(self, memo): return deepcopy(dict(self), memo)


class _IndexedList(list):
    __setitem__ = __delitem__ = append = clear = extend = insert = pop = remove = reverse = sort = __iadd__ = __imul__ = _immutable
    def __deepcopy__(self, memo): return deepcopy(list(self), memo)


def _freeze(value):
    if isinstance(value, dict): return _IndexedDict({k: _freeze(v) for k, v in value.items()})
    if isinstance(value, list): return _IndexedList(_freeze(v) for v in value)
    return value


def _group(rows, key):
    groups = defaultdict(list)
    for row in rows:
        identity = key(row)
        try: hash(identity)
        except TypeError: continue
        groups[identity].append(row)
    return MappingProxyType({identity: tuple(values) for identity, values in groups.items()})


class ObservationIndexes:
    """Immutable lookups for one accepted observation, never executable targets.

    Copies isolate cached rows from caller edits and equivalent observation
    copies. The runtime owns reuse/invalidation through its existing state guard.
    Preserve row order and duplicates; callers choose the same first/last match
    as their former scans, and ambiguity checks still see every candidate.
    """
    def __init__(self, observation: dict[str, Any]):
        self.elements = tuple(_freeze(e) for e in observation.get("elements", []) if isinstance(e, dict))
        self.applications = tuple(_freeze(a) for a in observation.get("applications", []) if isinstance(a, dict))
        self.rows = tuple(e for e in self.elements if isinstance(e.get("id"), str))
        self.elements_by_id = _group(self.rows, lambda e: e["id"])
        self.by_id = MappingProxyType({identity: rows[-1] for identity, rows in self.elements_by_id.items()})
        self.elements_by_pid = _group(self.elements, lambda e: e.get("pid"))
        self.applications_by_pid = _group(self.applications, lambda a: a.get("pid"))
        self.positions = MappingProxyType({e["id"]: i for i, e in enumerate(self.rows)})
        self.ancestors = MappingProxyType({identity: tuple(ancestor_ids(e, self.by_id)) for identity, e in self.by_id.items()})
        self.scopes = MappingProxyType({identity: (e.get("pid"), e.get("window_id") or
            next((self.by_id[p]["id"] for p in self.ancestors[identity] if self.by_id[p].get("role") == "AXWindow"), None)
            or e.get("window_title")) for identity, e in self.by_id.items()})
        self.children = _group((e for e in self.rows if isinstance(e.get("parent_id"), str) and e["parent_id"] in self.by_id),
                               lambda e: e["parent_id"])
        self.canonical_children = _group(self.by_id.values(), lambda e: (e.get("pid"), e.get("parent_id")))
        # Keep AX and graphics window namespaces distinct, including app PID.
        # Store per-app tables to retain first/last application scan semantics.
        self.windows = tuple(_group((w for w in a.get("windows", []) if isinstance(w, dict)),
                                    lambda w: w.get("window_id") or w.get("title")) for a in self.applications)
        self.graphics_windows = tuple(_group((w for w in a.get("graphics_windows", []) if isinstance(w, dict)),
                                             lambda w: w.get("id")) for a in self.applications)
        self._app_positions = _group(range(len(self.applications)), lambda i: self.applications[i].get("pid"))

    def element(self, identity, *, last=False):
        rows = self.elements_by_id.get(identity, ()) if isinstance(identity, str) else ()
        return rows[-1 if last else 0] if rows else None

    def application(self, pid, *, last=False):
        rows = self.applications_by_pid.get(pid, ())
        return rows[-1 if last else 0] if rows else None

    def window_candidates(self, pid, identity, *, graphics=False, application_last=False):
        positions = self._app_positions.get(pid, ())
        if not positions: return ()
        tables = self.graphics_windows if graphics else self.windows
        return tables[positions[-1 if application_last else 0]].get(identity, ())

    def ancestor_ids(self, element):
        identity = element.get("id")
        if isinstance(identity, str) and self.by_id.get(identity) is element: return self.ancestors[identity]
        # A pinned target or a duplicate row must retain its own parent scope.
        return tuple(ancestor_ids(element, self.by_id))


_index_provider = ContextVar("observation_index_provider", default=None)


@contextmanager
def observation_index_scope(provider):
    token = _index_provider.set(provider)
    try: yield
    finally: _index_provider.reset(token)


def observation_indexes(observation: dict[str, Any]) -> ObservationIndexes:
    provider = _index_provider.get()
    return provider(observation) if provider is not None else ObservationIndexes(observation)


def coordinate_targets(action: dict[str, Any], observation: dict[str, Any], indexes: ObservationIndexes | None = None) -> list[dict[str, Any]]:
    """Observed hit candidates; a label child is not a second actionable target."""
    try: point = action_global_point(action, observation)
    except CoordinateMappingError: return []
    targets = []
    indexes = indexes or observation_indexes(observation)
    for element in indexes.elements_by_pid.get(action.get("pid"), ()):
        if not isinstance(element, dict) or element.get("pid") != action.get("pid") or element.get("role") in POINTER_CONTAINERS: continue
        frame = element.get("frame", {})
        values = [frame.get(k) for k in ("x", "y", "width", "height")]
        if any(type(v) not in {int, float} or not math.isfinite(v) for v in values): continue
        fx, fy, fw, fh = values
        if fw > 0 and fh > 0 and fx <= point[0] <= fx + fw and fy <= point[1] <= fy + fh: targets.append(element)
    actionable = [e for e in targets if e.get("actions") or e.get("role") in CONTROL_ROLES]
    targets = actionable or targets
    return sorted(targets, key=lambda e: ("AXPress" not in e.get("actions", []),
                  e["frame"]["width"] * e["frame"]["height"], -e.get("depth", 0)))


def coordinates_are_ambiguous(action: dict[str, Any], observation: dict[str, Any], indexes: ObservationIndexes | None = None) -> bool:
    if action.get("element_id") or action.get("type") not in {"click", "double_click"}: return False
    indexes = indexes or observation_indexes(observation)
    targets = coordinate_targets(action, observation, indexes)
    return any(not (first.get("native_identity") and first.get("native_identity") == second.get("native_identity"))
               and first.get("id") not in indexes.ancestor_ids(second) and second.get("id") not in indexes.ancestor_ids(first)
               for i, first in enumerate(targets) for second in targets[i + 1:])


def structural_identity(target: dict[str, Any], observation: dict[str, Any], indexes: ObservationIndexes | None = None) -> dict[str, Any]:
    """Semantic context across revisions, used only by bounded replay protection."""
    indexes = indexes or observation_indexes(observation)
    chain = indexes.ancestor_ids(target)
    labels = sorted({element_text(e) for e in indexes.canonical_children.get((target.get("pid"), target.get("parent_id")), ())
                     if target.get("parent_id") and e.get("parent_id") == target.get("parent_id")
                     and e.get("role") in {"AXStaticText", "AXHeading"} and element_text(e)})
    return {"containers": [{k: indexes.by_id[p].get(k) for k in ("role", "title")} for p in reversed(chain)], "labels": labels}


def words(value: str) -> set[str]:
    folded = unicodedata.normalize("NFKD", value.casefold())
    folded = "".join(c for c in folded if not unicodedata.combining(c))
    return {w for w in re.findall(r"[^\W_]+", folded, re.UNICODE) if w not in STOP_WORDS}


def element_text(element: dict[str, Any]) -> str:
    # Credential redaction is native; do not use even a supplied secure value
    # as a ranking feature or a surrounding label.
    keys = ("title", "label", "description", "help")
    if element.get("role") != "AXSecureTextField" and "secure" not in str(element.get("subrole", "")).casefold():
        keys += ("value",)
    return " ".join(element[k][:4096] for k in keys if isinstance(element.get(k), str))


def select_elements(observation: dict[str, Any], task: str, limit: int, indexes: ObservationIndexes | None = None) -> list[dict[str, Any]]:
    indexes = indexes or observation_indexes(observation)
    rows, by_id, indices = indexes.rows, indexes.by_id, indexes.positions
    ancestors, scopes, applications = indexes.ancestors, indexes.scopes, indexes.applications
    primary = next((a for a in applications if a.get("topmost_on_agent_screen") is True), None)
    primary = primary or next((a for a in applications if a.get("active") is True), {})
    primary_pid = primary.get("pid")
    active_scopes = {scopes[e["id"]] for e in rows if e.get("active_window") is True}
    for app in applications:
        # Inactive applications can still report their own focused window;
        # that does not make it the active window on the task's display.
        if primary_pid is None or app.get("pid") != primary_pid: continue
        for window in app.get("windows", []):
            if not isinstance(window, dict): continue
            if window.get("topmost_on_agent_screen") is True or window.get("focused") is True:
                active_scopes.add((app.get("pid"), window.get("window_id") or window.get("title")))
    tokens = words(task)
    own = {e["id"]: words(element_text(e)) for e in rows}
    frequencies = Counter(w for values in own.values() for w in values)

    def relevance(values):
        return sum(1 + math.log1p(len(rows) / max(1, frequencies[w])) for w in values & tokens)

    matches = {identity: relevance(values) for identity, values in own.items()}
    siblings = {parent: [e["id"] for e in children] for parent, children in indexes.children.items()}
    scope_labels = defaultdict(list)
    for e in rows:
        if e.get("role") in LABEL_ROLES and element_text(e): scope_labels[scopes[e["id"]]].append(e["id"])

    def proximity(a, b):
        fa, fb = a.get("frame"), b.get("frame")
        if not isinstance(fa, dict) or not isinstance(fb, dict): return None
        values = [f.get(k) for f in (fa, fb) for k in ("x", "y", "width", "height")]
        if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) for v in values): return None
        ax, ay, aw, ah, bx, by, bw, bh = values
        if min(aw, ah, bw, bh) < 0: return None
        dx = max(ax - (bx + bw), bx - (ax + aw), 0)
        dy = max(ay - (by + bh), by - (ay + ah), 0)
        if dx > 180 or dy > 80: return None
        return dx + 3 * dy

    context_labels: dict[str, list[str]] = {}
    for e in rows:
        identity = e["id"]
        if e.get("role") not in CONTROL_ROLES and not e.get("actions"):
            context_labels[identity] = []
            continue
        group = siblings.get(e.get("parent_id"), [])
        position = group.index(identity) if identity in group else 0
        adjacent = set(group[max(0, position - 3):position + 4]) - {identity}
        candidates = []
        for other in scope_labels[scopes[identity]]:
            if other == identity or other in ancestors[identity]: continue
            neighbor = by_id[other]
            distance = proximity(e, neighbor)
            if other not in adjacent and distance is None: continue
            same_group = neighbor.get("parent_id") == e.get("parent_id") and len(group) <= 16
            candidates.append((other, 0 if same_group else 1,
                               distance if distance is not None else 100 + abs(indices[other] - indices[identity])))
        candidates.sort(key=lambda item: (item[1], -matches[item[0]], item[2], indices[item[0]]))
        # Once a small row/form supplies its own labels, another nearby row
        # must not replace or consume the context of an identical button.
        local = [item for item in candidates if item[1] == 0]
        if local: candidates = local
        context_labels[identity] = [item[0] for item in candidates[:2]]

    meaningful = [e for e in rows if e.get("actions") or element_text(e) or e.get("role") in CONTROL_ROLES]

    def priority(e):
        identity = e["id"]
        on_primary = primary_pid is None or e.get("pid") == primary_pid
        score = 600 if on_primary and e.get("focused") is True else 0
        if on_primary and e.get("role") in {"AXMenu", "AXMenuItem", "AXMenuBarItem", "AXSheet"}: score += 400
        if primary_pid is not None and e.get("pid") == primary_pid: score += 110
        if scopes[identity] in active_scopes: score += 180
        # Window/app names guide navigation, but a direct label or nearby row
        # label carries more weight than boilerplate shared by the entire app.
        score += 50 * matches[identity]
        score += 22 * max((matches[p] for p in ancestors[identity]), default=0)
        score += 25 * max((matches[p] for p in context_labels[identity]), default=0)
        score += 12 * relevance(words(str(e.get("app", "")) + " " + str(e.get("window_title", ""))))
        if e.get("actions") and e.get("enabled", True) is True: score += 60
        elif e.get("role") in CONTROL_ROLES: score += 20
        return -score, indices[identity]

    chosen: set[str] = set()
    for element in sorted(meaningful, key=priority):
        identity = element["id"]
        bundle = {identity, *ancestors[identity]}
        for label in context_labels[identity]: bundle.update([label, *ancestors[label]])
        if len(chosen | bundle) <= limit: chosen.update(bundle)
    repeated = defaultdict(list)
    unique_peers = defaultdict(set)
    for e in rows:
        label = str(e.get("title") or "").strip().casefold()
        if label and (e.get("actions") or e.get("role") in CONTROL_ROLES - {"AXApplication", "AXWindow", "AXSheet", "AXMenu"}):
            key = (e.get("pid"), e.get("role"), label)
            identity = e.get("native_identity") or e["id"]
            if identity not in unique_peers[key]: repeated[key].append(e["id"]); unique_peers[key].add(identity)
    selected = []
    # Preserve tree reading order and all executable IDs. References are only
    # to observed nodes; clipped peers remain explicitly counted, not invented.
    for e in rows:
        if e["id"] not in chosen: continue
        row = dict(e)
        row.pop("native_identity", None)  # Private reconciliation identity, outside prompts/history.
        if e.get("role") == "AXSecureTextField" or "secure" in str(e.get("subrole", "")).casefold():
            if "value" in row: row["value"] = "[secure]"
            if "value_complete" in row: row["value_complete"] = False
        context = {"path": list(reversed(ancestors[e["id"]])), "nearby_label_ids": context_labels[e["id"]]}
        peers = repeated[(e.get("pid"), e.get("role"), str(e.get("title") or "").strip().casefold())]
        if len(peers) > 1:
            # A large repeated table must not duplicate eight full IDs in every
            # row. Its selected controls already carry complete IDs and paths.
            visible = [p for p in peers if p in chosen] if len(peers) <= 8 else []
            context["repeated_label"] = {"count": len(peers), "candidate_ids": visible, "partial": len(visible) < len(peers)}
        row["target_context"] = context
        selected.append(row)
    return selected


def historical_progress(history: list[dict[str, Any]], recent_count: int,
                        command_verified: Callable[[dict[str, Any], dict[str, Any]], bool],
                        task: str = "") -> dict[str, Any]:
    """Retain confirmed past facts, never model completion claims or old IDs.

    The task loop already owns at most 100 steps. Give every confirmed older
    step a small evidence share instead of dropping the start of a long task.
    Detailed content is explicitly excerpted; this is not a completion oracle.
    """
    candidates = []
    for entry in history[:-recent_count]:
        if not isinstance(entry, dict): continue
        action, result = entry.get("action"), entry.get("result")
        if not isinstance(action, dict) or not isinstance(result, dict): continue
        if action.get("private_input") is True or entry.get("private_input") is True or result.get("secret_retained") is False: continue
        if result.get("error_code") or result.get("outcome") in {"rejected", "delivered_unconfirmed", "suppressed"}: continue
        kind = action.get("type")
        if kind == "run_command": confirmed = command_verified(action, result)
        elif kind == "read_file": confirmed = isinstance(result.get("content"), str) and result.get("encoding") in {"utf-8", "base64"}
        elif kind == "write_file": confirmed = result.get("verified") is True
        else: confirmed = result.get("outcome") == "verified"
        if not confirmed: continue
        if kind == "read_file" and result.get("encoding") == "base64":
            try: base64.b64decode(result["content"], validate=True)
            except ValueError: continue
        target = entry.get("target")
        if isinstance(target, dict) and (target.get("role") == "AXSecureTextField" or "secure" in str(target.get("subrole", "")).casefold()): continue
        candidates.append(entry)
    if not candidates: return {}

    # Retain each event's identity and evidence, sharing the bounded payload
    # budget fairly. A marker always distinguishes excerpts from full values.
    record_budget = max(96, (MAX_PROGRESS_CHARACTERS - 256) // len(candidates) - 1)
    terms = words(task)

    def excerpt(text: str, cap: int) -> tuple[str, bool]:
        if len(text) <= cap: return text, False
        matches = [m for m in re.finditer(r"[^\W_]+", text, re.UNICODE) if words(m.group()) & terms]
        start = max(0, matches[0].start() - cap // 4) if matches else 0
        return text[start:start + cap], True

    def bounded(value, budget):
        raw = json.dumps(value, ensure_ascii=False, separators=(',', ':'))
        if len(raw) <= budget: return value
        # Preserve field names and numeric/boolean evidence. Do not silently
        # truncate a path, binary value, or claim an excerpt is complete.
        if isinstance(value, str):
            text, _ = excerpt(value, max(16, budget - 45))
            return {"excerpt": text, "omitted_characters": len(value) - len(text)}
        if isinstance(value, dict):
            each = max(32, budget // max(1, len(value)))
            return {key: bounded(item, each) for key, item in value.items()}
        if isinstance(value, list):
            each = max(32, budget // max(1, len(value)))
            return [bounded(item, each) for item in value]
        return value

    facts = []
    for entry in candidates:
        action, result = entry["action"], entry["result"]
        kind = action["type"]
        fact: dict[str, Any] = {"step": entry.get("step"), "type": kind}
        if kind in {"read_file", "write_file"}:
            fact["path"] = result.get("path", action.get("path"))
        elif isinstance(entry.get("target"), dict):
            fact["target"] = {k: v for k, v in entry["target"].items() if k in {"app", "bundle_id", "window_title", "title", "role"}}
        if kind == "read_file":
            fact["evidence"] = {k: result[k] for k in ("content", "encoding", "bytes_returned", "truncated") if k in result}
            if result.get("encoding") == "base64":
                fact["evidence"].pop("content", None)
                fact["evidence"]["content_sha256"] = hashlib.sha256(base64.b64decode(result["content"], validate=True)).hexdigest()
        elif kind == "write_file":
            fact["evidence"] = {k: result[k] for k in ("mode", "bytes_written", "file_size") if k in result}
            fact["evidence"]["verified"] = True
            if isinstance(action.get("content"), str):
                fact["evidence"]["written_content"] = action["content"]
                fact["evidence"]["encoding"] = action.get("encoding", "utf-8")
        elif kind == "run_command":
            fields = () if action.get("operation") else ("content", "encoding", "text")
            checks = [{**actual, **{k: requested[k] for k in fields if k in requested}}
                      for requested, actual in zip(action["checks"], result["checks"])]
            fact["evidence"] = {"exit_code": result["exit_code"], "checks": checks}
            if action.get("operation"): fact["operation"] = action["operation"]
            if isinstance(result.get("stdout"), str) and result["stdout"]:
                fact["evidence"]["stdout"] = result["stdout"]
                fact["evidence"]["stdout_truncated"] = result.get("stdout_truncated", False)
        else:
            fact["evidence"] = {k: result[k] for k in ("message", "verification_scope", "text_verification") if k in result}
            fact["evidence"]["outcome"] = "verified"
            if kind in {"set_value", "type_text"} and isinstance(action.get("text"), str):
                fact["evidence"]["text"] = action["text"]
        compact = bounded(fact, record_budget)
        if len(json.dumps(compact, ensure_ascii=False, separators=(',', ':'))) > record_budget:
            # Nested check lists can exceed a proportional field budget. Keep
            # the step/type and an explicitly incomplete evidence excerpt.
            raw = json.dumps(fact, ensure_ascii=False, separators=(',', ':'))
            evidence, _ = excerpt(raw, max(1, record_budget - 100))
            compact = {"step": entry.get("step"), "type": kind,
                       "evidence_excerpt": evidence, "evidence_omitted": True}
            while evidence and len(json.dumps(compact, ensure_ascii=False, separators=(',', ':'))) > record_budget:
                evidence = evidence[:-1]; compact["evidence_excerpt"] = evidence
        facts.append(compact)
    return {"scope": "earlier_confirmed_events_in_this_task", "historical": True, "facts": facts}
