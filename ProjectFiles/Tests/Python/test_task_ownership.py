import contextlib
import io
import json
from pathlib import Path
import sys
import unittest
from unittest import mock
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
from evidence_fixtures import native_result
import openclaw_runtime as runtime
from coordinate_fixtures import fixture_coordinates
from action_contract_generated import CONTRACT_HASH, CONTRACT_VERSION, TASK_PROTOCOL_VERSION


class TaskOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.generation = str(uuid.uuid4())
        self.inbox = mock.patch.object(runtime, '_runtime_inbox', None)
        self.inbox.start(); self.addCleanup(self.inbox.stop)
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
            {'kind': 'bridge_response', 'request_id': 'same', 'task_generation_id': 'old', 'working_document_revision': 0, 'ok': True, 'result': {'observation_revision': 'old'}},
            {'kind': 'bridge_response', 'request_id': 'same', 'task_generation_id': self.generation, 'working_document_revision': 0, 'ok': True,
             'result': {**fixture, 'task_generation_id': self.generation, 'observation_revision': 'current', 'elements': []}},
        ]
        with mock.patch.object(runtime.uuid, 'uuid4', return_value='same'), mock.patch.object(sys, 'stdin', io.StringIO('\n'.join(map(json.dumps, replies)))), mock.patch.object(runtime, 'emit') as emit:
            result = runtime.bridge_call('observe', 1)
        self.assertEqual(runtime._bridge_observation_revision, 'current')
        self.assertNotIn('task_generation_id', result)  # Not model evidence.
        self.assertEqual(emit.call_count, 1)
        action_id='a710196f-89ed-4762-8df1-1b8b6f20db58'
        action={'type':'focus','element_id':'current:field'}
        action_reply = {**replies[1], 'request_id':action_id,'result':native_result(action), 'action_receipt': {'action_id':action_id,'state':'confirmed','terminal':True}}
        with mock.patch.object(runtime.uuid, 'uuid4', return_value=action_id), mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(action_reply))), mock.patch.object(runtime, 'emit') as emit:
            runtime.bridge_call('act', 1, action=action)
        self.assertEqual(emit.call_args.kwargs['params']['observation_revision'], 'current')

    def test_cross_task_observation_never_reaches_planning(self):
        reply = dict(kind='bridge_response', request_id='same', task_generation_id=self.generation, working_document_revision=0, ok=True,
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
        config = dict(kind='runtime_configuration', gemini_api_key='', action_contract_hash=CONTRACT_HASH,
            action_contract_version=CONTRACT_VERSION, instruction_revision=0,
            task_protocol_version=TASK_PROTOCOL_VERSION,
            stop_boundary_policy_version=runtime.STOP_BOUNDARY_POLICY_VERSION,
            native_action_policy_version=runtime.NATIVE_ACTION_POLICY_VERSION,
            coordinate_mapping_version=runtime.COORDINATE_MAPPING_VERSION,
            observation_completeness_version=runtime.OBSERVATION_COMPLETENESS_VERSION,
            text_recognition_version=runtime.TEXT_RECOGNITION_VERSION,
            evidence_consistency_version=runtime.EVIDENCE_CONSISTENCY_VERSION,
            wait_presentation_version=runtime.WAIT_PRESENTATION_VERSION,
            command_capability_version=runtime.COMMAND_CAPABILITY_VERSION,
            exact_input_reference_version=runtime.EXACT_INPUT_REFERENCE_VERSION,
            continuation_checkpoint_version=runtime.CONTINUATION_CHECKPOINT_VERSION,
            exact_input_references=[], working_document_protocol_version=runtime.WORKING_DOCUMENT_PROTOCOL_VERSION,
            target_choice_protocol_version=runtime.TARGET_CHOICE_PROTOCOL_VERSION)
        for invalid in [None, '', 'old', True, 7]:
            with self.subTest(invalid=invalid), mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(dict(config, task_generation_id=invalid)))):
                with self.assertRaisesRegex(RuntimeError, 'generation ID'): runtime.read_runtime_configuration(require_generation=True)
        with mock.patch.object(runtime.RuntimeInbox, 'register_instruction_corrections',
                               return_value=('instruction_correction', None, self.generation)), \
             mock.patch.object(runtime.RuntimeInbox, 'register_working_document_updates',
                               return_value=('working_document_update', None, self.generation)), \
             mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(dict(config, task_generation_id=self.generation)))):
            runtime.read_runtime_configuration(require_generation=True)
        self.assertEqual(runtime._task_generation_id, self.generation)
        self.assertEqual(runtime._exact_input_references, [])

    def test_startup_requires_matching_wait_presentation_version(self):
        config = dict(kind='runtime_configuration', gemini_api_key='', action_contract_hash=CONTRACT_HASH,
            action_contract_version=CONTRACT_VERSION, task_protocol_version=runtime.TASK_PROTOCOL_VERSION,
            stop_boundary_policy_version=runtime.STOP_BOUNDARY_POLICY_VERSION,
            native_action_policy_version=runtime.NATIVE_ACTION_POLICY_VERSION,
            task_generation_id=self.generation, instruction_revision=0, coordinate_mapping_version=runtime.COORDINATE_MAPPING_VERSION,
            observation_completeness_version=runtime.OBSERVATION_COMPLETENESS_VERSION,
            text_recognition_version=runtime.TEXT_RECOGNITION_VERSION,
            evidence_consistency_version=runtime.EVIDENCE_CONSISTENCY_VERSION,
            wait_presentation_version=runtime.WAIT_PRESENTATION_VERSION,
            command_capability_version=runtime.COMMAND_CAPABILITY_VERSION,
            exact_input_reference_version=runtime.EXACT_INPUT_REFERENCE_VERSION,
            continuation_checkpoint_version=runtime.CONTINUATION_CHECKPOINT_VERSION, exact_input_references=[])
        config["working_document_protocol_version"] = runtime.WORKING_DOCUMENT_PROTOCOL_VERSION
        for version in [None, True, '1', 0, runtime.WAIT_PRESENTATION_VERSION + 1]:
            with self.subTest(version=version), mock.patch.object(sys, 'stdin', io.StringIO(
                    json.dumps(dict(config, wait_presentation_version=version)))):
                with self.assertRaisesRegex(RuntimeError, 'wait presentation versions'):
                    runtime.read_runtime_configuration(require_generation=True)
        for invalid in [None, True, '1', 0]:
            with self.subTest(protocol=invalid), mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(dict(config, task_generation_id=self.generation, task_protocol_version=invalid)))):
                with self.assertRaisesRegex(RuntimeError, 'protocol does not match'): runtime.read_runtime_configuration(require_generation=True)
        runtime._bridge_observation_revision = 'old'
        with mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(config))): runtime.read_runtime_configuration()
        self.assertIsNone(runtime._task_generation_id)
        self.assertIsNone(runtime._bridge_observation_revision)
        self.assertEqual(runtime._exact_input_references, [])

    def test_startup_requires_matching_stop_boundary_policy_version(self):
        config = dict(kind='runtime_configuration', gemini_api_key='', action_contract_hash=CONTRACT_HASH,
            action_contract_version=CONTRACT_VERSION, task_protocol_version=TASK_PROTOCOL_VERSION,
            stop_boundary_policy_version=runtime.STOP_BOUNDARY_POLICY_VERSION,
            native_action_policy_version=runtime.NATIVE_ACTION_POLICY_VERSION,
            task_generation_id=self.generation, instruction_revision=0,
            coordinate_mapping_version=runtime.COORDINATE_MAPPING_VERSION,
            observation_completeness_version=runtime.OBSERVATION_COMPLETENESS_VERSION,
            text_recognition_version=runtime.TEXT_RECOGNITION_VERSION,
            evidence_consistency_version=runtime.EVIDENCE_CONSISTENCY_VERSION,
            wait_presentation_version=runtime.WAIT_PRESENTATION_VERSION,
            command_capability_version=runtime.COMMAND_CAPABILITY_VERSION,
            exact_input_reference_version=runtime.EXACT_INPUT_REFERENCE_VERSION,
            exact_input_references=[], working_document_protocol_version=runtime.WORKING_DOCUMENT_PROTOCOL_VERSION)
        for version in [None, True, '1', 0, runtime.STOP_BOUNDARY_POLICY_VERSION + 1]:
            with self.subTest(version=version), mock.patch.object(sys, 'stdin', io.StringIO(
                    json.dumps(dict(config, stop_boundary_policy_version=version)))):
                with self.assertRaisesRegex(RuntimeError, 'stop-before boundary policies'):
                    runtime.read_runtime_configuration(require_generation=True)

    def test_startup_requires_matching_native_action_policy_version(self):
        config = dict(kind='runtime_configuration', gemini_api_key='', action_contract_hash=CONTRACT_HASH,
            action_contract_version=CONTRACT_VERSION, task_protocol_version=TASK_PROTOCOL_VERSION,
            stop_boundary_policy_version=runtime.STOP_BOUNDARY_POLICY_VERSION,
            native_action_policy_version=runtime.NATIVE_ACTION_POLICY_VERSION,
            task_generation_id=self.generation, instruction_revision=0,
            coordinate_mapping_version=runtime.COORDINATE_MAPPING_VERSION,
            observation_completeness_version=runtime.OBSERVATION_COMPLETENESS_VERSION,
            text_recognition_version=runtime.TEXT_RECOGNITION_VERSION,
            evidence_consistency_version=runtime.EVIDENCE_CONSISTENCY_VERSION,
            wait_presentation_version=runtime.WAIT_PRESENTATION_VERSION,
            command_capability_version=runtime.COMMAND_CAPABILITY_VERSION,
            exact_input_reference_version=runtime.EXACT_INPUT_REFERENCE_VERSION,
            continuation_checkpoint_version=runtime.CONTINUATION_CHECKPOINT_VERSION,
            exact_input_references=[], working_document_protocol_version=runtime.WORKING_DOCUMENT_PROTOCOL_VERSION)
        for version in [None, True, '1', 0, runtime.NATIVE_ACTION_POLICY_VERSION + 1]:
            with self.subTest(version=version), mock.patch.object(sys, 'stdin', io.StringIO(
                    json.dumps(dict(config, native_action_policy_version=version)))):
                with self.assertRaisesRegex(RuntimeError, 'native action policy versions'):
                    runtime.read_runtime_configuration(require_generation=True)

    def test_startup_requires_versioned_bounded_reference_metadata(self):
        config = dict(kind='runtime_configuration', gemini_api_key='', action_contract_hash=CONTRACT_HASH,
            action_contract_version=CONTRACT_VERSION, task_protocol_version=TASK_PROTOCOL_VERSION,
            stop_boundary_policy_version=runtime.STOP_BOUNDARY_POLICY_VERSION,
            native_action_policy_version=runtime.NATIVE_ACTION_POLICY_VERSION,
            task_generation_id=self.generation, instruction_revision=0, coordinate_mapping_version=runtime.COORDINATE_MAPPING_VERSION,
            observation_completeness_version=runtime.OBSERVATION_COMPLETENESS_VERSION,
            text_recognition_version=runtime.TEXT_RECOGNITION_VERSION,
            evidence_consistency_version=runtime.EVIDENCE_CONSISTENCY_VERSION,
            wait_presentation_version=runtime.WAIT_PRESENTATION_VERSION,
            command_capability_version=runtime.COMMAND_CAPABILITY_VERSION,
            exact_input_reference_version=runtime.EXACT_INPUT_REFERENCE_VERSION,
            continuation_checkpoint_version=runtime.CONTINUATION_CHECKPOINT_VERSION, exact_input_references=[])
        config["working_document_protocol_version"] = runtime.WORKING_DOCUMENT_PROTOCOL_VERSION
        for version in [None, True, 0, runtime.EXACT_INPUT_REFERENCE_VERSION + 1]:
            with self.subTest(version=version), mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(
                    dict(config, exact_input_reference_version=version)))):
                with self.assertRaisesRegex(RuntimeError, 'exact-input reference versions'):
                    runtime.read_runtime_configuration(require_generation=True)
        for references in [None, {}, [None] * 129]:
            with self.subTest(references=type(references).__name__), mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(
                    dict(config, exact_input_references=references)))):
                with self.assertRaisesRegex(RuntimeError, 'invalid exact-input reference metadata'):
                    runtime.read_runtime_configuration(require_generation=True)
