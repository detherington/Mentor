import AVFoundation
import CoreMedia

/// Writes one track of the raw `.pepper` sidecar — `screen.mov` and
/// `webcam.mov` (H.264) or `mic.m4a` and `system.m4a` (AAC). There used
/// to be a video and an audio copy of this class that differed only in
/// output settings.
///
/// All interaction with the underlying `AVAssetWriter` + input happens on
/// a dedicated serial queue. Capture callbacks dispatch samples to it and
/// return immediately — critical because `AVAssetWriterInput.append` can
/// block when the encoder is back-pressured, and blocking a capture queue
/// causes downstream frame drops (visible as jitter in the recording).
final class TrackWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let outputURL: URL
    private let writeQueue: DispatchQueue
    private let label: String

    /// Screen only: keep the last appended frame so `finish(endTime:)`
    /// can re-stamp it at the stop time. ScreenCaptureKit skips idle
    /// frames, so without this `screen.mov` ends at the last on-screen
    /// change — and the editor clamps every other track to that length,
    /// cutting off narration over a static final slide.
    private let holdsLastFrame: Bool
    /// Called once, on the write queue, the first time an append fails
    /// (disk full, encoder error) so the recording can be stopped and
    /// the user told, instead of discovering it at render time.
    private let onFailure: (@Sendable (Error?) -> Void)?

    // All fields below are only touched on `writeQueue`.
    private var sessionStarted = false
    private var finished = false
    private var lastSample: CMSampleBuffer?
    private var failedAppends = 0

    // Drop telemetry — so we can correlate user-visible stutter with
    // encoder back-pressure. `appendCalls` counts every sample that
    // landed in `append()`; `dispatched` is what survived the pre-
    // dispatch readiness check; `encoded` is what actually got to
    // `input.append()`. `callerDrops` + `queueDrops` are the two silent
    // drop sinks, split so we know which side is under pressure.
    private let telemetryLock = NSLock()
    private var appendCalls: Int = 0
    private var callerDrops: Int = 0  // dropped before dispatch: input not ready
    private var dispatched: Int = 0
    private var queueDrops: Int = 0   // dropped on the write queue: input not ready
    private var encoded: Int = 0

    /// H.264 video track.
    static func video(
        outputURL: URL,
        pixelSize: CGSize,
        averageBitrate: Int,
        expectedFrameRate: Int,
        holdsLastFrame: Bool = false,
        onFailure: (@Sendable (Error?) -> Void)? = nil
    ) throws -> TrackWriter {
        // H.264 requires positive, even width/height. AVAssetWriterInput's
        // validator throws NSInvalidArgumentException on odd/zero dims and
        // that exception is uncatchable from Swift (process aborts). Fail
        // cleanly here instead.
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw CaptureError.writerSetupFailed(
                "invalid pixel size \(width)x\(height) for \(outputURL.lastPathComponent)"
            )
        }
        // High profile + no frame reordering: higher max level than
        // Baseline (Baseline auto-level tops out well before 4K on
        // Apple Silicon's H.264 hardware encoder and rejects anything
        // larger with an uncatchable NSInvalidArgument). Frame
        // reordering off keeps per-frame latency at zero so two
        // concurrent real-time encoders still fit within one media
        // engine. Frame-rate hints let the encoder plan rate control.
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitrate,
                AVVideoMaxKeyFrameIntervalKey: expectedFrameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: expectedFrameRate,
                AVVideoAverageNonDroppableFrameRateKey: expectedFrameRate
            ]
        ]
        return try TrackWriter(
            outputURL: outputURL,
            fileType: .mov,
            mediaType: .video,
            settings: settings,
            holdsLastFrame: holdsLastFrame,
            onFailure: onFailure
        )
    }

    /// AAC audio track.
    static func audio(
        outputURL: URL,
        channels: Int,
        sampleRate: Double = 48_000,
        bitrate: Int,
        onFailure: (@Sendable (Error?) -> Void)? = nil
    ) throws -> TrackWriter {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate
        ]
        return try TrackWriter(
            outputURL: outputURL,
            fileType: .m4a,
            mediaType: .audio,
            settings: settings,
            holdsLastFrame: false,
            onFailure: onFailure
        )
    }

    private init(
        outputURL: URL,
        fileType: AVFileType,
        mediaType: AVMediaType,
        settings: [String: Any],
        holdsLastFrame: Bool,
        onFailure: (@Sendable (Error?) -> Void)?
    ) throws {
        self.outputURL = outputURL
        self.label = outputURL.lastPathComponent
        self.holdsLastFrame = holdsLastFrame
        self.onFailure = onFailure
        self.writeQueue = DispatchQueue(
            label: "com.darrell.pepper.track-writer.\(outputURL.lastPathComponent)",
            qos: .userInteractive
        )

        try? FileManager.default.removeItem(at: outputURL)
        do {
            writer = try AVAssetWriter(url: outputURL, fileType: fileType)
        } catch {
            throw CaptureError.writerSetupFailed("\(label) writer: \(error.localizedDescription)")
        }
        input = AVAssetWriterInput(mediaType: mediaType, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CaptureError.writerSetupFailed("\(label) writer cannot add input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw CaptureError.writerSetupFailed(writer.error?.localizedDescription ?? "\(label) startWriting failed")
        }
    }

    /// Called from a capture queue — returns immediately. The actual encode
    /// happens on `writeQueue`. `sessionStart` is the recording's shared
    /// time origin (first screen frame), identical across every writer so
    /// all tracks share one timeline; samples before it are edited out,
    /// and a track whose first sample lands later gets an empty edit.
    func append(_ sampleBuffer: CMSampleBuffer, sessionStart: CMTime) {
        telemetryLock.lock(); appendCalls &+= 1; telemetryLock.unlock()
        // Caller-thread back-pressure check: if the encoder is full, drop
        // the sample now rather than queuing it (and holding the underlying
        // pixel buffer in memory, which can exhaust the capture pool).
        guard input.isReadyForMoreMediaData else {
            telemetryLock.lock(); callerDrops &+= 1; telemetryLock.unlock()
            return
        }
        telemetryLock.lock(); dispatched &+= 1; telemetryLock.unlock()
        writeQueue.async { [sampleBuffer] in
            self.appendOnQueue(sampleBuffer, sessionStart: sessionStart)
        }
    }

    private func appendOnQueue(_ sampleBuffer: CMSampleBuffer, sessionStart: CMTime) {
        if finished { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, sessionStart.isValid else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: sessionStart)
            sessionStarted = true
        }

        // `isReadyForMoreMediaData` provides the backpressure signal —
        // drop samples when the encoder is full rather than letting them
        // pile up on the queue.
        guard input.isReadyForMoreMediaData else {
            telemetryLock.lock(); queueDrops &+= 1; telemetryLock.unlock()
            return
        }
        guard input.append(sampleBuffer) else {
            failedAppends &+= 1
            if failedAppends == 1 { onFailure?(writer.error) }
            return
        }
        if holdsLastFrame { lastSample = sampleBuffer }
        telemetryLock.lock(); encoded &+= 1; telemetryLock.unlock()
    }

    /// Stop writing and finalize the file. Waits for all queued samples to
    /// flush through the encoder before finishing. `endTime` is the shared
    /// stop time (same timeline as `sessionStart`); every writer ends its
    /// session there so all tracks have the same length — trailing audio
    /// captured after Stop is edited out.
    func finish(endTime: CMTime? = nil) async -> URL? {
        // Drain any queued appends. Queue-only state is read inside the
        // hop and handed back.
        let (sessionStarted, failedAppends) = await withCheckedContinuation { (cont: CheckedContinuation<(Bool, Int), Never>) in
            writeQueue.async {
                if !self.finished {
                    self.finished = true
                    // Hold the final frame until the stop time: the copy
                    // at `endTime` itself is edited out by `endSession`,
                    // but it gives the real last frame its full duration.
                    if let endTime, endTime.isValid,
                       let last = self.lastSample,
                       CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(last), endTime) < 0,
                       self.input.isReadyForMoreMediaData,
                       let hold = last.restamped(at: endTime) {
                        self.input.append(hold)
                    }
                    self.lastSample = nil
                    self.input.markAsFinished()
                }
                cont.resume(returning: (self.sessionStarted, self.failedAppends))
            }
        }
        // `finishWriting` on a failed writer (disk full, encoder error)
        // is illegal; there's nothing to salvage anyway.
        guard writer.status == .writing else {
            PepperDebug.log("TRACK[\(label)]: writer not writing at finish (status=\(writer.status.rawValue), error=\(writer.error?.localizedDescription ?? "nil"), failedAppends=\(failedAppends))")
            return nil
        }
        if let endTime, endTime.isValid, sessionStarted {
            writer.endSession(atSourceTime: endTime)
        }
        await writer.finishWriting()
        telemetryLock.lock()
        let stats = (appendCalls, callerDrops, dispatched, queueDrops, encoded)
        telemetryLock.unlock()
        let total = max(stats.0, 1)
        let dropPct = Double(stats.1 + stats.3) / Double(total) * 100
        PepperDebug.log("TRACK[\(label)]: calls=\(stats.0) encoded=\(stats.4) dropped=\(stats.1 + stats.3) (\(String(format: "%.1f%%", dropPct)); caller=\(stats.1), queue=\(stats.3)) failedAppends=\(failedAppends)")
        return writer.status == .completed ? outputURL : nil
    }
}
