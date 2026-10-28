"""Dirty signal state is isolated in disposable hosts; no desktop/provider work."""
import errno
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT / 'AgentRuntime'))
import managed_openclaw as managed
import managed_spawn


class ManagedSpawnTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.probe = Path(cls.temporary.name) / 'signal-probe'
        subprocess.run(['/usr/bin/xcrun', 'clang', '-Werror', '-Wno-deprecated-declarations',
                        '-I', str(PROJECT / 'Sources/ProcessSupport/include'),
                        str(PROJECT / 'Tests/Fixtures/signal_state_probe.c'),
                        str(PROJECT / 'Sources/ProcessSupport/ProcessSupport.c'), '-o', str(cls.probe)], check=True)

    def dirty_host(self, body):
        source = '''
import sys, signal, json, os, threading
sys.path.insert(0, sys.argv[1])
import managed_openclaw as managed
from managed_spawn import DEFAULT_SIGNALS
probe = sys.argv[2]
for number in (*DEFAULT_SIGNALS, signal.SIGUSR1): signal.signal(number, signal.SIG_IGN)
blocked = {*DEFAULT_SIGNALS, signal.SIGUSR1}
signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
''' + body + '''
assert signal.pthread_sigmask(signal.SIG_BLOCK, ()) == blocked
assert all(signal.getsignal(number) == signal.SIG_IGN for number in (*DEFAULT_SIGNALS, signal.SIGUSR1))
'''
        result = subprocess.run([sys.executable, '-c', source, str(PROJECT / 'AgentRuntime'), str(self.probe)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_child_starts_with_empty_mask_and_defaults_without_parent_changes(self):
        text = self.dirty_host('print(managed.bounded_run([probe, "--report"]), end="")\n')
        self.assertEqual(json.loads(text), dict(mask_empty=True, defaults=True, unrelated_ignored=True,
                                               own_group=True, own_session=True))

    def test_threaded_launches_do_not_need_preexec_or_mutate_parent_state(self):
        text = self.dirty_host('''
from concurrent.futures import ThreadPoolExecutor
def run(_):
    before = signal.pthread_sigmask(signal.SIG_BLOCK, ())
    result = json.loads(managed.bounded_run([probe, "--report"]))
    assert signal.pthread_sigmask(signal.SIG_BLOCK, ()) == before
    assert all(result.values()), result
with ThreadPoolExecutor(max_workers=4) as workers: list(workers.map(run, range(12)))
print("threaded launches passed")
''')
        self.assertIn('threaded launches passed', text)

    def test_term_is_not_blocked_or_ignored_after_exec(self):
        text = self.dirty_host('print(json.dumps(managed.bounded_run([probe, "--term"], result=True)))\n')
        self.assertEqual(json.loads(text), [-signal.SIGTERM, 'ready\n'])

    def test_native_normalizes_same_teardown_signals_preserving_existing_policy(self):
        result = subprocess.run([str(self.probe), '--native-host'], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report['mask_empty']); self.assertTrue(report['defaults'])
        self.assertFalse(report['unrelated_ignored'], 'Native full-default policy must stay unchanged')
        self.assertTrue(report['own_group'])
        self.assertFalse(report['own_session'], 'Native group/session policy must stay unchanged')

    def test_input_cwd_environment_merged_output_and_nonzero_status(self):
        with tempfile.TemporaryDirectory(prefix='signal cwd ') as directory:
            code, text = managed.bounded_run([sys.executable, '-c', '''
import os,sys
assert os.getcwd() == sys.argv[1]
assert os.environ['FIXTURE'] == 'exact value'
assert sys.stdin.buffer.read() == 'Unicode 🐝'.encode()
os.write(1, b'out;'); os.write(2, b'err'); sys.exit(7)
''', os.path.realpath(directory)], cwd=directory, env={'FIXTURE': 'exact value'},
                input_data='Unicode 🐝'.encode(), result=True)
        self.assertEqual((code, text), (7, 'out;err'))
        self.assertEqual(managed.bounded_run(['/bin/cat']), '')

    def test_closed_controller_stdin_does_not_alias_child_stream_sources(self):
        text = self.dirty_host('''
os.close(0)
code = "import os,sys; assert sys.stdin.buffer.read() == b'input'; os.write(1,b'out'); os.write(2,b'err')"
assert managed.bounded_run([sys.executable, '-c', code], input_data=b'input') == 'outerr'
print('closed stdin passed')
''')
        self.assertIn('closed stdin passed', text)

    def test_explicit_leases_survive_but_unrelated_and_source_handles_close(self):
        with tempfile.TemporaryFile() as lease, tempfile.TemporaryFile() as unrelated:
            lease.write(b'lease'); lease.seek(0)
            os.set_inheritable(unrelated.fileno(), True)
            flags = [fcntl.fcntl(fd, fcntl.F_GETFD) for fd in (lease.fileno(), unrelated.fileno())]
            code = '''
import os,sys,errno
assert os.read(int(sys.argv[1]), 5) == b'lease'
for descriptor in map(int, sys.argv[2:]):
    try: os.fstat(descriptor)
    except OSError as error: assert error.errno == errno.EBADF
    else: raise AssertionError('unrelated/source descriptor inherited')
'''
            original = managed.spawn_bounded_helper
            def launch(argv, **kwargs):
                sources = {kwargs['stdin'], kwargs['stdout'], kwargs['stderr']} - {lease.fileno()}
                return original([*argv, *map(str, sorted(sources))], **kwargs)
            with patch.object(managed, 'spawn_bounded_helper', side_effect=launch):
                managed.bounded_run([sys.executable, '-c', code, str(lease.fileno()), str(unrelated.fileno())],
                                    pass_fds=(lease.fileno(),))
            self.assertEqual(flags, [fcntl.fcntl(fd, fcntl.F_GETFD) for fd in (lease.fileno(), unrelated.fileno())])

    def test_invalid_launch_and_configuration_errors_remain_exceptions(self):
        for argv, kwargs, expected in [(['/nonexistent-taskpilot-helper'], {}, FileNotFoundError),
                                        (['/usr/bin/true'], {'cwd': '/nonexistent-taskpilot-cwd'}, FileNotFoundError),
                                        (['/usr/bin/true'], {'pass_fds': (-1,)}, ValueError),
                                        (['/usr/bin/true\0ignored'], {}, ValueError),
                                        (['/usr/bin/true'], {'env': {'BAD=KEY': 'x'}}, ValueError)]:
            with self.subTest(argv=argv, kwargs=kwargs), self.assertRaises(expected): managed.bounded_run(argv, **kwargs)
        with self.assertRaises(managed.ManagedRuntimeError): managed.bounded_run(['/usr/bin/false'])

    def test_path_lookup_uses_child_environment_and_skips_nonexecutable_candidates(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); first, second = root / 'first', root / 'second'
            first.mkdir(); second.mkdir()
            (first / 'signal-helper').write_text('not executable')
            executable = second / 'signal-helper'; executable.write_text('#!/bin/sh\nprintf found')
            executable.chmod(0o700)
            self.assertEqual(managed.bounded_run(['signal-helper'], env={'PATH': str(first) + ':' + str(second)}), 'found')

    def test_spawn_attribute_failure_prevents_exec_and_destroys_initialized_objects(self):
        real = managed_spawn._api()
        class API:
            def __getattr__(self, name): return getattr(real, name)
        api = API()
        with patch.object(api, 'posix_spawnattr_setsigmask', return_value=errno.EINVAL), \
             patch.object(api, 'posix_spawn', wraps=real.posix_spawn) as launch, \
             patch.object(api, 'posix_spawnattr_destroy', wraps=real.posix_spawnattr_destroy) as destroy, \
             patch.object(api, 'posix_spawn_file_actions_destroy', wraps=real.posix_spawn_file_actions_destroy) as actions, \
             patch.object(managed_spawn, '_api', return_value=api):
            with self.assertRaises(OSError): managed.bounded_run(['/usr/bin/true'])
            launch.assert_not_called(); destroy.assert_called_once(); actions.assert_called_once()

    def test_timeout_and_interruption_keep_group_kill_and_reap_policy(self):
        with tempfile.TemporaryDirectory() as root:
            marker = Path(root) / 'late'
            with self.assertRaises(subprocess.TimeoutExpired):
                managed.bounded_run(['/bin/sh', '-c', '(/bin/sleep 0.4; /usr/bin/touch "$1") & wait', 'fixture', str(marker)], timeout=0.05)
            # A bounded fixture delay establishes the descendant never wrote.
            import time
            time.sleep(0.5)
            self.assertFalse(marker.exists())
        original, waits = managed_spawn.SpawnedProcess.wait, []
        def interrupt(process, timeout=None):
            waits.append(process)
            if len(waits) == 1: raise KeyboardInterrupt()
            return original(process, timeout)
        with patch.object(managed_spawn.SpawnedProcess, 'wait', interrupt):
            with self.assertRaises(KeyboardInterrupt): managed.bounded_run(['/bin/sleep', '5'])
        self.assertEqual(len(waits), 2)
        self.assertEqual(waits[0].returncode, -signal.SIGKILL)


if __name__ == '__main__': unittest.main()
