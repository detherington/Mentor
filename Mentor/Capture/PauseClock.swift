import CoreMedia
import Foundation

/// One recording's pause state and timeline, read by every capture
/// callback. Host-clock based, so the offsets are in the same time
/// domain as incoming sample PTS (`CMClockGetHostTimeClock()`) and
/// subtract directly to close the gap a pause leaves in the retimed
/// tracks. Guarded by its own lock; callers never hold another lock
/// while calling in.
final class PauseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var pauseStart: CMTime = .invalid
    private var cumulativeOffset: CMTime = .zero
    /// The recording's shared time zero: the host-clock PTS of the first
    /// screen frame. Every writer starts its session here and every log
    /// is rebased to it, so all tracks share one timeline. Previously
    /// each writer started at its own first sample, and mic/webcam/
    /// events began before `SCStream` was up — narration led the screen
    /// by the stream's startup latency.
    private var origin: CMTime = .invalid

    /// Fresh recording. Must run before any writer is installed —
    /// resetting after the stream started (as it once did) let the first
    /// frames see a previous recording's stale pause flag and offset.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        paused = false
        pauseStart = .invalid
        cumulativeOffset = .zero
        origin = .invalid
    }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    /// Total time paused so far, for loggers that retime in seconds.
    var cumulativeOffsetSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return CMTimeGetSeconds(cumulativeOffset)
    }

    /// Start a pause now. False if already paused.
    func pause() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !paused else { return false }
        paused = true
        pauseStart = CMClockGetTime(CMClockGetHostTimeClock())
        return true
    }

    /// End the pause, folding its length into the offset. Returns the new
    /// total offset in seconds, or nil if not paused.
    func resume() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard paused, pauseStart.isValid else { return nil }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        cumulativeOffset = CMTimeAdd(cumulativeOffset, CMTimeSubtract(now, pauseStart))
        paused = false
        pauseStart = .invalid
        return CMTimeGetSeconds(cumulativeOffset)
    }

    /// The per-sample snapshot for the capture hot path. `drop` is true
    /// inside a pause, or before the time origin exists (only the screen
    /// stream can establish it); otherwise retime by `offset` and write
    /// with `origin` as the session start. Pass the screen frame's PTS as
    /// `establishingOriginAt` so the first one becomes the origin.
    func sampleState(establishingOriginAt pts: CMTime? = nil) -> (drop: Bool, offset: CMTime, origin: CMTime) {
        lock.lock(); defer { lock.unlock() }
        if let pts, pts.isValid, !paused, !origin.isValid {
            origin = pts
        }
        return (paused || !origin.isValid, cumulativeOffset, origin)
    }

    /// Where the timeline ends if the recording stops now: now, or the
    /// moment the pause began if stopping while paused — retimed like
    /// every sample. `end` is nil if no frame ever arrived.
    ///
    /// Deliberately leaves the pause state alone. Clearing it before the
    /// stream stops and the writers detach let samples arriving in that
    /// window through without the in-progress pause's offset, and a stop
    /// while paused wrote an N-second frozen / silent tail. `reset()`
    /// clears it for the next recording.
    func stopPoint() -> (origin: CMTime, end: CMTime?) {
        lock.lock(); defer { lock.unlock() }
        let rawEnd = (paused && pauseStart.isValid)
            ? pauseStart
            : CMClockGetTime(CMClockGetHostTimeClock())
        let end = origin.isValid ? CMTimeSubtract(rawEnd, cumulativeOffset) : nil
        return (origin, end)
    }
}
