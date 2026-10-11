import Foundation

enum AutomationInputPolicy {
    static func waitUntilReady(
        timeout: TimeInterval = 2,
        ready: () -> Bool,
        cancelled: () -> Bool = { false }
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !ready() {
            if cancelled() { throw AccessibilityActionError.cancelled }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw AccessibilityActionError.activationFailed }
            try await Task.sleep(for: .milliseconds(25))
        }
        if cancelled() { throw AccessibilityActionError.cancelled }
        try Task.checkCancellation()
    }

    static func shouldRestore(
        scheduledGeneration: Int, currentGeneration: Int,
        targetPID: Int32, currentPID: Int32?, previousPID: Int32
    ) -> Bool {
        scheduledGeneration == currentGeneration && currentPID == targetPID && previousPID != targetPID
    }
}
