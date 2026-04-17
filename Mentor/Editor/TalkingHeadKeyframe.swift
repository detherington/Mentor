import CoreMedia
import CoreGraphics
import Foundation

/// A user-specified "talking head" moment: the webcam expands from its
/// normal corner position to a centred, large-format framing, holds for
/// `holdEndTime - startTime - inDuration` seconds, then shrinks back.
///
/// Shape mirrors `ZoomKeyframe` — same three-phase envelope (ramp in,
/// hold, ramp out) with `easeInOutCubic` easing — so the compositor's
/// per-frame activation logic feels consistent across features.
///
/// Not derived from events.json. User scrubs the timeline to a moment,
/// clicks "Add at playhead"; a default-sized keyframe lands there.
struct TalkingHeadKeyframe: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var startTime: CMTime
    var inDuration: CMTime
    var holdEndTime: CMTime
    var outDuration: CMTime
    /// Target webcam diameter as a fraction of the canvas's shorter
    /// side. 0.7 ≈ Loom-style "mostly webcam" talking head; 0.95 is
    /// "fills the frame short side nearly edge-to-edge".
    var targetDiameterFraction: CGFloat

    init(
        id: UUID = UUID(),
        startTime: CMTime,
        inDuration: CMTime = CMTime(seconds: 0.5, preferredTimescale: 600),
        holdEndTime: CMTime,
        outDuration: CMTime = CMTime(seconds: 0.5, preferredTimescale: 600),
        targetDiameterFraction: CGFloat = 0.7
    ) {
        self.id = id
        self.startTime = startTime
        self.inDuration = inDuration
        self.holdEndTime = holdEndTime
        self.outDuration = outDuration
        self.targetDiameterFraction = targetDiameterFraction
    }

    // MARK: - Codable

    // CMTime isn't directly Codable, so we serialize each time value as
    // TimeInterval (seconds) and re-hydrate with a fixed 600 timescale
    // on load — same convention the event log + soundboard log use.
    private enum CodingKeys: String, CodingKey {
        case id
        case startSeconds
        case inSeconds
        case holdEndSeconds
        case outSeconds
        case targetDiameterFraction
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        let s   = try c.decode(TimeInterval.self, forKey: .startSeconds)
        let i   = try c.decode(TimeInterval.self, forKey: .inSeconds)
        let he  = try c.decode(TimeInterval.self, forKey: .holdEndSeconds)
        let o   = try c.decode(TimeInterval.self, forKey: .outSeconds)
        self.startTime = CMTime(seconds: s, preferredTimescale: 600)
        self.inDuration = CMTime(seconds: i, preferredTimescale: 600)
        self.holdEndTime = CMTime(seconds: he, preferredTimescale: 600)
        self.outDuration = CMTime(seconds: o, preferredTimescale: 600)
        self.targetDiameterFraction = try c.decode(CGFloat.self, forKey: .targetDiameterFraction)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CMTimeGetSeconds(startTime),   forKey: .startSeconds)
        try c.encode(CMTimeGetSeconds(inDuration),  forKey: .inSeconds)
        try c.encode(CMTimeGetSeconds(holdEndTime), forKey: .holdEndSeconds)
        try c.encode(CMTimeGetSeconds(outDuration), forKey: .outSeconds)
        try c.encode(targetDiameterFraction, forKey: .targetDiameterFraction)
    }

    var endTime: CMTime { CMTimeAdd(holdEndTime, outDuration) }
    var peakStartTime: CMTime { CMTimeAdd(startTime, inDuration) }
    var timeRange: CMTimeRange { CMTimeRange(start: startTime, end: endTime) }

    func contains(_ t: CMTime) -> Bool {
        CMTimeCompare(t, startTime) >= 0 && CMTimeCompare(t, endTime) < 0
    }

    /// Progress 0...1 at composition time `t`. 0 outside the keyframe,
    /// 1 during the hold plateau, eased on the ramps.
    func progress(at time: CMTime) -> Double {
        let secs = CMTimeGetSeconds(time)
        let s    = CMTimeGetSeconds(startTime)
        let inS  = CMTimeGetSeconds(inDuration)
        let hS   = CMTimeGetSeconds(holdEndTime)
        let outS = CMTimeGetSeconds(outDuration)
        guard secs.isFinite else { return 0 }

        if secs < s { return 0 }
        if secs >= s + inS && secs <= hS { return 1 }
        if secs > hS && secs < hS + outS {
            let p = (secs - hS) / max(outS, 0.0001)
            return 1 - ZoomKeyframe.easeInOutCubic(p)
        }
        if secs < s + inS {
            let p = (secs - s) / max(inS, 0.0001)
            return ZoomKeyframe.easeInOutCubic(p)
        }
        return 0
    }
}
