"""Strict response contracts. No target, command, or content is synthesized."""
from __future__ import annotations

import base64
import json
import math
from typing import Any
from urllib.parse import urlparse

VALIDATION_VERSION = 2
VALID_ACTIONS = {"none", "press", "focus", "set_value", "click", "double_click", "type_text", "key", "scroll", "launch_app", "open_route", "wait", "read_file", "write_file", "run_command", "navigate_browser"}
KEYS = {"return", "enter", "tab", "space", "delete", "backspace", "escape", "left", "right", "down", "up", "home", "end", "page_up", "page_down", "a", "c", "v", "x", "z", "f", "l", "w", "q", "n", "s", "r", *"0123456789"}


class ResponseValidationError(RuntimeError):
    pass


def fail(path: str, expectation: str) -> None:
    raise ResponseValidationError(f"{path} {expectation}")


def extract_json_object(text: str) -> dict[str, Any]:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                fail("response", "contains duplicate object keys")
            result[key] = value
        return result
    def constant(_):
        fail("response", "must contain only finite numbers")
    decoder = json.JSONDecoder(object_pairs_hook=pairs, parse_constant=constant)
    cleaned = text.strip()
    # Scan only outer containers. Never recover an inner object from a broken
    # outer object or array, and never choose between multiple objects.
    if cleaned.startswith('"'):
        fail("response", "must contain one object, not a quoted JSON value")
    containers = []
    index = 0
    while index < len(cleaned):
        if cleaned[index] in "}]":
            fail("response", "contains unmatched outer punctuation")
        if cleaned[index] not in "{[":
            index += 1
            continue
        try:
            value, end = decoder.raw_decode(cleaned, index)
        except (ValueError, RecursionError):
            fail("response", "must contain one complete JSON object")
        containers.append(value)
        index = end
    if len(containers) != 1 or not isinstance(containers[0], dict):
        fail("response", "must contain exactly one JSON object")
    result = containers[0]
    def finite(value):
        if isinstance(value, float) and not math.isfinite(value):
            fail("response", "must contain only finite numbers")
        if isinstance(value, dict):
            for item in value.values(): finite(item)
        elif isinstance(value, list):
            for item in value: finite(item)
    finite(result)
    return result


def string(value: Any, path: str, nonempty: bool = False) -> None:
    if not isinstance(value, str): fail(path, "must be a string")
    if nonempty and not value.strip(): fail(path, "must be a nonempty string")
    try: value.encode("utf-8")
    except UnicodeEncodeError: fail(path, "must contain valid UTF-8 text")


def number(value: Any, path: str, low: float, high: float, integer: bool = False) -> None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or (integer and not isinstance(value, int)):
        fail(path, "must be an integer" if integer else "must be a number")
    if not low <= value <= high or (isinstance(value, float) and not math.isfinite(value)):
        fail(path, f"must be finite and between {low:g} and {high:g}")


def command_contract(action: dict[str, Any]) -> None:
    if "command" not in action and "argv" not in action:
        fail("action.command", "is required when argv is absent")
    if "command" in action and "argv" in action:
        fail("action", "requires exactly one of command or argv")
    if "command" in action:
        source = action["command"]
        if "\0" in source or len(source.encode("utf-8")) > 16384:
            fail("action.command", "must contain no NUL bytes and at most 16384 bytes")
    if "argv" in action:
        argv = action["argv"]
        if not isinstance(argv, list) or not 1 <= len(argv) <= 256:
            fail("action.argv", "must be a list of 1 to 256 strings")
        for index, item in enumerate(argv):
            string(item, f"action.argv[{index}]", index == 0)
            if "\0" in item: fail(f"action.argv[{index}]", "must contain no NUL bytes")
        if sum(len(item.encode("utf-8")) + 1 for item in argv) > 16384:
            fail("action.argv", "must contain at most 16384 bytes")
    if "checks" not in action: return
    checks = action["checks"]
    if not isinstance(checks, list) or not 1 <= len(checks) <= 16:
        fail("action.checks", "must be a list of 1 to 16 outcome checks")
    for index, check in enumerate(checks):
        path = f"action.checks[{index}]"
        if not isinstance(check, dict): fail(path, "must be an object")
        kind = check.get("type")
        if not isinstance(kind, str) or kind not in {"file_exists", "directory_exists", "path_absent", "file_contents", "stdout_equals"}:
            fail(path + ".type", "must be a supported outcome check")
        allowed = {"type", "text"} if kind == "stdout_equals" else {"type", "path", "content", "encoding"} if kind == "file_contents" else {"type", "path"}
        if set(check) - allowed: fail(path, "contains unsupported parameters")
        if kind == "stdout_equals":
            string(check.get("text"), path + ".text")
            if "\0" in check["text"] or len(check["text"].encode("utf-8")) > 65536:
                fail(path + ".text", "must contain no NUL bytes and at most 65536 bytes")
            continue
        string(check.get("path"), path + ".path", True)
        if not check["path"].startswith(("/", "~/")) or "\0" in check["path"]:
            fail(path + ".path", "must be an absolute or ~/ path without NUL bytes")
        if kind == "file_contents":
            string(check.get("content"), path + ".content")
            encoding = check.get("encoding", "utf-8")
            if not isinstance(encoding, str) or encoding not in {"utf-8", "utf8", "base64"}:
                fail(path + ".encoding", "must be utf-8 or base64")
            try:
                data = base64.b64decode(check["content"], validate=True) if encoding == "base64" else check["content"].encode("utf-8")
            except ValueError: fail(path + ".content", "must be valid base64 for this encoding")
            if len(data) > 2097152: fail(path + ".content", "must contain at most 2 MiB")


