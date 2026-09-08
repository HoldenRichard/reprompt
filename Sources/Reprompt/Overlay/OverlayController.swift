import AppKit
import SwiftUI

/// Owns the single overlay panel and positions it for each session.
final class OverlayController {
    private var panel: OverlayPanel?
    private let size = NSSize(width: 520, height: 380)

    /// Ordered front WITHOUT taking key focus. A key panel would capture the synthetic
    /// Cmd+C that the clipboard fallback posts, so key focus waits until the grab is done.
    func show(session: RepromptSession, position: OverlayPosition) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.onCancel = { [weak session] in session?.dismiss() }
        panel.contentView = NSHostingView(rootView: OverlayView(session: session))
        panel.setFrame(frame(for: position), display: false)
        panel.orderFrontRegardless()
    }

    /// Called once the selection has been read. Escape and Cmd+Return only reach the panel
    /// after this.
    func takeKeyFocus() {
        panel?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    /// Edit and Clarify need real text focus, which a non-activating panel cannot always give.
    func activateForTextInput() {
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> OverlayPanel {
        OverlayPanel(contentRect: NSRect(origin: .zero, size: size))
    }

    private func frame(for position: OverlayPosition) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        // With no display attached there is nothing sensible to clamp to.
        guard let visible = screen?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }
        return Self.frame(size: size, mouse: mouse, visibleFrame: visible, position: position)
    }

    /// Pure placement maths, kept separate so it can be checked without a display.
    static func frame(size: NSSize, mouse: NSPoint, visibleFrame visible: NSRect,
                      position: OverlayPosition) -> NSRect {
        var origin: NSPoint
        switch position {
        case .cursor:
            origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)
        case .screenCenter:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        // Clamp inside the visible frame, preferring the top-left edge when the panel is
        // larger than the screen so its controls stay reachable.
        let maxX = visible.maxX - size.width - 8
        let maxY = visible.maxY - size.height - 8
        origin.x = min(max(origin.x, visible.minX + 8), max(maxX, visible.minX + 8))
        origin.y = min(max(origin.y, visible.minY + 8), max(maxY, visible.minY + 8))
        return NSRect(origin: origin, size: size)
    }
}
