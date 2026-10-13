import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
import observation_context as context
from expected_effects import ExpectedEffect
from evidence_consistency import EvidenceConsistency
from recovery_cycles import state_key, target_for
from response_validation import normalize_action, ResponseValidationError


def observation(revision='r1'):
    def row(name, role, **fields):
        return dict(id=revision + ':' + name, pid=42, role=role, window_id=revision + ':w', **fields)
    return dict(observation_revision=revision, display=dict(x=0, y=0, width=1000, height=1000), applications=[
        dict(pid=42, name='Editor', bundle_id='fixture.editor', topmost_on_agent_screen=True,
             windows=[dict(window_id=revision + ':w', title='Document', focused=True)],
             graphics_windows=[dict(id=7, title='Document')]),
        dict(pid=43, name='Other', windows=[dict(window_id=revision + ':w', title='Other')],
             graphics_windows=[dict(id=7, title='Other')])], elements=[
        row('app', 'AXApplication'),
        row('window', 'AXWindow', parent_id=revision + ':app', title='Document'),
        row('sheet', 'AXSheet', parent_id=revision + ':window', title='Save as'),
        row('label', 'AXStaticText', parent_id=revision + ':sheet', title='Filename'),
        row('field', 'AXTextField', parent_id=revision + ':sheet', title='Name', window_title='Document',
            native_identity='field', value='draft', value_complete=True, focused=True, enabled=True),
        row('save', 'AXButton', parent_id=revision + ':sheet', title='Save', actions=['AXPress'], enabled=True,
            frame=dict(x=20, y=20, width=50, height=30)),
        dict(id=revision + ':other', pid=43, role='AXButton', window_id=revision + ':w', title='Save',
             actions=['AXPress'], frame=dict(x=20, y=20, width=50, height=30))])


