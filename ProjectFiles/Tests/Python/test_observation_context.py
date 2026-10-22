import copy
import base64
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
from evidence_fixtures import native_result
import openclaw_runtime as runtime
from observation_context import historical_progress, select_elements, MAX_PROGRESS_CHARACTERS
from response_validation import normalize_action


def button(identity, **fields):
    return {'id': identity, 'role': 'AXButton', 'title': 'Open', 'actions': ['AXPress'], 'enabled': True, **fields}


class ObservationRankingTests(unittest.TestCase):
    def ids(self, observation, task='', limit=360):
        return {e['id'] for e in select_elements(observation, task, limit)}

    def test_active_app_controls_displace_earlier_background_controls(self):
        rows = [button(f'background:{n}', pid=1, window_id='bg') for n in range(400)]
        rows += [button('current:save', pid=2, window_id='active', title='Save')]
        observation = {'applications': [{'pid': 1}, {'pid': 2, 'topmost_on_agent_screen': True}], 'elements': rows}
        self.assertIn('current:save', self.ids(observation))
        self.assertLessEqual(len(runtime.compact_observation(observation)['elements']), 360)

    def test_window_ids_distinguish_same_title_windows_of_one_app(self):
        rows = [button(f'old:{n}', pid=2, window_id='old', window_title='Untitled') for n in range(400)]
        rows += [button('current:save', pid=2, window_id='current', window_title='Untitled', title='Save')]
        observation = {'applications': [{'pid': 2, 'topmost_on_agent_screen': True, 'windows': [
            {'window_id': 'old', 'title': 'Untitled'}, {'window_id': 'current', 'title': 'Untitled', 'focused': True}]}], 'elements': rows}
        self.assertIn('current:save', self.ids(observation))
        selected = select_elements(observation, '', 1)
        self.assertEqual(selected[0]['id'], 'current:save')

    def test_task_words_find_late_controls_in_another_window(self):
        rows = [button(f'early:{n}', pid=2, window_id='active', title='Continue') for n in range(400)]
        rows += [button('late:export', pid=3, window_id='report', title='Export quarterly budget')]
        observation = {'applications': [{'pid': 2, 'active': True}], 'elements': rows}
        self.assertIn('late:export', self.ids(observation, 'Export the quarterly budget'))
        self.assertEqual(select_elements(observation, 'Export the quarterly budget', 1)[0]['id'], 'late:export')

    def test_inactive_apps_own_focused_windows_do_not_outrank_task_display_window(self):
        observation = {'applications': [
            {'pid': 2, 'topmost_on_agent_screen': True, 'windows': [{'window_id': 'active', 'focused': True}]},
            {'pid': 3, 'windows': [{'window_id': 'inactive', 'focused': True, 'topmost_on_agent_screen': True}]}],
            'elements': [button('inactive', pid=3, window_id='inactive', focused=True),
                         button('active', pid=2, window_id='active', focused=False)]}
        self.assertEqual(select_elements(observation, '', 1)[0]['id'], 'active')

    def test_row_labels_and_structural_ancestors_accompany_ambiguous_button(self):
        rows = [button(f'noise:{n}', pid=2, window_id='active') for n in range(400)]
        rows += [{'id': 'row', 'pid': 2, 'window_id': 'active', 'role': 'AXGroup'},
                 {'id': 'budget', 'pid': 2, 'window_id': 'active', 'parent_id': 'row', 'role': 'AXStaticText', 'value': 'Quarterly Budget'},
                 button('open-budget', pid=2, window_id='active', parent_id='row')]
        selected = self.ids({'elements': rows}, 'Open the Quarterly Budget', 4)
        self.assertTrue({'row', 'budget', 'open-budget'} <= selected)

    def test_each_identical_button_keeps_its_own_section_labels(self):
        rows = []
        for name, y in [('Personal account', 100), ('Work account', 180)]:
            rows += [{'id': name, 'pid': 2, 'window_id': 'w', 'role': 'AXGroup'},
                     {'id': name + ':label', 'pid': 2, 'window_id': 'w', 'parent_id': name, 'role': 'AXStaticText',
                      'title': name, 'frame': {'x': 100, 'y': y, 'width': 100, 'height': 30}},
                     button(name + ':save', pid=2, window_id='w', parent_id=name, title='Save',
                            frame={'x': 210, 'y': y, 'width': 60, 'height': 30})]
        observation = {'elements': rows}
        self.assertEqual(len(select_elements(observation, 'Save the Work account', 6)), 6)
        selected = self.ids(observation, 'Save the Work account', 3)
        self.assertEqual(selected, {'Work account', 'Work account:label', 'Work account:save'})

    def test_geometry_context_does_not_cross_apps_or_windows(self):
        frame = {'x': 100, 'y': 100, 'width': 100, 'height': 30}
        rows = [button('control', pid=2, window_id='one', frame=frame),
                {'id': 'label', 'pid': 2, 'window_id': 'one', 'role': 'AXStaticText', 'title': 'Account', 'frame': frame},
                {'id': 'other-app', 'pid': 3, 'window_id': 'one', 'role': 'AXStaticText', 'title': 'Confidential', 'frame': frame},
                {'id': 'other-window', 'pid': 2, 'window_id': 'two', 'role': 'AXStaticText', 'title': 'Confidential', 'frame': frame}]
        observation = {'elements': rows, 'applications': [{'pid': 2, 'topmost_on_agent_screen': True,
                        'windows': [{'window_id': 'one', 'focused': True}]}]}
        self.assertEqual(self.ids(observation, 'Open Account', 2), {'control', 'label'})

    def test_focus_menus_and_disabled_targets_remain_observable(self):
        rows = [button(f'noise:{n}', title='noise') for n in range(400)]
        rows += [button('focus', title='Name', focused=True),
                 {'id': 'menu', 'role': 'AXMenu', 'title': 'File'},
                 {'id': 'item', 'role': 'AXMenuItem', 'title': 'Export', 'parent_id': 'menu'},
                 button('disabled', title='Export quarterly budget', enabled=False)]
        self.assertTrue({'focus', 'menu', 'item', 'disabled'} <= self.ids({'elements': rows}, 'Export quarterly budget'))

    def test_unicode_words_match_and_ids_and_observations_remain_unchanged(self):
        rows = [button(f'noise:{n}', title='Open') for n in range(400)]
        rows += [button('rev:full:identifier', title='Résumé export')]
        observation = {'observation_revision': 'rev', 'elements': rows}
        original = copy.deepcopy(observation)
        selected = runtime.prompt_observation(observation, 'Export my resume')['elements']
        self.assertIn('rev:full:identifier', {e['id'] for e in selected})
        self.assertEqual(normalize_action({'type': 'press', 'element_id': 'rev:full:identifier'}, observation)['element_id'], 'rev:full:identifier')
        self.assertEqual(observation, original)

    def test_parent_cycles_and_deep_ancestor_chains_are_bounded(self):
        observation = {'elements': [{'id': 'a', 'role': 'AXGroup', 'parent_id': 'b'},
                                    {'id': 'b', 'role': 'AXGroup', 'parent_id': 'a'},
                                    button('c', parent_id='a', title='Export')]}
        self.assertEqual(self.ids(observation, 'Export', 3), {'a', 'b', 'c'})
        self.assertEqual(select_elements(observation, 'Export', 2), [])

    def test_prompt_building_and_ranking_add_no_model_or_native_calls(self):
        observation = {'elements': [button('current:export', title='Export report')], 'applications': []}
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(runtime, 'bridge_call') as bridge, mock.patch.object(runtime, 'emit'):
            image = Path(directory) / 'frame.png'; image.write_bytes(b'fixture')
            client = mock.Mock(selected_model=None, prompt_calls=0, model_switches=0)
            def prompt(*args):
                client.prompt_calls += 1
                return '{"status":"act","action":{"type":"press","element_id":"current:export"}}'
            client.prompt.side_effect = prompt
            instruction = runtime.desktop_instruction('Export report', observation, [])
            self.assertEqual(client.prompt_calls, 0)
            router = runtime.AdaptiveModelRouter(lambda *a, **k: None)
            decision = runtime.routed_json_prompt(router, client, instruction, image, observation=observation)
            self.assertEqual(decision['action']['element_id'], 'current:export')
            self.assertEqual(client.prompt_calls, 1)
            self.assertEqual(router.metrics['repairs'], 0)
            bridge.assert_not_called()


