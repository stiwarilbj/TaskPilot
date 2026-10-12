import io
import hashlib
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest import mock
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
from coordinate_fixtures import fixture_coordinates
from action_receipts import BridgeReplyLost, RuntimeInbox


class ActionReceiptTests(unittest.TestCase):
    def setUp(self):
        self.action_id = str(uuid.uuid4())
        self.generation = str(uuid.uuid4())
        self.now = 0.0
        self.calls = []
        self.action = {'type': 'write_file', 'path': '/fixture/note', 'content': 'X', 'mode': 'append'}
        self.metrics = dict(receipt_queries=0, receipt_recoveries=0, receipt_unresolved=0)
        for name, value in [('_task_generation_id', self.generation), ('_receipt_metrics', self.metrics),
                            ('_bridge_observation_revision', 'current')]:
            patch = mock.patch.object(runtime, name, value)
            patch.start(); self.addCleanup(patch.stop)

    def receipt(self, state='confirmed', **fields):
        return dict(action_id=self.action_id, state=state, terminal=state not in {'pending', 'dispatched', 'unknown'}, **fields)

    def lost(self, *receipts, connected=True):
        replies = iter(receipts)
        def exchange(method, display, params, timeout):
            self.calls.append((method, dict(params), timeout))
            if method == 'act':
                raise BridgeReplyLost('fixture lost reply', connected=connected)
            return {'ok': True, 'result': next(replies)}
        return exchange

    def execute(self, exchange):
        with mock.patch.object(runtime, 'bridge_exchange', side_effect=exchange), \
             mock.patch.object(runtime.time, 'monotonic', side_effect=lambda: self.now), \
             mock.patch.object(runtime.time, 'sleep', side_effect=lambda seconds: setattr(self, 'now', self.now + seconds)):
            return runtime.bridge_call('act', 1, action=self.action, action_id=self.action_id)

    def assert_once(self):
        self.assertEqual(sum(method == 'act' for method, _, _ in self.calls), 1)
        for method, params, _ in self.calls:
            self.assertEqual(params['action_id'], self.action_id)
            if method == 'action_receipt': self.assertNotIn('action', params)

    def test_healthy_reply_needs_no_receipt_queries_or_model_calls(self):
        def exchange(method, display, params, timeout):
            self.calls.append((method, params, timeout))
            return {'ok': True, 'result': {'verified': True}, 'action_receipt': self.receipt()}
        self.assertEqual(self.execute(exchange), {'verified': True})
        self.assert_once()
        self.assertEqual(self.metrics, dict(receipt_queries=0, receipt_recoveries=0, receipt_unresolved=0))

    def test_lost_confirmed_reply_is_recovered_without_replaying_append(self):
        result = {'verified': True, 'path': '/fixture/note', 'bytes_written': 1, 'mode': 'append'}
        self.assertEqual(self.execute(self.lost(self.receipt(result=result))), result)
        self.assert_once()
        self.assertEqual(self.metrics['receipt_queries'], 1)
        self.assertEqual(self.metrics['receipt_recoveries'], 1)

    def test_pending_work_is_polled_until_its_terminal_reply(self):
        result = {'exit_code': 0, 'timed_out': False, 'verified': False}
        self.action = {'type': 'run_command', 'argv': ['fixture'], 'timeout_seconds': 120}
        self.assertEqual(self.execute(self.lost(self.receipt('pending'), self.receipt('dispatched'), self.receipt(result=result))), result)
        self.assert_once()
        self.assertEqual(self.calls[0][2], 150)
        self.assertEqual(self.metrics['receipt_queries'], 3)

    def test_unfinished_work_stops_after_bounded_lookup_and_cannot_overlap(self):
        def exchange(method, display, params, timeout):
            self.calls.append((method, params, timeout))
            if method == 'act': raise BridgeReplyLost('timeout')
            return {'ok': True, 'result': self.receipt('dispatched')}
        with self.assertRaisesRegex(RuntimeError, 'not ended safely'): self.execute(exchange)
        self.assert_once()
        self.assertLessEqual(self.metrics['receipt_queries'], 51)
        self.assertEqual(self.metrics['receipt_unresolved'], 1)

    def test_unknown_mismatched_and_malformed_receipts_never_authorize_replay(self):
        for receipt in [self.receipt('unknown'), {**self.receipt(), 'action_id': 'another'},
                        {**self.receipt(), 'terminal': 1}, self.receipt(result='not an object'),
                        self.receipt('confirmed', result={'outcome': 'delivered_unconfirmed'})]:
            self.calls.clear()
            with self.subTest(receipt=receipt), self.assertRaises(RuntimeError):
                self.execute(self.lost(receipt))
            self.assert_once()

    def test_uncertain_gui_result_requires_fresh_evidence_not_duplicate_input(self):
        self.action = {'type': 'press', 'element_id': 'old:save'}
        outcome = self.execute(self.lost(self.receipt('unconfirmed', result={'outcome': 'delivered_unconfirmed'})))
        self.assertEqual(outcome['outcome'], 'delivered_unconfirmed')
        self.assert_once()
        recovery = runtime.ActionRecovery()
        before = {'elements': [{'id': 'old:save', 'pid': 42, 'title': 'Send', 'window_title': 'Draft'}]}
        after = {'elements': [{'id': 'new:save', 'pid': 42, 'title': 'Send', 'window_title': 'Draft'}]}
        recovery.unconfirmed(self.action, before)
        self.assertEqual(recovery.check({'type': 'click', 'element_id': 'new:save'}, after)['outcome'], 'suppressed')

    def test_terminal_rejection_and_stop_codes_remain_precise(self):
        for state, code in [('rejected', 'stale_target'), ('unconfirmed', 'unsupported_action'),
                            ('unconfirmed', 'cancelled'), ('unconfirmed', 'secure_input')]:
            self.calls.clear()
            with self.subTest(code=code), self.assertRaises(runtime.ActionRejected) as error:
                self.execute(self.lost(self.receipt(state, error='fixture', error_code=code)))
            self.assertEqual(error.exception.code, 'delivery_uncertain' if code == 'unsupported_action' else code)
            self.assert_once()

    def test_disconnected_pipe_cannot_be_repaired_or_replayed(self):
        with self.assertRaises(BridgeReplyLost): self.execute(self.lost(connected=False))
        self.assert_once()
        self.assertEqual(self.metrics['receipt_queries'], 0)

    def test_lost_lookup_reply_also_stops_without_replaying(self):
        def exchange(method, display, params, timeout):
            self.calls.append((method, params, timeout))
            raise BridgeReplyLost('lost')
        with self.assertRaises(BridgeReplyLost): self.execute(exchange)
        self.assert_once()
        self.assertEqual(self.metrics['receipt_unresolved'], 1)

    def test_cancellation_during_receipt_polling_never_delivers_again(self):
        with mock.patch.object(runtime, 'bridge_exchange', side_effect=self.lost(self.receipt('pending'))), \
             mock.patch.object(runtime.time, 'sleep', side_effect=SystemExit(143)):
            with self.assertRaises(SystemExit):
                runtime.bridge_call('act', 1, action=self.action, action_id=self.action_id)
        self.assert_once()

    def test_late_response_and_other_task_receipt_are_rejected_on_the_wire(self):
        replies = [dict(kind='bridge_response', request_id='old-request', task_generation_id=self.generation, ok=True, result={'old': True}),
                   dict(kind='bridge_response', request_id='lookup', task_generation_id='old-task', ok=True, result={'wrong': True}),
                   dict(kind='bridge_response', request_id='lookup', task_generation_id=self.generation, ok=True, result=self.receipt(result={'verified': True}))]
        with mock.patch.object(sys, 'stdin', io.StringIO('\n'.join(map(json.dumps, replies)))), \
             mock.patch.object(runtime.uuid, 'uuid4', return_value='lookup'), mock.patch.object(runtime, 'emit') as emitted:
            result = runtime.bridge_call('action_receipt', 1, action_id=self.action_id, _reply_timeout=1)
        self.assertEqual(result['action_id'], self.action_id)
        self.assertEqual(emitted.call_count, 1)

    def test_one_inbox_preserves_buffered_config_bridge_and_secure_input_lines(self):
        inbox = RuntimeInbox(io.StringIO('config\npartial reply\nsecure value\n'))
        self.assertEqual([inbox.read(1) for _ in range(3)], ['config\n', 'partial reply\n', 'secure value\n'])
        for _ in range(2):
            with self.assertRaises(BridgeReplyLost) as error: inbox.read(1)
            self.assertFalse(error.exception.connected)

    def test_partial_pipe_output_times_out_without_consuming_or_splitting_the_reply(self):
        read_fd, write_fd = os.pipe()
        stream = os.fdopen(read_fd, 'r', encoding='utf-8')
        try:
            inbox = RuntimeInbox(stream)
            os.write(write_fd, b'{"partial":')
            with self.assertRaises(BridgeReplyLost) as error: inbox.read(0.01)
            self.assertTrue(error.exception.connected)
            os.write(write_fd, b'true}\n')
            self.assertEqual(inbox.read(1), '{"partial":true}\n')
        finally:
            os.close(write_fd)
            stream.close()

    def test_invalid_initial_receipt_is_reconciled_instead_of_trusted(self):
        def exchange(method, display, params, timeout):
            self.calls.append((method, dict(params), timeout))
            if method == 'act':
                return {'ok': True, 'action_receipt': {**self.receipt(), 'action_id': 'stale'}, 'result': {'wrong': True}}
            return {'ok': True, 'result': self.receipt(result={'correct': True})}
        self.assertEqual(self.execute(exchange), {'correct': True})
        self.assert_once()
        self.assertEqual(self.metrics['receipt_recoveries'], 1)

    def test_runtime_exits_cleanly_while_the_controller_input_pipe_stays_open(self):
        script = 'import sys; from action_receipts import RuntimeInbox; assert RuntimeInbox(sys.stdin).read(1) == "fixture\\n"'
        child = subprocess.Popen([sys.executable, '-c', script], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, cwd=str(Path(runtime.__file__).parent))
        try:
            child.stdin.write(b'fixture\n')
            child.stdin.flush()
            self.assertEqual(child.wait(timeout=3), 0) # stdin remains open through exit
            self.assertEqual(child.stderr.read(), b'')
        finally:
            if child.poll() is None: child.kill(); child.wait()
            for stream in (child.stdin, child.stdout, child.stderr): stream.close()

    def test_action_id_is_private_and_new_logical_actions_get_distinct_ids(self):
        ids = []
        def exchange(method, display, params, timeout):
            ids.append(params['action_id'])
            return {'ok': True, 'result': {'verified': True}, 'action_receipt': dict(action_id=ids[-1], state='confirmed', terminal=True)}
        with mock.patch.object(runtime, 'bridge_exchange', side_effect=exchange):
            for _ in range(2):
                result = runtime.bridge_call('act', 1, action=self.action)
                self.assertNotIn('action_id', result)
                self.assertNotIn('action_receipt', result)
        self.assertNotEqual(*ids)
        for action_id in ids: self.assertEqual(str(uuid.UUID(action_id)), action_id)

    def test_actual_task_loop_recovers_lost_mutation_reply_with_no_extra_model_call(self):
        task = 'Append X once to /fixture/note.'
        native_receipts, delivered, events = {}, [], []
        router = runtime.AdaptiveModelRouter(lambda *a, **k: None)
        class Client:
            prompt_calls = 0
            model_switches = 0
            selected_model = None
            def select_model(client, model): client.selected_model = model
            def prompt(client, instruction, image):
                client.prompt_calls += 1
                if instruction == 'verify':
                    return json.dumps({'verified': True, 'coverage_complete': True, 'message': 'Append acknowledged',
                        'proofs': [{'requirement_id': key, 'evidence_ids': entry['evidence_ids'],
                                    'rationale': 'Native append receipt acknowledges exact bytes once'}
                                   for key, entry in client.ledger.requirements.items()]})
                return json.dumps({'status': 'act', 'action': self.action, 'finish_after_action': True,
                    'requirements': [{'source': task, 'description': 'Append X exactly once',
                        'check': {**self.action, 'type': 'file_written'}}]})
            def close(client): pass
        client = Client()
        def instruction(task, observation, history, ledger):
            client.ledger = ledger
            return 'plan'
        with tempfile.TemporaryDirectory() as directory:
            frames = 0
            def exchange(method, display, params, timeout):
                nonlocal frames
                if method == 'act':
                    delivered.append(params['action'])
                    native_receipts[params['action_id']] = dict(action_id=params['action_id'], state='confirmed', terminal=True,
                        result=dict(verified=True, path='/fixture/note', mode='append', bytes_written=1,
                                    content_sha256=hashlib.sha256(b'X').hexdigest()))
                    raise BridgeReplyLost('fixture dropped reply')
                if method == 'action_receipt': return {'ok': True, 'result': native_receipts[params['action_id']]}
                self.assertEqual(method, 'observe')
                frames += 1
                image = Path(directory) / f'{frames}.png'
                image.write_bytes(b'fixture')
                return {'ok': True, 'result': dict(**fixture_coordinates(str(frames)), task_generation_id=self.generation,
                    screenshot_path=str(image), observation_revision=str(frames), applications=[], elements=[])}
            with mock.patch.object(runtime, 'find_openclaw', return_value='fixture'), \
                 mock.patch.object(runtime, 'prepare_runtime', return_value=mock.Mock()), \
                 mock.patch.object(runtime, 'ACPClient', return_value=client), \
                 mock.patch.object(runtime, 'TaskModelRouter', return_value=router), \
                 mock.patch.object(runtime, 'bridge_exchange', side_effect=exchange), \
                 mock.patch.object(runtime, 'secure_input_target', return_value=None), \
                 mock.patch.object(runtime, 'desktop_instruction', side_effect=instruction), \
                 mock.patch.object(runtime, 'verification_instruction', return_value='verify'), \
                 mock.patch.object(runtime, 'record_action_diagnostic'), \
                 mock.patch.object(runtime, 'emit', side_effect=lambda kind, **fields: events.append((kind, fields))):
                runtime.run_task(task, 1, 'fixture', '')
        self.assertEqual(len(delivered), 1)
        self.assertEqual(client.prompt_calls, 2) # one planning and the existing final verifier
        self.assertEqual(sum(kind == 'complete' for kind, _ in events), 1)
        accepted = events[:next(index for index, (kind, _) in enumerate(events) if kind == 'complete')]
        self.assertEqual(next(fields for kind, fields in reversed(accepted) if kind == 'request_metrics')['receipt_recoveries'], 1)
        metrics = next(fields for kind, fields in reversed(events) if kind == 'request_metrics')
        self.assertEqual(metrics['receipt_queries'], 1)
        self.assertEqual(metrics['receipt_recoveries'], 1)
        self.assertEqual((metrics['planning'], metrics['verification']), (1, 1))


if __name__ == '__main__': unittest.main()
