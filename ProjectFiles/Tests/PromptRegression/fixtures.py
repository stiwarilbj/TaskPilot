"""Sanitized reproductions of documented failures; never live task recordings.

Only fictional controls, fixture paths, and local in-memory effects are used.
Private corpus files are materialized by the evaluator, outside the checkout.
"""
from copy import deepcopy
import hashlib
from evidence_fixtures import native_result, native_batch, native_delivery


def control(key, title, role="AXButton", window="Draft", x=100, **fields):
    return {"key": key, "title": title, "role": role, "pid": 42,
            "app": "Fixture App", "window_title": window, "enabled": True,
            "frame": {"x": x, "y": 100, "width": 80, "height": 30}, **fields}


def state(*controls):
    return {"controls": list(controls)}


def act(kind="press", target="$save", **fields):
    action = {"type": kind, **fields}
    if target:
        action["element_id"] = target
    return {"status": "act", "intended_target": "Requested fixture control",
            "expected_result": "The requested fixture outcome becomes visible", "action": action}


DONE = {"status": "done", "output": "Fixture work completed"}
YES = {"verified": True, "coverage_complete": True, "message": "Fixture outcome visible", "proofs": "$current_proofs"}
NO = {"verified": False, "missing": ["Requested fixture outcome is not visible"]}
BLOCKED = {"status": "blocked", "reason": "The requested outcome remains unavailable after recovery"}
VERIFIED = {"outcome": "verified", "delivery_method": "fixture", "pid": 42,
            "message": "Fixture event delivered"}


def transition(source, action, destination, effect=None, correct=True, result=None, **fields):
    if result is None: result = native_result(action, delivery_method='fixture', pid=42, message='Fixture event delivered')
    else: result = native_delivery(action, result)
    return {"from": source, "action": action, "to": destination,
            "effects": effect or {}, "correct": correct,
            "result": result, **fields}


def case(identifier, category, states, transitions, baseline, candidate, source):
    return {"id": identifier, "category": category,
            "provenance": {"kind": "failure_reproduction" if source else "synthetic_control",
                           "source": source or "healthy execution control"},
            "task": "In Fixture App, save the Draft exactly once.",
            "start": "initial", "states": states, "transitions": transitions,
            "goals": {"saved": 1}, "scripts": {"baseline": baseline, "candidate": candidate}}


