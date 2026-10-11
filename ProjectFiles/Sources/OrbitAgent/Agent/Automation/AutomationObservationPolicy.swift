import CoreGraphics

enum AutomationObservationPolicy {
    /// Prefer the focused visible window and actual display z-order before
    /// another window of the same application consumes the capture budget.
    static func windowOrder(count: Int, focusedIndex: Int?, topmostIndex: Int?) -> [Int] {
        var order: [Int] = []
        for index in [focusedIndex, topmostIndex].compactMap({ $0 }) + Array(0..<max(0, count)) {
            if index >= 0, index < count, !order.contains(index) { order.append(index) }
        }
        return order
    }

    static func matchingWindowIndex(frames: [CGRect], topmostFrame: CGRect?) -> Int? {
        guard let topmostFrame else { return nil }
        let matches = frames.indices.filter {
            abs(frames[$0].minX - topmostFrame.minX) <= 2 && abs(frames[$0].minY - topmostFrame.minY) <= 2 &&
            abs(frames[$0].width - topmostFrame.width) <= 2 && abs(frames[$0].height - topmostFrame.height) <= 2
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
