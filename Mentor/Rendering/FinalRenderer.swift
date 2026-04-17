import AVFoundation
import Foundation

/// Post-capture renderer that takes a `.mentor` sidecar bundle and produces
/// a playable composited `.mp4` alongside it. Runs offline (no real-time
/// pressure) so it can use the full media engine without competing with
/// live capture encoders.
///
/// Uses an explicit `AVAssetReader` + `AVAssetWriter` pipeline rather than
/// `AVAssetExportSession`, which picks its own frame-rate / codec heuristics
/// and doesn't reliably respect `videoComposition.frameDuration` when the
/// source has mixed frame rates. The reader pulls composited frames from
/// our custom `LiveCompositor` at the exact composition frame rate; the
/// writer encodes to H.264 at matching timing — no interpolation, no
/// duplicate/drop heuristics.
enum FinalRenderer {
    enum RenderError: Error, LocalizedError {
        case setupFailed(String)
        case exportFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .setupFailed(let s):  return "Final render setup failed: \(s)"
            case .exportFailed(let s): return "Final render failed: \(s)"
            case .cancelled:           return "Export cancelled."
            }
        }
    }

    /// Webcam-overlay parameters used by the renderer. Independent of the
    /// capture-time metadata, so the editor can pass user-modified layouts.
    struct ExportLayout {
        let position: WebcamPosition
        let shape: WebcamShape
        let diameterPixels: CGFloat
        let insetPixels: CGFloat
        let zoomKeyframes: [ZoomKeyframe]
        let webcamTransitions: WebcamTransitions
        let startCard: TitleCard
        let endCard: TitleCard
        let cursorRipples: [CursorRipple]
        let cursorRippleStyle: CursorRippleStyle
        let talkingHeadKeyframes: [TalkingHeadKeyframe]
        /// Target video bitrate in bits/sec. Defaults to the "high"
        /// preset to match the original hard-coded value.
        let videoBitrate: Int
        /// Per-track volumes applied via `AVAudioMix` at export time.
        /// Unity preserves the original recording mix.
        let audioMixVolumes: AudioMixBuilder.Volumes

        init(
            position: WebcamPosition,
            shape: WebcamShape,
            diameterPixels: CGFloat,
            insetPixels: CGFloat,
            zoomKeyframes: [ZoomKeyframe] = [],
            webcamTransitions: WebcamTransitions = .default,
            startCard: TitleCard = .defaultStart,
            endCard: TitleCard = .defaultEnd,
            cursorRipples: [CursorRipple] = [],
            cursorRippleStyle: CursorRippleStyle = .default,
            talkingHeadKeyframes: [TalkingHeadKeyframe] = [],
            videoBitrate: Int = ExportQuality.high.bitrate,
            audioMixVolumes: AudioMixBuilder.Volumes = .unity
        ) {
            self.position = position
            self.shape = shape
            self.diameterPixels = diameterPixels
            self.insetPixels = insetPixels
            self.zoomKeyframes = zoomKeyframes
            self.webcamTransitions = webcamTransitions
            self.startCard = startCard
            self.endCard = endCard
            self.cursorRipples = cursorRipples
            self.cursorRippleStyle = cursorRippleStyle
            self.talkingHeadKeyframes = talkingHeadKeyframes
            self.videoBitrate = videoBitrate
            self.audioMixVolumes = audioMixVolumes
        }

        static func fromCaptureMetadata(_ metadata: RecordingMetadata) -> ExportLayout {
            let layout = metadata.webcamLayout
            let backingScale = CGFloat(metadata.backingScale ?? 2.0)
            return ExportLayout(
                position: WebcamPosition(rawValue: layout.position) ?? .bottomRight,
                shape: WebcamShape(rawValue: layout.shape) ?? .circle,
                diameterPixels: CGFloat(layout.diameterPoints) * backingScale,
                insetPixels: CGFloat(layout.insetPoints) * backingScale,
                zoomKeyframes: []
                // webcamTransitions defaults to fade-in/out (.default)
                // startCard / endCard default to disabled — auto post-
                // capture render never adds title cards.
            )
        }
    }

    /// General-purpose render entry point — caller specifies layout +
    /// output URL + optional trim. Used by both the post-capture
    /// auto-render (with the capture-time layout, no trim) and the
    /// editor's Export button (with the user-modified layout + trim).
    @discardableResult
    static func render(
        bundle: RecordingBundle,
        metadata: RecordingMetadata,
        layout: ExportLayout,
        trimRange: CMTimeRange? = nil,
        outputURL: URL,
        progress: ((Float) -> Void)? = nil
    ) async throws -> URL {
        // Prime the compositor's shared state. NOTE: the compositor reads
        // this state per frame, so callers must avoid racing mutations
        // while a render is in flight.
        let composition = try await EditorComposition.build(bundle: bundle, metadata: metadata)
        let outRange = trimRange ?? CMTimeRange(start: .zero, duration: composition.duration)
        LiveCompositor.state.update(
            position: layout.position,
            shape: layout.shape,
            diameter: layout.diameterPixels,
            inset: layout.insetPixels,
            zoomKeyframes: layout.zoomKeyframes,
            webcamTransitions: layout.webcamTransitions,
            startCard: layout.startCard,
            endCard: layout.endCard,
            outputRange: outRange,
            cursorRipples: layout.cursorRipples,
            cursorRippleStyle: layout.cursorRippleStyle,
            talkingHeadKeyframes: layout.talkingHeadKeyframes
        )
        let audioMix = AudioMixBuilder.build(
            composition: composition.composition,
            micTrackID: composition.micTrackID,
            systemTrackID: composition.systemTrackID,
            soundboardTrackID: composition.soundboardTrackID,
            volumes: layout.audioMixVolumes
        )

        return try await writeComposition(
            composition: composition.composition,
            videoComposition: composition.videoComposition,
            duration: composition.duration,
            outputSize: CGSize(
                width: metadata.compositedPixelSize.width,
                height: metadata.compositedPixelSize.height
            ),
            trimRange: trimRange,
            videoBitrate: layout.videoBitrate,
            audioMix: audioMix,
            outputURL: outputURL,
            progress: progress
        )
    }

    @discardableResult
    static func renderUsingCaptureLayout(
        bundle: RecordingBundle,
        metadata: RecordingMetadata,
        progress: ((Float) -> Void)? = nil
    ) async throws -> URL {
        // Auto post-capture render: generate smart-zoom keyframes + cursor
        // ripples from the sidecar event log so the user gets the
        // Loom-style automatic polish without having to open the editor.
        let (keyframes, ripples) = await autoEventDerivatives(bundle: bundle, metadata: metadata)
        var layout = ExportLayout.fromCaptureMetadata(metadata)
        layout = ExportLayout(
            position: layout.position,
            shape: layout.shape,
            diameterPixels: layout.diameterPixels,
            insetPixels: layout.insetPixels,
            zoomKeyframes: keyframes,
            cursorRipples: ripples
        )
        return try await render(
            bundle: bundle,
            metadata: metadata,
            layout: layout,
            outputURL: bundle.finalMP4URL,
            progress: progress
        )
    }

    /// Pull duration from `screen.mov`, decode the event log, then derive
    /// both smart-zoom keyframes and cursor ripples in one pass. Returns
    /// empty arrays on any failure — auto-polish is best-effort, the
    /// render itself must still succeed.
    private static func autoEventDerivatives(
        bundle: RecordingBundle,
        metadata: RecordingMetadata
    ) async -> (keyframes: [ZoomKeyframe], ripples: [CursorRipple]) {
        let asset = AVURLAsset(url: bundle.screenVideoURL)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            return ([], [])
        }

        let log: EventRecorder.Log?
        if let data = try? Data(contentsOf: bundle.eventsURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            log = try? decoder.decode(EventRecorder.Log.self, from: data)
        } else {
            log = nil
        }

        return await MainActor.run {
            let keyframes = ZoomKeyframeGenerator.generate(
                from: log,
                metadata: metadata,
                duration: duration
            )
            let ripples = CursorRippleGenerator.generate(
                from: log,
                metadata: metadata
            )
            return (keyframes, ripples)
        }
    }

    // MARK: - Reader + Writer pipeline

    private static func writeComposition(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        duration: CMTime,
        outputSize: CGSize,
        trimRange: CMTimeRange? = nil,
        videoBitrate: Int = ExportQuality.high.bitrate,
        audioMix: AVAudioMix? = nil,
        outputURL: URL,
        progress: ((Float) -> Void)?
    ) async throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)

        // Effective source time range — either the trim, or the full duration.
        let sourceRange: CMTimeRange = trimRange ?? CMTimeRange(start: .zero, duration: duration)
        let sessionStart = sourceRange.start

        // ---- Reader
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: composition)
        } catch {
            throw RenderError.setupFailed("AVAssetReader: \(error.localizedDescription)")
        }
        reader.timeRange = sourceRange

        let videoTracks = composition.tracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw RenderError.setupFailed("composition has no video tracks")
        }

        let videoReaderOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        )
        videoReaderOutput.videoComposition = videoComposition
        videoReaderOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoReaderOutput) else {
            throw RenderError.setupFailed("reader cannot add video output")
        }
        reader.add(videoReaderOutput)

        let audioTracks = composition.tracks(withMediaType: .audio)
        let audioReaderOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000.0,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ]
            )
            output.alwaysCopiesSampleData = false
            output.audioMix = audioMix
            if reader.canAdd(output) {
                reader.add(output)
                audioReaderOutput = output
            } else {
                audioReaderOutput = nil
            }
        } else {
            audioReaderOutput = nil
        }

        // ---- Writer
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        } catch {
            throw RenderError.setupFailed("AVAssetWriter: \(error.localizedDescription)")
        }
        writer.shouldOptimizeForNetworkUse = true

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoMaxKeyFrameIntervalKey: 120,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoAverageNonDroppableFrameRateKey: 60
            ]
        ]
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoWriterInput) else {
            throw RenderError.setupFailed("writer cannot add video input")
        }
        writer.add(videoWriterInput)

        let audioWriterInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioWriterInput = input
            } else {
                audioWriterInput = nil
            }
        } else {
            audioWriterInput = nil
        }

        // ---- Start
        guard writer.startWriting() else {
            throw RenderError.exportFailed("writer.startWriting: \(writer.error?.localizedDescription ?? "unknown")")
        }
        guard reader.startReading() else {
            throw RenderError.exportFailed("reader.startReading: \(reader.error?.localizedDescription ?? "unknown")")
        }
        // Output PTS are sample PTS minus `sessionStart`, so trimmed exports
        // start at 0 in the written file regardless of where the trim begins
        // in composition time.
        writer.startSession(atSourceTime: sessionStart)

        let videoQueue = DispatchQueue(label: "com.darrell.mentor.render.video", qos: .userInitiated)
        let audioQueue = DispatchQueue(label: "com.darrell.mentor.render.audio", qos: .userInitiated)

        let totalSeconds = max(CMTimeGetSeconds(sourceRange.duration), 0.001)
        let progressOrigin = sessionStart

        // Pump video + audio concurrently; return only after both finish.
        async let videoDone: Void = pumpVideo(
            input: videoWriterInput,
            output: videoReaderOutput,
            queue: videoQueue,
            totalSeconds: totalSeconds,
            progressOrigin: progressOrigin,
            progress: progress
        )
        async let audioDone: Void = {
            if let audioWriterInput, let audioReaderOutput {
                await pumpAudio(input: audioWriterInput, output: audioReaderOutput, queue: audioQueue)
            }
        }()

        _ = await (videoDone, audioDone)

        // ---- Finish
        await writer.finishWriting()
        if reader.status != .completed && reader.status != .cancelled {
            reader.cancelReading()
        }

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: outputURL)
            throw RenderError.cancelled
        }

        if let writerError = writer.error {
            throw RenderError.exportFailed("writer error: \(writerError.localizedDescription)")
        }
        guard writer.status == .completed else {
            throw RenderError.exportFailed("writer status: \(writer.status.rawValue)")
        }
        return outputURL
    }

    private static func pumpVideo(
        input: AVAssetWriterInput,
        output: AVAssetReaderVideoCompositionOutput,
        queue: DispatchQueue,
        totalSeconds: Double,
        progressOrigin: CMTime,
        progress: ((Float) -> Void)?
    ) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        if Task.isCancelled {
                            input.markAsFinished()
                            cont.resume()
                            return
                        }
                        if let sample = output.copyNextSampleBuffer() {
                            input.append(sample)
                            if let progress {
                                let t = CMSampleBufferGetPresentationTimeStamp(sample)
                                let elapsed = CMTimeSubtract(t, progressOrigin)
                                let fraction = Float(min(1.0, max(0.0, CMTimeGetSeconds(elapsed) / totalSeconds)))
                                progress(fraction)
                            }
                        } else {
                            input.markAsFinished()
                            cont.resume()
                            return
                        }
                    }
                }
            }
        } onCancel: {
            // Nothing to do synchronously — the pump loop polls Task.isCancelled.
        }
    }

    private static func pumpAudio(
        input: AVAssetWriterInput,
        output: AVAssetReaderAudioMixOutput,
        queue: DispatchQueue
    ) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        if Task.isCancelled {
                            input.markAsFinished()
                            cont.resume()
                            return
                        }
                        if let sample = output.copyNextSampleBuffer() {
                            input.append(sample)
                        } else {
                            input.markAsFinished()
                            cont.resume()
                            return
                        }
                    }
                }
            }
        } onCancel: {
            // See above.
        }
    }
}
