import Foundation

struct StopBoundaryRecord: Equatable, Identifiable {
    let action: String
    let label: String
    let source: String
    let utf8Range: Range<Int>

    var id: String { action }
}

enum StopBoundaryPolicy {
    static let version = 1

    private struct Event {
        let range: NSRange
        let position: Int
        let verb: String
        let prohibited: Bool
    }

    private static let actionVerbPattern = #"(?:send(?:ing)?|publish(?:ing)?|post(?:ing)?|submit(?:ting)?|purchase|buy(?:ing)?|order(?:ing)?|checkout|check\s+out|place\s+(?:(?:an?|the|your)\s+)?order|deploy(?:ing)?)"#
    private static let negativePattern = #"\b(?:don[’']t|do\s+not|never|without|stop\s+before)\s+(?:(?:click(?:\s+on)?|press(?:\s+on)?|hit|tap|activate|trigger|ever|actually|use)\s+)*(?:"#
        + actionVerbPattern + #")(?:\s+(?:or|and)\s+"# + actionVerbPattern + #")*\b"#
    private static let positivePattern = #"\b(?:you\s+(?:may|can)(?:\s+now)?|go\s+ahead\s+and|please\s+(?:go\s+ahead\s+and\s+)?|actually\s*[,;:]?\s*|now\s+)\s*("#
        + actionVerbPattern + #")(?:\s+now)?\b"#
    private static let correctionPositivePattern = #"\b(?:user\s+correction|correction|new\s+instruction)\s*:\s*(?:please\s+)?("#
        + actionVerbPattern + #")\b"#

    static func detect(in text: String, exactInputReferences: [AgentTaskInputReference] = []) -> [StopBoundaryRecord] {
        guard !text.isEmpty else { return [] }
        let original = text as NSString
        let length = original.length
        var masked = Array(text.utf16)
        var hidden = Array(repeating: false, count: length)

        // Explicit chip values are data, even when their contents look like
        // instructions. Validate the exact source bytes before excluding them.
        let bytes = Array(text.utf8)
        for reference in exactInputReferences {
            guard reference.utf8Start >= 0, reference.utf8Length > 0,
                  reference.utf8Start <= bytes.count,
                  reference.utf8Length <= bytes.count - reference.utf8Start,
                  let value = String(bytes: bytes[reference.utf8Start..<(reference.utf8Start + reference.utf8Length)], encoding: .utf8),
                  value == reference.value,
                  let start8 = text.utf8.index(text.utf8.startIndex, offsetBy: reference.utf8Start, limitedBy: text.utf8.endIndex),
                  let end8 = text.utf8.index(start8, offsetBy: reference.utf8Length, limitedBy: text.utf8.endIndex),
                  let start = String.Index(start8, within: text),
                  let end = String.Index(end8, within: text) else { continue }
            let range = NSRange(start..<end, in: text)
            guard range.location != NSNotFound, range.location + range.length <= length else { continue }
            for index in range.location..<(range.location + range.length) { hidden[index] = true }
        }

        // Markdown block quotes are quoted source text, not user directives.
        var lineStart = 0
        while lineStart < length {
            var lineEnd = lineStart
            while lineEnd < length, original.character(at: lineEnd) != 10, original.character(at: lineEnd) != 13 { lineEnd += 1 }
            var first = lineStart
            while first < lineEnd, original.character(at: first) == 32 || original.character(at: first) == 9 { first += 1 }
            if first < lineEnd, original.character(at: first) == 62 {
                for index in lineStart..<lineEnd { hidden[index] = true }
            }
            lineStart = lineEnd + 1
        }

        // Paired quotation marks and code spans are masked. Apostrophes inside
        // contractions such as “don't” are not quote delimiters.
        // Mask paired quotation marks while keeping UTF-16 offsets stable.
        var quote: unichar = 0
        if length > 0 {
            for index in 0..<length {
                guard !hidden[index] else { continue }
                let unit = original.character(at: index)
                if quote != 0 {
                    let previous = index > 0 ? original.character(at: index - 1) : 0
                    let next = index + 1 < length ? original.character(at: index + 1) : 0
                    if (unit == 39 || unit == 8217), isWord(previous), isWord(next) {
                        hidden[index] = true
                        continue
                    }
                    hidden[index] = true
                    if unit == quote { quote = 0 }
                    continue
                }
                let previous = index > 0 ? original.character(at: index - 1) : 0
                let next = index + 1 < length ? original.character(at: index + 1) : 0
                if (unit == 39 || unit == 8217), isWord(previous), isWord(next) { continue }
                switch unit {
                case 34, 96, 39, 8217: quote = unit; hidden[index] = true
                case 8220: quote = 8221; hidden[index] = true
                case 8216: quote = 8217; hidden[index] = true
                default: break
                }
            }
        }

        for index in 0..<length where hidden[index] { masked[index] = 32 }
        let visible = String(utf16CodeUnits: masked, count: masked.count)
        let fullRange = NSRange(location: 0, length: (visible as NSString).length)
        let negative = (try? NSRegularExpression(pattern: negativePattern, options: [.caseInsensitive]))?.matches(
            in: visible, range: fullRange) ?? []
        let verbExpression = try? NSRegularExpression(pattern: actionVerbPattern, options: [.caseInsensitive])
        var events: [Event] = []
        for match in negative {
            let clause = (visible as NSString).substring(with: match.range)
            let clauseRange = NSRange(location: 0, length: (clause as NSString).length)
            let verbs = verbExpression?.matches(in: clause, range: clauseRange) ?? []
            for verb in verbs {
                let sourcePosition = match.range.location + verb.range.location
                events.append(Event(range: match.range, position: sourcePosition,
                                    verb: (clause as NSString).substring(with: verb.range), prohibited: true))
            }
        }
        for pattern in [positivePattern, correctionPositivePattern] {
            let matches = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?.matches(
                in: visible, range: fullRange) ?? []
            events.append(contentsOf: matches.map { match in
                Event(range: match.range, position: match.range.location + match.range(at: 1).location,
                      verb: original.substring(with: match.range(at: 1)), prohibited: false)
            })
        }
        events.sort { $0.position == $1.position ? !$0.prohibited && $1.prohibited : $0.position < $1.position }

        var active: [String: (record: StopBoundaryRecord, position: Int)] = [:]
        for event in events {
            let action = actionName(event.verb)
            guard !action.isEmpty, event.range.location >= 0,
                  event.range.location + event.range.length <= length else { continue }
            if !event.prohibited {
                active.removeValue(forKey: action)
                continue
            }
            let startIndex = String.Index(utf16Offset: event.range.location, in: text)
            let endIndex = String.Index(utf16Offset: event.range.location + event.range.length, in: text)
            let source = String(text[startIndex..<endIndex])
            let byteStart = text[..<startIndex].utf8.count
            let byteLength = source.utf8.count
            active[action] = (StopBoundaryRecord(action: action, label: displayLabel(action), source: source,
                                                 utf8Range: byteStart..<(byteStart + byteLength)), event.position)
        }
        return active.values.sorted { $0.position < $1.position }.map(\.record)
    }