def seed_cases():
    save = control("save", "Save")
    saved = state(control("saved", "Draft saved", "AXStaticText"))
    press = {"type": "press", "element_id": "$save"}
    normal = [act(), DONE, YES]
    healthy = case("healthy-control", "healthy", {"initial": state(save), "saved": saved},
                   [transition("initial", press, "saved", {"saved": 1})], normal, normal, "")
    wrong = case("wrong-window", "wrong_clicks",
                 {"initial": state(save, control("other", "Save", window="Other document", x=400)),
                  "wrong": state(save, control("other", "Other document saved", "AXStaticText", window="Other document")),
                  "saved": saved},
                 [transition("initial", {"type": "press", "element_id": "$other"}, "wrong", {"other": 1}, False),
                  transition("initial", press, "saved", {"saved": 1})],
                 [act(target="$other"), DONE, YES], normal,
                 "test_decision_prompts / same labels in different windows")
    stale = case("moved-control", "wrong_clicks",
                 {"initial": state(save), "moved": state(control("save", "Save", x=300)), "saved": saved},
                 [transition("initial", press, "moved", error="stale_target", correct=True),
                  transition("moved", press, "saved", {"saved": 1})],
                 [act(), act(), DONE, YES], [act(), act(), DONE, YES],
                 "test_screen_settling.test_stale_target_refreshes_and_replans_without_delivering_old_click")
    delayed = case("delayed-dialog", "delayed_screens",
                   {"initial": state(control("open", "Open save dialog")),
                    "loading": state(control("loading", "Loading", "AXProgressIndicator", busy=True)),
                    "ready": state(control("dialog", "Save Draft", "AXSheet"), save), "saved": saved},
                   [transition("initial", {"type": "press", "element_id": "$open"}, "loading",
                               delay_seconds=1.2, ready_state="ready"),
                    transition("ready", press, "saved", {"saved": 1})],
                   [act(target="$open"), DONE, YES], [act(target="$open"), act(), DONE, YES],
                   "test_screen_settling.test_loading_page_waits_for_ready_content")
    delayed["task"] = "In Fixture App, open the save dialog, then save the Draft exactly once."
    field = control("body", "Draft body", "AXTextField", value="", focused=True)
    malformed = case("invalid-text-type", "malformed_json",
                     {"initial": state(field), "saved": state(control("body", "Draft body", "AXTextField", value="Fixture text", focused=True))},
                     [transition("initial", {"type": "set_value", "element_id": "$body", "text": "Fixture text"}, "saved", {"saved": 1})],
                     [act("set_value", "$body", text=12), *("{" for _ in range(6))],
                     [act("set_value", "$body", text=12), act("set_value", "$body", text="Fixture text"), DONE, YES],
                     "test_response_validation / invalid action.text and same-model repair")
    malformed["task"] = "In Fixture App, replace the Draft body with Fixture text exactly once."
    command = {"type": "run_command", "argv": ["/fixture/create-result"],
               "working_directory": "/fixture", "checks": [{"type": "file_contents", "path": "/fixture/result.txt", "content": "Fixture result"}]}
    checked = {"exit_code": 0, "timed_out": False, "verified": True,
               "verification_scope": "requested_outcomes", "stdout": "", "stderr": "",
               "working_directory": "/fixture", "checks": [{"type": "file_contents", "path": "/fixture/result.txt", "verified": True,
                          "content_sha256": hashlib.sha256(b"Fixture result").hexdigest()}]}
    command_act = {"status": "act", "action": command, "finish_after_action": True}
    syntax_action = {"type": "run_command", "command": "printf 'unterminated", "working_directory": "/fixture"}
    syntax = case("command-syntax", "command_errors",
                  {"initial": state(), "retry": state(), "saved": state()},
                  [transition("initial", syntax_action, "retry", error="command_syntax"),
                   transition("initial", command, "saved", {"saved": 1}, result=checked),
                   transition("retry", command, "saved", {"saved": 1}, result=checked)],
                  [{"status": "act", "action": syntax_action}, BLOCKED, BLOCKED],
                  [{"status": "act", "action": syntax_action}, command_act, YES],
                  "TaskToolExecutor command syntax and requested-outcome checks")
    syntax["task"] = "Run the command /fixture/create-result in /fixture and verify /fixture/result.txt contains Fixture result."
    noop = {"type": "run_command", "argv": ["/fixture/no-op"], "working_directory": "/fixture"}
    zero = case("exit-zero-no-result", "command_errors",
                {"initial": state(), "retry": state(), "saved": state()},
                [transition("initial", noop, "retry", correct=False, result={"exit_code": 0, "timed_out": False, "stdout": "", "stderr": ""}),
                 transition("initial", command, "saved", {"saved": 1}, result=checked),
                 transition("retry", command, "saved", {"saved": 1}, result=checked)],
                [{"status": "act", "action": noop, "finish_after_action": True}, NO, BLOCKED, BLOCKED],
                [command_act, YES],
                "test_command_contract.test_only_matching_outcomes_enable_native_completion")
    zero["task"] = syntax["task"]
    early = case("premature-done", "premature_completion", {"initial": state(save), "saved": saved},
                 [transition("initial", press, "saved", {"saved": 1})], [DONE, YES], [DONE, NO, *normal],
                 "test_openclaw_runtime / reject attempted actions as completion")
    submit = control("save", "Submit Draft")
    uncertain = case("uncertain-submission", "wrong_clicks",
                     {"initial": state(submit), "saved": state(submit, control("receipt", "Draft submitted", "AXStaticText"))},
                     [transition("initial", press, "saved", {"saved": 1}, result=native_result(press, message='Fixture event delivered', delivery_method='fixture', pid=42)),
                      transition("saved", press, "saved", {"saved": 1}, correct=False)],
                     [act(), act(), act()], normal,
                     "test_action_recovery / do not replay an uncertain mutation")
    uncertain["task"] = "In Fixture App, submit the Draft exactly once and verify the receipt."
    cases = deepcopy([healthy, wrong, stale, delayed, malformed, syntax, zero, early, uncertain, *file_coverage_cases(), *cycle_cases()])
    for item in cases:
        item["scripts"] = deepcopy(item["scripts"])
        requirements = [{"source": item["task"], "description": item["task"],
                         "check": {"type": "visual", "expected": item["task"]}}]
        if item["id"] in {"command-syntax", "exit-zero-no-result"}:
            requirements = [{"source": item["task"], "description": "Execute the requested fixture command",
                             "check": {"type": "command_executed", "argv": ["/fixture/create-result"], "working_directory": "/fixture"}},
                            {"source": item["task"], "description": "Verify the requested file contents",
                             "check": {"type": "file_contents", "path": "/fixture/result.txt", "content": "Fixture result"}}]
        elif item["id"] in {"partial-file-coverage", "wrong-file-contents"}:
            requirements = [{"source": item["task"], "description": "Verify " + name + " contents",
                             "check": {"type": "file_contents", "path": "/fixture/" + name + ".txt", "content": name.upper()}}
                            for name in ("a", "b")]
        for script in item["scripts"].values():
            for response in script:
                if isinstance(response, dict) and "status" in response:
                    response["requirements"] = deepcopy(requirements)
    return cases


