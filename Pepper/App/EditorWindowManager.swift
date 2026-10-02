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

    /// An editor has this recording open.
    func isOpen(_ url: URL) -> Bool {
        editor(for: url) != nil
    }

    /// This recording's editor is exporting or uploading it.
    func isExporting(_ url: URL) -> Bool {
        editor(for: url)?.viewModel.hasActiveExport ?? false
    }

    /// Close this recording's editor, if open (its edits are saved first).
    func close(_ url: URL) {
        editor(for: url)?.close()
    }

    private func editor(for url: URL) -> EditorWindowController? {
        windows.first { $0.project.bundleURL.standardizedFileURL == url.standardizedFileURL }
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
        if let existing = editor(for: url) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        do {
            let project = try RecordingProject.load(bundleURL: url)
            // Editors are windowed — the app needs the Dock and focus
            // while one is open.
            let controller = EditorWindowController(project: project, cascadingFrom: windows.last?.window)
            DockPresence.claim(controller)
            controller.onClose = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.windows.removeAll { $0 === controller }
                DockPresence.release(controller)
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
        panel.directoryURL = CaptureCoordinator.outputDirectory
        if let recordingType = UTType("com.darrell.pepper.recording") {
            panel.allowedContentTypes = [recordingType]
        }
        // The panel needs focus too. Opening a recording claims the Dock
        // for its editor before the panel lets go.
        DockPresence.claim(panel)
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            open(url)
        }
        DockPresence.release(panel)
    }

    func openLatestRecording() {
        guard let latest = latestRecordingBundle() else {
            showError("No recordings found yet. Record something first.")
            return
        }
        open(latest)
    }

    /// The most recently *recorded* bundle, by creation date. Sorting by
    /// modification date picked whichever recording was edited last,
    /// since every editor save touches the bundle directory.
    private func latestRecordingBundle() -> URL? {
        let bundles = ((try? FileManager.default.contentsOfDirectory(
            at: CaptureCoordinator.outputDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter(RecordingBundle.isRecording)
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        return bundles.max { created($0) < created($1) }
    }
}
