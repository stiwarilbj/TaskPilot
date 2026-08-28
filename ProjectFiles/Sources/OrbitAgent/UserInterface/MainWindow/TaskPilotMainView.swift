import AppKit
import SwiftUI

struct TaskPilotMainView: View {
    static let outputResultFontSize: CGFloat = TaskPilotAppearancePreferences.defaultOutputFontSize
    static let geminiAPIKeyURL = URL(string: "https://aistudio.google.com/apikey")!

    @ObservedObject var model: TaskPilotCoordinator
    @Environment(\.openWindow) private var openWindow
    @FocusState private var promptFocused: Bool
    @FocusState private var userInputFocused: Bool
    @AppStorage(TaskPilotAppearancePreferences.themeKey) private var themeRawValue = TaskPilotTheme.light.rawValue
    @AppStorage(TaskPilotAppearancePreferences.inputFontSizeKey) private var inputFontSize = TaskPilotAppearancePreferences.defaultInputFontSize
    @AppStorage(TaskPilotAppearancePreferences.outputFontSizeKey) private var outputFontSize = TaskPilotAppearancePreferences.defaultOutputFontSize
    @AppStorage(TaskPilotAppearancePreferences.animateColorsKey) private var animateColors = false
    @AppStorage(TaskPilotAppearancePreferences.customStartColorKey) private var customStartHex = "#5B5BF7FF"
    @AppStorage(TaskPilotAppearancePreferences.customEndColorKey) private var customEndHex = "#B43DF2FF"
    @AppStorage(TaskPilotAppearancePreferences.customGradientKey) private var customGradient = true
    @AppStorage(TaskPilotAppearancePreferences.customImagePathKey) private var customImagePath = ""

    private var theme: TaskPilotTheme {
        TaskPilotTheme(rawValue: themeRawValue) ?? .light
    }

    private var accent: Color {
        theme == .custom
            ? TaskPilotThemeColorCodec.color(from: customStartHex)
            : theme.accent
    }

