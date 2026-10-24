"""Private, conservative policy for explicit user stop-before instructions.

The same small set of verbs and control rules is implemented by the Swift
delivery gate. The version is carried in task startup so older runtimes cannot
silently run without the policy.
"""
from __future__ import annotations

import re
from typing import Any

from observation_context import coordinate_targets, coordinates_are_ambiguous, observation_indexes

STOP_BOUNDARY_POLICY_VERSION = 1

_ACTIONS = {
    "send": ("Send", r"send(?:ing)?"),
    "publish": ("Publish/Post", r"publish(?:ing)?|post(?:ing)?"),
    "submit": ("Submit", r"submit(?:ting)?"),
    "purchase": ("Purchase/Place order", r"purchase|buy(?:ing)?|order(?:ing)?|checkout|check\s+out|place\s+(?:(?:an?|the|your)\s+)?order"),
    "deploy": ("Deploy", r"deploy(?:ing)?"),
}
_VERB_PATTERN = (r"(?:send(?:ing)?|publish(?:ing)?|post(?:ing)?|submit(?:ting)?|"
                 r"purchase|buy(?:ing)?|order(?:ing)?|checkout|check\s+out|place\s+(?:(?:an?|the|your)\s+)?order|deploy(?:ing)?)")
_NEGATIVE = re.compile(
    r"\b(?:don[’']t|do\s+not|never|without|stop\s+before)\s+"
    r"(?:(?:click(?:\s+on)?|press(?:\s+on)?|hit|tap|activate|trigger|ever|actually|use)\s+)*"
    rf"(?P<verbs>{_VERB_PATTERN}(?:\s+(?:or|and)\s+{_VERB_PATTERN})*)\b",
    re.IGNORECASE,
)
_VERBS = re.compile(rf"{_VERB_PATTERN}\b", re.IGNORECASE)
_POSITIVE = re.compile(
    r"\b(?:you\s+(?:may|can)(?:\s+now)?|go\s+ahead\s+and|please\s+(?:go\s+ahead\s+and\s+)?|"
    r"actually\s*[,;:]?\s*|now\s+)\s*"
    rf"(?P<verb>{_VERB_PATTERN})(?:\s+now)?\b",
    re.IGNORECASE,
)
_CORRECTION_POSITIVE = re.compile(
    rf"\b(?:user\s+correction|correction|new\s+instruction)\s*:\s*(?:please\s+)?(?P<verb>{_VERB_PATTERN})\b",
    re.IGNORECASE,
)


def _action_for_verb(verb: str) -> str:
    value = re.sub(r"\s+", " ", verb.casefold())
    if value.startswith("send"):
        return "send"
    if value.startswith(("publish", "post")):
        return "publish"
    if value.startswith("submit"):
        return "submit"
    if value.startswith(("purchase", "buy", "order", "checkout", "check out", "place ")):
        return "purchase"
    return "deploy"


