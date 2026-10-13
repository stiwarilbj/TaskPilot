"""Dependency checks use fictional observations and fake native delivery only."""
from copy import deepcopy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
from response_validation import ResponseValidationError, validate_response
from task_evidence import TaskEvidenceLedger, EvidenceValidationError, content_hash, digest

TASK = 'Select Draft, fill Title with Ready, verify the destination, and save it once.'


def observation(revision='now', value='', active='Draft', **field_changes):
    window = {'id': revision + ':window', 'pid': 42, 'role': 'AXWindow', 'title': 'Draft',
              'window_title': 'Draft', 'native_identity': 'window', 'enabled': True}
    field = {'id': revision + ':field', 'pid': 42, 'role': 'AXTextField', 'title': 'Title',
             'window_title': 'Draft', 'parent_id': window['id'], 'native_identity': 'title-field',
             'value': value, 'value_complete': True, 'enabled': True, **field_changes}
    return {'observation_revision': revision, 'applications': [{'pid': 42, 'name': 'Fixture',
             'bundle_id': 'example.fixture', 'topmost_on_agent_screen': True,
             'windows': [{'title': 'Draft', 'focused': active == 'Draft', 'topmost_on_agent_screen': active == 'Draft'},
                         {'title': 'Other', 'focused': active == 'Other', 'topmost_on_agent_screen': active == 'Other'}]}],
            'elements': [window, field]}


def req(check, depends=(), scope='outcome', task=TASK):
    return {'source': task, 'description': check['type'], 'check': check,
            'depends_on': list(depends), 'scope': scope}


def requirements():
    return [req({'type': 'window_active', 'pid': 42, 'title': 'Draft'}, scope='prerequisite'),
            req({'type': 'field_value', 'element_id': 'now:field', 'value': 'Ready'}, ['r1'], 'prerequisite'),
            req({'type': 'file_contents', 'path': '/fixture/result.txt', 'content': 'Ready'}, ['r2'])]


def decision(identifier='r2', element='now:field'):
    return {'status': 'act', 'requirement_ids': [identifier],
            'action': {'type': 'set_value', 'element_id': element, 'text': 'Ready'}}


def proof(ledger):
    return {'verified': True, 'coverage_complete': True, 'message': 'Verified fixture result', 'proofs': [
        {'requirement_id': key, 'evidence_ids': [next(ref for ref, evidence in reversed(list(ledger.evidence.items()))
         if ledger.requirement_matches(key, evidence, semantic=True))], 'rationale': 'Exact local fixture proof'}
        for key in ledger.requirements]}


