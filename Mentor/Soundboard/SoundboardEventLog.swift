import Foundation

/// Per-recording log of which soundboard cues fired during capture +
/// when. Persisted as `soundboard-events.json` in the `.mentor` sidecar
/// alongside `events.json`. Used by the editor timeline to draw
/// cue markers so the user can see — and seek to — each trigger.
///
/// Only cues fired via hotkey during active recording go in here.
/// Test-plays from the Soundboard window and any cues played while not
/// recording are ignored.
struct SoundboardEventLog: Codable {
    let version: Int
    let startDate: Date
    let events: [Fired]

    struct Fired: Codable {
        /// Seconds from recording start.
        let t: TimeInterval
        let cueID: UUID
        /// Snapshot of the cue's display name at fire time so the timeline
        /// marker's tooltip stays meaningful even if the cue is renamed or
        /// deleted later.
        let cueName: String
    }
}