    var body: some View {
        ZStack {
            TaskPilotThemeBackground(
                preset: theme,
                animateColors: animateColors,
                customStartHex: customStartHex,
                customEndHex: customEndHex,
                customGradient: customGradient,
                customImagePath: customImagePath
            )

            if theme != .light {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.18)
                    .ignoresSafeArea()
            }

            VStack(spacing: 18) {
                header
                taskComposer
                statusCard
                if model.userInputRequest != nil {
                    userInputCard
                } else {
                    outputCard
                }
                controls
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(accent)
        .preferredColorScheme(theme.preferredColorScheme)
        .sheet(isPresented: $model.showingSetup) {
            TaskPilotSetupView(model: model)
        }
        .onAppear {
            if model.isReady { promptFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshReadiness() }
        }
        .task {
            while !Task.isCancelled {
                await model.refreshReadiness()
                // This is deliberately a quiet preflight poll. Explicit
                // permission buttons own every prompt and pixel verification.
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Header and navigation

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: theme.logoColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .shadow(color: accent.opacity(0.25), radius: 12, y: 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(TaskPilotIdentity.displayName)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("OPENCLAW")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(accent.gradient, in: Capsule())
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.isReady ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(model.runsOnMainDisplay
                         ? "Home Screen mode"
                         : (model.agentDisplay?.name ?? "Setup needed"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(spacing: 2) {
                Button {
                    openWindow(id: "agent-viewer")
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .background(.thinMaterial, in: Circle())
                .disabled(model.agentDisplay == nil || !model.canViewAgentScreen)
                .help("Open the interactive live Agent Screen")
                .accessibilityLabel("Live View")

                Text("Live View")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 54)

            VStack(spacing: 2) {
                Button {
                    model.toggleWindowsOnMain()
                } label: {
                    Image(systemName: model.windowsPresentedOnMain
                          ? "arrow.uturn.backward.circle"
                          : "macwindow.on.rectangle")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .background(.thinMaterial, in: Circle())
                .disabled(model.backgroundAgentDisplay == nil || model.runsOnMainDisplay)
                .help(model.windowsPresentedOnMain
                      ? "Return agent windows to the background screen"
                      : "Bring all agent windows to the main screen")
                .accessibilityLabel(model.windowsPresentedOnMain ? "Send Back" : "Bring Home")

                Text(model.windowsPresentedOnMain ? "Send Back" : "Bring Home")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 58)

            VStack(spacing: 2) {
                Button {
                    model.clearAgentScreen()
                } label: {
                    Image(systemName: "xmark.rectangle")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .background(.thinMaterial, in: Circle())
                .disabled(
                    model.backgroundAgentDisplay == nil ||
                    model.runsOnMainDisplay ||
                    model.isActive ||
                    model.isClearingAgentScreen
                )
                        .help("Close all closeable windows on the separate \(TaskPilotIdentity.compatibilityAgentScreenName)")
                .accessibilityLabel("Clear Agent Screen")

                Text("Clear")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 48)

            if !model.queuedTasks.isEmpty {
                VStack(spacing: 2) {
                    Button {
                        openWindow(id: "task-center")
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "list.number")
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 32, height: 32)
                            Text("\(model.queuedTasks.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.indigo, in: Circle())
                                .offset(x: 5, y: -3)
                        }
                    }
                    .buttonStyle(.plain)
                    .background(.thinMaterial, in: Circle())
                    .help("View and reorder waiting requests")
                    .accessibilityLabel("\(model.queuedTasks.count) queued requests")

                    Text("Queue")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 48)
            }

            VStack(spacing: 2) {
                Button {
                    openWindow(id: "task-center")
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .background(.thinMaterial, in: Circle())
                .help("Open request history")
                .accessibilityLabel("History")

                Text("History")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 50)

            VStack(spacing: 2) {
                Button {
                    model.showSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .background(.thinMaterial, in: Circle())
                .help("Settings")
                .accessibilityLabel("Settings")

                Text("Settings")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 54)
        }
    }

    // MARK: - Task composer and output

    private var taskComposer: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("What should the agent do?")
                .font(.headline)

            ZStack(alignment: .topLeading) {
                if model.prompt.isEmpty {
                    Text("Example: Open Safari on the agent screen, compare three flight options, and leave the best one open")
                        .font(.system(size: TaskPilotAppearancePreferences.clampedInputFontSize(inputFontSize)))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.prompt)
                    .font(.system(size: TaskPilotAppearancePreferences.clampedInputFontSize(inputFontSize)))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 7)
                    .padding(.top, 12)
                    .padding(.bottom, 7)
                    .focused($promptFocused)
            }
            .frame(height: 116)
            .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(theme.borderColor, lineWidth: 1)
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            statusSymbol
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.borderColor, lineWidth: 1)
        }
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Output", systemImage: "doc.text.fill")
                    .font(.headline)
                    .foregroundStyle(accent)

                Spacer()

                if let output = model.taskOutput {
                    Label(
                        output.kind == .answer ? "Answer" : (output.kind == .completion ? "Completed" : "Result"),
                        systemImage: output.kind == .answer
                            ? "text.bubble.fill"
                            : (output.kind == .completion ? "checkmark.circle.fill" : "sparkles")
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            if let output = model.taskOutput {
                if output.shouldShow {
                    HStack(alignment: .firstTextBaseline) {
                        Text(output.title)
                            .font(.body.weight(.semibold))
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(output.content, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .help("Copy output")
                    }

                    ScrollView {
                        Text(output.content)
                            .font(.system(size: TaskPilotAppearancePreferences.clampedOutputFontSize(outputFontSize)))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                } else {
                    Label("Task completed", systemImage: "checkmark.circle")
                        .font(.callout.weight(.medium))
                    Text("The requested desktop action was completed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if model.isActive {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(TaskPilotIdentity.displayName) will return the verified result as soon as the desktop task is complete.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("After each task, \(TaskPilotIdentity.displayName) returns either the answer, result, or a confirmation of what was done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(accent.opacity(0.28), lineWidth: 1)
        }
    }

    private var userInputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let request = model.userInputRequest {
                HStack(spacing: 8) {
                    Label("Action needed", systemImage: "key.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Spacer()
                    Text("TASK PAUSED")
                        .font(.caption2.weight(.black))
                        .tracking(0.6)
                        .foregroundStyle(.orange)
                }

                Text(request.title)
                    .font(.body.weight(.semibold))
                Text(request.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                SecureField(
                    request.kind == .verificationCode
                        ? "Verification code"
                        : "Password or secure value",
                    text: $model.userInputDraft
                )
                .textFieldStyle(.roundedBorder)
                .focused($userInputFocused)
                .onSubmit {
                    if model.canSubmitUserInput {
                        model.continueWithUserInput()
                    }
                }

                HStack {
                    Label(
                        "Sent directly to the waiting app — never to OpenClaw or task history",
                        systemImage: "lock.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Continue") {
                        model.continueWithUserInput()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSubmitUserInput)
                }
                .task(id: request.id) {
                    userInputFocused = true
                }
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color.orange.opacity(0.55), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var statusSymbol: some View {
        switch model.runState {
        case .running, .stopping:
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
        case .paused, .takingOver:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 18))
        case .waitingForUser:
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 17))
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 18))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 18))
        case .idle:
            Image(systemName: model.isReady ? "display.and.arrow.down" : "wrench.and.screwdriver.fill")
                .foregroundStyle(model.isReady ? .indigo : .orange)
                .font(.system(size: 17))
        }
    }

    // MARK: - Task controls

    private var controls: some View {
        Group {
            if model.isActive {
                VStack(spacing: 10) {
                    Button {
                        model.enqueueCurrentPrompt()
                    } label: {
                        Label("Add Request to Queue", systemImage: "text.badge.plus")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.large)
                    .disabled(!model.canQueueCurrentPrompt)
                    .keyboardShortcut(.return, modifiers: [.command])

                    HStack(spacing: 10) {
                        if model.runState != .takingOver && model.runState != .waitingForUser {
                            Button {
                                model.togglePause()
                            } label: {
                                Label(model.runState == .paused ? "Resume" : "Pause",
                                      systemImage: model.runState == .paused ? "play.fill" : "pause.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.large)
                        }

                        if model.runState != .waitingForUser {
                            Button {
                                model.toggleManualTakeover()
                            } label: {
                                Label(model.runState == .takingOver ? "Return" : "Take Over",
                                      systemImage: model.runState == .takingOver ? "arrow.uturn.backward" : "hand.raised.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.large)
                        }

                        Button(role: .destructive) {
                            model.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                    }
                }
            } else if model.isReady {
                Button {
                    model.runTask()
                } label: {
                    Label("Run on Agent Screen", systemImage: "sparkles")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.large)
                .disabled(!model.canStart)
                .keyboardShortcut(.return, modifiers: [.command])
            } else {
                Button {
                    model.showSettings()
                } label: {
                    Label(
                        model.hasCompletedSetup ? "Open Settings" : "Finish Setup",
                        systemImage: "arrow.right.circle.fill"
                    )
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.large)
            }
        }
    }
}

// MARK: - Settings

private struct TaskPilotSetupView: View {
    @ObservedObject var model: TaskPilotCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showingPermissionRepair = false
    @State private var permissionPrompt: PermissionSettingsPrompt?
    @State private var appStyleExpanded = false
    @FocusState private var geminiAPIKeyFocused: Bool

    @AppStorage(TaskPilotAppearancePreferences.themeKey) private var themeRawValue = TaskPilotTheme.light.rawValue
    @AppStorage(TaskPilotAppearancePreferences.animateColorsKey) private var animateColors = false
    @AppStorage(TaskPilotAppearancePreferences.customStartColorKey) private var customStartHex = "#5B5BF7FF"
    @AppStorage(TaskPilotAppearancePreferences.customEndColorKey) private var customEndHex = "#B43DF2FF"
    @AppStorage(TaskPilotAppearancePreferences.customGradientKey) private var customGradient = true
    @AppStorage(TaskPilotAppearancePreferences.customImagePathKey) private var customImagePath = ""

    private var theme: TaskPilotTheme {
        TaskPilotTheme(rawValue: themeRawValue) ?? .light
    }

    var body: some View {
        ZStack {
            TaskPilotThemeBackground(
                preset: theme,
                animateColors: animateColors,
                customStartHex: customStartHex,
                customEndHex: customEndHex,
                customGradient: customGradient,
                customImagePath: customImagePath
            )

            if theme != .light {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.18)
                    .ignoresSafeArea()
            }

            settingsContent
        }
        .tint(theme.accent)
        .preferredColorScheme(theme.preferredColorScheme)
        .frame(width: 720, height: 720)
        .confirmationDialog(
            "Repair \(TaskPilotIdentity.displayName) permissions?",
            isPresented: $showingPermissionRepair,
            titleVisibility: .visible
        ) {
            Button("Reset \(TaskPilotIdentity.displayName) permissions", role: .destructive) {
                model.repairStalePermissions()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Use this when macOS Settings says On but \(TaskPilotIdentity.displayName) still says Off. It removes only \(TaskPilotIdentity.displayName)’s old Accessibility and Screen Recording entries so you can grant the exact current build.")
        }
        .alert(item: $permissionPrompt) { prompt in
            Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                primaryButton: .default(Text(prompt.openButtonTitle)) {
                    prompt.perform(using: model)
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(isPresented: $model.showingAutomatedOpenClawSetup) {
            AutomatedOpenClawSetupView(model: model)
        }
        .onAppear {
            // A saved visible credential must never be highlighted merely
            // because Settings opened. The field becomes first responder only
            // after the user clicks it.
            geminiAPIKeyFocused = false
            DispatchQueue.main.async {
                geminiAPIKeyFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(.title2.bold())
                    Text("Customize \(TaskPilotIdentity.displayName) and manage its one-time setup.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    model.finishSetup()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    setupRow(
                        icon: "key.fill",
                        title: "Gemini API key",
                        detail: "Paste the key once. Save keeps it immediately in \(TaskPilotIdentity.displayName)’s private Application Support data without testing it. Check tests all five models and saves the key only if at least one works. Saved keys return whenever the app opens, with no Keychain lookup.",
                        complete: model.hasWorkingGeminiModel,
                        iconTint: model.hasWorkingGeminiModel
                            ? Color.green
                            : (model.hasGeminiModelCheckFailure
                                ? Color.orange
                                : (model.hasSavedGeminiAPIKey ? Color.green.opacity(0.55) : Color.indigo))
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            Link(destination: TaskPilotMainView.geminiAPIKeyURL) {
                                Label(
                                    "Get or view your Gemini API key in Google AI Studio",
                                    systemImage: "arrow.up.right.square"
                                )
                            }
                            .font(.callout.weight(.semibold))
                            .accessibilityHint("Opens Google's official Gemini API key page in your web browser")

                            HStack(spacing: 8) {
                                Group {
                                    if model.isGeminiAPIKeyVisible {
                                        TextField("Paste your Gemini API key", text: $model.geminiAPIKeyDraft)
                                    } else {
                                        SecureField("Paste your Gemini API key", text: $model.geminiAPIKeyDraft)
                                    }
                                }
                                .textFieldStyle(.plain)
                                .font(.body.monospaced())
                                .focused($geminiAPIKeyFocused)

                                Button(model.isGeminiAPIKeyVisible ? "Hide" : "Show") {
                                    model.isGeminiAPIKeyVisible.toggle()
                                }
                                .buttonStyle(.plain)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.accent)
                                .accessibilityLabel(model.isGeminiAPIKeyVisible ? "Hide Gemini API key" : "Show Gemini API key")
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            }
                            .disabled(model.isCheckingGeminiModels)

                            HStack {
                                Button("Save") { model.saveGeminiAPIKey() }
                                    .disabled(!model.canSaveGeminiAPIKey)
                                Button("Check") { model.checkGeminiModels() }
                                    .disabled(!model.canCheckGeminiModels)
                                Button("Clear API Key", role: .destructive) {
                                    model.clearGeminiAPIKey()
                                }
                                .disabled(!model.hasSavedGeminiAPIKey || model.isCheckingGeminiModels)
                                if model.isCheckingGeminiModels {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }

                            Text(model.geminiAPIKeyStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            VStack(spacing: 6) {
                                ForEach(model.geminiModelChecks) { check in
                                    geminiModelCheckRow(check)
                                }
                            }
                        }
                    }

                    setupRow(
                        icon: "rectangle.2.swap",
                        title: "Screen placement",
                        detail: model.runsOnMainDisplay
                            ? "Home Screen mode is on. \(TaskPilotIdentity.displayName) sees and controls apps on your main display; its own windows remain protected."
                            : "Background Screen mode is on. Agent apps stay on the separate \(TaskPilotIdentity.compatibilityAgentScreenName).",
                        complete: true
                    ) {
                        Toggle("Run agent apps on my main screen", isOn: Binding(
                            get: { model.runsOnMainDisplay },
                            set: { model.setRunsOnMainDisplay($0) }
                        ))
                        .toggleStyle(TaskPilotBlueSwitchStyle())
                        .disabled(model.isActive)
                    }

                    setupRow(
                        icon: "rectangle.stack.badge.minus",
                        title: "Task cleanup",
                        detail: model.closesTaskAppsAfterUse
                            ? "On by default. \(TaskPilotIdentity.displayName) closes only the apps and windows it opened during a task; anything already open stays untouched."
                            : "Apps and windows opened during a task will remain open after the task finishes or stops.",
                        complete: true
                    ) {
                        Toggle("Close task-opened apps and windows after use", isOn: Binding(
                            get: { model.closesTaskAppsAfterUse },
                            set: { model.setClosesTaskAppsAfterUse($0) }
                        ))
                        .toggleStyle(TaskPilotBlueSwitchStyle())
                        .disabled(model.isActive)
                    }

                    setupRow(
                        icon: "bell.badge.fill",
                        title: "Notifications",
                        detail: model.completionNotificationsEnabled
                            ? "\(TaskPilotIdentity.displayName) alerts you after each background task, after every queued request, when the full queue finishes, and immediately when a password or verification code is needed."
                            : "Turn this on for task, queue, and password-needed alerts. If macOS has notifications disabled, \(TaskPilotIdentity.displayName) opens Notification Settings automatically.",
                        complete: model.completionNotificationsEnabled
                    ) {
                        Toggle("Notify me when a background task finishes", isOn: Binding(
                            get: { model.completionNotificationsEnabled },
                            set: { model.setCompletionNotificationsEnabled($0) }
                        ))
                        .toggleStyle(TaskPilotBlueSwitchStyle())
                    }

                    setupRow(
                        icon: "paintpalette.fill",
                        title: "App Style",
                        detail: "Choose readable text sizes, named themes, flowing colors, gradients, or your own colors and image.",
                        complete: true
                    ) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                appStyleExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .rotationEffect(.degrees(appStyleExpanded ? 90 : 0))
                                Text("Style options")
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.medium))
                        .accessibilityValue(appStyleExpanded ? "Expanded" : "Collapsed")

                        if appStyleExpanded {
                            AppearanceSettingsView()
                                .padding(.top, 12)
                        }
                    }

                    setupRow(
                        icon: "shippingbox.fill",
                        title: "OpenClaw",
                        detail: model.openClawInstalled
                            ? "Detected \(model.openClawVersion.isEmpty ? "OpenClaw" : model.openClawVersion). Guided setup can securely apply the requested Gemini model chain again at any time."
                            : "Install OpenClaw and its private Node runtime now. A Gemini API key is optional during this download and can be added later.",
                        complete: model.openClawInstalled
                    ) {
                        HStack {
                            Button(model.openClawInstalled ? "Manage OpenClaw" : "Install OpenClaw") {
                                model.beginAutomatedOpenClawSetup()
                            }
                            Button("Recheck") { model.recheckOpenClaw() }
                        }
                    }

                    setupRow(
                        icon: "brain.head.profile",
                        title: "OpenClaw agent",
                        detail: model.hasGeminiModelCheckFailure
                            ? "No Gemini model responded. Reconfigure Gemini before running \(TaskPilotIdentity.displayName) through OpenClaw."
                            : (model.openClawConfigured
                                ? "Ready. \(TaskPilotIdentity.displayName) cycles through all five Gemini models in order for every request and immediately moves to the next model when one fails."
                                : model.openClawDetail),
                        complete: model.openClawConfigured && !model.hasGeminiModelCheckFailure
                    ) {
                        HStack {
                            Button(model.openClawConfigured || model.hasGeminiModelCheckFailure
                                   ? "Reconfigure Gemini"
                                   : "Add API Key") {
                                model.beginAutomatedOpenClawSetup()
                            }
                            if model.openClawConfigured {
                                Button("Open Dashboard") { model.openOpenClawDashboard() }
                            }
                            Button("Open Terminal") { model.openOpenClawSetup() }
                            Button("Recheck") { model.recheckOpenClaw() }
                        }
                    }

                    setupRow(
                        icon: "arrow.triangle.branch",
                        title: "\(TaskPilotIdentity.displayName) ↔ OpenClaw bridge",
                        detail: model.runtimeInstalled
                            ? "Built into \(TaskPilotIdentity.displayName). The bridge carries images and structured decisions over ACP while native macOS permissions stay inside \(TaskPilotIdentity.displayName)."
                            : "The bundled OpenClaw bridge is missing. Replace this app with a complete \(TaskPilotIdentity.displayName).app bundle.",
                        complete: model.runtimeInstalled
                    ) {
                        Label(model.runtimeInstalled ? "Built in — no Python or ADK install required" : "Bridge missing",
                              systemImage: model.runtimeInstalled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(model.runtimeInstalled ? Color.secondary : Color.red)
                    }

                    setupRow(
                        icon: "rectangle.on.rectangle",
                        title: "Background agent screen",
                        detail: model.betterDisplayInstalled
                            ? "Uses BetterDisplay’s free virtual-screen feature, or any connected second display."
                            : "Install BetterDisplay once so \(TaskPilotIdentity.displayName) can create a real virtual macOS display.",
                        complete: model.backgroundAgentDisplay != nil || model.runsOnMainDisplay
                    ) {
                        HStack {
                            Button(model.betterDisplayInstalled ? "Create Agent Screen" : "Get BetterDisplay") {
                                model.createAgentDisplay()
                            }
                            .disabled(model.backgroundAgentDisplay != nil || model.isCreatingDisplay)
                            Button("Refresh") {
                                Task { await model.refreshReadiness() }
                            }
                            Button("Reset", role: .destructive) {
                                dismissWindow(id: "agent-viewer")
                                model.resetAgentDisplay()
                            }
                            .disabled(model.backgroundAgentDisplay == nil || model.isResettingDisplay)
                        }
                    }

                    setupRow(
                        icon: "lock.shield.fill",
                        title: "macOS permissions",
                        detail: model.hasAccessibilityPermission && model.hasScreenRecordingPermission
                            ? capturePermissionDetail
                            : "\(TaskPilotIdentity.displayName) reads the live authorization for this running app and refreshes automatically. A stale System Settings row is never shown as permission that the current app does not actually have.",
                        complete: model.hasAccessibilityPermission && model.hasScreenRecordingPermission
                    ) {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 12) {
                                permissionBadge("Control", on: model.hasAccessibilityPermission)
                                permissionBadge("Application", on: model.hasScreenRecordingPermission)
                                permissionBadge("Window", on: model.hasScreenRecordingPermission)
                                permissionBadge("Display", on: model.hasScreenRecordingPermission)
                            }
                            LazyVGrid(columns: permissionButtonColumns, spacing: 8) {
                                permissionButton(
                                    model.hasAccessibilityPermission
                                        ? "Accessibility Control: On"
                                        : "Allow Accessibility Control"
                                ) {
                                    if model.hasAccessibilityPermission {
                                        model.recheckPermissions()
                                    } else {
                                        permissionPrompt = .requestAccessibility
                                    }
                                }

                                permissionButton("Open Control Settings") {
                                    permissionPrompt = .openAccessibility
                                }

                                permissionButton(
                                    model.hasScreenRecordingPermission
                                        ? "Screen Capture: On"
                                        : "Request Screen Capture"
                                ) {
                                    if model.hasScreenRecordingPermission {
                                        model.recheckPermissions()
                                    } else {
                                        permissionPrompt = .requestScreenCapture
                                    }
                                }

                                permissionButton("Open Capture Settings") {
                                    permissionPrompt = .openScreenCapture
                                }

                                permissionButton("Recheck Permissions") {
                                    model.recheckPermissions()
                                }

                                permissionButton("Repair Stale Permissions", role: .destructive) {
                                    showingPermissionRepair = true
                                }
                                .disabled(model.isRepairingPermissions)
                            }
                        }
                    }
                }
                .padding(24)
            }

            Divider()
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 13)
        }
    }

    private var permissionButtonColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 145), spacing: 8), count: 3)
    }

    private func permissionButton(
        _ title: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    private func setupRow<Actions: View>(
        icon: String,
        title: String,
        detail: String,
        complete: Bool,
        iconTint: Color? = nil,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        let resolvedIconTint = iconTint ?? (complete ? Color.green : Color.indigo)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(resolvedIconTint)
                .frame(width: 32, height: 32)
                .background(resolvedIconTint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if complete {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
        }
        .padding(16)
        .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(theme.borderColor, lineWidth: 1)
        }
    }

    private func permissionBadge(_ name: String, on: Bool) -> some View {
        Label("\(name): \(on ? "On" : "Off")", systemImage: on ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(on ? .green : .orange)
    }

    private func geminiModelCheckRow(_ check: GeminiModelCheck) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch check.state {
                case .waiting:
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                case .checking:
                    ProgressView()
                        .controlSize(.mini)
                case .working:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 16, height: 16)

            Text(check.model.replacingOccurrences(of: "google/", with: ""))
                .font(.caption.monospaced())
                .frame(width: 188, alignment: .leading)

            switch check.state {
            case .waiting:
                Text("Not checked")
                    .foregroundStyle(.secondary)
            case .checking:
                Text("Sending request…")
                    .foregroundStyle(.secondary)
            case .working:
                Text("Working")
                    .foregroundStyle(.green)
            case let .failed(message):
                Text(message)
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var capturePermissionDetail: String {
        if case .restartRequired = model.captureAuthorization {
            return "The Settings switch is On. Click Recheck and \(TaskPilotIdentity.displayName) will reopen itself so real application, window, and display pixels become available."
        }
        return "Control plus application, window, and display capture are On and verified with real pixels."
    }
}

// MARK: - Guided OpenClaw setup

private struct AutomatedOpenClawSetupView: View {
    @ObservedObject var model: TaskPilotCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 48, height: 48)
                    .background(Color.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.openClawInstalled ? "Configure OpenClaw for \(TaskPilotIdentity.displayName)" : "Get OpenClaw")
                        .font(.title2.bold())
                    Text("Install OpenClaw now. Gemini configuration can happen during this setup or later.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !model.isAutomatingOpenClawSetup &&
                        !model.automatedOpenClawSucceeded &&
                        !model.automatedOpenClawInstalledOnly {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(
                                model.hasSavedGeminiAPIKey
                                    ? "The Gemini key saved in Settings will be applied to OpenClaw."
                                    : "No Gemini key is saved. OpenClaw and Node will install without one; add the key later at the top of Settings.",
                                systemImage: model.hasSavedGeminiAPIKey ? "key.fill" : "key.slash"
                            )
                            .font(.callout.weight(.medium))
                            .foregroundStyle(model.hasSavedGeminiAPIKey ? Color.green : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        setupExplanation
                        modelOrder
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                if model.automatedOpenClawSucceeded {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.title2)
                                } else if model.automatedOpenClawInstalledOnly {
                                    Image(systemName: "shippingbox.fill")
                                        .foregroundStyle(.indigo)
                                        .font(.title2)
                                } else {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(model.automatedOpenClawMessage)
                                    .font(.headline)
                            }
                            ProgressView(value: model.automatedOpenClawProgress)
                            Text("\(Int(model.automatedOpenClawProgress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(Color.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

                        if model.automatedOpenClawSucceeded {
                            Label(
                                "A real Gemini request succeeded. \(TaskPilotIdentity.displayName) will use OpenClaw for model routing, sessions, memory, and reasoning.",
                                systemImage: "checkmark.shield.fill"
                            )
                            .foregroundStyle(.green)
                        } else if model.automatedOpenClawInstalledOnly {
                            Label(
                                "OpenClaw and Node are installed. Add a Gemini key later from the first card in Settings. Run stays disabled until verification succeeds.",
                                systemImage: "lock.circle.fill"
                            )
                            .foregroundStyle(.indigo)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !model.automatedOpenClawError.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Setup needs attention", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                            Text(model.automatedOpenClawError)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("You can correct the key and retry. Open Terminal is available only as a recovery path.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.red)
                        .padding(14)
                        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                if !model.automatedOpenClawError.isEmpty {
                    Button("Open Terminal") { model.openOpenClawSetup() }
                }
                Spacer()
                if model.isAutomatingOpenClawSetup {
                    Button("Stop", role: .destructive) { model.cancelAutomatedOpenClawSetup() }
                } else if model.automatedOpenClawSucceeded || model.automatedOpenClawInstalledOnly {
                    if model.automatedOpenClawInstalledOnly {
                        Button("Add API Key Now") { model.beginAutomatedOpenClawSetup() }
                    }
                    Button("Done") {
                        model.showingAutomatedOpenClawSetup = false
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") {
                        dismiss()
                    }
                    Button(primarySetupButtonTitle) {
                        model.startAutomatedOpenClawSetup()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canBeginOpenClawAutomation)
                }
            }
            .padding(20)
        }
        .frame(width: 620, height: 640)
        .interactiveDismissDisabled(model.isAutomatingOpenClawSetup)
    }

    private var setupExplanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(TaskPilotIdentity.displayName) will do this for you")
                .font(.headline)
            setupLine("Download OpenClaw’s official user-space installer over HTTPS")
            setupLine("Install OpenClaw and a supported Node runtime under ~/.openclaw — no administrator password")
            setupLine("Let you close setup and add Gemini later without enabling Run")
            setupLine("When a key is provided: save it in OpenClaw, start the local Gateway, and verify a real reply")
        }
        .padding(16)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var modelOrder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Five-model Gemini rotation")
                .font(.headline)
            ForEach(Array(OpenClawService.allGeminiModels.enumerated()), id: \.offset) { index, modelName in
                modelLine(modelName, label: "Cycle \(index + 1)")
            }
            Text("\(TaskPilotIdentity.displayName) uses these five models in order, advances after every request, and returns to Cycle 1 after Cycle 5. If one model fails, it immediately tries the next model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var primarySetupButtonTitle: String {
        if !model.automatedOpenClawError.isEmpty {
            return "Try Again"
        }
        if !model.openClawInstalled && model.geminiAPIKeyIsEmpty {
            return "Install OpenClaw"
        }
        return model.openClawInstalled ? "Configure Gemini" : "Install and Configure"
    }

    private func setupLine(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func modelLine(_ modelName: String, label: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(modelName.replacingOccurrences(of: "google/", with: ""))
                .font(.callout.monospaced())
        }
    }
}

// MARK: - Permission prompts

private enum PermissionSettingsPrompt: String, Identifiable {
    case requestAccessibility
    case openAccessibility
    case requestScreenCapture
    case openScreenCapture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .requestAccessibility, .openAccessibility:
            return "Open Accessibility Settings?"
        case .requestScreenCapture, .openScreenCapture:
            return "Open Screen Capture Settings?"
        }
    }

    var message: String {
        switch self {
        case .requestAccessibility:
            return "\(TaskPilotIdentity.displayName) needs Accessibility permission to open apps, click controls, and type on your behalf. Open macOS Privacy & Security now? \(TaskPilotIdentity.displayName) will recheck automatically when you return."
        case .openAccessibility:
            return "Open macOS Privacy & Security → Accessibility for this exact \(TaskPilotIdentity.displayName) app? \(TaskPilotIdentity.displayName) will recheck automatically when you return."
        case .requestScreenCapture:
            return "\(TaskPilotIdentity.displayName) needs Screen & System Audio Recording permission to see application, window, and display pixels. Open macOS Privacy & Security now? \(TaskPilotIdentity.displayName) will recheck automatically when you return."
        case .openScreenCapture:
            return "Open macOS Privacy & Security → Screen & System Audio Recording for this exact \(TaskPilotIdentity.displayName) app? \(TaskPilotIdentity.displayName) will recheck automatically when you return."
        }
    }

    var openButtonTitle: String {
        switch self {
        case .requestAccessibility, .openAccessibility:
            return "Open Accessibility Settings"
        case .requestScreenCapture, .openScreenCapture:
            return "Open Capture Settings"
        }
    }

    @MainActor
    func perform(using model: TaskPilotCoordinator) {
        switch self {
        case .requestAccessibility:
            model.requestAccessibility()
        case .openAccessibility:
            model.openAccessibilitySettings()
        case .requestScreenCapture:
            model.requestScreenRecording()
        case .openScreenCapture:
            model.openScreenRecordingSettings()
        }
    }
}
