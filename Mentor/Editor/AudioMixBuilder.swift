import AVFoundation

/// Small helper that produces an `AVAudioMix` with per-track volumes
/// given the audio-track IDs from an `EditorComposition.Result`. Used
/// by both the editor's live preview (set on `player.currentItem.audioMix`)
/// and the export path (set on `AVAssetReaderAudioMixOutput.audioMix`
/// inside `FinalRenderer`).
///
/// Missing tracks (IDs that equal `kCMPersistentTrackID_Invalid`) are
/// simply skipped — e.g. if the user didn't configure soundboard cues
/// at capture time, there's no soundboard track and no mix parameter
/// for one.
enum AudioMixBuilder {
    struct Volumes: Equatable, Codable, Sendable {
        var mic: Float
        var system: Float
        var soundboard: Float

        static let unity = Volumes(mic: 1, system: 1, soundboard: 1)
    }

    static func build(
        composition: AVMutableComposition,
        micTrackID: CMPersistentTrackID,
        systemTrackID: CMPersistentTrackID,
        soundboardTrackID: CMPersistentTrackID,
        volumes: Volumes
    ) -> AVAudioMix? {
        var params: [AVMutableAudioMixInputParameters] = []

        func addParam(trackID: CMPersistentTrackID, volume: Float) {
            guard trackID != kCMPersistentTrackID_Invalid else { return }
            guard let track = composition.track(withTrackID: trackID) else { return }
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(volume, at: .zero)
            params.append(p)
        }

        addParam(trackID: micTrackID,        volume: volumes.mic)
        addParam(trackID: systemTrackID,     volume: volumes.system)
        addParam(trackID: soundboardTrackID, volume: volumes.soundboard)

        guard !params.isEmpty else { return nil }

        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return mix
    }
}
