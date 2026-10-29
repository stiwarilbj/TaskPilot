import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
import request_policy as policy
from observation_completeness import ObservationCompletenessError, validate_completeness, prompt_coverage
from coordinate_fixtures import fixture_coordinates


def observation(rows=None, reasons=None):
    rows = rows if rows is not None else [dict(id='current:root', pid=42, role='AXWindow', title='Report')]
    value = dict(fixture_coordinates('current', len(rows)), observation_revision='current',
                 applications=[dict(pid=42, name='Editor', active=True)], elements=rows)
    if reasons:
        report = value['observation_completeness']
        report.update(state='partial', reason_counts=reasons,
                      limitations=[dict(reason=reason, pid=42, **({'element_id': rows[0]['id']} if rows else {}))
                                   for reason, count in reasons.items() for _ in range(count)])
    return value


class ObservationCompletenessTests(unittest.TestCase):
    def test_only_exposed_accessibility_tree_is_claimed_complete(self):
        value = observation()
        report = validate_completeness(value, required=True)
        self.assertEqual(report['scope'], 'exposed_accessibility_tree_on_assigned_display')
        self.assertEqual(report['state'], 'complete')
        self.assertEqual(prompt_coverage(value, value['elements'], 360)['prompt_selection']['omitted'], 0)

    def test_all_collection_gaps_are_preserved_for_planning(self):
        reasons = {reason: 1 for reason in ('element_limit', 'child_limit', 'depth_limit', 'collection_timeout',
                   'accessibility_timeout', 'accessibility_incomplete', 'accessibility_read_error',
                   'accessibility_unavailable', 'accessibility_permission_unavailable',
                   'accessibility_stalled_subtree_deferred')}
        value = observation(reasons=reasons)
        before = copy.deepcopy(value)
        compact = runtime.prompt_observation(value, 'Save this report')
        report = compact['observation_completeness']
        self.assertEqual(report['reason_counts'], reasons)
        self.assertEqual(report['state'], 'partial')
        self.assertEqual(report['limitations'], value['observation_completeness']['limitations'])
        self.assertEqual(value, before)

    def test_prompt_budget_omissions_are_distinct_from_native_collection(self):
        rows = [dict(id=f'current:e{i}', pid=42, role='AXButton', title='Continue') for i in range(400)]
        rows += [dict(id='current:export', pid=42, role='AXButton', title='Export quarterly budget')]
        value = observation(rows)
        compact = runtime.prompt_observation(value, 'Export the quarterly budget')
        report = compact['observation_completeness']
        self.assertEqual(report['state'], 'complete')
        self.assertEqual(report['prompt_selection'], dict(included=360, omitted=41, limit=360,
                                                         reason='prompt_budget_or_context_filter'))
        self.assertIn('current:export', {e['id'] for e in compact['elements']})

    def test_expanded_controls_and_their_ancestry_reach_planning(self):
        rows = [dict(id='current:panel', pid=42, role='AXGroup', title='Quarterly budget')]
        rows += [dict(id=f'current:noise{i}', pid=42, role='AXButton', title='Unrelated') for i in range(640)]
        rows += [dict(id='current:save', pid=42, role='AXButton', title='Save', parent_id='current:panel')]
        value = observation(rows)
        value['observation_completeness']['local_expansion'] = dict(subtrees_attempted=1, controls_added=2, read_retries=0)
        compact = runtime.prompt_observation(value, 'Save the quarterly budget')
        self.assertTrue({'current:panel', 'current:save'} <= {e['id'] for e in compact['elements']})
        self.assertNotIn('local_expansion', compact['observation_completeness'])
        self.assertEqual(value['observation_completeness']['local_expansion']['controls_added'], 2)

    def test_compaction_removes_missing_scope_ids_without_losing_the_app_or_reason(self):
        value = observation(reasons={'child_limit': 1})
        scope = value['observation_completeness']['limitations'][0]
        scope['window_id'] = 'current:window'
        report = prompt_coverage(value, [], 360)
        self.assertNotIn('element_id', report['limitations'][0])
        self.assertEqual(report['limitations'][0]['pid'], 42)
        self.assertEqual(report['limitations'][0]['window_id'], 'current:window')
        self.assertEqual(report['limitations'][0]['reason'], 'child_limit')

    def test_graphics_only_app_is_partial_and_preserves_coordinate_fallback(self):
        value = observation([], {'accessibility_unavailable': 1})
        value['applications'][0]['accessibility_available'] = False
        report = validate_completeness(value, required=True)
        self.assertEqual(report['state'], 'partial')
        prompt = runtime.desktop_instruction('Click the visible Save button', value, [])
        self.assertIn('"type":"click"', prompt)
        self.assertIn('accessibility_unavailable', prompt)
        self.assertIn('unobserved, not unavailable', prompt)

    def test_legacy_offline_fixtures_have_unknown_coverage(self):
        value = dict(elements=[], applications=[])
        self.assertIsNone(validate_completeness(value))
        self.assertEqual(prompt_coverage(value, [], 360), {'state': 'unknown'})
        with self.assertRaises(ObservationCompletenessError): validate_completeness(value, required=True)

    def test_invalid_metadata_is_rejected_without_coercion(self):
        changes = [dict(version=True), dict(version=2), dict(state=[]), dict(state='complete', reason_counts={'element_limit': 1}),
                   dict(state='partial'), dict(scope='all_screen_controls'), dict(collected_controls=0),
                   dict(collected_controls=True), dict(reason_counts={'element_limit': '1'}),
                   dict(reason_counts={'element_limit': False}), dict(limitations=[dict(reason=[], pid=42)]),
                   dict(limitation_scopes_omitted=1), dict(local_expansion={}),
                   dict(local_expansion=dict(subtrees_attempted=0, controls_added=2, read_retries=0))]
        for change in changes:
            with self.subTest(change=change):
                value = observation(); value['observation_completeness'].update(change)
                with self.assertRaises(ObservationCompletenessError): validate_completeness(value, required=True)
        for target in ['old:root', [], None]:
            value = observation(reasons={'depth_limit': 1})
            value['observation_completeness']['limitations'][0]['element_id'] = target
            with self.assertRaisesRegex(ObservationCompletenessError, 'stale subtree'): validate_completeness(value)
        value = observation(reasons={'child_limit': 1})
        value['observation_completeness']['limitations'][0]['pid'] = 43
        with self.assertRaisesRegex(ObservationCompletenessError, 'stale subtree'): validate_completeness(value)

    def test_bounded_scope_details_keep_full_reason_counts(self):
        value = observation(reasons={'accessibility_timeout': 32})
        report = value['observation_completeness']
        report['reason_counts']['accessibility_timeout'] = 100
        report['limitation_scopes_omitted'] = 68
        self.assertIs(validate_completeness(value), report)

    def test_keywords_are_sent_locally_and_bad_reports_never_reach_model_or_revision(self):
        generation = 'd0b9c0fc-01af-42f0-b749-1027c907a2cd'
        for malformed in [False, True]:
            value = observation(reasons={'element_limit': 1})
            value['task_generation_id'] = generation
            if malformed: value['observation_completeness']['collected_controls'] = 0
            with mock.patch.object(runtime, '_task_generation_id', generation), \
                 mock.patch.object(runtime, '_bridge_observation_revision', 'old'), \
                 mock.patch.object(runtime, '_observation_keywords', ['budget', 'export']), \
                 mock.patch.object(runtime, 'bridge_exchange', return_value=dict(ok=True, result=value)) as exchange, \
                 mock.patch.object(runtime.ACPClient, 'prompt') as prompt:
                if malformed:
                    with self.assertRaises(runtime.ActionRejected) as error: runtime.bridge_call('observe', 1)
                    self.assertEqual(error.exception.code, 'observation_unstable')
                    self.assertIsNone(runtime._bridge_observation_revision)
                else:
                    runtime.bridge_call('observe', 1)
                    self.assertEqual(runtime._bridge_observation_revision, 'current')
                sent = dict(exchange.call_args.args[2])
                self.assertTrue(0 < sent.pop('local_budget_ms') <= 5000)
                self.assertEqual(sent, dict(observation_keywords=['budget', 'export']))
                prompt.assert_not_called()

    def test_startup_requires_matching_version_and_readiness_does_not_observe(self):
        config = dict(kind='runtime_configuration', gemini_api_key='', action_contract_hash=runtime.CONTRACT_HASH,
                      action_contract_version=runtime.CONTRACT_VERSION, instruction_revision=0, task_protocol_version=runtime.TASK_PROTOCOL_VERSION,
                      stop_boundary_policy_version=runtime.STOP_BOUNDARY_POLICY_VERSION,
                      native_action_policy_version=runtime.NATIVE_ACTION_POLICY_VERSION,
                      coordinate_mapping_version=runtime.COORDINATE_MAPPING_VERSION,
                      task_generation_id='d0b9c0fc-01af-42f0-b749-1027c907a2cd')
        with mock.patch.object(runtime, '_task_generation_id', None), mock.patch.object(runtime, '_observation_keywords', ['old']), \
             mock.patch.object(runtime, 'bridge_call') as bridge:
            for version in [None, True, '1', 2]:
                with mock.patch.object(runtime, 'runtime_line', return_value=json.dumps(dict(config, observation_completeness_version=version))):
                    with self.assertRaisesRegex(RuntimeError, 'completeness versions'):
                        runtime.read_runtime_configuration(require_generation=True)
            with mock.patch.object(runtime, 'runtime_line', return_value=json.dumps(config)):
                runtime.read_runtime_configuration() # Readiness has no task authority or generation calls.
            self.assertIsNone(runtime._task_generation_id)
            self.assertEqual(runtime._observation_keywords, [])
            bridge.assert_not_called()

    def test_all_prompt_phases_and_format_repair_preserve_coverage(self):
        value = observation(reasons={'collection_timeout': 1})
        planning = runtime.desktop_instruction('Save the report', value, [])
        recovery = runtime.desktop_instruction('Save the report', value, [dict(action=dict(type='press', element_id='old:save'),
                    result=dict(error_code='stale_target'))])
        verification = runtime.verification_instruction('Save the report', dict(status='done'), value, [])
        for prompt in (planning, recovery, verification):
            self.assertIn('"collection_timeout":1', prompt)
            self.assertIn('"state":"partial"', prompt)
        self.assertIn('cannot prove that a required control or outcome is absent', verification)
        repair = runtime.compile_repair(planning, '{', 'Malformed JSON', 'planning')
        self.assertIn(json.dumps(planning), repair)

    def test_partial_observation_healthy_decision_still_uses_one_call_and_cache_tracks_coverage(self):
        value = observation(reasons={'element_limit': 1})
        client = mock.Mock(selected_model=None, prompt_calls=0, model_switches=0, decision_cache={})
        def prompt(*args):
            client.prompt_calls += 1
            return '{"status":"act","action":{"type":"wait","seconds":0.2}}'
        client.prompt.side_effect = prompt
        router = policy.AdaptiveModelRouter(lambda *a, **k: None, sleep=lambda _: None)
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(runtime, 'emit'), mock.patch.object(runtime, 'bridge_call') as bridge:
            image = Path(directory) / 'screen.png'; image.write_bytes(b'fixture')
            instruction = runtime.desktop_instruction('Save the report', value, [])
            for _ in range(2): runtime.routed_json_prompt(router, client, instruction, image, 'planning', value)
            self.assertEqual(client.prompt_calls, 1); self.assertEqual(router.metrics['repairs'], 0)
            changed = copy.deepcopy(value)
            changed['observation_completeness']['local_expansion']['read_retries'] = 1
            runtime.routed_json_prompt(router, client, instruction, image, 'planning', changed)
            self.assertEqual(client.prompt_calls, 1) # Private diagnostics cannot add a generation.
            changed['observation_completeness']['reason_counts'] = {'child_limit': 1}
            changed['observation_completeness']['limitations'][0]['reason'] = 'child_limit'
            runtime.routed_json_prompt(router, client, instruction, image, 'planning', changed)
            self.assertEqual(client.prompt_calls, 2)
            bridge.assert_not_called()
