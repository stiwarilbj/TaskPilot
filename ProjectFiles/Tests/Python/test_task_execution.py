"""Offline execution graph, boundary guards, and interruption regressions."""
import contextlib
import itertools
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
from task_execution import TaskContext, ExecutionMachine, ExecutionStateError, Phase, TRANSITIONS, EFFECTS, current_task
from action_receipts import BridgeReplyLost
from coordinate_fixtures import fixture_coordinates
from evidence_fixtures import VerificationSessions, native_result, native_failure, with_requirements, proof_response


class ExecutionGraphTests(unittest.TestCase):
    def test_every_phase_pair_and_each_required_fact(self):
        # Independent expected adjacency: an accidental new edge fails this test.
        edges = {
            'starting': {'observing', 'recovering', 'draining'},
            'observing': {'planning', 'waiting_input', 'reconciling', 'executing', 'verifying', 'draining'},
            'planning': {'reconciling', 'recovering', 'draining'},
            'reconciling': {'observing', 'executing', 'waiting_input', 'verifying', 'recovering', 'draining'},
            'executing': {'reconciling', 'recovering', 'draining'},
            'waiting_input': {'reconciling', 'draining'},
            'verifying': {'observing', 'recovering', 'draining'},
            'recovering': {'starting', 'planning', 'verifying', 'reconciling', 'executing', 'draining'},
            'draining': {'finished'}, 'finished': set(),
        }
        for source, destination in itertools.product(Phase, repeat=2):
            with self.subTest(source=source, destination=destination):
                machine = ExecutionMachine(source)
                if destination.value not in edges[source.value]:
                    self.assertNotIn((source, destination), TRANSITIONS)
                    with self.assertRaises(ExecutionStateError): machine.transition(destination)
                    self.assertEqual(machine.phase, source)
                    continue
                rule = TRANSITIONS[source, destination]
                facts = dict.fromkeys(rule.prerequisites, True)
                for missing in rule.prerequisites:
                    for invalid in [False, None, 1, 'true']:
                        with self.assertRaisesRegex(ExecutionStateError, missing):
                            machine.transition(destination, **{**facts, missing: invalid})
                        self.assertEqual(machine.phase, source)
                machine.transition(destination, **facts)
                self.assertEqual(machine.phase, destination)

    def test_all_effect_permissions_and_pending_receipt_guards(self):
        for phase in Phase:
            for effect in set().union(*EFFECTS.values()):
                with self.subTest(phase=phase, effect=effect):
                    machine = ExecutionMachine(phase)
                    if effect in EFFECTS[phase]: machine.require(effect)
                    else:
                        with self.assertRaises(ExecutionStateError): machine.require(effect)
        machine = ExecutionMachine(Phase.EXECUTING)
        machine.dispatch('logical-action')
        with self.assertRaises(ExecutionStateError): machine.dispatch('duplicate')
        machine.reconcile()
        for destination in [Phase.OBSERVING, Phase.EXECUTING, Phase.WAITING_INPUT, Phase.VERIFYING]:
            with self.assertRaisesRegex(ExecutionStateError, 'reconciled'):
                machine.transition(destination, decision=True, preflight=True, secure_target=True)
        for effect in ['execute', 'plan', 'verify', 'complete']:
            with self.assertRaises(ExecutionStateError): machine.require(effect)
        with self.assertRaisesRegex(ExecutionStateError, 'pending work'): machine.resolve('other-task')
        self.assertEqual(machine.pending_action, 'logical-action')
        machine.resolve('logical-action')
        machine.transition(Phase.OBSERVING)

    def test_stop_is_admissible_from_every_live_state_and_completion_is_once(self):
        for phase in Phase:
            machine = ExecutionMachine(phase)
            machine.drain(); machine.drain()
            self.assertEqual(machine.phase, Phase.FINISHED if phase == Phase.FINISHED else Phase.DRAINING)
        machine = ExecutionMachine(Phase.VERIFYING)
        machine.complete()
        self.assertTrue(machine.completion_published)
        with self.assertRaises(ExecutionStateError): machine.complete()
        with self.assertRaises(ExecutionStateError): machine.transition(Phase.FINISHED)
        machine.transition(Phase.FINISHED, cleanup=True)

    def test_a_phase_cannot_dispatch_twice_even_after_a_successful_receipt(self):
        machine = ExecutionMachine(Phase.EXECUTING)
        machine.dispatch('first'); machine.resolve('first')
        with self.assertRaisesRegex(ExecutionStateError, 'single action'): machine.dispatch('second')
        machine.reconcile()
        machine.transition(Phase.EXECUTING, decision=True, preflight=True)
        machine.dispatch('second')
        self.assertEqual(machine.pending_action, 'second')

    def test_contexts_own_mutable_state_and_helpers_restore_standalone_defaults(self):
        first, second = (TaskContext('fixture', 1, str(uuid.uuid4())) for _ in range(2))
        fallback = dict(runtime._receipt_metrics)
        token = current_task.set(first)
        try:
            runtime._task_value('receipt_metrics')['receipt_queries'] = 7
            runtime._set_task_value('bridge_observation_revision', 'first-only')
            first.command_capabilities['fixture'] = {}
            first.history.append({'action': 'fixture'})
            self.assertEqual(first.receipt_metrics['receipt_queries'], 7)
            other = current_task.set(second)
            try:
                self.assertEqual(runtime._task_value('receipt_metrics')['receipt_queries'], 0)
                self.assertIsNone(runtime._task_value('bridge_observation_revision'))
                self.assertFalse(second.command_capabilities or second.history)
                with self.assertRaisesRegex(ExecutionStateError, 'already owns'):
                    runtime.run_task('nested', 2, None, '')
            finally: current_task.reset(other)
        finally: current_task.reset(token)
        self.assertEqual(runtime._receipt_metrics, fallback)
        self.assertIsNone(current_task.get())


class ExecutionBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.context = TaskContext('fixture', 1, str(uuid.uuid4()))
        self.token = current_task.set(self.context)
        self.addCleanup(current_task.reset, self.token)
        self.action = {'type': 'write_file', 'path': '/fixture/x', 'content': 'x'}
        self.action_id = str(uuid.uuid4())

    def test_wrong_phase_never_reaches_bridge_or_model(self):
        with mock.patch.object(runtime, 'bridge_exchange') as exchange:
            for phase in Phase:
                self.context.machine.phase = phase
                if phase in {Phase.EXECUTING, Phase.WAITING_INPUT}: continue
                with self.subTest(phase=phase), self.assertRaises(ExecutionStateError):
                    runtime.bridge_call('act', 1, action=self.action)
            exchange.assert_not_called()
        self.context.machine.phase = Phase.RECONCILING
        client = mock.Mock()
        with self.assertRaises(ExecutionStateError):
            runtime.routed_json_prompt(mock.Mock(), client, 'fixture', Path('/nonexistent'))
        client.prompt.assert_not_called()
        self.context.machine.phase = Phase.VERIFYING
        with mock.patch.object(runtime, 'emit') as emit:
            with self.assertRaises(ExecutionStateError):
                runtime.request_and_enter_user_input({}, 1)
            emit.assert_not_called()

    def test_stop_revokes_before_terminating_only_the_owned_process(self):
        self.context.machine.phase = Phase.RECONCILING
        owned, standalone = mock.Mock(), mock.Mock()
        owned.poll.return_value = None
        owned.terminate.side_effect = lambda: self.assertEqual(self.context.machine.phase, Phase.DRAINING)
        self.context.active_acp_process = owned
        with mock.patch.object(runtime, '_active_acp_process', standalone):
            with self.assertRaises(SystemExit): runtime._stop_handler(signal.SIGTERM, None)
        owned.terminate.assert_called_once()
        standalone.terminate.assert_not_called()

    def test_lost_reply_must_reconcile_before_another_dispatch(self):
        self.context.machine.phase = Phase.EXECUTING
        calls = []
        def exchange(method, display, params, timeout):
            calls.append((method, self.context.machine.phase, params['action_id']))
            if method == 'act': raise BridgeReplyLost('lost')
            with self.assertRaises(ExecutionStateError):
                runtime.bridge_call('act', 1, action=self.action)
            return {'ok': True, 'result': {'action_id': self.action_id, 'state': 'confirmed',
                                         'terminal': True, 'result': native_result(self.action)}}
        with mock.patch.object(runtime, 'bridge_exchange', side_effect=exchange):
            runtime.bridge_call('act', 1, action=self.action, action_id=self.action_id)
        self.assertEqual(calls, [('act', Phase.EXECUTING, self.action_id),
                                 ('action_receipt', Phase.RECONCILING, self.action_id)])
        self.assertIsNone(self.context.machine.pending_action)
        self.assertEqual(self.context.machine.phase, Phase.RECONCILING)

    def test_nonterminal_error_without_header_remains_pending_until_receipt(self):
        self.context.machine.phase = Phase.EXECUTING
        replies = [dict(ok=False, **native_failure('still_running', outcome='dispatched')),
                   {'ok': True, 'result': {'action_id': self.action_id, 'state': 'unknown', 'terminal': False}}]
        with mock.patch.object(runtime, 'bridge_exchange', side_effect=replies):
            with self.assertRaisesRegex(RuntimeError, 'unknown'):
                runtime.bridge_call('act', 1, action=self.action, action_id=self.action_id)
        self.assertEqual(self.context.machine.pending_action, self.action_id)
        self.assertEqual(self.context.machine.phase, Phase.RECONCILING)

    def test_malformed_result_does_not_release_pending_action(self):
        self.context.machine.phase = Phase.EXECUTING
        reply = {'ok': True, 'result': {'outcome': 'verified'}, 'action_receipt': {
            'action_id': self.action_id, 'state': 'confirmed', 'terminal': True}}
        with mock.patch.object(runtime, 'bridge_exchange', return_value=reply):
            with self.assertRaises(runtime.NativeProtocolError):
                runtime.bridge_call('act', 1, action=self.action, action_id=self.action_id)
        self.assertEqual(self.context.machine.pending_action, self.action_id)
        with self.assertRaises(ExecutionStateError): self.context.machine.require('execute')

    def test_pointer_presentation_uses_the_native_action_receipt_id(self):
        self.context.machine.phase = Phase.EXECUTING
        action = {'type': 'click', 'pid': 42, 'x': 500, 'y': 500}
        action_id = str(uuid.uuid4())
        result = native_result(action)
        response = {'ok': True, 'result': result, 'action_receipt': {
            'action_id': action_id, 'state': 'unconfirmed', 'terminal': True}}
        with mock.patch.object(runtime, 'bridge_exchange', return_value=response):
            runtime.bridge_call('act', 1, action=action, action_id=action_id)
        self.assertEqual(self.context.presentation_action_id, action_id)
        self.assertIsNone(self.context.machine.pending_action)

    def test_non_pointer_action_does_not_claim_a_live_view_presentation(self):
        self.context.machine.phase = Phase.EXECUTING
        action = {'type': 'write_file', 'path': '/fixture/file', 'content': 'value'}
        action_id = str(uuid.uuid4())
        result = native_result(action)
        response = {'ok': True, 'result': result, 'action_receipt': {
            'action_id': action_id, 'state': 'confirmed', 'terminal': True}}
        with mock.patch.object(runtime, 'bridge_exchange', return_value=response):
            runtime.bridge_call('act', 1, action=action, action_id=action_id)
        self.assertIsNone(self.context.presentation_action_id)


