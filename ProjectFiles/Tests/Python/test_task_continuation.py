from pathlib import Path
import hashlib
import sys
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "AgentRuntime"))
from evidence_fixtures import native_check, native_result
from task_evidence import EvidenceValidationError, TaskEvidenceLedger, content_hash


TASK = "Create /fixture/a.txt, /fixture/b.txt, and /fixture/c.txt with requested contents."


def _write(path, content):
    action = {"type": "write_file", "path": path, "content": content}
    return action, native_result(action)


def _two_of_three(generation=None):
    generation = generation or str(uuid.uuid4())
    ledger = TaskEvidenceLedger(TASK, generation)
    ledger.add_requirements([
        {"source": TASK, "description": f"Create {path} with {content}",
         "check": {"type": "file_contents", "path": path, "content": content}}
        for path, content in (("/fixture/a.txt", "A"), ("/fixture/b.txt", "B"), ("/fixture/c.txt", "C"))
    ])
    for path, content in (("/fixture/a.txt", "A"), ("/fixture/b.txt", "B")):
        action, result = _write(path, content)
        ledger.record_action(action, result)
    return ledger


def _checkpoint(ledger, *, unresolved=0):
    checkpoint = ledger.continuation_snapshot(instruction_revision=0, unresolved_receipts=unresolved, revision=1)
    if checkpoint is not None:
        checkpoint["eligible"] = True
    return checkpoint


