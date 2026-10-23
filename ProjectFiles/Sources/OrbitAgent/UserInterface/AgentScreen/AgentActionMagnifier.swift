import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import SwiftUI

enum AgentActionMagnifierState: Equatable {
    case targeting
    case delivered(String)
    case confirmed(String)
    case uncertain
    case rejected

    var title: String {
        switch self {
        case .targeting: "Targeting"
        case .delivered(let action): "\(action) — result unconfirmed"
        case .confirmed(let scope): "Result confirmed: \(scope.replacingOccurrences(of: "_", with: " "))"
        case .uncertain: "Delivery uncertain"
        case .rejected: "Not delivered"
        }
    }
}

struct AgentActionMagnifierEvent {
    enum Kind {
        case targeted(AgentActionMagnifierRequest)
        case state(actionID: String, generationID: String, sequence: UInt64, state: AgentActionMagnifierState)
        case clear(generationID: String, sequence: UInt64)
    }
    let kind: Kind

    var generationID: String {
        switch kind {
        case .targeted(let request): request.generationID
        case .state(_, let generationID, _, _), .clear(let generationID, _): generationID
        }
    }
}

enum AgentActionMagnifierCaption {
    static func actionTitle(for type: String) -> String? {
        return switch type {
        case "press": "Pressed"
        case "click": "Clicked"
        case "double_click": "Double-clicked"
        case "scroll": "Scrolled"
        default: nil
        }
    }

    static func breadcrumb(target: String?, containers: [String], application: String) -> String {
        func clean(_ value: String?) -> String? {
            guard let value else { return nil }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        let app = clean(application) ?? "Application"
        let target = clean(target)
        let parents = containers.compactMap(clean)
        guard target != nil || !parents.isEmpty else { return "Screen location → \(app)" }
        var seen: Set<String> = []
        let chain = ([target].compactMap { $0 } + Array(parents.suffix(2)) + [app])
            .filter { seen.insert($0).inserted }
        return chain.joined(separator: " → ")
    }
}

/// Pins the already accepted observation file so Python may unlink its path
/// without changing the exact pixels this action was planned against.
final class AgentMagnifierImageSource: @unchecked Sendable {
    let mapping: ScreenCoordinateMapping
    private let protectedTargets: [CGRect]
    private let lock = NSLock()
    private var descriptor: Int32

    init(url: URL, mapping: ScreenCoordinateMapping, protectedTargets: [CGRect]) throws {
        var info = stat()
        let opened = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard opened >= 0 else { throw POSIXError(.EIO) }
        guard fstat(opened, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= 32 * 1024 * 1024 else {
            Darwin.close(opened)
            throw POSIXError(.EFBIG)
        }
        self.descriptor = opened
        self.mapping = mapping
        self.protectedTargets = protectedTargets
    }

    func makeReader() -> AgentMagnifierImageReader? {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return nil }
        let copy = Darwin.dup(descriptor)
        guard copy >= 0 else { return nil }
        return AgentMagnifierImageReader(descriptor: copy, mapping: mapping, protectedTargets: protectedTargets)
    }

    deinit {
        lock.lock(); let old = descriptor; descriptor = -1; lock.unlock()
        if old >= 0 { Darwin.close(old) }
    }
}

final class AgentMagnifierImageReader: @unchecked Sendable {
    private let handle: FileHandle
    private let mapping: ScreenCoordinateMapping
    private let protectedTargets: [CGRect]

    fileprivate init(descriptor: Int32, mapping: ScreenCoordinateMapping, protectedTargets: [CGRect]) {
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.mapping = mapping
        self.protectedTargets = protectedTargets
    }

