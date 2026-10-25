import AppKit
import CoreGraphics
import SwiftUI

enum AgentScreenInteraction {
    case click(CGPoint, count: Int)
    case drag(from: CGPoint, to: CGPoint)
    case scroll(at: CGPoint, deltaX: Int, deltaY: Int)
    case key(code: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags)
}

@MainActor
final class AgentScreenViewerModel: ObservableObject {
    nonisolated static let cursorVisibilityDuration: Duration = .milliseconds(1_500)

    @Published private(set) var image: CGImage?
    @Published private(set) var status = "Connecting to the agent screen…"
    @Published private(set) var interactionStatus = "Click the screen to control it; type after selecting an app"
    @Published private(set) var agentCursor: AgentCursorPresentation?
    @Published private(set) var workingDocumentCandidates: [WorkingDocumentCandidate] = []
    @Published var showingWorkingDocumentPicker = false
    let actionMagnifier = AgentActionMagnifierModel()

    var interactionHandler: ((AgentScreenInteraction, DisplayDescriptor) throws -> String)?
    var workingDocumentCandidateProvider: ((DisplayDescriptor) -> [WorkingDocumentCandidate])?
    var canSelectWorkingDocument: (() -> Bool)?
    var onWorkingDocumentSelection: ((WorkingDocumentCandidate?) -> Void)?
    var onWorkingSelectionRequest: ((WorkingDocumentCandidate) -> Void)?

    private let capture: ScreenCaptureService
    private var captureTask: Task<Void, Never>?
    private var cursorVisibilityTask: Task<Void, Never>?
    private var currentDisplayID: CGDirectDisplayID?
    private var isViewerVisible = false

    var focusedWorkingDocumentLabel: String {
        guard let focused = workingDocumentCandidates.first(where: \.focused) else { return "Choose a window" }
        return "\(focused.title.isEmpty ? "Untitled window" : focused.title) — \(focused.applicationName)"
    }

    init(capture: ScreenCaptureService) {
        self.capture = capture
    }

