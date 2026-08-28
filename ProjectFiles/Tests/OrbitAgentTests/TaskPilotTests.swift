import CoreGraphics
import UserNotifications
import XCTest
@testable import OrbitAgent

final class TaskPilotTests: XCTestCase {
    func testTaskPilotProductIdentityPreservesCompatibilityScreenName() {
        XCTAssertEqual(TaskPilotIdentity.displayName, "TaskPilot")
        XCTAssertEqual(
            TaskPilotIdentity.compatibilityAgentScreenName,
            "Orbit Agent Screen"
        )
        XCTAssertEqual(TaskPilotIdentity.liveScreenWindowTitle, "TaskPilot Live Screen")
        XCTAssertEqual(TaskPilotIdentity.queueWindowTitle, "TaskPilot Queue & History")
    }

    func testTaskToolsReadWriteAndRunShellCommands() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskPilotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let tools = TaskToolExecutor()
        let file = root.appendingPathComponent("folder/note.txt")
        let write = try await tools.perform(action: [
            "type": "write_file",
            "path": file.path,
            "content": "hello from TaskPilot"
        ])
        XCTAssertEqual(write["bytes_written"] as? Int, 20)
        XCTAssertEqual(write["verified"] as? Bool, true)
        XCTAssertEqual(write["file_size"] as? Int, 20)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello from TaskPilot")

        let append = try await tools.perform(action: [
            "type": "write_file",
            "path": file.path,
            "content": "!",
            "mode": "append"
        ])
        XCTAssertEqual(append["mode"] as? String, "append")
        XCTAssertEqual(append["verified"] as? Bool, true)
        XCTAssertEqual(append["file_size"] as? Int, 21)

        let read = try await tools.perform(action: [
            "type": "read_file",
            "path": file.path
        ])
        XCTAssertEqual(read["content"] as? String, "hello from TaskPilot!")
        XCTAssertEqual(read["encoding"] as? String, "utf-8")

