import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "AgentRuntime"))
from evidence_fixtures import native_result
from task_evidence import TaskEvidenceLedger


class TaskProgressProjectionTests(unittest.TestCase):
    def test_projection_uses_only_current_validated_evidence_and_redacts_file_contents(self):
        task = "Create the report at /fixture/report.txt and write PRIVATE-CONTENT."
        ledger = TaskEvidenceLedger(task, "generation-1")
        ledger.add_requirements([{
            "source": "Create the report",
            "description": "Create the requested report file",
            "check": {"type": "file_contents", "path": "/fixture/report.txt", "content": "PRIVATE-CONTENT"},
        }])

        active = ledger.presentation_state(["r1"])
        self.assertEqual(active["requirements"][0]["state"], "pending")
        self.assertTrue(active["requirements"][0]["active"])
        self.assertEqual(active["active_requirement_ids"], ["r1"])
        self.assertEqual(active["requirements"][0]["evidence"], [])

        action = {"type": "write_file", "path": "/fixture/report.txt", "content": "PRIVATE-CONTENT"}
        ledger.record_action(action, native_result(action))
        confirmed = ledger.presentation_state()
        requirement = confirmed["requirements"][0]
        self.assertEqual(requirement["state"], "proven")
        self.assertFalse(requirement["active"])
        self.assertNotIn("source", requirement)
        self.assertEqual(requirement["source_ranges"], [[0, len("Create the report".encode("utf-8"))]])
        self.assertEqual(confirmed["active_requirement_ids"], [])
        self.assertTrue(requirement["evidence"])
        self.assertIn("/fixture/report.txt", requirement["evidence"][0]["detail"])
        serialized = str(confirmed)
        self.assertNotIn("PRIVATE-CONTENT", serialized)
        self.assertNotIn("content", requirement)
        self.assertNotIn("content_sha256", serialized)
        self.assertNotIn("screenshot", serialized)

        ledger.before_action({"type": "run_command", "argv": ["/fixture/mutate"]})
        invalidated = ledger.presentation_state()
        self.assertEqual(invalidated["requirements"][0]["state"], "invalidated")
        self.assertEqual(invalidated["requirements"][0]["evidence"], [])

    def test_repeated_sources_are_retained_without_claiming_whole_request_coverage(self):
        task = "Create a report, then Create a report."
        ledger = TaskEvidenceLedger(task, "generation-2")
        ledger.add_requirements([
            {"source": "Create a report", "description": "First report", "check": {"type": "file_exists", "path": "/fixture/first"}},
            {"source": "Create a report", "description": "Second report", "check": {"type": "file_exists", "path": "/fixture/second"}},
        ])
        projection = ledger.presentation_state()
        task_bytes = task.encode("utf-8")
        sources = {identifier: item["source"].encode("utf-8")
                   for identifier, item in ledger.requirements.items()}
        self.assertTrue(all("source" not in item for item in projection["requirements"]))
        self.assertEqual(
            [[task_bytes[start:end].decode("utf-8") for start, end in item["source_ranges"]]
             for item in projection["requirements"]],
            [["Create a report", "Create a report"], ["Create a report", "Create a report"]],
        )
        for item in projection["requirements"]:
            self.assertTrue(all(task_bytes[start:end] == sources[item["id"]]
                                for start, end in item["source_ranges"]))
        self.assertEqual(projection["whole_request_coverage"], "pending")
        self.assertEqual([item["state"] for item in projection["requirements"]], ["pending", "pending"])

    def test_long_and_large_checklists_are_bounded_without_partial_source_quotes(self):
        pieces = [f"Clause {index} has its exact request wording." for index in range(530)]
        task = " ".join(pieces)
        ledger = TaskEvidenceLedger(task, "generation-3")
        ledger.add_requirements([
            {"source": piece, "description": f"Requirement {index}",
             "check": {"type": "file_exists", "path": f"/fixture/{index}"}}
            for index, piece in enumerate(pieces)
        ])
        projection = ledger.presentation_state()
        self.assertEqual(len(projection["requirements"]), 512)
        self.assertTrue(all("source" not in item for item in projection["requirements"]))
        self.assertLessEqual(sum(len(item["source_ranges"]) for item in projection["requirements"]), 4096)
        task_bytes = task.encode("utf-8")
        sources = {identifier: item["source"].encode("utf-8")
                   for identifier, item in ledger.requirements.items()}
        for item in projection["requirements"]:
            self.assertTrue(all(0 <= start < end <= len(task_bytes) and task_bytes[start:end] == sources[item["id"]]
                                for start, end in item["source_ranges"]))

    def test_request_literals_and_command_text_are_not_repeated_in_progress_snapshots(self):
        task = "Write PRIVATE-CONTENT to /fixture/result.txt and run git reset --hard."
        ledger = TaskEvidenceLedger(task, "generation-command")
        ledger.add_requirements([{
            "source": "Write PRIVATE-CONTENT",
            "description": "Write the requested literal",
            "check": {"type": "file_contents", "path": "/fixture/result.txt", "content": "PRIVATE-CONTENT"},
        }, {
            "source": "run git reset --hard",
            "description": "Run the requested command",
            "check": {"type": "command_executed", "command": "git reset --hard"},
        }])
        snapshot = ledger.presentation_state()
        serialized = str(snapshot)
        self.assertNotIn("PRIVATE-CONTENT", serialized)
        self.assertNotIn("git reset --hard", serialized)
        self.assertNotIn("/fixture/result.txt", serialized)
        self.assertTrue(all("source" not in item for item in snapshot["requirements"]))

    def test_unavailable_matching_proof_cannot_appear_confirmed(self):
        task = "Create the report at /fixture/report.txt."
        ledger = TaskEvidenceLedger(task, "generation-proof")
        ledger.add_requirements([{
            "source": "Create the report",
            "description": "Create the report",
            "check": {"type": "file_exists", "path": "/fixture/report.txt"},
        }])
        action = {"type": "write_file", "path": "/fixture/report.txt", "content": "report"}
        ledger.record_action(action, native_result(action))
        self.assertEqual(ledger.requirements["r1"]["state"], "proven")
        with mock.patch.object(ledger, "requirement_matches", return_value=False):
            projection = ledger.presentation_state()
        self.assertNotEqual(projection["requirements"][0]["state"], "proven")
        self.assertEqual(projection["requirements"][0]["evidence"], [])

    def test_active_marker_is_suspended_during_secure_input(self):
        task = "Enter the verification code and save the report."
        ledger = TaskEvidenceLedger(task, "generation-4")
        ledger.add_requirements([{
            "source": "save the report",
            "description": "Save the report",
            "check": {"type": "file_exists", "path": "/fixture/report"},
        }])
        waiting = ledger.presentation_state(["r1"], lifecycle="waiting_for_user")
        self.assertFalse(waiting["requirements"][0]["active"])


if __name__ == "__main__":
    unittest.main()
