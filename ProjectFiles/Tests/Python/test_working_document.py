"""Working-document controls stay task-scoped and keep native identity private."""
import io
import json
from pathlib import Path
import sys
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "AgentRuntime"))
from action_receipts import RuntimeInbox
from task_execution import TaskContext
import openclaw_runtime as runtime


class WorkingDocumentControlTests(unittest.TestCase):
    def test_control_is_bound_to_generation_revision_and_opaque_selection(self):
        generation = str(uuid.uuid4())
        update_id, selection_id = str(uuid.uuid4()), str(uuid.uuid4())
        inbox = RuntimeInbox(io.StringIO(""))
        context = TaskContext("Edit this document", 7, generation,
                              working_document_key=inbox.register_working_document_updates(generation),
                              inbox=inbox)
        inbox._enqueue(json.dumps({
            "kind": "working_document_update",
            "version": 1,
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
                                   "revision": 1, "selection_id": selection_id})

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
                "pid": 123, "bundle_id": "com.example.numbers",
                "accessibility_identity": "opaque-native-identity",
            }
        })
        self.assertEqual(compact["working_document"], {
            "state": "active", "application": "Numbers", "title": "Budget",
            "location": "/private/Budget.numbers", "revision": 3,
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
            "kind": "working_document_update", "version": 1,
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
