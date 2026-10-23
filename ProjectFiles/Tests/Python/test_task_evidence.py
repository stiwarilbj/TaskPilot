import base64
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
from evidence_fixtures import native_result, native_check, native_batch
import openclaw_runtime as runtime
from evidence_fixtures import VerificationSessions
from response_validation import ResponseValidationError, validate_response
from task_evidence import TaskEvidenceLedger, content_hash, validate_metadata


TASK = 'Write /fixture/a.txt with A and /fixture/b.txt with B.'


def requirement(task, kind='file_contents', **fields):
    return {'source': task, 'description': f'{kind}: {fields}', 'check': {'type': kind, **fields}}


def write(path='/fixture/a.txt', content='A', **fields):
    return {'type': 'write_file', 'path': path, 'content': content, **fields}


def written(action):
    return native_result(action)


def read_result(target, content, **fields):
    return native_result({'type': 'read_file', 'path': target}, content=content, **fields)


def audit(ledger, **fields):
    proofs = []
    for identifier, r in ledger.requirements.items():
        refs = [ref for ref, evidence in ledger.evidence.items() if ledger.matches(r['check'], evidence, semantic=True)]
        proofs.append({'requirement_id': identifier, 'evidence_ids': refs[-1:], 'rationale': 'Exact fixture evidence'})
    return {'verified': True, 'coverage_complete': True, 'proofs': proofs, 'message': 'Verified fixture result', **fields}


