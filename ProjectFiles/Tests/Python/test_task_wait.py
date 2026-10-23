import sys
import unittest
import contextlib
import io
import json
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "AgentRuntime"))
import openclaw_runtime as runtime
from evidence_fixtures import native_result
from task_evidence import TaskEvidenceLedger
from task_execution import TaskContext, current_task
from task_wait import TaskWaitPublisher


class TaskWaitPresentationTests(unittest.TestCase):
    def test_operation_identity_and_revision_are_stable_within_one_operation(self):
        publisher = TaskWaitPublisher("generation")
        first = publisher.update("observing", "No confirmed result yet.", "Checking the current screen",
                                 operation_key="observe:1")
        repeated = publisher.update("observing", "No confirmed result yet.", "Checking the current screen",
                                    operation_key="observe:1")
        changed_detail = publisher.update("observing", "No confirmed result yet.", "Waiting for the page",
                                          operation_key="observe:1")
        next_operation = publisher.update("planning", "No confirmed result yet.", "Choosing the next step",
                                          operation_key="planning:1")

        self.assertEqual(first["revision"], 1)
        self.assertIsNone(repeated)
        self.assertEqual(changed_detail["revision"], 2)
        self.assertEqual(changed_detail["operation_id"], first["operation_id"])
        self.assertEqual(next_operation["revision"], 3)
        self.assertEqual(next_operation["operation_id"], first["operation_id"] + 1)

    def test_snapshots_are_bounded_and_strip_control_characters(self):
        publisher = TaskWaitPublisher("generation")
        snapshot = publisher.update("unknown", "A\nconfirmed\tresult", "  " + "x" * 400,
                                    attention="unexpected", operation_key="test")
        self.assertEqual(snapshot["phase"], "reconciling")
        self.assertEqual(snapshot["attention"], "none")
        self.assertEqual(snapshot["last_confirmed"], "A confirmed result")
        self.assertLessEqual(len(snapshot["waiting_for"].encode("utf-8")), 240)
        self.assertNotIn("\n", snapshot["last_confirmed"])

    def test_expected_results_are_prospective_and_do_not_expose_values_or_commands(self):
        self.assertEqual(runtime.expected_wait_description({
            "expected_result": {"type": "dialog_appeared", "title": "Export dialog"}
        }), "Export dialog")
        self.assertEqual(runtime.expected_wait_description({
            "expected_result": {"type": "field_value", "value": "private value"}
        }), "The expected field update")
        self.assertEqual(runtime.expected_wait_description({
            "action": {"type": "run_command", "command": "secret command"}
        }), "The requested command result")

    def test_model_wait_publication_is_generation_scoped_and_does_not_add_work(self):
        context = TaskContext("fixture request", 1, "00000000-0000-4000-8000-000000000001")
        token = current_task.set(context)
        output = io.StringIO()
        try:
            with contextlib.redirect_stdout(output), mock.patch.object(runtime, "bridge_call") as bridge:
                runtime.emit("wait_phase", phase="model_response", waiting_for="The model’s response")
            bridge.assert_not_called()
        finally:
            current_task.reset(token)

        message = json.loads(output.getvalue())
        self.assertEqual(message["kind"], "task_wait")
        self.assertEqual(message["task_generation_id"], context.generation)
        self.assertEqual(message["phase"], "model_response")
        self.assertEqual(message["waiting_for"], "The model’s response")

    def test_last_confirmation_uses_current_evidence_and_redacts_paths(self):
        task = "Write the report to /fixture/private/report.pdf."
        ledger = TaskEvidenceLedger(task, "generation")
        ledger.add_requirements([{
            "source": "Write the report",
            "description": "Write the requested report",
            "check": {"type": "file_contents", "path": "/fixture/private/report.pdf", "content": "private bytes"},
        }])
        action = {"type": "write_file", "path": "/fixture/private/report.pdf", "content": "private bytes"}
        ledger.record_action(action, native_result(action))
        self.assertEqual(ledger.latest_confirmed_status(), "File contents matched: report.pdf")
        self.assertNotIn("/fixture/private", ledger.latest_confirmed_status())
        self.assertNotIn("private bytes", ledger.latest_confirmed_status())

        ledger.before_action({"type": "run_command", "argv": ["/fixture/mutate"]})
        self.assertEqual(ledger.latest_confirmed_status(), "No confirmed result yet.")

    def test_command_exit_alone_never_claims_the_requested_effect(self):
        task = "Run the requested command and report its result."
        ledger = TaskEvidenceLedger(task, "generation-command")
        ledger.add_requirements([{
            "source": task,
            "description": "Complete the requested operation",
            "check": {"type": "command_executed", "argv": ["/fixture/command"]},
        }])
        action = {"type": "run_command", "argv": ["/fixture/command"]}
        ledger.record_action(action, native_result(action, exit_code=0, timed_out=False, working_directory="/fixture"))
        self.assertEqual(ledger.latest_confirmed_status(),
                         "Command finished; its requested result is not confirmed")


if __name__ == "__main__":
    unittest.main()
