import XCTest
@testable import OrbitAgent

final class ActionFailureTests: XCTestCase {
    func testToolFailureCodesDistinguishRejectionAndUncertainMutation() {
        XCTAssertEqual(TaskToolError.invalidAction("missing").code, "invalid_action")
        XCTAssertEqual(TaskToolError.operationFailed("before delivery").code, "delivery_rejected")
        XCTAssertEqual(TaskToolError.uncertainDelivery("after delivery").code, "delivery_uncertain")
    }

    func testCommandExitStatusPreservesOutputAndClassifiesEffects() async throws {
        let executor = TaskToolExecutor()
        for (command, outcome, code) in [("printf fixture", "delivered_unconfirmed", 0), ("printf partial; exit 2", "delivered_unconfirmed", 2)] {
            let result = try await executor.perform(action: ["type": "run_command", "command": command])
            XCTAssertEqual(result["exit_code"] as? Int, code)
            XCTAssertEqual(result["outcome"] as? String, outcome)
            XCTAssertEqual(result["timed_out"] as? Bool, false)
            XCTAssertEqual(result["stdout"] as? String, code == 0 ? "fixture" : "partial")
        }
    }

    func testTimedOutCommandDoesNotClaimVerifiedEffects() async throws {
        let result = try await TaskToolExecutor().perform(action: ["type": "run_command", "command": "sleep 0.4", "timeout_seconds": 0.2])
        XCTAssertEqual(result["timed_out"] as? Bool, true)
        XCTAssertEqual(result["outcome"] as? String, "delivered_unconfirmed")
    }
}
