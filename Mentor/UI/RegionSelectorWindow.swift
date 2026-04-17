import AppKit

/// Fullscreen drag-to-select region overlay. ESC, right-click, or 30s timeout cancels.
@MainActor
final class RegionSelectorWindow {
    private var window: FocusableRegionPanel?
    private var trackingView: RegionTrackingView?
    private var screen: NSScreen?
    private var onPicked: ((CGRect) -> Void)?
    private var onCancel: (() -> Void)?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var failsafeTimer: Timer?

    func show(onPicked: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        guard let screen = NSScreen.main else { onCancel(); return }
        self.screen = screen
        self.onPicked = onPicked
        self.onCancel = onCancel

        let win = FocusableRegionPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.acceptsMouseMovedEvents = true
        win.hasShadow = false

        let view = RegionTrackingView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onCommit = { [weak self] rect in self?.complete(rect: rect) }
        view.onCancel = { [weak self] in self?.cancel() }
        win.contentView = view
        self.window = win
        self.trackingView = view

        // Multiple ESC/cancel paths for safety:
        // 1. View's keyDown override (works because panel is key)
        // 2. Local monitor (in case view isn't first responder)
        // 3. Global monitor (in case app loses focus somehow)
        // 4. 30-second failsafe timeout
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
        }

        failsafeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
    }

    private func complete(rect: CGRect) {
        // rect is in screen-local coords with origin at bottom-left.
        // ScreenCaptureKit's SCStreamConfiguration.sourceRect uses the same convention
        // (display points, bottom-left origin), so we can pass it through.
        teardown()
        onPicked?(rect)
        onPicked = nil
        onCancel = nil
    }

    private func cancel() {
        teardown()
        let cb = onCancel
        onPicked = nil
        onCancel = nil
        cb?()
    }

    private func teardown() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        localKeyMonitor = nil
        globalKeyMonitor = nil
        failsafeTimer?.invalidate()
        failsafeTimer = nil
        window?.orderOut(nil)
        window = nil
        trackingView = nil
    }
}

/// NSPanel that can become key (so view receives keyDown events).
private final class FocusableRegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RegionTrackingView: NSView {
    var onCommit: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startPoint = p
        currentRect = NSRect(origin: p, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(start.x, p.x),
            y: min(start.y, p.y),
            width: abs(p.x - start.x),
            height: abs(p.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if currentRect.width >= 20 && currentRect.height >= 20 {
            onCommit?(currentRect)
        } else {
            onCancel?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // ESC
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()

        if currentRect.isEmpty {
            bounds.fill()
            drawHint()
            return
        }

        // Dim around the selection — 4 strips
        NSRect(x: 0, y: currentRect.maxY,
               width: bounds.width, height: bounds.height - currentRect.maxY).fill()
        NSRect(x: 0, y: 0,
               width: bounds.width, height: currentRect.minY).fill()
        NSRect(x: 0, y: currentRect.minY,
               width: currentRect.minX, height: currentRect.height).fill()
        NSRect(x: currentRect.maxX, y: currentRect.minY,
               width: bounds.width - currentRect.maxX, height: currentRect.height).fill()

        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: currentRect)
        path.lineWidth = 2
        path.stroke()

        let dim = "\(Int(currentRect.width)) × \(Int(currentRect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6)
        ]
        let str = NSAttributedString(string: " \(dim) ", attributes: attrs)
        let strSize = str.size()
        str.draw(at: NSPoint(
            x: currentRect.minX,
            y: currentRect.maxY + 6
        ).clamped(to: bounds, padding: strSize))
    }

    private func drawHint() {
        let hint = "Click and drag to select a region. Press Esc to cancel."
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: hint, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        ))
    }
}

private extension NSPoint {
    func clamped(to bounds: NSRect, padding: NSSize) -> NSPoint {
        let x = min(max(bounds.minX, self.x), bounds.maxX - padding.width)
        let y = min(max(bounds.minY, self.y), bounds.maxY - padding.height)
        return NSPoint(x: x, y: y)
    }
}
