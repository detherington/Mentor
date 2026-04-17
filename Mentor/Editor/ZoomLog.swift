import Foundation

/// Persisted list of zoom keyframes for a single recording. On first
/// editor open the keyframes come from `ZoomKeyframeGenerator` (auto-
/// derived from `events.json`); after that, the user's edits are
/// preserved here and the generator isn't re-run unless the user
/// explicitly asks to regenerate.
///
/// Written to `zoom.json` in the `.mentor` bundle. Small file; rewritten
/// on every mutation.
struct ZoomLog: Codable {
    let version: Int
    let keyframes: [ZoomKeyframe]

    static let empty = ZoomLog(version: 1, keyframes: [])
}
