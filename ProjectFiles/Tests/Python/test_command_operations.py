import base64
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
import action_contract_generated as contract
import openclaw_runtime as runtime
from evidence_fixtures import VerificationSessions
from coordinate_fixtures import fixture_coordinates
from command_intents import explicit_operation
from response_validation import bind_command_outcomes, normalize_action, validate_response, ResponseValidationError
from task_evidence import TaskEvidenceLedger
from action_receipts import BridgeReplyLost


def compiled(kind='copy_file', **parameters):
    return normalize_action({'type': 'run_command', 'operation': {'type': kind, **parameters}}, {})


def reply(action, content=b'exact', correct=True):
    checks = copy.deepcopy(action['checks'])
    recipe = contract.CONTRACT['command_operations'][action['operation']['type']]
    if 'snapshot' in recipe:
        checks.append({'type': 'file_contents', 'path': action['operation']['destination'],
                       'content': base64.b64encode(content).decode(), 'encoding': 'base64'})
    actual = []
    for check in checks:
        value = {'type': check['type'], 'verified': correct}
        if 'path' in check: value['path'] = check['path']
        if check['type'] == 'file_contents': value['content_sha256'] = hashlib.sha256(base64.b64decode(check['content'])).hexdigest()
        if check['type'] == 'stdout_equals': value['text_sha256'] = hashlib.sha256(check['text'].encode()).hexdigest()
        actual.append(value)
    return {'command_operation': action['operation'], 'outcome_checks': checks, 'checks': actual,
            'exit_code': 0, 'timed_out': False, 'verified': correct, 'outcome': 'verified' if correct else 'delivered_unconfirmed',
            'verification_scope': 'requested_outcomes', 'working_directory': '/fixture'}


