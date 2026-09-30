import AppKit
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let project: RecordingProject
    let viewModel: EditorViewModel
    var onClose: (() -> Void)?

    init(project: RecordingProject) {
        self.project = project
        self.viewModel = EditorViewModel(project: project)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = project.displayName
        let host = NSHostingController(rootView: EditorView(viewModel: viewModel))
        // Lets EditorView's `.toolbar` (Export, Send to Orbis, details)
        // become this window's toolbar; an NSWindow hosting SwiftUI gets
        // no toolbar otherwise.
        host.sceneBridgingOptions = [.toolbars]
        window.contentViewController = host
        window.toolbarStyle = .unified
        window.center()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        // Edits autosave on a short debounce; don't lose one in flight.
        viewModel.flushPendingSaves()
        onClose?()
    }
}

#if DEBUG
extension EditorWindowController {
    /// Review hook: `-pepper.debug.renderEditor <dir>
    /// -pepper.debug.renderEditorBundle <recording.pepper>` opens that
    /// recording and writes the window (toolbar and inspector included)
    /// as PNGs: every row closed, then each row open. Add
    /// `-pepper.debug.renderAppearance light|dark` to force one. True when
    /// it ran; the caller then quits. Debug builds only.
    static func renderIfRequested() -> Bool {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "pepper.debug.renderEditor"),
              let bundlePath = defaults.string(forKey: "pepper.debug.renderEditorBundle"),
              let project = try? RecordingProject.load(bundleURL: URL(fileURLWithPath: bundlePath)) else { return false }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let controller = EditorWindowController(project: project)
        controller.window?.setContentSize(NSSize(width: 1280, height: 860))
        switch defaults.string(forKey: "pepper.debug.renderAppearance") {
        case "light": controller.window?.appearance = NSAppearance(named: .aqua)
        case "dark":  controller.window?.appearance = NSAppearance(named: .darkAqua)
        default:      break
        }
        controller.showWindow(nil)
        let vm = controller.viewModel
        let deadline = Date().addingTimeInterval(15)
        while vm.isLoading, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let states: [InspectorFeature?] = [nil] + InspectorFeature.allCases
        for state in states {
            vm.openInspectorFeature = state
            vm.selectedZoomID = state == .zoom ? vm.zoomKeyframes.first?.id : nil
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            guard let frameView = controller.window?.contentView?.superview,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { continue }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let name = state?.rawValue ?? "closed"
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("editor-\(name).png"))
        }
        PepperDebug.log("DEBUG: rendered editor to \(dir.path)")
        return true
    }
}
#endif

