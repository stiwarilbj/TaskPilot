"""Task-local disagreements; inspection never dispatches an action or a command.

Missing/partial OCR is inconclusive. A reported discrepancy is a request for
inspection, not proof that the model or either source is correct.
"""
from __future__ import annotations

from copy import deepcopy
import hashlib
import re
import unicodedata

from action_contract_generated import validate_action, ActionContractError
from expected_effects import ExpectedEffect, FIELD_ROLES, FILE_EFFECTS, path_key
from local_text_recognition import validate_text_recognition
from observation_context import coordinate_targets, structural_identity, words, observation_indexes
from screen_coordinates import rectangle, CoordinateMappingError

EVIDENCE_CONSISTENCY_VERSION = 1
INSPECTION_SECONDS = 2.0
MAX_INSPECTIONS = 3
LABEL_ROLES = {"AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem", "AXMenuBarItem", "AXTab", "AXLink"}
FILE_FACTS = {"file_read", "file_contents", "file_exists", "directory_exists", "path_absent"}


def normalize(text):
    return " ".join(unicodedata.normalize("NFKC", text).casefold().split()).rstrip(".…")


def secure(element):
    return "secure" in (str(element.get("role", "")) + str(element.get("subrole", ""))).casefold() or element.get("value") == "[secure]"


def labels(element):
    return [value for key in ("title", "label") if isinstance(value := element.get(key), str) and value.strip()]


def agrees(text, aliases, *, partial=False):
    text = normalize(text)
    return bool(text) and any(text == normalize(label) or (partial and
        re.search(r"(?<!\w)" + re.escape(text) + r"(?!\w)", normalize(label))) for label in aliases)


def control_aliases(element):
    if element.get("role") in FIELD_ROLES:
        value = element.get("value")
        return [value] if element.get("value_complete") is True and isinstance(value, str) else []
    return labels(element)


def matches_text(text, element, *, partial=False):
    aliases = control_aliases(element)
    if element.get("role") not in FIELD_ROLES: return agrees(text, aliases, partial=partial)
    # Field values are literal contents, unlike case-insensitive control labels.
    text = " ".join(text.split())
    return bool(text) and any(text == " ".join(value.split()) or (partial and
        re.search(r"(?<!\w)" + re.escape(text) + r"(?!\w)", " ".join(value.split()))) for value in aliases)


def contained(inner, outer):
    return (inner[0] >= outer[0] and inner[1] >= outer[1] and
            inner[0] + inner[2] <= outer[0] + outer[2] and inner[1] + inner[3] <= outer[1] + outer[3])


def text_for(element, observation):
    report = validate_text_recognition(observation)
    if not report or secure(element): return []
    try: bounds = rectangle(element.get("frame"))
    except CoordinateMappingError: return []
    indexes = observation_indexes(observation)
    others = [e for e in indexes.elements_by_pid.get(element.get("pid"), ()) if
              e.get("role") in LABEL_ROLES | FIELD_ROLES and not secure(e) and e.get("id") != element.get("id")]
    matches = []
    for row in report["targets"]:
        windows = indexes.window_candidates(element.get("pid"), row["graphics_window_id"], graphics=True)
        owner = windows[-1] if windows else {}
        if row["pid"] != element.get("pid") or row["confidence"] < 0.9: continue
        if element.get("window_title") and owner.get("title") and element["window_title"] != owner["title"]: continue
        if not contained(rectangle(row["frame"]), bounds): continue
        # Nested/overlapping controls do not establish one label's ownership.
        ambiguous = False
        for other in others:
            try: frame = rectangle(other.get("frame"))
            except CoordinateMappingError: continue
            same = element.get("native_identity") and other.get("native_identity") == element["native_identity"]
            if contained(rectangle(row["frame"]), frame) and not same:
                ambiguous = True; break
        if not ambiguous: matches.append(row)
    return matches


def screen_conflicts(element, observation):
    aliases = control_aliases(element)
    field = element.get("role") in FIELD_ROLES
    if field:
        if element.get("value_complete") is not True or not isinstance(element.get("value"), str) or not element["value"]: return []
    if element.get("role") not in LABEL_ROLES | FIELD_ROLES or not aliases: return []
    return [{"type": "screen_ax_label", "target": target_data(element),
             "sources": [{"source": "accessibility", "values" if field else "labels": aliases},
                         {"source": "screenshot_text", "text": row["text"], "confidence": row["confidence"],
                          "candidate_id": row["candidate_id"]}]} for row in text_for(element, observation)
            if not matches_text(row["text"], element, partial=True) and not (field and agrees(row["text"], labels(element), partial=True))]


