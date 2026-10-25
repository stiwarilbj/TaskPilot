import SwiftUI

struct TaskResultPreviewSheetView: View {
    typealias CorrectionHandler = TaskResultShelfView.ChangeCorrectionHandler
    private enum Tab: String, CaseIterable, Identifiable {
        case preview = "Preview"
        case changes = "Show changes"
        var id: String { rawValue }
    }

    let url: URL
    let result: AgentTaskResultObject
    let snapshot: AgentTaskChangeLensSnapshot?
    let taskRequest: String
    let requirements: [AgentTaskProgressRequirement]
    let originatingInstruction: String
    let taskIsActive: Bool
    let surface: Color
    let border: Color
    let accent: Color
    let onCorrect: CorrectionHandler?
    var initiallyShowingChanges = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: Tab = .preview
    @State private var diffResult: AgentTaskChangeLensDiff.Result?
    @State private var diffIsRunning = false
    @State private var destinationCurrent = false
    @State private var selectedHunk: AgentTaskChangeLensHunk?
    @State private var correctionDraft = TaskComposerDraft()
    @State private var correctionMessage: String?

    private var isSupportedText: Bool {
        let ext = URL(fileURLWithPath: result.path ?? "").pathExtension.lowercased()
        return ["txt", "text", "md", "markdown", "rst", "swift", "py", "js", "jsx", "ts", "tsx",
                "json", "yaml", "yml", "toml", "ini", "c", "h", "cc", "cpp", "m", "mm", "rs",
                "go", "java", "kt", "sh", "zsh", "html", "css", "xml", "sql", "rb", "php",
                "pl", "lua", "log", "csv"].contains(ext)
    }

    private var snapshotMatchesResult: Bool {
        guard let snapshot else { return false }
        return result.kind == .file && result.path == snapshot.path &&
            result.fileIdentity == snapshot.fileIdentity && result.fileVersion == snapshot.fileVersion &&
            result.parentIdentity == snapshot.parentIdentity
    }

    private var diffHunks: [AgentTaskChangeLensHunk]? {
        guard case .hunks(let hunks) = diffResult else { return nil }
        return hunks
    }

    private var scopeAssessment: AgentTaskChangeLensScope.Assessment? {
        guard let snapshot, let diffHunks else { return nil }
        let instruction = originatingInstruction.isEmpty ? taskRequest : originatingInstruction
        return AgentTaskChangeLensScope.assess(request: instruction, before: snapshot.beforeText, hunks: diffHunks)
    }

