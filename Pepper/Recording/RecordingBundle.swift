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
    /// The bundle's extension, declared as `com.darrell.pepper.recording`.
    static let fileExtension = "pepper"

    /// Whether `url` names a recording bundle the editor can open.
    static func isRecording(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
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

// MARK: - Titles

extension RecordingBundle {
    /// When a recording was made, read from its bundle's name
    /// ("Pepper_2026-10-02_12-59-36"); nil for a renamed bundle.
    static func recordedDate(_ url: URL) -> Date? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("Pepper_") else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return parser.date(from: String(stem.dropFirst("Pepper_".count)))
    }

    /// "Today, 12:59 PM", "Sep 29, 10:05 PM", or with the year when it
    /// isn't this one: for editor window titles and the main window's
    /// tiles, which showed the raw file name. A renamed bundle keeps its
    /// own name.
    static func displayTitle(_ url: URL) -> String {
        guard let date = recordedDate(url) else { return url.deletingPathExtension().lastPathComponent }
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        let day = date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
        return "\(day), \(time)"
    }

    /// The rendered video beside the bundle, if there is one.
    static func videoFile(of url: URL) -> URL? {
        let mp4 = url.deletingPathExtension().appendingPathExtension("mp4")
        return FileManager.default.fileExists(atPath: mp4.path) ? mp4 : nil
    }
}
