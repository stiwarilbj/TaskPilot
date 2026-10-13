import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Screenshot text is evidence, never an AX element, a control role, or proof
/// that input was accepted. All rectangles use the central coordinate mapping.
struct ScreenTextMatch {
    let text: String
    let confidence: Double
    let frame: CGRect // Quartz points, top-left origin
    var lineText: String? = nil
}

struct ScreenTextWindow: Equatable {
    let pid: Int
    let id: Int
    let frame: CGRect
    var layer: Int = 0
}

struct ScreenTextTarget {
    let match: ScreenTextMatch
    let window: ScreenTextWindow
}

struct ScreenTextSnapshot {
    var state = "not_needed"
    var targets: [ScreenTextTarget] = []
    var crops: [[String: Any]] = [] // Bounded PNGs, in memory only.

    func metadata(revision: String, coordinates: ScreenCoordinateMapping) throws -> [String: Any] {
        let labels = Dictionary(grouping: targets, by: { $0.match.text.lowercased() })
        let rows = try targets.enumerated().map { index, target -> [String: Any] in
            let frame = target.match.frame
            let first = try coordinates.normalizedPoint(fromGlobal: frame.origin)
            let last = try coordinates.normalizedPoint(fromGlobal: CGPoint(x: frame.maxX, y: frame.maxY))
            let pixels = try coordinates.imagePoint(fromGlobal: frame.origin)
            let endPixels = try coordinates.imagePoint(fromGlobal: CGPoint(x: frame.maxX, y: frame.maxY))
            var row: [String: Any] = ["candidate_id": "\(revision):text:\(index)", "text": target.match.text,
                "confidence": target.match.confidence, "provisional": true,
                "pid": target.window.pid, "graphics_window_id": target.window.id,
                "frame": LocalTextRecognition.rect(frame),
                "image_bounds": LocalTextRecognition.rect(CGRect(x: pixels.x, y: pixels.y,
                    width: endPixels.x - pixels.x, height: endPixels.y - pixels.y)),
                "normalized_bounds": LocalTextRecognition.rect(CGRect(x: first.x, y: first.y,
                    width: last.x - first.x, height: last.y - first.y)),
                "repeated_text_count": labels[target.match.text.lowercased()]?.count ?? 1]
            if let line = target.match.lineText { row["line_text"] = line }
            return row
        }
        return ["version": LocalTextRecognition.version, "state": state,
            "observation_revision": revision, "targets": rows, "detail_crops": crops]
    }

    func target(at point: CGPoint, pid: Int) throws -> ScreenTextTarget? {
        let matches = targets.filter { $0.window.pid == pid && $0.match.frame.contains(point) }
        guard matches.count <= 1 else { throw AccessibilityActionError.ambiguousTarget }
        guard let target = matches.first else { return nil }
        guard target.match.confidence >= LocalTextRecognition.executionConfidence else {
            throw AccessibilityActionError.staleObservation
        }
        return target
    }
}

enum LocalTextRecognition {
    static let version = 1
    static let executionConfidence = 0.8
    static let maximumTargets = 48
    static let maximumCrops = 2
    typealias Recognizer = (CGImage, ScreenCoordinateMapping, TimeInterval) async throws -> [ScreenTextMatch]

    static func rect(_ r: CGRect) -> [String: Double] {
        ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
    }

    /// Vision rectangles start at the bottom left; all other image rectangles
    /// here start at the top left. Includes cropped/resized/negative-origin maps.
    static func globalFrame(_ box: CGRect, coordinates: ScreenCoordinateMapping) throws -> CGRect {
        guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
              box.width > 0, box.height > 0,
              CGRect(x: 0, y: 0, width: 1, height: 1).contains(box) else {
            throw ScreenCoordinateError.outsideImage
        }
        let first = try coordinates.globalPoint(fromImage: CGPoint(x: box.minX * coordinates.imageSize.width,
            y: (1 - box.maxY) * coordinates.imageSize.height))
        let last = try coordinates.globalPoint(fromImage: CGPoint(x: box.maxX * coordinates.imageSize.width,
            y: (1 - box.minY) * coordinates.imageSize.height))
        return CGRect(x: first.x, y: first.y, width: last.x - first.x, height: last.y - first.y)
    }

