import contextlib
import io
import json
from pathlib import Path
import sys
import unittest
from unittest import mock
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
from coordinate_fixtures import fixture_coordinates
from action_contract_generated import CONTRACT_HASH, CONTRACT_VERSION, TASK_PROTOCOL_VERSION


class TaskOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.generation = str(uuid.uuid4())
        self.patch = mock.patch.object(runtime, '_task_generation_id', self.generation)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.revision = mock.patch.object(runtime, '_bridge_observation_revision', None)
        self.revision.start(); self.addCleanup(self.revision.stop)

    def test_every_task_message_carries_generation_without_altering_payload(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            for kind in ['status', 'output', 'model_health', 'request_metrics', 'bridge_request', 'user_input_required', 'error', 'complete']:
                runtime.emit(kind, message='fixture')
        for message in map(json.loads, output.getvalue().splitlines()):
            self.assertEqual(message['task_generation_id'], self.generation)
            self.assertEqual(message['message'], 'fixture')

    def test_cross_task_bridge_reply_is_ignored_and_observation_is_bound(self):
        fixture = fixture_coordinates('current')
        replies = [
            {'kind': 'bridge_response', 'request_id': 'same', 'task_generation_id': 'old', 'ok': True, 'result': {'observation_revision': 'old'}},
            {'kind': 'bridge_response', 'request_id': 'same', 'task_generation_id': self.generation, 'ok': True,
             'result': {**fixture, 'task_generation_id': self.generation, 'observation_revision': 'current', 'elements': []}},
        ]
        with mock.patch.object(runtime.uuid, 'uuid4', return_value='same'), mock.patch.object(sys, 'stdin', io.StringIO('\n'.join(map(json.dumps, replies)))), mock.patch.object(runtime, 'emit') as emit:
            result = runtime.bridge_call('observe', 1)
        self.assertEqual(runtime._bridge_observation_revision, 'current')
        self.assertNotIn('task_generation_id', result)  # Not model evidence.
        self.assertEqual(emit.call_count, 1)
        action_reply = {**replies[1], 'action_receipt': {'action_id': 'same', 'state': 'confirmed', 'terminal': True}}
        with mock.patch.object(runtime.uuid, 'uuid4', return_value='same'), mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(action_reply))), mock.patch.object(runtime, 'emit') as emit:
            runtime.bridge_call('act', 1, action={'type': 'none'})
        self.assertEqual(emit.call_args.kwargs['params']['observation_revision'], 'current')

    def test_cross_task_observation_never_reaches_planning(self):
        reply = dict(kind='bridge_response', request_id='same', task_generation_id=self.generation, ok=True,
                     result=dict(task_generation_id='old', observation_revision='old'))
        with mock.patch.object(runtime.uuid, 'uuid4', return_value='same'), mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(reply))), mock.patch.object(runtime, 'emit'):
            with self.assertRaises(runtime.ActionRejected): runtime.bridge_call('observe', 1)
        self.assertIsNone(runtime._bridge_observation_revision)

    def test_secure_input_requires_matching_generation_and_request(self):
        responses = [dict(kind='user_input_response', request_id='same', task_generation_id='old', value='wrong'),
                     dict(kind='user_input_response', request_id='different', task_generation_id=self.generation, value='wrong'),
                     dict(kind='user_input_response', request_id='same', task_generation_id=self.generation, value='current')]
        with mock.patch.object(sys, 'stdin', io.StringIO('\n'.join(map(json.dumps, responses)))):
            self.assertEqual(runtime.wait_for_user_input('same'), 'current')

    def test_startup_requires_valid_generation_only_for_tasks_and_clears_old_state(self):
        config = dict(kind='runtime_configuration', gemini_api_key='', action_contract_hash=CONTRACT_HASH, action_contract_version=CONTRACT_VERSION, task_protocol_version=TASK_PROTOCOL_VERSION, coordinate_mapping_version=runtime.COORDINATE_MAPPING_VERSION, observation_completeness_version=runtime.OBSERVATION_COMPLETENESS_VERSION, text_recognition_version=runtime.TEXT_RECOGNITION_VERSION, evidence_consistency_version=runtime.EVIDENCE_CONSISTENCY_VERSION)
        for invalid in [None, '', 'old', True, 7]:
            with self.subTest(invalid=invalid), mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(dict(config, task_generation_id=invalid)))):
                with self.assertRaisesRegex(RuntimeError, 'generation ID'): runtime.read_runtime_configuration(require_generation=True)
        with mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(dict(config, task_generation_id=self.generation)))):
            runtime.read_runtime_configuration(require_generation=True)
        self.assertEqual(runtime._task_generation_id, self.generation)
        for invalid in [None, True, '1', 0]:
            with self.subTest(protocol=invalid), mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(dict(config, task_generation_id=self.generation, task_protocol_version=invalid)))):
                with self.assertRaisesRegex(RuntimeError, 'protocol does not match'): runtime.read_runtime_configuration(require_generation=True)
        runtime._bridge_observation_revision = 'old'
        with mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(config))): runtime.read_runtime_configuration()
        self.assertIsNone(runtime._task_generation_id)
        self.assertIsNone(runtime._bridge_observation_revision)
