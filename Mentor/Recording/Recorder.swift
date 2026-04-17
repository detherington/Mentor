import AVFoundation
import CoreMedia
import CoreVideo

/// Wraps AVAssetWriter. Writes:
/// - one video track (composited screen + webcam)
/// - mic audio track
/// - optional system-audio track (separate, so editor can rebalance later;
///   QuickTime mixes both during playback)
///
/// Capture callbacks call the `append*` methods and return immediately; the
/// underlying `AVAssetWriter` / `AVAssetWriterInput` operations run on a
/// dedicated serial queue so encoder back-pressure never blocks the capture
/// pipeline (which would otherwise cascade into dropped/stale frames in the
/// composited output).
final class Recorder: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let micAudioInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let outputURL: URL
    private let writeQueue: DispatchQueue

    // Only touched on `writeQueue`.
    private var sessionStarted = false
    private var finished = false

    init(outputURL: URL, videoSize: CGSize, includeSystemAudio: Bool) throws {
        self.outputURL = outputURL
        self.writeQueue = DispatchQueue(
            label: "com.darrell.mentor.recorder.\(outputURL.lastPathComponent)",
            qos: .userInteractive
        )
        try? FileManager.default.removeItem(at: outputURL)

        do {
            writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        } catch {
            throw CaptureError.writerSetupFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(videoSize.width),
            kCVPixelBufferHeightKey as String: Int(videoSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttrs
        )

        guard writer.canAdd(videoInput) else {
            throw CaptureError.writerSetupFailed("cannot add video input")
        }
        writer.add(videoInput)

        let micSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        micAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
        micAudioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(micAudioInput) else {
            throw CaptureError.writerSetupFailed("cannot add mic input")
        }
        writer.add(micAudioInput)

        if includeSystemAudio {
            let sysSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            let sysInput = AVAssetWriterInput(mediaType: .audio, outputSettings: sysSettings)
            sysInput.expectsMediaDataInRealTime = true
            if writer.canAdd(sysInput) {
                writer.add(sysInput)
                systemAudioInput = sysInput
            } else {
                systemAudioInput = nil
            }
        } else {
            systemAudioInput = nil
        }

        guard writer.startWriting() else {
            throw CaptureError.writerSetupFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    // MARK: - Public append APIs (non-blocking)

    func appendVideo(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        // Caller-thread back-pressure check — drop rather than queue when the
        // encoder is saturated, to keep pixel buffers from piling up and
        // starving the capture pool.
        guard videoInput.isReadyForMoreMediaData else { return }
        writeQueue.async { [pixelBuffer] in
            self.appendVideoOnQueue(pixelBuffer, pts: presentationTime)
        }
    }

    func appendMicAudio(_ sampleBuffer: CMSampleBuffer) {
        guard micAudioInput.isReadyForMoreMediaData else { return }
        writeQueue.async { [sampleBuffer] in
            self.appendAudioOnQueue(sampleBuffer, input: self.micAudioInput)
        }
    }

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let input = systemAudioInput, input.isReadyForMoreMediaData else { return }
        writeQueue.async { [sampleBuffer] in
            if let input = self.systemAudioInput {
                self.appendAudioOnQueue(sampleBuffer, input: input)
            }
        }
    }

    // MARK: - Queue-serialized implementations

    private func appendVideoOnQueue(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        if finished { return }
        guard pts.isValid else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: pts)
    }

    private func appendAudioOnQueue(_ sampleBuffer: CMSampleBuffer, input: AVAssetWriterInput) {
        if finished { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    // MARK: - Finish

    func finish() async -> URL? {
        // Drain pending appends, then mark inputs finished on the same queue
        // so ordering is preserved.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writeQueue.async {
                if !self.finished {
                    self.finished = true
                    self.videoInput.markAsFinished()
                    self.micAudioInput.markAsFinished()
                    self.systemAudioInput?.markAsFinished()
                }
                cont.resume()
            }
        }
        await writer.finishWriting()
        return writer.status == .completed ? outputURL : nil
    }
}