class TaskDispatcherTests(unittest.TestCase):
    def exercise(self, *, lost=False, disconnected=False, stop_after_rejection=False, startup_failure=False):
        task = 'Write marker to the fixture file'
        action = {'type': 'write_file', 'path': '/fixture/marker', 'content': 'marker'}
        test = self
        contexts, events, native_calls, phases = [], [], [], []
        state = mock.Mock()
        class Client(VerificationSessions):
            prompt_calls = model_switches = 0
            selected_model = None
            def select_model(self, model): self.selected_model = model
            def prompt(self, instruction, image):
                self.prompt_calls += 1
                if instruction == 'verify':
                    if stop_after_rejection: return json.dumps({'verified': False, 'missing': ['Marker missing']})
                    return json.dumps(proof_response(contexts[0].ledger))
                if stop_after_rejection: return json.dumps(with_requirements({'status': 'done'}, task))
                return json.dumps(with_requirements({'status': 'act', 'action': action, 'finish_after_action': True}, task))
            def close(self): self.closed = True
        client = Client()
        router = runtime.AdaptiveModelRouter(lambda *a, **kw: None)
        original = ExecutionMachine.transition
        def transition(machine, destination, **facts):
            original(machine, destination, **facts)
            phases.append(destination)
        def prepare(*args):
            contexts.append(current_task.get())
            if startup_failure: raise RuntimeError('fixture startup failure')
            return state
        with tempfile.TemporaryDirectory() as directory:
            frames = 0
            receipt = None
            def exchange(method, display, params, timeout):
                nonlocal frames, receipt
                native_calls.append(method)
                c = current_task.get()
                if method == 'completion_gate': return {'ok': True, 'result': {'accepted': True, 'pending_correction': False}}
                if method == 'act':
                    receipt = {'action_id': params['action_id'], 'state': 'confirmed', 'terminal': True,
                               'result': native_result(params['action'])}
                    test.assertEqual(c.machine.phase, Phase.EXECUTING)
                    if lost or disconnected: raise BridgeReplyLost('fixture dropped response', connected=not disconnected)
                    return {'ok': True, 'result': receipt['result'], 'action_receipt': {k: receipt[k] for k in ['action_id','state','terminal']}}
                if method == 'action_receipt':
                    test.assertEqual(c.machine.phase, Phase.RECONCILING)
                    return {'ok': True, 'result': receipt}
                test.assertEqual(method, 'observe')
                if stop_after_rejection and any(e.get('action') == 'completion_rejected' for e in c.history):
                    runtime._stop_handler(signal.SIGTERM, None)
                frames += 1
                path = Path(directory) / f'{frames}.png'; path.write_bytes(b'fixture')
                return {'ok': True, 'result': {**fixture_coordinates(str(frames)),
                    'task_generation_id': c.generation, 'observation_revision': str(frames),
                    'screenshot_path': str(path), 'elements': [], 'applications': []}}
            with contextlib.ExitStack() as stack:
                for name, value in [('find_openclaw', lambda path: 'fixture'), ('prepare_runtime', prepare),
                    ('ACPClient', lambda path: client), ('TaskModelRouter', lambda **kw: router),
                    ('bridge_exchange', exchange), ('desktop_instruction', lambda *a: 'plan'),
                    ('verification_instruction', lambda *a: 'verify'), ('secure_input_target', lambda *a: None),
                    ('record_action_diagnostic', lambda *a: None), ('emit', lambda kind, **kw: events.append((kind, kw)))]:
                    stack.enter_context(mock.patch.object(runtime, name, side_effect=value))
                stack.enter_context(mock.patch.object(ExecutionMachine, 'transition', new=transition))
                if disconnected:
                    with self.assertRaises(BridgeReplyLost): runtime.run_task(task, 1, 'fixture', '')
                elif stop_after_rejection:
                    with self.assertRaises(SystemExit): runtime.run_task(task, 1, 'fixture', '')
                elif startup_failure:
                    with self.assertRaisesRegex(RuntimeError, 'startup failure'): runtime.run_task(task, 1, 'fixture', '')
                else: runtime.run_task(task, 1, 'fixture', '')
            self.assertFalse(list(Path(directory).glob('*.png')))
        self.assertIsNone(current_task.get())
        self.assertEqual(contexts[0].machine.phase, Phase.FINISHED)
        if not startup_failure: self.assertTrue(client.closed)
        return contexts[0], client, router, native_calls, phases, events, state

    def test_healthy_task_has_one_plan_and_existing_verifier(self):
        c, client, router, calls, phases, events, _ = self.exercise()
        self.assertEqual(client.prompt_calls, 2)
        self.assertEqual((router.metrics['planning'], router.metrics['verification']), (1, 1))
        self.assertEqual(calls.count('act'), 1)
        self.assertEqual(sum(k == 'complete' for k, _ in events), 1)
        self.assertEqual(phases, [Phase.OBSERVING, Phase.PLANNING, Phase.RECONCILING,
            Phase.EXECUTING, Phase.RECONCILING, Phase.VERIFYING, Phase.DRAINING, Phase.FINISHED])

    def test_transport_loss_recovers_receipt_without_replay_or_extra_model_call(self):
        c, client, _, calls, _, events, _ = self.exercise(lost=True)
        self.assertEqual(calls.count('act'), 1)
        self.assertEqual(calls.count('action_receipt'), 1)
        self.assertEqual(client.prompt_calls, 2)
        self.assertEqual(c.receipt_metrics['receipt_recoveries'], 1)
        self.assertIsNone(c.machine.pending_action)
        self.assertEqual(sum(k == 'complete' for k, _ in events), 1)

    def test_disconnected_execution_drains_with_unresolved_receipt(self):
        c, client, _, calls, phases, events, state = self.exercise(disconnected=True)
        self.assertEqual(calls, ['observe', 'act'])
        self.assertEqual(client.prompt_calls, 1)
        self.assertIsNotNone(c.machine.pending_action)
        self.assertEqual(phases[-3:], [Phase.RECONCILING, Phase.DRAINING, Phase.FINISHED])
        self.assertFalse(any(k == 'complete' for k, _ in events))
        state.invalidate.assert_called_once()

    def test_completion_rejection_followed_by_stop_never_plans_or_executes_again(self):
        c, client, _, calls, phases, events, state = self.exercise(stop_after_rejection=True)
        self.assertEqual(client.prompt_calls, 2)
        self.assertNotIn('act', calls)
        self.assertEqual(phases[-4:], [Phase.VERIFYING, Phase.OBSERVING, Phase.DRAINING, Phase.FINISHED])
        self.assertFalse(any(k == 'complete' for k, _ in events))
        state.invalidate.assert_called_once()

    def test_failed_startup_still_drains_and_releases_context(self):
        _, client, _, calls, phases, _, _ = self.exercise(startup_failure=True)
        self.assertFalse(calls)
        self.assertEqual(client.prompt_calls, 0)
        self.assertEqual(phases, [Phase.DRAINING, Phase.FINISHED])

    def test_native_pause_during_receipt_recovery_preserves_phase_and_pending_work(self):
        # SIGSTOP is the existing native Pause protocol, not a new controller or
        # UI. A fake receipt wait demonstrates that Resume cannot lose its gate.
        code = '''
import sys
from task_execution import ExecutionMachine, ExecutionStateError, Phase
m = ExecutionMachine(Phase.EXECUTING)
m.dispatch('pending-mutation'); m.reconcile()
print('recovering', flush=True)
sys.stdin.readline()
assert m.phase == Phase.RECONCILING and m.pending_action == 'pending-mutation'
try: m.dispatch('duplicate')
except ExecutionStateError: pass
else: raise AssertionError('replayed')
m.resolve('pending-mutation'); m.transition(Phase.OBSERVING)
print(m.phase.value, flush=True)
'''
        process = subprocess.Popen([sys.executable, '-u', '-c', code], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, 'PYTHONPATH': str(Path(runtime.__file__).parent)})
        try:
            self.assertEqual(process.stdout.readline().strip(), 'recovering')
            os.kill(process.pid, signal.SIGSTOP)
            # Wait for the kernel's stop acknowledgement, not an arbitrary delay.
            deadline = time.monotonic() + 2
            while True:
                pid, status = os.waitpid(process.pid, os.WUNTRACED | os.WNOHANG)
                if pid:
                    self.assertTrue(os.WIFSTOPPED(status)); break
                if time.monotonic() >= deadline: self.fail('fixture did not pause')
                time.sleep(.005)
            process.stdin.write('receipt\n'); process.stdin.flush()
            self.assertEqual(select.select([process.stdout], [], [], .05)[0], [])
            os.kill(process.pid, signal.SIGCONT)
            output, error = process.communicate(timeout=3)
            self.assertEqual((process.returncode, output.strip(), error), (0, 'observing', ''))
        finally:
            if process.poll() is None:
                os.kill(process.pid, signal.SIGCONT); process.kill(); process.wait()
            for stream in [process.stdin, process.stdout, process.stderr]: stream.close()


if __name__ == '__main__': unittest.main()
