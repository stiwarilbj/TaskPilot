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
    let resultDestinations: [[String: Any]]
    let installedApplications: [[String: Any]]
    let systemContext: [String: Any]
    let completeness: [String: Any]
    let workingDocument: [String: Any]?

    init(revision: String, elements: [[String: Any]], applications: [[String: Any]],
         resultDestinations: [[String: Any]], installedApplications: [[String: Any]],
         systemContext: [String: Any], completeness: [String: Any],
         workingDocument: [String: Any]? = nil) {
        self.revision = revision
        self.elements = elements
        self.applications = applications
        self.resultDestinations = resultDestinations
        self.installedApplications = installedApplications
        self.systemContext = systemContext
        self.completeness = completeness
        self.workingDocument = workingDocument
    }
}

struct StagedAccessibilitySnapshot {
    let snapshot: AccessibilitySnapshot
    let consistencySignature: String
    let publish: () throws -> Void
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
    case ambiguousTarget
    case workingDocumentLost
    case workingDocumentTargetMismatch

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
        case .ambiguousTarget: return "ambiguous_target"
        case .controllerProtected: return "protected_target"
        case .workingDocumentLost: return "working_document_lost"
        case .workingDocumentTargetMismatch: return "working_document_target_mismatch"
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
        case .ambiguousTarget: return "These coordinates match multiple controls; observe their app, window, and panel and select one complete element ID"
        case .workingDocumentLost: return "The selected document window disappeared or changed. Choose the working document again before continuing."
        case .workingDocumentTargetMismatch: return "This action targets a different window than the selected working document. Observe the current window and choose the intended document."
        }
    }
}

final class AccessibilityController {
    // MARK: - Configuration and state