class CommandOperationTests(unittest.TestCase):
    def test_each_recipe_has_a_fixed_executable_required_checks_and_idempotent_normalization(self):
        for kind, recipe in contract.CONTRACT['command_operations'].items():
            with self.subTest(kind=kind):
                action = contract.operation_example(kind)
                before = copy.deepcopy(action)
                result = normalize_action(action, {})
                self.assertEqual(action, before)
                self.assertTrue(result['argv'][0].startswith('/'))
                self.assertTrue(result['checks'])
                self.assertEqual(result, normalize_action(result, {}))
                self.assertEqual(result['operation'], recipe['example'])

    def test_paths_and_text_stay_literal_not_shell_source_or_flags(self):
        path = "/fixture/-n spaces 'quotes' $(touch bad) `touch bad` ; newline\n"
        action = compiled(source=path, destination=path + 'copy')
        self.assertEqual(action['argv'], ['/bin/cp', '-n', path, path + 'copy'])
        self.assertNotIn('command', action)
        text = '%n $HOME $(touch bad) `touch bad`\n'
        self.assertEqual(compiled('print_text', text=text)['argv'], ['/usr/bin/printf', '%s', text])
        self.assertEqual(compiled('create_directory', path='~/literal').get('argv')[-1], str(Path.home() / 'literal'))

    def test_wrong_flags_paths_types_and_unsupported_parameters_reject_locally(self):
        base = {'type': 'run_command', 'operation': {'type': 'copy_file', 'source': '/fixture/a', 'destination': '/fixture/b'}}
        cases = [({'operation': {}}, 'action.operation.type'), ({'operation': True}, 'action.operation must be an object'),
                 ({'operation': {'type': 'unknown'}}, 'supported command operation'),
                 ({'operation': {'type': 'copy_file', 'source': '/fixture/a'}}, 'action.operation.destination is required'),
                 ({'operation': {**base['operation'], 'source': True}}, 'action.operation.source must be a string'),
                 ({'operation': {**base['operation'], 'destination': 'relative'}}, 'absolute or ~/'),
                 ({'operation': {**base['operation'], 'destination': '/fixture/../other'}}, 'parent traversal'),
                 ({'operation': {**base['operation'], 'source': '/fixture/\0'}}, 'NUL'),
                 ({'operation': {**base['operation'], 'overwrite': True}}, 'unsupported parameters'),
                 ({'argv': ['/bin/cp', '-rf', '/fixture/a', '/fixture/b']}, 'established operation template'),
                 ({'argv': ['/bin/cp', '-n', '/fixture/a', '/fixture/wrong']}, 'established operation template'),
                 ({'command': 'echo wrong'}, 'cannot accompany'),
                 ({'type': 'launch_app', 'app': 'Example App'}, 'only supported for run_command')]
        for parameters, error in cases:
            with self.subTest(parameters=parameters), self.assertRaisesRegex(ResponseValidationError, error):
                normalize_action({**base, **parameters}, {})

    def test_required_checks_cannot_be_removed_and_additional_checks_remain_available(self):
        action = compiled('create_directory', path='/fixture/folder')
        supplied = {**action, 'checks': [{'type': 'file_exists', 'path': '/fixture/other'}] * 2}
        result = normalize_action(supplied, {})
        self.assertEqual(result['checks'], action['checks'] + supplied['checks'][:1])
        self.assertEqual(result, normalize_action(result, {}))
        self.assertEqual(normalize_action({'type': 'run_command', 'command': 'printf literal | cat'}, {})['command'], 'printf literal | cat')

    def test_complete_literal_requests_bind_the_operation_and_operands(self):
        requests = [('Create a directory at "/fixture/a b"', 'create_directory', {'path': '/fixture/a b'}),
                    ('Copy /fixture/a to /fixture/b', 'copy_file', {'source': '/fixture/a', 'destination': '/fixture/b'}),
                    ("Rename file '/fixture/a' to '/fixture/b'", 'move_file', {'source': '/fixture/a', 'destination': '/fixture/b'}),
                    ('Delete the file /fixture/a', 'remove_file', {'path': '/fixture/a'}),
                    ('Remove an empty directory /fixture/a', 'remove_empty_directory', {'path': '/fixture/a'}),
                    ('Print literal text ""', 'print_text', {'text': ''})]
        for task, kind, parameters in requests:
            with self.subTest(task=task):
                self.assertEqual(explicit_operation(task), {'type': kind, **parameters})
                ledger = TaskEvidenceLedger(task)
                decision = {'status': 'act', 'action': compiled(kind, **parameters), 'requirements': [
                    {'source': task, 'description': 'Requested operation', 'check': {'type': 'command_operation', 'operation': {'type': kind, **parameters}}}]}
                validate_response(decision, 'planning', {}, ledger)
                changed = copy.deepcopy(decision); changed['action'] = {'type': 'run_command', 'operation': {'type': kind, **parameters}}
                key = next(iter(parameters)); changed['action']['operation'][key] += 'wrong'
                with self.assertRaisesRegex(ResponseValidationError, 'explicit operation and operands'):
                    validate_response(changed, 'planning', {}, ledger)

    def test_compound_ambiguous_and_negative_requests_are_not_partially_recognized(self):
        for task in ['Copy /fixture/a to /fixture/b then delete /fixture/c', 'Do not delete the file /fixture/a',
                     'Create a directory /fixture/a and write a note in it', 'Copy the selected file to Desktop',
                     'Create folder relative', 'Delete the file /fixture/a.', 'Run cp -a /fixture/a /fixture/b']:
            self.assertIsNone(explicit_operation(task), task)

    def test_only_the_explicit_destination_parent_is_allowed_as_a_prerequisite(self):
        task = 'Copy /fixture/source to /fixture/new/copy'
        ledger = TaskEvidenceLedger(task)
        base = {'status': 'act', 'requirements': [{'source': task, 'description': 'Copy', 'check':
                {'type': 'command_operation', 'operation': explicit_operation(task)}}]}
        validate_response({**base, 'action': compiled('create_directory', path='/fixture/new')}, 'planning', {}, ledger)
        with self.assertRaisesRegex(ResponseValidationError, 'explicit operation and operands'):
            validate_response({**base, 'action': compiled('remove_file', path='/fixture/source')}, 'planning', {}, ledger)

    def test_native_snapshot_is_bound_to_the_originating_operation_and_rechecked_read_only(self):
        task = 'Copy /fixture/a to /fixture/b'; operation = explicit_operation(task)
        action = compiled(**{k: v for k, v in operation.items() if k != 'type'}); result = reply(action, b'\0\xffexact')
        bound = bind_command_outcomes(action, result)
        ledger = TaskEvidenceLedger(task, 'owned')
        ledger.add_requirements([{'source': task, 'description': 'Copy exact bytes', 'check': {'type': 'command_operation', 'operation': operation}}])
        ledger.record_action(bound, result)
        self.assertEqual(ledger.requirements['r1']['state'], 'proven')
        self.assertFalse(ledger.can_complete())  # whole-request audit is still required
        ledger.before_action({'type': 'key', 'key': 'return'})
        self.assertEqual(ledger.requirements['r1']['state'], 'invalidated')
        self.assertEqual(ledger.recheck_actions(), [bound])
        ledger.record_action(bound, {'requested_checks': bound['checks'], 'checks': result['checks']}, recheck=True)
        self.assertEqual(ledger.requirements['r1']['state'], 'proven')
        self.assertNotIn('content', next(e['fact'] for e in ledger.evidence.values() if e['fact']['type'] == 'command_operation'))

    def test_zero_exit_exists_only_and_wrong_bytes_do_not_prove_copy(self):
        task = 'Copy /fixture/a to /fixture/b'; operation = explicit_operation(task); action = compiled(source='/fixture/a', destination='/fixture/b')
        ledger = TaskEvidenceLedger(task, 'owned')
        ledger.add_requirements([{'source': task, 'description': 'Copy', 'check': {'type': 'command_operation', 'operation': operation}}])
        for result in [{'exit_code': 0, 'timed_out': False}, {**reply(action), 'outcome_checks': action['checks'], 'checks': reply(action)['checks'][:1]}]:
            ledger.record_action(action, result)
            self.assertNotEqual(ledger.requirements['r1']['state'], 'proven')
        result = reply(action, correct=False); bound = bind_command_outcomes(action, result); ledger.record_action(bound, result)
        self.assertNotEqual(ledger.requirements['r1']['state'], 'proven')
        self.assertEqual(ledger.recheck_actions(), [bound])

    def test_mismatched_native_response_never_promotes_evidence(self):
        action = compiled(source='/fixture/a', destination='/fixture/b'); result = reply(action)
        for changed in [{'command_operation': {'type': 'remove_file', 'path': '/fixture/a'}},
                        {'outcome_checks': action['checks']}, {'outcome_checks': []},
                        {'outcome_checks': [*action['checks'], {'type': 'file_contents', 'path': '/fixture/wrong', 'content': '', 'encoding': 'base64'}]}]:
            with self.subTest(changed=changed), self.assertRaises(RuntimeError): bind_command_outcomes(action, {**result, **changed})

    def test_recheck_cannot_manufacture_a_command_operation_that_never_executed(self):
        action = compiled('create_directory', path='/fixture/folder'); result = reply(action)
        ledger = TaskEvidenceLedger('Create a directory at /fixture/folder', 'owned')
        ledger.record_action(action, {'requested_checks': action['checks'], 'checks': result['checks']}, recheck=True)
        self.assertFalse(any(e['fact']['type'] == 'command_operation' for e in ledger.evidence.values()))

    def test_native_source_snapshots_stay_out_of_recent_and_historical_model_context(self):
        action = compiled(source='/fixture/a', destination='/fixture/b')
        result = reply(action, b'private native snapshot' * 1000)
        action = bind_command_outcomes(action, result)
        entry = {'step': 1, 'action': action, 'result': result}
        before = copy.deepcopy(entry)
        snapshot = result['outcome_checks'][-1]['content']
        recent = runtime.compact_history([entry])[0]
        self.assertEqual(recent['action']['operation'], action['operation'])
        self.assertNotIn('checks', recent['action']); self.assertNotIn('argv', recent['action'])
        self.assertNotIn('outcome_checks', recent['result'])
        self.assertEqual(recent['result']['checks'], result['checks'])
        history = [entry, *[{'action': 'fixture'} for _ in range(runtime.MAX_RECENT_ACTIONS)]]
        progress = runtime.historical_progress(history, runtime.MAX_RECENT_ACTIONS, runtime.command_outcome_verified)
        self.assertEqual(progress['facts'][0]['operation'], action['operation'])
        self.assertNotIn('content', progress['facts'][0]['evidence']['checks'][-1])
        for prompt in [runtime.desktop_instruction('Copy /fixture/a to /fixture/b', {}, [entry]),
                       runtime.verification_instruction('Copy /fixture/a to /fixture/b', {}, {}, [entry])]:
            self.assertNotIn(snapshot, prompt)
            self.assertNotIn('private native snapshot', prompt)
        self.assertEqual(entry, before)

    def test_uncertain_operations_cannot_replay_by_dropping_the_template(self):
        action = compiled(source='/fixture/a', destination='/fixture/b')
        recovery = runtime.ActionRecovery(); recovery.unconfirmed(action, {})
        plain = {'type': 'run_command', 'argv': action['argv'], 'checks': action['checks']}
        self.assertEqual(recovery.check(plain, {})['outcome'], 'suppressed')

    def test_healthy_template_uses_one_model_request_and_invalid_operand_uses_one_repair(self):
        task = 'Copy /fixture/a to /fixture/b'; operation = explicit_operation(task); ledger = TaskEvidenceLedger(task)
        good = {'status': 'act', 'action': {'type': 'run_command', 'operation': operation}, 'requirements': [
            {'source': task, 'description': 'Copy', 'check': {'type': 'command_operation', 'operation': operation}}]}
        bad = copy.deepcopy(good); bad['action']['operation']['destination'] = '/fixture/wrong'
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image'; image.write_bytes(b'fixture')
            for responses, calls in [([good], 1), ([bad, good], 2)]:
                client = mock.Mock(selected_model=None, model_switches=0); client.prompt.side_effect = [json.dumps(value) for value in responses]
                router = runtime.AdaptiveModelRouter(lambda *a, **k: None)
                with mock.patch.object(runtime, 'bridge_call') as bridge, mock.patch.object(runtime, 'emit'):
                    result = runtime.routed_json_prompt(router, client, 'plan', image, observation={}, ledger=ledger)
                    bridge.assert_not_called()
                self.assertEqual(result['action']['argv'], ['/bin/cp', '-n', '/fixture/a', '/fixture/b'])
                self.assertEqual(client.prompt.call_count, calls); self.assertEqual(router.metrics['repairs'], calls - 1)

    def test_contextual_examples_are_valid_short_and_leave_general_tools_available(self):
        observation = {'elements': [], 'applications': []}
        for task in ['Create a directory at /fixture/folder', 'Copy /fixture/a to /fixture/b',
                     'Move /fixture/a to /fixture/b', 'Delete file /fixture/a', 'Remove empty folder /fixture/a', 'Print literal text "hello"']:
            prompt = runtime.desktop_instruction(task, observation, [], TaskEvidenceLedger(task))
            self.assertLessEqual(len(prompt), 4000, task)
            self.assertIn('"operation"', prompt); self.assertIn('General argv/command stays available', prompt)
            self.assertIn('ALL requirements', prompt); self.assertIn('explicit user authorization', prompt)
            section = prompt.split('RELEVANT ACTION EXAMPLES:\n')[1].split('ORIGINAL TASK AND OBSERVATION:')[0]
            for line in section.splitlines():
                if line.startswith('{'):
                    value = json.loads(line)
                    if value.get('status') == 'act': validate_response(value, 'planning', {})
                    else: normalize_action(value, {})