class ObservationIndexStructureTests(unittest.TestCase):
    def test_empty_and_unidentified_rows_do_not_create_targets(self):
        indexes = context.ObservationIndexes(dict(elements=[None, {}, dict(id=['bad'], pid=42)], applications=[None]))
        self.assertEqual(indexes.rows, ()); self.assertEqual(dict(indexes.by_id), {})
        self.assertIsNone(indexes.element(None)); self.assertIsNone(indexes.element(['bad']))
        self.assertIsNone(indexes.application(42)); self.assertEqual(indexes.window_candidates(42, 'w'), ())

    def test_element_pid_window_and_parent_tables_keep_observation_order(self):
        indexes = context.ObservationIndexes(observation())
        self.assertEqual(indexes.element('r1:save')['title'], 'Save')
        self.assertEqual(len(indexes.elements_by_pid[42]), 6)
        self.assertEqual([e['id'] for e in indexes.children['r1:sheet']], ['r1:label', 'r1:field', 'r1:save'])
        self.assertEqual(indexes.scopes['r1:save'], (42, 'r1:w'))
        self.assertEqual(indexes.application(42)['name'], 'Editor')
        self.assertEqual(indexes.window_candidates(42, 'r1:w')[0]['title'], 'Document')
        self.assertEqual(indexes.window_candidates(43, 'r1:w')[0]['title'], 'Other')
        self.assertEqual(indexes.window_candidates(42, 7, graphics=True)[0]['title'], 'Document')
        self.assertEqual(indexes.window_candidates(43, 7, graphics=True)[0]['title'], 'Other')
        self.assertEqual(indexes.window_candidates(42, 7), ())

    def test_ancestry_is_built_once_and_retains_app_window_dialog_order(self):
        with mock.patch.object(context, 'ancestor_ids', wraps=context.ancestor_ids) as walk:
            indexes = context.ObservationIndexes(observation())
            built = walk.call_count
            for _ in range(10):
                self.assertEqual(indexes.ancestor_ids(indexes.element('r1:save')), ('r1:sheet', 'r1:window', 'r1:app'))
            self.assertEqual(walk.call_count, built)
        self.assertEqual(context.structural_identity(indexes.element('r1:save'), {}, indexes),
                         dict(containers=[dict(role='AXApplication', title=None), dict(role='AXWindow', title='Document'),
                                          dict(role='AXSheet', title='Save as')], labels=['Filename']))

    def test_missing_parents_cycles_and_cross_app_or_window_edges_are_bounded(self):
        cases = [
            ([dict(id='a', pid=42, parent_id='missing')], ()),
            ([dict(id='a', pid=42, parent_id='b'), dict(id='b', pid=42, parent_id='a')], ('b',)),
            ([dict(id='a', pid=42, parent_id='b'), dict(id='b', pid=43)], ()),
            ([dict(id='a', pid=42, window_id='one', parent_id='b'), dict(id='b', pid=42, window_id='two')], ()),
            ([dict(id='a', pid=42, parent_id=[])], ())]
        for elements, expected in cases:
            with self.subTest(elements=elements):
                indexes = context.ObservationIndexes(dict(elements=elements))
                self.assertEqual(indexes.ancestor_ids(indexes.element('a')), expected)
        indexes = context.ObservationIndexes(dict(elements=[dict(id=str(i), pid=42, parent_id=str(i + 1)) for i in range(30)]))
        self.assertEqual(len(indexes.ancestor_ids(indexes.element('0'))), 24)

    def test_window_scope_can_come_from_an_observed_ancestor(self):
        value = observation(); value['elements'][-2].pop('window_id')
        indexes = context.ObservationIndexes(value)
        self.assertEqual(indexes.scopes['r1:save'], (42, 'r1:window'))

    def test_duplicates_keep_first_last_and_ambiguity_candidates(self):
        value = observation(); value['elements'].append(dict(value['elements'][-2], title='Later Save'))
        value['applications'].append(dict(pid=42, name='Later Editor', graphics_windows=[dict(id=7, title='Later')]))
        indexes = context.ObservationIndexes(value)
        self.assertEqual(indexes.element('r1:save')['title'], 'Save')
        self.assertEqual(indexes.element('r1:save', last=True)['title'], 'Later Save')
        self.assertEqual(len(indexes.elements_by_id['r1:save']), 2)
        self.assertEqual(indexes.application(42)['name'], 'Editor')
        self.assertEqual(indexes.application(42, last=True)['name'], 'Later Editor')
        self.assertEqual(indexes.window_candidates(42, 7, graphics=True, application_last=True)[0]['title'], 'Later')
        self.assertEqual(len(context.coordinate_targets(dict(type='click', pid=42, x=25, y=25), value, indexes)), 2)

    def test_pinned_target_uses_its_own_parent_and_pid(self):
        indexes = context.ObservationIndexes(observation())
        pinned = dict(indexes.element('r1:save'), parent_id='r1:window')
        self.assertEqual(indexes.ancestor_ids(pinned), ('r1:window', 'r1:app'))
        self.assertEqual(indexes.ancestor_ids(dict(pinned, pid=43)), ())

    def test_missing_parent_has_no_surrounding_labels(self):
        value = observation(); value['elements'][-2].pop('parent_id')
        self.assertEqual(context.structural_identity(value['elements'][-2], value)['labels'], [])

    def test_snapshot_and_tables_are_read_only_but_deepcopy_is_ordinary_json(self):
        indexes = context.ObservationIndexes(observation())
        with self.assertRaises(TypeError): indexes.by_id['new'] = {}
        with self.assertRaises(TypeError): indexes.element('r1:save')['frame']['x'] = 100
        with self.assertRaises(TypeError): indexes.element('r1:save')['actions'].append('wrong')
        clone = copy.deepcopy(indexes.element('r1:save'))
        clone['frame']['x'] = 100; clone['actions'].append('AXShowMenu')
        self.assertEqual(indexes.element('r1:save')['frame']['x'], 20)
        self.assertEqual(json.loads(json.dumps(clone)), clone)


class ObservationIndexLifecycleTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(); self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / 'screen.png'; self.path.write_bytes(b'fixture pixels')
        self.value = observation(); self.value['screenshot_path'] = str(self.path)

    def test_helpers_share_one_build_and_add_no_bridge_calls(self):
        with runtime.screenshot_buffer_scope(), mock.patch.object(runtime, 'ObservationIndexes', wraps=context.ObservationIndexes) as build, \
             mock.patch.object(runtime, 'bridge_call', side_effect=AssertionError('Indexing must stay local')):
            index = context.observation_indexes(self.value)
            for _ in range(3):
                normalize_action(dict(type='press', element_id='r1:save'), self.value)
                runtime.action_target(dict(type='press', element_id='r1:save'), self.value)
                runtime.action_identity(dict(type='press', element_id='r1:save'), self.value)
                runtime.action_history_context({}, dict(element_id='r1:save'), self.value)
                context.structural_identity(index.element('r1:save'), self.value)
                context.select_elements(self.value, 'Save draft', 360)
                state_key(self.value, 42)
            self.assertEqual(build.call_count, 1)

    def test_equivalent_copies_share_an_isolated_snapshot(self):
        clone = copy.deepcopy(self.value)
        with runtime.screenshot_buffer_scope():
            first = context.observation_indexes(self.value)
            self.assertIs(context.observation_indexes(clone), first)
            self.value['elements'][-2]['title'] = 'Changed'
            self.assertIs(context.observation_indexes(clone), first)
            self.assertEqual(first.element('r1:save')['title'], 'Save')
            changed = context.observation_indexes(self.value)
            self.assertIsNot(changed, first); self.assertEqual(changed.element('r1:save')['title'], 'Changed')

    def test_in_place_identity_layout_state_and_window_edits_invalidate(self):
        for change in [lambda o: o['elements'][-2].update(id='new', pid=43, parent_id='r1:other'),
                       lambda o: o['elements'][-2]['frame'].update(x=300),
                       lambda o: o['elements'][-2].update(enabled=False),
                       lambda o: o['applications'][0]['windows'][0].update(title='Other')]:
            value = copy.deepcopy(self.value)
            with self.subTest(change=change), runtime.screenshot_buffer_scope():
                before = context.observation_indexes(value)
                change(value); after = context.observation_indexes(value)
                self.assertIsNot(before, after)
                self.assertEqual(dict(after.by_id), dict(context.ObservationIndexes(value).by_id))

    def test_identical_data_with_new_revision_gets_new_indexes(self):
        with runtime.screenshot_buffer_scope():
            first = context.observation_indexes(self.value)
            other = dict(self.value, observation_revision='r2')
            self.assertIsNot(context.observation_indexes(other), first)

    def test_discard_drops_only_the_ending_revision_and_does_not_read_pixels(self):
        with runtime.screenshot_buffer_scope() as images, mock.patch.object(Path, 'read_bytes', side_effect=AssertionError('No image read')):
            first = context.observation_indexes(self.value)
            state = runtime.observation_state(self.value)
            other = dict(self.value, observation_revision='r2')
            second = context.observation_indexes(other)
            runtime.discard_observation_image(self.value)
            self.assertTrue(self.path.exists()); self.assertEqual(state._values, {})
            self.assertIs(context.observation_indexes(other), second)
            self.assertIsNot(context.observation_indexes(self.value), first)

    def test_cancellation_and_scope_exit_release_indexes_and_restore_provider(self):
        with self.assertRaises(RuntimeError):
            with runtime.screenshot_buffer_scope() as images:
                context.observation_indexes(self.value); state = runtime.observation_state(self.value)
                raise RuntimeError('Fixture cancelled')
        self.assertEqual(images.states, {}); self.assertEqual(state._values, {})
        self.assertIsNone(context._index_provider.get())
        with runtime.screenshot_buffer_scope():
            self.assertIsNot(context.observation_indexes(self.value), context.ObservationIndexes(self.value))

    def test_generation_change_and_foreign_observations_cannot_reuse_indexes(self):
        with mock.patch.object(runtime, '_task_generation_id', 'task-a'), runtime.screenshot_buffer_scope():
            context.observation_indexes(self.value)
            with mock.patch.object(runtime, '_task_generation_id', 'task-b'), self.assertRaises(runtime.ActionRejected):
                context.observation_indexes(self.value)
            with self.assertRaises(runtime.ActionRejected):
                context.observation_indexes(dict(self.value, task_generation_id='task-b'))

    def test_new_task_and_nested_scopes_get_their_own_indexes(self):
        with runtime.screenshot_buffer_scope():
            first = context.observation_indexes(self.value)
            with runtime.screenshot_buffer_scope():
                self.assertIsNot(context.observation_indexes(self.value), first)
            self.assertIs(context.observation_indexes(self.value), first)
        with runtime.screenshot_buffer_scope():
            self.assertIsNot(context.observation_indexes(self.value), first)

    def test_derived_tables_never_enter_prompt_observation_or_cache_input(self):
        original = copy.deepcopy(self.value)
        with runtime.screenshot_buffer_scope():
            context.observation_indexes(self.value)
            compact = runtime.compact_observation(self.value, 'Save draft')
            self.assertEqual(self.value, original)
            self.assertEqual(runtime.coverage_cache_input(self.value), original)
            self.assertFalse(any('index' in key or 'lookup' in key for key in compact))
            self.assertEqual(json.loads(json.dumps(compact)), compact)


