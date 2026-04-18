import CoreGraphics
import Foundation

/// User-facing knobs for smart-zoom generation. Maps to the richer
/// `ZoomKeyframeGenerator.Config` via `config()`. Persisted across
/// recordings so "your zooms look like your zooms" — if you lowered
/// the peak scale last session, the next regenerate keeps that.
struct ZoomTuning: Codable, Equatable, Sendable {
    enum Sensitivity: String, Codable, Equatable, CaseIterable, Identifiable {
        /// Conservative — longer cluster window, fewer keyframes.
        /// Good when you click around exploring before settling on
        /// the action, and don't want every drift to produce a zoom.
        case low
        /// Default — 1.5 s / 300 px cluster window.
        case medium
        /// Aggressive — tight cluster window, zooms on just about
        /// every isolated click. Good for precise UI walkthroughs.
        case high

        var id: String { rawValue }

        var label: String {
            switch self {
            case .low:    return "Low"
            case .medium: return "Medium"
            case .high:   return "High"
            }
        }

        /// Maps the preset to the underlying `timeWindow` + `spaceWindow`
        /// pair. `timeWindow` dominates the "feels like one gesture?"
        /// judgment; `spaceWindow` is its complement in pixel space.
        fileprivate var clusterWindows: (time: TimeInterval, space: CGFloat) {
            switch self {
            case .low:    return (3.0, 600)
            case .medium: return (1.5, 300)
            case .high:   return (0.6, 150)
            }
        }
    }

    /// Peak zoom scale. 1.0 = no zoom. 1.5 ≈ Loom default. Anything
    /// above ~2.0 starts to visibly blur pixels at retina capture.
    var scale: CGFloat
    /// Seconds the camera holds at peak after the last click in a
    /// cluster. Drives `trailOut`; the lead-in side uses a fixed
    /// 0.3 s so the zoom is already settled when the action happens.
    var holdSeconds: TimeInterval
    /// Cluster-density preset. Controls how readily adjacent clicks
    /// get merged into a single zoom moment.
    var sensitivity: Sensitivity

    static let `default` = ZoomTuning(
        scale: 1.5,
        holdSeconds: 0.5,
        sensitivity: .medium
    )

    /// Build the full generator config from the user-facing subset,
    /// folding in the non-tunable defaults for everything else.
    func config() -> ZoomKeyframeGenerator.Config {
        var c = ZoomKeyframeGenerator.Config.default
        c.scale = scale
        c.trailOut = holdSeconds
        let windows = sensitivity.clusterWindows
        c.timeWindow = windows.time
        c.spaceWindow = windows.space
        return c
    }
}
