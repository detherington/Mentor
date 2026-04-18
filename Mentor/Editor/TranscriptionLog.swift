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
struct TranscriptionLine: Identifiable, Codable, Equatable, Sendable {
    /// Stable identifier for SwiftUI list + edit tracking. Persisted so
    /// IDs survive disk round-trips and undo snapshots compare cleanly.
    /// Older on-disk transcriptions without an `id` field get a fresh
    /// UUID at decode time (see `init(from:)` below).
    let id: UUID
    var text: String
    var startSeconds: TimeInterval
    var endSeconds: TimeInterval

    init(
        id: UUID = UUID(),
        text: String,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval
    ) {
        self.id = id
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, startSeconds, endSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try c.decode(String.self, forKey: .text)
        self.startSeconds = try c.decode(TimeInterval.self, forKey: .startSeconds)
        self.endSeconds = try c.decode(TimeInterval.self, forKey: .endSeconds)
    }
}

/// Persisted subtitle track for a recording — written by
/// `CaptionTranscriber` when the user hits "Generate captions" and read
/// by the editor + compositor to render burned-in subtitles.
///
/// Stored as `transcription.json` in the `.mentor` sidecar. Re-running
/// generation overwrites the file. Editing keeps the same file in place
/// with updated `lines`.
struct TranscriptionLog: Codable, Equatable, Sendable {
    let version: Int
    let locale: String
    let createdAt: Date
    var lines: [TranscriptionLine]

    static let empty = TranscriptionLog(version: 1, locale: "en-US", createdAt: Date(), lines: [])
}
