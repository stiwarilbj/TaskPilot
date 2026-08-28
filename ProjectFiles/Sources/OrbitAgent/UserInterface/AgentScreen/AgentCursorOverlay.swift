import AppKit
import CoreGraphics
import Foundation

/// Converts Quartz's top-left display coordinates into AppKit's bottom-left
/// screen coordinates. Keeping this transformation explicit avoids moving the
/// user's hardware cursor just to make an agent action visible.
enum AgentCursorCoordinateMapper {
    static func appKitPoint(
        quartzPoint: CGPoint,
        display: DisplayDescriptor,
        screenFrame: CGRect
    ) -> CGPoint {
        let normalizedX = display.width > 0
            ? (quartzPoint.x - display.frame.minX) / display.frame.width
            : 0.5
        let normalizedY = display.height > 0
            ? (quartzPoint.y - display.frame.minY) / display.frame.height
            : 0.5
        return CGPoint(
            x: screenFrame.minX + min(max(normalizedX, 0), 1) * screenFrame.width,
            y: screenFrame.maxY - min(max(normalizedY, 0), 1) * screenFrame.height
        )
    }
}

/// A display-relative cursor event that Live View can render independently of
/// ScreenCaptureKit. ScreenCaptureKit intentionally excludes TaskPilot's windows on
/// the main display, so relying on the overlay panel alone makes the agent
/// pointer disappear from the viewer.
struct AgentCursorPresentation: Equatable {
    let id: UUID
    let normalizedPoint: CGPoint
    let isClicking: Bool

    init(
        id: UUID = UUID(),
        point: CGPoint,
        display: DisplayDescriptor,
        isClicking: Bool
    ) {
        self.id = id
        normalizedPoint = CGPoint(
            x: display.width > 0
                ? min(max((point.x - display.frame.minX) / display.frame.width, 0), 1)
                : 0.5,
            y: display.height > 0
                ? min(max((point.y - display.frame.minY) / display.frame.height, 0), 1)
                : 0.5
        )
        self.isClicking = isClicking
    }
}

/// Owns a transparent, non-activating panel on the agent display. The panel is
/// click-through and draws an agent pointer without changing the real
/// system pointer, so the user and TaskPilot can visibly have separate cursors.
final class AgentCursorOverlayController: @unchecked Sendable {
    static let actionVisibilityDuration: TimeInterval = 0.9

    /// Delivered on the main thread whenever TaskPilot performs a validated
    /// pointer action. Live View uses this event instead of trying to capture
    /// TaskPilot's own overlay panel and accidentally creating a recursive view.
    var onPresentation: ((AgentCursorPresentation) -> Void)?

    private var panel: NSPanel?
    private var canvas: NSView?
    private var glyph: AgentCursorGlyphView?
    private var displayID: CGDirectDisplayID?
    private var pulseGeneration = 0
    private var visibilityGeneration = 0

    func move(
        to point: CGPoint,
        on display: DisplayDescriptor,
        clicking: Bool,
        visibilityDuration: TimeInterval = AgentCursorOverlayController.actionVisibilityDuration
    ) {
        guard Self.contains(point, in: display.frame) else {
            hide()
            return
        }
        performOnMain { [weak self] in
            self?.present(
                at: point,
                on: display,
                clicking: clicking,
                animated: true,
                visibilityDuration: visibilityDuration
            )
        }
    }

    func hide() {
        performOnMain { [weak self] in
            self?.orderOut()
        }
    }

    private func orderOut() {
        visibilityGeneration += 1
        pulseGeneration += 1
        glyph?.isClicking = false
        panel?.orderOut(nil)
    }

    private func performOnMain(_ operation: @escaping () -> Void) {
        if Thread.isMainThread {
            operation()
        } else {
            // Pointer visibility is part of the action boundary: a screenshot
            // taken immediately after `hide` must not capture a stale glyph,
            // and a click must not race ahead of its visual indicator.
            DispatchQueue.main.sync(execute: operation)
        }
    }

