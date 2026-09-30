import AVFoundation
import Foundation

/// AVAudioEngine wrapper for the live soundboard.
///
/// Architecture:
///
///   [AVAudioPlayerNode × N] ──► mainMixer ──► output (speakers)
///                                    │
///                                    └─► tap ──► soundboard.m4a (AAC)
///
/// * N player nodes (pool) so overlapping triggers don't cut each other
///   off — AVAudioPlayerNode can schedule multiple files in sequence but
///   only plays one at a time, so rapid-fire triggers of the same cue
///   need multiple players.
/// * The tap on `mainMixerNode` captures the summed soundboard output at
///   the mixer's native float32 format; `AVAudioFile(forWriting:)` with
///   AAC settings handles the PCM → AAC conversion internally.
/// * Mic + system audio capture are *not* involved here — those get
///   written by their own sidecar writers (`TrackWriter`). The editor
///   composition combines mic + system + soundboard as three parallel
///   audio tracks, and `FinalRenderer`'s `AVAssetReaderAudioMixOutput`
///   mixes them down to stereo AAC during export.
final class SoundboardEngine: @unchecked Sendable {
    /// Opaque identifier for a single `play(cue:)` invocation. Pass it
    /// back to `stop(handle:)` to cancel that playback instance
    /// specifically (without affecting other overlapping triggers of the
    /// same cue).
    struct PlayerHandle: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private let engine = AVAudioEngine()
    /// "tapMixer" — all player nodes feed this. We install the recording
    /// tap here so it captures the full mixed output regardless of what
    /// the speaker attenuation is doing downstream.
    private let tapMixer = AVAudioMixerNode()
    /// Speaker attenuation — setting `mainMixerNode.outputVolume` to 0
    /// silences the speakers without affecting `tapMixer` (and therefore
    /// the recording). `speakerOutputMuted` flips this.
    private var speakerMixer: AVAudioMixerNode { engine.mainMixerNode }

    /// Pool of player nodes. One node per slot; a cue trigger grabs a
    /// free node or evicts the oldest if all are busy.
    private let playerCount = 6
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayerIndex = 0

    private let stateLock = NSLock()
    private var started = false
    private var configObserver: NSObjectProtocol?

    /// When true, the speakers are silent but the recording tap (and any
    /// cue events still getting fired) continue uninterrupted. Useful
    /// during recording if the user isn't on headphones and doesn't
    /// want the mic to double-capture cues bleeding through.
    var speakerOutputMuted: Bool = false {
        didSet { speakerMixer.outputVolume = speakerOutputMuted ? 0 : 1 }
    }

    // In-flight handle → player mapping, so `stop(handle:)` can find
    // the right node even if a different cue has reused that slot since.
    private let handleLock = NSLock()
    private var activePlayers: [UUID: AVAudioPlayerNode] = [:]

    // Recording tap state
    private let tapLock = NSLock()
    private var recordingFile: AVAudioFile?
    private var tapInstalled = false
    /// Path of the intermediate CAF we write tap buffers into. Converted
    /// to AAC M4A at `stopRecordingTap()` and deleted.
    private var pendingCAFURL: URL?
    /// Target URL for the final M4A (sidecar `soundboard.m4a`).
    private var pendingOutputURL: URL?
    /// `systemUptime` of the first sample in the CAF — the first tap
    /// buffer's host time, falling back to install time. The tap starts
    /// before screen capture is up, so stop trims the difference.
    private var tapStartUptime: TimeInterval?
    /// Recording pauses, in `systemUptime` seconds (end nil while still
    /// paused). Tap audio inside them is dropped so soundboard.m4a is
    /// retimed exactly like the other tracks — it used to keep recording
    /// through pauses and drift later by the total paused time.
    private var pauseIntervals: [(start: TimeInterval, end: TimeInterval?)] = []
    /// Built lazily when the mixer's format stops matching the CAF's.
    private var tapConverter: AVAudioConverter?

    // MARK: - Lifecycle

    /// Idempotent — safe to call repeatedly. Attaches + connects the
    /// player pool on first start, then starts the engine.
    func start() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        if started { return }

        // Build the graph once. We deliberately insert `tapMixer` between
        // the player nodes and the main (speaker) mixer so the recording
        // tap lives upstream of the speaker volume — i.e. muting speakers
        // does NOT mute the recording.
        //
        //   players ──► tapMixer ──► mainMixer ──► outputNode
        //                  │
        //                  └─► recording tap
        if players.isEmpty {
            engine.attach(tapMixer)
            engine.connect(tapMixer, to: speakerMixer, format: nil)

            for _ in 0..<playerCount {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                // Passing `format: nil` lets the engine pick a format that
                // bridges to the mixer without a resample step at connect
                // time; per-file resampling happens at scheduleFile.
                engine.connect(player, to: tapMixer, format: nil)
                players.append(player)
            }
        }

