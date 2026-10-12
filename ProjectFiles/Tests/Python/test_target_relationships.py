import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
from observation_context import ancestor_ids, coordinates_are_ambiguous, structural_identity
from response_validation import normalize_action, ResponseValidationError


def fixture():
    rows = [{'id': 'r:window', 'pid': 42, 'window_id': 'r:w1', 'role': 'AXWindow', 'title': 'Settings'},
            {'id': 'r:dialog', 'pid': 42, 'window_id': 'r:w1', 'role': 'AXSheet', 'title': 'Accounts', 'parent_id': 'r:window'}]
    for name, y in [('Personal', 100), ('Work', 200)]:
        rows += [{'id': 'r:' + name, 'pid': 42, 'window_id': 'r:w1', 'role': 'AXGroup', 'parent_id': 'r:dialog'},
                 {'id': 'r:' + name + ':label', 'pid': 42, 'window_id': 'r:w1', 'role': 'AXStaticText',
                  'title': name + ' account', 'parent_id': 'r:' + name,
                  'frame': {'x': 50, 'y': y, 'width': 100, 'height': 30}},
                 {'id': 'r:' + name + ':save', 'pid': 42, 'window_id': 'r:w1', 'role': 'AXButton',
                  'title': 'Save', 'parent_id': 'r:' + name, 'actions': ['AXPress'],
                  'frame': {'x': 200, 'y': y, 'width': 80, 'height': 30}}]
    return {'observation_revision': 'r', 'display': {'x': 0, 'y': 0, 'width': 1000, 'height': 800},
            'applications': [{'pid': 42, 'name': 'Fixture', 'windows': [{'window_id': 'r:w1', 'title': 'Settings'}]}], 'elements': rows}


