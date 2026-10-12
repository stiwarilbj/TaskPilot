import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
from evidence_fixtures import with_requirements, proof_response


class ActionRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.now = 0.0
        self.frames = []
        self.attempts = []
        self.histories = []

    def observation(self, title='Save', role='AXButton', **fields):
        index = len(self.frames) + 1
        path = Path(self.directory.name) / f'{index}.jpg'
        path.write_bytes(b'fixture')
        result = {'observation_revision': str(index), 'screenshot_path': str(path),
                  'display': {'x': 0, 'y': 0, 'width': 1000, 'height': 800},
                  'applications': [{'pid': 42, 'name': 'Fixture', 'active': True}],
                  'elements': [{'id': f'{index}:e1', 'pid': 42, 'role': role, 'title': title,
                                'window_title': 'Draft', 'enabled': True, 'actions': ['AXPress'],
                                'frame': {'x': 100, 'y': 100, 'width': 100, 'height': 40}, **fields}]}
        self.frames.append(result)
        return result

    def action(self, observation, kind='press', **fields):
        return {'type': kind, 'element_id': observation['elements'][0]['id'], **fields}

    def run_task(self, strategy, delivery, observe=None, cancelled=False, secure_target=None, secure_delivery=None):
        current = None
        state = mock.Mock()
        test = self
        class Client:
            prompt_calls = 0
            model_switches = 0
            selected_model = None
            def select_model(client, model): client.selected_model = model
            def prompt(client, instruction, image):
                client.prompt_calls += 1
                if instruction == 'verify': return json.dumps(proof_response(client.ledger))
                value = strategy(current, client.prompt_calls)
                return json.dumps(with_requirements(value if 'status' in value else {'status': 'act', 'action': value}, client.ledger.task))
            def close(client): pass
        self.client = Client()
        self.router = runtime.AdaptiveModelRouter(lambda *a, **k: None)
        def bridge(method, display_id, **params):
            if method == 'act':
                self.attempts.append(params['action'])
                return delivery(params['action'], len(self.attempts))
            return observe() if observe else self.observation()
        def instruction(task, observation, history, ledger=None):
            nonlocal current
            current = observation
            self.client.ledger = ledger
            self.histories.append(list(history))
            return 'plan'
        def sleep(seconds):
            if cancelled: raise SystemExit(143)
            test.now += seconds
        with mock.patch.object(runtime, 'find_openclaw', return_value='mock'), \
             mock.patch.object(runtime, 'prepare_runtime', return_value=state), \
             mock.patch.object(runtime, 'ACPClient', return_value=self.client), \
             mock.patch.object(runtime, 'TaskModelRouter', return_value=self.router), \
             mock.patch.object(runtime, 'bridge_call', side_effect=bridge), \
             mock.patch.object(runtime, 'secure_input_target', side_effect=secure_target, return_value=None), \
             mock.patch.object(runtime, 'request_and_enter_user_input', side_effect=secure_delivery), \
             mock.patch.object(runtime, 'desktop_instruction', side_effect=instruction), \
             mock.patch.object(runtime, 'verification_instruction', return_value='verify'), \
             mock.patch.object(runtime, 'record_action_diagnostic'), \
             mock.patch.object(runtime.time, 'monotonic', side_effect=lambda: self.now), \
             mock.patch.object(runtime.time, 'sleep', side_effect=sleep), \
             mock.patch.object(runtime, 'emit'):
            runtime.run_task('Click Save once', 1, 'mock', '')

    def test_failure_codes_select_distinct_recovery(self):
        expected = {'stale_target': 'observe_again', 'disabled_target': 'wait_or_choose_enabled',
                    'focus_mismatch': 'observe_and_refocus', 'activation_failed': 'observe_and_activate',
                    'unsupported_action': 'choose_supported_method', 'delivery_uncertain': 'inspect_effect'}
        for code, recovery in expected.items():
            self.assertEqual(runtime.action_failure_recovery(code), recovery)

    def test_rejection_bound_survives_revision_churn_and_incidental_parameters(self):
        recovery = runtime.ActionRecovery()
        first = self.observation()
        action = self.action(first)
        for _ in range(2): recovery.rejected(action, first, 'stale_target')
        fresh = self.observation()
        repeated = self.action(fresh, pid=42, x=140, y=125)
        self.assertEqual(recovery.check(repeated, fresh)['outcome'], 'suppressed')
        third = self.observation()
        with self.assertRaisesRegex(RuntimeError, 'same rejected action'):
            recovery.check(self.action(third, pid=42), third)
        changed = self.observation(frame={'x': 300, 'y': 100, 'width': 100, 'height': 40})
        self.assertIsNone(recovery.check(self.action(changed), changed))
        self.assertIsNone(recovery.check(self.action(fresh, 'click'), fresh))

    def test_window_scope_churn_does_not_reset_the_rejection_budget(self):
        recovery = runtime.ActionRecovery()
        def observe(focused, x=10):
            observation = self.observation(window_id=f'revision:{len(self.frames)}:window')
            observation['applications'][0]['windows'] = [
                {'title': 'Draft', 'window_id': observation['elements'][0]['window_id'],
                 'focused': focused, 'topmost_on_agent_screen': focused,
                 'frame': {'x': x, 'y': 10, 'width': 500, 'height': 400}}]
            return observation
        for focused in [True, False]:
            current = observe(focused)
            recovery.rejected(self.action(current), current, 'stale_target')
        fresh = observe(True)
        self.assertEqual(recovery.check(self.action(fresh), fresh)['outcome'], 'suppressed')
        moved = observe(True, x=400)
        self.assertIsNone(recovery.check(self.action(moved), moved))

    def test_uncertain_press_cannot_be_replayed_as_click_or_coordinates(self):
        for kind, parameters in [('click', {}), ('double_click', {}),
                                 ('click', {'pid': 42, 'x': 140, 'y': 140})]:
            recovery = runtime.ActionRecovery()
            before, after = self.observation(), self.observation()
            recovery.unconfirmed(self.action(before), before)
            action = self.action(after, kind, **parameters)
            if parameters: action.pop('element_id')
            self.assertEqual(recovery.check(action, after)['recovery'], 'inspect_effect')
            with self.assertRaisesRegex(RuntimeError, 'uncertain mutation'):
                recovery.check(action, after)

    def test_uncertain_submit_cannot_be_replayed_with_return_or_space(self):
        for key in ['return', 'space', 'v']:
            recovery = runtime.ActionRecovery()
            before = self.observation('Send')
            recovery.unconfirmed(self.action(before), before)
            action = {'type': 'key', 'pid': 42, 'key': key}
            if key == 'v': action['modifiers'] = ['command']
            self.assertEqual(recovery.check(action, self.observation())['outcome'], 'suppressed')

    def test_same_field_is_protected_across_text_methods_and_payloads(self):
        recovery = runtime.ActionRecovery()
        before = self.observation('Body', role='AXTextField', value='partial')
        recovery.unconfirmed(self.action(before, 'set_value', text='hello'), before)
        after = self.observation('Body', role='AXTextField', value='partial')
        self.assertEqual(recovery.check(self.action(after, 'type_text', text='hello'), after)['outcome'], 'suppressed')

    def test_exact_complete_readback_proves_replacement_without_reentry(self):
        recovery = runtime.ActionRecovery()
        before = self.observation('Body', role='AXTextField', value='old', value_complete=True)
        recovery.unconfirmed(self.action(before, 'set_value', text='hello'), before)
        after = self.observation('Body', role='AXTextField', value='hello', value_complete=True)
        result = recovery.check(self.action(after, 'set_value', text='hello'), after)
        self.assertEqual(result['outcome'], 'verified')
        self.assertEqual(result['recovery'], 'effect_already_present')
        self.assertNotIn('hello', json.dumps(result))

    def test_clipped_secure_or_changed_screens_do_not_prove_mutation_success(self):
        for fields in [dict(value='hello', value_complete=False), dict(value='hello'),
                       dict(value='hello', value_complete=True, subrole='AXSecureTextField'), dict(value='partial', value_complete=True)]:
            recovery = runtime.ActionRecovery()
            before = self.observation('Body', role='AXTextField')
            recovery.unconfirmed(self.action(before, 'set_value', text='hello'), before)
            after = self.observation('Body', role='AXTextField', **fields)
            self.assertNotEqual(recovery.check(self.action(after, 'set_value', text='hello'), after)['outcome'], 'verified')

    def test_recovery_state_does_not_cross_tasks_or_other_apps(self):
        before = self.observation()
        recovery = runtime.ActionRecovery()
        recovery.unconfirmed(self.action(before), before)
        after = self.observation(pid=43)
        self.assertIsNone(recovery.check(self.action(after), after))
        self.assertIsNone(runtime.ActionRecovery().check(self.action(before), before))

    def test_verified_delivery_resets_rejected_attempt_count(self):
        recovery = runtime.ActionRecovery()
        observation = self.observation()
        action = self.action(observation)
        recovery.rejected(action, observation, 'stale_target')
        recovery.succeeded(action, observation)
        recovery.rejected(action, observation, 'stale_target')
        self.assertIsNone(recovery.check(action, observation))

    def test_uncertain_native_mutations_require_read_only_inspection(self):
        observation = self.observation()
        for previous, changed in [({'type': 'run_command', 'command': 'do_work', 'timeout_seconds': 1},
                                    {'type': 'run_command', 'command': 'do_work', 'timeout_seconds': 15}),
                                   ({'type': 'write_file', 'path': '~/note.txt', 'content': 'hello', 'mode': 'append'},
                                    {'type': 'write_file', 'path': '~/./note.txt', 'content': 'hello again', 'mode': 'append'})]:
            recovery = runtime.ActionRecovery()
            recovery.unconfirmed(previous, observation)
            self.assertEqual(recovery.check(changed, observation)['outcome'], 'suppressed')
            self.assertIsNone(recovery.check({'type': 'read_file', 'path': '~/note.txt'}, observation))

    def test_keyboard_mutations_include_paste_space_and_plain_characters(self):
        for action in [{'type': 'key', 'key': 'space'}, {'type': 'key', 'key': 'a'},
                       {'type': 'key', 'key': 'v', 'modifiers': ['command']}, {'type': 'key', 'key': 's', 'modifiers': ['command']}]:
            self.assertTrue(runtime.action_may_mutate(action, {}))
        for action in [{'type': 'key', 'key': 'tab'}, {'type': 'key', 'key': 'c', 'modifiers': ['command']}]:
            self.assertFalse(runtime.action_may_mutate(action, {}))

    def test_two_rejected_attempts_then_suppression_stop_without_more_input(self):
        def delivery(action, count): raise runtime.ActionRejected('stale', 'stale_target')
        with self.assertRaisesRegex(RuntimeError, 'same rejected action'):
            self.run_task(lambda observation, count: self.action(observation), delivery)
        self.assertEqual(len(self.attempts), 2)
        self.assertEqual(self.router.metrics['action_rejections'], 2)
        self.assertEqual(self.client.prompt_calls, 4)
        self.assertEqual(self.histories[1][-1]['result']['recovery'], 'observe_again')

    def test_runtime_uncertain_press_then_click_is_never_delivered_twice(self):
        def delivery(action, count): raise runtime.ActionRejected('possibly sent', 'delivery_uncertain')
        with self.assertRaisesRegex(RuntimeError, 'uncertain mutation'):
            self.run_task(lambda observation, count: self.action(observation, 'press' if count == 1 else 'click'), delivery)
        self.assertEqual(len(self.attempts), 1)
        self.assertEqual(self.router.metrics['unconfirmed_actions'], 1)
        self.assertEqual(self.histories[1][-1]['result']['outcome'], 'delivered_unconfirmed')
        self.assertEqual(self.histories[1][-1]['result']['recovery'], 'inspect_effect')

    def test_runtime_late_text_readback_recovers_without_replacement_replay(self):
        def strategy(observation, count):
            return self.action(observation, 'set_value', text='hello') if count <= 2 else {'status': 'done'}
        self.run_task(strategy, lambda *args: {'outcome': 'delivered_unconfirmed', 'pid': 42},
                      observe=lambda: self.observation('Body', role='AXTextField', value='hello' if self.attempts else 'old', value_complete=True))
        self.assertEqual(len(self.attempts), 1)
        self.assertEqual(self.histories[-1][-1]['result']['recovery'], 'effect_already_present')
        self.assertEqual(self.client.prompt_calls, 4)  # Three decisions, one completion check.

    def test_loading_discards_old_decision_waits_then_uses_fresh_target(self):
        self.run_task(lambda observation, count: self.action(observation) if not self.attempts else {'status': 'done'},
                      lambda *args: {'outcome': 'verified', 'pid': 42},
                      observe=lambda: self.observation(busy=self.now < 0.6))
        self.assertEqual(len(self.attempts), 1)
        self.assertNotEqual(self.attempts[0]['element_id'], self.frames[0]['elements'][0]['id'])
        self.assertEqual(self.histories[1][-1]['result']['recovery'], 'wait_for_loading')
        self.assertEqual(self.client.prompt_calls, 4)
        self.assertTrue(all(not Path(frame['screenshot_path']).exists() for frame in self.frames))

    def test_permanent_loading_uses_two_local_waits_and_one_model_decision(self):
        with self.assertRaisesRegex(RuntimeError, 'still loading after bounded'):
            self.run_task(lambda observation, count: self.action(observation), mock.Mock(),
                          observe=lambda: self.observation(busy=True))
        self.assertEqual(self.attempts, [])
        self.assertEqual(self.client.prompt_calls, 1)
        self.assertEqual(self.now, 10.0)
        self.assertTrue(all(not Path(frame['screenshot_path']).exists() for frame in self.frames))

    def test_secure_input_takes_priority_over_continued_loading(self):
        entered = []
        def secure_target(observation, history):
            if self.now >= 5 and not entered:
                return {'pid': 42, 'element_id': observation['elements'][0]['id']}
            return None
        def enter(target, display_id):
            entered.append(target)
            return {'target_signature': 'fixture', 'secret_retained': False}
        self.run_task(lambda observation, count: self.action(observation) if not self.attempts else {'status': 'done'},
                      lambda *args: {'outcome': 'verified', 'pid': 42},
                      observe=lambda: self.observation(busy=not entered),
                      secure_target=secure_target, secure_delivery=enter)
        self.assertEqual(len(entered), 1)
        self.assertEqual(len(self.attempts), 1)

    def test_disabled_failure_with_loading_waits_before_replanning(self):
        def delivery(action, count):
            if count == 1: raise runtime.ActionRejected('disabled', 'disabled_target')
            return {'outcome': 'verified', 'pid': 42}
        self.run_task(lambda observation, count: self.action(observation) if len(self.attempts) < 2 else {'status': 'done'},
                      delivery, observe=lambda: self.observation(busy=bool(self.attempts) and self.now < 0.6))
        self.assertEqual(len(self.attempts), 2)
        self.assertEqual(self.histories[1][-1]['result']['recovery'], 'wait_or_choose_enabled')
        self.assertGreaterEqual(self.now, 0.6)

    def test_permission_rejection_and_native_transport_failure_stop_immediately(self):
        for error in [runtime.ActionRejected('permission', 'permission_denied'), RuntimeError('Lost native reply')]:
            self.attempts = []
            def delivery(action, count): raise error
            with self.assertRaisesRegex(RuntimeError, str(error)):
                self.run_task(lambda observation, count: self.action(observation), delivery)
            self.assertEqual(len(self.attempts), 1)
            self.assertEqual(self.client.prompt_calls, 1)

    def test_command_timeout_is_not_repeated_with_a_larger_timeout(self):
        with self.assertRaisesRegex(RuntimeError, 'uncertain mutation'):
            self.run_task(lambda observation, count: {'type': 'run_command', 'command': 'do_work', 'timeout_seconds': count},
                          lambda *args: {'outcome': 'delivered_unconfirmed', 'timed_out': True, 'exit_code': -15})
        self.assertEqual(len(self.attempts), 1)
        self.assertEqual(self.router.metrics['unconfirmed_actions'], 1)

    def test_unrelated_app_loading_does_not_delay_the_requested_control(self):
        def observation():
            current = self.observation()
            current['elements'].append({'id': current['observation_revision'] + ':e2', 'pid': 43, 'role': 'AXProgressIndicator'})
            return current
        self.run_task(lambda observation, count: self.action(observation) if not self.attempts else {'status': 'done'},
                      lambda *args: {'outcome': 'verified', 'pid': 42}, observe=observation)
        self.assertEqual(len(self.attempts), 1)
        self.assertEqual(self.client.prompt_calls, 3)
        self.assertFalse(any(entry.get('result', {}).get('recovery') == 'wait_for_loading'
                             for history in self.histories for entry in history))

    def test_cancellation_during_uncertain_effect_wait_never_replays(self):
        def delivery(action, count): raise runtime.ActionRejected('possibly sent', 'delivery_uncertain')
        with self.assertRaises(SystemExit):
            self.run_task(lambda observation, count: self.action(observation), delivery, cancelled=True)
        self.assertEqual(len(self.attempts), 1)
        self.assertEqual(self.client.prompt_calls, 1)
        self.assertTrue(all(not Path(frame['screenshot_path']).exists() for frame in self.frames))


if __name__ == '__main__': unittest.main()
