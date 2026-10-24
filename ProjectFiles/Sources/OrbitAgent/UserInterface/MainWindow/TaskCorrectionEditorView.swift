import SwiftUI

struct TaskCorrectionEditorView: View {
    @ObservedObject var model: TaskPilotCoordinator
    let session: TaskCorrectionSession
    let surface: Color
    let border: Color
    let fontSize: CGFloat

    @State private var focusRequested = true

    private var draft: Binding<TaskComposerDraft> {
        Binding(
            get: { model.taskCorrectionDraft(for: session.generationID) },
            set: { model.updateTaskCorrectionDraft($0) }
        )
    }

    private var canEdit: Bool { session.state == .editing && model.currentTaskGenerationID == session.generationID }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.orange)
                Text(session.state == .finished ? "Correction not applied" : "Keep going, but…")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if let notice = session.notice {
                    Text(notice)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(notice == "Correction pending" ? .orange : .green)
                        .accessibilityIdentifier("task-correction-feedback")
                }
            }

            TaskRequestComposer(
                draft: draft,
                fontSize: fontSize,
                focusRequested: focusRequested && canEdit,
                onFocusChanged: { focusRequested = $0 },
                accessibilityLabel: "Correction to the current task"
            )
            .frame(minHeight: 78, maxHeight: 118)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(surface.opacity(0.62), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(border.opacity(0.85), lineWidth: 1)
            }
            .disabled(!canEdit)

            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Apply correction") {
                    model.applyTaskCorrection(draft.wrappedValue.submission())
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canApplyTaskCorrection(generationID: session.generationID))
                .accessibilityLabel("Apply correction to the running task")

                Button(session.state == .finished ? "Dismiss" : "Cancel") {
                    model.cancelTaskCorrection()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .disabled(session.state == .pending)

                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(border.opacity(0.6), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task correction editor")
        .accessibilityIdentifier("task-correction-editor")
        .onExitCommand { model.cancelTaskCorrection() }
    }
}
