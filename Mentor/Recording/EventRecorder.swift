import AppKit
import Foundation

/// Captures user events during recording: mouse clicks, keystrokes,
/// and app activations. Timestamps are relative to the recording start
/// (in seconds) so the editor can sync them to video PTS.
///
/// Requires Accessibility permission for the global mouse/key monitors
/// to receive events outside Mentor itself. If permission isn't granted
/// we silently skip those monitors — app-activation events still work.
final class EventRecorder {
    struct Event: Codable {
        let t: TimeInterval           // seconds from recording start
        let type: String              // "click", "mouseUp", "key", "keyUp", "modifiers", "appActivate"
        let button: String?           // "left" / "right" for mouse events
        let x: Double?
        let y: Double?
        let keyCode: Int?
        let modifiers: UInt?
        let chars: String?
        let bundleId: String?
        let appName: String?
    }

    struct Log: Codable {
        let version: Int
        let startDate: Date
        let events: [Event]
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var monitors: [Any] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Reference timestamp (NSEvent.timestamp / ProcessInfo.systemUptime base)
    /// at the moment start() was called.
    private var referenceUptime: TimeInterval = 0
    private var startDate = Date()
    private var started = false
    /// Accumulated wall-clock time the user has spent paused. Each
    /// event's `t` is computed as `event.timestamp - referenceUptime
    /// - pausedOffset` so events time-align with the A/V tracks the
    /// coordinator retimed to close the pause gap.
    private var pausedOffset: TimeInterval = 0
    private var paused: Bool = false

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        events.removeAll(keepingCapacity: true)
        referenceUptime = ProcessInfo.processInfo.systemUptime
        startDate = Date()
        lock.unlock()

        // Mouse + key global monitors. Require Accessibility; fail silently.
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] event in
            self?.recordMouse(event)
        }) {
            monitors.append(m)
        }
        let keyMask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: keyMask, handler: { [weak self] event in
            self?.recordKey(event)
        }) {
            monitors.append(m)
        }

        // App activation — always works (no special permission).
        let center = NSWorkspace.shared.notificationCenter
        let obs = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.recordActivation(note)
        }
        workspaceObservers.append(obs)
    }

    /// Enter / exit the paused state. While paused, incoming events
    /// are dropped outright — simpler than buffering + discarding,
    /// and matches what the A/V writers do. `cumulativeOffsetSeconds`
    /// comes from the capture coordinator's shared pause clock so
    /// post-resume events get timestamps that line up with the
    /// retimed video frames.
    func setPaused(_ newPaused: Bool, cumulativeOffsetSeconds: TimeInterval = 0) {
        lock.lock()
        paused = newPaused
        if !newPaused {
            pausedOffset = cumulativeOffsetSeconds
        }
        lock.unlock()
    }

    /// Stop monitoring and return the collected log. Safe to call twice
    /// (returns nil after the first call).
    func stop() -> Log? {
        lock.lock()
        guard started else { lock.unlock(); return nil }
        started = false
        let collected = events
        let date = startDate
        events.removeAll(keepingCapacity: false)
        lock.unlock()

        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()

        return Log(version: 1, startDate: date, events: collected)
    }

    // MARK: - Internal event recording

    /// Coordinator-aware timestamp: returns nil while paused (caller
    /// drops the event), otherwise the event's relative time with
    /// cumulative pause offset subtracted — so events on either side
    /// of a pause land next to their corresponding A/V frames after
    /// retiming.
    private func adjustedTime(for rawHostUptime: TimeInterval) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        if paused { return nil }
        return rawHostUptime - referenceUptime - pausedOffset
    }

    private func recordMouse(_ event: NSEvent) {
        guard let t = adjustedTime(for: event.timestamp), t >= 0 else { return }
        let button: String
        let isDown: Bool
        switch event.type {
        case .leftMouseDown:  button = "left";  isDown = true
        case .leftMouseUp:    button = "left";  isDown = false
        case .rightMouseDown: button = "right"; isDown = true
        case .rightMouseUp:   button = "right"; isDown = false
        default: return
        }
        // NSEvent.mouseLocation returns screen coords with origin at bottom-left.
        let loc = NSEvent.mouseLocation
        let e = Event(
            t: t,
            type: isDown ? "click" : "mouseUp",
            button: button,
            x: Double(loc.x),
            y: Double(loc.y),
            keyCode: nil, modifiers: nil, chars: nil, bundleId: nil, appName: nil
        )
        append(e)
    }

    private func recordKey(_ event: NSEvent) {
        guard let t = adjustedTime(for: event.timestamp), t >= 0 else { return }
        let type: String
        var code: Int?
        var chars: String?
        switch event.type {
        case .keyDown:
            type = "key"
            code = Int(event.keyCode)
            chars = event.charactersIgnoringModifiers
        case .keyUp:
            type = "keyUp"
            code = Int(event.keyCode)
        case .flagsChanged:
            type = "modifiers"
        default:
            return
        }
        let e = Event(
            t: t,
            type: type,
            button: nil, x: nil, y: nil,
            keyCode: code,
            modifiers: event.modifierFlags.rawValue,
            chars: chars,
            bundleId: nil, appName: nil
        )
        append(e)
    }

    private func recordActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard let t = adjustedTime(for: ProcessInfo.processInfo.systemUptime), t >= 0 else { return }
        let e = Event(
            t: t,
            type: "appActivate",
            button: nil, x: nil, y: nil,
            keyCode: nil, modifiers: nil, chars: nil,
            bundleId: app.bundleIdentifier,
            appName: app.localizedName
        )
        append(e)
    }

    private func append(_ event: Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}
