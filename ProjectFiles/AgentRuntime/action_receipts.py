"""Private receipt recovery and one stdin reader shared by all protocol waits.

Receipts recover acknowledgements, not proof of a GUI mutation's outcome. This
module never executes an action, persists a payload, or makes model requests.
"""
from __future__ import annotations

import json
import threading
import time
from local_budget import LocalBudget, current_budget
from action_contract_generated import validate_native_receipt
from bounded_transport import RequestTransport, TransportFailure, read_frames


class BridgeReplyLost(RuntimeError):
    def __init__(self, message: str, *, connected: bool = True, code=None):
        super().__init__(message)
        self.connected = connected
        self.code = code


class RuntimeInbox:
    def __init__(self, stream, control_handler=None):
        self.stream = stream
        self.control_handler = control_handler
        self.transport = RequestTransport()
        self.transport.register(('runtime_configuration', None, None))
        self._instruction_correction_key = None
        self._started = False
        self._start_lock = threading.Lock()

    def register(self, kind, request_id, generation):
        key = (kind, request_id, generation)
        self.transport.register(key)
        return key

    def register_instruction_corrections(self, generation):
        key = ('instruction_correction', None, generation)
        if self._instruction_correction_key is None:
            self.transport.register(key)
            self._instruction_correction_key = key
        elif self._instruction_correction_key != key:
            raise TransportFailure('transport_generation_mismatch')
        return key

    @property
    def instruction_correction_key(self):
        return self._instruction_correction_key

    def has_instruction_correction(self):
        return bool(self._instruction_correction_key and
                    self.transport.has_pending(self._instruction_correction_key))

    def take_instruction_correction(self, timeout=0):
        if not self._instruction_correction_key:
            raise TransportFailure('transport_unknown_request')
        return self.transport.get(self._instruction_correction_key, timeout)

    def start(self):
        with self._start_lock:
            if not self._started:
                self._started = True
                threading.Thread(target=self._read, daemon=True).start()

    def _enqueue(self, frame):
        # Control messages must not enter a bridge/secure-input reply wait.
        # The sole reader can release disposable caches during a model wait.
        try:
            line = frame.decode('utf-8')
            message = json.loads(line)
            if not isinstance(message, dict):
                raise ValueError()
        except (ValueError, RecursionError):
            self.transport.fail(TransportFailure('transport_malformed_frame'))
            return
        if self.control_handler is not None and self.control_handler(line):
            return
        kind = message.get('kind')
        request_id = message.get('request_id')
        generation = message.get('task_generation_id')
        if kind == 'runtime_configuration':
            key = (kind, None, None)
        elif kind == 'instruction_correction':
            if not isinstance(generation, str) or not generation:
                return
            key = self._instruction_correction_key
            if key != ('instruction_correction', None, generation):
                return
            # Corrections are bounded control events, not terminal replies.
            self.transport.put(key, line + '\n', size=len(frame), terminal=False)
            return
        elif isinstance(kind, str) and isinstance(request_id, str) and (generation is None or isinstance(generation, str)):
            key = (kind, request_id, generation)
        else:
            return
        self.transport.put(key, line + '\n', size=len(frame), terminal=True)

    def _read(self):
        try:
            read_frames(self.stream, self._enqueue, self.transport.fail)
        finally:
            self.transport.close()

    def read(self, timeout=None, *, key=('runtime_configuration', None, None)):
        self.start()
        try:
            return self.transport.get(key, timeout)
        except TimeoutError as error:
            raise BridgeReplyLost("The native action reply did not arrive; checking its receipt") from error
        except TransportFailure as error:
            raise BridgeReplyLost(str(error), connected=error.connected, code=error.code) from error


def reconcile_receipt(action_id, lookup, metrics, *, budget=5.0, clock=time.monotonic, sleep=time.sleep, action=None):
    """Recover a terminal reply. Unfinished/unknown work must stop, not overlap.

    lookup is a read-only private bridge operation. Caller retains the same
    logical ID throughout; no payload-based inference or redispatch occurs.
    """
    allowance = current_budget.get() or LocalBudget(budget, 'receipt_reconciliation', clock=clock)
    deadline = min(clock() + budget, allowance.deadline)
    try:
        while True:
            remaining = min(deadline - clock(), allowance.remaining)
            if remaining <= 0:
                raise RuntimeError(f"The local budget was consumed during {allowance.phase}; the previous action has not ended safely; TaskPilot stopped without repeating it")
            allowance.check('receipt_reconciliation')
            metrics["receipt_queries"] += 1
            receipt = lookup(action_id, remaining)
            # A late terminal receipt is still authoritative. Expiry cannot
            # turn dispatched work into failure or authorize another delivery.
            validate_native_receipt(receipt, action_id, action)
            state = receipt['state']
            if state in {'pending', 'dispatched'}:
                sleep(min(0.1, max(0, deadline - clock())))
                continue
            if state == 'unknown':
                raise RuntimeError('The native action outcome is unknown; TaskPilot stopped without repeating it')
            if 'result' in receipt:
                response = {'ok': True, 'result': receipt['result']}
            else:
                # Preserve both the precise error and explicit delivery certainty.
                # The runtime stops on protocol errors; none authorize replay.
                response = {'ok': False, **{key: receipt[key] for key in
                    ('error', 'error_code', 'outcome', 'verified', 'verification_scope', 'terminal')}}
            metrics["receipt_recoveries"] += 1
            return response
    except Exception:
        metrics["receipt_unresolved"] += 1
        raise
