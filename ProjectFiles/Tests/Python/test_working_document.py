"""Working-document controls stay task-scoped and keep native identity private."""
import io
import json
from pathlib import Path
import sys
import unittest
import uuid
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "AgentRuntime"))
from action_receipts import RuntimeInbox
from task_execution import TaskContext, Phase
import openclaw_runtime as runtime


class WorkingDocumentControlTests(unittest.TestCase):
    def test_save_export_permission_comes_only_from_positive_user_wording(self):
        for task in ("Save this document as a PDF", "Export the selected table", "Don't send it, but save a draft"):
            self.assertTrue(runtime.task_requests_save_or_export(task), task)
        for task in ("Edit this document", "Don't save the document", "Do not send or save", "No need to export"):
            self.assertFalse(runtime.task_requests_save_or_export(task), task)

    def test_exact_input_values_cannot_grant_save_export_permission(self):
        task = "Inspect this reference: https://example.test/export"
        value = "https://example.test/export"
        start = task.encode("utf-8").index(value.encode("utf-8"))
        reference = {"version": 2, "kind": "url", "utf8_start": start,
                     "utf8_length": len(value.encode("utf-8")), "value": value}
        self.assertFalse(runtime.task_requests_save_or_export(task, [reference]))

        task = "Open this label: save"
        value = "save"
        start = task.encode("utf-8").rindex(value.encode("utf-8"))
        reference = {"version": 2, "kind": "text", "utf8_start": start,
                     "utf8_length": len(value.encode("utf-8")), "value": value}
        self.assertFalse(runtime.task_requests_save_or_export(task, [reference]))

    def test_explicit_save_instruction_remains_authorized_around_input(self):
        task = "Save this document as a copy beside /tmp/export-folder"
        value = "/tmp/export-folder"
        start = task.encode("utf-8").index(value.encode("utf-8"))
        reference = {"version": 2, "kind": "folder", "utf8_start": start,
                     "utf8_length": len(value.encode("utf-8")), "value": value}
        self.assertTrue(runtime.task_requests_save_or_export(task, [reference]))

    def test_completion_waits_for_selection_rebinding_without_claiming_success(self):
        class Ledger:
            def can_complete(self, _message): return True

        generation = str(uuid.uuid4())
        context = TaskContext("Edit the selected section", 7, generation, ledger=Ledger(),
                              working_document_revision=3)
        context.machine.transition(Phase.OBSERVING)
        context.machine.transition(Phase.VERIFYING, local_request=True)
        control = {"control_kind": "working_document_update", "id": str(uuid.uuid4()),
                   "revision": 4, "selection_id": str(uuid.uuid4()),
                   "selection_scope_id": str(uuid.uuid4()), "remove_selection_limit": False}
        token = runtime.current_task.set(context)
        try:
            with mock.patch.object(runtime, "bridge_call", return_value={"needs_working_selection": True}), \
                 mock.patch.object(runtime, "publish_task_wait"), \
                 mock.patch.object(runtime, "receive_pending_task_control", return_value=control), \
                 mock.patch.object(runtime, "emit") as emit:
                completed = runtime.complete_from_decision({"output": "Ready"}, "fallback", context.ledger)
            self.assertFalse(completed)
            self.assertEqual(context.pending_task_control, control)
            emit.assert_not_called()
        finally:
            runtime.current_task.reset(token)

    def test_control_is_bound_to_generation_revision_and_opaque_selection(self):
        generation = str(uuid.uuid4())
        update_id, selection_id = str(uuid.uuid4()), str(uuid.uuid4())
        inbox = RuntimeInbox(io.StringIO(""))
        context = TaskContext("Edit this document", 7, generation,
                              working_document_key=inbox.register_working_document_updates(generation),
                              inbox=inbox)
        inbox._enqueue(json.dumps({
            "kind": "working_document_update",
            "version": 2,
            "task_generation_id": generation,
            "update_id": update_id,
            "binding_revision": 1,
            "selection_id": selection_id,
        }).encode())
        token = runtime.current_task.set(context)
        try:
            control = runtime.receive_pending_task_control()
        finally:
            runtime.current_task.reset(token)
        self.assertEqual(control, {"control_kind": "working_document_update", "id": update_id,
                                   "revision": 1, "selection_id": selection_id,
                                   "selection_scope_id": None, "remove_selection_limit": False})

    def test_selection_limit_control_is_opaque_and_versioned(self):
        generation = str(uuid.uuid4())
        update_id, selection_id, scope_id = (str(uuid.uuid4()) for _ in range(3))
        inbox = RuntimeInbox(io.StringIO(""))
        context = TaskContext("Edit only this selection", 7, generation,
                              working_document_key=inbox.register_working_document_updates(generation), inbox=inbox)
        inbox._enqueue(json.dumps({"kind": "working_document_update", "version": 2,
            "task_generation_id": generation, "update_id": update_id, "binding_revision": 1,
            "selection_id": selection_id, "selection_scope_id": scope_id}).encode())
        token = runtime.current_task.set(context)
        try:
            control = runtime.receive_pending_task_control()
        finally:
            runtime.current_task.reset(token)
        self.assertEqual(control["selection_scope_id"], scope_id)
        self.assertEqual(control["selection_id"], selection_id)
        self.assertFalse(control["remove_selection_limit"])

    def test_invalid_scope_or_conflicting_removal_is_rejected(self):
        for fields in ({"selection_scope_id": str(uuid.uuid4())},
                       {"selection_id": str(uuid.uuid4()), "remove_selection_limit": True}):
            generation = str(uuid.uuid4())
            inbox = RuntimeInbox(io.StringIO(""))
            context = TaskContext("Edit only this selection", 7, generation,
                                  working_document_key=inbox.register_working_document_updates(generation), inbox=inbox)
            update = {"kind": "working_document_update", "version": 2,
                "task_generation_id": generation, "update_id": str(uuid.uuid4()), "binding_revision": 1, **fields}
            inbox._enqueue(json.dumps(update).encode())
            token = runtime.current_task.set(context)
            try:
                with self.assertRaisesRegex(RuntimeError, "working-selection"):
                    runtime.receive_pending_task_control()
            finally:
                runtime.current_task.reset(token)

    def test_wrong_generation_or_revision_cannot_become_a_task_control(self):
        generation = str(uuid.uuid4())
        inbox = RuntimeInbox(io.StringIO(""))
        context = TaskContext("Edit this document", 7, generation,
                              working_document_key=inbox.register_working_document_updates(generation),
                              inbox=inbox)
        inbox._enqueue(json.dumps({
            "kind": "working_document_update",
            "version": 1,
            "task_generation_id": generation,
            "update_id": str(uuid.uuid4()),
            "binding_revision": 2,
            "selection_id": str(uuid.uuid4()),
        }).encode())
        token = runtime.current_task.set(context)
        try:
            with self.assertRaisesRegex(RuntimeError, "another task or revision"):
                runtime.receive_pending_task_control()
        finally:
            runtime.current_task.reset(token)

    def test_prompt_observation_excludes_native_identity_but_keeps_description(self):
        compact = runtime.compact_observation({
            "working_document": {
                "state": "active", "application": "Numbers", "title": "Budget",
                "location": "/private/Budget.numbers", "revision": 3,
                "selection_state": "active", "selection_description": "Sheet 1 · B2:D4",
                "pid": 123, "bundle_id": "com.example.numbers",
                "accessibility_identity": "opaque-native-identity",
            }
        })
        self.assertEqual(compact["working_document"], {
            "state": "active", "application": "Numbers", "title": "Budget",
            "location": "/private/Budget.numbers", "revision": 3,
            "selection_state": "active", "selection_description": "Sheet 1 · B2:D4",
        })
        encoded = json.dumps(compact)
        self.assertNotIn("opaque-native-identity", encoded)
        self.assertNotIn("com.example.numbers", encoded)
        self.assertNotIn('"pid"', encoded)

    def test_selection_during_secure_input_wait_keeps_the_same_request_open(self):
        generation = str(uuid.uuid4())
        inbox = RuntimeInbox(io.StringIO(""))
        context = TaskContext("Enter the verification code", 7, generation,
                              working_document_key=inbox.register_working_document_updates(generation),
                              inbox=inbox)
        response_key = inbox.register("user_input_response", "secure-request", generation)
        update = {
            "kind": "working_document_update", "version": 2,
            "task_generation_id": generation, "update_id": str(uuid.uuid4()),
            "binding_revision": 1, "selection_id": str(uuid.uuid4()),
        }
        response = {
            "kind": "user_input_response", "task_generation_id": generation,
            "instruction_revision": 0, "working_document_revision": 1,
            "request_id": "secure-request", "value": "123456",
        }
        inbox._enqueue(json.dumps(update).encode())
        inbox._enqueue(json.dumps(response).encode())
        calls = []

        def apply(control, *, preserve_secure_input=False):
            calls.append((control, preserve_secure_input))
            context.working_document_revision = control["revision"]
            return True

        context.working_document_update_handler = apply
        token = runtime.current_task.set(context)
        try:
            secret = runtime.wait_for_user_input("secure-request", key=response_key)
        finally:
            runtime.current_task.reset(token)
        self.assertEqual(secret, "123456")
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0][1])
        self.assertEqual(context.working_document_revision, 1)


if __name__ == "__main__":
    unittest.main()
