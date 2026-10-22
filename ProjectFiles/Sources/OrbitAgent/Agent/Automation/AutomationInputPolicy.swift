import Foundation

enum AutomationInputPolicy {
    static func waitUntilReady(
        timeout: TimeInterval = 2,
        ready: () -> Bool,
        cancelled: () -> Bool = { false },
        timeoutError: AccessibilityActionError = .activationFailed
    ) async throws {
        try LocalOperationBudget.check("activation_or_focus")
        let deadline = ContinuousClock.now.advanced(by: .seconds(LocalOperationBudget.allowance(timeout)))
        while true {
            try TaskOwnership.check()
            if cancelled() { throw AccessibilityActionError.cancelled }
            if ready() { break }
            if cancelled() { throw AccessibilityActionError.cancelled }
            try TaskOwnership.check()
            guard ContinuousClock.now < deadline else { throw timeoutError }
            try await LocalOperationBudget.sleep(0.025, phase: "activation_or_focus")
        }
        if cancelled() { throw AccessibilityActionError.cancelled }
        try TaskOwnership.check()
    }

    static func shouldRestore(
        scheduledGeneration: Int, currentGeneration: Int,
        targetPID: Int32, currentPID: Int32?, previousPID: Int32
    ) -> Bool {
        scheduledGeneration == currentGeneration && currentPID == targetPID && previousPID != targetPID
    }
}
