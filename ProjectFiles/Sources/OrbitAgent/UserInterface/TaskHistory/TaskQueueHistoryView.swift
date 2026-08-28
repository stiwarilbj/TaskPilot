import SwiftUI

struct TaskQueueHistoryView: View {
    @ObservedObject var model: TaskPilotCoordinator
    @Environment(\.dismissWindow) private var dismissWindow
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
        }
        .frame(minWidth: 680, minHeight: 560)
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
    }

    private func currentTaskCard(_ request: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Running now", systemImage: "play.circle.fill")
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
        HStack(alignment: .top, spacing: 12) {
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

            HStack(spacing: 4) {
                Button {
                    model.moveQueuedTask(id: task.id, offset: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(index == 0)
                .help("Move earlier")

                Button {
                    model.moveQueuedTask(id: task.id, offset: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(index == model.queuedTasks.count - 1)
                .help("Move later")

                Button(role: .destructive) {
                    model.removeQueuedTask(id: task.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove from queue")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
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

                Spacer()

                Button("Delete", role: .destructive) {
                    model.deleteHistoryEntry(id: entry.id)
                }
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
