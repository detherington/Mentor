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

    /// Serialise concurrent renders — each render now owns its own
    /// compositor `State` (no shared singleton any more), so this
    /// lock is purely about not piling up simultaneous HW H.264
    /// encoders. The auto-bake runs right after `stopRecording`, and
    /// the editor's Export button runs on user action; back-to-back
    /// use is common, but overlapping use would mean two full-rate
    /// encoders on the media engine at once.
    private static let renderLock = NSLock()
    nonisolated(unsafe) private static var _isRendering: Bool = false

    /// Run `body` inside a guarded "render is in flight" window so
    /// only one encoder pass is live at a time.
    private static func withRenderLock<T>(_ body: () async throws -> T) async throws -> T {
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
            // `try?` here used to swallow CancellationError — a
            // cancelled waiter's sleep returns immediately, so the loop
            // spun at full CPU until the other render finished.
            do {
                try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
            } catch {
                throw RenderError.cancelled
            }
        }
        defer {
            renderLock.lock()
            _isRendering = false
            renderLock.unlock()
        }
        return try await body()
    }

    /// What an export renders: the overlay (in source time — the renderer
    /// remaps it when there are cuts) plus export-only options.
    /// Independent of the capture-time metadata, so the editor can pass
    /// user-modified layouts.
    struct ExportLayout {
        var overlay: OverlaySettings
        /// Target video bitrate in bits/sec. Defaults to the "high"
        /// preset to match the original hard-coded value.
        var videoBitrate: Int = ExportQuality.high.bitrate
        /// Per-track volumes applied via `AVAudioMix` at export time.
        /// Unity preserves the original recording mix.
        var audioMixVolumes: AudioMixBuilder.Volumes = .unity
        /// Optional replacement URL for the mic track. When non-nil
        /// and the file exists, the export composition uses this
        /// instead of `bundle.micAudioURL` — noise-reduction cleaned
        /// audio is fed in via this hook.
        var micOverrideURL: URL?
        /// When true and there are caption lines, the renderer writes a
        /// `.srt` sidecar next to the exported MP4. The SRT's timestamps
        /// are the post-trim, post-cut output times so they line up with
        /// the MP4's timeline — not the original recording's.
        var writeSRTSidecar: Bool = false

        /// The capture-time webcam layout; everything else at defaults
        /// (the post-capture auto-render never adds title cards).
        static func fromCaptureMetadata(_ metadata: RecordingMetadata) -> ExportLayout {
            let layout = metadata.webcamLayout
            let backingScale = CGFloat(metadata.backingScale ?? 2.0)
            var overlay = OverlaySettings()
            overlay.position = WebcamPosition(rawValue: layout.position) ?? .bottomRight
            overlay.shape = WebcamShape(rawValue: layout.shape) ?? .circle
            overlay.diameter = CGFloat(layout.diameterPoints) * backingScale
            overlay.inset = CGFloat(layout.insetPoints) * backingScale
            return ExportLayout(overlay: overlay)
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
        // Serialise all renders through the shared lock so we don't
        // spin up two real-time H.264 encoders at once (auto-bake +
        // editor export, or two exports in quick succession).
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
    /// render-lock wrapper above stays short + obvious. Each call
    /// owns its own `EditorComposition.Result` (and therefore its own
    /// `LiveCompositor.State`), so it can run concurrently with the
    /// editor's live preview on the same bundle.
    private static func runRender(
        bundle: RecordingBundle,
        metadata: RecordingMetadata,
        layout: ExportLayout,
        trimMap: TrimMap?,
        outputURL: URL,
        progress: ((Float) -> Void)?
    ) async throws -> URL {
        // Build this render's own composition (and thus its own
        // `LiveCompositor.State`). Any concurrent editor session on
        // the same bundle has a separate Result + separate state —
        // their `applyLayout` writes land in a different place.
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
        // The overlay lives in source time, so with cuts it's remapped
        // onto the stitched timeline before being handed to the
        // compositor, which then treats its trimMap as an identity span
        // over the stitched duration.
        let composition: EditorComposition.Result
        let compositorMap: TrimMap
        let overlay: OverlaySettings
        if effectiveMap.cuts.isEmpty {
            composition = sourceComp
            compositorMap = effectiveMap
            overlay = layout.overlay
        } else {
            composition = try EditorComposition.stitched(source: sourceComp, trimMap: effectiveMap)
            compositorMap = .entire(CMTimeRange(start: .zero, duration: composition.duration))
            overlay = layout.overlay.remapped(by: effectiveMap)
        }

        // Write to THIS render's own composition state — independent
        // of any editor session running concurrently on the same
        // bundle.
        composition.compositorState.set(overlay, trimMap: compositorMap)
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
        if layout.writeSRTSidecar, !layout.overlay.transcriptionLines.isEmpty {
            let srtLines = effectiveMap.remap(transcriptionLines: layout.overlay.transcriptionLines)
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
        layout.overlay.zoomKeyframes = keyframes
        layout.overlay.cursorRipples = ripples
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
        // `onCancel` is the only reliable cancel signal — see PumpControl.
        let control = PumpControl()
        await withTaskCancellationHandler {
            async let videoDone: Void = pump(
                input: videoWriterInput,
                output: videoReaderOutput,
                writer: writer,
                queue: videoQueue,
                control: control
            ) { sample in
                guard let progress else { return }
                let t = CMSampleBufferGetPresentationTimeStamp(sample)
                let elapsed = CMTimeSubtract(t, progressOrigin)
                progress(Float(min(1.0, max(0.0, CMTimeGetSeconds(elapsed) / totalSeconds))))
            }
            async let audioDone: Void = {
                if let audioWriterInput, let audioReaderOutput {
                    await pump(
                        input: audioWriterInput,
                        output: audioReaderOutput,
                        writer: writer,
                        queue: audioQueue,
                        control: control
                    )
                }
            }()
            _ = await (videoDone, audioDone)
        } onCancel: {
            control.abort()
        }

        // ---- Finish
        // Anything other than "both pumps drained a healthy reader into a
        // still-writing writer" is a failure. Previously a reader failure
        // (e.g. the compositor couldn't get a pixel buffer) surfaced as a
        // nil sample, was treated as end-of-file, and shipped a silently
        // truncated MP4. `finishWriting` is only legal while `.writing`.
        let cancelled = Task.isCancelled
        let readerFailed = reader.status == .failed
        if cancelled || readerFailed || writer.status != .writing {
            let readerError = reader.error
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: outputURL)
            if cancelled { throw RenderError.cancelled }
            if let writerError = writer.error {
                throw RenderError.exportFailed("writer error: \(writerError.localizedDescription)")
            }
            if readerFailed {
                throw RenderError.exportFailed("reader error: \(readerError?.localizedDescription ?? "unknown")")
            }
            throw RenderError.exportFailed("writer status: \(writer.status.rawValue)")
        }

        await writer.finishWriting()
        if reader.status != .completed && reader.status != .cancelled {
            reader.cancelReading()
        }

        if let writerError = writer.error {
            throw RenderError.exportFailed("writer error: \(writerError.localizedDescription)")
        }
        guard writer.status == .completed else {
            throw RenderError.exportFailed("writer status: \(writer.status.rawValue)")
        }
        return outputURL
    }

    /// Drain one reader output into one writer input. Video and audio
    /// used to have near-identical copies of this; the only difference
    /// was video's progress callback, now `onSample`.
    private static func pump(
        input: AVAssetWriterInput,
        output: AVAssetReaderOutput,
        writer: AVAssetWriter,
        queue: DispatchQueue,
        control: PumpControl,
        onSample: ((CMSampleBuffer) -> Void)? = nil
    ) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            guard let id = control.register(cont) else { return }
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if control.isAborted {
                        control.finish(id)
                        return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        // End of range — or a reader failure, which the
                        // caller distinguishes via `reader.status`.
                        input.markAsFinished()
                        control.finish(id)
                        return
                    }
                    guard input.append(sample) else {
                        // Writer failed. AVFoundation stops calling
                        // *both* inputs' blocks after this, so abort
                        // wakes the other pump too.
                        control.abort()
                        return
                    }
                    onSample?(sample)
                }
                // Not ready — normally backpressure, and we'll be called
                // again. But a writer that failed without an append
                // returning false (async encoder error) never calls back.
                if writer.status == .failed {
                    control.abort()
                }
            }
        }
    }
}

