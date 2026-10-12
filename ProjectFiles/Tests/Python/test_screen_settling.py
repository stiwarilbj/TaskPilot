from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
from evidence_fixtures import with_requirements, proof_response


class ScreenSettlingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.now = 0.0
        self.counter = 0
        self.paths = []
        self.baseline = self.observation('before')
        self.baseline_digest = runtime.observation_image_digest(self.baseline)
        self.action = {'type': 'press', 'element_id': self.baseline['elements'][0]['id']}

    def observation(self, title='before', pid=42, role='AXButton', **fields):
        self.counter += 1
        path = Path(self.directory.name) / f'{self.counter}.jpg'
        path.write_bytes(fields.pop('pixels', b'unchanged pixels'))
        self.paths.append(path)
        return {'observation_revision': str(self.counter), 'screenshot_path': str(path),
                'applications': [{'pid': pid, 'active': True}],
                'elements': [{'id': f'{self.counter}:e1', 'pid': pid, 'title': title,
                              'role': role, 'enabled': True, **fields}]}

    def run_wait(self, frames, timeout=2.0):
        iterator = iter(frames)
        last = frames[-1]
        def observe(method, display_id, **params):
            nonlocal last
            self.assertEqual(method, 'observe')
            self.assertEqual(display_id, 1)
            self.assertGreater(params['consistency_budget_ms'], 0)
            self.assertLessEqual(params['consistency_budget_ms'], max(1, min(5000, round((timeout - self.now) * 1000) + 1)))
            try: last = next(iterator)
            except StopIteration:
                last = self.observation(last['elements'][0]['title'],
                                        role=last['elements'][0]['role'],
                                        **{k: v for k, v in last['elements'][0].items()
                                           if k not in {'title', 'role', 'pid', 'id'}})
            return last
        def sleep(seconds): self.now += seconds
        with mock.patch.object(runtime, 'bridge_call', side_effect=observe) as bridge, \
             mock.patch.object(runtime.time, 'monotonic', side_effect=lambda: self.now), \
             mock.patch.object(runtime.time, 'sleep', side_effect=sleep), \
             mock.patch.object(runtime, 'routed_json_prompt') as model:
            result = runtime.wait_for_screen_change(1, self.baseline, self.action,
                                                    self.baseline_digest, timeout=timeout)
            model.assert_not_called()
            self.assertTrue(all(call.args[0] == 'observe' for call in bridge.call_args_list))
        return result

    def test_unchanged_screen_and_revision_churn_wait_to_bound(self):
        frames = [self.observation() for _ in range(15)]
        latest, result = self.run_wait(frames)
        self.assertEqual(result['reason'], 'bounded_wait_elapsed')
        self.assertFalse(result['changed'])
        self.assertEqual(self.now, 2.0)
        self.assertTrue(Path(latest['screenshot_path']).is_file())

    def test_native_consistency_retries_share_remaining_settling_budget(self):
        calls = []
        def observe(method, display_id, **params):
            calls.append(params['consistency_budget_ms'])
            self.now += 0.2  # Native collection/retries consumed local time.
            return self.observation()
        with mock.patch.object(runtime, 'bridge_call', side_effect=observe), \
             mock.patch.object(runtime.time, 'monotonic', side_effect=lambda: self.now), \
             mock.patch.object(runtime.time, 'sleep', side_effect=lambda seconds: setattr(self, 'now', self.now + seconds)), \
             mock.patch.object(runtime, 'routed_json_prompt') as model:
            _, result = runtime.wait_for_screen_change(1, self.baseline, self.action, timeout=1.0)
        model.assert_not_called()
        self.assertEqual(calls[0], 1000)
        self.assertTrue(all(1 <= value <= 1000 for value in calls))
        self.assertEqual(calls, sorted(calls, reverse=True))
        self.assertLessEqual(self.now, 1.0)
        self.assertEqual(result['reason'], 'bounded_wait_elapsed')

    def test_unstable_observation_never_reuses_old_targets_or_asks_model(self):
        frame = self.observation()
        with mock.patch.object(runtime, 'bridge_call', side_effect=[frame, runtime.ActionRejected('Changing layout', 'observation_unstable')]) as bridge, \
             mock.patch.object(runtime.time, 'monotonic', return_value=0), \
             mock.patch.object(runtime.time, 'sleep'), \
             mock.patch.object(runtime, 'routed_json_prompt') as model:
            with self.assertRaises(runtime.ActionRejected) as error:
                runtime.wait_for_screen_change(1, self.baseline, self.action, timeout=1.0)
        self.assertEqual(error.exception.code, 'observation_unstable')
        self.assertFalse(Path(frame['screenshot_path']).exists())
        self.assertTrue(all(call.args[0] == 'observe' for call in bridge.call_args_list))
        model.assert_not_called()

    def test_initial_unstable_capture_stops_before_planning_or_actions(self):
        client = mock.Mock(prompt_calls=0, model_switches=0)
        router = runtime.AdaptiveModelRouter(lambda *args, **kwargs: None)
        with mock.patch.object(runtime, 'find_openclaw', return_value='mock'), \
             mock.patch.object(runtime, 'prepare_runtime', return_value=mock.Mock()), \
             mock.patch.object(runtime, 'ACPClient', return_value=client), \
             mock.patch.object(runtime, 'TaskModelRouter', return_value=router), \
             mock.patch.object(runtime, 'bridge_call', side_effect=runtime.ActionRejected('Changing layout', 'observation_unstable')) as bridge, \
             mock.patch.object(runtime, 'emit'):
            with self.assertRaises(runtime.ActionRejected):
                runtime.run_task('Click the observed button', 1, 'mock', '')
        bridge.assert_called_once_with('observe', 1)
        client.prompt.assert_not_called()
        self.assertEqual(router.metrics['planning'], 0)
        self.assertEqual(router.metrics['model_switches'], 0)

    def test_dialog_must_stabilize_before_next_decision(self):
        frames = [self.observation(), self.observation('Confirm', role='AXSheet')]
        latest, result = self.run_wait(frames)
        self.assertEqual(result['reason'], 'dialog_opened')
        self.assertGreaterEqual(self.now, 0.45)
        self.assertLess(self.now, 2.0)
        self.assertEqual(latest['elements'][0]['role'], 'AXSheet')

    def test_field_becoming_enabled_and_focused(self):
        self.baseline['elements'][0].update(role='AXTextField', enabled=False)
        latest, result = self.run_wait([self.observation(role='AXTextField', focused=True)])
        self.assertEqual(result['reason'], 'field_ready')
        self.assertTrue(latest['elements'][0]['focused'])

    def test_loading_page_waits_for_ready_content(self):
        frames = [self.observation('Loading', role='AXProgressIndicator') for _ in range(4)]
        frames += [self.observation('Article', role='AXStaticText') for _ in range(4)]
        _, result = self.run_wait(frames)
        self.assertEqual(result['reason'], 'screen_changed')
        self.assertGreaterEqual(self.now, 0.9)
        self.assertLess(self.now, 2.0)

    def test_permanent_loading_is_bounded(self):
        _, result = self.run_wait([self.observation('Loading', role='AXProgressIndicator')])
        self.assertEqual(result['reason'], 'bounded_wait_elapsed')
        self.assertEqual(self.now, 2.0)

    def test_transient_changes_do_not_trigger_early_query(self):
        frames = [self.observation('animation1'), self.observation('animation2'),
                  self.observation('ready'), self.observation('ready'), self.observation('ready')]
        _, result = self.run_wait(frames)
        self.assertGreaterEqual(self.now, 0.6)
        self.assertEqual(result['reason'], 'screen_changed')

    def test_screenshot_change_handles_missing_accessibility_controls(self):
        self.baseline['elements'] = []
        frames = [self.observation(pixels=b'loaded image') for _ in range(4)]
        for frame in frames: frame['elements'] = []
        _, result = self.run_wait(frames)
        self.assertTrue(result['changed'])
        self.assertEqual(result['reason'], 'screen_changed')
        self.assertEqual(self.now, 0.3)

    def test_background_app_changes_do_not_count_as_target_progress(self):
        self.baseline['elements'].append({'id': 'old:e2', 'pid': 43, 'title': 'clock'})
        frames = [self.observation() for _ in range(15)]
        for index, frame in enumerate(frames):
            frame['elements'].append({'id': f'{index}:e2', 'pid': 43, 'title': str(index)})
        _, result = self.run_wait(frames)
        self.assertFalse(result['changed'])
        self.assertEqual(result['reason'], 'bounded_wait_elapsed')

    def test_foreground_and_enumeration_churn_is_ignored(self):
        baseline = {'applications': [{'pid': 42, 'active': True}, {'pid': 43, 'active': False}],
                    'elements': [{'id': 'old:a', 'pid': 42, 'title': 'A'}, {'id': 'old:b', 'pid': 42, 'title': 'B'}]}
        after = {'applications': [{'pid': 43, 'active': True}, {'pid': 42, 'active': False}],
                 'elements': [{'id': 'new:b', 'pid': 42, 'title': 'B'}, {'id': 'new:a', 'pid': 42, 'title': 'A'}]}
        self.assertEqual(runtime.observation_progress_signature(baseline), runtime.observation_progress_signature(after))

    def test_window_scope_ids_and_activation_metadata_do_not_reset_settling(self):
        import copy
        baseline = {'applications': [{'pid': 42, 'window_count': 2, 'windows': [
            {'window_id': 'old:w1', 'title': 'First', 'focused': True, 'topmost_on_agent_screen': True,
             'frame': {'x': 10, 'y': 10, 'width': 500, 'height': 400}},
            {'window_id': 'old:w2', 'title': 'Second', 'focused': False}]}], 'elements': []}
        after = copy.deepcopy(baseline)
        after['applications'][0]['windows'].reverse()
        for index, window in enumerate(after['applications'][0]['windows']):
            window.update(window_id=f'new:w{index}', focused=False, topmost_on_agent_screen=False)
        self.assertEqual(runtime.observation_progress_signature(baseline), runtime.observation_progress_signature(after))
        after['applications'][0]['windows'][0]['title'] = 'New dialog'
        self.assertNotEqual(runtime.observation_progress_signature(baseline), runtime.observation_progress_signature(after))

    def test_window_metadata_churn_alone_waits_to_bound_without_a_model_call(self):
        frames = [self.observation() for _ in range(15)]
        for observation in [self.baseline, *frames]:
            observation['applications'][0]['windows'] = [
                {'window_id': observation['observation_revision'] + ':w1', 'title': 'Budget', 'focused': True}]
        _, result = self.run_wait(frames)
        self.assertEqual(result['reason'], 'bounded_wait_elapsed')
        self.assertFalse(result['changed'])

    def test_intermediate_screenshots_are_removed_and_final_revision_retained(self):
        frames = [self.observation('ready') for _ in range(3)]
        latest, result = self.run_wait(frames)
        self.assertEqual(result['polls'], 3)
        self.assertEqual(latest['observation_revision'], frames[-1]['observation_revision'])
        self.assertTrue(Path(latest['screenshot_path']).is_file())
        self.assertFalse(Path(frames[0]['screenshot_path']).exists())
        self.assertFalse(Path(frames[1]['screenshot_path']).exists())

    def test_cancellation_during_local_wait_cleans_up_without_replay(self):
        frame = self.observation('ready')
        with mock.patch.object(runtime, 'bridge_call', return_value=frame) as bridge, \
             mock.patch.object(runtime.time, 'sleep', side_effect=SystemExit(143)):
            with self.assertRaises(SystemExit):
                runtime.wait_for_screen_change(1, self.baseline, self.action, self.baseline_digest)
        bridge.assert_called_once_with('observe', 1, consistency_budget_ms=2000)
        self.assertFalse(Path(frame['screenshot_path']).exists())

    def test_bridge_errors_propagate_and_cleanup(self):
        frame = self.observation('ready')
        with mock.patch.object(runtime, 'bridge_call', side_effect=[frame, RuntimeError('permission denied')]), \
             mock.patch.object(runtime.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'permission denied'):
                runtime.wait_for_screen_change(1, self.baseline, self.action, self.baseline_digest)
        self.assertFalse(Path(frame['screenshot_path']).exists())

    def test_stale_target_refreshes_and_replans_without_delivering_old_click(self):
        import json
        planned = []
        histories = []
        current = self.baseline
        attempts = []
        delivered = []
        state = mock.Mock()
        class Client:
            prompt_calls = 0
            model_switches = 0
            selected_model = None
            def select_model(client, model): client.selected_model = model
            def prompt(client, instruction, image):
                client.prompt_calls += 1
                if client.prompt_calls <= 2:
                    return json.dumps(with_requirements({'status': 'act', 'action': {
                        'type': 'press', 'element_id': current['elements'][0]['id']}}, client.ledger.task))
                return json.dumps(with_requirements({'status': 'done'}, client.ledger.task) if client.prompt_calls == 3 else proof_response(client.ledger))
            def close(client): pass
        client = Client()
        router = runtime.AdaptiveModelRouter(lambda *a, **k: None)
        def bridge(method, display_id, **params):
            if method == 'act':
                target = params['action']['element_id']
                attempts.append(target)
                if len(attempts) == 1:
                    raise runtime.ActionRejected('Control moved; observe again', 'stale_target')
                delivered.append(target)
                return {'message': 'Delivered once', 'outcome': 'verified', 'pid': 42}
            return self.observation('ready' if delivered else 'Save')
        def instruction(task, observation, history, ledger=None):
            nonlocal current
            current = observation
            planned.append(observation['observation_revision'])
            histories.append(list(history))
            client.ledger = ledger
            return 'plan'
        def sleep(seconds): self.now += seconds
        with mock.patch.object(runtime, 'find_openclaw', return_value='mock'), \
             mock.patch.object(runtime, 'prepare_runtime', return_value=state), \
             mock.patch.object(runtime, 'ACPClient', return_value=client), \
             mock.patch.object(runtime, 'TaskModelRouter', side_effect=lambda **kwargs: router), \
             mock.patch.object(runtime, 'bridge_call', side_effect=bridge), \
             mock.patch.object(runtime, 'secure_input_target', return_value=None), \
             mock.patch.object(runtime, 'desktop_instruction', side_effect=instruction), \
             mock.patch.object(runtime, 'verification_instruction', return_value='verify'), \
             mock.patch.object(runtime, 'record_action_diagnostic'), \
             mock.patch.object(runtime.time, 'monotonic', side_effect=lambda: self.now), \
             mock.patch.object(runtime.time, 'sleep', side_effect=sleep), \
             mock.patch.object(runtime, 'emit'):
            runtime.run_task('Click Save once', 1, 'mock', '')
        self.assertNotEqual(planned[0], planned[1])
        self.assertEqual(attempts, [f'{planned[0]}:e1', f'{planned[1]}:e1'])
        self.assertEqual(delivered, [f'{planned[1]}:e1'])
        self.assertEqual(histories[1][-1]['result']['error_code'], 'stale_target')
        self.assertEqual(client.prompt_calls, 4)  # Three decisions and fresh completion verification.
        self.assertEqual(router.metrics['action_rejections'], 1)
        self.assertEqual(router.metrics['action_deliveries'], 1)
        self.assertEqual(router.metrics['repairs'], 0)

    def test_unconfirmed_text_replacement_is_not_replayed_after_observation(self):
        import json
        current = self.observation('Body', role='AXTextField', value='', focused=True)
        deliveries = []
        state = mock.Mock()
        class Client:
            prompt_calls = 0
            model_switches = 0
            selected_model = None
            def select_model(client, model): client.selected_model = model
            def prompt(client, instruction, image):
                client.prompt_calls += 1
                return json.dumps(with_requirements({'status': 'act', 'action': {
                    'type': 'set_value', 'element_id': current['elements'][0]['id'], 'text': 'full'}}, client.ledger.task))
            def close(client): pass
        client = Client()
        router = runtime.AdaptiveModelRouter(lambda *a, **k: None)
        def bridge(method, display_id, **params):
            if method == 'act':
                deliveries.append(params['action'])
                return {'message': 'Read-back mismatch', 'outcome': 'delivered_unconfirmed',
                        'text_verification': 'mismatch', 'pid': 42}
            return self.observation('Body', role='AXTextField', focused=True,
                                    value='partial' if deliveries else '')
        def instruction(task, observation, history, ledger=None):
            nonlocal current
            current = observation
            client.ledger = ledger
            return 'plan'
        def sleep(seconds): self.now += seconds
        with mock.patch.object(runtime, 'find_openclaw', return_value='mock'), \
             mock.patch.object(runtime, 'prepare_runtime', return_value=state), \
             mock.patch.object(runtime, 'ACPClient', return_value=client), \
             mock.patch.object(runtime, 'TaskModelRouter', side_effect=lambda **kwargs: router), \
             mock.patch.object(runtime, 'bridge_call', side_effect=bridge), \
             mock.patch.object(runtime, 'secure_input_target', return_value=None), \
             mock.patch.object(runtime, 'desktop_instruction', side_effect=instruction), \
             mock.patch.object(runtime, 'record_action_diagnostic'), \
             mock.patch.object(runtime.time, 'monotonic', side_effect=lambda: self.now), \
             mock.patch.object(runtime.time, 'sleep', side_effect=sleep), \
             mock.patch.object(runtime, 'emit'):
            with self.assertRaisesRegex(RuntimeError, 'stopped rather than repeat an uncertain mutation'):
                runtime.run_task('Enter full into Body', 1, 'mock', '')
        self.assertEqual(len(deliveries), 1)
        self.assertEqual(router.metrics['action_deliveries'], 1)
        self.assertEqual(router.metrics['unconfirmed_actions'], 1)
        self.assertEqual(router.metrics['repairs'], 0)

    def test_task_loop_reuses_settled_observation_and_executes_once(self):
        import json
        initial = self.baseline
        revisions = []
        act_calls = []
        after_action = False
        calls = []
        state = mock.Mock()
        class Client:
            prompt_calls = 0
            model_switches = 0
            selected_model = None
            def select_model(client, model):
                if client.selected_model != model: client.model_switches += 1
                client.selected_model = model
            def prompt(client, instruction, image):
                client.prompt_calls += 1
                calls.append(instruction)
                if client.prompt_calls == 1:
                    return json.dumps(with_requirements({'status': 'act', 'action': {'type': 'press', 'element_id': initial['elements'][0]['id']}}, client.ledger.task))
                return json.dumps(with_requirements({'status': 'done'}, client.ledger.task) if client.prompt_calls == 2 else proof_response(client.ledger))
            def close(client): pass
        client = Client()
        router = runtime.AdaptiveModelRouter(lambda *a, **k: None)
        def bridge(method, display_id, **params):
            nonlocal after_action
            if method == 'act':
                act_calls.append(params['action'])
                after_action = True
                return {'message': 'Delivered', 'outcome': 'verified', 'pid': 42}
            frame = self.observation('ready') if after_action else initial
            revisions.append(frame['observation_revision'])
            return frame
        planning_revisions = []
        def instruction(task, observation, history, ledger=None):
            planning_revisions.append(observation['observation_revision'])
            client.ledger = ledger
            return 'plan'
        def sleep(seconds): self.now += seconds
        with mock.patch.object(runtime, 'find_openclaw', return_value='mock'), \
             mock.patch.object(runtime, 'prepare_runtime', return_value=state), \
             mock.patch.object(runtime, 'ACPClient', return_value=client), \
             mock.patch.object(runtime, 'TaskModelRouter', side_effect=lambda **kwargs: router), \
             mock.patch.object(runtime, 'bridge_call', side_effect=bridge), \
             mock.patch.object(runtime, 'secure_input_target', return_value=None), \
             mock.patch.object(runtime, 'desktop_instruction', side_effect=instruction), \
             mock.patch.object(runtime, 'verification_instruction', return_value='verify'), \
             mock.patch.object(runtime, 'record_action_diagnostic'), \
             mock.patch.object(runtime.time, 'monotonic', side_effect=lambda: self.now), \
             mock.patch.object(runtime.time, 'sleep', side_effect=sleep), \
             mock.patch.object(runtime, 'emit'):
            runtime.run_task('Click the visible button', 1, 'mock', '')
        self.assertEqual(len(act_calls), 1)
        self.assertEqual(client.prompt_calls, 3)  # Two decisions, one completion verification.
        self.assertEqual(calls, ['plan', 'plan', 'verify'])
        self.assertEqual(len(revisions), 5)  # Initial, three local polls, fresh completion evidence.
        self.assertEqual(planning_revisions[-1], revisions[-2])
        self.assertTrue(all(not p.exists() for p in self.paths))


if __name__ == '__main__': unittest.main()
