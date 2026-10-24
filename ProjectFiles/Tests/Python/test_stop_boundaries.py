import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "AgentRuntime"))
from task_action_boundaries import (BoundaryViolation, STOP_BOUNDARY_POLICY_VERSION,
                                    detect_stop_boundaries, validate_action_against_boundaries)


class StopBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).resolve().parents[1] / "Fixtures" / "stop-before-boundaries.json"
        cls.fixture = json.loads(path.read_text(encoding="utf-8"))

    def test_shared_source_detection_fixtures_and_utf8_spans(self):
        self.assertEqual(self.fixture["version"], STOP_BOUNDARY_POLICY_VERSION)
        for case in self.fixture["cases"]:
            with self.subTest(case=case["id"]):
                references = []
                if value := case.get("reference"):
                    start = case["request"].encode("utf-8").index(value.encode("utf-8"))
                    references.append({"utf8_start": start, "utf8_length": len(value.encode("utf-8")), "value": value})
                actual = detect_stop_boundaries(case["request"], references)
                self.assertEqual([entry["action"] for entry in actual], case["expected"])
                for entry in actual:
                    source = case["request"].encode("utf-8")[entry["utf8_start"]:
                        entry["utf8_start"] + entry["utf8_length"]].decode("utf-8")
                    self.assertEqual(source, entry["source"])

    def test_exact_input_and_quoted_screen_text_are_never_policy(self):
        text = 'Draft from “don\'t send” and chip'
        start = text.encode("utf-8").index(b"chip")
        self.assertEqual(detect_stop_boundaries(text, [{"utf8_start": start,
            "utf8_length": 4, "value": "chip"}]), [])
        # Malformed offsets cannot mask a prohibition that belongs to prose.
        self.assertEqual([item["action"] for item in detect_stop_boundaries("don't send it", [
            {"utf8_start": 1, "utf8_length": 9, "value": "unrelated"}])], ["send"])

    def test_rejects_matching_final_controls_and_generic_controls_in_final_context(self):
        boundary = detect_stop_boundaries("Draft the email but don't send it")
        cases = [
            ({"type": "click", "element_id": "send"}, {"elements": [
                {"id": "send", "pid": 8, "role": "AXButton", "title": "Send"}]}),
            ({"type": "press", "element_id": "continue"}, {"elements": [
                {"id": "continue", "pid": 8, "role": "AXButton", "title": "Continue",
                 "structure": [{"role": "AXGroup", "label": "Compose", "labels": ["Send message"]}]}]}),
        ]
        for action, observation in cases:
            with self.subTest(action=action):
                with self.assertRaises(BoundaryViolation) as raised:
                    validate_action_against_boundaries(action, observation, boundary)
                self.assertEqual(raised.exception.code, "stop_boundary_rejected")

    def test_coordinate_and_unlabeled_targets_fail_closed(self):
        boundary = detect_stop_boundaries("Draft it, don't publish")
        with self.assertRaises(BoundaryViolation) as raised:
            validate_action_against_boundaries({"type": "click", "x": 400, "y": 400, "pid": 8},
                                               {"elements": []}, boundary)
        self.assertEqual(raised.exception.code, "stop_boundary_uncertain")
        with self.assertRaises(BoundaryViolation):
            validate_action_against_boundaries({"type": "click", "element_id": "unknown"},
                                               {"elements": []}, boundary)

    def test_application_and_window_names_do_not_turn_save_into_send(self):
        boundary = detect_stop_boundaries("Draft the email, but don't send it")
        observation = {"elements": [{"id": "save", "pid": 8, "role": "AXButton",
            "title": "Save", "window_title": "Email draft", "focused": False,
            "structure": [{"role": "AXApplication", "label": "Mail"}]}]}
        validate_action_against_boundaries({"type": "click", "element_id": "save"}, observation, boundary)

    def test_unrelated_generic_control_is_held_without_being_mislabeled_as_send(self):
        boundary = detect_stop_boundaries("Draft the email, but don't send it")
        observation = {"elements": [{"id": "continue", "pid": 8, "role": "AXButton",
            "title": "Continue", "window_title": "Email draft", "structure": [
                {"role": "AXApplication", "label": "Mail"}]}]}
        with self.assertRaises(BoundaryViolation) as raised:
            validate_action_against_boundaries({"type": "click", "element_id": "continue"}, observation, boundary)
        self.assertEqual(raised.exception.code, "stop_boundary_uncertain")

    def test_place_your_order_is_a_purchase_boundary(self):
        boundary = detect_stop_boundaries("Prepare the cart but don't place your order")
        observation = {"elements": [{"id": "order", "pid": 8, "role": "AXButton", "title": "Place your order"}]}
        with self.assertRaises(BoundaryViolation) as raised:
            validate_action_against_boundaries({"type": "click", "element_id": "order"}, observation, boundary)
        self.assertEqual(raised.exception.code, "stop_boundary_rejected")

    def test_safe_preparation_and_opaque_commands(self):
        boundary = detect_stop_boundaries("Prepare the release without deploying")
        observation = {"elements": [{"id": "draft", "pid": 8, "role": "AXTextArea", "title": "Message"}]}
        for action in ({"type": "focus", "element_id": "draft"},
                       {"type": "type_text", "element_id": "draft", "text": "Draft"},
                       {"type": "read_file", "path": "/tmp/draft"},
                       {"type": "write_file", "path": "/tmp/draft", "content": "draft"},
                       {"type": "run_command", "operation": {"type": "print_text", "text": "ready"}}):
            with self.subTest(action=action):
                validate_action_against_boundaries(action, observation, boundary)
        with self.assertRaises(BoundaryViolation) as raised:
            validate_action_against_boundaries({"type": "run_command", "command": "./deploy.sh"},
                                               observation, boundary)
        self.assertEqual(raised.exception.code, "stop_boundary_uncertain")

    def test_enter_cannot_activate_a_submit_default_even_from_a_multiline_field(self):
        boundary = detect_stop_boundaries("Draft the message but do not send")
        observation = {"elements": [{"id": "body", "pid": 8, "role": "AXTextArea", "focused": True}]}
        with self.assertRaises(BoundaryViolation) as raised:
            validate_action_against_boundaries({"type": "key", "key": "return", "pid": 8}, observation, boundary)
        self.assertEqual(raised.exception.code, "stop_boundary_uncertain")
        with self.assertRaises(BoundaryViolation):
            validate_action_against_boundaries({"type": "key", "key": "enter", "modifiers": ["command"], "pid": 8},
                                               observation, boundary)

    def test_unclassified_shortcuts_and_space_activation_fail_closed(self):
        boundary = detect_stop_boundaries("Fill the form but don't submit")
        button = {"elements": [{"id": "submit", "pid": 8, "role": "AXButton", "title": "Submit", "focused": True}]}
        with self.assertRaises(BoundaryViolation) as raised:
            validate_action_against_boundaries({"type": "key", "key": "space", "pid": 8}, button, boundary)
        self.assertEqual(raised.exception.code, "stop_boundary_rejected")
        with self.assertRaises(BoundaryViolation):
            validate_action_against_boundaries({"type": "key", "key": "p", "modifiers": ["command"], "pid": 8}, button, boundary)

    def test_completion_cannot_pass_with_uncertain_final_action(self):
        from openclaw_runtime import has_unresolved_stop_boundary_action
        boundaries = detect_stop_boundaries("Draft the email but don't send")
        self.assertFalse(has_unresolved_stop_boundary_action([
            {"action": {"type": "click"}, "result": {"outcome": "rejected", "error_code": "stop_boundary_rejected"}}
        ], boundaries))
        self.assertTrue(has_unresolved_stop_boundary_action([
            {"action": {"type": "click"}, "result": {"outcome": "delivered_unconfirmed"}}
        ], boundaries))
        self.assertTrue(has_unresolved_stop_boundary_action([
            {"action": {"type": "run_command", "command": "./publish.sh"},
             "result": {"outcome": "unknown", "error_code": "delivery_uncertain"}}
        ], boundaries))
        self.assertFalse(has_unresolved_stop_boundary_action([
            {"action": {"type": "run_command", "operation": {"type": "print_text"}},
             "result": {"outcome": "delivered_unconfirmed"}}
        ], boundaries))


if __name__ == "__main__":
    unittest.main()