        let command = try await tools.perform(action: [
            "type": "run_command",
            "command": "pwd; printf taskpilot-shell",
            "working_directory": root.path,
            "timeout_seconds": 5
        ])
        XCTAssertEqual(command["exit_code"] as? Int, 0)
        XCTAssertEqual(command["timed_out"] as? Bool, false)
        XCTAssertTrue((command["stdout"] as? String)?.contains(root.path) ?? false)
        XCTAssertTrue((command["stdout"] as? String)?.contains("taskpilot-shell") ?? false)
    }

    func testTaskToolsExposeTheRequestedNativeCapabilities() {
        XCTAssertEqual(TaskToolExecutor.supportedActions, [
            "read_file", "write_file", "run_command"
        ])
        XCTAssertEqual(
            TaskToolExecutor.expandedFileURL("~/Desktop/example.txt").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/example.txt").path
        )
    }

    func testTaskToolShellTimeoutStopsTheCommandTree() async throws {
        let tools = TaskToolExecutor()
        let result = try await tools.perform(action: [
            "type": "run_command",
            "command": "sleep 5",
            "timeout_seconds": 0.2
        ])
        XCTAssertEqual(result["timed_out"] as? Bool, true)
        XCTAssertNotEqual(result["exit_code"] as? Int, 0)
    }

    func testAccessibilitySnapshotRejectsUnrepresentableFrames() {
        XCTAssertNil(serializedAccessibilityFrame(CGRect(
            x: 0,
            y: 0,
            width: CGFloat.greatestFiniteMagnitude,
            height: 20
        )))
        XCTAssertNil(serializedAccessibilityFrame(CGRect(
            x: CGFloat.infinity,
            y: 0,
            width: 20,
            height: 20
        )))
        XCTAssertEqual(
            serializedAccessibilityFrame(CGRect(x: -12.4, y: 8.6, width: 300.2, height: 99.8)),
            ["x": -12, "y": 9, "width": 300, "height": 100]
        )
    }

    func testAccessibilityPermissionFlowAvoidsTheRedundantSystemPrompt() {
        XCTAssertTrue(TaskPilotCoordinator.accessibilityPermissionUsesSettingsOnly)
    }

    func testKeyboardBridgeSupportsFindersSortBySizeShortcutKey() {
        XCTAssertEqual(AccessibilityController.supportedKeyCodes["6"], 22)
        XCTAssertEqual(AccessibilityController.supportedKeyCodes["0"], 29)
    }

    func testBrowserNavigationAcceptsWebURLsAndSearchesButRejectsOtherSchemes() throws {
        XCTAssertEqual(
            try AccessibilityController.browserNavigationText(from: [
                "url": "https://example.com/docs"
            ]),
            "https://example.com/docs"
        )
        XCTAssertEqual(
            try AccessibilityController.browserNavigationText(from: [
                "query": "TaskPilot documentation"
            ]),
            "TaskPilot documentation"
        )
        XCTAssertThrowsError(
            try AccessibilityController.browserNavigationText(from: [
                "url": "file:///Users/test/secret.txt"
            ])
        )
    }

    func testOpenClawLocatorPrefersTheExplicitConfiguredPath() {
        let urls = OpenClawService.candidateExecutableURLs(
            environment: [
                "ORBIT_OPENCLAW_PATH": "/custom/openclaw",
                "PATH": "/usr/local/bin:/usr/bin"
            ],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        XCTAssertEqual(urls.first?.path, "/custom/openclaw")
        XCTAssertTrue(urls.map(\.path).contains("/usr/local/bin/openclaw"))
        XCTAssertTrue(urls.map(\.path).contains("/Users/test/.openclaw/bin/openclaw"))
    }

    func testOpenClawReadinessProbeUsesAgentInventory() {
        XCTAssertEqual(OpenClawService.setupArguments, ["agents", "list", "--json"])
        XCTAssertEqual(
            OpenClawService.modelReadinessArguments,
            ["models", "status", "--json", "--check"]
        )
        XCTAssertEqual(
            OpenClawService.primaryModelArguments,
            ["config", "get", "agents.defaults.model.primary"]
        )
        XCTAssertEqual(OpenClawService.installedWithoutKeyExitStatus, 10)
        XCTAssertEqual(OpenClawService.installURL.host, "docs.openclaw.ai")
        XCTAssertEqual(OpenClawService.dashboardArguments, ["dashboard", "--yes"])
    }

    func testAutomatedOpenClawSetupUsesTheRequestedGeminiOrder() {
        XCTAssertEqual(OpenClawService.primaryGeminiModel, "google/gemini-3.5-flash")
        XCTAssertEqual(OpenClawService.fallbackGeminiModels, [
            "google/gemini-3-flash-preview",
            "google/gemini-3.1-flash-lite",
            "google/gemini-2.5-flash",
            "google/gemini-2.5-flash-lite"
        ])
        XCTAssertEqual(OpenClawService.allGeminiModels, [
            "google/gemini-3.5-flash",
            "google/gemini-3-flash-preview",
            "google/gemini-3.1-flash-lite",
            "google/gemini-2.5-flash",
            "google/gemini-2.5-flash-lite"
        ])
    }

    func testGeminiModelCheckKeepsTheAPIKeyOutOfTheURL() throws {
        let request = try GeminiModelVerifier.makeRequest(
            model: "google/gemini-3.5-flash",
            apiKey: "AIzaSyUnitTestSecret"
        )
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "AIzaSyUnitTestSecret")
        XCTAssertFalse(request.url?.absoluteString.contains("AIzaSyUnitTestSecret") ?? true)
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testGeminiAPIKeyPersistsInPrivateApplicationSupportData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskPilotKeyStoreTests-\(UUID().uuidString)", isDirectory: true)
        let file = root
            .appendingPathComponent(GeminiAPIKeyStore.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent(GeminiAPIKeyStore.fileName)
        let store = GeminiAPIKeyStore(fileURL: file)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(try store.load())
        try store.save("AIzaSyFirstPersistentUnitTestKey")
        XCTAssertEqual(try store.load(), "AIzaSyFirstPersistentUnitTestKey")

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: file.deletingLastPathComponent().path
        )
        XCTAssertEqual(
            (fileAttributes[.posixPermissions] as? NSNumber)?.intValue,
            GeminiAPIKeyStore.filePermissions
        )
        XCTAssertEqual(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue,
            GeminiAPIKeyStore.directoryPermissions
        )

        try store.save("AIzaSyReplacementPersistentKey")
        XCTAssertEqual(try store.load(), "AIzaSyReplacementPersistentKey")
        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testGeminiAPIKeyKeepsTheLegacyApplicationSupportPath() {
        let url = GeminiAPIKeyStore.defaultFileURL()
        XCTAssertEqual(url.lastPathComponent, GeminiAPIKeyStore.fileName)
        XCTAssertEqual(
            url.deletingLastPathComponent().lastPathComponent,
            GeminiAPIKeyStore.applicationSupportFolderName
        )
    }

    func testCompleteGeminiAPIKeysAreEligibleForSaving() {
        XCTAssertNil(TaskPilotCoordinator.completeGeminiAPIKey(from: "too-short"))
        XCTAssertEqual(
            TaskPilotCoordinator.completeGeminiAPIKey(from: "  AIzaSyCompletePersistentKey  "),
            "AIzaSyCompletePersistentKey"
        )
    }

    func testGeminiKeyVisibilityDefaultsToShownAndRestoresTheSavedChoice() throws {
        let suiteName = "TaskPilotTests.GeminiVisibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(TaskPilotCoordinator.initialGeminiAPIKeyVisibility(userDefaults: defaults))
        defaults.set(false, forKey: TaskPilotCoordinator.geminiAPIKeyVisibilityPreferenceKey)
        XCTAssertFalse(TaskPilotCoordinator.initialGeminiAPIKeyVisibility(userDefaults: defaults))
        defaults.set(true, forKey: TaskPilotCoordinator.geminiAPIKeyVisibilityPreferenceKey)
        XCTAssertTrue(TaskPilotCoordinator.initialGeminiAPIKeyVisibility(userDefaults: defaults))
    }

    func testOneWorkingGeminiModelMakesTheCheckedKeyUsable() {
        let checks = [
            GeminiModelCheck(model: "first", state: .failed("quota")),
            GeminiModelCheck(model: "second", state: .working("OK")),
            GeminiModelCheck(model: "third", state: .failed("unavailable"))
        ]
        XCTAssertEqual(TaskPilotCoordinator.workingGeminiModelCount(checks), 1)
        XCTAssertTrue(TaskPilotCoordinator.hasUsableGeminiModel(checks))
        XCTAssertFalse(TaskPilotCoordinator.hasUsableGeminiModel([
            GeminiModelCheck(model: "first", state: .failed("quota")),
            GeminiModelCheck(model: "second", state: .failed("unavailable"))
        ]))
    }

    func testPrivacyButtonsTargetTheCorrectSystemSettingsPanes() {
        XCTAssertEqual(
            TaskPilotCoordinator.privacySettingsURL(for: .accessibility)?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        XCTAssertEqual(
            TaskPilotCoordinator.privacySettingsURL(for: .screenCapture)?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    func testDisplayDescriptorPreservesQuartzCoordinateSpace() {
        let display = DisplayDescriptor(
            id: 42,
            name: "Agent Screen",
            x: 1728,
            y: -120,
            width: 1440,
            height: 900,
            isMain: false
        )

        XCTAssertEqual(display.frame, CGRect(x: 1728, y: -120, width: 1440, height: 900))
        XCTAssertFalse(display.isMain)
    }

    func testAgentScreenControlsOnlyManageWindowsCenteredOnThatDisplay() {
        let display = DisplayDescriptor(
            id: 42,
            name: "Orbit Agent Screen",
            x: 1728,
            y: 0,
            width: 1440,
            height: 900,
            isMain: false
        )

        XCTAssertTrue(AccessibilityController.windowBelongs(
            CGRect(x: 1800, y: 100, width: 600, height: 500),
            to: display
        ))
        XCTAssertFalse(AccessibilityController.windowBelongs(
            CGRect(x: 1200, y: 100, width: 700, height: 500),
            to: display
        ))
        XCTAssertFalse(AccessibilityController.windowBelongs(.null, to: display))
    }

    func testAgentScreenClearSummaryTracksClosedAndSkippedWindows() {
        XCTAssertEqual(AgentScreenClearSummary.empty, AgentScreenClearSummary(
            closedWindowCount: 0,
            skippedWindowCount: 0
        ))
    }

    func testPreferredAgentScreenNameIsStable() {
        XCTAssertEqual(DisplayService.preferredDisplayName, "Orbit Agent Screen")
    }

    func testBetterDisplayRequestCreatesTheNamedVirtualScreen() {
        let parameters = BetterDisplayService.createAgentScreenParameters
        XCTAssertEqual(parameters["type"], "VirtualScreen")
        XCTAssertEqual(parameters["virtualScreenName"], DisplayService.preferredDisplayName)
        XCTAssertEqual(parameters["virtualScreenHiDPI"], "on")
    }

    func testBetterDisplayReconnectsAnExistingOfflineAgentScreen() {
        let parameters = BetterDisplayService.connectAgentScreenParameters
        XCTAssertEqual(parameters["name"], DisplayService.preferredDisplayName)
        XCTAssertEqual(parameters["connected"], "on")
    }

    func testBetterDisplayCanDisconnectTheAgentScreenForReset() {
        let parameters = BetterDisplayService.disconnectAgentScreenParameters
        XCTAssertEqual(parameters["name"], DisplayService.preferredDisplayName)
        XCTAssertEqual(parameters["connected"], "off")
    }

    func testTaskOutputCarriesTheOutputAgentDecision() {
        let output = AgentTaskOutput(
            shouldShow: true,
            title: "Calculation",
            content: "42",
            decidedByAgent: true
        )

        XCTAssertTrue(output.shouldShow)
        XCTAssertEqual(output.title, "Calculation")
        XCTAssertEqual(output.content, "42")
        XCTAssertTrue(output.decidedByAgent)
        XCTAssertEqual(output.kind, .result)
    }

    func testApplicationNameMatchingHandlesGameWrappers() {
        XCTAssertEqual(
            AccessibilityController.normalizedApplicationName("BASEBALL 9.app"),
            AccessibilityController.normalizedApplicationName("baseball9")
        )
        XCTAssertEqual(
            AccessibilityController.normalizedApplicationName("Pokémon GO"),
            AccessibilityController.normalizedApplicationName("pokemon-go")
        )
    }

    func testIOSApplicationWrapperDiscoveryFollowsTheInnerAppHandoff() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("BASEBALL 9.app", isDirectory: true)
        let inner = root
            .appendingPathComponent("Wrapper", isDirectory: true)
            .appendingPathComponent("Baseball9.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inner,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: root.deletingLastPathComponent()
            )
        }

        let candidates = AccessibilityController.applicationBundleURLs(at: root)
        XCTAssertEqual(candidates.first, root)
        XCTAssertTrue(candidates.contains {
            $0.resolvingSymlinksInPath() == inner.resolvingSymlinksInPath()
        })
    }

    func testGeneralComputerTaskRoutesIncludeUsageAndFileDiscovery() {
        let routes = AccessibilityController.systemTaskRoutes
        XCTAssertTrue(routes.contains {
            $0["bundle_id"] == "com.apple.systempreferences" &&
            $0["destination"]?.contains("Screen Time") == true
        })
        XCTAssertTrue(routes.contains {
            $0["bundle_id"] == "com.apple.finder" &&
            $0["destination"]?.contains("Finder") == true
        })
    }

    func testVisionCaptureKeepsSmallGameTextReadable() {
        XCTAssertEqual(ScreenCaptureService.maximumVisionWidth, 2048)
        XCTAssertEqual(ScreenCaptureService.maximumVisionHeight, 1280)
        XCTAssertEqual(ScreenCaptureService.maximumPreviewWidth, 1440)
        XCTAssertEqual(ScreenCaptureService.maximumPreviewHeight, 900)
    }

    func testQuietScreenCapturePreflightMirrorsExistingTCCDecision() {
        XCTAssertEqual(
            ScreenCaptureService.preflightAuthorizationStatus(granted: true),
            .authorized
        )
        XCTAssertEqual(
            ScreenCaptureService.preflightAuthorizationStatus(granted: false),
            .denied
        )
    }

    func testAgentCursorMapsQuartzCoordinatesWithoutMovingTheSystemPointer() {
        let display = DisplayDescriptor(
            id: 42,
            name: "Orbit Agent Screen",
            x: 1728,
            y: -120,
            width: 1440,
            height: 900,
            isMain: false
        )
        let screenFrame = CGRect(x: 1728, y: 0, width: 1440, height: 900)

        XCTAssertEqual(
            AgentCursorCoordinateMapper.appKitPoint(
                quartzPoint: CGPoint(x: 1728, y: -120),
                display: display,
                screenFrame: screenFrame
            ),
            CGPoint(x: 1728, y: 900)
        )
        XCTAssertEqual(
            AgentCursorCoordinateMapper.appKitPoint(
                quartzPoint: CGPoint(x: 3168, y: 780),
                display: display,
                screenFrame: screenFrame
            ),
            CGPoint(x: 3168, y: 0)
        )
    }

    func testAgentCursorIsAnActionOnlyIndicator() {
        XCTAssertGreaterThan(AgentCursorOverlayController.actionVisibilityDuration, 0)
        XCTAssertLessThanOrEqual(AgentCursorOverlayController.actionVisibilityDuration, 1)
    }

    func testAgentCursorPresentationNormalizesForLiveView() {
        let display = DisplayDescriptor(
            id: 42,
            name: "Orbit Agent Screen",
            x: 100,
            y: -50,
            width: 1000,
            height: 500,
            isMain: false
        )
        let presentation = AgentCursorPresentation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
            point: CGPoint(x: 850, y: 75),
            display: display,
            isClicking: true
        )

        XCTAssertEqual(presentation.normalizedPoint.x, 0.75, accuracy: 0.0001)
        XCTAssertEqual(presentation.normalizedPoint.y, 0.25, accuracy: 0.0001)
        XCTAssertTrue(presentation.isClicking)
    }

    func testLiveViewCursorMapsIntoAspectFitContent() {
        let content = AgentScreenCursorMapper.fittedContentRect(
            displaySize: CGSize(width: 1600, height: 900),
            viewportSize: CGSize(width: 1000, height: 1000)
        )
        XCTAssertEqual(content, CGRect(x: 0, y: 218.75, width: 1000, height: 562.5))
        XCTAssertEqual(
            AgentScreenCursorMapper.point(
                normalizedPoint: CGPoint(x: 0.25, y: 0.75),
                in: content
            ),
            CGPoint(x: 250, y: 640.625)
        )
    }

    func testLiveViewCursorRemainsVisibleLongEnoughToObserve() {
        XCTAssertGreaterThanOrEqual(
            AgentScreenViewerModel.cursorVisibilityDuration,
            .milliseconds(1_400)
        )
    }

    func testTaskCleanupQuitsOnlyExplicitAgentLaunchesThatWereNotAlreadyOpen() {
        let candidates = AccessibilityController.cleanupApplicationPIDs(
            baselinePIDs: [10, 20],
            agentLaunchedPIDs: [20, 30, 40, 99],
            currentPIDs: [10, 20, 30, 99],
            controllerPID: 99
        )

        XCTAssertEqual(candidates, [30])
    }

    func testWindowLockedToAnotherDisplaySelectsTheDisplayThatActuallyContainsIt() {
        let background = DisplayDescriptor(
            id: 10,
            name: "Orbit Agent Screen",
            x: 1728,
            y: 0,
            width: 1440,
            height: 900,
            isMain: false
        )
        let main = DisplayDescriptor(
            id: 20,
            name: "Built-in Display",
            x: 0,
            y: 0,
            width: 1728,
            height: 1117,
            isMain: true
        )

        let selected = AccessibilityController.displayContainingLargestVisibleArea(
            windowFrames: [CGRect(x: 180, y: 120, width: 900, height: 700)],
            displays: [background, main]
        )

        XCTAssertEqual(selected, main)
    }

    func testGeneralSystemRoutesCoverUsageFilesAndLiveProcesses() {
        let intents = AccessibilityController.systemTaskRoutes.compactMap { $0["intent"] }
        XCTAssertTrue(intents.contains(where: { $0.contains("most-used app") }))
        XCTAssertTrue(intents.contains(where: { $0.contains("local files") }))
        XCTAssertTrue(intents.contains(where: { $0.contains("CPU") }))

        let routeIDs = Set(
            AccessibilityController.systemTaskRoutes.compactMap { $0["route_id"] }
        )
        XCTAssertTrue(routeIDs.isSuperset(of: [
            "screen_time", "finder", "calendar", "reminders", "activity_monitor",
            "storage", "mail", "notes", "contacts", "photos", "maps", "music",
            "calculator", "dictionary", "web"
        ]))
        XCTAssertEqual(
            AccessibilityController.systemTaskRoutes.first {
                $0["route_id"] == "screen_time"
            }?["settings_url"],
            "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension"
        )
    }

    func testOutputResultUsesLargerReadableType() {
        XCTAssertGreaterThanOrEqual(TaskPilotMainView.outputResultFontSize, 16)
    }

    func testGeminiAPIKeyLinkUsesGoogleAIStudiosOfficialHTTPSPage() {
        XCTAssertEqual(TaskPilotMainView.geminiAPIKeyURL.scheme, "https")
        XCTAssertEqual(TaskPilotMainView.geminiAPIKeyURL.host, "aistudio.google.com")
        XCTAssertEqual(TaskPilotMainView.geminiAPIKeyURL.path, "/apikey")
    }

    func testAppStyleIncludesEveryRequestedNamedTheme() {
        XCTAssertEqual(Set(TaskPilotTheme.allCases.map(\.rawValue)), Set([
            "Light", "Dark", "Red", "Blue", "Green", "Aquamarine",
            "Multicolored", "Gradients", "Flowing Colors", "Stream", "Ocean",
            "Dinosaurs", "Forest", "Tropical Rainforest",
            "Grasslands with Sunset", "Custom"
        ]))
    }

    func testCustomFontSizesAreClampedToReadableRanges() {
        XCTAssertEqual(
            TaskPilotAppearancePreferences.clampedInputFontSize(-100),
            TaskPilotAppearancePreferences.minimumInputFontSize
        )
        XCTAssertEqual(
            TaskPilotAppearancePreferences.clampedInputFontSize(500),
            TaskPilotAppearancePreferences.maximumInputFontSize
        )
        XCTAssertEqual(
            TaskPilotAppearancePreferences.clampedOutputFontSize(-100),
            TaskPilotAppearancePreferences.minimumOutputFontSize
        )
        XCTAssertEqual(
            TaskPilotAppearancePreferences.clampedOutputFontSize(500),
            TaskPilotAppearancePreferences.maximumOutputFontSize
        )
    }

    func testCompletionNotificationsOnlyAppearAwayFromTaskPilot() {
        XCTAssertTrue(CompletionNotificationService.shouldDeliver(
            enabled: true,
            appIsActive: false,
            controllerWindowIsKey: false
        ))
        XCTAssertFalse(CompletionNotificationService.shouldDeliver(
            enabled: false,
            appIsActive: false,
            controllerWindowIsKey: false
        ))
        XCTAssertFalse(CompletionNotificationService.shouldDeliver(
            enabled: true,
            appIsActive: true,
            controllerWindowIsKey: true
        ))
    }

    func testCompletionNotificationIncludesConciseAgentOutput() {
        let payload = CompletionNotificationService.payload(
            output: AgentTaskOutput(
                shouldShow: true,
                title: "Remaining energy",
                content: "  14/20\n",
                decidedByAgent: true
            ),
            completionMessage: "Task completed"
        )

        XCTAssertEqual(payload.title, "Remaining energy")
        XCTAssertEqual(payload.body, "14/20")
        XCTAssertLessThanOrEqual(
            CompletionNotificationService.conciseBody(String(repeating: "a", count: 400)).count,
            CompletionNotificationService.maximumBodyLength
        )
    }

    func testNotificationAuthorizationMappingOpensSettingsOnlyWhenNeeded() {
        XCTAssertEqual(
            CompletionNotificationService.authorizationState(for: .authorized),
            .allowed
        )
        XCTAssertEqual(
            CompletionNotificationService.authorizationState(for: .provisional),
            .allowed
        )
        XCTAssertEqual(
            CompletionNotificationService.authorizationState(for: .notDetermined),
            .notDetermined
        )
        XCTAssertEqual(
            CompletionNotificationService.authorizationState(for: .denied),
            .denied
        )
        XCTAssertEqual(
            CompletionNotificationService.notificationSettingsURL.scheme,
            "x-apple.systempreferences"
        )
        XCTAssertTrue(
            CompletionNotificationService.notificationSettingsURL.absoluteString
                .contains("Notifications-Settings")
        )
    }

    func testQueueCompletionNotificationDescribesOneAndManyItems() {
        XCTAssertEqual(
            CompletionNotificationService.queueFinishedBody(completedCount: 1),
            "The queued request is finished."
        )
        XCTAssertEqual(
            CompletionNotificationService.queueFinishedBody(completedCount: 4),
            "All 4 queued requests are finished."
        )
    }

    func testTaskLedgerPersistsAnUnboundedDuplicateFriendlyQueueAndHistory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskPilotLedgerTests-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent(AgentTaskLedgerStore.fileName)
        defer { try? FileManager.default.removeItem(at: root) }

        let repeatedRequest = "Run this exact request again"
        let queue = (0..<1_000).map { index in
            QueuedAgentTask(
                request: repeatedRequest,
                queuedAt: Date(timeIntervalSince1970: 1_000 + Double(index))
            )
        }
        let history = [
            AgentTaskHistoryEntry(
                request: repeatedRequest,
                responseTitle: "First result",
                response: "The first fresh execution completed.",
                outcome: .completed,
                startedAt: Date(timeIntervalSince1970: 500),
                finishedAt: Date(timeIntervalSince1970: 501),
                wasQueued: false
            ),
            AgentTaskHistoryEntry(
                request: repeatedRequest,
                responseTitle: "Second result",
                response: "The identical request ran again.",
                outcome: .completed,
                startedAt: Date(timeIntervalSince1970: 600),
                finishedAt: Date(timeIntervalSince1970: 601),
                wasQueued: true
            )
        ]

        let store = AgentTaskLedgerStore(fileURL: file)
        try store.save(queue: queue, history: history)
        let loaded = try store.load()

        XCTAssertEqual(loaded.queue, queue)
        XCTAssertEqual(loaded.queue.count, 1_000)
        XCTAssertTrue(loaded.queue.allSatisfy { $0.request == repeatedRequest })
        XCTAssertEqual(loaded.history, history)

        let directoryMode = try FileManager.default.attributesOfItem(
            atPath: root.path
        )[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(
            atPath: file.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, AgentTaskLedgerStore.directoryPermissions)
        XCTAssertEqual(fileMode?.intValue, AgentTaskLedgerStore.filePermissions)
    }

    func testQueueOrderingMovesOnlyWithinBounds() {
        let first = QueuedAgentTask(request: "first")
        let second = QueuedAgentTask(request: "second")
        let third = QueuedAgentTask(request: "third")
        let queue = [first, second, third]

        XCTAssertEqual(
            AgentTaskQueueOrdering.moving(queue, id: second.id, offset: -1),
            [second, first, third]
        )
        XCTAssertEqual(
            AgentTaskQueueOrdering.moving(queue, id: second.id, offset: 1),
            [first, third, second]
        )
        XCTAssertEqual(
            AgentTaskQueueOrdering.moving(queue, id: first.id, offset: -1),
            queue
        )
    }

    func testTaskHistoryGroupsNewestYearMonthDayAndEntryFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour
            ))!
        }
        func entry(_ label: String, finishedAt: Date) -> AgentTaskHistoryEntry {
            AgentTaskHistoryEntry(
                request: label,
                responseTitle: "Result",
                response: label,
                outcome: .completed,
                startedAt: finishedAt.addingTimeInterval(-10),
                finishedAt: finishedAt,
                wasQueued: false
            )
        }
        let entries = [
            entry("older year", finishedAt: date(2025, 12, 31, 23)),
            entry("earlier month", finishedAt: date(2026, 6, 30, 12)),
            entry("earlier today", finishedAt: date(2026, 7, 24, 8)),
            entry("latest", finishedAt: date(2026, 7, 24, 18)),
            entry("yesterday", finishedAt: date(2026, 7, 23, 22))
        ]

        let years = AgentTaskHistoryGrouping.years(
            from: entries,
            calendar: calendar
        )

        XCTAssertEqual(years.map(\.year), [2026, 2025])
        XCTAssertEqual(years[0].months.map(\.month), [7, 6])
        XCTAssertEqual(
            years[0].months[0].days.map(\.dayStart),
            [date(2026, 7, 24, 0), date(2026, 7, 23, 0)]
        )
        XCTAssertEqual(
            years[0].months[0].days[0].entries.map(\.request),
            ["latest", "earlier today"]
        )
    }

    func testSecureUserInputRequestCarriesNoCredentialValue() {
        let request = AgentUserInputRequest(
            requestID: "request-123",
            title: "Password required",
            message: "The waiting app needs your password.",
            kind: .password
        )
        XCTAssertEqual(request.id, "request-123")
        XCTAssertEqual(request.kind, .password)
        XCTAssertEqual(AgentUserInputKind.verificationCode.rawValue, "verification_code")
    }

    func testControllerWindowHasNoOneAxisResizeRestriction() {
        XCTAssertTrue(ControllerWindowLayout.supportsHorizontalAndVerticalResizing)
        XCTAssertGreaterThan(ControllerWindowLayout.defaultWidth, ControllerWindowLayout.minimumWidth)
        XCTAssertGreaterThan(ControllerWindowLayout.defaultHeight, ControllerWindowLayout.minimumHeight)
    }

    func testScrollRecoveryClampsToTheVisibleTargetWindow() {
        let point = AccessibilityController.clampedPointerPoint(
            preferred: CGPoint(x: -100, y: 900),
            windowFrame: CGRect(x: 100, y: 100, width: 600, height: 500),
            displayFrame: CGRect(x: 0, y: 0, width: 800, height: 700)
        )
        XCTAssertNotNil(point)
        XCTAssertTrue(CGRect(x: 100, y: 100, width: 600, height: 500).contains(point!))
        XCTAssertGreaterThan(point!.x, 100)
        XCTAssertLessThan(point!.y, 600)
    }

    func testPointerRecoveryRaisesOnlyAWindowThatAlreadyOwnsThePoint() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let targetWindow = CGRect(x: 100, y: 80, width: 700, height: 600)

        XCTAssertTrue(
            AccessibilityController.pointerVisibilityRecoveryIsSafe(
                point: CGPoint(x: 450, y: 350),
                displayFrame: display,
                targetWindowFrames: [targetWindow],
                targetPID: 42,
                topmostPID: 77
            )
        )
        XCTAssertFalse(
            AccessibilityController.pointerVisibilityRecoveryIsSafe(
                point: CGPoint(x: 900, y: 350),
                displayFrame: display,
                targetWindowFrames: [targetWindow],
                targetPID: 42,
                topmostPID: 77
            )
        )
        XCTAssertFalse(
            AccessibilityController.pointerVisibilityRecoveryIsSafe(
                point: CGPoint(x: 450, y: 350),
                displayFrame: display,
                targetWindowFrames: [targetWindow],
                targetPID: 42,
                topmostPID: 42
            )
        )
    }

    func testIOSGameTapWaitsForTheAppToConsumeTheRelease() {
        XCTAssertGreaterThanOrEqual(
            AccessibilityController.hidClickPressDuration,
            0.05
        )
        XCTAssertGreaterThanOrEqual(
            AccessibilityController.hidClickReleaseSettleDuration,
            0.10
        )
    }

    func testMissingActionPIDInheritsTheRememberedVisibleTaskApp() {
        XCTAssertEqual(
            AccessibilityController.resolvedTargetPID(
                explicitPID: nil,
                rememberedPID: 42,
                visiblePIDs: [42, 77],
                frontmostPID: 77
            ),
            42
        )
    }

    func testMissingActionPIDDoesNotGuessBetweenUnrelatedVisibleApps() {
        XCTAssertNil(
            AccessibilityController.resolvedTargetPID(
                explicitPID: nil,
                rememberedPID: nil,
                visiblePIDs: [42, 77],
                frontmostPID: nil
            )
        )
    }
}
