import AVFoundation
import CoreMedia

/// Builds the `AVMutableComposition` + `AVMutableVideoComposition` that both
/// the editor (for live preview) and the renderer (for post-capture
/// encoding) operate on. The composition combines raw screen + webcam
/// tracks with audio pulled from the sidecar `mic.m4a` + `system.m4a`.
enum EditorComposition {
    struct Result {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let duration: CMTime
        let screenTrackID: CMPersistentTrackID
        let webcamTrackID: CMPersistentTrackID
        /// Per-audio-track IDs so callers can build an `AVAudioMix` with
        /// per-track volumes. `kCMPersistentTrackID_Invalid` when the
        /// corresponding sidecar audio file didn't exist in the bundle.
        let micTrackID: CMPersistentTrackID
        let systemTrackID: CMPersistentTrackID
        let soundboardTrackID: CMPersistentTrackID
    }

    enum Error: Swift.Error, LocalizedError {
        case missingScreenTrack
        case cannotAddTrack(String)

        var errorDescription: String? {
            switch self {
            case .missingScreenTrack: return "screen.mov has no video track."
            case .cannotAddTrack(let name): return "Couldn't add \(name) track to composition."
            }
        }
    }

    static func build(for project: RecordingProject) async throws -> Result {
        try await build(bundle: project.bundle, metadata: project.metadata)
    }

    /// Lower-level builder that only needs the bundle layout + metadata —
    /// used by the renderer, which doesn't need a full `RecordingProject`.
    static func build(
        bundle: RecordingBundle,
        metadata: RecordingMetadata
    ) async throws -> Result {
        let screenAsset = AVURLAsset(url: bundle.screenVideoURL)
        let webcamAsset = AVURLAsset(url: bundle.webcamVideoURL)
        let micAsset    = AVURLAsset(url: bundle.micAudioURL)
        let systemAsset = AVURLAsset(url: bundle.systemAudioURL)

        async let screenVideoTracks = screenAsset.loadTracks(withMediaType: .video)
        async let screenDuration    = screenAsset.load(.duration)
        async let webcamVideoTracks = webcamAsset.loadTracks(withMediaType: .video)
        async let webcamDuration    = webcamAsset.load(.duration)

        let screenTracks = try await screenVideoTracks
        guard let screenTrack = screenTracks.first else {
            throw Error.missingScreenTrack
        }
        let sDuration = try await screenDuration
        let timeRange = CMTimeRange(start: .zero, duration: sDuration)

        let composition = AVMutableComposition()

        // Screen video
        guard let screenCompTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw Error.cannotAddTrack("screen") }
        try screenCompTrack.insertTimeRange(timeRange, of: screenTrack, at: .zero)

        // Webcam video (optional)
        var webcamTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        if let webcamTrack = try await webcamVideoTracks.first {
            if let webcamCompTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                let wcDuration = try await webcamDuration
                let wcRange = CMTimeRange(
                    start: .zero,
                    duration: CMTimeMinimum(wcDuration, sDuration)
                )
                try webcamCompTrack.insertTimeRange(wcRange, of: webcamTrack, at: .zero)
                webcamTrackID = webcamCompTrack.trackID
            }
        }

        // Audio from sidecar files (mic + optional system + optional soundboard).
        // Keep per-track IDs so the editor can build an AVAudioMix with
        // per-track volume balance.
        var micID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        var systemID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        var soundboardID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

        if FileManager.default.fileExists(atPath: bundle.micAudioURL.path) {
            if let micTrack = try? await micAsset.loadTracks(withMediaType: .audio).first,
               let micCompTrack = composition.addMutableTrack(
                   withMediaType: .audio,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                let micDuration = (try? await micAsset.load(.duration)) ?? sDuration
                let range = CMTimeRange(start: .zero, duration: CMTimeMinimum(micDuration, sDuration))
                try? micCompTrack.insertTimeRange(range, of: micTrack, at: .zero)
                micID = micCompTrack.trackID
            }
        }
        if FileManager.default.fileExists(atPath: bundle.systemAudioURL.path) {
            if let sysTrack = try? await systemAsset.loadTracks(withMediaType: .audio).first,
               let sysCompTrack = composition.addMutableTrack(
                   withMediaType: .audio,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                let sysDuration = (try? await systemAsset.load(.duration)) ?? sDuration
                let range = CMTimeRange(start: .zero, duration: CMTimeMinimum(sysDuration, sDuration))
                try? sysCompTrack.insertTimeRange(range, of: sysTrack, at: .zero)
                systemID = sysCompTrack.trackID
            }
        }

        // Soundboard track — only present if the user had at least one
        // cue configured at recording time. `FinalRenderer`'s mix output
        // reads every audio track and sums them into the export.
        if FileManager.default.fileExists(atPath: bundle.soundboardAudioURL.path) {
            let soundboardAsset = AVURLAsset(url: bundle.soundboardAudioURL)
            if let sbTrack = try? await soundboardAsset.loadTracks(withMediaType: .audio).first,
               let sbCompTrack = composition.addMutableTrack(
                   withMediaType: .audio,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                let sbDuration = (try? await soundboardAsset.load(.duration)) ?? sDuration
                let range = CMTimeRange(start: .zero, duration: CMTimeMinimum(sbDuration, sDuration))
                try? sbCompTrack.insertTimeRange(range, of: sbTrack, at: .zero)
                soundboardID = sbCompTrack.trackID
            }
        }

        // Video composition wiring.
        let outputSize = CGSize(
            width: metadata.compositedPixelSize.width,
            height: metadata.compositedPixelSize.height
        )
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.customVideoCompositorClass = LiveCompositor.self

        let instruction = LiveCompositor.Instruction(
            timeRange: timeRange,
            screenTrackID: screenCompTrack.trackID,
            webcamTrackID: webcamTrackID
        )
        videoComposition.instructions = [instruction]

        MentorDebug.log("COMPOSE: built — renderSize=\(outputSize), screenID=\(screenCompTrack.trackID), webcamID=\(webcamTrackID), duration=\(CMTimeGetSeconds(sDuration))s")

        return Result(
            composition: composition,
            videoComposition: videoComposition,
            duration: sDuration,
            screenTrackID: screenCompTrack.trackID,
            webcamTrackID: webcamTrackID,
            micTrackID: micID,
            systemTrackID: systemID,
            soundboardTrackID: soundboardID
        )
    }

    static func makePlayerItem(from result: Result) -> AVPlayerItem {
        let item = AVPlayerItem(asset: result.composition)
        item.videoComposition = result.videoComposition
        return item
    }
}

