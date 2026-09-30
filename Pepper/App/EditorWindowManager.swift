import AppKit
import UniformTypeIdentifiers

/// Owns the open editor windows and the activation-policy flip that goes
/// with them: the app shows in the Dock (`.regular`) while any editor is
/// open — so windows can take focus — and drops back to menu-bar-only
/// (`.accessory`) when the last one closes.
@MainActor
final class EditorWindowManager {
    private(set) var windows: [EditorWindowController] = []
    private let showError: (String) -> Void

    init(showError: @escaping (String) -> Void) {
        self.showError = showError
    }

    /// Editors with a local or Orbis export running.
    var exportingEditors: [EditorWindowController] {
        windows.filter { $0.viewModel.hasActiveExport }
    }

    /// Editors left open at quit never get `windowWillClose`.
    func flushPendingSaves() {
        for editor in windows { editor.viewModel.flushPendingSaves() }
    }

    func open(_ url: URL) {
        guard RecordingBundle.isRecording(url) else {
            showError("\(url.lastPathComponent) isn't a Pepper recording.")
            return
        }

        // If already open, bring that window to front instead of duplicating.
        if let existing = windows.first(where: { $0.project.bundleURL == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        do {
            let project = try RecordingProject.load(bundleURL: url)
            // Editors are windowed — app needs to show in the Dock and
            // accept focus. Flip activation policy on first editor open.
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
            let controller = EditorWindowController(project: project)
            controller.onClose = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.windows.removeAll { $0 === controller }
                // If no editors remain, go back to menu-bar-only mode.
                if self.windows.isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
            windows.append(controller)
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            showError("Couldn't open \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.recordingDirectories.first
        // The document type keeps its pre-rename identifier; it covers
        // both .pepper and .mentor (see project.yml).
        if let recordingType = UTType("com.darrell.mentor.recording") {
            panel.allowedContentTypes = [recordingType]
        }
        // Temporarily promote so the open panel gets focus; drop back when done
        // if we end up cancelling.
        let wasAccessory = NSApp.activationPolicy() != .regular
        if wasAccessory { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            open(url)
        } else if wasAccessory, windows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func openLatestRecording() {
        guard let latest = latestRecordingBundle() else {
            showError("No recordings found yet. Record something first.")
            return
        }
        open(latest)
    }

    /// Where recordings live, newest location first: ~/Movies/Pepper,
    /// then ~/Movies/Mentor from before the rename (only those that exist).
    private static var recordingDirectories: [URL] {
        [CaptureCoordinator.outputDirectory, CaptureCoordinator.legacyOutputDirectory]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The most recently *recorded* bundle, by creation date. Sorting by
    /// modification date picked whichever recording was edited last,
    /// since every editor save touches the bundle directory.
    private func latestRecordingBundle() -> URL? {
        let bundles = Self.recordingDirectories.flatMap { dir in
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }.filter(RecordingBundle.isRecording)
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        return bundles.max { created($0) < created($1) }
    }
}
