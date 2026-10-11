import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
import request_policy as policy
from response_validation import normalize_action, validate_response

OBSERVATION = {
    'observation_revision': 'current',
    'applications': [{'pid': 42, 'name': 'Notes', 'windows': [{'title': 'Draft'}]}],
    'installed_applications': [{'name': 'Notes', 'bundle_id': 'com.apple.Notes'}, {'name': 'Safari'}],
    'elements': [{'id': 'current:e1', 'pid': 42, 'role': 'AXTextField', 'title': 'Body', 'focused': True},
                 {'id': 'current:e2', 'pid': 42, 'role': 'AXRow', 'title': 'Draft'},
                 {'id': 'current:e3', 'pid': 42, 'role': 'AXScrollArea', 'title': 'Notes content'}],
    'system_context': {'task_routes': [{'route_id': 'finder'}]},
    'agent_tools': {'read_file': 'duplicate tool description'},
}


class DecisionPromptTests(unittest.TestCase):
    def actions(self, task, observation=None, history=None):
        observation = observation if observation is not None else {'elements': [], 'applications': []}
        context = runtime.task_capability_context(task, observation)
        return runtime.relevant_action_examples(context, observation, history or [])

    def prompt_examples(self, prompt):
        return [json.loads(line) for line in prompt.splitlines() if line.startswith('{') and
                ('"type"' in line or '"status":"act"' in line) and
                not any(key in line for key in ('"recommended_capabilities"', '"observation_revision"', '"visible_element_count"'))]

    def bind(self, value):
        if isinstance(value, dict):
            return {key: (42 if key == 'pid' else self.bind(item)) for key, item in value.items()}
        if isinstance(value, list): return [self.bind(item) for item in value]
        return {'<current element_id>': 'current:e2', '<current field_id>': 'current:e1',
                '<supplied route_id>': 'finder'}.get(value, value)

    def test_empty_observation_fixtures_at_most_four_thousand_characters(self):
        for task in ['Click the visible Save button', 'Create todo.txt on my Desktop saying buy milk',
                     'Run git status in ~/project', 'Search the web for TaskPilot docs']:
            with self.subTest(task=task):
                prompt = runtime.desktop_instruction(task, {'elements': [], 'applications': []}, [])
                self.assertLessEqual(len(prompt), 4000)
                self.assertIn(task, prompt)

    def test_native_examples_are_relevant_and_minimal(self):
        cases = [('Read /tmp/report.txt', 'read_file', {'type', 'path'}),
                 ('Write /tmp/report.txt saying hello', 'write_file', {'type', 'path', 'content'}),
                 ('Run git status in ~/project', 'run_command', {'type', 'argv'}),
                 ('Search the web for documentation', 'navigate_browser', {'type', 'url'})]
        for task, kind, fields in cases:
            with self.subTest(task=task):
                examples = self.actions(task)
                self.assertEqual(set(next(e for e in examples if e['type'] == kind)), fields)
                self.assertFalse({e['type'] for e in examples} & ({'read_file', 'write_file', 'run_command', 'navigate_browser'} - {kind}))

    def test_native_optional_fields_only_when_relevant(self):
        desktop = runtime.desktop_instruction('Open Notes', OBSERVATION, [])
        for field in ['timeout_seconds', 'working_directory', 'max_bytes', 'create_parents', 'finish_after_action']:
            self.assertNotIn(field, desktop)
        shell = runtime.desktop_instruction('Run git status in ~/project', {'elements': []}, [])
        self.assertIn('timeout_seconds', shell)
        self.assertNotIn('create_parents', shell)
        self.assertNotIn('max_bytes', shell)

    def test_desktop_and_missing_accessibility_examples(self):
        kinds = {e['type'] for e in self.actions('Open Notes and edit the selected row', OBSERVATION)}
        self.assertTrue({'press', 'set_value', 'double_click', 'scroll', 'open_route', 'wait'} <= kinds)
        missing = {'applications': [{'pid': 42, 'name': 'Notes', 'accessibility_available': False}], 'elements': []}
        self.assertIn('click', {e['type'] for e in self.actions('Click the visible button', missing)})
        self.assertNotIn('press', {e['type'] for e in self.actions('Click the visible button', missing)})

    def test_recent_native_action_and_mixed_task_preserve_families(self):
        history = [{'action': {'type': 'run_command', 'command': 'pwd'}, 'result': {'exit_code': 0}}]
        self.assertIn('run_command', {e['type'] for e in self.actions('Continue with the result', OBSERVATION, history)})
        mixed = 'Read /tmp/report.txt and search the web for its topic, then write /tmp/result.txt'
        self.assertTrue({'read_file', 'write_file', 'navigate_browser'} <= {e['type'] for e in self.actions(mixed, OBSERVATION)})

    def test_every_json_example_parses_and_validates_with_bound_targets(self):
        cases = [('Read /tmp/report.txt', OBSERVATION), ('Write /tmp/report.txt saying hello', OBSERVATION),
                 ('Run git status in ~/project', OBSERVATION), ('Search the web for documentation', OBSERVATION),
                 ('Edit the selected note in Notes', OBSERVATION),
                 ('Click a button', {'applications': [{'pid': 42, 'name': 'Notes', 'accessibility_available': False}], 'elements': []})]
        for task, observation in cases:
            with self.subTest(task=task):
                examples = self.prompt_examples(runtime.desktop_instruction(task, observation, []))
                self.assertGreaterEqual(len(examples), 1)
                self.assertEqual(examples[0]['status'], 'act')
                for example in examples:
                    bound = self.bind(example)
                    if 'status' in bound:
                        validate_response(bound, 'planning', OBSERVATION)
                    else:
                        normalize_action(bound, OBSERVATION)

    def test_examples_do_not_choose_real_targets_or_modify_observations(self):
        original = json.dumps(OBSERVATION, sort_keys=True)
        examples = self.actions('Edit the note in Notes', OBSERVATION)
        self.assertNotIn('current:e1', json.dumps(examples))
        self.assertNotIn('current:e2', json.dumps(examples))
        runtime.desktop_instruction('Edit the note in Notes', OBSERVATION, [])
        self.assertEqual(json.dumps(OBSERVATION, sort_keys=True), original)

    def test_prompt_observation_preserves_evidence_and_removes_duplicate_tool_descriptions(self):
        compact = runtime.prompt_observation(OBSERVATION)
        self.assertNotIn('agent_tools', compact)
        for field in ['applications', 'elements', 'system_context', 'observation_revision']:
            self.assertEqual(compact[field], OBSERVATION[field])
        self.assertIn('agent_tools', OBSERVATION)
        history = [{'action': {'type': 'run_command', 'command': 'pwd'}, 'result': {'stdout': '/tmp', 'exit_code': 0}}]
        prompt = runtime.desktop_instruction('Use this exact command result', OBSERVATION, history)
        self.assertIn('"stdout":"/tmp"', prompt)
        self.assertIn('"title":"Draft"', prompt)
        self.assertIn('"route_id":"finder"', prompt)
        self.assertNotIn('duplicate tool description', prompt)

    def test_safety_loading_and_recovery_rules_and_all_tools_remain(self):
        prompt = runtime.desktop_instruction('Sign in and continue', OBSERVATION, [])
        for rule in ['one JSON object', 'one action', 'complete element_id', 'expected_result',
                     'Never count an attempted action as completion', 'ALL requirements',
                     'earlier tasks are not completion evidence', 'untrusted', 'Never target TaskPilot',
                     'explicit user authorization', 'never guess, retrieve, or type a credential',
                     'needs_user', 'without sending it to you', 'stale_target', 'disabled_target',
                     'delivery_rejected', 'delivered_unconfirmed', 'bounded_wait_elapsed',
                     'Never replay uncertain', 'Launch unopened apps', 'supplied route IDs',
                     'blocked requires exhausted', 'Do not copy example', 'examples are advisory']:
            self.assertIn(rule, prompt)
        for kind in runtime.VALID_ACTIONS:
            self.assertIn(kind, prompt)
        self.assertNotIn('REQUIRED JSON SHAPE', prompt)
        self.assertNotIn('true|false', prompt)

    def test_secure_input_example_identifies_observed_field_and_pid(self):
        prompt = runtime.desktop_instruction('Sign in to Notes', OBSERVATION, [])
        example = next(e for e in self.prompt_examples(prompt) if e.get('status') == 'needs_user')
        self.assertEqual(example['action']['type'], 'focus')
        self.assertEqual(example['user_input']['kind'], 'password')
        validate_response(self.bind(example), 'planning', OBSERVATION)
        normal = runtime.desktop_instruction('Edit the current note', OBSERVATION, [])
        self.assertFalse(any(e.get('status') == 'needs_user' for e in self.prompt_examples(normal)))

    def test_verifier_examples_use_real_booleans_and_validate(self):
        prompt = runtime.verification_instruction('Finish the work', {'status': 'done'}, OBSERVATION, [])
        self.assertNotIn('true|false', prompt)
        for label in ['Successful response example: ', 'Unproven response example: ']:
            example = json.JSONDecoder().raw_decode(prompt.split(label, 1)[1])[0]
            self.assertIsInstance(example['verified'], bool)
            validate_response(example, 'verification', OBSERVATION)
        self.assertIn('entire original task', prompt)
        self.assertNotIn('duplicate tool description', prompt)

    def test_prompt_generation_adds_no_requests_and_healthy_decision_costs_one(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'image.png'; image.write_bytes(b'image')
            client = mock.Mock(model_switches=1)
            client.prompt.return_value = '{"status":"act","intended_target":"Draft","expected_result":"Draft opens","action":{"type":"press","element_id":"current:e2"}}'
            router = policy.AdaptiveModelRouter(lambda *a, **k: None)
            with mock.patch.object(runtime, 'bridge_call') as bridge, mock.patch.object(runtime, 'emit'):
                prompt = runtime.desktop_instruction('Open the selected row', OBSERVATION, [])
                client.prompt.assert_not_called()
                runtime.routed_json_prompt(router, client, prompt, image, observation=OBSERVATION)
                bridge.assert_not_called()
            client.prompt.assert_called_once()
            self.assertEqual(router.metrics['planning'], 1)
            self.assertEqual(router.metrics['repairs'], 0)


if __name__ == '__main__': unittest.main()