    func crop(target: CGRect?, pointer: CGPoint) -> AgentMagnifierCrop? {
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let displayedImageWidth = mapping.sourceRect.width / mapping.fullImageSize.width * mapping.displayBounds.width
        let displayedImageHeight = mapping.sourceRect.height / mapping.fullImageSize.height * mapping.displayBounds.height
        let scaleX = mapping.imageSize.width / displayedImageWidth
        let scaleY = mapping.imageSize.height / displayedImageHeight
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return nil }
        // The card is 240×140 points. Its crop covers 120×70 display points,
        // so filling the card gives a stable 2× magnification at any display scale.
        let pixelWidth = min(image.width, max(1, Int((120 * scaleX).rounded(.down))))
        let pixelHeight = min(image.height, max(1, Int((70 * scaleY).rounded(.down))))
        let width = CGFloat(pixelWidth)
        let height = CGFloat(pixelHeight)
        guard width > 1, height > 1 else { return nil }
        let center = target.map { CGPoint(x: $0.midX, y: $0.midY) } ?? pointer
        guard let imageCenter = try? mapping.imagePoint(fromGlobal: center) else { return nil }
        let maxX = CGFloat(image.width) - width
        let maxY = CGFloat(image.height) - height
        let originX = min(max(0, Int((imageCenter.x - width / 2).rounded(.down))), Int(maxX))
        let originY = min(max(0, Int((imageCenter.y - height / 2).rounded(.down))), Int(maxY))
        let cropRect = CGRect(x: CGFloat(originX), y: CGFloat(originY), width: width, height: height)
        for protected in protectedTargets {
            guard let topLeft = try? mapping.imagePoint(fromGlobal: CGPoint(x: protected.minX, y: protected.minY)),
                  let bottomRight = try? mapping.imagePoint(fromGlobal: CGPoint(x: protected.maxX, y: protected.maxY)) else { continue }
            let protectedImageRect = CGRect(x: topLeft.x, y: topLeft.y,
                                            width: bottomRight.x - topLeft.x,
                                            height: bottomRight.y - topLeft.y)
            if protectedImageRect.intersects(cropRect) { return nil }
        }
        guard let cropped = image.cropping(to: cropRect) else { return nil }
        let targetInCrop = target.flatMap { rectangle -> CGRect? in
            guard let topLeft = try? mapping.imagePoint(fromGlobal: CGPoint(x: rectangle.minX, y: rectangle.minY)),
                  let bottomRight = try? mapping.imagePoint(fromGlobal: CGPoint(x: rectangle.maxX, y: rectangle.maxY)) else { return nil }
            let imageRect = CGRect(x: topLeft.x, y: topLeft.y,
                                   width: bottomRight.x - topLeft.x,
                                   height: bottomRight.y - topLeft.y).intersection(cropRect)
            guard !imageRect.isNull, imageRect.width > 0, imageRect.height > 0 else { return nil }
            return CGRect(x: (imageRect.minX - cropRect.minX) / cropRect.width,
                          y: (imageRect.minY - cropRect.minY) / cropRect.height,
                          width: imageRect.width / cropRect.width,
                          height: imageRect.height / cropRect.height)
        }
        guard let imagePointer = try? mapping.imagePoint(fromGlobal: pointer) else { return nil }
        let pointerInCrop = CGPoint(x: (imagePointer.x - cropRect.minX) / cropRect.width,
                                    y: (imagePointer.y - cropRect.minY) / cropRect.height)
        return AgentMagnifierCrop(image: cropped, target: targetInCrop, pointer: pointerInCrop)
    }
}

struct AgentMagnifierCrop {
    let image: CGImage
    let target: CGRect?
    let pointer: CGPoint
}

struct AgentActionMagnifierRequest {
    let actionID: String
    let generationID: String
    let sequence: UInt64
    let observationRevision: String
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect
    let mapping: ScreenCoordinateMapping
    let actionTitle: String
    let breadcrumb: String
    let pointer: CGPoint
    let target: CGRect?
    let reader: AgentMagnifierImageReader?
}

struct AgentActionMagnifierPresentation {
    let request: AgentActionMagnifierRequest
    var state: AgentActionMagnifierState = .targeting
    var crop: AgentMagnifierCrop?
    var hasNewerAction = false
}

@MainActor
final class AgentActionMagnifierModel: ObservableObject {
    static let visibilityDuration: Duration = .seconds(4)

    @Published private(set) var presentation: AgentActionMagnifierPresentation?
    @Published private(set) var isPinned = false

    private(set) var generationID: String?
    private var expiryTask: Task<Void, Never>?
    private var cropTask: Task<Void, Never>?
    private var pendingCrop: AgentActionMagnifierRequest?
    private var latest: AgentActionMagnifierPresentation?
    private var latestSequence: UInt64 = 0

    func beginTask(_ generationID: String) {
        clear()
        self.generationID = generationID
        latestSequence = 0
    }

    func show(_ request: AgentActionMagnifierRequest) {
        guard request.generationID == generationID,
              request.sequence > latestSequence,
              !request.observationRevision.isEmpty,
              request.mapping.displayID == request.displayID,
              request.mapping.displayBounds == request.displayFrame else { return }
        expiryTask?.cancel(); expiryTask = nil
        latestSequence = request.sequence
        var next = AgentActionMagnifierPresentation(request: request)
        next.hasNewerAction = isPinned && presentation?.request.actionID != request.actionID
        latest = next
        if !isPinned {
            presentation = next
        } else if var pinned = presentation {
            pinned.hasNewerAction = true
            presentation = pinned
        }
        enqueueCrop(request)
    }

