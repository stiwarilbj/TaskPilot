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
        private let shouldDefer: (AXUIElement) -> Bool
        private let stalled: (AXUIElement) -> Void
        private let deferredReporter: (AXUIElement, String) -> Void
        private(set) var failures = 0
        let retried: () -> Void
        let shouldRetry: () -> Bool
        private let setTimeout: (AXUIElement, Float) -> Void
        private struct ReadKey: Hashable { let element: UInt; let attribute: String }
        private var retries: Set<ReadKey> = []
        private var deferredElements = NativeIdentityIndex<AXUIElement>()
        private var individualReadApps: Set<pid_t> = []
        init(deadline: TimeInterval, now: @escaping () -> TimeInterval,
             report: @escaping (String, String?, Int?) -> Void,
             retried: @escaping () -> Void, shouldRetry: @escaping () -> Bool,
             shouldDefer: @escaping (AXUIElement) -> Bool = { _ in false },
             stalled: @escaping (AXUIElement) -> Void = { _ in },
             deferred: @escaping (AXUIElement, String) -> Void = { _, _ in },
             setTimeout: @escaping (AXUIElement, Float) -> Void = { element, timeout in
                 _ = AXUIElementSetMessagingTimeout(element, timeout)
             }) {
            self.deadline = deadline; self.now = now; self.reporter = report
            self.retried = retried; self.shouldRetry = shouldRetry
            self.shouldDefer = shouldDefer; self.stalled = stalled; deferredReporter = deferred
            self.setTimeout = setTimeout
        }
        func report(_ reason: String, _ attribute: String?, _ code: Int?) {
            failures += 1; reporter(reason, attribute, code)
        }
        private func markDeferred(_ element: AXUIElement, attribute: String) {
            guard deferredElements.insert(element, hash: UInt(CFHash(element)), equal: { CFEqual($0, $1) }) else { return }
            failures += 1
            deferredReporter(element, attribute)
        }
        private func slowReadThreshold(began: TimeInterval) -> TimeInterval {
            max(0.005, min(0.04, max(0, deadline - began) * 0.5))
        }
        func read(_ element: AXUIElement, attribute: String, required: Bool = false,
                  reportErrors: Bool = true,
                  operation: () -> AXError) -> AXError {
            let began = now()
            let result = perform(element, attribute: attribute, operation: operation)
            return resolve(element, attribute: attribute, required: required, result: result,
                           began: began, reportErrors: reportErrors, retry: operation)
        }
        private func perform(_ element: AXUIElement, attribute: String, operation: () -> AXError) -> AXError {
            guard !shouldDefer(element) else {
                markDeferred(element, attribute: attribute)
                return .cannotComplete
            }
            guard (try? TaskOwnership.check()) != nil else { return .cannotComplete }
            guard now() < deadline else { report("collection_timeout", attribute, nil); return .cannotComplete }
            let timeout = Float(min(0.08, max(0.001, deadline - now())))
            setTimeout(element, timeout)
            defer { setTimeout(element, 0) }
            let result = operation()
            guard (try? TaskOwnership.check()) != nil else { return .cannotComplete }
            guard now() < deadline else { report("collection_timeout", attribute, nil); return .cannotComplete }
            return result
        }
        /// Decoded batch errors use the same per-attribute, shared retry budget
        /// as single reads. Successful neighbors are never queried again.
        func resolve(_ element: AXUIElement, attribute: String, required: Bool = false,
                     result initial: AXError, began: TimeInterval, reportErrors: Bool = true,
                     retry: () -> AXError) -> AXError {
            guard (try? TaskOwnership.check()) != nil else { return .cannotComplete }
            var result = initial
            let key = ReadKey(element: CFHash(element), attribute: attribute)
            if (result == .cannotComplete || result == .failure), !shouldDefer(element), shouldRetry(), now() < deadline,
               retries.count < 8, retries.insert(key).inserted {
                retried()
                result = perform(element, attribute: attribute, operation: retry)
            }
            guard (try? TaskOwnership.check()) != nil else { return .cannotComplete }
            let wasDeferred = deferredElements.contains(element, hash: UInt(CFHash(element)), equal: { CFEqual($0, $1) })
            if !wasDeferred, result == .cannotComplete, now() - began >= slowReadThreshold(began: began) {
                stalled(element)
                if shouldDefer(element) { markDeferred(element, attribute: attribute) }
            }
            if reportErrors, !wasDeferred, now() < deadline {
                record(result, attribute: attribute, required: required, began: began, element: element)
            }
            return result
        }
        func record(_ result: AXError, attribute: String, required: Bool = false, began: TimeInterval,
                    element: AXUIElement? = nil) {
            if let element, deferredElements.contains(element, hash: UInt(CFHash(element)), equal: { CFEqual($0, $1) }) { return }
            if result != .success {
                let absent = result == .attributeUnsupported || result == .noValue || result == .notImplemented
                if required || !absent {
                    let timeout = min(0.08, max(0.001, deadline - began))
                    let reason = result == .apiDisabled ? "accessibility_permission_unavailable"
                        : result == .cannotComplete && now() - began >= timeout * 0.9 ? "accessibility_timeout"
                        : absent ? "accessibility_incomplete" : "accessibility_read_error"
                    report(reason, attribute, Int(result.rawValue))
                }
            }
        }
        func usesIndividualReads(for pid: pid_t) -> Bool { individualReadApps.contains(pid) }
        func requireIndividualReads(for pid: pid_t) {
            // Compatibility lasts only for this bounded staging collection.
            if individualReadApps.count < 32 { individualReadApps.insert(pid) }
        }
    }
}
