import AVFoundation
import CoreMedia

/// Single-video-track writer for the raw screen + webcam tracks.
/// Accepts uncompressed sample buffers from ScreenCaptureKit / AVFoundation
/// and encodes to H.264 MOV.
///
/// All interaction with the underlying `AVAssetWriter` + `AVAssetWriterInput`
/// happens on a dedicated serial queue. Capture callbacks (screen / camera)
/// dispatch samples async to this queue and return immediately — critical
/// because `AVAssetWriterInput.append` can block when the encoder is
/// back-pressured, and blocking the capture queue causes downstream frame
/// drops (visible as jitter in the composited recording).
final class RawTrackWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let outputURL: URL
    private let writeQueue: DispatchQueue

    // All fields below are only touched on `writeQueue`.
    private var sessionStarted = false
    private var finished = false

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
    private let label: String

    init(
        outputURL: URL,
        pixelSize: CGSize,
        averageBitrate: Int = 8_000_000,
        expectedFrameRate: Int = 60
    ) throws {
        self.outputURL = outputURL
        self.label = outputURL.lastPathComponent
        self.writeQueue = DispatchQueue(
            label: "com.darrell.mentor.raw-writer.\(outputURL.lastPathComponent)",
            qos: .userInteractive
        )

        try? FileManager.default.removeItem(at: outputURL)

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

        do {
            writer = try AVAssetWriter(url: outputURL, fileType: .mov)
        } catch {
            throw CaptureError.writerSetupFailed("raw writer \(outputURL.lastPathComponent): \(error.localizedDescription)")
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
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw CaptureError.writerSetupFailed("raw writer cannot add input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw CaptureError.writerSetupFailed(writer.error?.localizedDescription ?? "raw writer startWriting failed")
        }
    }

    /// Called from a capture queue — returns immediately. The actual encode
    /// happens on `writeQueue`.
    func append(_ sampleBuffer: CMSampleBuffer) {
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
            self.appendOnQueue(sampleBuffer)
        }
    }

    private func appendOnQueue(_ sampleBuffer: CMSampleBuffer) {
        if finished { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }

        // `isReadyForMoreMediaData` provides the backpressure signal —
        // drop samples when the encoder is full rather than letting them
        // pile up on the queue.
        guard input.isReadyForMoreMediaData else {
            telemetryLock.lock(); queueDrops &+= 1; telemetryLock.unlock()
            return
        }
        input.append(sampleBuffer)
        telemetryLock.lock(); encoded &+= 1; telemetryLock.unlock()
    }

    /// Stop writing and finalize the file. Waits for all queued samples to
    /// flush through the encoder before finishing.
    func finish() async -> URL? {
        // Drain any queued appends.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writeQueue.async {
                if !self.finished {
                    self.finished = true
                    self.input.markAsFinished()
                }
                cont.resume()
            }
        }
        await writer.finishWriting()
        telemetryLock.lock()
        let stats = (appendCalls, callerDrops, dispatched, queueDrops, encoded)
        telemetryLock.unlock()
        let total = max(stats.0, 1)
        let dropPct = Double(stats.1 + stats.3) / Double(total) * 100
        MentorDebug.log("RAWWRITE[\(label)]: calls=\(stats.0) encoded=\(stats.4) dropped=\(stats.1 + stats.3) (\(String(format: "%.1f%%", dropPct)); caller=\(stats.1), queue=\(stats.3))")
        return writer.status == .completed ? outputURL : nil
    }
}
