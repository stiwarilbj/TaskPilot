import base64
import copy
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
import request_policy as policy
from coordinate_fixtures import fixture_coordinates
from local_text_recognition import (TextRecognitionError, validate_text_recognition,
                                    prompt_text_recognition, coordinate_text_target)
from response_validation import normalize_action, ResponseValidationError
from test_response_validation import FakeClient


def png(width, height):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + \
        chunk(b'IDAT', zlib.compress((b'\0' + b'\xff' * width * 3) * height)) + chunk(b'IEND', b'')


def observation(crop=True):
    value = dict(fixture_coordinates('current'), observation_revision='current', elements=[],
                 applications=[dict(pid=42, name='Editor', graphics_windows=[dict(id=7,
                    frame=dict(x=0, y=0, width=1440, height=900))])])
    target = dict(candidate_id='current:text:0', text='Save', confidence=0.99, provisional=True,
                  pid=42, graphics_window_id=7, repeated_text_count=1,
                  frame=dict(x=144, y=90, width=144, height=45),
                  image_bounds=dict(x=288, y=180, width=288, height=90),
                  normalized_bounds=dict(x=100, y=100, width=100, height=50))
    crops = [dict(candidate_text='Save', pid=42, graphics_window_id=7, mime_type='image/png',
                  data=base64.b64encode(png(320, 160)).decode(), image_size=dict(width=320, height=160),
                  image_to_global=dict(x_scale=0.5, y_scale=0.5, x_offset=140, y_offset=80))] if crop else []
    value['text_recognition'].update(state='recognized', targets=[target], detail_crops=crops)
    return value


class CropClient(FakeClient):
    def prompt(self, instruction, image, *, detail_images=None):
        self.images = getattr(self, 'images', []) + [copy.deepcopy(detail_images)]
        return super().prompt(instruction, image)


