import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

/// Orchestrates the live capture pipeline. Under Option A (post-capture
/// render), the coordinator only writes the raw `.pepper` sidecar during
/// recording — composited MP4 production is deferred to `FinalRenderer`
/// so the media engine never has to run three concurrent encoder sessions.
///
/// Live outputs (into the sidecar):
///   • screen.mov   — raw H.264 screen capture, full 60fps
///   • webcam.mov   — raw H.264 webcam, 30fps native
///   • mic.m4a      — mic audio, AAC
///   • system.m4a   — system audio, AAC (optional)
///   • events.json  — user event log (clicks, keystrokes, app focus)
///   • metadata.json — source info + webcam layout at capture time
final class CaptureCoordinator: @unchecked Sendable {
    /// Public so preview windows can attach.
    let cameraCapture = CameraCapture()

    /// Optional live-soundboard hook. Set by `AppDelegate` at launch —
    /// when set, the coordinator starts/stops its recording tap in
    /// sync with the main capture session.
    var soundboard: SoundboardController?

    /// Optional mic-sample sink. When non-nil, every mic sample buffer
    /// is tee'd to this closure in addition to the mic writer. Used by
    /// the teleprompter's follow-voice mode to compute a live amplitude
    /// envelope without duplicating the capture pipeline. Set + unset
    /// by `AppDelegate` around the lifecycle of whoever needs it;
    /// closure runs on the mic capture queue and MUST NOT block.
    private let micTapLock = NSLock()
    private var _micSampleSink: ((CMSampleBuffer) -> Void)?
    var micSampleSink: ((CMSampleBuffer) -> Void)? {
        get { micTapLock.lock(); defer { micTapLock.unlock() }; return _micSampleSink }
        set { micTapLock.lock(); _micSampleSink = newValue; micTapLock.unlock() }
    }

    private let screenCapture = ScreenCapture()

    private let stateLock = NSLock()
    private var _isRecording = false
    /// Set for the duration of `startRecording`. `_isRecording` only flips
    /// at the very end, so without this a second start (double-pressed
    /// shortcut) replaced the first's writers and left its stream running.
    private var _isStarting = false
    private var _interruptionReported = false

    /// Why a recording ended on its own.
    enum Interruption {
        /// SCStream stopped — display unplugged, captured window closed,
        /// or sharing stopped from the system's menu-bar indicator.
        case screenCaptureStopped(Error)
        /// A track writer's append failed — usually a full disk.
        case writeFailed(track: String, Error?)
    }

    /// Delivered at most once per recording, on the main queue. Set by
    /// `AppDelegate`, which stops the recording (keeping what was
    /// captured) and tells the user. Previously both cases were only
    /// logged: the app sat in "recording" while nothing was being
    /// written, and the loss surfaced at render time, if at all.
    var onInterruption: ((Interruption) -> Void)?

