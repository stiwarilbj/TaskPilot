import json
from pathlib import Path
import queue
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
import provider_errors as errors
import request_policy as policy


def quota(scope='credential', delay=None, daily=True):
    violation = {'quotaId': 'GenerateRequestsPerDayPerProject' if daily else 'GenerateRequestsPerMinutePerProject'}
    if scope == 'model':
        violation['quotaId'] += 'PerModel'
        violation['quotaDimensions'] = {'location': 'global', 'model': 'gemini-3.5-flash-lite'}
    details = [{'@type': 'type.googleapis.com/google.rpc.QuotaFailure', 'violations': [violation]}] if scope else []
    if delay is not None:
        details.append({'@type': 'type.googleapis.com/google.rpc.RetryInfo', 'retryDelay': f'{delay}s'})
    return {'error': {'code': 429, 'status': 'RESOURCE_EXHAUSTED', 'message': 'Quota reached private-provider-message', 'details': details}}


class ProviderErrorTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000.0
        self.calls = []
        self.events = []

    def router(self, state=None):
        def sleep(seconds): self.now += seconds
        return policy.AdaptiveModelRouter(lambda *a, **k: self.events.append((a, k)), state,
                                          clock=lambda: self.now, sleep=sleep)

    def failure(self, payload, model=policy.PRIMARY_MODELS[0]):
        return policy.classify_failure(errors.ProviderRequestError(payload, model), self.now)

    def test_nested_rpc_preserves_codes_status_scope_and_longest_hint(self):
        payload = {'code': -32000, 'message': 'ACP request failed', 'data': quota(delay=12)}
        payload['data']['error']['headers'] = {'Retry-After': '15'}
        payload['data']['error']['resetAt'] = 1100
        failure = self.failure(payload)
        self.assertEqual((failure.kind, failure.scope), ('quota', 'credential'))
        self.assertEqual((failure.code, failure.http_status, failure.rpc_code), (429, 429, -32000))
        self.assertEqual(failure.provider_status, 'RESOURCE_EXHAUSTED')
        self.assertEqual(failure.retry_at, 1100)
        copied = policy.classify_failure(policy.ModelAttemptError.from_failure(failure), self.now)
        self.assertEqual(copied.metadata(), failure.metadata())

    def test_model_and_unknown_quota_do_not_block_siblings(self):
        for scope, daily in [('model', True), ('model', False), (None, False)]:
            router = self.router()
            def operation(model):
                self.calls.append(model)
                if model == policy.PRIMARY_MODELS[0]: raise errors.ProviderRequestError(quota(scope, daily=daily))
                return 'ok'
            with self.subTest(scope=scope, daily=daily):
                self.calls = []
                self.assertEqual(router.execute(operation), 'ok')
                self.assertEqual(self.calls, list(policy.PRIMARY_MODELS))
                self.assertEqual(router.metrics['retries'], 0)
        failure = self.failure(quota('model'))
        self.assertEqual((failure.scope, failure.kind, failure.retry_at), ('model', 'quota', float('inf')))

    def test_shared_quota_without_reset_stops_after_one_call(self):
        router = self.router()
        def operation(model):
            self.calls.append(model)
            raise errors.ProviderRequestError(quota())
        with self.assertRaises(policy.RecoveryExhaustedError) as caught: router.execute(operation)
        self.assertEqual(self.calls, [policy.PRIMARY_MODELS[0]])
        self.assertEqual(router.metrics['retries'], 0)
        self.assertEqual(caught.exception.failure.code, 429)
        self.assertEqual(caught.exception.failure.scope, 'credential')
        self.assertNotIn('private-provider-message', str(caught.exception))
        self.assertTrue(all(e[1]['state'] == 'temporary' for e in self.events if e[0][0] == 'model_health'))

    def test_shared_reset_retries_only_owner_at_most_twice(self):
        router = self.router()
        def operation(model):
            self.calls.append((model, self.now))
            raise errors.ProviderRequestError(quota(delay=12))
        with self.assertRaises(policy.RecoveryExhaustedError): router.execute(operation)
        self.assertEqual(self.calls, [(policy.PRIMARY_MODELS[0], t) for t in (1000, 1012, 1024)])
        self.assertEqual(router.metrics['planning'], 3)
        self.assertEqual(router.metrics['retries'], 2)

    def test_shared_cooldown_success_stays_selected(self):
        router = self.router()
        def operation(model):
            self.calls.append((model, self.now))
            if len(self.calls) == 1: raise errors.ProviderRequestError(quota(delay=12))
            return 'ok'
        self.assertEqual(router.execute(operation), 'ok')
        self.assertEqual(router.execute(operation), 'ok')
        self.assertEqual(self.calls, [(policy.PRIMARY_MODELS[0], t) for t in (1000, 1012, 1012)])

    def test_expired_shared_block_can_fall_back_after_new_model_error(self):
        router = self.router()
        def operation(model):
            self.calls.append(model)
            if len(self.calls) == 1: raise errors.ProviderRequestError(quota(delay=12))
            if model == policy.PRIMARY_MODELS[0]: raise errors.ProviderRequestError({'error': {'code': 'MODEL_NOT_FOUND'}})
            return 'ok'
        self.assertEqual(router.execute(operation), 'ok')
        self.assertEqual(self.calls, [policy.PRIMARY_MODELS[0], *policy.PRIMARY_MODELS])

    def test_upstream_exhaustion_suppresses_shared_retries(self):
        payload = quota(delay=12); payload['recoveryExhausted'] = True; payload['providerRetries'] = 2
        operation = mock.Mock(side_effect=errors.ProviderRequestError(payload))
        router = self.router()
        with self.assertRaises(policy.RecoveryExhaustedError): router.execute(operation)
        operation.assert_called_once_with(policy.PRIMARY_MODELS[0])
        self.assertEqual(router.metrics['provider_retries'], 2)
        self.assertEqual(router.metrics['retries'], 0)

    def test_structured_exhausted_attempts_are_not_queried_again(self):
        payload = {'name': 'FailoverError', 'reason': 'rate_limit', 'message': 'All models failed',
                   'attempts': [{'provider': m.split('/')[0], 'model': m.split('/')[1], 'status': 503,
                                 'code': 'OVERLOADED', 'reason': 'rate_limit', 'rawError': 'private-provider-message'}
                                for m in policy.ALL_MODELS]}
        router = self.router(); operation = mock.Mock(side_effect=errors.ProviderRequestError(payload))
        with self.assertRaises(policy.RecoveryExhaustedError) as caught: router.execute(operation)
        operation.assert_called_once()
        self.assertEqual({m for m, _ in caught.exception.failures}, set(policy.ALL_MODELS))
        self.assertEqual(caught.exception.failure.http_status, 503)
        self.assertEqual(caught.exception.failure.code, 'OVERLOADED')
        self.assertIsNone(router.metrics['provider_retries'])  # Attempts are not provider retry counts.

    def test_partial_upstream_attempts_leave_untested_model_eligible(self):
        payload = {'reason': 'rate_limit', 'attempts': [{'provider': 'google', 'model': m.split('/')[1], 'status': 503}
                                                     for m in policy.PRIMARY_MODELS]}
        router = self.router()
        def operation(model):
            self.calls.append(model)
            if len(self.calls) == 1: raise errors.ProviderRequestError(payload)
            return 'ok'
        self.assertEqual(router.execute(operation), 'ok')
        self.assertEqual(self.calls, [policy.PRIMARY_MODELS[0], policy.FALLBACK_MODELS[0]])

    def test_upstream_account_error_blocks_siblings_even_without_model_identity(self):
        payload = {'reason': 'rate_limit', 'attempts': [{'provider': 'google', 'code': 'insufficient_quota', 'reason': 'billing'}]}
        router = self.router(); operation = mock.Mock(side_effect=errors.ProviderRequestError(payload))
        with self.assertRaises(policy.RecoveryExhaustedError): router.execute(operation)
        operation.assert_called_once()

    def test_upstream_credential_failure_stops_recovery(self):
        payload = {'reason': 'rate_limit', 'attempts': [{'provider': 'google', 'model': policy.PRIMARY_MODELS[1].split('/')[1], 'status': 401}]}
        router = self.router(); operation = mock.Mock(side_effect=errors.ProviderRequestError(payload))
        with self.assertRaises(policy.ModelAttemptError) as caught: router.execute(operation)
        self.assertEqual(caught.exception.kind, 'credentials')
        operation.assert_called_once()

    def test_generic_not_available_is_not_proof_of_missing_model(self):
        for payload, kind in [({'error': {'code': 503, 'message': 'not available'}}, 'temporary'),
                              ({'error': {'code': 404, 'message': 'endpoint not available'}}, 'configuration'),
                              ({'error': {'code': 'MODEL_NOT_FOUND', 'message': 'not available'}}, 'unavailable')]:
            with self.subTest(payload=payload): self.assertEqual(self.failure(payload).kind, kind)

    def test_server_and_timeout_codes_remain_distinct(self):
        for status, reason in [(500, 'server_error'), (501, 'server_error'), (502, 'server_error'), (520, 'server_error'), (503, 'overloaded'), (529, 'overloaded'), (504, 'timeout')]:
            with self.subTest(status=status):
                failure = self.failure({'error': {'code': status, 'message': 'Provider request failed'}})
                self.assertEqual((failure.kind, failure.reason, failure.http_status), ('temporary', reason, status))
                self.assertEqual(failure.retry_at, 1030)

    def test_duration_milliseconds_and_http_date_hints(self):
        for hints, expected in [({'retryDelay': {'seconds': '12', 'nanos': 500000000}}, 1012.5),
                                ({'retryAfterMs': 12500}, 1012.5),
                                ({'headers': {'Retry-After': 'Thu, 01 Jan 1970 00:20:00 GMT'}}, 1200),
                                ({'soonestCooldownExpiry': 1100000}, 1100),
                                ({'retryDelay': 'nan', 'resetAt': float('inf')}, 1030)]:
            with self.subTest(hints=hints):
                self.assertEqual(self.failure({'error': {'code': 503, **hints}}).retry_at, expected)

    def test_interrupted_wait_never_issues_premature_request(self):
        router = self.router(); router.sleep = lambda _: None
        operation = mock.Mock(side_effect=errors.ProviderRequestError(quota(delay=12)))
        with self.assertRaises(policy.RecoveryExhaustedError): router.execute(operation)
        operation.assert_called_once()
        router = self.router(); router.sleep = mock.Mock(side_effect=RuntimeError('Task cancelled'))
        with self.assertRaisesRegex(RuntimeError, 'cancelled'): router.execute(operation)
        self.assertEqual(router.metrics['retries'], 0)

    def test_cache_keeps_safe_facts_and_invalidates_shared_verification(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(policy.time, 'time', return_value=1000):
            state = policy.RuntimeState('key-fingerprint', 'version', Path(directory))
            for model in policy.ALL_MODELS: state.verify(model)
            state.verify('other/unrelated')
            payload = quota(delay=120); payload['request'] = {'apiKey': 'private-secret', 'command': 'private-command'}
            state.record_failure(policy.PRIMARY_MODELS[0], self.failure(payload))
            stored = state.path.read_text()
            for text in ('private-provider-message', 'private-secret', 'private-command', 'request'): self.assertNotIn(text, stored)
            self.assertIsNone(state.verified_model())
            self.assertIn('other/unrelated', state.value['verified'])
            reopened = policy.RuntimeState('key-fingerprint', 'version', Path(directory))
            self.assertTrue(all(reopened.health(m)['failure_scope'] == 'credential' for m in policy.ALL_MODELS))
            self.assertEqual(reopened.health(policy.PRIMARY_MODELS[1])['error_code'], 429)
            router = self.router(reopened); operation = mock.Mock(return_value='ok')
            self.assertEqual(router.execute(operation), 'ok')
            self.assertEqual(self.now, 1120)
            operation.assert_called_once_with(policy.PRIMARY_MODELS[0])
            self.assertFalse(any(reopened.health(m) for m in policy.ALL_MODELS))

    def test_cache_scope_is_cleared_by_changed_credentials_and_reset(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(policy.time, 'time', return_value=1000):
            state = policy.RuntimeState('key', 'version', Path(directory))
            state.record_failure(policy.PRIMARY_MODELS[0], self.failure(quota(delay=120)))
            self.assertFalse(policy.RuntimeState('changed-key', 'version', Path(directory)).health(policy.PRIMARY_MODELS[0]))
            with mock.patch.object(policy.time, 'time', return_value=1120):
                self.assertFalse(state.health(policy.PRIMARY_MODELS[1]))

    def test_cached_shared_quota_makes_no_generation_on_readiness_refresh_or_early_check(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(policy.time, 'time', return_value=1000):
            state = policy.RuntimeState('key', 'version', Path(directory))
            state.record_failure(policy.PRIMARY_MODELS[0], self.failure(quota(delay=120)))
            with mock.patch.object(runtime, 'prepare_runtime', return_value=state), mock.patch.object(runtime, 'RuntimeState', return_value=state), \
                 mock.patch.object(runtime, 'openclaw_version', return_value='version'), mock.patch.object(runtime, 'emit'), mock.patch.object(runtime, 'ACPClient') as client:
                self.assertFalse(runtime.check_models('openclaw', 'key', read_only=True))
                self.assertFalse(runtime.check_models('openclaw', 'key'))
                client.assert_not_called()

    def test_explicit_readiness_does_not_probe_siblings_for_new_shared_quota(self):
        with tempfile.TemporaryDirectory() as directory:
            state = policy.RuntimeState('key', 'version', Path(directory))
            client = mock.Mock(prompt_calls=1, selected_model=policy.PRIMARY_MODELS[0])
            client.prompt.side_effect = errors.ProviderRequestError(quota())
            with mock.patch.object(runtime, 'prepare_runtime', return_value=state), mock.patch.object(runtime, 'ACPClient', return_value=client), mock.patch.object(runtime, 'emit') as emit:
                self.assertFalse(runtime.check_models('openclaw', 'key'))
            client.prompt.assert_called_once()
            checks = emit.call_args.kwargs['checks']
            self.assertTrue(all(c['state'] == 'temporary' and c['error_code'] == 429 for c in checks))

    def test_explicit_check_can_detect_repaired_quota_with_no_reported_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            state = policy.RuntimeState('key', 'version', Path(directory))
            state.record_failure(policy.PRIMARY_MODELS[0], self.failure(quota()))
            client = mock.Mock(prompt_calls=1, selected_model=policy.PRIMARY_MODELS[0])
            client.prompt.return_value = '{"status":"done","check":"TASKPILOT_READY"}'
            with mock.patch.object(runtime, 'prepare_runtime', return_value=state), mock.patch.object(runtime, 'ACPClient', return_value=client), mock.patch.object(runtime, 'emit') as emit:
                self.assertTrue(runtime.check_models('openclaw', 'key'))
            client.prompt.assert_called_once()
            self.assertEqual([c['state'] for c in emit.call_args.kwargs['checks']], ['verified'] + ['configured'] * 5)

    def test_provider_json_bypasses_format_repair_without_hiding_codes(self):
        for response in [json.dumps(quota()), '```json\n' + json.dumps(quota()) + '\n```']:
            with tempfile.TemporaryDirectory() as directory, self.subTest(response=response):
                image = Path(directory) / 'image.png'; image.write_bytes(b'image')
                client = mock.Mock(selected_model=policy.PRIMARY_MODELS[0]); client.prompt.return_value = response
                budget = runtime.ResponseRepairBudget()
                with self.assertRaises(policy.ModelAttemptError) as caught:
                    runtime.validated_prompt(client, 'decision', image, 'planning', budget)
                self.assertEqual(caught.exception.failure.code, 429)
                self.assertEqual(caught.exception.failure.scope, 'credential')
                client.prompt.assert_called_once(); self.assertFalse(budget.used)

    def test_decision_with_error_words_is_still_a_decision(self):
        self.assertIsNone(errors.response_error({'status': 'blocked', 'reason': 'quota', 'error': 'unsupported'}))
        self.assertIsNone(errors.response_error({'status': [], 'action': {}}))
        self.assertIsNone(errors.response_error('[{"error":"quota"}]'))

    def client(self):
        client = runtime.ACPClient.__new__(runtime.ACPClient)
        client.session_id = 'current'; client.selected_model = policy.PRIMARY_MODELS[0]
        client.next_request_id = 2; client.transport = runtime.ACPTransport()
        client.agent_chunks = []; client.turn_errors = []; client.stderr_tail = []
        client.process = mock.Mock(); client.process.poll.return_value = None
        client._send = mock.Mock()
        return client

    def test_acp_rpc_response_keeps_nested_error_envelope(self):
        client = self.client()
        def send(_):
            client.transport.route({'id': 1, 'error': {'code': 401, 'message': 'stale'}})
            client.transport.route({'id': 2, 'error': {'code': -32000, 'data': quota()}})
        client._send.side_effect = send
        with self.assertRaises(errors.ProviderRequestError) as caught: client.request('session/prompt', {'sessionId': 'current'}, timeout=None)
        failure = self.failure(caught.exception.payload)
        self.assertEqual((failure.code, failure.rpc_code, failure.scope), (429, -32000, 'credential'))

    def test_stream_errors_keep_data_and_reject_foreign_requests(self):
        client = self.client(); client.pending_prompt_request_id = 2
        for session, request in [('earlier', 2), ('current', 1), ('current', 2)]:
            client._handle_server_message({'method': 'session/update', 'params': {'sessionId': session, 'requestId': request,
                'update': {'sessionUpdate': 'error', 'error': quota()}}})
        self.assertEqual(len(client.turn_errors), 1)
        self.assertEqual(self.failure(client.turn_errors[0]).scope, 'credential')
        client.accepting_prompt_updates = False
        client._handle_server_message({'method': 'session/update', 'params': {'sessionId': 'current', 'update': {'sessionUpdate': 'error', 'error': quota()}}})
        self.assertEqual(len(client.turn_errors), 1)

    def test_terminal_result_keeps_precise_provider_error(self):
        client = self.client(); client.request = mock.Mock(return_value={'stopReason': 'error', **quota()})
        with mock.patch.object(runtime, 'session_transcript_cursor', return_value=None), self.assertRaises(errors.ProviderRequestError) as caught:
            client._run_prompt([], None)
        self.assertEqual(self.failure(caught.exception.payload).code, 429)

    def test_partial_response_error_bypasses_repair_but_recovered_complete_output_succeeds(self):
        for response, fails in [('{"status":', True), ('{"status":"done"}', False)]:
            client = self.client()
            def request(*args, **kwargs):
                client.agent_chunks = [response]; client.turn_errors = [quota()]
                return {'stopReason': 'end_turn'}
            client.request = request
            with mock.patch.object(runtime, 'session_transcript_cursor', return_value=None), self.subTest(response=response):
                if fails:
                    with self.assertRaises(errors.ProviderRequestError): client._run_prompt([], None)
                else: self.assertEqual(client._run_prompt([], None)[1], response)

    def test_jsonl_cursor_and_gateway_recovery_keep_data_and_ignore_old_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); path = root / 'session.jsonl'
            message = {'role': 'assistant', 'stopReason': 'error', 'error': quota()}
            path.write_text(json.dumps({'message': message}) + '\n')
            (root / 'sessions.json').write_text(json.dumps({'agent:main:acp:current': {'sessionFile': str(path)}}))
            cursor = runtime.session_transcript_cursor('current', root)
            self.assertEqual(runtime.openclaw_session_error('current', root, cursor, structured=True), '')
            with path.open('a') as handle: handle.write(json.dumps({'message': message}) + '\n')
            self.assertEqual(self.failure(runtime.openclaw_session_error('current', root, cursor, structured=True)).code, 429)
            self.assertEqual(runtime.openclaw_session_error('current', root, structured=True, started_at=1000), '')
        client = self.client(); client.session_key = 'unique'; client.request = mock.Mock(return_value={'stopReason': 'end_turn'})
        client.gateway_configuration = mock.Mock(return_value={'messages': [{'role': 'assistant', 'timestamp': 999, 'stopReason': 'error', 'error': quota()},
                                                                           {'role': 'assistant', 'timestamp': 1001, 'stopReason': 'error', 'error': quota('model')}]})
        with mock.patch.object(runtime.time, 'time', return_value=1), mock.patch.object(runtime, 'session_transcript_cursor', return_value=None), \
             self.assertRaises(errors.ProviderRequestError) as caught: client._run_prompt([], None)
        self.assertEqual(self.failure(caught.exception.payload).scope, 'model')

    def test_gateway_cli_error_keeps_json_and_provider_codes(self):
        client = self.client(); client.openclaw_path = 'openclaw'
        for returncode in (0, 1):
            with mock.patch.object(runtime.subprocess, 'run', return_value=mock.Mock(returncode=returncode, stdout=json.dumps(quota()), stderr='')), \
                 self.subTest(returncode=returncode), self.assertRaises(errors.ProviderRequestError) as caught:
                client.gateway_configuration('sessions.get', {'key': 'unique'})
            self.assertEqual(self.failure(caught.exception.payload).code, 429)

    def test_json_in_rpc_message_and_numeric_string_status_keep_codes(self):
        for payload in [{'code': -32000, 'message': 'Request failed: ' + json.dumps(quota())},
                        {'message': {'error': quota()['error']}}, {'error': {'code': '429', 'status': 'RESOURCE_EXHAUSTED'}}]:
            with self.subTest(payload=payload): self.assertEqual(self.failure(payload).http_status, 429)

    def test_healthy_and_repaired_provider_counts_are_reported_without_extra_calls(self):
        with tempfile.TemporaryDirectory() as directory:
            client = self.client(); image = Path(directory) / 'image.png'; image.write_bytes(b'image')
            client._run_prompt = mock.Mock(side_effect=[({'providerRetries': 3}, '{'), ({'providerRetries': 1}, '{"status":"done"}')])
            router = self.router(); budget = runtime.ResponseRepairBudget()
            with mock.patch.object(runtime, 'emit'):
                value = runtime.validated_prompt(client, 'decision', image, 'planning', budget, metrics=router.metrics)
            self.assertEqual(value['status'], 'done')
            self.assertEqual(client.prompt_calls, 2)
            self.assertEqual(router.metrics['provider_retries'], 4)

    def test_provider_error_counts_from_result_and_text_are_not_double_counted(self):
        with tempfile.TemporaryDirectory() as directory:
            client = self.client(); image = Path(directory) / 'image.png'; image.write_bytes(b'image')
            payload = quota(); payload['providerRetries'] = 2
            client._run_prompt = mock.Mock(return_value=({'providerRetries': 2}, json.dumps(payload)))
            router = self.router(); budget = runtime.ResponseRepairBudget()
            with self.assertRaises(policy.RecoveryExhaustedError):
                router.execute(lambda _: runtime.validated_prompt(client, 'decision', image, 'planning', budget, metrics=router.metrics))
            self.assertEqual(client.prompt_calls, 1)
            self.assertEqual(router.metrics['provider_retries'], 2)

    def test_generic_exhausted_wrapper_uses_structured_attempt_causes(self):
        payload = {'name': 'FailoverError', 'message': 'All models failed', 'attempts': [
            {'provider': 'google', 'model': m.split('/')[1], 'status': 503} for m in policy.PRIMARY_MODELS]}
        router = self.router()
        def operation(model):
            self.calls.append(model)
            if len(self.calls) == 1: raise errors.ProviderRequestError(payload)
            return 'ok'
        self.assertEqual(router.execute(operation), 'ok')
        self.assertEqual(self.calls, [policy.PRIMARY_MODELS[0], policy.FALLBACK_MODELS[0]])

    def test_credential_and_bad_request_codes_are_not_retried_as_capacity(self):
        for payload, expected in [({'error': {'code': 400, 'status': 'INVALID_ARGUMENT', 'message': 'bad quota argument'}}, 'configuration'),
                                  ({'error': {'code': 400, 'details': [{'reason': 'API_KEY_INVALID'}]}}, 'credentials'),
                                  ({'error': {'code': 402}}, 'quota')]:
            with self.subTest(payload=payload): self.assertEqual(self.failure(payload).kind, expected)


if __name__ == '__main__': unittest.main()
