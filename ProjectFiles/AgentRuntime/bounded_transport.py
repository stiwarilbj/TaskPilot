"""Private bounded JSON-line framing and request mailboxes; no payload logging."""
from __future__ import annotations

from collections import deque
import hashlib
import json
import os
import select
import threading
import time

MIB = 1024 * 1024
FRAME_BYTES = 8 * MIB
BUFFER_BYTES = 32 * MIB
RESERVED_BYTES = 8 * MIB
MAX_MESSAGES = 1024
MAX_REQUESTS = 32


class TransportFailure(RuntimeError):
    def __init__(self, code, *, connected=True):
        self.code = code
        self.connected = connected
        super().__init__(f"TaskPilot transport failure ({code}); incomplete output is not a successful response")


class LineFramer:
    """Reject an oversized frame immediately, then drain through its delimiter."""
    def __init__(self, frame_limit=FRAME_BYTES):
        self.limit = frame_limit
        self.pending = bytearray()
        self.discarding = False

    def feed(self, data, on_frame, on_failure, *, flush=False):
        start = 0
        while start < len(data):
            end = data.find(b'\n', start)
            stop = len(data) if end < 0 else end
            length = stop - start
            if not self.discarding:
                if len(self.pending) + length > self.limit:
                    self.pending.clear()
                    self.discarding = True
                    on_failure(TransportFailure('transport_frame_limit'))
                else:
                    self.pending.extend(memoryview(data)[start:stop])
            if end < 0:
                break
            if not self.discarding and self.pending:
                on_frame(bytes(self.pending))
            self.pending.clear()
            self.discarding = False
            start = end + 1
        if flush:
            if self.pending and not self.discarding:
                on_frame(bytes(self.pending))
            self.pending.clear()
            self.discarding = False


def read_frames(stream, on_frame, on_failure, *, frame_limit=FRAME_BYTES):
    framer = LineFramer(frame_limit)
    descriptor = None
    try:
        try:
            # Own this descriptor until the sole reader exits. Reconnect may
            # close/reuse the original stream's descriptor in the meantime.
            descriptor = os.dup(stream.fileno())
        except (AttributeError, OSError, ValueError):
            descriptor = None
        while True:
            # One sole raw pipe reader avoids BufferedReader locks at exit.
            chunk = os.read(descriptor, 65536) if descriptor is not None else stream.read(65536)
            if not chunk:
                break
            if isinstance(chunk, str):
                chunk = chunk.encode('utf-8')
            framer.feed(chunk, on_frame, on_failure)
        framer.feed(b'', on_frame, on_failure, flush=True)
    except (OSError, ValueError):
        on_failure(TransportFailure('transport_closed', connected=False))
    finally:
        if descriptor is not None:
            os.close(descriptor)


class RequestMailbox:
    def __init__(self):
        self.events = deque()
        self.terminal = None
        self.failure = None
        self.last_status = None
        self.ended = False