    func update(actionID: String, generationID: String, sequence: UInt64? = nil,
                state: AgentActionMagnifierState) {
        guard generationID == self.generationID,
              var current = latest, current.request.actionID == actionID,
              current.request.generationID == generationID,
              sequence == nil || sequence == current.request.sequence else { return }
        current.state = state
        latest = current
        if !isPinned, presentation?.request.actionID == actionID { presentation = current }
        switch state {
        case .targeting: break
        default: startExpiry(for: actionID, generationID: generationID)
        }
    }

    func pin() {
        guard !isPinned, let presentation else { return }
        isPinned = true
        self.presentation = presentation
    }

    func followLatest() {
        isPinned = false
        presentation = latest
        if let latest, latest.crop == nil { enqueueCrop(latest.request) }
        if let latest { startExpiry(for: latest.request.actionID, generationID: latest.request.generationID) }
    }

    func dismiss() { clear(keepGeneration: true) }

    func clear(keepGeneration: Bool = false) {
        expiryTask?.cancel(); expiryTask = nil
        // A detached ImageIO decode cannot be cancelled safely in the middle
        // of reading. Keep ownership of the one in-flight slot until it ends;
        // clear() drops the replaceable pending reader immediately.
        pendingCrop = nil
        latest = nil
        presentation = nil
        isPinned = false
        if !keepGeneration { generationID = nil }
    }

    func expire(actionID: String, generationID: String) {
        guard !isPinned, self.generationID == generationID,
              presentation?.request.actionID == actionID else { return }
        clear(keepGeneration: true)
    }

    func clear(generationID: String, sequence: UInt64) {
        guard generationID == self.generationID, sequence >= latestSequence else { return }
        latestSequence = sequence
        clear(keepGeneration: true)
    }

    private func startExpiry(for actionID: String, generationID: String) {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibilityDuration)
            guard !Task.isCancelled else { return }
            self?.expire(actionID: actionID, generationID: generationID)
        }
    }

    private func enqueueCrop(_ request: AgentActionMagnifierRequest) {
        guard let reader = request.reader else { return }
        guard cropTask == nil else { pendingCrop = request; return }
        cropTask = Task { [weak self] in
            let crop = await Task.detached(priority: .utility) {
                reader.crop(target: request.target, pointer: request.pointer)
            }.value
            guard let self else { return }
            self.accept(crop, for: request)
            self.cropTask = nil
            if let pending = self.pendingCrop {
                self.pendingCrop = nil
                self.enqueueCrop(pending)
            }
        }
    }

    private func accept(_ crop: AgentMagnifierCrop?, for request: AgentActionMagnifierRequest) {
        guard var current = latest,
              current.request.actionID == request.actionID,
              current.request.generationID == request.generationID else { return }
        current.crop = crop
        latest = current
        if !isPinned, presentation?.request.actionID == request.actionID { presentation = current }
    }
}

enum AgentActionMagnifierLayout {
    static func scale(in size: CGSize) -> CGFloat {
        let available = min((size.width - 16) / 240, (size.height - 16) / 236)
        return min(1, max(0.25, available))
    }

    static func frame(cursor: CGPoint, size: CGSize, bounds: CGRect, reserved: [CGRect]) -> CGRect {
        let offsets: [(CGFloat, CGFloat)] = [(24, -24), (-24, -24), (24, 24), (-24, 24)]
        let initial = offsets.map { dx, dy -> CGRect in
            let x = dx > 0 ? cursor.x + dx : cursor.x - dx * -1 - size.width
            let y = dy > 0 ? cursor.y + dy : cursor.y - size.height + dy
            return clamp(CGRect(x: x, y: y, width: size.width, height: size.height), size: size, in: bounds)
        }
        var candidates = initial
        for candidate in initial {
            for area in reserved where candidate.intersects(area) {
                candidates.append(clamp(CGRect(x: candidate.minX, y: area.minY - size.height,
                    width: size.width, height: size.height), size: size, in: bounds))
                candidates.append(clamp(CGRect(x: candidate.minX, y: area.maxY,
                    width: size.width, height: size.height), size: size, in: bounds))
                candidates.append(clamp(CGRect(x: area.minX - size.width, y: candidate.minY,
                    width: size.width, height: size.height), size: size, in: bounds))
                candidates.append(clamp(CGRect(x: area.maxX, y: candidate.minY,
                    width: size.width, height: size.height), size: size, in: bounds))
            }
        }
        return candidates.min { score($0, cursor: cursor, reserved: reserved) < score($1, cursor: cursor, reserved: reserved) } ?? .zero
    }

