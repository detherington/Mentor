import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Single-window controller for the live soundboard configuration UI.
/// Mirrors the shape of `SettingsWindowController` — show() is idempotent,
/// a subsequent show() just brings the existing window forward.
@MainActor
final class SoundboardWindowController {
    private var window: NSWindow?
    private let controller: SoundboardController

    init(controller: SoundboardController) {
        self.controller = controller
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Soundboard"
        win.contentView = NSHostingView(rootView: SoundboardView(controller: controller))
        win.center()
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 460, height: 320)
        self.window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

// MARK: - SwiftUI view

private struct SoundboardView: View {
    @Bindable var controller: SoundboardController

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if controller.cues.isEmpty {
                emptyState
            } else {
                cueList
            }

            Divider()
            footerHint
        }
    }

    // MARK: Header

    @ViewBuilder
    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Live soundboard")
                    .font(.headline)
                Text("Audio cues you can trigger with a hotkey during recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                runAddCuePanel()
            } label: {
                Label("Add cue…", systemImage: "plus")
            }
            .controlSize(.regular)
        }
        .padding(14)
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No cues yet")
                .font(.title3.weight(.medium))
            Text("Click \"Add cue…\" to load a WAV, MP3, or M4A file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: Cue list

    @ViewBuilder
    private var cueList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(controller.cues) { cue in
                    CueRow(cue: cue, controller: controller)
                    Divider()
                }
            }
        }
    }

    // MARK: Footer hint + options

    @ViewBuilder
    private var footerHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Mute speakers during recording", isOn: Binding(
                get: { Settings.shared.soundboardMuteSpeakersDuringRecording },
                set: { Settings.shared.soundboardMuteSpeakersDuringRecording = $0 }
            ))
            .help("Silences cue playback through your speakers while recording. Cues still get written to the recording's soundboard track — this just prevents the mic from double-capturing them if you're not on headphones.")

            VStack(alignment: .leading, spacing: 4) {
                Text("Trigger globally: hotkeys fire whatever app is focused. Pick modifier combos your demo app doesn't use.")
                Text("Cues play through your default output (unless muted above) and are baked into the exported MP4.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: Add-cue file picker

    @MainActor
    private func runAddCuePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.audio, UTType.mp3, UTType.wav]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "Add soundboard cue"
        panel.message = "Choose one or more audio files."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let name = url.deletingPathExtension().lastPathComponent
            controller.addCue(SoundCue(name: name, fileURL: url))
        }
    }
}

// MARK: - Row

private struct CueRow: View {
    let cue: SoundCue
    @Bindable var controller: SoundboardController

    var body: some View {
        HStack(spacing: 10) {
            // Test-play toggle — tap to preview, tap again to stop.
            let isPlaying = controller.testPlayingCueIDs.contains(cue.id)
            Button {
                controller.testPlay(cue: cue)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isPlaying ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Stop \(cue.name)" : "Preview \(cue.name)")

            // Editable name
            TextField("Name", text: Binding(
                get: { cue.name },
                set: { newValue in
                    var updated = cue
                    updated.name = newValue
                    controller.updateCue(updated)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 160)

            // Volume
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(cue.volume) },
                        set: { v in
                            var updated = cue
                            updated.volume = Float(v)
                            controller.updateCue(updated)
                        }
                    ),
                    in: 0.0...1.5
                )
                .frame(width: 100)
            }

            Spacer()

            // Hotkey cell
            hotkeyCell

            // Delete
            Button {
                controller.removeCue(id: cue.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(cue.name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var hotkeyCell: some View {
        let isCapturing = controller.capturingHotkeyForCueID == cue.id

        HStack(spacing: 4) {
            Button {
                if isCapturing {
                    controller.cancelCapturingHotkey()
                } else {
                    controller.beginCapturingHotkey(for: cue.id)
                }
            } label: {
                Text(hotkeyLabel(isCapturing: isCapturing))
                    .frame(minWidth: 96)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isCapturing ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                    )
                    .monospacedDigit()
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isCapturing ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)

            if cue.hotkey != nil, !isCapturing {
                Button {
                    controller.clearHotkey(for: cue.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear hotkey")
            }
        }
    }

    private func hotkeyLabel(isCapturing: Bool) -> String {
        if isCapturing { return "Press keys…  (esc)" }
        if let hotkey = cue.hotkey { return hotkey.displayString }
        return "Click to bind"
    }
}
