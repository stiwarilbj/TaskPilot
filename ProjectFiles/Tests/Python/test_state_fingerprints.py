"""Revision caching with real ACP serialization and entirely offline transport."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "AgentRuntime"))
import openclaw_runtime as runtime
import task_evidence as evidence
from task_inputs import TASK_INPUT_VERSION, TaskInputBindings
from test_verification_sessions import ACPFixture


class CanonicalStateTests(unittest.TestCase):
    def test_pressure_eviction_serializes_with_rebuild_and_preserves_accepted_state(self):
        state = evidence.RevisionedJSONState()
        state.update({"label": "accepted fixture"})
        fingerprint, revision = state.fingerprint, state.revision
        entered, release = threading.Event(), threading.Event()
        results, errors = [], []
        def build():
            entered.set()
            if not release.wait(2): raise RuntimeError("Fixture was not released")
            return state.fingerprint  # Nested memoization must not deadlock.
        def rebuild():
            try: results.append(state.memoize("fixture", build))
            except BaseException as error: errors.append(error)
        worker = threading.Thread(target=rebuild)
        worker.start(); self.assertTrue(entered.wait(1))
        eviction = threading.Thread(target=state.evict_memoized)
        eviction.start(); release.set()
        worker.join(2); eviction.join(2)
        self.assertFalse(worker.is_alive()); self.assertFalse(eviction.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(results, [fingerprint])
        self.assertEqual(state._values, {})
        self.assertEqual((state.fingerprint, state.revision), (fingerprint, revision))

    def test_unchanged_state_encodes_and_hashes_once(self):
        state = evidence.RevisionedJSONState()
        value = {"nested": [{"label": "Save", "enabled": True}], "unicode": "café"}
        expected = evidence.digest(value)
        with mock.patch.object(evidence.json, "dumps", wraps=json.dumps) as encode, \
             mock.patch.object(evidence.hashlib, "sha256", wraps=hashlib.sha256) as digest:
            for _ in range(5):
                state.update(value)
                self.assertEqual(state.fingerprint, expected)
                self.assertIs(state.canonical, state.canonical)
            self.assertEqual((encode.call_count, digest.call_count, state.revision), (1, 1, 1))
            value["nested"][0]["label"] = "Submit"
            state.update(value)
            self.assertNotEqual(state.fingerprint, expected)
            self.assertEqual((encode.call_count, digest.call_count, state.revision), (2, 2, 2))

    def test_dictionary_order_does_not_create_a_revision_but_list_order_does(self):
        state = evidence.RevisionedJSONState()
        state.update({"a": 1, "b": [2, 3]}); before = state.fingerprint
        state.update({"b": [2, 3], "a": 1})
        self.assertEqual((state.fingerprint, state.revision), (before, 1))
        state.update({"a": 1, "b": [3, 2]})
        self.assertNotEqual(state.fingerprint, before)
        self.assertEqual(state.revision, 2)

    def test_equal_python_numbers_of_different_json_types_invalidate(self):
        for first, second in [(True, 1), (1, 1.0), (0.0, -0.0)]:
            with self.subTest(first=first, second=second):
                state = evidence.RevisionedJSONState()
                value = {"nested": [first]}; state.update(value); before = state.fingerprint
                value["nested"][0] = second; state.update(value)
                self.assertNotEqual(state.fingerprint, before)
                self.assertEqual(state.revision, 2)

    def test_snapshot_has_no_aliases_to_nested_mutable_inputs(self):
        state = evidence.RevisionedJSONState(); value = {"rows": [{"title": "Draft"}]}
        state.update(value); before = state.fingerprint
        value["rows"].append({"title": "Other"})
        self.assertEqual(state.fingerprint, before)  # Current revision is immutable.
        state.update(value)
        self.assertNotEqual(state.fingerprint, before)

    def test_clearing_releases_representations_and_next_update_is_fresh(self):
        state = evidence.RevisionedJSONState(); state.update({"label": "private fixture"})
        state.fingerprint; state.memoize("signature", lambda: "fixture")
        state.clear()
        self.assertIsNone(state._snapshot); self.assertEqual(state._values, {})
        state.update({"label": "new"})
        self.assertEqual(state.fingerprint, evidence.digest({"label": "new"}))

    def test_failed_encoding_is_not_cached_as_a_valid_representation(self):
        state = evidence.RevisionedJSONState(); state.update({"unsupported": {1}})
        with self.assertRaises(TypeError): state.fingerprint
        self.assertEqual(state._values, {})
        state.update({"supported": [1]})
        self.assertEqual(state.fingerprint, evidence.digest({"supported": [1]}))

    def test_immutable_task_inputs_keep_the_existing_identity_and_encode_once(self):
        inputs = TaskInputBindings('Read file "/fixture/a.txt"', scope="0123456789abcdef")
        expected = hashlib.sha256(json.dumps([TASK_INPUT_VERSION,
            [(e.identifier, e.value, e.sources) for e in inputs.entries], inputs.omitted], ensure_ascii=True).encode()).hexdigest()
        with mock.patch.object(evidence.json, "dumps", wraps=json.dumps) as encode, \
             mock.patch.object(evidence.hashlib, "sha256", wraps=hashlib.sha256) as digest:
            self.assertEqual([inputs.fingerprint() for _ in range(5)], [expected] * 5)
            self.assertEqual((encode.call_count, digest.call_count), (1, 1))
        self.assertNotEqual(inputs.fingerprint(), TaskInputBindings('Read file "/fixture/a.txt"').fingerprint())


class LedgerFingerprintTests(unittest.TestCase):
    def setUp(self):
        self.task = 'Create "/fixture/a.txt" and check its contents.'
        self.ledger = evidence.TaskEvidenceLedger(self.task, "task-a", input_scope="0123456789abcdef")
        self.requirement = {"source": self.task, "description": "Verified file contents",
                            "check": {"type": "file_contents", "path": "/fixture/a.txt", "content": "exact"}}
        self.ledger.add_requirements([self.requirement])
        self.ledger.inputs.fingerprint()

    def legacy_fingerprint(self):
        ledger = self.ledger
        return evidence.digest([evidence.CHECKLIST_VERSION, ledger.task, ledger.generation, ledger.inputs.fingerprint(),
            ledger.requirements, {key: [e["fact_fingerprint"], e["action_fingerprint"], e["valid"], e["mutable"],
            e["origin"], e.get("effect_check")] for key, e in ledger.evidence.items()}, ledger.coverage_complete])

    def test_same_ledger_revision_reuses_canonical_bytes_and_fingerprint(self):
        expected = self.legacy_fingerprint()
        with mock.patch.object(evidence.json, "dumps", wraps=json.dumps) as encode, \
             mock.patch.object(evidence.hashlib, "sha256", wraps=hashlib.sha256) as digest:
            for _ in range(5):
                self.ledger.refresh()
                self.ledger.add_requirements([self.requirement])
                self.assertEqual(self.ledger.fingerprint(), expected)
                self.assertEqual(self.ledger.revision, 1)
            self.assertEqual((encode.call_count, digest.call_count), (1, 1))

    def test_proof_invalidation_reproof_and_audit_change_revision_and_identity(self):
        ledger = self.ledger; before = ledger.fingerprint(); revision = ledger.revision
        ledger.add_evidence({"type": "file_contents", "path": "/fixture/a.txt",
                             "content_sha256": evidence.content_hash(self.requirement["check"])}, mutable=True)
        proven = ledger.fingerprint()
        self.assertNotEqual(before, proven); self.assertGreater(ledger.revision, revision)
        self.assertEqual(ledger.requirements["r1"]["state"], "proven")
        ledger.invalidate(lambda e: e["mutable"])
        self.assertNotEqual(proven, ledger.fingerprint())
        self.assertEqual(ledger.requirements["r1"]["state"], "invalidated")
        ledger.add_evidence({"type": "file_contents", "path": "/fixture/a.txt",
                             "content_sha256": evidence.content_hash(self.requirement["check"])}, mutable=True)
        reproof = ledger.fingerprint()
        self.assertTrue(ledger.audit({"verified": True, "coverage_complete": True,
            "proofs": [{"requirement_id": "r1", "evidence_ids": ["e2"], "rationale": "Exact native contents"}]}))
        self.assertNotEqual(reproof, ledger.fingerprint())
        self.assertEqual(ledger.fingerprint(), self.legacy_fingerprint())

    def test_nested_parameters_and_effect_metadata_invalidate_without_mutation_hooks(self):
        ledger = self.ledger
        ref = ledger.add_evidence({"type": "file_exists", "path": "/fixture/a.txt"})
        ledger.evidence[ref]["effect_check"] = {"type": "file_contents", "path": "/fixture/a.txt", "content": "exact"}
        before = ledger.fingerprint()
        ledger.evidence[ref]["effect_check"]["content"] = "different"
        self.assertNotEqual(before, ledger.fingerprint())
        before = ledger.fingerprint()
        ledger.requirements["r1"]["check"]["path"] = "/fixture/b.txt"
        self.assertNotEqual(before, ledger.fingerprint())
        self.assertEqual(ledger.fingerprint(), self.legacy_fingerprint())

    def test_noop_invalidation_and_local_wait_leave_revision_unchanged(self):
        before = self.ledger.fingerprint(); revision = self.ledger.revision
        self.ledger.invalidate(lambda e: False)
        self.ledger.before_action({"type": "wait", "seconds": 1})
        self.assertEqual((self.ledger.fingerprint(), self.ledger.revision), (before, revision))

    def test_verifier_prompt_projection_does_not_modify_the_ledger(self):
        self.ledger.coverage_complete = True
        before = self.ledger.fingerprint(); revision = self.ledger.revision
        projected = runtime.verification_evidence(self.task, [], self.ledger)
        self.assertEqual(projected["whole_request_coverage"], "requires_independent_audit")
        self.assertNotIn("state", projected["requirements"]["r1"])
        self.assertEqual((self.ledger.fingerprint(), self.ledger.revision), (before, revision))


class ObservationFingerprintTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(); self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "screen.png"; self.path.write_bytes(b"fixture pixels")
        self.observation = {"observation_revision": "first", "screenshot_path": str(self.path),
            "applications": [{"pid": 41, "name": "Fixture", "window_count": 1,
                              "windows": [{"title": "Draft", "frame": {"x": 0, "y": 0}}]}],
            "elements": [{"id": "first:button", "pid": 41, "role": "AXButton", "title": "Save",
                          "enabled": True, "frame": {"x": 10, "y": 10, "width": 40, "height": 20}}]}
        self.router = runtime.AdaptiveModelRouter(lambda *a, **k: None, sleep=lambda _: None)
        for name in ("emit", "session_transcript_cursor"):
            patch = mock.patch.object(runtime, name, return_value=None); patch.start(); self.addCleanup(patch.stop)

    def route(self, fixture, purpose="planning", instruction="fixture task", ledger=None):
        return runtime.routed_json_prompt(self.router, fixture.client, instruction, self.path,
            purpose=purpose, observation=self.observation, ledger=ledger)

    def test_progress_signatures_are_computed_once_per_pid_and_changed_revision(self):
        expected = runtime._observation_progress_signature(self.observation, 41)
        with runtime.screenshot_buffer_scope(), \
             mock.patch.object(runtime, "_observation_progress_signature", wraps=runtime._observation_progress_signature) as build:
            state = runtime.observation_state(self.observation)
            for _ in range(5): self.assertEqual(runtime.observation_progress_signature(self.observation, 41), expected)
            self.assertEqual(build.call_count, 1)
            runtime.observation_progress_signature(self.observation)
            self.assertEqual(build.call_count, 2)
            self.observation["elements"][0]["title"] = "Submit"
            self.assertNotEqual(runtime.observation_progress_signature(self.observation, 41), expected)
            self.assertEqual((build.call_count, state.revision), (3, 2))

    def test_unchanged_decision_hashes_state_and_identity_once_and_adds_no_calls(self):
        fixture = ACPFixture(['{"status":"done"}'])
        with runtime.screenshot_buffer_scope(), \
             mock.patch.object(runtime.hashlib, "sha256", wraps=hashlib.sha256) as digest:
            self.route(fixture); identity = fixture.client._decision_fingerprint
            self.assertEqual(digest.call_count, 2)
            self.route(fixture)
            self.assertIs(fixture.client._decision_fingerprint, identity)
            self.assertEqual((digest.call_count, fixture.client.prompt_calls, self.router.metrics["cache_hits"]), (2, 1, 1))

    def test_copies_of_the_same_accepted_revision_reuse_its_representation(self):
        with runtime.screenshot_buffer_scope(), \
             mock.patch.object(evidence.json, "dumps", wraps=json.dumps) as encode:
            first = runtime.observation_state(self.observation); before = first.fingerprint
            second = runtime.observation_state(deepcopy(self.observation))
            self.assertIs(first, second); self.assertEqual(second.fingerprint, before)
            self.assertEqual(encode.call_count, 1)

    def test_scope_cancellation_releases_cached_contents_and_representations(self):
        with self.assertRaises(runtime.ActionRejected):
            with runtime.screenshot_buffer_scope() as images:
                state = runtime.observation_state(self.observation); state.fingerprint
                raise runtime.ActionRejected("Fixture cancelled", "cancelled")
        self.assertEqual(images.states, {}); self.assertIsNone(state._snapshot)
        self.assertEqual(state._values, {})

    def test_reused_revision_with_changed_controls_or_windows_cannot_reuse_a_decision(self):
        for mutate in [lambda o: o["elements"][0]["frame"].update(x=11),
                       lambda o: o["elements"][0].update(enabled=False),
                       lambda o: o["applications"][0]["windows"][0].update(title="Other")]:
            with self.subTest(mutate=mutate), runtime.screenshot_buffer_scope():
                original = deepcopy(self.observation)
                fixture = ACPFixture(['{"status":"done"}', '{"status":"done"}'])
                self.route(fixture); before = fixture.client._decision_fingerprint[1]
                mutate(self.observation); self.route(fixture)
                self.assertNotEqual(fixture.client._decision_fingerprint[1], before)
                self.assertEqual(fixture.client.prompt_calls, 2)
                self.observation = original

    def test_diagnostic_expansion_counters_do_not_invalidate_task_evidence(self):
        self.observation["observation_completeness"] = {"state": "complete", "local_expansion": {"attempts": 1}}
        with runtime.screenshot_buffer_scope():
            state = runtime.observation_state(self.observation); before = state.fingerprint
            self.observation["observation_completeness"]["local_expansion"]["attempts"] += 1
            self.assertEqual(runtime.observation_state(self.observation).fingerprint, before)
            self.assertEqual(state.revision, 1)
            self.observation["observation_completeness"]["state"] = "incomplete"
            self.assertNotEqual(runtime.observation_state(self.observation).fingerprint, before)

    def test_new_capture_revision_retains_incidental_churn_rules_and_uses_fresh_identity(self):
        with runtime.screenshot_buffer_scope():
            first = runtime.observation_state(self.observation); before = first.fingerprint
            signature = runtime.observation_progress_signature(self.observation)
            fresh = deepcopy(self.observation); fresh["observation_revision"] = "second"
            fresh["elements"][0]["id"] = "second:button"
            second = runtime.observation_state(fresh)
            self.assertIsNot(first, second); self.assertNotEqual(second.fingerprint, before)
            self.assertEqual(runtime.observation_progress_signature(fresh), signature)

    def test_discard_and_scope_teardown_release_state_even_without_an_image_file(self):
        with runtime.screenshot_buffer_scope() as images:
            state = runtime.observation_state(self.observation); state.fingerprint
            runtime.observation_progress_signature(self.observation)
            self.path.unlink(); runtime.discard_observation_image(self.observation)
            self.assertEqual(images.states, {}); self.assertIsNone(state._snapshot)
            self.assertEqual(state._values, {})
            state = runtime.observation_state(self.observation); state.fingerprint
        self.assertIsNone(state._snapshot); self.assertEqual(images.states, {})

    def test_old_discard_preserves_another_revision_even_before_its_pixels_are_read(self):
        with runtime.screenshot_buffer_scope() as images:
            first = runtime.observation_state(self.observation); first.fingerprint
            fresh = deepcopy(self.observation); fresh["observation_revision"] = "second"
            second = runtime.observation_state(fresh); before = second.fingerprint
            runtime.discard_observation_image(self.observation)
            self.assertIsNone(first._snapshot); self.assertTrue(self.path.exists())
            self.assertEqual(runtime.observation_state(fresh).fingerprint, before)
            self.assertEqual(len(images.states), 1)
            runtime.discard_observation_image(fresh)
            self.assertFalse(self.path.exists()); self.assertEqual(images.states, {})

    def test_task_scopes_and_cancelled_generations_cannot_share_state(self):
        with mock.patch.object(runtime, "_task_generation_id", "task-a"):
            with runtime.screenshot_buffer_scope():
                first = runtime.observation_state(self.observation); first.fingerprint
                with mock.patch.object(runtime, "_task_generation_id", "task-b"):
                    with self.assertRaises(runtime.ActionRejected): runtime.observation_state(self.observation)
            self.assertIsNone(first._snapshot)
            with runtime.screenshot_buffer_scope():
                second = runtime.observation_state(self.observation)
                self.assertIsNot(first, second)

    def test_purpose_instruction_and_evidence_changes_invalidate_routing_identity(self):
        ledger = evidence.TaskEvidenceLedger("fixture task")
        fixture = ACPFixture(['{"status":"blocked","reason":"Await proof"}'] * 3 + ['{"verified":false}'])
        with runtime.screenshot_buffer_scope():
            self.route(fixture, ledger=ledger); first = fixture.client._decision_fingerprint[1]
            ledger.add_requirements([{"source": "fixture task", "description": "Current screen",
                                      "check": {"type": "visual", "expected": "fixture task"}}])
            self.route(fixture, ledger=ledger); second = fixture.client._decision_fingerprint[1]
            self.route(fixture, instruction="changed task evidence", ledger=ledger)
            third = fixture.client._decision_fingerprint[1]
            self.route(fixture, purpose="verification", instruction="changed task evidence", ledger=ledger)
            self.assertEqual(len({first, second, third, fixture.client._decision_fingerprint[1]}), 4)
            self.assertEqual(fixture.client.prompt_calls, 4)

    def test_repair_budget_and_mutation_cache_rules_remain_unchanged(self):
        fixture = ACPFixture(['{', '{"status":"done"}'])
        with runtime.screenshot_buffer_scope(), mock.patch.object(runtime, "bridge_call") as bridge:
            self.route(fixture); self.route(fixture)
            self.assertEqual((fixture.client.prompt_calls, self.router.metrics["repairs"]), (2, 1))
            action = '{"status":"act","action":{"type":"press","element_id":"first:button","pid":41}}'
            mutation = ACPFixture([action, action])
            self.route(mutation); self.route(mutation)
            self.assertEqual(mutation.client.prompt_calls, 2)
            self.assertEqual(mutation.client.decision_cache, {})
            bridge.assert_not_called()


if __name__ == "__main__":
    unittest.main()
