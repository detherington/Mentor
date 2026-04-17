import Foundation
import CoreMedia

/// Opacity envelope for the webcam overlay: fades from transparent to
/// opaque over `fadeIn` at the start of the recording, and from opaque to
/// transparent over `fadeOut` at the end. A duration of 0 disables that
/// side; a duration of >= half the total clip is clamped to half so a
/// short trim never collapses to "always invisible".
struct WebcamTransitions: Equatable, Codable, Sendable {
    var fadeIn: TimeInterval
    var fadeOut: TimeInterval

    static let `default` = WebcamTransitions(fadeIn: 0.5, fadeOut: 0.5)
    static let none      = WebcamTransitions(fadeIn: 0,   fadeOut: 0)

    /// Effective alpha (0...1) for the webcam at composition time `t`,
    /// given a total composition duration. Caller multiplies this into the
    /// webcam image's alpha channel before compositing.
    func alpha(at t: CMTime, totalDuration: CMTime) -> CGFloat {
        let secs  = CMTimeGetSeconds(t)
        let total = CMTimeGetSeconds(totalDuration)
        guard secs.isFinite, total.isFinite, total > 0 else { return 1 }

        // Clamp each half so a 1-second clip with 2-second fades doesn't
        // leave the webcam permanently invisible.
        let halfTotal = total / 2
        let inDur  = max(0, min(fadeIn, halfTotal))
        let outDur = max(0, min(fadeOut, halfTotal))

        var a: CGFloat = 1
        if inDur > 0, secs < inDur {
            a = min(a, CGFloat(secs / inDur))
        }
        if outDur > 0, secs > total - outDur {
            // Compress the fade so it reaches alpha=0 by `endMargin` before
            // the actual end. Otherwise the very last rendered frame (whose
            // PTS is total - 1/fps, not total exactly) shows a small
            // residual alpha that's noticeable on short fades.
            let endMargin = WebcamTransitions.endMargin
            let effectiveOut = max(outDur - endMargin, outDur * 0.5)
            let into = secs - (total - outDur)
            let p = min(1, into / effectiveOut)
            a = min(a, 1 - CGFloat(p))
        }
        return max(0, min(1, a))
    }

    /// Time before the end of the output at which a fade-out should be
    /// considered complete. Sized to comfortably exceed both 60fps frame
    /// duration (~17ms) and the editor's 30Hz periodic time observer tick
    /// (33ms), so any "last frame" the renderer or preview emits lands
    /// inside the fully-invisible window. Also reused by the end title
    /// card for the symmetric "doesn't quite reach full opacity" problem.
    static let endMargin: TimeInterval = 1.0 / 24.0
}
