"""Contradictory evidence tests use synthetic screens and fake native reads."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
from evidence_fixtures import native_result, native_batch
import openclaw_runtime as runtime
from evidence_consistency import EvidenceConsistency, normalize, screen_conflicts
from response_validation import ResponseValidationError, validate_response
from task_evidence import TaskEvidenceLedger, content_hash
from action_contract_generated import NativeProtocolError
from test_local_text_recognition import observation as text_observation
from test_response_validation import FakeClient
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'PromptRegression'))
import evaluate as regression
from fixtures import case, state, control, transition, act, DONE, YES, VERIFIED


TASK = 'In Editor, save the Draft exactly once.'
PATH = '/fixture/result.txt'


def observation(revision='current', title='Save', text='Delete', role='AXButton', **fields):
    result = text_observation(False)
    result.update(observation_revision=revision)
    result['coordinate_mapping']['observation_revision'] = revision
    result['text_recognition'].update(observation_revision=revision)
    result['text_recognition']['targets'][0].update(candidate_id=revision + ':text:0', text=text)
    result['applications'][0].update(bundle_id='example.editor')
    result['applications'][0]['graphics_windows'][0]['title'] = 'Draft'
    result['elements'] = [dict(id=revision + ':save', native_identity='save', pid=42, role=role,
        title=title, window_title='Draft', frame=dict(x=140, y=80, width=180, height=60), enabled=True, **fields)]
    result['observation_completeness']['collected_controls'] = 1
    return result


def plan(obs, **fields):
    return dict(status='act', action=dict(type='press', element_id=obs['elements'][0]['id']), **fields)


def read_result(content='Ready', **changes):
    return native_result({'type':'read_file', 'path':PATH}, content=content, **changes)


def checked(check, verified, reason='The requested outcome did not match'):
    actual = dict(type=check['type'], path=check['path'], verified=verified)
    if verified and check['type'] == 'file_contents': actual['content_sha256'] = content_hash(check)
    if not verified: actual['reason'] = reason
    return native_batch([deepcopy(check)], [actual])


class Inspection:
    def __init__(self, observations, reads=(), latency=0):
        self.observations, self.reads = list(observations), list(reads)
        self.now = 0.0; self.calls = []; self.discarded = []; self.latency = latency

    def observe(self, pid, budget):
        self.calls.append(('observe', pid, budget)); self.now += self.latency
        value = self.observations[min(sum(c[0] == 'observe' for c in self.calls)-1, len(self.observations)-1)]
        if isinstance(value, BaseException): raise value
        return deepcopy(value)

    def read(self, method, payload):
        self.calls.append((method, deepcopy(payload)))
        value = self.reads.pop(0)
        if isinstance(value, BaseException): raise value
        return deepcopy(value)

    def sleep(self, seconds): self.now += seconds

    def run(self, guard, conflicts, before, ledger):
        return guard.inspect(conflicts, before, ledger, self.observe, self.read,
            lambda obs: self.discarded.append(obs['observation_revision']) if obs else None,
            lambda: self.now, self.sleep)


class EvidenceConsistencyTests(unittest.TestCase):
    def ledger(self, obs, task=TASK):
        ledger = TaskEvidenceLedger(task, 'fixture-generation')
        ledger.observe(obs)
        return ledger

    def test_high_confidence_conflict_is_bound_to_target_and_coordinate_click(self):
        obs = observation(); guard = EvidenceConsistency(); ledger = self.ledger(obs)
        conflict = guard.conflicts(plan(obs), obs, ledger)[0]
        self.assertEqual(conflict['sources'][0]['labels'], ['Save'])
        self.assertEqual(conflict['sources'][1]['text'], 'Delete')
        self.assertEqual(conflict['target']['id'], 'current:save')
        self.assertEqual(guard.conflicts(dict(status='act', action=dict(type='click', pid=42, x=150, y=125)), obs, ledger)[0], conflict)

    def test_identical_partial_alias_and_low_confidence_text_are_not_conflicts(self):
        self.assertEqual(normalize('  ＳＡＶＥ… '), 'save')
        self.assertEqual(normalize('Straße'), normalize('STRASSE'))
        for title, text, confidence in [('Save', 'Save', .99), ('Save…', 'ＳＡＶＥ', .99),
                ('Save Report', 'Save', .99), ('Save', 'Delete', .8), ('Save', 'Delete', .899)]:
            obs = observation(title=title, text=text)
            obs['text_recognition']['targets'][0]['confidence'] = confidence
            self.assertEqual(screen_conflicts(obs['elements'][0], obs), [], (title, text, confidence))
        obs = observation(); obs['elements'][0]['label'] = 'Delete'
        self.assertEqual(screen_conflicts(obs['elements'][0], obs), [])

    def test_different_app_window_noncontained_text_or_overlapping_labels_are_inconclusive(self):
        variants = []
        other = observation(); other['elements'][0]['pid'] = 43; variants.append(other)
        other = observation(); other['elements'][0]['window_title'] = 'Other'; variants.append(other)
        other = observation(); other['elements'][0]['frame']['width'] = 10; variants.append(other)
        for identities in [('save', 'other'), (None, None)]:
            other = observation(); other['elements'][0]['native_identity'] = identities[0]
            other['elements'].append({**other['elements'][0], 'id': 'current:other', 'native_identity': identities[1]})
            variants.append(other)
        for obs in variants: self.assertEqual(screen_conflicts(obs['elements'][0], obs), [])

    def test_two_consistent_fresh_reads_resolve_but_discard_original_decision(self):
        before = observation(); guard = EvidenceConsistency(); ledger = self.ledger(before)
        io = Inspection([observation('fresh1', text='Save'), observation('fresh2', text='Save')])
        current, report = io.run(guard, guard.conflicts(plan(before), before, ledger), before, ledger)
        self.assertEqual(report['outcome'], 'rejected'); self.assertEqual(report['delivery'], 'not_dispatched')
        self.assertEqual(report['resolution'], 'consistent_fresh_reads')
        self.assertEqual(report['inspection_count'], 2); self.assertEqual(current['observation_revision'], 'fresh2')
        self.assertEqual(io.discarded, ['fresh1']); self.assertEqual(guard.pending, [])
        self.assertEqual(ledger.current_observation, current)
        self.assertTrue(all(c[1] == 42 and 0 < c[2] <= 2000 for c in io.calls))

    def test_missing_recognition_is_unconfirmed_and_pending_follows_new_revisions(self):
        before = observation(); guard = EvidenceConsistency(); ledger = self.ledger(before)
        fresh = observation('fresh', text='Save')
        fresh['text_recognition'].update(state='not_needed', targets=[])
        io = Inspection([fresh])
        current, report = io.run(guard, guard.conflicts(plan(before), before, ledger), before, ledger)
        self.assertEqual(report['resolution'], 'unresolved'); self.assertEqual(report['inspection_count'], 3)
        self.assertEqual(len(guard.conflicts(plan(current), current, ledger)), 1)
        self.assertEqual(len(io.calls), 3)

    def test_unresolved_field_is_still_checked_before_completion_without_label_keyword(self):
        before = observation(role='AXTextField', title='Title', text='Delete', value='Ready', value_complete=True)
        guard = EvidenceConsistency(); ledger = self.ledger(before)
        fresh = observation('fresh', role='AXTextField', title='Title', text='Delete', value='Ready', value_complete=True)
        current, report = Inspection([fresh]).run(guard, guard.conflicts(plan(before), before, ledger), before, ledger)
        self.assertEqual(report['resolution'], 'unresolved')
        # "Title" never appears in this original request. The previous target,
        # rather than keyword ranking, keeps its unresolved conflict relevant.
        self.assertTrue(guard.conflicts(dict(status='done'), current, ledger))

    def test_changed_missing_ambiguous_and_moving_targets_do_not_resolve(self):
        before = observation()
        missing = observation('gone', text='Save'); missing['elements'] = []
        replaced = observation('other', text='Save'); replaced['elements'][0]['native_identity'] = 'other'
        foreign = observation('foreign', text='Save'); foreign['applications'][0]['bundle_id'] = 'example.other'
        for fresh in [missing, replaced, foreign]:
            guard = EvidenceConsistency(); ledger = self.ledger(before); io = Inspection([fresh])
            _, report = io.run(guard, guard.conflicts(plan(before), before, ledger), before, ledger)
            self.assertEqual(report['resolution'], 'unresolved')
            self.assertEqual(report['refreshed_evidence'][0]['state'], 'target_missing_or_changed')
        moving = [observation('move'+str(i), text='Save') for i in range(3)]
        for i, fresh in enumerate(moving): fresh['elements'][0]['frame']['x'] += i
        guard = EvidenceConsistency(); ledger = self.ledger(before)
        _, report = Inspection(moving).run(guard, guard.conflicts(plan(before), before, ledger), before, ledger)
        self.assertEqual(report['resolution'], 'unresolved')

    def test_shared_deadline_limits_captures_and_does_not_fallback_or_act(self):
        before = observation(); guard = EvidenceConsistency(); ledger = self.ledger(before)
        io = Inspection([observation('fresh', text='Save')], latency=1.1)
        _, report = io.run(guard, guard.conflicts(plan(before), before, ledger), before, ledger)
        self.assertEqual(report['inspection_count'], 2)
        self.assertEqual(report['resolution'], 'unresolved')
        self.assertLess(io.calls[1][2], io.calls[0][2])
        self.assertTrue(all(c[0] == 'observe' for c in io.calls))

    def test_cancellation_and_foreign_task_discard_inspection_artifact(self):
        before = observation(); guard = EvidenceConsistency(); ledger = self.ledger(before)
        io = Inspection([observation('first', text='Save'), SystemExit(143)])
        with self.assertRaises(SystemExit): io.run(guard, guard.conflicts(plan(before), before, ledger), before, ledger)
        self.assertEqual(io.discarded, ['first'])
        foreign = observation('foreign', text='Save'); foreign['task_generation_id'] = 'other-task'
        io = Inspection([foreign])
        with self.assertRaisesRegex(ValueError, 'another task'):
            io.run(guard, guard.conflicts(plan(before), before, ledger), before, ledger)
        self.assertEqual(io.discarded, ['foreign'])

    def test_disagreement_metadata_is_strict_current_and_nonsecure(self):
        obs = observation(); ledger = self.ledger(obs)
        ledger.add_requirements([dict(source=TASK, description='Save the Draft', check=dict(type='visual', expected='Draft saved'))])
        marker = dict(element_id='current:save', screenshot_text='Delete')
        validate_response(plan(obs, evidence_disagreement=marker), 'planning', obs, ledger)
        for changes, error in [({'element_id': None}, 'element_id'), ({'element_id': {}}, 'element_id'),
                ({'element_id': 'old:save'}, 'element_id'), ({'screenshot_text': 2}, 'screenshot_text'),
                ({'screenshot_text': ''}, 'screenshot_text'), ({'screenshot_text': 'x'*257}, 'screenshot_text'),
                ({'screenshot_text': '\ud800'}, 'UTF-8'), ({'evidence_id': 'unknown'}, 'evidence_id'),
                ({'evidence_id': []}, 'evidence_id'), ({'extra': True}, 'only')]:
            with self.subTest(changes=changes), self.assertRaisesRegex(ResponseValidationError, error):
                validate_response(plan(obs, evidence_disagreement={**marker, **changes}), 'planning', obs, ledger)
        obs['elements'][0]['subrole'] = 'AXSecureTextField'
        with self.assertRaisesRegex(ResponseValidationError, 'nonsecure'):
            validate_response(plan(obs, evidence_disagreement=marker), 'planning', obs, ledger)

    def test_complete_field_value_conflicts_and_native_readback_are_reconciled_locally(self):
        before = observation(role='AXTextField', title='Title', text='Ready', value='Ready', value_complete=True)
        guard = EvidenceConsistency(); ledger = self.ledger(before)
        action = dict(type='set_value', element_id='current:save', text='Ready')
        guard.remember_native(action, before, dict(text_verification='matched'))
        changed = observation('changed', role='AXTextField', title='Title', text='Other', value='Other', value_complete=True)
        ledger.observe(changed)
        conflicts = guard.conflicts(dict(status='act', action=dict(type='key', pid=42, key='return')), changed, ledger)
        # Focus identifies the intended field for keyboard events.
        self.assertEqual(conflicts, [])
        changed['elements'][0]['focused'] = True
        conflicts = guard.conflicts(dict(status='act', action=dict(type='key', pid=42, key='return')), changed, ledger)
        self.assertIn('native_field_readback', [c['type'] for c in conflicts])
        _, report = Inspection([observation('one', role='AXTextField', title='Title', text='Other', value='Other', value_complete=True),
                                observation('two', role='AXTextField', title='Title', text='Other', value='Other', value_complete=True)]).run(guard, conflicts, changed, ledger)
        self.assertEqual(report['resolution'], 'consistent_fresh_reads')
        self.assertIsNone(guard.native_field)
        bad = observation(role='AXTextField', title='Title', text='Other', value='Ready', value_complete=True)
        self.assertEqual(len(screen_conflicts(bad['elements'][0], bad)), 1)
        bad['elements'][0]['value_complete'] = False
        self.assertEqual(screen_conflicts(bad['elements'][0], bad), [])
        literal = observation(role='AXTextField', title='Title', text='ready', value='Ready', value_complete=True)
        self.assertEqual(len(screen_conflicts(literal['elements'][0], literal)), 1)

    def test_reported_native_content_requires_new_complete_read_not_old_or_truncated_evidence(self):
        before = observation(title='Ready', text='Ready'); guard = EvidenceConsistency(); ledger = self.ledger(before)
        ledger.record_action(dict(type='read_file', path=PATH), read_result())
        evidence_id = next(k for k, e in ledger.evidence.items() if e['fact']['type'] == 'file_read')
        decision = plan(before, evidence_disagreement=dict(element_id='current:save', screenshot_text='Ready', evidence_id=evidence_id))
        conflicts = guard.conflicts(decision, before, ledger)
        for invalid in [dict(read_result(), content_sha256='wrong'), dict(read_result(), path='/fixture/other.txt')]:
            io = Inspection([observation('fresh', title='Ready', text='Ready')], [invalid]*3)
            with self.assertRaises(NativeProtocolError): io.run(guard, conflicts, before, ledger)
        for invalid in [dict(read_result(), truncated=True)]:
            io = Inspection([observation('fresh', title='Ready', text='Ready')], [invalid]*3)
            _, report = io.run(guard, conflicts, before, ledger)
            self.assertEqual(report['resolution'], 'unresolved')
            self.assertFalse(ledger.evidence[evidence_id]['valid'])
            self.assertIsNone(report['refreshed_evidence'][-1]['current_sha256'])
        io = Inspection([observation('one', title='Ready', text='Ready'), observation('two', title='Ready', text='Ready')], [read_result()]*2)
        _, report = io.run(guard, conflicts, before, ledger)
        self.assertEqual(report['resolution'], 'consistent_fresh_reads')
        self.assertEqual([c[0] for c in io.calls], ['observe', 'recheck', 'observe', 'recheck'])

    def test_explicit_negative_native_check_supersedes_proof_without_rerunning_mutation(self):
        before = observation(text='Save'); guard = EvidenceConsistency(); ledger = self.ledger(before)
        check = dict(type='file_contents', path=PATH, content='Ready')
        ledger.record_effect(check, checked(check, True)['checks'][0])
        prior = next(e for e in ledger.evidence.values() if e['fact']['type'] == 'file_contents')
        guard.note_native_check(check, checked(check, False), prior)
        conflicts = guard.conflicts(plan(before), before, ledger)
        self.assertEqual(conflicts[0]['type'], 'native_file_check')
        io = Inspection([observation('one', text='Save'), observation('two', text='Save')], [checked(check, False)]*2)
        _, report = io.run(guard, conflicts, before, ledger)
        self.assertEqual(report['resolution'], 'consistent_fresh_reads')
        self.assertFalse(prior['valid']); self.assertFalse(report['refreshed_evidence'][0]['verified'])
        self.assertTrue(all(c[0] in {'observe', 'check_effect'} for c in io.calls))
        self.assertTrue(all(c[1] is None for c in io.calls if c[0] == 'observe'))
        guard.note_native_check(check, checked(check, False, 'The requested outcome could not be inspected'), prior)
        self.assertFalse(guard.native_conflicts)
        with self.assertRaises(NativeProtocolError): guard.note_native_check(check, {'checks': []}, prior)

    def test_native_read_changes_need_two_new_matching_hashes_and_fail_closed_on_errors(self):
        before = observation(text='Save'); guard = EvidenceConsistency(); ledger = self.ledger(before)
        action = dict(type='read_file', path=PATH)
        ledger.record_action(action, read_result('Old'))
        prior = list(ledger.evidence.values())[-1]
        ledger.record_action(action, read_result('New'))
        guard.note_native_read(action, prior, list(ledger.evidence.values())[-1])
        conflicts = guard.conflicts(dict(status='done'), before, ledger)
        io = Inspection([observation('fresh', text='Save')], [read_result('New')]*2)
        _, report = io.run(guard, conflicts, before, ledger)
        self.assertEqual(report['resolution'], 'consistent_fresh_reads')
        self.assertEqual(report['inspection_count'], 2)
        self.assertFalse(prior['valid'])
        io = Inspection([observation('fresh', text='Save')], [runtime.ActionRejected('unavailable', 'read_failed')]*3)
        _, report = io.run(guard, conflicts, before, ledger)
        self.assertEqual(report['resolution'], 'unresolved')
        self.assertEqual(report['refreshed_evidence'][0]['inspection_error'], 'read_failed')
        io = Inspection([observation('fresh', text='Save')], [runtime.ActionRejected('permission', 'permission_denied')])
        with self.assertRaises(runtime.ActionRejected): io.run(guard, conflicts, before, ledger)

    def test_dependency_readback_queues_precise_conflict_and_leaves_requirement_unproven(self):
        before = observation(text='Save'); guard = EvidenceConsistency()
        task = 'Verify /fixture/result.txt contains Ready, then save the Draft.'
        ledger = self.ledger(before, task)
        check = dict(type='file_contents', path=PATH, content='Ready')
        ledger.add_requirements([dict(source=task, description='Destination contents', check=check, scope='prerequisite'),
            dict(source=task, description='Save once', check=dict(type='visual', expected='Draft saved'), depends_on=['r1'])])
        ledger.record_effect(check, checked(check, True)['checks'][0])
        with mock.patch.object(runtime, 'bridge_call', return_value=checked(check, False)) as bridge:
            blocked = runtime.prepare_dependency_action(plan(before, requirement_ids=['r2']), 1, ledger, {}, guard)
        self.assertEqual(blocked['blocked_by'], ['r1'])
        self.assertEqual(guard.native_conflicts[0]['sources'][1]['verified'], False)
        self.assertEqual(bridge.call_args.args[0], 'check_effect')

    def test_completion_conflict_prevents_verifier_and_verifier_marker_prevents_complete(self):
        for observed, verification in [(observation(), None), (observation(text='Save'),
                dict(verified=False, evidence_disagreement=dict(element_id='current:save', screenshot_text='Delete')))]:
            guard = EvidenceConsistency(); ledger = self.ledger(observed); history = []; metrics = {}
            router = mock.Mock(metrics=metrics)
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'original.png'; path.write_bytes(b'fixture')
                fresh_path = Path(directory) / 'fresh.png'; fresh_path.write_bytes(b'fixture')
                observed['screenshot_path'] = str(path)
                fresh = observation('fresh', text='Save'); fresh['screenshot_path'] = str(fresh_path)
                def bridge(method, display, **params):
                    self.assertEqual(method, 'observe')
                    return deepcopy(observed if 'consistency_budget_ms' not in params else fresh)
                with mock.patch.object(runtime, 'bridge_call', side_effect=bridge), \
                     mock.patch.object(runtime, 'routed_json_prompt', return_value=verification) as prompt, \
                     mock.patch.object(runtime, 'complete_from_decision') as complete, mock.patch.object(runtime, 'emit'):
                    self.assertFalse(runtime.verify_task_completion(TASK, dict(status='done'), 1, history, router, mock.Mock(), ledger, guard))
                self.assertEqual(prompt.call_count, int(verification is not None)); complete.assert_not_called()
                self.assertEqual(history[-1]['result']['error_code'], 'evidence_conflict')
                self.assertFalse(path.exists()); self.assertFalse(fresh_path.exists())

    def test_conflict_recovery_prompt_has_specific_sources_without_polluting_healthy_rules(self):
        obs = observation(); guard = EvidenceConsistency(); ledger = self.ledger(obs)
        _, report = Inspection([observation('fresh', text='Save')]).run(guard, guard.conflicts(plan(obs), obs, ledger), obs, ledger)
        healthy = runtime.desktop_instruction(TASK, obs, [], ledger)
        recovery = runtime.desktop_instruction(TASK, obs, [dict(action='evidence_inspection', result=report)], ledger)
        self.assertTrue(healthy.startswith('EXECUTION PHASE: planning'))
        self.assertNotIn('silently prefer one source', healthy)
        self.assertTrue(recovery.startswith('EXECUTION PHASE: recovery'))
        self.assertIn('silently prefer one source', recovery)
        for text in ('Delete', 'Save', 'refreshed_evidence', 'not_dispatched'): self.assertIn(text, recovery)
        self.assertNotIn('Do not call tools or propose executable actions', recovery)

    def test_startup_mismatch_stops_before_model_requests(self):
        configuration = dict(kind='runtime_configuration', gemini_api_key='', action_contract_hash=runtime.CONTRACT_HASH,
            action_contract_version=runtime.CONTRACT_VERSION, task_protocol_version=runtime.TASK_PROTOCOL_VERSION,
            task_generation_id='d0b9c0fc-01af-42f0-b749-1027c907a2cd', coordinate_mapping_version=runtime.COORDINATE_MAPPING_VERSION,
            observation_completeness_version=runtime.OBSERVATION_COMPLETENESS_VERSION, text_recognition_version=runtime.TEXT_RECOGNITION_VERSION)
        for version in (None, True, '1', 2):
            with mock.patch.object(runtime, 'runtime_line', return_value=json.dumps(dict(configuration, evidence_consistency_version=version))), \
                 mock.patch.object(runtime, '_task_generation_id'), \
                 mock.patch.object(runtime.ACPClient, 'prompt') as prompt:
                with self.assertRaisesRegex(RuntimeError, 'evidence inspection versions'):
                    runtime.read_runtime_configuration(require_generation=True)
                prompt.assert_not_called()

    def test_inspection_version_invalidates_validated_decision_cache_without_changing_repair_budget(self):
        obs = observation(text='Save')
        valid = json.dumps(dict(status='act', action=dict(type='wait', seconds=1)))
        client = FakeClient([valid, valid])
        router = runtime.AdaptiveModelRouter(lambda *a, **k: None, sleep=lambda _: None)
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(runtime, 'emit'), \
             mock.patch.object(runtime, 'bridge_call') as bridge:
            path = Path(directory) / 'fixture.png'; path.write_bytes(b'fixture')
            prompt = runtime.desktop_instruction(TASK, obs, [])
            first = runtime.routed_json_prompt(router, client, prompt, path, observation=obs)
            self.assertEqual(runtime.routed_json_prompt(router, client, prompt, path, observation=obs), first)
            with mock.patch.object(runtime, 'EVIDENCE_CONSISTENCY_VERSION', 2):
                self.assertEqual(runtime.routed_json_prompt(router, client, prompt, path, observation=obs), first)
        self.assertEqual(client.prompt_calls, 2); self.assertEqual(router.metrics['cache_hits'], 1)
        self.assertEqual(router.metrics['repairs'], 0); bridge.assert_not_called()

    def test_task_loop_discards_conflicted_click_then_executes_fresh_action_once(self):
        frame = dict(x=140, y=80, width=180, height=60)
        fixture = case('evidence-conflict', 'wrong_clicks',
            {'initial': state(control('save', 'Save', frame=frame)),
             'saved': state(control('saved', 'Draft saved', role='AXStaticText'))},
            [transition('initial', dict(type='press', element_id='$save'), 'saved', {'saved': 1})], [], [], '')
        original = regression.World
        worlds = []
        class ConflictWorld(original):
            def __init__(self, *args):
                super().__init__(*args); self.inspection_requests = []; self.action_observations = []; worlds.append(self)
            def bridge(self, method, display, **params):
                if method == 'act': self.action_observations.append(self.latest['observation_revision'])
                if method == 'observe':
                    if 'evidence_inspection_pid' in params: self.inspection_requests.append(params)
                    value = super().bridge(method, display, **params)
                    if self.state == 'initial':
                        text = observation(value['observation_revision'], text='Delete' if self.polls == 1 else 'Save')
                        for key in ('coordinate_mapping', 'display', 'text_recognition'):
                            value[key] = text[key]
                        value['applications'][0]['graphics_windows'] = text['applications'][0]['graphics_windows']
                    self.latest = deepcopy(value)
                    return value
                return super().bridge(method, display, **params)
        with mock.patch.object(regression, 'World', ConflictWorld):
            result, calls = regression.replay_case(fixture, regression.prompt_pack(), script=[act(), act(), DONE, YES])
        self.assertTrue(result['success'], result)
        self.assertEqual(result['incorrect_actions'], 0); self.assertEqual(result['duplicate_actions'], 0)
        self.assertEqual(worlds[0].delivered, 1)
        self.assertEqual(len(worlds[0].inspection_requests), 2)
        self.assertEqual(worlds[0].action_observations, ['frame-3'])
        self.assertEqual(len(calls), 4); self.assertFalse(any(c['repair'] for c in calls))

    def test_healthy_task_adds_no_inspections_or_calls_and_persistent_conflict_stops(self):
        fixture = case('healthy-evidence', 'healthy',
            {'initial': state(control('save', 'Save', frame=dict(x=140, y=80, width=180, height=60))),
             'saved': state(control('saved', 'Draft saved', role='AXStaticText'))},
            [transition('initial', dict(type='press', element_id='$save'), 'saved', {'saved': 1})], [], [], '')
        result, calls = regression.replay_case(fixture, regression.prompt_pack(), script=[act(), DONE, YES])
        self.assertTrue(result['success'], result); self.assertEqual(len(calls), 3)
        original = regression.World; worlds = []
        class ConflictedWorld(original):
            def __init__(self, *args): super().__init__(*args); worlds.append(self)
            def observe(self):
                value = super().observe(); text = observation(value['observation_revision'])
                for key in ('coordinate_mapping', 'display', 'text_recognition'): value[key] = text[key]
                value['applications'][0]['graphics_windows'] = text['applications'][0]['graphics_windows']
                self.latest = deepcopy(value); return value
        with mock.patch.object(regression, 'World', ConflictedWorld):
            result, calls = regression.replay_case(fixture, regression.prompt_pack(), script=[act()]*3)
        self.assertFalse(result['success']); self.assertEqual(len(calls), 3)
        self.assertEqual(worlds[0].delivered, 0); self.assertEqual(worlds[0].polls, 10)
        self.assertEqual(result['duplicate_actions'], 0)
