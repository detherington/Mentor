import AppKit
import SwiftUI
import AVFoundation

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Mentor Settings"
        win.contentView = NSHostingView(rootView: SettingsView())
        win.center()
        win.isReleasedWhenClosed = false
        self.window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @State private var webcamPosition  = Settings.shared.webcamPosition
    @State private var webcamShape     = Settings.shared.webcamShape
    @State private var webcamDiameter  = Settings.shared.webcamDiameter
    @State private var showWebcamPreview = Settings.shared.showWebcamPreview
    @State private var systemAudio     = Settings.shared.captureSystemAudio
    @State private var countdownEnabled = Settings.shared.countdownEnabled
    @State private var countdownSeconds = Settings.shared.countdownSeconds
    @State private var hideMenuBar     = Settings.shared.hideMenuBarIconWhenRecording
    @State private var cameraDeviceID: String = Settings.shared.cameraDeviceID ?? ""
    @State private var micDeviceID: String    = Settings.shared.microphoneDeviceID ?? ""
    @State private var availableCameras: [AVCaptureDevice] = []
    @State private var availableMics: [AVCaptureDevice]    = []

    var body: some View {
        Form {
            Section("Devices") {
                Picker("Camera", selection: $cameraDeviceID) {
                    Text("System Default").tag("")
                    ForEach(availableCameras, id: \.uniqueID) { dev in
                        Text(dev.localizedName).tag(dev.uniqueID)
                    }
                }
                .onChange(of: cameraDeviceID) { _, v in
                    Settings.shared.cameraDeviceID = v.isEmpty ? nil : v
                }

                Picker("Microphone", selection: $micDeviceID) {
                    Text("System Default").tag("")
                    ForEach(availableMics, id: \.uniqueID) { dev in
                        Text(dev.localizedName).tag(dev.uniqueID)
                    }
                }
                .onChange(of: micDeviceID) { _, v in
                    Settings.shared.microphoneDeviceID = v.isEmpty ? nil : v
                }

                Text("Changes apply immediately to the preview and to the next recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Webcam") {
                Picker("Shape", selection: $webcamShape) {
                    ForEach(WebcamShape.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: webcamShape) { _, v in Settings.shared.webcamShape = v }

                Picker("Position", selection: $webcamPosition) {
                    ForEach(WebcamPosition.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: webcamPosition) { _, v in Settings.shared.webcamPosition = v }

                HStack {
                    Text("Frame size")
                    Slider(value: $webcamDiameter, in: 200...800)
                        .onChange(of: webcamDiameter) { _, v in Settings.shared.webcamDiameter = v }
                    Text("\(Int(webcamDiameter))pt")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }

                Text("Sets the diameter of the circular webcam overlay. The framing stays the same at any size — the whole circle scales up or down together.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show floating preview", isOn: $showWebcamPreview)
                    .onChange(of: showWebcamPreview) { _, v in Settings.shared.showWebcamPreview = v }
            }

            Section("Audio") {
                Toggle("Capture system audio", isOn: $systemAudio)
                    .onChange(of: systemAudio) { _, v in Settings.shared.captureSystemAudio = v }
            }

            Section("Recording") {
                Toggle("Countdown before recording", isOn: $countdownEnabled)
                    .onChange(of: countdownEnabled) { _, v in Settings.shared.countdownEnabled = v }

                if countdownEnabled {
                    Stepper(value: $countdownSeconds, in: 1...10) {
                        Text("Countdown duration: \(countdownSeconds) sec")
                    }
                    .onChange(of: countdownSeconds) { _, v in Settings.shared.countdownSeconds = v }
                }

                Toggle("Hide menu bar icon while recording", isOn: $hideMenuBar)
                    .onChange(of: hideMenuBar) { _, v in Settings.shared.hideMenuBarIconWhenRecording = v }

                Text("Each recording writes a `.mentor` sidecar (raw screen + webcam + audio + event log) used by the editor. The composited MP4 is rendered in the background after you stop recording so live capture runs smoothly at full frame rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                HStack {
                    Text(CaptureCoordinator.outputDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal") {
                        let dir = CaptureCoordinator.outputDirectory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .onAppear { reloadDevices() }
    }

    private func reloadDevices() {
        availableCameras = CameraCapture.availableVideoDevices()
        availableMics    = CameraCapture.availableAudioDevices()
    }
}