    private static func clamp(_ frame: CGRect, size: CGSize, in bounds: CGRect) -> CGRect {
        CGRect(x: min(max(bounds.minX, frame.minX), max(bounds.minX, bounds.maxX - size.width)),
               y: min(max(bounds.minY, frame.minY), max(bounds.minY, bounds.maxY - size.height)),
               width: size.width, height: size.height)
    }

    private static func score(_ frame: CGRect, cursor: CGPoint, reserved: [CGRect]) -> CGFloat {
        let overlap = reserved.reduce(CGFloat.zero) { $0 + $1.intersection(frame).area }
        return overlap * 1000 + hypot(frame.midX - cursor.x, frame.midY - cursor.y)
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

struct AgentActionMagnifierOverlay: View {
    @ObservedObject var model: AgentActionMagnifierModel
    let displaySize: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            if let presentation = model.presentation {
                let content = AgentScreenCursorMapper.fittedContentRect(
                    displaySize: displaySize,
                    viewportSize: proxy.size
                )
                let normalized = CGPoint(
                    x: (presentation.request.pointer.x - presentation.request.displayFrame.minX) / presentation.request.displayFrame.width,
                    y: (presentation.request.pointer.y - presentation.request.displayFrame.minY) / presentation.request.displayFrame.height
                )
                let cursor = AgentScreenCursorMapper.point(normalizedPoint: normalized, in: content)
                let scale = AgentActionMagnifierLayout.scale(in: content.size)
                let size = CGSize(width: 240 * scale, height: 236 * scale)
                let reserved = [
                    CGRect(x: content.minX, y: content.minY, width: min(280, content.width), height: 52),
                    CGRect(x: content.minX, y: content.maxY - 48, width: content.width, height: 48)
                ]
                let rect = AgentActionMagnifierLayout.frame(cursor: cursor, size: size, bounds: content, reserved: reserved)
                Group {
                    if model.isPinned {
                        card(presentation, scale: scale, pinned: true)
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture().onEnded {})
                    } else {
                        Button { model.pin() } label: {
                            card(presentation, scale: scale, pinned: false)
                        }
                        .buttonStyle(.plain)
                        .help("Pin this action explanation")
                        .accessibilityLabel(accessibilityLabel(presentation) + ". Activate to pin this explanation.")
                    }
                }
                .frame(width: size.width, height: size.height)
                .position(x: rect.midX, y: rect.midY)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.presentation?.request.actionID)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.presentation?.state.title)
        .allowsHitTesting(model.presentation != nil)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func card(_ presentation: AgentActionMagnifierPresentation, scale: CGFloat, pinned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(presentation.state.title)
                        .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if pinned {
                    Text("Pinned")
                            .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Button("Follow latest") { model.followLatest() }
                        .font(.system(size: 9, weight: .semibold))
                        .buttonStyle(.borderless)
                    Button { model.dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss pinned explanation")
                    .accessibilityLabel("Dismiss pinned explanation")
                } else if presentation.hasNewerAction {
                    Text("Newer action available")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.75))
                if let crop = presentation.crop {
                    GeometryReader { imageProxy in
                        Image(decorative: crop.image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: imageProxy.size.width, height: imageProxy.size.height)
                        if let target = crop.target {
                            Rectangle()
                                .stroke(Color.cyan, lineWidth: 2)
                                .frame(width: max(2, target.width * imageProxy.size.width),
                                       height: max(2, target.height * imageProxy.size.height))
                                .position(x: target.midX * imageProxy.size.width,
                                          y: target.midY * imageProxy.size.height)
                        }
                        Circle()
                            .fill(.orange)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(.white, lineWidth: 1))
                            .position(x: crop.pointer.x * imageProxy.size.width,
                                      y: crop.pointer.y * imageProxy.size.height)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    Label("Screen crop unavailable", systemImage: "viewfinder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(height: 140)

            Text(presentation.request.breadcrumb)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
            Text("Observed before action")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(width: 240, height: 236, alignment: .topLeading)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: 240 * scale, height: 236 * scale, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
    }

    private func accessibilityLabel(_ presentation: AgentActionMagnifierPresentation) -> String {
        "\(presentation.state.title). \(presentation.request.breadcrumb). Observed before action."
    }
}