class TaskContinuationTests(unittest.TestCase):
    def test_two_of_three_creates_a_bounded_checkpoint_without_importing_proof_or_actions(self):
        source = _two_of_three()
        checkpoint = _checkpoint(source)
        self.assertIsNotNone(checkpoint)
        self.assertEqual([item["previously_proven"] for item in checkpoint["requirements"]], [True, True, False])
        self.assertEqual(checkpoint["source_task_generation_id"], source.generation)
        self.assertEqual(checkpoint["unresolved_receipts"], 0)
        self.assertLessEqual(len(str(checkpoint).encode()), 262_144)
        self.assertNotIn("evidence", checkpoint)
        self.assertNotIn("actions", checkpoint)

        continuation = TaskEvidenceLedger(TASK, str(uuid.uuid4()))
        continuation.initialize_continuation(checkpoint)
        self.assertEqual([item["state"] for item in continuation.requirements.values()], ["pending"] * 3)
        self.assertEqual(continuation.evidence, {})
        self.assertEqual(continuation.continuation_prior_verified_ids, {"r1", "r2"})
        self.assertEqual(continuation.prompt_state()["continuation"]["unfinished_requirement_ids"], ["r1", "r2", "r3"])

    def test_local_recheck_requires_matching_identity_and_contents(self):
        source = _two_of_three()
        checkpoint = _checkpoint(source)
        continuation = TaskEvidenceLedger(TASK, str(uuid.uuid4()))
        continuation.initialize_continuation(checkpoint)

        check = continuation.requirements["r1"]["check"]
        expected = checkpoint["expected_file_identities"]["r1"]
        changed_identity = native_check(check, file_identity="0" * 64)
        continuation.record_effect(check, changed_identity)
        self.assertEqual(continuation.requirements["r1"]["state"], "pending")
        self.assertNotIn("r1", continuation.continuation_rechecked_ids)

        changed_content = native_check(check, **expected, content_sha256="0" * 64)
        continuation.record_effect(check, changed_content)
        self.assertEqual(continuation.requirements["r1"]["state"], "pending")

        current = native_check(check, **expected, content_sha256=content_hash({"content": "A"}))
        continuation.record_effect(check, current)
        self.assertEqual(continuation.requirements["r1"]["state"], "proven")
        self.assertIn("r1", continuation.continuation_rechecked_ids)
        self.assertEqual(continuation.requirements["r2"]["state"], "pending")

    def test_checkpoint_rejects_changed_task_or_exact_input_references(self):
        task = "Summarize /fixture/input.pdf and create /fixture/out.txt"
        path = "/fixture/input.pdf"
        reference = {"version": 1, "kind": "file", "utf8_start": task.index(path),
                     "utf8_length": len(path.encode()), "value": path}
        source = TaskEvidenceLedger(task, str(uuid.uuid4()), exact_input_references=[reference])
        source.add_requirements([{"source": "create /fixture/out.txt", "description": "Create the output",
                                  "check": {"type": "file_contents", "path": "/fixture/out.txt", "content": "done"}}])
        action, result = _write("/fixture/out.txt", "done")
        source.record_action(action, result)
        checkpoint = _checkpoint(source)

        with self.assertRaisesRegex(EvidenceValidationError, "stale or malformed"):
            TaskEvidenceLedger(task, str(uuid.uuid4())).initialize_continuation(checkpoint)
        with self.assertRaisesRegex(EvidenceValidationError, "stale or malformed"):
            TaskEvidenceLedger(task + " extra", str(uuid.uuid4()), exact_input_references=[reference]).initialize_continuation(checkpoint)

    def test_source_generation_and_unresolved_receipts_prevent_automatic_replay(self):
        source = _two_of_three()
        self.assertIsNone(_checkpoint(source, unresolved=1))
        checkpoint = _checkpoint(source)
        restarted_generation = str(uuid.uuid4())
        checkpoint["source_task_generation_id"] = restarted_generation
        with self.assertRaisesRegex(EvidenceValidationError, "source task"):
            TaskEvidenceLedger(TASK, restarted_generation).initialize_continuation(checkpoint)

    def test_no_usable_verified_results_produces_no_checkpoint(self):
        ledger = TaskEvidenceLedger(TASK, str(uuid.uuid4()))
        ledger.add_requirements([
            {"source": "Create /fixture/a.txt", "description": "Create A",
             "check": {"type": "file_contents", "path": "/fixture/a.txt", "content": "A"}}
        ])
        self.assertIsNone(_checkpoint(ledger))

    def test_browser_continuation_rechecks_exact_destination_not_just_window_title(self):
        task = "Open the example page and leave it visible."
        source_generation = str(uuid.uuid4())
        source = TaskEvidenceLedger(task, source_generation)
        source.add_requirements([{
            "source": task,
            "description": "Leave the example page visible",
            "check": {"type": "window_active", "pid": 42, "title": "Example Domain"},
        }])
        observation = {
            "task_generation_id": source_generation,
            "observation_revision": "source-rev-1",
            "applications": [{
                "pid": 42, "name": "Safari", "bundle_id": "com.apple.Safari",
                "active": True, "topmost_on_agent_screen": True,
                "windows": [{"title": "Example Domain", "topmost_on_agent_screen": True}],
            }],
            "result_destinations": [{
                "pid": 42, "window_title": "Example Domain", "bundle_id": "com.apple.Safari",
                "title": "Example Domain", "url": "https://example.com/reports?month=october",
                "observation_revision": "source-rev-1",
            }],
        }
        source.observe(observation)
        checkpoint = _checkpoint(source)
        self.assertEqual(
            checkpoint["expected_web_destinations"]["r1"],
            hashlib.sha256(b"https://example.com/reports?month=october").hexdigest(),
        )

        continuation_generation = str(uuid.uuid4())
        continuation = TaskEvidenceLedger(task, continuation_generation)
        continuation.initialize_continuation(checkpoint)
        changed_destination = {
            **observation,
            "task_generation_id": continuation_generation,
            "observation_revision": "continuation-rev-1",
            "result_destinations": [{
                **observation["result_destinations"][0],
                "url": "https://example.com/reports?month=november",
                "observation_revision": "continuation-rev-1",
            }],
        }
        continuation.observe(changed_destination)
        self.assertEqual(continuation.requirements["r1"]["state"], "pending")
        self.assertNotIn("r1", continuation.continuation_rechecked_ids)

        same_destination = {
            **changed_destination,
            "observation_revision": "continuation-rev-2",
            "result_destinations": [{
                **observation["result_destinations"][0],
                "observation_revision": "continuation-rev-2",
            }],
        }
        continuation.observe(same_destination)
        self.assertEqual(continuation.requirements["r1"]["state"], "proven")
        self.assertIn("r1", continuation.continuation_rechecked_ids)


if __name__ == "__main__":
    unittest.main()
