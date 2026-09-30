import AppKit

/// Fullscreen 3-2-1 countdown shown before recording starts.
/// Optional per-tick beep and "Go!" flash, both opt-in via Settings.
@MainActor
final class CountdownOverlay {
    private var window: NSPanel?
    private var label: NSTextField?
    private var current: Int = 0
    private var onComplete: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var beepEnabled: Bool = false
    private var showGo: Bool = false
    /// Bumped on cancel so already-scheduled ticks from the cancelled
    /// run become no-ops instead of completing it.
    private var generation = 0
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    func show(
        seconds: Int,
        on targetScreen: NSScreen? = nil,
        onComplete: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        guard seconds > 0, let screen = targetScreen ?? NSScreen.main else {
            onComplete()
            return
        }
        self.onComplete = onComplete
        self.onCancel = onCancel
        generation &+= 1
        // Esc aborts. The panel is non-activating, so the user's app still
        // has focus — the global monitor catches Esc there, the local one
        // when Mentor is frontmost.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancel()
            return nil
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.cancel() }
        }
        self.current = seconds
        // Snapshot Settings once — users changing these mid-countdown
        // would be weird and the read-on-every-tick is free to skip.
        self.beepEnabled = Settings.shared.countdownBeepEnabled
        self.showGo = Settings.shared.countdownShowGo

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
        // `.fullScreenAuxiliary` lets the panel stay visible when the
        // target screen has an app running in full-screen Space, which
        // is a common "I'm about to record this" scenario. Matches the
        // recording-border configuration.
        win.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary
        ]
        win.hasShadow = false
        // On multi-display setups the `contentRect:` passed to `init` is
        // sometimes adjusted away from the target screen's global
        // origin (AppKit treats it as a "suggestion"). Force the frame
        // back to `screen.frame` before ordering front so the panel
        // lands on the display the user's actually recording.
        win.setFrame(frame, display: false)

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

        // `orderFrontRegardless` (vs `orderFront`) matters on non-main
        // displays: when the LSUIElement app isn't frontmost, plain
        // `orderFront` can silently no-op on other screens.
        win.orderFrontRegardless()
        // First tick fires synchronously so the user sees the starting
        // number + hears the first beep immediately — waiting a full
        // second before "3" would make the feature feel sluggish.
        if beepEnabled { playTickSound(highPitch: false) }
        tick()
    }

    private func tick() {
        guard let label, current > 0 else {
            // Countdown hit zero. If "Go!" is enabled, flash it for
            // ~300ms with the higher-pitched beep; otherwise dismiss
            // immediately so the recording starts right on cue.
            if showGo {
                flashGo()
            } else {
                dismiss()
            }
            return
        }
        label.stringValue = "\(current)"
        let run = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.generation == run else { return }
            self.current -= 1
            if self.current > 0 {
                if self.beepEnabled { self.playTickSound(highPitch: false) }
            }
            self.tick()
        }
    }

    private func flashGo() {
        guard let label else { dismiss(); return }
        label.font = .systemFont(ofSize: 160, weight: .heavy)
        label.stringValue = "Go!"
        if beepEnabled { playTickSound(highPitch: true) }
        // Short hold — long enough to register, short enough not to
        // delay the recording. 300 ms matches typical "screen flash"
        // cues in other capture apps.
        let run = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.generation == run else { return }
            self.dismiss()
        }
    }

    /// Abort without starting the recording (Esc, or the record
    /// shortcut pressed again). No-op when no countdown is showing.
    func cancel() {
        guard window != nil else { return }
        generation &+= 1
        let cb = onCancel
        teardown()
        cb?()
    }

    private func dismiss() {
        let cb = onComplete
        teardown()
        cb?()
    }

    private func teardown() {
        window?.orderOut(nil)
        window = nil
        label = nil
        onComplete = nil
        onCancel = nil
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        localKeyMonitor = nil
        globalKeyMonitor = nil
    }

    /// Play a short system tick/chime. `highPitch` lifts the final
    /// "Go!" cue above the regular ticks so the user's ear marks it
    /// as the start. Uses NSSound so there's no latency priming an
    /// AVAudioEngine for a single shot.
    private func playTickSound(highPitch: Bool) {
        // `Tink` is the short, light system tick — feels right for a
        // countdown. `Ping` is slightly higher + brighter for the Go!
        // moment. Both ship with every macOS install.
        let name = highPitch ? NSSound.Name("Ping") : NSSound.Name("Tink")
        NSSound(named: name)?.play()
    }
}
