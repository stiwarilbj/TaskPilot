"""Private, offline prompt regression replay through TaskPilot's real task loop.

No desktop, shell, browser, provider, or credentials are accessed. Recorded
terminal responses must match exact prompt/image hashes. Scripted controls can
exercise the evaluator, but never authorize adoption of a prompt change.
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack, contextmanager
from copy import deepcopy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import statistics
import struct
import sys
import tempfile
import time
from unittest import mock
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "AgentRuntime"))
import openclaw_runtime as runtime
import request_policy as policy
from provider_errors import ProviderRequestError
from response_validation import extract_json_object, ResponseValidationError
from action_contract_generated import CONTRACT_HASH
from prompt_compiler import PROMPT_COMPILER_VERSION, EXAMPLE_MARKERS, REPAIR_HEADER, phase_header, prompt_phase
from recovery_cycles import RECOVERY_CYCLE_VERSION
from fixtures import seed_cases

VERSION = 1
CATEGORIES = {"wrong_clicks", "delayed_screens", "malformed_json", "command_errors", "premature_completion", "recovery_cycles"}
REPO = Path(__file__).resolve().parents[3]
DEFAULT_ROOT = Path.home() / "Library/Application Support/TaskPilot/PromptRegression"
SLUG = re.compile(r"[a-z0-9][a-z0-9-]{0,63}\Z")
DIGEST = re.compile(r"[a-f0-9]{64}\Z")
RULE_FIELDS = {"planning": "planning_rules", "recovery": "recovery_rules", "completion": "verification_rules"}


class RecordingMismatch(BaseException):
    """Stop immediately; missing/mismatched recordings are not model failures."""


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=True,
                                     separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def runtime_revision():
    sources = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
               for p in sorted((REPO / "ProjectFiles/AgentRuntime").glob("*.py"))}
    sources["action_contract_hash"] = CONTRACT_HASH
    sources["action-contract.json"] = hashlib.sha256((REPO / "ProjectFiles/Contracts/action-contract.json").read_bytes()).hexdigest()
    return digest(sources)


def checked_slug(value):
    if not isinstance(value, str) or not SLUG.fullmatch(value):
        raise ValueError("Use a short lowercase identifier, without private names or paths")
    return value


def require_sanitized(value):
    """Reject recognizable private content; human review is still required.

    Never silently rewrite a recording: that would break prompt bindings and
    the very target/command behavior under test. Seeds already use fake data.
    """
    def scan_keys(item):
        if isinstance(item, dict):
            for key, child in item.items():
                if str(key).lower() in {"api_key", "password", "access_token", "secret", "authorization"} and child:
                    raise ValueError("Credential values cannot be imported")
                scan_keys(child)
        elif isinstance(item, list):
            for child in item:
                scan_keys(child)
    scan_keys(value)
    text = json.dumps(value, ensure_ascii=True, allow_nan=False)
    patterns = (r"(?:/Users/|/home/|[A-Z]:\\\\Users\\\\)",
                r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
                r"AIza[0-9A-Za-z_-]{20,}|\bsk-[0-9A-Za-z_-]{16,}",
                r"(?i)bearer\s+[a-z0-9._-]{8,}",
                r'(?i)\\"(?:api_key|password|access_token|secret)\\"\s*:\s*\\"[^\\"]+\\"')
    if any(re.search(pattern, text) for pattern in patterns):
        raise ValueError("Private content detected; replace it with fixture data and review before importing")
    for url in re.findall(r"https?://([^/\s\\\"]+)", text):
        if url not in {"example.com", "example.invalid"}:
            raise ValueError("Recordings may contain only fictional example URLs")


def private_root(path):
    root = Path(path).absolute()
    if root.is_symlink() or root.resolve().is_relative_to(REPO):
        raise ValueError("Keep the private corpus outside the repository and avoid symlinks")
    for parent in (root, *root.parents):
        if parent.is_symlink():
            raise ValueError("Private storage must not pass through symlinks")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if root.stat().st_uid != os.getuid():
        raise ValueError("Private storage must be owned by the current user")
    root.chmod(0o700)
    return root


def private_write(root, filename, value):
    root = private_root(root)
    path = root / filename
    if Path(filename).name != filename or path.is_symlink():
        raise ValueError("Private outputs must be direct files in private storage")
    data = (json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n").encode()
    descriptor, temporary = tempfile.mkstemp(prefix=".write-", dir=root)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return path


def load(path):
    path = Path(path)
    if not path.is_file() or path.is_symlink() or path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o077 or path.stat().st_size > 8_000_000:
        raise ValueError("Use a private regular recording file (mode 600), at most 8 MB")
    try:
        value = extract_json_object(path.read_text())
    except ResponseValidationError:
        raise ValueError("Recording container must be one strict JSON object") from None
    require_sanitized(value)
    return value


def validate_corpus(corpus):
    if corpus.get("version") != VERSION or corpus.get("sanitized_reviewed") is not True:
        raise ValueError("Corpus must declare its schema version and sanitized review")
    cases = corpus.get("cases")
    if not isinstance(cases, list) or not 1 <= len(cases) <= 200:
        raise ValueError("Corpus needs 1..200 cases")
    seen = set()
    for case in cases:
        if not isinstance(case, dict):
            raise ValueError("Cases must be objects")
        identifier = checked_slug(case.get("id"))
        if identifier in seen:
            raise ValueError("Duplicate case identifier")
        seen.add(identifier)
        if case.get("category") not in CATEGORIES | {"healthy"}:
            raise ValueError("Unknown failure category")
        if not isinstance(case.get("provenance"), dict) or case["provenance"].get("kind") not in {"failure_reproduction", "synthetic_control", "sanitized_recording"}:
            raise ValueError("Every case needs explicit recording/reproduction provenance")
        states = case.get("states")
        if not isinstance(states, dict) or case.get("start") not in states or not case.get("goals"):
            raise ValueError("Each case needs an initial state and independent outcome goals")
        if not isinstance(case.get("task"), str) or not case["task"].strip() or len(case["task"]) > 16000:
            raise ValueError("Each case needs a bounded sanitized task")
        if not isinstance(case["goals"], dict) or any(type(v) is not int or not 0 <= v <= 100 for v in case["goals"].values()):
            raise ValueError("Outcome goals must be exact bounded counters")
        for goal in case["goals"]:
            checked_slug(goal)
        for name, frame in states.items():
            checked_slug(name)
            if not isinstance(frame, dict):
                raise ValueError("States must be objects")
            controls = frame.get("controls")
            if not isinstance(controls, list) or len(controls) > 640:
                raise ValueError("A state needs a bounded control list")
            if any(not isinstance(c, dict) for c in controls):
                raise ValueError("Controls must be objects")
            keys = [checked_slug(c.get("key")) for c in controls]
            if len(keys) != len(set(keys)):
                raise ValueError("Control keys must be unique in a state")
        if not isinstance(case.get("transitions"), list) or len(case["transitions"]) > 500:
            raise ValueError("Cases need bounded transition lists")
        for entry in case["transitions"]:
            if not isinstance(entry, dict):
                raise ValueError("Transitions must be objects")
            if entry.get("from") not in states or entry.get("to") not in states:
                raise ValueError("Transition references an unknown state")
            if "ready_state" in entry and entry["ready_state"] not in states:
                raise ValueError("Delayed transition needs a valid ready state")
            delay = entry.get("delay_seconds", 0)
            if type(delay) not in (int, float) or not math.isfinite(delay) or not 0 <= delay <= 30:
                raise ValueError("Fixture delay must be finite and bounded")
            if not isinstance(entry.get("action"), dict) or entry["action"].get("type") not in runtime.VALID_ACTIONS:
                raise ValueError("Transition needs a supported action")
            if type(entry.get("correct")) is not bool or not isinstance(entry.get("result"), dict):
                raise ValueError("Every transition needs an independent correctness label and native result")
            if not isinstance(entry.get("effects"), dict) or any(type(v) is not int or not 0 <= v <= 100 for v in entry["effects"].values()):
                raise ValueError("Transition effects must be bounded counter increments")
    require_sanitized(corpus)


def prompt_pack(label="current", **rules):
    return {"version": VERSION, "label": checked_slug(label), "runtime_revision": runtime_revision(),
            "prompt_compiler_version": PROMPT_COMPILER_VERSION,
            "recovery_cycle_version": RECOVERY_CYCLE_VERSION,
            "verification_session_version": runtime.VERIFICATION_SESSION_VERSION,
            "local_change_version": runtime.LOCAL_CHANGE_VERSION,
            **{field: rules.get(field) for field in RULE_FIELDS.values()}}


def validate_pack(pack):
    checked_slug(pack.get("label"))
    if pack.get("version") != VERSION or pack.get("runtime_revision") != runtime_revision():
        raise ValueError("Prompt pack was built for another runtime; compare with the same executor version")
    if type(pack.get("prompt_compiler_version")) is not int or pack["prompt_compiler_version"] != PROMPT_COMPILER_VERSION:
        raise ValueError("Prompt compiler version does not match")
    if type(pack.get("recovery_cycle_version")) is not int or pack["recovery_cycle_version"] != RECOVERY_CYCLE_VERSION:
        raise ValueError("Recovery cycle version does not match")
    if type(pack.get("verification_session_version")) is not int or pack["verification_session_version"] != runtime.VERIFICATION_SESSION_VERSION:
        raise ValueError("Verification session version does not match")
    if type(pack.get("local_change_version")) is not int or pack["local_change_version"] != runtime.LOCAL_CHANGE_VERSION:
        raise ValueError("Local change version does not match")
    for field in RULE_FIELDS.values():
        value = pack.get(field)
        if value is not None and (not isinstance(value, str) or not value.strip() or len(value) > 16000):
            raise ValueError("Prompt rules must be nonempty bounded text, or null for current rules")
    require_sanitized(pack)


def apply_rules(original, pack, purpose):
    phase = prompt_phase(original)
    if (purpose == "planning") != (phase in {"planning", "recovery"}):
        raise RecordingMismatch("prompt_phase_mismatch")
    rules = pack.get(RULE_FIELDS[phase])
    if rules is None:
        return original
    marker = EXAMPLE_MARKERS[phase] + ":\n"
    if marker not in original:
        raise RecordingMismatch("prompt_contract_changed")
    # Replace the rule section only. Task, evidence, context examples and history
    # always come from the same production builder and fixture state.
    return phase_header(phase) + "\n\n" + phase.upper() + " RULES:\n" + rules.rstrip() + "\n\n" + marker + original.split(marker, 1)[1]


def fixture_image(frame):
    """A synthetic PNG, not a captured app screenshot; labels are in AX data."""
    width, height = 480, 320
    pixels = bytearray([245] * (width * height * 3))
    for index, control in enumerate(frame["controls"]):
        x, y = 24 + (index % 3) * 144, 24 + (index // 3) * 40
        for row in range(y, min(height, y + 24)):
            for col in range(x, min(width, x + 120)):
                offset = (row * width + col) * 3
                pixels[offset:offset+3] = bytes((60, 120, 190) if control.get("enabled", True) else (180, 180, 180))
    rows = b"".join(b"\0" + pixels[row*width*3:(row+1)*width*3] for row in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class World:
    def __init__(self, case, directory):
        self.case, self.directory = case, directory
        self.state, self.now, self.revision = case["start"], 0.0, 0
        self.pending = None
        self.facts = {}
        self.files = {}
        self.latest = None
        self.delivered = self.incorrect = self.incorrect_attempts = self.duplicates = self.polls = 0

    def advance(self, seconds):
        self.now += seconds
        if self.pending and self.now >= self.pending[0]:
            self.state, self.pending = self.pending[1], None

    def observe(self):
        self.advance(0)
        self.revision += 1
        self.polls += 1
        revision = "frame-" + str(self.revision)
        frame = self.case["states"][self.state]
        image = self.directory / (revision + ".png")
        image.write_bytes(fixture_image(frame))
        elements = []
        for raw in frame["controls"]:
            element = {k: v for k, v in raw.items() if k != "key"}
            element.update(id=revision + ":" + raw["key"], window_id=revision + ":window-" + raw.get("window_title", "Draft"))
            element.setdefault("native_identity", raw["key"])
            if element.get("role") in {"AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"}:
                element.setdefault("value_complete", True)
            elements.append(element)
        windows = sorted({e.get("window_title", "Draft") for e in elements}) or ["Draft"]
        self.latest = {"observation_revision": revision, "screenshot_path": str(image), "local_change_notifications": True,
                       "applications": [{"pid": 42, "name": "Fixture App", "active": True, "topmost_on_agent_screen": True,
                                         "windows": [{"title": w, "window_id": revision + ":window-" + w,
                                                      "focused": w == frame.get("active_window", "Draft"),
                                                      "topmost_on_agent_screen": w == frame.get("active_window", "Draft")} for w in windows]}],
                       "elements": elements}
        return deepcopy(self.latest)

    def goals_met(self):
        return all(self.facts.get(key, 0) == value for key, value in self.case["goals"].items())

    def bridge(self, method, _display, **params):
        if method == "observe":
            return self.observe()
        if method == "wait_for_change":
            deadline = self.now + params['timeout_ms'] / 1000
            self.advance(min(params.get('minimum_delay_ms', 0) / 1000, deadline - self.now))
            check = params.get('expected_result')
            checks = notifications = 0
            reason = 'condition_candidate'
            def candidate():
                controls = self.case['states'][self.state]['controls']
                if not check: return None
                if check['type'] == 'field_value':
                    key = check['element_id'].split(':', 1)[1]
                    targets = [c for c in controls if c['key'] == key and c.get('pid') == params.get('pid')]
                    return len(targets) == 1 and targets[0].get('value') == check['value']
                if check['type'] == 'dialog_appeared':
                    return any(c.get('pid') == check['pid'] and c.get('title') == check['title'] and
                               (c.get('role') in {'AXSheet', 'AXDialog'} or c.get('subrole') == 'AXDialog') for c in controls)
                return None
            ready = candidate(); checks += ready is not None
            while ready is not True and self.now < deadline:
                end = min(deadline, self.now + 0.5)
                event = self.pending and self.pending[0] <= end
                if event:
                    self.advance(max(0, self.pending[0] - self.now))
                    self.advance(min(0.05, max(0, deadline - self.now)))
                    notifications += 1; reason = 'change_notification'
                else:
                    self.advance(end - self.now); reason = 'poll_timeout'
                ready = candidate(); checks += ready is not None
                if ready is None: break
            return {'effect_ready': ready, 'targeted_checks': checks, 'notifications': notifications,
                    'reason': reason, 'notification_supported': True}
        if method == "wait_file_effect":
            deadline = self.now + params['timeout_ms'] / 1000; checks = 0
            while True:
                result = self.bridge('check_effect', _display, check=params['check']); checks += 1
                if result['checks'][0]['verified'] or self.now >= deadline: break
                self.advance(min(0.5, deadline - self.now))
            return {**result, 'local_wait': {'targeted_checks': checks, 'notifications': 0, 'reason': 'poll_timeout'}}
        if method == "check_effect":
            check = params["check"]
            content = self.files.get(check["path"])
            actual = {"type": check["type"], "path": check["path"], "verified": False}
            if check["type"] == "directory_exists":
                actual["verified"] = check["path"] in self.case["states"][self.state].get("directories", [])
            elif check["type"] == "file_exists": actual["verified"] = content is not None
            elif check["type"] == "path_absent": actual["verified"] = content is None
            elif check["type"] == "file_contents" and content == check["content"]:
                actual.update(verified=True, content_sha256=hashlib.sha256(content.encode()).hexdigest())
            return {"requested_checks": [check], "checks": [actual]}
        if method == "recheck":
            action = params["action"]
            checks = ([{"type": "file_contents", "path": action["path"], "content": action["content"],
                        "encoding": action.get("encoding", "utf-8")}]
                      if action["type"] == "write_file" else action.get("checks", []))
            actual = []
            for check in checks:
                if check["type"] == "stdout_equals": continue
                value = {"type": check["type"], "path": check["path"], "verified": False}
                content = self.files.get(check["path"])
                if check["type"] == "file_contents" and content == check["content"]:
                    value.update(verified=True, content_sha256=hashlib.sha256(content.encode()).hexdigest())
                elif check["type"] == "file_exists": value["verified"] = content is not None
                elif check["type"] == "path_absent": value["verified"] = content is None
                actual.append(value)
            return {"requested_checks": [c for c in checks if c["type"] != "stdout_equals"], "checks": actual}
        if method != "act":
            raise RecordingMismatch("unsupported_fixture_bridge_method")
        action = deepcopy(params["action"])
        element_id = action.get("element_id")
        if element_id:
            element = next((e for e in self.latest["elements"] if e["id"] == element_id), None)
            if element is None:
                raise runtime.ActionRejected("Fixture target became stale", "stale_target")
            if element.get("enabled") is False:
                raise runtime.ActionRejected("Fixture target disabled", "disabled_target")
            action["element_id"] = "$" + element_id.split(":", 1)[1]
        for entry in self.case["transitions"]:
            if entry["from"] != self.state or entry["action"] != action:
                continue
            self.state = entry["to"]
            if "ready_state" in entry:
                self.pending = (self.now + entry["delay_seconds"], entry["ready_state"])
            if entry.get("error"):
                raise runtime.ActionRejected("Fixture rejected action", entry["error"])
            self.delivered += 1
            self.incorrect += entry["correct"] is not True
            for key, amount in entry["effects"].items():
                if key in self.case["goals"] and amount > 0 and self.facts.get(key, 0) + amount > self.case["goals"][key]:
                    self.duplicates += 1
                self.facts[key] = self.facts.get(key, 0) + amount
            result = deepcopy(entry["result"])
            if action["type"] == "write_file" and result.get("verified") is True:
                self.files[action["path"]] = action["content"]
            for check, checked in zip(action.get("checks", []), result.get("checks", [])):
                if check["type"] == "file_contents" and checked.get("verified") is True:
                    self.files[check["path"]] = check["content"]
            return result
        self.incorrect_attempts += 1
        raise runtime.ActionRejected("Action does not match an allowed fixture operation", "unsupported_action")


def bind(value, observation, ledger=None):
    if isinstance(value, dict):
        return {key: bind(item, observation, ledger) for key, item in value.items()}
    if isinstance(value, list):
        return [bind(item, observation, ledger) for item in value]
    if value == "$current_proofs":
        return [{"requirement_id": key, "evidence_ids": [next((ref for ref, evidence in reversed(list(ledger.evidence.items()))
                 if ledger.requirement_matches(key, evidence, semantic=True)), "unproven")],
                 "rationale": "The cited fixture evidence shows this requested outcome"}
                for key, requirement in ledger.requirements.items()]
    if isinstance(value, str) and value.startswith("$"):
        match = next((e["id"] for e in observation["elements"] if e["id"].endswith(":" + value[1:])), None)
        if match is None:
            raise RecordingMismatch("script_target_missing")
        return match
    return value


class RecordedClient:
    def __init__(self, world, requests=None, script=None):
        self.world, self.requests, self.script = world, requests, script
        self.observation = None
        self.purpose = "planning"
        self.calls = []
        self.selected_model = None
        self.model_switches = self.prompt_calls = self.reconnects = 0
        self.successful_provider_retries = None
        self.session_id = "planning"
        self.verification_sessions = 0

    @contextmanager
    def verification_session(self):
        self.verification_sessions += 1
        self.session_id = f"verification-{self.verification_sessions}"
        try:
            yield
        finally:
            self.session_id = "planning"

    def select_model(self, model):
        self.model_switches += self.selected_model != model
        self.selected_model = model

    def reconnect(self):
        self.reconnects += 1

    def close(self):
        pass

    def prompt(self, instruction, image):
        if self.purpose == "verification" and self.session_id == "planning":
            raise RecordingMismatch("verification_session_not_isolated")
        index = self.prompt_calls
        fields = {"purpose": self.purpose, "repair": instruction.startswith(REPAIR_HEADER),
                  "model": self.selected_model, "instruction_sha256": hashlib.sha256(instruction.encode()).hexdigest(),
                  "image_sha256": hashlib.sha256(image.read_bytes()).hexdigest()}
        if self.script is not None:
            if index >= len(self.script):
                raise RecordingMismatch("script_exhausted")
            response = bind(self.script[index], self.observation, self.ledger)
            # Fictional ad-hoc scripts use the same explicit checklist metadata
            # as seeds. Recorded model responses are never augmented.
            if isinstance(response, dict) and "status" in response and "requirements" not in response:
                response["requirements"] = [{"source": self.world.case["task"], "description": self.world.case["task"],
                                             "check": {"type": "visual", "expected": self.world.case["task"]}}]
            entry = {**fields, "response": response if isinstance(response, str) else json.dumps(response, separators=(",", ":")),
                     "elapsed_seconds": 0.25, "provider_retries": None}
        else:
            if index >= len(self.requests):
                raise RecordingMismatch("recording_exhausted")
            entry = self.requests[index]
            if any(entry.get(key) != value for key, value in fields.items()):
                raise RecordingMismatch("prompt_or_evidence_mismatch")
        self.calls.append(deepcopy(entry))
        self.prompt_calls += 1
        self.world.advance(entry["elapsed_seconds"])
        retries = entry.get("provider_retries")
        self.last_prompt_provider_retries = retries
        if retries is not None:
            self.successful_provider_retries = (self.successful_provider_retries or 0) + retries
        if "error" in entry:
            raise ProviderRequestError(entry["error"], self.selected_model)
        return entry["response"]


def replay_case(case, pack, requests=None, script=None):
    # Native JSON dictionaries preserve input order; private JSON serialization
    # may reorder keys. Canonicalize fixture data before building any prompt so
    # exact recordings survive disk round trips and another Python process.
    case = json.loads(json.dumps(case, sort_keys=True))
    started = time.perf_counter()
    with tempfile.TemporaryDirectory(prefix="taskpilot-regression-") as directory:
        world = World(case, Path(directory))
        client = RecordedClient(world, requests, script)
        router = policy.AdaptiveModelRouter(lambda *a, **k: None, clock=lambda: 1_900_000_000 + world.now, sleep=world.advance)
        original_route, planning, verification = runtime.routed_json_prompt, runtime.desktop_instruction, runtime.verification_instruction
        capability_context = runtime.task_capability_context
        compact_history = runtime.compact_history
        original_ledger = runtime.TaskEvidenceLedger
        input_scope = digest(["fixture-inputs", case["id"], case["task"]])[:16]
        completion = premature = False
        failure = None
        def route(router, client, instruction, image, purpose="planning", observation=None, ledger=None):
            client.purpose, client.observation, client.ledger = purpose, observation, ledger
            return original_route(router, client, instruction, image, purpose, observation, ledger)
        def emit(kind, **_payload):
            nonlocal completion, premature
            if kind == "complete":
                completion = True
                premature = not world.goals_met()
        def forbidden(*_args, **_kwargs):
            raise RecordingMismatch("live_side_effect_forbidden")
        def fixture_context(task, observation):
            context = capability_context(task, observation)
            context["home_directory"] = "/fixture"
            return context
        with ExitStack() as stack:
            patches = {"find_openclaw": lambda *_: "fixture-acp", "prepare_runtime": lambda *_: mock.Mock(),
                       "ACPClient": lambda *_: client, "TaskModelRouter": lambda **_: router,
                       "bridge_call": world.bridge, "routed_json_prompt": route, "emit": emit,
                       "record_action_diagnostic": lambda *_: None,
                       "request_and_enter_user_input": forbidden, "largest_top_level_file": forbidden,
                       "task_capability_context": fixture_context,
                       "TaskEvidenceLedger": lambda task, generation=None: original_ledger(task, generation, input_scope=input_scope),
                       "compact_history": lambda history: json.loads(json.dumps(compact_history(history), sort_keys=True)),
                       "desktop_instruction": lambda *args: apply_rules(planning(*args), pack, "planning"),
                       "verification_instruction": lambda *args: apply_rules(verification(*args), pack, "verification")}
            for name, replacement in patches.items():
                stack.enter_context(mock.patch.object(runtime, name, replacement))
            stack.enter_context(mock.patch.object(runtime.time, "monotonic", lambda: world.now))
            stack.enter_context(mock.patch.object(runtime.time, "sleep", world.advance))
            stack.enter_context(mock.patch.object(runtime.subprocess, "run", forbidden))
            stack.enter_context(mock.patch.object(runtime.subprocess, "Popen", forbidden))
            try:
                runtime.run_task(case["task"], 1, "fixture-acp", "")
            except RecordingMismatch as error:
                failure = str(error)
            except (Exception, SystemExit) as error:
                # Error text can include responses/commands. Reports retain only
                # a closed classification, never that text or task contents.
                failure = "cancelled" if isinstance(error, SystemExit) else policy.classify_failure(error, 1_900_000_000 + world.now).kind
        complete_trace = requests is None or len(client.calls) == len(requests)
        response_seconds = sum(c["elapsed_seconds"] for c in client.calls)
        result = {"case_id": case["id"], "category": case["category"], "provenance": case["provenance"]["kind"],
                  "success": completion and world.goals_met() and complete_trace and failure is None,
                  "postconditions_met": world.goals_met(), "completed": completion,
                  "premature_completion": premature, "incorrect_actions": world.incorrect,
                  "incorrect_action_attempts": world.incorrect_attempts, "duplicate_actions": world.duplicates,
                  "delivered_actions": world.delivered, "observation_polls": world.polls,
                  "trace_complete": complete_trace, "failure_kind": failure,
                  "requests": client.prompt_calls, "planning": router.metrics["planning"],
                  "verification": router.metrics["verification"], "repairs": router.metrics["repairs"],
                  "retries": router.metrics["retries"], "model_switches": client.model_switches,
                  "provider_retries": router.metrics["provider_retries"],
                  "recovery_cycles": router.metrics.get("recovery_cycles", 0),
                  "cycle_suppressions": router.metrics.get("cycle_suppressions", 0),
                  "recorded_response_seconds": round(response_seconds, 3),
                  "local_wait_seconds": round(world.now - response_seconds, 3),
                  "task_seconds": round(world.now, 3), "replay_wall_seconds": round(time.perf_counter() - started, 3)}
        return result, client.calls


def validate_recording(recording, corpus, pack):
    if (recording.get("version") != VERSION or recording.get("sanitized_reviewed") is not True
            or recording.get("corpus_sha256") != digest(corpus) or recording.get("prompt_pack_sha256") != digest(pack)):
        raise ValueError("Recording must bind the reviewed corpus and exact prompt pack")
    if recording.get("source") not in {"scripted_control", "recorded_model"}:
        raise ValueError("Distinguish scripted controls from recorded model responses")
    identifiers = {case["id"] for case in corpus["cases"]}
    runs = recording.get("runs")
    if not isinstance(runs, list) or not 1 <= len(runs) <= 2000:
        raise ValueError("Recording needs bounded task runs")
    seen = set()
    for run in runs:
        if not isinstance(run, dict):
            raise ValueError("Task runs must be objects")
        case_id, trial = checked_slug(run.get("case_id")), run.get("trial")
        if case_id not in identifiers or type(trial) is not int or not 0 <= trial <= 999 or (case_id, trial) in seen:
            raise ValueError("Runs need unique case/trial pairs from the frozen corpus")
        seen.add((case_id, trial))
        requests = run.get("requests")
        if not isinstance(requests, list) or len(requests) > 500:
            raise ValueError("A run needs a bounded terminal-response trace")
        for entry in requests:
            if not isinstance(entry, dict):
                raise ValueError("Terminal responses must be objects")
            if entry.get("purpose") not in {"planning", "verification"} or type(entry.get("repair")) is not bool:
                raise ValueError("Every response needs its request purpose and repair flag")
            if entry.get("model") not in policy.ALL_MODELS:
                raise ValueError("Recording uses a different model configuration")
            if any(not isinstance(entry.get(k), str) or not DIGEST.fullmatch(entry[k])
                   for k in ("instruction_sha256", "image_sha256")):
                raise ValueError("Every terminal response must bind exact prompt and image hashes")
            elapsed = entry.get("elapsed_seconds")
            if type(elapsed) not in (float, int) or not math.isfinite(elapsed) or not 0 <= elapsed <= 3600:
                raise ValueError("Record terminal-response elapsed time as a finite number")
            retries = entry.get("provider_retries")
            if retries is not None and (type(retries) is not int or not 0 <= retries <= 1000):
                raise ValueError("Provider retries must be a reported integer or null")
            if ("response" in entry) == ("error" in entry):
                raise ValueError("A terminal request must have one response or provider error")
            if "response" in entry and (not isinstance(entry["response"], str) or len(entry["response"]) > 65536):
                raise ValueError("Response must be bounded text, including invalid JSON")
            if "error" in entry and not isinstance(entry["error"], dict):
                raise ValueError("Provider errors must retain their sanitized structure")
    require_sanitized(recording)


def evaluate(corpus, pack, recording):
    validate_corpus(corpus)
    validate_pack(pack)
    validate_recording(recording, corpus, pack)
    cases = {case["id"]: case for case in corpus["cases"]}
    results = []
    for run in recording["runs"]:
        result, _ = replay_case(cases[run["case_id"]], pack, requests=run["requests"])
        results.append({**result, "trial": run["trial"]})
    return {"version": VERSION, "source": recording["source"], "label": pack["label"],
            "corpus_sha256": digest(corpus), "prompt_pack_sha256": digest(pack),
            "rules_sha256": digest({k: pack.get(k) for k in RULE_FIELDS.values()}),
            "runtime_revision": runtime_revision(), "runs": results,
            "measurement": ("in-memory fixture outcomes; " + ("scripted response time" if recording["source"] == "scripted_control" else "recorded terminal-response time")
                            + " plus simulated local waits; replay wall time is separate"),
            "visual_live_validation": False}


def totals(runs):
    times = sorted(r["task_seconds"] for r in runs)
    return {"runs": len(runs), "successes": sum(r["success"] for r in runs),
            **{key: sum(r[key] for r in runs) for key in ("incorrect_actions", "incorrect_action_attempts", "duplicate_actions", "requests", "planning", "verification", "repairs", "retries", "model_switches", "premature_completion")},
            **{key: sum(r.get(key, 0) for r in runs) for key in ("recovery_cycles", "cycle_suppressions")},
            "provider_retries": sum(r["provider_retries"] for r in runs) if runs and all(r["provider_retries"] is not None for r in runs) else None,
            "median_task_seconds": round(statistics.median(times), 3) if times else None,
            "p95_task_seconds": times[math.ceil(len(times)*0.95)-1] if times else None}


def compare(corpus, baseline, candidate, minimum_trials=3):
    reasons = []
    if any(report["corpus_sha256"] != digest(corpus) or report["runtime_revision"] != runtime_revision()
           for report in (baseline, candidate)):
        reasons.append("different_corpus_or_runtime")
    if baseline["source"] != "recorded_model" or candidate["source"] != "recorded_model":
        reasons.append("scripted_responses_do_not_measure_prompt_quality")
    if baseline["rules_sha256"] == candidate["rules_sha256"]:
        reasons.append("no_prompt_change_to_adopt")
    old = {(r["case_id"], r["trial"]): r for r in baseline["runs"]}
    new = {(r["case_id"], r["trial"]): r for r in candidate["runs"]}
    if old.keys() != new.keys():
        reasons.append("missing_paired_runs")
    categories = {case["category"] for case in corpus["cases"]}
    if not CATEGORIES <= categories or "healthy" not in categories:
        reasons.append("missing_failure_or_healthy_coverage")
    comparisons = []
    for case in corpus["cases"]:
        pairs = [(old[key], new[key]) for key in sorted(old.keys() & new.keys()) if key[0] == case["id"]]
        if len(pairs) < minimum_trials:
            reasons.append("insufficient_paired_trials")
        before, after = [p[0] for p in pairs], [p[1] for p in pairs]
        comparisons.append({"case_id": case["id"], "baseline": totals(before), "candidate": totals(after)})
        for first, second in pairs:
            if not first["trace_complete"] or not second["trace_complete"] or any(
                    r["failure_kind"] in {"prompt_or_evidence_mismatch", "recording_exhausted", "live_side_effect_forbidden"} for r in (first, second)):
                reasons.append("invalid_or_incomplete_recording")
            if not second["success"]:
                reasons.append("candidate_task_failure")
            if second["incorrect_actions"] or second["incorrect_action_attempts"] or second["duplicate_actions"] or second["premature_completion"]:
                reasons.append("candidate_incorrect_action_or_completion")
            if first["success"] and second["requests"] > first["requests"]:
                reasons.append("more_requests_for_a_successful_task")
        healthy_pairs = [(a, b) for a, b in pairs if a["success"] and b["success"]]
        if healthy_pairs:
            old_time = statistics.median(a["task_seconds"] for a, _ in healthy_pairs)
            new_time = statistics.median(b["task_seconds"] for _, b in healthy_pairs)
            if new_time > old_time * 1.1 + 0.5:
                reasons.append("successful_task_time_regression")
    return {"version": VERSION, "eligible_for_adoption": not reasons, "reasons": sorted(set(reasons)),
            "minimum_paired_trials": minimum_trials, "baseline": totals(baseline["runs"]),
            "candidate": totals(candidate["runs"]), "cases": comparisons,
            "scope": "offline fixture gate; physical clicks, real shell behavior, and visual accuracy remain unverified",
            "automatic_adoption": False}


def initialize(root):
    corpus = {"version": VERSION, "sanitized_reviewed": True, "cases": seed_cases()}
    validate_corpus(corpus)
    private_write(root, "corpus.json", corpus)
    reports = []
    for label in ("baseline", "candidate"):
        pack = prompt_pack(label)
        private_write(root, label + "-prompt.json", pack)
        runs = []
        for case in corpus["cases"]:
            _, requests = replay_case(case, pack, script=case["scripts"][label])
            runs.append({"case_id": case["id"], "trial": 0, "requests": requests})
        recording = {"version": VERSION, "sanitized_reviewed": True, "source": "scripted_control",
                     "corpus_sha256": digest(corpus), "prompt_pack_sha256": digest(pack), "runs": runs}
        private_write(root, label + "-demo-recording.json", recording)
        report = evaluate(corpus, pack, recording)
        private_write(root, label + "-demo-report.json", report)
        reports.append(report)
    comparison = compare(corpus, *reports)
    private_write(root, "demo-comparison.json", comparison)
    return comparison


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--private-dir", type=Path, default=DEFAULT_ROOT)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    subparsers.add_parser("init", help="create private sanitized reproductions and clearly marked scripted controls")
    command = subparsers.add_parser("compare", help="replay paired recordings; no model or desktop calls")
    command.add_argument("--baseline", type=Path, required=True)
    command.add_argument("--candidate", type=Path, required=True)
    command.add_argument("--minimum-trials", type=int, default=3)
    args = parser.parse_args(argv)
    try:
        root = private_root(args.private_dir)
        if args.operation == "init":
            if (root / "corpus.json").exists():
                raise ValueError("Private corpus already exists; use another directory rather than overwrite recordings")
            comparison = initialize(root)
        else:
            if not 3 <= args.minimum_trials <= 100:
                raise ValueError("Require at least three paired trials per case")
            corpus = load(root / "corpus.json")
            baseline = evaluate(corpus, load(root / "baseline-prompt.json"), load(args.baseline))
            candidate = evaluate(corpus, load(root / "candidate-prompt.json"), load(args.candidate))
            comparison = compare(corpus, baseline, candidate, args.minimum_trials)
            private_write(root, "baseline-report.json", baseline)
            private_write(root, "candidate-report.json", candidate)
            private_write(root, "comparison.json", comparison)
        print(json.dumps({"eligible_for_adoption": comparison["eligible_for_adoption"],
                          "reasons": comparison["reasons"], "baseline": comparison["baseline"],
                          "candidate": comparison["candidate"]}, sort_keys=True))
        return 0 if args.operation == "init" or comparison["eligible_for_adoption"] else 1
    except (ValueError, OSError):
        # Do not echo arbitrary imported text, filenames, or exception details.
        print("Regression input or private-storage validation failed. Review the schema and privacy rules.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
