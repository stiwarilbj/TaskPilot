import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "AgentRuntime"))
from task_destination import TaskDestinationPublisher, planned_destination, explicit_destination_instruction
from task_evidence import TaskEvidenceLedger
from openclaw_runtime import action_destination, prompt_observation


class TaskDestinationTests(unittest.TestCase):
    def test_planned_destination_comes_from_explicit_output_reference(self):
        ledger = TaskEvidenceLedger("Export the report to /Users/test/Downloads/Reports/October.pdf.")
        self.assertEqual(planned_destination(ledger),
                         ("/Users/test/Downloads/Reports/October.pdf", "October.pdf"))

    def test_input_paths_and_ambiguous_multiple_outputs_are_not_guessed(self):
        input_only = TaskEvidenceLedger("Summarize /Users/test/Reports/October.pdf.")
        self.assertEqual(planned_destination(input_only), (None, None))
        multiple = TaskEvidenceLedger(
            "Export the report to /Users/test/Reports/October.pdf and /Users/test/Reports/November.pdf.")
        self.assertEqual(planned_destination(multiple), (None, None))
        separate = TaskEvidenceLedger(
            "Export the report to /Users/test/Reports/October.pdf. Then export another to /Users/test/Reports/November.pdf.")
        self.assertEqual(planned_destination(separate), (None, None))

    def test_filename_is_shown_only_when_explicitly_scoped_as_output(self):
        ledger = TaskEvidenceLedger("Save the report as October.pdf.")
        self.assertEqual(planned_destination(ledger), (None, "October.pdf"))

    def test_exact_input_file_and_folder_references_are_output_destinations(self):
        def ledger_with_reference(task, kind, value):
            start = len(task[:task.index(value)].encode("utf-8"))
            return TaskEvidenceLedger(task, exact_input_references=[{
                "version": 2,
                "kind": kind,
                "utf8_start": start,
                "utf8_length": len(value.encode("utf-8")),
                "value": value,
            }])

        folder = "/Users/test/Downloads/Reports"
        self.assertEqual(planned_destination(ledger_with_reference(
            f"Save the report to {folder}", "folder", folder)), (folder, None))
        file_path = "/Users/test/Downloads/Reports/October.pdf"
        self.assertEqual(planned_destination(ledger_with_reference(
            f"Export the report as {file_path}", "file", file_path)), (file_path, "October.pdf"))
        self.assertEqual(planned_destination(ledger_with_reference(
            "Export the report as October.pdf", "text", "October.pdf")), (None, "October.pdf"))

    def test_instruction_requires_one_clear_explicit_policy(self):
        self.assertEqual(explicit_destination_instruction("Create a new copy of the report."),
                         "Create a new copy")
        self.assertEqual(explicit_destination_instruction("Replace the existing file."),
                         "Replace existing file")
        self.assertEqual(explicit_destination_instruction("Append to the report."), "Append")
        self.assertIsNone(explicit_destination_instruction("Save the report."))
        self.assertIsNone(explicit_destination_instruction("Create a new copy and overwrite the old file."))
        self.assertIsNone(explicit_destination_instruction('Save this phrase: "overwrite the existing file".'))
        self.assertEqual(explicit_destination_instruction("Do not overwrite; create a new copy."),
                         "Create a new copy")
        self.assertIsNone(explicit_destination_instruction("Do not create a new copy."))
        self.assertIsNone(explicit_destination_instruction("No need to create a new copy."))
        self.assertIsNone(explicit_destination_instruction("Do not append to the report."))

    def test_exact_reference_text_cannot_supply_overwrite_policy(self):
        task = "Create a report using overwrite existing file as the input name."
        start = len("Create a report using ".encode("utf-8"))
        length = len("overwrite existing file".encode("utf-8"))
        self.assertIsNone(explicit_destination_instruction(
            task, [("text", start, length, "overwrite existing file")]))

    def test_action_destinations_are_limited_to_supported_native_and_deterministic_operands(self):
        self.assertEqual(action_destination({"type": "write_file", "path": "/tmp/out.pdf"}),
                         ("/tmp/out.pdf", "native_write"))
        self.assertEqual(action_destination({"type": "run_command", "operation": {
            "type": "copy_file", "source": "/tmp/in", "destination": "/tmp/out"}}),
            ("/tmp/out", "deterministic_command"))
        self.assertEqual(action_destination({"type": "run_command", "command": "cp a b"}), (None, None))

    def test_save_dialog_destination_must_match_the_observed_save_control(self):
        action = {"type": "click", "element_id": "save-button"}
        target = {"id": "save-button", "pid": 41, "window_id": "window-a", "title": "Save"}
        panel = {"pid": 41, "window_id": "window-a", "path_confirmed": True,
                 "actual_path": "/Users/test/Reports/October.pdf"}
        observation = {"elements": [target], "save_panel_destinations": [panel]}
        self.assertEqual(action_destination(action, observation), (panel["actual_path"], "save_panel"))
        observation["save_panel_destinations"] = [{**panel, "window_id": "window-b"}]
        self.assertEqual(action_destination(action, observation), (None, None))
        observation["save_panel_destinations"] = [panel, {**panel, "actual_path": "/tmp/other.pdf"}]
        self.assertEqual(action_destination(action, observation), (None, None))

    def test_save_panel_paths_are_removed_before_prompt_compilation(self):
        private_path = "/Users/test/private/Reports/October.pdf"
        observation = {"save_panel_destinations": [{"actual_path": private_path, "selected_filename": "October.pdf"}],
                      "elements": []}
        prompt = prompt_observation(observation)
        self.assertNotIn("save_panel_destinations", prompt)
        self.assertNotIn(private_path, repr(prompt))

    def test_publisher_deduplicates_and_scopes_revisions_to_operations(self):
        publisher = TaskDestinationPublisher("generation")
        first = publisher.update(state="planned", operation_key="plan:0",
                                 planned_path="/tmp/Report.pdf", requested_filename="Report.pdf")
        same = publisher.update(state="planned", operation_key="plan:0",
                                planned_path="/tmp/Report.pdf", requested_filename="Report.pdf")
        selected = publisher.update(state="checking", operation_key="save:1:native_write",
                                    planned_path="/tmp/Report.pdf", actual_path="/tmp/Report.pdf",
                                    requested_filename="Report.pdf", destination_exists=True,
                                    instruction="Create a new copy")
        self.assertEqual(first["revision"], 1)
        self.assertIsNone(same)
        self.assertEqual(selected["revision"], 2)
        self.assertEqual(selected["operation_id"], first["operation_id"] + 1)
        self.assertTrue(selected["destination_exists"])

    def test_invalid_paths_and_untrusted_policy_text_are_dropped(self):
        publisher = TaskDestinationPublisher("generation")
        snapshot = publisher.update(state="selected", operation_key="save",
                                    actual_path="relative/file.pdf", instruction="password=secret")
        self.assertEqual(snapshot["state"], "selected_unconfirmed")
        self.assertIsNone(snapshot["actual_path"])
        self.assertIsNone(snapshot["instruction"])

    def test_paths_and_filenames_preserve_internal_whitespace(self):
        publisher = TaskDestinationPublisher("generation")
        snapshot = publisher.update(state="preparing", operation_key="save",
                                    actual_path="/tmp/Report  October.pdf",
                                    requested_filename="Report  October.pdf")
        self.assertEqual(snapshot["actual_path"], "/tmp/Report  October.pdf")
        self.assertEqual(snapshot["requested_filename"], "Report  October.pdf")


if __name__ == "__main__":
    unittest.main()
