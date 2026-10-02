import AppKit
import SwiftUI
import AVFoundation

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let project: RecordingProject
    let viewModel: EditorViewModel
    var onClose: (() -> Void)?

    /// Where the last editor was, and its size, for the next one. Saved
    /// by hand rather than as an autosave name: two editors open at once
    /// can't share one.
    private static let frameName = "PepperEditor"

    /// `previous`: an editor already open, to cascade from instead of
    /// landing exactly on top of it.
    init(project: RecordingProject, cascadingFrom previous: NSWindow? = nil) {
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
        window.setFrameUsingName(Self.frameName)
        if let previous {
            window.cascadeTopLeft(from: previous.cascadeTopLeft(from: .zero))
        }
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)
        // Set after placing the window, so the cascade above isn't saved
        // as where the next editor should open.
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        // Edits autosave on a short debounce; don't lose one in flight.
        viewModel.flushPendingSaves()
        onClose?()
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: Self.frameName)
    }

    // MARK: - Edit menu

    // Undo and Redo in the Edit menu, for the editor's own undo stack.
    // A custom action rather than `undo:`, which a focused text field
    // would take for its own typing: ⌘Z in the editor has always undone
    // editor changes, caption text included.

    @objc func undoEditorChange(_ sender: Any?) { viewModel.performUndo() }
    @objc func redoEditorChange(_ sender: Any?) { viewModel.performRedo() }
}

extension EditorWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undoEditorChange(_:)):
            let name = viewModel.undoActionName
            item.title = viewModel.canUndo && !name.isEmpty ? "Undo \(name)" : "Undo"
            return viewModel.canUndo
        case #selector(redoEditorChange(_:)):
            let name = viewModel.redoActionName
            item.title = viewModel.canRedo && !name.isEmpty ? "Redo \(name)" : "Redo"
            return viewModel.canRedo
        default:
            return true
        }
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
        // `-pepper.debug.renderExportTo <file.mp4>`: run the editor's own
        // export (its layout and trim, as Export and Send to Orbis do)
        // and log how it ended.
        if let exportPath = defaults.string(forKey: "pepper.debug.renderExportTo") {
            let url = URL(fileURLWithPath: exportPath)
            // `-pepper.debug.renderExportTrimIn <seconds>`: Set In at the
            // playhead first, as the timeline button does.
            let trimIn = defaults.double(forKey: "pepper.debug.renderExportTrimIn")
            if trimIn > 0 {
                vm.seek(to: CMTime(seconds: trimIn, preferredTimescale: 600))
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                vm.setTrimStartToCurrent()
                PepperDebug.log("DEBUG: Set In at playhead \(vm.currentTime.value)/\(vm.currentTime.timescale)")
            }
            // `-pepper.debug.renderExportTrimInNs <nanoseconds>`: an In point
            // in the player's nanosecond time base, as Set In gets during
            // playback.
            if let trimInNs = defaults.string(forKey: "pepper.debug.renderExportTrimInNs").flatMap(Int64.init) {
                vm.setTrimStart(CMTime(value: CMTimeValue(trimInNs), timescale: 1_000_000_000))
                PepperDebug.log("DEBUG: Set In at \(vm.trimStart.value)/\(vm.trimStart.timescale)")
            }
            // `-pepper.debug.renderExportCutNs <start,end>`: a cut between
            // two nanosecond marks.
            if let cut = defaults.string(forKey: "pepper.debug.renderExportCutNs")?
                .split(separator: ",").compactMap({ Int64($0) }), cut.count == 2 {
                vm.insertCut(CMTimeRange(start: CMTime(value: cut[0], timescale: 1_000_000_000),
                                         end: CMTime(value: cut[1], timescale: 1_000_000_000)))
                PepperDebug.log("DEBUG: cut \(vm.cutRanges.map { "\(CMTimeGetSeconds($0.start))..\(CMTimeGetSeconds($0.end))" })")
            }
            // `-pepper.debug.renderExportCleanAudio YES`: Clean up audio on.
            if defaults.bool(forKey: "pepper.debug.renderExportCleanAudio") {
                var style = vm.noiseReductionStyle
                style.enabled = true
                vm.noiseReductionStyle = style
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                let cleanDeadline = Date().addingTimeInterval(120)
                while vm.isCleaningMic || vm.isLoading, Date() < cleanDeadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                }
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            }
            vm.startExport(to: url)
            let exportDeadline = Date().addingTimeInterval(600)
            while vm.isExporting, Date() < exportDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            let outcome = vm.exportError.map { "FAILED: \($0.localizedDescription)" } ?? "OK"
            PepperDebug.log("DEBUG: export \(url.lastPathComponent) trim=\(CMTimeGetSeconds(vm.trimStart))..\(CMTimeGetSeconds(vm.trimEnd)) duration=\(CMTimeGetSeconds(vm.duration)) → \(outcome)")
            print("EXPORT \(outcome)")
        }
        // Quick polish writes zooms and captions into the bundle, so
        // this pass is opt-in: point it at a copy.
        if defaults.bool(forKey: "pepper.debug.renderPolish") {
            func snapshot(_ name: String) {
                guard let frameView = controller.window?.contentView?.superview,
                      let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("editor-\(name).png"))
            }
            vm.openInspectorFeature = nil
            vm.quickPolish()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            snapshot("polishing")
            let polishDeadline = Date().addingTimeInterval(90)
            while vm.isPolishing, Date() < polishDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            snapshot("polished")
        }
        PepperDebug.log("DEBUG: rendered editor to \(dir.path)")
        return true
    }
}
#endif

