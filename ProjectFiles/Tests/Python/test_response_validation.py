import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
from evidence_fixtures import VerificationSessions
import request_policy as policy
from response_validation import ResponseValidationError, extract_json_object, validate_response

OBSERVATION = {
    'revision': 'current', 'applications': [{'pid': 42}],
    'elements': [{'id': 'current:e1', 'pid': 42, 'role': 'AXTextField'}],
    'system_context': {'task_routes': [{'route_id': 'finder'}]},
}


class ValidationTests(unittest.TestCase):
    def validate(self, value, purpose='planning'):
        return validate_response(value, purpose, OBSERVATION)

    def test_one_object_with_safe_wrappers(self):
        for text in ['{"status":"done"}', '```json\n{"status":"done"}\n```',
                     'Here is the result:\n{"status":"done"}\nFinished.']:
            with self.subTest(text=text):
                self.assertEqual(extract_json_object(text), {'status': 'done'})

    def test_ambiguous_malformed_or_nonfinite_json_is_rejected(self):
        texts = ['{"status":"act","action":{"type":"wait"}',
                 '{"status":"done"} {"status":"act"}',
                 '[{"status":"done"}]', '{} []', '{} {', '{} }', '{} ]',
                 '{"status":"done","status":"blocked"}',
                 '{"action":{"type":"wait","type":"none"}}',
                 '{"x":NaN}', '{"x":Infinity}', '{"x":-Infinity}',
                 '{"x":1e999}', '{"status":"done",}', '{status:"done"}',
                 '"{\\"status\\":\\"done\\"}"']
        for text in texts:
            with self.subTest(text=text), self.assertRaises(ResponseValidationError):
                extract_json_object(text)

    def test_required_fields_and_supplied_metadata(self):
        cases = [({'status': 'act'}, 'action is required'),
                 ({'status': []}, 'status must be'),
                 ({'status': 'done', 'summary': 1}, 'summary must be a string'),
                 ({'status': 'done', 'selected_capability': {}}, 'selected_capability must be'),
                 ({'status': 'done', 'output_kind': []}, 'output_kind must be'),
                 ({'status': 'done', 'finish_after_action': 'true'}, 'finish_after_action must be'),
                 ({'status': 'done', 'remaining_requirements': [1]}, 'remaining_requirements must be'),
                 ({'status': 'done', 'action': {'type': 'type_text', 'text': 5}}, 'action.text must be a string')]
        for value, error in cases:
            with self.subTest(value=value), self.assertRaisesRegex(ResponseValidationError, error):
                self.validate(value)
        self.assertEqual(self.validate({'status': 'done'}), {'status': 'done'})

    def test_native_action_contract(self):
        cases = [({'type': 'write_file', 'path': '/tmp/a'}, 'action.content is required'),
                 ({'type': 'read_file'}, 'action.path is required'),
                 ({'type': 'run_command'}, 'action.command is required'),
                 ({'type': 'run_command', 'command': 'pwd', 'timeout_seconds': 901}, 'action.timeout_seconds'),
                 ({'type': 'run_command', 'command': 'pwd', 'working_directory': 'relative'}, 'action.working_directory'),
                 ({'type': 'wait', 'seconds': True}, 'action.seconds must be a number'),
                 ({'type': 'wait', 'seconds': '1'}, 'action.seconds must be a number'),
                 ({'type': 'wait', 'seconds': 16}, 'action.seconds'),
                 ({'type': 'click', 'x': 1}, 'coordinates require both'),
                 ({'type': 'click', 'x': 1, 'y': 2}, 'action.pid'),
                 ({'type': 'scroll', 'delta_y': 1, 'x': 1, 'y': 2}, 'action.pid'),
                 ({'type': 'click', 'x': True, 'y': 2, 'pid': 42}, 'action.x must be a number'),
                 ({'type': 'click', 'x': float('inf'), 'y': 2, 'pid': 42}, 'action.x'),
                 ({'type': 'scroll', 'delta_y': 1.5}, 'action.delta_y must be an integer'),
                 ({'type': 'scroll', 'delta_y': 2001}, 'action.delta_y'),
                 ({'type': 'scroll'}, 'nonzero delta'),
                 ({'type': 'key', 'key': 'unknown'}, 'action.key'),
                 ({'type': 'key', 'key': 'return', 'pid': True}, 'action.pid must be an integer'),
                 ({'type': 'key', 'key': 'return', 'pid': '42'}, 'action.pid must be an integer'),
                 ({'type': 'key', 'key': 'return', 'pid': 10**400}, 'action.pid'),
                 ({'type': 'key', 'key': 'return', 'modifiers': ['unknown']}, 'action.modifiers'),
                 ({'type': 'launch_app'}, 'launch_app requires'),
                 ({'type': 'read_file', 'path': '/tmp/a', 'max_bytes': True}, 'action.max_bytes'),
                 ({'type': 'write_file', 'path': '/tmp/a', 'content': '', 'mode': 'bad'}, 'action.mode'),
                 ({'type': 'write_file', 'path': '/tmp/a', 'content': '', 'encoding': 'bad'}, 'action.encoding'),
                 ({'type': 'write_file', 'path': '/tmp/a', 'content': '???', 'encoding': 'base64'}, 'action.content'),
                 ({'type': 'write_file', 'path': '/tmp/a', 'content': '', 'create_parents': 1}, 'action.create_parents')]
        for action, error in cases:
            with self.subTest(action=action), self.assertRaisesRegex(ResponseValidationError, error):
                self.validate({'status': 'act', 'action': action})

    def test_current_targets_and_element_precedence(self):
        for action, error in [({'type': 'press', 'element_id': 'stale:e1'}, 'action.element_id'),
                              ({'type': 'press', 'element_id': 'current:e1', 'pid': 43}, 'action.pid'),
                              ({'type': 'click', 'x': 1, 'y': 2, 'pid': 43}, 'action.pid'),
                              ({'type': 'open_route', 'route_id': 'unknown'}, 'action.route_id')]:
            with self.subTest(action=action), self.assertRaisesRegex(ResponseValidationError, error):
                self.validate({'status': 'act', 'action': action})
        decision = self.validate({'status': 'blocked', 'action': {
            'type': 'click', 'element_id': 'current:e1', 'x': 999, 'y': 999, 'pid': 42}})
        self.assertEqual(decision['action'], {'type': 'press', 'element_id': 'current:e1', 'pid': 42})
        self.assertEqual(runtime.effective_decision_status(decision), 'act')

    def test_secure_input_requires_valid_target_and_types(self):
        valid = {'status': 'needs_user', 'user_input': {'kind': 'password'},
                 'action': {'type': 'focus', 'element_id': 'current:e1', 'pid': 42}}
        self.assertEqual(self.validate(valid), valid)
        for change, error in [({'user_input': {'kind': []}}, 'user_input.kind'),
                              ({'user_input': {'kind': 'password', 'title': 1}}, 'user_input.title'),
                              ({'action': {'type': 'focus', 'element_id': 'current:e1'}}, 'action.pid'),
                              ({'action': {'type': 'none', 'pid': 42}}, 'action.element_id'),
                              ({'user_input': None}, 'user_input must be an object')]:
            with self.subTest(change=change), self.assertRaisesRegex(ResponseValidationError, error):
                self.validate(dict(valid, **change))

    def test_secure_input_rejects_buttons_and_disabled_fields(self):
        decision = {'status': 'needs_user', 'user_input': {'kind': 'secret'},
                    'action': {'type': 'focus', 'element_id': 'current:e1', 'pid': 42}}
        for element in [{'id': 'current:e1', 'pid': 42, 'role': 'AXButton'},
                        {'id': 'current:e1', 'pid': 42, 'role': 'AXTextField', 'enabled': False}]:
            with self.subTest(element=element), self.assertRaisesRegex(ResponseValidationError, 'action.element_id'):
                validate_response(decision, 'planning', dict(OBSERVATION, elements=[element]))

    def test_verification_and_readiness_contracts(self):
        for value in ['false', 1, None, [], {}]:
            with self.subTest(value=value), self.assertRaisesRegex(ResponseValidationError, 'verified must be a boolean'):
                self.validate({'verified': value}, 'verification')
        self.assertFalse(self.validate({'verified': False}, 'verification')['verified'])
        with self.assertRaisesRegex(ResponseValidationError, 'check must equal'):
            self.validate({'status': 'done'}, 'readiness')
        self.assertEqual(self.validate({'status': 'done', 'check': 'TASKPILOT_READY'}, 'readiness')['status'], 'done')


