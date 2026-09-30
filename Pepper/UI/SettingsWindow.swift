import AppKit
import SwiftUI
import AVFoundation
import Carbon.HIToolbox

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
        win.title = "Pepper Settings"
        win.contentView = NSHostingView(rootView: SettingsView())
        win.center()
        win.setFrameAutosaveName("PepperSettings")
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

    // Orbis form state. Connection state itself is read straight from
    // `OrbisAccount.shared` (observable), so it's never stale.
    @State private var orbisHost: String            = OrbisSettings.shared.host
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

                Text("Each recording writes a `.pepper` sidecar (raw screen + webcam + audio + event log) used by the editor. The composited MP4 is rendered in the background after you stop recording so live capture runs smoothly at full frame rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                ShortcutRow(binding: .recordToggle)
                ShortcutRow(binding: .pauseToggle)
                Text("Global: they work whichever app is in front, so pick combos your other apps don't use (⌘⇧R is also a browser hard-reload). Pause only listens while a recording is running. Combos need ⌘, ⌥ or ⌃.")
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

            Section("Setup") {
                HStack {
                    Text("Walk through permissions and Orbis sign-in again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Setup Guide…") { OnboardingWindowController.shared.show(fromStart: true) }
                }
            }

            Section("Orbis") {
                let account = OrbisAccount.shared
                HStack {
                    Circle()
                        .fill(account.isConnected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    if account.isConnected {
                        Text("Signed in as \(account.userName ?? "?")").font(.caption)
                    } else {
                        Text("Not connected").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if account.isSigningIn {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser…").font(.caption)
                        Spacer()
                        Button("Cancel") { account.cancelSignIn() }
                    }
                } else if account.isConnected {
                    HStack {
                        Button("Sign Out", role: .destructive) { signOutOfOrbis() }
                        Button(orbisTesting ? "Testing…" : "Test connection") { testOrbisConnection() }
                            .disabled(orbisTesting)
                    }
                } else {
                    Button("Sign In with Orbis…") { signInToOrbis() }
                        .buttonStyle(.borderedProminent)
                }

                if let result = orbisTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Host", text: $orbisHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitOrbisHost() }
                Text("Sign-ins are kept per host, so changing it never sends your credentials to a different server. Orbis stores your recordings in a Cloudflare-backed video library; once connected, \"Export to Orbis\" appears in the editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 760)
        .onAppear {
            reloadDevices()
            orbisHost = OrbisSettings.shared.host
        }
    }

    private func reloadDevices() {
        availableCameras = CameraCapture.availableVideoDevices()
        availableMics    = CameraCapture.availableAudioDevices()
    }

    // MARK: - Orbis actions

    /// Every action commits the host field first — "Test connection"
    /// used to run against the previously saved host.
    private func commitOrbisHost() {
        OrbisSettings.shared.host = orbisHost
        orbisHost = OrbisSettings.shared.host
        OrbisAccount.shared.syncHost()
    }

    private func signInToOrbis() {
        commitOrbisHost()
        orbisTestResult = nil
        Task { @MainActor in
            do {
                try await OrbisAccount.shared.signIn()
            } catch OAuthLoopbackServer.LoopbackError.cancelled {
                // User pressed Cancel — nothing to report.
            } catch is CancellationError {
            } catch {
                orbisTestResult = error.localizedDescription
            }
        }
    }

    private func signOutOfOrbis() {
        orbisTestResult = nil
        Task { @MainActor in await OrbisAccount.shared.signOut() }
    }

    private func testOrbisConnection() {
        commitOrbisHost()
        orbisTesting = true
        orbisTestResult = nil
        Task { @MainActor in
            do {
                orbisTestResult = "Connected as \(try await OrbisAccount.shared.verify())."
            } catch {
                orbisTestResult = error.localizedDescription
            }
            orbisTesting = false
        }
    }
}

/// One global-shortcut row: the current combo (click to record a new
/// one), plus clear and reset-to-default. Captures with a local key
/// monitor; the live Carbon bindings are dropped meanwhile (see
/// `GlobalHotkey.captureWillBegin`) so pressing the current combo reaches
/// the recorder instead of starting a recording.
private struct ShortcutRow: View {
    let binding: HotkeyBinding
    @State private var combo: CueHotkey?
    @State private var isCapturing = false
    @State private var monitor: Any?

    init(binding: HotkeyBinding) {
        self.binding = binding
        _combo = State(initialValue: Settings.shared.shortcut(for: binding))
    }

    var body: some View {
        HStack {
            Text(binding.displayName)
            Spacer()
            Button {
                if isCapturing { stopCapture() } else { startCapture() }
            } label: {
                Text(isCapturing ? "Press keys…  (esc)" : (combo?.displayString ?? "None"))
                    .frame(minWidth: 90)
                    .monospacedDigit()
            }
            if combo != nil, !isCapturing {
                Button {
                    save(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove this shortcut")
                .accessibilityLabel("Remove shortcut")
            }
            if combo != binding.defaultCombo, !isCapturing {
                Button("Default") {
                    Settings.shared.resetShortcut(for: binding)
                    combo = binding.defaultCombo
                }
            }
        }
        .onDisappear { stopCapture() }
    }

    private func startCapture() {
        NotificationCenter.default.post(name: GlobalHotkey.captureWillBegin, object: nil)
        isCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopCapture()
            } else if let captured = CueHotkey(capturing: event) {
                save(captured)
                stopCapture()
            } else {
                // No ⌘ / ⌥ / ⌃ — not safe as a global shortcut.
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopCapture() {
        guard isCapturing else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isCapturing = false
        NotificationCenter.default.post(name: GlobalHotkey.captureDidEnd, object: nil)
    }

    private func save(_ newCombo: CueHotkey?) {
        Settings.shared.setShortcut(newCombo, for: binding)
        combo = newCombo
    }
}
