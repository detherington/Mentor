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
        window.contentViewController = NSHostingController(
            rootView: EditorView(viewModel: viewModel)
        )
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