    static func windows(scene: String) -> [ScreenTextWindow] {
        guard let data = scene.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["windows"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let pid = row["pid"] as? Int, pid > 0, let id = row["window"] as? Int, id > 0,
                  let layer = row["layer"] as? Int, let f = row["frame"] as? [Double], f.count == 4 else { return nil }
            let frame = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
            guard serializedAccessibilityFrame(frame) != nil, frame.width > 0, frame.height > 0 else { return nil }
            return ScreenTextWindow(pid: pid, id: id, frame: frame, layer: layer)
        }
    }

    static func neededPIDs(_ snapshot: AccessibilitySnapshot) -> Set<Int> {
        let gaps = snapshot.completeness["limitations"] as? [[String: Any]] ?? []
        var pids = Set(gaps.compactMap { $0["pid"] as? Int })
        // Some trees appear complete but expose only a window/web canvas.
        for app in snapshot.applications {
            guard let pid = app["pid"] as? Int else { continue }
            let windows = (app["windows"] as? [[String: Any]] ?? []).compactMap { $0["window_id"] as? String }
            func interactive(window: String?) -> Bool {
                snapshot.elements.contains { row in
                    row["pid"] as? Int == pid && (window == nil || row["window_id"] as? String == window) &&
                        ["AXButton", "AXTextField", "AXTextArea", "AXLink", "AXCheckBox", "AXPopUpButton", "AXSlider", "AXRow"]
                        .contains(row["role"] as? String ?? "")
                }
            }
            if app["accessibility_available"] as? Bool == false || !interactive(window: nil)
                || windows.contains(where: { !interactive(window: $0) }) { pids.insert(pid) }
        }
        // Do not OCR or export detail crops of a window containing secure or
        // identity-unreadable fields. AX and the existing screenshot remain.
        let securePIDs = snapshot.elements.compactMap { row -> Int? in
            let secure = AutomationTextEntryPolicy.isSecure(role: row["role"] as? String ?? "",
                subrole: row["subrole"] as? String ?? "") || row["value"] as? String == "[secure]"
            return secure ? row["pid"] as? Int : nil
        }
        pids.subtract(securePIDs)
        return pids
    }