    private var draftBinding: Binding<TaskComposerDraft> {
        Binding(get: { correctionDraft }, set: { correctionDraft = $0; correctionMessage = nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(result.name, systemImage: "doc.text")
                    .font(.headline)
                    .lineLimit(1)
                    .help(result.name)
                Spacer(minLength: 8)
                Picker("File preview mode", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 230)
                .accessibilityLabel("Preview or show changes")
            }
            Text(result.path ?? url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let snapshot, snapshot.created {
                Label("New file", systemImage: "sparkle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(accent)
            }

            Group {
                if let selectedHunk {
                    correctionEditor(for: selectedHunk)
                } else if selectedTab == .preview {
                    previewContent
                } else {
                    changesContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(6)
        .background(surface)
        .onAppear {
            if initiallyShowingChanges { selectedTab = .changes }
            refreshDestinationState()
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .changes { refreshDestinationState() }
        }
        .task(id: "\(selectedTab.rawValue):\(snapshot?.actionID ?? "none")") {
            guard selectedTab == .changes, let snapshot else { return }
            diffIsRunning = true
            diffResult = nil
            let worker = Task.detached(priority: .utility) {
                AgentTaskChangeLensDiff.build(before: snapshot.beforeText, after: snapshot.afterText)
            }
            let value = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            diffResult = value
            diffIsRunning = false
        }
        .accessibilityIdentifier("task-result-change-lens")
    }

    @ViewBuilder
    private var previewContent: some View {
        if destinationCurrent {
            TaskResultQuickLookView(url: url)
                .accessibilityLabel("Quick Look preview of \(result.name)")
        } else {
            ContentUnavailableView("The file changed", systemImage: "doc.questionmark",
                description: Text("This preview is unavailable because the verified file identity or version no longer matches. Use Show changes to review the historical comparison."))
        }
    }

    @ViewBuilder
    private var changesContent: some View {
        if !isSupportedText {
            explanation("Change comparisons support complete UTF-8 text, Markdown, and source files.")
        } else if !snapshotMatchesResult || snapshot == nil {
            explanation("No complete verified native text snapshot is available for this file. GUI edits and general shell edits are not included.")
        } else if let snapshot {
            VStack(alignment: .leading, spacing: 8) {
                if let instruction = originatingInstruction.isEmpty ? nil : originatingInstruction {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Request phrase")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(instruction)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(9)
                    .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
                }
                if !destinationCurrent {
                    Label("Historical comparison — the file changed after this verified version. Inspect it before making a correction.", systemImage: "arrow.clockwise.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if snapshot.chainReset {
                    Label("This comparison covers only the latest verified edit; an intervening file version was detected.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let assessment = scopeAssessment {
                    scopeNotice(assessment)
                }
                if diffIsRunning {
                    ProgressView("Preparing comparison…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let diffResult {
                    switch diffResult {
                    case .unavailable(let reason): explanation(reason)
                    case .hunks(let hunks) where hunks.isEmpty:
                        ContentUnavailableView("No text changes", systemImage: "equal", description: Text("The verified before and after versions are identical."))
                    case .hunks(let hunks):
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(hunks.enumerated()), id: \.element.id) { index, hunk in
                                    hunkView(hunk, index: index + 1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    explanation("A comparison is not available.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func hunkView(_ hunk: AgentTaskChangeLensHunk, index: Int) -> some View {
        let instruction = originatingInstruction.isEmpty ? taskRequest : originatingInstruction
        let scopeMismatch = snapshot.flatMap { value in
            AgentTaskChangeLensScope.hunkIsOutside(request: instruction, before: value.beforeText ?? "", hunk: hunk)
        } == true
        let changedTextColor = scopeMismatch ? Color.orange : accent
        let parts = passageParts(for: hunk)
        let passageIsUnique = snapshot?.uniquelyIdentifies(passage: parts.passage,
            beforeAnchor: parts.beforeAnchor, afterAnchor: parts.afterAnchor) == true
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Change \(index)")
                    .font(.caption.weight(.semibold))
                Spacer()
                if scopeMismatch {
                    Label("Potential scope mismatch", systemImage: "exclamationmark.triangle")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Potential scope mismatch in change \(index)")
                }
                if destinationCurrent, !hunk.after.filter(\.changed).isEmpty {
                    Button("Correct this passage") {
                        correctionDraft = TaskComposerDraft()
                        correctionMessage = nil
                        selectedHunk = hunk
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .disabled(!passageIsUnique)
                    .accessibilityLabel("Correct changed passage \(index) in \(result.name)")
                }
            }
            if destinationCurrent, !hunk.after.filter(\.changed).isEmpty, !passageIsUnique {
                Label("This passage is repeated or cannot be matched precisely. Inspect the current file before correcting it.", systemImage: "text.magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    AgentTaskChangeLensColumn(title: "Before", lines: hunk.before.filter(\.changed), empty: snapshot?.created == true ? "New file" : "No removed lines", accent: changedTextColor)
                    AgentTaskChangeLensColumn(title: "After", lines: hunk.after.filter(\.changed), empty: "No added lines", accent: changedTextColor)
                }
                VStack(alignment: .leading, spacing: 8) {
                    AgentTaskChangeLensColumn(title: "Before", lines: hunk.before.filter(\.changed), empty: snapshot?.created == true ? "New file" : "No removed lines", accent: changedTextColor)
                    AgentTaskChangeLensColumn(title: "After", lines: hunk.after.filter(\.changed), empty: "No added lines", accent: changedTextColor)
                }
            }
            DisclosureGroup("Show unchanged context") {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        AgentTaskChangeLensColumn(title: "Before context", lines: hunk.before.filter { !$0.changed }, empty: "No nearby context", accent: accent)
                        AgentTaskChangeLensColumn(title: "After context", lines: hunk.after.filter { !$0.changed }, empty: "No nearby context", accent: accent)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        AgentTaskChangeLensColumn(title: "Before context", lines: hunk.before.filter { !$0.changed }, empty: "No nearby context", accent: accent)
                        AgentTaskChangeLensColumn(title: "After context", lines: hunk.after.filter { !$0.changed }, empty: "No nearby context", accent: accent)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(9)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(border.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed text section \(index)")
    }

    private func correctionEditor(for hunk: AgentTaskChangeLensHunk) -> some View {
        let parts = passageParts(for: hunk)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Correct this passage", systemImage: "text.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                Spacer()
                Button("Back to changes") { selectedHunk = nil }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            Text("File: \(result.path ?? url.path)")
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(2)
            Group {
                if !originatingInstruction.isEmpty {
                    Text("Instruction: \(originatingInstruction)")
                } else {
                    Text("Instruction: \(taskRequest)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("Selected current passage")
                .font(.caption.weight(.semibold))
            ScrollView {
                Text(parts.passage)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 85)
            .padding(7)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            TaskRequestComposer(draft: draftBinding, fontSize: 13, focusRequested: true,
                onFocusChanged: { _ in }, accessibilityLabel: "Focused correction for selected passage")
                .frame(minHeight: 78, maxHeight: 110)
                .padding(5)
                .background(surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: 1))
            if let correctionMessage {
                Text(correctionMessage)
                    .font(.caption)
                    .foregroundStyle(correctionMessage.contains("started") || correctionMessage.contains("pending") || correctionMessage.contains("queued") ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(correctionMessage)
            }
            HStack {
                Button(taskIsActive ? "Apply correction" : "Run focused correction") {
                    submitCorrection(parts)
                }
                .buttonStyle(.borderedProminent)
                .disabled(correctionDraft.isEmpty || !destinationCurrent || parts.passage.isEmpty)
                .accessibilityLabel(taskIsActive ? "Apply correction at the next safe boundary" : "Run a fresh focused correction task")
                Button("Cancel") { selectedHunk = nil; correctionMessage = nil }
                    .buttonStyle(.bordered)
                Spacer()
            }
            Text("TaskPilot will inspect the current file and match this passage and its anchors before editing. Previous actions and completion evidence will not be reused.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func submitCorrection(_ parts: PassageParts) {
        guard let snapshot, let onCorrect else {
            correctionMessage = "Focused correction is unavailable."
            return
        }
        guard snapshot.currentDestinationMatches() else {
            destinationCurrent = false
            correctionMessage = "The file changed. Reopen Show changes after fresh verification before correcting this passage."
            return
        }
        let instruction = originatingInstruction.isEmpty ? taskRequest : originatingInstruction
        switch onCorrect(snapshot, parts.passage, parts.beforeAnchor, parts.afterAnchor,
                         instruction, correctionDraft.expandedText) {
        case .applied: correctionMessage = "Correction pending — TaskPilot will apply it after current work is reconciled."
        case .started: correctionMessage = "Focused correction started as a fresh task."
        case .queued: correctionMessage = "Focused correction queued as a fresh task."
        case .existingCorrectionDraft:
            correctionMessage = "A correction draft already exists. Continue it from the task status card."
        case .unavailable(let message): correctionMessage = message
        }
    }

    private struct PassageParts {
        let passage: String
        let beforeAnchor: String
        let afterAnchor: String
    }

    private func passageParts(for hunk: AgentTaskChangeLensHunk) -> PassageParts {
        let changed = hunk.after.indices.filter { hunk.after[$0].changed }
        let passage = changed.map { hunk.after[$0].text }.joined(separator: "\n")
        guard let first = changed.first, let last = changed.last else {
            return PassageParts(passage: "", beforeAnchor: "", afterAnchor: "")
        }
        let before = hunk.after[..<first].last(where: { !$0.changed })?.text ?? ""
        let after = hunk.after[hunk.after.index(after: last)...].first(where: { !$0.changed })?.text ?? ""
        return PassageParts(passage: passage, beforeAnchor: before, afterAnchor: after)
    }

    private func refreshDestinationState() {
        guard let snapshot else { destinationCurrent = false; return }
        destinationCurrent = snapshotMatchesResult && snapshot.currentDestinationMatches()
    }

    @ViewBuilder
    private func scopeNotice(_ assessment: AgentTaskChangeLensScope.Assessment) -> some View {
        switch assessment {
        case .potentialMismatch:
            Label("Potential scope mismatch — some edits appear outside the requested region.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .imprecise:
            Label("Scope could not be checked precisely.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        case .checked:
            Label("The detected edits are within the identified requested region.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .unrestricted:
            EmptyView()
        }
    }

    private func explanation(_ text: String) -> some View {
        ContentUnavailableView("Changes unavailable", systemImage: "doc.text.magnifyingglass", description: Text(text))
    }
}

private struct AgentTaskChangeLensColumn: View {
    let title: String
    let lines: [AgentTaskChangeLensLine]
    let empty: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if lines.isEmpty {
                Text(empty)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            }
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(line.number))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                    Text(line.text.isEmpty ? " " : line.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(line.changed ? accent.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 3))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(line.changed ? "Changed" : "Context") line \(line.number): \(line.text)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
    }
}