def _visible_text_and_offsets(text: str, references: list[dict] | None) -> tuple[str, list[int]]:
    """Mask quoted spans and exact-input UTF-8 ranges without changing offsets."""
    chars = list(text)
    mask = [False] * len(chars)
    quote_pairs = {'"': '"', "'": "'", "“": "”", "‘": "’", "`": "`"}
    quote_end: str | None = None
    byte_offsets: list[int] = []
    offset = 0
    for char in chars:
        byte_offsets.append(offset)
        offset += len(char.encode("utf-8"))
    raw = text.encode("utf-8")
    ranges: list[tuple[int, int]] = []
    for ref in references or []:
        if not isinstance(ref, dict):
            continue
        start, length = ref.get("utf8_start"), ref.get("utf8_length")
        value = ref.get("value")
        if (type(start) is not int or type(length) is not int or not isinstance(value, str)
                or start < 0 or length <= 0 or start > len(raw) or length > len(raw) - start):
            continue
        try:
            exact_value = raw[start:start + length].decode("utf-8")
        except UnicodeDecodeError:
            continue
        if exact_value == value:
            ranges.append((start, start + length))
    # Markdown block quotes are quoted material too. Mask complete lines before
    # scanning paired quotes so a quoted negation cannot become task policy.
    line_start = 0
    while line_start < len(chars):
        line_end = line_start
        while line_end < len(chars) and chars[line_end] not in {"\n", "\r"}:
            line_end += 1
        first = line_start
        while first < line_end and chars[first] in {" ", "\t"}:
            first += 1
        if first < line_end and chars[first] == ">":
            for index in range(line_start, line_end):
                mask[index] = True
        line_start = line_end + 1
    for index, char in enumerate(chars):
        byte_start = byte_offsets[index]
        byte_end = byte_start + len(char.encode("utf-8"))
        if any(byte_start < end and start < byte_end for start, end in ranges):
            mask[index] = True
        if mask[index]:
            continue
        if quote_end is not None:
            previous = chars[index - 1] if index else ""
            following = chars[index + 1] if index + 1 < len(chars) else ""
            if char in {"'", "’"} and previous.isalnum() and following.isalnum():
                mask[index] = True
                continue
            mask[index] = True
            if char == quote_end:
                quote_end = None
            continue
        # Apostrophes inside contractions (don't) and possessives are not quote
        # delimiters. Straight single quotes still mask quoted source values.
        if char in {"'", "’"}:
            previous = chars[index - 1] if index else ""
            following = chars[index + 1] if index + 1 < len(chars) else ""
            if previous.isalnum() and following.isalnum():
                continue
        if char in quote_pairs:
            quote_end = quote_pairs[char]
            mask[index] = True
    visible = "".join(" " if hidden else char for char, hidden in zip(chars, mask))
    return visible, byte_offsets


def detect_stop_boundaries(text: str, exact_input_references: list[dict] | None = None) -> list[dict[str, Any]]:
    """Return active explicit boundaries, retaining only the last clear rule.

    A later clear positive instruction can lift an earlier restriction. Vague
    wording has no event and therefore leaves the restriction active.
    """
    if not isinstance(text, str) or not text:
        return []
    visible, byte_offsets = _visible_text_and_offsets(text, exact_input_references)
    events: list[tuple[int, str, re.Match[str], re.Match[str] | None]] = []
    for match in _NEGATIVE.finditer(visible):
        for verb in _VERBS.finditer(match.group("verbs")):
            events.append((match.start("verbs") + verb.start(), "negative", match, verb))
    events.extend((m.start("verb"), "positive", m, None) for m in _POSITIVE.finditer(visible))
    events.extend((m.start("verb"), "positive", m, None) for m in _CORRECTION_POSITIVE.finditer(visible))
    events.sort(key=lambda item: item[0])
    active: dict[str, dict[str, Any]] = {}
    active: dict[str, tuple[dict[str, Any], int]] = {}
    for position, kind, match, verb_match in events:
        verb = verb_match.group(0) if verb_match is not None else match.group("verb")
        action = _action_for_verb(verb)
        if kind == "positive":
            active.pop(action, None)
            continue
        start, end = match.span()
        byte_start = byte_offsets[start]
        byte_end = byte_offsets[end - 1] + len(text[end - 1].encode("utf-8"))
        label = _ACTIONS[action][0]
        active[action] = ({"action": action, "label": label,
                           "source": text[start:end], "utf8_start": byte_start,
                           "utf8_length": byte_end - byte_start}, position)
    return [record for record, _ in sorted(active.values(), key=lambda item: item[1])]


class BoundaryViolation(ValueError):
    def __init__(self, code: str, message: str, action: str | None = None):
        super().__init__(message)
        self.code = code
        self.action = action


