"""Private SQLite companion fences; local fixtures only, no runtime launches."""
from contextlib import closing
import errno
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import managed_openclaw as managed


class Clock:
    def __init__(self): self.value = 0.0
    def __call__(self): return self.value


class DatabaseSidecarTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.state = Path(temporary.name).resolve()
        self.database = self.state / managed.SQLITE_HEALTH_FILES[0]
        with closing(sqlite3.connect(self.database)) as connection:
            connection.execute('CREATE TABLE fixture (value TEXT)')

    def health(self, **kwargs):
        return managed.known_database_health(self.state, **kwargs)[managed.SQLITE_HEALTH_FILES[0]]

    def sidecar(self, suffix):
        return self.database.with_name(self.database.name + suffix)

    def test_healthy_rollback_database_and_stable_missing_database(self):
        before = self.database.read_bytes()
        states = managed.known_database_health(self.state)
        self.assertEqual(states, {managed.SQLITE_HEALTH_FILES[0]:'ok', managed.SQLITE_HEALTH_FILES[1]:'missing'})
        self.assertEqual(self.database.read_bytes(), before)

    def test_real_wal_check_keeps_database_and_wal_unchanged_without_checkpointing(self):
        with closing(sqlite3.connect(self.database)) as writer:
            writer.execute('PRAGMA journal_mode=WAL')
            writer.execute('PRAGMA wal_autocheckpoint=0')
            writer.execute("INSERT INTO fixture VALUES ('private synthetic fixture')")
            writer.commit()
            originals = {path:path.read_bytes() for path in (self.database, self.sidecar('-wal'))}
            identities = {self.sidecar(suffix):self.sidecar(suffix).stat().st_ino for suffix in ('-wal', '-shm')}
            statements = []; descriptors = []
            connect, open_file = sqlite3.connect, os.open
            def reader(database_uri, **kwargs):
                self.assertTrue(database_uri.endswith('?mode=ro'))
                connection = connect(database_uri, **kwargs)
                connection.set_trace_callback(statements.append)
                return connection
            def opened(path, flags, *args, **kwargs):
                self.assertIn(Path(path), identities)
                self.assertTrue(flags & os.O_NOFOLLOW)
                self.assertTrue(flags & os.O_NONBLOCK)
                self.assertTrue(flags & os.O_CLOEXEC)
                self.assertFalse(flags & (os.O_CREAT | os.O_TRUNC | os.O_WRONLY | os.O_RDWR))
                fd = open_file(path, flags, *args, **kwargs)
                descriptors.append(fd)
                return fd
            with patch.object(managed.sqlite3, 'connect', side_effect=reader), \
                 patch.object(managed.os, 'open', side_effect=opened), \
                 patch.object(managed.os, 'read', side_effect=AssertionError('sidecar contents must not be read')):
                self.assertEqual(self.health(), 'ok')
            self.assertEqual(len(descriptors), 2)
            for fd in descriptors:
                with self.assertRaises(OSError): os.fstat(fd)
            for path, contents in originals.items(): self.assertEqual(path.read_bytes(), contents)
            for path, inode in identities.items(): self.assertEqual(path.stat().st_ino, inode)
            self.assertEqual(statements[-1], 'PRAGMA quick_check(1)')
            self.assertEqual(len(statements), 2)
            self.assertTrue(statements[0].startswith('PRAGMA busy_timeout='))

    def test_only_matching_companions_are_inspected_without_directory_enumeration(self):
        (self.state / 'unrelated.sqlite-wal').symlink_to('missing')
        self.database.with_name(self.database.name + '-wal.backup').symlink_to('missing')
        with patch.object(managed.os, 'scandir', side_effect=AssertionError('no directory scan')):
            self.assertEqual(self.health(), 'ok')

    def test_unexpected_links_and_nonregular_companions_block_sqlite(self):
        for suffix in ('-wal', '-shm'):
            for kind in ('symlink', 'hardlink', 'directory', 'fifo'):
                with self.subTest(suffix=suffix, kind=kind):
                    path = self.sidecar(suffix)
                    if kind == 'symlink': path.symlink_to('missing')
                    elif kind == 'hardlink': os.link(self.database, path)
                    elif kind == 'directory': path.mkdir()
                    else: os.mkfifo(path)
                    try:
                        with patch.object(managed, 'read_only_database_health') as check:
                            self.assertEqual(self.health(), 'inconclusive')
                            # The second known database is still checked independently.
                            self.assertFalse(any(call.args[0] == self.database for call in check.call_args_list))
                    finally:
                        if kind == 'directory': path.rmdir()
                        else: path.unlink()

    def test_companion_replacement_removal_and_access_changes_override_any_result(self):
        for suffix in ('-wal', '-shm'):
            for mutation in ('replace', 'remove', 'symlink', 'hardlink', 'mode'):
                for reported in ('ok', 'corrupt'):
                    with self.subTest(suffix=suffix, mutation=mutation, reported=reported):
                        path = self.sidecar(suffix); path.write_bytes(b'synthetic companion')
                        def check(database, **kwargs):
                            if database != self.database: return 'missing'
                            if mutation == 'replace':
                                other = path.with_suffix('.replacement'); other.write_bytes(path.read_bytes()); other.replace(path)
                            elif mutation == 'remove': path.unlink()
                            elif mutation == 'symlink': path.unlink(); path.symlink_to(self.database.name)
                            elif mutation == 'hardlink': os.link(path, self.state / 'unexpected-link')
                            else: path.chmod(0o400 if path.stat().st_mode & 0o200 else 0o600)
                            return reported
                        try:
                            with patch.object(managed, 'read_only_database_health', side_effect=check):
                                self.assertEqual(self.health(), 'inconclusive')
                        finally:
                            path.unlink(missing_ok=True)
                            (self.state / 'unexpected-link').unlink(missing_ok=True)

    def test_companion_appearing_during_check_is_inconclusive(self):
        for suffix in ('-wal', '-shm'):
            with self.subTest(suffix=suffix):
                path = self.sidecar(suffix)
                def check(database, **kwargs):
                    if database != self.database: return 'missing'
                    path.write_bytes(b'synthetic companion')
                    return 'corrupt'
                with patch.object(managed, 'read_only_database_health', side_effect=check):
                    self.assertEqual(self.health(), 'inconclusive')
                path.unlink()

    def test_open_failure_or_nofollow_race_is_inconclusive(self):
        self.sidecar('-wal').write_bytes(b'synthetic companion')
        for code in (errno.EACCES, errno.ELOOP, errno.ENOENT, errno.EIO):
            with self.subTest(code=code), patch.object(managed.os, 'open', side_effect=OSError(code, 'injected')), \
                 patch.object(managed, 'read_only_database_health') as check:
                self.assertEqual(self.health(), 'inconclusive')
                self.assertFalse(any(call.args[0] == self.database for call in check.call_args_list))

    def test_unexpected_owner_blocks_sqlite(self):
        self.sidecar('-shm').write_bytes(b'synthetic companion')
        owner = os.getuid()
        with patch.object(managed.os, 'getuid', return_value=owner + 1), \
             patch.object(managed.sqlite3, 'connect') as connect:
            self.assertEqual(self.health(), 'inconclusive')
            connect.assert_not_called()

    def test_replacement_between_metadata_and_open_is_inconclusive_and_closes_handle(self):
        path = self.sidecar('-wal'); path.write_bytes(b'synthetic companion')
        replacement = self.state / 'replacement'; replacement.write_bytes(b'different object')
        opened = os.open; descriptors = []
        def replace_and_open(value, *args, **kwargs):
            replacement.replace(path)
            fd = opened(value, *args, **kwargs); descriptors.append(fd)
            return fd
        with patch.object(managed.os, 'open', side_effect=replace_and_open), \
             patch.object(managed.sqlite3, 'connect') as connect:
            self.assertEqual(self.health(), 'inconclusive')
            connect.assert_not_called()
        for fd in descriptors:
            with self.assertRaises(OSError): os.fstat(fd)

    def test_other_known_database_remains_independent_of_bad_sidecar(self):
        second = self.state / managed.SQLITE_HEALTH_FILES[1]
        second.parent.mkdir(parents=True)
        with closing(sqlite3.connect(second)) as connection:
            connection.execute('CREATE TABLE fixture (value TEXT)')
        self.sidecar('-wal').symlink_to('missing')
        self.assertEqual(managed.known_database_health(self.state),
                         {managed.SQLITE_HEALTH_FILES[0]:'inconclusive', managed.SQLITE_HEALTH_FILES[1]:'ok'})

    def test_unreadable_metadata_before_or_after_check_is_inconclusive(self):
        path = self.sidecar('-wal'); path.write_bytes(b'synthetic companion')
        lstat = Path.lstat
        for after in (False, True):
            with self.subTest(after=after):
                checked = False
                def stat_file(value, *args, **kwargs):
                    if value == path and (not after or checked): raise PermissionError('injected')
                    return lstat(value, *args, **kwargs)
                def check(database, **kwargs):
                    nonlocal checked
                    if database != self.database: return 'missing'
                    checked = True
                    return 'corrupt'
                with patch.object(Path, 'lstat', new=stat_file), \
                     patch.object(managed, 'read_only_database_health', side_effect=check):
                    self.assertEqual(self.health(), 'inconclusive')

    def test_metadata_wait_and_query_share_one_deadline_and_busy_allowance(self):
        self.sidecar('-wal').write_bytes(b'synthetic companion')
        clock = Clock(); opened = os.open; connections = []
        def delay_open(*args, **kwargs):
            fd = opened(*args, **kwargs); clock.value += 0.45
            return fd
        class Connection:
            def execute(self, statement):
                if statement.startswith('PRAGMA busy_timeout='):
                    self.busy = int(statement.split('=')[1]); return self
                if statement == 'PRAGMA quick_check(1)': return self
                raise AssertionError('unexpected statement')
            def fetchone(self): return ('ok',)
            def set_progress_handler(self, *_): pass
            def close(self): pass
        def connect(database_uri, **kwargs):
            self.assertLessEqual(kwargs['timeout'], 0.05)
            connection = Connection(); connections.append(connection)
            return connection
        with patch.object(managed.os, 'open', side_effect=delay_open), \
             patch.object(managed.sqlite3, 'connect', side_effect=connect):
            self.assertEqual(self.health(timeout=0.5, now_monotonic=clock), 'ok')
        self.assertEqual(len(connections), 1)
        self.assertLessEqual(connections[0].busy, 50)

    def test_expired_metadata_work_skips_query_and_closes_its_descriptor(self):
        self.sidecar('-wal').write_bytes(b'synthetic companion')
        clock = Clock(); opened = os.open; descriptors = []
        def delay_open(*args, **kwargs):
            fd = opened(*args, **kwargs); descriptors.append(fd); clock.value += 1
            return fd
        with patch.object(managed.os, 'open', side_effect=delay_open), \
             patch.object(managed.sqlite3, 'connect') as connect:
            self.assertEqual(self.health(timeout=0.5, now_monotonic=clock), 'inconclusive')
            connect.assert_not_called()
        for fd in descriptors:
            with self.assertRaises(OSError): os.fstat(fd)

    def test_expired_postcheck_overrides_corruption(self):
        path = self.sidecar('-wal'); path.write_bytes(b'synthetic companion')
        clock = Clock(); lstat = Path.lstat; checked = False
        def stat_file(value, *args, **kwargs):
            if value == path and checked: clock.value += 1
            return lstat(value, *args, **kwargs)
        def check(database, **kwargs):
            nonlocal checked
            if database != self.database: return 'missing'
            self.assertEqual(kwargs['deadline'], 0.5)
            checked = True
            return 'corrupt'
        with patch.object(Path, 'lstat', new=stat_file), \
             patch.object(managed, 'read_only_database_health', side_effect=check):
            self.assertEqual(self.health(timeout=0.5, now_monotonic=clock), 'inconclusive')

    def test_missing_main_file_with_orphan_companions_is_inconclusive(self):
        self.database.unlink()
        self.sidecar('-wal').write_bytes(b'synthetic companion')
        self.assertEqual(self.health(), 'inconclusive')

    def test_stable_corrupt_main_file_is_still_reported_as_corrupt(self):
        self.database.write_bytes(b'not a database')
        self.assertEqual(self.health(), 'corrupt')

    def test_invalid_budgets_do_no_metadata_or_database_work(self):
        for timeout in (0, -1, True, float('nan'), float('inf'), 6, '0.5'):
            with self.subTest(timeout=timeout), patch.object(Path, 'lstat') as metadata, \
                 patch.object(managed.sqlite3, 'connect') as connect:
                self.assertEqual(self.health(timeout=timeout), 'inconclusive')
                metadata.assert_not_called(); connect.assert_not_called()


if __name__ == '__main__':
    unittest.main()
