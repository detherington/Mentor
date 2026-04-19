import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    // Callbacks
    var onChooseSourceAndRecord: () -> Void = {}
    var onStop: () -> Void = {}
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
    private var webcamPreviewItem: NSMenuItem!
    private var teleprompterItem: NSMenuItem!
    private var micLevelItem: NSMenuItem!
    private var micLevelView: MicLevelView!

    private var durationTimer: Timer?
    private var micPollTimer: Timer?
    private var recordingStart: Date?
    private var isFinalizing: Bool = false

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configure()
    }

    private func configure() {
        statusItem.button?.image = recordIcon(recording: false)
        statusItem.button?.imagePosition = .imageLeft

        startStopItem = NSMenuItem(
            title: "Start Recording…",
            action: #selector(handleStartStop(_:)),
            keyEquivalent: "r"
        )
        startStopItem.keyEquivalentModifierMask = [.command, .shift]
        startStopItem.target = self
        menu.addItem(startStopItem)

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
            startStopItem.title = "Stop Recording"
            updateButtonForRecording(true)
            startDurationTicker()
            applyHideIconIfNeeded(recording: true)
        } else {
            recordingStart = nil
            startStopItem.title = "Start Recording…"
            updateButtonForRecording(false)
            stopDurationTicker()
            applyHideIconIfNeeded(recording: false)
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
            updateButtonForRecording(false)
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
    }

    func menuDidClose(_ menu: NSMenu) {
        stopMicPolling()
    }

    // MARK: - Internals

    private func recordIcon(recording: Bool) -> NSImage? {
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

    private func updateButtonForRecording(_ recording: Bool) {
        guard let button = statusItem.button else { return }
        button.image = recordIcon(recording: recording)
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
        let secs = Int(Date().timeIntervalSince(start))
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