    private func present(
        at quartzPoint: CGPoint,
        on display: DisplayDescriptor,
        clicking: Bool,
        animated: Bool,
        visibilityDuration: TimeInterval
    ) {
        guard Self.contains(quartzPoint, in: display.frame),
              let screen = Self.screen(for: display.id) else {
            orderOut()
            return
        }
        ensurePanel(on: screen, displayID: display.id)
        guard let panel, let glyph else { return }

        if panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: true)
        }
        let globalPoint = AgentCursorCoordinateMapper.appKitPoint(
            quartzPoint: quartzPoint,
            display: display,
            screenFrame: screen.frame
        )
        let localPoint = CGPoint(
            x: globalPoint.x - screen.frame.minX,
            y: globalPoint.y - screen.frame.minY
        )
        let targetOrigin = CGPoint(
            x: min(max(localPoint.x - AgentCursorGlyphView.hotspot.x, 0),
                   max(0, screen.frame.width - glyph.frame.width)),
            y: min(max(localPoint.y - AgentCursorGlyphView.hotspot.y, 0),
                   max(0, screen.frame.height - glyph.frame.height))
        )

        visibilityGeneration += 1
        let visibilityToken = visibilityGeneration
        panel.orderFrontRegardless()
        onPresentation?(AgentCursorPresentation(
            point: quartzPoint,
            display: display,
            isClicking: clicking
        ))
        if animated, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                glyph.animator().setFrameOrigin(targetOrigin)
            }
        } else {
            glyph.setFrameOrigin(targetOrigin)
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.1, visibilityDuration)
        ) { [weak self] in
            guard let self, self.visibilityGeneration == visibilityToken else { return }
            self.orderOut()
        }

        guard clicking else { return }
        pulseGeneration += 1
        let pulseToken = pulseGeneration
        glyph.isClicking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self, weak glyph] in
            guard let self, self.pulseGeneration == pulseToken else { return }
            glyph?.isClicking = false
        }
    }

    private func ensurePanel(on screen: NSScreen, displayID: CGDirectDisplayID) {
        if self.displayID == displayID, panel != nil { return }
        panel?.orderOut(nil)

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]
        panel.sharingType = .readOnly
        panel.setAccessibilityElement(false)

        let canvas = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.clear.cgColor
        canvas.setAccessibilityElement(false)

        let glyph = AgentCursorGlyphView(
            frame: CGRect(origin: .zero, size: AgentCursorGlyphView.glyphSize)
        )
        glyph.setAccessibilityElement(false)
        canvas.addSubview(glyph)
        panel.contentView = canvas

        self.panel = panel
        self.canvas = canvas
        self.glyph = glyph
        self.displayID = displayID
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return false }
            return number.uint32Value == displayID
        }
    }

    private static func contains(_ point: CGPoint, in frame: CGRect) -> Bool {
        frame.insetBy(dx: -0.5, dy: -0.5).contains(point)
    }
}

private final class AgentCursorGlyphView: NSView {
    static let glyphSize = CGSize(width: 86, height: 54)
    static let hotspot = CGPoint(x: 14, y: 40)

    var isClicking = false {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isClicking {
            let ringRect = CGRect(
                x: Self.hotspot.x - 11,
                y: Self.hotspot.y - 11,
                width: 22,
                height: 22
            )
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = 3
            NSColor.systemCyan.withAlphaComponent(0.85).setStroke()
            ring.stroke()
        }

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()

        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: 11, y: 44))
        arrow.line(to: CGPoint(x: 11, y: 16))
        arrow.line(to: CGPoint(x: 18, y: 22))
        arrow.line(to: CGPoint(x: 24, y: 9))
        arrow.line(to: CGPoint(x: 30, y: 12))
        arrow.line(to: CGPoint(x: 24, y: 25))
        arrow.line(to: CGPoint(x: 34, y: 25))
        arrow.close()
        arrow.lineJoinStyle = .round
        arrow.lineWidth = 2.2
        NSColor.white.setStroke()
        NSColor.systemBlue.setFill()
        arrow.fill()
        arrow.stroke()

        NSGraphicsContext.restoreGraphicsState()
        let badgeRect = CGRect(x: 37, y: 14, width: 70, height: 21)
        let badge = NSBezierPath(roundedRect: badgeRect, xRadius: 8, yRadius: 8)
        NSColor.systemBlue.withAlphaComponent(0.94).setFill()
        badge.fill()
        let label = NSAttributedString(
            string: TaskPilotIdentity.displayName.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.white,
                .kern: 0.5
            ]
        )
        let labelSize = label.size()
        label.draw(at: CGPoint(
            x: badgeRect.midX - labelSize.width / 2,
            y: badgeRect.midY - labelSize.height / 2
        ))
    }
}
