import contextlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
from fault_correlation import FaultReports, CAUSES, STAGES, validate_event, validate_link
from task_execution import TaskContext, current_task, Phase
import openclaw_runtime as runtime
import managed_openclaw as managed
from openclaw_runtime import ResponseRepairBudget
from provider_errors import ProviderRequestError


class FaultCorrelationTests(unittest.TestCase):
    def test_shared_wire_vocabulary_and_strict_projection(self):
        fixture = json.loads((Path(__file__).resolve().parents[1] / 'Fixtures/backend-faults.json').read_text())
        self.assertEqual(CAUSES, set(fixture['causes']))
        self.assertEqual(STAGES, set(fixture['stages']))
        self.assertEqual(validate_event(fixture['valid']), fixture['valid'])
        for changes in fixture['invalid_changes']:
            with self.subTest(changes=changes), self.assertRaises((ValueError, TypeError)):
                validate_event({**fixture['valid'], **changes})

    def test_explicit_links_keep_first_actionable_cause_and_bound_consequences(self):
        events = []
        reports = FaultReports(publish=events.append)
        link = reports.record('gateway_unavailable', 'health_check')
        self.assertEqual(reports.record('transport', 'connection', link=link), link)
        for _ in range(100): reports.note(link, 'waiting')
        self.assertEqual(len(events), 16)
        self.assertTrue(all(e['cause'] == 'gateway_unavailable' for e in events))
        self.assertEqual(reports.reports[link].first_stage, 'health_check')
        quota = reports.record('provider_quota', 'model_request', link=link)
        command = reports.record('command_timeout', 'native_action', link=link)
        separate = reports.record('transport', 'connection')
        self.assertEqual(len({link, quota, command, separate}), 4)
        self.assertFalse(reports.claim(quota, 'reconnect'))
        self.assertFalse(reports.claim(command, 'gateway_restart'))

    def test_recovery_claims_are_atomic_and_do_not_allocate_more_budget(self):
        reports = FaultReports()
        link = reports.record('transport', 'connection')
        with ThreadPoolExecutor(max_workers=8) as workers:
            results = list(workers.map(lambda _: reports.claim(link, 'reconnect'), range(64)))
        self.assertEqual(sum(results), 1)
        self.assertEqual(reports.reports[link].suppressed, 63)
        self.assertTrue(reports.claim(link, 'reconnect', attempt=2))
        self.assertFalse(reports.claim(link, 'reconnect', attempt=17))

    def test_ttl_is_not_extended_by_symptoms_and_clock_regression_expires(self):
        now = [100.0]
        reports = FaultReports(clock=lambda: now[0], capacity=2)
        first = reports.record('transport', 'connection')
        now[0] += 119
        reports.note(first, 'waiting')
        now[0] += 1
        self.assertFalse(reports.claim(first, 'reconnect'))
        self.assertIsNone(reports.note(first, 'terminal'))
        second = reports.record('transport', 'connection')
        now[0] -= 1
        self.assertIsNone(reports.note(second, 'waiting'))
        for _ in range(100): reports.record('transport', 'connection')
        self.assertEqual(len(reports.reports), 2)

    def test_diagnostic_sink_failure_cannot_fail_work(self):
        reports = FaultReports(publish=mock.Mock(side_effect=OSError('fixture')))
        link = reports.record('transport', 'connection')
        self.assertTrue(reports.claim(link, 'reconnect'))

    def test_late_host_cause_joins_only_its_explicit_connection_and_preserves_spent_recovery(self):
        events, relations = [], []
        reports = FaultReports(publish=events.append, publish_link=relations.append)
        child = reports.record('transport', 'connection')
        reports.claim(child, 'reconnect'); reports.note(child, 'waiting')
        other = reports.record('provider_quota', 'model_request')
        parent = reports.record('gateway_unavailable', 'health_check')
        self.assertFalse(reports.attach(other, parent))
        self.assertTrue(reports.attach(child, parent))
        self.assertEqual(len(reports.reports), 2)
        self.assertFalse(reports.claim(child, 'reconnect'))
        self.assertEqual(reports.record('transport', 'draining', link=child), parent)
        self.assertEqual(validate_link(relations[0]), dict(version=1, child_id=child, parent_id=parent))
        self.assertEqual(reports.reports[parent].consequences['waiting'], 1)
        self.assertTrue(reports.attach(child, parent))
        self.assertEqual(len(relations), 1)
        for change in [dict(version=True), dict(child_id=parent), dict(detail='secret')]:
            with self.assertRaises(ValueError): validate_link({**relations[0], **change})

    @contextlib.contextmanager
    def task(self):
        context = TaskContext('synthetic', 1, 'generation')
        token = current_task.set(context)
        try:
            with mock.patch.object(runtime, 'emit') as emit:
                yield context, emit
        finally: current_task.reset(token)

    def test_later_wrapped_error_keeps_lineage_but_new_task_cannot_inherit(self):
        error = RuntimeError('OpenClaw ACP exited /private/task with secret content')
        with self.task() as (context, emit):
            first = runtime.report_task_failure(error, 'connection')
            wrapper = RuntimeError('terminal wrapper'); wrapper.__cause__ = error
            self.assertEqual(runtime.report_task_failure(wrapper, 'draining'), first)
            encoded = json.dumps([c.kwargs for c in emit.call_args_list])
            self.assertNotIn('secret', encoded)
            self.assertNotIn('/private', encoded)
            self.assertEqual(len(context.faults.reports), 1)
            self.assertIsNone(runtime.report_task_failure(KeyboardInterrupt(), 'draining'))
        with self.task() as (context, _):
            self.assertNotEqual(runtime.report_task_failure(error, 'connection'), first)
            self.assertEqual(len(context.faults.reports), 1)

    def test_same_terminal_transport_fault_cannot_reconnect_twice(self):
        with self.task() as (context, _), tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image.png'; image.write_bytes(b'image')
            error = RuntimeError('OpenClaw ACP exited')
            client = mock.Mock(selected_model='google/fixture', successful_provider_retries=None,
                               prompt=mock.Mock(side_effect=error))
            for _ in range(2):
                with self.assertRaises(RuntimeError):
                    runtime.validated_prompt(client, 'synthetic', image, 'planning', ResponseRepairBudget())
            self.assertEqual(client.reconnect.call_count, 1)
            self.assertEqual(client.prompt.call_count, 3)
            self.assertEqual(len(context.faults.reports), 1)
            report = next(iter(context.faults.reports.values()))
            self.assertEqual(report.cause, 'transport')
            self.assertEqual(report.suppressed, 1)

    def test_reconnect_can_discover_gateway_root_after_transport_failure(self):
        with self.task() as (context, emit), tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image.png'; image.write_bytes(b'image')
            error = RuntimeError('OpenClaw ACP exited')
            event = dict(version=1, fault_id='00000000-0000-4000-8000-000000000001',
                         sequence=1, cause='gateway_unavailable', stage='health_check')
            def reconnect(): runtime.observe_gateway_fault(event)
            client = mock.Mock(selected_model='google/fixture', successful_provider_retries=None,
                prompt=mock.Mock(side_effect=error), reconnect=mock.Mock(side_effect=reconnect))
            for _ in range(2):
                with self.assertRaises(RuntimeError):
                    runtime.validated_prompt(client, 'synthetic', image, 'planning', ResponseRepairBudget())
            self.assertEqual(client.reconnect.call_count, 1)
            self.assertEqual(len(context.faults.reports), 1)
            self.assertEqual(next(iter(context.faults.reports.values())).cause, 'gateway_unavailable')
            self.assertTrue(any('fault_link' in call.kwargs for call in emit.call_args_list))

    def test_provider_quota_bypasses_connection_recovery_and_format_repair(self):
        error = ProviderRequestError({'error': {'code': 429, 'status': 'RESOURCE_EXHAUSTED',
            'message': 'Quota exhausted'}})
        with self.task() as (context, _), tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image.png'; image.write_bytes(b'image')
            client = mock.Mock(successful_provider_retries=None, prompt=mock.Mock(side_effect=error))
            with self.assertRaises(ProviderRequestError):
                runtime.validated_prompt(client, 'synthetic', image, 'planning', ResponseRepairBudget())
            link = runtime.report_task_failure(error, 'model_request')
            self.assertEqual(context.faults.reports[link].cause, 'provider_quota')
            client.reconnect.assert_not_called()
            self.assertEqual(client.prompt.call_count, 1)

    def test_state_machine_failure_boundary_records_then_drains_without_actions(self):
        with self.task() as (context, _), mock.patch.object(runtime, 'find_openclaw',
                side_effect=RuntimeError('OpenClaw ACP exited')), mock.patch.object(runtime, 'bridge_call') as bridge:
            with self.assertRaises(RuntimeError): runtime.TaskExecution(context).run(None, '')
            self.assertEqual(context.machine.phase, Phase.FINISHED)
            bridge.assert_not_called()
            self.assertEqual(next(iter(context.faults.reports.values())).cause, 'transport')

    def test_router_preserves_quota_policy_and_correlates_waits_without_restarts(self):
        from request_policy import PRIMARY_MODELS, RecoveryExhaustedError
        error = ProviderRequestError({'error': {'code': 429, 'status': 'RESOURCE_EXHAUSTED',
            'message': 'Daily quota exhausted', 'details': [{'@type': 'type.googleapis.com/google.rpc.QuotaFailure',
                'violations': [{'quotaId': 'GenerateRequestsPerDayPerProject'}]}]}})
        with self.task() as (context, _):
            router = runtime.TaskModelRouter()
            calls = []
            def operation(model):
                calls.append(model)
                raise error
            with self.assertRaises(RecoveryExhaustedError) as terminal: router.execute(operation)
            runtime.report_task_failure(terminal.exception, 'draining')
            self.assertEqual(calls, [PRIMARY_MODELS[0]])
            self.assertEqual(len(context.faults.reports), 1)
            report = next(iter(context.faults.reports.values()))
            self.assertEqual(report.cause, 'provider_quota')
            self.assertFalse(report.claims)

    def test_native_protocol_and_delayed_command_never_become_provider_failures(self):
        with self.task() as (context, _):
            error = runtime.NativeProtocolError('Invalid response contained quota and credentials')
            link = runtime.report_task_failure(error, 'native_action')
            self.assertEqual(context.faults.reports[link].cause, 'native_protocol')
            self.assertFalse(context.faults.claim(link, 'reconnect'))
            context.machine.phase = Phase.RECONCILING
            context.action = {'type': 'run_command', 'argv': ['/usr/bin/true']}
            context.result = {'timed_out': True}
            context.decision = {}; context.observation = {}
            context.recovery_cycles = mock.Mock()
            with mock.patch.object(runtime, 'publish_task_progress'):
                runtime.TaskExecution(context).record_result()
            self.assertEqual([r.cause for r in context.faults.reports.values()], ['native_protocol', 'command_timeout'])
            self.assertEqual(context.machine.phase, Phase.OBSERVING)

    def test_gateway_hint_requires_live_matching_fresh_host_and_never_grants_health(self):
        descriptor = dict(instance_id='fixture', installation_fingerprint='install', configuration_fingerprint='config')
        event = dict(version=1, fault_id='00000000-0000-4000-8000-000000000001',
                     sequence=1, cause='gateway_unavailable', stage='health_check')
        record = dict(descriptor, version=1, state='recovering', checked_at=100, fault=event,
                      host_identity={'pid': 2, 'seconds': 1, 'microseconds': 0})
        with mock.patch.object(managed, 'identity_alive', return_value=True):
            self.assertEqual(managed.health_fault(record, descriptor, wall_time=101), event)
            self.assertFalse(managed.healthy_record(record, descriptor, wall_time=101))
            for changes in [dict(checked_at=200), dict(checked_at=1), dict(installation_fingerprint='old'),
                            dict(fault={**event, 'detail': 'private'}), dict(state='healthy')]:
                self.assertIsNone(managed.health_fault({**record, **changes}, descriptor, wall_time=101))
        with mock.patch.object(managed, 'identity_alive', return_value=False):
            self.assertIsNone(managed.health_fault(record, descriptor, wall_time=101))
        with self.task() as (context, emit):
            runtime.observe_gateway_fault(event); runtime.observe_gateway_fault(event)
            link = runtime.report_task_failure(RuntimeError('OpenClaw ACP exited'), 'connection')
            self.assertEqual(link, event['fault_id'])
            self.assertEqual(len(context.faults.reports), 1)
            self.assertEqual(emit.call_count, 2)
            runtime.observe_gateway_fault(None)
            self.assertIsNone(context.gateway_fault_link)
            next_link = runtime.report_task_failure(RuntimeError('OpenClaw ACP exited'), 'connection')
            self.assertNotEqual(next_link, link)


if __name__ == '__main__': unittest.main()
