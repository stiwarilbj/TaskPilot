import Foundation

enum QueuedTaskEditSurface: Equatable {
    case mainWindow
    case queueHistory
}

struct QueuedTaskEditSession: Equatable {
    let taskID: UUID
    let originalTask: QueuedAgentTask
    var draft: TaskComposerDraft
    var errorMessage: String?
    var focusSurface: QueuedTaskEditSurface?

    init(task: QueuedAgentTask, surface: QueuedTaskEditSurface) {
        taskID = task.id
        originalTask = task
        draft = TaskComposerDraft(submission: AgentTaskSubmission(
            request: task.request,
            exactInputReferences: task.exactInputReferences ?? []
        ))
        errorMessage = nil
        focusSurface = surface
    }

    /// Builds a replacement only while the original request is still waiting.
    /// It preserves identity and queue position metadata while compiling chip
    /// occurrences into fresh UTF-8 ranges for the immutable submission.
    func replacementQueue(from queue: [QueuedAgentTask]) -> [QueuedAgentTask]? {
        guard let index = queue.firstIndex(where: { $0.id == taskID }),
              queue[index] == originalTask else { return nil }

        let submission = draft.submission().trimmedForSubmission()
        guard !submission.request.isEmpty else { return nil }

        var replacement = queue
        replacement[index] = QueuedAgentTask(
            id: originalTask.id,
            request: submission.request,
            exactInputReferences: submission.exactInputReferences,
            queuedAt: originalTask.queuedAt
        )
        return replacement
    }

    func isEligible(in queue: [QueuedAgentTask]) -> Bool {
        queue.contains(where: { $0.id == taskID && $0 == originalTask })
    }

    func blocksAutomaticHandoff(in queue: [QueuedAgentTask]) -> Bool {
        queue.first?.id == taskID
    }

    /// The replacement is returned only after the caller's durable write has
    /// succeeded, which lets the coordinator publish it without exposing an
    /// unsaved edit as the queue's saved value.
    func commitReplacement(
        from queue: [QueuedAgentTask],
        persist: ([QueuedAgentTask]) throws -> Void
    ) throws -> [QueuedAgentTask]? {
        guard let replacement = replacementQueue(from: queue) else { return nil }
        try persist(replacement)
        return replacement
    }
}