class FakeClient(VerificationSessions):
    def __init__(self, responses):
        self.responses = iter(responses)
        self.calls = []
        self.selected_model = None
        self.model_switches = 0
        self.prompt_calls = 0
        self.reconnects = 0

    def select_model(self, model):
        if self.selected_model != model:
            self.model_switches += 1
        self.selected_model = model

    def prompt(self, instruction, image):
        self.calls.append((self.selected_model, instruction, image))
        self.prompt_calls += 1
        value = next(self.responses)
        if isinstance(value, Exception):
            raise value
        return value

    def close(self): pass


class RepairTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.image = Path(self.directory.name) / 'image.png'
        self.image.write_bytes(b'unchanged screenshot')
        self.router = policy.AdaptiveModelRouter(lambda *a, **k: None, sleep=lambda _: None)
        patcher = mock.patch.object(runtime, 'emit'); patcher.start(); self.addCleanup(patcher.stop)

    def run_response(self, responses, purpose='planning', instruction='Original task and applicable response contract'):
        self.client = FakeClient(responses)
        return runtime.routed_json_prompt(self.router, self.client, instruction, self.image,
                                          purpose, OBSERVATION)

    def test_healthy_and_wrapped_cost_one_request(self):
        for text in ['{"status":"done"}', '```json\n{"status":"done"}\n```']:
            self.run_response([text])
            self.assertEqual(self.client.prompt_calls, 1)
            self.assertEqual(self.router.metrics['repairs'], 0)

    def test_command_argument_error_uses_shared_same_model_repair(self):
        invalid = '{"status":"act","action":{"type":"run_command","argv":["touch",12]}}'
        valid = '{"status":"act","action":{"type":"run_command","argv":["touch","/tmp/marker"],"checks":[{"type":"file_exists","path":"/tmp/marker"}]}}'
        with mock.patch.object(runtime, 'bridge_call') as bridge:
            response = self.run_response([invalid, valid])
        self.assertEqual(response['action']['argv'], ['touch', '/tmp/marker'])
        self.assertEqual(self.client.prompt_calls, 2)
        self.assertEqual(self.router.metrics['planning'], 2)
        self.assertEqual(self.router.metrics['repairs'], 1)
        self.assertEqual(self.client.calls[0][0], self.client.calls[1][0])
        self.assertIn('action.argv[1] must be a string', self.client.calls[1][1])
        bridge.assert_not_called()

    def test_same_model_repair_reuses_evidence_without_actions(self):
        invalid = '{"status":"act","action":{"type":"type_text","text":12,"pid":42}}'
        with mock.patch.object(runtime, 'bridge_call') as bridge:
            result = self.run_response([invalid, '{"status":"act","action":{"type":"type_text","text":"hello","pid":42}}'])
            bridge.assert_not_called()
            # Execution is solely the caller's responsibility after validation.
            runtime.bridge_call('act', 1, action=result['action'])
            bridge.assert_called_once()
        self.assertEqual([c[0] for c in self.client.calls], [policy.PRIMARY_MODELS[0]] * 2)
        repair = self.client.calls[1][1]
        self.assertEqual(json.loads(repair.split('EXACT VALIDATION ERROR:\n', 1)[1].splitlines()[0]), 'action.text must be a string')
        self.assertIn('untrusted data', repair)
        self.assertIn(json.dumps(invalid), repair)
        contract = json.loads(repair.split('APPLICABLE PHASE CONTRACT (JSON-quoted instructions and unchanged evidence):\n', 1)[1])
        self.assertEqual(contract, self.client.calls[0][1])
        self.assertTrue(all(c[2] == self.image for c in self.client.calls))
        self.assertEqual(self.router.active_model, policy.PRIMARY_MODELS[0])
        self.assertEqual(self.router.metrics['planning'], 2)
        self.assertEqual(self.router.metrics['repairs'], 1)

    def test_empty_terminal_output_receives_one_repair(self):
        self.run_response(['', '{"status":"done"}'])
        self.assertEqual(self.client.prompt_calls, 2)
        self.assertEqual(self.router.metrics['repairs'], 1)

    def test_invalid_fields_containing_provider_words_still_repair(self):
        self.run_response(['{"status":"act","action":{"type":"type_text","text":12},"reason":"quota"}',
                           '{"status":"blocked","reason":"Insufficient target evidence"}'])
        self.assertEqual(self.client.prompt_calls, 2)
        self.assertEqual(self.router.metrics['repairs'], 1)

    def test_cancellation_and_repair_provider_rejection_stop(self):
        for responses in [[RuntimeError('OpenClaw cancelled the TaskPilot turn')],
                          ['{', RuntimeError('HTTP 401 invalid API key')]]:
            self.router = policy.AdaptiveModelRouter(lambda *a, **k: None)
            with self.subTest(responses=responses), self.assertRaises(RuntimeError):
                self.run_response(responses)
            self.assertEqual(self.client.prompt_calls, len(responses))
            self.assertEqual(self.router.metrics['repairs'], len(responses) - 1)

    def test_readiness_exhaustion_shares_one_repair(self):
        state = policy.RuntimeState('key', 'version', Path(self.directory.name))
        client = FakeClient(['{'] * 7)
        with mock.patch.object(runtime, 'prepare_runtime', return_value=state), mock.patch.object(runtime, 'ACPClient', return_value=client):
            self.assertFalse(runtime.check_models('openclaw', 'key'))
        self.assertEqual(client.prompt_calls, 7)
        self.assertIsNone(state.verified_model())
        self.assertNotIn('INVALID RESPONSE', state.path.read_text())

    def test_failed_repair_falls_back_without_another_repair(self):
        self.run_response(['{', '{', '{"status":"done"}'])
        self.assertEqual([c[0] for c in self.client.calls], [policy.PRIMARY_MODELS[0]] * 2 + [policy.PRIMARY_MODELS[1]])
        self.assertEqual(self.router.metrics['planning'], 3)
        self.assertEqual(self.router.metrics['repairs'], 1)
        self.assertEqual(self.router.metrics['retries'], 0)

    def test_exhaustion_has_exactly_one_repair_and_no_lite_repeat(self):
        with mock.patch.object(runtime, 'bridge_call') as bridge:
            with self.assertRaisesRegex(RuntimeError, 'No eligible Gemini model'):
                self.run_response(['{'] * (len(policy.ALL_MODELS) + 1))
            bridge.assert_not_called()
        self.assertEqual([c[0] for c in self.client.calls], [policy.PRIMARY_MODELS[0]] + list(policy.ALL_MODELS))
        self.assertEqual(self.router.metrics['planning'], 7)
        self.assertEqual(self.router.metrics['repairs'], 1)
        self.assertEqual(self.router.metrics['retries'], 0)

    def test_provider_errors_bypass_format_repair(self):
        for response in [RuntimeError('HTTP 401 invalid API key'), 'HTTP 401 invalid API key']:
            with self.subTest(response=response), self.assertRaisesRegex(RuntimeError, 'invalid API key'):
                self.run_response([response])
            self.assertEqual(self.client.prompt_calls, 1)
            self.assertEqual(self.router.metrics['repairs'], 0)
        self.run_response([RuntimeError('HTTP 503 Retry-After: 30'), '{"status":"done"}'])
        self.assertEqual(self.client.prompt_calls, 2)
        self.assertEqual(self.router.metrics['repairs'], 0)

    def test_provider_output_preserves_cooldown_without_persisting_raw_text(self):
        state = policy.RuntimeState('key', 'version', Path(self.directory.name))
        self.router = policy.AdaptiveModelRouter(lambda *a, **k: None, state)
        self.run_response(['HTTP 503 Retry-After: 45 private-provider-text', '{"status":"done"}'])
        health = state.health(policy.PRIMARY_MODELS[0])
        self.assertEqual(health['state'], 'temporary')
        self.assertGreater(health['retry_at'], policy.time.time() + 40)
        self.assertNotIn('private-provider-text', state.path.read_text())
        self.assertEqual(self.router.metrics['repairs'], 0)

    def test_acp_empty_terminal_response_reaches_validator(self):
        client = runtime.ACPClient.__new__(runtime.ACPClient)
        client._run_prompt = mock.Mock(return_value=({'stopReason': 'end_turn'}, ''))
        self.assertEqual(client.prompt('reason', self.image), '')
        self.assertEqual(client.prompt_calls, 1)

    def test_verification_uses_shared_repair_and_totals(self):
        result = self.run_response(['{"verified":"false"}', '{"verified":false}'], 'verification')
        self.assertIs(result['verified'], False)
        self.assertEqual(self.router.metrics['verification'], 2)
        self.assertEqual(self.router.metrics['planning'], 0)
        self.assertEqual(self.router.metrics['repairs'], 1)
        self.assertIn('verified must be a boolean', self.client.calls[1][1])

    def test_readiness_repair_and_stop_after_success(self):
        state = policy.RuntimeState('key', 'version', Path(self.directory.name))
        client = FakeClient(['{"status":"done"}', '{"status":"done","check":"TASKPILOT_READY"}'])
        with mock.patch.object(runtime, 'prepare_runtime', return_value=state), mock.patch.object(runtime, 'ACPClient', return_value=client):
            self.assertTrue(runtime.check_models('openclaw', 'key'))
        self.assertEqual(client.prompt_calls, 2)
        self.assertEqual(client.model_switches, 1)
        runtime.emit.assert_any_call('model_checks', checks=mock.ANY, cached=False, prompt_calls=2, repairs=1)

    def test_cache_identity_includes_purpose_version_and_observation(self):
        client = FakeClient(['{"status":"done"}', '{"verified":true}', '{"verified":true}', '{"verified":true}'])
        for purpose, observation in [('planning', OBSERVATION), ('verification', OBSERVATION),
                                     ('verification', dict(OBSERVATION, revision='new'))]:
            runtime.routed_json_prompt(self.router, client, 'same', self.image, purpose, observation)
        self.assertEqual(client.prompt_calls, 3)
        with mock.patch.object(runtime, 'VALIDATION_VERSION', runtime.VALIDATION_VERSION + 1):
            runtime.routed_json_prompt(self.router, client, 'same', self.image, 'verification', dict(OBSERVATION, revision='new'))
        self.assertEqual(client.prompt_calls, 4)

    def test_blocked_recovery_mutations_never_cache(self):
        response = '{"status":"blocked","action":{"type":"press","element_id":"current:e1"}}'
        client = FakeClient([response, response])
        for _ in range(2):
            runtime.routed_json_prompt(self.router, client, 'same', self.image, observation=OBSERVATION)
        self.assertEqual(client.prompt_calls, 2)
        self.assertEqual(client.decision_cache, {})


if __name__ == '__main__':
    unittest.main()
