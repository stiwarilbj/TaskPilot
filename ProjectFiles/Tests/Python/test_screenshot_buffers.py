"""Screenshot reuse through real ACP serialization with offline transport."""
import base64
import hashlib
import io
import json
from copy import deepcopy
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "AgentRuntime"))
import openclaw_runtime as runtime
from evidence_fixtures import proof_response, with_requirements
from test_verification_sessions import ACPFixture
from action_receipts import RuntimeInbox
from test_task_evidence import requirement, write, written


class ScreenshotBufferTests(unittest.TestCase):
    def pressure(self, generation="task-pressure", level="warning"):
        return json.dumps({"kind": "memory_pressure", "task_generation_id": generation, "level": level}) + "\n"

    def test_pressure_evicts_representations_without_rereading_or_losing_evidence(self):
        with mock.patch.object(runtime, "_task_generation_id", "task-pressure"), runtime.screenshot_buffer_scope() as images:
            image = images.image(self.path, "first")
            original, digest = image.base64, image.digest
            state = images.observation(self.observation)
            fingerprint, revision = state.fingerprint, state.revision
            indexes = images.indexes(self.observation)
            task = 'Write /fixture/a.txt with A.'
            ledger = runtime.TaskEvidenceLedger(task, "task-pressure")
            ledger.add_requirements([requirement(task, path='/fixture/a.txt', content='A')])
            ledger.record_action(write(), written(write()))
            ledger_fingerprint = ledger.fingerprint()
            evidence, requirements = deepcopy(ledger.evidence), deepcopy(ledger.requirements)
            self.path.write_bytes(b"changed file after acceptance")
            self.assertTrue(runtime.handle_runtime_control(self.pressure()))
            self.assertIsNone(image._base64)
            self.assertEqual(image._data, self.pixels)
            self.assertEqual(state._values, {})
            self.assertEqual((image.digest, state.revision, state.fingerprint), (digest, revision, fingerprint))
            self.assertIsNot(images.indexes(self.observation), indexes)
            self.assertEqual(image.base64, original)
            self.assertEqual(self.reads, [self.path])
            self.assertEqual(self.encode.call_count, 2)
            self.assertEqual((ledger.evidence, ledger.requirements, ledger.fingerprint()),
                             (evidence, requirements, ledger_fingerprint))
            self.assertTrue(self.path.exists())

    def test_pressure_controls_do_not_enter_action_or_secure_input_reply_waits(self):
        with mock.patch.object(runtime, "_task_generation_id", "task-pressure"), runtime.screenshot_buffer_scope() as images:
            image = images.image(self.path, "first"); image.base64
            bridge_reply = '{"kind":"bridge_response","request_id":"fixture","ok":true}\n'
            secure_reply = '{"kind":"user_input_response","request_id":"fixture","value":"fixture"}\n'
            stream = io.StringIO(self.pressure() + bridge_reply + self.pressure(level="critical") + secure_reply)
            inbox = RuntimeInbox(stream, control_handler=runtime.handle_runtime_control)
            bridge = inbox.register('bridge_response', 'fixture', None)
            secure = inbox.register('user_input_response', 'fixture', None)
            self.assertEqual(inbox.read(1, key=bridge), bridge_reply)
            self.assertEqual(inbox.read(1, key=secure), secure_reply)
            self.assertIsNone(image._base64)
            self.assertEqual(image._data, self.pixels)

    def test_invalid_and_cross_task_controls_are_consumed_without_eviction(self):
        with mock.patch.object(runtime, "_task_generation_id", "task-pressure"), runtime.screenshot_buffer_scope() as images:
            image = images.image(self.path, "first"); original = image.base64
            for generation, level in [("old-task", "warning"), (None, "critical"), (True, "warning"),
                                      ("task-pressure", "normal"), ("task-pressure", "invalid")]:
                self.assertTrue(runtime.handle_runtime_control(self.pressure(generation, level)))
                self.assertIs(image._base64, original)
            self.assertFalse(runtime.handle_runtime_control('{"kind":"bridge_response"}'))
            self.assertFalse(runtime.handle_runtime_control('malformed'))
        self.assertIsNone(runtime._pressure_images)
        self.assertTrue(runtime.handle_runtime_control(self.pressure()))
        self.assertIsNone(image._data)

    def test_eviction_keeps_identical_valid_decision_reuse_and_adds_no_model_calls(self):
        fixture = ACPFixture(['{"status":"done"}'])
        with mock.patch.object(runtime, "_task_generation_id", "task-pressure"), runtime.screenshot_buffer_scope():
            self.route(fixture)
            runtime.handle_runtime_control(self.pressure(level="critical"))
            self.route(fixture)
            self.assertEqual(fixture.client.prompt_calls, 1)
            self.assertEqual(self.router.metrics["cache_hits"], 1)
            self.assertEqual((len(self.reads), self.encode.call_count), (1, 1))

    def test_eviction_waits_for_encoding_then_releases_only_its_cache_reference(self):
        with runtime.screenshot_buffer_scope() as images:
            image = images.image(self.path, "first")
            entered, release = threading.Event(), threading.Event()
            result, errors = [], []
            def read():
                try: result.append(image.base64)
                except BaseException as error: errors.append(error)
            # Patch a captured encoder, avoiding recursively calling the mock.
            real_encode = self.encode._mock_wraps
            def controlled(data):
                entered.set()
                if not release.wait(2): raise RuntimeError("Fixture was not released")
                return real_encode(data)
            with mock.patch.object(runtime.base64, "b64encode", side_effect=controlled):
                worker = threading.Thread(target=read)
                worker.start(); self.assertTrue(entered.wait(1))
                eviction = threading.Thread(target=images.evict_disposable)
                eviction.start(); release.set()
                worker.join(2); eviction.join(2)
            self.assertFalse(worker.is_alive()); self.assertFalse(eviction.is_alive())
            self.assertEqual(errors, [])
            self.assertEqual(result, [real_encode(self.pixels).decode("ascii")])
            self.assertIsNone(image._base64)
            self.assertEqual(image._data, self.pixels)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "screen.png"
        self.pixels = b"fictional screenshot pixels"
        self.path.write_bytes(self.pixels)
        self.observation = {"screenshot_path": str(self.path), "observation_revision": "first",
                            "applications": [], "elements": []}
        self.reads = []
        read = Path.read_bytes
        def read_image(path):
            self.reads.append(path)
            return read(path)
        patch = mock.patch.object(Path, "read_bytes", autospec=True, side_effect=read_image)
        patch.start(); self.addCleanup(patch.stop)
        patch = mock.patch.object(runtime.base64, "b64encode", wraps=base64.b64encode)
        self.encode = patch.start(); self.addCleanup(patch.stop)
        for name, value in [("emit", None), ("session_transcript_cursor", None)]:
            patch = mock.patch.object(runtime, name, return_value=value)
            patch.start(); self.addCleanup(patch.stop)
        self.router = runtime.AdaptiveModelRouter(lambda *a, **k: None, sleep=lambda _: None)

    def route(self, fixture, purpose="planning", instruction="fixture task", observation=None):
        return runtime.routed_json_prompt(self.router, fixture.client, instruction, self.path,
                                          purpose=purpose, observation=observation or self.observation)

    def assert_images(self, fixture, pixels=None):
        expected = base64.b64encode(pixels or self.pixels).decode("ascii")
        for _, _, _, blocks in fixture.generations:
            self.assertEqual(blocks[1], {"type": "image", "data": expected, "mimeType": "image/png"})

    def test_digest_planning_and_encoding_read_once_and_cache_valid_decision(self):
        fixture = ACPFixture(['{"status":"done"}'])
        with runtime.screenshot_buffer_scope():
            for _ in range(3):
                self.assertEqual(runtime.observation_image_digest(self.observation),
                                 hashlib.blake2b(self.pixels, digest_size=16).hexdigest())
            self.route(fixture)
            self.route(fixture)
            self.assertEqual(self.reads, [self.path])
            self.assertEqual(self.encode.call_count, 1)
            self.assertEqual(fixture.client.prompt_calls, 1)
            self.assertEqual(self.router.metrics["cache_hits"], 1)
            self.assert_images(fixture)

    def test_wrapped_healthy_output_still_uses_one_read_and_one_request(self):
        fixture = ACPFixture(['```json\n{"status":"done"}\n```'])
        with runtime.screenshot_buffer_scope():
            self.route(fixture)
            self.assertEqual((len(self.reads), self.encode.call_count, fixture.client.prompt_calls), (1, 1, 1))
            self.assertEqual(self.router.metrics["repairs"], 0)

    def test_repair_and_model_fallback_reuse_original_encoding(self):
        for responses in [['{', '{"status":"done"}'], ['{', '{', '{"status":"done"}']]:
            with self.subTest(responses=responses), runtime.screenshot_buffer_scope():
                self.reads.clear(); self.encode.reset_mock()
                fixture = ACPFixture(responses)
                # Simulate a changed file after the accepted bytes were read.
                runtime.observation_image_digest(self.observation)
                self.path.write_bytes(b"later file contents")
                with mock.patch.object(runtime, "bridge_call") as bridge:
                    self.route(fixture, instruction="repair fixture")
                bridge.assert_not_called()
                self.assertEqual(self.reads, [self.path])
                self.assertEqual(self.encode.call_count, 1)
                self.assertEqual(fixture.client.prompt_calls, len(responses))
                self.assert_images(fixture)
                self.path.write_bytes(self.pixels)

    def test_independent_verification_session_reuses_same_observation_bytes(self):
        fixture = ACPFixture(['{"status":"done"}', '{"verified":false}'])
        with runtime.screenshot_buffer_scope():
            self.route(fixture)
            self.route(fixture, "verification", "independent verifier")
            self.assertNotEqual(fixture.generations[0][0], fixture.generations[1][0])
            self.assertEqual((len(self.reads), self.encode.call_count, fixture.client.prompt_calls), (1, 1, 2))
            self.assert_images(fixture)

    def test_reconnect_preserves_the_pending_image_without_rereading(self):
        fixture = ACPFixture([RuntimeError("OpenClaw ACP exited"), '{"verified":false}'])
        fixture.client.gateway_configuration = mock.Mock(return_value={"ok": True, "status": "no-active-run"})
        with runtime.screenshot_buffer_scope(), \
             mock.patch.object(runtime.ACPClient, "__init__", side_effect=fixture.initialize):
            self.route(fixture, "verification")
            self.assertEqual((len(self.reads), self.encode.call_count, fixture.client.prompt_calls), (1, 1, 2))
            self.assertEqual(fixture.client.reconnects, 1)
            self.assert_images(fixture)

    def test_settling_digests_do_not_encode_images(self):
        with runtime.screenshot_buffer_scope() as images:
            runtime.observation_image_digest(self.observation)
            runtime.observation_image_digest(self.observation)
            self.assertEqual(self.reads, [self.path])
            self.encode.assert_not_called()
            image = images.image(self.path, "first")
            self.assertIsNone(image._base64)
            runtime.discard_observation_image(self.observation)
            self.assertFalse(self.path.exists())
            self.assertIsNone(image._data)
            self.assertEqual(images.images, {})

    def test_discard_clears_bytes_and_encoding_even_if_file_already_removed(self):
        with runtime.screenshot_buffer_scope() as images:
            image = images.image(self.path, "first")
            image.base64
            self.path.unlink()
            runtime.discard_observation_image(self.observation)
            self.assertIsNone(image._data)
            self.assertIsNone(image._base64)
            with self.assertRaisesRegex(RuntimeError, "discarded"):
                image.base64
            self.assertEqual(images.images, {})

    def test_new_revision_at_same_path_reads_fresh_pixels_and_old_discard_is_safe(self):
        with runtime.screenshot_buffer_scope() as images:
            first = images.image(self.path, "first")
            first.base64
            self.path.write_bytes(b"new observation")
            second_observation = dict(self.observation, observation_revision="second")
            second = images.image(self.path, "second")
            self.assertNotEqual(first.digest, second.digest)
            self.assertEqual(second.base64, base64.b64encode(b"new observation").decode("ascii"))
            runtime.discard_observation_image(self.observation)
            self.assertTrue(self.path.is_file())
            self.assertIsNone(first._data)
            self.assertIs(images.image(self.path), second)
            runtime.discard_observation_image(second_observation)
            self.assertFalse(self.path.exists())
            self.assertEqual(self.reads, [self.path, self.path])

    def test_new_task_scope_cannot_reuse_previous_task_pixels(self):
        with mock.patch.object(runtime, "_task_generation_id", "one"), runtime.screenshot_buffer_scope() as first:
            old = first.image(self.path, "same-revision")
            old.base64
        self.assertIsNone(old._data)
        self.assertIsNone(old._base64)
        self.path.write_bytes(b"another task")
        with mock.patch.object(runtime, "_task_generation_id", "two"), runtime.screenshot_buffer_scope() as second:
            new = second.image(self.path, "same-revision")
            self.assertNotEqual(new.digest, hashlib.blake2b(self.pixels, digest_size=16).hexdigest())
        self.assertEqual(self.reads, [self.path, self.path])
        self.assertIsNone(runtime._screenshot_buffers.get())

    def test_generation_mismatch_stops_before_image_read(self):
        with mock.patch.object(runtime, "_task_generation_id", "one"), runtime.screenshot_buffer_scope():
            with mock.patch.object(runtime, "_task_generation_id", "two"):
                with self.assertRaises(runtime.ActionRejected) as rejected:
                    runtime.screenshot_buffer(self.path)
                self.assertEqual(rejected.exception.code, "cancelled")
        self.assertEqual(self.reads, [])

    def test_stop_exception_clears_remaining_buffers(self):
        for error in [RuntimeError("fixture failure"), SystemExit(143), KeyboardInterrupt()]:
            with self.subTest(error=type(error)), self.assertRaises(type(error)):
                with runtime.screenshot_buffer_scope() as images:
                    image = images.image(self.path, "first")
                    image.base64
                    raise error
            self.assertIsNone(image._data)
            self.assertIsNone(image._base64)
            self.assertEqual(images.images, {})
            self.assertIsNone(runtime._screenshot_buffers.get())

    def test_read_failure_is_not_cached(self):
        with runtime.screenshot_buffer_scope() as images:
            self.path.unlink()
            with self.assertRaises(FileNotFoundError):
                images.image(self.path, "first")
            self.assertEqual(images.images, {})
            self.path.write_bytes(self.pixels)
            self.assertEqual(images.image(self.path, "first").digest,
                             hashlib.blake2b(self.pixels, digest_size=16).hexdigest())

    def test_readiness_probe_shares_one_buffer_with_its_format_repair(self):
        fixture = ACPFixture(['{', '{"status":"done","check":"TASKPILOT_READY"}'])
        state = mock.Mock()
        state.verified_model.return_value = None
        state.health.return_value = {}; state.credential_health.return_value = {}
        with mock.patch.object(runtime, "prepare_runtime", return_value=state), \
             mock.patch.object(runtime, "ACPClient", return_value=fixture.client):
            self.assertTrue(runtime.check_models("fixture", ""))
        self.assertEqual((len(self.reads), self.encode.call_count, fixture.client.prompt_calls), (1, 1, 2))
        self.assertIsNone(runtime._screenshot_buffers.get())

    def test_complete_task_reads_each_planning_and_verification_image_once(self):
        observed = []
        fixture = ACPFixture([lambda _: json.dumps(with_requirements({"status": "done"}, "Inspect the fixture")),
                              lambda _: json.dumps(proof_response(fixture.client.ledger))])
        def observe(method, _display, **_params):
            self.assertEqual(method, "observe")
            path = Path(self.directory.name) / f"observation-{len(observed)}.png"
            path.write_bytes(self.pixels)
            observation = dict(self.observation, screenshot_path=str(path), observation_revision=str(len(observed)))
            observed.append(observation)
            return observation
        def instruction(task, observation, history, ledger):
            fixture.client.ledger = ledger
            return "fixture plan"
        with mock.patch.object(runtime, "find_openclaw", return_value="fixture"), \
             mock.patch.object(runtime, "prepare_runtime", return_value=mock.Mock()), \
             mock.patch.object(runtime, "ACPClient", return_value=fixture.client), \
             mock.patch.object(runtime, "bridge_call", side_effect=observe), \
             mock.patch.object(runtime, "desktop_instruction", side_effect=instruction):
            runtime.run_task("Inspect the fixture", 1, "fixture", "")
        self.assertEqual(self.reads, [Path(o["screenshot_path"]) for o in observed])
        self.assertEqual((len(observed), self.encode.call_count, fixture.client.prompt_calls), (2, 2, 2))
        self.assertTrue(all(not Path(o["screenshot_path"]).exists() for o in observed))
        self.assertIsNone(runtime._screenshot_buffers.get())


if __name__ == "__main__":
    unittest.main()
