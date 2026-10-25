import ApplicationServices
import CoreGraphics
import Foundation

/// A window offered by Live View. Its opaque selection ID is short lived and
/// resolves only to an Accessibility window retained by the native controller.
struct WorkingDocumentCandidate: Equatable, Identifiable {
    let selectionID: String
    let displayID: CGDirectDisplayID
    let pid: Int32
    let bundleID: String
    let processLaunchTime: TimeInterval
    let applicationName: String
    let title: String
    let location: String?
    let documentURL: String?
    let accessibilityIdentity: String
    let graphicsWindowID: UInt32?
    let focused: Bool
    let availableSelection: WorkingSelectionCandidate?

    init(selectionID: String, displayID: CGDirectDisplayID, pid: Int32, bundleID: String,
         processLaunchTime: TimeInterval, applicationName: String, title: String, location: String?,
         documentURL: String?, accessibilityIdentity: String, graphicsWindowID: UInt32?, focused: Bool,
         availableSelection: WorkingSelectionCandidate? = nil) {
        self.selectionID = selectionID
        self.displayID = displayID
        self.pid = pid
        self.bundleID = bundleID
        self.processLaunchTime = processLaunchTime
        self.applicationName = applicationName
        self.title = title
        self.location = location
        self.documentURL = documentURL
        self.accessibilityIdentity = accessibilityIdentity
        self.graphicsWindowID = graphicsWindowID
        self.focused = focused
        self.availableSelection = availableSelection
    }

    var id: String { selectionID }

    var menuTitle: String {
        let base = title.isEmpty ? "Untitled window" : title
        let place = location.map { " — \($0)" } ?? ""
        let active = focused ? " (front)" : ""
        return "\(base) — \(applicationName)\(place)\(active)"
    }

    var wireValue: [String: Any] {
        var value: [String: Any] = [
            "version": 1, "selection_id": selectionID, "display_id": Int(displayID),
            "pid": Int(pid), "bundle_id": bundleID, "process_launch_time": processLaunchTime,
            "application": applicationName, "title": title,
            "accessibility_identity": accessibilityIdentity
        ]
        if let location { value["location"] = location }
        if let documentURL { value["document_url"] = documentURL }
        if let graphicsWindowID { value["graphics_window_id"] = Int(graphicsWindowID) }
        return value
    }
}

/// A safe, presentation-only description of one native selection. The opaque
/// ID resolves to an Accessibility-backed record kept by the controller; no
/// AX objects or selected contents cross into SwiftUI or the runtime prompt.
struct WorkingSelectionCandidate: Equatable, Identifiable {
    enum Kind: String { case text, cellRange, section }
    let selectionID: String
    let kind: Kind
    let description: String
    var id: String { selectionID }
}

struct WorkingDocumentPresentation: Equatable {
    enum State: Equatable { case pending, active, needsReselection }
    let generationID: String
    var revision: UInt64
    var application: String
    var title: String
    var location: String?
    var state: State
    var selectionDescription: String?
    var selectionState: State?

    init(generationID: String, revision: UInt64, application: String, title: String,
         location: String?, state: State, selectionDescription: String? = nil,
         selectionState: State? = nil) {
        self.generationID = generationID
        self.revision = revision
        self.application = application
        self.title = title
        self.location = location
        self.state = state
        self.selectionDescription = selectionDescription
        self.selectionState = selectionState
    }

    var summary: String {
        let base = "Working document: \(title.isEmpty ? "Untitled" : title) — \(application)"
        return base + (selectionDescription.map { " · \($0) only" } ?? "")
    }

    var stateLabel: String {
        switch state {
        case .pending: return "Pending"
        case .active: return "Active"
        case .needsReselection: return "Needs reselection"
        }
    }

    var selectionStateLabel: String? {
        guard let selectionState else { return nil }
        switch selectionState {
        case .pending: return "Pending"
        case .active: return "Active"
        case .needsReselection: return "Needs reselection"
        }
    }
}

