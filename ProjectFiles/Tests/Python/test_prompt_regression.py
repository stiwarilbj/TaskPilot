from copy import deepcopy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "PromptRegression"))
import evaluate as regression
from fixtures import seed_cases, act, DONE, YES, NO


class PromptRegressionTests(unittest.TestCase):
    def setUp(self):
        self.corpus = {"version": 1, "sanitized_reviewed": True, "cases": seed_cases()}
        self.pack = regression.prompt_pack("baseline")
        self.cases = {case["id"]: case for case in self.corpus["cases"]}

    def scripted(self, identifier, label="candidate", script=None, pack=None):
        case = self.cases[identifier]
        return regression.replay_case(case, pack or self.pack,
                                      script=script if script is not None else case["scripts"][label])

    def recording(self, label="candidate", pack=None, trials=1, source="scripted_control"):
        pack = pack or self.pack
        runs = []
        for case in self.corpus["cases"]:
            for trial in range(trials):
                _, requests = self.scripted(case["id"], label, pack=pack)
                runs.append({"case_id": case["id"], "trial": trial, "requests": requests})
        return {"version": 1, "sanitized_reviewed": True, "source": source,
                "corpus_sha256": regression.digest(self.corpus),
                "prompt_pack_sha256": regression.digest(pack), "runs": runs}

    def test_all_failure_categories_have_sanitized_reproductions_and_healthy_control(self):
        regression.validate_corpus(self.corpus)
        self.assertTrue(regression.CATEGORIES <= {c["category"] for c in self.corpus["cases"]})
        self.assertEqual(len(self.corpus["cases"]), 13)
        self.assertTrue(all(c["provenance"]["kind"] != "sanitized_recording" for c in self.corpus["cases"]))

    def test_candidate_controls_reach_all_independent_postconditions(self):
        for identifier in self.cases:
            with self.subTest(case=identifier):
                result, _ = self.scripted(identifier)
                self.assertTrue(result["success"], result)
                self.assertEqual(result["incorrect_actions"], 0)
                self.assertEqual(result["duplicate_actions"], 0)
                self.assertEqual(result["premature_completion"], False)

    def test_prompt_rule_overrides_are_scoped_to_the_compiled_phase(self):
        runtime = regression.runtime
        observation = {'elements': [], 'applications': []}
        failed = [{'action': {'type': 'press', 'element_id': 'old:save'},
                   'result': {'error_code': 'stale_target', 'outcome': 'rejected', 'message': 'Moved before delivery'}}]
        planning = runtime.desktop_instruction('Click Save', observation, [])
        recovery = runtime.desktop_instruction('Click Save', observation, failed)
        completion = runtime.verification_instruction('Click Save', {'status': 'done'}, observation, failed)
        pack = regression.prompt_pack('candidate', planning_rules='New planning rules')
        self.assertEqual(regression.apply_rules(recovery, pack, 'planning'), recovery)
        self.assertEqual(regression.apply_rules(completion, pack, 'verification'), completion)
        self.assertIn('New planning rules', regression.apply_rules(planning, pack, 'planning'))
        pack = regression.prompt_pack('candidate', recovery_rules='New recovery rules', verification_rules='New completion rules')
        self.assertEqual(regression.apply_rules(planning, pack, 'planning'), planning)
        changed = regression.apply_rules(recovery, pack, 'planning')
        self.assertIn('New recovery rules', changed)
        self.assertEqual(changed.split('RELEVANT ACTION EXAMPLES:', 1)[1], recovery.split('RELEVANT ACTION EXAMPLES:', 1)[1])
        self.assertEqual(regression.prompt_phase(changed), 'recovery')
        self.assertIn('New completion rules', regression.apply_rules(completion, pack, 'verification'))

    def test_real_loop_compiles_failure_and_completion_templates_without_extra_calls(self):
        planning, verification = regression.runtime.desktop_instruction, regression.runtime.verification_instruction
        prompts = []
        def capture(builder, *args):
            result = builder(*args); prompts.append(result); return result
        with mock.patch.object(regression.runtime, 'desktop_instruction', side_effect=lambda *args: capture(planning, *args)), \
             mock.patch.object(regression.runtime, 'verification_instruction', side_effect=lambda *args: capture(verification, *args)):
            result, requests = self.scripted('moved-control')
        self.assertTrue(result['success'])
        self.assertEqual([regression.prompt_phase(p) for p in prompts], ['planning', 'recovery', 'recovery', 'completion'])
        self.assertEqual(len(requests), 4)
        self.assertIn('stale_target', prompts[1])
        self.assertIn('FAILED CONDITION', prompts[1])
        self.assertNotIn('FAILED CONDITION', prompts[-1])
        self.assertEqual(result['duplicate_actions'], 0)

    def test_regression_pack_binds_compiler_version_and_recovery_rules(self):
        changed = regression.prompt_pack('candidate', recovery_rules='Changed recovery rules')
        self.assertNotEqual(regression.digest(changed), regression.digest(self.pack))
        changed['prompt_compiler_version'] += 1
        with self.assertRaisesRegex(ValueError, 'Prompt compiler version'):
            regression.validate_pack(changed)

    def test_wrong_control_and_premature_verifier_claim_are_scored_independently(self):
        result, _ = self.scripted("wrong-window", "baseline")
        self.assertTrue(result["completed"])
        self.assertFalse(result["postconditions_met"])
        self.assertFalse(result["success"])
        self.assertEqual(result["incorrect_actions"], 1)
        self.assertTrue(result["premature_completion"])
        result, _ = self.scripted("premature-done", "baseline")
        self.assertEqual(result["delivered_actions"], 0)
        self.assertFalse(result["success"])
        self.assertEqual(result["requests"], 2)

    def test_exactly_once_ground_truth_detects_duplicate_even_when_final_screen_claims_success(self):
        case = deepcopy(self.cases["healthy-control"])
        repeated = deepcopy(case["transitions"][0])
        repeated["from"] = "saved"
        case["states"]["saved"]["controls"].append(deepcopy(case["states"]["initial"]["controls"][0]))
        case["transitions"].append(repeated)
        result, _ = regression.replay_case(case, self.pack, script=[act(), act(), DONE, YES])
        self.assertEqual(result["duplicate_actions"], 1)
        self.assertFalse(result["postconditions_met"])
        self.assertFalse(result["success"])

    def test_malformed_output_repairs_same_model_without_delivering_invalid_action(self):
        result, requests = self.scripted("invalid-text-type")
        self.assertTrue(result["success"])
        self.assertEqual(result["delivered_actions"], 1)
        self.assertEqual(result["planning"], 3)
        self.assertGreaterEqual(result["verification"], 1)
        self.assertEqual(result["repairs"], 1)
        self.assertEqual(result["requests"], 4)
        self.assertEqual(requests[0]["model"], requests[1]["model"])
        self.assertTrue(requests[1]["repair"])
        exhausted, _ = self.scripted("invalid-text-type", "baseline")
        self.assertEqual(exhausted["requests"], 7)
        self.assertEqual(exhausted["repairs"], 1)
        self.assertEqual(exhausted["delivered_actions"], 0)

    def test_intentionally_repeated_requirements_are_not_duplicate_actions(self):
        case = deepcopy(self.cases["healthy-control"])
        case["goals"]["saved"] = 2
        repeated = deepcopy(case["transitions"][0])
        repeated["from"] = "saved"
        case["states"]["saved"]["controls"].append(deepcopy(case["states"]["initial"]["controls"][0]))
        case["transitions"].append(repeated)
        result, _ = regression.replay_case(case, self.pack, script=[act(), act(), DONE, YES])
        self.assertTrue(result["success"])
        self.assertEqual(result["duplicate_actions"], 0)

    def test_delayed_screen_uses_local_waits_without_extra_model_requests(self):
        result, _ = self.scripted("delayed-dialog")
        self.assertTrue(result["success"])
        self.assertEqual(result["requests"], 4)
        self.assertEqual(result["delivered_actions"], 2)
        self.assertGreaterEqual(result["local_wait_seconds"], 1.2)
        self.assertGreater(result["observation_polls"], result["requests"])
        self.assertEqual(result["recorded_response_seconds"], 1.0)

    def test_command_exit_zero_does_not_satisfy_file_outcome(self):
        result, _ = self.scripted("exit-zero-no-result", "baseline")
        self.assertFalse(result["success"])
        self.assertFalse(result["postconditions_met"])
        self.assertGreaterEqual(result["verification"], 1)
        result, _ = self.scripted("command-syntax")
        self.assertTrue(result["success"])
        self.assertEqual(result["delivered_actions"], 1)

    def test_stale_targets_replan_and_uncertain_submissions_are_not_replayed(self):
        result, _ = self.scripted("moved-control")
        self.assertTrue(result["success"])
        self.assertEqual(result["delivered_actions"], 1)
        result, _ = self.scripted("uncertain-submission", "baseline")
        self.assertTrue(result["postconditions_met"])
        self.assertFalse(result["success"])
        self.assertEqual(result["delivered_actions"], 1)
        self.assertEqual(result["duplicate_actions"], 0)

    def test_replays_bind_exact_prompt_model_purpose_and_image(self):
        case = self.cases["healthy-control"]
        original, requests = self.scripted(case["id"])
        replay, _ = regression.replay_case(case, self.pack, requests=requests)
        for key in original.keys() - {"replay_wall_seconds"}:
            self.assertEqual(replay[key], original[key], key)
        for key in ("instruction_sha256", "image_sha256", "model", "purpose", "repair"):
            wrong = deepcopy(requests)
            wrong[0][key] = "wrong"
            with self.subTest(key=key):
                result, _ = regression.replay_case(case, self.pack, requests=wrong)
                self.assertFalse(result["success"])
                self.assertEqual(result["failure_kind"], "prompt_or_evidence_mismatch")
                self.assertEqual(result["requests"], 0)

    def test_missing_and_extra_responses_make_replay_incomplete(self):
        case = self.cases["healthy-control"]
        _, requests = self.scripted(case["id"])
        result, _ = regression.replay_case(case, self.pack, requests=requests[:-1])
        self.assertEqual(result["failure_kind"], "recording_exhausted")
        result, _ = regression.replay_case(case, self.pack, requests=[*requests, requests[0]])
        self.assertFalse(result["trace_complete"])
        self.assertFalse(result["success"])

    def test_recordings_survive_private_json_disk_round_trip_and_hide_real_home_context(self):
        recording = self.recording()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            corpus_path = regression.private_write(root, "corpus.json", self.corpus)
            recording_path = regression.private_write(root, "recording.json", recording)
            pack_path = regression.private_write(root, "prompt.json", self.pack)
            report = regression.evaluate(regression.load(corpus_path), regression.load(pack_path), regression.load(recording_path))
        self.assertTrue(all(r["success"] for r in report["runs"]))
        original = regression.runtime.desktop_instruction
        prompts = []
        def capture(*args):
            text = original(*args)
            prompts.append(text)
            return text
        with mock.patch.object(regression.runtime, "desktop_instruction", capture):
            self.scripted("healthy-control")
        self.assertNotIn(str(Path.home()), "\n".join(prompts))
        self.assertIn('"home_directory":"/fixture"', prompts[0])

    def test_cli_replay_survives_separate_python_hash_seeds(self):
        script = regression.REPO / "ProjectFiles/Scripts/evaluate-prompts.py"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / "private"
            initial = subprocess.run([sys.executable, str(script), "--private-dir", str(root), "init"],
                                     env={**os.environ, "PYTHONHASHSEED": "1"}, capture_output=True, text=True)
            self.assertEqual(initial.returncode, 0, initial.stderr)
            replay = subprocess.run([sys.executable, str(script), "--private-dir", str(root), "compare",
                                     "--baseline", str(root / "baseline-demo-recording.json"),
                                     "--candidate", str(root / "candidate-demo-recording.json")],
                                    env={**os.environ, "PYTHONHASHSEED": "2"}, capture_output=True, text=True)
            self.assertEqual(replay.returncode, 1, replay.stderr)
            comparison = json.loads(replay.stdout)
            self.assertEqual(comparison["candidate"]["successes"], 13)
            self.assertEqual(comparison["candidate"]["requests"], 52)
            self.assertEqual(comparison["candidate"]["recovery_cycles"], 2)
            self.assertEqual(comparison["candidate"]["cycle_suppressions"], 1)
            self.assertEqual(comparison["baseline"]["successes"], 2)
            self.assertNotIn("invalid_or_incomplete_recording", comparison["reasons"])

    def test_same_recording_cannot_be_reused_for_changed_prompt_or_task_evidence(self):
        recording = self.recording()
        candidate = regression.prompt_pack("candidate", planning_rules="A changed rule")
        with self.assertRaises(ValueError):
            regression.evaluate(self.corpus, candidate, recording)
        changed = deepcopy(self.corpus)
        changed["cases"][0]["task"] += " Also confirm the receipt."
        with self.assertRaises(ValueError):
            regression.evaluate(changed, self.pack, recording)

    def test_comparison_requires_actual_paired_trials_and_blocks_scripted_controls(self):
        pack = regression.prompt_pack("candidate", planning_rules="A hypothetical rule used only to test the gate")
        before = regression.evaluate(self.corpus, self.pack, self.recording("baseline"))
        after = regression.evaluate(self.corpus, pack, self.recording(pack=pack))
        comparison = regression.compare(self.corpus, before, after)
        self.assertFalse(comparison["eligible_for_adoption"])
        self.assertIn("scripted_responses_do_not_measure_prompt_quality", comparison["reasons"])
        self.assertIn("insufficient_paired_trials", comparison["reasons"])
        self.assertEqual(comparison["baseline"]["successes"], 2)
        self.assertEqual(comparison["candidate"]["successes"], 13)
        self.assertFalse(comparison["automatic_adoption"])

    def reports_for_gate(self):
        # Synthetic tests of the gate's mathematics, not recorded model evidence.
        report = regression.evaluate(self.corpus, self.pack, self.recording(trials=3))
        before, after = deepcopy(report), deepcopy(report)
        before["source"] = after["source"] = "recorded_model"
        after["rules_sha256"] = "f" * 64
        return before, after

    def test_gate_passes_only_when_all_covered_trials_are_correct_without_cost_regression(self):
        before, after = self.reports_for_gate()
        self.assertTrue(regression.compare(self.corpus, before, after)["eligible_for_adoption"])
        bad_cases = [("success", False, "candidate_task_failure"),
                     ("incorrect_actions", 1, "candidate_incorrect_action_or_completion"),
                     ("incorrect_action_attempts", 1, "candidate_incorrect_action_or_completion"),
                     ("duplicate_actions", 1, "candidate_incorrect_action_or_completion"),
                     ("premature_completion", True, "candidate_incorrect_action_or_completion"),
                     ("trace_complete", False, "invalid_or_incomplete_recording"),
                     ("requests", 100, "more_requests_for_a_successful_task")]
        for key, value, reason in bad_cases:
            changed = deepcopy(after)
            changed["runs"][0][key] = value
            with self.subTest(key=key):
                self.assertIn(reason, regression.compare(self.corpus, before, changed)["reasons"])
        slow = deepcopy(after)
        for result in slow["runs"]:
            result["task_seconds"] += 5
        self.assertIn("successful_task_time_regression", regression.compare(self.corpus, before, slow)["reasons"])
        missing = deepcopy(after)
        missing["runs"].pop()
        self.assertIn("missing_paired_runs", regression.compare(self.corpus, before, missing)["reasons"])

    def test_private_storage_is_outside_checkout_and_permissions_are_restricted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / "private"
            path = regression.private_write(root, "corpus.json", self.corpus)
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(regression.load(path), self.corpus)
            path.chmod(0o644)
            with self.assertRaises(ValueError): regression.load(path)
            link = root / "link.json"
            link.symlink_to(path)
            with self.assertRaises(ValueError): regression.private_write(root, "link.json", {})
        with self.assertRaises(ValueError): regression.private_root(regression.REPO / "private-corpus")

    def test_private_content_is_rejected_without_being_echoed_or_silently_rewritten(self):
        for value in [{"password": "secret-value"}, {"api_key": "credential-value"},
                      {"response": '{"password":"secret-value"}'}, {"task": "Open /Users/person/Documents/private"},
                      {"task": "Send to personal@example.org"}, {"task": "Visit https://private.example.org"},
                      {"error": "Bearer private-token"}]:
            with self.subTest(field=list(value)), self.assertRaises(ValueError) as caught:
                regression.require_sanitized(value)
            self.assertNotIn(next(iter(value.values())), str(caught.exception))

    def test_aggregate_reports_omit_raw_tasks_responses_commands_and_screens(self):
        recording = self.recording()
        report = regression.evaluate(self.corpus, self.pack, recording)
        serialized = json.dumps(report)
        for private_field in ["Fixture text", "Fixture App", "/fixture/create-result", "instruction_sha256", '"response"', '"task"']:
            self.assertNotIn(private_field, serialized)

    def test_no_real_desktop_provider_shell_diagnostics_or_downloads_access(self):
        with mock.patch.object(regression.runtime.ACPClient, "_run_prompt", side_effect=AssertionError("provider accessed")), \
             mock.patch.object(regression.runtime, "openclaw_version", side_effect=AssertionError("runtime accessed")), \
             mock.patch.object(regression.runtime, "sync_openclaw_google_key", side_effect=AssertionError("credentials accessed")):
            for identifier in self.cases:
                result, _ = self.scripted(identifier)
                self.assertTrue(result["success"])
        case = deepcopy(self.cases["healthy-control"])
        case["task"] = "What is the largest file in Downloads?"
        result, _ = regression.replay_case(case, self.pack, script=[])
        self.assertEqual(result["failure_kind"], "live_side_effect_forbidden")

    def test_invalid_recording_fields_fail_before_replay(self):
        recording = self.recording()
        for change in [{"elapsed_seconds": True}, {"elapsed_seconds": float("inf")},
                       {"elapsed_seconds": -1}, {"provider_retries": "2"}, {"repair": "false"},
                       {"instruction_sha256": "short"}, {"error": {"code": 503}}]:
            bad = deepcopy(recording)
            bad["runs"][0]["requests"][0].update(change)
            with self.subTest(change=list(change)), self.assertRaises(ValueError):
                regression.validate_recording(bad, self.corpus, self.pack)
        duplicate = deepcopy(recording)
        duplicate["runs"].append(deepcopy(duplicate["runs"][0]))
        with self.assertRaises(ValueError): regression.validate_recording(duplicate, self.corpus, self.pack)


if __name__ == "__main__": unittest.main()
