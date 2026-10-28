"""Local feature probes only: no OpenClaw, providers, or desktop interaction."""
import errno
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import managed_openclaw as managed


class PrivateVolumeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cache = managed.PrivateVolumeCache()

    def test_real_probe_is_reused_on_same_volume_without_writes_or_artifacts(self):
        other = self.root / 'other'; other.mkdir(mode=0o700)
        output = self.root / 'keep'; output.write_text('user output')
        with patch.object(managed, '_probe_private_volume', wraps=managed._probe_private_volume) as probe:
            managed.require_private_volume(self.root, cache=self.cache)
            with patch.object(os, 'mkdir', side_effect=AssertionError('warm check wrote scratch')):
                for path in [self.root, other] * 20: managed.require_private_volume(path, cache=self.cache)
            self.assertEqual(probe.call_count, 1)
        self.assertEqual(set(self.root.iterdir()), {other, output})
        self.assertEqual(output.read_text(), 'user output')
        output.unlink(); other.rmdir()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_volume_identity_changes_and_remount_flags_reprobe(self):
        with patch.object(managed, '_private_volume_identity', return_value=(1, 2, 0)) as identity, \
             patch.object(managed, '_probe_private_volume', return_value=(True, True)) as probe:
            for key in [(1, 2, 0), (1, 2, 0), (2, 2, 0), (2, 3, 0), (2, 3, 1)]:
                identity.return_value = key
                managed.require_private_volume(self.root, cache=self.cache)
            self.assertEqual(probe.call_count, 4)

    def test_cache_is_bounded_and_coalesces_concurrent_work(self):
        cache, calls, lock = managed.PrivateVolumeCache(capacity=2), [], threading.Lock()
        def probe():
            with lock: calls.append(1)
            return True, True
        with ThreadPoolExecutor(max_workers=8) as workers:
            list(workers.map(lambda _: cache.profile((1,), probe), range(100)))
        self.assertEqual(len(calls), 1)
        for key in [(2,), (3,), (1,)]: cache.profile(key, probe)
        self.assertEqual(len(calls), 4)
        self.assertEqual(len(cache.profiles), 2)

    def test_permission_and_symlink_changes_are_not_hidden_by_cache(self):
        managed.require_private_volume(self.root, cache=self.cache)
        self.root.chmod(0o755)
        with self.assertRaises(managed.PrivateDirectoryError) as caught:
            managed.require_private_volume(self.root, cache=self.cache)
        self.assertEqual(caught.exception.code, 'private_directory_permissions')
        self.root.chmod(0o700)
        link = self.root / 'link'; link.symlink_to(self.root)
        with self.assertRaises(managed.PrivateDirectoryError) as caught:
            managed.require_private_volume(link, cache=self.cache)
        self.assertEqual(caught.exception.code, 'private_directory_symlink')

    def test_unsupported_rename_and_sync_profiles_reused_with_specific_errors(self):
        for operation, code in [('replace', 'atomic_rename'), ('rename', 'atomic_rename'), ('fsync', 'directory_sync')]:
            cache = managed.PrivateVolumeCache()
            with self.subTest(operation=operation), patch.object(os, operation, side_effect=OSError(errno.ENOTSUP, 'unsupported')) as call:
                for _ in range(2):
                    with self.assertRaises(managed.PrivateVolumeError) as caught:
                        managed.require_private_volume(self.root, cache=cache)
                    self.assertEqual(caught.exception.code, 'private_directory_volume_' + code)
                self.assertEqual(call.call_count, 1)
                self.assertEqual(list(self.root.iterdir()), [])

    def test_transient_failures_are_not_cached_and_clean_the_scratch(self):
        for operation in ['replace', 'fsync', 'mkdir']:
            with self.subTest(operation=operation), patch.object(os, operation, side_effect=OSError(errno.ENOSPC, 'transient')):
                with self.assertRaises(managed.PrivateVolumeError) as caught:
                    managed.require_private_volume(self.root, cache=self.cache)
                self.assertEqual(caught.exception.code, 'private_directory_volume_unavailable')
            self.assertEqual(self.cache.profiles, {})
            self.assertEqual(list(self.root.iterdir()), [])
        managed.require_private_volume(self.root, cache=self.cache)

    def test_identity_change_during_probe_never_populates_cache(self):
        with patch.object(managed, '_private_volume_identity', side_effect=[(1, 2, 0), (2, 2, 0)]):
            with self.assertRaises(managed.PrivateVolumeError): managed.require_private_volume(self.root, cache=self.cache)
        self.assertEqual(self.cache.profiles, {})
        self.assertEqual(list(self.root.iterdir()), [])

    def test_probe_open_failure_removes_only_its_empty_scratch(self):
        original_open = os.open
        def open_checked(path, *args, **kwargs):
            if str(path).startswith('.volume-probe-'): raise OSError(errno.EIO, 'transient')
            return original_open(path, *args, **kwargs)
        with patch.object(os, 'open', side_effect=open_checked):
            with self.assertRaises(managed.PrivateVolumeError): managed.require_private_volume(self.root, cache=self.cache)
        self.assertEqual(list(self.root.iterdir()), [])
        self.assertEqual(self.cache.profiles, {})

    def test_cleanup_preserves_replaced_probe_directory(self):
        def replace_scratch(fd):
            probe = next(self.root.glob('.volume-probe-*'))
            probe.rename(self.root / 'original')
            probe.mkdir(mode=0o700)
            (probe / 'keep').write_text('replacement')
        with patch.object(os, 'fsync', side_effect=replace_scratch):
            managed.require_private_volume(self.root, cache=self.cache)
        self.assertEqual((next(self.root.glob('.volume-probe-*')) / 'keep').read_text(), 'replacement')
        self.assertEqual(list((self.root / 'original').iterdir()), [])

    def test_fork_reset_does_not_inherit_profiles_or_locked_mutex(self):
        original = managed._private_volume_cache
        self.addCleanup(setattr, managed, '_private_volume_cache', original)
        with original.lock:
            managed._reset_private_volume_cache()
            self.assertIsNot(managed._private_volume_cache.lock, original.lock)
            self.assertEqual(managed._private_volume_cache.profiles, {})

    def test_known_root_checks_every_directory_before_probing(self):
        child = self.root / 'instances'; child.mkdir(mode=0o755)
        with patch.object(managed, '_probe_private_volume') as probe:
            with self.assertRaises(managed.PrivateDirectoryError): managed.check_managed_directories(self.root)
            probe.assert_not_called()
        managed.check_managed_directories(self.root, repair=True)
        self.assertEqual(child.stat().st_mode & 0o7777, 0o700)

    def test_installation_and_repair_stop_before_payload_or_configuration_writes(self):
        active = self.root / 'runtime.json'; active.write_bytes(b'previous descriptor')
        with patch.object(managed, '_private_volume_cache', self.cache), \
             patch.object(managed, '_probe_private_volume', return_value=(True, False)), \
             patch.object(managed, 'download') as download, \
             patch.object(managed, 'bounded_run') as run, \
             patch.object(managed, 'atomic_json') as write:
            with self.assertRaises(managed.PrivateVolumeError): managed.install(self.root, self.root)
            with self.assertRaises(managed.PrivateVolumeError): managed.ensure(self.root, self.root)
            download.assert_not_called(); run.assert_not_called(); write.assert_not_called()
        self.assertEqual(active.read_bytes(), b'previous descriptor')
        self.assertFalse((self.root / 'installations').exists())
        self.assertFalse((self.root / 'provisioning.json').exists())

    def test_audit_and_repair_report_storage_issue_without_record_writes(self):
        with patch.object(managed, 'load_descriptor', side_effect=managed.PrivateVolumeError('atomic_rename')), \
             patch.object(managed, 'require_offline'), patch.object(managed, 'atomic_json') as write:
            result = managed.audit(self.root / 'runtime.json')
            self.assertEqual(result['causes'], ['private_directory_volume_atomic_rename'])
            self.assertFalse(result['ok'])
            with self.assertRaisesRegex(managed.ManagedRuntimeError, 'no automatic repair'):
                managed.repair(self.root / 'runtime.json', self.root)
            write.assert_not_called()
        self.assertEqual(list(self.root.iterdir()), [])


if __name__ == '__main__': unittest.main()
