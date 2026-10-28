"""Real advisory-lock paths with isolated private roots; no provider or desktop."""
import fcntl
import os
from pathlib import Path
import select
import subprocess
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

    def assert_waiter_rejects_replaced_lock(self, kind):
        root = self.root / kind
        root.mkdir(mode=0o700)
        lock_path = root / ("openclaw-configuration.lock" if kind == "configuration" else "installation.lock")
        holder = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_CLOEXEC, 0o600)
        fcntl.flock(holder, fcntl.LOCK_EX)
        runtime_path = Path(__file__).resolve().parents[2] / 'AgentRuntime'
        script = r'''import fcntl, pathlib, sys
sys.path.insert(0, sys.argv[1])
kind, path = sys.argv[2], pathlib.Path(sys.argv[3])
if kind == "configuration":
    import request_policy as target
    acquire = lambda: target.private_lock(path)
else:
    import managed_openclaw as target
    acquire = lambda: target.locked(path.parent)
real_flock = target.fcntl.flock
announced = False
def observed_flock(fd, operation):
    global announced
    if not announced:
        announced = True
        print("WAITING", flush=True)
    return real_flock(fd, operation)
target.fcntl.flock = observed_flock
try:
    with acquire():
        print("ENTERED", flush=True)
except Exception as error:
    print("REJECTED:" + getattr(error, "code", "") + ":" + str(error), flush=True)
'''
        process = subprocess.Popen([sys.executable, '-c', script, str(runtime_path), kind, str(lock_path)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        try:
            ready, _, _ = select.select([process.stdout], [], [], 3)
            self.assertTrue(ready, f'{kind} lock contender did not reach flock')
            self.assertEqual(process.stdout.readline().strip(), 'WAITING')
            displaced = lock_path.with_name(lock_path.name + '.displaced')
            os.replace(lock_path, displaced)
            replacement = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_CLOEXEC, 0o600)
            os.close(replacement)
            fcntl.flock(holder, fcntl.LOCK_UN)
            stdout, stderr = process.communicate(timeout=4)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertNotIn('ENTERED', stdout)
            self.assertIn('REJECTED:', stdout)
            if kind == 'configuration':
                self.assertIn('private_lock_identity_mismatch', stdout)
            else:
                self.assertIn('managed_lock_identity_mismatch', stdout)
        finally:
            try: fcntl.flock(holder, fcntl.LOCK_UN)
            except OSError: pass
            os.close(holder)
            if process.poll() is None:
                process.kill(); process.wait()

    def test_python_configuration_and_installation_waiters_reject_replaced_lock_names(self):
        self.assert_waiter_rejects_replaced_lock('configuration')
        self.assert_waiter_rejects_replaced_lock('installation')

    def test_python_lock_open_rejects_symlink_paths(self):
        target = self.root / 'target.lock'; target.touch(mode=0o600)
        link = self.root / 'linked.lock'; link.symlink_to(target)
        with self.assertRaises(policy.PrivateLockIdentityError):
            with policy.private_lock(link): pass
        managed_root = self.root / 'managed'; managed_root.mkdir(mode=0o700)
        managed_link = managed_root / 'installation.lock'; managed_link.symlink_to(target)
        with self.assertRaises(managed.ManagedLockIdentityError):
            with managed.locked(managed_root): pass

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