class DependencyTests(unittest.TestCase):
    def ledger(self, obs=None):
        obs = obs or observation()
        ledger = TaskEvidenceLedger(TASK, 'fixture-generation')
        ledger.observe(obs)
        ledger.add_requirements(requirements(), obs)
        return ledger

    def test_graph_accepts_forward_references_and_stable_ids(self):
        ledger = TaskEvidenceLedger(TASK)
        a, b = req({'type': 'file_exists', 'path': '/fixture/a'}, ['r2']), req({'type': 'file_exists', 'path': '/fixture/b'})
        ledger.add_requirements([a, b])
        ledger.add_requirements([b, a])
        self.assertEqual(list(ledger.requirements), ['r1', 'r2'])
        self.assertEqual(ledger.requirements['r1']['depends_on'], ['r2'])
        self.assertEqual(ledger.requirements['r1']['check']['path'], '/fixture/a')

    def test_unknown_self_and_cyclic_graphs_are_transactionally_rejected(self):
        for refs, error in [(['r99'], 'checklist'), (['r1'], 'itself')]:
            ledger = TaskEvidenceLedger(TASK)
            with self.assertRaisesRegex(EvidenceValidationError, error):
                ledger.add_requirements([req({'type': 'file_exists', 'path': '/fixture/a'}, refs)])
            self.assertFalse(ledger.requirements)
        ledger = TaskEvidenceLedger(TASK)
        ledger.add_requirements([req({'type': 'file_exists', 'path': '/fixture/a'})])
        before = deepcopy(ledger.requirements)
        with self.assertRaisesRegex(EvidenceValidationError, 'acyclic'):
            ledger.add_requirements([req({'type': 'file_exists', 'path': '/fixture/a'}, ['r2']),
                                     req({'type': 'file_exists', 'path': '/fixture/b'}, ['r1'])])
        self.assertEqual(ledger.requirements, before)

    def test_edges_are_additive_and_prose_cannot_remove_a_guard(self):
        ledger = self.ledger()
        altered = requirements()[2]
        altered['description'] = 'Renamed to bypass the earlier prerequisite'
        altered['depends_on'] = []
        ledger.add_requirements([altered])
        self.assertEqual(len(ledger.requirements), 3)
        self.assertEqual(ledger.requirements['r3']['depends_on'], ['r2'])
        altered['scope'] = 'prerequisite'
        with self.assertRaisesRegex(EvidenceValidationError, 'scope'):
            ledger.add_requirements([altered])

    def test_metadata_errors_use_precise_paths_before_execution(self):
        ledger = TaskEvidenceLedger(TASK)
        cases = [({'depends_on': True}, 'requirements[0].depends_on'),
                 ({'depends_on': ['r1', 'r1']}, 'requirements[0].depends_on'),
                 ({'depends_on': [1]}, 'requirements[0].depends_on'),
                 ({'scope': False}, 'requirements[0].scope')]
        for fields, path in cases:
            with self.subTest(fields=fields), self.assertRaises(ResponseValidationError) as error:
                validate_response({'status': 'act', 'action': {'type': 'read_file', 'path': '/fixture/a'},
                    'requirements': [{**req({'type': 'file_exists', 'path': '/fixture/a'}), **fields}]}, 'planning', ledger=ledger)
            self.assertIn(path, str(error.exception))
        ledger = self.ledger()
        for value in [None, [], ['r99'], ['r2', 'r2'], [True]]:
            item = decision()
            if value is None: del item['requirement_ids']
            else: item['requirement_ids'] = value
            with self.subTest(value=value), self.assertRaisesRegex(ResponseValidationError, 'requirement_ids'):
                validate_response(item, 'planning', observation(), ledger)

    def test_wrong_document_blocks_edits_even_if_completion_flags_claim_success(self):
        ledger = self.ledger(observation(active='Other'))
        plan = {**decision(), 'completed_requirements': ['r1'], 'remaining_requirements': []}
        validate_response(plan, 'planning', observation(active='Other'), ledger)
        self.assertEqual(ledger.check_prerequisites(plan)['blocked_by'], ['r1'])
        self.assertEqual(ledger.requirements['r1']['state'], 'pending')
        ledger.observe(observation('new', active='Draft'))
        self.assertIsNone(ledger.check_prerequisites(decision(element='new:field')))

    def test_initially_filled_field_does_not_bypass_unproven_ancestor(self):
        ledger = self.ledger(observation(value='Ready', active='Other'))
        save = {'status': 'act', 'requirement_ids': ['r3'], 'action': {'type': 'write_file', 'path': '/fixture/result.txt', 'content': 'Ready'}}
        blocked = ledger.check_prerequisites(save)
        self.assertIn('r1', blocked['blocked_by'])
        self.assertEqual(ledger.requirements['r2']['state'], 'pending')

    def test_historical_preconditions_survive_submission_but_do_not_unlock_new_edits(self):
        ledger = self.ledger()
        self.assertIsNone(ledger.check_prerequisites(decision(), retain=True))
        ledger.before_action(decision()['action'])
        ledger.observe(observation('filled', value='Ready'))
        save = {'status': 'act', 'requirement_ids': ['r3'], 'action': {'type': 'write_file', 'path': '/fixture/result.txt', 'content': 'Ready'}}
        self.assertIsNone(ledger.check_prerequisites(save, retain=True))
        ledger.before_action(save['action'])
        action = save['action']
        ledger.record_action(action, {'path': action['path'], 'mode': 'overwrite', 'verified': True,
            'bytes_written': 5, 'content_sha256': content_hash(action)})
        after = observation('closed', active='Other'); after['elements'] = []
        ledger.observe(after)
        self.assertEqual([r['state'] for r in ledger.requirements.values()], ['proven'] * 3)
        final = proof(ledger)
        validate_response(final, 'verification', after, ledger)
        self.assertTrue(ledger.audit(final))
        self.assertEqual(ledger.check_prerequisites(decision(element='closed:field'))['blocked_by'], ['r1'])

    def test_stale_incomplete_disabled_and_changed_field_values_do_not_unlock_submission(self):
        ledger = self.ledger()
        ledger.check_prerequisites(decision(), retain=True)
        save = {'status': 'act', 'requirement_ids': ['r3'], 'action': {'type': 'write_file', 'path': '/fixture/result.txt', 'content': 'Ready'}}
        for fields in [{'value': 'wrong'}, {'value': 'Ready', 'value_complete': False},
                       {'value': 'Ready', 'enabled': False}, {'value': 'Ready', 'native_identity': 'other-field'},
                       {'value': 'Ready', 'subrole': 'AXSecureTextField'}]:
            with self.subTest(fields=fields):
                ledger.observe(observation('changed', **fields))
                self.assertIn('r2', ledger.check_prerequisites(save)['blocked_by'])
        ledger.observe(observation('ready', value='Ready'))
        self.assertIsNone(ledger.check_prerequisites(save))

    def test_duplicate_field_candidates_and_application_replacement_are_unproven(self):
        ledger = self.ledger()
        ledger.check_prerequisites(decision(), retain=True)
        obs = observation('ambiguous', value='Ready')
        duplicate = {**obs['elements'][1], 'id': 'ambiguous:second', 'native_identity': 'second'}
        # Both have the same structural label; no native identity was available when bound.
        original = observation(); original['elements'][1].pop('native_identity')
        ledger = self.ledger(original); ledger.check_prerequisites(decision(), retain=True)
        obs['elements'].append(duplicate); ledger.observe(obs)
        self.assertEqual(ledger.requirements['r2']['state'], 'pending')
        obs = observation('replaced', value='Ready'); obs['applications'][0]['bundle_id'] = 'example.other'
        ledger.observe(obs)
        self.assertEqual(ledger.requirements['r2']['state'], 'pending')

    def test_target_binding_prevents_typing_into_another_field_or_omitting_the_target(self):
        ledger = self.ledger()
        for action in [{'type': 'set_value', 'element_id': 'now:window', 'text': 'Ready'},
                       {'type': 'type_text', 'pid': 42, 'text': 'Ready'}]:
            blocked = ledger.check_prerequisites({**decision(), 'action': action})
            self.assertEqual(blocked['reason'], 'action_requirement_target_mismatch')
        self.assertIsNone(ledger.check_prerequisites(decision()))  # Value may be different before the edit.

    def test_window_prerequisite_also_rejects_controls_in_another_document(self):
        obs = observation()
        obs['elements'].append({'id': 'now:other', 'pid': 42, 'role': 'AXButton', 'enabled': True, 'window_title': 'Other'})
        ledger = TaskEvidenceLedger(TASK); ledger.observe(obs)
        ledger.add_requirements([requirements()[0], req({'type': 'visual', 'expected': 'Draft edited'}, ['r1'])])
        blocked = ledger.check_prerequisites({'status': 'act', 'requirement_ids': ['r2'],
                                             'action': {'type': 'press', 'element_id': 'now:other'}})
        self.assertEqual(blocked['reason'], 'prerequisite_target_mismatch')

    def test_fresh_control_ids_reuse_the_requirement_without_rebinding_another_field(self):
        ledger = self.ledger()
        fresh = observation('new')
        ledger.observe(fresh)
        entries = requirements(); entries[1]['check']['element_id'] = 'new:field'
        ledger.add_requirements(entries, fresh)
        self.assertEqual(list(ledger.requirements), ['r1', 'r2', 'r3'])
        self.assertEqual(ledger.requirements['r2']['check']['element_id'], 'now:field')
        self.assertIsNone(ledger.check_prerequisites(decision(element='new:field')))

    def test_file_dependency_preflight_rechecks_destination_with_zero_generation_calls(self):
        ledger = TaskEvidenceLedger(TASK)
        ledger.add_requirements([req({'type': 'directory_exists', 'path': '/fixture/destination'}, scope='prerequisite'),
                                 req({'type': 'file_contents', 'path': '/fixture/destination/a', 'content': 'A'}, ['r1'])])
        plan = {'status': 'act', 'requirement_ids': ['r2'], 'action': {'type': 'write_file', 'path': '/fixture/destination/a', 'content': 'A'}}
        for available in [False, True, False]:
            result = {'requested_checks': [ledger.requirements['r1']['check']], 'checks': [
                {'type': 'directory_exists', 'path': '/fixture/destination', 'verified': available}]}
            with mock.patch.object(runtime, 'bridge_call', return_value=result) as bridge, mock.patch.object(runtime, 'routed_json_prompt') as model:
                metrics = {}; blocked = runtime.prepare_dependency_action(plan, 1, ledger, metrics)
                self.assertEqual(blocked is None, available)
                self.assertEqual(metrics['dependency_checks'], 1)
                bridge.assert_called_once_with('check_effect', 1, check=ledger.requirements['r1']['check'])
                model.assert_not_called()
        self.assertEqual(ledger.requirements['r1']['state'], 'proven')  # Historical proof retained, gate still refused stale state.

    def test_relabeling_a_file_mutation_does_not_bypass_its_dependency(self):
        ledger = TaskEvidenceLedger(TASK)
        ledger.add_requirements([req({'type': 'directory_exists', 'path': '/fixture/destination'}),
                                 req({'type': 'file_contents', 'path': '/fixture/destination/a', 'content': 'A'}, ['r1'])])
        plan = {'status': 'act', 'requirement_ids': ['r1'], 'action': {'type': 'write_file', 'path': '/fixture/destination/a', 'content': 'A'}}
        self.assertEqual(ledger.action_requirements(plan), ['r1', 'r2'])
        self.assertEqual(ledger.check_prerequisites(plan)['blocked_by'], ['r1'])

    def test_unknown_visual_claims_and_cross_task_evidence_do_not_unlock_actions(self):
        ledger = TaskEvidenceLedger(TASK, 'task-a')
        ledger.add_requirements([req({'type': 'visual', 'expected': 'Correct document'}, scope='prerequisite'),
                                 req({'type': 'file_exists', 'path': '/fixture/a'}, ['r1'])])
        ledger.observe({'observation_revision': 'now'})
        ledger.accept_plan({'completed_requirements': ['r1'], 'proofs': [{'requirement_id': 'r1', 'evidence_ids': ['e1'], 'rationale': 'claimed'}]})
        plan = {'status': 'act', 'requirement_ids': ['r2'], 'action': {'type': 'write_file', 'path': '/fixture/a', 'content': 'A'}}
        self.assertEqual(ledger.check_prerequisites(plan)['blocked_by'], ['r1'])
        ledger.add_evidence({'type': 'prerequisite_checked', 'requirement_id': 'r1', 'check_fingerprint': digest(ledger.requirements['r1']['check'])})
        ledger.evidence['e2']['generation'] = 'task-b'
        self.assertFalse(ledger.requirement_matches('r1', ledger.evidence['e2']))

    def test_dependency_changes_invalidate_coverage_and_cache_identity(self):
        ledger = TaskEvidenceLedger(TASK)
        entries = [req({'type': 'file_exists', 'path': '/fixture/a'}), req({'type': 'file_exists', 'path': '/fixture/b'})]
        ledger.add_requirements(entries); before = ledger.fingerprint(); ledger.coverage_complete = True
        entries[1]['depends_on'] = ['r1']; ledger.add_requirements([entries[1]])
        self.assertNotEqual(ledger.fingerprint(), before)
        self.assertFalse(ledger.coverage_complete)
        self.assertEqual(ledger.prompt_state()['requirements']['r2']['depends_on'], ['r1'])

    def test_graphics_window_metadata_can_prove_the_selected_window_without_ax_controls(self):
        obs = observation(); obs['elements'] = []
        obs['applications'][0]['windows'] = [{'source': 'core_graphics', 'frame': {}}]
        obs['applications'][0]['graphics_windows'] = [{'id': 12, 'title': 'Draft'}, {'id': 13, 'title': 'Other'}]
        ledger = TaskEvidenceLedger(TASK); ledger.observe(obs)
        ledger.add_requirements([requirements()[0], req({'type': 'file_exists', 'path': '/fixture/a'}, ['r1'])])
        self.assertEqual(ledger.requirements['r1']['state'], 'proven')
        changed = deepcopy(obs); changed['observation_revision'] = 'changed'
        changed['applications'][0]['graphics_windows'].reverse(); ledger.observe(changed)
        self.assertEqual(ledger.requirements['r1']['state'], 'invalidated')

    def test_final_audit_can_add_an_outcome_without_weakening_historical_prerequisites(self):
        ledger = TaskEvidenceLedger(TASK)
        earlier = req({'type': 'file_contents', 'path': '/fixture/a', 'content': 'A'}, scope='prerequisite')
        ledger.add_requirements([earlier, req({'type': 'file_contents', 'path': '/fixture/b', 'content': 'B'}, ['r1'])])
        ledger.add_evidence({'type': 'file_contents', 'path': '/fixture/a', 'content_sha256': content_hash(earlier['check'])}, mutable=True)
        ledger.check_prerequisites({'status': 'act', 'requirement_ids': ['r2'],
                                   'action': {'type': 'write_file', 'path': '/fixture/b', 'content': 'B'}}, retain=True)
        ledger.invalidate(lambda e: e['mutable'])
        uncovered = {'verified': False, 'uncovered_requirements': [{**earlier, 'scope': 'outcome'}]}
        validate_response(uncovered, 'verification', ledger=ledger)
        self.assertFalse(ledger.audit(uncovered))
        self.assertEqual(ledger.requirements['r1']['scope'], 'prerequisite')
        self.assertEqual(ledger.requirements['r3']['scope'], 'outcome')
        self.assertEqual(ledger.requirements['r3']['state'], 'pending')
        self.assertFalse(ledger.can_complete())

    def test_wait_and_existing_dependency_free_decisions_remain_compatible(self):
        ledger = self.ledger()
        validate_response({'status': 'act', 'action': {'type': 'wait', 'seconds': 1}}, 'planning', observation(), ledger)
        independent = TaskEvidenceLedger(TASK)
        validate_response({'status': 'act', 'action': {'type': 'write_file', 'path': '/fixture/a', 'content': 'A'},
            'requirements': [req({'type': 'file_contents', 'path': '/fixture/a', 'content': 'A'})]}, 'planning', ledger=independent)

    def test_prompt_dependency_example_is_valid_json_when_bound_to_fixture_targets(self):
        obs = observation()
        obs['elements'].append({'id': 'now:save', 'pid': 42, 'role': 'AXButton', 'title': 'Save',
                                'enabled': True, 'window_title': 'Draft'})
        ledger = TaskEvidenceLedger(TASK); ledger.observe(obs)
        prompt = runtime.desktop_instruction(TASK, obs, [], ledger)
        example = json.loads(next(line for line in prompt.splitlines() if line.startswith('{"action"')))
        self.assertEqual(example['requirement_ids'], ['r2'])
        self.assertEqual(example['requirements'][1]['depends_on'], ['r1'])
        example['action']['element_id'] = 'now:save'
        example['expected_result']['pid'] = 42
        for item in example['requirements']: item['source'] = TASK
        example['requirements'][0]['check'].update(pid=42, title='Draft')
        response = validate_response(example, 'planning', obs, ledger)
        ledger.accept_plan(response, obs)
        self.assertIsNone(ledger.check_prerequisites(response))

    def test_bound_input_refs_resolve_in_preconditions_but_cannot_forge_graph_ids(self):
        task = 'Select "Draft" and type "Ready".'
        obs = observation(); ledger = TaskEvidenceLedger(task); ledger.observe(obs)
        def ref(value): return {'input_ref': next(e.identifier for e in ledger.inputs.entries if e.value == value)}
        entries = [req({'type': 'window_active', 'pid': 42, 'title': ref('Draft')}, scope='prerequisite', task=task),
                   req({'type': 'field_value', 'element_id': 'now:field', 'value': ref('Ready')}, ['r1'], task=task)]
        value = {**decision(), 'requirements': entries}
        response = validate_response(value, 'planning', obs, ledger)
        self.assertEqual(response['requirements'][1]['check']['value'], 'Ready')
        self.assertEqual(response['requirements'][0]['check']['title'], 'Draft')
        ledger.accept_plan(response, obs)
        self.assertIsNone(ledger.check_prerequisites(response))
        value['requirement_ids'] = [ref('Draft')]
        with self.assertRaisesRegex(ResponseValidationError, 'cannot use an input reference'):
            validate_response(value, 'planning', obs, ledger)


