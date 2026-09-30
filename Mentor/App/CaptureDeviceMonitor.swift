import AppKit
import AVFoundation
import ApplicationServices

/// Camera + microphone access and device changes for the capture session:
/// asks for access and brings the session up (retrying when a device
/// appears), follows hot-plug and device picks in Settings, and prompts
/// for Accessibility.
@MainActor
final class CaptureDeviceMonitor {
    /// True while a recording is starting, running or stopping — device
    /// swaps then leave still-connected devices alone.
    var isRecordingInFlight: () -> Bool = { false }
    /// The session came up or swapped inputs — refresh the webcam preview.
    var onSessionChanged: () -> Void = {}
    /// The camera went away with nothing to fall back to.
    var onCameraLost: () -> Void = {}
    var showError: (String) -> Void = { _ in }

    private let coordinator: CaptureCoordinator
    private var observers: [NSObjectProtocol] = []
    private var lastKnownCameraDeviceID: String?
    private var lastKnownMicDeviceID: String?

    init(coordinator: CaptureCoordinator) {
        self.coordinator = coordinator
        lastKnownCameraDeviceID = Settings.shared.cameraDeviceID
        lastKnownMicDeviceID = Settings.shared.microphoneDeviceID
    }

    func startMonitoring() {
        observers = [
            // Hot-plug: if the session failed to configure at launch because
            // no device was connected, retry; if it's running, swap inputs so
            // the user's saved device wins when it comes online.
            NotificationCenter.default.addObserver(
                forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.deviceConnected() }
            },
            // Hot-unplug: fall back to another device if one is available,
            // otherwise clear the preview so it doesn't sit on a stale frame.
            NotificationCenter.default.addObserver(
                forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.deviceDisconnected() }
            },
        ]
    }

    func stopMonitoring() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    /// Settings may have picked a different camera or mic — swap the
    /// session's inputs live. Mid-recording picks apply when it ends.
    func settingsChanged() {
        let currentCamera = Settings.shared.cameraDeviceID
        let currentMic = Settings.shared.microphoneDeviceID
        guard currentCamera != lastKnownCameraDeviceID || currentMic != lastKnownMicDeviceID else { return }
        lastKnownCameraDeviceID = currentCamera
        lastKnownMicDeviceID = currentMic
        coordinator.reconfigureDevices(keepConnectedDevices: isRecordingInFlight())
    }

    /// Catch up on device changes held off during a recording. A no-op
    /// when nothing changed.
    func recordingEnded() {
        coordinator.reconfigureDevices()
    }

    func startSessionWithPermissions() async {
        let camOK = await ensure(.video)
        let micOK = await ensure(.audio)
        MentorDebug.log("APP: permissions cam=\(camOK) mic=\(micOK)")
        // Either one is enough — `configure()` sets up whichever input is
        // authorised. Requiring both meant a denied camera also meant no
        // mic, and every recording was silently voiceless.
        guard camOK || micOK else { return }
        do {
            try coordinator.startCameraSession()
            MentorDebug.log("APP: camera session started")
        } catch CaptureError.noCamera {
            // Absent camera at launch is a valid state — user may plug one in
            // later, or only want screen recording. Don't show a modal error
            // dialog; the hot-plug observer will retry when a device appears,
            // and the actual record flow surfaces its own error if still
            // missing at record time.
            MentorDebug.log("APP: no camera at launch — will retry on device connect")
        } catch {
            MentorDebug.log("APP: camera setup failed: \(error.localizedDescription)")
            showError("Camera setup failed: \(error.localizedDescription)")
        }
    }

    /// Fires when any AVCaptureDevice is connected to the system. We get
    /// this for every device type (camera, mic, external) so this runs
    /// whether it's a webcam plug-in, Continuity Camera wake, or a USB
    /// mic. Always safe to run even when nothing changed — `configure()`
    /// and `reconfigureDevices()` are both idempotent.
    private func deviceConnected() {
        if !coordinator.cameraCapture.isConfigured {
            MentorDebug.log("APP: device connected — retrying camera setup")
            Task { @MainActor in
                await self.startSessionWithPermissions()
                self.onSessionChanged()
            }
        } else {
            MentorDebug.log("APP: device connected — reconfiguring inputs")
            coordinator.reconfigureDevices(keepConnectedDevices: isRecordingInFlight())
            onSessionChanged()
        }
    }

    /// Camera (or mic) was unplugged / turned off. Re-resolve inputs so a
    /// still-present fallback device can take over; if nothing's left,
    /// wipe the preview so it doesn't sit on the last captured frame.
    private func deviceDisconnected() {
        guard coordinator.cameraCapture.isConfigured else { return }
        MentorDebug.log("APP: device disconnected — reconfiguring inputs")
        coordinator.reconfigureDevices(keepConnectedDevices: isRecordingInFlight())
        if CameraCapture.resolveVideoDevice() == nil {
            onCameraLost()
        }
    }

    private func ensure(_ type: AVMediaType) async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: type)
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: type)
        }
        return status == .authorized
    }

    /// Trigger the Accessibility prompt if the user hasn't granted it yet.
    /// Needed so `NSEvent.addGlobalMonitorForEvents` actually receives mouse
    /// and key events outside Mentor — that's the backbone of the event log
    /// used by the editor's smart-zoom feature.
    func promptForAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let options: CFDictionary = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
