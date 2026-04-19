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
    private var teleprompterController: TeleprompterController?
    private var teleprompterWindow: TeleprompterWindow?

    private var settingsObserver: NSObjectProtocol?
    private var lastKnownCameraDeviceID: String?
    private var lastKnownMicDeviceID: String?

    /// URLs received via `application(_:open:)` during launch — before
    /// the other controllers are wired up. Drained either after
    /// `applicationDidFinishLaunching` finishes wiring (normal case) or
    /// forwarded to an already-running instance before we self-terminate
    /// (duplicate case).
    private var pendingOpenURLs: [URL] = []

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

            // Install a raw `kAEOpenDocuments` handler in addition to
            // `application(_:open:)`. On LSUIElement apps the high-level
            // delegate method sometimes doesn't fire before the runloop
            // reaches `applicationDidFinishLaunching` — but the raw
            // Apple Event is delivered synchronously whenever it's
            // dispatched, giving us a reliable channel that populates
            // `pendingOpenURLs` in time for the duplicate check.
            NSAppleEventManager.shared().setEventHandler(
                delegate,
                andSelector: #selector(handleOpenDocumentsEvent(_:withReplyEvent:)),
                forEventClass: AEEventClass(kCoreEventClass),
                andEventID: AEEventID(kAEOpenDocuments)
            )

            app.run()
        }
    }

    /// Low-level handler for the `kAEOpenDocuments` Apple Event. Parses
    /// the `keyDirectObject` as a list of alias / URL descriptors and
    /// feeds them through the same `pendingOpenURLs` buffer that the
    /// higher-level `application(_:open:)` uses. Either path is
    /// sufficient — they cross-populate into the same buffer.
    @MainActor
    @objc
    func handleOpenDocumentsEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let listDescriptor = event.paramDescriptor(forKeyword: keyDirectObject) else {
            return
        }
        var urls: [URL] = []
        for i in 1...max(listDescriptor.numberOfItems, 0) {
            guard let item = listDescriptor.atIndex(i) else { continue }
            // URL-shaped descriptors come in as `typeFileURL`; older
            // senders may use `typeAlias`. Try both.
            if let urlString = item.stringValue, let url = URL(string: urlString) {
                urls.append(url)
                continue
            }
            if let data = item.coerce(toDescriptorType: typeFileURL)?.data,
               let s = String(data: data, encoding: .utf8),
               let url = URL(string: s) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        MentorDebug.log("APP: handleOpenDocumentsEvent captured \(urls.count) URL(s); menuBar=\(menuBar == nil ? "nil" : "ready")")
        if menuBar == nil {
            pendingOpenURLs.append(contentsOf: urls)
        } else {
            for url in urls { openEditor(for: url) }
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
        // Drain any queued Apple Events (specifically `kAEOpenDocuments`)
        // before running the duplicate-instance check. When Finder
        // double-clicks a .mentor file, macOS launches us with the file
        // to open — but the open URL is delivered via an Apple Event
        // that's queued on the main runloop. Without pumping the
        // runloop, `applicationDidFinishLaunching` executes before the
        // Apple Event gets dispatched to `application(_:open:)`, so
        // `pendingOpenURLs` is empty when we reach the duplicate check
        // below and we terminate without ever forwarding the URL.
        //
        // A 50ms pump is enough: Apple Events emitted at launch are
        // in-queue by the time we get here, so they dispatch on the
        // first runloop iteration. If nothing's queued we return
        // immediately.
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))

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
            MentorDebug.log("APP: another Mentor instance is running (pid=\(other.processIdentifier)); forwarding \(pendingOpenURLs.count) pending URLs + quitting.")
            // Forward any .mentor URLs that Finder handed us on launch
            // so the already-running instance opens them — otherwise a
            // double-click would spawn us, we'd terminate as a duplicate,
            // and nothing would end up opening.
            if !pendingOpenURLs.isEmpty, let bundleURL = other.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                config.addsToRecentItems = false
                for url in pendingOpenURLs {
                    NSWorkspace.shared.open(
                        [url],
                        withApplicationAt: bundleURL,
                        configuration: config,
                        completionHandler: nil
                    )
                }
                pendingOpenURLs.removeAll()
            } else {
                // No URLs to forward — just bring the other instance
                // forward so the user sees which one remains.
                other.activate(options: [])
            }
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
        menuBar.onToggleTeleprompter    = { [weak self] in self?.toggleTeleprompter() }
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
            self.refreshTeleprompter()
            self.checkAccessibilityPermission()
        }

        // Drain any URLs that `application(_:open:)` buffered during
        // launch (i.e. the user double-clicked a .mentor and Finder
        // handed us the file before our controllers existed).
        if !pendingOpenURLs.isEmpty {
            MentorDebug.log("APP: draining \(pendingOpenURLs.count) pending open URL(s)")
            let urls = pendingOpenURLs
            pendingOpenURLs.removeAll()
            for url in urls {
                openEditor(for: url)
            }
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
                    self.attachTeleprompterMicTap()
                }
            } catch {
                await MainActor.run {
                    self.menuBar.flashError(message: "\(error.localizedDescription)")
                }
            }
        }
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

    private func detachTeleprompterMicTap() {
        coordinator.micSampleSink = nil
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
        detachTeleprompterMicTap()
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
        MentorDebug.log("APP: application(_:open:) fired with \(urls.count) URL(s); menuBar=\(menuBar == nil ? "nil" : "ready")")
        // This callback fires during launch — specifically BEFORE
        // `applicationDidFinishLaunching` completes — when the user
        // double-clicks a .mentor file in Finder and we're not yet
        // running. At that point `menuBar`/`coordinator`/`editorWindows`
        // are all nil, so calling `openEditor` now would crash.
        //
        // If we're not wired up yet, buffer the URLs and drain them
        // after `applicationDidFinishLaunching` decides whether to keep
        // running (normal case) or self-terminate + forward to the
        // pre-existing instance (duplicate case).
        if menuBar == nil {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
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