_FINAL_TARGET_WORDS = {
    "send": re.compile(r"\b(?:send|sending|deliver|dispatch)\b", re.I),
    "publish": re.compile(r"\b(?:publish|publishing|post|posting)\b", re.I),
    "submit": re.compile(r"\b(?:submit|submitting)\b", re.I),
    "purchase": re.compile(r"\b(?:purchase|buy|buying|order|ordering|checkout|check\s+out|place(?:\s+\w+){0,2}\s+order)\b", re.I),
    "deploy": re.compile(r"\b(?:deploy|deploying|release)\b", re.I),
}
_ACTION_ROLES = {"AXButton", "AXDefaultButton", "AXMenuItem", "AXMenuBarItem", "AXLink",
                 "AXPopUpButton", "AXRadioButton", "AXCheckBox", "AXTab", "AXRow", "AXCell",
                 "AXOutline", "AXTable", "AXList"}
_GENERIC_FINAL_CONTROLS = {"ok", "continue", "done", "yes", "confirm", "finish", "go"}
_TEXT_ROLES = {"AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"}


def _target_for(action: dict[str, Any], observation: dict[str, Any]) -> dict[str, Any] | None:
    identifier = action.get("element_id")
    if isinstance(identifier, str):
        for element in observation.get("elements", []):
            if isinstance(element, dict) and element.get("id", element.get("element_id")) == identifier:
                return element
        return None
    if action.get("type") in {"click", "double_click"} and "x" in action and "y" in action:
        if coordinates_are_ambiguous(action, observation):
            return None
        targets = coordinate_targets(action, observation)
        return targets[0] if targets else None
    if action.get("type") == "key":
        indexes = observation_indexes(observation)
        pid = action.get("pid")
        focused = [element for element in indexes.elements_by_pid.get(pid, ())
                   if isinstance(element, dict) and element.get("focused") is True]
        return focused[0] if len(focused) == 1 else None
    return None


def _target_labels(target: dict[str, Any]) -> list[str]:
    labels: list[str] = []
    # Window and application names describe context, not the action performed
    # by this control (for example, the Mail app is not a Send button).
    for key in ("title", "label", "name", "description", "help"):
        value = target.get(key)
        if isinstance(value, str) and value.strip():
            labels.append(value.strip())
    for node in target.get("structure", []) if isinstance(target.get("structure"), list) else []:
        if not isinstance(node, dict):
            continue
        if node.get("role") == "AXApplication":
            continue
        for value in [node.get("label"), *(node.get("labels") if isinstance(node.get("labels"), list) else [])]:
            if isinstance(value, str) and value.strip():
                labels.append(value.strip())
    return labels


def _matches_boundary(texts: list[str], boundary: dict[str, Any]) -> bool:
    pattern = _FINAL_TARGET_WORDS[boundary["action"]]
    return any(pattern.search(text) for text in texts)