class HistoricalProgressTests(unittest.TestCase):
    def progress(self, history, task=''):
        return historical_progress(history, 8, runtime.command_outcome_verified, task)

    def read(self, step=1, content='Quarterly revenue: 42'):
        return {'step': step, 'action': {'type': 'read_file', 'path': f'/tmp/report-{step}.txt'},
                'result': {'action_type':'read_file','outcome':'verified','verified':True,'verification_scope':'file_read', 'file_identity':'1'*64, 'file_version':'2'*64, 'parent_identity':'3'*64, 'path': f'/tmp/report-{step}.txt', 'content': content, 'encoding': 'utf-8',
                           'bytes_returned': len(content), 'truncated': False,
                           'content_sha256': hashlib.sha256(content.encode()).hexdigest()}}

    def tail(self):
        return [{'step': 20 + n, 'action': {'type': 'wait'}, 'result': {'message': 'waited'}} for n in range(8)]

    def test_earlier_exact_results_survive_the_recent_eight_action_limit(self):
        history = [self.read(), *self.tail()]
        progress = self.progress(history)
        self.assertIs(progress['historical'], True)
        self.assertEqual(progress['facts'][0]['step'], 1)
        self.assertEqual(progress['facts'][0]['evidence']['content'], 'Quarterly revenue: 42')
        self.assertNotIn(1, [e['step'] for e in runtime.compact_history(history)])
        for prompt in [runtime.desktop_instruction('Compare quarterly revenue', {'elements': []}, history),
                       runtime.verification_instruction('Compare quarterly revenue', {}, {'elements': []}, history)]:
            self.assertIn('Quarterly revenue: 42', prompt)
        self.assertIn('historical; recheck mutable state and use current IDs', runtime.desktop_instruction('Compare quarterly revenue', {}, history))
        self.assertNotIn('EARLIER CONFIRMED TASK FACTS', runtime.verification_instruction('Compare quarterly revenue', {}, {}, history))

    def test_claims_delivery_attempts_and_zero_exit_are_not_verified_progress(self):
        entries = [{'step': 1, 'action': button('old'), 'result': {'outcome': 'delivered_unconfirmed'},
                    'completed_requirements': ['Everything completed']},
                   {'step': 2, 'action': {'type': 'run_command', 'command': 'true'}, 'result': {'exit_code': 0}},
                   {'step': 3, 'action': {'type': 'write_file', 'path': '/tmp/a'}, 'result': {'verified': False}},
                   {'step': 4, 'action': {'type': 'press'}, 'result': {'outcome': 'verified', 'error_code': 'stale_target'}}]
        self.assertEqual(self.progress(entries + self.tail()), {})

    def test_native_outcome_checks_and_targets_retain_facts_without_stale_ids(self):
        checks = [{'type': 'file_exists', 'path': '/tmp/marker'}]
        entries = [{'step': 1, 'action': {'type': 'run_command', 'argv': ['touch', '/tmp/marker'], 'checks': checks},
                    'result': {'verified': True, 'verification_scope': 'requested_outcomes', 'exit_code': 0, 'timed_out': False,
                               'checks': [{**checks[0], 'verified': True}]}},
                   {'step': 2, 'action': {'type': 'press', 'element_id': 'stale:123'},
                    'target': {'app': 'Notes', 'window_title': 'Budget', 'title': 'Save', 'role': 'AXButton', 'window_id': 'stale-window'},
                    'result': {'outcome': 'verified', 'verification_scope': 'action_effect', 'message': 'Observed effect'},
                    'completed_requirements': ['Unproven complete task']}]
        entries[0]['result'] = native_result(entries[0]['action'])
        progress = self.progress(entries + self.tail())
        self.assertEqual(len(progress['facts']), 2)
        self.assertEqual(progress['facts'][1]['target']['window_title'], 'Budget')
        encoded = json.dumps(progress)
        for forbidden in ['stale:123', 'stale-window', 'element_id', 'Unproven complete task', 'argv']:
            self.assertNotIn(forbidden, encoded)
        self.assertFalse(runtime.trusted_native_history('Use Notes to save the budget', {}, entries))

    def test_verified_writes_and_command_content_checks_keep_the_confirmed_value(self):
        checks = [{'type': 'file_contents', 'path': '/tmp/report.txt', 'content': 'Revenue: 42'}]
        entries = [{'step': 1, 'action': {'type': 'write_file', 'path': '/tmp/report.txt', 'content': 'Revenue: 42'},
                    'result': {'verified': True, 'mode': 'overwrite', 'bytes_written': 11, 'file_size': 11}},
                   {'step': 2, 'action': {'type': 'run_command', 'argv': ['cat', '/tmp/report.txt'], 'checks': checks},
                    'result': {'verified': True, 'verification_scope': 'requested_outcomes', 'exit_code': 0, 'timed_out': False,
                               'checks': [{'type': 'file_contents', 'path': '/tmp/report.txt', 'verified': True}]}}]
        for entry in entries: entry['result'] = native_result(entry['action'])
        facts = self.progress(entries + self.tail())['facts']
        self.assertEqual(facts[0]['evidence']['written_content'], 'Revenue: 42')
        self.assertEqual(facts[1]['evidence']['checks'][0]['content'], 'Revenue: 42')

    def test_binary_reads_keep_a_digest_of_bytes_without_large_encoded_content(self):
        content = b'\x00\xff\x01'
        entry = self.read(content=base64.b64encode(content).decode())
        entry['result'].update(encoding='base64', bytes_returned=3)
        evidence = self.progress([entry] + self.tail())['facts'][0]['evidence']
        self.assertEqual(evidence['content_sha256'], hashlib.sha256(content).hexdigest())
        self.assertNotIn('content', evidence)
        entry['result']['content'] = 'invalid base64!'
        self.assertEqual(self.progress([entry] + self.tail()), {})

    def test_long_tasks_keep_all_earlier_fact_steps_with_explicit_excerpts(self):
        history = [self.read(n, 'ordinary text ' * 500 + 'quarterly revenue: 42') for n in range(100)]
        progress = self.progress(history, 'Compare quarterly revenue')
        self.assertEqual([fact['step'] for fact in progress['facts']], list(range(92)))
        self.assertLessEqual(len(json.dumps(progress, ensure_ascii=False, separators=(',', ':'))), MAX_PROGRESS_CHARACTERS)
        self.assertTrue(any('omitted' in json.dumps(fact) for fact in progress['facts']))
        self.assertIn('quarterly', json.dumps(progress))

    def test_private_inputs_and_secure_fields_never_enter_progress(self):
        entries = []
        for fields in [{'target': {'role': 'AXSecureTextField'}}, {'target': {'role': 'AXTextField', 'subrole': 'AXSecureTextField'}},
                       {'private_input': True}, {'result': {'outcome': 'verified', 'secret_retained': False}}]:
            entry = {'step': 1, 'action': {'type': 'set_value', 'text': 'private-secret'}, 'result': {'outcome': 'verified'}}
            entry.update(fields); entries.append(entry)
        entries.append({'step': 1, 'action': 'user_input_entered', 'result': {'outcome': 'verified', 'secret_retained': False}})
        self.assertEqual(self.progress(entries + self.tail()), {})

    def test_progress_is_task_local_and_does_not_modify_history(self):
        history = [self.read(), *self.tail()]; original = copy.deepcopy(history)
        self.assertTrue(self.progress(history))
        self.assertEqual(self.progress([]), {})
        self.assertEqual(history, original)

    def test_action_context_uses_planning_target_labels_not_future_observation(self):
        observation = {'elements': [button('rev:button', app='Notes', window_title='Budget', title='Save')]}
        decision = {'intended_target': 'Budget Save', 'expected_result': 'Saved badge appears'}
        context = runtime.action_history_context(decision, {'type': 'press', 'element_id': 'rev:button'}, observation)
        self.assertEqual(context['target']['title'], 'Save')
        self.assertEqual(context['expected_result'], 'Saved badge appears')
        self.assertNotIn('id', context['target'])


if __name__ == '__main__': unittest.main()