/// Out-of-band stop signal shared by the video + audio pumps.
///
/// `requestMediaDataWhenReady` blocks run on GCD queues outside any
/// Task, so `Task.isCancelled` inside them is always false — the old
/// cancel check never fired and a cancelled export ran to completion.
/// Worse, once the writer fails AVFoundation stops invoking the blocks,
/// so a pump parked on its continuation would wait forever while
/// holding the render lock, wedging every later render (including the
/// post-recording auto-bake). Cancel or a failed append calls `abort()`,
/// which resumes every pending pump exactly once.
private final class PumpControl: @unchecked Sendable {
    private let lock = NSLock()
    private var aborted = false
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextID = 0

    var isAborted: Bool {
        lock.lock(); defer { lock.unlock() }
        return aborted
    }

    /// Returns nil (and resumes immediately) if already aborted — the
    /// cancel handler can fire before a pump has registered.
    func register(_ cont: CheckedContinuation<Void, Never>) -> Int? {
        lock.lock()
        if aborted {
            lock.unlock()
            cont.resume()
            return nil
        }
        let id = nextID
        nextID += 1
        pending[id] = cont
        lock.unlock()
        return id
    }

    /// Normal completion. No-op if `abort()` already resumed this pump.
    func finish(_ id: Int) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        cont?.resume()
    }

    func abort() {
        lock.lock()
        aborted = true
        let conts = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        conts.forEach { $0.resume() }
    }
}