    var isRecording: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isRecording
    }

    /// Pause state + the recording's time origin. See `PauseClock`.
    private let clock = PauseClock()

    var isPaused: Bool { clock.isPaused }

    /// Total paused duration so far. Callers read this to keep
    /// subsidiary loggers' offsets in sync.
    var cumulativePauseOffsetSeconds: TimeInterval { clock.cumulativeOffsetSeconds }

    /// The recording in progress. Installed, rolled back and torn down as
    /// one value under `pipelineLock`; the capture callbacks snapshot the
    /// writer they need and release the lock before writing.
    private let pipelineLock = NSLock()
    private var session: RecordingSession?

    // Drop telemetry — tracks how many screen-delegate callbacks fired
    // and how often the raw writer was nil at that moment (i.e. samples
    // arrived before startRecording finished wiring up, or after
    // stopRecording tore down). Printed on stop.
    private let coordStatsLock = NSLock()
    private var screenDelegateCalls: Int = 0
    private var screenDelegateWithNilWriter: Int = 0
    private var cameraDelegateCalls: Int = 0
    private var cameraDelegateWithNilWriter: Int = 0

    /// Called on the camera queue on every camera frame.
    private let observerLock = NSLock()
    private var _cameraFrameObserver: ((CVPixelBuffer) -> Void)?
    var cameraFrameObserver: ((CVPixelBuffer) -> Void)? {
        get { observerLock.lock(); defer { observerLock.unlock() }; return _cameraFrameObserver }
        set { observerLock.lock(); _cameraFrameObserver = newValue; observerLock.unlock() }
    }

    static var outputDirectory: URL {
        let movies = (try? FileManager.default.url(
            for: .moviesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("Pepper", isDirectory: true)
    }

    /// Start the camera+mic session for live preview. Idempotent.
    func startCameraSession() throws {
        try cameraCapture.configure()
        cameraCapture.delegate = self
        cameraCapture.startRunning()
    }

    func stopCameraSession() {
        cameraCapture.stopRunning()
    }

    /// Swap the live capture session's camera + mic inputs to whatever the
    /// user picked in Settings. Safe to call while preview is running; see
    /// `CameraCapture.reconfigureDevices(keepConnectedDevices:)`.
    func reconfigureDevices(keepConnectedDevices: Bool = false) {
        cameraCapture.reconfigureDevices(keepConnectedDevices: keepConnectedDevices)
    }

    /// Stopping a recording hands back the finished bundle; callers
    /// typically kick off `FinalRenderer` at this point.
    struct FinishedRecording {
        let bundle: RecordingBundle
        let metadata: RecordingMetadata
    }

    func startRecording(source: CaptureSource) async throws {
        stateLock.lock()
        guard !_isRecording, !_isStarting else {
            stateLock.unlock()
            throw CaptureError.alreadyRecording
        }
        _isStarting = true
        _interruptionReported = false
        stateLock.unlock()
        defer {
            stateLock.lock()
            _isStarting = false
            stateLock.unlock()
        }

        let (outputSize, scale, displayFrame, primaryHeight): (CGSize, CGFloat, CGRect?, CGFloat?) = try await MainActor.run {
            guard let size = source.outputPixelSize() else {
                throw CaptureError.writerSetupFailed("source has no capturable area")
            }
            // Snapshot the screen layout for the editor's click mapping.
            let frame: CGRect? = {
                switch source {
                case .display, .region: return source.targetScreen()?.frame
                case .window:           return nil
                }
            }()
            return (size, source.backingScale(), frame, NSScreen.screens.first?.frame.height)
        }
        PepperDebug.log("COORD: startRecording source=\(source.displayName) outputSize=\(Int(outputSize.width))x\(Int(outputSize.height)) scale=\(scale)")
        let dir = Self.outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundle = RecordingBundle.make(baseDirectory: dir)
        try bundle.createSidecarDirectory()

        clock.reset()

        let captureSysAudio = Settings.shared.captureSystemAudio

        // Raw video writers — High-profile H.264, no frame reordering, hints for 60fps
        // screen / 30fps webcam so the media engine can plan rate control.
        let screenRaw = try TrackWriter.video(
            outputURL: bundle.screenVideoURL,
            pixelSize: outputSize,
            averageBitrate: 8_000_000,
            expectedFrameRate: 60,
            holdsLastFrame: true,
            onFailure: writeFailureHandler(track: "screen")
        )
        // Each writer only spins up when the session actually has that
        // input. Creating one with no input produces an empty MOV/M4A
        // that AVFoundation later refuses to open, so skip it and let the
        // editor/renderer treat the track as absent. (The mic writer used
        // to key off `isConfigured`, which a camera-only session also
        // satisfies.)
        let webcamRaw: TrackWriter? = cameraCapture.hasVideoInput
            ? try TrackWriter.video(
                outputURL: bundle.webcamVideoURL,
                pixelSize: cameraCapture.sourcePixelSize,
                averageBitrate: 4_000_000,
                expectedFrameRate: 30,
                onFailure: writeFailureHandler(track: "webcam")
            )
            : nil

        let micWriter: TrackWriter? = cameraCapture.hasAudioInput
            ? try TrackWriter.audio(
                outputURL: bundle.micAudioURL,
                channels: 1,
                bitrate: 128_000,
                onFailure: writeFailureHandler(track: "microphone")
            )
            : nil
        let systemWriter: TrackWriter? = captureSysAudio
            ? try TrackWriter.audio(
                outputURL: bundle.systemAudioURL,
                channels: 2,
                bitrate: 192_000,
                onFailure: writeFailureHandler(track: "system audio")
            )
            : nil

        let eventRec = EventRecorder()
        eventRec.start()

        // Cursor position sampler — separate from the event recorder
        // because it runs a timer instead of an event monitor and has
        // no Accessibility dependency. Feeds the editor's cursor-
        // highlight halo; older recordings without this sidecar just
        // get no halo (graceful degradation).
        let cursorSamp = CursorSampler()
        cursorSamp.start()

        let metadata = RecordingMetadata(
            version: 1,
            startDate: Date(),
            source: Self.metadataSourceInfo(for: source, displayFrame: displayFrame, primaryScreenHeight: primaryHeight),
            screenPixelSize: RecordingMetadata.CGSizeCodable(outputSize),
            webcamPixelSize: RecordingMetadata.CGSizeCodable(cameraCapture.sourcePixelSize),
            compositedPixelSize: RecordingMetadata.CGSizeCodable(outputSize),
            webcamLayout: RecordingMetadata.WebcamLayoutInfo(
                position: Settings.shared.webcamPosition.rawValue,
                shape: Settings.shared.webcamShape.rawValue,
                diameterPoints: Double(Settings.shared.webcamDiameter),
                insetPoints: Double(Settings.shared.webcamInset)
            ),
            hasSystemAudio: captureSysAudio,
            backingScale: Double(scale)
        )

        let newSession = RecordingSession(
            bundle: bundle,
            metadata: metadata,
            screen: screenRaw,
            webcam: webcamRaw,
            mic: micWriter,
            systemAudio: systemWriter,
            events: eventRec,
            cursor: cursorSamp
        )
        pipelineLock.lock()
        self.session = newSession
        pipelineLock.unlock()

        // Hook the live soundboard into this recording. Safe to call
        // even with no cues — the controller no-ops when empty and we
        // never create the soundboard.m4a file.
        if let soundboard {
            await soundboard.startRecordingTap(
                outputURL: bundle.soundboardAudioURL,
                eventLogURL: bundle.soundboardEventsURL
            )
        }

        screenCapture.delegate = self
        do {
            try await screenCapture.start(source: source, captureSystemAudio: captureSysAudio)
        } catch {
            // Roll back everything on failure
            pipelineLock.lock()
            self.session = nil
            pipelineLock.unlock()
            await newSession.finishWriters(endTime: nil)
            _ = eventRec.stop()
            _ = cursorSamp.stop()
            if let soundboard {
                await soundboard.stopRecordingTap()
            }
            try? FileManager.default.removeItem(at: bundle.sidecarURL)
            throw error
        }

        stateLock.lock()
        _isRecording = true
        stateLock.unlock()
    }

    /// Stop capture, flush all sidecar writers, write events + metadata.
    /// Caller is responsible for kicking off `FinalRenderer` on the bundle.
    /// Pause the current recording. Samples captured while paused are
    /// dropped at the coordinator delegate; on resume, subsequent
    /// samples are retimed by the accumulated paused duration so the
    /// output tracks read as continuous with no freeze-frame gap.
    /// Subsidiary loggers (events, cursor) are also paused and given
    /// the same cumulative offset on resume so their timestamps stay
    /// aligned with the retimed A/V. No-ops if not recording or
    /// already paused.
    func pauseRecording() {
        stateLock.lock()
        let active = _isRecording
        stateLock.unlock()
        guard active else { return }

        guard clock.pause() else { return }

        pipelineLock.lock()
        let current = self.session
        pipelineLock.unlock()
        current?.events.setPaused(true)
        current?.cursor.setPaused(true)
        PepperDebug.log("COORD: recording paused")
    }

    /// Resume from pause. Computes this pause interval, folds it
    /// into the cumulative offset, then flips subsidiary loggers
    /// back on with the fresh offset value. No-ops if not recording
    /// or not currently paused.
    func resumeRecording() {
        stateLock.lock()
        let active = _isRecording
        stateLock.unlock()
        guard active else { return }

        guard let offsetSeconds = clock.resume() else { return }

        pipelineLock.lock()
        let current = self.session
        pipelineLock.unlock()
        current?.events.setPaused(false, cumulativeOffsetSeconds: offsetSeconds)
        current?.cursor.setPaused(false, cumulativeOffsetSeconds: offsetSeconds)
        PepperDebug.log("COORD: recording resumed (cumulative pause offset: \(String(format: "%.2fs", offsetSeconds)))")
    }

    func stopRecording() async -> FinishedRecording? {
        stateLock.lock()
        guard _isRecording else { stateLock.unlock(); return nil }
        _isRecording = false
        stateLock.unlock()

        // Each writer ends its session at the shared end of the timeline
        // so all tracks are the same length (the screen writer re-stamps
        // its last frame to reach it). Pause state is left alone — see
        // `PauseClock.stopPoint()`.
        let (origin, endTime) = clock.stopPoint()
        // Loggers run on systemUptime, which shares the host clock's base.
        let originUptime: TimeInterval? = origin.isValid ? CMTimeGetSeconds(origin) : nil

        await screenCapture.stop()

        coordStatsLock.lock()
        let stats = (screenDelegateCalls, screenDelegateWithNilWriter,
                     cameraDelegateCalls, cameraDelegateWithNilWriter)
        screenDelegateCalls = 0
        screenDelegateWithNilWriter = 0
        cameraDelegateCalls = 0
        cameraDelegateWithNilWriter = 0
        coordStatsLock.unlock()
        PepperDebug.log("COORD delegates: screen=\(stats.0) (nilWriter=\(stats.1)) camera=\(stats.2) (nilWriter=\(stats.3))")

        // Close the soundboard tap *before* we tear down the rest —
        // stopping synchronises with the engine so by the time the
        // below writers finish, soundboard.m4a is fully flushed.
        if let soundboard {
            await soundboard.stopRecordingTap(timeOriginUptime: originUptime)
        }

        pipelineLock.lock()
        let finished = self.session
        self.session = nil
        pipelineLock.unlock()
        guard let finished else { return nil }

        await finished.finishWriters(endTime: endTime)

        // Flush event log + metadata.
        let bundle = finished.bundle
        if let log = finished.events.stop(rebasedToUptime: originUptime) {
            persistJSON(log, to: bundle.eventsURL)
        }
        if let cursorLog = finished.cursor.stop(rebasedToUptime: originUptime) {
            persistJSON(cursorLog, to: bundle.cursorLogURL)
        }
        persistJSON(finished.metadata, to: bundle.metadataURL)
        return FinishedRecording(bundle: bundle, metadata: finished.metadata)
    }

    private func writeFailureHandler(track: String) -> @Sendable (Error?) -> Void {
        { [weak self] error in
            self?.reportInterruption(.writeFailed(track: track, error))
        }
    }

    /// Hand an interruption to `onInterruption` once per recording, and
    /// only while actually recording (our own stop tears the stream down
    /// without an error, and a start that fails throws instead).
    private func reportInterruption(_ reason: Interruption) {
        stateLock.lock()
        guard _isRecording, !_interruptionReported else {
            stateLock.unlock()
            return
        }
        _interruptionReported = true
        stateLock.unlock()
        PepperDebug.log("COORD: recording interrupted: \(reason)")
        DispatchQueue.main.async { [weak self] in
            self?.onInterruption?(reason)
        }
    }

    /// Mic level normalized to 0...1.
    func micLevelNormalized() -> Float? {
        cameraCapture.currentMicLevel()
    }

    private func persistJSON<T: Encodable>(_ value: T, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            PepperDebug.log("COORD: failed to write \(url.lastPathComponent): \(error)")
        }
    }

    private static func metadataSourceInfo(
        for source: CaptureSource,
        displayFrame: CGRect?,
        primaryScreenHeight: CGFloat?
    ) -> RecordingMetadata.SourceInfo {
        let dfx = displayFrame.map { Double($0.origin.x) }
        let dfy = displayFrame.map { Double($0.origin.y) }
        let dfw = displayFrame.map { Double($0.width) }
        let dfh = displayFrame.map { Double($0.height) }
        let ph = primaryScreenHeight.map { Double($0) }
        switch source {
        case .display(let d):
            return .init(
                kind: "display",
                displayID: d.displayID,
                windowID: nil,
                windowTitle: nil,
                appBundleID: nil,
                regionX: nil, regionY: nil, regionWidth: nil, regionHeight: nil,
                windowFrameX: nil, windowFrameY: nil,
                windowFrameWidth: nil, windowFrameHeight: nil,
                displayFrameX: dfx, displayFrameY: dfy,
                displayFrameWidth: dfw, displayFrameHeight: dfh,
                primaryScreenHeight: ph
            )
        case .window(let w):
            // SCWindow.frame is in Quartz screen points (origin top-left of
            // primary display). Used by smart-zoom to map global clicks
            // into window-image pixels.
            let f = w.frame
            return .init(
                kind: "window",
                displayID: nil,
                windowID: w.windowID,
                windowTitle: w.title,
                appBundleID: w.owningApplication?.bundleIdentifier,
                regionX: nil, regionY: nil, regionWidth: nil, regionHeight: nil,
                windowFrameX: Double(f.origin.x),
                windowFrameY: Double(f.origin.y),
                windowFrameWidth: Double(f.width),
                windowFrameHeight: Double(f.height),
                displayFrameX: nil, displayFrameY: nil,
                displayFrameWidth: nil, displayFrameHeight: nil,
                primaryScreenHeight: ph
            )
        case .region(let d, let rect):
            return .init(
                kind: "region",
                displayID: d.displayID,
                windowID: nil,
                windowTitle: nil,
                appBundleID: nil,
                regionX: Double(rect.origin.x),
                regionY: Double(rect.origin.y),
                regionWidth: Double(rect.width),
                regionHeight: Double(rect.height),
                windowFrameX: nil, windowFrameY: nil,
                windowFrameWidth: nil, windowFrameHeight: nil,
                displayFrameX: dfx, displayFrameY: dfy,
                displayFrameWidth: dfw, displayFrameHeight: dfh,
                primaryScreenHeight: ph
            )
        }
    }
}