class DependencyRuntimeTests(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'PromptRegression'))
        import evaluate, fixtures
        self.evaluator, self.fixtures = evaluate, fixtures

    def case(self, premature=False):
        f = self.fixtures
        field = f.control('field', 'Title', 'AXTextField', value='', focused=True)
        submit = f.control('submit', 'Submit')
        task = 'In Fixture App, select Draft, fill Title with Ready, then submit once and verify Submitted.'
        entries = [req({'type': 'window_active', 'pid': 42, 'title': 'Draft'}, scope='prerequisite', task=task),
                   req({'type': 'field_value', 'element_id': '$field', 'value': 'Ready'}, ['r1'], 'prerequisite', task),
                   req({'type': 'dialog_present', 'pid': 42, 'title': 'Submitted'}, ['r2'], task=task)]
        enter = {'status': 'act', 'requirements': entries, 'requirement_ids': ['r2'],
                 'action': {'type': 'set_value', 'element_id': '$field', 'text': 'Ready'}}
        send = {'status': 'act', 'requirement_ids': ['r3'], 'action': {'type': 'press', 'element_id': '$submit'}}
        case = f.case('dependency-fixture', 'healthy', {
            'initial': f.state(field, submit), 'filled': f.state({**field, 'value': 'Ready'}, submit),
            'saved': f.state(f.control('receipt', 'Submitted', 'AXDialog'))}, [
            f.transition('initial', {'type': 'set_value', 'element_id': '$field', 'text': 'Ready'}, 'filled'),
            f.transition('filled', {'type': 'press', 'element_id': '$submit'}, 'saved', {'saved': 1})], [], [], '')
        case['task'] = task
        script = [enter, send, f.DONE, f.YES]
        if premature: script.insert(0, {**send, 'requirements': entries})
        return case, script

    def test_healthy_decisions_add_no_calls_and_submit_once_after_native_field_proof(self):
        case, script = self.case()
        result, requests = self.evaluator.replay_case(case, self.evaluator.prompt_pack(), script=script)
        self.assertTrue(result['success'], result)
        self.assertEqual(result['planning'], 3)
        self.assertEqual(result['verification'], 1)
        self.assertEqual(result['requests'], 4)
        self.assertEqual(result['repairs'], 0)
        self.assertEqual(result['delivered_actions'], 2)
        self.assertEqual(result['incorrect_action_attempts'], 0)
        self.assertEqual(result['duplicate_actions'], 0)
        replay, _ = self.evaluator.replay_case(case, self.evaluator.prompt_pack(), requests=requests)
        self.assertTrue(replay['success'], replay)

    def test_premature_submission_is_never_dispatched_and_recovers_through_prerequisite(self):
        case, script = self.case(premature=True)
        result, _ = self.evaluator.replay_case(case, self.evaluator.prompt_pack(), script=script)
        self.assertTrue(result['success'], result)
        self.assertEqual(result['planning'], 4)
        self.assertEqual(result['repairs'], 0)  # Unproven state is not a provider/format failure.
        self.assertEqual(result['delivered_actions'], 2)
        self.assertEqual(result['incorrect_action_attempts'], 0)
        self.assertEqual(result['duplicate_actions'], 0)

    def test_repeated_unproven_submission_stops_without_any_native_action(self):
        case, script = self.case(premature=True)
        result, _ = self.evaluator.replay_case(case, self.evaluator.prompt_pack(), script=[script[0]] * 3)
        self.assertFalse(result['success'])
        self.assertEqual(result['requests'], 3)
        self.assertEqual(result['delivered_actions'], 0)
        self.assertEqual(result['incorrect_action_attempts'], 0)
        self.assertEqual(result['repairs'], 0)

    def test_graph_validation_uses_existing_single_repair_before_one_execution(self):
        case, script = self.case()
        bad = deepcopy(script[0]); bad['requirements'][1]['depends_on'] = ['r99']
        result, requests = self.evaluator.replay_case(case, self.evaluator.prompt_pack(), script=[bad, *script])
        self.assertTrue(result['success'], result)
        self.assertEqual(result['repairs'], 1)
        self.assertEqual(result['planning'], 4)
        self.assertEqual(result['delivered_actions'], 2)
        self.assertEqual(result['duplicate_actions'], 0)
        self.assertEqual(requests[0]['model'], requests[1]['model'])
        self.assertEqual(requests[0]['image_sha256'], requests[1]['image_sha256'])
        self.assertTrue(requests[1]['repair'])


if __name__ == '__main__': unittest.main()
