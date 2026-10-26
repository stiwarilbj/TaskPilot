import SwiftUI

struct QueuedTaskEditForm: View {
    @ObservedObject var model: TaskPilotCoordinator
    let taskID: UUID
    let surface: QueuedTaskEditSurface

    @AppStorage(TaskPilotAppearancePreferences.inputFontSizeKey)
    private var inputFontSize = TaskPilotAppearancePreferences.defaultInputFontSize
    @State private var focusRequested = false

    private var session: QueuedTaskEditSession? {
        guard let session = model.queuedTaskEditSession, session.taskID == taskID else { return nil }
        return session
    }

    private var draftBinding: Binding<TaskComposerDraft> {
        Binding(
            get: { model.queuedTaskEditDraft(for: taskID) },
            set: { model.updateQueuedTaskEditDraft($0, taskID: taskID) }
        )
    }

    private var shouldFocus: Bool {
        focusRequested || session?.focusSurface == surface
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            TaskRequestComposer(
                draft: draftBinding,
                fontSize: TaskPilotAppearancePreferences.clampedInputFontSize(inputFontSize),
                focusRequested: shouldFocus,
                editorSessionID: session?.editorSessionID,
                onFocusChanged: { focused in
                    focusRequested = focused
                    if focused {
                        model.queuedTaskEditorDidFocus(taskID: taskID, surface: surface)
                    }
                },
                accessibilityLabel: "Edit waiting request"
            )
            .frame(minHeight: 84, maxHeight: 118)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.background.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
            }

            if let error = session?.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Save changes") {
                    model.saveQueuedTaskEdit(taskID: taskID)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.queuedTaskEditDraft(for: taskID).isEmpty)
                .accessibilityLabel("Save changes to waiting request")

                Button("Cancel") {
                    model.cancelQueuedTaskEdit(taskID: taskID)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Cancel waiting request edits")

                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit waiting request")
        .id("queued-editor-\(taskID.uuidString)")
    }
}