extension CaptureCoordinator: ScreenCaptureDelegate {
    func screenCapture(_ capture: ScreenCapture, didOutputVideo sample: CMSampleBuffer) {
        pipelineLock.lock()
        let screenRaw = self.session?.screen
        pipelineLock.unlock()
        coordStatsLock.lock()
        screenDelegateCalls &+= 1
        if screenRaw == nil { screenDelegateWithNilWriter &+= 1 }
        coordStatsLock.unlock()
        let (drop, offset, origin) = clock.sampleState(
            establishingOriginAt: CMSampleBufferGetPresentationTimeStamp(sample)
        )
        if drop { return }
        // `retimed` returns self for a zero offset; nil means the copy
        // failed — drop rather than write an un-retimed sample that
        // would land behind already-written ones.
        guard let adjusted = sample.retimed(by: offset) else { return }
        // Only the raw track is written live — composited output is
        // rebuilt post-capture by FinalRenderer.
        screenRaw?.append(adjusted, sessionStart: origin)
    }

    func screenCapture(_ capture: ScreenCapture, didOutputAudio sample: CMSampleBuffer) {
        pipelineLock.lock()
        let sysWriter = self.session?.systemAudio
        pipelineLock.unlock()
        let (drop, offset, origin) = clock.sampleState()
        if drop { return }
        guard let adjusted = sample.retimed(by: offset) else { return }
        sysWriter?.append(adjusted, sessionStart: origin)
    }

