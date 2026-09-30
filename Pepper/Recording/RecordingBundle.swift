import Foundation

/// Layout of the sidecar `.pepper` directory that accompanies each
/// composited recording. Editor v1 (Phase 3b) will read these files to
/// recompose videos with different webcam positions, smart-zoom keyframes,
/// trim points, etc.
///
/// Example on disk:
/// ```
/// ~/Movies/Pepper/
/// ├── Pepper_2026-04-17_12-34-56.mp4            ← composited final (shareable)
/// └── Pepper_2026-04-17_12-34-56.pepper/        ← sidecar directory
///     ├── screen.mov                            ← raw screen video (H.264)
///     ├── webcam.mov                            ← raw webcam video (H.264)
///     ├── events.json                           ← mouse / key / app-focus events
///     └── metadata.json                         ← recording config at capture time
/// ```
struct RecordingBundle {
    /// Extension for new recordings. Before the app was renamed Pepper
    /// (2.0) it wrote `.mentor`; those still open in the editor. Both
    /// share one document type, whose identifier keeps the old name
    /// (`com.darrell.mentor.recording`) so existing files stay associated.
    static let fileExtension = "pepper"
    static let legacyFileExtension = "mentor"

    /// Whether `url` names a recording bundle the editor can open.
    static func isRecording(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == fileExtension || ext == legacyFileExtension
    }

    let finalMP4URL: URL
    let sidecarURL: URL

    var screenVideoURL: URL     { sidecarURL.appendingPathComponent("screen.mov") }
    var webcamVideoURL: URL     { sidecarURL.appendingPathComponent("webcam.mov") }
    var micAudioURL: URL        { sidecarURL.appendingPathComponent("mic.m4a") }
    var systemAudioURL: URL     { sidecarURL.appendingPathComponent("system.m4a") }
    /// Mixed soundboard output, only written when the user has at least
    /// one `SoundCue` configured at recording time. Optional — absent
    /// bundles skip this track in the composition.
    var soundboardAudioURL: URL { sidecarURL.appendingPathComponent("soundboard.m4a") }
    var soundboardEventsURL: URL { sidecarURL.appendingPathComponent("soundboard-events.json") }
    var eventsURL: URL          { sidecarURL.appendingPathComponent("events.json") }
    var metadataURL: URL        { sidecarURL.appendingPathComponent("metadata.json") }
    /// Manual editor-side talking-head keyframes. Written by the editor
    /// only; missing in fresh recordings until the user adds one.
    var talkingHeadURL: URL     { sidecarURL.appendingPathComponent("talking-head.json") }
    /// Persisted zoom keyframes (auto-generated on first editor open,
    /// but preserved + editable after that).
    var zoomURL: URL            { sidecarURL.appendingPathComponent("zoom.json") }
    /// Trim, cuts and webcam layout from the editor (`EditState`).
    /// Written by the editor only; absent until the first edit.
    var editStateURL: URL       { sidecarURL.appendingPathComponent("edit-state.json") }
    /// Burned-in subtitles — populated the first time the user clicks
    /// "Generate captions" in the editor, and used verbatim on reopen.
    var transcriptionURL: URL   { sidecarURL.appendingPathComponent("transcription.json") }
    /// Per-frame cursor position samples (captured at 30 Hz during
    /// recording). Feeds the cursor-highlight halo overlay — absent
    /// in older recordings, in which case the overlay is unavailable
    /// for those bundles.
    var cursorLogURL: URL       { sidecarURL.appendingPathComponent("cursor.json") }
    /// Offline-generated cleaned mic track (highpass + noise gate).
    /// Only exists if the user has flipped noise reduction on for
    /// this recording; absent otherwise. CAF (PCM) rather than m4a
    /// so we skip an extra AAC re-encode round-trip — the final
    /// export writer compresses this in a single pass anyway.
    var cleanedMicAudioURL: URL { sidecarURL.appendingPathComponent("mic_cleaned.caf") }

    static func make(baseDirectory: URL, timestamp: Date = Date()) -> RecordingBundle {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stem = "Pepper_\(formatter.string(from: timestamp))"
        return RecordingBundle(
            finalMP4URL: baseDirectory.appendingPathComponent("\(stem).mp4"),
            sidecarURL: baseDirectory.appendingPathComponent("\(stem).\(fileExtension)", isDirectory: true)
        )
    }

    /// Create the sidecar directory (idempotent).
    func createSidecarDirectory() throws {
        try FileManager.default.createDirectory(
            at: sidecarURL,
            withIntermediateDirectories: true
        )
    }
}