        try engine.start()
        started = true

        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                self?.handleConfigurationChange()
            }
        }
    }

    /// An output-device change (AirPods connecting, switching speakers)
    /// stops the engine. Nothing restarted it, so the next cue called
    /// `play()` on a stopped engine — which raises an Objective-C
    /// exception Swift can't catch. Restart it; if that fails, mark it
    /// stopped so `play()` refuses cleanly.
    private func handleConfigurationChange() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard started, !engine.isRunning else { return }
        do {
            try engine.start()
            MentorDebug.log("SOUNDBOARD: engine restarted after configuration change")
        } catch {
            started = false
            MentorDebug.log("SOUNDBOARD: engine restart after configuration change failed: \(error)")
        }
    }

    /// The engine's real state, not just our flag — a configuration
    /// change can stop it underneath us.
    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return started && engine.isRunning
    }

    // MARK: - Playback

    /// Play `cue` through a free player node. Non-throwing; failures are
    /// logged and swallowed since playback is triggered from a hotkey
    /// handler that shouldn't crash the app if a file's missing.
    ///
    /// Returns a handle that callers can hand back to `stop(handle:)` to
    /// cancel this specific playback instance — useful for the
    /// Soundboard window's play/stop toggle. `onComplete` fires on the
    /// main queue when playback ends (naturally or via `stop(handle:)`).
    /// The handle is removed from the engine's internal map before
    /// `onComplete` runs.
    @discardableResult
    func play(cue: SoundCue, onComplete: (@MainActor () -> Void)? = nil) -> PlayerHandle? {
        guard isRunning else {
            MentorDebug.log("SOUNDBOARD: play called while engine not running")
            return nil
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: cue.fileURL)
        } catch {
            MentorDebug.log("SOUNDBOARD: can't open \(cue.fileURL.lastPathComponent): \(error)")
            return nil
        }

        let player = nextPlayer()
        player.volume = cue.volume
        // Stop anything currently scheduled so overlapping triggers of
        // the SAME slot don't queue up beyond the first file.
        player.stop()

        let handle = PlayerHandle(id: UUID())
        handleLock.lock()
        activePlayers[handle.id] = player
        handleLock.unlock()

        // `scheduleFile`'s completion fires once — either when the buffer
        // is fully consumed OR when `stop()` cuts it short. Either way we
        // want to drop the handle and notify the caller.
        player.scheduleFile(file, at: nil) { [weak self] in
            guard let self else { return }
            self.handleLock.lock()
            self.activePlayers.removeValue(forKey: handle.id)
            self.handleLock.unlock()
            if let onComplete {
                DispatchQueue.main.async { onComplete() }
            }
        }
        player.play()
        return handle
    }

    /// Cancel the playback associated with `handle`. No-op if already
    /// finished. The `onComplete` callback passed to `play` will fire
    /// shortly after as a result of the underlying stop.
    func stop(handle: PlayerHandle) {
        handleLock.lock()
        let player = activePlayers[handle.id]
        handleLock.unlock()
        player?.stop()
    }

    /// Round-robin through the player pool. Prefer idle players; fall
    /// back to rotating through if all are busy.
    private func nextPlayer() -> AVAudioPlayerNode {
        if let idle = players.first(where: { !$0.isPlaying }) {
            return idle
        }
        let p = players[nextPlayerIndex % players.count]
        nextPlayerIndex += 1
        return p
    }

    // MARK: - Recording tap

    /// Start writing the mixer's output to `outputURL` (AAC in an M4A
    /// container). Call once per recording session. If the engine isn't
    /// already running it'll be started — the tap captures silent
    /// samples between cues so timing lines up with the other audio
    /// tracks.
    ///
    /// Two-step encoding: the tap writes into an intermediate `.caf`
    /// at the mixer's **native** PCM format, then `stopRecordingTap()`
    /// re-encodes to AAC offline. Writing AAC directly via
    /// `AVAudioFile` turns out to be fragile — its internal encoder
    /// rejects the non-interleaved float32 layout the main mixer
    /// delivers by default (`AudioConverterSetProperty` returns
    /// `fmt?`). The two-step CAF path sidesteps this and matches
    /// exactly how we handle audio in `FinalRenderer`.
    func startRecordingTap(outputURL: URL) throws {
        try start()

        tapLock.lock()
        defer { tapLock.unlock() }
        guard !tapInstalled else { return }

        let tempCAF = outputURL.deletingPathExtension().appendingPathExtension("caf")
        try? FileManager.default.removeItem(at: tempCAF)

        let tapFormat = tapMixer.outputFormat(forBus: 0)
        // AVAudioFile picks container format from the URL extension.
        // `.caf` + a PCM settings dict = native PCM storage, which
        // `write(from:)` can append to without any encoder work.
        let file = try AVAudioFile(forWriting: tempCAF, settings: tapFormat.settings)
        recordingFile = file
        pendingCAFURL = tempCAF
        pendingOutputURL = outputURL
        tapStartUptime = nil
        pauseIntervals = []
        tapConverter = nil
        let installUptime = ProcessInfo.processInfo.systemUptime

        tapMixer.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, when in
            self?.write(buffer: buffer, when: when, installUptime: installUptime)
        }
        tapInstalled = true
    }

    /// Close the tap, then asynchronously transcode the captured CAF
    /// into the destination M4A. Awaitable — callers wait until the
    /// final M4A exists before the sidecar bundle is considered
    /// complete, so the post-capture render sees it.
    ///
    /// `origin` is the recording's shared time zero (first screen frame,
    /// `systemUptime` seconds). Audio before it is trimmed so the track
    /// starts in sync with `screen.mov` like every other track.
    func stopRecordingTap(timeOriginUptime origin: TimeInterval? = nil) async {
        tapLock.lock()
        let cafURL = pendingCAFURL
        let outURL = pendingOutputURL
        let wasInstalled = tapInstalled
        let lead: TimeInterval = {
            guard let origin, let start = tapStartUptime else { return 0 }
            return max(0, origin - start)
        }()
        tapStartUptime = nil
        pauseIntervals = []
        tapConverter = nil
        // Releasing the AVAudioFile flushes + closes the CAF output.
        recordingFile = nil
        pendingCAFURL = nil
        pendingOutputURL = nil
        tapInstalled = false
        tapLock.unlock()

        if wasInstalled {
            tapMixer.removeTap(onBus: 0)
        }

        guard let cafURL, let outURL else { return }
        await Self.transcode(cafURL: cafURL, toM4A: outURL, leadingTrim: lead)
        try? FileManager.default.removeItem(at: cafURL)
    }

    /// Mirror the recording's pause state. Called alongside the capture
    /// coordinator's pause/resume.
    func setRecordingPaused(_ paused: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        tapLock.lock(); defer { tapLock.unlock() }
        guard recordingFile != nil else { return }
        if paused {
            if pauseIntervals.last.map({ $0.end != nil }) ?? true {
                pauseIntervals.append((now, nil))
            }
        } else if let last = pauseIntervals.last, last.end == nil {
            pauseIntervals[pauseIntervals.count - 1].end = now
        }
    }

    private func write(buffer: AVAudioPCMBuffer, when: AVAudioTime, installUptime: TimeInterval) {
        tapLock.lock(); defer { tapLock.unlock() }
        guard let file = recordingFile else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let rate = buffer.format.sampleRate
        // Host time and systemUptime share mach_absolute_time's base.
        let bufferStart = when.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: when.hostTime)
            : ProcessInfo.processInfo.systemUptime - Double(frames) / rate
        if tapStartUptime == nil {
            tapStartUptime = when.isHostTimeValid ? bufferStart : installUptime
        }
        // Drop exactly the frames that fall inside a pause — whole-buffer
        // decisions would be off by up to a buffer (~85 ms) per pause.
        for range in keptFrames(bufferStart: bufferStart, frames: frames, rate: rate) {
            if range.count == frames {
                writeToFile(buffer, file)
            } else if let piece = buffer.copyFrames(range) {
                writeToFile(piece, file)
            }
        }
    }

    private func keptFrames(bufferStart: TimeInterval, frames: Int, rate: Double) -> [Range<Int>] {
        var kept: [Range<Int>] = [0..<frames]
        for pause in pauseIntervals {
            let lo = Int(((pause.start - bufferStart) * rate).rounded())
            let hi = pause.end.map { Int((($0 - bufferStart) * rate).rounded()) } ?? frames
            guard hi > 0, lo < frames, hi > lo else { continue }
            kept = kept.flatMap { r -> [Range<Int>] in
                let beforeEnd = min(r.upperBound, max(r.lowerBound, lo))
                let afterStart = max(r.lowerBound, min(r.upperBound, hi))
                return [r.lowerBound..<beforeEnd, afterStart..<r.upperBound].filter { !$0.isEmpty }
            }
        }
        return kept
    }

    /// The mixer's format can change mid-recording — an output-device
    /// switch (AirPods dropping to a lower sample rate) reconfigures the
    /// graph — but the CAF keeps the format it was opened with, and
    /// AVAudioFile rejects mismatched buffers. Convert when they differ.
    private func writeToFile(_ buffer: AVAudioPCMBuffer, _ file: AVAudioFile) {
        var output = buffer
        if buffer.format != file.processingFormat {
            if tapConverter?.inputFormat != buffer.format {
                tapConverter = AVAudioConverter(from: buffer.format, to: file.processingFormat)
            }
            let ratio = file.processingFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
            guard let converter = tapConverter,
                  let converted = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                MentorDebug.log("SOUNDBOARD: no converter for tap format change")
                return
            }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error else {
                MentorDebug.log("SOUNDBOARD: tap conversion failed: \(conversionError?.localizedDescription ?? "unknown")")
                return
            }
            output = converted
        }
        do {
            try file.write(from: output)
        } catch {
            // Swallow — throwing from the audio thread would tear down
            // the tap.
            MentorDebug.log("SOUNDBOARD: tap write failed: \(error)")
        }
    }

    // MARK: - CAF → M4A transcode

    /// Re-encode the intermediate CAF as AAC in an M4A container.
    /// Uses AVAssetReader + AVAssetWriter — the same pattern
    /// `FinalRenderer` uses for its audio pump, so AAC encoder
    /// behaviour is consistent with the rest of the pipeline.
    private static func transcode(cafURL: URL, toM4A m4aURL: URL, leadingTrim: TimeInterval = 0) async {
        try? FileManager.default.removeItem(at: m4aURL)

        let asset = AVURLAsset(url: cafURL)
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            MentorDebug.log("SOUNDBOARD: transcode loadTracks failed: \(error)")
            return
        }
        guard let track = audioTracks.first else {
            MentorDebug.log("SOUNDBOARD: transcode — CAF has no audio track")
            return
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            MentorDebug.log("SOUNDBOARD: transcode reader init failed: \(error)")
            return
        }

        // Pull samples out as standard 48kHz S16 stereo PCM — matches
        // what the AAC encoder in the writer wants to see.
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            MentorDebug.log("SOUNDBOARD: transcode can't add reader output")
            return
        }
        reader.add(readerOutput)
        let trimStart = CMTime(seconds: leadingTrim, preferredTimescale: 48_000)
        if leadingTrim > 0 {
            reader.timeRange = CMTimeRange(start: trimStart, duration: .positiveInfinity)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(url: m4aURL, fileType: .m4a)
        } catch {
            MentorDebug.log("SOUNDBOARD: transcode writer init failed: \(error)")
            return
        }
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            MentorDebug.log("SOUNDBOARD: transcode can't add writer input")
            return
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            MentorDebug.log("SOUNDBOARD: transcode writer.startWriting failed: \(writer.error?.localizedDescription ?? "nil")")
            return
        }
        guard reader.startReading() else {
            MentorDebug.log("SOUNDBOARD: transcode reader.startReading failed: \(reader.error?.localizedDescription ?? "nil")")
            return
        }
        // Session starts at the trim point so the M4A's t=0 is the
        // recording's time origin.
        writer.startSession(atSourceTime: leadingTrim > 0 ? trimStart : .zero)

        let queue = DispatchQueue(label: "com.darrell.mentor.soundboard-transcode", qos: .userInitiated)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sample)
                    } else {
                        writerInput.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }

        await writer.finishWriting()
        if writer.status != .completed {
            MentorDebug.log("SOUNDBOARD: transcode failed — writer status \(writer.status.rawValue), error=\(writer.error?.localizedDescription ?? "nil")")
        }
    }
}

private extension AVAudioPCMBuffer {
    /// Copy of `range`'s frames in the same format. Works for interleaved
    /// and non-interleaved PCM: `mBytesPerFrame` is per buffer, which is
    /// one channel when non-interleaved and all channels when interleaved.
    func copyFrames(_ range: Range<Int>) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)) else {
            return nil
        }
        copy.frameLength = AVAudioFrameCount(range.count)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(source, destination) {
            guard let from = src.mData, let to = dst.mData else { return nil }
            memcpy(to, from + range.lowerBound * bytesPerFrame, range.count * bytesPerFrame)
        }
        return copy
    }
}
