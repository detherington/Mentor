import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    // Callbacks
    var onChooseSourceAndRecord: () -> Void = {}
    var onStop: () -> Void = {}
    var onTogglePause: () -> Void = {}
    var onRevealOutput: () -> Void = {}
    var onShowSettings: () -> Void = {}
    var onShowSoundboard: () -> Void = {}
    var onToggleWebcamPreview: () -> Void = {}
    var onToggleTeleprompter: () -> Void = {}
    var onOpenRecording: () -> Void = {}
    var onEditLastRecording: () -> Void = {}
    var onCheckForUpdates: () -> Void = {}
    var onQuit: () -> Void = {}

    /// Returns mic level in 0...1 range, or nil if not available.
    var micLevelProvider: (() -> Float?)?

    private var startStopItem: NSMenuItem!
    private var pauseResumeItem: NSMenuItem!
    private var webcamPreviewItem: NSMenuItem!
    private var teleprompterItem: NSMenuItem!
    private var micLevelItem: NSMenuItem!
    private var micLevelView: MicLevelView!
    // Warning item — hidden unless `CaptureContention.detectedOffenders()`
    // returns a non-empty list when the menu opens. Kept as a persistent
    // NSMenuItem so we don't rebuild the menu on every open.
    private var contentionWarningItem: NSMenuItem!
    private var contentionSeparatorItem: NSMenuItem!
    private var detectedOffenders: [CaptureContention.KnownOffender] = []

    private var durationTimer: Timer?
    private var micPollTimer: Timer?
    private var recordingStart: Date?
    private var isFinalizing: Bool = false
    /// Wall-clock time the current pause started. Used by the
    /// duration ticker to subtract paused wall-clock out of the
    /// displayed "elapsed" number so it matches what the writers
    /// will bake into the final recording.
    private var pauseStart: Date?
    /// Cumulative paused wall-clock across the full recording —
    /// survives across pause/resume cycles, zeroed on stop.
    private var accumulatedPause: TimeInterval = 0
    private var isPaused: Bool = false

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configure()
    }

    private func configure() {
        statusItem.button?.image = recordIcon(recording: false, paused: false)
        statusItem.button?.imagePosition = .imageLeft

        startStopItem = NSMenuItem(
            title: "Start Recording…",
            action: #selector(handleStartStop(_:)),
            keyEquivalent: "r"
        )
        startStopItem.keyEquivalentModifierMask = [.command, .shift]
        startStopItem.target = self
        menu.addItem(startStopItem)

        // Pause / Resume — hidden until a recording is running, so
        // the idle menu stays tidy. ⌘⇧P toggles.
        pauseResumeItem = NSMenuItem(
            title: "Pause Recording",
            action: #selector(handleTogglePause(_:)),
            keyEquivalent: "p"
        )
        pauseResumeItem.keyEquivalentModifierMask = [.command, .shift]
        pauseResumeItem.target = self
        pauseResumeItem.isHidden = true
        menu.addItem(pauseResumeItem)

        // Contention warning — sits right under Start Recording so
        // users see it just as they're about to hit record. Both the
        // warning item and its separator are hidden by default and
        // toggled together by `menuWillOpen`.
        contentionWarningItem = NSMenuItem(
            title: "",  // filled in at open time
            action: #selector(handleContentionWarning(_:)),
            keyEquivalent: ""
        )
        contentionWarningItem.target = self
        contentionWarningItem.isHidden = true
        menu.addItem(contentionWarningItem)
        contentionSeparatorItem = .separator()
        contentionSeparatorItem.isHidden = true
        menu.addItem(contentionSeparatorItem)

        menu.addItem(.separator())

        // Mic level
        micLevelView = MicLevelView()
        micLevelItem = NSMenuItem()
        micLevelItem.view = micLevelView
        menu.addItem(micLevelItem)

        menu.addItem(.separator())

        webcamPreviewItem = NSMenuItem(
            title: "Show Webcam Preview",
            action: #selector(handleToggleWebcamPreview(_:)),
            keyEquivalent: ""
        )
        webcamPreviewItem.target = self
        menu.addItem(webcamPreviewItem)

        teleprompterItem = NSMenuItem(
            title: "Show Teleprompter",
            action: #selector(handleToggleTeleprompter(_:)),
            keyEquivalent: ""
        )
        teleprompterItem.target = self
        menu.addItem(teleprompterItem)

        let revealItem = NSMenuItem(
            title: "Reveal Recordings in Finder",
            action: #selector(handleReveal(_:)),
            keyEquivalent: ""
        )
        revealItem.target = self
        menu.addItem(revealItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "Open Recording…",
            action: #selector(handleOpenRecording(_:)),
            keyEquivalent: "o"
        )
        openItem.keyEquivalentModifierMask = [.command]
        openItem.target = self
        menu.addItem(openItem)

        let editLastItem = NSMenuItem(
            title: "Edit Last Recording",
            action: #selector(handleEditLast(_:)),
            keyEquivalent: "e"
        )
        editLastItem.keyEquivalentModifierMask = [.command, .shift]
        editLastItem.target = self
        menu.addItem(editLastItem)

        menu.addItem(.separator())

        let soundboardItem = NSMenuItem(
            title: "Soundboard…",
            action: #selector(handleSoundboard(_:)),
            keyEquivalent: ""
        )
        soundboardItem.target = self
        menu.addItem(soundboardItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(handleSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(handleCheckUpdates(_:)),
            keyEquivalent: ""
        )
        updatesItem.target = self
        menu.addItem(updatesItem)

        let quit = NSMenuItem(
            title: "Quit Mentor",
            action: #selector(handleQuit(_:)),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - State

    func setRecording(_ recording: Bool) {
        if recording {
            recordingStart = Date()
            accumulatedPause = 0
            pauseStart = nil
            isPaused = false
            startStopItem.title = "Stop Recording"
            pauseResumeItem.isHidden = false
            pauseResumeItem.title = "Pause Recording"
            updateButtonForRecording(recording: true, paused: false)
            startDurationTicker()
            applyHideIconIfNeeded(recording: true)
        } else {
            recordingStart = nil
            accumulatedPause = 0
            pauseStart = nil
            isPaused = false
            startStopItem.title = "Start Recording…"
            pauseResumeItem.isHidden = true
            pauseResumeItem.title = "Pause Recording"
            updateButtonForRecording(recording: false, paused: false)
            stopDurationTicker()
            applyHideIconIfNeeded(recording: false)
        }
    }

    /// Reflect pause state in the menu + icon. Caller passes `true`
    /// when coordinator.pauseRecording() has been invoked, `false` on
    /// resume. Keeps the elapsed-time ticker frozen during pause so
    /// the displayed duration matches what actually gets written.
    func setPaused(_ paused: Bool) {
        guard recordingStart != nil else { return }
        if paused, !isPaused {
            isPaused = true
            pauseStart = Date()
            pauseResumeItem.title = "Resume Recording"
            updateButtonForRecording(recording: true, paused: true)
        } else if !paused, isPaused {
            if let start = pauseStart {
                accumulatedPause += Date().timeIntervalSince(start)
            }
            pauseStart = nil
            isPaused = false
            pauseResumeItem.title = "Pause Recording"
            updateButtonForRecording(recording: true, paused: false)
        }
    }

    func setWebcamPreviewShown(_ shown: Bool) {
        webcamPreviewItem.title = shown ? "Hide Webcam Preview" : "Show Webcam Preview"
    }

    func setTeleprompterShown(_ shown: Bool) {
        teleprompterItem.title = shown ? "Hide Teleprompter" : "Show Teleprompter"
    }

    /// Toggle the "Finalizing…" indicator shown in the menu bar between
    /// recording stop and final-MP4 render completion.
    func setFinalizing(_ finalizing: Bool) {
        isFinalizing = finalizing
        if finalizing {
            // Subtle spinner icon + title; doesn't replace the normal icon
            // during active recording (this only runs post-stop).
            statusItem.button?.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "Finalizing"
            )
            statusItem.button?.contentTintColor = nil
            statusItem.button?.title = " Finalizing…"
        } else if recordingStart == nil {
            // Return to idle state.
            updateButtonForRecording(recording: false, paused: false)
        }
    }

    func flashError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Recording failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Menu callbacks

    @objc private func handleStartStop(_ sender: Any?) {
        if recordingStart != nil {
            onStop()
        } else {
            onChooseSourceAndRecord()
        }
    }
    @objc private func handleTogglePause(_ sender: Any?) { onTogglePause() }
    @objc private func handleReveal(_ sender: Any?) { onRevealOutput() }
    @objc private func handleSettings(_ sender: Any?) { onShowSettings() }
    @objc private func handleSoundboard(_ sender: Any?) { onShowSoundboard() }
    @objc private func handleCheckUpdates(_ sender: Any?) { onCheckForUpdates() }
    @objc private func handleToggleWebcamPreview(_ sender: Any?) { onToggleWebcamPreview() }
    @objc private func handleToggleTeleprompter(_ sender: Any?)  { onToggleTeleprompter() }
    @objc private func handleOpenRecording(_ sender: Any?) { onOpenRecording() }
    @objc private func handleEditLast(_ sender: Any?) { onEditLastRecording() }
    @objc private func handleQuit(_ sender: Any?) { onQuit() }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        startMicPolling()
        refreshContentionWarning()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopMicPolling()
    }

    /// Recheck which known always-on mic/camera apps are currently
    /// running and update the warning item's visibility + label. Called
    /// each time the user opens the menu so the check is always fresh
    /// without burning background cycles.
    private func refreshContentionWarning() {
        let offenders = CaptureContention.detectedOffenders()
        detectedOffenders = offenders
        if offenders.isEmpty {
            contentionWarningItem.isHidden = true
            contentionSeparatorItem.isHidden = true
            return
        }
        contentionWarningItem.isHidden = false
        contentionSeparatorItem.isHidden = false
        let count = offenders.count
        let suffix = count == 1 ? "app" : "apps"
        contentionWarningItem.title = "⚠︎ \(count) \(suffix) may cause capture lag — click to review"
    }

    @objc private func handleContentionWarning(_ sender: Any?) {
        guard !detectedOffenders.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Other apps may be using your mic or camera"
        // Two-paragraph explanation: what's happening, then why it
        // matters, then what to do. Keeps the window short but
        // answers "so what?" without needing a docs link.
        let intro = """
        These apps are currently running and are known to hold the \
        microphone or camera even when you're not actively using them. \
        When Mentor tries to capture, macOS's AV subsystem splits \
        priority between everyone — the result is stuttery webcam \
        preview, occasional audio crackle, or dropped frames in the \
        recording itself.

        Quitting the apps you don't need right now will give Mentor \
        exclusive access to the capture pipeline and smooth out the \
        recording. You can relaunch them after you're done.
        """
        let list = detectedOffenders
            .map { "  •  \($0.name) — holds \($0.holds)" }
            .joined(separator: "\n")
        alert.informativeText = "\(intro)\n\n\(list)"
        alert.addButton(withTitle: "Quit Those Apps…")
        alert.addButton(withTitle: "Ignore for Now")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        // Quit each offending process we can locate. `terminate()`
        // asks nicely; apps with unsaved work may prompt. That's fine
        // — the user just asked to quit them, so their save dialog
        // is the expected flow.
        let offenderBundleIDs = Set(
            CaptureContention.knownOffenders
                .filter { offender in
                    detectedOffenders.contains(where: { $0.name == offender.name })
                }
                .map(\.bundleID)
        )
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, offenderBundleIDs.contains(id) else { continue }
            app.terminate()
        }
    }

    // MARK: - Internals

    private func recordIcon(recording: Bool, paused: Bool) -> NSImage? {
        if paused {
            // Pause symbol (amber) so the menu bar clearly reads as
            // "recording, but on hold" rather than "recording live."
            let base = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "Mentor (paused)")
            if let base {
                let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
                return base.withSymbolConfiguration(config) ?? base
            }
            return base
        }
        let name = recording ? "record.circle.fill" : "record.circle"
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "Mentor")
        if recording, let base {
            // Bake red into a non-template variant so the title text is NOT
            // tinted (it should use the system menu-bar text color).
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            return base.withSymbolConfiguration(config) ?? base
        }
        // Not recording: leave as template image so it auto-adapts to light/dark
        // menu bar appearance.
        return base
    }

    private func updateButtonForRecording(recording: Bool, paused: Bool) {
        guard let button = statusItem.button else { return }
        button.image = recordIcon(recording: recording, paused: paused)
        button.contentTintColor = nil   // never override; title uses system text color
        button.title = recording ? " 00:00" : ""
    }

    private func startDurationTicker() {
        durationTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDuration() }
        }
        // .common so it fires even while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        durationTimer = timer
        refreshDuration()
    }

    private func stopDurationTicker() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func refreshDuration() {
        guard let start = recordingStart else { return }
        // Subtract any wall-clock time spent paused — both fully-
        // elapsed pauses (accumulatedPause) and the currently-live
        // pause, if any — so the displayed elapsed matches the
        // retimed video duration that will end up on disk.
        var paused = accumulatedPause
        if let pauseStart {
            paused += Date().timeIntervalSince(pauseStart)
        }
        let secs = max(0, Int(Date().timeIntervalSince(start) - paused))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        let title: String
        if h > 0 {
            title = String(format: " %d:%02d:%02d", h, m, s)
        } else {
            title = String(format: " %02d:%02d", m, s)
        }
        statusItem.button?.title = title
    }

    private func startMicPolling() {
        micPollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let level = self.micLevelProvider?() ?? 0
                self.micLevelView.setLevel(level)
            }
        }
        // .common so the timer fires while the menu is open (menu tracking
        // suspends the .default runloop mode).
        RunLoop.main.add(timer, forMode: .common)
        micPollTimer = timer
    }

    private func stopMicPolling() {
        micPollTimer?.invalidate()
        micPollTimer = nil
    }

    private func applyHideIconIfNeeded(recording: Bool) {
        if recording && Settings.shared.hideMenuBarIconWhenRecording {
            statusItem.isVisible = false
        } else {
            statusItem.isVisible = true
        }
    }
}

// MARK: - Mic level view

private final class MicLevelView: NSView {
    private let levelIndicator: NSLevelIndicator

    init() {
        levelIndicator = NSLevelIndicator(frame: .zero)
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 28))

        let label = NSTextField(labelWithString: "Mic")
        label.font = .menuFont(ofSize: NSFont.systemFontSize(for: .small))
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        levelIndicator.levelIndicatorStyle = .continuousCapacity
        levelIndicator.minValue = 0
        levelIndicator.maxValue = 100
        levelIndicator.warningValue = 75
        levelIndicator.criticalValue = 95
        levelIndicator.doubleValue = 0
        levelIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(levelIndicator)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            levelIndicator.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            levelIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            levelIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            levelIndicator.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setLevel(_ level: Float) {
        levelIndicator.doubleValue = Double(max(0, min(1, level))) * 100
    }
}
