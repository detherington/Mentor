import AppKit
import AVFoundation

/// The start → record → stop flow: source picker, countdown, starting
/// capture, pause / resume, stopping, and the post-recording render —
/// plus what to do when capture is interrupted.
@MainActor
final class RecordingFlowController {
    /// Where the flow is. This used to be implied by
    /// `coordinator.isRecording` alone, which is false while picking,
    /// counting down and starting — so the record shortcut during any of
    /// those opened a second picker and orphaned the first.
    enum State {
        case idle, picking, countingDown, starting, recording, stopping
    }

    private(set) var state: State = .idle {
        didSet { if oldValue != state { onStateChange?(state) } }
    }

    var onStateChange: ((State) -> Void)?
    /// The app wires the teleprompter's follow-voice mic tap to these.
    var onRecordingStarted: (() -> Void)?
    var onRecordingWillStop: (() -> Void)?

    private let coordinator: CaptureCoordinator
    private let menuBar: MenuBarController
    private let soundboard: SoundboardController
    private let sourcePicker = SourcePickerWindow()
    private let countdown = CountdownOverlay()
    private var recordingBorder: RecordingBorderWindow?

    /// In-flight stop → finalize writers → auto-render pipelines, keyed
    /// so each removes only itself (a second recording can stop while
    /// the first is still rendering). Held so quit can wait on them, or
    /// cancel their renders, instead of killing writers mid-flight.
    private var finalizeTasks: [UUID: Task<Void, Never>] = [:]

    /// Asked once per launch — see `confirmMissingCaptureAccess`.
    private var captureAccessWarningShown = false

    init(coordinator: CaptureCoordinator, menuBar: MenuBarController, soundboard: SoundboardController) {
        self.coordinator = coordinator
        self.menuBar = menuBar
        self.soundboard = soundboard
        coordinator.onInterruption = { [weak self] reason in
            Task { @MainActor in self?.handleInterruption(reason) }
        }
    }

    /// Stop / render pipelines still running.
    var pendingFinalizeTasks: [Task<Void, Never>] {
        Array(finalizeTasks.values)
    }

    /// Close the source picker or countdown, if either is up (quit).
    func cancelPreRecording() {
        switch state {
        case .picking:      sourcePicker.dismiss()
        case .countingDown: countdown.cancel()
        default:            break
        }
    }

    /// The record shortcut / menu item. Pressing it again while picking
    /// or counting down cancels; mid-transition presses are ignored
    /// rather than racing the start or stop in flight.
    func toggleRecording() {
        switch state {
        case .idle:              start()
        case .picking:           sourcePicker.dismiss()
        case .countingDown:      countdown.cancel()
        case .recording:         stop()
        case .starting, .stopping: break
        }
    }

    /// Flip the paused state. No-ops when there's no recording in
    /// flight — the menu item is hidden in that case, and the pause
    /// shortcut is only registered while recording, but guard anyway.
    func togglePause() {
        guard state == .recording else { return }
        let pausing = !coordinator.isPaused
        if pausing {
            coordinator.pauseRecording()
        } else {
            coordinator.resumeRecording()
        }
        menuBar.setPaused(pausing)
        soundboard.setRecordingPaused(
            pausing,
            cumulativeOffsetSeconds: coordinator.cumulativePauseOffsetSeconds
        )
    }

    /// Menu "Start Recording…": pick a source, count down, record.
    func start() {
        guard state == .idle else { return }
        guard confirmMissingCaptureAccess() else { return }
        state = .picking
        let picker = sourcePicker
        let onPicked: (CaptureSource) -> Void = { [weak self] source in
            Task { @MainActor in self?.proceedWithCountdown(source: source) }
        }
        let onCancel: () -> Void = { [weak self] in
            Task { @MainActor in
                if self?.state == .picking { self?.state = .idle }
            }
        }
        Task { @MainActor in
            await picker.show(onPicked: onPicked, onCancel: onCancel)
        }
    }

