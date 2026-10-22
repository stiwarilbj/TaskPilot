"""Cross-process tests use fake ACP and private temporary state only."""
import json
import multiprocessing
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import request_policy as policy
import openclaw_runtime as runtime
from provider_errors import ProviderRequestError

MODEL = policy.PRIMARY_MODELS[0]
SECONDARY = policy.PRIMARY_MODELS[1]


def quota(deadline):
    return policy.Failure('quota', 'not persisted', deadline, provider='google', model=MODEL, scope='credential')


def write_model(root, model, barrier):
    state = policy.RuntimeState('key', 'v', Path(root))
    barrier.wait(5)
    state.verify(model)


def check_process(root, entered, released, count, observed, result, fail=False):
    os.environ['ORBIT_RUNTIME_STATE_DIRECTORY'] = root
    state = policy.RuntimeState('key', 'v', Path(root))
    original = state.check_revision
    def revision():
        value = original()
        observed.set()
        return value
    state.check_revision = revision
    class Client:
        prompt_calls = 0
        def __init__(self, path): pass
        def select_model(self, model): pass
        def prompt(self, *args, **kwargs):
            self.prompt_calls += 1
            with count.get_lock(): count.value += 1
            entered.set()
            if not released.wait(8): raise RuntimeError('fixture timeout')
            if fail: raise ProviderRequestError({'error': {'code': 401, 'message': 'invalid api key'}}, MODEL)
            return '{"status":"done","check":"TASKPILOT_READY"}'
        def close(self): pass
    with mock.patch.object(runtime, 'prepare_runtime', return_value=state), mock.patch.object(runtime, 'ACPClient', Client), mock.patch.object(runtime, 'emit'):
        result.put(runtime.check_models('fixture', 'key'))


def configuration_process(root, entered, released):
    os.environ['ORBIT_RUNTIME_STATE_DIRECTORY'] = root
    with policy.configuration_transaction():
        entered.set()
        released.wait(8)


def synchronize_process(root, barrier, writes):
    import subprocess
    os.environ['ORBIT_RUNTIME_STATE_DIRECTORY'] = root
    state = policy.RuntimeState('key', 'v', Path(root))
    def command(arguments, **kwargs):
        if arguments[1:3] == ['config', 'set']:
            with writes.get_lock(): writes.value += 1
            time.sleep(0.01)
        value = {'agents.defaults.modelPolicy.allow': [], 'agents.defaults.model': {},
                 'agents.defaults.imageModel': None, 'agents.defaults.models': {}}.get(arguments[3])
        return subprocess.CompletedProcess(arguments, 0, stdout=json.dumps(value))
    barrier.wait(5)
    with mock.patch.object(runtime.subprocess, 'run', side_effect=command):
        runtime.synchronize_model_configuration('fixture', state)


def abandoned_check(root, entered):
    state = policy.RuntimeState('key', 'v', Path(root))
    with state.explicit_check():
        entered.set()
        time.sleep(30)


class ProviderCoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.state = policy.RuntimeState('key', 'v', self.root)
        self.peer = policy.RuntimeState('key', 'v', self.root)
        self.mp = multiprocessing.get_context('spawn')

    def test_stale_success_cannot_clear_newer_quota(self):
        revision = self.state.refresh()
        self.peer.record_failure(MODEL, quota(time.time() + 120))
        self.assertFalse(self.state.verify(SECONDARY, revision))
        self.assertEqual(self.state.health(SECONDARY)['failure_kind'], 'quota')
        self.assertIsNone(self.state.verified_model())

    def test_success_then_failure_also_invalidates_verification(self):
        self.state.verify(SECONDARY)
        self.peer.record_failure(MODEL, quota(time.time() + 120))
        self.assertIsNone(self.state.verified_model())

    def test_cooldown_survives_version_and_configuration_changes(self):
        self.state.record_failure(MODEL, quota(time.time() + 120))
        other = policy.RuntimeState('key', 'new-version', self.root, configuration='changed')
        self.assertEqual(other.health(SECONDARY)['failure_kind'], 'quota')
        self.assertFalse(other.verify(SECONDARY, other.refresh()))
        self.assertFalse(policy.RuntimeState('different-key', 'v', self.root).health(MODEL))

    def test_shorter_concurrent_cooldown_cannot_shorten_shared_limit(self):
        deadline = time.time() + 300
        self.state.record_failure(MODEL, quota(deadline))
        self.peer.record_failure(SECONDARY, quota(deadline - 100))
        self.assertEqual(self.state.health(MODEL)['retry_at'], deadline)

    def test_expired_cooldown_can_be_cleared_by_new_success(self):
        self.state.record_failure(MODEL, quota(time.time() - 1))
        self.assertTrue(self.peer.verify(SECONDARY, self.peer.refresh()))
        self.assertFalse(self.state.health(MODEL))

    def test_unknown_reset_probe_cannot_clear_new_failure(self):
        self.state.record_failure(MODEL, quota(float('inf')))
        revision = self.state.refresh()
        self.peer.record_failure(MODEL, quota(float('inf')))
        self.assertFalse(self.state.verify(MODEL, revision))
        self.assertTrue(self.peer.verify(MODEL, self.peer.refresh()))

    def test_new_global_failure_blocks_late_sibling_success(self):
        revision = self.state.refresh()
        self.peer.record_failure(MODEL, policy.Failure('transport', 'not persisted'))
        self.assertFalse(self.state.verify(SECONDARY, revision))
        self.peer.record_failure(MODEL, policy.Failure('credentials', 'not persisted'))
        self.assertEqual(self.state.health(SECONDARY)['failure_kind'], 'credentials')

    def test_stale_invalidation_preserves_other_model_success(self):
        self.state.verify(MODEL)
        self.peer.verify(SECONDARY)
        self.state.invalidate(MODEL)
        self.assertEqual(self.peer.verified_model(), SECONDARY)

    def test_separate_process_updates_merge(self):
        barrier = self.mp.Barrier(2)
        processes = [self.mp.Process(target=write_model, args=(str(self.root), model, barrier)) for model in (MODEL, SECONDARY)]
        for process in processes: process.start()
        for process in processes:
            process.join(8)
            self.assertEqual(process.exitcode, 0)
        self.state.refresh()
        self.assertEqual(set(self.state.value['verified']), {MODEL, SECONDARY})
        self.assertEqual(self.state.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.state.value['revision'], 2)

    def coalesced_check(self, fail):
        entered, released = self.mp.Event(), self.mp.Event()
        observed = [self.mp.Event(), self.mp.Event()]
        count, result = self.mp.Value('i', 0), self.mp.Queue()
        processes = [self.mp.Process(target=check_process, args=(str(self.root), entered, released, count, signal, result, fail)) for signal in observed]
        try:
            processes[0].start()
            self.assertTrue(entered.wait(5))
            processes[1].start()
            self.assertTrue(observed[1].wait(5))
            # Ordinary refresh remains immediately readable during a generation.
            with mock.patch.object(runtime, 'RuntimeState', return_value=self.state), mock.patch.object(runtime, 'openclaw_version', return_value='v'), mock.patch.object(runtime, 'ACPClient') as client, mock.patch.object(runtime, 'emit'):
                self.assertFalse(runtime.check_models('fixture', 'key', read_only=True))
                client.assert_not_called()
            released.set()
            for process in processes:
                process.join(8)
                self.assertEqual(process.exitcode, 0)
            self.assertEqual([result.get(timeout=2), result.get(timeout=2)], [not fail, not fail])
            self.assertEqual(count.value, 1)
        finally:
            released.set()
            for process in processes:
                if process.pid and process.is_alive(): process.terminate(); process.join(3)
            result.close()

    def test_identical_simultaneous_success_checks_generate_once(self):
        self.coalesced_check(False)

    def test_identical_simultaneous_failed_checks_generate_once(self):
        self.coalesced_check(True)

    def test_killed_leader_releases_check_lease(self):
        entered = self.mp.Event()
        process = self.mp.Process(target=abandoned_check, args=(str(self.root), entered))
        process.start()
        try:
            self.assertTrue(entered.wait(5))
        finally:
            process.terminate(); process.join(3)
        with self.state.explicit_check() as reused:
            self.assertFalse(reused)

    def test_configuration_lease_serializes_startup_and_mutation(self):
        entered, released = self.mp.Event(), self.mp.Event()
        process = self.mp.Process(target=configuration_process, args=(str(self.root), entered, released))
        process.start()
        try:
            self.assertTrue(entered.wait(5))
            import fcntl
            with (self.root / 'openclaw-configuration.lock').open('r') as lock:
                with self.assertRaises(BlockingIOError): fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            released.set(); process.join(5)
            self.assertEqual(process.exitcode, 0)
            with mock.patch.dict(os.environ, {'ORBIT_RUNTIME_STATE_DIRECTORY': str(self.root)}):
                with policy.configuration_transaction():
                    with policy.configuration_transaction(): pass  # Nested startup is safe.
        finally:
            released.set()
            if process.is_alive(): process.terminate(); process.join(3)

    def test_task_router_reads_other_process_cooldown_before_request(self):
        router = policy.AdaptiveModelRouter(lambda *args, **kwargs: None, self.state)
        self.peer.record_failure(MODEL, quota(float('inf')))
        operation = mock.Mock()
        with self.assertRaises(policy.RecoveryExhaustedError): router.execute(operation)
        operation.assert_not_called()

    def test_config_markers_are_scoped_to_configuration_path(self):
        self.state.configuration_updated()
        self.assertEqual(self.peer.configuration_version(), policy.CONFIG_VERSION)
        with mock.patch.dict(os.environ, {'OPENCLAW_CONFIG_PATH': str(self.root / 'other.json')}):
            other = policy.RuntimeState('key', 'v', self.root)
            self.assertIsNone(other.configuration_version())

    def test_persistence_contains_only_safe_machine_facts(self):
        self.state.record_failure(MODEL, quota(time.time() + 60))
        data = self.state.path.read_text()
        self.assertNotIn('not persisted', data)
        self.assertNotIn('"key"', data)
        self.assertEqual(json.loads(data)['revision'], 1)

    def test_invalidation_rejects_late_success(self):
        revision = self.state.refresh()
        self.peer.invalidate()
        self.assertFalse(self.state.verify(MODEL, revision))
        self.assertTrue(self.state.verify(MODEL, self.state.refresh()))

    def test_configuration_update_rejects_late_success(self):
        revision = self.state.refresh()
        self.peer.configuration_updated()
        self.assertFalse(self.state.verify(MODEL, revision))

    def test_configuration_child_retains_lease_if_wrapper_exits(self):
        import fcntl
        import signal
        import subprocess
        marker = self.root / 'child'
        program = "import os,pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(1)"
        process = subprocess.Popen([sys.executable, runtime.__file__, '--configuration-command', sys.executable, '-c', program, str(marker)],
            env={**os.environ, 'ORBIT_RUNTIME_STATE_DIRECTORY': str(self.root)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline: time.sleep(0.01)
            self.assertTrue(marker.exists())
            process.kill(); process.wait(timeout=3)
            with (self.root / 'openclaw-configuration.lock').open('r') as lock:
                with self.assertRaises(BlockingIOError): fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                deadline = time.monotonic() + 3
                while True:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        if time.monotonic() >= deadline: self.fail('configuration lease was not released')
                        time.sleep(0.01)
        finally:
            if process.poll() is None: process.terminate(); process.wait(timeout=3)
            if marker.exists():
                try: os.kill(int(marker.read_text()), signal.SIGTERM)
                except ProcessLookupError: pass

    def test_task_router_observes_repaired_unknown_reset(self):
        self.state.record_failure(MODEL, quota(float('inf')))
        router = policy.AdaptiveModelRouter(lambda *args, **kwargs: None, self.state)
        self.assertTrue(self.peer.verify(MODEL, self.peer.refresh()))
        operation = mock.Mock(return_value='healthy')
        self.assertEqual(router.execute(operation), 'healthy')
        operation.assert_called_once_with(MODEL)

    def test_readiness_success_cannot_override_concurrent_quota(self):
        client = mock.Mock(prompt_calls=1)
        def response(*args, **kwargs):
            self.peer.record_failure(MODEL, quota(time.time() + 60))
            return '{"status":"done","check":"TASKPILOT_READY"}'
        client.prompt.side_effect = response
        with mock.patch.object(runtime, 'prepare_runtime', return_value=self.state), mock.patch.object(runtime, 'ACPClient', return_value=client), mock.patch.object(runtime, 'emit') as events:
            self.assertFalse(runtime.check_models('fixture', 'key'))
        checks = [call.kwargs['checks'] for call in events.call_args_list if call.args[0] == 'model_checks'][-1]
        self.assertTrue(all(check['state'] == 'temporary' for check in checks))
        client.prompt.assert_called_once()

    def test_useful_task_response_does_not_publish_false_health(self):
        events = mock.Mock()
        router = policy.AdaptiveModelRouter(events, self.state)
        def response(model):
            self.peer.record_failure(MODEL, quota(time.time() + 60))
            return 'useful response'
        self.assertEqual(router.execute(response), 'useful response')
        self.assertIsNone(self.state.verified_model())
        self.assertFalse(any(call.kwargs.get('state') == 'verified' for call in events.call_args_list))

    def test_concurrent_model_migrations_run_once(self):
        barrier, writes = self.mp.Barrier(2), self.mp.Value('i', 0)
        processes = [self.mp.Process(target=synchronize_process, args=(str(self.root), barrier, writes)) for _ in range(2)]
        try:
            for process in processes: process.start()
            for process in processes:
                process.join(8)
                self.assertEqual(process.exitcode, 0)
            self.assertEqual(writes.value, 2)
            self.assertEqual(self.state.configuration_version(), policy.CONFIG_VERSION)
        finally:
            for process in processes:
                if process.is_alive(): process.terminate(); process.join(3)

    def test_failed_configuration_migration_has_no_completed_marker(self):
        import subprocess
        def command(arguments, **kwargs):
            return subprocess.CompletedProcess(arguments, 1 if arguments[1:3] == ['config', 'set'] else 0, stdout='{}')
        with mock.patch.dict(os.environ, {'ORBIT_RUNTIME_STATE_DIRECTORY': str(self.root)}), mock.patch.object(runtime.subprocess, 'run', side_effect=command):
            with self.assertRaises(RuntimeError): runtime.synchronize_model_configuration('fixture', self.state)
        self.assertIsNone(self.state.configuration_version())
