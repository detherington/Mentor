import AppKit
import ScreenCaptureKit

/// Thin red "you're recording" border shown at the edges of the captured
/// display. Excluded from the recording itself because Mentor's own
/// windows are in `SCContentFilter.excludingApplications`.
///
/// Implementation detail: four thin OPAQUE NSPanel strips (top / bottom /
/// left / right) rather than one fullscreen transparent panel. A
/// fullscreen transparent overlay is cheap on paper but forces the
/// WindowServer to alpha-composite the entire screen every display
/// refresh, which contends with the GPU bandwidth our Core Image preview
/// pipeline is already using — empirically that caused visible webcam
/// preview jitter on a 4K-class display. Four thin opaque strips cost
/// essentially nothing to composite.
@MainActor
final class RecordingBorderWindow {
    private var panels: [NSPanel] = []

    private let thickness: CGFloat = 4
    private let color: NSColor = .systemRed

    func show(for source: CaptureSource) {
        hide()
        for screen in targetScreens(for: source) {
            panels.append(contentsOf: makeStrips(on: screen))
        }
        for p in panels { p.orderFrontRegardless() }
    }

    func hide() {
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
    }

    // MARK: - Strip construction

    private func makeStrips(on screen: NSScreen) -> [NSPanel] {
        let f = screen.frame
        let t = thickness

        // Each strip's rect in screen (global) coordinates. Strips are
        // sized so they abut cleanly at the corners without overlap.
        let top    = NSRect(x: f.minX,         y: f.maxY - t,  width: f.width,      height: t)
        let bottom = NSRect(x: f.minX,         y: f.minY,      width: f.width,      height: t)
        let left   = NSRect(x: f.minX,         y: f.minY + t,  width: t,            height: f.height - 2 * t)
        let right  = NSRect(x: f.maxX - t,     y: f.minY + t,  width: t,            height: f.height - 2 * t)

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
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        return panel
    }

    // MARK: - Target screen resolution

    private func targetScreens(for source: CaptureSource) -> [NSScreen] {
        switch source {
        case .display(let display), .region(let display, _):
            if let screen = Self.screen(for: display) {
                return [screen]
            }
            return [NSScreen.main].compactMap { $0 }

        case .window(let window):
            let windowFrame = window.frame
            let match = NSScreen.screens.max { a, b in
                Self.intersectionArea(a.frame, windowFrame) <
                Self.intersectionArea(b.frame, windowFrame)
            }
            return [match ?? NSScreen.main].compactMap { $0 }
        }
    }

    private static func screen(for display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return n.uint32Value == display.displayID
        }
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        guard !r.isNull, !r.isEmpty else { return 0 }
        return r.width * r.height
    }
}
