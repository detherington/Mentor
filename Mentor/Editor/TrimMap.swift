import Foundation
import CoreMedia

/// Describes the editor's effective time mapping: an outer trim (leading +
/// trailing `trimStart`/`trimEnd`) plus zero or more interior cut ranges
/// that have been deleted from the middle of the recording.
///
/// All times are in **source composition time** — the coordinate space of
/// the raw `.mentor` sidecar tracks as they were captured. The "output"
/// coordinate space (what the player and exported MP4 see) is derived by
/// removing the cuts and shifting the leading trim to t=0.
///
/// The struct is immutable and cheap to copy. The editor holds a live
/// `TrimMap` computed from `trimStart`, `trimEnd`, and `cutRanges`; it's
/// passed to the compositor for per-frame keyframe lookups and to the
/// exporter for stitched-composition construction.
///
/// # Invariants
///
/// - `outerTrim.start <= outerTrim.end` (zero-duration outerTrim is
///   allowed during the initial load, before `duration` is known).
/// - `cuts` is sorted by `start` ascending.
/// - Cut ranges are non-overlapping and non-adjacent (any overlap or
///   touch is merged by `normalise`).
/// - Each cut is strictly contained within `outerTrim` — a cut that
///   spills out is clamped to the outer bounds; a cut entirely outside
///   is dropped.
///
/// Construct via the `init(outerTrim:cuts:)` designated initializer; it
/// always calls `normalise` so the result is valid even if the caller
/// passes unsorted / overlapping input.
struct TrimMap: Equatable, Sendable {
    let outerTrim: CMTimeRange
    let cuts: [CMTimeRange]

    init(outerTrim: CMTimeRange, cuts: [CMTimeRange] = []) {
        self.outerTrim = outerTrim
        self.cuts = Self.normalise(cuts, within: outerTrim)
    }

    /// Full pass-through: entire outer range kept, no cuts. Used as the
    /// default before the user edits anything.
    static func entire(_ range: CMTimeRange) -> TrimMap {
        TrimMap(outerTrim: range, cuts: [])
    }

    /// True if this map is "trivial" — outerTrim spans the full source
    /// and there are no interior cuts. Exporter fast-paths to the
    /// existing single-range reader when this is true.
    func isTrivial(fullDuration: CMTime) -> Bool {
        outerTrim.start == .zero &&
        outerTrim.end == fullDuration &&
        cuts.isEmpty
    }

    /// The non-cut segments of `outerTrim`, in ascending source-time
    /// order. These are the segments the exporter stitches into the
    /// output composition.
    var keptRanges: [CMTimeRange] {
        if cuts.isEmpty {
            return [outerTrim]
        }
        var ranges: [CMTimeRange] = []
        var cursor = outerTrim.start
        for cut in cuts {
            if CMTimeCompare(cursor, cut.start) < 0 {
                ranges.append(CMTimeRange(start: cursor, end: cut.start))
            }
            cursor = cut.end
        }
        if CMTimeCompare(cursor, outerTrim.end) < 0 {
            ranges.append(CMTimeRange(start: cursor, end: outerTrim.end))
        }
        return ranges
    }

    /// Total duration of the kept material — i.e. the duration of the
    /// exported MP4 / the length of the playback timeline.
    var outputDuration: CMTime {
        keptRanges.reduce(.zero) { CMTimeAdd($0, $1.duration) }
    }

    /// Convert a time in the output timeline (where t=0 is the start of
    /// the first kept segment) to the corresponding source time.
    /// Returns the clamped boundary if the input falls outside
    /// `[0, outputDuration]`.
    func sourceTime(forOutputTime outputTime: CMTime) -> CMTime {
        if CMTimeCompare(outputTime, .zero) <= 0 {
            return outerTrim.start
        }
        var remaining = outputTime
        for range in keptRanges {
            if CMTimeCompare(remaining, range.duration) <= 0 {
                return CMTimeAdd(range.start, remaining)
            }
            remaining = CMTimeSubtract(remaining, range.duration)
        }
        // Past the end — clamp to outerTrim.end.
        return outerTrim.end
    }

    /// Convert a source time to the corresponding output time. If
    /// `sourceTime` falls inside a cut range, returns the output time of
    /// the *end* of that cut (the next frame that will actually play).
    /// If outside `outerTrim`, clamps to 0 or `outputDuration`.
    func outputTime(forSourceTime sourceTime: CMTime) -> CMTime {
        if CMTimeCompare(sourceTime, outerTrim.start) <= 0 { return .zero }
        if CMTimeCompare(sourceTime, outerTrim.end) >= 0 { return outputDuration }
        var accumulated: CMTime = .zero
        for range in keptRanges {
            if CMTimeCompare(sourceTime, range.end) < 0 {
                if CMTimeCompare(sourceTime, range.start) < 0 {
                    // Inside a cut — snap to the next kept segment's start.
                    return accumulated
                }
                return CMTimeAdd(accumulated, CMTimeSubtract(sourceTime, range.start))
            }
            accumulated = CMTimeAdd(accumulated, range.duration)
        }
        return accumulated
    }

    /// True iff `sourceTime` lands inside one of the cut regions.
    /// Used by the keyframe plumbing to drop zoom/talking-head/caption
    /// entries that would otherwise "flash" across a cut boundary.
    func isCut(_ sourceTime: CMTime) -> Bool {
        for cut in cuts {
            if CMTimeCompare(sourceTime, cut.start) >= 0,
               CMTimeCompare(sourceTime, cut.end) < 0 {
                return true
            }
        }
        return false
    }

    // MARK: - Mutation helpers (return new TrimMap; TrimMap is immutable)