/// Native-only binding data. AXUIElements and window identities never cross
/// the Python protocol or enter a saved task record.
struct WorkingDocumentNativeBinding {
    let generationID: String
    let revision: UInt64
    let pid: pid_t
    let application: AutomationApplicationIdentity
    let window: AXUIElement
    let accessibilityIdentity: String
    let graphicsWindowID: CGWindowID?
    let title: String
    let location: String?
    let documentURL: URL?
    let displayID: CGDirectDisplayID
    var selectionScope: WorkingSelectionNativeScope?
}

struct WorkingDocumentSelectionRecord {
    let candidate: WorkingDocumentCandidate
    let window: AXUIElement
    let application: AutomationApplicationIdentity
    let documentURL: URL?
    let expiresAt: TimeInterval
    let availableSelection: WorkingSelectionNativeRecord?
}

/// Native-only selection identity and bounded text anchors. The text value is
/// retained only in memory and is never serialized or added to prompts.
final class WorkingSelectionNativeRecord {
    let candidate: WorkingSelectionCandidate
    let window: AXUIElement
    let selectedElement: AXUIElement
    let container: AXUIElement
    let selectionOwner: AXUIElement
    let selectedCells: [AXUIElement]
    let selectedCellAnchors: [WorkingSelectionCellAnchor]
    let rowRange: ClosedRange<Int>?
    let columnRange: ClosedRange<Int>?
    let textRange: NSRange?
    var expectedTextValue: String?
    var expectedSelection: NSRange?

    init(candidate: WorkingSelectionCandidate, window: AXUIElement, selectedElement: AXUIElement,
         container: AXUIElement, selectedCells: [AXUIElement] = [],
         selectedCellAnchors: [WorkingSelectionCellAnchor] = [], rowRange: ClosedRange<Int>? = nil,
         columnRange: ClosedRange<Int>? = nil, textRange: NSRange? = nil, textValue: String? = nil,
         selectionOwner: AXUIElement? = nil) {
        self.candidate = candidate
        self.window = window
        self.selectedElement = selectedElement
        self.container = container
        self.selectionOwner = selectionOwner ?? container
        self.selectedCells = selectedCells
        self.selectedCellAnchors = selectedCellAnchors
        self.rowRange = rowRange
        self.columnRange = columnRange
        self.textRange = textRange
        self.expectedTextValue = textValue
        self.expectedSelection = textRange
    }
}

struct WorkingSelectionCellAnchor {
    let element: AXUIElement
    let row: Int
    let column: Int
}

typealias WorkingSelectionNativeScope = WorkingSelectionNativeRecord

struct WorkingDocumentUpdate: Equatable {
    static let protocolVersion = 2
    let id: String
    let generationID: String
    let revision: UInt64
    let candidate: WorkingDocumentCandidate?
    let selectionScopeID: String?
    let removeSelectionLimit: Bool

    init(id: String, generationID: String, revision: UInt64, candidate: WorkingDocumentCandidate?,
         selectionScopeID: String? = nil, removeSelectionLimit: Bool = false) {
        self.id = id
        self.generationID = generationID
        self.revision = revision
        self.candidate = candidate
        self.selectionScopeID = selectionScopeID
        self.removeSelectionLimit = removeSelectionLimit
    }

    var wireValue: [String: Any] {
        var value: [String: Any] = [
            "version": Self.protocolVersion,
            "update_id": id,
            "task_generation_id": generationID,
            "binding_revision": revision
        ]
        if let candidate { value["selection_id"] = candidate.selectionID }
        if let selectionScopeID { value["selection_scope_id"] = selectionScopeID }
        if removeSelectionLimit { value["remove_selection_limit"] = true }
        return value
    }
}

enum WorkingSelectionScopePolicy {
    static let maximumTextBytes = 128 * 1024
    static let maximumCellCount = 64

