"""Crash-injected provisioning with tiny local archives; no runtime or network."""
from contextlib import contextmanager
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import managed_openclaw as managed


class Interrupted(BaseException):
    pass


class ProvisioningTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.root = self.base / 'managed'
        self.root.mkdir(mode=0o700)
        (self.root / 'installations').mkdir(mode=0o700)
        self.resources = self.base / 'resources'
        self.resources.mkdir()
        for name in ('package.json', 'package-lock.json'):
            (self.resources / name).write_text('{}')
        self.archive = self.resources / 'fixture.tar.gz'
        with tarfile.open(self.archive, 'w:gz') as archive:
            for name in ('bin/node', 'lib/node_modules/npm/bin/npm-cli.js'):
                info = tarfile.TarInfo('fixture/' + name)
                info.size = len(b'fixture'); info.mode = 0o700
                archive.addfile(info, io.BytesIO(b'fixture'))
        self.fingerprint = hashlib.sha256(b'fixture-installation').hexdigest()
        self.manifest = dict(openclaw_version='2026.9.5', node_version='24.22.1',
                             node_archives={platform.machine(): dict(name='fixture.tar.gz', sha256=managed.digest(self.archive))})
        self.calls = []

    def cli(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        if 'ci' in argv:
            package = Path(kwargs['cwd']) / 'node_modules/openclaw'
            package.mkdir(parents=True)
            (package / 'package.json').write_text(json.dumps({'version':self.manifest['openclaw_version']}))
            (package / 'openclaw.mjs').write_text('fixture module')
        return self.manifest['openclaw_version'] if '--version' in argv else ''

    @contextmanager
    def build(self):
        def download(url, destination, expected):
            self.assertEqual(expected, managed.digest(self.archive))
            destination.write_bytes(self.archive.read_bytes())
        with patch.object(managed, 'specification', return_value=(self.manifest, self.fingerprint)), \
             patch.object(managed, 'download', side_effect=download) as downloads, \
             patch.object(managed, 'bounded_run', side_effect=self.cli) as runs:
            yield downloads, runs

    @contextmanager
    def crash_at(self, phase):
        original = managed.ProvisioningJournal.record
        def record(journal, *args, **kwargs):
            value = original(journal, *args, **kwargs)
            if value['phase'] == phase and (phase != 'staging' or value['stage_identity'] is not None):
                raise Interrupted()
            return value
        with patch.object(managed.ProvisioningJournal, 'record', new=record):
            yield

    def sealed(self, directory, fingerprint):
        directory.mkdir(mode=0o700)
        (directory / 'code').write_text('previous verified code')
        managed.atomic_json(directory / 'integrity.json', dict(fingerprint=fingerprint, files=managed.seal(directory)))
        return directory

    def marker(self):
        with managed.ProvisioningJournal(self.root) as journal:
            return journal.read()

    def preserve_active(self):
        old = self.sealed(self.root / 'installations/old', 'old')
        managed.atomic_json(self.root / 'runtime.json', {'fixture':'previous descriptor'})
        before = {p.relative_to(self.root):p.read_bytes() for p in old.rglob('*') if p.is_file()}
        before[Path('runtime.json')] = (self.root / 'runtime.json').read_bytes()
        return before

    def assert_preserved(self, before):
        for name, data in before.items():
            self.assertEqual((self.root / name).read_bytes(), data)

    def test_incomplete_stage_is_removed_without_touching_other_work(self):
        for phase in ('staging', 'sealing'):
            with self.subTest(phase=phase):
                self.root = self.base / phase; self.root.mkdir(mode=0o700)
                (self.root / 'installations').mkdir(mode=0o700)
                before = self.preserve_active()
                unrelated = self.root / 'installations/.stage-unrelated'
                unrelated.mkdir(); (unrelated / 'keep').write_text('unrelated')
                with self.build() as (downloads, _):
                    with self.crash_at(phase), self.assertRaises(Interrupted):
                        managed.install(self.resources, self.root)
                    record = self.marker(); stage = self.root / 'installations' / ('.stage-' + record['stage_id'])
                    self.assertTrue(stage.exists())
                    downloads.reset_mock()
                    target, fingerprint, _ = managed.install(self.resources, self.root)
                    downloads.assert_called_once()
                    self.assertFalse(stage.exists())
                    self.assertTrue(managed.validate_install(target, fingerprint, force_full=True))
                self.assertEqual((unrelated / 'keep').read_text(), 'unrelated')
                self.assert_preserved(before)

    def test_sealed_stage_resumes_only_after_full_integrity_validation(self):
        for phase in ('sealed', 'promoting'):
            with self.subTest(phase=phase):
                self.root = self.base / phase; self.root.mkdir(mode=0o700)
                (self.root / 'installations').mkdir(mode=0o700)
                before = self.preserve_active()
                with self.build() as (downloads, runs):
                    with self.crash_at(phase), self.assertRaises(Interrupted):
                        managed.install(self.resources, self.root)
                    downloads.reset_mock(); runs.reset_mock()
                    with patch.object(managed, '_hash_installation_file', wraps=managed._hash_installation_file) as hashes:
                        target, fingerprint, _ = managed.install(self.resources, self.root)
                    self.assertGreater(hashes.call_count, 0)
                    downloads.assert_not_called(); runs.assert_not_called()
                    self.assertTrue(managed.validate_install(target, fingerprint))
                self.assert_preserved(before)

    def test_corrupt_sealed_stage_and_changed_bundle_are_not_resumed(self):
        for change in ('contents', 'fingerprint'):
            with self.subTest(change=change):
                self.root = self.base / change; self.root.mkdir(mode=0o700)
                (self.root / 'installations').mkdir(mode=0o700)
                with self.build():
                    with self.crash_at('sealed'), self.assertRaises(Interrupted):
                        managed.install(self.resources, self.root)
                record = self.marker()
                stage = self.root / 'installations' / ('.stage-' + record['stage_id'])
                if change == 'contents': (stage / 'node/bin/node').write_text('tampered')
                else: self.fingerprint = hashlib.sha256(b'new-bundle').hexdigest()
                with self.build() as (downloads, _):
                    target, fingerprint, _ = managed.install(self.resources, self.root)
                    downloads.assert_called_once()
                self.assertFalse(stage.exists())
                self.assertTrue(managed.validate_install(target, fingerprint))

    def test_promotion_crashes_preserve_active_and_resume_without_reinstallation(self):
        for crash_after in ('quarantine', 'promotion'):
            with self.subTest(after=crash_after):
                self.root = self.base / crash_after; self.root.mkdir(mode=0o700)
                (self.root / 'installations').mkdir(mode=0o700)
                before = self.preserve_active()
                target = self.root / 'installations' / self.fingerprint
                target.mkdir(mode=0o700); (target / 'broken').write_text('bad')
                rename = Path.rename
                def interrupt(path, destination):
                    result = rename(path, destination)
                    if (crash_after == 'quarantine' and Path(destination).name.startswith('.corrupt-') or
                            crash_after == 'promotion' and path.name.startswith('.stage-')):
                        raise Interrupted()
                    return result
                with self.build() as (downloads, runs):
                    with patch.object(Path, 'rename', new=interrupt), self.assertRaises(Interrupted):
                        managed.install(self.resources, self.root)
                    self.assertEqual(self.marker()['phase'], 'promoting')
                    downloads.reset_mock(); runs.reset_mock()
                    installed, fingerprint, _ = managed.install(self.resources, self.root)
                    downloads.assert_not_called(); runs.assert_not_called()
                self.assertTrue(managed.validate_install(installed, fingerprint))
                self.assertEqual(len(list(target.parent.glob('.corrupt-*'))), 1)
                self.assert_preserved(before)

    def test_existing_verified_target_wins_over_recovered_duplicate(self):
        with self.build():
            target, _, _ = managed.install(self.resources, self.root)
            identity = target.stat().st_ino
            with managed.ProvisioningJournal(self.root) as journal:
                stage_id = 'a' * 32
                stage = self.sealed(target.parent / ('.stage-' + stage_id), self.fingerprint)
                info = stage.stat()
                journal.record('sealed', self.fingerprint, stage_id, dict(device=info.st_dev, inode=info.st_ino))
            with self.build() as (downloads, runs):
                installed, _, _ = managed.install(self.resources, self.root)
                downloads.assert_not_called(); runs.assert_not_called()
            self.assertEqual(installed.stat().st_ino, identity)
            self.assertFalse(stage.exists())

    def test_marker_is_private_bounded_and_contains_only_opaque_fields(self):
        snapshots = []
        original = managed.atomic_json
        def capture(path, value):
            if path.name == 'provisioning.json': snapshots.append(value.copy())
            result = original(path, value)
            if path.name == 'provisioning.json':
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            return result
        with self.build(), patch.object(managed, 'atomic_json', side_effect=capture), \
             patch.object(managed, 'verify_settings'):
            descriptor = managed.ensure(self.resources, self.root, key='secret-api-key-not-in-journal')
        phases = [v['phase'] for v in snapshots]
        for phase in ('staging', 'sealing', 'sealed', 'promoting', 'promoted', 'configuration', 'readback', 'activating', 'activated'):
            self.assertIn(phase, phases)
        for value in snapshots:
            self.assertTrue(managed.ProvisioningJournal.valid(value))
            self.assertLess(len(json.dumps(value)), 4096)
        data = json.dumps(snapshots)
        for forbidden in ('secret-api-key', str(self.root), descriptor['instance_id'], 'gateway', 'config_contents'):
            self.assertNotIn(forbidden, data)
        self.assertFalse((self.root / 'provisioning.json').exists())
        self.assertEqual((self.root / 'provisioning-lease.lock').stat().st_mode & 0o777, 0o600)
        self.assertTrue(all(call[1]['pass_fds'] for call in self.calls))

    def test_interrupted_readback_repeats_authoritative_configuration_checks(self):
        with self.build(), patch.object(managed, 'verify_settings') as readback:
            first = managed.ensure(self.resources, self.root)
            before = (self.root / 'runtime.json').read_bytes()
            config = Path(first['config']).read_bytes()
            readback.reset_mock(); self.calls.clear()
            with self.crash_at('readback'), self.assertRaises(Interrupted):
                managed.ensure(self.resources, self.root)
            self.assertEqual((self.root / 'runtime.json').read_bytes(), before)
            self.assertEqual(Path(first['config']).read_bytes(), config)
            managed.ensure(self.resources, self.root)
            readback.assert_called_once()
            self.assertTrue(any('patch' in argv for argv, _ in self.calls))
            self.assertFalse((self.root / 'provisioning.json').exists())
            # A healthy refresh uses no patch/readback generation or reinstalls.
            readback.reset_mock(); self.calls.clear()
            managed.ensure(self.resources, self.root)
            readback.assert_not_called()
            self.assertFalse(any('patch' in argv for argv, _ in self.calls))

    def test_activation_flag_survives_repeated_interruption(self):
        original = managed.atomic_json
        def interrupt(path, value):
            if path.name == 'activation-verification.json': raise Interrupted()
            original(path, value)
        with self.build(), patch.object(managed, 'verify_settings'):
            with patch.object(managed, 'atomic_json', side_effect=interrupt), self.assertRaises(Interrupted):
                managed.ensure(self.resources, self.root)
            self.assertEqual(self.marker()['phase'], 'activating')
            descriptor = managed.load_descriptor(self.root / 'runtime.json')
            with self.crash_at('configuration'), self.assertRaises(Interrupted):
                managed.ensure(self.resources, self.root)
            flag = self.root / 'activation-verification.json'
            self.assertEqual(json.loads(flag.read_text())['installation_fingerprint'], descriptor['installation_fingerprint'])
            managed.ensure(self.resources, self.root)
            self.assertTrue(flag.exists())
            self.assertFalse((self.root / 'provisioning.json').exists())

    def test_failed_readback_cannot_publish_new_runtime_or_change_old_configuration(self):
        with self.build(), patch.object(managed, 'verify_settings'):
            first = managed.ensure(self.resources, self.root)
        before = (self.root / 'runtime.json').read_bytes()
        config = Path(first['config']).read_bytes()
        self.fingerprint = hashlib.sha256(b'new-bundle').hexdigest()
        with self.build(), patch.object(managed, 'verify_settings', side_effect=managed.ManagedRuntimeError('readback failed')):
            with self.assertRaisesRegex(managed.ManagedRuntimeError, 'readback failed'):
                managed.ensure(self.resources, self.root)
        self.assertEqual((self.root / 'runtime.json').read_bytes(), before)
        self.assertEqual(Path(first['config']).read_bytes(), config)
        self.assertTrue(managed.validate_install(Path(first['node']).parents[2], first['installation_fingerprint']))

    def test_malformed_markers_cannot_trigger_cleanup_or_installation(self):
        before = self.preserve_active()
        valid = dict(version=1, phase='staging', fingerprint=self.fingerprint, stage_id='a'*32, stage_identity=None)
        cases = [b'{', b'x'*4097, b'['*1500 + b']'*1500, json.dumps({**valid, 'stage_id':'../outside'}).encode(),
                 json.dumps({**valid, 'version':True}).encode(), json.dumps({**valid, 'phase':[]}).encode(),
                 json.dumps({**valid, 'stage_identity':{'device':True, 'inode':1}}).encode(),
                 json.dumps({**valid, 'extra':'secret'}).encode(),
                 json.dumps(valid).replace('"version": 1', '"version": 1, "version": 1').encode()]
        for data in cases:
            with self.subTest(data=data[:80]), self.build() as (downloads, runs):
                marker = self.root / 'provisioning.json'
                marker.write_bytes(data); marker.chmod(0o600)
                with self.assertRaisesRegex(managed.ManagedRuntimeError, 'journal needs attention'):
                    managed.install(self.resources, self.root)
                downloads.assert_not_called(); runs.assert_not_called()
                self.assert_preserved(before)

    def test_marker_symlink_or_fifo_is_rejected_without_following_or_blocking(self):
        marker = self.root / 'provisioning.json'
        outside = self.base / 'keep'; outside.write_text('keep')
        marker.symlink_to(outside)
        for kind in ('symlink', 'fifo'):
            with self.subTest(kind=kind), managed.ProvisioningJournal(self.root) as journal:
                if kind == 'fifo': marker.unlink(); os.mkfifo(marker, 0o600)
                with self.assertRaises(managed.ManagedRuntimeError): journal.read()
        self.assertEqual(outside.read_text(), 'keep')
        marker.unlink()

    def test_unbound_empty_stage_can_be_removed_but_unbound_contents_are_preserved(self):
        with managed.ProvisioningJournal(self.root) as journal:
            record = journal.record('staging', self.fingerprint, 'a'*32)
            stage = journal.stage(record); stage.mkdir(mode=0o700)
            journal.recover_stage(self.fingerprint)
            self.assertFalse(stage.exists()); self.assertIsNone(journal.read())
            record = journal.record('staging', self.fingerprint, 'b'*32)
            stage = journal.stage(record); stage.mkdir(mode=0o700); (stage / 'unexpected').write_text('keep')
            with self.assertRaisesRegex(managed.ManagedRuntimeError, 'not empty'):
                journal.recover_stage(self.fingerprint)
            self.assertEqual((stage / 'unexpected').read_text(), 'keep')

    def test_stage_replacement_is_rejected_and_nested_symlink_cleanup_is_confined(self):
        outside = self.base / 'outside'; outside.mkdir(); (outside / 'keep').write_text('keep')
        with managed.ProvisioningJournal(self.root) as journal:
            record = journal.record('staging', self.fingerprint, 'a'*32)
            stage = journal.stage(record); stage.mkdir(mode=0o700)
            info = stage.stat()
            record = journal.record('staging', self.fingerprint, 'a'*32, dict(device=info.st_dev, inode=info.st_ino))
            moved = stage.with_name('moved'); stage.rename(moved); stage.mkdir(mode=0o700)
            (stage / 'replacement').write_text('keep')
            with self.assertRaisesRegex(managed.ManagedRuntimeError, 'identity changed'):
                journal.recover_stage(self.fingerprint)
            self.assertEqual((stage / 'replacement').read_text(), 'keep')
            (stage / 'replacement').unlink(); stage.rmdir(); moved.rename(stage)
            (stage / 'link').symlink_to(outside, target_is_directory=True)
            journal.recover_stage(self.fingerprint)
            self.assertFalse(stage.exists())
        self.assertEqual((outside / 'keep').read_text(), 'keep')

    def test_journal_write_failure_prevents_payload_work_and_preserves_previous_marker(self):
        before = self.preserve_active()
        with managed.ProvisioningJournal(self.root) as journal:
            journal.record('configuration', 'old')
        previous = (self.root / 'provisioning.json').read_bytes()
        replace = os.replace
        def fail(source, target):
            if Path(target).name == 'provisioning.json': raise OSError('injected write failure')
            return replace(source, target)
        with self.build() as (downloads, runs), patch.object(os, 'replace', side_effect=fail):
            with self.assertRaises(OSError): managed.install(self.resources, self.root)
            downloads.assert_not_called(); runs.assert_not_called()
        self.assertEqual((self.root / 'provisioning.json').read_bytes(), previous)
        self.assertFalse(list(self.root.glob('.provisioning.json*')))
        self.assertFalse(list((self.root / 'installations').glob('.stage-*')))
        self.assert_preserved(before)

    def test_live_helper_retains_lease_after_controller_exit(self):
        ready = self.base / 'ready'; release = self.base / 'release'
        helper = """import os,sys,time
from pathlib import Path
os.fstat(int(sys.argv[3]))
Path(sys.argv[1]).write_text(str(os.getpid()))
while not Path(sys.argv[2]).exists(): time.sleep(.01)
"""
        controller = """import sys
from pathlib import Path
import managed_openclaw as managed
root=Path(sys.argv[1])
with managed.locked(root), managed.ProvisioningJournal(root) as journal:
    journal.record('configuration','fixture')
    journal.run([sys.executable,'-c',sys.argv[2],sys.argv[3],sys.argv[4],str(journal.fd)])
"""
        process = subprocess.Popen([sys.executable, '-c', controller, str(self.root), helper, str(ready), str(release)],
                                   env={**os.environ, 'PYTHONPATH':str(Path(managed.__file__).parent)},
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        helper_pid = None
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and process.poll() is None and time.monotonic() < deadline: time.sleep(.01)
            self.assertTrue(ready.exists())
            helper_pid = int(ready.read_text())
            process.kill(); process.wait(timeout=5)
            with managed.locked(self.root):
                with self.assertRaisesRegex(managed.ManagedRuntimeError, 'still finishing'):
                    with managed.ProvisioningJournal(self.root): self.fail('orphaned helper lease was lost')
            release.touch()
            deadline = time.monotonic() + 5
            while True:
                try:
                    with managed.ProvisioningJournal(self.root) as journal:
                        self.assertEqual(journal.read()['phase'], 'configuration')
                    break
                except managed.ManagedRuntimeError:
                    if time.monotonic() >= deadline: raise
                    time.sleep(.01)
        finally:
            release.touch()
            if process.poll() is None: process.kill(); process.wait(timeout=5)
            if helper_pid is not None:
                try: os.killpg(helper_pid, signal.SIGKILL)
                except ProcessLookupError: pass
            process.stderr.close()


if __name__ == '__main__':
    unittest.main()
