import Foundation

/// Preset bundles for the editor's export quality picker. Keeps the UI
/// to a single one-dimensional choice instead of exposing raw bitrates.
/// All three presets keep source resolution — only bitrate varies —
/// since downscaling would require re-plumbing the compositor's output
/// size, which the baseline pipeline treats as fixed.
enum ExportQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    /// Target H.264 average bitrate in bits per second.
    var bitrate: Int {
        switch self {
        case .low:    return 4_000_000
        case .medium: return 8_000_000
        case .high:   return 12_000_000
        }
    }

    /// Label for the Export save panel's Quality menu.
    var label: String {
        switch self {
        case .low:    return "Smaller file"
        case .medium: return "Standard"
        case .high:   return "Best"
        }
    }

    /// Expected file size per minute at 1080p60. Rough heuristic — AAC
    /// audio adds ~1.5 MB/min on top.
    var sizeHint: String {
        switch self {
        case .low:    return "About 30 MB a minute"
        case .medium: return "About 60 MB a minute"
        case .high:   return "About 90 MB a minute"
        }
    }
}
