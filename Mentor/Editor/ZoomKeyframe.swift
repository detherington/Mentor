import CoreMedia
import CoreGraphics
import Foundation

/// A single auto-generated zoom-in moment. Three phases:
///
///   ```
///   ┌───── inDuration ─────┐  ┌─── hold ───┐  ┌──── outDuration ────┐
///   1.0x  ─────►  scale (peak)  ──hold──    scale (peak)  ─────►  1.0x
///   startTime                              holdEndTime           endTime
///   ```
///
/// `target` is the focal point in **screen-image pixel coordinates**, with
/// origin at bottom-left to match Core Image's coordinate system. The
/// compositor uses it as the fixed point of the zoom transform.
struct ZoomKeyframe: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var startTime: CMTime          // composition time when zoom-in begins
    var inDuration: CMTime         // duration of zoom-in ramp
    var holdEndTime: CMTime        // composition time when zoom-out begins
    var outDuration: CMTime        // duration of zoom-out ramp
    var target: CGPoint            // image pixels, bottom-left origin
    var scale: CGFloat             // peak scale (e.g. 1.5)

    init(
        id: UUID = UUID(),
        startTime: CMTime,
        inDuration: CMTime,
        holdEndTime: CMTime,
        outDuration: CMTime,
        target: CGPoint,
        scale: CGFloat
    ) {
        self.id = id
        self.startTime = startTime
        self.inDuration = inDuration
        self.holdEndTime = holdEndTime
        self.outDuration = outDuration
        self.target = target
        self.scale = scale
    }

    // MARK: - Codable

    // CMTime + CGPoint aren't directly Codable in a sensible way; encode
    // the time values as TimeInterval (seconds) and the target as a pair
    // of Doubles. Rehydrate with a fixed 600 timescale on load, matching
    // the convention used elsewhere in the sidecar.
    private enum CodingKeys: String, CodingKey {
        case id
        case startSeconds
        case inSeconds
        case holdEndSeconds
        case outSeconds
        case targetX
        case targetY
        case scale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        let s  = try c.decode(TimeInterval.self, forKey: .startSeconds)
        let i  = try c.decode(TimeInterval.self, forKey: .inSeconds)
        let he = try c.decode(TimeInterval.self, forKey: .holdEndSeconds)
        let o  = try c.decode(TimeInterval.self, forKey: .outSeconds)
        self.startTime   = CMTime(seconds: s,  preferredTimescale: 600)
        self.inDuration  = CMTime(seconds: i,  preferredTimescale: 600)
        self.holdEndTime = CMTime(seconds: he, preferredTimescale: 600)
        self.outDuration = CMTime(seconds: o,  preferredTimescale: 600)
        let tx = try c.decode(Double.self, forKey: .targetX)
        let ty = try c.decode(Double.self, forKey: .targetY)
        self.target = CGPoint(x: tx, y: ty)
        self.scale = try c.decode(CGFloat.self, forKey: .scale)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CMTimeGetSeconds(startTime),   forKey: .startSeconds)
        try c.encode(CMTimeGetSeconds(inDuration),  forKey: .inSeconds)
        try c.encode(CMTimeGetSeconds(holdEndTime), forKey: .holdEndSeconds)
        try c.encode(CMTimeGetSeconds(outDuration), forKey: .outSeconds)
        try c.encode(Double(target.x), forKey: .targetX)
        try c.encode(Double(target.y), forKey: .targetY)
        try c.encode(scale, forKey: .scale)
    }

    /// End of the zoom-out ramp — anything past this is back at 1.0x.
    var endTime: CMTime { CMTimeAdd(holdEndTime, outDuration) }

    /// Composition-time range covered by this keyframe.
    var timeRange: CMTimeRange {
        CMTimeRange(start: startTime, end: endTime)
    }

    /// Peak time (start of the held plateau).
    var peakStartTime: CMTime { CMTimeAdd(startTime, inDuration) }

    /// `true` if `t` falls inside [startTime, endTime).
    func contains(_ t: CMTime) -> Bool {
        CMTimeCompare(t, startTime) >= 0 && CMTimeCompare(t, endTime) < 0
    }

    /// Effective scale at composition time `t`. Returns 1.0 outside the
    /// keyframe's range (caller should still gate on `contains`).
    func currentScale(at t: CMTime) -> CGFloat {
        let secs = CMTimeGetSeconds(t)
        let s    = CMTimeGetSeconds(startTime)
        let inS  = CMTimeGetSeconds(inDuration)
        let hS   = CMTimeGetSeconds(holdEndTime)
        let outS = CMTimeGetSeconds(outDuration)
        guard secs.isFinite else { return 1 }

        if secs < s { return 1 }
        if secs >= s + inS && secs <= hS { return scale }
        if secs > hS && secs < hS + outS {
            let p = (secs - hS) / max(outS, 0.0001)
            return ZoomKeyframe.lerp(scale, 1, ZoomKeyframe.easeInOutCubic(p))
        }
        if secs < s + inS {
            let p = (secs - s) / max(inS, 0.0001)
            return ZoomKeyframe.lerp(1, scale, ZoomKeyframe.easeInOutCubic(p))
        }
        return 1
    }

    // MARK: - Easing helpers

    /// Standard easeInOutCubic: slow at the edges, fast in the middle.
    /// Matches what feels natural for "Loom-style" zooms — no jump-in jolt.
    static func easeInOutCubic(_ p: Double) -> Double {
        let q = max(0, min(1, p))
        if q < 0.5 { return 4 * q * q * q }
        let f = -2 * q + 2
        return 1 - (f * f * f) / 2
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }
}