class ObservationIndexBehaviorTests(unittest.TestCase):
    def test_pid_conflicts_unknown_ids_and_coordinate_ambiguity_still_reject(self):
        value = observation()
        with runtime.screenshot_buffer_scope():
            with self.assertRaisesRegex(ResponseValidationError, "match the selected element's app"):
                normalize_action(dict(type='press', element_id='r1:save', pid=43), value)
            with self.assertRaisesRegex(ResponseValidationError, 'current observation'):
                normalize_action(dict(type='press', element_id='old:save'), value)
            # The other app at these coordinates is not a candidate for PID 42.
            self.assertEqual(len(context.coordinate_targets(dict(type='click', pid=42, x=25, y=25), value)), 1)
            value['elements'].append(dict(value['elements'][-2], id='r1:unrelated', parent_id='r1:window'))
            with self.assertRaisesRegex(ResponseValidationError, 'overlap multiple unrelated'):
                normalize_action(dict(type='click', pid=42, x=25, y=25), value)

    def test_refresh_reconciles_expected_field_without_duplicate_execution(self):
        before, after = observation(), observation('r2')
        after['elements'][4]['value'] = 'wanted'
        with runtime.screenshot_buffer_scope():
            effect = ExpectedEffect(dict(type='field_value', element_id='r1:field', value='wanted'), before)
            self.assertEqual(effect.observe(after)['outcome'], 'verified')
            self.assertEqual(target_for(dict(type='key', pid=42), after)['id'], 'r2:field')
            self.assertEqual([e['id'] for e in EvidenceConsistency.candidates(before['elements'][4], before, after)], ['r2:field'])
            after['applications'][0]['bundle_id'] = 'another.editor'
            self.assertEqual(effect.observe(after)['reason'], 'application_changed')

    def test_cached_and_fresh_helpers_preserve_prompt_and_recovery_output(self):
        value = observation()
        expected = (context.select_elements(value, 'Save draft', 6), state_key(value, 42),
                    runtime.action_identity(dict(type='press', element_id='r1:save'), value))
        with runtime.screenshot_buffer_scope():
            actual = (context.select_elements(value, 'Save draft', 6), state_key(value, 42),
                      runtime.action_identity(dict(type='press', element_id='r1:save'), value))
        self.assertEqual(actual, expected)


if __name__ == '__main__': unittest.main()
