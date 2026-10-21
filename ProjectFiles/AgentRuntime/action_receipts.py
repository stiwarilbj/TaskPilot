"""Private receipt recovery and one stdin reader shared by all protocol waits.

Receipts recover acknowledgements, not proof of a GUI mutation's outcome. This
module never executes an action, persists a payload, or makes model requests.
"""
from __future__ import annotations

import queue
import os
import threading
import time
from action_contract_generated import validate_native_receipt


class BridgeReplyLost(RuntimeError):
    def __init__(self, message: str, *, connected: bool = True):
        super().__init__(message)
        self.connected = connected


class RuntimeInbox:
    def __init__(self, stream, control_handler=None):
        self.stream = stream
        self.control_handler = control_handler
        self.lines = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _enqueue(self, line):
        # Control messages must not enter a bridge/secure-input reply wait.
        # The sole reader can release disposable caches during a model wait.
        if self.control_handler is None or not self.control_handler(line):
            self.lines.put(line)

    def _read(self):
        try:
            try:
                descriptor = self.stream.fileno()
            except (AttributeError, OSError, ValueError):
                descriptor = None
            if descriptor is None:
                for line in self.stream:
                    self._enqueue(line)
            else:
                # Reading the real pipe directly avoids holding stdin's
                # BufferedReader lock on a daemon thread during process exit.
                # This is the sole reader, including startup configuration.
                pending = bytearray()
                while chunk := os.read(descriptor, 65536):
                    pending.extend(chunk)
                    while (newline := pending.find(b'\n')) >= 0:
                        self._enqueue(bytes(pending[:newline + 1]).decode('utf-8'))
                        del pending[:newline + 1]
                if pending:
                    self._enqueue(bytes(pending).decode('utf-8'))
        except (OSError, ValueError):
            pass
        finally:
            self.lines.put(None)

    def read(self, timeout=None):
        try:
            line = self.lines.get(timeout=timeout)
        except queue.Empty as error:
            raise BridgeReplyLost("The native action reply did not arrive; checking its receipt") from error
        if line is None:
            self.lines.put(None)
            raise BridgeReplyLost("Lost contact with the native TaskPilot controller", connected=False)
        return line


def reconcile_receipt(action_id, lookup, metrics, *, budget=5.0, clock=time.monotonic, sleep=time.sleep, action=None):
    """Recover a terminal reply. Unfinished/unknown work must stop, not overlap.

    lookup is a read-only private bridge operation. Caller retains the same
    logical ID throughout; no payload-based inference or redispatch occurs.
    """
    deadline = clock() + budget
    try:
        while True:
            remaining = deadline - clock()
            if remaining <= 0:
                raise RuntimeError("The previous action has not ended safely; TaskPilot stopped without repeating it")
            metrics["receipt_queries"] += 1
            receipt = lookup(action_id, remaining)
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
