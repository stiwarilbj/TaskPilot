import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class TaskPilotCoordinator: ObservableObject {
    // MARK: - Stable preferences

    // Accessibility authorization is granted only in System Settings. Calling
    // AXIsProcessTrustedWithOptions(prompt: true) adds a redundant modal that
    // can be stranded on a virtual display even after the Settings toggle is On.
    nonisolated static let accessibilityPermissionUsesSettingsOnly = true
    nonisolated static let geminiAPIKeyVisibilityPreferenceKey =
        "OrbitAgent.isGeminiAPIKeyVisible"

    nonisolated static func initialGeminiAPIKeyVisibility(
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        userDefaults.object(forKey: geminiAPIKeyVisibilityPreferenceKey) as? Bool ?? true
    }

    nonisolated static func completeGeminiAPIKey(from value: String) -> String? {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.count >= 20 ? key : nil
    }

    enum PrivacyPane: String {
        case accessibility = "Privacy_Accessibility"
        case screenCapture = "Privacy_ScreenCapture"
    }

    enum RunState: Equatable {
        case idle
        case running
        case paused
        case waitingForUser
        case takingOver
        case stopping
        case failed
        case completed
    }

    // MARK: - Observable app state

    @Published var prompt = ""
    @Published private(set) var runState: RunState = .idle
    @Published private(set) var status = "Checking your agent screen…"
    @Published private(set) var agentDisplay: DisplayDescriptor?
    @Published private(set) var backgroundAgentDisplay: DisplayDescriptor?
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var captureAuthorization: ScreenCaptureAuthorization = .denied
    @Published private(set) var runtimeInstalled = false
    @Published private(set) var openClawInstalled = false
    @Published private(set) var openClawConfigured = false
    @Published private(set) var openClawVersion = ""
    @Published private(set) var openClawDetail = "Checking OpenClaw…"
    @Published var showingAutomatedOpenClawSetup = false
    @Published var geminiAPIKeyDraft = "" {
        didSet {
            let key = geminiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key != savedGeminiAPIKey else { return }
            geminiAPIKeyVerified = false
            geminiModelChecks = OpenClawService.allGeminiModels.map {
                GeminiModelCheck(model: $0, state: .waiting)
            }
            if key.isEmpty {
                geminiAPIKeyStatus = hasSavedGeminiAPIKey
                    ? "The previously saved key is still retained. Paste a replacement or click Clear API Key."
                    : "Paste a Gemini API key, then click Save or Check."
            } else if Self.completeGeminiAPIKey(from: key) == nil {
                geminiAPIKeyStatus = "Keep typing — this API key is not complete yet."
            } else {
                geminiAPIKeyStatus = hasSavedGeminiAPIKey
                    ? "This key has unsaved changes. Click Save, or Check to save it only after a model works."
                    : "Click Save to keep this key now, or Check to save it only after a model works."
            }
        }
    }
    @Published var isGeminiAPIKeyVisible = TaskPilotCoordinator.initialGeminiAPIKeyVisibility() {
        didSet {
            UserDefaults.standard.set(
                isGeminiAPIKeyVisible,
                forKey: TaskPilotCoordinator.geminiAPIKeyVisibilityPreferenceKey
            )
        }
    }
    @Published private(set) var hasSavedGeminiAPIKey = false
    @Published private(set) var isCheckingGeminiModels = false
    @Published private(set) var geminiAPIKeyVerified = false
    @Published private(set) var geminiAPIKeyStatus = "Paste a Gemini API key to save or check it."
    @Published private(set) var geminiModelChecks = OpenClawService.allGeminiModels.map {
        GeminiModelCheck(model: $0, state: .waiting)
    }
    @Published private(set) var isAutomatingOpenClawSetup = false
    @Published private(set) var automatedOpenClawProgress = 0.0
    @Published private(set) var automatedOpenClawMessage = "Ready to install OpenClaw."
    @Published private(set) var automatedOpenClawError = ""
    @Published private(set) var automatedOpenClawSucceeded = false
    @Published private(set) var automatedOpenClawInstalledOnly = false
    @Published private(set) var betterDisplayInstalled = false
    @Published private(set) var isCreatingDisplay = false
    @Published private(set) var isResettingDisplay = false
    @Published private(set) var isRepairingPermissions = false
    @Published private(set) var taskOutput: AgentTaskOutput?
    @Published private(set) var userInputRequest: AgentUserInputRequest?
    @Published var userInputDraft = ""
    @Published private(set) var queuedTasks: [QueuedAgentTask] = []
    @Published private(set) var taskHistory: [AgentTaskHistoryEntry] = []
    @Published private(set) var currentTaskRequest: String?
    @Published var showingSetup = false
    @Published private(set) var runsOnMainDisplay = UserDefaults.standard.bool(
        forKey: "OrbitAgent.runsOnMainDisplay"
    )
    @Published private(set) var closesTaskAppsAfterUse =
        UserDefaults.standard.object(forKey: "OrbitAgent.closesTaskAppsAfterUse") as? Bool ?? true
    @Published private(set) var completionNotificationsEnabled =
        UserDefaults.standard.bool(forKey: CompletionNotificationService.preferenceKey)
    @Published private(set) var hasCompletedSetup = UserDefaults.standard.bool(
        forKey: "OrbitAgent.hasCompletedSetup"
    )
    @Published private(set) var windowsPresentedOnMain = false
    @Published private(set) var isClearingAgentScreen = false

    // MARK: - Dependencies and private state

    private let displayService = DisplayService()
    private let agentCursor = AgentCursorOverlayController()
    private lazy var accessibility = AccessibilityController(agentCursor: agentCursor)
    private let capture = ScreenCaptureService()
    private(set) lazy var viewer = AgentScreenViewerModel(capture: capture)
    private let bundledRuntime = BundledRuntimeLocator()
    private let openClawService = OpenClawService()
    private let geminiAPIKeyStore = GeminiAPIKeyStore()
    private let geminiModelVerifier = GeminiModelVerifier()
    private let taskLedgerStore = AgentTaskLedgerStore()
    private var savedGeminiAPIKey = ""
    private let betterDisplay = BetterDisplayService()
    private let completionNotifications = CompletionNotificationService()
    private lazy var bridge = AgentAutomationBridge(
        displayService: displayService,
        accessibility: accessibility,
        capture: capture
    )
    private lazy var runtime = AgentRuntimeProcess(bridge: bridge)
    private var takeoverPlacements: [WindowPlacement] = []
    private var mainDisplayModePlacements: [WindowPlacement] = []
    private var openClawExecutableURL: URL?
    private var lastOpenClawProbeAt = Date.distantPast
    private var readinessStatusSuppressedUntil = Date.distantPast
    private var permissionMonitorTask: Task<Void, Never>?
    private var notificationEnablePending = false
    private var currentTaskStartedAt: Date?
    private var currentTaskWasQueued = false
    private var completedQueuedTaskCount = 0

    // MARK: - Derived readiness

    var isReady: Bool {
        agentDisplay != nil && hasAccessibilityPermission &&
        captureAuthorization == .authorized && runtimeInstalled && openClawConfigured
    }

    var canViewAgentScreen: Bool {
        captureAuthorization == .authorized
    }

    var canStart: Bool {
        isReady && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !windowsPresentedOnMain && [.idle, .failed, .completed].contains(runState)
    }

    var canQueueCurrentPrompt: Bool {
        isActive && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var geminiAPIKeyLooksComplete: Bool {
        geminiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20
    }

    var geminiAPIKeyIsEmpty: Bool {
        geminiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canBeginOpenClawAutomation: Bool {
        if openClawInstalled {
            return geminiAPIKeyLooksComplete
        }
        return geminiAPIKeyIsEmpty || geminiAPIKeyLooksComplete
    }

    var canSaveGeminiAPIKey: Bool {
        geminiAPIKeyLooksComplete && !geminiAPIKeyMatchesSavedKey && !isCheckingGeminiModels
    }

    var canCheckGeminiModels: Bool {
        geminiAPIKeyLooksComplete && !isCheckingGeminiModels
    }

    var geminiAPIKeyMatchesSavedKey: Bool {
        hasSavedGeminiAPIKey &&
        geminiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines) == savedGeminiAPIKey
    }

    var allGeminiModelsWorking: Bool {
        geminiAPIKeyVerified &&
        geminiModelChecks.count == OpenClawService.allGeminiModels.count &&
        geminiModelChecks.allSatisfy {
            if case .working = $0.state { return true }
            return false
        }
    }

    nonisolated static func workingGeminiModelCount(
        _ checks: [GeminiModelCheck]
    ) -> Int {
        checks.filter {
            if case .working = $0.state { return true }
            return false
        }.count
    }

    nonisolated static func hasUsableGeminiModel(
        _ checks: [GeminiModelCheck]
    ) -> Bool {
        workingGeminiModelCount(checks) > 0
    }

    var hasWorkingGeminiModel: Bool {
        geminiAPIKeyVerified && Self.hasUsableGeminiModel(geminiModelChecks)
    }

    var hasGeminiModelCheckFailure: Bool {
        // One responsive model is enough because TaskPilot's runtime skips any
        // failed entry and rotates to the next model in the five-model list.
        if hasWorkingGeminiModel { return false }
        let hasFailedModel = geminiModelChecks.contains {
            if case .failed = $0.state { return true }
            return false
        }
        let checkFinished = geminiModelChecks.count == OpenClawService.allGeminiModels.count &&
            geminiModelChecks.allSatisfy {
                switch $0.state {
                case .working, .failed: return true
                case .waiting, .checking: return false
                }
            }
        return hasFailedModel || (checkFinished && !geminiAPIKeyVerified)
    }

    var isActive: Bool {
        [.running, .paused, .waitingForUser, .takingOver, .stopping].contains(runState)
    }

    var canSubmitUserInput: Bool {
        userInputRequest != nil &&
        !userInputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Lifecycle

    init() {
        do {
            let ledger = try taskLedgerStore.load()
            queuedTasks = ledger.queue
            taskHistory = ledger.history.sorted { $0.finishedAt > $1.finishedAt }
        } catch {
            status = "\(TaskPilotIdentity.displayName) could not load Queue & History: \(error.localizedDescription)"
        }
        do {
            if let loadedKey = try geminiAPIKeyStore.load(),
               let completeKey = Self.completeGeminiAPIKey(from: loadedKey) {
                savedGeminiAPIKey = completeKey
                geminiAPIKeyDraft = completeKey
                hasSavedGeminiAPIKey = true
                geminiAPIKeyStatus = "Loaded automatically from \(TaskPilotIdentity.displayName)'s private app data. Click Check to test the model rotation."
            }
        } catch {
            geminiAPIKeyStatus = "\(TaskPilotIdentity.displayName) could not load its saved Gemini API key: \(error.localizedDescription)"
        }
        agentCursor.onPresentation = { [weak self] presentation in
            Task { @MainActor [weak self] in
                self?.viewer.showAgentCursor(presentation)
            }
        }
        viewer.interactionHandler = { [weak self] interaction, display in
            guard let self else { return "Live control disconnected" }
            return try self.accessibility.performViewerInteraction(interaction, on: display)
        }
    }

    // MARK: - Setup and readiness

    func showSettings() {
        showingSetup = true
    }

    func refreshReadiness(
        showSetupWhenNeeded: Bool = false,
        verifyCapture: Bool = false
    ) async {
        let accessibilityPermission = AXIsProcessTrusted()
        let captureStatus = await capture.authorizationStatus(verifyPixels: verifyCapture)
        let screenRecordingPermission: Bool
        switch captureStatus {
        case .authorized, .restartRequired:
            screenRecordingPermission = true
        case .denied, .unavailable:
            screenRecordingPermission = false
        }
        let bundledRuntimeInstalled = bundledRuntime.isInstalled
        let openClawProbe: OpenClawProbe?
        if Date().timeIntervalSince(lastOpenClawProbeAt) >= 15 {
            lastOpenClawProbeAt = Date()
            openClawProbe = await openClawService.probe()
        } else {
            openClawProbe = nil
        }
        let installedBetterDisplay = betterDisplay.isInstalled
        let detectedBackgroundDisplay = displayService.agentDisplay()
        let detectedAgentDisplay = runsOnMainDisplay
            ? displayService.mainDisplay()
            : detectedBackgroundDisplay

        if hasAccessibilityPermission != accessibilityPermission {
            hasAccessibilityPermission = accessibilityPermission
        }
        if hasScreenRecordingPermission != screenRecordingPermission {
            hasScreenRecordingPermission = screenRecordingPermission
        }
        if captureAuthorization != captureStatus {
            captureAuthorization = captureStatus
        }
        if runtimeInstalled != bundledRuntimeInstalled {
            runtimeInstalled = bundledRuntimeInstalled
        }
        if let openClawProbe {
            openClawExecutableURL = openClawProbe.executableURL
            openClawInstalled = openClawProbe.installed
            openClawConfigured = openClawProbe.configured
            openClawVersion = openClawProbe.version
            openClawDetail = openClawProbe.detail
        }
        if betterDisplayInstalled != installedBetterDisplay {
            betterDisplayInstalled = installedBetterDisplay
        }
        if agentDisplay != detectedAgentDisplay {
            agentDisplay = detectedAgentDisplay
        }
        if backgroundAgentDisplay != detectedBackgroundDisplay {
            backgroundAgentDisplay = detectedBackgroundDisplay
        }

        // Preserve completed and failed task messages until the user starts a
        // new task. Readiness polling should only own the idle status text.
        if runState == .idle && Date() >= readinessStatusSuppressedUntil {
            let refreshedStatus: String
            if isReady {
                refreshedStatus = "Ready on \(agentDisplay?.name ?? "agent screen")"
            } else {
                refreshedStatus = readinessSummary
            }
            if status != refreshedStatus {
                status = refreshedStatus
            }
        }
        // Migrate existing users automatically: if every real prerequisite is
        // already present, the one-time setup has in fact been completed even
        // if this preference did not exist in an older TaskPilot build.
        if isReady && !hasCompletedSetup {
            hasCompletedSetup = true
            UserDefaults.standard.set(true, forKey: "OrbitAgent.hasCompletedSetup")
        }
        if showSetupWhenNeeded && !isReady && !hasCompletedSetup {
            showingSetup = true
        }
        if notificationEnablePending,
           await completionNotifications.authorizationState() == .allowed {
            notificationEnablePending = false
            completionNotificationsEnabled = true
            UserDefaults.standard.set(true, forKey: CompletionNotificationService.preferenceKey)
            pinStatus("Notifications are On — \(TaskPilotIdentity.displayName) will alert you when a task finishes or needs a password")
        }
        startNextQueuedTaskIfPossible()
    }

    func finishSetup() {
        hasCompletedSetup = true
        UserDefaults.standard.set(true, forKey: "OrbitAgent.hasCompletedSetup")
        showingSetup = false
        if isReady {
            pinStatus("Setup complete — \(TaskPilotIdentity.displayName) will quietly reuse these permissions next time")
        } else {
            pinStatus("Settings saved. \(readinessSummary); Run stays locked until setup is ready.", for: 30)
        }
    }

    private var readinessSummary: String {
        if !runtimeInstalled { return "The bundled OpenClaw bridge is missing" }
        if !openClawInstalled { return "Install OpenClaw to finish setup" }
        if !openClawConfigured { return "Configure OpenClaw with the guided Gemini setup" }
        if !hasAccessibilityPermission { return "Allow Accessibility control" }
        if !hasScreenRecordingPermission {
            if case .unavailable = captureAuthorization {
                return "Capture access needs repair in Setup"
            }
            return "Allow application, window, and display capture"
        }
        if case .restartRequired = captureAuthorization {
            return "Capture is On — click Recheck to reopen \(TaskPilotIdentity.displayName) and finish applying it"
        }
        if agentDisplay == nil { return "Create or connect an agent screen" }
        return "Setup required"
    }

    // MARK: - OpenClaw and Gemini setup

    func openOpenClawInstallGuide() {
        openClawService.openInstallGuide()
        pinStatus("Opened the official OpenClaw install guide", for: 20)
    }

    func beginAutomatedOpenClawSetup() {
        guard !isAutomatingOpenClawSetup else { return }
        automatedOpenClawProgress = 0
        automatedOpenClawMessage = openClawInstalled
            ? "Ready to configure this OpenClaw installation."
            : "Ready to install OpenClaw."
        automatedOpenClawError = ""
        automatedOpenClawSucceeded = false
        automatedOpenClawInstalledOnly = false
        showingAutomatedOpenClawSetup = true
    }

    func saveGeminiAPIKey() {
        guard let key = Self.completeGeminiAPIKey(from: geminiAPIKeyDraft) else {
            geminiAPIKeyStatus = "Enter a complete Gemini API key before clicking Save."
            return
        }
        do {
            try geminiAPIKeyStore.save(key)
            savedGeminiAPIKey = key
            geminiAPIKeyDraft = key
            hasSavedGeminiAPIKey = true
            geminiAPIKeyVerified = false
            geminiModelChecks = OpenClawService.allGeminiModels.map {
                GeminiModelCheck(model: $0, state: .waiting)
            }
            geminiAPIKeyStatus = "Saved in \(TaskPilotIdentity.displayName) on this Mac without checking the models. Click Check whenever you want to verify it."
            pinStatus("Gemini API key saved in \(TaskPilotIdentity.displayName)")
        } catch {
            geminiAPIKeyStatus = "\(TaskPilotIdentity.displayName) could not save this key: \(error.localizedDescription)"
            pinStatus("Could not save the Gemini API key: \(error.localizedDescription)", for: 30)
        }
    }

    func clearGeminiAPIKey() {
        guard !isCheckingGeminiModels else { return }
        do {
            try geminiAPIKeyStore.delete()
            savedGeminiAPIKey = ""
            geminiAPIKeyDraft = ""
            hasSavedGeminiAPIKey = false
            geminiAPIKeyVerified = false
            geminiAPIKeyStatus = "The saved Gemini API key was cleared."
            geminiModelChecks = OpenClawService.allGeminiModels.map {
                GeminiModelCheck(model: $0, state: .waiting)
            }
            pinStatus("Saved Gemini API key cleared")
        } catch {
            geminiAPIKeyStatus = error.localizedDescription
            pinStatus("Could not clear the Gemini API key: \(error.localizedDescription)", for: 30)
        }
    }

    func checkGeminiModels() {
        guard !isCheckingGeminiModels else { return }
        let apiKey = geminiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.count >= 20 else {
            geminiAPIKeyStatus = "Enter a complete Gemini API key before clicking Check."
            return
        }
        let wasAlreadySaved = hasSavedGeminiAPIKey && apiKey == savedGeminiAPIKey

        isCheckingGeminiModels = true
        geminiAPIKeyVerified = false
        geminiAPIKeyStatus = "Sending five simple requests — one to each Gemini model…"
        geminiModelChecks = OpenClawService.allGeminiModels.map {
            GeminiModelCheck(model: $0, state: .checking)
        }
        Task {
            let results = await geminiModelVerifier.verify(
                apiKey: apiKey,
                models: OpenClawService.allGeminiModels
            )
            geminiModelChecks = results
            isCheckingGeminiModels = false
            let workingCount = Self.workingGeminiModelCount(results)
            if workingCount > 0 {
                do {
                    try geminiAPIKeyStore.save(apiKey)
                    savedGeminiAPIKey = apiKey
                    geminiAPIKeyDraft = apiKey
                    hasSavedGeminiAPIKey = true
                    geminiAPIKeyVerified = true
                    geminiAPIKeyStatus = workingCount == results.count
                        ? "All five Gemini models responded, so Check saved the API key in \(TaskPilotIdentity.displayName)."
                        : "\(workingCount) of \(results.count) Gemini models responded, so Check saved the key. \(TaskPilotIdentity.displayName) will skip unavailable models automatically."
                } catch {
                    geminiAPIKeyVerified = false
                    geminiAPIKeyStatus = "At least one model responded, but the API key could not be saved: \(error.localizedDescription)"
                }
            } else {
                geminiAPIKeyVerified = false
                geminiAPIKeyStatus = wasAlreadySaved
                    ? "None of the five models responded. The previously saved copy remains unchanged; review the results below."
                    : "None of the five models responded, so Check did not save this key. Review the results below or use Save to keep it without verification."
            }
            pinStatus(geminiAPIKeyStatus, for: 30)
        }
    }

    func startAutomatedOpenClawSetup() {
        guard !isAutomatingOpenClawSetup else { return }
        let key = geminiAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty || key.count >= 20 else {
            automatedOpenClawError = "Enter a complete Gemini API key from Google AI Studio."
            return
        }
        guard !openClawInstalled || !key.isEmpty else {
            automatedOpenClawError = "OpenClaw is already installed. Add a Gemini API key to configure it, or click Cancel and return later."
            return
        }

        isAutomatingOpenClawSetup = true
        automatedOpenClawProgress = 0.02
        automatedOpenClawMessage = "Starting private OpenClaw setup…"
        automatedOpenClawError = ""
        automatedOpenClawSucceeded = false
        automatedOpenClawInstalledOnly = false
        pinStatus(key.isEmpty ? "Installing OpenClaw…" : "Installing and configuring OpenClaw…", for: 60 * 20)

        do {
            if !key.isEmpty {
                // The guided installer and normal Run path must use the same
                // app-owned credential. Saving it here also means the
                // key remains available when installation finishes or the app
                // is reopened; Check can validate all five models afterward.
                try geminiAPIKeyStore.save(key)
                savedGeminiAPIKey = key
                hasSavedGeminiAPIKey = true
                geminiAPIKeyVerified = false
            }
            try openClawService.startAutomatedSetup(geminiAPIKey: key) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleAutomatedOpenClawEvent(event)
                }
            }
            // The installer receives the key only through stdin; the durable
            // copy is TaskPilot's owner-only Application Support file.
            // Keep the masked value in the field as requested so Show can
            // reveal the currently saved key without making the user retype it.
            geminiAPIKeyDraft = key
        } catch {
            isAutomatingOpenClawSetup = false
            automatedOpenClawError = error.localizedDescription
            pinStatus("OpenClaw setup could not start: \(error.localizedDescription)", for: 30)
        }
    }

    func cancelAutomatedOpenClawSetup() {
        guard isAutomatingOpenClawSetup else { return }
        automatedOpenClawMessage = "Stopping OpenClaw setup…"
        openClawService.cancelAutomatedSetup()
    }

    private func handleAutomatedOpenClawEvent(_ event: OpenClawAutomatedSetupEvent) {
        switch event {
        case let .progress(progress, message):
            automatedOpenClawProgress = progress
            automatedOpenClawMessage = message
        case let .installed(message):
            isAutomatingOpenClawSetup = false
            automatedOpenClawProgress = 1
            automatedOpenClawMessage = message
            automatedOpenClawError = ""
            automatedOpenClawSucceeded = false
            automatedOpenClawInstalledOnly = true
            lastOpenClawProbeAt = .distantPast
            Task {
                await refreshReadiness()
                pinStatus("OpenClaw is installed. Add a Gemini API key later to unlock Run.", for: 30)
            }
        case let .completed(message):
            isAutomatingOpenClawSetup = false
            automatedOpenClawProgress = 1
            automatedOpenClawMessage = message
            automatedOpenClawError = ""
            automatedOpenClawSucceeded = true
            automatedOpenClawInstalledOnly = false
            lastOpenClawProbeAt = .distantPast
            Task {
                await refreshReadiness()
                pinStatus(openClawConfigured
                    ? "OpenClaw and the Gemini model chain are installed, running, and verified"
                    : "OpenClaw finished setup; click Recheck if readiness is still updating",
                    for: 30)
            }
        case let .failed(message):
            isAutomatingOpenClawSetup = false
            automatedOpenClawError = message
            automatedOpenClawMessage = "Setup needs attention."
            automatedOpenClawInstalledOnly = false
            pinStatus("OpenClaw setup needs attention: \(message)", for: 45)
        }
    }

    func openOpenClawSetup() {
        do {
            try openClawService.openSetupTerminal()
            pinStatus("OpenClaw setup opened in Terminal — finish model setup, then click Recheck", for: 30)
        } catch {
            pinStatus("Could not open OpenClaw setup: \(error.localizedDescription)", for: 30)
        }
    }

    func openOpenClawDashboard() {
        pinStatus("Starting OpenClaw and opening its authenticated dashboard…")
        Task {
            do {
                try await openClawService.openDashboard()
                lastOpenClawProbeAt = .distantPast
                await refreshReadiness()
                pinStatus("Opened the authenticated local OpenClaw dashboard")
            } catch {
                pinStatus("Could not open the OpenClaw dashboard: \(error.localizedDescription)", for: 30)
            }
        }
    }

    func recheckOpenClaw() {
        lastOpenClawProbeAt = .distantPast
        pinStatus("Rechecking OpenClaw…")
        Task {
            await refreshReadiness()
            pinStatus(openClawConfigured
                ? "OpenClaw is ready — \(TaskPilotIdentity.displayName) will use its configured model, memory, and tools"
                : openClawDetail,
                for: 25)
        }
    }

    // MARK: - macOS permissions

    func requestAccessibility() {
        if AXIsProcessTrusted() {
            Task { await refreshReadiness() }
            pinStatus("Accessibility control is already On")
            return
        }
        pinStatus("Opening Accessibility Settings for this \(TaskPilotIdentity.displayName) build…", for: 30)
        // System Settings is the source of truth. Do not also ask macOS to
        // create its informational Accessibility modal: that modal grants
        // nothing itself and can remain above the agent display after the
        // Settings switch has already been enabled.
        openAccessibilitySettings()
    }

    func requestScreenRecording() {
        if CGPreflightScreenCaptureAccess() {
            Task { await refreshReadiness(verifyCapture: true) }
            pinStatus("Application, window, and display capture are already On")
            return
        }
        pinStatus("Requesting application, window, and display capture for this \(TaskPilotIdentity.displayName) build…", for: 30)
        // CGRequestScreenCaptureAccess owns native permission UI. Request it
        // from the main app interaction after TaskPilot's alert has disappeared;
        // background requests may not register the app in macOS Settings.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            let granted = CGRequestScreenCaptureAccess()
            self.openScreenRecordingSettings()
            await self.refreshReadiness()
            if granted {
                self.pinStatus(self.permissionStatusSummary, for: 20)
            }
        }
    }

    func openScreenRecordingSettings() {
        openPrivacyPane(
            .screenCapture,
            successMessage: "Capture Settings opened. Turn on \(TaskPilotIdentity.displayName), then return here; this page will update automatically."
        )
    }

    func openAccessibilitySettings() {
        openPrivacyPane(
            .accessibility,
            successMessage: "Accessibility Settings opened. Turn on \(TaskPilotIdentity.displayName), then return here; this page will update automatically."
        )
    }

    func recheckPermissions() {
        pinStatus("Rechecking this exact \(TaskPilotIdentity.displayName) build…")
        Task {
            await refreshReadiness(verifyCapture: true)
            if case .restartRequired = captureAuthorization {
                pinStatus("Permissions are On — reopening \(TaskPilotIdentity.displayName) to apply them…")
                await relaunchForPermissions()
            } else if hasAccessibilityPermission && captureAuthorization == .authorized {
                pinStatus("Control plus application, window, and display capture are On")
            } else if !hasAccessibilityPermission && hasScreenRecordingPermission {
                pinStatus("Capture is On, but Accessibility control is still Off for this exact build. Open Control Settings or repair stale entries.")
            } else if hasAccessibilityPermission && !hasScreenRecordingPermission {
                pinStatus("Accessibility control is On, but application, window, and display capture are still Off for this exact build.")
            } else {
                pinStatus("This exact build is still denied. If Settings already says On, click Repair stale entries once.")
            }
        }
    }

    func repairStalePermissions() {
        guard !isRepairingPermissions else { return }
        isRepairingPermissions = true
        pinStatus("Removing stale \(TaskPilotIdentity.displayName) permission entries…")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.orbitagent.controller"
        Task {
            let failures = await Task.detached(priority: .userInitiated) {
                ["Accessibility", "ScreenCapture"].compactMap { service -> String? in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                    process.arguments = ["reset", service, bundleID]
                    do {
                        try process.run()
                        process.waitUntilExit()
                        return process.terminationStatus == 0 ? nil : service
                    } catch {
                        return service
                    }
                }
            }.value
            isRepairingPermissions = false
            if failures.isEmpty {
                hasAccessibilityPermission = false
                hasScreenRecordingPermission = false
                captureAuthorization = .denied
                pinStatus("Stale entries removed. Turn \(TaskPilotIdentity.displayName) on in Accessibility, then in Capture Settings.", for: 20)
                openAccessibilitySettings()
            } else {
                pinStatus("Could not reset \(failures.joined(separator: " and ")); open both Settings panes manually")
            }
        }
    }

    private func relaunchForPermissions() async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: configuration
            )
            NSApp.terminate(nil)
        } catch {
            pinStatus("Permissions are On, but \(TaskPilotIdentity.displayName) could not reopen automatically: \(error.localizedDescription)")
        }
    }

    private func pinStatus(_ message: String, for seconds: TimeInterval = 10) {
        status = message
        readinessStatusSuppressedUntil = Date().addingTimeInterval(seconds)
    }

    nonisolated static func privacySettingsURL(for pane: PrivacyPane) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")
    }

    private func openPrivacyPane(_ pane: PrivacyPane, successMessage: String) {
        guard let url = Self.privacySettingsURL(for: pane) else {
            pinStatus("Could not create the macOS Privacy & Security Settings link")
            return
        }

        pinStatus("Opening macOS Privacy & Security…", for: 30)
        startPermissionMonitor()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open(url, configuration: configuration) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.pinStatus("Could not open macOS Privacy & Security: \(error.localizedDescription)", for: 30)
                } else {
                    self.pinStatus(successMessage, for: 30)
                }
            }
        }
    }

    private func startPermissionMonitor() {
        permissionMonitorTask?.cancel()
        permissionMonitorTask = Task { [weak self] in
            for _ in 0..<90 {
                guard let self, !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }

                let previousAccessibility = self.hasAccessibilityPermission
                let previousCapture = self.hasScreenRecordingPermission
                let previousAuthorization = self.captureAuthorization
                await self.refreshReadiness()

                let changed = previousAccessibility != self.hasAccessibilityPermission ||
                    previousCapture != self.hasScreenRecordingPermission ||
                    previousAuthorization != self.captureAuthorization
                if changed {
                    self.pinStatus(self.permissionStatusSummary, for: 20)
                }
                if self.hasAccessibilityPermission && self.captureAuthorization == .authorized {
                    return
                }
            }
        }
    }

    private var permissionStatusSummary: String {
        if hasAccessibilityPermission && captureAuthorization == .authorized {
            return "Accessibility control plus application, window, and display capture are On"
        }
        if case .restartRequired = captureAuthorization {
            return hasAccessibilityPermission
                ? "All switches are On. Click Recheck so \(TaskPilotIdentity.displayName) can reopen and apply capture access."
                : "Capture is On. Accessibility control still needs to be enabled for this exact build."
        }
        if hasAccessibilityPermission {
            return "Accessibility control is On. Screen capture is still Off for this exact build."
        }
        if hasScreenRecordingPermission {
            return "Screen capture is On. Accessibility control is still Off for this exact build."
        }
        return "\(TaskPilotIdentity.displayName) is still waiting for Accessibility and Screen Recording permission"
    }

    // MARK: - Displays, cleanup, and notifications

    func createAgentDisplay() {
        guard !isCreatingDisplay else { return }
        if !betterDisplay.isInstalled {
            betterDisplay.openDownloadPage()
            pinStatus("Install BetterDisplay, then return here")
            return
        }
        isCreatingDisplay = true
        pinStatus("Creating the background agent screen…")
        Task {
            do {
                try await betterDisplay.createAgentScreen()
                try? await Task.sleep(for: .seconds(3))
                await refreshReadiness()
                pinStatus(backgroundAgentDisplay == nil
                    ? "Enable BetterDisplay Settings → Application → Integration, then retry"
                    : "Agent screen ready")
            } catch {
                pinStatus("Could not create the agent screen: \(error.localizedDescription)")
            }
            isCreatingDisplay = false
        }
    }

    func resetAgentDisplay() {
        guard !isResettingDisplay else { return }
        isResettingDisplay = true
        if isActive { stop() }
        viewer.stop()
        agentCursor.hide()

        if let background = backgroundAgentDisplay,
           let main = displayService.mainDisplay() {
            _ = accessibility.moveWindows(from: background, to: main)
        }
        takeoverPlacements = []
        windowsPresentedOnMain = false
        pinStatus("Resetting the \(TaskPilotIdentity.compatibilityAgentScreenName)…")

        Task {
            do {
                if displayService.preferredAgentDisplay() != nil {
                    try await betterDisplay.disconnectAgentScreen()
                }
                try? await Task.sleep(for: .milliseconds(900))
                await refreshReadiness()
                pinStatus(backgroundAgentDisplay == nil
                    ? "\(TaskPilotIdentity.compatibilityAgentScreenName) removed; create it again whenever you need it"
                    : "Viewer closed and agent windows moved home; the connected physical display remains available")
            } catch {
                pinStatus("Could not reset the agent screen: \(error.localizedDescription)")
            }
            isResettingDisplay = false
        }
    }

    func setRunsOnMainDisplay(_ enabled: Bool) {
        guard !isActive, enabled != runsOnMainDisplay else { return }
        if enabled,
           let background = backgroundAgentDisplay,
           let main = displayService.mainDisplay() {
            mainDisplayModePlacements = accessibility.moveWindows(from: background, to: main)
        } else if !enabled {
            accessibility.restoreWindows(mainDisplayModePlacements)
            mainDisplayModePlacements = []
        }
        runsOnMainDisplay = enabled
        UserDefaults.standard.set(enabled, forKey: "OrbitAgent.runsOnMainDisplay")
        windowsPresentedOnMain = false
        pinStatus(enabled
            ? "Home Screen mode on — the agent works beside your other windows"
            : "Background Screen mode on — the agent works on its separate display")
        Task { await refreshReadiness() }
    }

    func setClosesTaskAppsAfterUse(_ enabled: Bool) {
        closesTaskAppsAfterUse = enabled
        UserDefaults.standard.set(enabled, forKey: "OrbitAgent.closesTaskAppsAfterUse")
        pinStatus(enabled
            ? "Task cleanup on — apps and windows opened by \(TaskPilotIdentity.displayName) will close after each task"
            : "Task cleanup off — apps and windows opened by \(TaskPilotIdentity.displayName) will remain open")
    }

    func setCompletionNotificationsEnabled(_ enabled: Bool) {
        guard enabled != completionNotificationsEnabled else { return }
        if !enabled {
            notificationEnablePending = false
            completionNotificationsEnabled = false
            UserDefaults.standard.set(false, forKey: CompletionNotificationService.preferenceKey)
            pinStatus("Task-completion notifications are Off")
            return
        }

        pinStatus("Checking macOS notification permission…")
        Task {
            let state = await completionNotifications.authorizationState()
            let granted: Bool
            switch state {
            case .allowed:
                granted = true
            case .notDetermined:
                granted = await completionNotifications.requestAuthorization()
            case .denied:
                granted = false
            }
            completionNotificationsEnabled = granted
            UserDefaults.standard.set(granted, forKey: CompletionNotificationService.preferenceKey)
            if granted {
                notificationEnablePending = false
                pinStatus("Notifications are On — \(TaskPilotIdentity.displayName) will alert you when a task finishes or needs a password")
            } else {
                notificationEnablePending = true
                _ = completionNotifications.openNotificationSettings()
                pinStatus("Notifications are Off in macOS — turn on \(TaskPilotIdentity.displayName) in Notification Settings, then return here")
            }
        }
    }

    // MARK: - Task queue and execution

    func runTask() {
        submitCurrentPrompt()
    }

    func submitCurrentPrompt() {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        if isActive || !queuedTasks.isEmpty {
            enqueueRequest(request)
            prompt = ""
            startNextQueuedTaskIfPossible()
            return
        }
        guard isReady, !windowsPresentedOnMain else {
            showingSetup = true
            return
        }
        prompt = ""
        startTask(request: request, queuedTask: nil)
    }

    func enqueueCurrentPrompt() {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActive, !request.isEmpty else { return }
        enqueueRequest(request)
        prompt = ""
    }

    func rerunHistoryEntry(id: UUID) {
        guard let entry = taskHistory.first(where: { $0.id == id }) else { return }
        // Every rerun is a new execution. Duplicate wording is intentionally
        // preserved and never deduplicated against prior history.
        if isActive {
            enqueueRequest(entry.request)
        } else if isReady && !windowsPresentedOnMain {
            startTask(request: entry.request, queuedTask: nil)
        } else {
            prompt = entry.request
            showingSetup = true
        }
    }

    func removeQueuedTask(id: UUID) {
        queuedTasks.removeAll { $0.id == id }
        persistTaskLedger()
    }

    func clearQueue() {
        queuedTasks.removeAll()
        persistTaskLedger()
    }

    func moveQueuedTask(id: UUID, offset: Int) {
        queuedTasks = AgentTaskQueueOrdering.moving(
            queuedTasks,
            id: id,
            offset: offset
        )
        persistTaskLedger()
    }

    func deleteHistoryEntry(id: UUID) {
        taskHistory.removeAll { $0.id == id }
        persistTaskLedger()
    }

    func clearHistory() {
        taskHistory.removeAll()
        persistTaskLedger()
    }

    private func enqueueRequest(_ request: String) {
        queuedTasks.append(QueuedAgentTask(request: request))
        persistTaskLedger()
    }

    private func startNextQueuedTaskIfPossible() {
        guard !isActive, isReady, !windowsPresentedOnMain,
              !queuedTasks.isEmpty else { return }
        let next = queuedTasks.removeFirst()
        persistTaskLedger()
        startTask(request: next.request, queuedTask: next)
    }

    private func startTask(
        request: String,
        queuedTask: QueuedAgentTask?
    ) {
        guard !isActive,
              isReady,
              !windowsPresentedOnMain,
              let display = agentDisplay,
              let openClawExecutableURL else {
            if let queuedTask {
                queuedTasks.insert(queuedTask, at: 0)
                persistTaskLedger()
            }
            showingSetup = true
            return
        }
        currentTaskRequest = request
        currentTaskStartedAt = Date()
        currentTaskWasQueued = queuedTask != nil
        runState = .running
        status = "Looking at the agent screen…"
        taskOutput = nil
        userInputRequest = nil
        userInputDraft = ""
        accessibility.beginTaskResourceTracking(on: display)
        agentCursor.hide()

        runtime.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleRuntimeEvent(event) }
        }

        do {
            try runtime.start(
                task: request,
                display: display,
            runtimeURL: bundledRuntime.executableURL,
                openClawURL: openClawExecutableURL,
                geminiAPIKey: savedGeminiAPIKey
            )
        } catch {
            agentCursor.hide()
            _ = accessibility.finishTaskResourceTracking(
                closeOpenedResources: closesTaskAppsAfterUse
            )
            let wasQueued = currentTaskWasQueued
            runState = .failed
            let message = "Could not start the agent: \(error.localizedDescription)"
            status = message
            recordCurrentTask(
                outcome: .failed,
                responseTitle: "Could not start",
                response: message
            )
            if wasQueued {
                completionNotifications.deliverQueuedTaskFinished(
                    enabled: completionNotificationsEnabled,
                    title: "Queued task failed to start",
                    body: message
                )
            }
            advanceQueueAfterTerminalTask()
        }
    }

    func togglePause() {
        switch runState {
        case .running:
            runtime.pause()
            agentCursor.hide()
            runState = .paused
            status = "Paused — the agent cannot click or type"
        case .paused:
            runtime.resume()
            agentCursor.hide()
            runState = .running
            status = "Resuming on the agent screen…"
        default:
            break
        }
    }

    func stop() {
        guard isActive else { return }
        agentCursor.hide()
        if runState == .takingOver {
            accessibility.restoreWindows(takeoverPlacements)
            takeoverPlacements = []
            windowsPresentedOnMain = false
        }
        runState = .stopping
        status = "Stopping safely…"
        userInputRequest = nil
        userInputDraft = ""
        runtime.stop()
    }

    func continueWithUserInput() {
        guard let request = userInputRequest, canSubmitUserInput else { return }
        let value = userInputDraft
        userInputDraft = ""
        userInputRequest = nil
        runtime.submitUserInput(requestID: request.requestID, value: value)
        runState = .running
        status = "Credential entered securely — continuing the task…"
    }

    func toggleManualTakeover() {
        toggleWindowsOnMain()
    }

    func toggleWindowsOnMain() {
        guard !runsOnMainDisplay else {
            pinStatus("Agent windows are already on the main display in Home Screen mode")
            return
        }
        if windowsPresentedOnMain || runState == .takingOver {
            accessibility.restoreWindows(takeoverPlacements)
            takeoverPlacements = []
            windowsPresentedOnMain = false
            if runState == .takingOver {
                runState = .paused
                pinStatus("Windows returned to the agent screen; the agent remains paused")
            } else {
                pinStatus("Windows returned to the agent screen")
            }
            return
        }
        guard let display = backgroundAgentDisplay else { return }
        if runState == .running { runtime.pause() }
        agentCursor.hide()
        takeoverPlacements = accessibility.moveWindowsForTakeover(from: display)
        windowsPresentedOnMain = !takeoverPlacements.isEmpty
        if runState == .running || runState == .paused { runState = .takingOver }
        pinStatus(takeoverPlacements.isEmpty
            ? "No controllable agent-screen window is open yet"
            : "Brought \(takeoverPlacements.count) agent window\(takeoverPlacements.count == 1 ? "" : "s") home")
    }

    func clearAgentScreen() {
        guard !isClearingAgentScreen else { return }
        guard !runsOnMainDisplay, let display = backgroundAgentDisplay else {
            pinStatus("Clear is available when the separate \(TaskPilotIdentity.compatibilityAgentScreenName) is connected")
            return
        }
        guard !isActive else {
            pinStatus("Stop the current task before clearing the \(TaskPilotIdentity.compatibilityAgentScreenName)")
            return
        }

        isClearingAgentScreen = true
        let summary = accessibility.clearWindows(on: display)
        isClearingAgentScreen = false

        if summary.closedWindowCount > 0 {
            let noun = summary.closedWindowCount == 1 ? "window" : "windows"
            pinStatus("Cleared \(summary.closedWindowCount) \(noun) from the \(TaskPilotIdentity.compatibilityAgentScreenName)")
        } else if summary.skippedWindowCount > 0 {
            pinStatus("The remaining Agent Screen windows cannot be closed automatically")
        } else {
            pinStatus("The \(TaskPilotIdentity.compatibilityAgentScreenName) is already clear")
        }
    }

    // MARK: - Runtime events and history

    private func handleRuntimeEvent(_ event: RuntimeEvent) {
        switch event {
        case .status(let message):
            if runState == .running { status = message }
        case .output(let output):
            taskOutput = output
        case .userInputRequired(let request):
            agentCursor.hide()
            userInputDraft = ""
            userInputRequest = request
            runState = .waitingForUser
            status = "Paused — \(request.title.lowercased())"
            Task {
                let state = await completionNotifications.authorizationState()
                let allowed: Bool
                if state == .notDetermined {
                    allowed = await completionNotifications.requestAuthorization()
                } else {
                    allowed = state == .allowed
                }
                if allowed {
                    completionNotifications.deliverUserActionRequired(
                        title: request.title,
                        message: request.message
                    )
                } else {
                    NSApp.requestUserAttention(.criticalRequest)
                }
            }
        case .completed(let message):
            agentCursor.hide()
            userInputRequest = nil
            userInputDraft = ""
            let wasQueued = currentTaskWasQueued
            let cleanup = accessibility.finishTaskResourceTracking(
                closeOpenedResources: closesTaskAppsAfterUse
            )
            runState = .completed
            status = statusWithCleanup(message, cleanup: cleanup)
            let payload = CompletionNotificationService.payload(
                output: taskOutput,
                completionMessage: message
            )
            if wasQueued {
                completionNotifications.deliverQueuedTaskFinished(
                    enabled: completionNotificationsEnabled,
                    title: payload.title,
                    body: payload.body
                )
            } else {
                completionNotifications.deliverSuccessfulCompletion(
                    enabled: completionNotificationsEnabled,
                    outputTitle: payload.title,
                    outputBody: payload.body
                )
            }
            let fullResponse = taskOutput?.shouldShow == true
                ? taskOutput?.content.trimmingCharacters(in: .whitespacesAndNewlines)
                : message.trimmingCharacters(in: .whitespacesAndNewlines)
            let fullResponseTitle = taskOutput?.shouldShow == true
                ? taskOutput?.title.trimmingCharacters(in: .whitespacesAndNewlines)
                : "Task complete"
            recordCurrentTask(
                outcome: .completed,
                responseTitle: nonemptyValue(fullResponseTitle) ?? "Task complete",
                response: nonemptyValue(fullResponse) ?? message
            )
            advanceQueueAfterTerminalTask()
        case .failed(let message):
            agentCursor.hide()
            userInputRequest = nil
            userInputDraft = ""
            let wasQueued = currentTaskWasQueued
            let cleanup = accessibility.finishTaskResourceTracking(
                closeOpenedResources: closesTaskAppsAfterUse
            )
            runState = .failed
            if Self.isCapturePermissionFailure(message) {
                hasScreenRecordingPermission = false
                captureAuthorization = .denied
                showingSetup = true
                status = "Capture permission needs repair for this exact build — use Setup → Capture access"
            } else {
                status = statusWithCleanup(message, cleanup: cleanup)
            }
            recordCurrentTask(
                outcome: .failed,
                responseTitle: "Task failed",
                response: status
            )
            if wasQueued {
                completionNotifications.deliverQueuedTaskFinished(
                    enabled: completionNotificationsEnabled,
                    title: "Queued task failed",
                    body: status
                )
            }
            advanceQueueAfterTerminalTask()
        case .stopped:
            agentCursor.hide()
            userInputRequest = nil
            userInputDraft = ""
            let wasQueued = currentTaskWasQueued
            let cleanup = accessibility.finishTaskResourceTracking(
                closeOpenedResources: closesTaskAppsAfterUse
            )
            runState = .idle
            status = statusWithCleanup("Stopped", cleanup: cleanup)
            recordCurrentTask(
                outcome: .stopped,
                responseTitle: "Task stopped",
                response: status
            )
            if wasQueued {
                completionNotifications.deliverQueuedTaskFinished(
                    enabled: completionNotificationsEnabled,
                    title: "Queued task stopped",
                    body: status
                )
            }
            advanceQueueAfterTerminalTask()
        }
    }

    private func recordCurrentTask(
        outcome: AgentTaskHistoryOutcome,
        responseTitle: String,
        response: String
    ) {
        guard let request = currentTaskRequest,
              let startedAt = currentTaskStartedAt else { return }
        let wasQueued = currentTaskWasQueued
        let entry = AgentTaskHistoryEntry(
            request: request,
            responseTitle: responseTitle,
            response: response,
            outcome: outcome,
            startedAt: startedAt,
            wasQueued: wasQueued
        )
        taskHistory.append(entry)
        taskHistory.sort { $0.finishedAt > $1.finishedAt }
        if wasQueued {
            completedQueuedTaskCount += 1
        }
        currentTaskRequest = nil
        currentTaskStartedAt = nil
        currentTaskWasQueued = false
        persistTaskLedger()
    }

    private func advanceQueueAfterTerminalTask() {
        if !queuedTasks.isEmpty {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.startNextQueuedTaskIfPossible()
            }
            return
        }
        guard completedQueuedTaskCount > 0 else { return }
        let count = completedQueuedTaskCount
        completedQueuedTaskCount = 0
        completionNotifications.deliverQueueFinished(
            enabled: completionNotificationsEnabled,
            completedCount: count
        )
    }

    private func persistTaskLedger() {
        do {
            try taskLedgerStore.save(queue: queuedTasks, history: taskHistory)
        } catch {
            if !isActive {
                status = "\(TaskPilotIdentity.displayName) could not save Queue & History: \(error.localizedDescription)"
            }
        }
    }

    private func nonemptyValue(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func statusWithCleanup(
        _ message: String,
        cleanup: TaskApplicationCleanupSummary
    ) -> String {
        let appCount = cleanup.quitApplicationNames.count
        let windowCount = cleanup.closedWindowCount
        guard appCount > 0 || windowCount > 0 else { return message }

        var parts: [String] = []
        if appCount > 0 {
            parts.append("quit \(appCount) task app\(appCount == 1 ? "" : "s")")
        }
        if windowCount > 0 {
            parts.append("closed \(windowCount) task window\(windowCount == 1 ? "" : "s")")
        }
        return "\(message) — \(parts.joined(separator: ", "))"
    }

    private static func isCapturePermissionFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("tcc") ||
            lowered.contains("screen capture") ||
            lowered.contains("display capture") ||
            lowered.contains("screen viewing")
    }
}
