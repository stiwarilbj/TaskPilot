import SwiftUI

struct TaskQueueHistoryView: View {
    @ObservedObject var model: TaskPilotCoordinator
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingClearQueue = false
    @State private var confirmingClearHistory = false

    private var historyGroups: [AgentTaskHistoryYearGroup] {
        AgentTaskHistoryGrouping.years(from: model.taskHistory)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Queue & History")
                        .font(.title2.bold())
                    Text("Waiting requests run in order. Every finished run keeps its request and response.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismissWindow(id: "task-center")
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let currentRequest = model.currentTaskRequest {
                            currentTaskCard(currentRequest)
                        }

                        if !model.queuedTasks.isEmpty {
                            queueSection
                        }

                        historySection
                    }
                    .padding(20)
                }
                .onAppear {
                    scrollToRequestedTask(using: proxy)
                }
                .onChange(of: model.requestedQueueTaskID) { _, _ in
                    scrollToRequestedTask(using: proxy)
                }
            }
        }
        .frame(minWidth: 540, minHeight: 560)
        .confirmationDialog(
            "Remove every waiting request?",
            isPresented: $confirmingClearQueue
        ) {
            Button("Clear Queue", role: .destructive) {
                model.clearQueue()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The running request is not affected.")
        }
        .confirmationDialog(
            "Delete all task history?",
            isPresented: $confirmingClearHistory
        ) {
            Button("Delete All History", role: .destructive) {
                model.clearHistory()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes all saved requests and responses.")
        }
        .confirmationDialog(
            "A Remix is already in progress",
            isPresented: Binding(
                get: { model.pendingRemixHistoryEntryID != nil },
                set: { if !$0 { model.continueCurrentRemix() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Continue Editing") {
                model.continueCurrentRemix()
                openWindow(id: "controller")
            }
            Button("Discard Remix and Load Selected", role: .destructive) {
                if model.discardRemixAndLoadPendingHistoryEntry() {
                    openWindow(id: "controller")
                }
            }
            Button("Cancel", role: .cancel) { model.continueCurrentRemix() }
        } message: {
            Text("You can keep editing the current request, or replace it with this history request. Your original composer draft will be restored when Remix ends.")
        }
    }

    private func currentTaskCard(_ request: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Current task", systemImage: "play.circle.fill")
                .font(.headline)
                .foregroundStyle(.indigo)
            Text(request)
                .font(.body.weight(.medium))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.indigo.opacity(0.28), lineWidth: 1)
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    "\(model.queuedTasks.count) waiting",
                    systemImage: "list.number"
                )
                .font(.headline)
                Spacer()
                Button("Clear Queue", role: .destructive) {
                    confirmingClearQueue = true
                }
            }

            ForEach(Array(model.queuedTasks.enumerated()), id: \.element.id) { index, task in
                queueRow(task, index: index)
            }
        }
    }

    private func queueRow(
        _ task: QueuedAgentTask,
        index: Int
    ) -> some View {
        let editSession = model.queuedTaskEditSession
        let isEditingThis = editSession?.taskID == task.id

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index + 1)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(.secondary.opacity(0.1), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text(task.request)
                        .font(.body.weight(.medium))
                        .textSelection(.enabled)
                    Text("Queued \(task.queuedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        queueEditButton(task, index: index, editSession: editSession, isEditingThis: isEditingThis)
                        moveEarlierButton(task, index: index)
                        moveLaterButton(task, index: index)
                        removeQueuedButton(task)
                    }
                    VStack(alignment: .trailing, spacing: 6) {
                        queueEditButton(task, index: index, editSession: editSession, isEditingThis: isEditingThis)
                        HStack(spacing: 6) {
                            moveEarlierButton(task, index: index)
                            moveLaterButton(task, index: index)
                            removeQueuedButton(task)
                        }
                    }
                }
            }

            if isEditingThis {
                if !model.isActive, model.queuedTasks.first?.id == task.id {
                    Label("Waiting for Save or Cancel", systemImage: "pause.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                QueuedTaskEditForm(model: model, taskID: task.id, surface: .queueHistory)
            } else if let editSession, model.queuedTasks.contains(where: { $0.id == editSession.taskID }) {
                Text("Finish or cancel the other request’s edit before editing this one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(
                    model.requestedQueueTaskID == task.id ? Color.accentColor.opacity(0.65) : .clear,
                    lineWidth: 2
                )
        }
        .id(task.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waiting request \(index + 1)")
    }

    @ViewBuilder
    private func queueEditButton(
        _ task: QueuedAgentTask,
        index: Int,
        editSession: QueuedTaskEditSession?,
        isEditingThis: Bool
    ) -> some View {
        if !isEditingThis {
            if let editSession,
               model.queuedTasks.contains(where: { $0.id == editSession.taskID }) {
                Button("Continue editing") {
                    model.revealQueuedTask(id: editSession.taskID, continueEditing: true)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reveal the request currently being edited")
            } else {
                Button("Edit") {
                    model.beginQueuedTaskEdit(id: task.id, surface: .queueHistory)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit waiting request \(index + 1)")
            }
        } else {
            Label("Editing", systemImage: "pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func moveEarlierButton(_ task: QueuedAgentTask, index: Int) -> some View {
        Button {
            model.moveQueuedTask(id: task.id, offset: -1)
        } label: {
            Image(systemName: "arrow.up")
        }
        .disabled(index == 0)
        .help("Move earlier")
        .accessibilityLabel("Move waiting request earlier")
    }

    private func moveLaterButton(_ task: QueuedAgentTask, index: Int) -> some View {
        Button {
            model.moveQueuedTask(id: task.id, offset: 1)
        } label: {
            Image(systemName: "arrow.down")
        }
        .disabled(index == model.queuedTasks.count - 1)
        .help("Move later")
        .accessibilityLabel("Move waiting request later")
    }

    private func removeQueuedButton(_ task: QueuedAgentTask) -> some View {
        Button(role: .destructive) {
            model.removeQueuedTask(id: task.id)
        } label: {
            Image(systemName: "trash")
        }
        .help("Remove from queue")
        .accessibilityLabel("Remove waiting request")
    }

    private func scrollToRequestedTask(using proxy: ScrollViewProxy) {
        guard let id = model.requestedQueueTaskID,
              model.queuedTasks.contains(where: { $0.id == id }) else { return }
        proxy.scrollTo(id, anchor: .center)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                if !model.taskHistory.isEmpty {
                    Text("\(model.taskHistory.count) finished")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Delete All", role: .destructive) {
                        confirmingClearHistory = true
                    }
                }
            }

            if model.taskHistory.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "clock",
                    description: Text("Finished requests and their responses will appear here.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ForEach(historyGroups) { yearGroup in
                    Text(String(yearGroup.year))
                        .font(.title3.bold())
                        .padding(.top, 4)

                    ForEach(yearGroup.months) { monthGroup in
                        Text(monthName(monthGroup.month))
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        ForEach(monthGroup.days) { dayGroup in
                            Text(dayGroup.dayStart.formatted(
                                .dateTime.weekday(.wide).month(.wide).day()
                            ))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                            ForEach(dayGroup.entries) { entry in
                                historyRow(entry)
                            }
                        }
                    }
                }
            }
        }
    }

    private func historyRow(
        _ entry: AgentTaskHistoryEntry
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.request)
                    .font(.body.weight(.semibold))
                    .textSelection(.enabled)
                ForEach(entry.corrections ?? []) { correction in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: correction.applied ? "arrow.turn.down.right" : "questionmark.circle")
                            .foregroundStyle(correction.applied ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(correction.applied ? "Applied correction" : "Correction not confirmed")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(correction.applied ? .orange : .secondary)
                            Text(correction.displaySummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(correction.applied ? "Applied correction" : "Correction not confirmed"): \(correction.displaySummary)")
                }
                Spacer()
                Text(entry.finishedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 7) {
                Label(
                    entry.outcome.displayName,
                    systemImage: outcomeIcon(entry.outcome)
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(outcomeColor(entry.outcome))
                if entry.wasQueued {
                    Text("QUEUED")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                Text(entry.responseTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(entry.response)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)

            if let metrics = entry.requestMetrics {
                Text(metrics.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Button {
                    model.rerunHistoryEntry(id: entry.id)
                } label: {
                    Label(
                        model.isActive ? "Queue Request Again" : "Run Request Again",
                        systemImage: model.isActive ? "text.badge.plus" : "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)

                if let candidate = model.continuationCandidate,
                   candidate.historyEntryID == entry.id,
                   model.taskHistory.first?.id == entry.id,
                   candidate.checkpoint.isEligible {
                    Button {
                        model.continueUnfinishedWork(historyEntryID: entry.id)
                    } label: {
                        Label("Continue unfinished work", systemImage: "arrow.clockwise.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("Recheck the previous run’s verified results, then continue requirements that still need work")
                    .accessibilityHint(candidate.checkpoint.explanation)
                }

                Button {
                    if model.beginHistoryRemix(id: entry.id) {
                        openWindow(id: "controller")
                    }
                } label: {
                    Label("Remix", systemImage: "slider.horizontal.3")
                }
                .help("Open this request in the task composer with editable exact inputs")

                Spacer()

                Button("Delete", role: .destructive) {
                    model.deleteHistoryEntry(id: entry.id)
                }
            }
            if let candidate = model.continuationCandidate,
               candidate.historyEntryID == entry.id,
               model.taskHistory.first?.id == entry.id,
               candidate.checkpoint.isEligible {
                Text(model.continuationStartNotice ?? candidate.checkpoint.explanation)
                    .font(.caption)
                    .foregroundStyle(model.continuationStartNotice == nil ? Color.secondary : Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Continue unfinished work. \(model.continuationStartNotice ?? candidate.checkpoint.explanation)")
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        }
    }

    private func monthName(_ month: Int) -> String {
        guard Calendar.current.monthSymbols.indices.contains(month - 1) else {
            return "Month \(month)"
        }
        return Calendar.current.monthSymbols[month - 1]
    }

    private func outcomeIcon(_ outcome: AgentTaskHistoryOutcome) -> String {
        switch outcome {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle.fill"
        }
    }

    private func outcomeColor(_ outcome: AgentTaskHistoryOutcome) -> Color {
        switch outcome {
        case .completed: return .green
        case .failed: return .red
        case .stopped: return .orange
        }
    }
}
