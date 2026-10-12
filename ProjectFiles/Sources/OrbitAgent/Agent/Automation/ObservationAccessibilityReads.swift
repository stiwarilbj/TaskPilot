import ApplicationServices
import Foundation

/// Per-staging read limits; never changes the process-wide AX timeout, and
/// never participates in mutations or delivery. Each object resets afterward.
enum ObservationAccessibilityReads {
    @TaskLocal static var current: Context?
    final class Context {
        let deadline: TimeInterval
        let now: () -> TimeInterval
        private let reporter: (String, String?, Int?) -> Void
        private(set) var failures = 0
        let retried: () -> Void
        let shouldRetry: () -> Bool
        private struct ReadKey: Hashable { let element: UInt; let attribute: String }
        private var retries: Set<ReadKey> = []
        init(deadline: TimeInterval, now: @escaping () -> TimeInterval,
             report: @escaping (String, String?, Int?) -> Void,
             retried: @escaping () -> Void, shouldRetry: @escaping () -> Bool) {
            self.deadline = deadline; self.now = now; self.reporter = report
            self.retried = retried; self.shouldRetry = shouldRetry
        }
        func report(_ reason: String, _ attribute: String?, _ code: Int?) {
            failures += 1; reporter(reason, attribute, code)
        }
        func read(_ element: AXUIElement, attribute: String, required: Bool = false,
                  operation: () -> AXError) -> AXError {
            guard (try? TaskOwnership.check()) != nil else { return .cannotComplete }
            guard now() < deadline else { report("collection_timeout", attribute, nil); return .cannotComplete }
            let timeout = Float(min(0.08, max(0.001, deadline - now())))
            _ = AXUIElementSetMessagingTimeout(element, timeout)
            defer { _ = AXUIElementSetMessagingTimeout(element, 0) }
            let began = now()
            var result = operation()
            let key = ReadKey(element: CFHash(element), attribute: attribute)
            if (result == .cannotComplete || result == .failure), shouldRetry(), now() < deadline,
               retries.count < 8, retries.insert(key).inserted {
                retried()
                _ = AXUIElementSetMessagingTimeout(element, Float(min(0.08, max(0.001, deadline - now()))))
                result = operation()
            }
            if result != .success {
                let absent = result == .attributeUnsupported || result == .noValue || result == .notImplemented
                if required || !absent {
                    let reason = result == .apiDisabled ? "accessibility_permission_unavailable"
                        : result == .cannotComplete && now() - began >= Double(timeout) * 0.9 ? "accessibility_timeout"
                        : absent ? "accessibility_incomplete" : "accessibility_read_error"
                    report(reason, attribute, Int(result.rawValue))
                }
            }
            return result
        }
    }
}
