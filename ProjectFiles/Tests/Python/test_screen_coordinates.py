import copy
import json
from pathlib import Path
import sys
import unittest
from unittest import mock
from coordinate_fixtures import fixture_coordinates

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'AgentRuntime'))
import openclaw_runtime as runtime
from observation_context import coordinate_targets
from response_validation import normalize_action
from screen_coordinates import (COORDINATE_MAPPING_VERSION, CoordinateMappingError,
                                action_global_point, image_global_point, image_action_point,
                                validate_observation_mapping)


def fixtures():
    return json.loads((ROOT / 'Tests/Fixtures/screen-coordinate-cases.json').read_text())['cases']


class ScreenCoordinatesTests(unittest.TestCase):
    def assert_point(self, actual, expected):
        for a, b in zip(actual, expected): self.assertAlmostEqual(a, b, places=8)

    def test_same_native_corpus_maps_pixels_and_normalized_targets(self):
        for case in fixtures():
            with self.subTest(case=case['name']):
                validate_observation_mapping(case, required=True)
                action = dict(type='click', pid=42, x=case['normalized'][0], y=case['normalized'][1])
                self.assert_point(action_global_point(action, case), case['global'])
                self.assert_point(image_global_point(case['pixel'], case), case['global'])
                self.assert_point(image_action_point(case['pixel'], case), case['normalized'])

    def test_hit_matching_uses_native_mapping_instead_of_pixel_values(self):
        for case in fixtures():
            x, y = case['global']
            case['applications'] = [{'pid': 42}]
            case['elements'] = [dict(id='correct:save', pid=42, role='AXButton', title='Save',
                                    frame=dict(x=x-10, y=y-10, width=20, height=20)),
                                dict(id='wrong:save', pid=42, role='AXButton', title='Save',
                                     frame=dict(x=x+40, y=y+40, width=20, height=20))]
            action = dict(type='click', pid=42, x=case['normalized'][0], y=case['normalized'][1])
            self.assertEqual([e['id'] for e in coordinate_targets(action, case)], ['correct:save'])
            self.assertEqual(normalize_action(action, case), action)
            # An explicit element keeps precedence; no image-to-action rewrite.
            explicit = dict(type='click', element_id='correct:save', x=99, y=99)
            self.assertEqual(normalize_action(explicit, case)['element_id'], 'correct:save')

    def test_crop_edges_remain_full_display_action_coordinates(self):
        case = fixtures()[4]
        self.assert_point(image_action_point((0, 0), case), (250, 250))
        self.assert_point(image_action_point((512, 320), case), (750, 750))
        for point in [(-1, 0), (513, 0), (0, 321), (True, 2), ('1', 2), (float('nan'), 2)]:
            with self.assertRaises(CoordinateMappingError): image_global_point(point, case)

    def test_edge_events_stay_inside_even_with_zero_global_maximum(self):
        for case in fixtures():
            d = case['display']
            actual = action_global_point(dict(x=1000, y=1000), case)
            self.assertEqual(actual, (d['x'] + d['width'] - 0.5, d['y'] + d['height'] - 0.5))
        observation = {'display': dict(x=-1920, y=-1080, width=1920, height=1080)}
        self.assertEqual(action_global_point(dict(x=1000, y=1000), observation), (-0.5, -0.5))

    def test_bad_metadata_is_rejected_instead_of_guessed_or_ignored(self):
        original = fixtures()[0]
        changes = [('version', 2), ('version', True), ('axes', 'appkit_bottom_left'),
                   ('normalized_extent', True), ('normalized_extent', 1), ('display_id', 2),
                   ('display_id', True), ('observation_revision', 'old'), ('edge_inset_points', 0),
                   ('image_size', dict(width=True, height=10)), ('image_size', dict(width='10', height=10)),
                   ('image_size', dict(width=1.5, height=10)), ('image_size', dict(width=0, height=10)),
                   ('full_image_size', dict(width=10, height=10)),
                   ('source_rect', dict(x=-1, y=0, width=10, height=10)),
                   ('source_rect', dict(x=0, y=0, width=10000, height=10)),
                   ('display_bounds', dict(x=1, y=0, width=1440, height=900)),
                   ('normalized_to_global', dict(x_scale=2, y_scale=2, x_offset=0, y_offset=0)),
                   ('image_to_global', dict(x_scale=float('inf'), y_scale=1, x_offset=0, y_offset=0))]
        for field, value in changes:
            with self.subTest(field=field, value=value):
                case = copy.deepcopy(original); case['coordinate_mapping'][field] = value
                with self.assertRaises(CoordinateMappingError): validate_observation_mapping(case, required=True)
        for value in [None, [], True, {}]:
            case = copy.deepcopy(original); case['coordinate_mapping'] = value
            with self.assertRaises(CoordinateMappingError): validate_observation_mapping(case, required=True)

    def test_numeric_strings_booleans_and_invalid_bounds_are_not_coordinates(self):
        original = fixtures()[0]
        for value in [True, '5', float('nan'), float('inf'), -1, 1001]:
            with self.assertRaises(CoordinateMappingError): action_global_point(dict(x=value, y=500), original)
        for value in [0, -1, True, '900', float('nan')]:
            case = {'display': dict(x=0, y=0, width=1440, height=value)}
            with self.assertRaises(CoordinateMappingError): action_global_point(dict(x=500, y=500), case)

    def test_native_observation_validation_precedes_revision_and_model_requests(self):
        generation = 'd0b9c0fc-01af-42f0-b749-1027c907a2cd'
        for invalid in [False, True]:
            case = fixtures()[0]
            case.update(fixture_coordinates('fixture:accepted'))
            case['task_generation_id'] = generation
            if invalid: case['coordinate_mapping']['observation_revision'] = 'stale'
            reply = dict(ok=True, result=case)
            with mock.patch.object(runtime, '_task_generation_id', generation), \
                 mock.patch.object(runtime, '_bridge_observation_revision', 'prior'), \
                 mock.patch.object(runtime, 'bridge_exchange', return_value=reply) as exchange, \
                 mock.patch.object(runtime.ACPClient, 'prompt') as prompt:
                if invalid:
                    with self.assertRaises(runtime.ActionRejected) as raised: runtime.bridge_call('observe', 1)
                    self.assertEqual(raised.exception.code, 'observation_unstable')
                    self.assertIsNone(runtime._bridge_observation_revision)
                else:
                    runtime.bridge_call('observe', 1)
                    self.assertEqual(runtime._bridge_observation_revision, 'fixture:accepted')
                self.assertEqual(exchange.call_count, 1)
                prompt.assert_not_called()

    def test_startup_rejects_mapping_version_mismatch_before_generation(self):
        config = dict(kind='runtime_configuration', gemini_api_key='', action_contract_hash=runtime.CONTRACT_HASH,
                      action_contract_version=runtime.CONTRACT_VERSION, instruction_revision=0, task_protocol_version=runtime.TASK_PROTOCOL_VERSION,
                      stop_boundary_policy_version=runtime.STOP_BOUNDARY_POLICY_VERSION,
                      task_generation_id='d0b9c0fc-01af-42f0-b749-1027c907a2cd')
        for invalid in [None, True, '1', COORDINATE_MAPPING_VERSION + 1]:
            with mock.patch.object(runtime, 'runtime_line', return_value=json.dumps(dict(config, coordinate_mapping_version=invalid))):
                with self.assertRaisesRegex(RuntimeError, 'coordinate mapping versions'):
                    runtime.read_runtime_configuration(require_generation=True)
        runtime._task_generation_id = None
