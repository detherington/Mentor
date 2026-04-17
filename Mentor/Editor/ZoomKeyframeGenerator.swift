import AppKit
import CoreMedia
import CoreGraphics
import Foundation

/// Builds a list of `ZoomKeyframe`s from an `EventRecorder.Log` for a given
/// recording. Strategy: cluster nearby clicks (close in space *and* time)
/// into single zoom moments, drop clusters that are too short or too close
/// to the edges of the recording, then resolve any time overlaps by
/// shortening earlier ramps.
///
/// Coordinate plumbing: the event log stores `NSEvent.mouseLocation`, which
/// is **global Cocoa** screen coords (points, bottom-left origin of the
/// primary display). For a display-source recording, we translate to
/// display-local points (subtract the captured `NSScreen`'s frame origin)
/// then multiply by the backing scale to land in image pixels — same
/// coordinate system Core Image uses, with origin at bottom-left.
///
/// Window + region sources fall through to "no keyframes" for now: window
/// position at click time isn't captured, and region needs a top-left/
/// bottom-left disambiguation we haven't pinned down yet.
@MainActor
enum ZoomKeyframeGenerator {

    struct Config {
        /// Two clicks within this window are considered the same gesture.
        var timeWindow: TimeInterval = 1.5
        /// Two clicks within this many image pixels are considered the same gesture.
        var spaceWindow: CGFloat = 300
        /// Don't generate a keyframe within this many seconds of the recording start
        /// (avoids zooming on the click that pressed our own UI's "stop" button before
        /// the user actually started the demo).
        var recordingStartGuard: TimeInterval = 0.5
        /// Don't generate a keyframe within this many seconds of the recording end
        /// (avoids zooming on the click that pressed "stop").
        var recordingEndGuard: TimeInterval = 0.6
        /// Minimum total duration (in + hold + out) — drops clusters that would be
        /// over before they began.
        var minTotalDuration: TimeInterval = 1.2
        /// Lead-in: zoom-in starts this many seconds *before* the first click in the cluster
        /// so the action is already framed when it happens.
        var leadIn: TimeInterval = 0.3
        /// Trail-out: hold the zoom this long after the last click in the cluster
        /// before ramping back out.
        var trailOut: TimeInterval = 0.5
        /// Zoom-in ramp duration.
        var inDuration: TimeInterval = 0.4
        /// Zoom-out ramp duration.
        var outDuration: TimeInterval = 0.6
        /// Peak zoom scale (1.5 ≈ Loom default).
        var scale: CGFloat = 1.5

        static let `default` = Config()
    }

    /// Main entrypoint.
    static func generate(
        from log: EventRecorder.Log?,
        metadata: RecordingMetadata,
        duration: CMTime,
        config: Config = .default
    ) -> [ZoomKeyframe] {
        guard let log else { return [] }

        // Map clicks to image pixels, dropping any we can't place.
        let placed = log.events.compactMap { evt -> PlacedClick? in
            guard evt.type == "click", let x = evt.x, let y = evt.y else { return nil }
            guard let target = SourceCoordinateMapper.imagePixel(
                forScreenPoint: CGPoint(x: x, y: y),
                metadata: metadata
            ) else { return nil }
            return PlacedClick(time: evt.t, target: target)
        }

        // Cluster consecutive clicks that are close in time + space.
        let clusters = cluster(clicks: placed, config: config)

        // Map clusters → keyframes, applying duration / edge-guard filters.
        let totalSeconds = CMTimeGetSeconds(duration)
        var keyframes: [ZoomKeyframe] = []
        for c in clusters {
            guard let kf = makeKeyframe(
                from: c,
                config: config,
                totalSeconds: totalSeconds
            ) else { continue }
            keyframes.append(kf)
        }

        // Resolve overlap: if a later keyframe starts before the previous one ends,
        // shorten the previous one's outDuration so they butt up cleanly.
        return resolveOverlap(keyframes)
    }

    // MARK: - Internal helpers

    private struct PlacedClick {
        let time: TimeInterval
        let target: CGPoint   // image pixels, bottom-left origin
    }

    private struct Cluster {
        var firstTime: TimeInterval
        var lastTime: TimeInterval
        var center: CGPoint           // average target, image pixels
        var count: Int
    }

    private static func cluster(clicks: [PlacedClick], config: Config) -> [Cluster] {
        var clusters: [Cluster] = []
        for click in clicks {
            if var last = clusters.last,
               click.time - last.lastTime <= config.timeWindow,
               distance(last.center, click.target) <= config.spaceWindow {
                // Extend cluster.
                let n = CGFloat(last.count)
                let newCenter = CGPoint(
                    x: (last.center.x * n + click.target.x) / (n + 1),
                    y: (last.center.y * n + click.target.y) / (n + 1)
                )
                last.center = newCenter
                last.lastTime = click.time
                last.count += 1
                clusters[clusters.count - 1] = last
            } else {
                clusters.append(Cluster(
                    firstTime: click.time,
                    lastTime: click.time,
                    center: click.target,
                    count: 1
                ))
            }
        }
        return clusters
    }

    private static func makeKeyframe(
        from cluster: Cluster,
        config: Config,
        totalSeconds: Double
    ) -> ZoomKeyframe? {
        // Edge guards — skip clusters that bump up against either end of the recording.
        if cluster.firstTime < config.recordingStartGuard { return nil }
        if cluster.lastTime > totalSeconds - config.recordingEndGuard { return nil }

        // Ideal start = first click − lead-in, but never before the start guard.
        let startSec = max(config.recordingStartGuard, cluster.firstTime - config.leadIn)
        // Hold ends trailOut after the last click.
        let holdEndSec = min(
            totalSeconds - config.recordingEndGuard,
            cluster.lastTime + config.trailOut
        )
        let inDurSec = config.inDuration
        let outDurSec = config.outDuration

        let totalDur = (holdEndSec + outDurSec) - startSec
        if totalDur < config.minTotalDuration { return nil }
        // Sanity: hold has to come after the in-ramp finishes.
        if holdEndSec < startSec + inDurSec { return nil }
        // Don't extend past the duration.
        if startSec + totalDur > totalSeconds { return nil }

        return ZoomKeyframe(
            startTime: time(startSec),
            inDuration: time(inDurSec),
            holdEndTime: time(holdEndSec),
            outDuration: time(outDurSec),
            target: cluster.center,
            scale: config.scale
        )
    }

    private static func resolveOverlap(_ keyframes: [ZoomKeyframe]) -> [ZoomKeyframe] {
        guard keyframes.count > 1 else { return keyframes }
        var out: [ZoomKeyframe] = []
        out.reserveCapacity(keyframes.count)
        for kf in keyframes {
            if let prev = out.last, CMTimeCompare(prev.endTime, kf.startTime) > 0 {
                // Shorten prev.outDuration so prev ends exactly at kf.startTime.
                let newOutEnd = kf.startTime
                let newOutDur = CMTimeSubtract(newOutEnd, prev.holdEndTime)
                if CMTimeGetSeconds(newOutDur) > 0.05 {
                    let shortened = ZoomKeyframe(
                        id: prev.id,
                        startTime: prev.startTime,
                        inDuration: prev.inDuration,
                        holdEndTime: prev.holdEndTime,
                        outDuration: newOutDur,
                        target: prev.target,
                        scale: prev.scale
                    )
                    out[out.count - 1] = shortened
                    out.append(kf)
                } else {
                    // Not enough room for a clean ease-out — drop the new one rather
                    // than ship something that visibly snaps.
                    continue
                }
            } else {
                out.append(kf)
            }
        }
        return out
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }
}
