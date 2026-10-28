"""Real advisory-lock paths with isolated private roots; no provider or desktop."""
import fcntl
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import lock_order
import managed_openclaw as managed
import request_policy as policy
from lock_order import LockCategory as C, LockOrderError, reserve


class LockOrderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = patch.dict(os.environ, ORBIT_RUNTIME_STATE_DIRECTORY=str(self.root))
        self.env.start(); self.addCleanup(self.env.stop)

    def test_full_supported_order_and_reentrant_configuration(self):
        with policy.private_lock(self.root / 'check.lock', category=C.SINGLE_FLIGHT):
            with policy.configuration_transaction() as fd:
                with managed.locked(self.root / 'managed'):
                    with policy.private_lock(self.root / 'state.lock'):
                        # This reuses an owned lease, with no new wait.
                        with policy.configuration_transaction() as nested:
                            self.assertEqual(fd, nested)
        with policy.private_lock(self.root / 'next.lock', category=C.SINGLE_FLIGHT): pass

    def test_every_rank_pair_rejects_only_descending_order(self):
        self.assertEqual([category.value for category in C], [10, 20, 30, 40])
        for outer in C:
            for inner in C:
                with self.subTest(outer=outer, inner=inner), reserve(outer):
                    if inner < outer:
                        with self.assertRaises(LockOrderError): reserve(inner)
                    else:
                        with reserve(inner): pass

    def test_inversions_fail_before_filesystem_or_flock_and_do_not_drop_outer_rank(self):
        with managed.locked(self.root / 'managed'):
            with patch.object(policy.os, 'open') as opened, patch.object(policy.fcntl, 'flock') as flock:
                with self.assertRaisesRegex(LockOrderError, '^internal_lock_order$'):
                    with policy.configuration_transaction(): pass
                opened.assert_not_called(); flock.assert_not_called()
            with self.assertRaises(LockOrderError):
                with policy.private_lock(self.root / 'check.lock', category=C.SINGLE_FLIGHT): pass
        with policy.private_lock(self.root / 'state.lock'):
            with patch.object(managed, 'check_private_directory') as check:
                with self.assertRaises(LockOrderError):
                    with managed.locked(self.root / 'must-not-exist'): pass
                check.assert_not_called()
            self.assertFalse((self.root / 'must-not-exist').exists())

    def test_failed_open_wait_and_body_release_rank_and_real_lock(self):
        for failure in ('open', 'wait', 'body'):
            with self.subTest(failure=failure):
                with self.assertRaises(OSError):
                    if failure == 'open':
                        with patch.object(policy.os, 'open', side_effect=OSError()):
                            with policy.configuration_transaction(): pass
                    elif failure == 'wait':
                        with patch.object(policy.fcntl, 'flock', side_effect=BlockingIOError()):
                            with policy.configuration_transaction(blocking=False): pass
                    else:
                        with policy.configuration_transaction(): raise OSError()
                with policy.private_lock(self.root / 'check.lock', category=C.SINGLE_FLIGHT): pass
        fd = os.open(self.root / 'openclaw-configuration.lock', os.O_RDWR)
        try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally: os.close(fd)

    def test_installation_failures_release_reservation(self):
        for failure in ('open', 'wait', 'body'):
            with self.subTest(failure=failure), self.assertRaises(OSError):
                if failure == 'open':
                    with patch.object(managed, 'check_private_directory'), \
                            patch.object(managed.os, 'open', side_effect=OSError()):
                        with managed.locked(self.root / 'managed'): pass
                elif failure == 'wait':
                    with patch.object(managed.fcntl, 'flock', side_effect=BlockingIOError()):
                        with managed.locked(self.root / 'managed', blocking=False): pass
                else:
                    with managed.locked(self.root / 'managed'): raise OSError()
            with policy.configuration_transaction(blocking=False): pass
        with managed.locked(self.root / 'managed', blocking=False): pass

    def test_thread_operations_are_independent_and_samples_are_bounded_content_free(self):
        errors = []
        def worker():
            try:
                with policy.configuration_transaction(blocking=False): pass
            except BaseException as error: errors.append(error)
        with reserve(C.STATE):
            thread = threading.Thread(target=worker)
            thread.start(); thread.join(2)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])
        for _ in range(140):
            with reserve(C.CONFIGURATION) as ticket:
                with patch.object(lock_order.time, 'monotonic_ns', side_effect=[10, 2_000_010]):
                    with ticket.waiting(): pass
        samples = lock_order.wait_samples()
        self.assertEqual(len(samples), 128)
        self.assertTrue(all(sample == {'category':'configuration', 'wait_ms':2} for sample in samples))


if __name__ == '__main__': unittest.main()
