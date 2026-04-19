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

    /// Global "a render is in flight" flag. The compositor state
    /// `LiveCompositor.state` is a singleton; whichever code path
    /// writes to it last wins. That's fine when there's only one
    /// consumer, but `renderUsingCaptureLayout` (auto-baked MP4 right
    /// after stopping a recording) and any open editor's
    /// `applyLayout()` can race if the user opens an editor for a
    /// *different* recording while the auto-render of the new one is
    /// still running — editor writes pollute the render's state and
    /// settings like `webcamBackgroundStyle` flip mid-video.
    ///
    /// Callers (here + `EditorViewModel.applyLayout`) check this flag
    /// and skip pushing updates while a render is active. One-render-
    /// at-a-time behaviour is also enforced by `renderLock` below.
    private static let renderLock = NSLock()
    nonisolated(unsafe) private static var _isRendering: Bool = false
    static var isRendering: Bool {
        renderLock.lock(); defer { renderLock.unlock() }
        return _isRendering
    }

    /// Run `body` inside a guarded "render is in flight" window.
    /// Serialises multiple renders and surfaces `isRendering == true`
    /// to other code paths (specifically `EditorViewModel`) so they
    /// skip compositor-state writes while we've got the singleton
    /// committed to our layout.
    private static func withRenderLock<T>(_ body: () async throws -> T) async rethrows -> T {
        // Busy-wait with a short sleep rather than a continuation
        // queue — we don't expect contention to be common (auto-
        // render happens serially after recording ends, and editor
        // exports are user-triggered), so the simple version is
        // plenty and avoids a structured-continuation dance.
        while true {
            renderLock.lock()
            if !_isRendering {
                _isRendering = true
                renderLock.unlock()
                break
            }
            renderLock.unlock()
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
        }
        defer {
            renderLock.lock()
            _isRendering = false
            renderLock.unlock()
        }
        return try await body()
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
        /// Subtitle lines + styling. Empty `transcriptionLines` or
        /// `captionStyle.enabled == false` → no captions baked into the
        /// export.
        let transcriptionLines: [TranscriptionLine]
        let captionStyle: CaptionStyle

        /// Keystroke overlay chips + styling. Empty chips or
        /// `keystrokeOverlayStyle.enabled == false` → no overlay in the
        /// export.
        let keystrokeChips: [KeystrokeChip]
        let keystrokeOverlayStyle: KeystrokeOverlayStyle

        /// Cursor-highlight halo track + styling. Empty track or
        /// `cursorHighlightStyle.enabled == false` → no halo baked in.
        let cursorTrack: CursorHighlightTrack
        let cursorHighlightStyle: CursorHighlightStyle

        /// Webcam background processing (blur / color). Off → raw
        /// webcam goes through unchanged.
        let webcamBackgroundStyle: WebcamBackgroundStyle

        /// Optional replacement URL for the mic track. When non-nil
        /// and the file exists, the export composition uses this
        /// instead of `bundle.micAudioURL` — noise-reduction cleaned
        /// audio is fed in via this hook.
        let micOverrideURL: URL?

        /// When true and `transcriptionLines` is non-empty, the
        /// renderer writes a `.srt` sidecar next to the exported MP4.
        /// The SRT's timestamps are the post-trim, post-cut output
        /// times so they line up with the MP4's timeline — not the
        /// original recording's.
        let writeSRTSidecar: Bool

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
            audioMixVolumes: AudioMixBuilder.Volumes = .unity,
            transcriptionLines: [TranscriptionLine] = [],
            captionStyle: CaptionStyle = .default,
            keystrokeChips: [KeystrokeChip] = [],
            keystrokeOverlayStyle: KeystrokeOverlayStyle = .default,
            cursorTrack: CursorHighlightTrack = .empty,
            cursorHighlightStyle: CursorHighlightStyle = .default,
            webcamBackgroundStyle: WebcamBackgroundStyle = .default,
            micOverrideURL: URL? = nil,
            writeSRTSidecar: Bool = false
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
            self.transcriptionLines = transcriptionLines
            self.captionStyle = captionStyle
            self.keystrokeChips = keystrokeChips
            self.keystrokeOverlayStyle = keystrokeOverlayStyle
            self.cursorTrack = cursorTrack
            self.cursorHighlightStyle = cursorHighlightStyle
            self.webcamBackgroundStyle = webcamBackgroundStyle
            self.micOverrideURL = micOverrideURL
            self.writeSRTSidecar = writeSRTSidecar
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
        trimMap: TrimMap? = nil,
        outputURL: URL,
        progress: ((Float) -> Void)? = nil
    ) async throws -> URL {
        // Serialise all renders through the shared lock — while we're
        // inside this block `isRendering` is true, which causes any
        // open editor's `applyLayout()` to skip writing to
        // `LiveCompositor.state`. Prevents the "auto-render picks up
        // whatever the editor happened to type last" bug.
        try await withRenderLock {
            try await runRender(
                bundle: bundle,
                metadata: metadata,
                layout: layout,
                trimMap: trimMap,
                outputURL: outputURL,
                progress: progress
            )
        }
    }

    /// Actual render body — extracted from `render(...)` so the
    /// render-lock wrapper above stays short + obvious. Everything in
    /// here assumes exclusive access to `LiveCompositor.state`.
    private static func runRender(
        bundle: RecordingBundle,
        metadata: RecordingMetadata,
        layout: ExportLayout,
        trimMap: TrimMap?,
        outputURL: URL,
        progress: ((Float) -> Void)?
    ) async throws -> URL {
        // Prime the compositor's shared state. NOTE: the compositor reads
        // this state per frame, so callers must avoid racing mutations
        // while a render is in flight.
        let sourceComp = try await EditorComposition.build(
            bundle: bundle,
            metadata: metadata,
            micOverride: layout.micOverrideURL
        )
        let effectiveMap = trimMap ?? .entire(CMTimeRange(start: .zero, duration: sourceComp.duration))

        // When the user has made interior cuts, stitch a new composition
        // whose duration already reflects only the kept segments. The
        // downstream reader/writer pipeline then runs in "output time"
        // throughout — no reader.timeRange trimming needed, and the
        // compositor sees frames at their final output PTS.
        //
        // Keyframes, captions and cursor ripples live in source time, so
        // they get remapped through the TrimMap before being handed to
        // the compositor. The compositor itself treats the incoming
        // trimMap as an identity span over `stitchedDuration`.
        let composition: EditorComposition.Result
        let compositorMap: TrimMap
        let renderKeyframes: [ZoomKeyframe]
        let renderTalkingHeads: [TalkingHeadKeyframe]
        let renderRipples: [CursorRipple]
        let renderCaptions: [TranscriptionLine]
        let renderKeystrokes: [KeystrokeChip]
        let renderCursorTrack: CursorHighlightTrack

        if effectiveMap.cuts.isEmpty {
            composition = sourceComp
            compositorMap = effectiveMap
            renderKeyframes = layout.zoomKeyframes
            renderTalkingHeads = layout.talkingHeadKeyframes
            renderRipples = layout.cursorRipples
            renderCaptions = layout.transcriptionLines
            renderKeystrokes = layout.keystrokeChips
            renderCursorTrack = layout.cursorTrack
        } else {
            composition = try EditorComposition.stitched(source: sourceComp, trimMap: effectiveMap)
            compositorMap = .entire(CMTimeRange(start: .zero, duration: composition.duration))
            renderKeyframes = effectiveMap.remap(zoomKeyframes: layout.zoomKeyframes)
            renderTalkingHeads = effectiveMap.remap(talkingHeadKeyframes: layout.talkingHeadKeyframes)
            renderRipples = effectiveMap.remap(cursorRipples: layout.cursorRipples)
            renderCaptions = effectiveMap.remap(transcriptionLines: layout.transcriptionLines)
            renderKeystrokes = effectiveMap.remap(keystrokeChips: layout.keystrokeChips)
            renderCursorTrack = effectiveMap.remap(cursorTrack: layout.cursorTrack)
        }

        LiveCompositor.state.update(
            position: layout.position,
            shape: layout.shape,
            diameter: layout.diameterPixels,
            inset: layout.insetPixels,
            zoomKeyframes: renderKeyframes,
            webcamTransitions: layout.webcamTransitions,
            startCard: layout.startCard,
            endCard: layout.endCard,
            trimMap: compositorMap,
            cursorRipples: renderRipples,
            cursorRippleStyle: layout.cursorRippleStyle,
            talkingHeadKeyframes: renderTalkingHeads,
            transcriptionLines: renderCaptions,
            captionStyle: layout.captionStyle,
            keystrokeChips: renderKeystrokes,
            keystrokeOverlayStyle: layout.keystrokeOverlayStyle,
            cursorTrack: renderCursorTrack,
            cursorHighlightStyle: layout.cursorHighlightStyle,
            webcamBackgroundStyle: layout.webcamBackgroundStyle
        )
        let audioMix = AudioMixBuilder.build(
            composition: composition.composition,
            micTrackID: composition.micTrackID,
            systemTrackID: composition.systemTrackID,
            soundboardTrackID: composition.soundboardTrackID,
            volumes: layout.audioMixVolumes
        )

        // Once stitched, there are no interior cuts left in the asset —
        // the reader runs over the full stitched duration. For the non-
        // stitched path we still honour the outer trim via trimMap.
        let readerMap: TrimMap = effectiveMap.cuts.isEmpty
            ? effectiveMap
            : compositorMap

        let writtenURL = try await writeComposition(
            composition: composition.composition,
            videoComposition: composition.videoComposition,
            duration: composition.duration,
            outputSize: CGSize(
                width: metadata.compositedPixelSize.width,
                height: metadata.compositedPixelSize.height
            ),
            trimMap: readerMap,
            videoBitrate: layout.videoBitrate,
            audioMix: audioMix,
            outputURL: outputURL,
            progress: progress
        )

        // Sidecar SRT — only if asked AND there's actually a
        // transcription to emit. Always run source→output remap so
        // the timestamps line up with the MP4 regardless of whether
        // we took the stitched or straight-reader path above.
        if layout.writeSRTSidecar, !layout.transcriptionLines.isEmpty {
            let srtLines = effectiveMap.remap(transcriptionLines: layout.transcriptionLines)
            if !srtLines.isEmpty {
                let srtURL = writtenURL
                    .deletingPathExtension()
                    .appendingPathExtension("srt")
                let srtBody = SRTFormatter.format(lines: srtLines)
                do {
                    try srtBody.write(to: srtURL, atomically: true, encoding: .utf8)
                    MentorDebug.log("EXPORT: wrote SRT sidecar \(srtURL.lastPathComponent) (\(srtLines.count) cues)")
                } catch {
                    // Non-fatal — the MP4 is already on disk.
                    MentorDebug.log("EXPORT: SRT sidecar write failed: \(error.localizedDescription)")
                }
            }
        }

        return writtenURL
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
        trimMap: TrimMap? = nil,
        videoBitrate: Int = ExportQuality.high.bitrate,
        audioMix: AVAudioMix? = nil,
        outputURL: URL,
        progress: ((Float) -> Void)?
    ) async throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)

        // Effective source time range — either the outer trim, or the full
        // duration. NOTE: interior cuts (when present) are handled by
        // stitching a new composition upstream; at this layer we only
        // care about the outer range.
        let sourceRange: CMTimeRange = trimMap?.outerTrim ?? CMTimeRange(start: .zero, duration: duration)
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