class RequestTransport:
    """Only registered IDs retain data. Terminal slots bypass stream congestion.

    Both bytes and object counts are bounded. A loss of a nonredundant event
    fails its request, never silently produces a truncated successful response.
    EOF is out of band and cannot displace a previously received terminal reply.
    """
    def __init__(self, *, byte_limit=BUFFER_BYTES, reserve_bytes=RESERVED_BYTES,
                 message_limit=MAX_MESSAGES, request_limit=MAX_REQUESTS):
        self.byte_limit = byte_limit
        self.reserve_bytes = reserve_bytes
        self.message_limit = message_limit
        self.request_limit = request_limit
        self.pending = {}
        self.bytes = 0
        self.count = 0
        self.closed = False
        self.condition = threading.Condition()

    def register(self, key):
        with self.condition:
            if self.closed:
                raise TransportFailure('transport_closed', connected=False)
            if key in self.pending:
                raise TransportFailure('transport_duplicate_request')
            if len(self.pending) >= self.request_limit:
                raise TransportFailure('transport_request_limit')
            self.pending[key] = RequestMailbox()

    def unregister(self, key):
        with self.condition:
            slot = self.pending.pop(key, None)
            if slot:
                self._clear(slot)
                if slot.terminal:
                    self.bytes -= slot.terminal[1]
                    self.count -= 1

    def _clear(self, slot):
        for _, size in slot.events:
            self.bytes -= size
            self.count -= 1
        slot.events.clear()
        slot.last_status = None

    def fail(self, error, key=None):
        with self.condition:
            slots = self.pending.values() if key is None else [self.pending[key]] if key in self.pending else []
            for slot in slots:
                if slot.ended:
                    continue  # Trailing noise cannot replace an intact terminal.
                self._clear(slot)
                slot.failure = slot.failure or error
            self.condition.notify_all()

    def put(self, key, message, *, size=None, terminal=False, status=False):
        with self.condition:
            slot = self.pending.get(key)
            if slot is None or slot.ended:
                return False  # Unknown, retired, duplicate or post-terminal work.
            if slot.failure and not terminal:
                return False
            signature = hashlib.sha256(json.dumps(message, separators=(',', ':')).encode()).digest() if status else None
            if status and signature == slot.last_status:
                return True
            size = size if size is not None else len(json.dumps(message, separators=(',', ':')).encode())
            limit = self.byte_limit if terminal else self.byte_limit - self.reserve_bytes
            count_limit = self.message_limit + self.request_limit if terminal else self.message_limit
            if self.bytes + size > limit or self.count >= count_limit:
                self.fail(TransportFailure('transport_buffer_limit'), key)
                return False
            self.bytes += size
            self.count += 1
            if terminal:
                slot.terminal = (message, size)
                slot.ended = True
            else:
                slot.events.append((message, size))
                if status:
                    slot.last_status = signature
            self.condition.notify_all()
            return True

    def get(self, key, timeout=None):
        deadline = None if timeout is None else time.monotonic() + timeout
        with self.condition:
            while True:
                slot = self.pending.get(key)
                if slot is None:
                    raise TransportFailure('transport_unknown_request')
                if slot.failure:
                    raise slot.failure
                if slot.events:
                    value, size = slot.events.popleft()
                elif slot.terminal:
                    value, size = slot.terminal
                    slot.terminal = None
                elif self.closed:
                    raise TransportFailure('transport_closed', connected=False)
                else:
                    remaining = None if deadline is None else deadline - time.monotonic()
                    if remaining is not None and remaining <= 0:
                        raise TimeoutError()
                    self.condition.wait(remaining)
                    continue
                self.bytes -= size
                self.count -= 1
                return value

    def get_any(self, keys, timeout=None):
        """Read the earliest available event from several task-owned mailboxes."""
        deadline = None if timeout is None else time.monotonic() + timeout
        with self.condition:
            while True:
                for key in keys:
                    slot = self.pending.get(key)
                    if slot is None:
                        continue
                    if slot.failure:
                        raise slot.failure
                    if slot.events:
                        value, size = slot.events.popleft()
                    elif slot.terminal:
                        value, size = slot.terminal
                        slot.terminal = None
                    else:
                        continue
                    self.bytes -= size
                    self.count -= 1
                    return key, value
                if self.closed:
                    raise TransportFailure('transport_closed', connected=False)
                remaining = None if deadline is None else deadline - time.monotonic()
                if remaining is not None and remaining <= 0:
                    raise TimeoutError()
                self.condition.wait(remaining)

    def has_pending(self, key):
        with self.condition:
            slot = self.pending.get(key)
            return bool(slot and (slot.events or slot.terminal))

    def close(self):
        with self.condition:
            self.closed = True
            self.condition.notify_all()


class ACPTransport(RequestTransport):
    def register(self, key, *, method='', session=None):
        with self.condition:
            super().register(key)
            self.pending[key].method = method
            self.pending[key].session = session

    def route(self, message, size=None):
        with self.condition:
            if 'id' in message and type(message['id']) not in (int, str):
                self.fail(TransportFailure('transport_invalid_request_id'))
                return
            if 'id' in message and ('result' in message or 'error' in message) and 'method' not in message:
                key = message['id']
                if key not in self.pending:
                    return
                if (('result' in message) == ('error' in message)
                        or not isinstance(message.get('result', message.get('error')), dict)):
                    self.fail(TransportFailure('transport_malformed_envelope'), key)
                    return
                self.put(key, message, size=size, terminal=True)
                return
            params = message.get('params')
            params = params if isinstance(params, dict) else {}
            if message.get('method') == 'session/update':
                keys = [key for key, slot in self.pending.items()
                        if slot.method == 'session/prompt' and slot.session == params.get('sessionId')
                        and ('requestId' not in params or type(params['requestId']) is type(key) and params['requestId'] == key)]
            else:
                keys = list(self.pending) if 'id' in message and isinstance(message.get('method'), str) else []
            if len(keys) != 1:
                return
            update = params.get('update')
            if message.get('method') == 'session/update' and not isinstance(update, dict):
                self.fail(TransportFailure('transport_malformed_envelope'), keys[0])
                return
            status = isinstance(update, dict) and update.get('sessionUpdate') == 'tool_call'
            self.put(keys[0], message, size=size, status=status)


def write_frame(stream, message, *, timeout=5.0, cancelled=lambda: False):
    """Bounded nonblocking pipe writes; cancellation never waits behind a write."""
    data = (json.dumps(message, separators=(',', ':')) + '\n').encode()
    if len(data) - 1 > FRAME_BYTES:
        raise TransportFailure('transport_frame_limit')
    descriptor = stream.fileno()
    os.set_blocking(descriptor, False)
    deadline = time.monotonic() + timeout
    offset = 0
    while offset < len(data):
        if cancelled():
            raise TransportFailure('transport_cancelled')
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TransportFailure('transport_write_timeout')
        try:
            offset += os.write(descriptor, memoryview(data)[offset:offset + 65536])
        except BlockingIOError:
            select.select([], [descriptor], [], min(0.1, remaining))
        except OSError as error:
            raise TransportFailure('transport_closed', connected=False) from error
