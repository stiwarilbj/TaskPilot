"""Completion isolation with fictional ACP transport and native evidence only."""
from collections import deque
from copy import deepcopy
import hashlib
import io
import json
import os
from pathlib import Path
import queue
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
from evidence_fixtures import native_result
import openclaw_runtime as runtime
import prompt_compiler as compiler
from provider_errors import ProviderRequestError
from task_evidence import TaskEvidenceLedger


def section(prompt, name):
    return json.loads(prompt.split(name + ':\n', 1)[1].splitlines()[0])


class ACPFixture:
    """Use real client session/configuration/prompt code without a provider."""
    def __init__(self, responses):
        self.responses = iter(responses)
        self.requests = []
        self.generations = []
        self.serial = 0
        self.client = runtime.ACPClient.__new__(runtime.ACPClient)
        self.initialize('fixture')

    def initialize(self, _path):
        client = self.client
        client.process = mock.Mock()
        client.process.poll.return_value = None
        client.process.stdout = client.process.stderr = client.process.stdin = None
        client.messages = queue.Queue()
        client.stdout_finished = threading.Event()
        client.stderr_tail = deque()
        client.openclaw_path = 'fixture'
        client.selected_model = None
        client._session_ids = set()
        client.accepting_prompt_updates = False
        client.pending_prompt_session_id = None
        client.prompt_calls = client.model_switches = client.reconnects = 0
        client.successful_provider_retries = None
        client.request = self.request
        client._new_session()

    def request(self, method, params, timeout):
        self.requests.append((method, deepcopy(params)))
        client = self.client
        if method == 'session/new':
            self.serial += 1
            self.options = [{'id': 'model', 'category': 'model', 'currentValue': 'default'},
                            {'id': 'thought_level', 'category': 'thought_level', 'currentValue': 'high',
                             'options': [{'value': 'off'}, {'value': 'high'}]}]
            return {'sessionId': f'fixture-{self.serial}', 'configOptions': deepcopy(self.options)}
        if method == 'session/set_config_option':
            for option in self.options:
                if option['id'] == params['configId']: option['currentValue'] = params['value']
            return {'configOptions': deepcopy(self.options)}
        if method == 'session/prompt':
            client.pending_prompt_session_id = params['sessionId']
            self.generations.append((params['sessionId'], client.session_key, client.selected_model, deepcopy(params['prompt'])))
            value = next(self.responses)
            if isinstance(value, BaseException): raise value
            if callable(value): value = value(client)
            if value:
                client._handle_server_message({'method': 'session/update', 'params': {
                    'sessionId': params['sessionId'], 'update': {'sessionUpdate': 'agent_message_chunk',
                                                               'content': {'text': value}}}})
            client.pending_prompt_session_id = None
            return {'stopReason': 'end_turn'}
        raise AssertionError('Unexpected ACP method ' + method)


class VerificationSessionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(); self.addCleanup(self.directory.cleanup)
        self.image = Path(self.directory.name) / 'fixture.png'; self.image.write_bytes(b'offline image')
        self.router = runtime.AdaptiveModelRouter(lambda *a, **k: None, sleep=lambda _: None)
        patcher = mock.patch.object(runtime, 'emit'); patcher.start(); self.addCleanup(patcher.stop)
        patcher = mock.patch.object(runtime, 'session_transcript_cursor', return_value=None)
        self.cursor = patcher.start(); self.addCleanup(patcher.stop)

    def route(self, fixture, purpose='verification', instruction='independent check'):
        return runtime.routed_json_prompt(self.router, fixture.client, instruction, self.image, purpose=purpose)

    def test_healthy_verification_is_fresh_with_one_existing_generation(self):
        fixture = ACPFixture(['{"status":"done"}', '{"verified":true}'])
        client = fixture.client; planning = client.session_id, client.session_key
        self.route(fixture, 'planning', 'planner completion claim')
        self.route(fixture)
        first, second = fixture.generations
        self.assertNotEqual(first[:2], second[:2])
        self.assertEqual((client.session_id, client.session_key), planning)
        self.assertEqual(second[3][0]['text'], 'independent check')
        self.assertEqual(client.prompt_calls, 2)
        self.assertEqual((self.router.metrics['planning'], self.router.metrics['verification'], self.router.metrics['repairs']), (1, 1, 0))
        self.assertEqual(client.model_switches, 1)
        configured = [params for method, params in fixture.requests if method == 'session/set_config_option']
        self.assertEqual([p['sessionId'] for p in configured if p['configId'] == 'model'], [first[0], second[0]])
        self.assertEqual([p['value'] for p in configured if p['configId'] == 'thought_level'], ['off', 'off'])

    def test_each_rejected_completion_gets_another_fresh_session(self):
        fixture = ACPFixture(['{"verified":false}', '{"status":"done"}', '{"verified":false}'])
        planning = fixture.client.session_id
        self.assertFalse(self.route(fixture)['verified'])
        self.route(fixture, 'planning', 'continue unmet requirement')
        self.assertFalse(self.route(fixture, instruction='second check')['verified'])
        sessions = [call[0] for call in fixture.generations]
        self.assertEqual(sessions[1], planning)
        self.assertEqual(len(set(sessions)), 3)
        self.assertEqual(fixture.client.session_id, planning)

    def test_format_repair_uses_same_isolated_session_and_shared_budget(self):
        fixture = ACPFixture(['{"verified":"yes"}', '{"verified":true}'])
        self.assertTrue(self.route(fixture)['verified'])
        self.assertEqual(len({call[0] for call in fixture.generations}), 1)
        self.assertEqual(len({call[2] for call in fixture.generations}), 1)
        repair = fixture.generations[1][3][0]['text']
        self.assertIn('verified must be a boolean', repair)
        self.assertIn('independent check', repair)
        self.assertEqual((fixture.client.prompt_calls, self.router.metrics['verification'], self.router.metrics['repairs']), (2, 2, 1))

    def test_fallback_remains_isolated_and_successful_model_returns_to_planning(self):
        fixture = ACPFixture(['{"verified":"yes"}', '{"verified":null}', '{"verified":true}', '{"status":"done"}'])
        planning = fixture.client.session_id
        self.assertTrue(self.route(fixture)['verified'])
        self.assertEqual(len({call[0] for call in fixture.generations}), 1)
        self.assertEqual([call[2] for call in fixture.generations], [runtime.PRIMARY_MODELS[0]] * 2 + [runtime.PRIMARY_MODELS[1]])
        self.assertEqual(self.router.metrics['repairs'], 1)
        self.assertEqual(self.router.active_model, runtime.PRIMARY_MODELS[1])
        self.route(fixture, 'planning', 'continue')
        self.assertEqual(fixture.generations[-1][:3], (planning, fixture.client.session_key, runtime.PRIMARY_MODELS[1]))
        self.assertEqual(fixture.client.model_switches, 2)
        self.assertEqual(self.router.metrics['verification'], 3)

    def test_credentials_and_cancellation_bypass_repair(self):
        for error in [ProviderRequestError({'code': 401, 'message': 'invalid API key'}), RuntimeError('OpenClaw cancelled the TaskPilot turn')]:
            with self.subTest(error=type(error).__name__):
                fixture = ACPFixture([error]); planning = fixture.client.session_id
                self.router = runtime.AdaptiveModelRouter(lambda *a, **k: None)
                with self.assertRaises(RuntimeError): self.route(fixture)
                self.assertEqual(fixture.client.session_id, planning)
                self.assertEqual(len(fixture.generations), 1)
                self.assertEqual(self.router.metrics['repairs'], 0)

    def test_session_creation_rejects_missing_or_reused_identity_before_generation(self):
        for response in [{}, {'sessionId': ''}, {'sessionId': 'fixture-1'}]:
            fixture = ACPFixture([]); planning = fixture.client.session_id
            with self.subTest(response=response), mock.patch.object(fixture.client, 'request', return_value=response):
                with self.assertRaisesRegex(RuntimeError, 'fresh.*session'): self.route(fixture)
            self.assertEqual(fixture.client.session_id, planning)
            self.assertEqual(fixture.client.prompt_calls, 0)

    def test_thinking_setting_must_be_acknowledged_before_generation(self):
        fixture = ACPFixture([]); request = fixture.request
        def reject(method, params, timeout):
            if method == 'session/set_config_option': return {'configOptions': []}
            return request(method, params, timeout)
        with mock.patch.object(fixture.client, 'request', side_effect=reject):
            with self.assertRaisesRegex(RuntimeError, 'thinking setting'): self.route(fixture)
        self.assertEqual(fixture.client.prompt_calls, 0)

    def test_pending_planning_response_cannot_be_switched(self):
        fixture = ACPFixture([]); fixture.client.accepting_prompt_updates = True
        with self.assertRaisesRegex(RuntimeError, 'planning response is pending'): self.route(fixture)
        self.assertEqual(self.router.metrics['verification'], 0)
        self.assertEqual(fixture.serial, 1)

    def test_stale_and_unscoped_updates_do_not_enter_verifier_or_restored_planner(self):
        fixture = ACPFixture([]); planning = fixture.client.session_id
        def updates(client):
            for session in [planning, None]:
                for update in [{'sessionUpdate': 'error', 'message': 'old invalid API key'},
                               {'sessionUpdate': 'agent_message_chunk', 'content': {'text': 'stale completion'}}]:
                    client._handle_server_message({'method': 'session/update', 'params': {'sessionId': session, 'update': update}})
            return '{"verified":false}'
        fixture.responses = iter([updates])
        self.assertFalse(self.route(fixture)['verified'])
        client = fixture.client; client.accepting_prompt_updates = True
        client._handle_server_message({'method': 'session/update', 'params': {'sessionId': fixture.generations[0][0],
            'update': {'sessionUpdate': 'error', 'message': 'late verifier failure'}}})
        self.assertEqual(client.agent_chunks, [])
        self.assertEqual(client.turn_errors, [])
        self.assertEqual(self.cursor.call_args.args, (fixture.generations[0][0],))

    def test_empty_stream_recovery_reads_only_fresh_gateway_session(self):
        fixture = ACPFixture(['']); client = fixture.client; planning = client.session_key
        client.gateway_configuration = mock.Mock(return_value={'messages': [
            {'role': 'assistant', 'timestamp': 2000, 'content': [{'text': '{"verified":false}'}]}]})
        with mock.patch.object(runtime.time, 'time', return_value=1):
            self.assertFalse(self.route(fixture)['verified'])
        method, params = client.gateway_configuration.call_args.args
        self.assertEqual(method, 'sessions.get')
        self.assertNotEqual(params['key'], planning)
        self.assertEqual(params['key'], fixture.generations[0][1])
        self.assertEqual(client.prompt_calls, 1)

    def test_reconnect_aborts_verifier_before_replay_and_reattaches_planner(self):
        fixture = ACPFixture([RuntimeError('OpenClaw ACP exited'), '{"verified":false}', '{"status":"done"}'])
        client = fixture.client; planning = client.session_id, client.session_key
        client.gateway_configuration = mock.Mock(return_value={'ok': True, 'status': 'no-active-run'})
        with mock.patch.object(runtime.ACPClient, '__init__', side_effect=fixture.initialize):
            self.assertFalse(self.route(fixture)['verified'])
        client.gateway_configuration.assert_called_once_with('sessions.abort', {'key': fixture.generations[0][1]})
        self.assertNotEqual(fixture.generations[0][:2], fixture.generations[1][:2])
        self.assertEqual(client.session_key, planning[1])
        self.assertNotEqual(client.session_id, planning[0])
        self.assertEqual((client.prompt_calls, client.reconnects, client.model_switches), (2, 1, 1))
        self.route(fixture, 'planning', 'continue')
        self.assertEqual(fixture.generations[-1][1], planning[1])
        self.assertEqual(self.router.metrics['verification'], 2)
        self.assertEqual(self.router.metrics['repairs'], 0)

    def test_failed_reconnect_acknowledgement_never_replays_or_resumes(self):
        fixture = ACPFixture([RuntimeError('OpenClaw ACP exited')]); client = fixture.client
        client.gateway_configuration = mock.Mock(return_value={'ok': True, 'status': 'pending'})
        with mock.patch.object(runtime.ACPClient, '__init__') as initialize:
            with self.assertRaisesRegex(RuntimeError, 'confirm the previous'): self.route(fixture)
            initialize.assert_not_called()
        self.assertEqual(len(fixture.generations), 1)
        self.assertEqual(fixture.serial, 2)

    def test_cancelled_pending_verifier_is_the_session_cancelled_by_close(self):
        fixture = ACPFixture([SystemExit(143)]); client = fixture.client
        with self.assertRaises(SystemExit): self.route(fixture)
        pending = fixture.generations[0][0]
        client._send = mock.Mock()
        with mock.patch.object(runtime, '_active_acp_process', client.process): client.close()
        self.assertEqual(client._send.call_args.args[0]['params']['sessionId'], pending)
        self.assertEqual(len(fixture.generations), 1)

    def test_reconnect_reader_uses_only_originating_pipes_and_queues(self):
        fixture = ACPFixture([]); client = fixture.client
        old = mock.Mock(stdout=io.StringIO('{"method":"old"}\n'), stderr=io.StringIO('old error\n'))
        old_queue, old_finished, old_tail = queue.Queue(), threading.Event(), deque()
        client._read_stdout(old, old_queue, old_finished)
        client._read_stderr(old, old_tail)
        self.assertEqual(old_queue.get_nowait(), {'method': 'old'})
        self.assertTrue(old_finished.is_set())
        self.assertEqual(list(old_tail), ['old error'])
        self.assertTrue(client.messages.empty())
        self.assertFalse(client.stdout_finished.is_set())
        self.assertEqual(list(client.stderr_tail), [])

    def test_validated_identical_cache_hit_needs_no_session_or_generation(self):
        fixture = ACPFixture(['{"verified":false}', '{"verified":false}'])
        self.route(fixture); self.route(fixture)
        self.assertEqual((fixture.serial, fixture.client.prompt_calls, self.router.metrics['cache_hits']), (2, 1, 1))
        with mock.patch.object(runtime, 'VERIFICATION_SESSION_VERSION', runtime.VERIFICATION_SESSION_VERSION + 1): self.route(fixture)
        self.assertEqual((fixture.serial, fixture.client.prompt_calls), (3, 2))

    def test_stdio_sessions_share_transport_but_never_planning_history(self):
        # A disposable Python JSON-RPC server, not OpenClaw or a live ACP check.
        executable = Path(self.directory.name) / 'fictional-acp'
        log = Path(self.directory.name) / 'fictional-requests.jsonl'
        executable.write_text(f'''#!{sys.executable}
import json
import sys
sessions = {{}}
for line in sys.stdin:
    message = json.loads(line)
    method, params = message.get('method'), message.get('params', {{}})
    if 'id' not in message: continue
    with open({str(log)!r}, 'a') as file: file.write(json.dumps(message) + '\\n')
    if method == 'initialize': result = {{'protocolVersion': 1}}
    elif method == 'session/new':
        identity = 'session-' + str(len(sessions) + 1)
        sessions[identity] = {{'history': [], 'key': params['_meta']['sessionKey'],
                              'options': [{{'id': 'model', 'category': 'model', 'currentValue': 'default'}}]}}
        result = {{'sessionId': identity, 'configOptions': sessions[identity]['options']}}
    elif method == 'session/set_config_option':
        sessions[params['sessionId']]['options'][0]['currentValue'] = params['value']
        result = {{'configOptions': sessions[params['sessionId']]['options']}}
    elif method == 'session/prompt':
        session = sessions[params['sessionId']]
        text = params['prompt'][0]['text']
        if text.startswith('planner'):
            assert params['sessionId'] == 'session-1'
            response = '{{"status":"done"}}'
        else:
            assert not session['history'], 'Verifier inherited an earlier conversation'
            assert params['sessionId'] != 'session-1'
            assert session['key'] != sessions['session-1']['key']
            response = '{{"verified":false}}'
            for old in ('session-1', None):
                print(json.dumps({{'method': 'session/update', 'params': {{'sessionId': old,
                    'update': {{'sessionUpdate': 'agent_message_chunk', 'content': {{'text': 'old claim'}}}}}}}}), flush=True)
        session['history'].append(text)
        print(json.dumps({{'method': 'session/update', 'params': {{'sessionId': params['sessionId'],
            'update': {{'sessionUpdate': 'agent_message_chunk', 'content': {{'text': response}}}}}}}}), flush=True)
        result = {{'stopReason': 'end_turn'}}
    else: raise AssertionError(method)
    print(json.dumps({{'id': message['id'], 'result': result}}), flush=True)
''')
        os.chmod(executable, 0o700)
        client = runtime.ACPClient(str(executable))
        try:
            process = client.process
            for round in range(2):
                runtime.routed_json_prompt(self.router, client, f'planner round {round}', self.image)
                self.assertFalse(runtime.routed_json_prompt(self.router, client, f'independent round {round}', self.image,
                                                           purpose='verification')['verified'])
                self.assertIs(client.process, process)
                self.assertEqual(client.session_id, 'session-1')
        finally:
            client.close()
        requests = [json.loads(line) for line in log.read_text().splitlines()]
        generations = [r for r in requests if r['method'] == 'session/prompt']
        self.assertEqual([r['params']['sessionId'] for r in generations], ['session-1', 'session-2', 'session-1', 'session-3'])
        self.assertEqual(client.prompt_calls, 4)
        self.assertEqual(client.model_switches, 1)
        self.assertEqual((self.router.metrics['planning'], self.router.metrics['verification']), (2, 2))