    /// Camera and mic are set up independently, so a denied one just
    /// drops out of the recording. Say so before the first recording of
    /// the session rather than letting the user find a silent or
    /// webcam-less take afterwards. Returns false if they cancelled.
    private func confirmMissingCaptureAccess() -> Bool {
        guard !captureAccessWarningShown else { return true }
        let denied: (AVMediaType) -> Bool = { type in
            let status = AVCaptureDevice.authorizationStatus(for: type)
            return status == .denied || status == .restricted
        }
        let micDenied = denied(.audio)
        let camDenied = denied(.video)
        guard micDenied || camDenied else { return true }
        captureAccessWarningShown = true

        let missing = [camDenied ? "camera" : nil, micDenied ? "microphone" : nil]
            .compactMap { $0 }
            .joined(separator: " or ")
        let consequence = micDenied && camDenied
            ? "This recording will have no webcam and no narration."
            : micDenied
                ? "This recording will have no narration."
                : "This recording will have no webcam."
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Pepper can't use your \(missing)"
        alert.informativeText = "\(consequence) Allow access in System Settings → Privacy & Security, then relaunch Pepper."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Record Anyway")
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            let pane = micDenied ? "Privacy_Microphone" : "Privacy_Camera"
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
            return false
        default:
            return false
        }
    }

    private func proceedWithCountdown(source: CaptureSource) {
        guard state == .picking else { return }
        let proceed: () -> Void = { [weak self] in
            Task { @MainActor in self?.startRecording(source: source) }
        }
        if Settings.shared.countdownEnabled {
            state = .countingDown
            countdown.show(
                seconds: Settings.shared.countdownSeconds,
                on: source.targetScreen(),
                onComplete: proceed,
                onCancel: { [weak self] in
                    if self?.state == .countingDown { self?.state = .idle }
                }
            )
        } else {
            proceed()
        }
    }

    private func startRecording(source: CaptureSource) {
        guard state == .picking || state == .countingDown else { return }
        state = .starting
        Task { @MainActor in
            do {
                try await coordinator.startRecording(source: source)
                self.state = .recording
                self.menuBar.setRecording(true)
                self.showRecordingBorder(for: source)
                self.onRecordingStarted?()
            } catch {
                self.state = .idle
                self.menuBar.flashError(message: "\(error.localizedDescription)")
            }
        }
    }

    /// The recording can't continue (see `CaptureCoordinator.Interruption`).
    /// Stop it the normal way so everything captured so far is finalised
    /// and rendered, then say why.
    private func handleInterruption(_ reason: CaptureCoordinator.Interruption) {
        guard state == .recording else { return }
        stop()
        let message: String
        switch reason {
        case .screenCaptureStopped(let error):
            message = "Screen capture ended unexpectedly (\(error.localizedDescription)). This happens when the display is disconnected, the recorded window closes, or sharing is stopped from the menu bar. Everything up to that point was saved."
        case .writeFailed(let track, let error):
            message = "Pepper couldn't keep writing the \(track) track (\(error?.localizedDescription ?? "unknown error")). The disk may be full. The recording was stopped; tracks still writing were saved. Free up space before recording again."
        }
        menuBar.flashError(title: "Recording stopped", message: message)
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

    /// `renderAfterStop: false` is the quit path — finalize the writers
    /// so the .pepper bundle is complete, but skip the multi-minute
    /// auto-render.
    @discardableResult
    func stop(renderAfterStop: Bool = true) -> Task<Void, Never> {
        guard state == .recording else { return Task {} }
        state = .stopping
        onRecordingWillStop?()
        let id = UUID()
        let task = Task { @MainActor in
            defer { self.finalizeTasks[id] = nil }
            let finished = await coordinator.stopRecording()
            self.state = .idle
            self.menuBar.setRecording(false)
            self.hideRecordingBorder()
            guard let finished else { return }
            // Reveal the bundle immediately so the user sees where the
            // recording was saved — the composited MP4 will appear
            // alongside it when the post-capture render finishes.
            NSWorkspace.shared.activateFileViewerSelecting([finished.bundle.sidecarURL])
            guard renderAfterStop, !Task.isCancelled else { return }
            self.menuBar.setFinalizing(true)
            // Render the composited MP4 post-capture. The heavy lifting
            // runs on the renderer's own queues, so awaiting it here
            // doesn't block the main actor.
            do {
                let finalURL = try await FinalRenderer.renderUsingCaptureLayout(
                    bundle: finished.bundle,
                    metadata: finished.metadata
                )
                PepperDebug.log("APP: final render complete → \(finalURL.lastPathComponent)")
                self.menuBar.setFinalizing(false)
            } catch FinalRenderer.RenderError.cancelled {
                // Quit cancelled it — no alert; the bundle is intact.
                PepperDebug.log("APP: final render cancelled")
                self.menuBar.setFinalizing(false)
            } catch {
                PepperDebug.log("APP: final render failed: \(error.localizedDescription)")
                self.menuBar.setFinalizing(false)
                self.menuBar.flashError(
                    message: "Final MP4 render failed: \(error.localizedDescription). You can still open the .pepper bundle in the editor."
                )
            }
        }
        // Safe ordering: the task is main-actor bound, so it can't run
        // (or remove itself) until this function returns.
        finalizeTasks[id] = task
        return task
    }
}