class TargetRelationshipTests(unittest.TestCase):
    def test_app_window_dialog_panel_and_local_labels_are_grounded(self):
        original = fixture()
        before = copy.deepcopy(original)
        compact = runtime.prompt_observation(original, 'Save the Work account')
        by_id = {e['id']: e for e in compact['elements']}
        target = by_id['r:Work:save']
        self.assertEqual(target['pid'], compact['applications'][0]['pid'])
        self.assertEqual(target['window_id'], compact['applications'][0]['windows'][0]['window_id'])
        self.assertEqual(target['target_context']['path'], ['r:window', 'r:dialog', 'r:Work'])
        self.assertEqual(target['target_context']['nearby_label_ids'], ['r:Work:label'])
        peers = target['target_context']['repeated_label']
        self.assertEqual(peers['count'], 2)
        self.assertEqual(set(peers['candidate_ids']), {'r:Work:save', 'r:Personal:save'})
        self.assertFalse(peers['partial'])
        self.assertEqual(original, before)

    def test_omitted_peers_are_counted_without_inventing_visible_controls(self):
        original = fixture()
        selected = runtime.select_elements(original, 'Save the Work account', 5)
        by_id = {e['id']: e for e in selected}
        target = by_id['r:Work:save']['target_context']
        self.assertEqual(target['repeated_label'], {'count': 2, 'candidate_ids': ['r:Work:save'], 'partial': True})
        self.assertTrue(set(target['path'] + target['nearby_label_ids']) <= by_id.keys())

    def test_parent_cycles_and_foreign_parent_edges_do_not_create_relationships(self):
        observation = fixture(); by_id = {e['id']: e for e in observation['elements']}
        by_id['r:Work']['parent_id'] = 'r:Personal'
        by_id['r:Personal']['parent_id'] = 'r:Work'
        self.assertLessEqual(len(ancestor_ids(by_id['r:Work:save'], by_id)), 3)
        by_id['r:Personal']['pid'] = 43
        self.assertEqual(ancestor_ids(by_id['r:Work:save'], by_id), ['r:Work'])

    def test_secure_values_are_neither_labels_nor_replay_context(self):
        observation = fixture()
        observation['elements'].append({'id': 'r:secret', 'pid': 42, 'window_id': 'r:w1', 'parent_id': 'r:Work',
                                        'role': 'AXSecureTextField', 'value': 'never-copy-this-secret'})
        self.assertNotIn('never-copy-this-secret', str(runtime.prompt_observation(observation)))

    def test_overlapping_unrelated_controls_are_rejected_before_execution(self):
        observation = fixture(); target = observation['elements'][-1]
        observation['elements'][4]['frame'] = copy.deepcopy(target['frame'])
        action = {'type': 'click', 'pid': 42, 'x': 240, 'y': 270}
        self.assertTrue(coordinates_are_ambiguous(action, observation))
        with self.assertRaisesRegex(ResponseValidationError, 'action.element_id.*multiple unrelated controls'):
            normalize_action(action, observation)
        action['element_id'] = target['id']
        self.assertFalse(coordinates_are_ambiguous(action, observation))
        self.assertEqual(normalize_action(action, observation)['element_id'], target['id'])

    def test_button_label_child_is_not_another_actionable_target(self):
        observation = fixture(); target = observation['elements'][-1]
        observation['elements'].append({'id': 'r:child', 'pid': 42, 'window_id': 'r:w1', 'parent_id': target['id'],
                                        'role': 'AXStaticText', 'title': 'Save', 'frame': target['frame']})
        self.assertFalse(coordinates_are_ambiguous({'type': 'click', 'pid': 42, 'x': 240, 'y': 270}, observation))

    def test_repeated_buttons_in_separate_panels_have_different_replay_identity(self):
        observation = fixture(); before = {'type': 'press', 'element_id': 'r:Personal:save'}
        after = {'type': 'press', 'element_id': 'r:Work:save'}
        recovery = runtime.ActionRecovery(); recovery.unconfirmed(before, observation)
        self.assertIsNone(recovery.check(after, observation))
        self.assertEqual(recovery.check(before, observation)['outcome'], 'suppressed')

    def test_scoped_ids_do_not_break_same_target_replay_protection(self):
        original = fixture(); later = copy.deepcopy(original)
        for row in later['elements']:
            for key in ('id', 'parent_id', 'window_id'):
                if key in row: row[key] = row[key].replace('r:', 'later:')
        old = next(e for e in original['elements'] if e['id'] == 'r:Work:save')
        new = next(e for e in later['elements'] if e['id'] == 'later:Work:save')
        self.assertEqual(structural_identity(old, original), structural_identity(new, later))

    def test_native_aliases_do_not_create_false_ambiguity_or_leak_into_prompt(self):
        observation = fixture(); target = observation['elements'][-1]
        target['native_identity'] = 'private-native-token'
        alias = copy.deepcopy(target); alias['id'] = 'r:alias'; alias.pop('parent_id'); observation['elements'].append(alias)
        self.assertFalse(coordinates_are_ambiguous({'type': 'click', 'pid': 42, 'x': 240, 'y': 270}, observation))
        self.assertNotIn('private-native-token', str(runtime.prompt_observation(observation)))

    def test_relabeling_same_live_control_cannot_authorize_uncertain_replay(self):
        original = fixture(); original['elements'][-1]['native_identity'] = 'same-live-control'
        later = copy.deepcopy(original); later['elements'][-2]['title'] = 'Personal account'
        action = {'type': 'press', 'element_id': 'r:Work:save'}
        recovery = runtime.ActionRecovery(); recovery.unconfirmed(action, original)
        self.assertEqual(recovery.check(action, later)['outcome'], 'suppressed')

    def test_prompt_explains_relations_only_when_observed_and_stays_bounded(self):
        prompt = runtime.desktop_instruction('Save the Work account', fixture(), [])
        self.assertIn('outer-to-inner', prompt)
        self.assertIn('repeated_label', prompt)
        self.assertIn('intended app/window/panel', prompt)
        self.assertLessEqual(len(runtime.desktop_instruction('Save the Work account', {}, [])), 4000)


if __name__ == '__main__': unittest.main()
