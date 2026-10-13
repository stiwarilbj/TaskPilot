from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
from expected_effects import ExpectedEffect
from test_expected_effects import checked


class LocalChangeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(); self.addCleanup(self.directory.cleanup)
        self.clock = 0.0; self.frames = []; self.methods = []
        runtime._local_change_metrics.update(local_notifications=0, local_targeted_checks=0, local_poll_wakeups=0)
        self.before = self.frame('old')
        self.action = {'type': 'set_value', 'element_id': self.before['elements'][0]['id'], 'text': 'wanted'}
        self.spec = {'type': 'field_value', 'element_id': self.before['elements'][0]['id'], 'value': 'wanted'}

    def frame(self, value, *, controls=True):
        revision = str(len(self.frames)); path = Path(self.directory.name) / (revision + '.png')
        path.write_bytes(b'accepted pixels'); self.frames.append(path)
        return {'local_change_notifications': True, 'task_generation_id': 'owned',
                'observation_revision': revision, 'screenshot_path': str(path),
                'applications': [{'pid': 42, 'name': 'Fixture', 'bundle_id': 'local.fixture'}],
                'elements': [{'id': revision + ':field', 'native_identity': 'field', 'pid': 42,
                              'role': 'AXTextField', 'title': 'Body', 'window_title': 'Document',
                              'value': value, 'value_complete': True}] if controls else []}

    def wait(self, native, observe, *, expected=True, timeout=2):
        def exchange(method, display, **params):
            self.methods.append((method, params))
            if method == 'observe': return observe()
            self.assertEqual(method, 'wait_for_change')
            self.assertGreater(params['timeout_ms'], 0); self.assertLessEqual(params['timeout_ms'], 500)
            self.assertLessEqual(params['timeout_ms'] / 1000, max(0, timeout - self.clock - 0.5) + 0.001)
            return native(params)
        with mock.patch.object(runtime, 'bridge_call', side_effect=exchange), \
             mock.patch.object(runtime.time, 'monotonic', side_effect=lambda: self.clock), \
             mock.patch.object(runtime.time, 'sleep', side_effect=lambda s: setattr(self, 'clock', self.clock + s)), \
             mock.patch.object(runtime, 'routed_json_prompt') as model:
            result = runtime.wait_for_screen_change(1, self.before, self.action, timeout=timeout,
                expected_effect=ExpectedEffect(self.spec, self.before) if expected else None)
            model.assert_not_called()
        self.assertTrue(all(method in {'observe', 'wait_for_change'} for method, _ in self.methods))
        self.assertEqual(sum(path.exists() for path in self.frames), 2)  # Original + final accepted pair.
        return result

    def testDelayedFieldUsesTargetedChecksThenFreshAcceptedObservation(self):
        def wake(params):
            self.clock += params['timeout_ms'] / 1000
            return {'effect_ready': self.clock >= 0.8, 'targeted_checks': 2, 'notifications': 1, 'reason': 'change_notification'}
        latest, settling = self.wait(wake, lambda: self.frame('wanted' if self.clock >= 0.8 else 'old'))
        self.assertEqual(settling['reason'], 'expected_effect_verified')
        self.assertGreaterEqual(self.clock, 0.8); self.assertLess(self.clock, 2)
        self.assertEqual(settling['expected_effect']['observation_revision'], latest['observation_revision'])
        self.assertLessEqual(settling['polls'], 3)
        watchers = [params for method, params in self.methods if method == 'wait_for_change']
        self.assertTrue(all(p['expected_result']['value'] == 'wanted' and p['pid'] == 42 for p in watchers))
        self.assertNotEqual(watchers[0]['expected_result']['element_id'], self.spec['element_id'])
        self.assertEqual(watchers[0]['expected_result']['element_id'].split(':')[0], watchers[0]['observation_revision'])
        self.assertGreater(runtime._local_change_metrics['local_targeted_checks'], 0)

    def testNotificationClaimCannotProveAnUnchangedOrWrongField(self):
        def wake(params):
            self.clock += max(0.05, params['minimum_delay_ms'] / 1000)
            return {'effect_ready': True, 'targeted_checks': 1, 'notifications': 1}
        _, settling = self.wait(wake, lambda: self.frame('wrong'))
        self.assertEqual(settling['reason'], 'bounded_wait_elapsed')
        self.assertEqual(settling['expected_effect']['outcome'], 'unconfirmed')
        self.assertLessEqual(self.clock, 2)

    def testIrrelevantNotificationsDoNotCollectWholeObservationEachTime(self):
        def wake(params):
            self.clock += min(0.05, params['timeout_ms'] / 1000)
            return {'effect_ready': False, 'targeted_checks': 1, 'notifications': 4, 'reason': 'change_notification'}
        _, settling = self.wait(wake, lambda: self.frame('old'))
        self.assertEqual(settling['expected_effect']['outcome'], 'unconfirmed')
        self.assertEqual(self.clock, 2); self.assertLessEqual(settling['polls'], 6)
        self.assertGreater(len([m for m, _ in self.methods if m == 'wait_for_change']), settling['polls'])

    def testMissingEventsStillCheckFieldAndMeetExistingBound(self):
        def wake(params):
            self.clock += params['timeout_ms'] / 1000
            return {'effect_ready': self.clock >= 0.7, 'targeted_checks': 2,
                    'notifications': 0, 'notification_supported': False, 'reason': 'poll_timeout'}
        _, settling = self.wait(wake, lambda: self.frame('wanted' if self.clock >= 0.7 else 'old'))
        self.assertEqual(settling['expected_effect']['outcome'], 'verified')
        self.assertGreater(runtime._local_change_metrics['local_poll_wakeups'], 0)

    def testGenericAndGraphicsOnlyChangesUseBoundedPollingAndFreshPairs(self):
        self.before['elements'] = []
        def wake(params):
            self.assertNotIn('expected_result', params)
            self.clock += params['timeout_ms'] / 1000
            return {'effect_ready': None, 'reason': 'poll_timeout', 'notification_supported': False}
        def observe():
            frame = self.frame('ready', controls=False)
            Path(frame['screenshot_path']).write_bytes(b'changed pixels')
            return frame
        _, settling = self.wait(wake, observe, expected=False)
        self.assertEqual(settling['reason'], 'screen_changed'); self.assertTrue(settling['changed'])
        self.assertNotIn('expected_effect', settling)

    def testStaleNativeProbeRefreshesInsteadOfReplayingAction(self):
        def wake(params):
            self.clock += 0.15
            raise runtime.ActionRejected('Target moved', 'stale_target')
        _, settling = self.wait(wake, lambda: self.frame('wanted'))
        self.assertEqual(settling['expected_effect']['outcome'], 'verified')
        self.assertTrue(any(m == 'wait_for_change' for m, _ in self.methods))

    def testCancellationDuringNativeWaitDeletesIntermediateCapture(self):
        for code in ['cancelled', 'permission_denied', 'protected_target']:
            with self.subTest(code=code):
                self.clock = 0; self.methods = []
                def wake(params): raise runtime.ActionRejected('Stopped', code)
                with self.assertRaises(runtime.ActionRejected) as error:
                    self.wait(wake, lambda: self.frame('old'))
                self.assertEqual(error.exception.code, code)
                self.assertTrue(self.frames[0].exists()); self.assertFalse(self.frames[-1].exists())

    def testUnavailableWatcherReturnsToExistingPolling(self):
        def wake(params): raise runtime.ActionRejected('Unsupported method', 'action_rejected')
        _, settling = self.wait(wake, lambda: self.frame('wanted'))
        self.assertEqual(settling['expected_effect']['outcome'], 'verified')
        self.assertEqual(len([m for m, _ in self.methods if m == 'wait_for_change']), 1)

    def testFileWaitUsesOneNativeExchangeAndCountsReadbacksWithoutModelCalls(self):
        spec = {'type': 'file_contents', 'path': '/fixture/note', 'content': 'wanted'}
        response = {**checked(spec), 'local_wait': {'effect_ready': True, 'targeted_checks': 3, 'notifications': 2}}
        metrics = {}
        with mock.patch.object(runtime, 'bridge_call', return_value=response) as bridge, \
             mock.patch.object(runtime, 'routed_json_prompt') as model:
            frame, result = runtime.verify_expected_effect(1, self.before, {'type': 'run_command'},
                {'outcome': 'delivered_unconfirmed'}, spec, None, metrics)
        bridge.assert_called_once_with('wait_file_effect', 1, check=spec, timeout_ms=2000)
        model.assert_not_called(); self.assertIsNone(frame)
        self.assertEqual(result['expected_effect']['outcome'], 'verified'); self.assertEqual(metrics['effect_checks'], 3)
        self.assertEqual(runtime._local_change_metrics['local_notifications'], 2)
        self.assertNotIn('local_wait', result)

    def testFileNotificationWithoutMatchingContentsNeverProvesEffect(self):
        spec = {'type': 'file_contents', 'path': '/fixture/note', 'content': 'wanted'}
        response = {**checked(spec, False), 'local_wait': {'effect_ready': True, 'targeted_checks': 2, 'notifications': 20}}
        with mock.patch.object(runtime, 'bridge_call', return_value=response) as bridge:
            _, result = runtime.verify_expected_effect(1, self.before, {'type': 'run_command'},
                {'outcome': 'delivered_unconfirmed'}, spec, None, {})
        self.assertEqual(bridge.call_count, 1); self.assertEqual(result['expected_effect']['outcome'], 'unconfirmed')
        self.assertEqual(result['outcome'], 'delivered_unconfirmed')

    def testWatcherFlagsAndCountersStayOutOfPromptsAndProof(self):
        prompt = runtime.prompt_observation(self.before)
        self.assertNotIn('local_change_notifications', prompt)
        runtime.record_local_wake({'notifications': True, 'targeted_checks': '2', 'reason': 'changed'})
        self.assertEqual(runtime._local_change_metrics, {'local_notifications': 0, 'local_targeted_checks': 0, 'local_poll_wakeups': 0})

    def testDialogExpectationTargetsObservedAppAndRequiresAcceptedProof(self):
        self.spec = {'type': 'dialog_appeared', 'pid': 42, 'title': 'Save'}
        def wake(params):
            self.assertEqual(params['expected_result'], self.spec); self.assertEqual(params['pid'], 42)
            self.clock += 0.3
            return {'effect_ready': True, 'notifications': 1, 'targeted_checks': 1}
        def observe():
            frame = self.frame('old')
            if self.clock >= 0.3:
                frame['elements'].append({'id': frame['observation_revision'] + ':dialog', 'native_identity': 'new-dialog',
                                          'pid': 42, 'role': 'AXSheet', 'title': 'Save'})
            return frame
        _, settling = self.wait(wake, observe)
        self.assertEqual(settling['reason'], 'expected_effect_verified')
        self.assertEqual(settling['expected_effect']['outcome'], 'verified')


if __name__ == '__main__': unittest.main()
