import Foundation

enum ObservationConsistencyError: LocalizedError {
    case unstable
    var errorDescription: String? {
        "The screen or controls kept changing during capture. No action was performed from inconsistent evidence."
    }
}

struct ObservationConsistencyDiagnostics {
    var attempts = 0
    var rejected: [String: Int] = [:]
    var elapsedSeconds: Double = 0
}

/// No model calls or input delivery. A candidate owns no executable IDs until
/// publish runs, and every unsuccessful path disposes of its screenshot.
enum ObservationConsistency {
    private enum Retry: Error { case changed(String), resumed }

    static func collect<Candidate, Scene: Equatable, Frame>(
        budget: TimeInterval = 5,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        checkpoint: () async throws -> Void,
        suspensionRevision: () -> Int = { 0 },
        scene: () throws -> Scene,
        stage: (TimeInterval) throws -> Candidate,
        stageAfter: ((TimeInterval) throws -> Candidate)? = nil,
        signature: (Candidate) throws -> String,
        capture: (Bool) async throws -> Frame,
        discard: (Frame) -> Void,
        prepare: (Candidate, Frame, Scene) async throws -> Void = { _, _, _ in },
        publish: (Candidate) throws -> Void,
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        report: (ObservationConsistencyDiagnostics) -> Void = { _ in }
    ) async throws -> (Candidate, Frame) {
        try await checkpoint()
        let started = now()
        var deadline = started + min(5, max(0, budget))
        var epoch = suspensionRevision()
        var diagnostics = ObservationConsistencyDiagnostics()
        var backoff: TimeInterval = 0.1
        var pendingBackoff: TimeInterval?
        defer { diagnostics.elapsedSeconds = max(0, now() - started); report(diagnostics) }

        func check(requireTime: Bool = false) async throws {
            try await checkpoint()
            guard epoch == suspensionRevision() else { throw Retry.resumed }
            guard !requireTime || now() < deadline else { throw ObservationConsistencyError.unstable }
        }

        while true {
            var image: Frame?
            do {
                // A macOS read already in flight cannot be preempted. The
                // deadline bounds new attempts, not a healthy read's return.
                try await check(requireTime: true)
                if let delay = pendingBackoff {
                    try await sleep(min(delay, max(0, deadline - now())))
                    pendingBackoff = nil
                    try await check(requireTime: true)
                }
                diagnostics.attempts += 1
                let firstScene = try scene()
                let before = try stage(max(0, deadline - now()))
                let beforeSignature = try signature(before)
                try await check()
                guard try scene() == firstScene else { throw Retry.changed("window_before_capture") }
                image = try await capture(diagnostics.attempts > 1)
                try await check()
                guard try scene() == firstScene else { throw Retry.changed("window_during_capture") }
                let after: Candidate
                if let stageAfter { after = try stageAfter(max(0, deadline - now())) }
                else { after = try stage(max(0, deadline - now())) }
                try await check()
                guard try scene() == firstScene else { throw Retry.changed("window_during_controls") }
                guard try signature(after) == beforeSignature else { throw Retry.changed("control_layout") }
                // The pair is now fixed. Encoding/OCR may only consume this
                // frame, never ask the capture service for its latest pixels.
                try await prepare(after, image!, firstScene)
                try await check()
                try publish(after)
                return (after, image!)
            } catch {
                if let rejected = image { discard(rejected) }
                image = nil // Release queued pixels before Pause/backoff.
                // Pause can occur during a wait or immediately before commit.
                // Cancellation/revocation still wins over a resumption retry.
                try await checkpoint()
                if epoch != suspensionRevision(), error is Retry || error is CancellationError {
                    epoch = suspensionRevision()
                    deadline = now() + min(5, max(0, budget))
                    backoff = 0.1
                    pendingBackoff = nil
                    diagnostics.rejected["pause", default: 0] += 1
                    continue
                }
                switch error {
                case Retry.changed(let reason):
                    diagnostics.rejected[reason, default: 0] += 1
                    pendingBackoff = backoff
                    backoff = min(0.5, backoff * 2)
                case ScreenCoordinateError.captureChanged:
                    diagnostics.rejected["capture_geometry", default: 0] += 1
                    pendingBackoff = backoff
                    backoff = min(0.5, backoff * 2)
                default: throw error
                }
            }
        }
    }

    /// Canonicalize the *same* fields read for planning. IDs and enumeration
    /// order change on every walk; ancestry and window ownership do not.
    static func controlSignature(elements: [[String: Any]], applications: [[String: Any]]) throws -> String {
        let byID = Dictionary(elements.compactMap { row -> (String, [String: Any])? in
            (row["id"] as? String).map { ($0, row) }
        }, uniquingKeysWith: { first, _ in first })
        func identity(_ row: [String: Any]) -> [String: Any] {
            row.filter { ["pid", "role", "subrole", "title", "frame", "window_title"].contains($0.key) }
        }
        func ancestry(_ row: [String: Any]) -> [[String: Any]] {
            var result: [[String: Any]] = []
            var current = row
            var visited: Set<String> = []
            while let parent = current["parent_id"] as? String, visited.insert(parent).inserted,
                  let next = byID[parent] {
                result.append(identity(next)); current = next
            }
            return result
        }
        func encode(_ value: Any) throws -> String {
            // Foundation's bridged containers/data must drain between rows,
            // rather than accumulate across a full control tree or retry.
            try autoreleasepool {
                String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
            }
        }
        let controls = try elements.map { row -> String in
            var stable = row.filter { !["id", "parent_id", "window_id", "depth", "app"].contains($0.key) }
            if row["role"] as? String == "AXProgressIndicator" { stable.removeValue(forKey: "value") }
            if let actions = row["actions"] as? [String] { stable["actions"] = actions.sorted() }
            stable["ancestry"] = ancestry(row)
            return try encode(stable)
        }.sorted()
        let apps = try applications.map { row -> String in
            var stable = row
            if let windows = row["windows"] as? [[String: Any]] {
                stable["windows"] = try windows.map { try encode($0.filter { $0.key != "window_id" }) }.sorted()
            }
            return try encode(stable)
        }.sorted()
        return try encode(["controls": controls, "applications": apps])
    }

    /// Destination evidence is revision-scoped for publication, but generated
    /// revisions and Accessibility enumeration order do not describe a screen
    /// change and must not destabilize the capture/control pair.
    static func resultDestinationSignature(_ rows: [[String: Any]]) throws -> String {
        let fields: Set<String> = ["pid", "bundle_id", "app", "window_title", "title", "url"]
        let stableRows = try rows.map { row in
            let stable = row.filter { fields.contains($0.key) }
            return String(decoding: try JSONSerialization.data(withJSONObject: stable, options: [.sortedKeys]), as: UTF8.self)
        }.sorted()
        return String(decoding: try JSONSerialization.data(withJSONObject: stableRows, options: [.sortedKeys]), as: UTF8.self)
    }
}