    static func validate(action: [String: Any], boundaries: [StopBoundaryRecord], targetRole: String? = nil,
                         targetLabels: [String] = [], targetIsReliable: Bool = false,
                         applicationName: String? = nil) throws {
        guard !boundaries.isEmpty else { return }
        let type = action["type"] as? String ?? ""
        if ["read_file", "write_file", "focus", "set_value", "type_text", "scroll", "wait", "none", "launch_app"].contains(type) {
            if ["set_value", "type_text"].contains(type), isTerminalName(applicationName) {
                throw StopBoundaryViolation.uncertain(boundaries[0].label)
            }
            return
        }
        if type == "run_command" {
            let operation = (action["operation"] as? [String: Any])?["type"] as? String
            let permitted = Set(["create_directory", "copy_file", "move_file", "remove_file",
                                 "remove_empty_directory", "print_text"])
            guard let operation, permitted.contains(operation) else {
                throw StopBoundaryViolation.uncertain(boundaries[0].label)
            }
            return
        }
        if ["open_route", "navigate_browser"].contains(type) {
            let route = ["url", "route_id", "query"].compactMap { action[$0] as? String }.joined(separator: " ")
            if let boundary = boundaries.first(where: { matches(route, action: $0.action) }) {
                throw StopBoundaryViolation.rejected(boundary.label)
            }
            return
        }
        if ["click", "double_click", "press"].contains(type) {
            let safeTextClick = ["click", "double_click"].contains(type) && ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"].contains(targetRole ?? "")
            let actionRole = ["AXButton", "AXDefaultButton", "AXMenuItem", "AXMenuBarItem", "AXLink",
                              "AXPopUpButton", "AXRadioButton", "AXCheckBox", "AXTab", "AXRow", "AXCell",
                              "AXOutline", "AXTable", "AXList"].contains(targetRole ?? "")
            guard targetIsReliable, actionRole || safeTextClick,
                  targetLabels.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw StopBoundaryViolation.uncertain(boundaries[0].label)
            }
            let primary = targetLabels.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let generic = primary.isEmpty || ["ok", "continue", "done", "yes", "confirm", "finish", "go"].contains(primary.lowercased())
            for boundary in boundaries {
                if matches(primary, action: boundary.action) || (generic && targetLabels.contains(where: { matches($0, action: boundary.action) })) {
                    throw StopBoundaryViolation.rejected(boundary.label)
                }
            }
            if generic { throw StopBoundaryViolation.uncertain(boundaries[0].label) }
            return
        }
        if type == "key" {
            // Return in a terminal executes the current shell line. Even a
            // known label cannot establish that the command stays within a
            // stop-before boundary, so hold every terminal key action.
            if isTerminalName(applicationName) {
                throw StopBoundaryViolation.uncertain(boundaries[0].label)
            }
            let key = (action["key"] as? String ?? "").lowercased()
            let modifiers = Set((action["modifiers"] as? [String] ?? []).map { $0.lowercased() })
            guard targetIsReliable else { throw StopBoundaryViolation.uncertain(boundaries[0].label) }
            let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"]
            let editingKeys: Set<String> = ["left", "right", "up", "down", "home", "end", "pageup", "pagedown",
                                             "backspace", "delete", "tab", "escape"]
            if modifiers.isEmpty, textRoles.contains(targetRole ?? ""), editingKeys.contains(key) { return }
            if !modifiers.isEmpty {
                let commandEditing = modifiers.isSubset(of: ["command", "cmd"]) &&
                    ["a", "c", "v", "x", "z"].contains(key) && textRoles.contains(targetRole ?? "")
                guard commandEditing else { throw StopBoundaryViolation.uncertain(boundaries[0].label) }
                return
            }
            if ["return", "enter"].contains(key) {
                for boundary in boundaries where targetLabels.contains(where: { matches($0, action: boundary.action) }) {
                    throw StopBoundaryViolation.rejected(boundary.label)
                }
                throw StopBoundaryViolation.uncertain(boundaries[0].label)
            }
            if key == "space" || key == " ", ["AXButton", "AXDefaultButton", "AXMenuItem", "AXMenuBarItem",
                "AXLink", "AXPopUpButton", "AXRadioButton", "AXCheckBox", "AXTab"].contains(targetRole ?? "") {
                for boundary in boundaries where targetLabels.contains(where: { matches($0, action: boundary.action) }) {
                    throw StopBoundaryViolation.rejected(boundary.label)
                }
                throw StopBoundaryViolation.uncertain(boundaries[0].label)
            }
            guard editingKeys.contains(key) || (textRoles.contains(targetRole ?? "") && key == "space") else {
                throw StopBoundaryViolation.uncertain(boundaries[0].label)
            }
            return
        }
        throw StopBoundaryViolation.uncertain(boundaries[0].label)
    }

    private static func isWord(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func actionName(_ verb: String) -> String {
        let value = verb.lowercased()
        if value.hasPrefix("send") { return "send" }
        if value.hasPrefix("publish") || value.hasPrefix("post") { return "publish" }
        if value.hasPrefix("submit") { return "submit" }
        if ["purchase", "buy", "buying", "order", "ordering", "checkout", "check out"].contains(value) || value.hasPrefix("place ") { return "purchase" }
        if value.hasPrefix("deploy") { return "deploy" }
        return ""
    }

    private static func displayLabel(_ action: String) -> String {
        switch action {
        case "send": return "Send"
        case "publish": return "Publish/Post"
        case "submit": return "Submit"
        case "purchase": return "Purchase/Place order"
        case "deploy": return "Deploy"
        default: return action.capitalized
        }
    }

    private static func matches(_ text: String, action: String) -> Bool {
        let word = switch action {
        case "send": #"\b(?:send|sending|deliver|dispatch)\b"#
        case "publish": #"\b(?:publish|publishing|post|posting)\b"#
        case "submit": #"\b(?:submit|submitting)\b"#
        case "purchase": #"\b(?:purchase|buy|buying|order|ordering|checkout|check\s+out|place(?:\s+\w+){0,2}\s+order)\b"#
        case "deploy": #"\b(?:deploy|deploying|release)\b"#
        default: #"(?!)"#
        }
        return (try? NSRegularExpression(pattern: word, options: [.caseInsensitive]))?.firstMatch(
            in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func isTerminalName(_ applicationName: String?) -> Bool {
        guard let applicationName else { return false }
        return ["terminal", "iterm", "console", "warp", "kitty", "alacritty"].contains {
            applicationName.localizedCaseInsensitiveContains($0)
        }
    }
}

enum StopBoundaryViolation: LocalizedError {
    case rejected(String)
    case uncertain(String)

    var code: String {
        switch self {
        case .rejected: return "stop_boundary_rejected"
        case .uncertain: return "stop_boundary_uncertain"
        }
    }

    var errorDescription: String? {
        switch self {
        case .rejected(let label): return "TaskPilot stopped before \(label) as the request instructed. It can continue with verified preparation."
        case .uncertain(let label): return "TaskPilot held this action because its effect on the \(label) boundary is uncertain. Inspect the current target or choose a safe preparation step."
        }
    }
}
