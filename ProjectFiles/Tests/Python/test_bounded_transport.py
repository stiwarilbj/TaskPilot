"""Offline transport faults only: no providers, desktop actions or browsers."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
from action_receipts import RuntimeInbox, BridgeReplyLost
from bounded_transport import ACPTransport, RequestTransport, LineFramer, TransportFailure, read_frames, write_frame
from evidence_fixtures import native_result


class BoundedTransportTests(unittest.TestCase):
    def test_fragmented_utf8_and_eof_preserve_complete_frames(self):
        payload = '☃ 🧭'.encode()
        framer = LineFramer(16); frames = []; errors = []
        for byte in payload + b'\nlast':
            framer.feed(bytes([byte]), frames.append, errors.append)
        framer.feed(b'', frames.append, errors.append, flush=True)
        self.assertEqual(frames, [payload, b'last'])
        self.assertEqual(errors, [])
        self.assertEqual(len(framer.pending), 0)

    def test_exact_limit_then_oversized_unterminated_flood_is_bounded(self):
        framer = LineFramer(64); frames = []; errors = []
        framer.feed(b'x' * 64 + b'\n', frames.append, errors.append)
        for _ in range(10000):
            framer.feed(b'y' * 1024, frames.append, errors.append)
            self.assertLessEqual(len(framer.pending), 64)
        self.assertEqual(frames, [b'x' * 64])
        self.assertEqual([error.code for error in errors], ['transport_frame_limit'])
        framer.feed(b'\nterminal\n', frames.append, errors.append)
        self.assertEqual(frames[-1], b'terminal')

    def test_reader_does_not_use_unbounded_readline(self):
        class Stream(io.StringIO):
            def readline(self, *args): raise AssertionError('unbounded readline')
            def read(self, count):
                self_limit = 65536
                assert count <= self_limit
                return super().read(count)
        frames = []; errors = []
        read_frames(Stream('x' * 100000 + '\n{}'), frames.append, errors.append, frame_limit=32)
        self.assertEqual(frames, [b'{}'])
        self.assertEqual(errors[0].code, 'transport_frame_limit')

    def test_replies_route_directly_out_of_order(self):
        transport = ACPTransport()
        for key in [1, 2]: transport.register(key)
        transport.route({'id': 2, 'result': {'two': True}})
        transport.route({'id': 1, 'error': {'code': 401}})
        self.assertEqual(transport.get(1, 0)['error']['code'], 401)
        self.assertTrue(transport.get(2, 0)['result']['two'])
        self.assertEqual((transport.bytes, transport.count), (0, 0))

    def test_unknown_retired_and_cross_session_flood_retains_nothing(self):
        transport = ACPTransport()
        transport.register(2, method='session/prompt', session='current')
        for _ in range(10000):
            transport.route({'id': 1, 'result': {}})
            transport.route({'method': 'session/update', 'params': {'sessionId': 'old', 'update': {'sessionUpdate': 'error'}}})
            transport.route({'method': 'session/update', 'params': {'sessionId': 'current', 'requestId': 1}})
        self.assertEqual((transport.bytes, transport.count), (0, 0))
        transport.unregister(2)
        transport.route({'id': 2, 'result': {}})
        self.assertEqual(len(transport.pending), 0)

    def test_chunks_errors_and_terminal_order_survive_eof(self):
        transport = ACPTransport(); transport.register(1, method='session/prompt', session='s')
        messages = [{'method': 'session/update', 'params': {'sessionId': 's', 'update': {'sessionUpdate': kind}}}
                    for kind in ['agent_message_chunk', 'error', 'agent_message_chunk']]
        for message in messages: transport.route(message)
        terminal = {'id': 1, 'result': {'stopReason': 'end_turn'}}
        transport.route(terminal); transport.close()
        self.assertEqual([transport.get(1, 0) for _ in range(4)], messages + [terminal])
        with self.assertRaises(TransportFailure): transport.get(1, 0)

    def test_redundant_status_coalesces_even_after_consumption(self):
        transport = ACPTransport(); transport.register(1, method='session/prompt', session='s')
        status = {'method': 'session/update', 'params': {'sessionId': 's', 'update': {'sessionUpdate': 'tool_call', 'title': 'same'}}}
        transport.route(status); self.assertEqual(transport.get(1, 0), status)
        for _ in range(10000): transport.route(status)
        self.assertEqual((transport.bytes, transport.count), (0, 0))
        self.assertIsInstance(transport.pending[1].last_status, bytes)
        self.assertEqual(len(transport.pending[1].last_status), 32)

    def test_identical_response_chunks_are_never_coalesced(self):
        transport = ACPTransport(); transport.register(1, method='session/prompt', session='s')
        chunk = {'method': 'session/update', 'params': {'sessionId': 's', 'update': {'sessionUpdate': 'agent_message_chunk', 'content': {'text': 'a'}}}}
        for _ in range(4): transport.route(chunk)
        self.assertEqual([transport.get(1, 0) for _ in range(4)], [chunk] * 4)

    def test_terminal_has_reserved_bytes_and_message_slot(self):
        transport = RequestTransport(byte_limit=100, reserve_bytes=40, message_limit=2)
        transport.register('a')
        for value in ['one', 'two']: self.assertTrue(transport.put('a', value, size=30))
        self.assertTrue(transport.put('a', 'complete', size=40, terminal=True))
        self.assertEqual(transport.bytes, 100)
        self.assertEqual([transport.get('a', 0) for _ in range(3)], ['one', 'two', 'complete'])
        self.assertFalse(transport.put('a', 'late'))

    def test_overflow_is_classified_without_silently_truncating(self):
        for limit in ['bytes', 'messages']:
            with self.subTest(limit=limit):
                transport = RequestTransport(byte_limit=100, reserve_bytes=40, message_limit=1 if limit == 'messages' else 10)
                transport.register(1)
                transport.put(1, 'chunk', size=40)
                self.assertFalse(transport.put(1, 'chunk', size=40))
                self.assertTrue(transport.put(1, 'terminal', size=30, terminal=True))
                self.assertEqual(transport.pending[1].terminal[0], 'terminal')
                with self.assertRaises(TransportFailure) as caught: transport.get(1, 0)
                self.assertEqual(caught.exception.code, 'transport_buffer_limit')
                transport.unregister(1)
                self.assertEqual((transport.bytes, transport.count), (0, 0))

    def test_request_limit_and_duplicate_registration_are_bounded(self):
        transport = RequestTransport(request_limit=1); transport.register(1)
        for key, code in [(1, 'transport_duplicate_request'), (2, 'transport_request_limit')]:
            with self.assertRaises(TransportFailure) as caught: transport.register(key)
            self.assertEqual(caught.exception.code, code)

    def test_trailing_noise_does_not_replace_an_intact_terminal(self):
        transport = RequestTransport(); transport.register(1)
        transport.put(1, 'complete', terminal=True)
        transport.fail(TransportFailure('transport_malformed_frame'))
        transport.close()
        self.assertEqual(transport.get(1, 0), 'complete')

    def test_waiters_wake_on_close_without_polling(self):
        transport = RequestTransport(); transport.register(1)
        done = threading.Event()
        def wait():
            try: transport.get(1)
            except TransportFailure as error: self.assertFalse(error.connected)
            finally: done.set()
        thread = threading.Thread(target=wait); thread.start()
        transport.close()
        self.assertTrue(done.wait(1)); thread.join(1)

    def test_pending_acp_request_waits_after_partial_output_until_terminal(self):
        client = runtime.ACPClient.__new__(runtime.ACPClient)
        client.transport = ACPTransport(); client.next_request_id = 1
        client.session_id = 's'; client.agent_chunks = []; client.turn_errors = []
        client.accepting_prompt_updates = True
        partial = threading.Event(); finished = threading.Event(); result = []
        def send(_):
            client.transport.route({'method': 'session/update', 'params': {'sessionId': 's', 'update': {
                'sessionUpdate': 'agent_message_chunk', 'content': {'text': '{"status":'}}}})
            partial.set()
        client._send = mock.Mock(side_effect=send)
        def wait():
            result.append(client.request('session/prompt', {'sessionId': 's'}, None)); finished.set()
        thread = threading.Thread(target=wait); thread.start()
        try:
            self.assertTrue(partial.wait(1))
            self.assertFalse(finished.wait(0.03))
            client.transport.route({'id': 1, 'result': {'stopReason': 'end_turn'}})
            self.assertTrue(finished.wait(1))
            self.assertEqual(result, [{'stopReason': 'end_turn'}])
            self.assertEqual(client.agent_chunks, ['{"status":'])
            self.assertEqual(client._send.call_count, 1)
        finally:
            client.transport.close(); thread.join(1)

    def test_native_replies_and_secure_input_keep_their_own_slots(self):
        lines = [{'kind': 'status', 'message': 'noise'}] * 10000 + [
            {'kind': 'user_input_response', 'request_id': 'secure', 'task_generation_id': 'task', 'value': 'fixture'},
            {'kind': 'bridge_response', 'request_id': 'bridge', 'task_generation_id': 'task', 'ok': True}]
        inbox = RuntimeInbox(io.StringIO('\n'.join(map(json.dumps, lines))))
        action = inbox.register('bridge_response', 'bridge', 'task')
        secure = inbox.register('user_input_response', 'secure', 'task')
        self.assertTrue(json.loads(inbox.read(2, key=action))['ok'])
        self.assertEqual(json.loads(inbox.read(2, key=secure))['value'], 'fixture')
        self.assertEqual(inbox.transport.bytes, 0)

    def test_malformed_and_non_object_native_frames_have_no_default_meaning(self):
        for value in ['{bad}', '[]', '\ufffd']:
            inbox = RuntimeInbox(io.StringIO(value + '\n'))
            with self.assertRaises(BridgeReplyLost) as caught: inbox.read(1)
            self.assertEqual(caught.exception.code, 'transport_malformed_frame')

    def test_blocked_write_has_a_deadline_and_cancellation_bypasses_it(self):
        read_fd, write_fd = os.pipe()
        stream = os.fdopen(write_fd, 'wb', buffering=0)
        try:
            os.set_blocking(write_fd, False)
            with contextlib.suppress(BlockingIOError):
                while True: os.write(write_fd, b'x' * 4096)
            started = time.monotonic()
            with self.assertRaises(TransportFailure) as caught: write_frame(stream, {'x': 1}, timeout=0.03)
            self.assertEqual(caught.exception.code, 'transport_write_timeout')
            self.assertLess(time.monotonic() - started, 1)
            with self.assertRaises(TransportFailure) as caught: write_frame(stream, {}, cancelled=lambda: True)
            self.assertEqual(caught.exception.code, 'transport_cancelled')
        finally:
            stream.close(); os.close(read_fd)

    def test_transport_failure_is_never_classified_as_format_repair(self):
        for code in ['transport_frame_limit', 'transport_buffer_limit', 'transport_write_timeout']:
            failure = runtime.classify_failure(TransportFailure(code), 0)
            self.assertEqual(failure.kind, 'transport')
            self.assertEqual(failure.code, code)

    def test_malformed_request_id_cannot_escape_reader_or_alias_an_integer(self):
        for key in [True, [], {}]:
            transport = ACPTransport(); transport.register(1)
            transport.route({'id': key, 'result': {}})
            with self.assertRaises(TransportFailure) as caught: transport.get(1, 0)
            self.assertEqual(caught.exception.code, 'transport_invalid_request_id')

    def test_malformed_terminal_envelopes_cannot_authorize_success(self):
        for response in [{'result': True}, {'result': {}, 'error': {}}, {'error': 'invalid envelope'}]:
            transport = ACPTransport(); transport.register(1)
            transport.route({'id': 1, **response})
            with self.assertRaises(TransportFailure) as caught: transport.get(1, 0)
            self.assertEqual(caught.exception.code, 'transport_malformed_envelope')

    def test_accumulated_response_chunks_and_errors_are_bounded(self):
        for kind in ['agent_message_chunk', 'error']:
            client = runtime.ACPClient.__new__(runtime.ACPClient)
            client.session_id = 's'; client.agent_chunks = []; client.turn_errors = []
            message = {'method': 'session/update', 'params': {'sessionId': 's', 'update': {
                'sessionUpdate': kind, 'content': {'text': 'x' * 80}, 'message': 'x' * 80}}}
            with mock.patch.object(runtime, 'FRAME_BYTES', 128):
                with self.assertRaises(TransportFailure):
                    for _ in range(3): client._handle_server_message(message)

    def test_lost_native_frame_reconciles_once_without_redispatch(self):
        read_fd, write_fd = os.pipe(); stream = os.fdopen(read_fd, 'r')
        action = {'type': 'write_file', 'path': '/fixture/proof', 'content': 'fixture'}
        action_id = 'a710196f-89ed-4762-8df1-1b8b6f20db58'
        calls = []; metrics = {'receipt_queries': 0, 'receipt_recoveries': 0, 'receipt_unresolved': 0}
        def emit(kind, **payload):
            if kind != 'bridge_request': return
            calls.append(payload['method'])
            if payload['method'] == 'act': os.write(write_fd, b'x' * 4097 + b'\n')
            else:
                receipt = {'action_id': action_id, 'state': 'confirmed', 'terminal': True, 'result': native_result(action)}
                reply = dict(kind='bridge_response', request_id=payload['request_id'], task_generation_id='task', ok=True, result=receipt)
                os.write(write_fd, json.dumps(reply).encode() + b'\n')
        real_reader = read_frames
        try:
            with mock.patch.object(sys, 'stdin', stream), mock.patch.object(runtime, '_runtime_inbox', None), \
                 mock.patch.object(runtime, '_task_generation_id', 'task'), mock.patch.object(runtime, '_receipt_metrics', metrics), \
                 mock.patch.object(runtime, 'emit', side_effect=emit), \
                 mock.patch('action_receipts.read_frames', side_effect=lambda *a: real_reader(*a, frame_limit=4096)):
                result = runtime.bridge_call('act', 1, action=action, action_id=action_id)
            self.assertTrue(result['verified'])
            self.assertEqual(calls, ['act', 'action_receipt'])
            self.assertEqual(metrics['receipt_recoveries'], 1)
        finally:
            os.close(write_fd); stream.close()

    def test_real_offline_acp_status_flood_preserves_chunks_and_exit_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'fake-acp'
            executable.write_text('#!' + sys.executable + '\n' + '''import json, sys
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method == 'initialize': result = {'protocolVersion': 1}
    elif method == 'session/new': result = {'sessionId': 'fixture', 'configOptions': []}
    elif method == 'session/prompt':
        update = {'method':'session/update','params':{'sessionId':'fixture','update':{'sessionUpdate':'tool_call','title':'fixture'}}}
        for _ in range(10000): print(json.dumps(update))
        update['params']['update'] = {'sessionUpdate':'agent_message_chunk','content':{'text':'{"status":"done"}'}}
        print(json.dumps(update))
        print(json.dumps({'id':request['id'],'result':{'stopReason':'end_turn'}}), end='', flush=True)
        sys.exit(0)
    else: continue
    print(json.dumps({'id':request['id'],'result':result}), flush=True)
''')
            executable.chmod(0o700)
            image = Path(directory) / 'fixture.png'; image.write_bytes(b'offline')
            with mock.patch.object(runtime, 'emit') as emit, mock.patch.object(runtime, 'session_transcript_cursor', return_value=None):
                client = runtime.ACPClient(str(executable))
                try:
                    self.assertEqual(client.prompt('fixture', image), '{"status":"done"}')
                    self.assertEqual(client.prompt_calls, 1)
                    self.assertEqual(client.transport.bytes, 0)
                    self.assertEqual(emit.call_count, 1)
                finally: client.close()

    def test_oversized_real_acp_frame_stops_child_before_reporting_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'fake-acp'
            executable.write_text('#!' + sys.executable + '\n' + '''import json, sys, time
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method == 'initialize': result = {'protocolVersion': 1}
    elif method == 'session/new': result = {'sessionId': 'fixture', 'configOptions': []}
    elif method == 'session/prompt':
        sys.stdout.write('x' * (8*1024*1024+1)); sys.stdout.flush(); time.sleep(20)
        continue
    else: continue
    print(json.dumps({'id':request['id'],'result':result}), flush=True)
''')
            executable.chmod(0o700)
            image = Path(directory) / 'fixture.png'; image.write_bytes(b'offline')
            with mock.patch.object(runtime, 'session_transcript_cursor', return_value=None):
                client = runtime.ACPClient(str(executable))
                try:
                    started = time.monotonic()
                    with self.assertRaises(TransportFailure) as caught: client.prompt('fixture', image)
                    self.assertEqual(caught.exception.code, 'transport_frame_limit')
                    self.assertIsNotNone(client.process.poll())
                    self.assertLess(time.monotonic() - started, 4)
                    self.assertEqual(client.prompt_calls, 1)
                    self.assertEqual(client.transport.bytes, 0)
                finally: client.close()