    static let hidClickPressDuration: TimeInterval = 0.055
    static let hidClickReleaseSettleDuration: TimeInterval = 0.10
    static let supportedKeyCodes: [String: CGKeyCode] = ActionContract.keyCodes

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
        let supportsActions: Bool
        let wasFocused: Bool
        let observedTextValue: String?
        let observedSelection: NSRange?
        var pid: pid_t { identity.application.pid }
        var role: String { identity.role }
        var observedBounds: CGRect? { identity.bounds }
    }

    private struct SnapshotWindowRecord {
        let element: AXUIElement
        let id: String
        let focused: Bool
        let topmost: Bool
        let frame: CGRect
    }

    private struct ObservationNode {
        let element: AXUIElement
        let pid: pid_t
        let appName: String
        let application: AutomationApplicationIdentity
        let focusedElement: AXUIElement?
        let ownerWindow: AXUIElement?
        let windowRecords: [SnapshotWindowRecord]
        func child(_ element: AXUIElement) -> Self {
            Self(element: element, pid: pid, appName: appName, application: application,
                 focusedElement: focusedElement, ownerWindow: ownerWindow, windowRecords: windowRecords)
        }
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
    private let compatibilityProfiles: ControlCompatibilityProfiles
    private var elementMap: [String: ElementRecord] = [:]
    private var observationRevision = ""
    private var observationCoordinates: ScreenCoordinateMapping?
    private var observationMagnifierSource: (revision: String, displayID: CGDirectDisplayID, source: AgentMagnifierImageSource)?
    private var actionMagnifierSequence: UInt64 = 0
    private var activeMagnifierAction: (actionID: String, generationID: String, sequence: UInt64)?
    var onActionMagnifierEvent: ((AgentActionMagnifierEvent) -> Void)?
    private var observationTaskGenerationID: String?
    private var observedGraphicsWindows: [pid_t: [AutomationGraphicsWindow]] = [:]
    private var observedApplications: [pid_t: AutomationApplicationIdentity] = [:]
    private var taskLease: TaskLease?
    private var discoveryGraph: NativeGraphSession?
    private var teardownForeground: (NSRunningApplication, pid_t)?
    private var taskGenerationID: String?
    private var workingDocumentSelections: [String: WorkingDocumentSelectionRecord] = [:]
    private var workingDocumentBinding: WorkingDocumentNativeBinding?
    private var inputGeneration = 0
    private var inputCancelled = false
    private var restoreWorkItem: DispatchWorkItem?
    private var previousInputApplication: NSRunningApplication?
    private var inputTargetPID: pid_t?
    private var manualTargetPID: pid_t?
    private var taskApplicationBaseline: TaskApplicationBaseline?
    private var taskDisplayOverrideID: CGDirectDisplayID?
    private let controllerPID = getpid()
    private let passiveLaunchWait: Duration = .seconds(4)
    private let activatedLaunchWait: Duration = .seconds(16)
    private lazy var installedApplicationEntries = discoverInstalledApplications()

    init(agentCursor: AgentCursorOverlayController? = nil, compatibilityProfiles: ControlCompatibilityProfiles? = nil) {
        self.agentCursor = agentCursor
        self.compatibilityProfiles = compatibilityProfiles ?? ControlCompatibilityProfiles(
            fileURL: ControlCompatibilityProfiles.defaultFileURL, environment: Self.compatibilityEnvironment())
    }

    func hideAgentCursor() {
        agentCursor?.hide()
    }

    /// Records the apps and windows that existed before a task. Cleanup can
    /// then preserve every pre-existing item, close only new windows on the
    /// assigned display, and quit only apps launched through TaskPilot's own
    /// `launch_app` action.
    // MARK: - Task resource tracking

    func beginTaskResourceTracking(on display: DisplayDescriptor, lease: TaskLease? = nil) {
        resetInputCancellation()
        let applications = controllableRunningApplications()
        var windowsByPID: [pid_t: [AXUIElement]] = [:]
        for application in applications {
            windowsByPID[application.processIdentifier] = windows(
                of: application.processIdentifier
            )
        }

        lock.lock()
        let previousGraph = discoveryGraph
        discoveryGraph = lease.map { NativeGraphSession(lease: $0) }
        taskLease = lease
        taskGenerationID = lease?.id
        elementMap.removeAll(); observationRevision = ""; observationCoordinates = nil
        observationMagnifierSource = nil
        actionMagnifierSequence = 0; activeMagnifierAction = nil
        manualTargetPID = nil
        workingDocumentSelections.removeAll()
        workingDocumentBinding = nil
        taskDisplayOverrideID = nil
        taskApplicationBaseline = TaskApplicationBaseline(
            display: display,
            runningPIDs: Set(applications.map(\.processIdentifier)),
            windowsByPID: windowsByPID,
            agentLaunchedPIDs: []
        )
        lock.unlock()
        previousGraph?.close()
    }

    func workingDocumentCandidates(on display: DisplayDescriptor) -> [WorkingDocumentCandidate] {
        guard AXIsProcessTrusted() else { return [] }
        var candidates: [WorkingDocumentCandidate] = []
        let apps = orderedApplicationsForSnapshot(on: display)
        for app in apps {
            let pid = app.processIdentifier
            guard pid != controllerPID, app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  let launchDate = app.launchDate,
                  let bundleID = app.bundleIdentifier else { continue }
            let appElement = AXUIElementCreateApplication(pid)
            let appWindows = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let focusedWindow = accessibilityElement(appElement, kAXFocusedWindowAttribute)
            let graphics = graphicsWindows(of: pid)
            let identity = applicationIdentity(app)
            for window in appWindows {
                guard let frame = frame(of: window), frame.intersects(display.frame) else { continue }
                let title = stringAttribute(window, kAXTitleAttribute) ?? ""
                let documentURL = Self.workingDocumentURL(
                    attribute(window, kAXDocumentAttribute) ?? attribute(window, kAXURLAttribute)
                )
                let windowGraphics = graphics.max { lhs, rhs in
                    Self.intersectionArea(lhs.frame, frame) < Self.intersectionArea(rhs.frame, frame)
                }
                let graphicsID = windowGraphics.flatMap {
                    Self.intersectionArea($0.frame, frame) > 0 ? $0.id : nil
                }
                let selectionID = UUID().uuidString.lowercased()
                let candidate = WorkingDocumentCandidate(
                    selectionID: selectionID,
                    displayID: display.id,
                    pid: pid,
                    bundleID: bundleID,
                    processLaunchTime: launchDate.timeIntervalSince1970,
                    applicationName: app.localizedName ?? "Unknown app",
                    title: title,
                    location: documentURL.flatMap(Self.workingDocumentLocation),
                    documentURL: documentURL?.absoluteString,
                    accessibilityIdentity: String(CFHash(window)),
                    graphicsWindowID: graphicsID,
                    focused: focusedWindow.map { CFEqual($0, window) } == true && app.isActive
                )
                let record = WorkingDocumentSelectionRecord(candidate: candidate, window: window,
                    application: identity, documentURL: documentURL,
                    expiresAt: ProcessInfo.processInfo.systemUptime + 90)
                candidates.append(candidate)
                lock.withLock {
                    workingDocumentSelections = workingDocumentSelections.filter {
                        $0.value.expiresAt > ProcessInfo.processInfo.systemUptime
                    }
                    workingDocumentSelections[selectionID] = record
                }
            }
        }
        return candidates.sorted {
            if $0.focused != $1.focused { return $0.focused }
            let appOrder = $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName)
            if appOrder != .orderedSame { return appOrder == .orderedAscending }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func prepareWorkingDocumentBinding(selectionID: String?, generationID: String,
                                       revision: UInt64) throws -> WorkingDocumentNativeBinding? {
        guard lock.withLock({ taskGenerationID == generationID }) else { throw WorkingDocumentUpdateError.stale }
        guard let selectionID else { return nil }
        let selection = lock.withLock { workingDocumentSelections[selectionID] }
        guard let selection, selection.expiresAt >= ProcessInfo.processInfo.systemUptime else {
            throw WorkingDocumentUpdateError.unavailable
        }
        guard let app = NSRunningApplication(processIdentifier: selection.candidate.pid), !app.isTerminated,
              app.bundleIdentifier == selection.candidate.bundleID,
              app.bundleURL?.path == selection.application.bundlePath,
              abs((app.launchDate?.timeIntervalSince1970 ?? 0) - selection.candidate.processLaunchTime) < 0.01,
              let retainedWindow = windows(of: selection.candidate.pid).first(where: { CFEqual($0, selection.window) }) else {
            throw WorkingDocumentUpdateError.unavailable
        }
        let currentURL = Self.workingDocumentURL(
            attribute(retainedWindow, kAXDocumentAttribute) ?? attribute(retainedWindow, kAXURLAttribute)
        )
        if let expected = selection.documentURL?.absoluteString,
           currentURL?.absoluteString != expected {
            throw WorkingDocumentUpdateError.unavailable
        }
        let currentFrame = frame(of: retainedWindow)
        let graphicsID = currentFrame.flatMap { frame in
            graphicsWindows(of: selection.candidate.pid).max {
                Self.intersectionArea($0.frame, frame) < Self.intersectionArea($1.frame, frame)
            }.flatMap { Self.intersectionArea($0.frame, frame) > 0 ? $0.id : nil }
        }
        if let expected = selection.candidate.graphicsWindowID, let graphicsID,
           expected != graphicsID, currentURL == nil {
            throw WorkingDocumentUpdateError.unavailable
        }
        return WorkingDocumentNativeBinding(generationID: generationID, revision: revision,
            pid: selection.candidate.pid, application: selection.application, window: retainedWindow,
            accessibilityIdentity: selection.candidate.accessibilityIdentity,
            graphicsWindowID: graphicsID ?? selection.candidate.graphicsWindowID,
            title: stringAttribute(retainedWindow, kAXTitleAttribute) ?? selection.candidate.title,
            location: currentURL.flatMap(Self.workingDocumentLocation), documentURL: currentURL,
            displayID: selection.candidate.displayID)
    }

    func installWorkingDocumentBinding(_ binding: WorkingDocumentNativeBinding?, generationID: String) {
        lock.withLock {
            guard taskGenerationID == generationID else { return }
            workingDocumentBinding = binding
        }
    }

    func workingDocumentInfo(generationID: String) -> [String: Any]? {
        guard let binding = lock.withLock({ workingDocumentBinding }), binding.generationID == generationID else { return nil }
        let state = refreshWorkingDocumentBinding(binding)
        guard let active = state.binding else {
            return ["state": "needs_reselection", "application": binding.application.name ?? "Unknown app",
                    "title": binding.title, "revision": Int(binding.revision)]
        }
        if state.changed { installWorkingDocumentBinding(active, generationID: generationID) }
        return ["state": "active", "application": active.application.name ?? "Unknown app",
                "title": active.title,
                "location": active.location as Any? ?? NSNull(),
                "revision": Int(active.revision),
                "pid": Int(active.pid),
                "bundle_id": active.application.bundleID ?? "",
                "accessibility_identity": active.accessibilityIdentity]
    }

    private func isWorkingDocumentWindow(_ element: AXUIElement, pid: pid_t, generationID: String) -> Bool {
        lock.withLock {
            guard let binding = workingDocumentBinding,
                  binding.generationID == generationID,
                  binding.pid == pid else { return false }
            return CFEqual(binding.window, element)
        }
    }

    private func refreshWorkingDocumentBinding(_ binding: WorkingDocumentNativeBinding)
        -> (binding: WorkingDocumentNativeBinding?, changed: Bool) {
        guard let app = NSRunningApplication(processIdentifier: binding.pid), !app.isTerminated,
              app.bundleIdentifier == binding.application.bundleID,
              binding.application.bundlePath == nil || app.bundleURL?.path == binding.application.bundlePath,
              abs((app.launchDate?.timeIntervalSince1970 ?? 0) - (binding.application.launchDate?.timeIntervalSince1970 ?? 0)) < 0.01 else {
            return (nil, false)
        }
        let appWindows = windows(of: binding.pid)
        if let retained = appWindows.first(where: { CFEqual($0, binding.window) }) {
            let currentURL = Self.workingDocumentURL(
                attribute(retained, kAXDocumentAttribute) ?? attribute(retained, kAXURLAttribute)
            )
            guard binding.documentURL == nil || currentURL?.absoluteString == binding.documentURL?.absoluteString else {
                return rediscoverWorkingDocument(binding, in: appWindows)
            }
            let currentGraphicsID = frame(of: retained).flatMap { target in
                graphicsWindows(of: binding.pid).max {
                    Self.intersectionArea($0.frame, target) < Self.intersectionArea($1.frame, target)
                }.flatMap { Self.intersectionArea($0.frame, target) > 0 ? $0.id : nil }
            }
            if let expected = binding.graphicsWindowID, let currentGraphicsID, expected != currentGraphicsID {
                guard binding.documentURL != nil else { return (nil, false) }
                return rediscoverWorkingDocument(binding, in: appWindows)
            }
            return (binding, false)
        }
        return rediscoverWorkingDocument(binding, in: appWindows)
    }

    private func rediscoverWorkingDocument(_ binding: WorkingDocumentNativeBinding, in windows: [AXUIElement])
        -> (binding: WorkingDocumentNativeBinding?, changed: Bool) {
        guard let url = binding.documentURL else { return (nil, false) }
        let matches = windows.filter {
            Self.workingDocumentURL(attribute($0, kAXDocumentAttribute) ?? attribute($0, kAXURLAttribute))?.absoluteString == url.absoluteString
        }
        guard matches.count == 1, let window = matches.first else { return (nil, false) }
        let frame = frame(of: window)
        let graphicsID = frame.flatMap { target in graphicsWindows(of: binding.pid).max {
            Self.intersectionArea($0.frame, target) < Self.intersectionArea($1.frame, target)
        }.flatMap { Self.intersectionArea($0.frame, target) > 0 ? $0.id : nil } }
        return (WorkingDocumentNativeBinding(generationID: binding.generationID, revision: binding.revision,
            pid: binding.pid, application: binding.application, window: window,
            accessibilityIdentity: String(CFHash(window)), graphicsWindowID: graphicsID,
            title: stringAttribute(window, kAXTitleAttribute) ?? binding.title,
            location: Self.workingDocumentLocation(url), documentURL: url, displayID: binding.displayID), true)
    }

    private static func workingDocumentURL(_ value: Any?) -> URL? {
        let raw: String?
        if let value = value as? String { raw = value }
        else if let value = value as? URL { raw = value.absoluteString }
        else if let value = value as? NSURL { raw = value.absoluteString }
        else { raw = nil }
        guard let raw, !raw.isEmpty, raw.utf8.count <= 4096,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["file", "http", "https"].contains(scheme) else { return nil }
        return url
    }

    private static func workingDocumentLocation(_ url: URL) -> String? {
        if url.isFileURL { return url.standardizedFileURL.path }
        guard let host = url.host else { return nil }
        return host + (url.path.isEmpty ? "" : url.path)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull || intersection.isEmpty ? 0 : intersection.width * intersection.height
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
        let foreground = teardownForeground
        teardownForeground = nil
        let endingGraph = discoveryGraph; discoveryGraph = nil
        taskLease = nil
        taskApplicationBaseline = nil
        taskGenerationID = nil
        elementMap.removeAll(); observationRevision = ""; observationCoordinates = nil
        observationMagnifierSource = nil
        activeMagnifierAction = nil
        manualTargetPID = nil
        workingDocumentSelections.removeAll()
        workingDocumentBinding = nil
        taskDisplayOverrideID = nil
        lock.unlock()

        endingGraph?.close()
        if let (previous, target) = foreground, !previous.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == target {
            _ = ownedActivate(previous)
        }
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
                if ownedAXPress(
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

    // Legacy/manual snapshot callers retain immediate publication. Task
    // observations use stageSnapshot and explicitly commit the accepted pair.
    func snapshot(on display: DisplayDescriptor) -> AccessibilitySnapshot {
        guard let staged = try? stageSnapshot(on: display) else {
            return AccessibilitySnapshot(revision: "", elements: [], applications: [], resultDestinations: [],
                installedApplications: [], systemContext: [:],
                completeness: ["version": 1, "state": "partial", "reason_counts": ["collection_failed": 1]],
                workingDocument: nil)
        }
        try? staged.publish()
        return staged.snapshot
    }

    func invalidateObservation() throws {
        try TaskOwnership.commit {
            lock.withLock {
                elementMap.removeAll()
                observationRevision = ""
                observationCoordinates = nil
                observedGraphicsWindows.removeAll()
                observedApplications.removeAll()
            }
        }
    }

    /// Fresh Core Graphics z-order, including transient app windows. Never use
    /// ScreenCaptureKit's content cache as evidence that the layout is stable.
    func observationScene(on display: DisplayDescriptor) throws -> String {
        try TaskOwnership.check()
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let applications = controllableRunningApplications()
        let byPID = Dictionary(uniqueKeysWithValues: applications.map { ($0.processIdentifier, $0) })
        var ordered: [[String: Any]] = []
        for row in windows {
            guard let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let app = byPID[pid_t(owner.intValue)],
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rectangle.intersects(display.frame), serializedAccessibilityFrame(rectangle) != nil else { continue }
            let identity = applicationIdentity(app)
            ordered.append([
                "pid": owner.intValue, "bundle": identity.bundleID ?? "",
                "path": identity.bundlePath ?? "", "launch": identity.launchDate?.timeIntervalSince1970 ?? 0,
                "window": row[kCGWindowNumber as String] as? NSNumber ?? 0,
                "layer": row[kCGWindowLayer as String] as? NSNumber ?? 0,
                "title": row[kCGWindowName as String] as? String ?? "",
                "frame": [rectangle.minX, rectangle.minY, rectangle.width, rectangle.height],
                "active": app.isActive
            ])
        }
        let scene: [String: Any] = ["display": Int(display.id),
            "pixels": [CGDisplayPixelsWide(display.id), CGDisplayPixelsHigh(display.id)],
            "frame": [display.frame.minX, display.frame.minY, display.frame.width, display.frame.height],
            "windows": ordered]
        return String(decoding: try JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys]), as: UTF8.self)
    }

    func stageSnapshot(on display: DisplayDescriptor, keywords: [String] = [], budget: TimeInterval = 1.5, forceFreshTopology: Bool = true) throws -> StagedAccessibilitySnapshot {
        var graph: NativeGraphSession?
        if let lease = TaskOwnership.current {
            var ending: NativeGraphSession?
            graph = lock.withLock {
                guard taskLease === lease else { return nil }
                if discoveryGraph?.matches(lease) != true {
                    ending = discoveryGraph; discoveryGraph = NativeGraphSession(lease: lease)
                }
                return discoveryGraph
            }
            ending?.close()
        }
        try LocalOperationBudget.check("accessibility_collection")
        let collection = ObservationCollection<ObservationNode>(budget: LocalOperationBudget.allowance(min(1.5, max(0, budget))))
        let reads = ObservationAccessibilityReads.Context(deadline: collection.deadline, now: collection.now,
            report: { collection.issue($0, attribute: $1, code: $2) }, retried: { collection.retriedRead() },
            shouldRetry: { collection.scope.priority > 0 })
        defer {
            if reads.failures > 0 || collection.reasonCounts.keys.contains(where: { $0.hasPrefix("accessibility_") }) { graph?.gap() }
        }
        return try ObservationAccessibilityReads.$current.withValue(reads) {
            try stageSnapshot(on: display, keywords: keywords, collection: collection, graph: graph, forceFreshTopology: forceFreshTopology)
        }
    }

    private func stageSnapshot(on display: DisplayDescriptor, keywords: [String], collection: ObservationCollection<ObservationNode>, graph: NativeGraphSession?, forceFreshTopology: Bool) throws -> StagedAccessibilitySnapshot {
        try TaskOwnership.check()
        let suspension = TaskOwnership.current?.suspensionRevision
        var newMap: [String: ElementRecord] = [:]
        var structureCache: [UInt: AutomationStructureNode] = [:]
        var elementRows: [[String: Any]] = []
        var applicationRows: [[String: Any]] = []
        var resultDestinations: [[String: Any]] = []
        var roots: [ObservationCollection<ObservationNode>.Entry] = []
        let revision = UUID().uuidString
        var observedGraphics: [pid_t: [AutomationGraphicsWindow]] = [:]
        var observedApps: [pid_t: AutomationApplicationIdentity] = [:]
        let workingDocument = TaskOwnership.current.flatMap { self.workingDocumentInfo(generationID: $0.id) }
        let workingDocumentGeneration = TaskOwnership.current?.id
        let workingDocumentIsActive = workingDocument?["state"] as? String == "active"

        let apps = orderedApplicationsForSnapshot(on: display)
        graph?.retainProcesses(Set(apps.map(\.processIdentifier)))

        func collectRoots(expand: Bool) throws {
            try collection.collect(roots: roots, revision: revision, expand: expand, check: { try TaskOwnership.check() },
                equal: { CFEqual($0.element, $1.element) }, identityHash: { UInt(CFHash($0.element)) }, inspect: { entry, id in
                    try self.inspectObservation(entry: entry, id: id, keywords: keywords, map: &newMap,
                        rows: &elementRows, revision: revision, structureCache: &structureCache)
                }, children: { entry, offset, count in
                    self.observationChildren(entry: entry, offset: offset, count: count, collection: collection,
                        graph: graph?.graph(for: entry.node.application), forceFresh: forceFreshTopology)
                })
            roots.removeAll(keepingCapacity: true)
        }
        for (appIndex, app) in apps.enumerated() {
            try TaskOwnership.check()
            let pid = app.processIdentifier
            let appPriority = (appIndex == 0 ? 120 : 0) + (app.isActive ? 80 : 0)
                + AutomationObservationPolicy.keywordScore(app.localizedName ?? "", keywords: keywords)
            collection.scope = .init(pid: Int(pid), priority: appPriority)
            let appElement = AXUIElementCreateApplication(pid)
            let windowValue = attribute(appElement, kAXWindowsAttribute)
            let windows = windowValue as? [AXUIElement] ?? []
            if windowValue != nil, !(windowValue is [AXUIElement]) {
                collection.issue("accessibility_incomplete", attribute: kAXWindowsAttribute)
            }
            let visibleWindows = windows.filter { window in
                guard let frame = frame(of: window) else {
                    collection.issue("accessibility_incomplete", attribute: "AXWindowBounds"); return false
                }
                return frame.intersects(display.frame)
            }
            let graphics = graphicsWindows(of: pid).filter { $0.frame.intersects(display.frame) }
            let cgFrames = graphics.map(\.frame)
            let focusedWindow = accessibilityElement(appElement, kAXFocusedWindowAttribute)
            let windowFrames = visibleWindows.enumerated().compactMap { index, window -> (index: Int, frame: CGRect)? in
                frame(of: window).map { (index, $0) }
            }
            let match = AutomationObservationPolicy.matchingWindowIndex(frames: windowFrames.map(\.frame), topmostFrame: cgFrames.first)
            let topmostIndex = match.map { windowFrames[$0].index }
            let focusedIndex = visibleWindows.firstIndex { window in focusedWindow.map { CFEqual(window, $0) } == true }
            let windowRecords = visibleWindows.enumerated().compactMap { index, window -> SnapshotWindowRecord? in
                guard let rectangle = windowFrames.first(where: { $0.index == index })?.frame else { return nil }
                return SnapshotWindowRecord(element: window, id: "\(revision):p\(pid):w\(index)",
                    focused: index == focusedIndex, topmost: index == topmostIndex, frame: rectangle)
            }
            guard Self.hasObservableWindow(accessibilityCount: visibleWindows.count, graphicsCount: cgFrames.count) else { continue }
            if visibleWindows.isEmpty {
                collection.issue("accessibility_unavailable", attribute: kAXWindowsAttribute)
            } else if cgFrames.count > visibleWindows.count {
                collection.issue("accessibility_incomplete", attribute: kAXWindowsAttribute)
            }
            observedGraphics[pid] = graphics
            let appIdentity = applicationIdentity(app)
            observedApps[pid] = appIdentity
            graph?.prepare(appIdentity, windows: visibleWindows)

            for windowRecord in windowRecords {
                guard resultDestinations.count < 128 else { break }
                guard let documentURL = Self.taskResultWebURL(
                    attribute(windowRecord.element, kAXDocumentAttribute)
                        ?? attribute(windowRecord.element, kAXURLAttribute)
                ) else { continue }
                let title = stringAttribute(windowRecord.element, kAXTitleAttribute) ?? ""
                resultDestinations.append([
                    "pid": Int(pid), "bundle_id": appIdentity.bundleID ?? "",
                    "app": app.localizedName ?? "Unknown app", "window_title": title,
                    "title": title, "url": documentURL.absoluteString,
                    "observation_revision": revision
                ])
            }

            applicationRows.append([
                "name": app.localizedName ?? "Unknown app",
                "bundle_id": app.bundleIdentifier ?? "",
                "pid": Int(pid),
                "window_count": max(visibleWindows.count, cgFrames.count),
                "accessibility_available": !visibleWindows.isEmpty,
                "active": app.isActive,
                "topmost_on_agent_screen": applicationRows.isEmpty,
                "graphics_windows": graphics.compactMap { window -> [String: Any]? in
                    guard serializedAccessibilityFrame(window.frame) != nil else { return nil }
                    return ["id": Int(window.id), "frame": LocalTextRecognition.rect(window.frame), "title": window.title]
                },
                "windows": windowRecords.compactMap { record -> [String: Any]? in
                    guard let serialized = serializedAccessibilityFrame(record.frame) else { return nil }
                    var row: [String: Any] = ["title": stringAttribute(record.element, kAXTitleAttribute) ?? "",
                            "window_id": record.id, "focused": record.focused,
                            "topmost_on_agent_screen": record.topmost, "frame": serialized]
                    if workingDocumentIsActive,
                       let workingDocumentGeneration,
                       self.isWorkingDocumentWindow(record.element, pid: pid, generationID: workingDocumentGeneration) {
                        row["working_document"] = true
                    }
                    return row
                } + (visibleWindows.isEmpty ? cgFrames.compactMap { rectangle -> [String: Any]? in
                    guard let serialized = serializedAccessibilityFrame(rectangle) else { return nil }
                    return ["frame": serialized, "source": "core_graphics"]
                } : [])
            ])

            // Menu bars and focused fields are not necessarily descendants of
            // AXWindows. Collect them first so large web trees cannot hide them.
            var transientRoots: [AXUIElement] = []
            let focusedElement = accessibilityElement(appElement, kAXFocusedUIElementAttribute)
            if let focused = focusedElement,
               ["AXTextField", "AXTextArea", "AXSecureTextField"].contains(stringAttribute(focused, kAXRoleAttribute) ?? ""),
               frame(of: focused)?.intersects(display.frame) == true { transientRoots.append(focused) }
            if let menu = accessibilityElement(appElement, kAXMenuBarAttribute) { transientRoots.append(menu) }
            transientRoots += (attribute(appElement, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter {
                ["AXMenu", "AXSheet"].contains(stringAttribute($0, kAXRoleAttribute) ?? "")
            }
            for root in transientRoots {
                roots.append(.init(node: ObservationNode(element: root, pid: pid, appName: app.localizedName ?? "Unknown app",
                    application: appIdentity, focusedElement: focusedElement, ownerWindow: nil, windowRecords: windowRecords),
                    scope: .init(pid: Int(pid), priority: appPriority + 400)))
            }

            for index in AutomationObservationPolicy.windowOrder(count: visibleWindows.count, focusedIndex: focusedIndex, topmostIndex: topmostIndex) {
                let window = visibleWindows[index]
                let record = windowRecords.first { CFEqual($0.element, window) }
                let title = stringAttribute(window, kAXTitleAttribute) ?? ""
                roots.append(.init(node: ObservationNode(element: window, pid: pid, appName: app.localizedName ?? "Unknown app",
                    application: appIdentity, focusedElement: focusedElement, ownerWindow: window, windowRecords: windowRecords),
                    scope: .init(pid: Int(pid), windowID: record?.id,
                        priority: appPriority + (index == focusedIndex || index == topmostIndex ? 300 : 0)
                            + AutomationObservationPolicy.keywordScore(title, keywords: keywords))))
            }
            // Read the visible app's controls before probing unrelated apps;
            // slow background metadata must not consume the entire AX budget.
            try collectRoots(expand: false)
        }

        try collectRoots(expand: true)

        let snapshot = AccessibilitySnapshot(
            revision: revision,
            elements: elementRows,
            applications: applicationRows,
            resultDestinations: resultDestinations,
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
            systemContext: systemContext(), completeness: collection.metadata,
            workingDocument: workingDocument
        )
        // Compare full target labels/geometry and full editable text in memory;
        // prompt clipping must not hide a change. Secure values are never read.
        let signatureRows = elementRows.map { row -> [String: Any] in
            var result = row
            if let id = row["id"] as? String, let record = newMap[id] {
                result["title"] = record.identity.label
                result["element_identity"] = String(CFHash(record.element))
                result["structure"] = record.identity.structure.map(\.dictionary)
                if let window = record.window { result["window_identity"] = String(CFHash(window)) }
                if let frame = record.identity.bounds, serializedAccessibilityFrame(frame) != nil {
                    result["frame"] = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
                }
                if let value = record.observedTextValue { result["value"] = value }
            }
            return result
        }
        let signatureApps = applicationRows.map { row -> [String: Any] in
            var result = row
            if let pid = row["pid"] as? Int, let identity = observedApps[pid_t(pid)] {
                result["launch"] = identity.launchDate?.timeIntervalSince1970 ?? 0
                result["bundle_path"] = identity.bundlePath ?? ""
            }
            return result
        }
        let controls = try ObservationConsistency.controlSignature(elements: signatureRows, applications: signatureApps)
        let destinationSignature = try ObservationConsistency.resultDestinationSignature(resultDestinations)
        let signature = String(decoding: try JSONSerialization.data(withJSONObject:
            ["controls": controls, "collection_gaps": collection.reasonCounts,
             "working_document": workingDocument.map { $0 as Any } ?? (NSNull() as Any),
             "result_destinations": destinationSignature], options: [.sortedKeys]), as: UTF8.self)
        let lease = TaskOwnership.current
        return StagedAccessibilitySnapshot(snapshot: snapshot, consistencySignature: signature, publish: { [self] in
            try TaskOwnership.$current.withValue(lease) {
                try TaskOwnership.commit {
                    guard lease?.suspensionRevision == suspension else { throw CancellationError() }
                    lock.withLock {
                        elementMap = newMap
                        observationRevision = revision
                        observationCoordinates = nil
                        observationTaskGenerationID = lease?.id
                        observedGraphicsWindows = observedGraphics
                        observedApplications = observedApps
                    }
                }
            }
        })
    }

    private func inspectObservation(
        entry: ObservationCollection<ObservationNode>.Entry,
        id: String,
        keywords: [String],
        map: inout [String: ElementRecord],
        rows: inout [[String: Any]],
        revision: String,
        structureCache: inout [UInt: AutomationStructureNode]
    ) throws -> ObservationCollection<ObservationNode>.Inspection {
        try TaskOwnership.check()
        let node = entry.node
        let element = node.element, pid = node.pid, appName = node.appName, application = node.application
        let focusedElement = node.focusedElement, ownerWindow = node.ownerWindow, windowRecords = node.windowRecords
        let depth = entry.scope.depth, parentID = entry.scope.parentID

        let attributes = try ObservationControlAttributes.read(element, pid: pid, context: ObservationAccessibilityReads.current!)
        guard let role = attributes.role else {
            return .init(included: false) // Required role failure is already reported; no value or executable ID.
        }
        // Closed menu trees expose commands with zero bounds. They consume the
        // observation budget and can be mistaken for currently usable controls.
        if role == "AXMenu" {
            guard let bounds = attributes.bounds, bounds.width > 0, bounds.height > 0 else {
                return .init(included: false)
            }
        }
        let subrole = attributes.subrole
        let secure = attributes.requiresSecureMask
        let title = attributes.title
        let bounds = attributes.bounds
        let value = secure ? nil : attribute(element, kAXValueAttribute)
        let rawValue = secure ? "[secure]" : printableValue(value)
        let focused = attributes.focused
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
                windowBounds: window.flatMap { frame(of: $0) }, structure: targetStructure(element, cache: &structureCache)),
            window: window, depth: depth, supportsPress: actions.contains("AXPress"), supportsActions: !actions.isEmpty,
            wasFocused: focused, observedTextValue: AutomationTextEntryPolicy.inputRoles.contains(role) ? value as? String : nil,
            observedSelection: selection)
        var row: [String: Any] = [
            "id": id,
            "native_identity": String(CFHash(element)),
            "pid": Int(pid),
            "app": appName,
            "role": role,
            "depth": depth,
            "enabled": attributes.enabled
        ]
        row["focused"] = focused
        if let title = map[id]?.identity.windowTitle { row["window_title"] = clipped(title) }
        if let window, let windowRecord = windowRecords.first(where: { CFEqual($0.element, window) }) {
            row["window_id"] = windowRecord.id
        }
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
        guard let reads = ObservationAccessibilityReads.current, reads.now() < reads.deadline else {
            map.removeValue(forKey: id)
            return .init(included: false, omission: "collection_timeout")
        }
        rows.append(row)
        return .init(relevance: AutomationObservationPolicy.keywordScore(title, keywords: keywords))
    }

    private func observationChildren(entry: ObservationCollection<ObservationNode>.Entry, offset: Int, count: Int,
                                     collection: ObservationCollection<ObservationNode>, graph: NativeAccessibilityGraph<AXUIElement>?,
                                     forceFresh: Bool) -> ObservationCollection<ObservationNode>.Page {
        let element = entry.node.element
        let ticket = graph?.beginRead()
        let failuresBefore = ObservationAccessibilityReads.current?.failures ?? 0
        defer { if (ObservationAccessibilityReads.current?.failures ?? 0) > failuresBefore { graph?.gap() } }
        var total = 0
        let read = ObservationAccessibilityReads.current!
        let counted = read.read(element, attribute: kAXChildrenAttribute) {
            AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &total)
        }
        if counted == .success {
            guard total >= 0 else {
                collection.issue("accessibility_incomplete", attribute: kAXChildrenAttribute)
                return .init(nodes: [], total: 0, incomplete: true)
            }
            if let cached = graph?.page(element, offset: offset, count: count, total: total, fresh: forceFresh) {
                return .init(nodes: cached.children.map { entry.node.child($0) }, total: cached.total)
            }
            func remember(_ nodes: [AXUIElement], total: Int) {
                if let ticket { graph?.store(element, offset: offset, page: .init(children: nodes, total: total), ticket: ticket) }
            }
            guard total > offset else { remember([], total: total); return .init(nodes: [], total: total) }
            var values: CFArray?
            let result = read.read(element, attribute: kAXChildrenAttribute) {
                AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, offset, min(count, total - offset), &values)
            }
            if result == .success, let nodes = values as? [AXUIElement], nodes.count == min(count, total - offset) {
                remember(nodes, total: total)
                return .init(nodes: nodes.map { entry.node.child($0) }, total: total)
            }
            if result == .attributeUnsupported || result == .notImplemented {
                if let nodes = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                    return .init(nodes: Array(nodes.dropFirst(offset).prefix(count)).map { entry.node.child($0) }, total: nodes.count)
                }
            }
            collection.issue("accessibility_incomplete", attribute: kAXChildrenAttribute)
            return .init(nodes: [], total: total, incomplete: true)
        }
        // Some apps implement only the single-value children attribute. Do
        // not interpret unsupported pagination as an unavailable control.
        if counted == .attributeUnsupported || counted == .notImplemented || counted == .noValue {
            let value = attribute(element, kAXChildrenAttribute)
            if let nodes = value as? [AXUIElement] {
                return .init(nodes: Array(nodes.dropFirst(offset).prefix(count)).map { entry.node.child($0) }, total: nodes.count)
            }
            if value != nil {
                collection.issue("accessibility_incomplete", attribute: kAXChildrenAttribute)
            } else if let role = stringAttribute(element, kAXRoleAttribute),
               ["AXWindow", "AXGroup", "AXScrollArea", "AXOutline", "AXTable", "AXWebArea", "AXSheet", "AXDialog", "AXMenu"].contains(role) {
                collection.issue("accessibility_incomplete", attribute: kAXChildrenAttribute)
            }
            return .init(nodes: [], total: 0)
        }
        return .init(nodes: [], total: 0, incomplete: true)
    }

    static func hasObservableWindow(accessibilityCount: Int, graphicsCount: Int) -> Bool {
        accessibilityCount > 0 || graphicsCount > 0
    }

    func validateObservation(_ revision: String?) throws {
        lock.lock()
        let current = observationRevision
        let generation = observationTaskGenerationID
        lock.unlock()
        guard let revision, !revision.isEmpty, revision == current,
              TaskOwnership.current == nil || TaskOwnership.current?.id == generation else {
            throw AccessibilityActionError.staleObservation
        }
    }

    /// A read-only hint for deciding when a complete, consistent observation is
    /// worth collecting. Only the subsequent accepted observation proves the
    /// effect; these probes never publish elements or authorize delivery.
    func localChangeTarget(_ params: [String: Any]) throws -> (pid: pid_t?, elements: [AXUIElement], check: () throws -> Bool?) {
        try validateObservation(params["observation_revision"] as? String)
        let pid: pid_t?
        if let value = params["pid"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  (1...Double(Int32.max)).contains(number.doubleValue) else {
                throw AccessibilityActionError.invalidAction("pid must be a positive integer")
            }
            pid = number.int32Value
        } else { pid = nil }
        let application = lock.withLock { pid.flatMap { observedApplications[$0] } }
        if let pid, application == nil || pid == controllerPID { throw AccessibilityActionError.staleObservation }
        let effect = params["expected_result"] as? [String: Any]
        if let effectPID = effect?["pid"] {
            guard let number = effectPID as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue == Double(pid ?? 0) else {
                throw AccessibilityActionError.invalidAction("Local check pid must match the observed app")
            }
        }
        if params["expected_result"] != nil && effect == nil {
            throw AccessibilityActionError.invalidAction("Local screen check must be an object")
        }
        let kind = effect?["type"] as? String
        var record: ElementRecord?
        if kind == "field_value" {
            guard let effect, Set(effect.keys).isSubset(of: ["type", "element_id", "value", "pid"]),
                  let id = effect["element_id"] as? String, let value = effect["value"] as? String,
                  value.utf8.count <= TaskToolExecutor.maximumWriteBytes else {
                throw AccessibilityActionError.invalidAction("Invalid local field check")
            }
            record = try self.record(for: ["element_id": id])
            guard let record, record.pid == pid, ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(record.role),
                  !AutomationTextEntryPolicy.isSecure(role: record.role, subrole: record.identity.subrole) else {
                throw AccessibilityActionError.staleObservation
            }
        } else if kind == "dialog_appeared" {
            guard let effect, Set(effect.keys).isSubset(of: ["type", "pid", "title", "window_title"]),
                  let title = effect["title"] as? String, !title.isEmpty, title.utf8.count <= 2_097_152,
                  effect["window_title"] == nil || effect["window_title"] is String else {
                throw AccessibilityActionError.invalidAction("Invalid local dialog check")
            }
        } else if effect != nil { throw AccessibilityActionError.invalidAction("Unsupported local screen check") }
        let elements = record.map { [$0.element] + ($0.window.map { [$0] } ?? []) } ?? []
        let probe: () throws -> Bool? = { [self] in
            try TaskOwnership.check()
            if let pid, let application {
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                      applicationIdentity(app) == application else { return nil }
            }
            if let record, let expected = effect?["value"] as? String {
                let window = accessibilityElement(record.element, kAXWindowAttribute)
                guard elementTitle(record.element) == record.identity.label,
                      stringAttribute(record.element, kAXSubroleAttribute) ?? "" == record.identity.subrole,
                      record.window.map({ expected in window.map { CFEqual(expected, $0) } ?? false }) ?? (window == nil) else {
                    return nil
                }
                return readableTextValue(record).map { $0 == expected }
            }
            if kind == "dialog_appeared", let pid, let title = effect?["title"] as? String {
                // Search only the specified app's window/dialog subtree, with
                // strict local limits. Incomplete reads fall back to capture.
                let deadline = ProcessInfo.processInfo.systemUptime + 0.1
                var nodes = windows(of: pid).map { ($0, elementTitle($0), 0) }
                var visited: Set<UInt> = []
                while let (element, windowTitle, depth) = nodes.popLast() {
                    if ProcessInfo.processInfo.systemUptime >= deadline || visited.count >= 200 { return nil }
                    guard visited.insert(CFHash(element)).inserted else { continue }
                    guard let role = stringAttribute(element, kAXRoleAttribute) else { return nil }
                    if (["AXSheet", "AXDialog"].contains(role) || stringAttribute(element, kAXSubroleAttribute) == "AXDialog"),
                       elementTitle(element) == title,
                       effect?["window_title"] == nil || effect?["window_title"] as? String == windowTitle { return true }
                    if depth >= 12 { return nil }
                    if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                        if children.count + nodes.count + visited.count > 200 { return nil }
                        nodes.append(contentsOf: children.map { ($0, windowTitle, depth + 1) })
                    }
                }
                return false
            }
            return nil
        }
        return (pid, elements, {
            let context = ObservationAccessibilityReads.Context(deadline: ProcessInfo.processInfo.systemUptime + 0.1,
                now: { ProcessInfo.processInfo.systemUptime }, report: { _, _, _ in }, retried: {}, shouldRetry: { false })
            let candidate = try ObservationAccessibilityReads.$current.withValue(context) { try probe() }
            return context.failures > 0 ? nil : candidate
        })
    }

    func bindCoordinates(_ coordinates: ScreenCoordinateMapping, revision: String, on display: DisplayDescriptor,
                         screenshotURL: URL? = nil) throws {
        try coordinates.validate(display: display)
        try validateObservation(revision)
        let protectedTargets = lock.withLock {
            elementMap.values.filter {
                AutomationTextEntryPolicy.isSecure(role: $0.role, subrole: $0.identity.subrole)
            }.compactMap(\.observedBounds)
        }
        let source = screenshotURL.flatMap { try? AgentMagnifierImageSource(
            url: $0, mapping: coordinates, protectedTargets: protectedTargets
        ) }
        try TaskOwnership.commit {
            try lock.withLock {
                guard revision == observationRevision else { throw AccessibilityActionError.staleObservation }
                observationCoordinates = coordinates
                observationMagnifierSource = source.map { (revision, display.id, $0) }
            }
        }
    }

    func finishActionMagnifier(actionID: String, generationID: String, state: AgentActionMagnifierState) {
        guard let lease = TaskOwnership.current, lease.id == generationID, lease.accepts(generationID) else { return }
        guard let sequence = lock.withLock({ () -> UInt64? in
            guard activeMagnifierAction?.actionID == actionID,
                  activeMagnifierAction?.generationID == generationID else { return nil }
            return activeMagnifierAction?.sequence
        }) else { return }
        onActionMagnifierEvent?(.init(kind: .state(
            actionID: actionID, generationID: generationID, sequence: sequence, state: state
        )))
    }

    func clearActionMagnifier() {
        guard let lease = TaskOwnership.current, lease.accepts(lease.id) else { return }
        let sequence = lock.withLock { () -> UInt64 in
            actionMagnifierSequence &+= 1
            activeMagnifierAction = nil
            return actionMagnifierSequence
        }
        onActionMagnifierEvent?(.init(kind: .clear(generationID: lease.id, sequence: sequence)))
    }

    private func publishActionMagnifier(
        type: String,
        record: ElementRecord?,
        pid: pid_t,
        point: CGPoint,
        display: DisplayDescriptor
    ) {
        guard let lease = TaskOwnership.current, lease.accepts(lease.id),
              let receipt = TaskOwnership.actionReceipt, receipt.generation == lease.id else { return }
        let state = lock.withLock {
            (observationRevision, observationCoordinates, observationMagnifierSource)
        }
        guard !state.0.isEmpty,
              let coordinates = state.1,
              coordinates.displayID == display.id else { return }
        if let acceptedSource = state.2,
           acceptedSource.revision != state.0 || acceptedSource.displayID != display.id {
            return
        }
        let source = state.2?.source
        do { try coordinates.validate(display: display) }
        catch { return }
        if let record, record.revision != state.0 { return }
        guard display.frame.contains(point) else { return }

        let secureTarget = record.map {
            AutomationTextEntryPolicy.isSecure(role: $0.role, subrole: $0.identity.subrole)
        } ?? false
        let appName = record?.identity.application.name
            ?? NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? "Application"
        var containers: [String] = []
        if let structure = record?.identity.structure {
            let contextualRoles: Set<String> = ["AXWindow", "AXSheet", "AXDialog", "AXPopover", "AXMenu",
                "AXGroup", "AXTabGroup", "AXToolbar", "AXScrollArea", "AXList", "AXTable", "AXOutline"]
            for node in structure.reversed() where contextualRoles.contains(node.role) {
                if !node.label.isEmpty { containers.append(node.label) }
            }
        }
        guard let actionTitle = AgentActionMagnifierCaption.actionTitle(for: type) else { return }
        let breadcrumb = AgentActionMagnifierCaption.breadcrumb(
            target: record?.identity.label, containers: containers, application: appName
        )
        let sequence = lock.withLock { () -> UInt64 in
            actionMagnifierSequence &+= 1
            activeMagnifierAction = (receipt.id, lease.id, actionMagnifierSequence)
            return actionMagnifierSequence
        }
        let reader = secureTarget ? nil : source?.makeReader()
        let request = AgentActionMagnifierRequest(
            actionID: receipt.id,
            generationID: lease.id,
            sequence: sequence,
            observationRevision: state.0,
            displayID: display.id,
            displayFrame: display.frame,
            mapping: coordinates,
            actionTitle: actionTitle,
            breadcrumb: breadcrumb,
            pointer: point,
            target: secureTarget ? nil : record?.observedBounds,
            reader: reader
        )
        onActionMagnifierEvent?(.init(kind: .targeted(request)))
    }

    func validateCoordinates(on display: DisplayDescriptor) throws {
        guard let coordinates = lock.withLock({ observationCoordinates }) else {
            throw AccessibilityActionError.staleObservation
        }
        try coordinates.validate(display: display)
    }

    private func validateEventGeometry(on display: DisplayDescriptor) throws {
        if TaskOwnership.current != nil { try validateCoordinates(on: display) }
        guard CGDisplayBounds(display.id) == display.frame else { throw AccessibilityActionError.staleObservation }
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
        let taskLease = TaskOwnership.current ?? lock.withLock { self.taskLease }

        lock.lock()
        inputCancelled = true
        inputGeneration += 1
        restoreWorkItem?.cancel()
        let previous = previousInputApplication
        let target = inputTargetPID
        let generation = inputGeneration
        if let previous, let target { teardownForeground = (previous, target) }
        previousInputApplication = nil
        inputTargetPID = nil
        lock.unlock()
        if let previous, let target, NSWorkspace.shared.frontmostApplication?.processIdentifier == target {
            DispatchQueue.main.async { [weak self] in
                TaskOwnership.callback(taskLease) {
                    guard let self, self.lock.withLock({ self.inputGeneration == generation }),
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == target else { return }
                    _ = ownedActivate(previous)
                }
            }
        }
    }

    private func inputIsCancelledUnlocked() -> Bool {
        inputCancelled || Task.isCancelled
    }

    private func inputIsCancelled() -> Bool {
        let state = TaskOwnership.current?.state
        let stale = state != nil && state != .running && state != .paused
        lock.lock(); defer { lock.unlock() }
        return inputCancelled || Task.isCancelled || stale
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
        try await TaskOwnership.checkpoint()
        prepareInputTarget(pid)
        guard let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated else {
            throw AccessibilityActionError.elementUnavailable
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            let allowed = try await ownedActivateAsync(target)
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
        let taskLease = TaskOwnership.current ?? lock.withLock { self.taskLease }

        lock.lock()
        let generation = inputGeneration
        let previous = previousInputApplication
        lock.unlock()
        guard let previous else { return }
        let work = DispatchWorkItem { [weak self] in
            TaskOwnership.callback(taskLease) {
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
                _ = ownedActivate(previous)
                self.lock.lock()
                if generation == self.inputGeneration {
                    self.previousInputApplication = nil
                    self.inputTargetPID = nil
                }
                self.lock.unlock()
            }
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

    private func validatedDesktopAction(_ input: [String: Any]) throws -> [String: Any] {
        do {
            let action = try ActionContract.validate(input)
            guard ActionKind(rawValue: action["type"] as! String)!.owner == .desktop else {
                throw AccessibilityActionError.invalidAction("This action does not belong to the desktop executor")
            }
            return action
        } catch let error as ActionContract.ValidationError {
            throw AccessibilityActionError.invalidAction(error.localizedDescription)
        }
    }

    func performStructured(action: [String: Any], on display: DisplayDescriptor, privateInput: Bool = false,
                           verifyScreenshotTarget: (() async throws -> (() throws -> Void)?)? = nil) async throws -> [String: Any] {
        try await TaskOwnership.checkpoint()
        let action = try validatedDesktopAction(action)
        guard !inputIsCancelled() else { throw AccessibilityActionError.cancelled }
        try ControlCompatibilityProfiles.owned { compatibilityProfiles.prepare(environment: Self.compatibilityEnvironment()) }
        let planningRevision = lock.withLock { observationRevision }
        let type = action["type"] as? String ?? ""
        if ["launch_app", "open_route", "navigate_browser"].contains(type) {
            let message = try await perform(action: action, on: display)
            return ["action_type": type, "message": message, "delivery_method": "workspace",
                    "outcome": type == "launch_app" ? "verified" : "delivered_unconfirmed", "verified": type == "launch_app",
                    "verification_scope": type == "launch_app" ? "window_visible" : "delivery_only"]
        }
        guard AXIsProcessTrusted() else { throw AccessibilityActionError.permissionDenied }
        let record = action["element_id"] == nil ? nil : try self.record(for: action)
        let pid = try record?.pid ?? actionPID(action, on: display,
            fallbackPoint: (action["x"] != nil && action["y"] != nil) ? point(from: action, display: display) : nil)
        try ensureAllowedOnDisplay(pid, display: display)
        try validateWorkingDocumentTarget(action: action, record: record, pid: pid, display: display)
        try await beginVerifiedInput(to: pid)
        defer { scheduleInputRestoration(pid) }
        try validateWorkingDocumentTarget(action: action, record: record, pid: pid, display: display)
        if let record { try validateRecord(record, action: action, on: display) }
        else if ["click", "double_click", "scroll"].contains(type) {
            try validateCoordinateWindows(pid, on: display)
        }
        if ["click", "double_click", "scroll"].contains(type), let record,
           let rectangle = frame(of: record.element) {
            let targetPoint = CGPoint(x: rectangle.midX, y: rectangle.midY)
            if !pointerTargetIsVisible(pid, at: targetPoint, display: display) {
                if let window = record.window { _ = ownedAXPress(window, kAXRaiseAction as CFString) }
                try await AutomationInputPolicy.waitUntilReady(
                    ready: { self.pointerTargetIsVisible(pid, at: targetPoint, display: display) && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid },
                    cancelled: { self.inputIsCancelled() })
            }
        }
        try validateObservation(planningRevision)
        if ["set_value", "type_text"].contains(type) {
            let target = try record ?? observedFocusedInput(pid: pid)
            return try await performTextEntry(action: action, record: target, on: display, privateInput: privateInput).dictionary(pid: pid)
                .merging(["action_type": type]) { _, new in new }
        }
        let profileKey = try record.flatMap { try compatibilityKey($0, action: action, on: display) }
        if let profileKey { _ = try ControlCompatibilityProfiles.owned { compatibilityProfiles.preferred(for: profileKey, permitted: []) } }
        let controlBefore = record.map(controlInteractionState)
        let before = actionState(pid)
        let screenshotPreflight = try await verifyScreenshotTarget?()
        let message = try await perform(action: action, on: display, planningRevision: planningRevision,
                                        screenshotPreflight: screenshotPreflight ?? nil)
        let method = ControlDeliveryMethod.delivered(action: ActionKind(rawValue: type)!,
            coordinatePress: message.hasPrefix("Clicked"), hid: requiresHIDFallback(pid))?.rawValue ?? "process_event"
        try LocalOperationBudget.check("delivery_verification")
        let deadline = ContinuousClock.now.advanced(by: .seconds(LocalOperationBudget.allowance(2)))
        var verified = false
        var changed = false
        repeat {
            guard !inputIsCancelled() else { throw AccessibilityActionError.cancelled }
            try Task.checkCancellation()
            if type == "focus", let record {
                verified = intendedElementHasFocus(record)
            } else { changed = actionState(pid) != before }
            if verified || changed { break }
            try await LocalOperationBudget.sleep(0.08, phase: "delivery_verification")
        } while ContinuousClock.now < deadline
        if let record, let profileKey, let controlBefore, let deliveryMethod = ControlDeliveryMethod(rawValue: method),
           (try? validateRecord(record, action: action, on: display)) != nil {
            let proven = controlBefore.verifies(controlInteractionState(record))
            try recordCompatibility(proven ? .verified : .supported, method: deliveryMethod,
                                    key: profileKey, record: record, action: action, on: display)
        }
        return ["action_type": type, "verified": verified,
                "message": verified ? "\(message); confirmed focus" : "\(message); delivery acknowledged, intended effect not confirmed",
                "delivery_method": method, "outcome": verified ? "verified" : "delivered_unconfirmed",
                "verification_scope": verified ? "focus" : "delivery_only", "pid": Int(pid)]
    }

    func perform(action: [String: Any], on display: DisplayDescriptor, planningRevision: String? = nil,
                 screenshotPreflight: (() throws -> Void)? = nil) async throws -> String {
        try await TaskOwnership.checkpoint()
        let action = try validatedDesktopAction(action)
        let kind = ActionKind(rawValue: action["type"] as! String)!
        let type = kind.rawValue
        // Observation, planning, typing, and app launch are idle states for the
        // visual pointer. A pointer action below will briefly reveal it again.
        agentCursor?.hide()
        switch kind {
        case .press:
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
            let profileKey = try compatibilityKey(record, action: action, on: display)
            let coordinateMethod: ControlDeliveryMethod = requiresHIDFallback(record.pid) ? .hid : .session_event
            let preferred = try profileKey.flatMap { key in
                try ControlCompatibilityProfiles.owned { compatibilityProfiles.preferred(for: key, permitted: [.accessibility, coordinateMethod]) }
            }
            let unsupported = try profileKey.map { key in
                try ControlCompatibilityProfiles.owned { compatibilityProfiles.evidence(for: key, method: .accessibility) == .unsupported }
            } ?? false
            var magnifierPublished = false
            func publishMagnifier(at point: CGPoint) {
                guard !magnifierPublished else { return }
                magnifierPublished = true
                self.publishActionMagnifier(type: type, record: record, pid: record.pid,
                                            point: point, display: display)
            }
            let method = try AutomationPressPolicy.deliver(
                preferVerifiedCoordinate: preferred == coordinateMethod && unsupported,
                pressAdvertised: profileKey?.pressAdvertised ?? true,
                recordPress: { result in
                    guard let profileKey else { return }
                    let evidence: ControlCompatibilityProfiles.Evidence
                    switch result {
                    case .success: evidence = .supported
                    case .actionUnsupported, .notImplemented: evidence = .unsupported
                    case .apiDisabled, .invalidUIElement: return
                    default: evidence = .unconfirmed
                    }
                    try self.recordCompatibility(evidence, method: .accessibility, key: profileKey,
                                                 record: record, action: action, on: display)
                }, preflight: {
                try self.validateRecord(record, action: action, on: display)
                if let bounds = self.frame(of: record.element) {
                    publishMagnifier(at: CGPoint(x: bounds.midX, y: bounds.midY))
                }
            }, press: {
                ownedAXPress(record.element, kAXPressAction as CFString)
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
                        publishMagnifier(at: CGPoint(x: elementFrame.midX, y: elementFrame.midY))
                    }
                )
                if let profileKey {
                    try recordCompatibility(.supported, method: coordinateMethod, key: profileKey,
                                            record: record, action: action, on: display)
                }
            })
            return method == "coordinate" ? "Clicked the requested control" : "Pressed the requested control"

        case .focus:
            let record = try record(for: action)
            try ensureAllowedOnDisplay(record.pid, display: display)
            rememberManualTarget(record.pid)
            try await ensureElementFocus(record, action: action, on: display)
            return "Focused the requested control"

        case .set_value, .type_text:
            let target = try action["element_id"] == nil
                ? observedFocusedInput(pid: actionPID(action, on: display)) : record(for: action)
            return try await performTextEntry(action: action, record: target, on: display).message

        case .click, .double_click:
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
            let coordinateRecord = record == nil ? try observedControl(at: point, pid: pid) : nil
            var magnifierPublished = false
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
                        try screenshotPreflight?()
                        if let coordinateRecord {
                            try self.validateRecord(coordinateRecord, action: action, on: display)
                            try self.validatePointerHit(coordinateRecord, at: point)
                        }
                    }
                    try self.validateWorkingDocumentTarget(action: action, record: record ?? coordinateRecord,
                                                           pid: pid, display: display, point: point)
                    if !magnifierPublished {
                        magnifierPublished = true
                        self.publishActionMagnifier(type: type, record: record ?? coordinateRecord,
                                                    pid: pid, point: point, display: display)
                    }
                }
            )
            return type == "double_click" ? "Double-clicked" : "Clicked"

        case .key:
            let pid = try actionPID(action, on: display)
            try ensureAllowedOnDisplay(pid, display: display)
            rememberManualTarget(pid)
            guard let key = action["key"] as? String else {
                throw AccessibilityActionError.invalidAction("key requires a key name")
            }
            let modifiers = action["modifiers"] as? [String] ?? []
            try postKey(key, modifiers: modifiers, to: pid, preflight: {
                try self.validateWorkingDocumentTarget(action: action, record: nil, pid: pid, display: display)
            })
            return "Sent the \(key) key"

        case .scroll:
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
            try validateWorkingDocumentTarget(action: action, record: record, pid: pid, display: display, point: point)
            rememberManualTarget(pid)
            let deltaX = intValue(action["delta_x"]) ?? 0
            let deltaY = intValue(action["delta_y"]) ?? 0
            var magnifierPublished = false
            let retargeted = try postScroll(
                to: pid,
                point: point,
                deltaX: deltaX,
                deltaY: deltaY,
                on: display,
                preflight: {
                    if let record { try self.validateRecord(record, action: action, on: display) }
                    try self.validateWorkingDocumentTarget(action: action, record: record, pid: pid,
                                                           display: display, point: point)
                },
                onResolvedPoint: { resolvedPoint in
                    guard !magnifierPublished else { return }
                    magnifierPublished = true
                    let resolvedRecord = record ?? (try? self.observedControl(at: resolvedPoint, pid: pid))
                    self.publishActionMagnifier(type: type, record: resolvedRecord,
                                                pid: pid, point: resolvedPoint, display: display)
                }
            )
            return retargeted
                ? "Scrolled the target app after safely retargeting inside its visible window"
                : "Scrolled the target app"

        case .launch_app:
            return try await launchApp(action, on: display)

        case .open_route:
            return try await openRoute(action, on: display)

        case .navigate_browser:
            return try await navigateBrowser(action, on: display)

        case .none, .wait, .read_file, .write_file, .run_command:
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
                      ownedAXSet(
                        window,
                        kAXPositionAttribute as CFString,
                        value
                      ) == .success else { continue }

                placements.append(WindowPlacement(element: window, position: oldPosition))
                movedApplications[app.processIdentifier] = app
                _ = ownedAXPress(window, kAXRaiseAction as CFString)
                cascade = min(cascade + 24, 144)
            }
        }

        // Activating every affected app makes the transferred windows visible
        // immediately. The former implementation activated only the first app,
        // which left the other successfully moved windows behind the controller.
        for application in movedApplications.values.sorted(by: {
            ($0.localizedName ?? "") < ($1.localizedName ?? "")
        }) {
            _ = ownedActivate(application)
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
                if ownedAXPress(
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
            _ = ownedAXSet(
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
            let point = try displayPoint(from: normalizedPoint, display: display)
            let pid = try targetPID(at: point)
            rememberManualTarget(pid)
            try postClick(to: pid, point: point, double: count > 1, on: display)
            return count > 1 ? "Double-clicked from the live viewer" : "Clicked from the live viewer"

        case .drag(let normalizedStart, let normalizedEnd):
            let start = try displayPoint(from: normalizedStart, display: display)
            let end = try displayPoint(from: normalizedEnd, display: display)
            let pid = try targetPID(at: start)
            rememberManualTarget(pid)
            try postDrag(to: pid, from: start, to: end, on: display)
            return "Dragged from the live viewer"

        case .scroll(let normalizedPoint, let deltaX, let deltaY):
            let point = try displayPoint(from: normalizedPoint, display: display)
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

    private func displayPoint(from normalized: CGPoint, display: DisplayDescriptor) throws -> CGPoint {
        try ScreenCoordinateMapping.displayOnly(display).eventPoint(fromUnit: normalized)
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
                  TaskOwnership.permitted(false, { NSWorkspace.shared.open(settingsURL) }) else {
                throw AccessibilityActionError.operationFailed(
                    "Could not open the predefined \(route["destination"] ?? appName) route"
                )
            }
            // System Settings loads extension-backed panes asynchronously.
            // Give the selected pane enough time to replace the previous one
            // before the next screenshot is captured and reasoned over.
            try? await LocalOperationBudget.sleep(0.9, phase: "launch_or_placement")
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
        let browserName = requestedBrowser?.isEmpty == false ? requestedBrowser! : ActionContract.defaultValue(.navigate_browser, "browser") as! String
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
        try? await LocalOperationBudget.sleep(0.35, phase: "launch_or_placement")
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
        try? await LocalOperationBudget.sleep(0.18, phase: "launch_or_placement")
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

        var app: NSRunningApplication
        do {
            app = try await ownedOpenApplication(workspace, at: url, configuration: configuration)
            recordAgentLaunch(pids: [app.processIdentifier])
            try await TaskOwnership.checkpoint()
        } catch {
            try TaskOwnership.check()
            // iPhone/iPad-style wrappers can be registered with LaunchServices
            // without behaving like a conventional macOS bundle. The plain
            // workspace open route handles those wrappers, after which we bind
            // to the actual (sometimes translocated) running process.
            guard TaskOwnership.permitted(false, { workspace.open(url) }),
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
                _ = ownedActivate(candidate)
            }
            try? await LocalOperationBudget.sleep(0.25, phase: "launch_or_placement")
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
                    _ = try? TaskOwnership.commit { candidate.unhide() }
                    _ = ownedActivate(candidate)
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
        guard TaskOwnership.current == nil || TaskOwnership.current?.id == taskGenerationID,
              var baseline = taskApplicationBaseline else {
            lock.unlock()
            return
        }
        baseline.agentLaunchedPIDs.formUnion(pids.filter { $0 != controllerPID })
        taskApplicationBaseline = baseline
        lock.unlock()
    }

    private func setTaskDisplayOverride(_ displayID: CGDirectDisplayID) {
        lock.lock()
        guard !inputIsCancelledUnlocked() else { lock.unlock(); return }
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
        let deadline = clock.now.advanced(by: min(timeout, .seconds(LocalOperationBudget.allowance(Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18))))
        var seenPIDs: Set<pid_t> = []
        var activatedPIDs: Set<pid_t> = []
        repeat {
            guard (try? await TaskOwnership.checkpoint()) != nil else { break }
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
                    _ = try? TaskOwnership.commit { candidate.unhide() }
                    _ = ownedActivate(candidate)
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
            try? await LocalOperationBudget.sleep(0.35, phase: "launch_or_placement")
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
                _ = ownedAXSet(
                    window,
                    kAXPositionAttribute as CFString,
                    value
                )
            }
            _ = ownedAXPress(window, kAXRaiseAction as CFString)
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
        let deadline = clock.now.advanced(by: min(timeout, .seconds(LocalOperationBudget.allowance(Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18))))
        repeat {
            guard (try? await TaskOwnership.checkpoint()) != nil else { return nil }
            if let app = matchingRunningApplication(bundleID: bundleID, name: name) {
                return app
            }
            try? await LocalOperationBudget.sleep(0.3, phase: "launch_or_placement")
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

    private static func compatibilityEnvironment() -> String {
        ControlCompatibilityProfiles.fingerprint([String(ControlCompatibilityProfiles.policyVersion),
            ProcessInfo.processInfo.operatingSystemVersionString, ActionContract.fingerprint,
            String(AXIsProcessTrusted()), String(CGPreflightScreenCaptureAccess())])
    }

    private func compatibilityKey(_ record: ElementRecord, action: [String: Any], on display: DisplayDescriptor) throws -> ControlCompatibilityProfiles.Key? {
        guard !AutomationTextEntryPolicy.isSecure(role: record.role, subrole: record.identity.subrole),
              let kind = ActionKind(rawValue: action["type"] as? String ?? ""),
              ControlDeliveryMethod.allCases.contains(where: { $0.permits(kind) }),
              let app = NSRunningApplication(processIdentifier: record.pid), applicationIdentity(app) == record.identity.application,
              let appID = app.bundleIdentifier, let bundleURL = app.bundleURL, let bundle = Bundle(url: bundleURL),
              let executable = bundle.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? NSNumber,
              let launched = app.launchDate, modified <= launched else { return nil }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard !version.isEmpty || !build.isEmpty else { return nil }
        let infoFiles = [bundleURL.appendingPathComponent("Contents/Info.plist"), bundleURL.appendingPathComponent("Info.plist")]
        guard let info = infoFiles.compactMap({ try? FileManager.default.attributesOfItem(atPath: $0.path) }).first,
              let infoModified = info[.modificationDate] as? Date, infoModified <= launched,
              let infoSize = info[.size] as? NSNumber else { return nil }
        var capabilities: [String: Bool] = [:]
        if kind == .press {
            var actions: CFArray?
            let result = AXUIElementCopyActionNames(record.element, &actions)
            if result == .apiDisabled { throw AccessibilityActionError.permissionDenied }
            guard result == .success else { return nil }
            capabilities["press"] = (actions as? [String] ?? []).contains(kAXPressAction as String)
        }
        if kind == .set_value || kind == .type_text {
            for name in [kAXValueAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] {
                var settable = DarwinBoolean(false)
                let result = AXUIElementIsAttributeSettable(record.element, name as CFString, &settable)
                if result == .apiDisabled { throw AccessibilityActionError.permissionDenied }
                guard [.success, .attributeUnsupported, .notImplemented].contains(result) else { return nil }
                capabilities[name] = result == .success && settable.boolValue
            }
        }
        return ControlCompatibilityProfiles.Key(appID: appID, bundlePath: bundleURL.path, version: version, build: build,
            executableRevision: "\(modified.timeIntervalSince1970):\(size.int64Value):\(infoModified.timeIntervalSince1970):\(infoSize.int64Value)", role: record.role,
            subrole: record.identity.subrole, action: kind, capabilities: capabilities,
            hid: requiresHIDFallback(record.pid), mainDisplay: display.isMain, environment: Self.compatibilityEnvironment())
    }

    private func recordCompatibility(_ evidence: ControlCompatibilityProfiles.Evidence, method: ControlDeliveryMethod,
                                     key: ControlCompatibilityProfiles.Key, record: ElementRecord,
                                     action: [String: Any], on display: DisplayDescriptor) throws {
        try TaskOwnership.check()
        guard !inputIsCancelled(), (try? compatibilityKey(record, action: action, on: display)) == key else { return }
        try ControlCompatibilityProfiles.owned { compatibilityProfiles.record(evidence, method: method, for: key) }
    }

    private func controlInteractionState(_ record: ElementRecord) -> ControlInteractionState {
        guard !AutomationTextEntryPolicy.isSecure(role: record.role, subrole: record.identity.subrole) else {
            return ControlInteractionState()
        }
        var state = ControlInteractionState(selected: boolAttribute(record.element, kAXSelectedAttribute),
                                            expanded: boolAttribute(record.element, kAXExpandedAttribute))
        if ["AXCheckBox", "AXRadioButton"].contains(record.role),
           let value = attribute(record.element, kAXValueAttribute) as? NSNumber,
           [0.0, 1.0].contains(value.doubleValue) { state.toggle = value.boolValue }
        if AutomationTextEntryPolicy.inputRoles.contains(record.role) { state.editableFocused = intendedElementHasFocus(record) }
        return state
    }

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
            window: window, depth: 0, supportsPress: false, supportsActions: false, wasFocused: true,
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
            let result = ownedAXSet(record.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
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
        switch ownedAXSet(record.element, name as CFString, value) {
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
        let profileKey = secure ? nil : try compatibilityKey(record, action: action, on: display)
        let permitted: [ControlDeliveryMethod] = action["type"] as? String == "set_value"
            ? [.accessibility_value, .accessibility_selected_text, .process_event] : [.accessibility_selected_text, .process_event]
        let preferred = try profileKey.flatMap { key in
            try ControlCompatibilityProfiles.owned { compatibilityProfiles.preferred(for: key, permitted: permitted) }
        }
        let result = try await AutomationTextEntryPolicy.enter(text: text, replacement: action["type"] as? String == "set_value", secure: secure,
            preferredMethod: preferred,
            recordDelivery: { method, delivery in
                guard let profileKey else { return }
                let evidence: ControlCompatibilityProfiles.Evidence = delivery == .unsupported ? .unsupported
                    : delivery == .accepted ? .supported : .unconfirmed
                try self.recordCompatibility(evidence, method: method, key: profileKey,
                                             record: record, action: action, on: display)
            },
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
                try LocalOperationBudget.check("text_readback")
                let deadline = ProcessInfo.processInfo.systemUptime + LocalOperationBudget.allowance(2)
                let signal = LocalChangeSignal()
                let source = await NativeChangeSubscription.accessibility(pid: record.pid, elements: [record.element], signal: signal, deadline: deadline)
                _ = try await LocalChangeWait.run(signal: signal, source: source, deadline: deadline, check: {
                    guard !self.inputIsCancelled() else { throw AccessibilityActionError.cancelled }
                    return matches()
                })
                guard !self.inputIsCancelled() else { throw AccessibilityActionError.cancelled }
                try Task.checkCancellation()
            })
        if let profileKey, let method = ControlDeliveryMethod(rawValue: result.method) {
            try recordCompatibility(result.verified ? .verified : .unconfirmed, method: method,
                                    key: profileKey, record: record, action: action, on: display)
        }
        return result
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
        try validateWorkingDocumentTarget(action: action, record: record, pid: record.pid, display: display)
    }

    private func validateWorkingDocumentTarget(action: [String: Any], record: ElementRecord?,
                                               pid: pid_t, display: DisplayDescriptor,
                                               point: CGPoint? = nil) throws {
        guard let stored = lock.withLock({ workingDocumentBinding }),
              stored.generationID == (TaskOwnership.current?.id ?? taskGenerationID) else { return }
        let refreshed = refreshWorkingDocumentBinding(stored)
        guard let binding = refreshed.binding else { throw AccessibilityActionError.workingDocumentLost }
        if refreshed.changed { installWorkingDocumentBinding(binding, generationID: binding.generationID) }
        // Other applications remain available to the task. The binding only
        // constrains actions routed into the selected document's application.
        guard pid == binding.pid else { return }
        if let record {
            let role = record.role
            let menuAction = role.hasPrefix("AXMenu") || role == "AXMenuBar"
            let expectedWindow = record.window ?? (role == "AXWindow" ? record.element : nil)
            if menuAction || action["type"] as? String == "key" {
                let focused = accessibilityElement(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
                guard let focused, window(focused, belongsTo: binding.window) else {
                    throw AccessibilityActionError.workingDocumentTargetMismatch
                }
            } else if let expectedWindow, window(expectedWindow, belongsTo: binding.window) {
                return
            } else {
                throw AccessibilityActionError.workingDocumentTargetMismatch
            }
            return
        }
        if let point {
            guard let boundFrame = frame(of: binding.window), boundFrame.contains(point) else {
                throw AccessibilityActionError.workingDocumentTargetMismatch
            }
            return
        }
        let focused = accessibilityElement(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
        guard let focused, window(focused, belongsTo: binding.window) else {
            throw AccessibilityActionError.workingDocumentTargetMismatch
        }
    }

    private func window(_ candidate: AXUIElement, belongsTo selected: AXUIElement) -> Bool {
        var current: AXUIElement? = candidate
        var visited: Set<UInt> = []
        for _ in 0..<32 {
            guard let element = current, visited.insert(CFHash(element)).inserted else { break }
            if CFEqual(element, selected) { return true }
            current = accessibilityElement(element, kAXParentAttribute)
        }
        return false
    }

    private func applicationIdentity(_ app: NSRunningApplication) -> AutomationApplicationIdentity {
        AutomationApplicationIdentity(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
            bundlePath: app.bundleURL?.path, name: app.localizedName, launchDate: app.launchDate)
    }

    private func targetIdentity(_ element: AXUIElement, application: AutomationApplicationIdentity,
                                window: AXUIElement?) -> AutomationTargetIdentity {
        var cache: [UInt: AutomationStructureNode] = [:]
        return targetIdentity(element, application: application, window: window, structure: targetStructure(element, cache: &cache))
    }

    private func targetIdentity(_ element: AXUIElement, application: AutomationApplicationIdentity,
                                window: AXUIElement?, structure: [AutomationStructureNode]) -> AutomationTargetIdentity {
        AutomationTargetIdentity(application: application,
            role: stringAttribute(element, kAXRoleAttribute) ?? "unknown",
            subrole: stringAttribute(element, kAXSubroleAttribute) ?? "",
            label: elementTitle(element), bounds: frame(of: element),
            windowTitle: window.map { elementTitle($0) }, windowBounds: window.flatMap { frame(of: $0) }, structure: structure)
    }

    /// Snapshot-local caching avoids rereading a shared panel for every child.
    /// Delivery preflight uses a fresh cache and compares the complete chain.
    private func targetStructure(_ element: AXUIElement, cache: inout [UInt: AutomationStructureNode]) -> [AutomationStructureNode] {
        var result: [AutomationStructureNode] = []
        var parent = accessibilityElement(element, kAXParentAttribute)
        var visited: Set<UInt> = [CFHash(element)]
        while let current = parent, visited.insert(CFHash(current)).inserted, result.count < 24 {
            let token = CFHash(current)
            let node: AutomationStructureNode
            if let existing = cache[token] { node = existing }
            else {
                let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] ?? []
                // Only label controls, never input values or credential fields.
                let labels = children.prefix(160).filter {
                    ["AXStaticText", "AXHeading"].contains(stringAttribute($0, kAXRoleAttribute) ?? "")
                        && !AutomationTextEntryPolicy.isSecure(role: stringAttribute($0, kAXRoleAttribute) ?? "",
                                                              subrole: stringAttribute($0, kAXSubroleAttribute) ?? "")
                }.map { label in
                    let title = elementTitle(label)
                    return title.isEmpty ? (stringAttribute(label, kAXValueAttribute) ?? "") : title
                }.filter { !$0.isEmpty }.sorted()
                node = AutomationStructureNode(identity: token, role: stringAttribute(current, kAXRoleAttribute) ?? "unknown",
                    label: elementTitle(current), bounds: frame(of: current), labels: labels)
                cache[token] = node
            }
            result.append(node)
            parent = accessibilityElement(current, kAXParentAttribute)
        }
        return result
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

    /// OCR cannot infer enabled/focus/role. Keep existing app/window checks and
    /// reject secure or disabled controls whenever native hit testing exposes them.
    func validateTextPointer(action: [String: Any], on display: DisplayDescriptor) throws {
        let point = try point(from: action, display: display)
        let pid = try actionPID(action, on: display, fallbackPoint: point)
        try ensureAllowedOnDisplay(pid, display: display)
        try validateCoordinateWindows(pid, on: display)
        guard pointerTargetIsVisible(pid, at: point, display: display) else { throw AccessibilityActionError.staleObservation }
        if let record = try observedControl(at: point, pid: pid) {
            try validateRecord(record, action: action, on: display)
            try validatePointerHit(record, at: point)
        }
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &hit) == .success,
           let hit {
            if boolAttribute(hit, kAXEnabledAttribute) == false { throw AccessibilityActionError.disabledElement }
            if AutomationTextEntryPolicy.isSecure(role: stringAttribute(hit, kAXRoleAttribute) ?? "",
                    subrole: stringAttribute(hit, kAXSubroleAttribute) ?? "") { throw AccessibilityActionError.focusMismatch }
        }
    }

    private func observedControl(at point: CGPoint, pid: pid_t) throws -> ElementRecord? {
        let containers: Set<String> = ["AXApplication", "AXWindow", "AXGroup", "AXScrollArea", "AXSplitGroup",
                                       "AXWebArea", "AXLayoutArea", "AXMenuBar", "unknown"]
        let all = lock.withLock {
            elementMap.values.filter {
                $0.pid == pid && !containers.contains($0.role) && $0.observedBounds?.contains(point) == true
            }.sorted {
                if $0.supportsPress != $1.supportsPress { return $0.supportsPress }
                let a = $0.observedBounds!, b = $1.observedBounds!
                return a.width * a.height == b.width * b.height ? $0.depth > $1.depth
                    : a.width * a.height < b.width * b.height
            }
        }
        let actionable = all.filter { $0.supportsActions || AutomationTargetPolicy.pointerControlRoles.contains($0.role) }
        let candidates = actionable.isEmpty ? all : actionable
        try AutomationTargetPolicy.validateCoordinateCandidates(count: candidates.count) { first, second in
            self.element(candidates[first].element, isWithin: candidates[second].element)
                || self.element(candidates[second].element, isWithin: candidates[first].element)
        }
        return candidates.first
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
            _ = ownedActivate(NSRunningApplication(processIdentifier: pid))
            for window in windows(of: pid)
                where frame(of: window)?.contains(point) == true {
                _ = ownedAXPress(window, kAXRaiseAction as CFString)
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
        guard let coordinates = lock.withLock({ observationCoordinates }) else {
            throw AccessibilityActionError.staleObservation
        }
        try coordinates.validate(display: display)
        return try coordinates.eventPoint(fromNormalized: CGPoint(x: nx, y: ny))
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
            try validateEventGeometry(on: display)
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
        try TaskOwnership.commit {
            defer { if let originalPointer { CGWarpMouseCursorPosition(originalPointer) } }
            try preflight()
            move.post(tap: tap)
            Thread.sleep(forTimeInterval: 0.008)
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            try AutomationTargetPolicy.deliver(preflight: preflight, event: { down.post(tap: tap) })
            Thread.sleep(forTimeInterval: Self.hidClickPressDuration)
            up.post(tap: tap)
            if double {
                Thread.sleep(forTimeInterval: 0.060)
                try preflight()
                down.setIntegerValueField(.mouseEventClickState, value: 2)
                up.setIntegerValueField(.mouseEventClickState, value: 2)
                down.post(tap: tap)
                Thread.sleep(forTimeInterval: Self.hidClickPressDuration)
                up.post(tap: tap)
            }
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
        try TaskOwnership.commit {
            defer { if let originalPointer { CGWarpMouseCursorPosition(originalPointer) } }
            try validateEventGeometry(on: display)
            let events = [move, down, dragged, up]
            for (index, event) in events.enumerated() {
                if useHID { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
                if index < events.count - 1 { Thread.sleep(forTimeInterval: 0.020) }
            }
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
            try TaskOwnership.commit {
                down.postToPid(pid)
                Thread.sleep(forTimeInterval: 0.012)
                up.postToPid(pid)
            }
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
        for modifier in modifiers {
            if let canonical = ActionContract.modifierAliases[modifier.lowercased()],
               let raw = ActionContract.modifierFlags[canonical] {
                flags.formUnion(CGEventFlags(rawValue: raw))
            }
        }
        down.flags = flags
        up.flags = flags
        try TaskOwnership.commit {
            try AutomationTargetPolicy.deliver(preflight: preflight, event: { down.postToPid(pid) })
            Thread.sleep(forTimeInterval: 0.018)
            up.postToPid(pid)
        }
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
        try TaskOwnership.commit {
            down.postToPid(pid)
            Thread.sleep(forTimeInterval: 0.012)
            up.postToPid(pid)
        }
    }

    @discardableResult
    private func postScroll(
        to pid: pid_t,
        point: CGPoint,
        deltaX: Int,
        deltaY: Int,
        on display: DisplayDescriptor,
        preflight: () throws -> Void = {},
        onResolvedPoint: ((CGPoint) -> Void)? = nil
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
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw AccessibilityActionError.activationFailed
        }
        onResolvedPoint?(resolvedPoint)
        let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                           mouseCursorPosition: resolvedPoint, mouseButton: .left)
        try TaskOwnership.commit {
            defer { if let originalPointer { CGWarpMouseCursorPosition(originalPointer) } }
            try validateEventGeometry(on: display)
            try preflight()
            move?.post(tap: .cgSessionEventTap)
            Thread.sleep(forTimeInterval: 0.025)
            try validateEventGeometry(on: display)
            try preflight()
            event.location = resolvedPoint
            event.post(tap: .cgSessionEventTap)
        }
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
        _ = ownedActivate(target)
        // Agent actions have already awaited confirmed activation in
        // beginVerifiedInput. Viewer input must never block the main run loop.
        return previous?.processIdentifier == pid ? nil : previous
    }

    private func restoreFrontmostApplication(
        _ application: NSRunningApplication?,
        after delay: TimeInterval,
        targetPID: pid_t
    ) {
        let taskLease = TaskOwnership.current ?? lock.withLock { self.taskLease }

        guard let application,
              application.processIdentifier != controllerPID,
              !application.isTerminated else { return }
        lock.lock()
        let generation = inputGeneration
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            TaskOwnership.callback(taskLease) {
                guard let self else { return }
                self.lock.lock()
                let currentGeneration = self.inputGeneration
                self.lock.unlock()
                guard !application.isTerminated,
                      AutomationInputPolicy.shouldRestore(scheduledGeneration: generation, currentGeneration: currentGeneration,
                        targetPID: targetPID, currentPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                        previousPID: application.processIdentifier), !self.hasOpenMenu(targetPID) else { return }
                _ = ownedActivate(application)
            }
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        guard (try? TaskOwnership.check()) != nil else { return nil }
        if ObservationAccessibilityReads.current == nil, let budget = LocalOperationBudget.current {
            guard budget.remaining > 0 else { return nil }
            AXUIElementSetMessagingTimeout(element, Float(min(0.08, budget.remaining)))
        }
        defer { if ObservationAccessibilityReads.current == nil, LocalOperationBudget.current != nil { AXUIElementSetMessagingTimeout(element, 0) } }
        var value: CFTypeRef?
        let result: AXError
        if let read = ObservationAccessibilityReads.current {
            result = read.read(element, attribute: name, required: name == kAXRoleAttribute) {
                AXUIElementCopyAttributeValue(element, name as CFString, &value)
            }
        } else { result = AXUIElementCopyAttributeValue(element, name as CFString, &value) }
        guard result == .success else {
            return nil
        }
        if name == kAXRoleAttribute, (value as? String)?.isEmpty != false {
            ObservationAccessibilityReads.current?.report("accessibility_incomplete", name, nil)
        } else if name == kAXSubroleAttribute, value != nil, !(value is String) {
            ObservationAccessibilityReads.current?.report("accessibility_incomplete", name, nil)
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

    private static func taskResultWebURL(_ value: Any?) -> URL? {
        let raw: String?
        if let value = value as? String {
            raw = value
        } else if let value = value as? URL {
            raw = value.absoluteString
        } else if let value = value as? NSURL {
            raw = value.absoluteString
        } else {
            raw = nil
        }
        guard let raw, !raw.isEmpty, raw.utf8.count <= 4096,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        return url
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
        let result = ObservationAccessibilityReads.current.map { read in
            read.read(element, attribute: "AXActions") { AXUIElementCopyActionNames(element, &names) }
        } ?? AXUIElementCopyActionNames(element, &names)
        guard result == .success else { return [] }
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


private func ownedAXSet(_ element: AXUIElement, _ name: CFString, _ value: CFTypeRef) -> AXError {
    TaskOwnership.permitted(.cannotComplete) { AXUIElementSetAttributeValue(element, name, value) }
}
private func ownedAXPress(_ element: AXUIElement, _ action: CFString) -> AXError {
    TaskOwnership.permitted(.cannotComplete) { AXUIElementPerformAction(element, action) }
}
private func ownedActivate(_ app: NSRunningApplication?) -> Bool {
    TaskOwnership.permitted(false) { app?.activate(options: [.activateAllWindows]) ?? false }
}
private func ownedActivateAsync(_ app: NSRunningApplication) async throws -> Bool {
    while true {
        try await TaskOwnership.checkpoint()
        do { return try await MainActor.run { try TaskOwnership.commit { app.activate(options: [.activateAllWindows]) } } }
        catch { if TaskOwnership.current?.state != .paused { throw error } }
    }
}
private func ownedOpenApplication(_ workspace: NSWorkspace, at url: URL, configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication {
    try await TaskOwnership.checkpoint()
    return try await withCheckedThrowingContinuation { continuation in
        do {
            try TaskOwnership.commit {
                workspace.openApplication(at: url, configuration: configuration) { app, error in
                    if let app { continuation.resume(returning: app) }
                    else { continuation.resume(throwing: error ?? AccessibilityActionError.elementUnavailable) }
                }
            }
        } catch { continuation.resume(throwing: error) }
    }
}
