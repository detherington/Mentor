import AVFoundation
import CoreMedia

/// Single-audio-track writer used for the raw `mic.m4a` / `system.m4a`
/// sidecar files. Same back-pressure + serial-queue model as
/// `RawTrackWriter` — capture callbacks return immediately and the actual
/// encode happens on a dedicated queue.
final class AudioWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let outputURL: URL
    private let writeQueue: DispatchQueue

    // Only touched on `writeQueue`.
    private var sessionStarted = false
    private var finished = false

    init(
        outputURL: URL,
        channels: Int,
        sampleRate: Double = 48_000,
        bitrate: Int = 128_000
    ) throws {
        self.outputURL = outputURL
        self.writeQueue = DispatchQueue(
            label: "com.darrell.mentor.audio-writer.\(outputURL.lastPathComponent)",
            qos: .userInteractive
        )
        try? FileManager.default.removeItem(at: outputURL)

        do {
            writer = try AVAssetWriter(url: outputURL, fileType: .m4a)
        } catch {
            throw CaptureError.writerSetupFailed("audio writer \(outputURL.lastPathComponent): \(error.localizedDescription)")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw CaptureError.writerSetupFailed("audio writer cannot add input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw CaptureError.writerSetupFailed(writer.error?.localizedDescription ?? "audio writer startWriting failed")
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
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
        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    func finish() async -> URL? {
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
