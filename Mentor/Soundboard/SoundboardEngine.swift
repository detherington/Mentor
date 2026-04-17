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
///   written by their own sidecar writers (`AudioWriter`). The editor
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
    }

    func stop() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard started else { return }
        // Stop any in-flight players before shutting the engine down,
        // otherwise they emit a short click.
        for p in players where p.isPlaying {
            p.stop()
        }
        engine.stop()
        started = false
    }

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return started
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

        tapMixer.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            self?.write(buffer: buffer)
        }
        tapInstalled = true
    }

    /// Close the tap, then asynchronously transcode the captured CAF
    /// into the destination M4A. Awaitable — callers wait until the
    /// final M4A exists before the sidecar bundle is considered
    /// complete, so the post-capture render sees it.
    func stopRecordingTap() async {
        tapLock.lock()
        let cafURL = pendingCAFURL
        let outURL = pendingOutputURL
        let wasInstalled = tapInstalled
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
        await Self.transcode(cafURL: cafURL, toM4A: outURL)
        try? FileManager.default.removeItem(at: cafURL)
    }

    private func write(buffer: AVAudioPCMBuffer) {
        tapLock.lock(); defer { tapLock.unlock() }
        guard let file = recordingFile else { return }
        do {
            try file.write(from: buffer)
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
    private static func transcode(cafURL: URL, toM4A m4aURL: URL) async {
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
        writer.startSession(atSourceTime: .zero)

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
