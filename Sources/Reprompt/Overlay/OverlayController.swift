import AppKit
import SwiftUI

/// Owns the single overlay panel and positions it for each session.
final class OverlayController {
    private var panel: OverlayPanel?
    private let size = NSSize(width: 520, height: 380)

    func show(session: RepromptSession, position: OverlayPosition) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.onCancel = { [weak session] in session?.dismiss() }
        panel.contentView = NSHostingView(rootView: OverlayView(session: session))
        panel.setFrame(frame(for: position), display: false)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    /// Edit mode needs real text focus, which a non-activating panel cannot always give.
    func activateForTextInput() {
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> OverlayPanel {
        OverlayPanel(contentRect: NSRect(origin: .zero, size: size))
    }

    private func frame(for position: OverlayPosition) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin: NSPoint
        switch position {
        case .cursor:
            origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)
        case .screenCenter:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return NSRect(origin: origin, size: size)
    }
}
