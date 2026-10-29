import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "AgentRuntime"))
from action_boundary_policy import (ALLOW, PROTOCOL_ERROR, decision_for_probes,
                                    evaluate_checks, NATIVE_ACTION_POLICY_VERSION)
from task_action_boundaries import BoundaryViolation


class NativeActionBoundaryPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).resolve().parents[2] / "Contracts" / "Fixtures" / "native-action-boundary-policy.json"
        cls.fixture = json.loads(path.read_text(encoding="utf-8"))

    def test_shared_order_and_decision_fixtures(self):
        self.assertEqual(self.fixture["version"], NATIVE_ACTION_POLICY_VERSION)
        from action_boundary_policy import STAGE_ORDER
        self.assertEqual(self.fixture["stage_order"], list(STAGE_ORDER))
        for case in self.fixture["cases"]:
            with self.subTest(case=case["id"]):
                self.assertEqual(decision_for_probes(case["probes"]).as_dict(), case["expected"])

    def test_invalid_probes_fail_closed(self):
        self.assertEqual(decision_for_probes([{"stage": "invented", "disposition": "allow", "reason": "none"}]),
                         PROTOCOL_ERROR)
        self.assertEqual(decision_for_probes([{"stage": "stop_before", "disposition": "allow",
                                               "reason": "none", "details": "ignored?"}]), PROTOCOL_ERROR)
        self.assertEqual(decision_for_probes([{"stage": "stop_before", "disposition": "allow",
                                               "reason": "stop_boundary_rejected"}]), PROTOCOL_ERROR)

    def test_runtime_check_callbacks_run_once_in_fixed_order(self):
        calls = []
        result = evaluate_checks({
            "destination_identity": lambda: calls.append("destination"),
            "selection_scope": lambda: calls.append("selection"),
        })
        self.assertEqual(result.decision, ALLOW)
        self.assertEqual(calls, ["selection", "destination"])

    def test_runtime_preserves_policy_failure_and_returns_fixed_decision(self):
        error = BoundaryViolation("stop_boundary_rejected", "Stop before Send")
        result = evaluate_checks({"stop_before": lambda: (_ for _ in ()).throw(error)})
        self.assertIs(result.failure, error)
        self.assertEqual(result.decision.as_dict(), {
            "disposition": "reject", "reason": "stop_boundary_rejected"})


if __name__ == "__main__":
    unittest.main()
