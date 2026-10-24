"""Correction controls preserve completed history without trusting old plans."""
import io
import json
from pathlib import Path
import sys
import unittest
from unittest import mock
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "AgentRuntime"))
from action_receipts import RuntimeInbox
from task_evidence import EvidenceValidationError, TaskEvidenceLedger
from task_execution import Phase, TaskContext
import openclaw_runtime as runtime


ORIGINAL = "Run /fixture/old-tool and save its report."
CORRECTION = "Use /fixture/new-tool instead."
EFFECTIVE = ORIGINAL + "\n\nUser correction: " + CORRECTION


class InstructionCorrectionTests(unittest.TestCase):
    def test_correction_mailbox_is_generation_scoped_and_does_not_consume_other_replies(self):
        generation = str(uuid.uuid4())
        inbox = RuntimeInbox(io.StringIO(""))
        key = inbox.register_instruction_corrections(generation)
        stale = {"kind": "instruction_correction", "task_generation_id": str(uuid.uuid4()),
                 "instruction_revision": 1, "correction": {"instruction_revision": 1}}
        accepted = {"kind": "instruction_correction", "task_generation_id": generation,
                    "instruction_revision": 1, "correction": {"instruction_revision": 1}}
        inbox._enqueue(json.dumps(stale).encode())
        inbox._enqueue(json.dumps(accepted).encode())
        self.assertTrue(inbox.has_instruction_correction())
        self.assertEqual(json.loads(inbox.take_instruction_correction(0))["task_generation_id"], generation)
        self.assertFalse(inbox.has_instruction_correction())

    def test_secure_input_wait_stores_correction_and_never_returns_stale_secret(self):
        generation, correction_id = str(uuid.uuid4()), str(uuid.uuid4())
        correction = {"version": 1, "correction_id": correction_id, "instruction_revision": 1,
                      "request": "Use the other spreadsheet", "exact_input_references": []}
        frame = {"kind": "instruction_correction", "task_generation_id": generation,
                 "instruction_revision": 1, "correction": correction}
        stream = io.StringIO(json.dumps(frame) + "\n")
        inbox = RuntimeInbox(stream)
        context = TaskContext(ORIGINAL, 1, generation)
        context.inbox = inbox
        context.correction_key = inbox.register_instruction_corrections(generation)
        token = runtime.current_task.set(context)
        try:
            with mock.patch.object(runtime, "_runtime_inbox", inbox):
                with self.assertRaises(runtime.InstructionSuperseded):
                    runtime.wait_for_user_input("secure-request")
                self.assertTrue(runtime.instruction_correction_pending())
                self.assertEqual(context.pending_correction_message["correction"]["correction_id"], correction_id)
        finally:
            runtime.current_task.reset(token)

    def test_duplicate_acknowledged_correction_is_idempotent(self):
        generation, correction_id = str(uuid.uuid4()), str(uuid.uuid4())
        correction = {"version": 1, "correction_id": correction_id, "instruction_revision": 1,
                      "request": "Use the other spreadsheet", "exact_input_references": []}
        message = {"kind": "instruction_correction", "task_generation_id": generation,
                   "instruction_revision": 1, "correction": correction}
        inbox = RuntimeInbox(io.StringIO(""))
        context = TaskContext(ORIGINAL, 1, generation, instruction_revision=1,
            correction_key=inbox.register_instruction_corrections(generation),
            instruction_corrections=[{"id": correction_id, "revision": 1,
                                      "request": correction["request"],
                                      "exact_input_references": []}])
        context.inbox = inbox
        inbox._enqueue(json.dumps(message).encode())
        token = runtime.current_task.set(context)
        try:
            with mock.patch.object(runtime, "_runtime_inbox", inbox):
                self.assertTrue(runtime.receive_instruction_correction()["duplicate"])
                self.assertEqual(context.instruction_revision, 1)
        finally:
            runtime.current_task.reset(token)

    def test_correction_arriving_during_model_wait_discards_response_without_repair(self):
        generation = str(uuid.uuid4())
        inbox = RuntimeInbox(io.StringIO(""))
        context = TaskContext(ORIGINAL, 1, generation, correction_key=inbox.register_instruction_corrections(generation), inbox=inbox)
        correction = {"version": 1, "correction_id": str(uuid.uuid4()), "instruction_revision": 1,
                      "request": CORRECTION, "exact_input_references": []}
        control = {"kind": "instruction_correction", "task_generation_id": generation,
                   "instruction_revision": 1, "correction": correction}

        class Client:
            prompt_calls = 0
            def prompt(self, *_args, **_kwargs):
                self.prompt_calls += 1
                inbox._enqueue(json.dumps(control).encode())
                return "not valid JSON; must never enter repair or fallback"

        client = Client()
        budget = runtime.ResponseRepairBudget()
        token = runtime.current_task.set(context)
        try:
            with mock.patch.object(runtime, "detail_images", return_value=[]):
                with self.assertRaises(runtime.InstructionSuperseded):
                    runtime.validated_prompt(client, "old decision", Path("/unused"), "planning", budget)
            self.assertEqual(client.prompt_calls, 1)
            self.assertFalse(budget.used)
            self.assertTrue(runtime.instruction_correction_pending())
        finally:
            runtime.current_task.reset(token)

    def test_correction_arriving_during_validation_skips_the_repair_request(self):
        generation = str(uuid.uuid4())
        inbox = RuntimeInbox(io.StringIO(""))
        context = TaskContext(ORIGINAL, 1, generation, correction_key=inbox.register_instruction_corrections(generation), inbox=inbox)
        correction = {"version": 1, "correction_id": str(uuid.uuid4()), "instruction_revision": 1,
                      "request": CORRECTION, "exact_input_references": []}
        control = {"kind": "instruction_correction", "task_generation_id": generation,
                   "instruction_revision": 1, "correction": correction}

        class Client:
            prompt_calls = 0
            def prompt(self, *_args, **_kwargs):
                self.prompt_calls += 1
                return "malformed but terminal"

        client, budget = Client(), runtime.ResponseRepairBudget()
        token = runtime.current_task.set(context)
        def invalidated_parse(_response):
            inbox._enqueue(json.dumps(control).encode())
            raise runtime.ResponseValidationError("response must contain one object")
        try:
            with mock.patch.object(runtime, "detail_images", return_value=[]), \
                 mock.patch.object(runtime, "extract_json_object", side_effect=invalidated_parse):
                with self.assertRaises(runtime.InstructionSuperseded):
                    runtime.validated_prompt(client, "old decision", Path("/unused"), "planning", budget)
            self.assertEqual(client.prompt_calls, 1)
            self.assertFalse(budget.used)
        finally:
            runtime.current_task.reset(token)

    def test_applying_correction_preserves_utf8_chip_ranges_and_invalidates_mutable_proof(self):
        generation, correction_id = str(uuid.uuid4()), str(uuid.uuid4())
        request = "Use /fixture/café.xlsx as the source."
        value = "/fixture/café.xlsx"
        encoded = request.encode("utf-8")
        start = encoded.index(value.encode("utf-8"))
        reference = {"version": runtime.EXACT_INPUT_REFERENCE_VERSION, "kind": "file",
                     "utf8_start": start, "utf8_length": len(value.encode("utf-8")), "value": value}
        correction = {"version": 1, "correction_id": correction_id, "instruction_revision": 1,
                      "request": request, "exact_input_references": [reference]}
        message = {"kind": "instruction_correction", "task_generation_id": generation,
                   "instruction_revision": 1, "correction": correction}
        ledger = TaskEvidenceLedger(ORIGINAL, generation)
        ledger.add_requirements([{"source": ORIGINAL, "description": "The report exists",
            "check": {"type": "file_exists", "path": "/fixture/report.txt"}}])
        evidence_id = ledger.add_evidence({"type": "file_exists", "path": "/fixture/report.txt"}, mutable=True)
        ledger.requirements["r1"]["evidence_ids"] = [evidence_id]
        ledger.refresh()
        context = TaskContext(ORIGINAL, 1, generation, ledger=ledger, correction_key=("instruction_correction", None, generation),
                              pending_correction_message=message)
        token = runtime.current_task.set(context)
        emitted = []
        try:
            with mock.patch.object(runtime, "emit", side_effect=lambda kind, **fields: emitted.append((kind, fields))):
                runtime.TaskExecution(context).apply_pending_correction()
            self.assertEqual(context.instruction_revision, 1)
            self.assertTrue(context.task.endswith("User correction: " + request))
            corrected_range = context.exact_input_references[-1]
            self.assertEqual(context.task.encode("utf-8")[corrected_range["utf8_start"]:
                corrected_range["utf8_start"] + corrected_range["utf8_length"]].decode(), value)
            self.assertIn(evidence_id, ledger.evidence)
            self.assertFalse(ledger.evidence[evidence_id]["valid"])
            self.assertFalse(ledger.can_complete())
            self.assertIn(("instruction_correction_applied", {"correction_id": correction_id,
                "instruction_revision": 1}), emitted)
        finally:
            runtime.current_task.reset(token)

    def test_planning_prompt_requires_inspection_before_revising_completed_mutations(self):
        ledger = TaskEvidenceLedger(ORIGINAL, "fixture-generation")
        ledger.apply_instruction_revision(ORIGINAL + "\n\nUser correction: Use the corrected destination", [])
        policy = runtime.checklist_instruction(ledger)
        self.assertIn("inspect its current result first", policy)
        self.assertIn("Never repeat a mutation solely because a correction arrived", policy)

    def test_completion_rechecks_after_a_rolled_back_correction_barrier_without_model_call(self):
        class Ledger:
            def can_complete(self, _message): return True

        context = TaskContext(ORIGINAL, 1, str(uuid.uuid4()), ledger=Ledger())
        context.machine.transition(Phase.OBSERVING)
        context.machine.transition(Phase.VERIFYING, local_request=True)
        token = runtime.current_task.set(context)
        gate = mock.Mock(side_effect=[{"accepted": False, "pending_correction": True},
                                     {"accepted": True, "pending_correction": False}])
        emitted = []
        try:
            with mock.patch.object(runtime, "bridge_call", gate), \
                 mock.patch.object(runtime, "receive_instruction_correction", side_effect=TimeoutError), \
                 mock.patch.object(runtime, "publish_task_wait"), \
                 mock.patch.object(runtime, "publish_task_progress"), \
                 mock.patch.object(runtime, "emit", side_effect=lambda kind, **fields: emitted.append((kind, fields))):
                runtime.complete_from_decision({"output": "Existing verified result"}, "fallback", context.ledger)
            self.assertEqual(gate.call_count, 2)
            self.assertEqual(context.instruction_revision, 0)
            self.assertEqual([kind for kind, _ in emitted], ["complete"])
        finally:
            runtime.current_task.reset(token)

    def test_latest_correction_can_supersede_only_explicitly_replaced_requirements(self):
        ledger = TaskEvidenceLedger(ORIGINAL, "fixture-generation")
        old = {"source": "Run /fixture/old-tool", "description": "Run the original tool",
               "check": {"type": "command_executed", "argv": ["/fixture/old-tool"],
                         "working_directory": "/fixture"}}
        ledger.add_requirements([old])
        ledger.add_evidence({"type": "command_executed", "argv": ["/fixture/old-tool"],
                             "working_directory": "/fixture"})
        old_evidence = next(iter(ledger.evidence))
        self.assertEqual(ledger.requirements["r1"]["state"], "proven")

        ledger.apply_instruction_revision(EFFECTIVE, [])
        replacement = {"source": CORRECTION, "description": "Use the corrected tool",
                      "check": {"type": "command_executed", "argv": ["/fixture/new-tool"],
                                "working_directory": "/fixture"},
                      "supersedes": ["r1"]}
        ledger.add_requirements([replacement])
        self.assertEqual(ledger.requirements["r1"]["state"], "superseded")
        self.assertEqual(ledger.requirements["r2"]["state"], "pending")
        self.assertTrue(ledger.evidence[old_evidence]["valid"], "immutable action history remains attributable")
        state = ledger.prompt_state()
        self.assertEqual(set(state["requirements"]), {"r2"})
        self.assertEqual(state["superseded_requirements"]["r1"]["superseded_by"], "r2")

        # A repeated planning response is idempotent and cannot create r3.
        ledger.add_requirements([replacement])
        self.assertEqual(set(ledger.requirements), {"r1", "r2"})
        ledger.add_evidence({"type": "command_executed", "argv": ["/fixture/new-tool"],
                             "working_directory": "/fixture"})
        proof_id = next(identifier for identifier, evidence in ledger.evidence.items()
                        if evidence["fact"].get("argv") == ["/fixture/new-tool"])
        result = {"verified": True, "coverage_complete": True, "message": "Corrected report is ready",
                  "proofs": [{"requirement_id": "r2", "evidence_ids": [proof_id],
                              "rationale": "The corrected executable was verified"}]}
        self.assertTrue(ledger.audit(result))
        self.assertEqual(ledger.requirements["r1"]["state"], "superseded")

    def test_supersession_rejects_initial_unknown_unquoted_and_uncovered_claims(self):
        ledger = TaskEvidenceLedger(ORIGINAL, "fixture-generation")
        original = {"source": ORIGINAL, "description": "Original", "check": {"type": "visual", "expected": "Old"}}
        ledger.add_requirements([original])
        replacement = {"source": "Run /fixture/old-tool", "description": "Replacement",
                       "check": {"type": "visual", "expected": "New"}, "supersedes": ["r1"]}
        with self.assertRaisesRegex(EvidenceValidationError, "current user correction"):
            ledger.add_requirements([replacement])
        ledger.apply_instruction_revision(EFFECTIVE, [])
        valid_source = {**replacement, "source": CORRECTION}
        with self.assertRaisesRegex(EvidenceValidationError, "existing requirements"):
            ledger.add_requirements([{**valid_source, "supersedes": ["r99"]}])
        with self.assertRaisesRegex(EvidenceValidationError, "current user correction"):
            ledger.add_requirements([replacement])
        with self.assertRaisesRegex(EvidenceValidationError, "only quote a current user correction"):
            ledger.add_requirements([valid_source], path="uncovered_requirements")
        self.assertEqual(ledger.requirements["r1"]["state"], "pending")

    def test_revision_invalidates_mutable_state_but_retains_its_historical_record(self):
        ledger = TaskEvidenceLedger(ORIGINAL, "fixture-generation")
        entry = {"source": ORIGINAL, "description": "The output exists",
                 "check": {"type": "file_exists", "path": "/fixture/report.txt"}}
        ledger.add_requirements([entry])
        identifier = ledger.add_evidence({"type": "file_exists", "path": "/fixture/report.txt"}, mutable=True)
        ledger.requirements["r1"]["evidence_ids"] = [identifier]
        ledger.refresh()
        self.assertEqual(ledger.requirements["r1"]["state"], "proven")
        ledger.apply_instruction_revision(EFFECTIVE, [])
        self.assertIn(identifier, ledger.evidence)
        self.assertFalse(ledger.evidence[identifier]["valid"])
        self.assertEqual(ledger.requirements["r1"]["state"], "invalidated")
        self.assertFalse(ledger.can_complete())


if __name__ == "__main__":
    unittest.main()
