from pathlib import Path
import sys
import unittest
from unittest import mock
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
from local_budget import LocalBudget, LocalBudgetExpired, current_budget, local_operation, local_scope
from action_receipts import reconcile_receipt
from expected_effects import ExpectedEffect
from evidence_fixtures import native_failure, native_batch, native_check, native_result
import openclaw_runtime as runtime
from task_execution import TaskContext, Phase, current_task


class LocalBudgetTests(unittest.TestCase):
    def setUp(self):
        self.now = 0.0
        self.budget = LocalBudget(1, 'activation', clock=lambda: self.now)
        self.metrics = dict(receipt_queries=0, receipt_recoveries=0, receipt_unresolved=0)
        self.action_id = str(uuid.uuid4())

    def advance(self, seconds): self.now += seconds

    def test_nested_phases_share_allowance_and_cannot_renew_it(self):
        @local_operation(10, 'inspection')
        def inspect():
            self.assertIs(current_budget.get(), self.budget)
            self.budget.check('inspection')
            self.advance(0.7)
        with local_scope(1, 'activation', budget=self.budget):
            self.advance(0.4)
            inspect()
            with self.assertRaises(LocalBudgetExpired) as raised: self.budget.check('capture')
            self.assertEqual(raised.exception.phase, 'inspection')
        self.assertIsNone(current_budget.get())
        self.assertIsNone(runtime.PROMPT_TIMEOUT_SECONDS)

    def test_cancellation_is_checked_before_another_phase(self):
        budget = LocalBudget(10, 'activation', cancelled=lambda: True)
        with self.assertRaisesRegex(RuntimeError, 'cancelled'): budget.check('capture')
        self.assertEqual(budget.phase, 'activation')

    def test_bridge_sends_remaining_allowance_and_caps_reply_wait(self):
        receipt = dict(action_id=self.action_id, state='unknown', terminal=False)
        self.advance(0.4)
        with local_scope(1, 'activation', budget=self.budget), \
             mock.patch.object(runtime, 'bridge_exchange', return_value=dict(ok=True, result=receipt)) as exchange:
            runtime.bridge_call('action_receipt', 1, action_id=self.action_id, _reply_timeout=20)
        params, timeout = exchange.call_args.args[2:]
        self.assertEqual(params['local_budget_ms'], 600)
        self.assertAlmostEqual(timeout, 0.6)
        self.assertNotIn('deadline', params)

    def test_expired_budget_preserves_pending_mutation_and_makes_no_bridge_or_model_calls(self):
        context = TaskContext('fixture', 1, None)
        context.machine.phase = Phase.RECONCILING
        context.machine.pending_action = self.action_id
        token = current_task.set(context)
        self.addCleanup(current_task.reset, token)
        self.advance(1.1)
        with local_scope(1, 'activation', budget=self.budget), \
             mock.patch.object(runtime, 'bridge_exchange') as exchange, \
             mock.patch.object(runtime, 'routed_json_prompt') as model:
            with self.assertRaises(LocalBudgetExpired): runtime.bridge_call('action_receipt', 1, action_id=self.action_id)
            self.assertEqual(context.machine.pending_action, self.action_id)
            with self.assertRaisesRegex(RuntimeError, 'without repeating'):
                reconcile_receipt(self.action_id, exchange, self.metrics, clock=lambda: self.now, sleep=self.advance)
            exchange.assert_not_called(); model.assert_not_called()
        self.assertEqual(self.metrics['receipt_unresolved'], 1)

    def test_receipt_recovery_uses_original_remaining_time_not_another_five_seconds(self):
        calls = []
        def lookup(action_id, remaining):
            calls.append((action_id, remaining)); self.advance(0.9)
            return dict(action_id=action_id, state='dispatched', terminal=False)
        with local_scope(1, 'activation', budget=self.budget):
            with self.assertRaisesRegex(RuntimeError, 'without repeating'):
                reconcile_receipt(self.action_id, lookup, self.metrics, clock=lambda: self.now, sleep=self.advance)
        self.assertEqual(len(calls), 1); self.assertAlmostEqual(self.now, 1)
        self.assertEqual(self.metrics['receipt_recoveries'], 0)

    def test_late_terminal_receipt_keeps_delivery_uncertain(self):
        receipt = dict(action_id=self.action_id, state='unconfirmed',
                       **native_failure('local_budget_exhausted', outcome='delivered_unconfirmed'))
        def lookup(*args): self.advance(1.1); return receipt
        with local_scope(1, 'activation', budget=self.budget):
            response = reconcile_receipt(self.action_id, lookup, self.metrics, clock=lambda: self.now, sleep=self.advance)
        self.assertEqual(response['outcome'], 'delivered_unconfirmed')
        self.assertFalse(response['verified']); self.assertEqual(self.metrics['receipt_recoveries'], 1)

    def test_file_polls_stop_before_new_checks_after_shared_expiry(self):
        spec = dict(type='file_exists', path='/fixture/output')
        effect = ExpectedEffect(spec, {})
        calls = []
        def check(value):
            calls.append(value); self.advance(0.6)
            return native_batch([spec], [native_check(spec, verified=False)])
        with local_scope(1, 'activation', budget=self.budget):
            result = effect.wait_file(check, now=lambda: self.now, sleep=self.advance)
        self.assertEqual(len(calls), 2)
        self.assertEqual(result['outcome'], 'unconfirmed')

    def test_file_and_screen_effect_checks_use_the_same_budget(self):
        spec = dict(type='file_exists', path='/fixture/output')
        before = dict(local_change_notifications=True, elements=[])
        def bridge(method, *_args, **_kwargs):
            self.assertEqual(method, 'wait_file_effect'); self.advance(0.8)
            return native_batch([spec], [native_check(spec, verified=False)])
        def settle(*args, **kwargs):
            self.assertIs(current_budget.get(), self.budget)
            self.assertAlmostEqual(current_budget.get().remaining, 0.2)
            return None, dict(reason='bounded_wait_elapsed', polls=1)
        with local_scope(1, 'activation', budget=self.budget), \
             mock.patch.object(runtime, 'bridge_call', side_effect=bridge), \
             mock.patch.object(runtime, 'wait_for_screen_change', side_effect=settle):
            _, result = runtime.verify_expected_effect(1, before, dict(type='click', pid=42, x=100, y=100),
                native_result(dict(type='click', pid=42, x=100, y=100)), spec, None, {})
        self.assertEqual(result['outcome'], 'delivered_unconfirmed')

    def test_native_budget_expiry_during_readback_cannot_prove_or_replay_mutation(self):
        spec = dict(type='file_exists', path='/fixture/output')
        with local_scope(1, 'activation', budget=self.budget), \
             mock.patch.object(runtime, 'bridge_call', side_effect=runtime.ActionRejected('capture budget expired', 'local_budget_exhausted')) as bridge, \
             mock.patch.object(runtime, 'routed_json_prompt') as model:
            _, result = runtime.verify_expected_effect(1, dict(local_change_notifications=True), dict(type='click', pid=42, x=100, y=100),
                native_result(dict(type='click', pid=42, x=100, y=100)), spec, None, {})
            self.assertEqual(result['local_budget']['reason'], 'local_budget_exhausted')
            self.assertEqual(result['local_budget']['message'], 'capture budget expired')
            self.assertEqual(result['outcome'], 'delivered_unconfirmed')
            self.assertFalse(result['verified']); bridge.assert_called_once(); model.assert_not_called()

    def test_slow_settling_read_cannot_start_another_after_shared_deadline(self):
        frames = []
        def bridge(*args, **kwargs):
            frames.append(self.now); self.advance(0.6)
            return dict(elements=[], observation_revision=str(len(frames)))
        with local_scope(1, 'activation', budget=self.budget), \
             mock.patch.object(runtime.time, 'monotonic', side_effect=lambda: self.now), \
             mock.patch.object(runtime.time, 'sleep', side_effect=self.advance), \
             mock.patch.object(runtime, 'bridge_call', side_effect=bridge), \
             mock.patch.object(runtime, 'observation_image_digest', return_value=None):
            _, settling = runtime.wait_for_screen_change(1, dict(elements=[]), dict(type='click'), timeout=5)
        self.assertEqual(len(frames), 2)
        self.assertTrue(all(start < 1 for start in frames))
        self.assertIn(settling['reason'], {'local_budget_exhausted', 'bounded_wait_elapsed'})

    def test_expired_command_inspection_cannot_launch_an_action(self):
        context = TaskContext('fixture', 1, None)
        context.machine.phase = Phase.EXECUTING
        context.action = dict(type='run_command', argv=['/fixture/tool'], timeout_seconds=1)
        context.observation = {}
        context.ledger = mock.Mock()
        token = current_task.set(context)
        self.addCleanup(current_task.reset, token)
        def inspect(*args): self.advance(32); return {}
        with mock.patch.object(runtime.time, 'monotonic', side_effect=lambda: self.now), \
             mock.patch.object(runtime, 'inspect_general_command', side_effect=inspect), \
             mock.patch.object(runtime, 'bridge_exchange') as exchange:
            with self.assertRaises(LocalBudgetExpired): runtime.TaskExecution(context).execute()
            exchange.assert_not_called()
        self.assertIsNone(context.machine.pending_action)
        self.assertFalse(context.machine.execution_consumed)

    def test_completion_readbacks_share_budget_without_scoping_provider_wait(self):
        ledger = mock.Mock()
        ledger.recheck_actions.return_value = [dict(type='focus', element_id='fixture:control')] * 3
        ledger.recheck_effects.return_value = []
        ledger.evidence = {}
        calls = []
        def bridge(method, *args, **kwargs):
            current_budget.get().check(method)
            calls.append(method); self.advance(0.6)
            return dict(checks=[], requested_checks=[])
        with local_scope(1, 'activation', budget=self.budget), \
             mock.patch.object(runtime, 'bridge_call', side_effect=bridge), \
             mock.patch.object(runtime, 'routed_json_prompt') as model:
            with self.assertRaises(LocalBudgetExpired):
                runtime.refresh_completion_evidence(1, ledger, mock.Mock(), mock.Mock())
            model.assert_not_called()
        self.assertEqual(calls, ['recheck', 'recheck'])
        self.assertIsNone(current_budget.get())

    def test_explicit_positional_wait_keeps_its_existing_bound(self):
        def bridge(*args, **kwargs):
            self.assertAlmostEqual(current_budget.get().remaining, 20)
            self.advance(20)
            return dict(elements=[])
        with mock.patch.object(runtime.time, 'monotonic', side_effect=lambda: self.now), \
             mock.patch.object(runtime, 'bridge_call', side_effect=bridge), \
             mock.patch.object(runtime, 'observation_image_digest', return_value=None):
            _, result = runtime.wait_for_screen_change(1, dict(elements=[]), dict(type='wait'), None, 20)
        self.assertEqual(result['reason'], 'bounded_wait_elapsed')
