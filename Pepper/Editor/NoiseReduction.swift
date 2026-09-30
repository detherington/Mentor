import Foundation

/// Strength preset for offline mic noise reduction. Maps to a
/// `MicCleaner.Settings` struct at generation time; persisted here as
/// the enum so the user's chosen preset survives across recordings.
enum NoiseReductionStrength: String, Codable, Equatable, CaseIterable, Identifiable {
    /// 80 Hz high-pass + a gentle adaptive gate 6 dB above the learned
    /// noise floor. Catches AC hum and room tone without biting into
    /// quiet speech.
    case light
    /// 110 Hz high-pass + a steeper adaptive gate 10 dB above the
    /// learned floor. Cleaner on noisier rooms / bassier mics, at
    /// higher risk of clipping the tails of soft words.
    case strong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light:  return "Light"
        case .strong: return "Strong"
        }
    }

    var cleanerSettings: MicCleaner.Settings {
        switch self {
        case .light:  return .light
        case .strong: return .strong
        }
    }
}

/// Persisted user preference for noise reduction. `enabled` drives the
/// editor's "should I use the cleaned mic file or the raw one?" check.
/// `strength` is stored even when disabled so flipping back on remembers
/// the last preset.
struct NoiseReductionStyle: Codable, Equatable, Sendable {
    var enabled: Bool
    var strength: NoiseReductionStrength

    static let `default` = NoiseReductionStyle(
        enabled: false,
        strength: .light
    )
}
