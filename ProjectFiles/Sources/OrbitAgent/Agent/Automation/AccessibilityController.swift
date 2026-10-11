import AppKit
import ApplicationServices
import CoreServices
import CoreGraphics
import Foundation

struct WindowPlacement {
    let element: AXUIElement
    let position: CGPoint
}

struct AccessibilitySnapshot {
    let revision: String
    let elements: [[String: Any]]
    let applications: [[String: Any]]
    let installedApplications: [[String: Any]]
    let systemContext: [String: Any]
}

func serializedAccessibilityFrame(_ frame: CGRect) -> [String: Int]? {
    // Some macOS views expose AX frames with CGFloat.greatestFiniteMagnitude
    // while their layout is still being calculated. Converting that value to
    // Int traps in Swift and used to terminate TaskPilot during a live task.
    let coordinateLimit: CGFloat = 10_000_000
    guard frame.origin.x.isFinite,
          frame.origin.y.isFinite,
          frame.width.isFinite,
          frame.height.isFinite,
          abs(frame.origin.x) <= coordinateLimit,
          abs(frame.origin.y) <= coordinateLimit,
          frame.width >= 0,
          frame.height >= 0,
          frame.width <= coordinateLimit,
          frame.height <= coordinateLimit else {
        return nil
    }
    return [
        "x": Int(frame.origin.x.rounded()),
        "y": Int(frame.origin.y.rounded()),
        "width": Int(frame.width.rounded()),
        "height": Int(frame.height.rounded())
    ]
}

struct TaskApplicationCleanupSummary: Equatable {
    let closedWindowCount: Int
    let quitApplicationNames: [String]

    static let empty = TaskApplicationCleanupSummary(
        closedWindowCount: 0,
        quitApplicationNames: []
    )
}

struct AgentScreenClearSummary: Equatable {
    let closedWindowCount: Int
    let skippedWindowCount: Int

    static let empty = AgentScreenClearSummary(
        closedWindowCount: 0,
        skippedWindowCount: 0
    )
}

enum AccessibilityActionError: LocalizedError {
    case controllerProtected
    case elementUnavailable
    case invalidAction(String)
    case operationFailed(String)
    case staleObservation
    case disabledElement
    case activationFailed
    case cancelled
    case permissionDenied
    case uncertainDelivery(String)
    case focusMismatch
    case unsupportedAction

    var code: String {
        switch self {
        case .staleObservation, .elementUnavailable: return "stale_target"
        case .disabledElement: return "disabled_target"
        case .activationFailed: return "activation_failed"
        case .cancelled: return "cancelled"
        case .permissionDenied: return "permission_denied"
        case .uncertainDelivery: return "delivery_uncertain"
        case .focusMismatch: return "focus_mismatch"
        case .unsupportedAction: return "unsupported_action"
        case .controllerProtected: return "protected_target"
        case .invalidAction: return "invalid_action"
        case .operationFailed: return "delivery_rejected"
        }
    }

    var errorDescription: String? {
        switch self {
        case .controllerProtected: return "\(TaskPilotIdentity.displayName) is protected from agent control"
        case .elementUnavailable: return "That interface element is no longer available; observe the screen again"
        case .invalidAction(let message), .operationFailed(let message): return message
        case .staleObservation: return "The target changed since this observation; observe again before acting"
        case .disabledElement: return "The requested control is disabled; wait or choose an enabled control"
        case .activationFailed: return "The target app did not become active within two seconds; observe again"
        case .cancelled: return "Task cancelled before input delivery"
        case .permissionDenied: return "Accessibility permission is unavailable; restore TaskPilot’s existing macOS permission before continuing"
        case .uncertainDelivery(let message): return message
        case .focusMismatch: return "The intended field does not have confirmed focus; observe and focus the correct field before typing"
        case .unsupportedAction: return "Accessibility press is unsupported and no verified coordinate fallback is available; observe and choose another supported method"
        }
    }
}

final class AccessibilityController {
    // MARK: - Configuration and state

