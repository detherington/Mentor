import AppKit
import AVFoundation
import ApplicationServices
import Sparkle
import UniformTypeIdentifiers

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var coordinator: CaptureCoordinator!
    private var hotkey: GlobalHotkey!
    private var countdown: CountdownOverlay!
    private var sourcePicker: SourcePickerWindow!
    private var settingsController: SettingsWindowController!
    private var soundboardController: SoundboardController!
    private var soundboardWindow: SoundboardWindowController!
    /// Sparkle's all-in-one controller — drives both the update check
    /// scheduling and the user-facing update dialog. `startingUpdater: true`
    /// starts the background checker (respects `SUEnableAutomaticChecks`
    /// + `SUScheduledCheckInterval` from Info.plist).
    private var updater: SPUStandardUpdaterController!
    private var webcamPreview: WebcamPreviewWindow?
    private var editorWindows: [EditorWindowController] = []
    private var recordingBorder: RecordingBorderWindow?

    private var settingsObserver: NSObjectProtocol?
    private var lastKnownCameraDeviceID: String?
    private var lastKnownMicDeviceID: String?

    nonisolated static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            // LSUIElement apps don't get a main menu bar automatically,
            // which means ⌘Q, ⌘W, ⌘H, ⌘Cut/Copy/Paste, and the standard
            // About / Hide / Show All commands all have nothing to route
            // through when a window is key. Install a minimal standard
            // main menu so those work — the menu visually appears at the
            // top of the screen whenever any of our windows is focused.
            app.mainMenu = Self.buildMainMenu()
            app.run()
        }
    }

    /// Standard-shape main menu: App, Edit, Window. `Edit` deliberately
    /// omits Undo/Redo items — those are handled inside the editor view
    /// via `.onKeyPress` so they're scoped to the editor's UndoManager
    /// without fighting text-field native undo.
    @MainActor
    private static func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        // App menu — the title of the first item is ignored; the system
        // always displays the app's name.
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        appMenu.addItem(withTitle: "About Mentor",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Mentor",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Mentor",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // Edit menu — text-field clipboard actions via the responder
        // chain (NSText handles these natively for any focused NSTextView
        // / NSTextField, which is what SwiftUI TextFields wrap).
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")

        // Window menu — Close / Minimize. `NSApp.windowsMenu` lets
        // AppKit auto-populate it with the app's live window list.
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        return main
    }

    /// Returns another running Mentor instance (matched by bundle ID),
    /// or nil if we're the only one. Used to enforce a single menu-bar
    /// instance — running two at once leaves competing capture sessions
    /// + two indistinguishable status items.
    private static func otherMentorInstance() -> NSRunningApplication? {
        guard let myBundleID = Bundle.main.bundleIdentifier else { return nil }
        let me = NSRunningApplication.current.processIdentifier
        return NSWorkspace.shared.runningApplications.first { app in
            app.bundleIdentifier == myBundleID && app.processIdentifier != me
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bail if another Mentor is already running (e.g. you launched a
        // fresh build from Xcode while a previous one is still pinned to
        // the menu bar). Two menu bar items + two competing capture
        // sessions is always bad — and from the user's perspective they
        // want the new build, so we terminate ourselves only if our PID
        // is *newer* than the other's. The older instance keeps owning
        // the menu bar, but in practice the user spotted the duplicate
        // because they intend to kill the older one anyway, so we just
        // surface a console hint.
        if let other = Self.otherMentorInstance() {
            MentorDebug.log("APP: another Mentor instance is running (pid=\(other.processIdentifier)); quitting this one. Activate or quit the other from the menu bar.")
            // Bring the other instance forward so the user can see it
            // got the focus.
            other.activate(options: [])
            NSApp.terminate(nil)
            return
        }

        MentorDebug.reset()
        MentorDebug.log("APP: applicationDidFinishLaunching")
        coordinator = CaptureCoordinator()
        MentorDebug.log("APP: coordinator created")
        menuBar = MenuBarController()
        MentorDebug.log("APP: menuBar created")
        hotkey = GlobalHotkey()
        countdown = CountdownOverlay()
        sourcePicker = SourcePickerWindow()
        settingsController = SettingsWindowController()
        soundboardController = SoundboardController()
        soundboardWindow = SoundboardWindowController(controller: soundboardController)
        coordinator.soundboard = soundboardController
        updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        MentorDebug.log("APP: all controllers created (soundboard cues: \(soundboardController.cues.count))")

        menuBar.onChooseSourceAndRecord = { [weak self] in self?.chooseAndRecord() }
        menuBar.onStop                  = { [weak self] in self?.stopRecording() }
        menuBar.onRevealOutput          = { [weak self] in self?.revealOutput() }
        menuBar.onShowSettings          = { [weak self] in self?.settingsController.show() }
        menuBar.onShowSoundboard        = { [weak self] in self?.soundboardWindow.show() }
        menuBar.onCheckForUpdates       = { [weak self] in self?.updater.checkForUpdates(nil) }
        menuBar.onToggleWebcamPreview   = { [weak self] in self?.toggleWebcamPreview() }
        menuBar.onOpenRecording         = { [weak self] in self?.showOpenRecordingPanel() }
        menuBar.onEditLastRecording     = { [weak self] in self?.editLastRecording() }
        menuBar.onQuit                  = { NSApp.terminate(nil) }
        menuBar.micLevelProvider        = { [weak self] in self?.coordinator.micLevelNormalized() }

        hotkey.register(.recordToggle) { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }

        lastKnownCameraDeviceID = Settings.shared.cameraDeviceID
        lastKnownMicDeviceID = Settings.shared.microphoneDeviceID

        settingsObserver = NotificationCenter.default.addObserver(
            forName: Settings.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onSettingsChanged() }
        }

        Task { @MainActor in
            await self.startCameraSessionWithPermissions()
            self.refreshWebcamPreview()
            self.checkAccessibilityPermission()
        }
    }

    /// Trigger the Accessibility prompt if the user hasn't granted it yet.
    /// Needed so `NSEvent.addGlobalMonitorForEvents` actually receives mouse
    /// and key events outside Mentor — that's the backbone of the event log
    /// used by the editor's smart-zoom feature.
    private func checkAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let options: CFDictionary = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = settingsObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Permissions / camera bring-up

    private func startCameraSessionWithPermissions() async {
        let camOK = await ensure(.video)
        let micOK = await ensure(.audio)
        MentorDebug.log("APP: permissions cam=\(camOK) mic=\(micOK)")
        guard camOK, micOK else { return }
        do {
            try coordinator.startCameraSession()
            MentorDebug.log("APP: camera session started")
        } catch {
            MentorDebug.log("APP: camera setup failed: \(error.localizedDescription)")
            menuBar.flashError(message: "Camera setup failed: \(error.localizedDescription)")
        }
    }

    private func ensure(_ type: AVMediaType) async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: type)
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: type)
        }
        return status == .authorized
    }

    // MARK: - Recording flow

    private func toggleRecording() {
        if coordinator.isRecording {
            stopRecording()
        } else {
            chooseAndRecord()
        }
    }

    private func chooseAndRecord() {
        Task { @MainActor in
            await sourcePicker.show(
                onPicked: { [weak self] source in
                    Task { @MainActor in self?.proceedWithCountdown(source: source) }
                },
                onCancel: { }
            )
        }
    }

    private func proceedWithCountdown(source: CaptureSource) {
        let proceed: () -> Void = { [weak self] in
            Task { @MainActor in self?.startRecording(source: source) }
        }
        if Settings.shared.countdownEnabled {
            countdown.show(seconds: Settings.shared.countdownSeconds, onComplete: proceed)
        } else {
            proceed()
        }
    }

    private func startRecording(source: CaptureSource) {
        Task {
            do {
                _ = try await coordinator.startRecording(source: source)
                await MainActor.run {
                    self.menuBar.setRecording(true)
                    self.showRecordingBorder(for: source)
                }
            } catch {
                await MainActor.run {
                    self.menuBar.flashError(message: "\(error.localizedDescription)")
                }
            }
        }
    }

    private func showRecordingBorder(for source: CaptureSource) {
        if recordingBorder == nil {
            recordingBorder = RecordingBorderWindow()
        }
        recordingBorder?.show(for: source)
    }

    private func hideRecordingBorder() {
        recordingBorder?.hide()
    }

    private func stopRecording() {
        Task {
            let finished = await coordinator.stopRecording()
            await MainActor.run {
                self.menuBar.setRecording(false)
                self.hideRecordingBorder()
                guard let finished else { return }
                // Reveal the bundle immediately so the user sees where the
                // recording was saved — the composited MP4 will appear
                // alongside it when the post-capture render finishes.
                NSWorkspace.shared.activateFileViewerSelecting([finished.bundle.sidecarURL])
                self.menuBar.setFinalizing(true)
            }
            guard let finished else { return }
            // Render the composited MP4 post-capture. Running off the
            // MainActor so live UI stays responsive.
            do {
                let finalURL = try await FinalRenderer.renderUsingCaptureLayout(
                    bundle: finished.bundle,
                    metadata: finished.metadata
                )
                MentorDebug.log("APP: final render complete → \(finalURL.lastPathComponent)")
                await MainActor.run { self.menuBar.setFinalizing(false) }
            } catch {
                MentorDebug.log("APP: final render failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.menuBar.setFinalizing(false)
                    self.menuBar.flashError(
                        message: "Final MP4 render failed: \(error.localizedDescription). You can still open the .mentor bundle in the editor."
                    )
                }
            }
        }
    }

    // MARK: - Settings-change handling

    private func onSettingsChanged() {
        // Detect device-ID changes and re-swap the capture session inputs
        // live — otherwise Settings.didChange would only rebuild the
        // preview surface but leave the backing session running on the
        // old devices.
        let currentCamera = Settings.shared.cameraDeviceID
        let currentMic = Settings.shared.microphoneDeviceID
        if currentCamera != lastKnownCameraDeviceID || currentMic != lastKnownMicDeviceID {
            lastKnownCameraDeviceID = currentCamera
            lastKnownMicDeviceID = currentMic
            coordinator.reconfigureDevices()
        }
        refreshWebcamPreview()
    }

    // MARK: - Webcam preview

    private func toggleWebcamPreview() {
        Settings.shared.showWebcamPreview.toggle()
    }

    private func refreshWebcamPreview() {
        let shouldShow = Settings.shared.showWebcamPreview
            && Settings.shared.webcamPosition != .hidden
        if shouldShow {
            let sourceMin = coordinator.cameraCapture.sourceMinDimPixels
            if webcamPreview == nil {
                let preview = WebcamPreviewWindow(
                    diameter: Settings.shared.webcamDiameter,
                    shape: Settings.shared.webcamShape,
                    sourceMinDimPixels: sourceMin
                )
                preview.orderFront(nil)
                webcamPreview = preview
            } else {
                webcamPreview?.orderFront(nil)
            }
            webcamPreview?.apply(
                diameter: Settings.shared.webcamDiameter,
                shape: Settings.shared.webcamShape,
                sourceMinDimPixels: sourceMin
            )
            // Feed camera frames to the preview. Coordinator calls this on
            // the camera queue; WebcamPreviewWindow.update is thread-safe.
            if let preview = webcamPreview {
                MentorDebug.log("APP: setting cameraFrameObserver")
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

    // MARK: - Editor

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            openEditor(for: url)
        }
    }

    private func openEditor(for url: URL) {
        guard url.pathExtension == "mentor" else {
            menuBar.flashError(message: "\(url.lastPathComponent) isn't a Mentor recording bundle.")
            return
        }

        // If already open, bring that window to front instead of duplicating.
        if let existing = editorWindows.first(where: { $0.project.bundleURL == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        do {
            let project = try RecordingProject.load(bundleURL: url)
            // Editors are windowed — app needs to show in the Dock and
            // accept focus. Flip activation policy on first editor open.
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
            let controller = EditorWindowController(project: project)
            controller.onClose = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.editorWindows.removeAll { $0 === controller }
                // If no editors remain, go back to menu-bar-only mode.
                if self.editorWindows.isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            editorWindows.append(controller)
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            menuBar.flashError(
                message: "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private func showOpenRecordingPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = CaptureCoordinator.outputDirectory
        if let mentorType = UTType("com.darrell.mentor.recording") {
            panel.allowedContentTypes = [mentorType]
        }
        // Temporarily promote so the open panel gets focus; drop back when done
        // if we end up cancelling.
        let wasAccessory = NSApp.activationPolicy() != .regular
        if wasAccessory { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            openEditor(for: url)
        } else if wasAccessory, editorWindows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func editLastRecording() {
        guard let latest = latestRecordingBundle() else {
            menuBar.flashError(message: "No recordings found yet. Record something first.")
            return
        }
        openEditor(for: latest)
    }

    private func latestRecordingBundle() -> URL? {
        let dir = CaptureCoordinator.outputDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let bundles = contents.filter { $0.pathExtension == "mentor" }
        return bundles.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }.first
    }

    // MARK: - Misc

    private func revealOutput() {
        let dir = CaptureCoordinator.outputDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}
