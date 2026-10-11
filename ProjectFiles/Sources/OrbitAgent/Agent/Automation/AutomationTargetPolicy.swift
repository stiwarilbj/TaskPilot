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
}

struct AutomationGraphicsWindow: Equatable {
    let id: CGWindowID
    let title: String
    let frame: CGRect
}

enum AutomationTargetPolicy {
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
    static func deliver<T>(preflight: () throws -> Void, event: () throws -> T) throws -> T {
        try preflight()
        return try event()
    }
}
