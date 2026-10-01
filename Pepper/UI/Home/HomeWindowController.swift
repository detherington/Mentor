import AppKit
import SwiftUI

/// Pepper's main window: start a recording, reopen a recent one, and see
/// that the camera, microphone and Orbis are set. Pepper began as a
/// menu-bar app whose only thing on screen at launch was the webcam
/// preview, which left new users unsure it had opened or what to do next.
///
/// Shown at launch (after setup, the first time), on a Dock-icon click
/// with nothing open, and from the menu bar. Not at launch when the Dock
/// icon is hidden: that's the menu-bar way of using Pepper. Steps out of
/// the way while a recording starts, so it isn't in the shot, and comes
/// back if the recording is cancelled before it begins.
@MainActor
final class HomeWindowController: NSObject, NSWindowDelegate {
    struct Actions {
        var record: () -> Void
        var open: (URL) -> Void
        var showOpenPanel: () -> Void
        var showSettings: () -> Void
        var revealRecordings: () -> Void
    }

    private let actions: Actions
    private let model = HomeModel()
    private var window: NSWindow?
    /// Hidden because a recording started; `recordingBegan` says whether
    /// it got as far as recording (then the editor opens instead).
    private var hiddenForRecording = false
    private var recordingBegan = false

    init(actions: Actions) {
        self.actions = actions
    }

    func show() {
        model.refresh()
        let win = window ?? makeWindow()
        window = win
        DockPresence.claim(self)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func recordingStateChanged(_ state: RecordingFlowController.State) {
        switch state {
        case .picking, .countingDown, .starting:
            guard let window, window.isVisible else { return }
            window.orderOut(nil)
            DockPresence.release(self)
            hiddenForRecording = true
        case .recording:
            recordingBegan = true
        case .stopping:
            break
        case .idle:
            if hiddenForRecording, !recordingBegan { show() }
            hiddenForRecording = false
            recordingBegan = false
            model.refresh()
        }
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: HomeView.size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Pepper"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = .black
        win.contentView = NSHostingView(rootView: HomeView(model: model, actions: actions))
        win.isReleasedWhenClosed = false
        win.tabbingMode = .disallowed
        win.delegate = self
        win.center()
        win.setFrameAutosaveName("PepperHome")
        return win
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.release(self)
    }

    /// Coming back to the window: a recording may have finished or been
    /// renamed, a device or permission changed, Orbis signed in.
    func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
    }
}

#if DEBUG
extension HomeWindowController {
    /// Review hook: `-pepper.debug.renderHome <dir>` writes the window as
    /// a PNG, with this Mac's recordings, devices and Orbis state. True
    /// when it ran; the caller then quits. Debug builds only.
    static func renderIfRequested() -> Bool {
        guard let path = UserDefaults.standard.string(forKey: "pepper.debug.renderHome") else { return false }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let noop = Actions(record: {}, open: { _ in }, showOpenPanel: {}, showSettings: {}, revealRecordings: {})
        let controller = HomeWindowController(actions: noop)
        controller.show()
        // Thumbnails load in the background.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        if let frameView = controller.window?.contentView?.superview,
           let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("home.png"))
        }
        return true
    }
}
#endif