class EvidenceLedgerTests(unittest.TestCase):
    def ledger(self, task=TASK):
        ledger = TaskEvidenceLedger(task, 'task-a')
        ledger.add_requirements([requirement(task, path='/fixture/a.txt', content='A'),
                                 requirement(task, path='/fixture/b.txt', content='B')])
        return ledger

    def test_successful_write_proves_only_matching_requirement_and_never_root_coverage(self):
        ledger = self.ledger()
        a = write(); ledger.record_action(a, written(a))
        self.assertEqual([r['state'] for r in ledger.requirements.values()], ['proven', 'pending'])
        self.assertFalse(ledger.can_complete())
        b = write('/fixture/b.txt', 'B'); ledger.record_action(b, written(b))
        self.assertFalse(ledger.can_complete())
        result = audit(ledger)
        validate_response(result, 'verification', ledger=ledger)
        self.assertTrue(ledger.audit(result))

    def test_existence_and_wrong_contents_do_not_prove_file_contents(self):
        ledger = self.ledger()
        ledger.add_evidence({'type': 'file_exists', 'path': '/fixture/a.txt'}, mutable=True)
        wrong = write(content='wrong'); ledger.record_action(wrong, written(wrong))
        self.assertEqual(ledger.requirements['r1']['state'], 'pending')
        with self.assertRaisesRegex(ResponseValidationError, 'target and outcome'):
            validate_response({'verified': True, 'coverage_complete': True, 'proofs': [
                {'requirement_id': 'r1', 'evidence_ids': ['e1'], 'rationale': 'It exists'}]}, 'verification', ledger=ledger)

    def test_invalid_native_results_never_create_proof(self):
        for changes in [{'path': '/fixture/other.txt'}, {'content_sha256': 'wrong'}, {'bytes_written': True},
                        {'verified': False}, {'mode': 'append'}]:
            ledger = self.ledger(); action = write()
            with self.assertRaises(runtime.NativeProtocolError): ledger.record_action(action, native_result(action, **{**written(action), **changes}))
            self.assertFalse(ledger.evidence, changes)

    def test_later_mutation_invalidates_state_but_retains_history_and_recheck_targets(self):
        ledger = self.ledger(); action = write(); ledger.record_action(action, written(action))
        original = len(ledger.evidence)
        ledger.before_action(write('/fixture/unrelated', 'C'))
        self.assertEqual(ledger.requirements['r1']['state'], 'invalidated')
        self.assertEqual(len(ledger.evidence), original)
        self.assertEqual(ledger.recheck_actions(), [action])
        check = {'type': 'file_contents', 'path': action['path'], 'content': 'A'}
        ledger.record_action(action, native_batch([check], [native_check(check)]), recheck=True)
        self.assertEqual(ledger.requirements['r1']['state'], 'proven')

    def test_commands_prove_each_check_individually_and_execution_is_historical(self):
        ledger = self.ledger()
        command = {'type': 'run_command', 'argv': ['/fixture/create'], 'working_directory': '/fixture',
                   'checks': [{'type': 'file_contents', 'path': '/fixture/a.txt', 'content': 'A'},
                              {'type': 'file_contents', 'path': '/fixture/b.txt', 'content': 'B'}]}
        ledger.add_requirements([requirement(TASK, 'command_executed', argv=command['argv'], working_directory='/fixture')])
        ledger.record_action(command, native_result(command, **{'exit_code': 0, 'timed_out': False, 'working_directory': '/fixture',
                                       'verified': False, 'checks': [
                                           {'type': 'file_contents', 'path': '/fixture/a.txt', 'verified': True, 'content_sha256': content_hash(write())},
                                           {'type': 'file_contents', 'path': '/fixture/b.txt', 'verified': False}]}))
        self.assertEqual([r['state'] for r in ledger.requirements.values()], ['proven', 'pending', 'proven'])
        ledger.before_action({'type': 'run_command', 'argv': ['/fixture/other']})
        self.assertEqual([r['state'] for r in ledger.requirements.values()], ['invalidated', 'pending', 'proven'])

    def test_exit_zero_only_proves_execution(self):
        ledger = self.ledger()
        ledger.record_action({'type': 'run_command', 'argv': ['/fixture/noop']}, native_result({'type': 'run_command', 'argv': ['/fixture/noop']}, **{'exit_code': 0, 'timed_out': False}))
        self.assertEqual([r['state'] for r in ledger.requirements.values()], ['pending', 'pending'])
        self.assertEqual(next(iter(ledger.evidence.values()))['fact']['type'], 'command_executed')

    def test_append_proves_historical_append_not_complete_file_contents(self):
        ledger = self.ledger(); action = write(mode='append')
        ledger.add_requirements([requirement(TASK, 'file_append', path=action['path'], content='A')])
        ledger.record_action(action, written(action))
        self.assertEqual(ledger.requirements['r1']['state'], 'pending')
        ledger.before_action(write(content='B'))
        self.assertEqual(ledger.requirements['r3']['state'], 'proven')

    def test_historical_write_can_remain_proven_after_requested_replacement(self):
        ledger = self.ledger(); action = write()
        ledger.add_requirements([requirement(TASK, 'file_written', path=action['path'], content='A')])
        ledger.record_action(action, written(action))
        ledger.before_action(write(content='replacement'))
        self.assertEqual(ledger.requirements['r1']['state'], 'invalidated')
        self.assertEqual(ledger.requirements['r3']['state'], 'proven')
        facts = list(ledger.prompt_state()['evidence'].values())
        self.assertEqual(facts[0]['origin'], {'action_id': 'a1', 'method': 'execution'})

    def test_duplicate_uncovered_requirement_cannot_bypass_coverage_audit(self):
        ledger = self.ledger()
        for action in [write(), write('/fixture/b.txt', 'B')]: ledger.record_action(action, written(action))
        response = {'verified': True, 'coverage_complete': True, 'uncovered_requirements': [requirement(TASK, path='/fixture/a.txt', content='A')]}
        self.assertFalse(ledger.audit(response))
        self.assertFalse(ledger.can_complete())

    def test_full_reads_require_untruncated_valid_bytes_and_hash(self):
        for changes in [{'truncated': True}, {'bytes_returned': True}, {'bytes_returned': 1},
                        {'content_sha256': 'fake'}, {'encoding': 'unknown'}, {'path': '/fixture/wrong'}]:
            ledger = self.ledger()
            try: ledger.record_action({'type': 'read_file', 'path': '/fixture/a.txt'}, read_result('/fixture/a.txt', 'ABC', **changes))
            except runtime.NativeProtocolError: pass
            self.assertFalse(ledger.evidence, changes)

    def test_exact_output_requires_native_contents_or_explicit_output_reference(self):
        task = 'Read file "/fixture/a.txt"'; ledger = TaskEvidenceLedger(task)
        ledger.record_action({'type': 'read_file', 'path': '/fixture/a.txt'}, read_result('/fixture/a.txt', ' A\n'))
        result = audit(ledger, message='Made up contents')
        with self.assertRaisesRegex(ResponseValidationError, 'complete verified requested output'):
            validate_response(result, 'verification', ledger=ledger)
        result['output_evidence_ids'] = ['e1']
        validate_response(result, 'verification', ledger=ledger)
        self.assertFalse(ledger.can_complete('Made up contents'))
        self.assertTrue(ledger.can_complete(' A\n'))

    def test_requested_answer_cannot_use_file_existence_or_delivered_click(self):
        task = 'Tell me the contents'; ledger = TaskEvidenceLedger(task)
        ledger.add_requirements([requirement(task, 'answer', expected=task)])
        ledger.add_evidence({'type': 'file_exists', 'path': '/fixture/a.txt'}, mutable=True)
        result = audit(ledger); result['proofs'][0]['evidence_ids'] = ['e1']
        with self.assertRaisesRegex(ResponseValidationError, 'target and outcome'):
            validate_response(result, 'verification', ledger=ledger)
        ledger.record_action({'type': 'press', 'element_id': 'x'}, native_result({'type': 'press', 'element_id': 'x'}))
        self.assertEqual(len(ledger.evidence), 1)

    def test_visual_proof_requires_fresh_observation_not_event_delivery(self):
        task = 'Save the draft'; ledger = TaskEvidenceLedger(task, 'task-a')
        ledger.add_requirements([requirement(task, 'visual', expected='Saved receipt')])
        ledger.observe({'observation_revision': 'first', 'task_generation_id': 'task-a'})
        result = audit(ledger); validate_response(result, 'verification', ledger=ledger)
        self.assertTrue(ledger.audit(result))
        ledger.observe({'observation_revision': 'second', 'task_generation_id': 'task-a'})
        self.assertFalse(ledger.can_complete())
        with self.assertRaisesRegex(ResponseValidationError, 'current evidence'):
            validate_response(result, 'verification', ledger=ledger)

    def test_cross_task_observation_and_evidence_cannot_prove_completion(self):
        ledger = self.ledger()
        with self.assertRaisesRegex(ValueError, 'another task'):
            ledger.observe({'observation_revision': 'old', 'task_generation_id': 'task-b'})
        action = write(); ledger.record_action(action, written(action))
        evidence = deepcopy(ledger.evidence['e1']); evidence['generation'] = 'task-b'
        self.assertFalse(ledger.matches(ledger.requirements['r1']['check'], evidence))

    def test_precise_metadata_errors_and_unknown_references(self):
        ledger = self.ledger(); action = write(); ledger.record_action(action, written(action))
        cases = [({'requirements': [requirement('Not from task', path='/fixture/a', content='A')]}, 'requirements[0].source'),
                 ({'requirements': [{'source': TASK, 'description': 'bad', 'check': {'type': []}}]}, 'check.type'),
                 ({'requirements': [requirement(TASK, path='/fixture/a', content=True)]}, 'check.content'),
                 ({'coverage_complete': 'true'}, 'coverage_complete'),
                 ({'output_evidence_ids': ['e1']}, 'output_evidence_ids'),
                 ({'proofs': [{'requirement_id': 'r99', 'evidence_ids': ['e1'], 'rationale': 'x'}]}, 'proofs[0].requirement_id'),
                 ({'proofs': [{'requirement_id': 'r1', 'evidence_ids': ['stale'], 'rationale': 'x'}]}, 'proofs[0].evidence_ids')]
        for value, expected in cases:
            with self.subTest(expected=expected), self.assertRaises(ResponseValidationError) as error:
                validate_response({'status': 'done', **value}, 'planning', ledger=ledger)
            self.assertIn(expected, str(error.exception))

    def test_global_verified_and_empty_remaining_list_cannot_authorize_completion(self):
        ledger = self.ledger()
        for response in [{'verified': True}, {'verified': True, 'coverage_complete': True, 'proofs': []}]:
            with self.assertRaises(ResponseValidationError): validate_response(response, 'verification', ledger=ledger)
        self.assertFalse(ledger.can_complete())
        ledger.accept_plan({'completed_requirements': ['everything'], 'remaining_requirements': []})
        self.assertFalse(ledger.can_complete())

    def test_uncovered_requirements_are_added_pending_without_removing_existing(self):
        ledger = self.ledger()
        response = {'verified': False, 'uncovered_requirements': [requirement(TASK, 'answer', expected='Explain result')]}
        validate_response(response, 'verification', ledger=ledger)
        self.assertFalse(ledger.audit(response))
        self.assertEqual(list(ledger.requirements), ['r1', 'r2', 'r3'])
        ledger.accept_plan({'requirements': []})
        self.assertEqual(len(ledger.requirements), 3)

    def test_long_history_keeps_complete_proof_but_prompt_uses_explicit_excerpts(self):
        ledger = self.ledger(); content = 'A' * 15000
        for i in range(20):
            action = write(f'/fixture/{i}', content)
            ledger.record_action(action, written(action))
        self.assertEqual(len(ledger.evidence), 60)
        read = {'type': 'read_file', 'path': '/fixture/long'}
        ledger.record_action(read, read_result(read['path'], content))
        self.assertEqual(ledger.evidence['e61']['fact']['content'], content)
        self.assertEqual(ledger.prompt_state()['evidence']['e61']['content']['full_length'], 15000)
        self.assertNotIn('task-a', json.dumps(ledger.prompt_state()))

    def test_fingerprint_changes_for_pending_proof_invalidation_and_coverage(self):
        ledger = self.ledger(); before = ledger.fingerprint()
        action = write(); ledger.record_action(action, written(action))
        after = ledger.fingerprint(); self.assertNotEqual(before, after)
        ledger.before_action(write()); self.assertNotEqual(after, ledger.fingerprint())

    def test_only_complete_local_grammars_enable_shortcuts(self):
        for task in ['What is the largest file in Downloads?', 'What’s my largest file in my downloads folder',
                     'Read file "/fixture/a.txt"']:
            self.assertTrue(TaskEvidenceLedger(task).local_complete_grammar, task)
        for task in ['Find the largest file in Downloads and delete it',
                     'What is the largest file in Downloads? Also open it.',
                     'Read file "/fixture/a.txt" and write "/fixture/b.txt"',
                     'Read file "/fixture/a.txt" and explain it']:
            self.assertFalse(TaskEvidenceLedger(task).local_complete_grammar, task)

    def test_planning_checklist_uses_existing_one_call_and_same_model_repair_budget(self):
        task = 'Save the draft'; ledger = TaskEvidenceLedger(task)
        good = {'status': 'act', 'requirements': [requirement(task, 'visual', expected='Saved')],
                'action': {'type': 'press', 'element_id': 'now:save'}}
        observation = {'elements': [{'id': 'now:save', 'pid': 42}], 'applications': [{'pid': 42}]}
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'frame'; image.write_bytes(b'fixture')
            for responses, count in [([good], 1), ([{'status': 'act', 'action': good['action']}, good], 2)]:
                client = mock.Mock(model_switches=1, selected_model=None, reconnects=0,
                                   successful_provider_retries=None, prompt=mock.Mock(side_effect=[json.dumps(v) for v in responses]))
                router = runtime.AdaptiveModelRouter(lambda *a, **k: None)
                with mock.patch.object(runtime, 'emit'), mock.patch.object(runtime, 'bridge_call') as bridge:
                    decision = runtime.routed_json_prompt(router, client, 'unchanged fixture contract', image, observation=observation, ledger=ledger)
                self.assertEqual(decision['action'], good['action']); self.assertEqual(client.prompt.call_count, count)
                bridge.assert_not_called()
                self.assertEqual(router.metrics['repairs'], count - 1)
                if count == 2: self.assertIn('requirements must enumerate', client.prompt.call_args_list[1].args[0])