class CommandOperationTaskLoopTests(unittest.TestCase):
    def test_copy_uses_one_decision_readonly_completion_checks_and_no_replay_after_lost_response(self):
        for lost in [False, True]:
            with self.subTest(lost=lost), tempfile.TemporaryDirectory() as directory:
                task = 'Copy /fixture/a to /fixture/b'; operation = explicit_operation(task)
                generation = str(uuid.uuid4()); events, actions, methods, receipts = [], [], [], {}
                frame = [0]; router = runtime.AdaptiveModelRouter(lambda *a, **k: None)
                class Client(VerificationSessions):
                    selected_model = None; model_switches = 0; prompt_calls = 0
                    def select_model(client, model): client.selected_model = model
                    def prompt(client, instruction, image):
                        client.prompt_calls += 1
                        if instruction == 'verify':
                            return json.dumps({'verified': True, 'coverage_complete': True, 'message': 'Copied exact bytes',
                                'proofs': [{'requirement_id': key, 'evidence_ids': entry['evidence_ids'], 'rationale': 'Exact native operation and byte readback'}
                                           for key, entry in client.ledger.requirements.items()]})
                        return json.dumps({'status': 'act', 'action': {'type': 'run_command', 'operation': operation}, 'finish_after_action': True,
                            'requirements': [{'source': task, 'description': 'Copy exact source bytes to the requested destination',
                                              'check': {'type': 'command_operation', 'operation': operation}}]})
                    def close(client): pass
                client = Client()
                def plan(task, observation, history, ledger): client.ledger = ledger; return 'plan'
                def exchange(method, display, params, timeout):
                    methods.append(method)
                    if method == 'observe':
                        frame[0] += 1; image = Path(directory) / (str(frame[0]) + '.png'); image.write_bytes(b'fixture')
                        return {'ok': True, 'result': {**fixture_coordinates(str(frame[0])), 'task_generation_id': generation, 'observation_revision': str(frame[0]),
                                                      'screenshot_path': str(image), 'applications': [], 'elements': []}}
                    if method == 'act':
                        actions.append(params['action']); result = reply(params['action'], b'\0\xffexact')
                        receipt = {'action_id': params['action_id'], 'state': 'confirmed', 'terminal': True, 'result': result}
                        receipts[params['action_id']] = receipt
                        if lost: raise BridgeReplyLost('Lost terminal reply')
                        return {'ok': True, 'result': result, 'action_receipt': {key: receipt[key] for key in ('action_id', 'state', 'terminal')}}
                    if method == 'action_receipt': return {'ok': True, 'result': receipts[params['action_id']]}
                    if method == 'recheck':
                        checks = params['action']['checks']; original = next(iter(receipts.values()))['result']
                        self.assertEqual(checks, original['outcome_checks'])
                        return {'ok': True, 'result': {'requested_checks': checks, 'checks': original['checks']}}
                    self.fail('Unexpected native method ' + method)
                with mock.patch.object(runtime, '_task_generation_id', generation), mock.patch.object(runtime, 'find_openclaw', return_value='fixture'), \
                     mock.patch.object(runtime, 'prepare_runtime', return_value=mock.Mock()), mock.patch.object(runtime, 'ACPClient', return_value=client), \
                     mock.patch.object(runtime, 'TaskModelRouter', return_value=router), mock.patch.object(runtime, 'bridge_exchange', side_effect=exchange), \
                     mock.patch.object(runtime, 'secure_input_target', return_value=None), mock.patch.object(runtime, 'desktop_instruction', side_effect=plan), \
                     mock.patch.object(runtime, 'verification_instruction', return_value='verify'), mock.patch.object(runtime, 'record_action_diagnostic'), \
                     mock.patch.object(runtime, 'emit', side_effect=lambda event, **fields: events.append((event, fields))):
                    runtime.run_task(task, 1, 'fixture', '')
                self.assertEqual(len(actions), 1); self.assertEqual(actions[0]['argv'], ['/bin/cp', '-n', '/fixture/a', '/fixture/b'])
                self.assertEqual(client.prompt_calls, 2); self.assertEqual(router.metrics['planning'], 1); self.assertEqual(router.metrics['verification'], 1)
                self.assertEqual(router.metrics['repairs'], 0); self.assertEqual(methods.count('action_receipt'), int(lost))
                self.assertEqual(methods.count('recheck'), 1); self.assertEqual(sum(event == 'complete' for event, _ in events), 1)


if __name__ == '__main__': unittest.main()