    func screenCapture(_ capture: ScreenCapture, didFailWith error: Error) {
        PepperDebug.log("COORD: screen capture stopped: \(error)")
        reportInterruption(.screenCaptureStopped(error))
    }
}

extension CaptureCoordinator: CameraCaptureDelegate {
    func cameraCapture(_ capture: CameraCapture, didOutputVideo sample: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        pipelineLock.lock()
        let webcamRaw = self.session?.webcam
        pipelineLock.unlock()
        coordStatsLock.lock()
        cameraDelegateCalls &+= 1
        if webcamRaw == nil { cameraDelegateWithNilWriter &+= 1 }
        coordStatsLock.unlock()

        // The preview always sees the latest frame, even during
        // pause — freezing the webcam preview mid-pause would be
        // disorienting. Only the recording writer is gated by the
        // pause state.
        observerLock.lock()
        let observer = _cameraFrameObserver
        observerLock.unlock()
        observer?(imageBuffer)

        let (drop, offset, origin) = clock.sampleState()
        if drop { return }
        guard let adjusted = sample.retimed(by: offset) else { return }
        webcamRaw?.append(adjusted, sessionStart: origin)
    }

    func cameraCapture(_ capture: CameraCapture, didOutputAudio sample: CMSampleBuffer) {
        pipelineLock.lock()
        let micWriter = self.session?.mic
        pipelineLock.unlock()
        let (drop, offset, origin) = clock.sampleState()
        if drop {
            // Mic tap still sees samples while paused (or before the
            // time origin exists) — teleprompter follow-voice + any other
            // live listener shouldn't go silent just because the writer
            // is on hold.
            micTapLock.lock()
            let sink = _micSampleSink
            micTapLock.unlock()
            sink?(sample)
            return
        }
        if let adjusted = sample.retimed(by: offset) {
            micWriter?.append(adjusted, sessionStart: origin)
        }

        // Tee to any attached live-amplitude sink (e.g. the
        // teleprompter's follow-voice mode). Read the closure
        // reference under lock so AppDelegate can swap it safely
        // from the main actor; invoke outside the lock so a slow
        // consumer can't stall mic delivery.
        micTapLock.lock()
        let sink = _micSampleSink
        micTapLock.unlock()
        sink?(sample)
    }
}

/// Everything one recording writes to, installed and torn down as a unit
/// — start, rollback and stop each swap one value instead of eight
/// separately-locked optionals.
private struct RecordingSession {
    let bundle: RecordingBundle
    let metadata: RecordingMetadata
    let screen: TrackWriter
    let webcam: TrackWriter?
    let mic: TrackWriter?
    let systemAudio: TrackWriter?
    let events: EventRecorder
    let cursor: CursorSampler

    /// Finish every writer in parallel at the shared end time.
    func finishWriters(endTime: CMTime?) async {
        async let screenDone = screen.finish(endTime: endTime)
        async let webcamDone = webcam?.finish(endTime: endTime)
        async let micDone = mic?.finish(endTime: endTime)
        async let systemDone = systemAudio?.finish(endTime: endTime)
        _ = await (screenDone, webcamDone, micDone, systemDone)
    }
}
