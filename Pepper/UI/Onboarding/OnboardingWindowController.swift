import AppKit
import SwiftUI

/// The setup walkthrough's window: black, no visible title bar, like
/// Muesli's. Shown at launch until it's finished; Settings can reopen it.
/// Closing it early leaves setup unfinished, so it comes back next launch.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    /// `fromStart` for Settings' "Show Setup Guide…"; otherwise resumes
    /// on the saved step.
    func show(fromStart: Bool = false) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = OnboardingView(startAt: fromStart ? .welcome : nil) { [weak self] in
            self?.window?.close()
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Welcome to Pepper"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = .black
        win.contentView = NSHostingView(rootView: view)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win
        DockPresence.claim(self)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        DockPresence.release(self)
    }

    #if DEBUG
    /// Review hook: launching with `-pepper.debug.renderOnboarding <dir>`
    /// writes every step as a PNG, drawn from the real view in an
    /// offscreen window, so layout can be checked without clicking through
    /// (or granting) anything. True when it ran; the caller then quits.
    /// Debug builds only.
    static func renderStepsIfRequested() -> Bool {
        guard let path = UserDefaults.standard.string(forKey: "pepper.debug.renderOnboarding") else { return false }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Each step as this Mac stands, then with nothing granted.
        for unset in [false, true] {
            Permissions.shared.debugReportNothingGranted = unset
            Permissions.shared.refresh()
            render(to: dir, suffix: unset ? "-unset" : "")
        }
        PepperDebug.log("DEBUG: rendered onboarding steps to \(dir.path)")
        return true
    }

    private static func render(to dir: URL, suffix: String) {
        for (i, step) in OnboardingView.Step.allCases.enumerated() {
            let host = NSHostingView(rootView: OnboardingView(startAt: step) {})
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 580),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = dir.appendingPathComponent(String(format: "%02d-%@%@.png", i, step.rawValue, suffix))
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
    #endif
}
