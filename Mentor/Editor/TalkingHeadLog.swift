import Foundation

/// Manual talking-head keyframes the user has added in the editor.
/// Persisted alongside the other sidecar logs so they survive editor
/// sessions — unlike smart-zoom keyframes (which are regenerated from
/// the click log) or cursor ripples (likewise), talking-head moments
/// are pure user intent and can't be recomputed from anything else.
///
/// Written to `talking-head.json` in the `.mentor` bundle on every
/// change. Small file; cheap to rewrite.
struct TalkingHeadLog: Codable {
    let version: Int
    let keyframes: [TalkingHeadKeyframe]

    static let empty = TalkingHeadLog(version: 1, keyframes: [])
}
