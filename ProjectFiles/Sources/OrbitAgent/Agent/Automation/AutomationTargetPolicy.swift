import CoreGraphics
import Foundation

struct AutomationApplicationIdentity: Equatable {
    let pid: Int32
    let bundleID: String?
    let bundlePath: String?
    let name: String?
    let launchDate: Date?
}

struct AutomationTargetIdentity: Equatable {
    let application: AutomationApplicationIdentity
    let role: String
    let subrole: String
    let label: String
    let bounds: CGRect?
    let windowTitle: String?
    let windowBounds: CGRect?
    var structure: [AutomationStructureNode] = []
}

struct AutomationStructureNode: Equatable {
    let identity: UInt
    let role: String
    let label: String
    let bounds: CGRect?
    var labels: [String] = []

    var dictionary: [String: Any] {
        var value: [String: Any] = ["identity": String(identity), "role": role, "label": label, "labels": labels]
        if let bounds, let frame = serializedAccessibilityFrame(bounds) { value["frame"] = frame }
        return value
    }
}

struct AutomationGraphicsWindow: Equatable {
    let id: CGWindowID
    let title: String
    let frame: CGRect
}

enum AutomationTargetPolicy {
    static let pointerControlRoles: Set<String> = ["AXApplication", "AXWindow", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenu", "AXMenuItem", "AXMenuBarItem", "AXSheet", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
        "AXSecureTextField", "AXSlider", "AXTab", "AXLink", "AXRow", "AXOutline", "AXTable"]
    /// Ancestor/descendant hit candidates describe the same control. Two
    /// unrelated controls at one point require an explicit observed element.
    static func validateCoordinateCandidates(count: Int, related: (Int, Int) -> Bool) throws {
        for first in 0..<count {
            for second in (first + 1)..<count where !related(first, second) {
                throw AccessibilityActionError.ambiguousTarget
            }
        }
    }
    static func validateWindows(observed: [AutomationGraphicsWindow], current: [AutomationGraphicsWindow]) throws {
        guard !observed.isEmpty, observed.count == current.count,
              observed.allSatisfy({ current.contains($0) }) else {
            throw AccessibilityActionError.staleObservation
        }
    }

    static func validate(
        observed: AutomationTargetIdentity, current: AutomationTargetIdentity,
        sameWindow: Bool, enabled: Bool, displayFrame: CGRect
    ) throws {
        guard observed == current, sameWindow,
              let bounds = current.bounds,
              serializedAccessibilityFrame(bounds) != nil,
              bounds.width > 0, bounds.height > 0,
              bounds.intersects(displayFrame) else {
            throw AccessibilityActionError.staleObservation
        }
        guard enabled else { throw AccessibilityActionError.disabledElement }
    }

    /// One check immediately before delivery. A rejected preflight never calls
    /// the delivery closure; it cannot become a second attempt at a mutation.
    static func deliver<T>(preflight: @escaping () throws -> Void, event: () throws -> T) throws -> T {
        try TaskOwnership.commit(policyChecks: [
            .init(.resolvedTarget) { _ in try preflight() }
        ]) {
            try event()
        }
    }
}
