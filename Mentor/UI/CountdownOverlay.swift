import AppKit

/// Fullscreen 3-2-1 countdown shown before recording starts.
@MainActor
final class CountdownOverlay {
    private var window: NSPanel?
    private var label: NSTextField?
    private var current: Int = 0
    private var onComplete: (() -> Void)?

    func show(seconds: Int, onComplete: @escaping () -> Void) {
        guard seconds > 0, let screen = NSScreen.main else {
            onComplete()
            return
        }
        self.onComplete = onComplete
        self.current = seconds

        let frame = screen.frame
        let win = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .screenSaver
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.hasShadow = false

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true

        let badgeSize: CGFloat = 360
        let badge = NSView(frame: NSRect(
            x: (frame.width - badgeSize) / 2,
            y: (frame.height - badgeSize) / 2,
            width: badgeSize,
            height: badgeSize
        ))
        badge.wantsLayer = true
        let badgeLayer = CALayer()
        badgeLayer.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        badgeLayer.cornerRadius = badgeSize / 2
        badge.layer = badgeLayer

        let lbl = NSTextField(labelWithString: "\(seconds)")
        lbl.font = .monospacedDigitSystemFont(ofSize: 220, weight: .bold)
        lbl.textColor = .white
        lbl.alignment = .center
        lbl.frame = NSRect(x: 0, y: (badgeSize - 240) / 2, width: badgeSize, height: 240)
        lbl.isBezeled = false
        lbl.drawsBackground = false
        badge.addSubview(lbl)

        container.addSubview(badge)
        win.contentView = container
        self.window = win
        self.label = lbl

        win.orderFront(nil)
        tick()
    }

    private func tick() {
        guard let label, current > 0 else {
            dismiss()
            return
        }
        label.stringValue = "\(current)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.current -= 1
            self?.tick()
        }
    }

    private func dismiss() {
        window?.orderOut(nil)
        window = nil
        label = nil
        let cb = onComplete
        onComplete = nil
        cb?()
    }
}