def normalize_action(value: Any, observation: dict[str, Any] | None = None) -> dict[str, Any]:
    if not isinstance(value, dict): fail("action", "must be an object")
    action = dict(value)
    kind = action.get("type")
    if not isinstance(kind, str) or kind not in VALID_ACTIONS: fail("action.type", "must be a supported action")
    # Coordinate values have no authority when a semantic click target is
    # supplied. Preserve existing element precedence without guessing a target.
    if kind == "click" and action.get("element_id"):
        action["type"] = kind = "press"
        action.pop("x", None); action.pop("y", None)
    for key in ("element_id", "text", "key", "app", "bundle_id", "route_id", "path", "content", "encoding", "mode", "command", "working_directory", "url", "query", "browser"):
        if key in action: string(action[key], f"action.{key}", key not in {"content", "text"})
    for key in ("path", "working_directory"):
        if key in action and (not action[key].startswith(("/", "~/")) or "\0" in action[key]):
            fail(f"action.{key}", "must be an absolute or ~/ path without NUL bytes")
    if "pid" in action: number(action["pid"], "action.pid", 1, 2147483647, integer=True)
    if ("x" in action) != ("y" in action): fail("action", "coordinates require both x and y")
    for key in ("x", "y"):
        if key in action: number(action[key], f"action.{key}", 0, 1000)
    for key in ("delta_x", "delta_y"):
        if key in action: number(action[key], f"action.{key}", -2000, 2000, integer=True)
    for key, low, high, integer in (("seconds", .2, 15, False), ("timeout_seconds", .2, 900, False), ("max_bytes", 1, 131072, True)):
        if key in action: number(action[key], f"action.{key}", low, high, integer)
    if "create_parents" in action and type(action["create_parents"]) is not bool: fail("action.create_parents", "must be a boolean")
    if "modifiers" in action:
        if not isinstance(action["modifiers"], list) or any(not isinstance(m, str) or m.lower() not in {"command", "cmd", "shift", "option", "alt", "control", "ctrl"} for m in action["modifiers"]):
            fail("action.modifiers", "must be a list of supported modifier names")
    required = {"press": ("element_id",), "focus": ("element_id",), "set_value": ("element_id", "text"), "type_text": ("text",), "key": ("key",), "open_route": ("route_id",), "read_file": ("path",), "write_file": ("path", "content")}
    for key in required.get(kind, ()):
        if key not in action: fail(f"action.{key}", "is required")
    if kind == "run_command": command_contract(action)
    elif "argv" in action or "checks" in action: fail("action", "argv and checks are only supported for run_command")
    if kind == "type_text" and not action["text"]: fail("action.text", "must be a nonempty string")
    if kind in {"click", "double_click"} and not action.get("element_id"):
        if "x" not in action: fail("action", f"{kind} requires an element id or visible coordinates")
        if "pid" not in action: fail("action.pid", "is required for coordinate clicks")
    if "x" in action and not action.get("element_id") and "pid" not in action:
        fail("action.pid", "is required for coordinate targets")
    if kind == "scroll" and not any(action.get(k, 0) for k in ("delta_x", "delta_y")): fail("action", "scroll requires a nonzero delta")
    if kind == "key" and action["key"].lower() not in KEYS: fail("action.key", "must be a supported key name")
    if kind == "launch_app" and not (action.get("app") or action.get("bundle_id")): fail("action", "launch_app requires an app name or bundle id")
    if kind == "navigate_browser":
        if not (action.get("url") or action.get("query")): fail("action", "navigate_browser requires url or query")
        if "url" in action:
            parsed = urlparse(action["url"])
            if parsed.scheme not in {"http", "https"} or not parsed.netloc: fail("action.url", "must be an http/https URL")
    if "encoding" in action and action["encoding"] not in {"utf-8", "utf8", "base64"}: fail("action.encoding", "must be utf-8 or base64")
    if "mode" in action and action["mode"] not in {"overwrite", "append"}: fail("action.mode", "must be overwrite or append")
    if kind == "write_file" and action.get("encoding") == "base64":
        try: base64.b64decode(action["content"], validate=True)
        except ValueError: fail("action.content", "must be valid base64 for this encoding")
    if observation is not None:
        elements = {e["id"]: e for e in observation.get("elements", []) if isinstance(e, dict) and "id" in e}
        if "element_id" in action:
            element = elements.get(action["element_id"])
            if element is None: fail("action.element_id", "must reference the current observation")
            if "pid" in action and action["pid"] != element.get("pid"): fail("action.pid", "must match the selected element's app")
        elif "pid" in action:
            if action["pid"] not in {app.get("pid") for app in observation.get("applications", []) if isinstance(app, dict)}:
                fail("action.pid", "must reference an app in the current observation")
        if kind == "open_route":
            routes = observation.get("system_context", {}).get("task_routes", [])
            if action["route_id"] not in {r.get("route_id") for r in routes if isinstance(r, dict)}:
                fail("action.route_id", "must reference a supplied task route")
    return action