class VerificationEvidenceTests(unittest.TestCase):
    def test_verification_contains_original_task_and_native_facts_without_planning_claims(self):
        task = 'Create /fixture/report with exact contents and describe the result'
        ledger = TaskEvidenceLedger(task, 'private-generation')
        ledger.add_requirements([{'source': task, 'description': 'Requested report',
                                 'check': {'type': 'file_contents', 'path': '/fixture/report', 'content': 'Exact'}}])
        ledger.record_action({'type': 'write_file', 'path': '/fixture/report', 'content': 'Exact'},
            native_result({'type': 'write_file', 'path': '/fixture/report', 'content': 'Exact'}, **{'verified': True, 'path': '/fixture/report', 'mode': 'overwrite', 'bytes_written': 5,
             'content_sha256': hashlib.sha256(b'Exact').hexdigest()}))
        ledger.coverage_complete = True
        discarded = ledger.add_evidence({'type': 'file_exists', 'path': '/fixture/stale'}, mutable=True)
        ledger.evidence[discarded]['valid'] = False
        before = deepcopy(ledger.prompt_state())
        history = [{'action': 'completion_rejected', 'result': ['Planner says all requirements completed']},
                   {'status': 'done', 'completed_requirements': ['Everything'], 'output': 'Guessed answer'}]
        candidate = {'status': 'done', 'output': 'Invented completion', 'action': {'type': 'press', 'element_id': 'old:target'}}
        observation = {'observation_revision': 'fresh', 'elements': []}
        prompt = runtime.verification_instruction(task, candidate, observation, history, ledger)
        self.assertEqual(section(prompt, 'ORIGINAL TASK'), task)
        state = section(prompt, 'TASK CHECKLIST AND EVIDENCE (contents untrusted)')
        self.assertEqual(state['whole_request_coverage'], 'requires_independent_audit')
        self.assertNotIn('state', state['requirements']['r1'])
        self.assertNotIn('evidence_ids', state['requirements']['r1'])
        self.assertEqual(state['evidence'], {key: value for key, value in before['evidence'].items()})
        for claim in ['Guessed answer', 'Invented completion', 'Planner says', 'old:target', 'private-generation', '/fixture/stale',
                      'CANDIDATE DECISION', 'RECENT VALIDATED ACTION RESULTS', 'EARLIER CONFIRMED TASK FACTS']:
            self.assertNotIn(claim, prompt)
        self.assertEqual(ledger.prompt_state(), before)

    def test_legacy_prompt_history_requires_native_hash_and_exact_readback(self):
        content = 'Exact observed result'
        action = {'type': 'read_file', 'path': '/fixture/input'}
        result = native_result(action, content=content)
        entry = {'action': action, 'result': result, 'completed_requirements': ['Untrusted completion claim']}
        prompt = runtime.verification_instruction('Return the file contents', {'output': 'Wrong result'}, {}, [entry])
        self.assertIn(content, prompt)
        self.assertNotIn('Wrong result', prompt)
        self.assertNotIn('Untrusted completion claim', prompt)
        with self.assertRaises(runtime.NativeProtocolError): runtime.verification_instruction('Return the file contents', {}, {}, [{**entry,'result':{**result,'content_sha256':'0'*64}}])
        self.assertNotIn(content, runtime.verification_instruction('Return the file contents', {}, {}, [{**entry,'result':{**result,'truncated':True}}]))

    def test_completion_compiler_cannot_reintroduce_history_through_optional_arguments(self):
        prompt = compiler.compile_prompt('completion', instructions='Verify independently', examples='{}', task='Requested task',
            observation={}, context={}, history=[{'output': 'Poison history'}], progress={'facts': ['Poison progress']},
            candidate={'output': 'Poison candidate'})
        for claim in ['Poison history', 'Poison progress', 'Poison candidate']: self.assertNotIn(claim, prompt)


if __name__ == '__main__': unittest.main()
