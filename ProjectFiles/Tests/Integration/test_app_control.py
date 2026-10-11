"""Opt-in live native bridge test; creates disposable controls, never sends messages."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import uuid


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--keep-results", type=Path)
    parser.add_argument("--live-acp", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="taskpilot-control-") as temporary:
        root = Path(temporary)
        fixture = root / "TaskPilot Control Fixture.app"
        contents = fixture / "Contents"
        binary = contents / "MacOS/TaskPilotControlFixture"
        binary.parent.mkdir(parents=True)
        import plistlib
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": binary.name, "CFBundleIdentifier": "org.taskpilot.control-fixture",
            "CFBundleName": "TaskPilot Control Fixture", "CFBundlePackageType": "APPL",
            "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "14.0",
        }))
        subprocess.run(["swiftc", "-parse-as-library", str(Path(__file__).parent / "Fixtures/ControlFixture.swift"),
                        "-o", str(binary)], check=True, capture_output=True, text=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(fixture)], check=True, capture_output=True)
        state_path = root / "state.json"
        fixture_log = (root / "fixture.log").open("w")
        fixture_process = subprocess.Popen([str(binary), str(state_path)], stdout=fixture_log, stderr=fixture_log)
        host_log = (root / "host.log").open("w")
        host = subprocess.Popen([str(args.app / "Contents/MacOS/OrbitAgent"), "--automation-test-bridge"],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=host_log,
                                text=True, bufsize=1)
        revision = None
        observations = []
        latest_observation = {}
        report = {"modes": [], "actions": [], "wrong_actions": 0}

        def call(method, display=0, **params):
            request_id = str(uuid.uuid4())
            if method == "act":
                params["observation_revision"] = revision
            host.stdin.write(json.dumps({"request_id": request_id, "method": method,
                                        "params": {"display_id": display, **params}}) + "\n")
            host.stdin.flush()
            deadline = time.monotonic() + 35
            while time.monotonic() < deadline:
                if not select.select([host.stdout], [], [], 0.5)[0]:
                    if host.poll() is not None:
                        raise AssertionError(f"Signed app test host exited ({host.returncode}): {host_log.name}")
                    continue
                line = host.stdout.readline()
                if not line:
                    host.wait(timeout=2)
                    raise AssertionError(f"Signed app test host closed stdout ({host.returncode}) during {method}")
                try:
                    response = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if response.get("request_id") == request_id:
                    return response
            raise AssertionError(f"Bridge timed out for {method}: {host_log.name}")

        def observe(display):
            nonlocal revision, latest_observation
            response = call("observe", display)
            assert response["ok"], response
            result = response["result"]
            revision = result["observation_revision"]
            latest_observation = result
            observations.append(Path(result["screenshot_path"]))
            return result

        def act(display, action, rejection=None):
            response = call("act", display, action=action)
            if rejection:
                assert not response["ok"] and response.get("error_code") == rejection, response
                return response
            for recovery in range(2):
                if response["ok"] or response.get("error_code") not in {"activation_failed", "delivery_rejected", "stale_target"}: break
                # These errors occur before delivery. Fresh evidence permits
                # recovery without replaying an uncertain/completed action.
                original = next((e for e in latest_observation.get("elements", []) if e.get("id") == action.get("element_id")), None)
                fresh = observe(display)
                if original:
                    candidates = [e for e in fresh["elements"] if e.get("pid") == original.get("pid") and e.get("role") == original.get("role") and e.get("title") == original.get("title")]
                    assert len(candidates) == 1, "Fresh target is ambiguous"
                    action = {**action, "element_id": candidates[0]["id"]}
                response = call("act", display, action=action)
                report["pre_delivery_recoveries"] = report.get("pre_delivery_recoveries", 0) + 1
            assert response["ok"], response
            report["actions"].append({"type": action["type"], **response["result"]})
            return response["result"]

        def state():
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    return json.loads(state_path.read_text())
                except (OSError, json.JSONDecodeError):
                    time.sleep(0.05)
            raise AssertionError("Fixture did not publish its counters")

        def control(observation, label):
            found = [e for e in observation["elements"] if e.get("pid") == fixture_process.pid
                     and e.get("title") == label]
            assert found, f"Missing fixture control {label} for fixture PID {fixture_process.pid}"
            return found[0]

        try:
            state()
            capabilities = call("test_displays")["result"]
            print("Signed app permissions:", {k: capabilities[k] for k in ("accessibility", "capture")}, flush=True)
            assert capabilities["accessibility"] and capabilities["capture"], "Existing macOS permissions do not cover this signed app process"
            displays = capabilities["displays"]
            modes = [next(d for d in displays if d["main"])]
            secondary = next((d for d in displays if not d["main"]), None)
            if secondary:
                modes.append(secondary)
            for display in modes:
                display_id = display["id"]
                assert call("test_begin", display_id)["ok"]
                observe(display_id)
                act(display_id, {"type": "launch_app", "app": "TaskPilot Control Fixture",
                                 "bundle_id": "org.taskpilot.control-fixture"})
                baseline = state()
                for index in range(5):
                    observation = observe(display_id)
                    assert observation["display"]["id"] == display_id, "Fixture unexpectedly changed display modes"
                    button = control(observation, "Increment")
                    act(display_id, {"type": "press", "element_id": button["id"], "pid": fixture_process.pid})
                    assert state()["clicks"] == baseline["clicks"] + index + 1, state()
                    observation = observe(display_id)
                    target = control(observation, "Double target")
                    act(display_id, {"type": "double_click", "element_id": target["id"], "pid": fixture_process.pid})
                    assert state()["doubles"] == baseline["doubles"] + index + 1, state()
                    observation = observe(display_id)
                    field = control(observation, "Entry field")
                    value = f"fixture-{display_id}-{index}"
                    act(display_id, {"type": "set_value", "element_id": field["id"], "text": value})
                    time.sleep(0.15)
                    assert state()["text"] == value, state()
                    observation = observe(display_id)
                    act(display_id, {"type": "scroll", "pid": fixture_process.pid, "delta_y": 120})
                    observation = observe(display_id)
                    disabled = control(observation, "Disabled target")
                    act(display_id, {"type": "press", "element_id": disabled["id"]}, rejection="disabled_target")
                    old = control(observation, "Increment")
                    observe(display_id)
                    act(display_id, {"type": "press", "element_id": old["id"]}, rejection="stale_target")
                    assert state()["wrong"] == 0, state()
                observation = observe(display_id)
                ignored = control(observation, "Ignored target")
                ignored_result = act(display_id, {"type": "press", "element_id": ignored["id"]})
                assert ignored_result["outcome"] == "delivered_unconfirmed", "An ignored action must not be reported as verified"
                report["ignored_delivery"] = ignored_result["outcome"]
                observation = observe(display_id)
                menu = control(observation, "Fixture")
                act(display_id, {"type": "press", "element_id": menu["id"]})
                observation = observe(display_id)
                menu_item = control(observation, "Increment menu")
                act(display_id, {"type": "press", "element_id": menu_item["id"]})
                time.sleep(0.4)
                assert state()["menus"] == baseline["menus"] + 1, state()
                assert state()["scroll_y"] != baseline["scroll_y"], state()
                if args.live_acp and not report.get("acp"):
                    import sys
                    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "AgentRuntime"))
                    import openclaw_runtime as runtime
                    observation = observe(display_id)
                    client = runtime.ACPClient(str(Path.home() / ".openclaw/bin/openclaw"))
                    try:
                        client.select_model(runtime.PRIMARY_MODELS[0])
                        response = client.prompt(runtime.desktop_instruction(
                            "Click the Increment button in TaskPilot Control Fixture exactly once.",
                            observation, []), Path(observation["screenshot_path"]))
                        decision = runtime.extract_json_object(response)
                        assert decision.get("status") == "act", "ACP did not choose an action"
                        action = runtime.normalized_action(decision["action"])
                        expected = control(observation, "Increment")
                        chosen = next((e for e in observation["elements"] if e.get("id") == action.get("element_id")), None)
                        correct = chosen is not None and chosen.get("pid") == fixture_process.pid and chosen.get("title") == "Increment"
                        if not correct and action.get("type") == "click" and "x" in action and "y" in action:
                            screen = observation["display"]
                            x = screen.get("x", 0) + action["x"] * screen["width"] / 1000
                            y = screen.get("y", 0) + action["y"] * screen["height"] / 1000
                            bounds = expected["frame"]
                            correct = bounds["x"] <= x <= bounds["x"] + bounds["width"] and bounds["y"] <= y <= bounds["y"] + bounds["height"]
                        assert correct, f"ACP did not select the intended fixture control: type={action.get('type')}, resolved_title={chosen.get('title') if chosen else None}, x={action.get('x')}, y={action.get('y')}"

                        before_acp = state()["clicks"]
                        act(display_id, action)
                        assert state()["clicks"] == before_acp + 1, state()
                        assert client.prompt_calls == 1
                        report["acp"] = {"planning_calls": client.prompt_calls, "correct_target": True}
                    finally:
                        client.close()
                report["modes"].append({"display": display, "fixture": state(), "repetitions": 5})
                assert call("test_end", display_id)["ok"]
                print(f"PASS: {display['name']}, five click/double-click/text/scroll cycles, menu, disabled and stale targets", flush=True)
            report["wrong_actions"] = state()["wrong"]
            report["secondary_available"] = secondary is not None
        finally:
            try:
                call("test_end")
            except Exception:
                pass
            try:
                host.stdin.close()
            except BrokenPipeError:
                pass
            try:
                host.wait(timeout=5)
            except subprocess.TimeoutExpired:
                host.terminate()
            fixture_process.terminate()
            fixture_process.wait(timeout=5)
            for path in observations:
                path.unlink(missing_ok=True)
            fixture_log.close()
            host_log.close()
            if args.keep_results:
                args.keep_results.mkdir(parents=True, exist_ok=True)
                import shutil
                for path in root.glob("*.log"):
                    shutil.copy2(path, args.keep_results / path.name)
                (args.keep_results / "report.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