def validate_action_against_boundaries(action: dict[str, Any], observation: dict[str, Any],
                                       boundaries: list[dict[str, Any]]) -> None:
    """Reject a finalizing or opaque action before the native bridge call."""
    if not boundaries:
        return
    kind = action.get("type")
    by_action = {row["action"]: row for row in boundaries}
    if kind in {"read_file", "write_file", "focus", "set_value", "type_text", "scroll", "wait", "none", "launch_app"}:
        return
    if kind == "run_command":
        operation = action.get("operation")
        if isinstance(operation, dict) and operation.get("type") in {
            "create_directory", "copy_file", "move_file", "remove_file", "remove_empty_directory", "print_text"
        }:
            return
        raise BoundaryViolation("stop_boundary_uncertain",
            "TaskPilot stopped before an opaque command because it cannot establish that the command would preserve the requested boundary")
    if kind in {"press", "click", "double_click"}:
        target = _target_for(action, observation)
        if target is None:
            raise BoundaryViolation("stop_boundary_uncertain",
                "TaskPilot stopped before a control action because the intended control is not identified in the current observation")
        role = target.get("role")
        labels = _target_labels(target)
        safe_text_click = kind in {"click", "double_click"} and role in _TEXT_ROLES
        if (role not in _ACTION_ROLES and not safe_text_click) or not labels:
            raise BoundaryViolation("stop_boundary_uncertain",
                "TaskPilot stopped before a control action because its current role and label do not establish that it is safe")
        primary = [str(target.get(key) or "").strip() for key in ("title", "label", "name", "description")]
        primary = [value for value in primary if value]
        generic = not primary or primary[0].casefold() in _GENERIC_FINAL_CONTROLS
        for boundary in boundaries:
            if _matches_boundary(primary[:1], boundary) or (generic and _matches_boundary(labels, boundary)):
                raise BoundaryViolation("stop_boundary_rejected",
                    f"TaskPilot stopped before {boundary['label']} as the request instructed", boundary["action"])
        if generic:
            raise BoundaryViolation("stop_boundary_uncertain",
                "TaskPilot held a generic control because its effect on the stop-before boundary is unclear")
        return
    if kind == "key":
        key = str(action.get("key") or "").casefold()
        modifiers = {str(value).casefold() for value in action.get("modifiers", []) if isinstance(value, str)}
        target = _target_for(action, observation)
        if target is None:
            raise BoundaryViolation("stop_boundary_uncertain",
                "TaskPilot stopped before a keyboard action because the focused control is not identified in the current observation")
        role = target.get("role")
        labels = _target_labels(target)
        text_role = role in _TEXT_ROLES
        editing_keys = {"left", "right", "up", "down", "home", "end", "pageup", "pagedown",
                        "backspace", "delete", "tab", "escape"}
        if modifiers:
            command_edit = modifiers <= {"command", "cmd"} and key in {"a", "c", "v", "x", "z"} and text_role
            if not command_edit:
                raise BoundaryViolation("stop_boundary_uncertain",
                    "TaskPilot held a keyboard shortcut because its effect on the stop-before boundary is not established")
            return
        if key in {"return", "enter"}:
            for boundary in boundaries:
                if role in _ACTION_ROLES and _matches_boundary(labels, boundary):
                    raise BoundaryViolation("stop_boundary_rejected",
                        f"TaskPilot stopped before {boundary['label']} as the request instructed", boundary["action"])
            boundary = boundaries[0]
            raise BoundaryViolation("stop_boundary_uncertain",
                f"TaskPilot stopped before Return because its effect on the {boundary['label']} boundary is uncertain", boundary["action"])
        if key in {"space", " "} and role in _ACTION_ROLES:
            for boundary in boundaries:
                if _matches_boundary(labels, boundary):
                    raise BoundaryViolation("stop_boundary_rejected",
                        f"TaskPilot stopped before {boundary['label']} as the request instructed", boundary["action"])
            raise BoundaryViolation("stop_boundary_uncertain",
                f"TaskPilot held Space because it activates the focused control and could cross the {boundaries[0]['label']} boundary")
        if (text_role and key in editing_keys) or key in {"tab", "left", "right", "up", "down", "escape"}:
            return
        if text_role and key in {"space", " "}:
            return
        raise BoundaryViolation("stop_boundary_uncertain",
            f"TaskPilot held the keyboard action because its effect on the {boundaries[0]['label']} boundary is not established")
    if kind in {"navigate_browser", "open_route"}:
        target = str(action.get("url") or action.get("route_id") or action.get("query") or "")
        for boundary in boundaries:
            if _matches_boundary([target], boundary):
                raise BoundaryViolation("stop_boundary_rejected",
                    f"TaskPilot stopped before navigating to a {boundary['label']} destination", boundary["action"])
        return
    # Unsupported action kinds are rejected by the action contract. Any new
    # owner/action added later fails closed while a user boundary is active.
    raise BoundaryViolation("stop_boundary_uncertain",
        "TaskPilot held this action because its effect could cross a requested stop-before boundary")
