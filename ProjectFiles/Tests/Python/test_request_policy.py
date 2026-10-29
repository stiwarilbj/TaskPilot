import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import request_policy as policy
import openclaw_runtime as runtime
from evidence_fixtures import VerificationSessions


class RequestPolicyTests(unittest.TestCase):
    def router(self):
        self.now = 1000.0
        self.calls = []
        def sleep(seconds):
            self.now += seconds
        return policy.AdaptiveModelRouter(lambda *a, **k: None, clock=lambda: self.now, sleep=sleep)

    def test_runtime_state_persists_file_before_syncing_its_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            state = policy.RuntimeState('key', 'version', Path(directory))
            synced_kinds = []
            real_fsync = os.fsync

            def observe(descriptor):
                synced_kinds.append(stat.S_ISDIR(os.fstat(descriptor).st_mode))
                return real_fsync(descriptor)

            with mock.patch.object(policy.os, 'fsync', side_effect=observe):
                state.invalidate(policy.PRIMARY_MODELS[0])

            self.assertEqual(synced_kinds, [False, True])
            document = json.loads(state.path.read_text())
            self.assertEqual(document['revision'], 1)

    def test_runtime_state_persistence_failures_preserve_complete_conservative_cooldowns(self):
        model = policy.PRIMARY_MODELS[0]
        for phase in ('write', 'file_sync', 'replace', 'directory_sync'):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                state = policy.RuntimeState('key', 'version', root)
                state.record_failure(model, policy.Failure(
                    'quota', 'fixture cooldown', retry_at=10**12, scope='model'))
                previous = state.path.read_bytes()
                real_fsync = os.fsync
                fsync_calls = [0]

                def fail_dump(document, stream, *args, **kwargs):
                    stream.write('{"revision":')
                    raise OSError('injected write failure')

                def fail_sync(descriptor):
                    fsync_calls[0] += 1
                    if phase == 'file_sync' or phase == 'directory_sync' and fsync_calls[0] == 2:
                        raise OSError('injected synchronization failure')
                    return real_fsync(descriptor)

                if phase == 'write':
                    failure = mock.patch.object(policy.json, 'dump', side_effect=fail_dump)
                elif phase == 'replace':
                    failure = mock.patch.object(policy.os, 'replace', side_effect=OSError('injected replace failure'))
                else:
                    failure = mock.patch.object(policy.os, 'fsync', side_effect=fail_sync)
                with failure, self.assertRaises(OSError):
                    state.invalidate(model)

                recovered = policy.RuntimeState('key', 'version', root)
                health = recovered.health(model)
                self.assertEqual(health['state'], 'temporary')
                self.assertGreaterEqual(health['retry_at'], 10**12)
                complete = json.loads(recovered.path.read_text())
                if phase == 'directory_sync':
                    self.assertGreater(complete['revision'], json.loads(previous)['revision'])
                else:
                    self.assertEqual(recovered.path.read_bytes(), previous)

    def test_healthy_sticky_one_call_per_decision(self):
        router = self.router()
        for _ in range(3):
            router.execute(lambda model: self.calls.append(model) or 'ok')
        self.assertEqual(self.calls, [policy.PRIMARY_MODELS[0]] * 3)
        self.assertEqual(router.metrics['planning'], 3)
        self.assertEqual(router.metrics['retries'], 0)

    def test_primary_failure_secondary_success_stays_selected(self):
        router = self.router()
        def operation(model):
            self.calls.append(model)
            if model == policy.PRIMARY_MODELS[0]:
                raise RuntimeError('HTTP 503 Retry-After: 45')
            return 'ok'
        router.execute(operation)
        router.execute(operation)
        self.assertEqual(self.calls, [*policy.PRIMARY_MODELS, policy.PRIMARY_MODELS[1]])
        self.assertEqual(router.metrics['retries'], 0)

    def test_credentials_stop_without_other_requests(self):
        router = self.router()
        def operation(model):
            self.calls.append(model)
            raise RuntimeError('HTTP 401 invalid API key')
        with self.assertRaisesRegex(RuntimeError, 'invalid API key'):
            router.execute(operation)
        self.assertEqual(len(self.calls), 1)

    def test_exhausted_recovery_is_not_wrapped_in_extra_cycles(self):
        router = self.router()
        def operation(model):
            self.calls.append(model)
            raise RuntimeError('All models failed: HTTP 503 recovery exhausted')
        with self.assertRaises(RuntimeError):
            router.execute(operation)
        self.assertEqual(self.calls, list(policy.ALL_MODELS))
        self.assertEqual(router.metrics['retries'], 0)

    def test_maximum_two_shared_lite_retries_respect_cooldown(self):
        router = self.router()
        def operation(model):
            self.calls.append((model, self.now))
            raise RuntimeError('HTTP 503 Retry-After: 45')
        with self.assertRaises(RuntimeError):
            router.execute(operation)
        self.assertEqual(len(self.calls), 8)
        self.assertEqual(router.metrics['retries'], 2)
        self.assertTrue(all(at >= 1045 for _, at in self.calls[6:]))

    def test_quota_waits_until_reported_reset_without_retry(self):
        router = self.router()
        failure = policy.classify_failure(RuntimeError('daily quota exhausted resets at 1800000000'), 1000)
        self.assertEqual(failure.kind, 'quota')
        self.assertEqual(failure.retry_at, 1800000000)
        router.cooldowns[policy.PRIMARY_MODELS[0]] = failure.retry_at
        router.execute(lambda model: self.calls.append(model) or 'ok')
        self.assertEqual(self.calls, [policy.PRIMARY_MODELS[1]])

    def test_wait_events_explain_model_responses_and_classified_cooldowns(self):
        events = []
        self.now = 1000.0

        def sleep(seconds):
            self.now += seconds

        router = policy.AdaptiveModelRouter(lambda *args, **kwargs: events.append((args, kwargs)),
            clock=lambda: self.now, sleep=sleep)
        router.execute(lambda model: "ok")
        model_waits = [payload for args, payload in events if args == ("wait_phase",)]
        self.assertEqual(model_waits, [{"phase": "model_response", "waiting_for": "The model’s response"}])

        events.clear()
        def temporarily_unavailable(model):
            raise RuntimeError("HTTP 503 Retry-After: 1")
        router.active_model = None
        with self.assertRaises(RuntimeError):
            router.execute(temporarily_unavailable)
        cooldowns = [payload for args, payload in events if args == ("wait_phase",)]
        cooldown = next(payload for payload in cooldowns if payload["phase"] == "provider_cooldown")
        self.assertEqual(cooldown["waiting_for"], "The selected model’s capacity cooldown")

    def test_unavailable_model_skipped_for_rest_of_task(self):
        router = self.router()
        def operation(model):
            self.calls.append(model)
            if model == policy.PRIMARY_MODELS[0]:
                raise RuntimeError('unknown model')
            return 'ok'
        router.execute(operation)
        router.active_model = None
        router.execute(operation)
        self.assertEqual(self.calls.count(policy.PRIMARY_MODELS[0]), 1)

    def test_cache_expires_and_is_keyed_by_credentials_version(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(policy.time, 'time', return_value=1000):
            root = Path(directory)
            state = policy.RuntimeState('fingerprint', 'v1', root)
            state.verify(policy.PRIMARY_MODELS[0], now=1000, monotonic_now=100, boot_session='boot-a')
            self.assertEqual(state.verified_model(now=1000, monotonic_now=100, boot_session='boot-a'),
                             policy.PRIMARY_MODELS[0])
            self.assertIsNone(policy.RuntimeState('changed', 'v1', root).verified_model())
            self.assertIsNone(policy.RuntimeState('fingerprint', 'v2', root).verified_model())
            with mock.patch.object(policy.time, 'time', return_value=1600):
                self.assertIsNone(state.verified_model(now=1600, monotonic_now=700, boot_session='boot-a'))
            state.record_failure(policy.PRIMARY_MODELS[0], policy.Failure('temporary', 'overloaded', 1100))
            self.assertIsNone(state.verified_model())
            self.assertEqual(policy.RuntimeState('fingerprint', 'v1', root).health(policy.PRIMARY_MODELS[0])['state'], 'temporary')
            self.assertEqual(state.path.stat().st_mode & 0o777, 0o600)

    def test_readiness_success_cache_uses_monotonic_age_and_rejects_reboot_or_uncertain_clock(self):
        model = policy.PRIMARY_MODELS[0]
        with tempfile.TemporaryDirectory() as directory:
            state = policy.RuntimeState('fingerprint', 'v1', Path(directory))
            state.verify(model, now=10_000, monotonic_now=100, boot_session='boot-a')

            # Large forward and backward wall-clock corrections do not alter
            # the ten-minute age while the boot marker and monotonic clock agree.
            self.assertEqual(state.verified_model(now=99_000, monotonic_now=110, boot_session='boot-a'), model)
            self.assertEqual(state.verified_model(now=1_000, monotonic_now=110, boot_session='boot-a'), model)

            # Monotonic expiry, a reboot, or a monotonic regression all require
            # a fresh readiness check even when wall time appears recent.
            self.assertIsNone(state.verified_model(now=10_010, monotonic_now=700, boot_session='boot-a'))
            self.assertIsNone(state.verified_model(now=10_010, monotonic_now=101, boot_session='boot-b'))
            self.assertIsNone(state.verified_model(now=10_010, monotonic_now=99, boot_session='boot-a'))

            record = json.loads(state.path.read_text())['credentials'][state.credential]['records'][state.identity]
            self.assertEqual(record['verified'][model], 10_000)
            self.assertEqual(record['verification_clocks'][model], {
                'version': policy.VERIFICATION_CLOCK_VERSION, 'boot_session': 'boot-a',
                'wall': 10_000, 'monotonic': 100,
            })

    def test_readiness_clock_correction_cannot_authorize_a_stale_cached_check(self):
        model = policy.PRIMARY_MODELS[0]
        with tempfile.TemporaryDirectory() as directory:
            state = policy.RuntimeState('fingerprint', 'v1', Path(directory))
            state.verify(model, now=10_000, monotonic_now=100, boot_session='boot-a')
            with mock.patch.object(policy, '_boot_session_marker', return_value='boot-a'), \
                 mock.patch.object(policy.time, 'time', return_value=99_000), \
                 mock.patch.object(policy.time, 'monotonic', return_value=110), \
                 mock.patch.object(runtime, 'emit'):
                self.assertTrue(runtime._perform_model_check('fixture', state, read_only=True))

            # A wall-clock jump alone cannot make a 10-second success stale.
            # A genuinely old monotonic success is not accepted as verified.
            with mock.patch.object(policy, '_boot_session_marker', return_value='boot-a'), \
                 mock.patch.object(policy.time, 'time', return_value=10_010), \
                 mock.patch.object(policy.time, 'monotonic', return_value=700), \
                 mock.patch.object(runtime, 'emit'), mock.patch.object(runtime, 'ACPClient') as client:
                self.assertFalse(runtime._perform_model_check('fixture', state, read_only=True))
                client.assert_not_called()

            with mock.patch.object(policy, '_boot_session_marker', return_value='boot-b'), \
                 mock.patch.object(policy.time, 'time', return_value=10_010), \
                 mock.patch.object(policy.time, 'monotonic', return_value=101), \
                 mock.patch.object(runtime, 'emit'), mock.patch.object(runtime, 'ACPClient') as client:
                self.assertFalse(runtime._perform_model_check('fixture', state, read_only=True))
                client.assert_not_called()

    def test_legacy_or_malformed_verification_clock_never_authorizes_cache_hit(self):
        model = policy.PRIMARY_MODELS[0]
        with tempfile.TemporaryDirectory() as directory:
            state = policy.RuntimeState('fingerprint', 'v1', Path(directory))
            with state.transaction(write=True) as (_document, _bucket, record):
                record['verified'][model] = 10_000
            self.assertIsNone(state.verified_model(now=10_001, monotonic_now=101, boot_session='boot-a'))

            state.verify(model, now=10_001, monotonic_now=101, boot_session='boot-a')
            with state.transaction(write=True) as (_document, _bucket, record):
                record['verification_clocks'][model]['monotonic'] = 'invalid'
            self.assertIsNone(state.verified_model(now=10_002, monotonic_now=102, boot_session='boot-a'))

            state.verify(model, now=10_003, monotonic_now=103, boot_session='boot-a')
            state.invalidate(model)
            record = json.loads(state.path.read_text())['credentials'][state.credential]['records'][state.identity]
            self.assertNotIn(model, record['verified'])
            self.assertNotIn('verification_clocks', record)

    def test_pruning_uses_monotonic_expiry_despite_wall_clock_jumps(self):
        model = policy.PRIMARY_MODELS[0]
        old_identity = 'b' * 64
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(policy, '_rollback_readiness_protection', return_value=(set(), set(), set(), False)), \
             mock.patch.object(policy, '_any_active_check_lease', return_value=False), \
             mock.patch.object(policy, '_check_lease_state', return_value=False):
            root = Path(directory)
            state = policy.RuntimeState('fingerprint', 'v1', root)
            old_record = {
                'verified': {model: 10_000},
                'verification_clocks': {model: {
                    'version': policy.VERIFICATION_CLOCK_VERSION,
                    'boot_session': 'boot-a', 'wall': 10_000, 'monotonic': 100,
                }},
            }
            document = {'revision': 0, 'credentials': {state.credential: {
                'records': {old_identity: old_record}, 'health': {}, 'credential_health': {},
            }}}
            state.path.write_text(json.dumps(document)); state.path.chmod(0o600)

            with mock.patch.object(policy, '_boot_session_marker', return_value='boot-a'), \
                 mock.patch.object(policy.time, 'time', return_value=99_000), \
                 mock.patch.object(policy.time, 'monotonic', return_value=110):
                state.finish_check(True)
                retained = json.loads(state.path.read_text())['credentials'][state.credential]['records']
                self.assertIn(old_identity, retained)

            with mock.patch.object(policy, '_boot_session_marker', return_value='boot-a'), \
                 mock.patch.object(policy.time, 'time', return_value=10_600), \
                 mock.patch.object(policy.time, 'monotonic', return_value=700):
                state.finish_check(True)
                pruned = json.loads(state.path.read_text())['credentials'][state.credential]['records']
                self.assertNotIn(old_identity, pruned)

            state.verify(model, now=10_004, monotonic_now=104, boot_session='boot-a')
            state.record_failure(model, policy.Failure('temporary', 'fixture', retry_at=20_000))
            record = json.loads(state.path.read_text())['credentials'][state.credential]['records'][state.identity]
            self.assertNotIn(model, record['verified'])
            self.assertNotIn('verification_clocks', record)

    def test_readiness_pruning_is_bounded_and_preserves_current_rollback_and_cooldowns(self):
        now = 50_000.0
        model = policy.PRIMARY_MODELS[0]
        old_id, rollback_id, active_id, invalidated_id = (letter * 64 for letter in "abcd")
        old_credential = "e" * 64
        current_managed = "f" * 64
        rollback_managed = "1" * 64
        obsolete_managed = "2" * 64
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.dict(os.environ, {"TASKPILOT_MANAGED_FINGERPRINT": "current:install:config"}), \
             mock.patch.object(policy.time, "time", return_value=now):
            root = Path(directory)
            state = policy.RuntimeState("key", "version", root)
            current_managed = __import__("hashlib").sha256(state.managed_configuration.encode()).hexdigest()
            active_lock = root / ("readiness-" + active_id + ".lock")
            obsolete_bucket = {
                "records": {"e" * 64: {"verified": {model: now - 601}}},
                "health": {"google/old-model": {"state": "temporary", "retry_at": now + 300, "revision": 9}},
                "credential_health": {"google": {"state": "temporary", "retry_at": None,
                                                     "failure_kind": "quota", "revision": 8}},
            }
            current_verification_clock = {
                "version": policy.VERIFICATION_CLOCK_VERSION,
                "boot_session": policy._boot_session_marker(),
                "wall": now - 20,
                "monotonic": policy.time.monotonic(),
            }
            bucket = {
                "records": {
                    state.identity: {"verified": {model: now - 20},
                                     "verification_clocks": {model: current_verification_clock}},
                    old_id: {"verified": {model: now - 601}},
                    rollback_id: {"verified": {model: now - 601}},
                    active_id: {"verified": {model: now - 601}},
                    invalidated_id: {"verified": {model: now - 601}, "invalidations": {"*": 4},
                                     "check_revision": 3, "check_success": False},
                },
                "health": {},
                "credential_health": {},
                "managed_health": {
                    current_managed: {"google/other-model": {"state": "repair", "revision": 7}},
                    rollback_managed: {model: {"state": "repair", "revision": 6}},
                    obsolete_managed: {model: {"state": "temporary", "retry_at": now - 1, "revision": 2}},
                },
            }
            document = {"revision": 3, "credentials": {state.credential: bucket, old_credential: obsolete_bucket}}
            state.path.write_text(json.dumps(document))
            state.path.chmod(0o600)
            before_size = state.path.stat().st_size

            rollback_context = mock.patch.object(policy, "_rollback_readiness_protection",
                return_value=({old_credential}, {rollback_id}, {rollback_managed}, False))
            with rollback_context:
                with policy.private_lock(active_lock, category=policy.LockCategory.SINGLE_FLIGHT):
                    state.finish_check(True)
                first = json.loads(state.path.read_text())
                self.assertNotIn(old_id, first["credentials"][state.credential]["records"])
                self.assertIn(rollback_id, first["credentials"][state.credential]["records"])
                self.assertIn(active_id, first["credentials"][state.credential]["records"])
                invalidated = first["credentials"][state.credential]["records"][invalidated_id]
                self.assertNotIn("verified", invalidated)
                self.assertEqual(invalidated["invalidations"], {"*": 4})
                self.assertEqual(invalidated["check_revision"], 3)
                self.assertIn(obsolete_managed, first["credentials"][state.credential]["managed_health"])
                self.assertEqual(first["credentials"][old_credential]["credential_health"]["google"]["retry_at"], None)
                self.assertEqual(first["credentials"][old_credential]["health"]["google/old-model"]["retry_at"], now + 300)
                self.assertGreater(before_size, state.path.stat().st_size)
                self.assertEqual(first["credentials"][state.credential]["records"][state.identity]["verified"][model], now - 20)
                with mock.patch.object(runtime, "RuntimeState", return_value=state), \
                     mock.patch.object(runtime, "openclaw_version", return_value="version"), \
                     mock.patch.object(runtime, "ACPClient") as client, mock.patch.object(runtime, "emit"):
                    self.assertTrue(runtime.check_models("fixture", "key", read_only=True))
                    client.assert_not_called()

                # An applicable indefinite account cooldown is still retained
                # and prevents a read-only check from attempting a provider call.
                first["credentials"][state.credential]["credential_health"]["google"] = {
                    "state": "temporary", "retry_at": None, "failure_kind": "quota",
                    "failure_scope": "credential", "revision": 5,
                }
                state.path.write_text(json.dumps(first)); state.path.chmod(0o600)
                state.finish_check(True)
                self.assertIsNone(state.verified_model())
                self.assertIsNone(state.credential_health(model)["retry_at"])
                with mock.patch.object(runtime, "RuntimeState", return_value=state), \
                     mock.patch.object(runtime, "openclaw_version", return_value="version"), \
                     mock.patch.object(runtime, "ACPClient") as client, mock.patch.object(runtime, "emit"):
                    self.assertFalse(runtime.check_models("fixture", "key", read_only=True))
                    client.assert_not_called()

                # Once the active check lease is gone, a later existing write can
                # reclaim its expired verification and the obsolete health entry.
                state.finish_check(True)
                second = json.loads(state.path.read_text())
                self.assertNotIn(active_id, second["credentials"][state.credential]["records"])
                self.assertNotIn(obsolete_managed, second["credentials"][state.credential]["managed_health"])
                self.assertIn(rollback_managed, second["credentials"][state.credential]["managed_health"])
                self.assertEqual(second["credentials"][state.credential]["credential_health"]["google"]["retry_at"], None)
                self.assertEqual(second["credentials"][old_credential]["credential_health"]["google"]["retry_at"], None)

    def test_readiness_pruning_retains_every_namespace_when_rollback_identity_is_uncertain(self):
        now = 60_000.0
        model = policy.PRIMARY_MODELS[0]
        old_id = "a" * 64
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(policy.time, "time", return_value=now):
            root = Path(directory)
            state = policy.RuntimeState("key", "version", root)
            record = {"verified": {model: now - 1000}}
            document = {"revision": 0, "credentials": {state.credential: {
                "records": {state.identity: {"verified": {model: now - 10}}, old_id: record},
                "health": {}, "credential_health": {}, "managed_health": {"3" * 64: {model: {"state": "temporary", "retry_at": now - 1}}},
            }}}
            state.path.write_text(json.dumps(document)); state.path.chmod(0o600)
            with mock.patch.object(policy, "_rollback_readiness_protection", return_value=(set(), set(), set(), True)):
                state.finish_check(True)
            recovered = json.loads(state.path.read_text())["credentials"][state.credential]
            self.assertEqual(recovered["records"][old_id], record)
            self.assertIn("3" * 64, recovered["managed_health"])

    def test_readiness_pruning_visits_only_a_bounded_rotating_slice(self):
        now = 70_000.0
        model = policy.PRIMARY_MODELS[0]
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(policy.time, "time", return_value=now), \
             mock.patch.object(policy, "_check_lease_state", return_value=False), \
             mock.patch.object(policy, "_any_active_check_lease", return_value=False), \
             mock.patch.object(policy, "_rollback_readiness_protection", return_value=(set(), set(), set(), False)):
            root = Path(directory)
            state = policy.RuntimeState("key", "version", root)
            records = {f"{index + 1000:064x}": {"verified": {model: now - 601}} for index in range(200)}
            records[state.identity] = {
                "verified": {model: now - 10},
                "verification_clocks": {model: {
                    "version": policy.VERIFICATION_CLOCK_VERSION,
                    "boot_session": policy._boot_session_marker(),
                    "wall": now - 10,
                    "monotonic": policy.time.monotonic(),
                }},
            }
            document = {"revision": 0, "credentials": {state.credential: {
                "records": records, "health": {}, "credential_health": {}, "managed_health": {},
            }}}
            state.path.write_text(json.dumps(document)); state.path.chmod(0o600)

            state.finish_check(True)
            first = json.loads(state.path.read_text())
            remaining = first["credentials"][state.credential]["records"]
            self.assertEqual(sum(key != state.identity for key in remaining), 200 - policy.READINESS_PRUNE_MAX_IDENTITIES)

            state.finish_check(True)
            second = json.loads(state.path.read_text())
            remaining = second["credentials"][state.credential]["records"]
            self.assertEqual(set(remaining), {state.identity})
            self.assertEqual(state.verified_model(), model)

    def test_readiness_pruning_rotates_across_credential_namespaces(self):
        import hashlib
        now = 80_000.0
        model = policy.PRIMARY_MODELS[0]
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(policy.time, "time", return_value=now), \
             mock.patch.object(policy, "_check_lease_state", return_value=False), \
             mock.patch.object(policy, "_any_active_check_lease", return_value=False):
            root = Path(directory)
            state = policy.RuntimeState("key", "version", root)
            credentials = {}
            credential_order = []
            for index in range(130):
                credential = hashlib.sha256(f"obsolete-credential-{index}".encode()).hexdigest()
                credential_order.append(credential)
                records = {}
                for number in range(2):
                    identity = hashlib.sha256(f"obsolete-runtime-{index}-{number}".encode()).hexdigest()
                    records[identity] = {"verified": {model: now - 601}}
                credentials[credential] = {
                    "records": records, "health": {},
                    "credential_health": {"google": {"state": "temporary", "retry_at": None,
                                                         "failure_kind": "quota", "revision": index}},
                }
            credentials[state.credential] = {"records": {state.identity: {"verified": {model: now - 10}}},
                                             "health": {}, "credential_health": {}}
            document = {"revision": 0, "credentials": credentials}
            state.path.write_text(json.dumps(document)); state.path.chmod(0o600)

            state.finish_check(True)
            first = json.loads(state.path.read_text())
            remaining_first = sum(len(value.get("records", {})) for key, value in first["credentials"].items()
                                  if key != state.credential)
            self.assertEqual(remaining_first, 260 - policy.READINESS_PRUNE_MAX_IDENTITIES)
            first_keys = list(first["credentials"])
            self.assertEqual(first_keys[0], credential_order[policy.READINESS_PRUNE_MAX_CREDENTIALS])
            self.assertEqual(first_keys[-1], credential_order[policy.READINESS_PRUNE_MAX_CREDENTIALS - 1])

            state.finish_check(True)
            second = json.loads(state.path.read_text())
            remaining_second = sum(len(value.get("records", {})) for key, value in second["credentials"].items()
                                   if key != state.credential)
            self.assertLess(remaining_second, remaining_first)
            for bucket in second["credentials"].values():
                if bucket.get("credential_health"):
                    self.assertIsNone(bucket["credential_health"]["google"]["retry_at"])

    def test_readiness_pruning_rotates_past_live_records_and_unexpired_health(self):
        now = 85_000.0
        model = policy.PRIMARY_MODELS[0]
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(policy.time, "time", return_value=now), \
             mock.patch.object(policy, "_any_active_check_lease", return_value=False), \
             mock.patch.object(policy, "_rollback_readiness_protection", return_value=(set(), set(), set(), False)):
            root = Path(directory)
            state = policy.RuntimeState("key", "version", root)
            live_order = [f"{index + 5000:064x}" for index in range(policy.READINESS_PRUNE_MAX_IDENTITIES)]
            expired_order = [f"{index + 6000:064x}" for index in range(policy.READINESS_PRUNE_MAX_IDENTITIES)]
            live_ids = set(live_order)
            expired_ids = set(expired_order)
            records = {identity: {"verified": {model: now - 601}}
                       for identity in live_order + expired_order}
            records[state.identity] = {"verified": {model: now - 10}}
            health = {f"google/model-{index}": {"state": "temporary", "retry_at": now + 100}
                      for index in range(policy.READINESS_PRUNE_MAX_HEALTH_RECORDS)}
            health["google/expired"] = {"state": "temporary", "retry_at": now - 1}
            managed_health = {
                f"{index + 1:064x}": {model: {"state": "temporary", "retry_at": now + 100}}
                for index in range(policy.READINESS_PRUNE_MAX_HEALTH_RECORDS)
            }
            managed_health[f"{policy.READINESS_PRUNE_MAX_HEALTH_RECORDS + 1:064x}"] = {
                model: {"state": "temporary", "retry_at": now - 1}
            }
            state.path.write_text(json.dumps({"revision": 0, "credentials": {state.credential: {
                "records": records, "health": health, "managed_health": managed_health,
                "credential_health": {},
            }}})); state.path.chmod(0o600)

            with mock.patch.object(policy, "_check_lease_state", side_effect=lambda _root, identity: identity in live_ids):
                state.finish_check(True)
                first = json.loads(state.path.read_text())["credentials"][state.credential]
                self.assertEqual(first["records"][live_order[0]]["verified"][model], now - 601)
                self.assertIn("google/expired", first["health"])
                self.assertIn(f"{policy.READINESS_PRUNE_MAX_HEALTH_RECORDS + 1:064x}", first["managed_health"])

                state.finish_check(True)
                second = json.loads(state.path.read_text())["credentials"][state.credential]
                self.assertTrue(expired_ids.isdisjoint(second["records"]))
                self.assertNotIn("google/expired", second["health"])
                self.assertNotIn(f"{policy.READINESS_PRUNE_MAX_HEALTH_RECORDS + 1:064x}", second["managed_health"])
                self.assertTrue(live_ids.issubset(second["records"]))

    def test_pruning_expiry_checks_retain_ambiguous_values(self):
        now = 90_000.0
        for value in (True, "old", now + 1, 10 ** 10000):
            self.assertFalse(policy._expired_verification(value, now))
        self.assertFalse(policy._expired_verification(now - 601, float("inf")))
        for failure in (
            {"state": "repair", "retry_at": now - 1},
            {"state": "temporary", "retry_at": None},
            {"state": "temporary", "retry_at": "expired"},
            {"state": "temporary", "retry_at": 10 ** 10000},
        ):
            self.assertFalse(policy._expired_temporary_failure(failure, now))

    def test_rollback_readiness_protection_uses_only_validated_private_metadata(self):
        import hashlib
        import uuid
        with tempfile.TemporaryDirectory() as directory:
            support = Path(directory)
            managed_root = support / "ManagedOpenClaw"
            instance = str(uuid.uuid4())
            state_path = managed_root / "instances" / instance
            state_path.mkdir(parents=True, mode=0o700)
            (managed_root / "installations" / "pkg" / "node" / "bin").mkdir(parents=True)
            (managed_root / "installations" / "pkg" / "package" / "node_modules" / "openclaw").mkdir(parents=True)
            (state_path / "workspace").mkdir()
            (state_path / "credential-fingerprint.json").write_text(json.dumps({"fingerprint": "a" * 64}))
            defaults = {"model": {"primary": "google/model"}, "modelPolicy": [], "imageModel": None, "models": {}}
            (state_path / "openclaw.json").write_text(json.dumps({"agents": {"defaults": defaults}}))
            descriptor = {
                "version": 1, "instance_id": instance, "installation_fingerprint": "install-fingerprint",
                "configuration_fingerprint": "configuration-fingerprint", "openclaw_version": "2026.9.5",
                "node_version": "24.22.1", "node": str(managed_root / "installations" / "pkg" / "node" / "bin" / "node"),
                "entry": str(managed_root / "installations" / "pkg" / "package" / "node_modules" / "openclaw" / "openclaw.mjs"),
                "executable": str(state_path / "openclaw"), "state": str(state_path),
                "config": str(state_path / "openclaw.json"), "workspace": str(state_path / "workspace"),
                "token_file": str(state_path / "gateway-token"), "port": 12345, "endpoint": "ws://127.0.0.1:12345",
            }
            previous = managed_root / "previous-runtime.json"
            previous.write_text(json.dumps(descriptor)); previous.chmod(0o600)

            cache = {}
            protection = policy._rollback_readiness_protection(support, cache)
            import private_runtime_metadata
            with mock.patch.object(private_runtime_metadata, "read_bytes", side_effect=AssertionError("cache missed")):
                self.assertEqual(policy._rollback_readiness_protection(support, cache), protection)
            credentials, records, managed, uncertain = protection
            self.assertFalse(uncertain)
            self.assertEqual(credentials, {hashlib.sha256(("a" * 64).encode()).hexdigest()})
            self.assertEqual(managed, {hashlib.sha256((instance + ":install-fingerprint:configuration-fingerprint").encode()).hexdigest()})
            config_fingerprint = hashlib.sha256(json.dumps(defaults, sort_keys=True).encode()).hexdigest()
            source = "a" * 64
            expected_identity = hashlib.sha256(json.dumps([
                source, "OpenClaw 2026.9.5", policy.CONFIG_VERSION, policy.ALL_MODELS,
                config_fingerprint, runtime.VALIDATION_VERSION, runtime.CONTRACT_HASH,
                policy.ERROR_POLICY_VERSION, instance + ":install-fingerprint:configuration-fingerprint",
            ]).encode()).hexdigest()
            self.assertEqual(records, {expected_identity})

    def test_credential_error_invalidates_all_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            state = policy.RuntimeState('key', 'version', Path(directory))
            for model in policy.PRIMARY_MODELS:
                state.verify(model)
            state.record_failure(policy.PRIMARY_MODELS[0], policy.Failure('credentials', 'invalid key'))
            self.assertIsNone(state.verified_model())

    def test_real_path_check_stops_after_one_image_json_request(self):
        with tempfile.TemporaryDirectory() as directory:
            state = policy.RuntimeState('key', 'version', Path(directory))
            client = mock.Mock(prompt_calls=1)
            client.prompt.return_value = '{"status":"done","check":"TASKPILOT_READY"}'
            with mock.patch.object(runtime, 'prepare_runtime', return_value=state), mock.patch.object(runtime, 'ACPClient', return_value=client), mock.patch.object(runtime, 'emit'):
                self.assertTrue(runtime.check_models('openclaw', 'key'))
            client.prompt.assert_called_once()
            client.select_model.assert_called_once_with(policy.PRIMARY_MODELS[0])
            client.close.assert_called_once()

    def test_readiness_refresh_never_constructs_acp_or_generates(self):
        with tempfile.TemporaryDirectory() as directory:
            state = policy.RuntimeState('key', 'version', Path(directory))
            with mock.patch.object(runtime, 'RuntimeState', return_value=state), mock.patch.object(runtime, 'openclaw_version', return_value='version'), mock.patch.object(runtime, 'ACPClient') as client, mock.patch.object(runtime, 'emit'):
                self.assertFalse(runtime.check_models('openclaw', 'key', read_only=True))
                state.verify(policy.PRIMARY_MODELS[0])
                self.assertTrue(runtime.check_models('openclaw', 'key', read_only=True))
            client.assert_not_called()

    def test_same_input_reuse_excludes_mutating_actions(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image.png'
            image.write_bytes(b'image')
            class Client(VerificationSessions):
                model_switches = 0
                def select_model(self, model): self.selected_model = model
                prompt = mock.Mock(return_value='{"status":"act","action":{"type":"wait"}}')
            client = Client()
            router = self.router()
            with mock.patch.object(runtime, 'emit'):
                runtime.routed_json_prompt(router, client, 'unchanged instruction and history', image)
                runtime.routed_json_prompt(router, client, 'unchanged instruction and history', image)
                self.assertEqual(client.prompt.call_count, 1)
                runtime.routed_json_prompt(router, client, 'new evidence', image)
                self.assertEqual(client.prompt.call_count, 2)
                client.decision_cache = {}
                client.prompt.return_value = '{"status":"act","action":{"type":"click","x":1,"y":2,"pid":42}}'
                for _ in range(2):
                    runtime.routed_json_prompt(router, client, 'mutation', image)
                self.assertEqual(client.prompt.call_count, 4)

    def test_reconnect_once_replays_only_reasoning(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image.png'; image.write_bytes(b'image')
            class Client(VerificationSessions):
                model_switches = 0
                reconnects = 0
                def select_model(self, model): self.selected_model = model
                def reconnect(self): self.reconnects += 1
                prompt = mock.Mock(side_effect=[RuntimeError('OpenClaw ACP exited'), '{"status":"done"}'])
            client = Client(); router = self.router()
            with mock.patch.object(runtime, 'emit'), mock.patch.object(runtime, 'bridge_call') as bridge:
                self.assertEqual(runtime.routed_json_prompt(router, client, 'reason', image)['status'], 'done')
                bridge.assert_not_called()
            self.assertEqual(client.reconnects, 1)
            self.assertEqual(client.prompt.call_count, 2)

    def test_malformed_output_repairs_before_switching(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image.png'; image.write_bytes(b'image')
            class Client(VerificationSessions):
                model_switches = 0
                def select_model(self, model): self.selected_model = model
                prompt = mock.Mock(side_effect=['partial {', '{"status":"done"}'])
            with mock.patch.object(runtime, 'emit'):
                self.assertEqual(runtime.routed_json_prompt(self.router(), Client(), 'reason', image)['status'], 'done')

    def test_stale_transcript_error_is_not_recovered(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); transcript = root / 'session.jsonl'
            transcript.write_text(json.dumps({'message': {'role':'assistant','stopReason':'error','errorMessage':'old invalid API key'}})+'\n')
            (root/'sessions.json').write_text(json.dumps({'agent:main:acp:session': {'sessionFile':str(transcript)}}))
            cursor = runtime.session_transcript_cursor('session', root)
            self.assertIsNotNone(cursor)
            self.assertEqual(runtime.openclaw_session_error('session', root, cursor), '')
            with transcript.open('a') as handle:
                handle.write(json.dumps({'message': {'role':'assistant','stopReason':'error','errorMessage':'new HTTP 503'}})+'\n')
            self.assertEqual(runtime.openclaw_session_error('session', root, cursor), 'new HTTP 503')

    def test_foreign_session_output_and_errors_rejected(self):
        client = runtime.ACPClient.__new__(runtime.ACPClient)
        client.session_id = 'current'; client.agent_chunks = []; client.turn_errors = []
        for update in [{'sessionUpdate':'agent_message_chunk','content':{'text':'stale'}}, {'sessionUpdate':'error','message':'stale failure'}]:
            client._handle_server_message({'method':'session/update','params':{'sessionId':'earlier','update':update}})
        self.assertEqual(client.agent_chunks, [])
        self.assertEqual(client.turn_errors, [])

    def test_configuration_migration_preserves_unrelated_settings_and_runs_once(self):
        with tempfile.TemporaryDirectory() as directory:
            state = policy.RuntimeState('key', 'version', Path(directory))
            values = {
                'agents.defaults.modelPolicy.allow': ['google/gemini-3.5-flash', 'google/gemini-3.6-flash', 'google/gemini-3.7-flash', 'other/custom'],
                'agents.defaults.model': {'primary':'google/gemini-3.7-flash', 'fallbacks':['google/gemini-3.6-flash','other/custom'], 'extra':'retained'},
                'agents.defaults.imageModel': {'primary':'google/gemini-3.5-flash', 'fallbacks':['google/gemini-3.7-flash','other/custom']},
                'agents.defaults.models': {'google/gemini-3.5-flash': {}, 'other/custom': {'alias':'custom'}},
            }
            writes = []
            def run(arguments, **kwargs):
                if arguments[2] == 'get':
                    return mock.Mock(returncode=0, stdout=json.dumps(values[arguments[3]]))
                writes.append((arguments[3],json.loads(arguments[4])))
                return mock.Mock(returncode=0)
            with mock.patch.object(runtime.subprocess, 'run', side_effect=run):
                runtime.synchronize_model_configuration('openclaw', state)
                count = len(writes)
                runtime.synchronize_model_configuration('openclaw', state)
                self.assertEqual(len(writes), count)
            settings = dict(writes)
            self.assertEqual(settings['agents.defaults.model']['primary'], policy.PRIMARY_MODELS[0])
            self.assertEqual(settings['agents.defaults.model']['extra'], 'retained')
            self.assertIn('other/custom', settings['agents.defaults.modelPolicy.allow'])
            self.assertEqual(settings['agents.defaults.models'], {'other/custom':{'alias':'custom'}})
            self.assertFalse(any('gemini-3.5-flash"' in json.dumps(value) or 'gemini-3.6-flash"' in json.dumps(value) or 'gemini-3.7-flash"' in json.dumps(value) for _, value in writes))
            self.assertTrue(all(setting.startswith('agents.defaults.') for setting, _ in writes))

    def test_bridge_model_control_requires_acknowledgement_and_no_prompt(self):
        client = runtime.ACPClient.__new__(runtime.ACPClient)
        client.selected_model = None; client.config_options = []; client.session_key = 'unique'; client.model_switches = 0
        client.gateway_configuration = mock.Mock(return_value={'ok':True,'resolved':{'modelProvider':'google','model':'gemini-3.5-flash-lite'}})
        client.prompt = mock.Mock()
        client.select_model(policy.PRIMARY_MODELS[0])
        client.select_model(policy.PRIMARY_MODELS[0])
        self.assertEqual(client.model_switches, 1)
        client.gateway_configuration.assert_called_once_with('sessions.patch', {'key':'unique','model':policy.PRIMARY_MODELS[0]})
        client.prompt.assert_not_called()
        client.gateway_configuration.return_value = {'ok':True,'resolved':{'modelProvider':'google','model':'wrong'}}
        with self.assertRaisesRegex(RuntimeError, 'not acknowledged'):
            client.select_model(policy.PRIMARY_MODELS[1])

    def test_configuration_changes_invalidate_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = policy.RuntimeState('key', 'version', root, configuration='original')
            state.verify(policy.PRIMARY_MODELS[0])
            self.assertIsNone(policy.RuntimeState('key', 'version', root, configuration='changed').verified_model())

    def test_cancellation_stops_without_retry(self):
        router = self.router()
        operation = mock.Mock(side_effect=RuntimeError('OpenClaw cancelled the TaskPilot turn'))
        with self.assertRaises(RuntimeError):
            router.execute(operation)
        operation.assert_called_once()
        self.assertEqual(router.metrics['retries'], 0)

    def test_cached_cooldown_skips_primary_without_an_extra_call(self):
        with tempfile.TemporaryDirectory() as directory:
            state = policy.RuntimeState('key', 'version', Path(directory))
            state.record_failure(policy.PRIMARY_MODELS[0], policy.Failure('temporary', '503', policy.time.time()+60))
            router = policy.AdaptiveModelRouter(lambda *a, **k: None, state)
            calls = []
            router.execute(lambda model: calls.append(model) or 'ok')
            self.assertEqual(calls, [policy.PRIMARY_MODELS[1]])

    def test_quota_recovery_waits_for_reset_before_retrying(self):
        router = self.router()
        def operation(model):
            self.calls.append((model, self.now))
            if model == policy.PRIMARY_MODELS[0]:
                if self.now < 1800000000:
                    raise RuntimeError('daily quota exhausted resets at 1800000000')
                return 'ok'
            raise RuntimeError('unknown model')
        self.assertEqual(router.execute(operation), 'ok')
        self.assertEqual(len(self.calls), 7)
        self.assertEqual(self.calls[-1], (policy.PRIMARY_MODELS[0], 1800000000))

    def test_reconnect_waits_for_gateway_terminal_acknowledgement(self):
        client = runtime.ACPClient.__new__(runtime.ACPClient)
        client.reconnects = 0; client.prompt_calls = 1; client.model_switches = 1
        client.session_key = 'old'; client.openclaw_path = 'openclaw'
        events = []
        client.close = lambda: events.append('old child ended')
        client.gateway_configuration = lambda method, params: events.append((method,params)) or {'ok':True,'status':'no-active-run'}
        with mock.patch.object(runtime.ACPClient, '__init__', side_effect=lambda path: events.append('new client')):
            client.reconnect()
        self.assertEqual(events, ['old child ended', ('sessions.abort', {'key':'old'}), 'new client'])
        self.assertEqual(client.reconnects, 1)
        with mock.patch.object(runtime.ACPClient, '__init__'):
            client.reconnect(); client.reconnect()
            with self.assertRaisesRegex(RuntimeError, 'reconnect budget exhausted'):
                client.reconnect()

    def test_reconnect_does_not_replay_without_terminal_acknowledgement(self):
        client = runtime.ACPClient.__new__(runtime.ACPClient)
        client.reconnects = 0; client.prompt_calls = 1; client.model_switches = 1
        client.session_key = 'old'; client.openclaw_path = 'openclaw'
        client.close = mock.Mock()
        client.gateway_configuration = mock.Mock(return_value={'ok':True,'status':'pending'})
        with mock.patch.object(runtime.ACPClient, '__init__') as initialize:
            with self.assertRaisesRegex(RuntimeError, 'confirm the previous'):
                client.reconnect()
            initialize.assert_not_called()

    def test_queued_previous_turn_stream_is_drained(self):
        import queue
        client = runtime.ACPClient.__new__(runtime.ACPClient)
        client.session_id = 'session'; client.transport = runtime.ACPTransport()
        client.agent_chunks = []; client.turn_errors = []
        for update in [{'sessionUpdate':'error','message':'old error'}, {'sessionUpdate':'agent_message_chunk','content':{'text':'old output'}}]:
            client.transport.route({'method':'session/update','params':{'sessionId':'session','update':update}})
        def request(*args, **kwargs):
            client._handle_server_message({'method':'session/update','params':{'sessionId':'session','update':{'sessionUpdate':'agent_message_chunk','content':{'text':'{"status":"done"}'}}}})
            return {'stopReason':'end_turn'}
        client.request = request
        with mock.patch.object(runtime, 'session_transcript_cursor', return_value=None):
            self.assertEqual(client._run_prompt([], None)[1], '{"status":"done"}')
        self.assertEqual(client.turn_errors, [])

    def test_string_false_does_not_pass_visual_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image.png'; image.write_bytes(b'image')
            class Client(VerificationSessions):
                model_switches = 0
                def select_model(self, model): self.selected_model = model
                prompt = mock.Mock(side_effect=['{"verified":"false"}', '{"verified":false}'])
            with mock.patch.object(runtime, 'emit'):
                result = runtime.routed_json_prompt(self.router(), Client(), 'verify', image, purpose='verification')
            self.assertIs(result['verified'], False)

    def test_structured_retry_delay_and_http_date_are_respected(self):
        self.assertEqual(policy.classify_failure(RuntimeError('HTTP 503 {"retryDelay":"12s"}'), 1000).retry_at, 1012)
        failure = policy.classify_failure(RuntimeError('daily quota exhausted Retry-After: Thu, 01 Jan 1970 00:20:00 GMT'), 1000)
        self.assertEqual(failure.kind, 'quota')
        self.assertEqual(failure.retry_at, 1200)
        self.assertEqual(policy.classify_failure(RuntimeError('daily quota exhausted resetAt: 2026-10-10T00:00:00Z'), 1000).retry_at, 1791590400)

    def test_sqlite_transcript_recovery_rejects_stale_turn_errors(self):
        import queue
        client = runtime.ACPClient.__new__(runtime.ACPClient)
        client.session_id = 'session'; client.session_key = 'unique'; client.transport = runtime.ACPTransport()
        client.request = mock.Mock(return_value={'stopReason':'end_turn'})
        client.gateway_configuration = mock.Mock(return_value={'messages':[
            {'role':'assistant','timestamp':900,'stopReason':'error','errorMessage':'old error'},
            {'role':'assistant','timestamp':1001,'content':[{'text':'{"status":"done"}'}]}
        ]})
        with mock.patch.object(runtime.time, 'time', return_value=1), mock.patch.object(runtime, 'session_transcript_cursor', return_value=None):
            self.assertEqual(client._run_prompt([], None)[1], '{"status":"done"}')
            client.gateway_configuration.return_value = {'messages':[
                {'role':'assistant','timestamp':900,'stopReason':'error','errorMessage':'old error'}
            ]}
            with mock.patch.object(runtime, 'openclaw_session_error', return_value=''):
                self.assertEqual(client._run_prompt([], None)[1], '')

if __name__ == '__main__':
    unittest.main()