    /// Add a cut range. Overlaps with existing cuts are merged; parts
    /// outside `outerTrim` are clamped or dropped.
    func inserting(_ cut: CMTimeRange) -> TrimMap {
        TrimMap(outerTrim: outerTrim, cuts: cuts + [cut])
    }

    /// Remove the cut at `index` (no-op if out of range).
    func removing(cutAt index: Int) -> TrimMap {
        guard cuts.indices.contains(index) else { return self }
        var next = cuts
        next.remove(at: index)
        return TrimMap(outerTrim: outerTrim, cuts: next)
    }

    /// Replace the outer trim. Any cut now outside the new outer range
    /// is clamped or dropped by `normalise`.
    func withOuterTrim(_ range: CMTimeRange) -> TrimMap {
        TrimMap(outerTrim: range, cuts: cuts)
    }

    // MARK: - Normalisation

    /// Clamp to outerTrim, drop empties, sort, merge overlapping /
    /// adjacent ranges. Called from the initializer so every TrimMap in
    /// the wild satisfies the struct's invariants.
    private static func normalise(_ input: [CMTimeRange], within bounds: CMTimeRange) -> [CMTimeRange] {
        let clamped: [CMTimeRange] = input.compactMap { raw in
            let start = Self.max(raw.start, bounds.start)
            let end = Self.min(raw.end, bounds.end)
            if CMTimeCompare(end, start) <= 0 { return nil }
            return CMTimeRange(start: start, end: end)
        }
        guard !clamped.isEmpty else { return [] }
        let sorted = clamped.sorted { CMTimeCompare($0.start, $1.start) < 0 }
        var merged: [CMTimeRange] = [sorted[0]]
        for range in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if CMTimeCompare(range.start, last.end) <= 0 {
                // Overlaps or touches — merge.
                let newEnd = Self.max(last.end, range.end)
                merged[merged.count - 1] = CMTimeRange(start: last.start, end: newEnd)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func min(_ a: CMTime, _ b: CMTime) -> CMTime {
        CMTimeCompare(a, b) <= 0 ? a : b
    }

    private static func max(_ a: CMTime, _ b: CMTime) -> CMTime {
        CMTimeCompare(a, b) >= 0 ? a : b
    }
}

// MARK: - Keyframe remapping
//
// Used by the exporter when interior cuts are present. The stitched
// export composition has its own time coordinate (= output time); the
// editor stores keyframes + captions + ripples in source time, so each
// entry needs to be remapped before being handed to the compositor.
//
// For range-typed entries (zoom / talking-head / captions): remap the
// start and end to output-time and drop any whose output span collapses
// to zero (i.e. the entry fell entirely inside a cut). For instants
// (cursor ripples): remap the point; drop if it lands inside a cut.

extension TrimMap {
    func remap(zoomKeyframes: [ZoomKeyframe]) -> [ZoomKeyframe] {
        zoomKeyframes.compactMap { kf in
            let start = outputTime(forSourceTime: kf.startTime)
            let holdEnd = outputTime(forSourceTime: kf.holdEndTime)
            guard CMTimeCompare(holdEnd, start) > 0 else { return nil }
            // Drop keyframes whose entire peak moment landed inside a
            // cut — they'd render as zero-length flashes otherwise.
            if isCut(kf.startTime) && isCut(kf.holdEndTime),
               cuts.contains(where: { CMTimeCompare($0.start, kf.startTime) <= 0 &&
                                      CMTimeCompare($0.end, kf.holdEndTime) >= 0 }) {
                return nil
            }
            return ZoomKeyframe(
                id: kf.id,
                startTime: start,
                inDuration: kf.inDuration,
                holdEndTime: holdEnd,
                outDuration: kf.outDuration,
                target: kf.target,
                scale: kf.scale
            )
        }
    }

    func remap(talkingHeadKeyframes: [TalkingHeadKeyframe]) -> [TalkingHeadKeyframe] {
        talkingHeadKeyframes.compactMap { kf in
            let newStart = outputTime(forSourceTime: kf.startTime)
            let newHoldEnd = outputTime(forSourceTime: kf.holdEndTime)
            guard CMTimeCompare(newHoldEnd, newStart) > 0 else { return nil }
            if isCut(kf.startTime) && isCut(kf.holdEndTime),
               cuts.contains(where: { CMTimeCompare($0.start, kf.startTime) <= 0 &&
                                      CMTimeCompare($0.end, kf.holdEndTime) >= 0 }) {
                return nil
            }
            return TalkingHeadKeyframe(
                id: kf.id,
                startTime: newStart,
                inDuration: kf.inDuration,
                holdEndTime: newHoldEnd,
                outDuration: kf.outDuration,
                targetDiameterFraction: kf.targetDiameterFraction
            )
        }
    }

    func remap(cursorRipples: [CursorRipple]) -> [CursorRipple] {
        cursorRipples.compactMap { ripple in
            if isCut(ripple.time) { return nil }
            let mapped = outputTime(forSourceTime: ripple.time)
            return CursorRipple(id: ripple.id, time: mapped, target: ripple.target)
        }
    }

    func remap(transcriptionLines: [TranscriptionLine]) -> [TranscriptionLine] {
        transcriptionLines.compactMap { line in
            let startCM = CMTime(seconds: line.startSeconds, preferredTimescale: 600)
            let endCM = CMTime(seconds: line.endSeconds, preferredTimescale: 600)
            let newStart = outputTime(forSourceTime: startCM)
            let newEnd = outputTime(forSourceTime: endCM)
            let newStartSec = CMTimeGetSeconds(newStart)
            let newEndSec = CMTimeGetSeconds(newEnd)
            guard newEndSec > newStartSec + 0.01 else { return nil }
            return TranscriptionLine(
                text: line.text,
                startSeconds: newStartSec,
                endSeconds: newEndSec
            )
        }
    }
}