class LocalTextRecognitionTests(unittest.TestCase):
    def test_valid_recognition_is_provisional_and_never_an_accessibility_element(self):
        value = observation()
        self.assertEqual(validate_text_recognition(value, required=True), value['text_recognition'])
        self.assertEqual(value['elements'], [])
        action = dict(type='click', pid=42, x=150, y=125)
        self.assertEqual(normalize_action(action, value), action)
        with self.assertRaisesRegex(ResponseValidationError, 'current observation'):
            normalize_action(dict(type='press', element_id='current:text:0'), value)

    def test_prompts_include_context_and_crop_mapping_without_image_bytes(self):
        value = observation()
        before = copy.deepcopy(value)
        prompt = runtime.desktop_instruction('Click Save', value, [])
        self.assertIn('Vision text targets are provisional', prompt)
        self.assertIn('not element_id or control roles', prompt)
        self.assertIn('"graphics_window_id":7', prompt)
        self.assertIn('"normalized_bounds"', prompt)
        self.assertIn('"image_to_global"', prompt)
        self.assertNotIn(value['text_recognition']['detail_crops'][0]['data'], prompt)
        self.assertEqual(value, before)
        final = runtime.verification_instruction('Save', dict(status='done'), value, [])
        self.assertIn('not proof of control role', final)

    def test_stale_ownership_types_confidence_and_coordinates_are_rejected(self):
        changes = [dict(candidate_id='old:text:0'), dict(provisional=False), dict(provisional=1),
                   dict(pid=43), dict(pid=True), dict(graphics_window_id=8), dict(confidence=True),
                   dict(confidence='0.9'), dict(confidence=float('nan')), dict(confidence=0.1),
                   dict(text=''), dict(text='x'*257), dict(repeated_text_count=True), dict(repeated_text_count=2),
                   dict(normalized_bounds=dict(x=101, y=100, width=100, height=50)),
                   dict(frame=dict(x=-1, y=90, width=144, height=45))]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(TextRecognitionError):
                value = observation(); value['text_recognition']['targets'][0].update(change)
                validate_text_recognition(value)
        for change in [dict(version=True), dict(version=2), dict(state='verified'),
                       dict(observation_revision='old'), dict(state='not_needed')]:
            value = observation(); value['text_recognition'].update(change)
            with self.assertRaises(TextRecognitionError): validate_text_recognition(value)

    def test_crops_have_bounded_valid_image_bytes_mapping_and_current_targets(self):
        changes = [dict(data='bad'), dict(data='A'*700000), dict(data=True), dict(mime_type='image/jpeg'),
                   dict(candidate_text='Other'), dict(pid=43), dict(graphics_window_id=8),
                   dict(image_size=dict(width=True, height=160)), dict(image_size=dict(width=321, height=160)),
                   dict(image_to_global=dict(x_scale=-1, y_scale=1, x_offset=140, y_offset=80)),
                   dict(image_to_global=dict(x_scale=1, y_scale=1, x_offset=1200, y_offset=80)),
                   dict(image_to_global=dict(x_scale=0.1, y_scale=0.1, x_offset=140, y_offset=80))]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(TextRecognitionError):
                value = observation(); value['text_recognition']['detail_crops'][0].update(change)
                validate_text_recognition(value)
        value = observation(); value['text_recognition']['detail_crops'] *= 3
        with self.assertRaises(TextRecognitionError): validate_text_recognition(value)

    def test_repeated_save_labels_are_distinct_and_overlapping_candidates_rejected(self):
        value = observation(False)
        rows = value['text_recognition']['targets']
        rows.append(dict(copy.deepcopy(rows[0]), candidate_id='current:text:1'))
        for row in rows: row['repeated_text_count'] = 2
        validate_text_recognition(value)
        with self.assertRaisesRegex(ResponseValidationError, 'overlap provisional text'):
            normalize_action(dict(type='click', pid=42, x=150, y=125), value)
        rows[1].update(frame=dict(x=720, y=90, width=144, height=45),
                       image_bounds=dict(x=1440, y=180, width=288, height=90),
                       normalized_bounds=dict(x=500, y=100, width=100, height=50))
        self.assertEqual(coordinate_text_target(dict(type='click', pid=42, x=550, y=125), value)['candidate_id'], 'current:text:1')

    def test_low_confidence_cannot_be_used_for_clicks_or_secure_input(self):
        value = observation(False); value['text_recognition']['targets'][0]['confidence'] = 0.6
        with self.assertRaisesRegex(ResponseValidationError, 'low-confidence'):
            normalize_action(dict(type='click', pid=42, x=150, y=125), value)
        value['elements'] = [dict(id='native:secret', pid=42, role='AXSecureTextField')]
        with self.assertRaisesRegex(TextRecognitionError, 'Secure app text'):
            validate_text_recognition(value)

    def test_element_precedence_and_other_actions_do_not_use_text_candidates(self):
        value = observation(False)
        value['elements'] = [dict(id='native:save', pid=42, role='AXButton')]
        self.assertEqual(normalize_action(dict(type='click', element_id='native:save', x='bad', y=True), value),
                         dict(type='press', element_id='native:save'))
        self.assertIsNone(coordinate_text_target(dict(type='scroll', pid=42, delta_y=-10), value))

    def test_healthy_and_repaired_decisions_attach_same_crops_in_existing_calls(self):
        value = observation()
        good = json.dumps(dict(status='act', action=dict(type='click', pid=42, x=150, y=125)))
        for responses, expected in [([good], 1), (['{"status":"act"}', good], 2)]:
            with tempfile.TemporaryDirectory() as directory, mock.patch.object(runtime, 'emit'):
                image = Path(directory) / 'image.png'; image.write_bytes(png(10, 10))
                client = CropClient(responses)
                router = policy.AdaptiveModelRouter(lambda *a, **k: None, sleep=lambda _: None)
                with mock.patch.object(runtime, 'bridge_call') as bridge:
                    result = runtime.routed_json_prompt(router, client, runtime.desktop_instruction('Click Save', value, []), image, 'planning', value)
                self.assertEqual(result['action']['type'], 'click')
                self.assertEqual(client.prompt_calls, expected)
                self.assertEqual(router.metrics['planning'], expected)
                self.assertEqual(router.metrics['repairs'], expected-1)
                self.assertTrue(all(images == value['text_recognition']['detail_crops'] for images in client.images))
                bridge.assert_not_called()

    def test_acp_uses_standard_image_blocks_in_one_terminal_request(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'image.png'; path.write_bytes(png(10, 10))
            client = runtime.ACPClient.__new__(runtime.ACPClient)
            client._run_prompt = mock.Mock(return_value=({}, '{"status":"done"}'))
            client.prompt('contract', path, detail_images=observation()['text_recognition']['detail_crops'])
            self.assertEqual(client._run_prompt.call_count, 1)
            blocks = client._run_prompt.call_args.args[0]
            self.assertEqual([b['type'] for b in blocks], ['text', 'image', 'text', 'image'])
            self.assertEqual(blocks[-1]['mimeType'], 'image/png')

    def test_missing_and_invalid_native_report_never_reach_a_model(self):
        value = observation(False)
        for report in [None, dict(value['text_recognition'], observation_revision='old')]:
            reply = {**value, 'task_generation_id': 'task', 'text_recognition': report}
            with mock.patch.object(runtime, '_task_generation_id', 'task'), \
                 mock.patch.object(runtime, '_bridge_observation_revision', 'old'), \
                 mock.patch.object(runtime, 'bridge_exchange', return_value=dict(ok=True, result=reply)), \
                 mock.patch.object(runtime.ACPClient, 'prompt') as prompt:
                with self.assertRaises(runtime.ActionRejected): runtime.bridge_call('observe', 1)
                self.assertIsNone(runtime._bridge_observation_revision); prompt.assert_not_called()

    def test_not_needed_and_legacy_fixtures_do_not_expand_prompt_or_calls(self):
        value = dict(fixture_coordinates('current'), observation_revision='current', elements=[])
        self.assertIsNone(prompt_text_recognition(value))
        self.assertNotIn('text_recognition', runtime.compact_observation(value))
        self.assertIsNone(validate_text_recognition(dict(elements=[])))
        with self.assertRaises(TextRecognitionError): validate_text_recognition(dict(elements=[]), required=True)

    def test_startup_rejects_text_version_mismatches_before_model_requests(self):
        config = dict(kind='runtime_configuration', gemini_api_key='', action_contract_hash=runtime.CONTRACT_HASH,
            action_contract_version=runtime.CONTRACT_VERSION, instruction_revision=0, task_protocol_version=runtime.TASK_PROTOCOL_VERSION,
            stop_boundary_policy_version=runtime.STOP_BOUNDARY_POLICY_VERSION,
            task_generation_id='d0b9c0fc-01af-42f0-b749-1027c907a2cd', coordinate_mapping_version=1, observation_completeness_version=1)
        for version in (None, True, '1', 2):
            with mock.patch.object(runtime, 'runtime_line', return_value=json.dumps(dict(config, text_recognition_version=version))):
                with self.assertRaisesRegex(RuntimeError, 'text recognition versions'):
                    runtime.read_runtime_configuration(require_generation=True)
        runtime._task_generation_id = None
