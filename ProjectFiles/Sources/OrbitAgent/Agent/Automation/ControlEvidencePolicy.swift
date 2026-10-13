import CoreFoundation
import Foundation

/// Read-only inspection metadata is private; it grants no delivery authority.
enum ControlEvidencePolicy {
    static let version = 1
    static let labelRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem", "AXMenuBarItem", "AXTab", "AXLink"]

    static func inspectionPID(_ value: Any?) throws -> Int? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              (1...Double(Int32.max)).contains(number.doubleValue) else {
            throw TaskToolError.invalidAction("evidence_inspection_pid must be a positive integer PID")
        }
        return number.intValue
    }

    static func normalized(_ value: String) -> String {
        var text = value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while let last = text.last, last == "." || last == "…" { text.removeLast() }
        return text
    }

    static func disagrees(_ match: ScreenTextMatch, with row: [String: Any]) -> Bool {
        guard match.confidence >= 0.9, labelRoles.contains(row["role"] as? String ?? ""),
              let frame = LocalTextRecognition.frame(row["frame"]), frame.contains(match.frame) else { return false }
        let text = normalized(match.text)
        let aliases = ["title", "label"].compactMap { row[$0] as? String }.map(normalized).filter { !$0.isEmpty }
        guard !text.isEmpty, !aliases.isEmpty else { return false }
        // OCR often supplies one word of a longer label. Partial overlap is
        // inconclusive, never an assertion that the whole label agrees.
        let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: text) + "(?!\\w)"
        return !aliases.contains { $0 == text || $0.range(of: pattern, options: .regularExpression) != nil }
    }
}