def target_data(element):
    return {k: deepcopy(element[k]) for k in ("id", "pid", "role", "title", "window_title", "native_identity", "frame") if k in element}


def validate_disagreement(value, observation, ledger, fail):
    if not isinstance(value, dict) or set(value) - {"element_id", "screenshot_text", "evidence_id"}:
        fail("evidence_disagreement", "must contain only element_id, screenshot_text and optional evidence_id")
    identifier = value.get("element_id")
    if not isinstance(identifier, str) or not identifier.strip():
        fail("evidence_disagreement.element_id", "must reference a current nonsecure control")
    target = observation_indexes(observation or {}).element(identifier)
    if target is None or secure(target): fail("evidence_disagreement.element_id", "must reference a current nonsecure control")
    text = value.get("screenshot_text")
    if not isinstance(text, str) or not text.strip() or len(text) > 256:
        fail("evidence_disagreement.screenshot_text", "must be a nonempty string of at most 256 characters")
    try: text.encode("utf-8")
    except UnicodeEncodeError: fail("evidence_disagreement.screenshot_text", "must contain valid UTF-8 text")
    if "evidence_id" in value:
        evidence = ledger.evidence.get(value["evidence_id"]) if ledger and isinstance(value["evidence_id"], str) else None
        if (not evidence or not evidence["valid"] or not evidence["mutable"] or
                evidence["generation"] != ledger.generation or evidence["fact"].get("type") not in FILE_FACTS):
            fail("evidence_disagreement.evidence_id", "must reference current native file evidence from this task")


