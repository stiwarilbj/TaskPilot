"""Offline transport faults only: no providers, desktop actions or browsers."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import random
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


class CountingFrameBuffer(bytearray):
    """Test-only copy accounting; production framing retains no metrics."""
    def __init__(self):
        super().__init__()
        self.extend_calls = self.extended_bytes = 0
        self.materializations = self.materialized_bytes = 0

    def extend(self, value):
        self.extend_calls += 1
        self.extended_bytes += len(value)
        super().extend(value)

    def __bytes__(self):
        self.materializations += 1
        self.materialized_bytes += len(self)
        return bytes(memoryview(self))


class BoundedTransportTests(unittest.TestCase):
    def during_preparation(self, transport, send, operation, *, block_hash=False):
        """Barrier-based contention, not a serialization latency threshold."""
        entered = threading.Event(); release = threading.Event(); completed = threading.Event()
        results = []; failures = []
        original = hashlib.sha256 if block_hash else json.JSONEncoder.iterencode

        def blocked(*args, **kwargs):
            entered.set()
            if not release.wait(3): raise AssertionError('preparation barrier timed out')
            return original(*args, **kwargs)

        def sending():
            try: results.append(send())
            except BaseException as error: failures.append(error)

        def operating():
            try: operation()
            except BaseException as error: failures.append(error)
            finally: completed.set()

        patch = (mock.patch('bounded_transport.hashlib.sha256', side_effect=blocked) if block_hash else
                 mock.patch.object(json.JSONEncoder, 'iterencode', autospec=True, side_effect=blocked))
        with patch:
            sender = threading.Thread(target=sending)
            worker = threading.Thread(target=operating)
            sender.start()
            try:
                self.assertTrue(entered.wait(2))
                worker.start()
                # Admission/retirement must finish while serialization or hashing
                # is still deliberately blocked on a different thread.
                self.assertTrue(completed.wait(2), 'preparation holds the admission lock')
            finally:
                release.set(); sender.join(3)
                if worker.ident is not None: worker.join(3)
        self.assertFalse(sender.is_alive())
        self.assertFalse(worker.is_alive())
        self.assertEqual(failures, [])
        return results

    def test_one_encoding_supplies_default_size_and_status_digest(self):
        message = {'text': 'emoji 🧭, combining e\u0301, control\n', 'values': [True, None, 1.25]}
        encoded = json.dumps(message, separators=(',', ':')).encode()
        original = json.JSONEncoder.iterencode
        for status in (False, True):
            for supplied in (None, len(encoded) + 12):
                with self.subTest(status=status, supplied=supplied):
                    transport = RequestTransport(); transport.register(1)
                    with mock.patch.object(json.JSONEncoder, 'iterencode', autospec=True, side_effect=original) as encode:
                        self.assertTrue(transport.put(1, message, size=supplied, status=status))
                    self.assertEqual(encode.call_count, int(status or supplied is None))
                    self.assertEqual(transport.bytes, len(encoded) if supplied is None else supplied)
                    self.assertEqual(transport.pending[1].last_status,
                                     hashlib.sha256(encoded).digest() if status else None)
                    self.assertEqual(transport.get(1, 0), message)
                    self.assertEqual((transport.bytes, transport.count), (0, 0))

    def test_prepare_is_bounded_and_does_not_coalesce_overflow_without_a_digest(self):
        for status in (False, True):
            transport = RequestTransport(byte_limit=100, reserve_bytes=0); transport.register(1)
            yielded = []
            def chunks(*_):
                for index in range(100):
                    yielded.append(index)
                    yield 'x' * 40
            with mock.patch.object(json.JSONEncoder, 'iterencode', side_effect=chunks):
                self.assertFalse(transport.put(1, {}, status=status))
            self.assertEqual(yielded, [0, 1, 2])
            self.assertEqual((transport.bytes, transport.count), (0, 0))
            with self.assertRaises(TransportFailure) as caught: transport.get(1, 0)
            self.assertEqual(caught.exception.code, 'transport_buffer_limit')

    def test_wire_size_survives_json_escape_expansion_and_whitespace(self):
        transport = ACPTransport(byte_limit=250, reserve_bytes=0)
        transport.register(1, method='session/prompt', session='s')
        status = {'method':'session/update', 'params':{'sessionId':'s',
                  'update':{'sessionUpdate':'tool_call', 'title':'€' * 30}}}
        wire = json.dumps(status, ensure_ascii=False).encode()
        canonical = json.dumps(status, separators=(',', ':')).encode()
        self.assertLess(len(wire), 250)
        self.assertGreater(len(canonical), 250)
        transport.route(status, len(wire))
        self.assertEqual(transport.bytes, len(wire))
        self.assertEqual(transport.pending[1].last_status, hashlib.sha256(canonical).digest())
        self.assertEqual(transport.get(1, 0), status)
        transport.route(status, len(wire) + 2)
        self.assertEqual((transport.bytes, transport.count), (0, 0))

    def test_retirement_close_and_terminal_fence_preparing_messages(self):
        for routed in (False, True):
            for transition in ('unregister', 'replace', 'close', 'terminal', 'failure'):
                with self.subTest(routed=routed, transition=transition):
                    transport = ACPTransport(); transport.register(1, method='session/prompt', session='s')
                    message = {'method':'session/update', 'params':{'sessionId':'s',
                               'update':{'sessionUpdate':'tool_call', 'title':'old'}}}
                    def operate():
                        if transition in ('unregister', 'replace'):
                            transport.unregister(1)
                            if transition == 'replace': transport.register(1, method='session/prompt', session='new')
                        elif transition == 'close': transport.close()
                        elif transition == 'failure': transport.fail(TransportFailure('transport_closed'))
                        else: self.assertTrue(transport.put(1, 'terminal', size=8, terminal=True))
                    send = (lambda: transport.route(message)) if routed else (lambda: transport.put(1, message, status=True))
                    result = self.during_preparation(transport, send, operate)
                    self.assertEqual(result, [None] if routed else [False])
                    self.assertEqual((transport.bytes, transport.count), (8, 1) if transition == 'terminal' else (0, 0))
                    if transition == 'replace':
                        self.assertFalse(transport.has_pending(1))
                        self.assertIsNone(transport.pending[1].last_status)

    def test_other_replies_are_consumable_during_encoding_and_hashing(self):
        for block_hash in (False, True):
            transport = ACPTransport()
            transport.register(1, method='session/prompt', session='s'); transport.register(2)
            transport.route({'id': 2, 'result': {'ready': True}}, size=40)
            message = {'method':'session/update', 'params':{'sessionId':'s',
                       'update':{'sessionUpdate':'tool_call', 'title':'preparing'}}}
            def consume(): self.assertTrue(transport.get(2, 0)['result']['ready'])
            self.during_preparation(transport, lambda: transport.route(message), consume, block_hash=block_hash)
            self.assertEqual(transport.get(1, 0), message)
            self.assertEqual((transport.bytes, transport.count), (0, 0))

    def test_preparing_terminal_cannot_enter_a_replacement_mailbox(self):
        transport = ACPTransport(); transport.register(1)
        def replace():
            transport.unregister(1); transport.register(1)
        self.during_preparation(transport, lambda: transport.route({'id':1, 'result':{}}), replace)
        self.assertFalse(transport.has_pending(1))
        self.assertFalse(transport.pending[1].ended)
        self.assertEqual((transport.bytes, transport.count), (0, 0))

    def test_delayed_oversize_preparation_cannot_fail_a_new_mailbox(self):
        transport = RequestTransport(byte_limit=100, reserve_bytes=0); transport.register(1)
        def replace():
            transport.unregister(1); transport.register(1)
            self.assertTrue(transport.put(1, 'new', size=3, terminal=True))
        self.assertEqual(self.during_preparation(transport, lambda: transport.put(1, {'old':'x' * 200}), replace), [False])
        self.assertEqual(transport.get(1, 0), 'new')
        self.assertEqual((transport.bytes, transport.count), (0, 0))

    def test_parallel_admission_rechecks_aggregate_capacity(self):
        transport = RequestTransport(byte_limit=100, reserve_bytes=40); transport.register(1); transport.register(2)
        prepared = threading.Barrier(2)
        original = transport._prepare
        def preparing(*args):
            result = original(*args); prepared.wait(2); return result
        results = []
        with mock.patch.object(transport, '_prepare', side_effect=preparing):
            threads = [threading.Thread(target=lambda key=key: results.append((key, transport.put(key, 'ready', size=40)))) for key in (1, 2)]
            for thread in threads: thread.start()
            for thread in threads: thread.join(3)
        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.assertEqual(sorted(value for _, value in results), [False, True])
        accepted = next(key for key, value in results if value)
        rejected = next(key for key, value in results if not value)
        self.assertEqual((transport.bytes, transport.count), (40, 1))
        self.assertTrue(transport.put(accepted, 'complete', size=60, terminal=True))
        self.assertEqual(transport.bytes, 100)
        self.assertEqual([transport.get(accepted, 0) for _ in range(2)], ['ready', 'complete'])
        with self.assertRaises(TransportFailure) as caught: transport.get(rejected, 0)
        self.assertEqual(caught.exception.code, 'transport_buffer_limit')
        self.assertEqual((transport.bytes, transport.count), (0, 0))

    def test_parallel_request_producers_preserve_each_fifo_and_exact_accounting(self):
        transport = ACPTransport()
        for key in range(4): transport.register(key, method='session/prompt', session=str(key))
        failures = []
        def produce(key):
            try:
                for index in range(30):
                    transport.route({'method':'session/update', 'params':{'sessionId':str(key),
                                     'update':{'sessionUpdate':'agent_message_chunk', 'index':index}}})
                transport.route({'id':key, 'result':{'complete':True}})
            except BaseException as error: failures.append(error)
        threads = [threading.Thread(target=produce, args=(key,)) for key in range(4)]
        for thread in threads: thread.start()
        for thread in threads: thread.join(3)
        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.assertEqual(failures, [])
        self.assertEqual(transport.count, 124)
        for key in range(4):
            self.assertEqual([transport.get(key, 0)['params']['update']['index'] for _ in range(30)], list(range(30)))
            self.assertTrue(transport.get(key, 0)['result']['complete'])
        self.assertEqual((transport.bytes, transport.count), (0, 0))

    def test_simultaneously_prepared_duplicate_statuses_admit_once(self):
        transport = RequestTransport(); transport.register(1)
        prepared = threading.Barrier(2)
        original = transport._prepare
        def preparing(*args):
            result = original(*args); prepared.wait(2); return result
        results = []
        with mock.patch.object(transport, '_prepare', side_effect=preparing):
            threads = [threading.Thread(target=lambda: results.append(transport.put(1, {'status':'same'}, status=True))) for _ in range(2)]
            for thread in threads: thread.start()
            for thread in threads: thread.join(3)
        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.assertEqual(results, [True, True])
        self.assertEqual(transport.count, 1)
        self.assertEqual(transport.get(1, 0), {'status':'same'})
        self.assertEqual((transport.bytes, transport.count), (0, 0))

    def test_invalid_or_retired_messages_do_not_touch_accounting(self):
        transport = RequestTransport(); transport.register(1)
        with self.assertRaises(TypeError): transport.put(1, {'unsupported':object()})
        self.assertEqual((transport.bytes, transport.count), (0, 0))
        transport.unregister(1)
        with mock.patch.object(transport, '_prepare', side_effect=AssertionError('retired preparation')):
            self.assertFalse(transport.put(1, {}))
        transport.register(1); transport.close()
        with mock.patch.object(transport, '_prepare', side_effect=AssertionError('closed preparation')):
            self.assertFalse(transport.put(1, {}))

    def test_fragmented_utf8_and_eof_preserve_complete_frames(self):
        payload = '☃ 🧭'.encode()
        framer = LineFramer(16); frames = []; errors = []
        for byte in payload + b'\nlast':
            framer.feed(bytes([byte]), frames.append, errors.append)
        framer.feed(b'', frames.append, errors.append, flush=True)
        self.assertEqual(frames, [payload, b'last'])
        self.assertEqual(errors, [])
        self.assertEqual(len(framer.pending), 0)

    def test_complete_lines_bypass_pending_copies(self):
        expected = [json.dumps({'index': index, 'value': 'x' * 24}).encode() for index in range(1000)]
        framer = LineFramer(128); framer.pending = CountingFrameBuffer()
        frames = []; errors = []
        framer.feed(b'\n'.join(expected) + b'\n', frames.append, errors.append, flush=True)
        self.assertEqual(frames, expected)
        self.assertTrue(all(type(frame) is bytes for frame in frames))
        self.assertEqual(errors, [])
        self.assertEqual((framer.pending.extend_calls, framer.pending.extended_bytes,
                          framer.pending.materializations, framer.pending.materialized_bytes), (0, 0, 0, 0))
        self.assertEqual(framer.pending, b'')

    def test_only_fragmented_lines_use_the_accumulation_buffer(self):
        framer = LineFramer(16); framer.pending = CountingFrameBuffer()
        frames = []; errors = []
        framer.feed(b'alpha\nbe', frames.append, errors.append)
        self.assertEqual((frames, bytes(memoryview(framer.pending))), ([b'alpha'], b'be'))
        framer.feed(b'ta\ngamma\nlast', frames.append, errors.append)
        framer.feed(b'', frames.append, errors.append, flush=True)
        self.assertEqual(frames, [b'alpha', b'beta', b'gamma', b'last'])
        self.assertEqual(errors, [])
        self.assertEqual((framer.pending.extend_calls, framer.pending.extended_bytes,
                          framer.pending.materializations, framer.pending.materialized_bytes), (3, 8, 2, 8))

    def test_random_fragmentation_matches_wire_frames_errors_and_eof_byte_for_byte(self):
        for seed in range(80):
            rng = random.Random(seed)
            limit = rng.choice([0, 1, 16, 64])
            lines = [b'', b'\r', 'emoji 🧭 e\u0301'.encode(), b'\x00\xff\xfe',
                     b'x' * limit, b'y' * (limit + 1), b'z' * (limit * 3 + 1)]
            lines += [bytes(rng.choice([0, 13, 32, 65, 127, 255]) for _ in range(rng.randrange(130)))
                      for _ in range(30)]
            wire = b'\n'.join(lines) + (b'\n' if seed % 2 else b'')
            expected = [('failure', 'transport_frame_limit') if len(line) > limit else ('frame', line)
                        for line in wire.split(b'\n') if line]
            framer = LineFramer(limit); events = []
            def frame(value):
                self.assertIs(type(value), bytes)
                events.append(('frame', value))
            def failure(error): events.append(('failure', error.code))
            position = 0
            with self.subTest(seed=seed, limit=limit):
                while position < len(wire):
                    stop = min(len(wire), position + rng.randrange(1, 257))
                    framer.feed(wire[position:stop], frame, failure,
                                flush=stop == len(wire) and seed % 3 == 0)
                    self.assertLessEqual(len(framer.pending), limit)
                    if rng.randrange(4) == 0: framer.feed(b'', frame, failure)
                    position = stop
                framer.feed(b'', frame, failure, flush=True)
                framer.feed(b'', frame, failure, flush=True)
                self.assertEqual(events, expected)
                self.assertEqual(framer.pending, b'')
                self.assertFalse(framer.discarding)

    def test_direct_frames_own_bytes_independently_of_source_and_later_feeds(self):
        source = bytearray(b'alpha\nbeta\n')
        framer = LineFramer(16); frames = []; errors = []
        framer.feed(source, frames.append, errors.append)
        source[:] = b'changed'
        framer.feed(b'fragment', frames.append, errors.append)
        framer.feed(b'ed\nnext\n', frames.append, errors.append)
        self.assertEqual(frames, [b'alpha', b'beta', b'fragmented', b'next'])
        self.assertTrue(all(type(frame) is bytes for frame in frames))
        self.assertEqual(errors, [])

    def test_oversized_and_empty_lines_resynchronize_into_direct_frames(self):
        framer = LineFramer(4); framer.pending = CountingFrameBuffer()
        events = []
        frame = lambda value: events.append(('frame', value))
        failure = lambda error: events.append(('failure', error.code))
        framer.feed(b'\n\nxxxx\n12345\n\r\nokay\nlast', frame, failure)
        self.assertEqual(events, [('frame', b'xxxx'), ('failure', 'transport_frame_limit'),
                                  ('frame', b'\r'), ('frame', b'okay')])
        self.assertEqual((framer.pending.extend_calls, framer.pending.extended_bytes), (1, 4))
        framer.feed(b'x', frame, failure)  # Oversized final fragment fails before EOF.
        self.assertEqual(events[-1], ('failure', 'transport_frame_limit'))
        framer.feed(b'', frame, failure, flush=True)
        self.assertFalse(framer.discarding)
        framer.feed(b'new\n', frame, failure)
        self.assertEqual(events[-1], ('frame', b'new'))
        self.assertEqual(framer.pending.materializations, 0)

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
        for code in ['transport_frame_limit', 'transport_buffer_limit', 'transport_write_timeout',
                     'transport_write_no_progress']:
            failure = runtime.classify_failure(TransportFailure(code), 0)
            self.assertEqual(failure.kind, 'transport')
            self.assertEqual(failure.code, code)

    def test_zero_byte_write_fails_without_waiting_or_retrying_a_partial_frame(self):
        message = {'fixture': 'unchanged'}
        expected = (json.dumps(message, separators=(',', ':')) + '\n').encode()
        real_write = os.write
        for prefix in [0, 7]:
            with self.subTest(prefix=prefix):
                read_fd, write_fd = os.pipe()
                stream = os.fdopen(write_fd, 'wb', buffering=0)
                attempts = []
                def write(descriptor, data):
                    attempts.append(bytes(data))
                    if prefix and len(attempts) == 1:
                        return real_write(descriptor, data[:prefix])
                    if len(attempts) == (2 if prefix else 1):
                        return 0
                    self.fail('retried a zero-progress write')
                try:
                    with mock.patch('bounded_transport.os.write', side_effect=write), \
                         mock.patch('bounded_transport.time.monotonic', return_value=10), \
                         mock.patch('bounded_transport.select.select') as wait:
                        with self.assertRaises(TransportFailure) as caught:
                            write_frame(stream, message, timeout=300)
                    self.assertEqual(caught.exception.code, 'transport_write_no_progress')
                    self.assertTrue(caught.exception.connected)  # No claim that an associated effect failed.
                    self.assertEqual(attempts, [expected, expected[prefix:]] if prefix else [expected])
                    wait.assert_not_called()
                    self.assertFalse(stream.closed)  # The caller owns teardown.
                    stream.close()
                    self.assertEqual(os.read(read_fd, len(expected)), expected[:prefix])
                finally:
                    stream.close(); os.close(read_fd)

    def test_temporary_backpressure_still_resumes_the_same_partial_frame(self):
        message = {'fixture': 'backpressure'}
        expected = (json.dumps(message, separators=(',', ':')) + '\n').encode()
        read_fd, write_fd = os.pipe()
        stream = os.fdopen(write_fd, 'wb', buffering=0)
        real_write = os.write
        attempts = []
        def write(descriptor, data):
            attempts.append(bytes(data))
            if len(attempts) == 1:
                return real_write(descriptor, data[:7])
            if len(attempts) == 2:
                raise BlockingIOError()
            return real_write(descriptor, data)
        try:
            with mock.patch('bounded_transport.os.write', side_effect=write), \
                 mock.patch('bounded_transport.select.select', return_value=([], [write_fd], [])) as wait:
                write_frame(stream, message)
            self.assertEqual(attempts, [expected, expected[7:], expected[7:]])
            wait.assert_called_once()
            stream.close()
            self.assertEqual(os.read(read_fd, len(expected) + 1), expected)
        finally:
            stream.close(); os.close(read_fd)

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
                reply = dict(kind='bridge_response', request_id=payload['request_id'], task_generation_id='task', working_document_revision=0, ok=True, result=receipt)
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

    def test_zero_progress_acp_write_drains_child_and_retains_abort_requirement(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'fake-acp'
            executable.write_text('#!' + sys.executable + '\n' + '''import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if request.get('method') == 'initialize': result = {'protocolVersion': 1}
    elif request.get('method') == 'session/new': result = {'sessionId': 'fixture', 'configOptions': []}
    else: continue
    print(json.dumps({'id':request['id'],'result':result}), flush=True)
''')
            executable.chmod(0o700)
            image = Path(directory) / 'fixture.png'; image.write_bytes(b'offline')
            real_write = os.write
            for prefix in [0, 7]:
                with self.subTest(prefix=prefix), \
                     mock.patch.object(runtime, 'session_transcript_cursor', return_value=None):
                    client = runtime.ACPClient(str(executable))
                    descriptor = client.process.stdin.fileno()
                    attempts = []
                    def write(fd, data):
                        if fd != descriptor: return real_write(fd, data)
                        attempts.append(bytes(data))
                        if prefix and len(attempts) == 1:
                            return real_write(fd, data[:prefix])
                        return 0  # The best-effort cancellation also cannot use this pipe.
                    try:
                        with mock.patch('bounded_transport.os.write', side_effect=write):
                            with self.assertRaises(TransportFailure) as caught:
                                client.prompt('fixture', image)
                        self.assertEqual(caught.exception.code, 'transport_write_no_progress')
                        self.assertEqual(len(attempts), 3 if prefix else 2)
                        self.assertIsNotNone(client.process.poll())
                        self.assertTrue(all(stream.closed for stream in
                                            (client.process.stdin, client.process.stdout, client.process.stderr)))
                        self.assertTrue(client.stdout_finished.wait(1))
                        self.assertEqual(client.transport.pending, {})
                        self.assertEqual(client.transport.bytes, 0)
                        self.assertEqual(client.prompt_calls, 1)
                        self.assertEqual(client.pending_prompt_session_id, 'fixture')
                        with mock.patch.object(client, 'gateway_configuration', return_value={'ok': False}) as abort, \
                             mock.patch.object(client, '_initialize') as restart:
                            with self.assertRaisesRegex(RuntimeError, 'confirm the previous OpenClaw request ended'):
                                client.reconnect()
                        abort.assert_called_once_with('sessions.abort', {'key': client.session_key})
                        restart.assert_not_called()
                        self.assertEqual(client.prompt_calls, 1)
                    finally:
                        client.close()

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
