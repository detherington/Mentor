import AppKit
import AVFoundation
import Sparkle

/// App entry point and wiring. The pieces live in their own types —
/// `RecordingFlowController` (picker → countdown → record → stop),
/// `EditorWindowManager`, `CaptureDeviceMonitor`, `OpenURLRouter`,
/// `MainMenu` — and this class connects them to the menu bar, global
/// shortcuts, Settings, the webcam preview and the teleprompter, and
/// handles quit.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var home: HomeWindowController!
    private var coordinator: CaptureCoordinator!
    private var recording: RecordingFlowController!
    private var editors: EditorWindowManager!
    private var devices: CaptureDeviceMonitor!
    private let urlRouter = OpenURLRouter()
    private var hotkey: GlobalHotkey!
    private var settingsController: SettingsWindowController!
    private var soundboardController: SoundboardController!
    private var soundboardWindow: SoundboardWindowController!
    /// Sparkle's all-in-one controller — drives both the update check
    /// scheduling and the user-facing update dialog. `startingUpdater: true`
    /// starts the background checker (respects `SUEnableAutomaticChecks`
    /// + `SUScheduledCheckInterval` from Info.plist).
    private var updater: SPUStandardUpdaterController!
    private var webcamPreview: WebcamPreviewWindow?
    private var teleprompterController: TeleprompterController?
    private var teleprompterWindow: TeleprompterWindow?
    private var settingsObserver: NSObjectProtocol?

    /// Preview-relevant settings as of the last preview refresh. Every
    /// Settings write posts `didChange` — the editor saves its last-used
    /// styles on each slider tick — and refreshing unconditionally
    /// re-fronted the preview window and logged a line per tick.
    private struct WebcamPreviewConfig: Equatable {
        let show: Bool
        let position: WebcamPosition
        let diameter: CGFloat
        let shape: WebcamShape

        @MainActor static var current: WebcamPreviewConfig {
            WebcamPreviewConfig(
                show: Settings.shared.showWebcamPreview,
                position: Settings.shared.webcamPosition,
                diameter: Settings.shared.webcamDiameter,
                shape: Settings.shared.webcamShape
            )
        }
    }
    private var lastWebcamPreviewConfig: WebcamPreviewConfig?

    /// True while the Settings shortcut recorder is listening — live
    /// bindings stay unregistered until it finishes.
    private var shortcutCaptureActive = false
    private var shortcutCaptureObservers: [NSObjectProtocol] = []
    /// Last-seen shortcut settings, so `onSettingsChanged` only re-registers
    /// (and reports conflicts) when a shortcut actually changed.
    private var lastShortcutSettings: [CueHotkey?] = []

    // Main-actor isolated via the class-level @MainActor. Swift 6.4
    // rejects a `nonisolated main()` on a @MainActor @main type, so the
    // old `MainActor.assumeIsolated` wrapper is gone.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // LSUIElement stays on so a hidden Dock icon never flashes at
        // launch; the policy is set here instead.
        DockPresence.apply()
        app.mainMenu = MainMenu.build()
        delegate.urlRouter.installAppleEventHandler()
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Render-and-quit review mode; runs before the single-instance
        // check so it works while another Pepper is open.
        if OnboardingWindowController.renderStepsIfRequested() { exit(0) }
        if EditorWindowController.renderIfRequested() { exit(0) }
        if VideoReadyNotice.renderIfRequested() { exit(0) }
        if HomeWindowController.renderIfRequested() { exit(0) }
        #endif
        // Drain any queued Apple Events (specifically `kAEOpenDocuments`)
        // before the duplicate-instance check. When Finder double-clicks a
        // .pepper file, macOS launches us with the file to open — but the
        // URL arrives via an Apple Event queued on the main runloop.
        // Without pumping it, the check below runs before the event is
        // dispatched and a duplicate would quit without forwarding the
        // file. A 50 ms pump is enough: events emitted at launch are
        // queued by now; if nothing's queued it returns immediately.
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        if urlRouter.deferToRunningInstance() { return }

        PepperDebug.reset()
        PepperDebug.log("APP: applicationDidFinishLaunching")
        coordinator = CaptureCoordinator()
        menuBar = MenuBarController()
        hotkey = GlobalHotkey()
        settingsController = SettingsWindowController()
        soundboardController = SoundboardController()
        soundboardWindow = SoundboardWindowController(controller: soundboardController)
        coordinator.soundboard = soundboardController
        updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        recording = RecordingFlowController(
            coordinator: coordinator,
            menuBar: menuBar,
            soundboard: soundboardController
        )
        recording.onStateChange = { [weak self] state in self?.recordingStateChanged(state) }
        recording.onRecordingStarted = { [weak self] in self?.attachTeleprompterMicTap() }
        recording.onRecordingWillStop = { [weak self] in self?.coordinator.micSampleSink = nil }
        recording.onRecordingSaved = { [weak self] bundle in self?.editors.open(bundle) }
        recording.onVideoRendered = { [weak self] video, bundle in
            guard let self else { return }
            // In the editor, Export is how to get the edited video; a
            // card about the as-recorded copy would muddle the two.
            guard !self.editors.isOpen(bundle) else { return }
            VideoReadyNotice.shared.show(video: video) { [weak self] in self?.editors.open(bundle) }
        }

        editors = EditorWindowManager(showError: { [weak self] in self?.menuBar.flashError(message: $0) })
        home = HomeWindowController(actions: .init(
            record: { [weak self] in self?.recording.start() },
            open: { [weak self] in self?.editors.open($0) },
            showOpenPanel: { [weak self] in self?.editors.showOpenPanel() },
            showSettings: { [weak self] in self?.settingsController.show() },
            revealRecordings: { [weak self] in self?.revealOutput() }
        ))

        devices = CaptureDeviceMonitor(coordinator: coordinator)
        devices.isRecordingInFlight = { [weak self] in (self?.recording.state ?? .idle) != .idle }
        devices.onSessionChanged = { [weak self] in self?.refreshWebcamPreview() }
        devices.onCameraLost = { [weak self] in self?.webcamPreview?.clear() }
        devices.showError = { [weak self] in self?.menuBar.flashError(message: $0) }
        PepperDebug.log("APP: all controllers created (soundboard cues: \(soundboardController.cues.count))")

        menuBar.onChooseSourceAndRecord = { [weak self] in self?.recording.start() }
        menuBar.onStop                  = { [weak self] in self?.recording.stop() }
        menuBar.onTogglePause           = { [weak self] in self?.recording.togglePause() }
        menuBar.onRevealOutput          = { [weak self] in self?.revealOutput() }
        menuBar.onShowSettings          = { [weak self] in self?.settingsController.show() }
        menuBar.onShowSoundboard        = { [weak self] in self?.soundboardWindow.show() }
        menuBar.onCheckForUpdates       = { [weak self] in
            // LSUIElement apps don't auto-activate when menu-bar actions
            // fire, so Sparkle's update panel opens behind whichever
            // window is frontmost. Activate so it lands on top.
            NSApp.activate(ignoringOtherApps: true)
            self?.updater.checkForUpdates(nil)
        }
        menuBar.onToggleWebcamPreview   = { [weak self] in self?.toggleWebcamPreview() }
        menuBar.onToggleTeleprompter    = { [weak self] in self?.toggleTeleprompter() }
        menuBar.onOpenRecording         = { [weak self] in self?.editors.showOpenPanel() }
        menuBar.onShowHome              = { [weak self] in self?.home.show() }
        menuBar.onEditLastRecording     = { [weak self] in self?.editors.openLatestRecording() }
        menuBar.onQuit                  = { NSApp.terminate(nil) }
        menuBar.micLevelProvider        = { [weak self] in self?.coordinator.micLevelNormalized() }

        shortcutCaptureObservers = [
            NotificationCenter.default.addObserver(
                forName: GlobalHotkey.captureWillBegin, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.shortcutCaptureActive = true
                    self?.hotkey.unregisterAll()
                }
            },
            NotificationCenter.default.addObserver(
                forName: GlobalHotkey.captureDidEnd, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.shortcutCaptureActive = false
                    self?.applyShortcuts(reportFailures: true)
                }
            },
        ]
        lastShortcutSettings = HotkeyBinding.allCases.map { Settings.shared.shortcut(for: $0) }
        applyShortcuts()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: Settings.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onSettingsChanged() }
        }

        devices.startMonitoring()
        devices.startSessionIfAuthorized()
        refreshWebcamPreview()
        refreshTeleprompter()
        // Setup asks for camera and mic from its buttons; bring the
        // session up as soon as either is granted.
        Permissions.shared.onCaptureAccessChanged = { [weak self] in
            self?.devices.startSessionIfAuthorized()
            self?.refreshWebcamPreview()
        }
        // The main window comes up at launch, after setup the first time.
        // With the Dock icon hidden, Pepper starts quietly in the menu bar.
        if !Settings.shared.hasCompletedOnboarding {
            OnboardingWindowController.shared.onClose = { [weak self] in
                OnboardingWindowController.shared.onClose = nil
                self?.home.show()
            }
            OnboardingWindowController.shared.show()
        } else if !Settings.shared.hideDockIcon {
            home.show()
        }

        // Ready: open anything Finder handed us during launch.
        urlRouter.open = { [weak self] url in self?.editors.open(url) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urlRouter.receive(urls)
    }

    /// Clicking the Dock icon (or opening Pepper again from Finder) with
    /// no window open shows the main window. The floating panels (webcam
    /// preview, teleprompter) don't count as open windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let hasWindow = sender.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
        // A minimised window: let AppKit bring it back.
        let hasMinimised = sender.windows.contains { $0.isMiniaturized }
        guard !hasWindow, !hasMinimised else { return true }
        home.show()
        return false
    }

    private func recordingStateChanged(_ state: RecordingFlowController.State) {
        home.recordingStateChanged(state)
        applyShortcuts()
        // Device changes are held off while a recording is in flight
        // (see `reconfigureDevices(keepConnectedDevices:)`); catch up
        // once idle.
        if state == .idle { devices.recordingEnded() }
    }

    // MARK: - Quit

    /// Quit (menu, ⌘Q, logout, Sparkle "Install and Relaunch") used to
    /// kill unfinished writers — losing a live recording outright, or
    /// leaving a truncated MP4 from an in-flight render. Now: stop and
    /// save a live recording first, and cancel renders/exports cleanly
    /// (the renderer deletes its partial output) before replying.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A duplicate instance quits before wiring anything up — there's
        // nothing to protect.
        guard let recording else { return .terminateNow }
        let exportingEditors = editors.exportingEditors

        switch recording.state {
        case .picking, .countingDown:
            recording.cancelPreRecording()
        case .starting:
            // Let the start settle, then retry the quit so it takes the
            // stop-and-save path below instead of racing the writers.
            Task { @MainActor in
                while recording.state == .starting {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                NSApp.terminate(nil)
            }
            return .terminateCancel
        case .idle, .recording, .stopping:
            break
        }

        if recording.state == .recording {
            guard confirmQuit(
                message: "Pepper is still recording.",
                info: "Stop and save the recording before quitting? The .pepper recording is kept; export the MP4 from the editor next time.",
                confirmTitle: "Stop & Quit"
            ) else { return .terminateCancel }
            let earlierRenders = recording.pendingFinalizeTasks
            earlierRenders.forEach { $0.cancel() }
            let stop = recording.stop(renderAfterStop: false)
            Task { @MainActor in
                await stop.value
                for render in earlierRenders { await render.value }
                for editor in exportingEditors {
                    await editor.viewModel.cancelActiveExportsAndWait()
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }

        let pending = recording.pendingFinalizeTasks
        guard !pending.isEmpty || !exportingEditors.isEmpty else { return .terminateNow }
        guard confirmQuit(
            message: "Pepper is still rendering.",
            info: "Quitting now cancels the render. Your .pepper recording is already saved and can be exported from the editor.",
            confirmTitle: "Quit Anyway"
        ) else { return .terminateCancel }
        pending.forEach { $0.cancel() }
        Task { @MainActor in
            for render in pending { await render.value }
            for editor in exportingEditors {
                await editor.viewModel.cancelActiveExportsAndWait()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func confirmQuit(message: String, info: String, confirmTitle: String) -> Bool {
        // LSUIElement: without activating first the alert opens behind
        // whatever app is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func applicationWillTerminate(_ notification: Notification) {
        editors?.flushPendingSaves()
        devices?.stopMonitoring()
        shortcutCaptureObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let obs = settingsObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Shortcuts

    /// Record is live whenever it's set; pause only while a recording is
    /// running. Both used to be registered for the app's whole life,
    /// swallowing ⌘⇧R / ⌘⇧P in every other app (browser hard-reload,
    /// editor command palettes).
    private func applyShortcuts(reportFailures: Bool = false) {
        guard !shortcutCaptureActive else { return }
        let record = Settings.shared.shortcut(for: .recordToggle)
        let pause = Settings.shared.shortcut(for: .pauseToggle)
        var failed: [String] = []
        if let record {
            let ok = hotkey.register(.recordToggle, combo: record) { [weak self] in
                Task { @MainActor in self?.recording.toggleRecording() }
            }
            if !ok { failed.append(record.displayString) }
        } else {
            hotkey.unregister(.recordToggle)
        }
        if recording.state == .recording, let pause {
            let ok = hotkey.register(.pauseToggle, combo: pause) { [weak self] in
                Task { @MainActor in self?.recording.togglePause() }
            }
            if !ok { failed.append(pause.displayString) }
        } else {
            hotkey.unregister(.pauseToggle)
        }
        menuBar.setShortcuts(record: record, pause: pause)
        if reportFailures, !failed.isEmpty {
            menuBar.flashError(
                title: "Shortcut unavailable",
                message: "\(failed.joined(separator: " and ")) is already taken by another app, so Pepper can't use it. Pick a different combo in Settings → Shortcuts."
            )
        }
    }

    // MARK: - Settings-change handling

    private func onSettingsChanged() {
        DockPresence.apply()
        let shortcuts = HotkeyBinding.allCases.map { Settings.shared.shortcut(for: $0) }
        if shortcuts != lastShortcutSettings {
            lastShortcutSettings = shortcuts
            applyShortcuts(reportFailures: true)
        }
        devices.settingsChanged()
        if WebcamPreviewConfig.current != lastWebcamPreviewConfig {
            refreshWebcamPreview()
        }
    }

    // MARK: - Teleprompter

    /// Flip the Teleprompter window's visibility. Stateless from the
    /// user's perspective — just "show/hide", with the state persisted
    /// in Settings so relaunches restore the last choice.
    private func toggleTeleprompter() {
        Settings.shared.teleprompterVisible.toggle()
        refreshTeleprompter()
    }

    /// Apply the current `Settings.teleprompterVisible` flag: open or
    /// close the window, wire the mic tap as appropriate. Called on
    /// toggle, on app launch, and whenever the recording state changes
    /// (so follow-voice gets mic input only while recording).
    private func refreshTeleprompter() {
        let shouldShow = Settings.shared.teleprompterVisible
        if shouldShow {
            if teleprompterController == nil {
                teleprompterController = TeleprompterController()
            }
            if teleprompterWindow == nil, let controller = teleprompterController {
                let window = TeleprompterWindow(controller: controller)
                teleprompterWindow = window
            }
            teleprompterWindow?.orderFront(nil)
            teleprompterController?.start()
        } else {
            teleprompterController?.stop()
            teleprompterWindow?.orderOut(nil)
            teleprompterWindow = nil
            teleprompterController = nil
        }
        menuBar.setTeleprompterShown(shouldShow)
        // Re-evaluate the mic tap — follow-voice only has meaningful
        // data while a recording's in progress, but we leave the
        // controller alive for the user to edit their script at any
        // time. Lifecycle of the actual mic-tap wiring is managed in
        // the recording start/stop hooks below.
    }

    /// When the teleprompter is visible AND a recording's in progress,
    /// pipe mic samples to its controller so follow-voice mode has an
    /// amplitude envelope to work with. Weak ref so detaching the sink
    /// doesn't leak if the controller outlives the recording.
    private func attachTeleprompterMicTap() {
        guard let controller = teleprompterController else {
            coordinator.micSampleSink = nil
            return
        }
        coordinator.micSampleSink = { [weak controller] sample in
            controller?.feedMicSample(sample)
        }
    }

    // MARK: - Webcam preview

    private func toggleWebcamPreview() {
        Settings.shared.showWebcamPreview.toggle()
    }

    private func refreshWebcamPreview() {
        lastWebcamPreviewConfig = .current
        let shouldShow = Settings.shared.showWebcamPreview
            && Settings.shared.webcamPosition != .hidden
        if shouldShow {
            if webcamPreview == nil {
                let preview = WebcamPreviewWindow(
                    diameter: Settings.shared.webcamDiameter,
                    shape: Settings.shared.webcamShape
                )
                preview.orderFront(nil)
                webcamPreview = preview
            } else {
                webcamPreview?.orderFront(nil)
            }
            webcamPreview?.apply(
                diameter: Settings.shared.webcamDiameter,
                shape: Settings.shared.webcamShape
            )
            // Feed camera frames to the preview. Coordinator calls this on
            // the camera queue; WebcamPreviewWindow.update is thread-safe.
            if let preview = webcamPreview {
                PepperDebug.log("APP: setting cameraFrameObserver")
                coordinator.cameraFrameObserver = { [weak preview] buffer in
                    preview?.update(with: buffer)
                }
            }
        } else {
            coordinator.cameraFrameObserver = nil
            webcamPreview?.orderOut(nil)
            webcamPreview = nil
        }
        menuBar.setWebcamPreviewShown(webcamPreview != nil)
    }

    // MARK: - Main menu actions

    @objc func showSettingsWindow(_ sender: Any?) { settingsController.show() }
    @objc func showOpenRecordingPanel(_ sender: Any?) { editors.showOpenPanel() }

    // Reached only when no editor is key (the key editor handles these
    // first): disable Undo and Redo and drop the last editor's action
    // name from their titles.
    @objc func undoEditorChange(_ sender: Any?) {}
    @objc func redoEditorChange(_ sender: Any?) {}

    // MARK: - Misc

    private func revealOutput() {
        let dir = CaptureCoordinator.outputDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undoEditorChange(_:)):
            item.title = "Undo"
            return false
        case #selector(redoEditorChange(_:)):
            item.title = "Redo"
            return false
        default:
            return true
        }
    }
}