class EvidenceTaskLoopTests(unittest.TestCase):
    def run_task(self, task, responses, *, initial_files=None):
        files = dict(initial_files or {}); self.actions = []; self.events = []; self.ledgers = []
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        revision = 0
        def create(*args, **kwargs):
            ledger = TaskEvidenceLedger(*args, **kwargs); self.ledgers.append(ledger); return ledger
        def bridge(method, _display, **params):
            nonlocal revision
            if method == 'observe':
                revision += 1; image = Path(temporary.name) / f'{revision}.png'; image.write_bytes(b'fixture')
                return {'observation_revision': str(revision), 'screenshot_path': str(image), 'applications': [], 'elements': []}
            action = params['action']
            if method == 'recheck':
                self.assertEqual(action['type'], 'write_file')
                check = {'type': 'file_contents', 'path': action['path'], 'content': action['content']}
                actual = {'type': 'file_contents', 'path': action['path'], 'verified': files.get(action['path']) == action['content'],
                          'content_sha256': content_hash(action)}
                return native_batch([check], [actual])
            self.assertEqual(method, 'act'); self.actions.append(deepcopy(action))
            if action['type'] == 'read_file': return read_result(action['path'], files[action['path']])
            files[action['path']] = action['content']; return written(action)
        test = self
        class Client(VerificationSessions):
            prompt_calls = model_switches = reconnects = 0
            successful_provider_retries = None
            selected_model = None
            def select_model(client, model): client.selected_model = model
            def prompt(client, instruction, image):
                client.prompt_calls += 1
                response = responses[client.prompt_calls - 1]
                return json.dumps(response(test.ledgers[0]) if callable(response) else response)
            def close(client): pass
        client = Client(); router = runtime.AdaptiveModelRouter(lambda *a, **k: None)
        with mock.patch.object(runtime, 'TaskEvidenceLedger', side_effect=create), \
             mock.patch.object(runtime, 'find_openclaw', return_value='fixture'), \
             mock.patch.object(runtime, 'prepare_runtime', return_value=mock.Mock()), \
             mock.patch.object(runtime, 'ACPClient', return_value=client), \
             mock.patch.object(runtime, 'TaskModelRouter', return_value=router), \
             mock.patch.object(runtime, 'bridge_call', side_effect=bridge), \
             mock.patch.object(runtime, 'secure_input_target', return_value=None), \
             mock.patch.object(runtime, 'record_action_diagnostic'), \
             mock.patch.object(runtime, 'emit', side_effect=lambda kind, **fields: self.events.append((kind, fields))):
            runtime.run_task(task, 1, 'fixture', '')
        return client, router

    def test_two_file_task_rejects_first_partial_completion_then_finishes_once(self):
        first = {'status': 'act', 'requirements': [requirement(TASK, path='/fixture/a.txt', content='A'),
                                                requirement(TASK, path='/fixture/b.txt', content='B')],
                 'action': write(), 'finish_after_action': True, 'remaining_requirements': []}
        second = {'status': 'act', 'action': write('/fixture/b.txt', 'B'), 'finish_after_action': True}
        client, router = self.run_task(TASK, [first, {'verified': False, 'missing': ['Write B']}, second, audit])
        self.assertEqual(len(self.actions), 2)
        self.assertEqual(sum(kind == 'complete' for kind, _ in self.events), 1)
        self.assertEqual(client.prompt_calls, 4)
        self.assertEqual((router.metrics['planning'], router.metrics['verification'], router.metrics['repairs']), (2, 2, 0))
        self.assertEqual(client.verification_sessions, 2)
        self.assertEqual(router.metrics['evidence_checks'], 3)
        self.assertEqual(router.metrics['coverage_rejections'], 1)

    def test_done_cannot_complete_using_only_global_verified_and_model_claims(self):
        task = 'Write /fixture/a.txt with A.'
        first = {'status': 'act', 'requirements': [requirement(task, path='/fixture/a.txt', content='A')],
                 'action': write()}
        client, router = self.run_task(task, [first, {'status': 'done', 'remaining_requirements': []},
                                             {'verified': True}, audit])
        self.assertEqual(client.prompt_calls, 4)
        self.assertEqual(router.metrics['repairs'], 1)
        self.assertEqual(len(self.actions), 1)

    def test_exact_read_shortcut_has_zero_requests_preserves_whitespace_and_binary(self):
        for content in [' A\n', '']:
            client, _ = self.run_task('Read file "/fixture/a.txt"', [], initial_files={'/fixture/a.txt': content})
            self.assertEqual(client.prompt_calls, 0)
            self.assertEqual(self.events[-1][0], 'complete')
            self.assertTrue(any(kind == 'request_metrics' for kind, _ in self.events[:-1]))
            output = next(fields['content'] for kind, fields in self.events if kind == 'output')
            self.assertEqual(output, content)

    def test_truncated_local_read_never_reports_completion(self):
        task = 'Read file "/fixture/a.txt"'
        with mock.patch.object(runtime, 'find_openclaw'), mock.patch.object(runtime, 'prepare_runtime'), \
             mock.patch.object(runtime, 'bridge_call', return_value=read_result('/fixture/a.txt', 'prefix', truncated=True)), \
             mock.patch.object(runtime, 'emit') as emit, mock.patch.object(runtime, 'ACPClient') as client:
            with self.assertRaisesRegex(RuntimeError, 'incomplete'): runtime.run_task(task, 1, 'fixture', '')
        client.assert_not_called()
        self.assertFalse(any(c.args[0] == 'complete' for c in emit.call_args_list))

    def test_exact_largest_shortcut_has_zero_calls_and_cannot_drop_additional_instructions(self):
        with mock.patch.object(runtime, 'find_openclaw'), mock.patch.object(runtime, 'prepare_runtime'), \
             mock.patch.object(runtime, 'largest_top_level_file', return_value={'name': 'fixture.txt', 'bytes': 3}), \
             mock.patch.object(runtime, 'emit') as emit, mock.patch.object(runtime, 'ACPClient') as client:
            runtime.run_task('What is the largest file in Downloads?', 1, 'fixture', '')
        client.assert_not_called(); self.assertTrue(any(c.args[0] == 'complete' for c in emit.call_args_list))
        self.assertFalse(runtime.is_largest_downloads_file_task('Find the largest file in Downloads and delete it'))

    def test_empty_observation_prompt_including_new_contract_stays_bounded(self):
        for task in ['Click Save', 'Create todo.txt on my Desktop saying buy milk',
                     'Run git status in ~/project', 'Search the web for TaskPilot docs']:
            prompt = runtime.desktop_instruction(task, {'elements': [], 'applications': []}, [], TaskEvidenceLedger(task))
            self.assertLessEqual(len(prompt), 4000)
            self.assertIn(task, prompt)


if __name__ == '__main__': unittest.main()
