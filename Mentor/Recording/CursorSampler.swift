import AppKit
import Foundation

/// Samples the global mouse location during a recording so the editor
/// can render a cursor-highlight halo per frame. Runs a background
/// timer at ~30 Hz — 30 samples/second is smooth enough for linear-
/// interpolation between frames at 60 fps output, and keeps the
/// sidecar log under half a MB even for very long recordings.
///
/// Time base matches `EventRecorder`: `t` is seconds from `start()`
/// using `ProcessInfo.systemUptime` as the reference clock, so cursor
/// samples align cleanly with click + key events in `events.json`.
/// Unlike the EventRecorder, we don't need Accessibility permission —
/// `NSEvent.mouseLocation` is available without special entitlements.
final class CursorSampler: @unchecked Sendable {
    struct Sample: Codable {
        let t: TimeInterval
        let x: Double
        let y: Double
    }

    struct Log: Codable {
        let version: Int
        let sampleHz: Double
        let samples: [Sample]
    }

    private let sampleHz: Double
    private let queue = DispatchQueue(label: "com.darrell.mentor.cursor-sampler", qos: .userInitiated)
    private let lock = NSLock()

    private var timer: DispatchSourceTimer?
    private var samples: [Sample] = []
    private var referenceUptime: TimeInterval = 0
    private var started = false
    private var paused = false
    /// Cumulative wall-clock time spent paused. Each captured
    /// sample's `t` is computed as `uptime - reference - pausedOffset`
    /// so post-resume samples sync with the retimed video frames.
    private var pausedOffset: TimeInterval = 0
    // Small dedup: skip a sample if position + integer-rounded time
    // haven't changed from the previous. Keeps the log compact during
    // long idle periods where the cursor sits still.
    private var lastX: Double = .nan
    private var lastY: Double = .nan

    init(sampleHz: Double = 30.0) {
        self.sampleHz = sampleHz
    }

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(sampleHz) * 300)  // ~5 minutes at 30Hz
        referenceUptime = ProcessInfo.processInfo.systemUptime
        lastX = .nan
        lastY = .nan
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(Int(1000.0 / sampleHz))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Enter / exit the paused state. While paused, `tick()` skips
    /// appending samples. On resume, `cumulativeOffsetSeconds` from
    /// the coordinator is stamped in so subsequent samples' `t`
    /// values stay aligned with retimed A/V frames.
    func setPaused(_ newPaused: Bool, cumulativeOffsetSeconds: TimeInterval = 0) {
        lock.lock()
        paused = newPaused
        if !newPaused {
            pausedOffset = cumulativeOffsetSeconds
            // Reset dedup state so the first post-resume sample
            // always gets through even if the cursor hasn't moved.
            lastX = .nan
            lastY = .nan
        }
        lock.unlock()
    }

    func stop() -> Log? {
        lock.lock()
        guard started else { lock.unlock(); return nil }
        started = false
        let collected = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()

        timer?.cancel()
        timer = nil

        return Log(version: 1, sampleHz: sampleHz, samples: collected)
    }

    private func tick() {
        // NSEvent.mouseLocation is main-thread safe (it just wraps a
        // CGEvent query) and returns screen coordinates with origin at
        // the bottom-left of the primary display's bounds — same
        // coordinate space EventRecorder uses for click positions, so
        // SourceCoordinateMapper can consume our samples directly.
        let loc = NSEvent.mouseLocation
        let rawUptime = ProcessInfo.processInfo.systemUptime
        guard loc.x.isFinite, loc.y.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        if !started || paused { return }
        let t = rawUptime - referenceUptime - pausedOffset
        guard t >= 0 else { return }
        // Skip duplicate positions — reduces log size during idle
        // stretches. `lastX`/`lastY` are compared in pt space; sub-px
        // jitter gets preserved for smooth interp but integer-stable
        // positions collapse to a single sample.
        if loc.x == lastX, loc.y == lastY { return }
        lastX = loc.x
        lastY = loc.y
        samples.append(Sample(t: t, x: loc.x, y: loc.y))
    }
}
