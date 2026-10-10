import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import request_policy as policy
import openclaw_runtime as runtime


class RequestPolicyTests(unittest.TestCase):
    def router(self):
        self.now = 1000.0
        self.calls = []
        def sleep(seconds):
            self.now += seconds
        return policy.AdaptiveModelRouter(lambda *a, **k: None, clock=lambda: self.now, sleep=sleep)

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
            state.verify(policy.PRIMARY_MODELS[0])
            self.assertEqual(state.verified_model(), policy.PRIMARY_MODELS[0])
            self.assertIsNone(policy.RuntimeState('changed', 'v1', root).verified_model())
            self.assertIsNone(policy.RuntimeState('fingerprint', 'v2', root).verified_model())
            with mock.patch.object(policy.time, 'time', return_value=1600):
                self.assertIsNone(state.verified_model())
            state.record_failure(policy.PRIMARY_MODELS[0], policy.Failure('temporary', 'overloaded', 1100))
            self.assertIsNone(state.verified_model())
            self.assertEqual(policy.RuntimeState('fingerprint', 'v1', root).health(policy.PRIMARY_MODELS[0])['state'], 'temporary')
            self.assertEqual(state.path.stat().st_mode & 0o777, 0o600)

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
            class Client:
                model_switches = 0
                def select_model(self, model): pass
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
                client.prompt.return_value = '{"status":"act","action":{"type":"click","x":1,"y":2}}'
                for _ in range(2):
                    runtime.routed_json_prompt(router, client, 'mutation', image)
                self.assertEqual(client.prompt.call_count, 4)

    def test_reconnect_once_replays_only_reasoning(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image.png'; image.write_bytes(b'image')
            class Client:
                model_switches = 0
                reconnects = 0
                def select_model(self, model): pass
                def reconnect(self): self.reconnects += 1
                prompt = mock.Mock(side_effect=[RuntimeError('OpenClaw ACP exited'), '{"status":"done"}'])
            client = Client(); router = self.router()
            with mock.patch.object(runtime, 'emit'), mock.patch.object(runtime, 'bridge_call') as bridge:
                self.assertEqual(runtime.routed_json_prompt(router, client, 'reason', image)['status'], 'done')
                bridge.assert_not_called()
            self.assertEqual(client.reconnects, 1)
            self.assertEqual(client.prompt.call_count, 2)

    def test_malformed_output_recovers_to_secondary(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image.png'; image.write_bytes(b'image')
            class Client:
                model_switches = 0
                def select_model(self, model): pass
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
        with self.assertRaisesRegex(RuntimeError, 'disconnected again'):
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
        client.session_id = 'session'; client.messages = queue.Queue()
        client.agent_chunks = []; client.turn_errors = []
        for update in [{'sessionUpdate':'error','message':'old error'}, {'sessionUpdate':'agent_message_chunk','content':{'text':'old output'}}]:
            client.messages.put({'method':'session/update','params':{'sessionId':'session','update':update}})
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
            class Client:
                model_switches = 0
                def select_model(self, model): pass
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
        client.session_id = 'session'; client.session_key = 'unique'; client.messages = queue.Queue()
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
