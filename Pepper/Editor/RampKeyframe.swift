import CoreMedia

/// Shape shared by zoom and talking-head keyframes: a ramp in, a hold,
/// a ramp out. Their timeline editing rules — where a new one fits, how
/// far one can move, how long its hold can stretch — are identical, so
/// they live here once instead of as parallel copies in the view model.
protocol RampKeyframe: Identifiable where ID == UUID {
    var startTime: CMTime { get set }
    var inDuration: CMTime { get }
    var holdEndTime: CMTime { get set }
    var outDuration: CMTime { get }
    var endTime: CMTime { get }
    var peakStartTime: CMTime { get }
}

extension ZoomKeyframe: RampKeyframe {}
extension TalkingHeadKeyframe: RampKeyframe {}

/// Editing rules over a list of non-overlapping ramp keyframes on a
/// timeline `duration` long. Each returns the updated list, or nil when
/// the edit changes nothing.
enum RampKeyframes {
    /// Shortest hold a keyframe may have. With 0.5 s ramps that makes the
    /// smallest keyframe worth placing 1.25 s.
    static let minHold = CMTime(seconds: 0.25, preferredTimescale: 600)

    /// The first gap at or after `time` at least `minTotal` long, with its
    /// length capped at `defaultTotal` — so "Add at playhead" skips past
    /// existing keyframes and shrinks to fit a small gap.
    static func nextSlot<K: RampKeyframe>(
        in keyframes: [K],
        from time: CMTime,
        duration: CMTime,
        minTotal: CMTime,
        defaultTotal: CMTime
    ) -> (start: CMTime, maxTotalDuration: CMTime)? {
        var cursor = time
        for kf in sorted(keyframes) {
            if CMTimeCompare(kf.endTime, cursor) <= 0 { continue }  // ends before the cursor
            if CMTimeCompare(kf.startTime, cursor) <= 0 {
                cursor = kf.endTime  // cursor is inside this keyframe — jump past it
                continue
            }
            let gap = CMTimeSubtract(kf.startTime, cursor)
            if CMTimeCompare(gap, minTotal) >= 0 {
                return (cursor, CMTimeMinimum(gap, defaultTotal))
            }
            cursor = kf.endTime  // too small — keep looking
        }
        let tail = CMTimeSubtract(duration, cursor)
        guard CMTimeCompare(tail, minTotal) >= 0 else { return nil }
        return (cursor, CMTimeMinimum(tail, defaultTotal))
    }

    /// Hold end for a new keyframe filling a slot `total` long.
    static func holdEnd(start: CMTime, total: CMTime, inOut: CMTime) -> CMTime {
        let holdSeconds = max(
            CMTimeGetSeconds(minHold),
            CMTimeGetSeconds(total) - 2 * CMTimeGetSeconds(inOut)
        )
        return CMTimeAdd(CMTimeAdd(start, inOut), CMTime(seconds: holdSeconds, preferredTimescale: 600))
    }

    /// `id` moved to start at `newStart` with its length kept, clamped
    /// between its neighbours and the timeline.
    static func moving<K: RampKeyframe>(_ keyframes: [K], id: UUID, to newStart: CMTime, duration: CMTime) -> [K]? {
        guard let idx = keyframes.firstIndex(where: { $0.id == id }) else { return nil }
        let kf = keyframes[idx]
        let length = CMTimeSubtract(kf.endTime, kf.startTime)
        let prev = keyframes
            .filter { $0.id != id && CMTimeCompare($0.startTime, kf.startTime) <= 0 }
            .max(by: { CMTimeCompare($0.startTime, $1.startTime) < 0 })
        let next = keyframes
            .filter { $0.id != id && CMTimeCompare($0.startTime, kf.startTime) > 0 }
            .min(by: { CMTimeCompare($0.startTime, $1.startTime) < 0 })
        let clamped = clamp(
            newStart,
            lower: prev?.endTime ?? .zero,
            upper: CMTimeSubtract(next?.startTime ?? duration, length)
        )
        guard clamped != kf.startTime else { return nil }
        var updated = keyframes
        let delta = CMTimeSubtract(clamped, kf.startTime)
        updated[idx].startTime = clamped
        updated[idx].holdEndTime = CMTimeAdd(kf.holdEndTime, delta)
        return sorted(updated)
    }

    /// `id`'s hold set to `hold`, clamped between `minHold` and the room
    /// left before the next keyframe (or the end of the timeline).
    static func settingHold<K: RampKeyframe>(_ keyframes: [K], id: UUID, hold: CMTime, duration: CMTime) -> [K]? {
        guard let idx = keyframes.firstIndex(where: { $0.id == id }) else { return nil }
        let kf = keyframes[idx]
        let nextStart = keyframes
            .filter { CMTimeCompare($0.startTime, kf.startTime) > 0 }
            .map(\.startTime)
            .min(by: { CMTimeCompare($0, $1) < 0 }) ?? duration
        let holdStart = CMTimeAdd(kf.startTime, kf.inDuration)
        let maxHoldEnd = CMTimeSubtract(nextStart, kf.outDuration)
        let minSeconds = CMTimeGetSeconds(minHold)
        let maxSeconds = max(minSeconds, CMTimeGetSeconds(maxHoldEnd) - CMTimeGetSeconds(holdStart))
        let seconds = min(max(CMTimeGetSeconds(hold), minSeconds), maxSeconds)
        let newHoldEnd = CMTimeAdd(holdStart, CMTime(seconds: seconds, preferredTimescale: 600))
        guard newHoldEnd != kf.holdEndTime else { return nil }
        var updated = keyframes
        updated[idx].holdEndTime = newHoldEnd
        return updated
    }

    static func sorted<K: RampKeyframe>(_ keyframes: [K]) -> [K] {
        keyframes.sorted { CMTimeCompare($0.startTime, $1.startTime) < 0 }
    }

    private static func clamp(_ t: CMTime, lower: CMTime, upper: CMTime) -> CMTime {
        if CMTimeCompare(t, lower) < 0 { return lower }
        if CMTimeCompare(t, upper) > 0 { return upper }
        return t
    }
}