def cycle_cases():
    opened = act(target="$open")
    closed = act(target="$close")
    opened['expected_result'] = {'type':'field_value','element_id':'$state','value':'open'}
    closed['expected_result'] = {'type':'field_value','element_id':'$state','value':'closed'}
    saved = state(control("saved", "Draft saved", "AXStaticText"))
    dialog = case("repeated-dialog", "recovery_cycles",
        {"initial": state(control("open", "Open save dialog"), control("save", "Save using menu"), control("state", "Dialog status", "AXTextField", value="closed", value_complete=True)),
         "dialog": state(control("dialog", "Save Draft", "AXSheet"), control("close", "Cancel"), control("state", "Dialog status", "AXTextField", value="open", value_complete=True)), "saved": saved},
        [transition("initial", opened["action"], "dialog"), transition("dialog", closed["action"], "initial"),
         transition("initial", {"type": "press", "element_id": "$save"}, "saved", {"saved": 1})],
        [opened, closed, opened, closed, opened, opened, opened],
        [opened, closed, opened, closed, act(), DONE, YES], "repeated open/close recovery path")
    methods = case("alternating-methods", "recovery_cycles",
        {"initial": state(control("save", "Save"), control("menu", "Save using menu")), "saved": saved},
        [transition("initial", {"type": "press", "element_id": "$save"}, "initial", error="unsupported_action"),
         transition("initial", {"type": "click", "pid": 42, "x": 120, "y": 115}, "initial", error="delivery_rejected"),
         transition("initial", {"type": "press", "element_id": "$menu"}, "saved", {"saved": 1})],
        [act(), act("click", None, pid=42, x=120, y=115), act(), act("click", None, pid=42, x=120, y=115), act()],
        [act(), act("click", None, pid=42, x=120, y=115), act(), act(target="$menu"), DONE, YES], "unsuccessful AX/coordinate method alternation")
    return [dialog, methods]


def file_coverage_cases():
    def write(name, content):
        action = {"type": "write_file", "path": "/fixture/" + name + ".txt", "content": content}
        response = {"status": "act", "action": action, "finish_after_action": True, "remaining_requirements": []}
        result = {"verified": True, "outcome": "verified", "path": action["path"], "mode": "overwrite",
                  "bytes_written": len(content), "content_sha256": hashlib.sha256(content.encode()).hexdigest()}
        return action, response, result
    a, first, ar = write("a", "A")
    b, second, br = write("b", "B")
    incorrect, bad, badr = write("a", "wrong")
    states = {"initial": state(), "partial": state(), "wrong": state(), "saved": state()}
    transitions = [transition("initial", a, "partial", {"a": 1}, result=ar),
                   transition("partial", b, "saved", {"b": 1}, result=br),
                   transition("initial", incorrect, "wrong", {"wrong": 1}, correct=False, result=badr)]
    cases = []
    for identifier, baseline in [("partial-file-coverage", [first, NO, BLOCKED, BLOCKED]),
                                  ("wrong-file-contents", [bad, NO, BLOCKED, BLOCKED])]:
        item = case(identifier, "premature_completion", states, transitions, baseline,
                    [first, NO, second, YES], "Task requirement evidence: verified native output does not imply complete coverage")
        item["task"] = "Write /fixture/a.txt with A and /fixture/b.txt with B."
        item["goals"] = {"a": 1, "b": 1}
        cases.append(item)
    return cases