def validate_response(value: dict[str, Any], purpose: str, observation: dict[str, Any] | None = None) -> dict[str, Any]:
    result = dict(value)
    for key in ("summary", "context_used", "visual_evidence", "intended_target", "expected_result", "output", "output_title", "reason", "message", "title", "check"):
        if key in result: string(result[key], key)
    for key in ("completed_requirements", "remaining_requirements", "missing"):
        if key in result and (not isinstance(result[key], list) or any(not isinstance(item, str) for item in result[key])):
            fail(key, "must be a list of strings")
    if "finish_after_action" in result and type(result["finish_after_action"]) is not bool: fail("finish_after_action", "must be a boolean")
    for key, choices in (("selected_capability", {"file_read", "file_write", "shell", "browser", "app_automation", "mixed"}), ("output_kind", {"answer", "result", "completion"}), ("kind", {"answer", "result", "completion"})):
        if key in result and (not isinstance(result[key], str) or result[key] not in choices): fail(key, "must be a supported value")
    if "status" in result and (not isinstance(result["status"], str) or result["status"] not in {"act", "done", "needs_user", "blocked"}):
        fail("status", "must be act, done, needs_user, or blocked")
    if result.get("status") == "act" and "action" not in result:
        fail("action", "is required when status is act")
    if purpose == "verification":
        if type(result.get("verified")) is not bool: fail("verified", "must be a boolean")
    else:
        status = result.get("status")
        if not isinstance(status, str) or status not in {"act", "done", "needs_user", "blocked"}: fail("status", "must be act, done, needs_user, or blocked")
        if purpose == "readiness" and (status != "done" or result.get("check") != "TASKPILOT_READY"): fail("check", "must equal TASKPILOT_READY with status done")
    if "action" in result: result["action"] = normalize_action(result["action"], observation)
    if "user_input" in result:
        request = result["user_input"]
        if not isinstance(request, dict): fail("user_input", "must be an object")
        if not isinstance(request.get("kind"), str) or request["kind"] not in {"password", "verification_code", "secret"}: fail("user_input.kind", "must be password, verification_code, or secret")
        for key in ("title", "message", "target_signature"):
            if key in request: string(request[key], f"user_input.{key}")
    if result.get("status") == "needs_user":
        if "user_input" not in result: fail("user_input", "is required when status is needs_user")
        action = result.get("action", {})
        for key in ("element_id", "pid"):
            if key not in action: fail(f"action.{key}", "is required for secure input")
        if observation is not None:
            element = next(e for e in observation.get("elements", []) if e.get("id") == action["element_id"])
            if element.get("role") not in {"AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox"}:
                fail("action.element_id", "must reference an observed text input for secure input")
            if element.get("enabled") is False:
                fail("action.element_id", "must reference an enabled secure input target")
    return result
