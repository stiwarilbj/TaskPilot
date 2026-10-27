"""Offline profile retirement: synthetic owners, private fixtures, no OpenClaw."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import managed_openclaw as managed
import managed_profiles as profiles
import request_policy as policy


class ManagedProfileTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.root = self.base / 'managed'; self.root.mkdir(mode=0o700)
        (self.root / 'instances').mkdir(mode=0o700)
        self.owner = dict(pid=999999, seconds=123, microseconds=456)
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, ORBIT_RUNTIME_STATE_DIRECTORY=str(self.base / 'policy')).start()

    def tracked(self):
        state = self.root / 'instances' / str(uuid.uuid4()); state.mkdir(mode=0o700)
        (state / 'workspace').mkdir(mode=0o700)
        with patch.object(managed, 'process_identity', return_value=self.owner), patch.object(profiles.time, 'time', return_value=100):
            profiles.register_owner(self.root, state, created=True)
        return state

    def record(self, state):
        return json.loads((state / profiles.MARKER).read_text())

    def aged(self, state):
        record = self.record(state); record['unreferenced_since'] = 100
        managed.atomic_json(state / profiles.MARKER, record)

    def collect(self, **kwargs):
        with patch.object(profiles, '_gone', return_value=True):
            return profiles.collect(self.root, now=kwargs.pop('now', 1_000_000), **kwargs)

    def descriptor(self, state, name='runtime.json'):
        install = self.root / 'installations/fixture'; install.mkdir(parents=True, mode=0o700, exist_ok=True)
        (self.root / 'installations').chmod(0o700)
        value = dict(version=1, openclaw_version='fixture', node_version='fixture', instance_id=state.name,
                     port=24200, endpoint='ws://127.0.0.1:24200', installation_fingerprint='fixture',
                     configuration_fingerprint='fixture', executable=str(state / 'openclaw'),
                     node=str(install / 'node/bin/node'), entry=str(install / 'entry'), state=str(state),
                     workspace=str(state / 'workspace'), config=str(state / 'openclaw.json'), token_file=str(state / 'token'))
        managed.atomic_json(self.root / name, value)
        self.assertEqual(managed.load_descriptor(self.root / name), value)

    def test_unreferenced_profile_gets_a_full_grace_period(self):
        state = self.tracked(); (state / 'openclaw.json').write_text('private data')
        self.assertEqual(self.collect(now=100)['removed'], 0)
        self.assertEqual(self.record(state)['unreferenced_since'], 100)
        self.assertEqual(self.collect(now=100 + profiles.GRACE_SECONDS - 1)['removed'], 0)
        result = self.collect(now=100 + profiles.GRACE_SECONDS)
        self.assertEqual(result, dict(version=1, inspected=1, removed=1, deferred=0))
        self.assertFalse(state.exists())
        self.assertNotIn('private data', json.dumps(result))

    def test_active_rollback_and_previous_descriptors_all_protect_profiles(self):
        for name in ('runtime.json', 'working-runtime.json', 'previous-runtime.json'):
            state = self.tracked(); self.aged(state); self.descriptor(state, name)
        abandoned = self.tracked(); self.aged(abandoned)
        self.assertEqual(self.collect()['removed'], 1)
        self.assertFalse(abandoned.exists())
        for name in ('runtime.json', 'working-runtime.json', 'previous-runtime.json'):
            state = Path(managed.load_descriptor(self.root / name)['state'])
            self.assertTrue(state.exists())
            self.assertIsNone(self.record(state)['unreferenced_since'])

    def test_bad_descriptor_aborts_without_deleting_any_profile(self):
        state = self.tracked(); self.aged(state)
        (self.root / 'runtime.json').write_text('{bad')
        with self.assertRaises(managed.ManagedRuntimeError): self.collect()
        self.assertTrue(state.exists())

    def test_live_or_uncertain_owner_resets_grace(self):
        state = self.tracked(); self.aged(state)
        with patch.object(profiles, '_gone', return_value=False):
            self.assertEqual(profiles.collect(self.root, now=1_000_000)['removed'], 0)
        self.assertIsNone(self.record(state)['unreferenced_since'])
        self.assertEqual(self.collect()['removed'], 0)
        self.assertEqual(self.record(state)['unreferenced_since'], 1_000_000)

    def test_birth_identity_and_definite_exit_are_required(self):
        with patch.object(managed, 'process_identity', return_value=self.owner):
            self.assertFalse(profiles._gone(self.owner))
        with patch.object(managed, 'process_identity', return_value={**self.owner, 'seconds':124}):
            self.assertTrue(profiles._gone(self.owner))  # PID reuse is not the old owner.
        with patch.object(managed, 'process_identity', return_value=None):
            for error, gone in ((None, False), (ProcessLookupError(), True), (PermissionError(), False), (OSError(), False)):
                with self.subTest(error=error), patch.object(profiles.os, 'kill', side_effect=error):
                    self.assertEqual(profiles._gone(self.owner), gone)

    def test_real_child_owner_is_retained_until_it_exits(self):
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            identity = managed.process_identity(child.pid)
            if identity is None: self.skipTest('Process birth identity is unavailable on this platform')
            state = self.tracked(); record = self.record(state)
            record.update(owners=[identity], unreferenced_since=100)
            managed.atomic_json(state / profiles.MARKER, record)
            self.assertEqual(profiles.collect(self.root, now=1_000_000)['removed'], 0)
            self.assertTrue(state.exists())
        finally:
            child.terminate(); child.wait(timeout=5)
        self.assertEqual(profiles.collect(self.root, now=1_000_000)['removed'], 0)
        self.assertEqual(profiles.collect(self.root, now=1_000_000 + profiles.GRACE_SECONDS)['removed'], 1)

    def test_registration_does_not_adopt_legacy_or_unknown_owners(self):
        for identity in (self.owner, None):
            state = self.root / 'instances' / str(uuid.uuid4()); state.mkdir(mode=0o700)
            with patch.object(managed, 'process_identity', return_value=identity):
                profiles.register_owner(self.root, state)
            self.assertFalse((state / profiles.MARKER).exists())
        state = self.root / 'instances' / str(uuid.uuid4()); state.mkdir(mode=0o700)
        with patch.object(managed, 'process_identity', return_value=None):
            profiles.register_owner(self.root, state, created=True)
        self.assertFalse((state / profiles.MARKER).exists())
        self.assertEqual(self.collect()['removed'], 0)

    def test_same_owner_avoids_rewrites_and_overflow_disables_collection(self):
        state = self.tracked()
        with patch.object(managed, 'process_identity', return_value=self.owner), patch.object(profiles, '_gone', return_value=False), \
                patch.object(profiles, '_write_record', wraps=profiles._write_record) as writes:
            profiles.register_owner(self.root, state)
            writes.assert_not_called()
        record = self.record(state)
        record['owners'] = [dict(pid=i + 100, seconds=123, microseconds=0) for i in range(profiles.MAX_OWNERS)]
        managed.atomic_json(state / profiles.MARKER, record)
        with patch.object(managed, 'process_identity', return_value=self.owner), patch.object(profiles, '_gone', return_value=False):
            profiles.register_owner(self.root, state)
        self.assertFalse(self.record(state)['collectable'])
        self.aged(state)
        self.assertEqual(self.collect()['removed'], 0)

    def test_only_recorded_private_uuid_directories_are_eligible(self):
        tracked = self.tracked(); self.aged(tracked)
        legacy = self.root / 'instances' / str(uuid.uuid4()); legacy.mkdir(mode=0o700)
        ordinary = self.root / 'instances/shared-profile'; ordinary.mkdir(mode=0o700)
        (ordinary / 'user-file').write_text('keep')
        public = self.tracked(); self.aged(public); public.chmod(0o755)
        self.assertEqual(self.collect()['removed'], 1)
        for state in (legacy, ordinary, public): self.assertTrue(state.exists())

    def test_replaced_profile_identity_is_never_adopted(self):
        state = self.tracked(); self.aged(state)
        record = (state / profiles.MARKER).read_bytes()
        old = self.base / 'original'; state.rename(old); state.mkdir(mode=0o700)
        (state / profiles.MARKER).write_bytes(record); (state / profiles.MARKER).chmod(0o600)
        (state / 'keep').write_text('replacement')
        self.assertEqual(self.collect()['removed'], 0)
        self.assertEqual((state / 'keep').read_text(), 'replacement')
        self.assertTrue(old.exists())

    def test_symlinked_profile_or_record_is_not_followed(self):
        outside = self.base / 'outside'; outside.mkdir(mode=0o700)
        (outside / 'keep').write_text('keep')
        (self.root / 'instances' / str(uuid.uuid4())).symlink_to(outside)
        state = self.tracked(); self.aged(state)
        (state / profiles.MARKER).rename(outside / 'record')
        (state / profiles.MARKER).symlink_to(outside / 'record')
        self.assertEqual(self.collect()['removed'], 0)
        self.assertEqual((outside / 'keep').read_text(), 'keep')
        self.assertTrue((outside / 'record').exists())

    def test_nonempty_or_symlinked_workspace_preserves_user_files(self):
        state = self.tracked(); self.aged(state)
        output = state / 'workspace/report.txt'; output.write_text('user result')
        self.assertEqual(self.collect()['removed'], 0)
        self.assertEqual(output.read_text(), 'user result')
        self.assertIsNone(self.record(state)['unreferenced_since'])
        output.unlink(); (state / 'workspace').rmdir()
        outside = self.base / 'user-folder'; outside.mkdir(); (outside / 'keep').write_text('keep')
        (state / 'workspace').symlink_to(outside)
        self.aged(state)
        self.assertEqual(self.collect()['removed'], 0)
        self.assertEqual((outside / 'keep').read_text(), 'keep')

    def test_nested_symlinks_are_unlinked_without_touching_their_destinations(self):
        state = self.tracked(); self.aged(state)
        outside = self.base / 'outside'; outside.mkdir(); (outside / 'keep').write_text('keep')
        (state / 'agents').mkdir(); (state / 'agents/link').symlink_to(outside)
        self.assertEqual(self.collect()['removed'], 1)
        self.assertEqual((outside / 'keep').read_text(), 'keep')

    def test_removal_budget_preserves_marker_for_later_continuation(self):
        state = self.tracked(); self.aged(state)
        for i in range(5): (state / str(i)).write_text('private fixture')
        self.assertEqual(self.collect(max_removals=2)['removed'], 0)
        self.assertTrue((state / profiles.MARKER).exists())
        self.assertGreaterEqual(len(list(state.iterdir())), 4)
        self.assertEqual(self.collect()['removed'], 1)

    def test_expired_time_budget_performs_no_profile_work(self):
        state = self.tracked(); self.aged(state)
        with patch.object(profiles, '_record', wraps=profiles._record) as reads:
            result = self.collect(budget_seconds=0)
            reads.assert_not_called()
        self.assertEqual(result['removed'], 0); self.assertTrue(state.exists())

    def test_clock_regression_restarts_the_grace_period(self):
        state = self.tracked(); self.aged(state)
        self.assertEqual(self.collect(now=50)['removed'], 0)
        self.assertEqual(self.record(state)['unreferenced_since'], 50)
        for values in ({'now':float('nan')}, {'now':True}, {'grace_seconds':float('inf')},
                       {'budget_seconds':-1}, {'max_removals':True}):
            with self.subTest(values=values), self.assertRaises(ValueError): self.collect(**values)
        self.assertTrue(state.exists())

    def test_corrupt_duplicate_and_oversized_records_are_retained(self):
        state = self.tracked(); original = self.record(state)
        cases = ['{bad', json.dumps(original)[:-1] + ',"version":1}', 'x' * 8193,
                 json.dumps({**original, 'created_at':float('nan')}),
                 json.dumps({**original, 'owners':[]}), json.dumps({**original, 'collectable':1})]
        for content in cases:
            (state / profiles.MARKER).write_text(content)
            with self.subTest(content=content[:30]): self.assertEqual(self.collect()['removed'], 0)
        self.assertTrue(state.exists())

    def test_busy_configuration_installation_and_provisioning_are_not_waited_on(self):
        state = self.tracked(); self.aged(state)
        with policy.private_lock(policy.runtime_state_root() / 'openclaw-configuration.lock'):
            self.assertEqual(self.collect()['deferred'], 1)
        with managed.locked(self.root): self.assertEqual(self.collect()['deferred'], 1)
        with managed.ProvisioningJournal(self.root), self.assertRaises(managed.ManagedRuntimeError): self.collect()
        self.assertTrue(state.exists())

    def test_live_gateway_refuses_collection_even_without_a_descriptor(self):
        state = self.tracked(); self.aged(state)
        managed.atomic_json(self.root / 'gateway-root.json', self.owner)
        with patch.object(managed, 'identity_alive', return_value=True), self.assertRaises(managed.ManagedRuntimeError): self.collect()
        self.assertTrue(state.exists())

    def test_concurrent_workspace_write_is_preserved(self):
        state = self.tracked(); self.aged(state)
        remove = profiles._remove_contents
        def race(*args, **kwargs):
            (state / 'workspace/report').write_text('new output')
            return remove(*args, **kwargs)
        with patch.object(profiles, '_remove_contents', side_effect=race): self.assertEqual(self.collect()['removed'], 0)
        self.assertEqual((state / 'workspace/report').read_text(), 'new output')

    def test_directory_replacement_during_cleanup_cannot_delete_the_new_target(self):
        state = self.tracked(); self.aged(state)
        moved = self.base / 'moved'
        def replace(fd, device, remaining, deadline, depth=0):
            state.rename(moved); state.mkdir(mode=0o700); (state / 'keep').write_text('replacement')
            return True
        with patch.object(profiles, '_remove_contents', side_effect=replace): self.assertEqual(self.collect()['removed'], 0)
        self.assertEqual((state / 'keep').read_text(), 'replacement')
        self.assertTrue((moved / profiles.MARKER).exists())

    def test_record_updates_stay_relative_to_the_opened_directory(self):
        state = self.tracked(); moved = self.base / 'moved'
        fd = os.open(state, os.O_RDONLY | os.O_DIRECTORY)
        try:
            record = profiles._record(fd)
            state.rename(moved); state.mkdir(mode=0o700)
            record['unreferenced_since'] = 100
            profiles._write_record(fd, record)
            self.assertEqual(self.record(moved)['unreferenced_since'], 100)
            self.assertFalse((state / profiles.MARKER).exists())
        finally: os.close(fd)

    def test_profile_enumeration_is_bounded(self):
        for _ in range(5): self.tracked()
        with patch.object(profiles, 'MAX_PROFILES', 2): result = self.collect()
        self.assertEqual(result['inspected'], 2)


if __name__ == '__main__': unittest.main()
