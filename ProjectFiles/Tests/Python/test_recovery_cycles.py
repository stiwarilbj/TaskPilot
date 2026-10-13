"""Synthetic layouts and recorded decisions only; no live desktop/provider."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
from recovery_cycles import RecoveryCycles, HISTORY_LIMIT, approach, state_key
from task_evidence import TaskEvidenceLedger
import openclaw_runtime as runtime
from prompt_compiler import prompt_phase
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'PromptRegression'))
import evaluate as regression
from fixtures import seed_cases, VERIFIED

TASK = 'Save the Draft and verify both files.'


def observation(name='closed', revision='now', **fields):
    opened = name == 'dialog'
    elements = [dict(id=revision + ':open', pid=42, role='AXButton', title='Open', window_title='Draft',
                     frame=dict(x=100, y=100, width=80, height=30), enabled=True),
                dict(id=revision + ':save', pid=42, role='AXButton', title='Save', window_title='Draft',
                     frame=dict(x=300, y=100, width=80, height=30), enabled=True)]
    if opened:
        elements = [dict(id=revision + ':dialog', pid=42, role='AXSheet', title='Save Draft', window_title='Draft'),
                    dict(id=revision + ':close', pid=42, role='AXButton', title='Cancel', window_title='Draft',
                         parent_id=revision + ':dialog', frame=dict(x=400, y=300, width=80, height=30), enabled=True)]
    return dict(observation_revision=revision, display=dict(x=0, y=0, width=1000, height=800),
                applications=[dict(pid=42, name='Fixture App', active=True,
                                   windows=[dict(window_id=revision + ':window', title='Draft')])],
                elements=elements, **fields)


def action(obs, key='open', kind='press', **fields):
    return dict(type=kind, element_id=obs['observation_revision'] + ':' + key, **fields)


class RecoveryCycleTests(unittest.TestCase):
    def setUp(self):
        self.ledger = TaskEvidenceLedger(TASK, 'fixture-generation')
        self.tracker = RecoveryCycles()
        self.index = 0

    def screen(self, name='closed'):
        self.index += 1
        return observation(name, str(self.index))

    def delivered(self, before, target, after, kind='press', result=None):
        self.ledger.observe(before)
        self.tracker.record(action(before, target, kind), before, result or VERIFIED, self.ledger)
        self.ledger.observe(after)
        return self.tracker.observe(after, self.ledger)

    def cycle(self):
        current = self.screen()
        report = None
        for target, name in [('open', 'dialog'), ('close', 'closed')] * 2:
            after = self.screen(name)
            report = self.delivered(current, target, after)
            current = after
        return current, report

    def prove_file(self, name='a', generation=None):
        check = dict(type='file_contents', path='/fixture/' + name, content='A')
        self.ledger.add_requirements([dict(source=TASK, description='Verify file ' + name, check=check)])
        ref = self.ledger.add_evidence(dict(type='file_contents', path=check['path'], content_sha256=hashlib.sha256(b'A').hexdigest()), mutable=True)
        if generation:
            self.ledger.evidence[ref]['generation'] = generation
            self.ledger.refresh()
        return ref

    def test_two_dialog_laps_warn_before_another_action_and_different_route_remains_allowed(self):
        current, report = self.cycle()
        self.assertEqual(report['cycle_kind'], 'repeated_state_path')
        self.assertEqual(report['state_sequence'], ['state_1', 'state_2', 'state_1'])
        self.assertEqual([e['target']['label'] for e in report['approaches_tried']], ['Open', 'Cancel'])
        self.assertEqual(self.tracker.check(action(current), current, self.ledger)['outcome'], 'suppressed')
        self.assertIsNone(self.tracker.check(action(current, 'save'), current, self.ledger))
        self.assertEqual(self.tracker.detections, 1)

    def test_one_dialog_visit_and_nonrepeating_navigation_are_not_cycles(self):
        first, second, third = self.screen(), self.screen('dialog'), self.screen()
        self.assertIsNone(self.delivered(first, 'open', second))
        self.assertIsNone(self.delivered(second, 'close', third))
        self.assertIsNone(self.tracker.check(action(third), third, self.ledger))

    def test_three_state_cycle_with_different_action_names(self):
        screens = [observation(revision=str(i)) for i in range(7)]
        for i, obs in enumerate(screens): obs['elements'][0]['title'] = ['First', 'Second', 'Third'][i % 3]
        for i in range(6):
            kind = ['press', 'click', 'double_click'][i % 3]
            report = self.delivered(screens[i], 'open', screens[i + 1], kind)
            self.assertEqual(report is not None, i == 5)
        self.assertEqual(len(report['approaches_tried']), 3)

    def test_same_control_toggling_between_two_states_is_also_a_cycle(self):
        screens = [observation(revision=str(i)) for i in range(5)]
        for i, obs in enumerate(screens): obs['elements'][1]['title'] = ['Off', 'On'][i % 2]
        for i in range(4):
            report = self.delivered(screens[i], 'open', screens[i + 1])
            self.assertEqual(report is not None, i == 3)
        self.assertEqual(report['cycle_kind'], 'repeated_state_path')

    def test_failed_methods_cannot_alternate_back_but_an_untried_method_can_run(self):
        current = self.screen()
        for kind in ['press', 'click']:
            after = self.screen()
            self.assertIsNone(self.delivered(current, 'open', after, kind,
                dict(outcome='rejected', error_code='unsupported_action')))
            current = after
        self.assertIsNone(self.tracker.check(action(current, kind='double_click'), current, self.ledger))
        report = self.tracker.check(action(current), current, self.ledger)
        self.assertEqual(report['cycle_kind'], 'unsuccessful_methods')
        self.assertEqual([e['action_type'] for e in report['approaches_tried']], ['press', 'click'])

    def test_a_single_failed_method_retains_existing_identical_action_guard(self):
        current = self.screen()
        for _ in range(2):
            after = self.screen()
            self.delivered(current, 'open', after, result=dict(outcome='rejected', error_code='stale_target'))
            current = after
        self.assertIsNone(self.tracker.check(action(current), current, self.ledger))

    def test_incidental_churn_does_not_change_state_or_approach(self):
        first, second = observation(revision='old'), observation(revision='fresh')
        second['applications'][0]['active'] = False
        second['applications'][0]['windows'][0].update(focused=False, topmost_on_agent_screen=False)
        second['elements'].reverse()
        second.update(cursor=dict(x=500, y=600), screenshot_path='/not-a-real-file')
        self.assertEqual(state_key(first, 42), state_key(second, 42))
        self.assertEqual(approach(action(first), first)[1],
                         approach(action(second, pid=42, x=120, y=115), second)[1])

    def test_progress_animation_values_and_secure_values_are_not_meaningful_state(self):
        first = observation()
        first['elements'] += [dict(id='now:progress', pid=42, role='AXProgressIndicator', value=10),
                              dict(id='now:password', pid=42, role='AXSecureTextField', value='private-one')]
        second = deepcopy(first)
        second['elements'][-2]['value'] = 90
        second['elements'][-1]['value'] = 'private-two'
        self.assertEqual(state_key(first, 42), state_key(second, 42))

    def test_field_values_layout_identity_and_target_structure_are_meaningful(self):
        first = observation()
        first['elements'][0].update(role='AXTextField', value='old', value_complete=True)
        for field, value in [('value', 'new'), ('enabled', False), ('focused', True), ('title', 'Other')]:
            second = deepcopy(first); second['elements'][0][field] = value
            self.assertNotEqual(state_key(first, 42), state_key(second, 42), field)
        second = deepcopy(first); second['elements'][0]['frame']['x'] += 50
        self.assertNotEqual(state_key(first, 42), state_key(second, 42))
        second = deepcopy(first); second['applications'][0]['name'] = 'Other App'
        self.assertNotEqual(state_key(first, 42), state_key(second, 42))
        second = deepcopy(first); second['elements'][0]['actions'] = ['AXPress']
        self.assertNotEqual(state_key(first, 42), state_key(second, 42))

    def test_other_apps_changing_do_not_hide_target_app_cycles(self):
        first = observation(); second = deepcopy(first)
        second['applications'].append(dict(pid=43, name='Clock', windows=[dict(title='12:34')]))
        second['elements'].append(dict(id='other', pid=43, role='AXStaticText', title='12:34'))
        self.assertEqual(state_key(first, 42), state_key(second, 42))

    def test_graphics_only_content_uses_recognized_text_or_conservative_image_digest(self):
        first = observation(); first['elements'] = []
        first['applications'][0]['graphics_windows'] = [dict(id=1, title='Page', frame=dict(x=10, y=10, width=500, height=400))]
        second = deepcopy(first); second['applications'][0]['graphics_windows'][0]['frame']['x'] += 10
        self.assertNotEqual(state_key(first, 42, 'a'), state_key(second, 42, 'a'))
        self.assertNotEqual(state_key(first, 42, 'a'), state_key(first, 42, 'b'))
        first['text_recognition'] = dict(targets=[dict(pid=42, text='Step one', confidence=.99, frame=dict(x=10, y=10, width=80, height=30))])
        second = deepcopy(first); second['text_recognition']['targets'][0]['text'] = 'Step two'
        self.assertNotEqual(state_key(first, 42), state_key(second, 42))

    def test_failed_methods_budget_survives_wait_none_read_and_noop_delivery(self):
        current = self.screen()
        for kind in ['press', 'click']:
            after = self.screen()
            self.delivered(current, 'open', after, kind, dict(outcome='rejected', error_code='unsupported_action'))
            current = after
        for local in [dict(type='wait', seconds=1), dict(type='none'), dict(type='read_file', path='/fixture/a')]:
            self.tracker.record(local, current, dict(verified=True), self.ledger)
            self.tracker.observe(current, self.ledger)
        after = self.screen()
        self.delivered(current, 'save', after, 'focus')
        self.assertEqual(self.tracker.check(action(after), after, self.ledger)['cycle_kind'], 'unsuccessful_methods')

    def test_new_deterministic_requirement_proof_resets_cycle_but_reproof_does_not(self):
        current, _ = self.cycle()
        self.prove_file()
        self.assertIsNone(self.tracker.check(action(current), current, self.ledger))
        current, _ = self.cycle()
        self.prove_file()  # A new evidence ID for the exact same requirement.
        self.assertEqual(self.tracker.check(action(current), current, self.ledger)['outcome'], 'suppressed')
        self.prove_file('b')
        self.assertIsNone(self.tracker.check(action(current), current, self.ledger))

    def test_invalidated_proof_model_claims_and_cross_task_evidence_do_not_reset_cycles(self):
        ref = self.prove_file()
        self.tracker.progress(self.ledger)
        self.ledger.evidence[ref]['valid'] = False; self.ledger.refresh()
        current, _ = self.cycle()
        self.prove_file()
        self.ledger.accept_plan(dict(completed_requirements=[TASK], remaining_requirements=[]))
        self.assertIsNotNone(self.tracker.check(action(current), current, self.ledger))
        self.prove_file('b', generation='another-task')
        self.assertIsNotNone(self.tracker.check(action(current), current, self.ledger))

    def test_fresh_verified_field_progress_allows_same_workflow_for_next_requirement(self):
        current, _ = self.cycle()
        current['elements'][0].update(role='AXTextField', value='A', value_complete=True)
        self.ledger.add_requirements([dict(source=TASK, description='Enter A',
            check=dict(type='field_value', element_id=current['elements'][0]['id'], value='A'))], current)
        self.ledger.observe(current)
        self.tracker.observe(current, self.ledger)
        self.assertEqual(self.tracker.blocked, {})
        self.assertEqual(self.ledger.requirements['r1']['state'], 'proven')

    def test_repeated_suppressed_proposals_stop_within_existing_three_decision_bound(self):
        current, _ = self.cycle()
        for _ in range(2): self.assertIsNotNone(self.tracker.check(action(current), current, self.ledger))
        with self.assertRaisesRegex(RuntimeError, 'recovery-cycle'):
            self.tracker.check(action(current), current, self.ledger)
        self.assertEqual(self.tracker.suppressions, 3)

    def test_relevant_state_change_different_panel_or_app_is_not_a_blocked_approach(self):
        current, _ = self.cycle()
        moved = deepcopy(current); moved['elements'][0]['frame']['x'] += 100
        self.assertIsNone(self.tracker.check(action(moved), moved, self.ledger))
        other = deepcopy(current); other['elements'][0].update(window_title='Other panel')
        self.assertIsNone(self.tracker.check(action(other), other, self.ledger))
        other['elements'][0]['pid'] = 43
        self.assertIsNone(self.tracker.check(action(other), other, self.ledger))

    def test_bounded_memory_and_task_isolation(self):
        for i in range(HISTORY_LIMIT * 3):
            before, after = self.screen(), self.screen()
            before['elements'][0]['title'] = str(i)
            after['elements'][0]['title'] = str(i + 1)
            self.delivered(before, 'open', after)
        self.assertEqual(len(self.tracker.history), HISTORY_LIMIT)
        current, _ = self.cycle()
        fresh = RecoveryCycles()
        self.assertIsNone(fresh.observe(current, TaskEvidenceLedger(TASK, 'another-generation')))
        self.assertIsNone(fresh.check(action(current), current, self.ledger))

    def test_strategy_summaries_do_not_retain_literal_commands_paths_text_or_scoped_ids(self):
        current = self.screen()
        for kind in ['command-a', 'command-b']:
            command = dict(type='run_command', argv=['/private/' + kind, 'private-text'], working_directory='/private')
            self.tracker.record(command, current, dict(error_code='command_syntax'), self.ledger)
            self.tracker.observe(current, self.ledger)
        report = self.tracker.check(dict(type='run_command', argv=['/private/command-a', 'private-text'], working_directory='/private'), current, self.ledger)
        serialized = json.dumps(report)
        for literal in ['/private', 'private-text', current['observation_revision'] + ':open']:
            self.assertNotIn(literal, serialized)


class RuntimeRecoveryCycleTests(unittest.TestCase):
    def replay(self, identifier, label='candidate', script=None):
        fixture = next(c for c in seed_cases() if c['id'] == identifier)
        return regression.replay_case(fixture, regression.prompt_pack(), script=script or fixture['scripts'][label])

    def test_dialog_cycle_changes_route_without_duplicate_events_or_extra_detection_requests(self):
        result, calls = self.replay('repeated-dialog')
        self.assertTrue(result['success'], result)
        self.assertEqual(result['delivered_actions'], 5)
        self.assertEqual(result['incorrect_action_attempts'], 0)
        self.assertEqual(result['duplicate_actions'], 0)
        self.assertEqual((result['planning'], result['verification'], result['repairs']), (6, 1, 0))
        self.assertEqual((result['recovery_cycles'], result['cycle_suppressions']), (1, 0))
        self.assertEqual(len(calls), 7)

    def test_bad_cycle_proposals_never_reach_bridge_and_exhaust_locally(self):
        result, _ = self.replay('repeated-dialog', 'baseline')
        self.assertFalse(result['completed'])
        self.assertEqual(result['delivered_actions'], 4)
        self.assertEqual(result['incorrect_action_attempts'], 0)
        self.assertEqual((result['requests'], result['cycle_suppressions']), (7, 3))

    def test_alternating_rejections_suppress_repeat_then_use_untried_target(self):
        result, _ = self.replay('alternating-methods')
        self.assertTrue(result['success'], result)
        self.assertEqual(result['delivered_actions'], 1)
        self.assertEqual(result['incorrect_action_attempts'], 0)
        self.assertEqual((result['recovery_cycles'], result['cycle_suppressions']), (1, 1))
        self.assertEqual((result['requests'], result['repairs'], result['retries']), (6, 0, 0))

    def test_healthy_and_delayed_tasks_keep_existing_call_counts(self):
        for identifier, count in [('healthy-control', 3), ('delayed-dialog', 4)]:
            result, _ = self.replay(identifier)
            self.assertTrue(result['success'], result)
            self.assertEqual(result['requests'], count)
            self.assertEqual(result['recovery_cycles'], 0)

    def test_uncertain_mutations_still_stop_before_switching_methods(self):
        result, _ = self.replay('uncertain-submission', 'baseline')
        self.assertFalse(result['completed'])
        self.assertEqual(result['delivered_actions'], 1)
        self.assertEqual(result['duplicate_actions'], 0)
        self.assertEqual(result['cycle_suppressions'], 0)

    def test_cancellation_discards_pending_recovery_without_any_further_delivery(self):
        bridge = regression.World.bridge
        def cancelled(world, method, display, **params):
            if method == 'act' and world.delivered == 1: raise SystemExit(143)
            return bridge(world, method, display, **params)
        with mock.patch.object(regression.World, 'bridge', cancelled):
            result, _ = self.replay('repeated-dialog')
        self.assertEqual(result['failure_kind'], 'cancelled')
        self.assertEqual(result['delivered_actions'], 1)
        self.assertEqual(result['requests'], 2)
        self.assertEqual(result['cycle_suppressions'], 0)

    def test_cycle_recovery_prompt_contains_path_and_approaches_only_in_recovery(self):
        ledger = TaskEvidenceLedger(TASK)
        tracker = RecoveryCycles()
        current = observation()
        for index, (target, name) in enumerate([('open', 'dialog'), ('close', 'closed')] * 2):
            after = observation(name, str(index))
            tracker.record(action(current, target), current, VERIFIED, ledger)
            report = tracker.observe(after, ledger)
            current = after
        history = [dict(action='recovery_cycle', result=report)]
        prompt = runtime.desktop_instruction(TASK, current, history)
        self.assertEqual(prompt_phase(prompt), 'recovery')
        self.assertIn('state_sequence', prompt)
        self.assertIn('approaches_tried', prompt)
        self.assertIn('untried supported strategy', prompt)
        self.assertNotIn('untried supported strategy', runtime.desktop_instruction(TASK, current, []))

    def test_regression_identity_rejects_other_cycle_policy(self):
        pack = regression.prompt_pack(); pack['recovery_cycle_version'] = 0
        with self.assertRaisesRegex(ValueError, 'Recovery cycle version'):
            regression.validate_pack(pack)
