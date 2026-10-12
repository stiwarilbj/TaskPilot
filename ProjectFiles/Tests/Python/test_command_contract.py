import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'AgentRuntime'))
import openclaw_runtime as runtime
from response_validation import normalize_action, ResponseValidationError


class CommandContractTests(unittest.TestCase):
    def test_literal_argument_arrays_and_checks_are_preserved(self):
        action = {'type': 'run_command', 'argv': ['/usr/bin/touch', "/tmp/space 'quote' $(no) `no`\n"],
                  'working_directory': '/tmp', 'checks': [{'type': 'file_exists', 'path': '/tmp/result'}]}
        self.assertEqual(normalize_action(action, {}), action)
        for check in [{'type': 'directory_exists', 'path': '/tmp'}, {'type': 'path_absent', 'path': '/tmp/gone'},
                      {'type': 'file_contents', 'path': '/tmp/a', 'content': ''},
                      {'type': 'file_contents', 'path': '/tmp/a', 'content': 'AP8B', 'encoding': 'base64'},
                      {'type': 'stdout_equals', 'text': ''}]:
            normalize_action({'type': 'run_command', 'argv': ['true'], 'checks': [check]}, {})

    def test_bad_command_parameters_report_precise_paths(self):
        cases = [({'argv': []}, 'action.argv'), ({'argv': 'echo'}, 'action.argv'),
                 ({'argv': ['echo', True]}, 'action.argv[1]'), ({'argv': ['echo', '\0']}, 'action.argv[1]'),
                 ({'argv': ['']}, 'action.argv[0]'), ({'command': 'true', 'argv': ['true']}, 'exactly one'),
                 ({'command': 'echo\0bad'}, 'action.command'), ({'command': 'x' * 16385}, 'action.command'),
                 ({'argv': ['echo', 'x' * 16384]}, 'action.argv'), ({'working_directory': '/tmp\0bad'}, 'working_directory'),
                 ({'checks': []}, 'action.checks'), ({'checks': [{}]}, 'action.checks[0].type'),
                 ({'checks': [{'type': 'file_exists'}]}, 'action.checks[0].path'),
                 ({'checks': [{'type': 'file_exists', 'path': 'relative'}]}, 'action.checks[0].path'),
                 ({'checks': [{'type': 'file_contents', 'path': '/tmp/a'}]}, 'action.checks[0].content'),
                 ({'checks': [{'type': 'stdout_equals', 'text': True}]}, 'action.checks[0].text'),
                 ({'checks': [{'type': 'stdout_equals', 'text': 'x' * 65537}]}, 'action.checks[0].text'),
                 ({'checks': [{'type': 'file_contents', 'path': '/tmp/a', 'content': '?', 'encoding': 'base64'}]}, 'action.checks[0].content'),
                 ({'checks': [{'type': 'file_exists', 'path': '/tmp/a', 'content': 'unused'}]}, 'unsupported parameters'),
                 ({'checks': [{'type': 'file_contents', 'path': '/tmp/a', 'content': 'x', 'encoding': {}}]}, 'action.checks[0].encoding'),
                 ({'command': '\ud800'}, 'valid UTF-8')]
        for fields, error in cases:
            action = {'type': 'run_command', 'argv': ['true']}
            if 'command' in fields and 'argv' not in fields: action.pop('argv')
            action.update(fields)
            with self.subTest(fields=list(fields), error=error), self.assertRaises(ResponseValidationError) as raised:
                normalize_action(action, {})
            self.assertIn(error, str(raised.exception))

    def test_matching_outcomes_alone_do_not_establish_full_task_coverage(self):
        action = {'type': 'run_command', 'argv': ['/usr/bin/touch', '/tmp/marker'],
                  'checks': [{'type': 'file_exists', 'path': '/tmp/marker'}]}
        result = {'exit_code': 0, 'timed_out': False, 'verified': True, 'verification_scope': 'requested_outcomes',
                  'checks': [{'type': 'file_exists', 'path': '/tmp/marker', 'verified': True}]}
        task = 'Run the shell command touch /tmp/marker'
        decision = {'finish_after_action': True, 'remaining_requirements': []}
        self.assertFalse(runtime.native_action_can_finish(task, decision, action, result, {}))
        self.assertFalse(runtime.trusted_native_history(task, {}, [{'action': action, 'result': result}]))
        invalid = [{'verified': False}, {'timed_out': True}, {'exit_code': False}, {'exit_code': 1},
                   {'verification_scope': 'execution_only'}, {'checks': []},
                   {'checks': [{'type': 'file_exists', 'path': '/tmp/other', 'verified': True}]},
                   {'checks': [{'type': 'file_exists', 'path': '/tmp/marker', 'verified': False}]}]
        for change in invalid:
            bad = {**result, **change}
            self.assertFalse(runtime.native_action_can_finish(task, decision, action, bad, {}))
            self.assertFalse(runtime.trusted_native_history(task, {}, [{'action': action, 'result': bad}]))
        execution_only = {'exit_code': 0, 'timed_out': False, 'stdout': '', 'stderr': ''}
        self.assertFalse(runtime.native_action_can_finish(task, decision, action, execution_only, {}))
        self.assertFalse(runtime.trusted_native_history(task, {}, [{'action': action, 'result': execution_only}]))

    def test_changing_timeout_or_checks_cannot_replay_unconfirmed_command(self):
        recovery = runtime.ActionRecovery()
        original = {'type': 'run_command', 'argv': ['touch', '/tmp/marker'], 'working_directory': '/tmp', 'timeout_seconds': 1}
        recovery.unconfirmed(original, {})
        changed = {**original, 'timeout_seconds': 10, 'checks': [{'type': 'file_exists', 'path': '/tmp/marker'}]}
        self.assertTrue(recovery.overlaps(original, {}, changed, {}))
        self.assertTrue(recovery.overlaps(original, {}, {'type': 'run_command', 'command': "touch '/tmp/marker'", 'working_directory': '/tmp/./'}, {}))
        self.assertFalse(recovery.overlaps(original, {}, {'type': 'run_command', 'argv': ['cat', '/tmp/marker'], 'working_directory': '/tmp'}, {}))
        self.assertFalse(recovery.overlaps(original, {}, {'type': 'run_command', 'argv': ['touch', '/tmp/different'], 'working_directory': '/tmp'}, {}))
        self.assertEqual(original, {'type': 'run_command', 'argv': ['touch', '/tmp/marker'], 'working_directory': '/tmp', 'timeout_seconds': 1})

    def test_prompts_request_literal_arguments_and_outcome_evidence(self):
        observation = {'elements': [], 'applications': []}
        prompt = runtime.desktop_instruction('Run git status in ~/project', observation, [])
        for text in ['prefer literal argv', 'single-quote paths', 'checks', 'file_contents', 'stdout_equals',
                     'Exit zero proves execution only', 'existing folder']:
            self.assertIn(text, prompt)
        self.assertLessEqual(len(prompt), 4000)
        self.assertIn('independent readback evidence', runtime.verification_instruction('Run a command', {}, observation, []))


if __name__ == '__main__':
    unittest.main()