    /// Recognition and detail crops use only pixels from the staged capture.
    /// No extra capture, model call, synthesized PID or executable element ID.
    static func supplement(image: CGImage, coordinates: ScreenCoordinateMapping,
                           snapshot: AccessibilitySnapshot, scene: String, keywords: [String],
                           budget: TimeInterval, inspectionPID: Int? = nil,
                           recognize: Recognizer = recognize) async throws -> ScreenTextSnapshot {
        try await TaskOwnership.checkpoint()
        var needed = neededPIDs(snapshot)
        if let inspectionPID, snapshot.applications.contains(where: { $0["pid"] as? Int == inspectionPID }),
           !snapshot.elements.contains(where: { $0["pid"] as? Int == inspectionPID &&
               (AutomationTextEntryPolicy.isSecure(role: $0["role"] as? String ?? "", subrole: $0["subrole"] as? String ?? "") || $0["value"] as? String == "[secure]") }) {
            needed.insert(inspectionPID)
        }
        guard !needed.isEmpty else { return ScreenTextSnapshot() }
        var result = ScreenTextSnapshot(state: "partial")
        let allWindows = windows(scene: scene)
        let securePIDs = Set(snapshot.elements.compactMap { row -> Int? in
            AutomationTextEntryPolicy.isSecure(role: row["role"] as? String ?? "", subrole: row["subrole"] as? String ?? "")
                || row["value"] as? String == "[secure]" ? row["pid"] as? Int : nil
        })
        let appOrder = snapshot.applications.compactMap { $0["pid"] as? Int }
        let selected = allWindows.filter { window in
            window.layer == 0 && needed.contains(window.pid) && window.frame.intersects(coordinates.displayBounds) &&
                !allWindows.contains { securePIDs.contains($0.pid) && $0.frame.intersects(window.frame) }
        }.sorted { a, b in
            if (a.pid == inspectionPID) != (b.pid == inspectionPID) { return a.pid == inspectionPID }
            let aIndex = appOrder.firstIndex(of: a.pid) ?? Int.max
            let bIndex = appOrder.firstIndex(of: b.pid) ?? Int.max
            return aIndex == bIndex ? allWindows.firstIndex(of: a)! < allWindows.firstIndex(of: b)! : aIndex < bIndex
        }
        guard !selected.isEmpty else { return result }
        let deadline = ProcessInfo.processInfo.systemUptime + min(1.5, max(0, budget))
        var finished = 0
        for window in selected.prefix(maximumCrops) {
            try await TaskOwnership.checkpoint()
            guard deadline > ProcessInfo.processInfo.systemUptime else { break }
            let visible = window.frame.intersection(coordinates.displayBounds)
            guard let (crop, mapping) = try crop(image, coordinates: coordinates, frame: visible) else { continue }
            let matches: [ScreenTextMatch]
            do { matches = try await recognize(crop, mapping, deadline - ProcessInfo.processInfo.systemUptime) }
            catch is CancellationError { throw CancellationError() }
            catch { continue } // OCR failure is explicitly partial, never model fallback.
            try await TaskOwnership.checkpoint()
            finished += 1
            for match in matches {
                guard !match.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, match.text.count <= 256,
                      match.confidence.isFinite, (0.45...1).contains(match.confidence),
                      visible.contains(match.frame), match.frame.width > 0, match.frame.height > 0 else { continue }
                let center = CGPoint(x: match.frame.midX, y: match.frame.midY)
                // A crop may include another app's window. Actual z-order owns
                // the entire label, not just a guessed application rectangle.
                let points = [center, match.frame.origin, CGPoint(x: match.frame.maxX - 0.01, y: match.frame.maxY - 0.01)]
                guard points.allSatisfy({ point in allWindows.first { $0.frame.contains(point) } == window }) else { continue }
                let exposed = snapshot.elements.filter { row in
                    guard row["pid"] as? Int == window.pid,
                          (row["actions"] as? [String])?.contains("AXPress") == true,
                          !["AXWindow", "AXApplication", "AXGroup", "AXWebArea", "AXScrollArea"].contains(row["role"] as? String ?? ""),
                          let f = frame(row["frame"]) else { return false }
                    return f.contains(center)
                }
                // Preserve an actual disagreement. Native controls still own
                // execution; neither label silently replaces the other.
                if !exposed.isEmpty && window.pid != inspectionPID &&
                    !exposed.contains(where: { ControlEvidencePolicy.disagrees(match, with: $0) }) { continue }
                result.targets.append(ScreenTextTarget(match: match, window: window))
            }
        }
        let tokens = Set(keywords.map { $0.lowercased() })
        let nativeLabels = snapshot.elements.compactMap { row -> (Int, CGRect, [String: Any])? in
            guard let pid = row["pid"] as? Int, ControlEvidencePolicy.labelRoles.contains(row["role"] as? String ?? ""),
                  let bounds = frame(row["frame"]) else { return nil }
            return (pid, bounds, row)
        }
        // Compute priority once, rather than re-reading every native frame
        // inside the sort. Opposing labels must survive the bounded list even
        // when an agreeing task keyword would otherwise outrank them.
        result.targets = result.targets.enumerated().map { index, target in
            let conflict = nativeLabels.contains { pid, bounds, row in
                pid == target.window.pid && bounds.contains(target.match.frame) &&
                    ControlEvidencePolicy.disagrees(target.match, with: row)
            }
            let words = Set(target.match.text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            return (target: target, conflict: conflict, score: words.intersection(tokens).count, index: index)
        }.sorted { a, b in
            if a.conflict != b.conflict { return a.conflict }
            if a.score != b.score { return a.score > b.score }
            if a.target.window != b.target.window { return selected.firstIndex(of: a.target.window)! < selected.firstIndex(of: b.target.window)! }
            if a.target.match.frame.minY != b.target.match.frame.minY { return a.target.match.frame.minY < b.target.match.frame.minY }
            if a.target.match.frame.minX != b.target.match.frame.minX { return a.target.match.frame.minX < b.target.match.frame.minX }
            return a.index < b.index
        }.map(\.target)
        let total = result.targets.count
        result.targets = Array(result.targets.prefix(maximumTargets))
        result.state = finished == selected.count && total <= maximumTargets ? "recognized" : "partial"
        // Small detail regions retain nearby labels. Keep original resolution;
        // never invent pixels or treat crop coordinates as display coordinates.
        for target in result.targets.prefix(maximumCrops) {
            let region = target.match.frame.insetBy(dx: -90, dy: -55).intersection(target.window.frame)
                .intersection(coordinates.displayBounds)
            if let (detail, mapping) = try crop(image, coordinates: coordinates, frame: region),
               let data = png(detail), data.count <= 524_288 {
                result.crops.append(["candidate_text": target.match.text, "pid": target.window.pid,
                    "graphics_window_id": target.window.id, "image_to_global": mapping.metadata(revision: "")["image_to_global"]!,
                    "image_size": ["width": detail.width, "height": detail.height],
                    "mime_type": "image/png", "data": data.base64EncodedString()])
            }
        }
        try TaskOwnership.check()
        return result
    }

    static func frame(_ value: Any?) -> CGRect? {
        guard let f = value as? [String: Any], let x = f["x"] as? NSNumber, let y = f["y"] as? NSNumber,
              let w = f["width"] as? NSNumber, let h = f["height"] as? NSNumber else { return nil }
        let r = CGRect(x: x.doubleValue, y: y.doubleValue, width: w.doubleValue, height: h.doubleValue)
        return serializedAccessibilityFrame(r) != nil && r.width > 0 && r.height > 0 ? r : nil
    }

    static func crop(_ image: CGImage, coordinates: ScreenCoordinateMapping, frame: CGRect) throws -> (CGImage, ScreenCoordinateMapping)? {
        let first = try coordinates.imagePoint(fromGlobal: frame.origin)
        let last = try coordinates.imagePoint(fromGlobal: CGPoint(x: frame.maxX, y: frame.maxY))
        let pixels = CGRect(x: first.x, y: first.y, width: last.x - first.x, height: last.y - first.y).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isEmpty, let cropped = image.cropping(to: pixels) else { return nil }
        return (cropped, try coordinates.cropped(to: pixels, outputSize: CGSize(width: cropped.width, height: cropped.height)))
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A fresh local read may support a provisional coordinate click. It does
    /// not prove the role, enabled state or result; native hit checks still run.
    static func validate(_ target: ScreenTextTarget, matches: [ScreenTextMatch], point: CGPoint) throws {
        let found = matches.filter { $0.text == target.match.text && $0.confidence >= executionConfidence &&
            abs($0.frame.minX - target.match.frame.minX) <= 2 && abs($0.frame.minY - target.match.frame.minY) <= 2 &&
            abs($0.frame.width - target.match.frame.width) <= 2 && abs($0.frame.height - target.match.frame.height) <= 2 &&
            $0.frame.contains(point) }
        guard found.count == 1 else { throw AccessibilityActionError.staleObservation }
        guard matches.filter({ $0.frame.contains(point) }).count == 1 else { throw AccessibilityActionError.ambiguousTarget }
    }

    /// Vision runs off the main thread. A cancellation/deadline cancels the
    /// request; wait for its worker to end so owned work cannot escape drainage.
    static func recognize(_ image: CGImage, _ coordinates: ScreenCoordinateMapping,
                          _ budget: TimeInterval) async throws -> [ScreenTextMatch] {
        guard budget > 0 else { throw RecognitionError.expired }
        let work = VisionTextWork()
        let lease = TaskOwnership.current
        let timer = Task { try await Task.sleep(for: .seconds(budget)); work.cancel() }
        defer { timer.cancel() }
        let result: [ScreenTextMatch] = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try lease?.check(); try work.check()
                        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
                        try handler.perform([work.request]); try work.check()
                        let matches = try (work.request.results ?? []).flatMap { observation -> [ScreenTextMatch] in
                            guard let candidate = observation.topCandidates(1).first else { return [] }
                            // A line can span neighboring buttons ("Save Cancel").
                            // Word boxes keep its midpoint out of the gap while
                            // preserving the full line as surrounding context.
                            return try candidate.string.split(whereSeparator: { $0.isWhitespace }).compactMap { word in
                                guard let box = try candidate.boundingBox(for: word.startIndex..<word.endIndex) else { return nil }
                                return ScreenTextMatch(text: String(word), confidence: Double(candidate.confidence),
                                    frame: try globalFrame(box.boundingBox, coordinates: coordinates),
                                    lineText: String(candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256)))
                            }
                        }
                        continuation.resume(returning: matches)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { work.cancel() })
        try TaskOwnership.check()
        return result
    }

    private enum RecognitionError: Error { case expired }
    private final class VisionTextWork: @unchecked Sendable {
        let request = VNRecognizeTextRequest()
        private let lock = NSLock()
        private var cancelled = false
        init() {
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = true
            request.minimumTextHeight = 0.005
        }
        func cancel() { lock.withLock { cancelled = true }; request.cancel() }
        func check() throws { if lock.withLock({ cancelled }) { throw RecognitionError.expired } }
    }
}
