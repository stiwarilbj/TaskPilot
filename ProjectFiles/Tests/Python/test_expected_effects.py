import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
from evidence_fixtures import VerificationSessions, native_result, native_batch
from coordinate_fixtures import fixture_coordinates
from expected_effects import ExpectedEffect, validate_expectation
from response_validation import validate_response, ResponseValidationError
from task_evidence import TaskEvidenceLedger
from action_receipts import BridgeReplyLost
from action_contract_generated import NativeProtocolError


def digest(text): return hashlib.sha256(text.encode()).hexdigest()


def observation(value='', revision='before', **changes):
    target = {'id': revision + ':field', 'pid': 42, 'role': 'AXTextField', 'title': 'Body', 'window_title': 'Draft',
              'native_identity': 'field', 'value': value, 'value_complete': True, **changes}
    return {'observation_revision': revision, 'applications': [{'pid': 42, 'name': 'Fixture'}], 'elements': [target]}


def checked(spec, verified=True, **changes):
    actual = {'type': spec['type'], 'path': spec['path'], 'verified': verified, **changes}
    if spec['type'] == 'file_contents': actual.setdefault('content_sha256', digest(spec['content']))
    return native_batch([spec], [actual])


class ExpectedEffectTests(unittest.TestCase):
    def setUp(self):
        self.before = observation('old')
        self.field = {'type': 'field_value', 'element_id': 'before:field', 'value': 'wanted'}
        self.file = {'type': 'file_contents', 'path': '/fixture/note', 'content': 'wanted'}
        self.dialog = {'type': 'dialog_appeared', 'pid': 42, 'title': 'Save Draft'}

    def test_checks_validate_types_targets_and_generated_file_bounds(self):
        valid = [self.field, self.file, self.dialog, {'type': 'file_exists', 'path': '/fixture/note'}, 'Save completes']
        for spec in valid: self.assertEqual(validate_expectation(spec, self.before), spec)
        invalid = [({**self.field, 'value': 1}, 'expected_result.value must be a string'),
                   ({**self.field, 'element_id': 'old:field'}, 'expected_result.element_id must reference'),
                   ({**self.field, 'pid': 43}, 'expected_result.pid must match'),
                   ({**self.dialog, 'pid': True}, 'expected_result.pid must be an integer'),
                   ({**self.dialog, 'pid': '42'}, 'expected_result.pid must be an integer'),
                   ({**self.dialog, 'pid': 43}, 'expected_result.pid must reference'),
                   ({**self.dialog, 'title': []}, 'expected_result.title must be a string'),
                   ({**self.file, 'path': 'relative'}, 'expected_result.path must be an absolute'),
                   ({**self.file, 'content': '!', 'encoding': 'base64'}, 'expected_result.content must be valid base64'),
                   ({**self.file, 'content': 'x' * (2097152 + 1)}, 'expected_result.content must contain at most'),
                   ({**self.file, 'command': 'untrusted'}, 'expected_result contains unsupported'),
                   ({'type': 'field_value', 'element_id': 'before:field'}, 'expected_result.value is required')]
        for spec, error in invalid:
            with self.subTest(error=error), self.assertRaisesRegex(ResponseValidationError, error):
                validate_response({'status': 'act', 'action': {'type': 'focus', 'element_id': 'before:field'},
                                   'expected_result': spec}, 'planning', self.before)

    def test_secure_values_cannot_be_expected_or_read_back(self):
        for changes in [{'role': 'AXSecureTextField'}, {'subrole': 'AXSecureTextField'}]:
            with self.assertRaisesRegex(ResponseValidationError, 'nonsecure observed text field'):
                validate_response({'status': 'act', 'action': {'type': 'focus', 'element_id': 'before:field'},
                                   'expected_result': self.field}, 'planning', observation(**changes))

    def test_field_requires_complete_value_at_bound_target_not_another_ready_field(self):
        effect = ExpectedEffect(self.field, self.before)
        for after in [observation('other', 'after'), observation('wanted', 'after', value_complete=False),
                      observation('wanted', 'after', native_identity='another-field'),
                      observation('wanted', 'after', title='Other field'), observation('wanted', 'after', pid=43)]:
            self.assertEqual(effect.observe(after)['outcome'], 'unconfirmed')
        result = effect.observe(observation('wanted', 'after'))
        self.assertEqual(result['outcome'], 'verified')
        self.assertEqual(result['element_id'], 'after:field')

    def test_missing_empty_value_is_verified_only_when_value_is_complete(self):
        spec = {**self.field, 'value': ''}; after = observation('', 'after'); after['elements'][0].pop('value')
        self.assertEqual(ExpectedEffect(spec, self.before).observe(after)['outcome'], 'verified')
        after['elements'][0]['value_complete'] = False
        self.assertEqual(ExpectedEffect(spec, self.before).observe(after)['outcome'], 'unconfirmed')

    def test_ambiguous_fields_are_not_picked_by_enumeration_order(self):
        before = observation('old'); before['elements'][0].pop('native_identity')
        effect = ExpectedEffect(self.field, before); after = observation('wanted', 'after')
        other = copy.deepcopy(after['elements'][0]); other['id'] = 'after:other'; other['native_identity'] = 'second'; after['elements'].append(other)
        self.assertEqual(effect.observe(after)['reason'], 'ambiguous_target')

    def test_foreign_generation_or_replaced_app_cannot_prove_effect(self):
        before = observation('old'); before['task_generation_id'] = 'owned'
        effect = ExpectedEffect(self.field, before); after = observation('wanted', 'after'); after['task_generation_id'] = 'foreign'
        self.assertEqual(effect.observe(after)['reason'], 'foreign_observation')
        after['task_generation_id'] = 'owned'; after['applications'][0]['name'] = 'Other App'
        self.assertEqual(effect.observe(after)['reason'], 'application_changed')

    def test_dialog_requires_exact_title_app_scope_and_new_presence(self):
        effect = ExpectedEffect(self.dialog, self.before)
        after = observation('old', 'after')
        target = {'id': 'after:dialog', 'pid': 42, 'role': 'AXSheet', 'title': 'Save Draft', 'native_identity': 'new-dialog'}
        for changes in [{'title': 'Unrelated dialog'}, {'pid': 43}, {'role': 'AXMenu'}]:
            after['elements'] = [{**target, **changes}]
            self.assertEqual(effect.observe(after)['outcome'], 'unconfirmed')
        after['elements'] = [target]
        self.assertEqual(effect.observe(after)['outcome'], 'verified')
        self.assertEqual(ExpectedEffect(self.dialog, after).observe(after)['reason'], 'dialog_already_present')
        after['elements'].append({**target, 'id': 'second', 'native_identity': 'second-dialog'})
        self.assertEqual(effect.observe(after)['reason'], 'ambiguous_target')

    def test_unknown_expectations_do_not_execute_code_or_read_files(self):
        for spec in ['this should work', {'type': 'script', 'command': 'never execute'}, {'type': 'stdout_equals', 'text': 'unknown'}]:
            effect = ExpectedEffect(spec, self.before)
            with mock.patch.object(runtime, 'bridge_call') as bridge:
                self.assertEqual(effect.observe(observation('wanted'))['reason'], 'unsupported_expectation')
                bridge.assert_not_called()

    def test_exact_native_file_proof_is_scoped_to_path_hash_and_check(self):
        effect = ExpectedEffect(self.file, self.before)
        self.assertEqual(effect.native_check(checked(self.file))['outcome'], 'verified')
        self.assertEqual(effect.native_check(checked(self.file, False))['outcome'], 'unconfirmed')
        for reply in [checked(self.file, path='/fixture/other'), checked(self.file, content_sha256=digest('wrong')),
                      native_batch([], checked(self.file)['checks']), native_batch([self.file], [])]:
            with self.assertRaises(NativeProtocolError): effect.native_check(reply)

    def test_native_write_and_read_reuse_avoid_additional_requests(self):
        action = {'type': 'write_file', 'path': self.file['path'], 'content': self.file['content']}
        result = native_result(action)
        with mock.patch.object(runtime, 'bridge_call') as bridge, mock.patch.object(runtime, 'routed_json_prompt') as model:
            observation_result, final = runtime.verify_expected_effect(1, self.before, action, result, self.file, None, {})
            self.assertIsNone(observation_result); self.assertEqual(final['expected_effect']['outcome'], 'verified')
            bridge.assert_not_called(); model.assert_not_called()
        read = {'type': 'read_file', 'path': self.file['path']}
        read_result = native_result(read, content='wanted', bytes_returned=6, content_sha256=digest('wanted'))
        self.assertEqual(ExpectedEffect(self.file, self.before).reuse_native(read, read_result)['outcome'], 'verified')
        self.assertIsNone(ExpectedEffect(self.file, self.before).reuse_native(read, {**read_result, 'truncated': True}))
        with self.assertRaises(NativeProtocolError):
            ExpectedEffect(self.file, self.before).reuse_native(action, {**result, 'path': '/fixture/wrong'})

    def test_exit_zero_and_unrelated_command_check_are_not_file_proof(self):
        effect = ExpectedEffect(self.file, self.before)
        action = {'type': 'run_command', 'argv': ['fixture']}
        self.assertIsNone(effect.reuse_native(action, native_result(action)))
        other = {**self.file, 'path': '/fixture/other'}
        action = {**action, 'checks': [other]}
        self.assertIsNone(effect.reuse_native(action, native_result(action)))

    def test_local_file_polling_waits_for_expected_contents_without_mutating(self):
        effect = ExpectedEffect(self.file, self.before); clock = [0.0]; calls = []
        def check(spec): calls.append(spec); return checked(spec, clock[0] >= 0.4)
        result = effect.wait_file(check, timeout=1, now=lambda: clock[0], sleep=lambda seconds: clock.__setitem__(0, clock[0] + seconds))
        self.assertEqual(result['outcome'], 'verified'); self.assertGreater(len(calls), 1)
        self.assertTrue(all(value == self.file for value in calls)); self.assertLess(clock[0], 1)

    def test_file_polling_bound_cancellation_and_unavailable_response(self):
        effect = ExpectedEffect(self.file, self.before); clock = [0.0]
        result = effect.wait_file(lambda check: checked(check, False), timeout=0.5, now=lambda: clock[0],
                                 sleep=lambda seconds: clock.__setitem__(0, clock[0] + seconds))
        self.assertEqual(result['outcome'], 'unconfirmed'); self.assertEqual(clock[0], 0.5)
        with self.assertRaises(runtime.ActionRejected):
            effect.wait_file(mock.Mock(side_effect=runtime.ActionRejected('Stopped', 'cancelled')))
        self.assertEqual(effect.wait_file(mock.Mock(side_effect=RuntimeError('Lost readonly response')))['reason'], 'check_unavailable')

    def test_file_polling_handles_deadline_crossing_before_sleep(self):
        effect = ExpectedEffect(self.file, self.before)
        clock = mock.Mock(side_effect=[0.0, 0.4, 0.6, 0.7])
        sleep = mock.Mock()
        result = effect.wait_file(lambda check: checked(check, False), timeout=0.5, now=clock, sleep=sleep)
        self.assertEqual(result['outcome'], 'unconfirmed')
        sleep.assert_called_once_with(0.0)

    def test_command_with_gui_expectation_uses_bounded_local_check(self):
        after = observation('wanted', 'after')
        effect = ExpectedEffect(self.field, self.before)
        action = {'type': 'run_command', 'argv': ['fixture']}
        with mock.patch.object(runtime, 'wait_for_screen_change', return_value=(after, {
                'reason': 'expected_effect_verified', 'polls': 2, 'expected_effect': effect.observe(after)})) as wait, \
             mock.patch.object(runtime, 'routed_json_prompt') as model:
            _, result = runtime.verify_expected_effect(1, self.before, action, {'exit_code': 0, 'timed_out': False},
                                                       self.field, None, {})
            self.assertEqual(result['expected_effect']['outcome'], 'verified')
            self.assertEqual(wait.call_args.kwargs['timeout'], 2.0)
            model.assert_not_called()

    def test_effect_evidence_proves_only_matching_requirement_and_rechecks_without_gui_replay(self):
        task = 'Save /fixture/note with wanted and submit the form.'
        ledger = TaskEvidenceLedger(task, 'owned')
        ledger.add_requirements([{'source': task, 'description': 'File contents', 'check': self.file},
                                 {'source': task, 'description': 'Form submitted', 'check': {'type': 'visual', 'expected': 'Receipt visible'}}])
        action = {'type': 'press', 'element_id': 'before:save'}
        ledger.record_effect(self.file, checked(self.file)['checks'][0], action)
        self.assertEqual(ledger.requirements['r1']['state'], 'proven'); self.assertEqual(ledger.requirements['r2']['state'], 'pending')
        self.assertFalse(ledger.can_complete()); self.assertEqual(ledger.recheck_actions(), [])
        ledger.before_action({'type': 'key', 'key': 'return'})
        self.assertEqual(ledger.requirements['r1']['state'], 'invalidated')
        self.assertEqual(ledger.recheck_effects(), [self.file])

    def test_expected_result_validation_uses_existing_one_repair_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image'; image.write_bytes(b'fixture')
            good = {'status': 'act', 'action': {'type': 'set_value', 'element_id': 'before:field', 'text': 'wanted'},
                    'expected_result': self.field}
            bad = {**good, 'expected_result': {**self.field, 'value': 123}}
            client = mock.Mock(selected_model=None, model_switches=0)
            client.prompt.side_effect = [json.dumps(bad), json.dumps(good)]
            router = runtime.AdaptiveModelRouter(lambda *a, **k: None)
            with mock.patch.object(runtime, 'bridge_call') as bridge, mock.patch.object(runtime, 'emit'):
                result = runtime.routed_json_prompt(router, client, 'plan', image, observation=self.before)
            self.assertEqual(result, good); self.assertEqual(client.prompt.call_count, 2); self.assertEqual(router.metrics['repairs'], 1)
            self.assertIn('expected_result.value must be a string', client.prompt.call_args_list[1].args[0]); bridge.assert_not_called()

    def test_healthy_structured_expectation_still_uses_one_planning_request(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image'; image.write_bytes(b'fixture')
            good = {'status': 'act', 'action': {'type': 'set_value', 'element_id': 'before:field', 'text': 'wanted'},
                    'expected_result': self.field}
            client = mock.Mock(selected_model=None, model_switches=0); client.prompt.return_value = json.dumps(good)
            router = runtime.AdaptiveModelRouter(lambda *a, **k: None)
            with mock.patch.object(runtime, 'bridge_call') as bridge, mock.patch.object(runtime, 'emit'):
                self.assertEqual(runtime.routed_json_prompt(router, client, 'plan', image, observation=self.before), good)
            self.assertEqual(client.prompt.call_count, 1); self.assertEqual(router.metrics['repairs'], 0); bridge.assert_not_called()

    def test_unrelated_native_success_is_not_expected_effect_success_or_permission_to_replay(self):
        action = {'type': 'set_value', 'element_id': 'before:field', 'text': 'wanted'}
        effect = ExpectedEffect(self.field, self.before); after = observation('wrong', 'after')
        metrics = {}
        with mock.patch.object(runtime, 'wait_for_screen_change', return_value=(after, {
                'reason': 'bounded_wait_elapsed', 'polls': 3, 'expected_effect': effect.observe(after)})), \
             mock.patch.object(runtime, 'bridge_call') as bridge:
            _, result = runtime.verify_expected_effect(1, self.before, action, {'outcome': 'verified', 'pid': 42}, self.field, None, metrics)
            bridge.assert_not_called()
        self.assertEqual(result['outcome'], 'delivered_unconfirmed'); self.assertEqual(result['delivery_outcome'], 'verified')
        self.assertEqual(result['verification_scope'], 'expected_effect_unconfirmed')
        self.assertEqual(metrics['effect_checks'], 3); self.assertEqual(metrics['unconfirmed_effects'], 1)
        recovery = runtime.ActionRecovery(); recovery.unconfirmed(action, self.before)
        self.assertEqual(recovery.check(action, self.before)['outcome'], 'suppressed')


class ExpectedSettlingTests(unittest.TestCase):
    def test_unrelated_change_does_not_end_wait_before_expected_field_value(self):
        self.run_scenario(appears=0.8, expected='verified')

    def test_unrelated_change_exhausts_bound_without_claiming_expected_effect(self):
        self.run_scenario(appears=100, expected='unconfirmed')

    def run_scenario(self, appears, expected):
        clock = [0.0]; files = []
        with tempfile.TemporaryDirectory() as directory:
            def frame(value='old', unrelated=False):
                revision = str(len(files)); result = observation(value, revision)
                if unrelated: result['elements'].append({'id': revision + ':extra', 'pid': 42, 'role': 'AXStaticText', 'title': 'Other change'})
                path = Path(directory) / (revision + '.png'); path.write_bytes(b'stable pixels'); files.append(path)
                result['screenshot_path'] = str(path); return result
            before = frame(); action = {'type': 'press', 'element_id': before['elements'][0]['id']}
            spec = {'type': 'field_value', 'element_id': before['elements'][0]['id'], 'value': 'wanted'}
            def observe(*args, **kwargs): self.assertEqual(args[0], 'observe'); return frame('wanted' if clock[0] >= appears else 'old', True)
            with mock.patch.object(runtime, 'bridge_call', side_effect=observe) as bridge, \
                 mock.patch.object(runtime.time, 'monotonic', side_effect=lambda: clock[0]), \
                 mock.patch.object(runtime.time, 'sleep', side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                 mock.patch.object(runtime, 'routed_json_prompt') as model:
                latest, result = runtime.wait_for_screen_change(1, before, action, timeout=1.5, expected_effect=ExpectedEffect(spec, before))
                model.assert_not_called()
            self.assertEqual(result['expected_effect']['outcome'], expected)
            self.assertGreaterEqual(clock[0], min(appears, 1.5))
            self.assertEqual(result['reason'], 'expected_effect_verified' if expected == 'verified' else 'bounded_wait_elapsed')
            self.assertTrue(Path(latest['screenshot_path']).is_file())
            self.assertEqual(sum(path.exists() for path in files), 2)  # baseline + accepted final image
            self.assertTrue(all(call.args[0] == 'observe' for call in bridge.call_args_list))


class ExpectedTaskLoopTests(unittest.TestCase):
    def test_file_write_reuses_proof_and_lost_gui_reply_reconciles_file_outcome_once(self):
        for kind, calls in [('write_file', 2), ('press', 3)]:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                task = 'Save /fixture/note containing wanted.'
                spec = {'type': 'file_contents', 'path': '/fixture/note', 'content': 'wanted'}
                requirement = {'source': task, 'description': 'Save exact contents', 'check': spec}
                events, actions, methods, receipts = [], [], [], {}
                files, frame_number = {}, [0]
                generation = str(uuid.uuid4())
                router = runtime.AdaptiveModelRouter(lambda *a, **k: None)
                class Client(VerificationSessions):
                    prompt_calls = 0; model_switches = 0; selected_model = None; decisions = 0
                    def select_model(client, model): client.selected_model = model
                    def prompt(client, instruction, image):
                        client.prompt_calls += 1
                        if instruction == 'verify':
                            return json.dumps({'verified': True, 'coverage_complete': True, 'message': 'Exact file contents confirmed',
                                'proofs': [{'requirement_id': key, 'evidence_ids': entry['evidence_ids'], 'rationale': 'Exact path and content hash'}
                                           for key, entry in client.ledger.requirements.items()]})
                        client.decisions += 1
                        if client.decisions > 1: return json.dumps({'status': 'done', 'output': 'Saved exact contents'})
                        action = {'type': kind, 'path': spec['path'], 'content': spec['content']} if kind == 'write_file' else {'type': 'press', 'element_id': client.current['elements'][0]['id']}
                        return json.dumps({'status': 'act', 'action': action, 'expected_result': spec,
                                           'finish_after_action': kind == 'write_file', 'requirements': [requirement]})
                    def close(client): pass
                client = Client()
                def plan(task, observation, history, ledger): client.ledger = ledger; client.current = observation; return 'plan'
                def exchange(method, display, params, timeout):
                    methods.append(method)
                    if method == 'observe':
                        frame_number[0] += 1; revision = str(frame_number[0]); image = Path(directory) / (revision + '.png'); image.write_bytes(b'fixture')
                        return {'ok': True, 'result': {**fixture_coordinates(revision, 1), 'task_generation_id': generation, 'observation_revision': revision, 'screenshot_path': str(image),
                            'applications': [{'pid': 42, 'name': 'Fixture'}], 'elements': [{'id': revision + ':save', 'pid': 42, 'role': 'AXButton', 'title': 'Save'}]}}
                    if method == 'act':
                        actions.append(params['action']); files[spec['path']] = 'wanted'
                        native = native_result(params['action'])
                        receipt = {'action_id': params['action_id'], 'state': 'confirmed' if kind == 'write_file' else 'unconfirmed', 'terminal': True, 'result': native}
                        receipts[params['action_id']] = receipt
                        if kind == 'press': raise BridgeReplyLost('Lost GUI delivery response')
                        return {'ok': True, 'result': native, 'action_receipt': {key: receipt[key] for key in ('action_id', 'state', 'terminal')}}
                    if method == 'action_receipt': return {'ok': True, 'result': receipts[params['action_id']]}
                    if method in {'check_effect', 'recheck'}:
                        requested = params.get('check', spec)
                        return {'ok': True, 'result': checked(requested, files.get(requested['path']) == requested['content'])}
                    self.fail('Unexpected native method')
                with mock.patch.object(runtime, '_task_generation_id', generation), mock.patch.object(runtime, 'find_openclaw', return_value='fixture'), \
                     mock.patch.object(runtime, 'prepare_runtime', return_value=mock.Mock()), mock.patch.object(runtime, 'ACPClient', return_value=client), \
                     mock.patch.object(runtime, 'TaskModelRouter', return_value=router), mock.patch.object(runtime, 'bridge_exchange', side_effect=exchange), \
                     mock.patch.object(runtime, 'secure_input_target', return_value=None), mock.patch.object(runtime, 'desktop_instruction', side_effect=plan), \
                     mock.patch.object(runtime, 'verification_instruction', return_value='verify'), mock.patch.object(runtime, 'record_action_diagnostic'), \
                     mock.patch.object(runtime, 'emit', side_effect=lambda event, **fields: events.append((event, fields))):
                    runtime.run_task(task, 1, 'fixture', '')
                self.assertEqual(len(actions), 1); self.assertEqual(client.prompt_calls, calls)
                self.assertEqual(methods.count('act'), 1); self.assertEqual(sum(event == 'complete' for event, _ in events), 1)
                self.assertEqual(methods.count('check_effect'), 0 if kind == 'write_file' else 2)
                self.assertEqual(methods.count('action_receipt'), 0 if kind == 'write_file' else 1)
                self.assertEqual(router.metrics['verified_effects'], 1); self.assertEqual(router.metrics['repairs'], 0)


if __name__ == '__main__': unittest.main()