    static let hidClickPressDuration: TimeInterval = 0.055
    static let hidClickReleaseSettleDuration: TimeInterval = 0.10
    static let supportedKeyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "delete": 51, "backspace": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "page_up": 116, "page_down": 121,
        "a": 0, "c": 8, "v": 9, "x": 7, "z": 6, "f": 3, "l": 37,
        "w": 13, "q": 12, "n": 45, "s": 1, "r": 15,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25
    ]

    private struct InstalledApplication {
        let name: String
        let bundleID: String
        let url: URL
        let isIOSApp: Bool
        let lastUsedDate: Date?
        let usedDatesInLast30Days: Int
        let totalUseCount: Int
    }

    private struct ElementRecord {
        let element: AXUIElement
        let revision: String
        let identity: AutomationTargetIdentity
        let window: AXUIElement?
        let depth: Int
        let supportsPress: Bool
        let wasFocused: Bool
        let observedTextValue: String?
        let observedSelection: NSRange?
        var pid: pid_t { identity.application.pid }
        var role: String { identity.role }
        var observedBounds: CGRect? { identity.bounds }
    }

    private struct TaskApplicationBaseline {
        let display: DisplayDescriptor
        let runningPIDs: Set<pid_t>
        let windowsByPID: [pid_t: [AXUIElement]]
        var agentLaunchedPIDs: Set<pid_t>
    }

    private struct LaunchPlacementResult {
        let visibleWindowCount: Int
        let candidatePIDs: [pid_t]
    }

    private let lock = NSLock()
    private let agentCursor: AgentCursorOverlayController?
    private var elementMap: [String: ElementRecord] = [:]
    private var observationRevision = ""
    private var observedGraphicsWindows: [pid_t: [AutomationGraphicsWindow]] = [:]
    private var observedApplications: [pid_t: AutomationApplicationIdentity] = [:]
    private var inputGeneration = 0
    private var inputCancelled = false
    private var restoreWorkItem: DispatchWorkItem?
    private var previousInputApplication: NSRunningApplication?
    private var inputTargetPID: pid_t?
    private var manualTargetPID: pid_t?
    private var taskApplicationBaseline: TaskApplicationBaseline?
    private var taskDisplayOverrideID: CGDirectDisplayID?
    private let controllerPID = getpid()
    private let maxElements = 640
    private let passiveLaunchWait: Duration = .seconds(4)
    private let activatedLaunchWait: Duration = .seconds(16)
    private lazy var installedApplicationEntries = discoverInstalledApplications()

    init(agentCursor: AgentCursorOverlayController? = nil) {
        self.agentCursor = agentCursor
    }

    func hideAgentCursor() {
        agentCursor?.hide()
    }

    /// Records the apps and windows that existed before a task. Cleanup can
    /// then preserve every pre-existing item, close only new windows on the
    /// assigned display, and quit only apps launched through TaskPilot's own
    /// `launch_app` action.
    // MARK: - Task resource tracking

    func beginTaskResourceTracking(on display: DisplayDescriptor) {
        resetInputCancellation()
        let applications = controllableRunningApplications()
        var windowsByPID: [pid_t: [AXUIElement]] = [:]
        for application in applications {
            windowsByPID[application.processIdentifier] = windows(
                of: application.processIdentifier
            )
        }

        lock.lock()
        manualTargetPID = nil
        taskDisplayOverrideID = nil
        taskApplicationBaseline = TaskApplicationBaseline(
            display: display,
            runningPIDs: Set(applications.map(\.processIdentifier)),
            windowsByPID: windowsByPID,
            agentLaunchedPIDs: []
        )
        lock.unlock()
    }

    /// Ends task tracking. When cleanup is enabled, only new windows currently
    /// touching the assigned task display are closed, and only applications
    /// explicitly launched by the agent are asked to quit. `terminate()` is
    /// deliberately graceful so apps can still present save confirmation.
    @discardableResult
    func finishTaskResourceTracking(
        closeOpenedResources: Bool
    ) -> TaskApplicationCleanupSummary {
        cancelInputDelivery()
        lock.lock()
        let baseline = taskApplicationBaseline
        taskApplicationBaseline = nil
        manualTargetPID = nil
        taskDisplayOverrideID = nil
        lock.unlock()

        guard closeOpenedResources, let baseline else { return .empty }

        let currentApplications = controllableRunningApplications()
        let currentPIDs = Set(currentApplications.map(\.processIdentifier))
        let launchedPIDs = Self.cleanupApplicationPIDs(
            baselinePIDs: baseline.runningPIDs,
            agentLaunchedPIDs: baseline.agentLaunchedPIDs,
            currentPIDs: currentPIDs,
            controllerPID: controllerPID
        )

        var quitNames: [String] = []
        for application in currentApplications
            where launchedPIDs.contains(application.processIdentifier) {
            guard !application.isTerminated,
                  application.bundleIdentifier != Bundle.main.bundleIdentifier else { continue }
            if application.terminate() {
                quitNames.append(application.localizedName ?? "Application")
            }
        }

        var closedWindowCount = 0
        for application in currentApplications {
            let pid = application.processIdentifier
            guard baseline.runningPIDs.contains(pid),
                  !launchedPIDs.contains(pid) else { continue }
            let originalWindows = baseline.windowsByPID[pid] ?? []
            for window in windows(of: pid) {
                guard frame(of: window)?.intersects(baseline.display.frame) == true,
                      !originalWindows.contains(where: { CFEqual($0, window) }),
                      let closeButton = attribute(window, kAXCloseButtonAttribute),
                      CFGetTypeID(closeButton) == AXUIElementGetTypeID(),
                      actionNames(closeButton as! AXUIElement).contains(kAXPressAction as String)
                else { continue }
                if AXUIElementPerformAction(
                    closeButton as! AXUIElement,
                    kAXPressAction as CFString
                ) == .success {
                    closedWindowCount += 1
                }
            }
        }

        return TaskApplicationCleanupSummary(
            closedWindowCount: closedWindowCount,
            quitApplicationNames: quitNames.sorted()
        )
    }

    static func cleanupApplicationPIDs(
        baselinePIDs: Set<pid_t>,
        agentLaunchedPIDs: Set<pid_t>,
        currentPIDs: Set<pid_t>,
        controllerPID: pid_t
    ) -> Set<pid_t> {
        agentLaunchedPIDs
            .subtracting(baselinePIDs)
            .intersection(currentPIDs)
            .subtracting([controllerPID])
    }

    /// Some iPhone/iPad, Catalyst, game, and sandboxed apps refuse to move their
    /// windows to a secondary display. Once a launched window is proven visible
    /// on another display, the native bridge follows it for the rest of that
    /// task instead of continuing to capture and validate the now-wrong screen.
    func resolvedTaskDisplay(
        preferred: DisplayDescriptor,
        availableDisplays: [DisplayDescriptor]
    ) -> DisplayDescriptor {
        lock.lock()
        let overrideID = taskDisplayOverrideID
        lock.unlock()
        guard let overrideID else { return preferred }
        guard let display = availableDisplays.first(where: { $0.id == overrideID }) else {
            lock.lock()
            taskDisplayOverrideID = nil
            lock.unlock()
            return preferred
        }
        return display
    }

    static func displayContainingLargestVisibleArea(
        windowFrames: [CGRect],
        displays: [DisplayDescriptor]
    ) -> DisplayDescriptor? {
        displays.compactMap { display -> (DisplayDescriptor, CGFloat)? in
            let visibleArea = windowFrames.reduce(CGFloat.zero) { partial, frame in
                let intersection = frame.intersection(display.frame)
                guard !intersection.isNull, !intersection.isInfinite else { return partial }
                return partial + max(0, intersection.width) * max(0, intersection.height)
            }
            return visibleArea > 0 ? (display, visibleArea) : nil
        }
        .max(by: { $0.1 < $1.1 })?
        .0
    }

    // MARK: - Screen observation and actions

    func snapshot(on display: DisplayDescriptor) -> AccessibilitySnapshot {
        var newMap: [String: ElementRecord] = [:]
        var elementRows: [[String: Any]] = []
        var applicationRows: [[String: Any]] = []
        var nextID = 1
        let revision = UUID().uuidString
        var observedGraphics: [pid_t: [AutomationGraphicsWindow]] = [:]
        var observedApps: [pid_t: AutomationApplicationIdentity] = [:]

        let apps = orderedApplicationsForSnapshot(on: display)


        for app in apps {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            let windows = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let visibleWindows = windows.filter { window in
                guard let frame = frame(of: window) else { return false }
                return frame.intersects(display.frame)
            }
            let graphics = graphicsWindows(of: pid).filter { $0.frame.intersects(display.frame) }
            let cgFrames = graphics.map(\.frame)
            guard Self.hasObservableWindow(accessibilityCount: visibleWindows.count, graphicsCount: cgFrames.count) else { continue }
            observedGraphics[pid] = graphics
            let appIdentity = applicationIdentity(app)
            observedApps[pid] = appIdentity

            applicationRows.append([
                "name": app.localizedName ?? "Unknown app",
                "bundle_id": app.bundleIdentifier ?? "",
                "pid": Int(pid),
                "window_count": max(visibleWindows.count, cgFrames.count),
                "accessibility_available": !visibleWindows.isEmpty,
                "active": app.isActive,
                "topmost_on_agent_screen": applicationRows.isEmpty,
                "windows": visibleWindows.compactMap { window -> [String: Any]? in
                    guard let windowFrame = frame(of: window) else { return nil }
                    return [
                        "title": stringAttribute(window, kAXTitleAttribute) ?? "",
                        "frame": [
                            "x": Int(windowFrame.minX.rounded()),
                            "y": Int(windowFrame.minY.rounded()),
                            "width": Int(windowFrame.width.rounded()),
                            "height": Int(windowFrame.height.rounded())
                        ]
                    ]
                } + (visibleWindows.isEmpty ? cgFrames.compactMap { rectangle -> [String: Any]? in
                    guard let serialized = serializedAccessibilityFrame(rectangle) else { return nil }
                    return ["frame": serialized, "source": "core_graphics"]
                } : [])
            ])

            // Menu bars and focused fields are not necessarily descendants of
            // AXWindows. Collect them first so large web trees cannot hide them.
            var roots: [AXUIElement] = []
            let focusedElement = accessibilityElement(appElement, kAXFocusedUIElementAttribute)
            if let focused = focusedElement,
               ["AXTextField", "AXTextArea", "AXSecureTextField"].contains(stringAttribute(focused, kAXRoleAttribute) ?? ""),
               frame(of: focused)?.intersects(display.frame) == true { roots.append(focused) }
            if let menu = accessibilityElement(appElement, kAXMenuBarAttribute) { roots.append(menu) }
            roots += (attribute(appElement, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter {
                ["AXMenu", "AXSheet"].contains(stringAttribute($0, kAXRoleAttribute) ?? "")
            }
            for root in roots {
                walk(element: root, pid: pid, appName: app.localizedName ?? "Unknown app",
                     application: appIdentity,
                     focusedElement: focusedElement,
                     depth: 0, nextID: &nextID, map: &newMap, rows: &elementRows,
                     revision: revision, parentID: nil, ownerWindow: nil)
            }

            for window in visibleWindows {
                walk(
                    element: window,
                    pid: pid,
                    appName: app.localizedName ?? "Unknown app",
                    application: appIdentity,
                    focusedElement: focusedElement,
                    depth: 0,
                    nextID: &nextID,
                    map: &newMap,
                    rows: &elementRows,
                    revision: revision, parentID: nil, ownerWindow: window
                )
                if elementRows.count >= maxElements { break }
            }
        }

        lock.lock()
        elementMap = newMap
        observationRevision = revision
        observedGraphicsWindows = observedGraphics
        observedApplications = observedApps
        lock.unlock()
        return AccessibilitySnapshot(
            revision: revision,
            elements: elementRows,
            applications: applicationRows,
            installedApplications: installedApplicationEntries.map { entry in
                var row: [String: Any] = [
                    "name": entry.name,
                    "bundle_id": entry.bundleID,
                    "platform": entry.isIOSApp ? "iPhone/iPad app on Mac" : "macOS",
                    "usage_date_samples_last_30_days": entry.usedDatesInLast30Days
                ]
                if let lastUsedDate = entry.lastUsedDate {
                    row["last_used"] = ISO8601DateFormatter().string(from: lastUsedDate)
                }
                return row
            },
            systemContext: systemContext()
        )
    }

    private func walk(
        element: AXUIElement,
        pid: pid_t,
        appName: String,
        application: AutomationApplicationIdentity,
        focusedElement: AXUIElement?,
        depth: Int,
        nextID: inout Int,
        map: inout [String: ElementRecord],
        rows: inout [[String: Any]],
        revision: String,
        parentID: String?,
        ownerWindow: AXUIElement?
    ) {
        guard depth <= 14, rows.count < maxElements else { return }
        let alreadyVisited = map.values.contains(where: { CFEqual($0.element, element) })
        let id = "\(revision):e\(nextID)"
        nextID += 1

        let role = stringAttribute(element, kAXRoleAttribute) ?? "unknown"
        // Closed menu trees expose commands with zero bounds. They consume the
        // observation budget and can be mistaken for currently usable controls.
        if role == "AXMenu" {
            guard let bounds = frame(of: element), bounds.width > 0, bounds.height > 0 else { return }
        }
        let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
        let title = elementTitle(element)
        let bounds = frame(of: element)
        let secure = AutomationTextEntryPolicy.isSecure(role: role, subrole: subrole)
        let value = secure ? nil : attribute(element, kAXValueAttribute)
        let rawValue = secure ? "[secure]" : printableValue(value)
        let focused = boolAttribute(element, kAXFocusedAttribute) == true
            || focusedElement.map { CFEqual($0, element) } == true
        let actions = actionNames(element)
        let selection = secure || !AutomationTextEntryPolicy.inputRoles.contains(role) ? nil : selectedTextRange(element)
        let window = role == "AXWindow" ? element
            : (ownerWindow ?? accessibilityElement(element, kAXWindowAttribute))
        // Use the same immutable values in the private record and the rows
        // sent for planning, rather than fetching two different layouts.
        map[id] = ElementRecord(element: element, revision: revision,
            identity: AutomationTargetIdentity(application: application, role: role, subrole: subrole,
                label: title, bounds: bounds, windowTitle: window.map { elementTitle($0) },
                windowBounds: window.flatMap { frame(of: $0) }),
            window: window, depth: depth, supportsPress: actions.contains("AXPress"),
            wasFocused: focused, observedTextValue: AutomationTextEntryPolicy.inputRoles.contains(role) ? value as? String : nil,
            observedSelection: selection)
        var row: [String: Any] = [
            "id": id,
            "pid": Int(pid),
            "app": appName,
            "role": role,
            "depth": depth,
            "enabled": boolAttribute(element, kAXEnabledAttribute) ?? true
        ]
        row["focused"] = focused
        if let title = map[id]?.identity.windowTitle { row["window_title"] = clipped(title) }
        if let selection { row["selection_range"] = ["location": selection.location, "length": selection.length] }
        if let parentID { row["parent_id"] = parentID }
        if !subrole.isEmpty { row["subrole"] = subrole }
        if !title.isEmpty { row["title"] = clipped(title) }
        if !rawValue.isEmpty { row["value"] = clipped(rawValue) }
        if AutomationTextEntryPolicy.inputRoles.contains(role) {
            row["value_complete"] = !secure && value is String && rawValue == clipped(rawValue)
        }
        let sortDirection = printableValue(
            attribute(element, kAXSortDirectionAttribute)
        )
        if !sortDirection.isEmpty { row["sort_direction"] = clipped(sortDirection) }
        if !actions.isEmpty { row["actions"] = actions }
        if let frame = bounds,
           let serializedFrame = serializedAccessibilityFrame(frame) {
            row["frame"] = serializedFrame
        }
        rows.append(row)
        // A focused-field alias still appears in its window hierarchy, but
        // never traverse the same subtree twice or follow Accessibility cycles.
        if alreadyVisited { return }

        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for child in children.prefix(160) {
            walk(
                element: child,
                pid: pid,
                appName: appName,
                application: application,
                focusedElement: focusedElement,
                depth: depth + 1,
                nextID: &nextID,
                map: &map,
                rows: &rows, revision: revision, parentID: id, ownerWindow: ownerWindow
            )
            if rows.count >= maxElements { break }
        }
    }

    static func hasObservableWindow(accessibilityCount: Int, graphicsCount: Int) -> Bool {
        accessibilityCount > 0 || graphicsCount > 0
    }

    func validateObservation(_ revision: String?) throws {
        lock.lock()
        let current = observationRevision
        lock.unlock()
        guard let revision, !revision.isEmpty, revision == current else {
            throw AccessibilityActionError.staleObservation
        }
    }

    func resetInputCancellation() {
        lock.lock()
        inputCancelled = false
        inputGeneration += 1
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
        lock.unlock()
    }

    func cancelInputDelivery() {
        lock.lock()
        inputCancelled = true
        inputGeneration += 1
        restoreWorkItem?.cancel()
        let previous = previousInputApplication
        let target = inputTargetPID
        let generation = inputGeneration
        previousInputApplication = nil
        inputTargetPID = nil
        lock.unlock()
        if let previous, let target, NSWorkspace.shared.frontmostApplication?.processIdentifier == target {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lock.withLock({ self.inputGeneration == generation }),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target else { return }
                _ = previous.activate(options: [.activateAllWindows])
            }
        }
    }

    private func inputIsCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inputCancelled
    }

    private func prepareInputTarget(_ pid: pid_t) {
        lock.lock()
        inputGeneration += 1
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
        if let current = NSWorkspace.shared.frontmostApplication, current.processIdentifier != pid,
           current.processIdentifier != inputTargetPID {
            previousInputApplication = current
        }
        inputTargetPID = pid
        lock.unlock()
    }

    private func beginVerifiedInput(to pid: pid_t) async throws {
        prepareInputTarget(pid)
        guard let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated else {
            throw AccessibilityActionError.elementUnavailable
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            let allowed = await MainActor.run { target.activate(options: [.activateAllWindows]) }
            guard allowed else { throw AccessibilityActionError.activationFailed }
        }
        try await AutomationInputPolicy.waitUntilReady(
            ready: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid },
            cancelled: { self.inputIsCancelled() }
        )
    }

    private func hasOpenMenu(_ pid: pid_t) -> Bool {
        let root = AXUIElementCreateApplication(pid)
        var budget = 160
        func containsMenu(_ element: AXUIElement, _ depth: Int) -> Bool {
            guard depth < 8, budget > 0 else { return false }
            budget -= 1
            if stringAttribute(element, kAXRoleAttribute) == "AXMenu",
               let rectangle = frame(of: element), rectangle.width > 0, rectangle.height > 0 { return true }
            return (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).contains {
                containsMenu($0, depth + 1)
            }
        }
        return containsMenu(root, 0)
    }

    private func scheduleInputRestoration(_ pid: pid_t) {
        lock.lock()
        let generation = inputGeneration
        let previous = previousInputApplication
        lock.unlock()
        guard let previous else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let currentGeneration = self.inputGeneration
            self.lock.unlock()
            guard !previous.isTerminated, AutomationInputPolicy.shouldRestore(
                scheduledGeneration: generation, currentGeneration: currentGeneration,
                targetPID: pid, currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                previousPID: previous.processIdentifier
            ) else { return }
            if self.hasOpenMenu(pid) {
                self.scheduleInputRestoration(pid)
                return
            }
            _ = previous.activate(options: [.activateAllWindows])
            self.lock.lock()
            if generation == self.inputGeneration {
                self.previousInputApplication = nil
                self.inputTargetPID = nil
            }
            self.lock.unlock()
        }
        lock.lock()
        restoreWorkItem?.cancel()
        restoreWorkItem = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func actionState(_ pid: pid_t) -> [String] {
        var states: [String] = ["menu_open|\(hasOpenMenu(pid))"]
        var budget = 640
        func collect(_ element: AXUIElement, depth: Int) {
            guard depth < 14, budget > 0 else { return }
            budget -= 1
            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            if !AutomationTextEntryPolicy.isSecure(role: role, subrole: stringAttribute(element, kAXSubroleAttribute) ?? "") {
                states.append("\(role)|\(stringAttribute(element, kAXTitleAttribute) ?? "")|\(printableValue(attribute(element, kAXValueAttribute)))|\(boolAttribute(element, kAXSelectedAttribute) ?? false)")
            }
            for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(160) {
                collect(child, depth: depth + 1)
            }
        }
        let root = AXUIElementCreateApplication(pid)
        for window in windows(of: pid) { collect(window, depth: 0) }
        if let menu = accessibilityElement(root, kAXMenuBarAttribute) { collect(menu, depth: 0) }
        if let focused = accessibilityElement(root, kAXFocusedUIElementAttribute) {
            states.append("focused|\(stringAttribute(focused, kAXRoleAttribute) ?? "")|\(stringAttribute(focused, kAXTitleAttribute) ?? "")")
        }
        return states
    }

    func performStructured(action: [String: Any], on display: DisplayDescriptor, privateInput: Bool = false) async throws -> [String: Any] {
        guard !inputIsCancelled() else { throw AccessibilityActionError.cancelled }
        let planningRevision = lock.withLock { observationRevision }
        let type = action["type"] as? String ?? ""
        if ["launch_app", "open_route", "navigate_browser"].contains(type) {
            let message = try await perform(action: action, on: display)
            return ["message": message, "delivery_method": "workspace", "outcome": type == "launch_app" ? "verified" : "delivered_unconfirmed", "verification_scope": "window_visible"]
        }
        guard AXIsProcessTrusted() else { throw AccessibilityActionError.permissionDenied }
        let record = action["element_id"] == nil ? nil : try self.record(for: action)
        let pid = try record?.pid ?? actionPID(action, on: display,
            fallbackPoint: (action["x"] != nil && action["y"] != nil) ? point(from: action, display: display) : nil)
        try ensureAllowedOnDisplay(pid, display: display)
        try await beginVerifiedInput(to: pid)
        defer { scheduleInputRestoration(pid) }
        if let record { try validateRecord(record, action: action, on: display) }
        else if ["click", "double_click", "scroll"].contains(type) {
            try validateCoordinateWindows(pid, on: display)
        }
        if ["click", "double_click", "scroll"].contains(type), let record,
           let rectangle = frame(of: record.element) {
            let targetPoint = CGPoint(x: rectangle.midX, y: rectangle.midY)
            if !pointerTargetIsVisible(pid, at: targetPoint, display: display) {
                if let window = record.window { _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
                try await AutomationInputPolicy.waitUntilReady(
                    ready: { self.pointerTargetIsVisible(pid, at: targetPoint, display: display) && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid },
                    cancelled: { self.inputIsCancelled() })
            }
        }
        try validateObservation(planningRevision)
        if ["set_value", "type_text"].contains(type) {
            let target = try record ?? observedFocusedInput(pid: pid)
            return try await performTextEntry(action: action, record: target, on: display, privateInput: privateInput).dictionary(pid: pid)
        }
        let before = actionState(pid)
        let message = try await perform(action: action, on: display, planningRevision: planningRevision)
        let method = ["focus", "set_value", "press"].contains(type) && !message.hasPrefix("Clicked")
            ? "accessibility" : (requiresHIDFallback(pid) ? "hid" : (["click", "double_click", "scroll"].contains(type) ? "session_event" : "process_event"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var verified = false
        repeat {
            guard !inputIsCancelled() else { throw AccessibilityActionError.cancelled }
            try Task.checkCancellation()
            if type == "focus", let record {
                verified = intendedElementHasFocus(record)
            } else { verified = actionState(pid) != before }
            if verified { break }
            try await Task.sleep(for: .milliseconds(80))
        } while ContinuousClock.now < deadline
        return ["message": verified ? "\(message); observed the action effect" : "\(message); delivery acknowledged, effect not confirmed",
                "delivery_method": method, "outcome": verified ? "verified" : "delivered_unconfirmed",
                "verification_scope": "action_effect", "pid": Int(pid)]
    }

    func perform(action: [String: Any], on display: DisplayDescriptor, planningRevision: String? = nil) async throws -> String {
        guard let type = action["type"] as? String else {
            throw AccessibilityActionError.invalidAction("The action has no type")
        }
        // Observation, planning, typing, and app launch are idle states for the
        // visual pointer. A pointer action below will briefly reveal it again.
        agentCursor?.hide()
        switch type {
        case "press":
            let record = try record(for: action)
            try ensureAllowedOnDisplay(record.pid, display: display)
            rememberManualTarget(record.pid)
            if let elementFrame = frame(of: record.element) {
                let pointerPoint = CGPoint(x: elementFrame.midX, y: elementFrame.midY)
                if display.frame.insetBy(dx: -0.5, dy: -0.5).contains(pointerPoint),
                   topmostWindowOwnerPID(at: pointerPoint) == record.pid {
                    agentCursor?.move(
                        to: pointerPoint,
                        on: display,
                        clicking: true
                    )
                }
            }
            let method = try AutomationPressPolicy.deliver(preflight: {
                try self.validateRecord(record, action: action, on: display)
            }, press: {
                AXUIElementPerformAction(record.element, kAXPressAction as CFString)
            }, fallback: {
                // Some macOS apps advertise a semantic control but reject
                // AXPress. Fall back to a targeted click at that element's
                // center without moving the user's physical pointer.
                guard let elementFrame = frame(of: record.element),
                      elementFrame.width > 0,
                      elementFrame.height > 0,
                      elementFrame.intersects(display.frame) else {
                    throw AccessibilityActionError.unsupportedAction
                }
                try postClick(
                    to: record.pid,
                    point: CGPoint(x: elementFrame.midX, y: elementFrame.midY),
                    double: false,
                    on: display,
                    preflight: {
                        try self.validateRecord(record, action: action, on: display)
                        try self.validatePointerHit(record, at: CGPoint(x: elementFrame.midX, y: elementFrame.midY))
                    }
                )
            })
            return method == "coordinate" ? "Clicked the requested control" : "Pressed the requested control"

        case "focus":
            let record = try record(for: action)
            try ensureAllowedOnDisplay(record.pid, display: display)
            rememberManualTarget(record.pid)
            try await ensureElementFocus(record, action: action, on: display)
            return "Focused the requested control"

        case "set_value", "type_text":
            let target = try action["element_id"] == nil
                ? observedFocusedInput(pid: actionPID(action, on: display)) : record(for: action)
            return try await performTextEntry(action: action, record: target, on: display).message

        case "click", "double_click":
            let record = action["element_id"] == nil ? nil : try self.record(for: action)
            let point: CGPoint
            let pid: pid_t
            if let record {
                try validateRecord(record, action: action, on: display)
                guard let rectangle = frame(of: record.element), rectangle.width > 0, rectangle.height > 0 else {
                    throw AccessibilityActionError.elementUnavailable
                }
                point = CGPoint(x: rectangle.midX, y: rectangle.midY)
                pid = record.pid
            } else {
                point = try self.point(from: action, display: display)
                pid = try actionPID(action, on: display, fallbackPoint: point)
            }
            try ensureAllowedOnDisplay(pid, display: display)
            rememberManualTarget(pid)
            // Bind coordinates to the control in the planning observation,
            // before activation or z-order recovery can change its position.
            let coordinateRecord = record == nil ? observedControl(at: point, pid: pid) : nil
            try postClick(
                to: pid,
                point: point,
                double: type == "double_click",
                on: display,
                preflight: {
                    if let planningRevision { try self.validateObservation(planningRevision) }
                    if let record {
                        try self.validateRecord(record, action: action, on: display)
                        try self.validatePointerHit(record, at: point)
                    } else {
                        try self.validateCoordinateWindows(pid, on: display)
                        if let coordinateRecord {
                            try self.validateRecord(coordinateRecord, action: action, on: display)
                            try self.validatePointerHit(coordinateRecord, at: point)
                        }
                    }
                }
            )
            return type == "double_click" ? "Double-clicked" : "Clicked"

        case "key":
            let pid = try actionPID(action, on: display)
            try ensureAllowedOnDisplay(pid, display: display)
            rememberManualTarget(pid)
            guard let key = action["key"] as? String else {
                throw AccessibilityActionError.invalidAction("key requires a key name")
            }
            let modifiers = action["modifiers"] as? [String] ?? []
            try postKey(key, modifiers: modifiers, to: pid)
            return "Sent the \(key) key"

        case "scroll":
            let record = action["element_id"] == nil ? nil : try self.record(for: action)
            let pid = try record?.pid ?? actionPID(action, on: display)
            let point: CGPoint
            if let record {
                try validateRecord(record, action: action, on: display)
                guard let rectangle = frame(of: record.element) else { throw AccessibilityActionError.elementUnavailable }
                point = CGPoint(x: rectangle.midX, y: rectangle.midY)
            } else if action["x"] != nil, action["y"] != nil {
                point = try self.point(from: action, display: display)
            } else {
                let scrollFrames = lock.withLock {
                    elementMap.values.filter { $0.pid == pid && $0.role == "AXScrollArea" }
                        .compactMap { frame(of: $0.element) }.filter { $0.intersects(display.frame) }
                        .sorted { $0.width * $0.height > $1.width * $1.height }
                }
                guard let rectangle = scrollFrames.first ?? targetWindowFrames(of: pid).first(where: { $0.intersects(display.frame) }) else {
                    throw AccessibilityActionError.elementUnavailable
                }
                point = CGPoint(x: rectangle.midX, y: rectangle.midY)
            }
            try ensureAllowedOnDisplay(pid, display: display)
            rememberManualTarget(pid)
            let deltaX = intValue(action["delta_x"]) ?? 0
            let deltaY = intValue(action["delta_y"]) ?? 0
            let retargeted = try postScroll(
                to: pid,
                point: point,
                deltaX: deltaX,
                deltaY: deltaY,
                on: display
            )
            return retargeted
                ? "Scrolled the target app after safely retargeting inside its visible window"
                : "Scrolled the target app"

        case "launch_app":
            return try await launchApp(action, on: display)

        case "open_route":
            return try await openRoute(action, on: display)

        case "navigate_browser":
            return try await navigateBrowser(action, on: display)

        default:
            throw AccessibilityActionError.invalidAction("Unsupported action: \(type)")
        }
    }

    // MARK: - Window and display management

    func captureWindowPlacements() -> [WindowPlacement] {
        controllableRunningApplications().flatMap { app in
            windows(of: app.processIdentifier).compactMap { window in
                pointAttribute(window, kAXPositionAttribute).map { WindowPlacement(element: window, position: $0) }
            }
        }
    }

    func moveWindowsForTakeover(from source: DisplayDescriptor) -> [WindowPlacement] {
        guard let main = DisplayService().mainDisplay() else { return [] }
        return moveWindows(from: source, to: main)
    }

    func moveWindows(from source: DisplayDescriptor, to destination: DisplayDescriptor) -> [WindowPlacement] {
        var placements: [WindowPlacement] = []
        var cascade: CGFloat = 0
        var movedApplications: [pid_t: NSRunningApplication] = [:]

        for app in controllableRunningApplications() {
            for window in windows(of: app.processIdentifier) {
                guard let oldPosition = pointAttribute(window, kAXPositionAttribute),
                      let oldFrame = frame(of: window),
                      Self.windowBelongs(oldFrame, to: source) else { continue }
                var newPosition = CGPoint(
                    x: destination.frame.minX + 50 + cascade,
                    y: destination.frame.minY + 80 + cascade
                )
                guard let value = AXValueCreate(.cgPoint, &newPosition),
                      AXUIElementSetAttributeValue(
                        window,
                        kAXPositionAttribute as CFString,
                        value
                      ) == .success else { continue }

                placements.append(WindowPlacement(element: window, position: oldPosition))
                movedApplications[app.processIdentifier] = app
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                cascade = min(cascade + 24, 144)
            }
        }

        // Activating every affected app makes the transferred windows visible
        // immediately. The former implementation activated only the first app,
        // which left the other successfully moved windows behind the controller.
        for application in movedApplications.values.sorted(by: {
            ($0.localizedName ?? "") < ($1.localizedName ?? "")
        }) {
            application.activate(options: [.activateAllWindows])
        }
        return placements
    }

    /// Closes ordinary app windows whose center is on the dedicated agent
    /// display. Main-screen windows and TaskPilot's own controller/viewer windows
    /// are never included. Apps with unsaved work may still show their normal
    /// confirmation sheet because this presses the native close button rather
    /// than force-quitting the process.
    func clearWindows(on display: DisplayDescriptor) -> AgentScreenClearSummary {
        var closedWindowCount = 0
        var skippedWindowCount = 0

        for application in controllableRunningApplications() {
            for window in windows(of: application.processIdentifier) {
                guard let windowFrame = frame(of: window),
                      Self.windowBelongs(windowFrame, to: display) else { continue }
                guard let closeButton = attribute(window, kAXCloseButtonAttribute),
                      CFGetTypeID(closeButton) == AXUIElementGetTypeID(),
                      actionNames(closeButton as! AXUIElement).contains(
                        kAXPressAction as String
                      ) else {
                    skippedWindowCount += 1
                    continue
                }
                if AXUIElementPerformAction(
                    closeButton as! AXUIElement,
                    kAXPressAction as CFString
                ) == .success {
                    closedWindowCount += 1
                } else {
                    skippedWindowCount += 1
                }
            }
        }

        return AgentScreenClearSummary(
            closedWindowCount: closedWindowCount,
            skippedWindowCount: skippedWindowCount
        )
    }

    /// Uses the window center instead of any overlap so a main-screen window
    /// that extends a few pixels onto the agent display is never moved or
    /// closed by the Agent Screen controls.
    static func windowBelongs(_ windowFrame: CGRect, to display: DisplayDescriptor) -> Bool {
        guard !windowFrame.isNull,
              !windowFrame.isEmpty,
              windowFrame.origin.x.isFinite,
              windowFrame.origin.y.isFinite,
              windowFrame.width.isFinite,
              windowFrame.height.isFinite else { return false }
        return display.frame.contains(CGPoint(x: windowFrame.midX, y: windowFrame.midY))
    }

    func restoreWindows(_ placements: [WindowPlacement]) {
        for placement in placements {
            var position = placement.position
            guard let value = AXValueCreate(.cgPoint, &position) else { continue }
            _ = AXUIElementSetAttributeValue(
                placement.element,
                kAXPositionAttribute as CFString,
                value
            )
        }
    }

    /// Sends input from the local live viewer to the app visible at the same
    /// point on the real display. TaskPilot itself is skipped even when its viewer
    /// window overlaps that point on the main screen.
    func performViewerInteraction(
        _ interaction: AgentScreenInteraction,
        on display: DisplayDescriptor
    ) throws -> String {
        switch interaction {
        case .click(let normalizedPoint, let count):
            let point = displayPoint(from: normalizedPoint, display: display)
            let pid = try targetPID(at: point)
            rememberManualTarget(pid)
            try postClick(to: pid, point: point, double: count > 1, on: display)
            return count > 1 ? "Double-clicked from the live viewer" : "Clicked from the live viewer"

        case .drag(let normalizedStart, let normalizedEnd):
            let start = displayPoint(from: normalizedStart, display: display)
            let end = displayPoint(from: normalizedEnd, display: display)
            let pid = try targetPID(at: start)
            rememberManualTarget(pid)
            try postDrag(to: pid, from: start, to: end, on: display)
            return "Dragged from the live viewer"

        case .scroll(let normalizedPoint, let deltaX, let deltaY):
            let point = displayPoint(from: normalizedPoint, display: display)
            let pid = try targetPID(at: point)
            rememberManualTarget(pid)
            try postScroll(to: pid, point: point, deltaX: deltaX, deltaY: deltaY, on: display)
            return "Scrolled from the live viewer"

        case .key(let keyCode, let characters, let modifiers):
            lock.lock()
            let pid = manualTargetPID
            lock.unlock()
            guard let pid else {
                throw AccessibilityActionError.operationFailed(
                    "Click an app in the live viewer before typing"
                )
            }
            try ensureAllowed(pid)
            let commandLike = modifiers.intersection([.command, .control, .function]).isEmpty == false
            if !commandLike, let characters, !characters.isEmpty {
                try postUnicode(characters, to: pid)
            } else {
                try postRawKey(keyCode, modifiers: modifiers, to: pid)
            }
            return "Typed into the selected live-viewer app"
        }
    }

    private func rememberManualTarget(_ pid: pid_t) {
        lock.lock()
        manualTargetPID = pid
        lock.unlock()
    }

    private func displayPoint(from normalized: CGPoint, display: DisplayDescriptor) -> CGPoint {
        CGPoint(
            x: display.frame.minX + display.frame.width * min(1, max(0, normalized.x)),
            y: display.frame.minY + display.frame.height * min(1, max(0, normalized.y))
        )
    }

    private func targetPID(at point: CGPoint) throws -> pid_t {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw AccessibilityActionError.operationFailed("Could not inspect windows at that point")
        }
        for row in rows {
            guard let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = row[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let boundsDictionary = row[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.contains(point) else { continue }
            let pid = pid_t(owner.intValue)
            guard pid != controllerPID else { continue }
            try ensureAllowed(pid)
            return pid
        }
        throw AccessibilityActionError.operationFailed(
            "No controllable app is visible at that point"
        )
    }

    // MARK: - App and browser routing

    private func openRoute(
        _ action: [String: Any],
        on display: DisplayDescriptor
    ) async throws -> String {
        guard let routeID = action["route_id"] as? String,
              let route = Self.systemTaskRoutes.first(where: {
                  $0["route_id"] == routeID
              }),
              let appName = route["app"],
              let bundleID = route["bundle_id"] else {
            throw AccessibilityActionError.invalidAction(
                "open_route requires a predefined system route"
            )
        }

        let launchAction: [String: Any] = [
            "type": "launch_app",
            "app": appName,
            "bundle_id": bundleID
        ]
        _ = try await launchApp(launchAction, on: display)

        if let settingsURLText = route["settings_url"] {
            guard let settingsURL = URL(string: settingsURLText),
                  NSWorkspace.shared.open(settingsURL) else {
                throw AccessibilityActionError.operationFailed(
                    "Could not open the predefined \(route["destination"] ?? appName) route"
                )
            }
            // System Settings loads extension-backed panes asynchronously.
            // Give the selected pane enough time to replace the previous one
            // before the next screenshot is captured and reasoned over.
            try? await Task.sleep(for: .milliseconds(900))
        }

        // A settings deep link can replace or resize the window *after*
        // launchApp has already placed it. Re-resolve the app identity and
        // verify its final window on the assigned display so the next
        // screenshot and pointer validation use the same geometry/z-order.
        // This also covers ordinary routes whose app was already running
        // behind another window when the request began.
        try await stabilizeRoutedApplication(
            bundleID: bundleID,
            name: appName,
            on: display
        )

        let destination = route["destination"] ?? appName
        return "Opened \(destination) in \(appName)"
    }

    private func navigateBrowser(
        _ action: [String: Any],
        on display: DisplayDescriptor
    ) async throws -> String {
        let navigationText = try Self.browserNavigationText(from: action)
        let rawURL = (action["url"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let description: String
        if let rawURL, !rawURL.isEmpty {
            let url = URL(string: navigationText)!
            description = url.host ?? "the requested website"
        } else {
            description = "web results for \(navigationText)"
        }

        let requestedBrowser = (action["browser"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let browserName = requestedBrowser?.isEmpty == false ? requestedBrowser! : "Safari"
        var launchAction: [String: Any] = [
            "type": "launch_app",
            "app": browserName
        ]
        if browserName.caseInsensitiveCompare("Safari") == .orderedSame {
            launchAction["bundle_id"] = "com.apple.Safari"
        }
        _ = try await launchApp(launchAction, on: display)

        let browserPID = lock.withLock { manualTargetPID }
        guard let browserPID else {
            throw AccessibilityActionError.operationFailed(
                "The browser opened, but \(TaskPilotIdentity.displayName) could not identify its visible window"
            )
        }
        try ensureAllowedOnDisplay(browserPID, display: display)
        rememberManualTarget(browserPID)
        try await beginVerifiedInput(to: browserPID)
        defer { scheduleInputRestoration(browserPID) }
        try postKey("l", modifiers: ["command"], to: browserPID)
        var addressField: ElementRecord?
        try await AutomationInputPolicy.waitUntilReady(ready: {
            guard let field = self.currentFocusedInput(pid: browserPID, on: display),
                  ["AXTextField", "AXComboBox"].contains(field.role) else { return false }
            var ancestorRoles: [String] = []
            var parent = self.accessibilityElement(field.element, kAXParentAttribute)
            for _ in 0..<15 {
                guard let element = parent else { break }
                let role = self.stringAttribute(element, kAXRoleAttribute) ?? ""
                ancestorRoles.append(role)
                if role == "AXWindow" { break }
                parent = self.accessibilityElement(element, kAXParentAttribute)
            }
            guard AutomationTextEntryPolicy.isBrowserAddressField(label: field.identity.label, ancestorRoles: ancestorRoles) else { return false }
            addressField = field
            return true
        }, cancelled: { self.inputIsCancelled() }, timeoutError: .focusMismatch)
        guard let addressField else { throw AccessibilityActionError.focusMismatch }
        let textResult = try await performTextEntry(action: ["type": "set_value", "pid": Int(browserPID), "text": navigationText],
            record: addressField, on: display)
        guard textResult.verified else {
            throw AccessibilityActionError.uncertainDelivery("The browser address could not be verified; navigation was not submitted. Inspect the address field before continuing")
        }
        try postKey("return", modifiers: [], to: browserPID, preflight: {
            try self.validateRecord(addressField, action: ["pid": Int(browserPID)], on: display)
            guard self.intendedElementHasFocus(addressField), self.readableTextValue(addressField) == navigationText else {
                throw AccessibilityActionError.focusMismatch
            }
        })
        try? await Task.sleep(for: .milliseconds(350))
        return "Opened \(description) in \(browserName); inspect the rendered page before finishing"
    }

    static func browserNavigationText(from action: [String: Any]) throws -> String {
        let rawURL = (action["url"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let rawURL, !rawURL.isEmpty {
            guard let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host != nil else {
                throw AccessibilityActionError.invalidAction(
                    "navigate_browser accepts only a complete http or https URL"
                )
            }
            return url.absoluteString
        }
        let rawQuery = (action["query"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let rawQuery, !rawQuery.isEmpty else {
            throw AccessibilityActionError.invalidAction(
                "navigate_browser requires a URL or search query"
            )
        }
        return rawQuery
    }

    private func stabilizeRoutedApplication(
        bundleID: String,
        name: String,
        on display: DisplayDescriptor
    ) async throws {
        guard let application = await waitForRunningApplication(
            bundleID: bundleID,
            name: name,
            timeout: .seconds(3)
        ) else {
            throw AccessibilityActionError.operationFailed(
                "The routed app stopped before its destination became visible"
            )
        }

        let placement = await waitForWindowsAndPlace(
            launchedApplication: application,
            bundleID: bundleID,
            name: name,
            on: display,
            timeout: .seconds(3),
            activateCandidates: true
        )
        guard placement.visibleWindowCount > 0 else {
            throw AccessibilityActionError.operationFailed(
                "The routed destination did not leave a visible window on the agent screen"
            )
        }

        recordAgentLaunch(pids: placement.candidatePIDs)
        rememberPreferredTaskTarget(from: placement.candidatePIDs, on: display)

        // Activation and AXRaise complete on different run-loop turns in
        // System Settings. Raise the final pane, then wait one short turn so
        // the next screenshot cannot race the old z-order.
        for pid in placement.candidatePIDs {
            _ = placeAndRaiseWindows(of: pid, on: display)
        }
        try? await Task.sleep(for: .milliseconds(180))
    }

    private func launchApp(_ action: [String: Any], on display: DisplayDescriptor) async throws -> String {
        let requestedBundleID = action["bundle_id"] as? String
        let requestedName = action["app"] as? String
        if requestedBundleID == Bundle.main.bundleIdentifier {
            throw AccessibilityActionError.controllerProtected
        }

        let workspace = NSWorkspace.shared
        let url: URL?
        if let requestedBundleID, !requestedBundleID.isEmpty {
            url = workspace.runningApplications.first(where: {
                    $0.bundleIdentifier == requestedBundleID && !$0.isTerminated
                })?.bundleURL
                ?? workspace.urlForApplication(withBundleIdentifier: requestedBundleID)
                ?? installedApplicationEntries.first(where: { $0.bundleID == requestedBundleID })?.url
        } else if let requestedName, !requestedName.isEmpty {
            url = applicationURL(named: requestedName)
        } else {
            url = nil
        }
        guard let url else {
            throw AccessibilityActionError.invalidAction("The requested app could not be found")
        }
        if url.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
            throw AccessibilityActionError.controllerProtected
        }

        let expectedBundleID = Self.applicationBundleIdentifier(at: url) ?? requestedBundleID
        let configuration = NSWorkspace.OpenConfiguration()
        // Activation is required for several Catalyst and iPhone/iPad apps to
        // create their first SceneWindow. TaskPilot still relocates a movable
        // window immediately after it appears.
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.hidesOthers = false

        let app: NSRunningApplication
        do {
            app = try await workspace.openApplication(at: url, configuration: configuration)
        } catch {
            // iPhone/iPad-style wrappers can be registered with LaunchServices
            // without behaving like a conventional macOS bundle. The plain
            // workspace open route handles those wrappers, after which we bind
            // to the actual (sometimes translocated) running process.
            guard workspace.open(url),
                  let launched = await waitForRunningApplication(
                    bundleID: expectedBundleID,
                    name: requestedName,
                    timeout: .seconds(8)
                  ) else {
                throw error
            }
            app = launched
        }

        var placement = await waitForWindowsAndPlace(
            launchedApplication: app,
            bundleID: expectedBundleID,
            name: requestedName,
            on: display,
            timeout: passiveLaunchWait,
            activateCandidates: false
        )
        recordAgentLaunch(pids: placement.candidatePIDs)

        if placement.visibleWindowCount == 0 {
            // iPhone/iPad apps and some launchers hand off to a new,
            // translocated process after NSWorkspace returns. Resolve matching
            // applications again on every poll, activate the real process once,
            // and follow any replacement PID until its SceneWindow appears.
            placement = await waitForWindowsAndPlace(
                launchedApplication: app,
                bundleID: expectedBundleID,
                name: requestedName,
                on: display,
                timeout: activatedLaunchWait,
                activateCandidates: true
            )
        } else {
            // Raise the relocated app above stale Safari/Finder windows so the
            // next agent-screen screenshot actually shows the requested app.
            let candidates = candidateApplications(
                launchedApplication: app,
                bundleID: expectedBundleID,
                name: requestedName
            )
            for candidate in candidates {
                candidate.unhide()
                _ = candidate.activate(options: [.activateAllWindows])
            }
            try? await Task.sleep(for: .milliseconds(250))
            placement = LaunchPlacementResult(
                visibleWindowCount: max(
                    placement.visibleWindowCount,
                    candidates.reduce(0) {
                        $0 + placeAndRaiseWindows(of: $1.processIdentifier, on: display)
                    }
                ),
                candidatePIDs: Array(Set(
                    placement.candidatePIDs + candidates.map(\.processIdentifier)
                ))
            )
        }

        // Some iOS-on-Mac wrappers replace their launcher process after the
        // first window appears. Capture that final PID as part of this same
        // explicit agent launch, without treating unrelated concurrent apps as
        // task-owned.
        let finalCandidates = candidateApplications(
            launchedApplication: app,
            bundleID: expectedBundleID,
            name: requestedName
        )
        let finalPIDs = Array(Set(
            placement.candidatePIDs + finalCandidates.map(\.processIdentifier)
        ))
        recordAgentLaunch(pids: finalPIDs)

        if placement.visibleWindowCount == 0 {
            let allWindowFrames = finalPIDs.flatMap(cgWindowFrames(of:))
            if let fallbackDisplay = Self.displayContainingLargestVisibleArea(
                windowFrames: allWindowFrames,
                displays: DisplayService().displays()
            ), fallbackDisplay.id != display.id {
                for candidate in finalCandidates {
                    candidate.unhide()
                    _ = candidate.activate(options: [.activateAllWindows])
                }
                setTaskDisplayOverride(fallbackDisplay.id)
                rememberPreferredTaskTarget(from: finalPIDs, on: fallbackDisplay)
                let openedName = app.localizedName ?? requestedName ?? "the app"
                return "Opened \(openedName); macOS kept its visible window on \(fallbackDisplay.name), so \(TaskPilotIdentity.displayName) followed it there"
            }
        }

        guard placement.visibleWindowCount > 0 else {
            throw AccessibilityActionError.operationFailed(
                "\(app.localizedName ?? requestedName ?? "The requested app") launched, but no visible window appeared on the agent screen"
            )
        }
        rememberPreferredTaskTarget(from: finalPIDs, on: display)
        return "Opened \(app.localizedName ?? requestedName ?? "the app"); its window is visible on the agent screen"
    }

    private func recordAgentLaunch(pids: [pid_t]) {
        lock.lock()
        guard var baseline = taskApplicationBaseline else {
            lock.unlock()
            return
        }
        baseline.agentLaunchedPIDs.formUnion(pids.filter { $0 != controllerPID })
        taskApplicationBaseline = baseline
        lock.unlock()
    }

    private func setTaskDisplayOverride(_ displayID: CGDirectDisplayID) {
        lock.lock()
        taskDisplayOverrideID = displayID
        lock.unlock()
    }

    private func waitForWindowsAndPlace(
        launchedApplication: NSRunningApplication,
        bundleID: String?,
        name: String?,
        on display: DisplayDescriptor,
        timeout: Duration,
        activateCandidates: Bool
    ) async -> LaunchPlacementResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var seenPIDs: Set<pid_t> = []
        var activatedPIDs: Set<pid_t> = []
        repeat {
            let candidates = candidateApplications(
                launchedApplication: launchedApplication,
                bundleID: bundleID,
                name: name
            )
            let pids = Array(Set(
                candidates.map(\.processIdentifier) +
                matchingWindowOwnerPIDs(bundleID: bundleID, name: name)
            )).filter { $0 != controllerPID }
            seenPIDs.formUnion(pids)

            if activateCandidates {
                for candidate in candidates
                    where !activatedPIDs.contains(candidate.processIdentifier) {
                    candidate.unhide()
                    _ = candidate.activate(options: [.activateAllWindows])
                    activatedPIDs.insert(candidate.processIdentifier)
                }
            }

            var count = 0
            for pid in pids where pid != controllerPID {
                count += placeAndRaiseWindows(of: pid, on: display)
            }
            let cgVisibleCount = pids.reduce(0) { partial, pid in
                partial + cgWindowFrames(of: pid).filter {
                    $0.intersects(display.frame)
                }.count
            }
            count = max(count, cgVisibleCount)
            if count > 0 {
                return LaunchPlacementResult(
                    visibleWindowCount: count,
                    candidatePIDs: Array(seenPIDs)
                )
            }
            try? await Task.sleep(for: .milliseconds(350))
        } while clock.now < deadline
        return LaunchPlacementResult(
            visibleWindowCount: 0,
            candidatePIDs: Array(seenPIDs)
        )
    }

    @discardableResult
    private func placeAndRaiseWindows(of pid: pid_t, on display: DisplayDescriptor) -> Int {
        guard pid != controllerPID else { return 0 }
        let root = AXUIElementCreateApplication(pid)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var offset: CGFloat = 0
        var visibleCount = 0
        for window in windows {
            var position = CGPoint(
                x: display.frame.minX + 50 + offset,
                y: display.frame.minY + 70 + offset
            )
            if let value = AXValueCreate(.cgPoint, &position) {
                _ = AXUIElementSetAttributeValue(
                    window,
                    kAXPositionAttribute as CFString,
                    value
                )
            }
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            let currentFrame = frame(of: window)
            if currentFrame?.intersects(display.frame) == true {
                visibleCount += 1
            }
            offset = min(offset + 28, 140)
        }
        return visibleCount
    }

    private func candidateApplications(
        launchedApplication: NSRunningApplication,
        bundleID: String?,
        name: String?
    ) -> [NSRunningApplication] {
        let normalizedName = name.map(Self.normalizedApplicationName)
        var matches = NSWorkspace.shared.runningApplications.filter { candidate in
            guard candidate.processIdentifier != controllerPID,
                  !candidate.isTerminated else { return false }
            if candidate.processIdentifier == launchedApplication.processIdentifier {
                return true
            }
            if let bundleID, !bundleID.isEmpty,
               candidate.bundleIdentifier == bundleID {
                return true
            }
            if let normalizedName, !normalizedName.isEmpty,
               Self.normalizedApplicationName(candidate.localizedName ?? "") == normalizedName {
                return true
            }
            if let bundleURL = candidate.bundleURL,
               let bundleID, !bundleID.isEmpty,
               Self.applicationBundleIdentifier(at: bundleURL) == bundleID {
                return true
            }
            return false
        }
        if !launchedApplication.isTerminated,
           !matches.contains(where: {
               $0.processIdentifier == launchedApplication.processIdentifier
           }) {
            matches.append(launchedApplication)
        }
        return matches
    }

    private func matchingWindowOwnerPIDs(
        bundleID: String?,
        name: String?
    ) -> [pid_t] {
        let normalizedName = name.map(Self.normalizedApplicationName)
        let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return Array(Set(rows.compactMap { row -> pid_t? in
            guard let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = row[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0 else { return nil }
            let pid = pid_t(owner.intValue)
            guard pid != controllerPID,
                  let candidate = NSRunningApplication(processIdentifier: pid),
                  !candidate.isTerminated else { return nil }
            if let bundleID, !bundleID.isEmpty,
               candidate.bundleIdentifier == bundleID {
                return pid
            }
            if let normalizedName, !normalizedName.isEmpty,
               Self.normalizedApplicationName(candidate.localizedName ?? "") == normalizedName {
                return pid
            }
            return nil
        }))
    }

    private func waitForRunningApplication(
        bundleID: String?,
        name: String?,
        timeout: Duration
    ) async -> NSRunningApplication? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if let app = matchingRunningApplication(bundleID: bundleID, name: name) {
                return app
            }
            try? await Task.sleep(for: .milliseconds(300))
        } while clock.now < deadline
        return nil
    }

    private func matchingRunningApplication(
        bundleID: String?,
        name: String?
    ) -> NSRunningApplication? {
        let normalizedName = name.map(Self.normalizedApplicationName)
        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.processIdentifier != controllerPID, !app.isTerminated else { return false }
                if let bundleID, !bundleID.isEmpty, app.bundleIdentifier == bundleID { return true }
                if let normalizedName, !normalizedName.isEmpty,
                   Self.normalizedApplicationName(app.localizedName ?? "") == normalizedName {
                    return true
                }
                return false
            }
            .max(by: { $0.processIdentifier < $1.processIdentifier })
    }

    static func applicationBundleIdentifier(at url: URL) -> String? {
        for bundleURL in applicationBundleURLs(at: url) {
            if let identifier = Bundle(url: bundleURL)?.bundleIdentifier {
                return identifier
            }
        }
        return nil
    }

    static func applicationBundleURLs(at url: URL) -> [URL] {
        var candidates = [url]
        let fileManager = FileManager.default
        for folderName in ["Wrapper", "WrappedBundle"] {
            let wrapper = url.appendingPathComponent(folderName, isDirectory: true)
            guard let children = try? fileManager.contentsOfDirectory(
                at: wrapper,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            candidates.append(contentsOf: children.filter {
                $0.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame
            })
        }
        return candidates
    }

    private static func isIOSApplication(at url: URL) -> Bool {
        for bundleURL in applicationBundleURLs(at: url) {
            guard let bundle = Bundle(url: bundleURL) else { continue }
            if bundle.object(forInfoDictionaryKey: "LSRequiresIPhoneOS") as? Bool == true {
                return true
            }
            if let platforms = bundle.object(
                forInfoDictionaryKey: "CFBundleSupportedPlatforms"
            ) as? [String],
               platforms.contains(where: {
                   $0.localizedCaseInsensitiveContains("iphone")
               }) {
                return true
            }
        }
        return false
    }

    private func applicationURL(named name: String) -> URL? {
        let normalizedName = Self.normalizedApplicationName(name)
        if let runningURL = NSWorkspace.shared.runningApplications.first(where: {
            Self.normalizedApplicationName($0.localizedName ?? "") == normalizedName
        })?.bundleURL {
            return runningURL
        }
        let appName = name.lowercased().hasSuffix(".app") ? name : "\(name).app"
        let directCandidates = [
            URL(fileURLWithPath: "/Applications").appendingPathComponent(appName),
            URL(fileURLWithPath: "/System/Applications").appendingPathComponent(appName),
            URL(fileURLWithPath: "/System/Applications/Utilities").appendingPathComponent(appName),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(appName)
        ]
        if let direct = directCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            return direct
        }

        // The cached catalog recursively covers app folders such as Utilities
        // and vendor suites, while skipping the contents of each .app bundle.
        return installedApplicationEntries.first(where: {
            Self.normalizedApplicationName($0.name) == normalizedName
        })?.url
    }

    private func discoverInstalledApplications() -> [InstalledApplication] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        var entries: [String: InstalledApplication] = [:]

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let candidate as URL in enumerator {
                guard candidate.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }
                let name = candidate.deletingPathExtension().lastPathComponent
                let bundleID = Self.applicationBundleIdentifier(at: candidate) ?? ""
                guard bundleID != Bundle.main.bundleIdentifier,
                      candidate.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL else {
                    continue
                }
                let metadata = applicationUsageMetadata(at: candidate)
                let key = bundleID.isEmpty
                    ? Self.normalizedApplicationName(name)
                    : bundleID.lowercased()
                if entries[key] == nil {
                    entries[key] = InstalledApplication(
                        name: name,
                        bundleID: bundleID,
                        url: candidate,
                        isIOSApp: Self.isIOSApplication(at: candidate),
                        lastUsedDate: metadata.lastUsedDate,
                        usedDatesInLast30Days: metadata.usedDatesInLast30Days,
                        totalUseCount: metadata.totalUseCount
                    )
                }
            }
        }

        return entries.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(400)
            .map { $0 }
    }

    private func applicationUsageMetadata(
        at url: URL
    ) -> (lastUsedDate: Date?, usedDatesInLast30Days: Int, totalUseCount: Int) {
        guard let item = MDItemCreate(
            kCFAllocatorDefault,
            url.path as CFString
        ) else {
            return (nil, 0, 0)
        }
        let lastUsed = MDItemCopyAttribute(
            item,
            kMDItemLastUsedDate
        ) as? Date
        let usedDates = MDItemCopyAttribute(
            item,
            "kMDItemUsedDates" as CFString
        ) as? [Date] ?? []
        let totalUseCount = (MDItemCopyAttribute(
            item,
            "kMDItemUseCount" as CFString
        ) as? NSNumber)?.intValue ?? 0
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        return (
            lastUsed,
            usedDates.filter { $0 >= cutoff }.count,
            totalUseCount
        )
    }

    static let systemTaskRoutes: [[String: String]] = [
        [
            "route_id": "screen_time",
            "intent": "app usage, most-used app, or screen-time totals",
            "app": "System Settings",
            "bundle_id": "com.apple.systempreferences",
            "destination": "Screen Time → App & Website Activity",
            "settings_url": "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension",
            "guidance": "Use the visible Screen Time duration only for its displayed day or week. A day/week value never satisfies a past-month request. For a past-month request, use system_context.usage_rankings_last_30_days for the ranking and report its exact amount only as activity recorded on N of the last 30 days, clearly distinguished from Screen Time duration."
        ],
        [
            "route_id": "finder",
            "intent": "find, inspect, organize, or open local files",
            "app": "Finder",
            "bundle_id": "com.apple.finder",
            "destination": "Finder search",
            "guidance": "Search visibly in Finder and respect any macOS protected-folder prompt."
        ],
        [
            "route_id": "calendar",
            "intent": "calendar, events, availability, or scheduling",
            "app": "Calendar",
            "bundle_id": "com.apple.iCal",
            "destination": "Calendar",
            "guidance": "Search the visible calendar before answering or editing."
        ],
        [
            "route_id": "reminders",
            "intent": "reminders or personal task lists",
            "app": "Reminders",
            "bundle_id": "com.apple.reminders",
            "destination": "Reminders",
            "guidance": "Search visible lists and verify the final state."
        ],
        [
            "route_id": "activity_monitor",
            "intent": "running processes, CPU, memory, energy, or app responsiveness",
            "app": "Activity Monitor",
            "bundle_id": "com.apple.ActivityMonitor",
            "destination": "Activity Monitor",
            "guidance": "Use the relevant visible column and sort it when needed."
        ],
        [
            "route_id": "storage",
            "intent": "storage usage or installed application sizes",
            "app": "System Settings",
            "bundle_id": "com.apple.systempreferences",
            "destination": "General → Storage",
            "settings_url": "x-apple.systempreferences:com.apple.settings.Storage",
            "guidance": "Wait for visible storage categories to finish loading."
        ],
        [
            "route_id": "mail",
            "intent": "email, inbox, or sent mail",
            "app": "Mail",
            "bundle_id": "com.apple.mail",
            "destination": "Mail search",
            "guidance": "Use the visible mailbox/search interface and verify the requested message facts or final action."
        ],
        [
            "route_id": "notes",
            "intent": "notes or note folders",
            "app": "Notes",
            "bundle_id": "com.apple.Notes",
            "destination": "Notes search",
            "guidance": "Search visible notes and open the relevant result before answering or editing."
        ],
        [
            "route_id": "contacts",
            "intent": "contacts or address book",
            "app": "Contacts",
            "bundle_id": "com.apple.AddressBook",
            "destination": "Contacts search",
            "guidance": "Search visible contact records and report only requested visible fields."
        ],
        [
            "route_id": "photos",
            "intent": "photos, albums, or image library",
            "app": "Photos",
            "bundle_id": "com.apple.Photos",
            "destination": "Photos library or search",
            "guidance": "Use visible albums/search and inspect the requested photo context."
        ],
        [
            "route_id": "maps",
            "intent": "maps, places, routes, or directions",
            "app": "Maps",
            "bundle_id": "com.apple.Maps",
            "destination": "Maps search or directions",
            "guidance": "Search visibly, inspect the route/place card, and preserve visible distance and time units."
        ],
        [
            "route_id": "music",
            "intent": "music, songs, albums, artists, or playlists",
            "app": "Music",
            "bundle_id": "com.apple.Music",
            "destination": "Music search or library",
            "guidance": "Search the visible library/catalog and verify the requested playback or result."
        ],
        [
            "route_id": "calculator",
            "intent": "calculation or arithmetic",
            "app": "Calculator",
            "bundle_id": "com.apple.calculator",
            "destination": "Calculator",
            "guidance": "Use the visible Calculator result and return only the requested value."
        ],
        [
            "route_id": "dictionary",
            "intent": "word definition or dictionary lookup",
            "app": "Dictionary",
            "bundle_id": "com.apple.Dictionary",
            "destination": "Dictionary search",
            "guidance": "Search visibly and return only the requested definition or word fact."
        ],
        [
            "route_id": "web",
            "intent": "website, online research, or a web account",
            "app": "Safari",
            "bundle_id": "com.apple.Safari",
            "destination": "the rendered website",
            "guidance": "Use page content, controls, and scrolling—not only the URL or tab title."
        ]
    ]

    private func systemContext() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        let rankedApplications = installedApplicationEntries
            .filter { $0.lastUsedDate != nil || $0.usedDatesInLast30Days > 0 }
            .sorted {
                if $0.usedDatesInLast30Days != $1.usedDatesInLast30Days {
                    return $0.usedDatesInLast30Days > $1.usedDatesInLast30Days
                }
                if $0.totalUseCount != $1.totalUseCount {
                    return $0.totalUseCount > $1.totalUseCount
                }
                return ($0.lastUsedDate ?? .distantPast) > ($1.lastUsedDate ?? .distantPast)
            }
            .prefix(80)
            .enumerated()
            .map { index, entry -> [String: Any] in
                var row: [String: Any] = [
                    "rank": index + 1,
                    "name": entry.name,
                    "bundle_id": entry.bundleID,
                    "platform": entry.isIOSApp ? "iPhone/iPad app on Mac" : "macOS",
                    "usage_date_samples_last_30_days": entry.usedDatesInLast30Days
                ]
                if let lastUsedDate = entry.lastUsedDate {
                    row["last_used"] = formatter.string(from: lastUsedDate)
                }
                return row
            }
        return [
            "task_routes": Self.systemTaskRoutes,
            "usage_rankings_last_30_days": rankedApplications,
            "usage_measurement_note": "usage_date_samples_last_30_days is local Spotlight usage-date frequency within the last 30 days, not launches or foreground duration. Report it only as usage-date samples (for example, activity recorded on N of the last 30 days). For precise time totals, inspect System Settings → Screen Time and report its visible date range.",
            "application_inventory_scope": [
                "/Applications",
                "/System/Applications",
                "~/Applications"
            ],
            "file_discovery": [
                "recommended_app": "Finder",
                "rule": "Use native read_file/write_file for known paths. Use Finder or run_command to discover a path when the request does not identify one. Protected folders remain governed by normal macOS privacy prompts."
            ],
            "computer_access": [
                "applications": "\(TaskPilotIdentity.displayName) inventories launchable apps in system and user Applications folders, including nested suites and iPhone/iPad wrappers.",
                "files": "\(TaskPilotIdentity.displayName) can read and write known file paths directly, or use Finder for visible discovery, under the signed-in user's normal macOS access. A protected folder may still show its own macOS consent prompt.",
                "shell": "\(TaskPilotIdentity.displayName) runs user-requested zsh commands with bounded output and a timeout; Pause and Stop apply to the command process group.",
                "browser": "\(TaskPilotIdentity.displayName) can navigate directly to a URL or search, then inspect and control the rendered browser interface through Accessibility.",
                "privacy": "Accessibility and Screen & System Audio Recording are sufficient for visible app control. \(TaskPilotIdentity.displayName) does not bypass macOS privacy protections or read passwords."
            ]
        ]
    }

    static func normalizedApplicationName(_ value: String) -> String {
        let withoutExtension = value.lowercased().hasSuffix(".app")
            ? String(value.dropLast(4))
            : value
        let folded = withoutExtension.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return String(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    // MARK: - Action target validation

    private func observedFocusedInput(pid: pid_t) throws -> ElementRecord {
        let candidates = lock.withLock { elementMap.values.filter {
            $0.pid == pid && $0.wasFocused && AutomationTextEntryPolicy.inputRoles.contains($0.role)
        }.sorted { $0.depth > $1.depth } }
        guard let first = candidates.first,
              candidates.allSatisfy({ element(first.element, isWithin: $0.element) }) else {
            throw AccessibilityActionError.focusMismatch
        }
        return first
    }

    private func currentFocusedInput(pid: pid_t, on display: DisplayDescriptor) -> ElementRecord? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let focused = accessibilityElement(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
              let rectangle = frame(of: focused), rectangle.intersects(display.frame) else { return nil }
        let window = accessibilityElement(focused, kAXWindowAttribute)
        let identity = targetIdentity(focused, application: applicationIdentity(app), window: window)
        guard AutomationTextEntryPolicy.inputRoles.contains(identity.role),
              !AutomationTextEntryPolicy.isSecure(role: identity.role, subrole: identity.subrole) else { return nil }
        return ElementRecord(element: focused, revision: lock.withLock { observationRevision }, identity: identity,
            window: window, depth: 0, supportsPress: false, wasFocused: true,
            observedTextValue: stringAttribute(focused, kAXValueAttribute), observedSelection: selectedTextRange(focused))
    }

    private func element(_ child: AXUIElement, isWithin parent: AXUIElement) -> Bool {
        var current = child
        for _ in 0..<15 {
            if CFEqual(current, parent) { return true }
            guard let ancestor = accessibilityElement(current, kAXParentAttribute), !CFEqual(ancestor, current) else { break }
            current = ancestor
        }
        return false
    }

    private func intendedElementHasFocus(_ record: ElementRecord) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == record.pid,
              let focused = accessibilityElement(AXUIElementCreateApplication(record.pid), kAXFocusedUIElementAttribute)
        else { return false }
        if CFEqual(focused, record.element) { return true }
        // Editable combo boxes can delegate focus to their text-field child.
        return AutomationTextEntryPolicy.inputRoles.contains(record.role)
            && AutomationTextEntryPolicy.inputRoles.contains(stringAttribute(focused, kAXRoleAttribute) ?? "")
            && element(focused, isWithin: record.element)
    }

    private func ensureElementFocus(_ record: ElementRecord, action: [String: Any], on display: DisplayDescriptor) async throws {
        try validateRecord(record, action: action, on: display)
        if !intendedElementHasFocus(record) {
            // PID-only insertion refers to the field focused in the planning
            // observation. Never redirect it to a newly focused field.
            guard action["type"] as? String != "type_text" || action["element_id"] != nil else {
                throw AccessibilityActionError.focusMismatch
            }
            let result = AXUIElementSetAttributeValue(record.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if result == .apiDisabled { throw AccessibilityActionError.permissionDenied }
            guard result == .success else { throw AccessibilityActionError.focusMismatch }
        }
        try await AutomationInputPolicy.waitUntilReady(
            ready: { self.intendedElementHasFocus(record) }, cancelled: { self.inputIsCancelled() },
            timeoutError: .focusMismatch)
        try validateRecord(record, action: action, on: display)
    }

    private func selectedTextRange(_ element: AXUIElement) -> NSRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func readableTextValue(_ record: ElementRecord) -> String? {
        var pid: pid_t = 0
        let role = stringAttribute(record.element, kAXRoleAttribute) ?? ""
        let subrole = stringAttribute(record.element, kAXSubroleAttribute) ?? ""
        guard AXUIElementGetPid(record.element, &pid) == .success, pid == record.pid,
              role == record.role, !AutomationTextEntryPolicy.isSecure(role: role, subrole: subrole) else { return nil }
        return stringAttribute(record.element, kAXValueAttribute)
    }

    private func setTextAttribute(_ name: String, value: CFTypeRef, record: ElementRecord) throws -> TextAttributeDelivery {
        var settable = DarwinBoolean(false)
        let support = AXUIElementIsAttributeSettable(record.element, name as CFString, &settable)
        if support == .apiDisabled { throw AccessibilityActionError.permissionDenied }
        guard support == .success, settable.boolValue else { return .unsupported }
        guard !inputIsCancelled() else { throw AccessibilityActionError.cancelled }
        guard intendedElementHasFocus(record) else { throw AccessibilityActionError.focusMismatch }
        switch AXUIElementSetAttributeValue(record.element, name as CFString, value) {
        case .success: return .accepted
        case .attributeUnsupported, .actionUnsupported, .notImplemented: return .unsupported
        case .apiDisabled: throw AccessibilityActionError.permissionDenied
        default: return .uncertain
        }
    }

    private func performTextEntry(action: [String: Any], record: ElementRecord, on display: DisplayDescriptor, privateInput: Bool = false) async throws -> AutomationTextEntryResult {
        guard AutomationTextEntryPolicy.inputRoles.contains(record.role), let text = action["text"] as? String else {
            throw AccessibilityActionError.invalidAction("Text entry requires an observed text input and text")
        }
        guard action["type"] as? String != "type_text" || !text.isEmpty else {
            throw AccessibilityActionError.invalidAction("type_text requires nonempty text")
        }
        try validateRecord(record, action: action, on: display)
        let secure = privateInput || AutomationTextEntryPolicy.isSecure(role: record.role, subrole: record.identity.subrole)
        if !secure {
            guard readableTextValue(record) == record.observedTextValue else { throw AccessibilityActionError.staleObservation }
            if action["type"] as? String == "type_text", record.wasFocused,
               selectedTextRange(record.element) != record.observedSelection { throw AccessibilityActionError.staleObservation }
        }
        rememberManualTarget(record.pid)
        return try await AutomationTextEntryPolicy.enter(text: text, replacement: action["type"] as? String == "set_value", secure: secure,
            focus: {
                try await self.ensureElementFocus(record, action: action, on: display)
                if !secure, self.readableTextValue(record) != record.observedTextValue {
                    throw AccessibilityActionError.staleObservation
                }
                if !secure, action["type"] as? String == "type_text", record.wasFocused,
                   self.selectedTextRange(record.element) != record.observedSelection {
                    throw AccessibilityActionError.staleObservation
                }
            },
            preflight: {
                try self.validateRecord(record, action: action, on: display)
                guard self.intendedElementHasFocus(record) else { throw AccessibilityActionError.focusMismatch }
            },
            readValue: { self.readableTextValue(record) }, readSelection: { self.selectedTextRange(record.element) },
            setValue: { try self.setTextAttribute(kAXValueAttribute, value: $0 as CFString, record: record) },
            setSelectedText: { try self.setTextAttribute(kAXSelectedTextAttribute, value: $0 as CFString, record: record) },
            selectRange: { requested in
                var range = CFRange(location: requested.location, length: requested.length)
                guard let value = AXValueCreate(.cfRange, &range) else { return false }
                return try self.setTextAttribute(kAXSelectedTextRangeAttribute, value: value, record: record) == .accepted
            },
            typeText: { text, preflight in
                if text.isEmpty { try self.postKey("delete", modifiers: [], to: record.pid, preflight: preflight) }
                else { try self.postUnicode(text, to: record.pid, preflight: preflight) }
            },
            waitForMatch: { matches in
                guard !self.inputIsCancelled() else { throw AccessibilityActionError.cancelled }
                try Task.checkCancellation()
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while !matches(), ContinuousClock.now < deadline {
                    guard !self.inputIsCancelled() else { throw AccessibilityActionError.cancelled }
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard !self.inputIsCancelled() else { throw AccessibilityActionError.cancelled }
                try Task.checkCancellation()
            })
    }

    private func record(for action: [String: Any]) throws -> ElementRecord {
        guard let id = action["element_id"] as? String else {
            throw AccessibilityActionError.invalidAction("This action requires an element_id")
        }
        lock.lock()
        let value = elementMap[id]
        lock.unlock()
        guard let value else { throw AccessibilityActionError.elementUnavailable }
        return value
    }

    private func validateRecord(_ record: ElementRecord, action: [String: Any], on display: DisplayDescriptor) throws {
        guard !inputIsCancelled() else { throw AccessibilityActionError.cancelled }
        try validateObservation(record.revision)
        var ownerPID: pid_t = 0
        guard let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated,
              AXUIElementGetPid(record.element, &ownerPID) == .success, ownerPID == record.pid else {
            throw AccessibilityActionError.staleObservation
        }
        if let pid = intValue(action["pid"]), pid != Int(record.pid) {
            throw AccessibilityActionError.staleObservation
        }
        let currentWindow = record.role == "AXWindow" ? record.element
            : accessibilityElement(record.element, kAXWindowAttribute)
        let sameWindow: Bool
        if let expected = record.window, let currentWindow {
            // Open app menus may have an AX owner window that is absent from
            // AXWindows; still require the same owner and its observed state.
            sameWindow = CFEqual(expected, currentWindow)
                && (record.role.hasPrefix("AXMenu") || windows(of: record.pid).contains { CFEqual($0, expected) })
        } else { sameWindow = record.window == nil && currentWindow == nil }
        try AutomationTargetPolicy.validate(observed: record.identity,
            current: targetIdentity(record.element, application: applicationIdentity(app), window: currentWindow),
            sameWindow: sameWindow, enabled: boolAttribute(record.element, kAXEnabledAttribute) != false,
            displayFrame: display.frame)
    }

    private func applicationIdentity(_ app: NSRunningApplication) -> AutomationApplicationIdentity {
        AutomationApplicationIdentity(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
            bundlePath: app.bundleURL?.path, name: app.localizedName, launchDate: app.launchDate)
    }

    private func targetIdentity(_ element: AXUIElement, application: AutomationApplicationIdentity,
                                window: AXUIElement?) -> AutomationTargetIdentity {
        AutomationTargetIdentity(application: application,
            role: stringAttribute(element, kAXRoleAttribute) ?? "unknown",
            subrole: stringAttribute(element, kAXSubroleAttribute) ?? "",
            label: elementTitle(element), bounds: frame(of: element),
            windowTitle: window.map { elementTitle($0) }, windowBounds: window.flatMap { frame(of: $0) })
    }

    private func validateCoordinateWindows(_ pid: pid_t, on display: DisplayDescriptor) throws {
        let (expectedApp, expected) = lock.withLock { (observedApplications[pid], observedGraphicsWindows[pid] ?? []) }
        let current = graphicsWindows(of: pid).filter { $0.frame.intersects(display.frame) }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              expectedApp == applicationIdentity(app) else {
            throw AccessibilityActionError.staleObservation
        }
        guard !inputIsCancelled() else { throw AccessibilityActionError.cancelled }
        try AutomationTargetPolicy.validateWindows(observed: expected, current: current)
    }

    private func observedControl(at point: CGPoint, pid: pid_t) -> ElementRecord? {
        let containers: Set<String> = ["AXApplication", "AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup",
                                       "AXWebArea", "AXLayoutArea", "AXMenuBar", "unknown"]
        return lock.withLock {
            elementMap.values.filter {
                $0.pid == pid && !containers.contains($0.role) && $0.observedBounds?.contains(point) == true
            }.sorted {
                if $0.supportsPress != $1.supportsPress { return $0.supportsPress }
                let a = $0.observedBounds!, b = $1.observedBounds!
                return a.width * a.height == b.width * b.height ? $0.depth > $1.depth
                    : a.width * a.height < b.width * b.height
            }.first
        }
    }

    private func validatePointerHit(_ record: ElementRecord, at point: CGPoint) throws {
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(record.pid),
            Float(point.x), Float(point.y), &hit)
        guard result == .success, let current = hit else { throw AccessibilityActionError.staleObservation }
        // A button can hit-test as its image/label child. Accept only that same
        // control or a descendant, never a different control at the old point.
        if element(current, isWithin: record.element) { return }
        throw AccessibilityActionError.staleObservation
    }

    static func resolvedTargetPID(
        explicitPID: Int?,
        rememberedPID: pid_t?,
        visiblePIDs: Set<pid_t>,
        frontmostPID: pid_t?
    ) -> pid_t? {
        if let explicitPID, explicitPID > 0 {
            return pid_t(explicitPID)
        }
        if let rememberedPID, visiblePIDs.contains(rememberedPID) {
            return rememberedPID
        }
        if let frontmostPID, visiblePIDs.contains(frontmostPID) {
            return frontmostPID
        }
        return visiblePIDs.count == 1 ? visiblePIDs.first : nil
    }

    private func actionPID(
        _ action: [String: Any],
        on display: DisplayDescriptor,
        fallbackPoint: CGPoint? = nil
    ) throws -> pid_t {
        lock.lock()
        let rememberedPID = manualTargetPID
        lock.unlock()
        let visiblePIDs = Set(
            controllableRunningApplications()
                .map(\.processIdentifier)
                .filter { hasWindow(of: $0, intersecting: display.frame) }
        )
        if let pid = Self.resolvedTargetPID(
            explicitPID: intValue(action["pid"]),
            rememberedPID: rememberedPID,
            visiblePIDs: visiblePIDs,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ) {
            return pid
        }
        if let fallbackPoint {
            return try targetPID(at: fallbackPoint)
        }
        throw AccessibilityActionError.invalidAction(
            "This action requires the target app pid; observe the active app again"
        )
    }

    private func rememberPreferredTaskTarget(
        from candidatePIDs: [pid_t],
        on display: DisplayDescriptor
    ) {
        let visiblePIDs = Set(candidatePIDs.filter {
            $0 != controllerPID && hasWindow(of: $0, intersecting: display.frame)
        })
        if let pid = Self.resolvedTargetPID(
            explicitPID: nil,
            rememberedPID: nil,
            visiblePIDs: visiblePIDs,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ) {
            rememberManualTarget(pid)
        }
    }

    private func ensureAllowed(_ pid: pid_t) throws {
        guard pid != controllerPID else { throw AccessibilityActionError.controllerProtected }
        if let app = NSRunningApplication(processIdentifier: pid),
           app.bundleIdentifier == Bundle.main.bundleIdentifier {
            throw AccessibilityActionError.controllerProtected
        }
    }

    private func ensureAllowedOnDisplay(
        _ pid: pid_t,
        display: DisplayDescriptor
    ) throws {
        try ensureAllowed(pid)
        guard hasWindow(of: pid, intersecting: display.frame) else {
            throw AccessibilityActionError.operationFailed(
                "The target app is no longer on the assigned agent screen; observe again before acting"
            )
        }
    }

    private func ensurePointerTarget(
        _ pid: pid_t,
        at point: CGPoint,
        display: DisplayDescriptor
    ) throws {
        try ensureAllowedOnDisplay(pid, display: display)
        if pointerTargetIsVisible(pid, at: point, display: display) {
            return
        }

        // App activation and AXRaise are asynchronous. If the requested point
        // is genuinely inside the target app's current window, allow one
        // native z-order recovery before rejecting it. This never clamps or
        // redirects clicks: points outside the intended app still fail closed.
        if Self.pointerVisibilityRecoveryIsSafe(
            point: point,
            displayFrame: display.frame,
            targetWindowFrames: targetWindowFrames(of: pid),
            targetPID: pid,
            topmostPID: topmostWindowOwnerPID(at: point)
        ) {
            _ = NSRunningApplication(processIdentifier: pid)?.activate(
                options: [.activateAllWindows]
            )
            for window in windows(of: pid)
                where frame(of: window)?.contains(point) == true {
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
            Thread.sleep(forTimeInterval: 0.12)
            if pointerTargetIsVisible(pid, at: point, display: display) {
                return
            }
        }


        agentCursor?.hide()
        throw AccessibilityActionError.operationFailed(
            "The requested pointer location is not visibly on that app in the assigned agent screen; observe again before clicking"
        )
    }

    static func pointerVisibilityRecoveryIsSafe(
        point: CGPoint,
        displayFrame: CGRect,
        targetWindowFrames: [CGRect],
        targetPID: pid_t,
        topmostPID: pid_t?
    ) -> Bool {
        displayFrame.insetBy(dx: -0.5, dy: -0.5).contains(point) &&
        targetWindowFrames.contains(where: { $0.contains(point) }) &&
        topmostPID != targetPID
    }

    private func targetWindowFrames(of pid: pid_t) -> [CGRect] {
        let accessibilityFrames = windows(of: pid).compactMap { frame(of: $0) }
        return accessibilityFrames + cgWindowFrames(of: pid)
    }

    private func pointerTargetIsVisible(
        _ pid: pid_t,
        at point: CGPoint,
        display: DisplayDescriptor
    ) -> Bool {
        if ownedMenuContains(pid, point: point, display: display) { return true }
        return display.frame.insetBy(dx: -0.5, dy: -0.5).contains(point) &&
        hasWindow(of: pid, containing: point) &&
        topmostWindowOwnerPID(at: point) == pid
    }

    private func ownedMenuContains(_ pid: pid_t, point: CGPoint, display: DisplayDescriptor) -> Bool {
        guard display.frame.contains(point),
              NSRunningApplication(processIdentifier: pid)?.ownsMenuBar == true else { return false }
        lock.lock()
        let records = elementMap.values.filter { $0.pid == pid && $0.role.hasPrefix("AXMenu") }
        lock.unlock()
        return records.contains { frame(of: $0.element)?.contains(point) == true }
    }

    static func clampedPointerPoint(
        preferred: CGPoint,
        windowFrame: CGRect,
        displayFrame: CGRect,
        inset: CGFloat = 8
    ) -> CGPoint? {
        let visible = windowFrame.intersection(displayFrame)
        guard !visible.isNull, !visible.isInfinite,
              visible.width > 0, visible.height > 0 else { return nil }
        let dx = min(inset, max(0, visible.width / 3))
        let dy = min(inset, max(0, visible.height / 3))
        let safe = visible.insetBy(dx: dx, dy: dy)
        let target = safe.width > 0 && safe.height > 0 ? safe : visible
        return CGPoint(
            x: min(target.maxX, max(target.minX, preferred.x)),
            y: min(target.maxY, max(target.minY, preferred.y))
        )
    }

    private func resolvedScrollPoint(
        for pid: pid_t,
        preferred: CGPoint,
        display: DisplayDescriptor
    ) throws -> CGPoint {
        if pointerTargetIsVisible(pid, at: preferred, display: display) {
            return preferred
        }

        let frames = targetWindowFrames(of: pid).sorted {
            $0.width * $0.height > $1.width * $1.height
        }
        for windowFrame in frames {
            let visible = windowFrame.intersection(display.frame)
            guard !visible.isNull, visible.width > 0, visible.height > 0,
                  let clamped = Self.clampedPointerPoint(
                      preferred: preferred,
                      windowFrame: windowFrame,
                      displayFrame: display.frame
                  ) else { continue }
            let candidates = [
                clamped,
                CGPoint(x: visible.midX, y: visible.midY),
                CGPoint(x: visible.minX + visible.width * 0.22, y: visible.midY),
                CGPoint(x: visible.maxX - visible.width * 0.22, y: visible.midY)
            ]
            if let candidate = candidates.first(where: {
                pointerTargetIsVisible(pid, at: $0, display: display)
            }) {
                return candidate
            }
        }

        try ensurePointerTarget(pid, at: preferred, display: display)
        return preferred
    }

    private func topmostWindowOwnerPID(at point: CGPoint) -> pid_t? {
        let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        for row in rows {
            guard let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = row[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let boundsDictionary = row[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                  ),
                  bounds.contains(point) else { continue }
            let pid = pid_t(owner.intValue)
            // Event delivery must use the real z-order, including controller
            // windows that capture omits. Otherwise a foreground event could
            // hit an occluding controller instead of the validated app.
            return pid
        }
        return nil
    }

    private func point(from action: [String: Any], display: DisplayDescriptor) throws -> CGPoint {
        guard let nx = doubleValue(action["x"]), let ny = doubleValue(action["y"]),
              (0...1000).contains(nx), (0...1000).contains(ny) else {
            throw AccessibilityActionError.invalidAction("Coordinates must be normalized from 0 through 1000")
        }
        return CGPoint(
            x: display.frame.minX + display.frame.width * nx / 1000,
            y: display.frame.minY + display.frame.height * ny / 1000
        )
    }

    // MARK: - Validated input delivery

    private func postClick(
        to pid: pid_t,
        point: CGPoint,
        double: Bool,
        on display: DisplayDescriptor,
        preflight: () throws -> Void = {}
    ) throws {
        let previouslyActiveApp = activateForTargetedInput(pid)
        defer { restoreFrontmostApplication(previouslyActiveApp, after: 0.10, targetPID: pid) }
        // Bring the intended app forward before validating z-order. Validating
        // first rejected correct coordinates whenever the previous foreground
        // app temporarily covered a window that TaskPilot was about to target.
        try ensurePointerTarget(pid, at: point, display: display)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw AccessibilityActionError.activationFailed
        }
        agentCursor?.move(to: point, on: display, clicking: true)
        func finalPreflight() throws {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                throw AccessibilityActionError.activationFailed
            }
            guard pointerTargetIsVisible(pid, at: point, display: display) else {
                throw AccessibilityActionError.staleObservation
            }
            try preflight()
        }

        // iOS-on-Mac wrappers (including BASEBALL 9) discard events delivered
        // only to their process queue. Use the real HID event tap for those
        // wrappers, then immediately put the user's physical pointer back.
        if requiresHIDFallback(pid) {
            try postHIDClick(at: point, double: double, preflight: finalPreflight)
            return
        }

        // The WindowServer session route performs AppKit's hit testing. A
        // process queue accepts mouse events without delivering them to views.
        // Use exactly one route, after verifying the foreground and target.
        try postSessionClick(at: point, double: double, preflight: finalPreflight)
        // Catalyst/iOS-on-Mac apps can discard an instantaneous background
        // mouse sequence. Give their event loop one frame to consume the
        // targeted events before restoring whatever app the user was using.
        Thread.sleep(forTimeInterval: 0.020)
    }

    private func requiresHIDFallback(_ pid: pid_t) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else {
            return false
        }
        if url.path.lowercased().contains("/wrapper/") { return true }
        return (Bundle(url: url)?.object(forInfoDictionaryKey: "LSRequiresIPhoneOS") as? Bool) == true
    }

    private func postHIDClick(at point: CGPoint, double: Bool, preflight: () throws -> Void) throws {
        try postSessionClick(at: point, double: double, tap: .cghidEventTap, preflight: preflight)
    }

    private func postSessionClick(at point: CGPoint, double: Bool, tap: CGEventTapLocation = .cgSessionEventTap,
                                  preflight: () throws -> Void) throws {
        let originalPointer = CGEvent(source: nil)?.location
        defer {
            if let originalPointer {
                CGWarpMouseCursorPosition(originalPointer)
            }
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            throw AccessibilityActionError.operationFailed("Could not create a HID mouse event")
        }
        source.localEventsSuppressionInterval = 0
        move.post(tap: tap)
        Thread.sleep(forTimeInterval: 0.008)
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        try AutomationTargetPolicy.deliver(preflight: preflight, event: { down.post(tap: tap) })
        Thread.sleep(forTimeInterval: Self.hidClickPressDuration)
        up.post(tap: tap)
        if double {
            Thread.sleep(forTimeInterval: 0.060)
            down.setIntegerValueField(.mouseEventClickState, value: 2)
            up.setIntegerValueField(.mouseEventClickState, value: 2)
            down.post(tap: tap)
            Thread.sleep(forTimeInterval: Self.hidClickPressDuration)
            up.post(tap: tap)
        }
        // iOS game result screens sometimes process the tap on the next run
        // loop turn. Keep the pointer over the target briefly before restoring
        // the user's physical cursor so the game does not discard the release.
        Thread.sleep(forTimeInterval: Self.hidClickReleaseSettleDuration)
    }

    private func postDrag(
        to pid: pid_t,
        from start: CGPoint,
        to end: CGPoint,
        on display: DisplayDescriptor
    ) throws {
        let previouslyActiveApp = activateForTargetedInput(pid)
        defer { restoreFrontmostApplication(previouslyActiveApp, after: 0.05, targetPID: pid) }
        try ensurePointerTarget(pid, at: start, display: display)
        guard display.frame.insetBy(dx: -0.5, dy: -0.5).contains(end) else {
            throw AccessibilityActionError.operationFailed(
                "The drag endpoint is outside the assigned agent screen"
            )
        }
        agentCursor?.move(to: start, on: display, clicking: true)
        let useHID = requiresHIDFallback(pid)
        let sourceID: CGEventSourceStateID = useHID ? .hidSystemState : .privateState
        guard let source = CGEventSource(stateID: sourceID),
              let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: start, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: start, mouseButton: .left),
              let dragged = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                                    mouseCursorPosition: end, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: end, mouseButton: .left) else {
            throw AccessibilityActionError.operationFailed("Could not create a drag event")
        }
        source.localEventsSuppressionInterval = 0
        let originalPointer = useHID ? CGEvent(source: nil)?.location : nil
        defer {
            if let originalPointer { CGWarpMouseCursorPosition(originalPointer) }
        }
        let events = [move, down, dragged, up]
        for (index, event) in events.enumerated() {
            if useHID { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
            if index < events.count - 1 { Thread.sleep(forTimeInterval: 0.020) }
        }
        agentCursor?.move(to: end, on: display, clicking: false)
    }

    private func postUnicode(_ text: String, to pid: pid_t, preflight: () throws -> Void = {}) throws {
        let previouslyActiveApp = activateForTargetedInput(pid)
        defer { restoreFrontmostApplication(previouslyActiveApp, after: 0.05, targetPID: pid) }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw AccessibilityActionError.operationFailed("Could not create a keyboard event")
        }
        try AutomationTextEntryPolicy.deliverChunks(text.chunked(maxUTF16Count: 40), preflight: preflight,
            cancelled: { self.inputIsCancelled() }) { chunk in
            let units = Array(chunk.utf16)
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            }
            down.postToPid(pid)
            Thread.sleep(forTimeInterval: 0.012)
            up.postToPid(pid)
        }
        Thread.sleep(forTimeInterval: 0.035)
    }

    private func postKey(_ key: String, modifiers: [String], to pid: pid_t, preflight: () throws -> Void = {}) throws {
        let previouslyActiveApp = activateForTargetedInput(pid)
        defer { restoreFrontmostApplication(previouslyActiveApp, after: 0.05, targetPID: pid) }
        guard let code = Self.supportedKeyCodes[key.lowercased()],
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw AccessibilityActionError.invalidAction("Unsupported key: \(key)")
        }
        var flags: CGEventFlags = []
        for modifier in modifiers.map({ $0.lowercased() }) {
            switch modifier {
            case "command", "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            default: break
            }
        }
        down.flags = flags
        up.flags = flags
        try AutomationTargetPolicy.deliver(preflight: preflight, event: { down.postToPid(pid) })
        Thread.sleep(forTimeInterval: 0.018)
        up.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.035)
    }

    private func postRawKey(
        _ keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        to pid: pid_t
    ) throws {
        let previouslyActiveApp = activateForTargetedInput(pid)
        defer { restoreFrontmostApplication(previouslyActiveApp, after: 0.04, targetPID: pid) }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw AccessibilityActionError.operationFailed("Could not create a keyboard event")
        }
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.012)
        up.postToPid(pid)
    }

    @discardableResult
    private func postScroll(
        to pid: pid_t,
        point: CGPoint,
        deltaX: Int,
        deltaY: Int,
        on display: DisplayDescriptor
    ) throws -> Bool {
        let previouslyActiveApp = activateForTargetedInput(pid)
        defer { restoreFrontmostApplication(previouslyActiveApp, after: 0.05, targetPID: pid) }
        let resolvedPoint = try resolvedScrollPoint(
            for: pid,
            preferred: point,
            display: display
        )
        agentCursor?.move(to: resolvedPoint, on: display, clicking: false)
        guard let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(clamping: deltaY),
                wheel2: Int32(clamping: deltaX),
                wheel3: 0
              ) else {
            throw AccessibilityActionError.operationFailed("Could not create a scroll event")
        }
        let originalPointer = CGEvent(source: nil)?.location
        defer { if let originalPointer { CGWarpMouseCursorPosition(originalPointer) } }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw AccessibilityActionError.activationFailed
        }
        let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                           mouseCursorPosition: resolvedPoint, mouseButton: .left)
        move?.post(tap: .cgSessionEventTap)
        Thread.sleep(forTimeInterval: 0.025)
        event.location = resolvedPoint
        event.post(tap: .cgSessionEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        return resolvedPoint != point
    }

    // MARK: - Accessibility helpers

    private func controllableRunningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != controllerPID &&
            !$0.isTerminated &&
            $0.activationPolicy == .regular &&
            $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
    }

    /// Returns apps in actual window z-order for the assigned display. This
    /// makes the active website/app context reach the model before background
    /// applications when the accessibility tree approaches its size limit.
    private func orderedApplicationsForSnapshot(
        on display: DisplayDescriptor
    ) -> [NSRunningApplication] {
        let applications = controllableRunningApplications()
        let byPID = Dictionary(
            uniqueKeysWithValues: applications.map { ($0.processIdentifier, $0) }
        )
        let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        var seen: Set<pid_t> = []
        var ordered: [NSRunningApplication] = []

        for row in rows {
            guard let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = row[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let boundsDictionary = row[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                  ),
                  bounds.intersects(display.frame) else { continue }
            let pid = pid_t(owner.intValue)
            guard !seen.contains(pid), let application = byPID[pid] else { continue }
            seen.insert(pid)
            ordered.append(application)
        }

        ordered.append(contentsOf: applications
            .filter { !seen.contains($0.processIdentifier) }
            .sorted {
                ($0.localizedName ?? "").localizedCaseInsensitiveCompare(
                    $1.localizedName ?? ""
                ) == .orderedAscending
            })
        let remembered = lock.withLock { manualTargetPID }
        if let remembered, let index = ordered.firstIndex(where: { $0.processIdentifier == remembered }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        return ordered
    }

    private func windows(of pid: pid_t) -> [AXUIElement] {
        guard pid != controllerPID else { return [] }
        let root = AXUIElementCreateApplication(pid)
        return attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    private func hasWindow(of pid: pid_t, intersecting targetFrame: CGRect) -> Bool {
        if windows(of: pid).contains(where: {
            frame(of: $0)?.intersects(targetFrame) == true
        }) {
            return true
        }
        return cgWindowFrames(of: pid).contains(where: { $0.intersects(targetFrame) })
    }

    private func hasWindow(of pid: pid_t, containing point: CGPoint) -> Bool {
        if windows(of: pid).contains(where: { frame(of: $0)?.contains(point) == true }) {
            return true
        }
        return cgWindowFrames(of: pid).contains(where: { $0.contains(point) })
    }

    private func cgWindowFrames(of pid: pid_t) -> [CGRect] {
        graphicsWindows(of: pid).map(\.frame)
    }

    private func graphicsWindows(of pid: pid_t) -> [AutomationGraphicsWindow] {
        let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
                  pid_t(owner.intValue) == pid,
                  let layer = row[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let id = row[kCGWindowNumber as String] as? NSNumber,
                  let boundsDictionary = row[kCGWindowBounds as String] as? [String: Any]
            else { return nil }
            guard let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { return nil }
            return AutomationGraphicsWindow(id: id.uint32Value, title: row[kCGWindowName as String] as? String ?? "", frame: frame)
        }
    }

    /// Some sandboxed, Catalyst, and iOS-on-Mac apps only accept a targeted
    /// CGEvent while they are frontmost. Activation does not move the hardware
    /// cursor; TaskPilot restores the user's previous app immediately after the
    /// target has consumed the event.
    private func activateForTargetedInput(_ pid: pid_t) -> NSRunningApplication? {
        guard let target = NSRunningApplication(processIdentifier: pid),
              !target.isTerminated,
              !target.isActive else { return nil }

        let previous = NSWorkspace.shared.frontmostApplication
        target.activate(options: [.activateAllWindows])
        // Agent actions have already awaited confirmed activation in
        // beginVerifiedInput. Viewer input must never block the main run loop.
        return previous?.processIdentifier == pid ? nil : previous
    }

    private func restoreFrontmostApplication(
        _ application: NSRunningApplication?,
        after delay: TimeInterval,
        targetPID: pid_t
    ) {
        guard let application,
              application.processIdentifier != controllerPID,
              !application.isTerminated else { return }
        lock.lock()
        let generation = inputGeneration
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let currentGeneration = self.inputGeneration
            self.lock.unlock()
            guard !application.isTerminated,
                  AutomationInputPolicy.shouldRestore(scheduledGeneration: generation, currentGeneration: currentGeneration,
                    targetPID: targetPID, currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                    previousPID: application.processIdentifier), !self.hasOpenMenu(targetPID) else { return }
            application.activate(options: [.activateAllWindows])
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func accessibilityElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func elementTitle(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { stringAttribute(element, $0) }.first { !$0.isEmpty } ?? ""
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        attribute(element, name) as? Bool
    }

    private func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(element, kAXPositionAttribute),
              let size = sizeAttribute(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func printableValue(_ value: AnyObject?) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }

    private func clipped(_ value: String) -> String {
        String(value.prefix(240))
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}

private extension String {
    func chunked(maxUTF16Count: Int) -> [String] {
        guard utf16.count > maxUTF16Count else { return [self] }
        var result: [String] = []
        var current = ""
        var count = 0
        for character in self {
            let length = String(character).utf16.count
            if count + length > maxUTF16Count, !current.isEmpty {
                result.append(current)
                current = ""
                count = 0
            }
            current.append(character)
            count += length
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
