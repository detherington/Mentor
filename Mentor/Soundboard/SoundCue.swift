import Foundation

/// One entry in the live soundboard: a short audio file, optionally
/// bound to a global hotkey, with per-cue volume. Persisted verbatim in
/// `Settings.shared.soundboardCues`. Cues are **global** — the same list
/// of cues is used across every recording.
struct SoundCue: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var name: String
    var fileURL: URL
    var hotkey: CueHotkey?
    /// Playback gain, 0...1.5. Above 1.0 is explicit amplification;
    /// AVAudioPlayerNode accepts values up to ~12.0 but it's easy to
    /// clip the mix past 1.5× with short sharp cues.
    var volume: Float

    init(
        id: UUID = UUID(),
        name: String,
        fileURL: URL,
        hotkey: CueHotkey? = nil,
        volume: Float = 1.0
    ) {
        self.id = id
        self.name = name
        self.fileURL = fileURL
        self.hotkey = hotkey
        self.volume = volume
    }
}