    static func validTextRange(_ range: NSRange, in value: String, allowEmpty: Bool = false) -> Bool {
        guard range.location >= 0, (allowEmpty || range.length > 0),
              range.location <= value.utf16.count,
              range.length <= value.utf16.count - range.location,
              value.utf8.count <= maximumTextBytes else { return false }
        let utf16 = value.utf16
        let lower = utf16.index(utf16.startIndex, offsetBy: range.location)
        let upper = utf16.index(lower, offsetBy: range.length)
        return String.Index(lower, within: value) != nil && String.Index(upper, within: value) != nil
    }

    static func replacementPreservesOutsideRegion(before: String, after: String,
                                                   range: NSRange, replacement: String) -> NSRange? {
        guard validTextRange(range, in: before), replacement.utf8.count <= maximumTextBytes,
              let expected = AutomationTextEntryPolicy.inserting(replacement, into: before, selection: range),
              expected == after else { return nil }
        let next = NSRange(location: range.location, length: replacement.utf16.count)
        guard validTextRange(next, in: after, allowEmpty: true) else { return nil }
        return next
    }

    static func rectangularBounds(_ coordinates: [(row: Int, column: Int)]) ->
        (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        guard !coordinates.isEmpty, coordinates.count <= maximumCellCount,
              Set(coordinates.map { "\($0.row):\($0.column)" }).count == coordinates.count,
              let minRow = coordinates.map(\.row).min(), let maxRow = coordinates.map(\.row).max(),
              let minColumn = coordinates.map(\.column).min(), let maxColumn = coordinates.map(\.column).max(),
              maxRow >= minRow, maxColumn >= minColumn,
              (maxRow - minRow + 1) * (maxColumn - minColumn + 1) == coordinates.count else { return nil }
        return (minRow...maxRow, minColumn...maxColumn)
    }

    static func permits(action: [String: Any], scopeKind: WorkingSelectionCandidate.Kind,
                        targetMatchesScope: Bool, currentSelectionMatches: Bool,
                        targetRole: String? = nil, targetLabel: String? = nil,
                        allowSaveExport: Bool = false) -> Bool {
        guard targetMatchesScope, currentSelectionMatches,
              let type = action["type"] as? String else { return false }
        switch type {
        case "scroll", "focus": return true
        case "type_text": return scopeKind == .text ||
            (scopeKind == .cellRange && ["AXCell", "AXTextField", "AXTextArea", "AXComboBox"].contains(targetRole ?? ""))
        case "set_value": return (scopeKind == .cellRange && targetRole == "AXCell") ||
            (scopeKind == .section && ["AXTextField", "AXTextArea", "AXComboBox"].contains(targetRole ?? ""))
        case "press", "click", "double_click":
            if scopeKind == .cellRange, targetRole == "AXCell" { return true }
            guard let label = targetLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let role = targetRole else { return false }
            if safeNavigationLabels.contains(label), ["AXMenuBarItem", "AXMenuItem", "AXButton"].contains(role) { return true }
            if allowSaveExport, saveExportLabels.contains(label), ["AXMenuItem", "AXButton"].contains(role) { return true }
            return ["AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton"].contains(role)
                && formattingLabels.contains(label)
        case "key":
            let key = (action["key"] as? String ?? "").lowercased()
            let modifiers = Set(action["modifiers"] as? [String] ?? [])
            if modifiers == ["command"] && ["b", "i", "u"].contains(key) { return true }
            if allowSaveExport && ((key == "s" && modifiers == ["command"]) ||
                                   (key == "s" && modifiers == ["command", "shift"])) { return true }
            return false
        default: return false
        }
    }

    private static let formattingLabels: Set<String> = [
        "bold", "italic", "underline", "strikethrough", "wrap text", "wrap text in cell",
        "align left", "align center", "align right", "align top", "align middle", "align bottom",
        "increase indent", "decrease indent", "increase font size", "decrease font size",
        "font color", "text color", "fill color", "cell color", "number format", "format cells"
    ]
    private static let safeNavigationLabels: Set<String> = ["file"]
    static let saveExportLabels: Set<String> = ["save", "save as", "export", "export as", "export to pdf"]
}
