import CoreGraphics
import CoreText
import Darwin
import Foundation
import Vision

// Compile-only dependency of the unused capture collector. This benchmark
// calls production controlSignature, never capture, AX, a task or a provider.
enum ScreenCoordinateError: Error { case captureChanged }

func heapBytes() -> UInt64 {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return UInt64(statistics.size_in_use)
}

// Mirrors the synchronous Vision worker's request options and word conversion.
// This isolates autoreleased processing objects from async queue scheduling.
struct Match { let text: String; let bounds: CGRect; let line: String }
func visionBatch(_ image: CGImage) throws -> [Match] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.automaticallyDetectsLanguage = true
    request.minimumTextHeight = 0.005
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
    try handler.perform([request])
    return try (request.results ?? []).flatMap { observation -> [Match] in
        guard let candidate = observation.topCandidates(1).first else { return [] }
        return try candidate.string.split(whereSeparator: { $0.isWhitespace }).compactMap { word in
            guard let box = try candidate.boundingBox(for: word.startIndex..<word.endIndex) else { return nil }
            return Match(text: String(word), bounds: box.boundingBox,
                         line: String(candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256)))
        }
    }
}

let fixture = CommandLine.arguments.dropFirst().first ?? "controls"
let scoped = CommandLine.arguments.dropFirst(2).first == "scoped"
precondition(["controls", "vision"].contains(fixture))
let iterations = fixture == "controls" ? 12 : 20
let operation: () throws -> Int
if fixture == "controls" {
    let rows: [[String: Any]] = (0..<640).map { index in
        var row: [String: Any] = ["id": "revision:e\(index)", "pid": 42,
            "role": index == 0 ? "AXWindow" : "AXButton",
            "title": "Fixture control \(index) " + String(repeating: "label ", count: 12),
            "enabled": true, "focused": false, "actions": ["AXPress"],
            "frame": ["x": index % 32 * 30, "y": index / 32 * 30, "width": 20, "height": 20],
            "window_title": "Synthetic window"]
        if index > 0 { row["parent_id"] = "revision:e0" }
        return row
    }
    operation = { try ObservationConsistency.controlSignature(elements: rows, applications: []).utf8.count }
} else {
    let context = CGContext(data: nil, width: 1000, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
    for line in 0..<8 {
        let text = NSAttributedString(string: "SAVE REPORT CANCEL FILE SETTINGS", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 28, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        context.textPosition = CGPoint(x: 30, y: 45 + line * 65)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
    let image = context.makeImage()!
    operation = { try visionBatch(image).reduce(0) { $0 + $1.text.utf8.count + $1.line.utf8.count } }
}

for _ in 0..<3 { try autoreleasepool { _ = try operation() } }
var baseline: UInt64 = 0, maximum: UInt64 = 0, beforeDrain: UInt64 = 0, checksum = 0
let started = ProcessInfo.processInfo.systemUptime
try autoreleasepool {
    baseline = heapBytes(); maximum = baseline
    for _ in 0..<iterations {
        checksum += scoped ? try autoreleasepool { try operation() } : try operation()
        // Sampling at batch boundaries measures accumulated live heap. This
        // is neither whole-process peak RSS nor allocator-reserved memory.
        maximum = max(maximum, heapBytes())
    }
    beforeDrain = heapBytes()
}
let report: [String: Any] = ["fixture": fixture, "outer_batch_pool": scoped,
    "iterations": iterations, "baseline_heap_bytes": baseline,
    "maximum_heap_at_batch_boundaries": maximum, "before_outer_drain_bytes": beforeDrain,
    "after_outer_drain_bytes": heapBytes(), "checksum": checksum,
    "seconds": ProcessInfo.processInfo.systemUptime - started]
print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
