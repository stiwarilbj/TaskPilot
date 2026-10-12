"""Private receipt recovery and one stdin reader shared by all protocol waits.

Receipts recover acknowledgements, not proof of a GUI mutation's outcome. This
module never executes an action, persists a payload, or makes model requests.
"""
from __future__ import annotations

import queue
import os
import threading
import time


class BridgeReplyLost(RuntimeError):
    def __init__(self, message: str, *, connected: bool = True):
        super().__init__(message)
        self.connected = connected


class RuntimeInbox:
    def __init__(self, stream):
        self.stream = stream
        self.lines = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            try:
                descriptor = self.stream.fileno()
            except (AttributeError, OSError, ValueError):
                descriptor = None
            if descriptor is None:
                for line in self.stream:
                    self.lines.put(line)
            else:
                # Reading the real pipe directly avoids holding stdin's
                # BufferedReader lock on a daemon thread during process exit.
                # This is the sole reader, including startup configuration.
                pending = bytearray()
                while chunk := os.read(descriptor, 65536):
                    pending.extend(chunk)
                    while (newline := pending.find(b'\n')) >= 0:
                        self.lines.put(bytes(pending[:newline + 1]).decode('utf-8'))
                        del pending[:newline + 1]
                if pending:
                    self.lines.put(bytes(pending).decode('utf-8'))
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


def reconcile_receipt(action_id, lookup, metrics, *, budget=5.0, clock=time.monotonic, sleep=time.sleep):
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
            if (not isinstance(receipt, dict) or receipt.get("action_id") != action_id or
                    type(receipt.get("terminal")) is not bool):
                raise RuntimeError("The action receipt does not match this task's pending action; no action was repeated")
            state, terminal = receipt.get("state"), receipt["terminal"]
            if state in {"pending", "dispatched"} and not terminal:
                sleep(min(0.1, max(0, deadline - clock())))
                continue
            if state not in {"confirmed", "unconfirmed", "rejected"} or not terminal:
                raise RuntimeError("The native action outcome is unknown; TaskPilot stopped without repeating it")
            result = receipt.get("result")
            if state in {"confirmed", "unconfirmed"} and isinstance(result, dict):
                if (result.get("outcome") == "delivered_unconfirmed") != (state == "unconfirmed"):
                    raise RuntimeError("The action receipt's outcome is inconsistent; no action was repeated")
                response = {"ok": True, "result": result}
            elif state in {"rejected", "unconfirmed"} and isinstance(receipt.get("error"), str) and isinstance(receipt.get("error_code"), str):
                code = receipt["error_code"]
                if state == "unconfirmed" and code not in {"cancelled", "permission_denied", "protected_target", "secure_input"}:
                    code = "delivery_uncertain"
                response = {"ok": False, "error": receipt["error"], "error_code": code}
            else:
                raise RuntimeError("The native action receipt lacks a terminal result; no action was repeated")
            metrics["receipt_recoveries"] += 1
            return response
    except Exception:
        metrics["receipt_unresolved"] += 1
        raise
