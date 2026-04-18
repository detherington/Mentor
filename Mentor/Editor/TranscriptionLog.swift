import Foundation

/// One displayable subtitle line — a grouping of consecutive words from
/// the speech recognizer that belong on screen at the same time.
///
/// Word-level segments from the legacy `SFSpeechRecognizer` path would
/// flash individually for every syllable boundary, which reads as
/// flicker. `CaptionTranscriber.groupIntoLines` collapses those words
/// into lines sized for human reading (up to ~40 chars / 4 seconds /
/// pauses longer than ~0.6s). The modern macOS 26 `SpeechAnalyzer`
/// path returns already-grouped `CMTimeRange` results, so line
/// grouping is only applied to the legacy + cloud paths.
struct TranscriptionLine: Codable, Equatable, Sendable {
    let text: String
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
}

/// Persisted subtitle track for a recording — written by
/// `CaptionTranscriber` when the user hits "Generate captions" and read
/// by the editor + compositor to render burned-in subtitles.
///
/// Stored as `transcription.json` in the `.mentor` sidecar. Re-running
/// generation overwrites the file.
struct TranscriptionLog: Codable, Equatable, Sendable {
    let version: Int
    let locale: String
    let createdAt: Date
    let lines: [TranscriptionLine]

    static let empty = TranscriptionLog(version: 1, locale: "en-US", createdAt: Date(), lines: [])
}