class EvidenceConsistency:
    def __init__(self):
        self.pending = []
        self.native_conflicts = []
        self.native_field = None
        self.inspections = self.rejections = 0

    @staticmethod
    def candidates(pinned, before, observation):
        indexes, before_indexes = observation_indexes(observation), observation_indexes(before)
        app = before_indexes.application(pinned.get("pid")) or {}
        current = indexes.application(pinned.get("pid")) or {}
        if any(app.get(k) != current.get(k) for k in ("pid", "name", "bundle_id")): return []
        identity = structural_identity(pinned, before, before_indexes)
        return [e for e in indexes.elements_by_pid.get(pinned.get("pid"), ()) if not secure(e) and
                e.get("role") == pinned.get("role") and e.get("window_title") == pinned.get("window_title") and
                ((pinned.get("native_identity") and e.get("native_identity") == pinned["native_identity"]) or
                 (not pinned.get("native_identity") and e.get("title") == pinned.get("title") and
                  structural_identity(e, observation, indexes) == identity))]

    def targets(self, decision, observation, ledger):
        action = decision.get("action", {})
        indexes = observation_indexes(observation)
        elements = indexes.elements
        targets = []
        if decision.get("evidence_disagreement"):
            ids = [decision["evidence_disagreement"]["element_id"]]
        elif action.get("element_id"): ids = [action["element_id"]]
        elif action.get("type") in {"click", "double_click"}:
            targets = coordinate_targets(action, observation, indexes); ids = []
        elif action.get("type") in {"key", "type_text"}:
            ids = [e.get("id") for e in indexes.elements_by_pid.get(action.get("pid"), ()) if e.get("focused") is True]
        elif decision.get("status") == "done" or "verified" in decision:
            ids = [e.get("id") for e in elements if e.get("role") in LABEL_ROLES and words(e.get("title", "")) & words(ledger.task)]
            ids += [c.get("id") for check in ledger.observation_checks.values()
                    if isinstance(check, ExpectedEffect) and check.kind == "field_value"
                    for c in check.field_candidates(observation)]
            ids += [c.get("id") for pending, before in self.pending if pending["target"].get("pid")
                    for c in self.candidates(pending["target"], before, observation)]
            if self.native_field: ids += [c.get("id") for c in self.native_field[0].field_candidates(observation)]
        else: ids = []
        if action:
            for ref in ledger.prerequisites(ledger.action_requirements(decision)):
                check = ledger.observation_checks.get(ref)
                if isinstance(check, ExpectedEffect) and check.kind == "field_value":
                    ids += [c.get("id") for c in check.field_candidates(observation)]
        targets += [e for identifier in dict.fromkeys(ids) for e in indexes.elements_by_id.get(identifier, ()) if not secure(e)]
        return targets

    def note_native_check(self, check, checked, prior):
        """Compare only an attributable explicit negative against prior proof."""
        if not prior or check.get("type") not in FILE_EFFECTS: return
        result = ExpectedEffect(check, {}).native_check(checked)
        if result["outcome"] == "verified": return
        rows = checked.get("checks", []) if isinstance(checked, dict) else []
        if (result.get("reason") != "expected_file_mismatch" or len(rows) != 1 or
                rows[0].get("verified") is not False or rows[0].get("reason") != "The requested outcome did not match"):
            return  # Unavailable/malformed readbacks are not opposing facts.
        conflict = {"type": "native_file_check", "target": {"path": check["path"]}, "check": deepcopy(check),
                    "sources": [{"source": "prior_native_proof", "verified": True,
                                 "fact_type": prior["fact"]["type"], "content_sha256": prior["fact"].get("content_sha256")},
                                {"source": "native_readback", "verified": False, "reason": rows[0]["reason"]}]}
        if conflict not in self.native_conflicts: self.native_conflicts.append(conflict)

    def note_native_read(self, action, prior, fresh):
        if action.get("type") != "read_file" or not prior or not fresh: return
        old, current = prior["fact"], fresh["fact"]
        if (old.get("path") != current.get("path") or current.get("type") != "file_read" or
                not old.get("content_sha256") or old["content_sha256"] == current.get("content_sha256")): return
        conflict = {"type": "native_file_read", "target": {"path": old["path"]}, "read_action": deepcopy(action),
                    "sources": [{"source": "prior_native_proof", "content_sha256": old["content_sha256"]},
                                {"source": "native_readback", "content_sha256": current["content_sha256"]}]}
        if conflict not in self.native_conflicts: self.native_conflicts.append(conflict)

    def conflicts(self, decision, observation, ledger):
        targets = self.targets(decision, observation, ledger)
        found = [*self.native_conflicts, *[conflict for target in targets for conflict in screen_conflicts(target, observation)]]
        self.native_conflicts = []
        for previous, before in self.pending:
            if previous["type"] in {"native_file_check", "native_file_read"}:
                # Reconciliation of uncertain file outcomes is local, never an
                # excuse to rerun their originating command or mutation.
                found.append(previous); continue
            candidates = self.candidates(previous["target"], before, observation)
            if not any(e.get("id") == target.get("id") for e in candidates for target in targets): continue
            if not any(c.get("target", {}).get("id") in {e.get("id") for e in candidates} for c in found):
                found.append({**previous, "target": target_data(candidates[0]) if len(candidates) == 1 else previous["target"],
                              "reason": "unresolved_source_disagreement"})
        if self.native_field:
            effect, source = self.native_field
            candidates = effect.field_candidates(observation)
            if len(effect.unique(candidates)) == 1 and any(t.get("pid") == candidates[0].get("pid") and
                    t.get("window_title") == candidates[0].get("window_title") for t in targets):
                target = candidates[0]
                if target.get("value_complete") is True and isinstance(target.get("value"), str) and target["value"] != effect.spec["value"]:
                    found.append({"type": "native_field_readback", "target": target_data(target), "sources": [
                        {"source": "native_readback", "value_sha256": source},
                        {"source": "accessibility", "value_sha256": hashlib.sha256(target["value"].encode()).hexdigest()}]})
        reported = decision.get("evidence_disagreement")
        if reported:
            found.append({"type": "reported_disagreement", "target": target_data(targets[0]),
                          "sources": [{"source": "screenshot_report", "text": reported["screenshot_text"], "untrusted": True},
                                      {"source": "accessibility", "values" if targets[0].get("role") in FIELD_ROLES else "labels": control_aliases(targets[0])}],
                          **({"evidence_id": reported["evidence_id"]} if "evidence_id" in reported else {})})
        unique = []
        for conflict in found:
            if conflict not in unique: unique.append(conflict)
        return unique[:4]

    def remember_native(self, action, before, result):
        self.native_field = None
        if action.get("type") != "set_value" or result.get("text_verification") not in {"matched", "already_matched"}: return
        target = next((e for e in before.get("elements", []) if e.get("id") == action.get("element_id")), None)
        if not target or secure(target) or target.get("role") not in FIELD_ROLES: return
        effect = ExpectedEffect({"type": "field_value", "element_id": target["id"], "value": action["text"]}, before)
        self.native_field = effect, hashlib.sha256(action["text"].encode()).hexdigest()

    def inspect(self, conflicts, before, ledger, observe, readback, discard, now, sleep):
        """At most three accepted captures within one shared two-second budget."""
        start = now(); deadline = start + INSPECTION_SECONDS
        latest = None; refreshed = []; previous = None; stable = 0; resolved = False; count = 0
        file_reads = {}
        def inspect_read(method, payload):
            try: return readback(method, payload)
            except Exception as error:
                code = getattr(error, "code", "inspection_unavailable")
                if code in {"cancelled", "permission_denied", "protected_target", "secure_input"}: raise
                return {"inspection_error": code}
        for conflict in conflicts:
            if conflict.get("evidence_id"):
                evidence = ledger.evidence[conflict["evidence_id"]]
                # Historical native output is revoked before a fresh read.
                ledger.invalidate(lambda e: e is evidence)
                fact = evidence["fact"]
                action = {"type": "read_file", "path": fact["path"]} if fact["type"] in {"file_read", "file_contents"} else None
                file_reads[conflict["evidence_id"]] = (evidence, action)
        try:
            for attempt in range(MAX_INSPECTIONS):
                remaining = deadline - now()
                if remaining <= 0: break
                pid = conflicts[0]["target"].get("pid")
                current = observe(pid, max(1, int(remaining * 1000)))
                discard(latest); latest = current
                ledger.observe(current); self.inspections += 1; count += 1
                refreshed = []; signature = []; resolved = True
                for conflict in conflicts:
                    if conflict["type"] == "native_file_read":
                        if now() >= deadline: resolved = False; continue
                        path = conflict["target"]["path"]
                        ledger.invalidate(lambda e: e["mutable"] and e["fact"].get("path") == path)
                        known = set(ledger.evidence)
                        action = conflict["read_action"]
                        value = inspect_read("recheck", action)
                        ledger.record_action(action, value, recheck=True)
                        fresh = [e for key, e in ledger.evidence.items() if key not in known and e["valid"] and
                                 e["fact"].get("type") == "file_read" and e["fact"].get("path") == path]
                        actual = fresh[-1]["fact"] if fresh else {}
                        confirmed = bool(actual)
                        refreshed.append({"type": "native_file_read", "target": conflict["target"],
                            "content_sha256": actual.get("content_sha256"), "state": "current_readback" if confirmed else "unconfirmed",
                            **({"inspection_error": value["inspection_error"]} if value.get("inspection_error") else {})})
                        signature.append((path, actual.get("content_sha256"), confirmed))
                        resolved &= confirmed
                        continue
                    if conflict["type"] == "native_file_check":
                        if now() >= deadline: resolved = False; continue
                        check = conflict["check"]
                        ledger.invalidate(lambda e: e["mutable"] and ledger.matches(check, e))
                        value = inspect_read("check_effect", check)
                        checked = ExpectedEffect(check, {}).native_check(value)
                        rows = value.get("checks", []) if isinstance(value, dict) else []
                        actual = rows[0] if len(rows) == 1 and isinstance(rows[0], dict) else {}
                        negative = (checked.get("reason") == "expected_file_mismatch" and actual.get("verified") is False and
                                    actual.get("reason") == "The requested outcome did not match")
                        confirmed = checked["outcome"] == "verified" or negative
                        if checked["outcome"] == "verified": ledger.record_effect(check, checked["evidence"])
                        refreshed.append({"type": "native_file_check", "target": conflict["target"],
                            "verified": actual.get("verified"), "reason": actual.get("reason"),
                            "state": "current_readback" if confirmed else "unconfirmed",
                            **({"inspection_error": value["inspection_error"]} if value.get("inspection_error") else {})})
                        signature.append((check["path"], check["type"], actual.get("verified"), actual.get("content_sha256"), confirmed))
                        resolved &= confirmed
                        continue
                    candidates = self.candidates(conflict["target"], before, current)
                    if len(candidates) != 1:
                        refreshed.append({"type": conflict["type"], "state": "target_missing_or_changed"}); resolved = False; continue
                    target = candidates[0]; rows = text_for(target, current)
                    aliases = control_aliases(target)
                    local_conflicts = screen_conflicts(target, current)
                    agreement = bool(rows) and any(matches_text(row["text"], target) for row in rows) and not local_conflicts
                    # Two fresh complete AX reads can supersede an earlier
                    # native field readback, never an unresolved screenshot claim.
                    if conflict["type"] == "native_field_readback":
                        agreement = target.get("value_complete") is True and isinstance(target.get("value"), str) and (
                            not rows or all(matches_text(row["text"], target, partial=True) for row in rows))
                    resolved &= agreement
                    refreshed.append({"target": target_data(target), "accessibility": aliases,
                                      "screenshot_text": [{"text": r["text"], "confidence": r["confidence"]} for r in rows],
                                      "state": "agree" if agreement else "unconfirmed", "conflicts": local_conflicts})
                    signature.append((target.get("native_identity"), target.get("title"), target.get("value"),
                                      tuple(sorted(target.get("frame", {}).items())), target.get("window_title"),
                                      tuple(r["text"] for r in rows), agreement))
                for ref, (evidence, action) in file_reads.items():
                    if now() >= deadline: resolved = False; break
                    fact = evidence["fact"]
                    if action:
                        ledger.invalidate(lambda e: e["mutable"] and e["fact"].get("path") == fact["path"])
                        known = set(ledger.evidence)
                        value = inspect_read("recheck", action)
                        try: action = validate_action(action)
                        except ActionContractError: resolved = False; continue
                        ledger.record_action(action, value, recheck=True)
                        fresh = [e for key, e in ledger.evidence.items() if key not in known and e["valid"] and
                                 e["fact"].get("type") == "file_read" and e["fact"].get("path") == fact["path"]]
                        actual = fresh[-1]["fact"] if fresh else {}
                        agreement = bool(actual) and actual.get("encoding") == "utf-8" and any(
                            c.get("evidence_id") == ref and c["sources"][0].get("text") == actual.get("content") for c in conflicts)
                        detail = {"evidence_id": ref, "source": "native_readback", "path": fact["path"],
                                  "previous_sha256": fact.get("content_sha256"), "current_sha256": actual.get("content_sha256"),
                                  "state": "agree_with_report" if agreement else "unconfirmed"}
                    else:
                        value = inspect_read("check_effect", {"type": fact["type"], "path": fact["path"]})
                        agreement = False  # Existence alone cannot verify screenshot text.
                        detail = {"evidence_id": ref, "source": "native_readback", "path": fact["path"],
                                  "state": "unconfirmed", "check": value.get("checks", [])}
                    refreshed.append(detail); resolved &= agreement
                    signature.append((ref, detail.get("current_sha256"), agreement))
                stable = stable + 1 if signature == previous else 1
                previous = signature
                if resolved and stable >= 2: break
                if attempt + 1 < MAX_INSPECTIONS and now() < deadline: sleep(min(0.1 * (attempt + 1), deadline - now()))
            resolved = resolved and stable >= 2 and now() <= deadline
            if latest is None: raise RuntimeError("TaskPilot could not inspect contradictory evidence before its deadline")
            self.native_field = None
            self.pending = [] if resolved else [(deepcopy(c), deepcopy(before)) for c in conflicts]
            self.rejections += 1
            return latest, {"outcome": "rejected", "error_code": "evidence_conflict", "delivery": "not_dispatched",
                           "message": "Reconsider the intended target using refreshed evidence; no action was delivered",
                           "disagreements": conflicts, "refreshed_evidence": refreshed,
                           "resolution": "consistent_fresh_reads" if resolved else "unresolved",
                           "observation_revision": latest["observation_revision"], "inspection_count": count,
                           "elapsed_seconds": round(now() - start, 3)}
        except BaseException:
            discard(latest)
            raise
