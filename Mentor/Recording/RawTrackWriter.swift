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

    init(
        outputURL: URL,
        pixelSize: CGSize,
        averageBitrate: Int = 8_000_000,
        expectedFrameRate: Int = 60
    ) throws {
        self.outputURL = outputURL
        self.writeQueue = DispatchQueue(
            label: "com.darrell.mentor.raw-writer.\(outputURL.lastPathComponent)",
            qos: .userInteractive
        )

        try? FileManager.default.removeItem(at: outputURL)

        do {
            writer = try AVAssetWriter(url: outputURL, fileType: .mov)
        } catch {
            throw CaptureError.writerSetupFailed("raw writer \(outputURL.lastPathComponent): \(error.localizedDescription)")
        }

        // Baseline profile + no frame reordering: removes B-frame encoding
        // work. Frame-rate hints help the encoder plan rate control. Lower
        // bitrate reduces entropy coding / rate-control CPU work. All of
        // this reduces media-engine throughput demand so two concurrent
        // real-time encoders fit comfortably within one media engine.
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitrate,
                AVVideoMaxKeyFrameIntervalKey: expectedFrameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
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
        // Caller-thread back-pressure check: if the encoder is full, drop
        // the sample now rather than queuing it (and holding the underlying
        // pixel buffer in memory, which can exhaust the capture pool).
        guard input.isReadyForMoreMediaData else { return }
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
        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
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
        return writer.status == .completed ? outputURL : nil
    }
}
