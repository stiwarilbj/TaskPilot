import Foundation

enum TextAttributeDelivery: Equatable {
    case accepted, unsupported, uncertain
}

struct AutomationTextEntryResult {
    let method: String
    let verification: String
    var verified: Bool { verification == "matched" || verification == "already_matched" }

    var message: String {
        switch verification {
        case "matched": return "Entered text; read-back matched the intended value"
        case "already_matched": return "The intended field already contains the requested value; no text was entered"
        case "mismatch": return "Text delivery ended, but read-back did not match; inspect before entering more text"
        default: return "Text delivery ended; the value cannot be verified locally, so inspect before entering more text"
        }
    }

    func dictionary(pid: Int32) -> [String: Any] {
        ["message": message, "delivery_method": method,
         "outcome": verified ? "verified" : "delivered_unconfirmed",
         "verification_scope": "text_value", "text_verification": verification, "pid": Int(pid)]
    }
}

enum AutomationTextEntryPolicy {
    static let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"]

    static func isSecure(role: String, subrole: String) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    static func isBrowserAddressField(label: String, ancestorRoles: [String]) -> Bool {
        let label = label.lowercased()
        return ancestorRoles.contains("AXToolbar") && !ancestorRoles.contains("AXWebArea")
            && ["address", "location", "url", "search or enter"].contains { label.contains($0) }
    }

    static func inserting(_ text: String, into value: String?, selection: NSRange?) -> String? {
        guard let value, let selection, selection.location != NSNotFound,
              selection.location >= 0, selection.length >= 0,
              selection.location <= value.utf16.count,
              selection.length <= value.utf16.count - selection.location else { return nil }
        let utf16 = value.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: selection.location)
        let end = utf16.index(start, offsetBy: selection.length)
        guard let lower = String.Index(start, within: value), let upper = String.Index(end, within: value) else { return nil }
        return value.replacingCharacters(in: lower..<upper, with: text)
    }

    static func deliverChunks(_ chunks: [String], preflight: () throws -> Void,
                              cancelled: () -> Bool, deliver: (String) throws -> Void) throws {
        var delivered = false
        for chunk in chunks {
            do { try preflight() }
            catch {
                if cancelled() { throw AccessibilityActionError.cancelled }
                guard delivered else { throw error }
                throw AccessibilityActionError.uncertainDelivery("Text entry stopped after partial delivery; inspect the intended field before entering more text")
            }
            try deliver(chunk)
            delivered = true
        }
    }

    /// All hooks operate on one bound field. Unsupported attributes permit a
    /// different method; accepted or ambiguous delivery never permits replay.
    static func enter(
        text: String, replacement: Bool, secure: Bool,
        focus: () async throws -> Void, preflight: @escaping () throws -> Void,
        readValue: @escaping () -> String?, readSelection: () -> NSRange?,
        setValue: (String) throws -> TextAttributeDelivery,
        setSelectedText: (String) throws -> TextAttributeDelivery,
        selectRange: (NSRange) throws -> Bool,
        typeText: (String, () throws -> Void) throws -> Void,
        waitForMatch: (() -> Bool) async throws -> Void
    ) async throws -> AutomationTextEntryResult {
        try await focus()
        try preflight()
        let before = secure ? nil : readValue()
        let selection = secure ? nil : readSelection()
        let expected = replacement ? text : inserting(text, into: before, selection: selection)
        if !secure, replacement, before == expected {
            return AutomationTextEntryResult(method: "local_check", verification: "already_matched")
        }

        var method = "process_event"
        var delivered = false
        // Full-value setters belong to replacement. Insertion uses the native
        // selected-text setter so it preserves rich text and caret semantics.
        if let expected, replacement {
            try preflight()
            switch try setValue(expected) {
            case .accepted, .uncertain:
                method = "accessibility_value"
                delivered = true
            case .unsupported: break
            }
        }
        if !delivered {
            if replacement {
                // Replacement by keyboard is safe only with a readable value
                // and an acknowledged selection of the whole field.
                guard !secure, let before else {
                    throw AccessibilityActionError.operationFailed("The field cannot safely replace its value; choose another text-entry method")
                }
                let all = NSRange(location: 0, length: before.utf16.count)
                try preflight()
                guard try selectRange(all), readSelection() == all else {
                    throw AccessibilityActionError.operationFailed("The field did not select its whole value; no replacement text was delivered")
                }
            }
            try preflight()
            switch try setSelectedText(text) {
            case .accepted, .uncertain:
                method = "accessibility_selected_text"
                delivered = true
            case .unsupported: break
            }
            if !delivered { try typeText(text, preflight) }
        }
        guard !secure else { return AutomationTextEntryResult(method: method, verification: "secure") }
        guard let expected else { return AutomationTextEntryResult(method: method, verification: "unavailable") }
        try await waitForMatch { readValue() == expected }
        let actual = readValue()
        return AutomationTextEntryResult(method: method,
            verification: actual == expected ? "matched" : (actual == nil ? "unavailable" : "mismatch"))
    }
}
