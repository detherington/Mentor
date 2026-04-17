import CoreGraphics
import CoreMedia
import Foundation

/// A single click that should trigger a ripple animation. Generated from
/// `events.json` once at editor-load time; the compositor decides per
/// frame whether it's "active" (within `style.duration` of `time`).
struct CursorRipple: Identifiable, Equatable, Sendable {
    let id: UUID
    let time: CMTime
    let target: CGPoint   // image pixels, bottom-left origin

    init(id: UUID = UUID(), time: CMTime, target: CGPoint) {
        self.id = id
        self.time = time
        self.target = target
    }
}

/// Styling for cursor ripples. Shared across all ripples in a recording.
struct CursorRippleStyle: Equatable, Sendable {
    var enabled: Bool
    /// Lifetime of one ripple, in seconds. Ripple is fully invisible past this.
    var duration: TimeInterval
    var initialRadius: CGFloat        // image pixels
    var finalRadius: CGFloat          // image pixels
    var initialOpacity: CGFloat       // 0...1
    var strokeWidth: CGFloat          // image pixels
    var color: ColorRGBA

    static let `default` = CursorRippleStyle(
        enabled: true,
        duration: 0.55,
        initialRadius: 18,
        finalRadius: 96,
        initialOpacity: 0.7,
        strokeWidth: 5,
        color: ColorRGBA(red: 1.0, green: 0.92, blue: 0.35, alpha: 1.0)  // soft yellow
    )
}
