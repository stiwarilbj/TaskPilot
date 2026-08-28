import unittest
from pathlib import Path
import hashlib
import io
import json
import os
import sys
import tempfile
from unittest import mock

RUNTIME_DIRECTORY = Path(__file__).resolve().parents[2] / "AgentRuntime"
sys.path.insert(0, str(RUNTIME_DIRECTORY))

import openclaw_runtime as runtime


class OpenClawRuntimeTests(unittest.TestCase):
    def test_extracts_plain_json(self):
        self.assertEqual(runtime.extract_json_object('{"status":"done"}')["status"], "done")

    def test_extracts_fenced_json(self):
        value = runtime.extract_json_object('Result:\n```json\n{"verified":true}\n```')
        self.assertTrue(value["verified"])

    def test_extracts_json_after_short_narration(self):
        value = runtime.extract_json_object(
            'Here is the decision: {"status":"act","action":{"type":"wait"}}'
        )
        self.assertEqual(value["action"]["type"], "wait")

    def test_rejects_unknown_action(self):
        with self.assertRaisesRegex(RuntimeError, "unsupported"):
            runtime.normalized_action({"type": "shell"})

    def test_native_file_and_shell_actions_are_validated(self):
        self.assertEqual(
            runtime.normalized_action({"type": "read_file", "path": "~/notes.txt"})["path"],
            "~/notes.txt",
        )
        self.assertEqual(
            runtime.normalized_action({
                "type": "write_file", "path": "~/notes.txt", "content": "hello"
            })["content"],
            "hello",
        )
        self.assertEqual(
            runtime.normalized_action({"type": "run_command", "command": "pwd"})["command"],
            "pwd",
        )
        with self.assertRaisesRegex(RuntimeError, "requires path"):
            runtime.normalized_action({"type": "read_file"})
        with self.assertRaisesRegex(RuntimeError, "requires content"):
            runtime.normalized_action({"type": "write_file", "path": "/tmp/a"})
        with self.assertRaisesRegex(RuntimeError, "requires command"):
            runtime.normalized_action({"type": "run_command"})

    def test_browser_navigation_requires_a_url_or_query(self):
        self.assertEqual(
            runtime.normalized_action({
                "type": "navigate_browser", "query": "TaskPilot docs"
            })["query"],
            "TaskPilot docs",
        )
        with self.assertRaisesRegex(RuntimeError, "requires url or query"):
            runtime.normalized_action({"type": "navigate_browser"})

    def test_coordinate_click_requires_both_coordinates(self):
        with self.assertRaisesRegex(RuntimeError, "requires"):
            runtime.normalized_action({"type": "click", "x": 500})

    def test_semantic_click_does_not_require_coordinates(self):
        action = runtime.normalized_action({"type": "click", "element_id": "e12"})
        self.assertEqual(action["element_id"], "e12")
        self.assertEqual(action["type"], "press")

    def test_nonpositive_pid_is_removed(self):
        action = runtime.normalized_action({"type": "key", "key": "return", "pid": 0})
        self.assertNotIn("pid", action)

    def test_blocked_decision_with_a_real_action_is_recovered_as_act(self):
        self.assertEqual(runtime.effective_decision_status({
            "status": "blocked",
            "action": {"type": "press", "element_id": "e133"},
        }), "act")
        self.assertEqual(runtime.effective_decision_status({
            "status": "blocked", "action": {"type": "none"}
        }), "blocked")

    def test_coordinate_bounds_are_enforced(self):
        with self.assertRaisesRegex(RuntimeError, "between 0 and 1000"):
            runtime.normalized_action({"type": "click", "x": 1001, "y": 10})

    def test_compact_observation_removes_local_screenshot_path(self):
        result = runtime.compact_observation(
            {"screenshot_path": "/tmp/private.jpg", "elements": [], "display": {"id": 1}}
        )
        self.assertNotIn("screenshot_path", result)
        self.assertEqual(result["display"]["id"], 1)

    def test_compact_observation_bounds_repeated_inventory(self):
        result = runtime.compact_observation({
            "installed_applications": [
                {"name": str(index), "bundle_id": f"app.{index}", "last_used": "large duplicate"}
                for index in range(180)
            ],
            "elements": [{"id": f"e{index}", "value": str(index)} for index in range(500)],
        })
        self.assertEqual(result["installed_application_count"], 180)
        self.assertEqual(len(result["installed_applications"]), 180)
        self.assertNotIn("last_used", result["installed_applications"][0])
        self.assertEqual(result["visible_element_count"], 500)
        self.assertEqual(len(result["elements"]), runtime.MAX_COMPACT_ELEMENTS)

    def test_compact_observation_drops_empty_structural_elements(self):
        result = runtime.compact_observation({
            "elements": [
                {"id": "e1", "role": "AXGroup", "frame": {"x": 0}},
                {"id": "e2", "role": "AXButton", "title": "Continue"},
                {"id": "e3", "role": "AXStaticText", "value": "Visible result"},
            ]
        })
        self.assertEqual([item["id"] for item in result["elements"]], ["e2", "e3"])

    def test_history_keeps_eight_actions_and_only_two_old_evidence_blocks(self):
        history = [
            {"step": index, "visual_evidence": f"screen {index}", "result": "ok"}
            for index in range(12)
        ]
        result = runtime.compact_history(history)
        self.assertEqual([item["step"] for item in result], list(range(4, 12)))
        self.assertNotIn("visual_evidence", result[0])
        self.assertEqual(result[-2]["visual_evidence"], "screen 10")

    def test_instruction_routes_all_computer_capabilities_through_taskpilot(self):
        prompt = runtime.desktop_instruction("Open Notes", {"elements": []}, [])
        self.assertIn("Do not call OpenClaw's own tools", prompt)
        self.assertIn("read_file", prompt)
        self.assertIn("write_file", prompt)
        self.assertIn("run_command", prompt)
        self.assertIn("navigate_browser", prompt)
        self.assertIn("cross-app control", prompt)
        self.assertIn("TASK CAPABILITY CONTEXT", prompt)
        self.assertIn("ORIGINAL USER TASK", prompt)
        self.assertIn("brand-new execution on every run", prompt)
        self.assertIn("do not treat it as already completed", prompt)
        self.assertIn("Open Notes", prompt)

    def test_instruction_keeps_credentials_local_and_allows_verified_fast_finish(self):
        prompt = runtime.desktop_instruction(
            "Sign in and save the downloaded report", {"elements": []}, []
        )
        self.assertIn("needs_user", prompt)
        self.assertIn("never guess, retrieve, or type a credential", prompt)
        self.assertIn("without sending it to you", prompt)
        self.assertIn("finish_after_action", prompt)

    def test_action_settle_time_is_adaptive(self):
        self.assertEqual(runtime.action_settle_seconds("read_file"), 0)
        self.assertEqual(runtime.action_settle_seconds("write_file"), 0)
        self.assertEqual(runtime.action_settle_seconds("run_command"), 0)
        self.assertEqual(runtime.action_settle_seconds("navigate_browser"), 0.35)
        self.assertLess(runtime.action_settle_seconds("press"), runtime.ACTION_SETTLE_SECONDS)

    def test_structured_native_history_can_skip_only_redundant_visual_verification(self):
        self.assertTrue(runtime.trusted_native_history(
            "Create todo.txt on my Desktop saying buy milk",
            {},
            [{
            "action": {"type": "write_file"},
            "result": {"verified": True, "bytes_written": 4},
        }]))
        self.assertTrue(runtime.trusted_native_history(
            "What does Documents/report.txt say?",
            {},
            [{
            "action": {"type": "read_file"},
            "result": {"content": "exact contents"},
        }]))
        self.assertFalse(runtime.trusted_native_history(
            "Create todo.txt on my Desktop saying buy milk",
            {},
            [{
            "action": {"type": "write_file"},
            "result": {"verified": False},
        }]))
        self.assertFalse(runtime.trusted_native_history(
            "Run the shell command false",
            {},
            [{
            "action": {"type": "run_command"},
            "result": {"exit_code": 1, "timed_out": False},
        }]))
        self.assertFalse(runtime.trusted_native_history(
            "Open Notes and click New Note",
            {},
            [{
            "action": {"type": "press"},
            "result": {"message": "pressed"},
        }]))
        self.assertFalse(runtime.trusted_native_history(
            "Read ~/Documents/notes.txt and copy it into Notes",
            {},
            [{
                "action": {"type": "read_file"},
                "result": {"content": "exact contents"},
            }],
        ))

    def test_fast_finish_is_limited_to_self_verifying_single_action_tasks(self):
        decision = {"finish_after_action": True, "remaining_requirements": []}
        self.assertTrue(runtime.native_action_can_finish(
            "Create todo.txt on my Desktop saying buy milk",
            decision,
            {"type": "write_file"},
            {"verified": True},
            {},
        ))
        self.assertFalse(runtime.native_action_can_finish(
            "Create todo.txt on my Desktop saying buy milk",
            decision,
            {"type": "write_file"},
            {"verified": False},
            {},
        ))
        self.assertTrue(runtime.native_action_can_finish(
            "Run the shell command touch /tmp/taskpilot-marker",
            decision,
            {"type": "run_command"},
            {"exit_code": 0, "timed_out": False},
            {},
        ))
        self.assertFalse(runtime.native_action_can_finish(
            "Run git status and show output",
            decision,
            {"type": "run_command"},
            {"exit_code": 0, "timed_out": False},
            {},
        ))

    def test_secure_field_detection_pauses_only_for_empty_unhandled_fields(self):
        observation = {"elements": [{
            "id": "e7",
            "pid": 123,
            "role": "AXSecureTextField",
            "description": "Account password",
            "value": "",
        }]}
        target = runtime.secure_input_target(observation, [])
        self.assertEqual(target["element_id"], "e7")
        self.assertEqual(target["input_kind"], "password")

        filled = {"elements": [{**observation["elements"][0], "value": "••••"}]}
        self.assertIsNone(runtime.secure_input_target(filled, []))
        self.assertIsNone(runtime.secure_input_target(observation, [{
            "action": "user_input_entered",
            "result": {"target_signature": target["target_signature"]},
        }]))

    def test_verification_code_field_uses_a_specific_local_request(self):
        target = runtime.secure_input_target({"elements": [{
            "id": "otp",
            "pid": 321,
            "role": "AXTextField",
            "description": "Verification code",
            "value": "",
        }]}, [])
        self.assertEqual(target["input_kind"], "verification_code")
        self.assertEqual(target["title"], "Verification code required")

    def test_user_secret_is_sent_only_to_the_native_type_action(self):
        secret = "Correct-Horse-Battery-Staple"
        emitted = []
        bridge_calls = []

        def fake_emit(kind, **payload):
            emitted.append({"kind": kind, **payload})

        def fake_bridge(method, display_id, **payload):
            bridge_calls.append((method, display_id, payload))
            return {"message": "ok"}

        target = {
            "element_id": "e9",
            "pid": 444,
            "input_kind": "password",
            "title": "Password required",
            "message": "The account password is required.",
            "target_signature": "444|account password",
        }
        stdin_payload = json.dumps({
            "kind": "user_input_response",
            "request_id": "fixed-request",
            "value": secret,
        }) + "\n"
        with mock.patch.object(runtime.uuid, "uuid4", return_value="fixed-request"), \
             mock.patch.object(runtime, "emit", side_effect=fake_emit), \
             mock.patch.object(runtime, "bridge_call", side_effect=fake_bridge), \
             mock.patch.object(sys, "stdin", io.StringIO(stdin_payload)):
            result = runtime.request_and_enter_user_input(target, 88)

        self.assertEqual(emitted[0]["kind"], "user_input_required")
        self.assertNotIn(secret, json.dumps(emitted))
        self.assertEqual(bridge_calls[0][2]["action"], {
            "type": "focus", "element_id": "e9"
        })
        self.assertEqual(bridge_calls[1][2]["action"]["text"], secret)
        self.assertNotIn(secret, json.dumps(result))
        self.assertFalse(result["secret_retained"])

    def test_simple_file_requests_route_to_native_file_tools(self):
        create = runtime.task_capability_context(
            "Create todo.txt on my Desktop saying buy milk", {}
        )
        self.assertIn("file_write", create["recommended_capabilities"])
        self.assertEqual(create["mentioned_standard_locations"]["desktop"], "~/Desktop")

        read = runtime.task_capability_context(
            "What does Downloads/report.txt say?", {}
        )
        self.assertIn("file_read", read["recommended_capabilities"])
        self.assertEqual(read["mentioned_standard_locations"]["downloads"], "~/Downloads")

    def test_simple_shell_and_browser_requests_route_correctly(self):
        shell = runtime.task_capability_context("Run git status in ~/project", {})
        self.assertIn("shell", shell["recommended_capabilities"])

        browser = runtime.task_capability_context(
            "Search the web for the OpenClaw documentation", {}
        )
        self.assertIn("browser", browser["recommended_capabilities"])
        self.assertTrue(any("navigate_browser" in item for item in browser["relevant_examples"]))

    def test_context_recognizes_cross_app_workflow_without_misrouting_notes_as_file(self):
        observation = {
            "installed_applications": [
                {"name": "Safari"}, {"name": "Notes"}, {"name": "Finder"}
            ],
            "applications": [{"name": "Safari"}],
        }
        workflow = runtime.task_capability_context(
            "Copy the total from this page in Safari into Notes", observation
        )
        self.assertIn("browser", workflow["recommended_capabilities"])
        self.assertIn("app_automation", workflow["recommended_capabilities"])
        self.assertEqual(workflow["explicitly_named_apps"], ["Notes", "Safari"])
        self.assertIn("Safari", workflow["currently_visible_apps"])

        note = runtime.task_capability_context("Write a note in Notes saying hello", observation)
        self.assertIn("app_automation", note["recommended_capabilities"])
        self.assertNotIn("file_write", note["recommended_capabilities"])

    def test_completion_verifier_accepts_validated_native_results(self):
        prompt = runtime.verification_instruction(
            "Create a note file",
            {"status": "done", "output": "Created it"},
            {"elements": []},
            [{
                "step": 1,
                "action": {"type": "write_file", "path": "/tmp/note.txt"},
                "result": {"message": "Wrote 4 bytes", "bytes_written": 4},
            }],
        )
        self.assertIn("validated native action results", prompt)
        self.assertIn("bytes_written", prompt)

    def test_largest_downloads_instruction_requires_proven_descending_size_sort(self):
        prompt = runtime.desktop_instruction(
            "What’s my largest file in my downloads folder", {"elements": []}, []
        )
        self.assertIn("SPECIAL FINDER ACCURACY RULE", prompt)
        self.assertIn("down sort arrow must be inside the Size column", prompt)
        self.assertIn("Clicking Size is not proof", prompt)

    def test_exact_largest_file_uses_top_level_metadata_and_ignores_nested_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "small.txt").write_bytes(b"a" * 10)
            (root / "largest.iso").write_bytes(b"b" * 100)
            nested = root / "folder"
            nested.mkdir()
            (nested / "nested.bin").write_bytes(b"c" * 1000)
            self.assertEqual(
                runtime.largest_top_level_file(root),
                {"name": "largest.iso", "bytes": 100},
            )

    def test_file_size_formatter_includes_readable_decimal_units(self):
        self.assertEqual(runtime.formatted_file_size(5_267_005_440), "5.27 GB")

    @staticmethod
    def finder_downloads_observation(sort_title="go down", sort_x=375):
        return {
            "elements": [
                {"id": "window", "role": "AXWindow", "title": "Downloads", "depth": 1},
                {"id": "name", "role": "AXStaticText", "value": "Name", "depth": 7,
                 "frame": {"x": 100, "y": 120, "width": 40, "height": 16}},
                {"id": "size", "role": "AXStaticText", "value": "Size", "depth": 7,
                 "frame": {"x": 300, "y": 120, "width": 30, "height": 16}},
                {"id": "kind", "role": "AXStaticText", "value": "Kind", "depth": 7,
                 "frame": {"x": 400, "y": 120, "width": 35, "height": 16}},
                {"id": "date", "role": "AXStaticText", "value": "Date Added", "depth": 7,
                 "frame": {"x": 500, "y": 120, "width": 70, "height": 16}},
                {"id": "sort", "role": "AXImage", "title": sort_title, "depth": 7,
                 "frame": {"x": sort_x, "y": 122, "width": 12, "height": 10}},
                {"id": "folder-row", "role": "AXRow", "depth": 5},
                {"id": "folder-name", "role": "AXTextField", "value": "TaskPilot", "depth": 7},
                {"id": "folder-size", "role": "AXStaticText", "value": "--", "depth": 7},
                {"id": "folder-kind", "role": "AXStaticText", "value": "Folder", "depth": 7},
                {"id": "file-row", "role": "AXRow", "depth": 5},
                {"id": "file-name", "role": "AXTextField", "value": "largest.iso", "depth": 7},
                {"id": "file-size", "role": "AXStaticText", "value": "5.27 GB", "depth": 7},
                {"id": "file-kind", "role": "AXStaticText", "value": "ISO disk image", "depth": 7},
                {"id": "next-row", "role": "AXRow", "depth": 5},
                {"id": "next-name", "role": "AXTextField", "value": "archive.zip", "depth": 7},
                {"id": "next-size", "role": "AXStaticText", "value": "507.5 MB", "depth": 7},
            ]
        }

    def test_visible_largest_downloads_file_skips_folders_and_uses_first_file(self):
        result = runtime.visible_largest_downloads_file(self.finder_downloads_observation())
        self.assertEqual(result, {"name": "largest.iso", "size": "5.27 GB"})

    def test_visible_largest_downloads_file_rejects_date_added_sort(self):
        observation = self.finder_downloads_observation(sort_x=575)
        self.assertIsNone(runtime.visible_largest_downloads_file(observation))

    def test_visible_largest_downloads_file_rejects_ascending_size_sort(self):
        observation = self.finder_downloads_observation(sort_title="go up")
        self.assertIsNone(runtime.visible_largest_downloads_file(observation))

    def test_largest_downloads_action_clicks_size_then_uses_finder_shortcut(self):
        observation = self.finder_downloads_observation(sort_x=575)
        observation["elements"][2]["pid"] = 123
        self.assertEqual(
            runtime.largest_downloads_next_action(observation, []),
            {"type": "press", "element_id": "size"},
        )
        self.assertEqual(
            runtime.largest_downloads_next_action(observation, [{
                "accuracy_action": "sort_downloads_by_size"
            }]),
            {"type": "key", "key": "6", "modifiers": ["control", "command"], "pid": 123},
        )

    def test_taskpilot_screen_captures_use_png(self):
        self.assertEqual(runtime.image_mime_type(Path("screen-123.png")), "image/png")

    def test_round_robin_cycles_all_five_models_across_restarts(self):
        with tempfile.TemporaryDirectory() as directory:
            state_path = Path(directory) / "router.json"
            selected = []
            for _ in range(6):
                router = runtime.RoundRobinModelRouter(state_path)
                selected.append(router.execute(lambda model: model))
            self.assertEqual(selected, [*runtime.ALL_MODELS, runtime.ALL_MODELS[0]])

    def test_failed_model_moves_immediately_to_the_next_model(self):
        with tempfile.TemporaryDirectory() as directory:
            state_path = Path(directory) / "router.json"
            router = runtime.RoundRobinModelRouter(state_path)
            attempted = []

            def fail_first(model):
                attempted.append(model)
                if len(attempted) == 1:
                    raise runtime.ModelCapacityError("429 quota exhausted")
                return model

            self.assertEqual(router.execute(fail_first), runtime.ALL_MODELS[1])
            self.assertEqual(attempted, list(runtime.ALL_MODELS[:2]))
            restarted = runtime.RoundRobinModelRouter(state_path)
            self.assertEqual(restarted.execute(lambda model: model), runtime.ALL_MODELS[2])

    def test_old_phase_state_migrates_to_the_new_five_model_cycle(self):
        with tempfile.TemporaryDirectory() as directory:
            state_path = Path(directory) / "router.json"
            state_path.write_text(
                '{"version":1,"phase":"probe","next_primary":0,"next_reserve":0,"primary_failures":[]}',
                encoding="utf-8",
            )
            router = runtime.RoundRobinModelRouter(state_path)
            self.assertEqual(router.execute(lambda model: model), runtime.ALL_MODELS[0])

    def test_invalid_credential_fails_without_wasting_requests_on_other_models(self):
        with tempfile.TemporaryDirectory() as directory:
            router = runtime.RoundRobinModelRouter(Path(directory) / "router.json")
            attempts = []
            with self.assertRaisesRegex(RuntimeError, "invalid credential"):
                router.execute(lambda model: attempts.append(model) or (_ for _ in ()).throw(
                    RuntimeError("invalid credential")
                ))
            self.assertEqual(attempts, [runtime.ALL_MODELS[0]])

    def test_noncredential_model_error_rotates_to_next_model(self):
        with tempfile.TemporaryDirectory() as directory:
            router = runtime.RoundRobinModelRouter(Path(directory) / "router.json")
            attempts = []

            def operation(model):
                attempts.append(model)
                if len(attempts) == 1:
                    raise RuntimeError("model returned an empty response")
                return model

            self.assertEqual(router.execute(operation), runtime.ALL_MODELS[1])
            self.assertEqual(attempts, list(runtime.ALL_MODELS[:2]))

    def test_recognizes_google_quota_error_forms(self):
        self.assertTrue(runtime.is_model_capacity_failure("HTTP 429"))
        self.assertTrue(runtime.is_model_capacity_failure("Rate-limited — ready in ~25s"))
        self.assertTrue(runtime.is_model_capacity_failure("RESOURCE_EXHAUSTED"))
        self.assertTrue(runtime.is_model_capacity_failure("quota limit reached"))
        self.assertTrue(runtime.is_model_capacity_failure("Google Gemini first response retry deadline reached"))
        self.assertTrue(runtime.is_model_capacity_failure(
            "Google API error (503): model experiencing high demand [code=UNAVAILABLE]"
        ))
        self.assertFalse(runtime.is_model_capacity_failure("invalid API key"))

    def test_invalid_key_error_is_actionable_in_taskpilot(self):
        message = runtime.user_facing_openclaw_error(
            "Google Generative AI API error (400): API key not valid."
        )
        self.assertIn("Gemini rejected the saved API key", message)
        self.assertIn("click Check", message)
        self.assertIn("Reconfigure Gemini", message)

    def test_recovers_provider_error_from_openclaw_session_transcript(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session_id = "fake-acp-session"
            transcript = root / "transcript.jsonl"
            transcript.write_text(
                json.dumps({"type": "session", "id": "internal"}) + "\n" +
                json.dumps({
                    "type": "message",
                    "message": {
                        "role": "assistant",
                        "stopReason": "error",
                        "errorMessage": "RESOURCE_EXHAUSTED: quota reached",
                    },
                }) + "\n",
                encoding="utf-8",
            )
            (root / "sessions.json").write_text(
                json.dumps({
                    f"agent:main:acp-bridge:{session_id}": {
                        "sessionFile": str(transcript)
                    }
                }),
                encoding="utf-8",
            )
            self.assertEqual(
                runtime.openclaw_session_error(session_id, root),
                "RESOURCE_EXHAUSTED: quota reached",
            )

    def test_recovers_gateway_injected_capacity_message_from_transcript(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session_id = "capacity-acp-session"
            transcript = root / "transcript.jsonl"
            transcript.write_text(
                json.dumps({
                    "type": "message",
                    "message": {
                        "role": "assistant",
                        "stopReason": "stop",
                        "content": [{
                            "type": "text",
                            "text": "The AI service is temporarily overloaded. Please try again in a moment.",
                        }],
                    },
                }) + "\n",
                encoding="utf-8",
            )
            (root / "sessions.json").write_text(
                json.dumps({
                    f"agent:main:acp-bridge:{session_id}": {
                        "sessionFile": str(transcript)
                    }
                }),
                encoding="utf-8",
            )
            detail = runtime.openclaw_session_error(session_id, root)
            self.assertIn("temporarily overloaded", detail)
            self.assertTrue(runtime.is_model_capacity_failure(detail))

    def test_saved_key_is_synchronized_once_without_putting_it_in_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command_log = root / "commands.jsonl"
            fake_openclaw = root / "openclaw"
            fake_openclaw.write_text(
                f"""#!{sys.executable}
import hashlib
import json
import sys
from pathlib import Path
arguments = sys.argv[1:]
entry = {{'arguments': arguments}}
if arguments[:3] == ['models', 'auth', 'paste-api-key']:
    key = sys.stdin.readline().strip()
    entry['stdin_sha256'] = hashlib.sha256(key.encode()).hexdigest()
with Path({str(command_log)!r}).open('a', encoding='utf-8') as handle:
    handle.write(json.dumps(entry) + '\\n')
raise SystemExit(0)
""",
                encoding="utf-8",
            )
            os.chmod(fake_openclaw, 0o700)
            state_path = root / "key-state.json"
            api_key = "AIzaSyExampleSecretThatIsLongEnough"

            runtime.sync_openclaw_google_key(str(fake_openclaw), api_key, state_path)
            first_lines = command_log.read_text(encoding="utf-8").splitlines()
            runtime.sync_openclaw_google_key(str(fake_openclaw), api_key, state_path)
            second_lines = command_log.read_text(encoding="utf-8").splitlines()

            self.assertEqual(len(first_lines), 3)
            self.assertEqual(second_lines, first_lines)
            entries = [json.loads(line) for line in first_lines]
            flattened_arguments = " ".join(" ".join(entry["arguments"]) for entry in entries)
            self.assertNotIn(api_key, flattened_arguments)
            self.assertEqual(
                entries[0]["stdin_sha256"],
                hashlib.sha256(api_key.encode()).hexdigest(),
            )
            self.assertEqual(entries[1]["arguments"], ["gateway", "restart"])
            self.assertEqual(entries[2]["arguments"], ["health", "--json"])
            self.assertNotIn(api_key, state_path.read_text(encoding="utf-8"))

    def test_runtime_configuration_reads_key_from_private_stdin(self):
        api_key = "AIzaSyExampleSecretThatIsLongEnough"
        payload = json.dumps({
            "kind": "runtime_configuration",
            "gemini_api_key": api_key,
        }) + "\n"
        with mock.patch.object(sys, "stdin", io.StringIO(payload)):
            self.assertEqual(runtime.read_runtime_configuration(), api_key)

    def test_runtime_can_reuse_openclaws_configured_credential(self):
        payload = json.dumps({
            "kind": "runtime_configuration",
            "gemini_api_key": "",
        }) + "\n"
        with mock.patch.object(sys, "stdin", io.StringIO(payload)):
            self.assertEqual(runtime.read_runtime_configuration(), "")

    def test_incomplete_json_rotates_to_the_next_model(self):
        class FakeClient:
            def __init__(self):
                self.models = []

            def select_model(self, model):
                self.models.append(model)

            def prompt(self, _instruction, _screenshot_path):
                if len(self.models) == 1:
                    return '{"status":"act","action":{"type":'
                return '{"status":"done"}'

        with tempfile.TemporaryDirectory() as directory:
            client = FakeClient()
            router = runtime.RoundRobinModelRouter(Path(directory) / "router.json")
            result = runtime.routed_json_prompt(
                router, client, "Return JSON", Path(directory) / "screen.png"
            )
            self.assertEqual(result["status"], "done")
            self.assertEqual(client.models, list(runtime.ALL_MODELS[:2]))

    def test_acp_client_completes_image_prompt_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            fake_openclaw = Path(directory) / "openclaw"
            fake_openclaw.write_text(
                f"""#!{sys.executable}
import json
import sys
for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    if 'id' not in message:
        continue
    if method == 'initialize':
        result = {{'protocolVersion': 1, 'agentCapabilities': {{'promptCapabilities': {{'image': True}}}}}}
    elif method == 'session/new':
        result = {{'sessionId': 'fake-taskpilot-session'}}
    elif method == 'session/prompt':
        update = {{'jsonrpc': '2.0', 'method': 'session/update', 'params': {{'sessionId': 'fake-taskpilot-session', 'update': {{'sessionUpdate': 'agent_message_chunk', 'content': {{'type': 'text', 'text': '{{\"status\":\"done\"}}'}}}}}}}}
        print(json.dumps(update), flush=True)
        result = {{'stopReason': 'end_turn'}}
    else:
        result = {{}}
    print(json.dumps({{'jsonrpc': '2.0', 'id': message['id'], 'result': result}}), flush=True)
""",
                encoding="utf-8",
            )
            os.chmod(fake_openclaw, 0o700)
            screenshot = Path(directory) / "screen.png"
            screenshot.write_bytes(b"not-a-real-png-needed-for-transport-test")
            client = runtime.ACPClient(str(fake_openclaw))
            try:
                client.select_model(runtime.ALL_MODELS[0])
                response = client.prompt("Return JSON", screenshot)
            finally:
                client.close()
            self.assertEqual(client.selected_model, runtime.ALL_MODELS[0])
            self.assertEqual(runtime.extract_json_object(response)["status"], "done")


if __name__ == "__main__":
    unittest.main()