    func start(display: DisplayDescriptor?) {
        isViewerVisible = display != nil
        if let newID = display?.id, let currentDisplayID, currentDisplayID != newID {
            actionMagnifier.clear(keepGeneration: true)
        }
        currentDisplayID = display?.id
        captureTask?.cancel()
        captureTask = nil
        guard let display else {
            actionMagnifier.clear(keepGeneration: true)
            image = nil
            status = "The agent screen is not connected"
            return
        }

        status = "Connecting to \(display.name)…"
        captureTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let frame = try await capture.capturePreview(display: display)
                    guard !Task.isCancelled else { return }
                    image = frame
                    status = "Live — \(display.name)"
                    try await Task.sleep(for: .milliseconds(100))
                } catch is CancellationError {
                    return
                } catch {
                    image = nil
                    status = error.localizedDescription
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    func stop() {
        captureTask?.cancel()
        captureTask = nil
        cursorVisibilityTask?.cancel()
        cursorVisibilityTask = nil
        agentCursor = nil
        currentDisplayID = nil
        isViewerVisible = false
        actionMagnifier.clear(keepGeneration: true)
    }

    func beginTask(_ generationID: String) { actionMagnifier.beginTask(generationID) }

    func handleActionMagnifier(_ event: AgentActionMagnifierEvent) {
        switch event.kind {
        case .targeted(let request):
            guard isViewerVisible, currentDisplayID == request.displayID else { return }
            actionMagnifier.show(request)
        case .state(let actionID, let generationID, let sequence, let state):
            actionMagnifier.update(actionID: actionID, generationID: generationID,
                                   sequence: sequence, state: state)
        case .clear(let generationID, let sequence):
            actionMagnifier.clear(generationID: generationID, sequence: sequence)
        }
    }

    func clearActionMagnifier() { actionMagnifier.clear(keepGeneration: true) }

    func showAgentCursor(_ presentation: AgentCursorPresentation) {
        cursorVisibilityTask?.cancel()
        agentCursor = presentation
        cursorVisibilityTask = Task { [weak self] in
            try? await Task.sleep(for: Self.cursorVisibilityDuration)
            guard !Task.isCancelled,
                  self?.agentCursor?.id == presentation.id else { return }
            self?.agentCursor = nil
        }
    }

    func handle(_ interaction: AgentScreenInteraction, display: DisplayDescriptor) {
        do {
            interactionStatus = try interactionHandler?(interaction, display)
                ?? "Live control is not connected"
        } catch {
            interactionStatus = error.localizedDescription
        }
    }

    func openWorkingDocumentPicker() { showingWorkingDocumentPicker = true }

    func refreshWorkingDocumentCandidates(display: DisplayDescriptor?) {
        guard isViewerVisible, let display else { workingDocumentCandidates = []; return }
        workingDocumentCandidates = Array((workingDocumentCandidateProvider?(display) ?? []).prefix(32))
    }

    func selectWorkingDocument(_ candidate: WorkingDocumentCandidate?) {
        guard canSelectWorkingDocument?() == true else { return }
        onWorkingDocumentSelection?(candidate)
        showingWorkingDocumentPicker = false
    }

    func limitWorkingDocumentToSelection(_ candidate: WorkingDocumentCandidate) {
        guard canSelectWorkingDocument?() == true, candidate.availableSelection != nil else { return }
        onWorkingSelectionRequest?(candidate)
        showingWorkingDocumentPicker = false
    }

    var workingDocumentSelectionEnabled: Bool { canSelectWorkingDocument?() == true }
}

struct AgentScreenViewer: View {
    @ObservedObject var model: AgentScreenViewerModel
    let display: DisplayDescriptor?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = model.image {
                ZStack {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if let display {
                        RemoteInputSurface(display: display) { interaction in
                            model.handle(interaction, display: display)
                        }

                        if let cursor = model.agentCursor {
                            AgentCursorLiveOverlay(
                                presentation: cursor,
                                displaySize: display.frame.size
                            )
                            .allowsHitTesting(false)
                            .transition(.opacity)
                        }

                        AgentActionMagnifierOverlay(
                            model: model.actionMagnifier,
                            displaySize: display.frame.size
                        )
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.image == nil ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text(model.status)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(.black.opacity(0.68), in: Capsule())

                Button { model.openWorkingDocumentPicker() } label: {
                    Label(model.focusedWorkingDocumentLabel, systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 280, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(!model.workingDocumentSelectionEnabled)
                .accessibilityLabel("Choose the working document. Focused window: \(model.focusedWorkingDocumentLabel)")
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(.black.opacity(0.68), in: Capsule())
                .popover(isPresented: $model.showingWorkingDocumentPicker, arrowEdge: .top) {
                    workingDocumentPicker
                        .onAppear { model.refreshWorkingDocumentCandidates(display: display) }
                        .frame(width: 340)
                }
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .overlay(alignment: .bottom) {
            Label(model.interactionStatus, systemImage: "hand.point.up.left.fill")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(14)
        }
        .onAppear {
            model.start(display: display)
            model.refreshWorkingDocumentCandidates(display: display)
        }
        .onDisappear { model.stop() }
        .onChange(of: display) { _, updatedDisplay in
            model.start(display: updatedDisplay)
            model.refreshWorkingDocumentCandidates(display: updatedDisplay)
        }
    }

    private var workingDocumentPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Working document")
                .font(.headline)
            Text("Choose a visible window for references like ‘this spreadsheet.’ TaskPilot will confirm it before using it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let focused = model.workingDocumentCandidates.first(where: \.focused) {
                Button {
                    model.selectWorkingDocument(focused)
                } label: {
                    Label("Use this document for the current request", systemImage: "checkmark.document")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!model.workingDocumentSelectionEnabled)
                .accessibilityLabel("Use focused document \(focused.title) from \(focused.applicationName) for the current request")
                if let selection = focused.availableSelection {
                    Button {
                        model.limitWorkingDocumentToSelection(focused)
                    } label: {
                        Label("Work only in this selection · \(selection.description)", systemImage: "scope")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(!model.workingDocumentSelectionEnabled)
                    .accessibilityLabel("Work only in \(selection.description) in \(focused.title), \(focused.applicationName)")
                } else {
                    Text("No supported single selection is available. It may be empty, disconnected, secure, oversized, or unsupported. Select one continuous text range, a rectangular cell range, or a supported section.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
            }
            if model.workingDocumentCandidates.isEmpty {
                Text("No eligible windows are visible on this display.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.workingDocumentCandidates) { candidate in
                            VStack(alignment: .leading, spacing: 3) {
                                Button {
                                    model.selectWorkingDocument(candidate)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.menuTitle)
                                            .font(.callout)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if let location = candidate.location {
                                            Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                .disabled(!model.workingDocumentSelectionEnabled)
                                .accessibilityLabel("Use \(candidate.title.isEmpty ? "Untitled window" : candidate.title), \(candidate.applicationName)\(candidate.location.map { ", \($0)" } ?? "") as the working document")
                                if let selection = candidate.availableSelection {
                                    Button {
                                        model.limitWorkingDocumentToSelection(candidate)
                                    } label: {
                                        Label("Work only in \(selection.description)", systemImage: "scope")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!model.workingDocumentSelectionEnabled)
                                    .accessibilityLabel("Work only in \(selection.description) in \(candidate.title), \(candidate.applicationName)")
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(15)
    }
}

enum AgentScreenCursorMapper {
    static func fittedContentRect(displaySize: CGSize, viewportSize: CGSize) -> CGRect {
        guard displaySize.width > 0, displaySize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return .zero }
        let scale = min(
            viewportSize.width / displaySize.width,
            viewportSize.height / displaySize.height
        )
        let size = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
        return CGRect(
            x: (viewportSize.width - size.width) / 2,
            y: (viewportSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    static func point(normalizedPoint: CGPoint, in contentRect: CGRect) -> CGPoint {
        CGPoint(
            x: contentRect.minX + min(max(normalizedPoint.x, 0), 1) * contentRect.width,
            y: contentRect.minY + min(max(normalizedPoint.y, 0), 1) * contentRect.height
        )
    }
}

private struct AgentCursorLiveOverlay: View {
    let presentation: AgentCursorPresentation
    let displaySize: CGSize

    var body: some View {
        GeometryReader { proxy in
            let contentRect = AgentScreenCursorMapper.fittedContentRect(
                displaySize: displaySize,
                viewportSize: proxy.size
            )
            let point = AgentScreenCursorMapper.point(
                normalizedPoint: presentation.normalizedPoint,
                in: contentRect
            )

            ZStack(alignment: .topLeading) {
                if presentation.isClicking {
                    Circle()
                        .stroke(Color.cyan.opacity(0.9), lineWidth: 3)
                        .frame(width: 25, height: 25)
                        .offset(x: -10, y: -10)
                }

                Image(systemName: "cursorarrow")
                    .font(.system(size: 30, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.blue)
                    .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)

                Text(TaskPilotIdentity.displayName.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.95), in: Capsule())
                    .offset(x: 24, y: 18)
            }
            .position(x: point.x + 22, y: point.y + 16)
            .animation(.easeOut(duration: 0.08), value: presentation.normalizedPoint)
        }
    }
}

private struct RemoteInputSurface: NSViewRepresentable {
    let display: DisplayDescriptor
    let handler: (AgentScreenInteraction) -> Void

    func makeNSView(context: Context) -> RemoteInputView {
        let view = RemoteInputView()
        view.displaySize = display.frame.size
        view.handler = handler
        return view
    }

    func updateNSView(_ view: RemoteInputView, context: Context) {
        view.displaySize = display.frame.size
        view.handler = handler
    }
}

private final class RemoteInputView: NSView {
    var displaySize = CGSize(width: 16, height: 10)
    var handler: ((AgentScreenInteraction) -> Void)?
    private var mouseDownPoint: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownPoint = normalizedPoint(for: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = mouseDownPoint,
              let end = normalizedPoint(for: event.locationInWindow) else { return }
        mouseDownPoint = nil
        let dx = (end.x - start.x) * bounds.width
        let dy = (end.y - start.y) * bounds.height
        if hypot(dx, dy) < 5 {
            handler?(.click(end, count: max(1, event.clickCount)))
        } else {
            handler?(.drag(from: start, to: end))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = normalizedPoint(for: event.locationInWindow) else { return }
        let multiplier = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        handler?(.scroll(
            at: point,
            deltaX: Int((event.scrollingDeltaX * multiplier).rounded()),
            deltaY: Int((event.scrollingDeltaY * multiplier).rounded())
        ))
    }

    override func keyDown(with event: NSEvent) {
        handler?(.key(
            code: event.keyCode,
            characters: event.characters,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        ))
    }

    private func normalizedPoint(for windowPoint: CGPoint) -> CGPoint? {
        let localPoint = convert(windowPoint, from: nil)
        let content = fittedContentRect
        guard content.contains(localPoint), content.width > 0, content.height > 0 else { return nil }
        return CGPoint(
            x: (localPoint.x - content.minX) / content.width,
            y: (content.maxY - localPoint.y) / content.height
        )
    }

    private var fittedContentRect: CGRect {
        guard displaySize.width > 0, displaySize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / displaySize.width, bounds.height / displaySize.height)
        let size = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
