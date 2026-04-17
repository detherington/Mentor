import AppKit
import Foundation

/// Owns the persisted list of `SoundCue`s, the `SoundboardEngine`, and
/// the global hotkey monitors. One instance per app lifetime, created
/// by `AppDelegate`.
///
/// The controller's lifecycle:
///
///   * `init`: load persisted cues from Settings. Don't start the engine
///     yet — many users won't touch the soundboard at all, and the
///     engine allocates audio hardware.
///   * First cue added OR first recording: `start()` → engine running,
///     hotkey monitors installed.
///   * `startRecordingTap(outputURL:)` / `stopRecordingTap()`: bridge
///     capture lifecycle so the mixer's output lands in
///     `soundboard.m4a` inside the sidecar bundle.
///   * App quit: no explicit teardown needed; macOS reclaims the engine.
@MainActor
@Observable
final class SoundboardController {
    private(set) var cues: [SoundCue]
    private let engine = SoundboardEngine()

    /// When non-nil, the *next* modifier-key combo the user presses will
    /// be stored as the hotkey for this cue (instead of firing any
    /// existing binding). The UI uses this to drive its "Click to set…"
    /// / "Press keys…" cell state.
    private(set) var capturingHotkeyForCueID: UUID?

    /// Cues whose Soundboard-window "test" button is currently playing
    /// them. The button renders as stop when its cue is in this set, so
    /// a second tap becomes a cancel rather than another overlapping
    /// playback. Separate from hotkey-triggered playback, which is
    /// allowed to overlap freely (rapid-fire stings are a feature).
    private(set) var testPlayingCueIDs: Set<UUID> = []

    // Retained monitor handles so we can remove them when cues change.
    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private var localMonitor: Any?

    /// Handle for each cue's active *test* playback. Used to cancel
    /// when the user re-taps the button. Hotkey-triggered plays never
    /// populate this map.
    @ObservationIgnored private var testHandles: [UUID: SoundboardEngine.PlayerHandle] = [:]

    // Recording-time event log state.
    @ObservationIgnored private var recordingActive = false
    @ObservationIgnored private var recordingStartDate = Date()
    @ObservationIgnored private var recordingStartUptime: TimeInterval = 0
    @ObservationIgnored private var recordedCueFires: [SoundboardEventLog.Fired] = []
    @ObservationIgnored private var pendingEventLogURL: URL?

    init() {
        self.cues = Settings.shared.soundboardCues
        ensureEngineRunning()
    }

    // MARK: - Cue management

    func addCue(_ cue: SoundCue) {
        cues.append(cue)
        persist()
        ensureEngineRunning()
    }

    func updateCue(_ cue: SoundCue) {
        guard let idx = cues.firstIndex(where: { $0.id == cue.id }) else { return }
        cues[idx] = cue
        persist()
    }

    func removeCue(id: UUID) {
        cues.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        Settings.shared.soundboardCues = cues
    }

    // MARK: - Engine + monitor lifecycle

    /// Start the engine and install hotkey monitors if there's at least
    /// one cue. Idempotent.
    private func ensureEngineRunning() {
        guard !cues.isEmpty else { return }
        do {
            try engine.start()
        } catch {
            MentorDebug.log("SOUNDBOARD: engine start failed: \(error)")
            return
        }
        installMonitorsIfNeeded()
    }

