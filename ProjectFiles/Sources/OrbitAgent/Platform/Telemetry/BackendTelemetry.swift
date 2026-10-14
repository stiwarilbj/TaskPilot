import Foundation
import OSLog

/// Local numeric measurements only. This API cannot accept content, paths,
/// commands, error messages, or task identifiers as telemetry metadata.
final class BackendTelemetry: @unchecked Sendable {
    static let shared = BackendTelemetry()
    @TaskLocal static var current: BackendTelemetry = .shared

    enum Phase: String, CaseIterable, Codable {
        case startup, capture, previewCapture, axCollection, pngEncoding
        case jsonEncoding, jsonDecoding, ipcReceive, ipcSend, ipcBridge
        case commandLaunch, persistenceRead, persistenceWrite
        var name: StaticString {
            switch self {
            case .startup: return "Runtime Startup"
            case .capture: return "Task Capture"
            case .previewCapture: return "Preview Capture"
            case .axCollection: return "AX Collection"
            case .pngEncoding: return "PNG Encoding"
            case .jsonEncoding: return "JSON Encoding"
            case .jsonDecoding: return "JSON Decoding"
            case .ipcReceive: return "IPC Receive"
            case .ipcSend: return "IPC Send"
            case .ipcBridge: return "IPC Bridge"
            case .commandLaunch: return "Command Launch"
            case .persistenceRead: return "Persistence Read"
            case .persistenceWrite: return "Persistence Write"
            }
        }
    }
    enum Outcome: Int, Codable { case succeeded, failed, cancelled, abandoned }
    struct Sample: Codable {
        let phase: Phase
        let outcome: Outcome
        let seconds: Double
        let inputBytes: Int?
        let outputBytes: Int?
        let items: Int?
    }
    struct Summary: Codable {
        let phase: Phase
        let samples: Int
        let medianMilliseconds: Double
        let p95Milliseconds: Double
        let maximumMilliseconds: Double
    }
    private struct Ring {
        var values: [Sample] = []
        var next = 0
        mutating func append(_ value: Sample, capacity: Int) {
            if values.count < capacity { values.append(value) }
            else { values[next] = value; next = (next + 1) % capacity }
        }
    }
    final class Span: @unchecked Sendable {
        private let owner: BackendTelemetry
        private let phase: Phase
        private let state: OSSignpostIntervalState
        private let started: TimeInterval
        private let lock = NSLock()
        private var ended = false
        private var inputBytes: Int?
        private var outputBytes: Int?
        private var items: Int?
        fileprivate init(_ owner: BackendTelemetry, _ phase: Phase, inputBytes: Int?, items: Int?) {
            self.owner = owner; self.phase = phase
            self.inputBytes = inputBytes.flatMap { $0 >= 0 ? $0 : nil }
            self.items = items.flatMap { $0 >= 0 ? $0 : nil }
            started = owner.now()
            state = owner.signposter.beginInterval(phase.name, id: owner.signposter.makeSignpostID())
        }
        func record(inputBytes: Int? = nil, outputBytes: Int? = nil, items: Int? = nil) {
            lock.withLock {
                guard !ended else { return }
                if let inputBytes, inputBytes >= 0 { self.inputBytes = inputBytes }
                if let outputBytes, outputBytes >= 0 { self.outputBytes = outputBytes }
                if let items, items >= 0 { self.items = items }
            }
        }
        func finish(_ outcome: Outcome) {
            let sample: Sample? = lock.withLock {
                guard !ended else { return nil }
                ended = true
                return Sample(phase: phase, outcome: outcome, seconds: max(0, owner.now() - started),
                    inputBytes: inputBytes, outputBytes: outputBytes, items: items)
            }
            guard let sample else { return }
            // Presence bits distinguish absent sizes from measured zero without
            // negative sentinels (some Instruments views format them unsigned).
            let fields = (sample.inputBytes == nil ? 0 : 1) | (sample.outputBytes == nil ? 0 : 2) | (sample.items == nil ? 0 : 4)
            owner.signposter.endInterval(phase.name, state,
                "outcome=\(outcome.rawValue, privacy: .public) duration_ms=\(sample.seconds * 1000, privacy: .public) input_bytes=\(sample.inputBytes ?? 0, privacy: .public) output_bytes=\(sample.outputBytes ?? 0, privacy: .public) items=\(sample.items ?? 0, privacy: .public) fields=\(fields, privacy: .public)")
            owner.append(sample)
        }
        deinit { finish(.abandoned) }
    }
    private let signposter = OSSignposter(subsystem: "com.orbitagent.controller", category: "BackendPhases")
    private let lock = NSLock()
    private let capacity: Int
    private let now: @Sendable () -> TimeInterval
    private var rings: [Phase: Ring] = [:]
    init(capacity: Int = 128, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capacity = max(1, min(1024, capacity)); self.now = now
    }
    func begin(_ phase: Phase, inputBytes: Int? = nil, items: Int? = nil) -> Span {
        Span(self, phase, inputBytes: inputBytes, items: items)
    }
    func measure<T>(_ phase: Phase, inputBytes: Int? = nil, items: Int? = nil, _ body: (Span) throws -> T) rethrows -> T {
        let span = begin(phase, inputBytes: inputBytes, items: items)
        do { let result = try body(span); span.finish(.succeeded); return result }
        catch { span.finish(error is CancellationError ? .cancelled : .failed); throw error }
    }
    func encodeJSON(_ value: Any, recordSize: Bool = true) throws -> Data {
        try measure(.jsonEncoding) { span in
            let data = try JSONSerialization.data(withJSONObject: value)
            if recordSize { span.record(outputBytes: data.count) }
            return data
        }
    }
    private func append(_ sample: Sample) { lock.withLock { rings[sample.phase, default: Ring()].append(sample, capacity: capacity) } }
    func samples() -> [Sample] { lock.withLock { Phase.allCases.flatMap { rings[$0]?.values ?? [] } } }
    func summaries() -> [Summary] {
        let samples = samples()
        return Phase.allCases.compactMap { phase in
            let values = samples.filter { $0.phase == phase && $0.outcome == .succeeded }.map { $0.seconds * 1000 }.sorted()
            guard !values.isEmpty else { return nil }
            func percentile(_ fraction: Double) -> Double { values[max(0, Int(ceil(Double(values.count) * fraction)) - 1)] }
            return Summary(phase: phase, samples: values.count, medianMilliseconds: percentile(0.5),
                           p95Milliseconds: percentile(0.95), maximumMilliseconds: values.last!)
        }
    }
}
