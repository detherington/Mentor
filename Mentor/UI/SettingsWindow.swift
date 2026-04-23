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
    @State private var countdownBeep    = Settings.shared.countdownBeepEnabled
    @State private var countdownGo      = Settings.shared.countdownShowGo
    @State private var hideMenuBar     = Settings.shared.hideMenuBarIconWhenRecording
    @State private var cameraDeviceID: String = Settings.shared.cameraDeviceID ?? ""
    @State private var micDeviceID: String    = Settings.shared.microphoneDeviceID ?? ""
    @State private var availableCameras: [AVCaptureDevice] = []
    @State private var availableMics: [AVCaptureDevice]    = []

    // Orbis state — mirror `OrbisSettings.shared` + Keychain into
    // @State so SwiftUI renders reactively. Refreshed on
    // `OrbisSettings.didChange` and after Connect / Disconnect /
    // Test Connection actions.
    @State private var orbisHost: String            = OrbisSettings.shared.host
    @State private var orbisConnected: Bool         = OrbisSettings.shared.isConnected
    @State private var orbisUserName: String?       = OrbisSettings.shared.connectedUserName
    @State private var orbisTestResult: String?     = nil
    @State private var orbisTesting: Bool           = false

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

                    Toggle("Beep on each tick", isOn: $countdownBeep)
                        .onChange(of: countdownBeep) { _, v in Settings.shared.countdownBeepEnabled = v }

                    Toggle("Flash \"Go!\" when countdown reaches zero", isOn: $countdownGo)
                        .onChange(of: countdownGo) { _, v in Settings.shared.countdownShowGo = v }
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

            Section("Orbis") {
                TextField("Host", text: $orbisHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { OrbisSettings.shared.host = orbisHost }

                HStack {
                    Circle()
                        .fill(orbisConnected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    if orbisConnected, let name = orbisUserName {
                        Text("Connected as \(name)").font(.caption)
                    } else {
                        Text("Not connected").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack {
                    if orbisConnected {
                        Button("Disconnect", role: .destructive) {
                            OrbisSettings.shared.host = orbisHost
                            disconnectOrbis()
                        }
                        Button(orbisTesting ? "Testing…" : "Test connection") {
                            testOrbisConnection()
                        }
                        .disabled(orbisTesting)
                    } else {
                        Button("Connect to Orbis") {
                            OrbisSettings.shared.host = orbisHost
                            connectOrbis()
                        }
                    }
                }
                if let result = orbisTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Orbis stores your recordings in a Cloudflare-backed video library. After you connect, an \"Export to Orbis\" action appears in the editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 760)
        .onAppear {
            reloadDevices()
            refreshOrbisState()
        }
        .onReceive(NotificationCenter.default.publisher(for: OrbisSettings.didChange)) { _ in
            refreshOrbisState()
        }
    }

    private func reloadDevices() {
        availableCameras = CameraCapture.availableVideoDevices()
        availableMics    = CameraCapture.availableAudioDevices()
    }

    // MARK: - Orbis actions

    private func refreshOrbisState() {
        orbisHost      = OrbisSettings.shared.host
        orbisConnected = OrbisSettings.shared.isConnected
        orbisUserName  = OrbisSettings.shared.connectedUserName
    }

    /// Open the browser to the Orbis PAT page. The callback
    /// (`mentor://orbis-token?…`) is handled by `AppDelegate` once
    /// the user finishes creating a token — no further action
    /// needed on this side.
    private func connectOrbis() {
        guard let url = OrbisSettings.shared.connectURL() else {
            orbisTestResult = "Can't open host URL. Check that the host is valid."
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func disconnectOrbis() {
        OrbisKeychain.deleteToken()
        OrbisSettings.shared.connectedUserName = nil
        orbisTestResult = nil
        refreshOrbisState()
    }

    /// Hit `GET /api/auth/me`. Success → update the cached user name.
    /// 401 → wipe the token + prompt re-auth. Anything else → show
    /// the raw error so the user knows the server side is unhappy.
    private func testOrbisConnection() {
        guard let token = OrbisKeychain.loadToken() else {
            orbisTestResult = "Not connected."
            return
        }
        orbisTesting = true
        orbisTestResult = nil
        Task { @MainActor in
            let client = OrbisClient(host: OrbisSettings.shared.host, token: token)
            do {
                let me = try await client.me()
                OrbisSettings.shared.connectedUserName = me.name ?? me.email ?? "Connected"
                orbisTestResult = "Connected as \(OrbisSettings.shared.connectedUserName ?? "?")."
            } catch OrbisError.tokenInvalid {
                OrbisKeychain.deleteToken()
                OrbisSettings.shared.connectedUserName = nil
                orbisTestResult = "Token expired. Reconnect to refresh."
            } catch {
                orbisTestResult = error.localizedDescription
            }
            orbisTesting = false
            refreshOrbisState()
        }
    }
}
