import AppKit

/// Blue edge-highlight used by the source picker to show which physical
/// display a hovered "Display N" card refers to on multi-monitor rigs —
/// the displayID number alone doesn't map to anything the user can see.
///
/// Same four-thin-opaque-strip pattern as `RecordingBorderWindow` — a
/// fullscreen transparent overlay would force the WindowServer to
/// alpha-composite every refresh, which is wasteful for a purely
/// informational hover cue.
@MainActor
final class ScreenHighlightWindow {
    private var panels: [NSPanel] = []
    private var currentScreen: NSScreen?

    private let thickness: CGFloat = 6
    private let color: NSColor = .systemBlue

    func show(on screen: NSScreen) {
        // No-op if we're already highlighting this screen — the hover
        // loop fires steadily and we'd otherwise tear down and rebuild
        // on every mouse move inside a single card.
        if currentScreen == screen, !panels.isEmpty { return }
        hide()
        currentScreen = screen
        for strip in makeStrips(on: screen) {
            panels.append(strip)
        }
        for p in panels { p.orderFrontRegardless() }
    }

    func hide() {
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
        currentScreen = nil
    }

    private func makeStrips(on screen: NSScreen) -> [NSPanel] {
        let f = screen.frame
        let t = thickness
        let top    = NSRect(x: f.minX,         y: f.maxY - t, width: f.width,     height: t)
        let bottom = NSRect(x: f.minX,         y: f.minY,     width: f.width,     height: t)
        let left   = NSRect(x: f.minX,         y: f.minY + t, width: t,           height: f.height - 2 * t)
        let right  = NSRect(x: f.maxX - t,     y: f.minY + t, width: t,           height: f.height - 2 * t)
        return [top, bottom, left, right].map { strip(rect: $0, screen: screen) }
    }

    private func strip(rect: NSRect, screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.isOpaque = true
        panel.backgroundColor = color
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary
        ]
        // AppKit relocates contentRect on multi-display rigs — pin the
        // frame back to the rect we actually want. Same fix as
        // RecordingBorderWindow + CountdownOverlay.
        panel.setFrame(rect, display: false)
        return panel
    }
}
