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

struct WorkingDocumentPresentation: Equatable {
    enum State: Equatable { case pending, active, needsReselection }
    let generationID: String
    var revision: UInt64
    var application: String
    var title: String
    var location: String?
    var state: State

    var summary: String {
        "Working document: \(title.isEmpty ? "Untitled" : title) — \(application)"
    }

    var stateLabel: String {
        switch state {
        case .pending: "Pending"
        case .active: "Active"
        case .needsReselection: "Needs reselection"
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
}

struct WorkingDocumentSelectionRecord {
    let candidate: WorkingDocumentCandidate
    let window: AXUIElement
    let application: AutomationApplicationIdentity
    let documentURL: URL?
    let expiresAt: TimeInterval
}

struct WorkingDocumentUpdate: Equatable {
    static let protocolVersion = 1
    let id: String
    let generationID: String
    let revision: UInt64
    let candidate: WorkingDocumentCandidate?

    var wireValue: [String: Any] {
        var value: [String: Any] = [
            "version": 1,
            "update_id": id,
            "task_generation_id": generationID,
            "binding_revision": revision
        ]
        if let candidate { value["selection_id"] = candidate.selectionID }
        return value
    }
}