    private func installMonitorsIfNeeded() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return }
                Task { @MainActor in self.handle(event) }
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let handled = self.handle(event)
                return handled ? nil : event
            }
        }
    }

    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        // Capture mode wins over everything. If ESC, cancel. If the event
        // carries a valid hotkey (has modifiers), store it; otherwise we
        // swallow the keystroke so it doesn't trigger a different cue or
        // leak into the focused app unexpectedly.
        if let captureID = capturingHotkeyForCueID {
            if event.keyCode == 0x35 /* esc */ {
                capturingHotkeyForCueID = nil
                return true
            }
            if let hotkey = CueHotkey(capturing: event),
               var cue = cues.first(where: { $0.id == captureID }) {
                cue.hotkey = hotkey
                updateCue(cue)
                capturingHotkeyForCueID = nil
            }
            // Consume — don't want the pressed keys to also play another
            // cue or leak into a focused app.
            return true
        }

        for cue in cues {
            if let hotkey = cue.hotkey, hotkey.matches(event: event) {
                engine.play(cue: cue)
                // Log the fire if we're mid-recording — gives the editor
                // timeline accurate cue markers without having to
                // retroactively infer them from audio bursts.
                if recordingActive {
                    let t = ProcessInfo.processInfo.systemUptime - recordingStartUptime
                    if t >= 0 {
                        recordedCueFires.append(SoundboardEventLog.Fired(
                            t: t, cueID: cue.id, cueName: cue.name
                        ))
                    }
                }
                return true
            }
        }
        return false
    }

    // MARK: - Hotkey-capture control

    func beginCapturingHotkey(for cueID: UUID) {
        capturingHotkeyForCueID = cueID
        // Ensure our monitors are live — even with zero cues we need the
        // capture monitor active or the UI would hang on "Press keys…".
        installMonitorsIfNeeded()
    }

    func cancelCapturingHotkey() {
        capturingHotkeyForCueID = nil
    }

    /// Clear the hotkey binding from a cue (but keep the cue itself).
    func clearHotkey(for cueID: UUID) {
        guard var cue = cues.first(where: { $0.id == cueID }) else { return }
        cue.hotkey = nil
        updateCue(cue)
    }

    // MARK: - Test / preview playback

    /// Toggle preview playback of `cue` for the Soundboard window's
    /// test button:
    ///
    ///   * If the cue is already test-playing → stop it.
    ///   * Otherwise → start a fresh test playback, track the handle so
    ///     a second tap becomes "stop", and auto-clear when the file
    ///     finishes naturally.
    ///
    /// Starts the engine on first use so cues can be previewed before
    /// the first recording.
    func testPlay(cue: SoundCue) {
        // Already test-playing this cue? Second tap is a stop.
        if let handle = testHandles[cue.id] {
            engine.stop(handle: handle)
            // State-cleanup happens in the play completion handler below
            // (stop() triggers the same completion path), so we don't
            // double-remove from the map here.
            return
        }

        if !engine.isRunning {
            do { try engine.start() } catch {
                MentorDebug.log("SOUNDBOARD: engine start (test) failed: \(error)")
                return
            }
            installMonitorsIfNeeded()
        }

        let cueID = cue.id
        let handle = engine.play(cue: cue) { [weak self] in
            guard let self else { return }
            self.testHandles.removeValue(forKey: cueID)
            self.testPlayingCueIDs.remove(cueID)
        }
        guard let handle else { return }
        testHandles[cueID] = handle
        testPlayingCueIDs.insert(cueID)
    }

    // MARK: - Recording integration

    /// Begin writing the engine's mixer output to `outputURL`. No-op if
    /// there are no configured cues (in that case we also won't create
    /// the file, and `EditorComposition` will skip the missing track).
    /// `eventLogURL` is where the cue-fire log will be written at stop.
    func startRecordingTap(outputURL: URL, eventLogURL: URL? = nil) {
        guard !cues.isEmpty else { return }
        do {
            try engine.startRecordingTap(outputURL: outputURL)
            engine.speakerOutputMuted = Settings.shared.soundboardMuteSpeakersDuringRecording
        } catch {
            MentorDebug.log("SOUNDBOARD: recording tap start failed: \(error)")
            return
        }
        // Start the cue-fire log clock.
        recordingStartDate = Date()
        recordingStartUptime = ProcessInfo.processInfo.systemUptime
        recordedCueFires.removeAll(keepingCapacity: true)
        pendingEventLogURL = eventLogURL
        recordingActive = true
    }

    func stopRecordingTap() async {
        recordingActive = false
        engine.speakerOutputMuted = false

        // Flush the cue-fire log before awaiting the transcode (the bundle
        // is considered complete only after both land).
        if let url = pendingEventLogURL, !recordedCueFires.isEmpty {
            let log = SoundboardEventLog(
                version: 1,
                startDate: recordingStartDate,
                events: recordedCueFires
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(log)
                try data.write(to: url, options: .atomic)
            } catch {
                MentorDebug.log("SOUNDBOARD: cue-event log write failed: \(error)")
            }
        }
        recordedCueFires.removeAll(keepingCapacity: false)
        pendingEventLogURL = nil

        await engine.stopRecordingTap()
    }
}
