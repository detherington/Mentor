import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

/// Orchestrates the live capture pipeline. Under Option A (post-capture
/// render), the coordinator only writes the raw `.mentor` sidecar during
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

    private let screenCapture = ScreenCapture()

    private let stateLock = NSLock()
    private var _isRecording = false

    var isRecording: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isRecording
    }

    private let pipelineLock = NSLock()
    private var screenRawWriter: RawTrackWriter?
    private var webcamRawWriter: RawTrackWriter?
    private var micAudioWriter: AudioWriter?
    private var systemAudioWriter: AudioWriter?
    private var eventRecorder: EventRecorder?
    private var currentBundle: RecordingBundle?
    private var currentMetadata: RecordingMetadata?
    private var latestCameraBuffer: CVPixelBuffer?

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
        return movies.appendingPathComponent("Mentor", isDirectory: true)
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
    /// user picked in Settings. Safe to call while preview is running.
    func reconfigureDevices() {
        cameraCapture.reconfigureDevices()
    }

    /// Stopping a recording hands back the finished bundle; callers
    /// typically kick off `FinalRenderer` at this point.
    struct FinishedRecording {
        let bundle: RecordingBundle
        let metadata: RecordingMetadata
    }

    func startRecording(source: CaptureSource) async throws {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        let outputSize = source.pixelSize(scale: scale)
        let dir = Self.outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundle = RecordingBundle.make(baseDirectory: dir)
        try bundle.createSidecarDirectory()

        let captureSysAudio = Settings.shared.captureSystemAudio

        // Raw video writers — baseline H.264, no B-frames, hints for 60fps
        // screen / 30fps webcam so the media engine can plan rate control.
        let screenRaw = try RawTrackWriter(
            outputURL: bundle.screenVideoURL,
            pixelSize: outputSize,
            averageBitrate: 8_000_000,
            expectedFrameRate: 60
        )
        let webcamRaw = try RawTrackWriter(
            outputURL: bundle.webcamVideoURL,
            pixelSize: cameraCapture.sourcePixelSize,
            averageBitrate: 4_000_000,
            expectedFrameRate: 30
        )

        // Audio writers (sidecar m4a files — replaces the old composited
        // recorder's audio tracks).
        let micWriter = try AudioWriter(
            outputURL: bundle.micAudioURL,
            channels: 1,
            bitrate: 128_000
        )
        let systemWriter: AudioWriter? = captureSysAudio
            ? try AudioWriter(
                outputURL: bundle.systemAudioURL,
                channels: 2,
                bitrate: 192_000
            )
            : nil

        let eventRec = EventRecorder()
        eventRec.start()

        let metadata = RecordingMetadata(
            version: 1,
            startDate: Date(),
            source: Self.metadataSourceInfo(for: source),
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

        pipelineLock.lock()
        self.screenRawWriter = screenRaw
        self.webcamRawWriter = webcamRaw
        self.micAudioWriter = micWriter
        self.systemAudioWriter = systemWriter
        self.eventRecorder = eventRec
        self.currentBundle = bundle
        self.currentMetadata = metadata
        latestCameraBuffer = nil
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
            self.screenRawWriter = nil
            self.webcamRawWriter = nil
            self.micAudioWriter = nil
            self.systemAudioWriter = nil
            self.eventRecorder = nil
            self.currentBundle = nil
            self.currentMetadata = nil
            pipelineLock.unlock()
            _ = await screenRaw.finish()
            _ = await webcamRaw.finish()
            _ = await micWriter.finish()
            _ = await systemWriter?.finish()
            _ = eventRec.stop()
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
    func stopRecording() async -> FinishedRecording? {
        stateLock.lock()
        guard _isRecording else { stateLock.unlock(); return nil }
        _isRecording = false
        stateLock.unlock()

        await screenCapture.stop()

        // Close the soundboard tap *before* we tear down the rest —
        // stopping synchronises with the engine so by the time the
        // below writers finish, soundboard.m4a is fully flushed.
        if let soundboard {
            await soundboard.stopRecordingTap()
        }

        pipelineLock.lock()
        let screenRaw = self.screenRawWriter
        let webcamRaw = self.webcamRawWriter
        let micWriter = self.micAudioWriter
        let sysWriter = self.systemAudioWriter
        let eventRec = self.eventRecorder
        let bundle = self.currentBundle
        let metadata = self.currentMetadata
        self.screenRawWriter = nil
        self.webcamRawWriter = nil
        self.micAudioWriter = nil
        self.systemAudioWriter = nil
        self.eventRecorder = nil
        self.currentBundle = nil
        self.currentMetadata = nil
        latestCameraBuffer = nil
        pipelineLock.unlock()

        // Finish all writers in parallel.
        async let screenURL = screenRaw?.finish()
        async let webcamURL = webcamRaw?.finish()
        async let micURL    = micWriter?.finish()
        async let sysURL    = sysWriter?.finish()
        _ = await (screenURL, webcamURL, micURL, sysURL)

        // Flush event log + metadata.
        if let bundle, let eventRec, let log = eventRec.stop() {
            persistJSON(log, to: bundle.eventsURL)
        }
        if let bundle, let metadata {
            persistJSON(metadata, to: bundle.metadataURL)
        }

        guard let bundle, let metadata else { return nil }
        return FinishedRecording(bundle: bundle, metadata: metadata)
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
            MentorDebug.log("COORD: failed to write \(url.lastPathComponent): \(error)")
        }
    }

    private static func metadataSourceInfo(for source: CaptureSource) -> RecordingMetadata.SourceInfo {
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
                windowFrameWidth: nil, windowFrameHeight: nil
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
                windowFrameHeight: Double(f.height)
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
                windowFrameWidth: nil, windowFrameHeight: nil
            )
        }
    }
}

extension CaptureCoordinator: ScreenCaptureDelegate {
    func screenCapture(_ capture: ScreenCapture, didOutputVideo sample: CMSampleBuffer) {
        pipelineLock.lock()
        let screenRaw = self.screenRawWriter
        pipelineLock.unlock()
        // Only the raw track is written live — composited output is
        // rebuilt post-capture by FinalRenderer.
        screenRaw?.append(sample)
    }

    func screenCapture(_ capture: ScreenCapture, didOutputAudio sample: CMSampleBuffer) {
        pipelineLock.lock()
        let sysWriter = self.systemAudioWriter
        pipelineLock.unlock()
        sysWriter?.append(sample)
    }

    func screenCapture(_ capture: ScreenCapture, didFailWith error: Error) {
        MentorDebug.log("COORD: screen capture stopped: \(error)")
    }
}

extension CaptureCoordinator: CameraCaptureDelegate {
    func cameraCapture(_ capture: CameraCapture, didOutputVideo sample: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        pipelineLock.lock()
        latestCameraBuffer = imageBuffer
        let webcamRaw = self.webcamRawWriter
        pipelineLock.unlock()

        webcamRaw?.append(sample)

        observerLock.lock()
        let observer = _cameraFrameObserver
        observerLock.unlock()
        observer?(imageBuffer)
    }

    func cameraCapture(_ capture: CameraCapture, didOutputAudio sample: CMSampleBuffer) {
        pipelineLock.lock()
        let micWriter = self.micAudioWriter
        pipelineLock.unlock()
        micWriter?.append(sample)
    }
}
