import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import Observation

/// Where a permission stands, as far as macOS lets us tell. Screen
/// Recording and Accessibility only report on or off, so "off" reads as
/// not allowed yet rather than denied.
enum PermissionState: Equatable {
    case granted, notDetermined, denied

    var label: String {
        switch self {
        case .granted:       return "Allowed"
        case .notDetermined: return "Not allowed yet"
        case .denied:        return "Denied"
        }
    }

    var symbolName: String {
        switch self {
        case .granted:       return "checkmark.circle.fill"
        case .notDetermined: return "circle.dashed"
        case .denied:        return "xmark.circle.fill"
        }
    }
}

/// The four privacy permissions Pepper records with, for the setup
/// walkthrough. `refresh()` only reads; the `request…` methods show the
/// system prompts and are called from a button click, never on their own.
/// Before onboarding, launch asked for camera, mic and Accessibility all
/// at once with no context.
@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()

    private(set) var screenRecording: PermissionState = .notDetermined
    private(set) var camera: PermissionState = .notDetermined
    private(set) var microphone: PermissionState = .notDetermined
    private(set) var accessibility: PermissionState = .notDetermined

    /// Camera or mic access was just granted — the capture session needs
    /// bringing up (or its inputs adding). Set by `AppDelegate`.
    @ObservationIgnored var onCaptureAccessChanged: () -> Void = {}

    #if DEBUG
    /// Onboarding's render hook: report everything as not allowed yet, so
    /// the walkthrough's un-granted layouts can be checked on a Mac that
    /// has already granted them.
    @ObservationIgnored var debugReportNothingGranted = false
    #endif

    private init() { refresh() }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        camera = Self.state(for: .video)
        microphone = Self.state(for: .audio)
        accessibility = AXIsProcessTrusted() ? .granted : .notDetermined
        #if DEBUG
        if debugReportNothingGranted {
            (screenRecording, camera, microphone, accessibility) = (.notDetermined, .notDetermined, .notDetermined, .notDetermined)
        }
        #endif
    }

    /// `refresh()` for the walkthrough's once-a-second check. True when
    /// something was just switched on outside Pepper (System Settings), so
    /// the walkthrough can come back to the front. A camera or mic turned
    /// on there also brings the capture session up.
    func poll() -> Bool {
        let before = (screenRecording, camera, microphone, accessibility)
        refresh()
        let captureGranted = (before.1 != .granted && camera == .granted)
            || (before.2 != .granted && microphone == .granted)
        if captureGranted { onCaptureAccessChanged() }
        return captureGranted
            || (before.0 != .granted && screenRecording == .granted)
            || (before.3 != .granted && accessibility == .granted)
    }

    /// First time: macOS shows its own request and lists Pepper in System
    /// Settings. After that the request does nothing, so open the pane,
    /// where the person switches Pepper on themselves.
    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            SystemSettingsPane.screenRecording.open()
        }
        refresh()
    }

    func requestCamera() { request(.video) }
    func requestMicrophone() { request(.audio) }

    /// Lists Pepper under Accessibility (macOS may show its own request)
    /// and opens that pane: the request alone often never appears.
    func requestAccessibility() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) {
            SystemSettingsPane.accessibility.open()
        }
        refresh()
    }

    /// A denied camera or mic can't be asked again — only System Settings
    /// can turn it back on.
    private func request(_ type: AVMediaType) {
        guard Self.state(for: type) == .notDetermined else {
            SystemSettingsPane(mediaType: type).open()
            return
        }
        Task { @MainActor in
            let granted = await AVCaptureDevice.requestAccess(for: type)
            refresh()
            if granted { onCaptureAccessChanged() }
        }
    }

    private static func state(for type: AVMediaType) -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:            return .granted
        case .notDetermined:         return .notDetermined
        case .denied, .restricted:   return .denied
        @unknown default:            return .denied
        }
    }
}

/// Privacy & Security panes in System Settings. Opening one never
/// triggers a permission prompt.
enum SystemSettingsPane: String {
    case screenRecording = "Privacy_ScreenCapture"
    case camera = "Privacy_Camera"
    case microphone = "Privacy_Microphone"
    case accessibility = "Privacy_Accessibility"
    case speechRecognition = "Privacy_SpeechRecognition"

    init(mediaType: AVMediaType) {
        self = mediaType == .video ? .camera : .microphone
    }

    func open() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)") else { return }
        NSWorkspace.shared.open(url)
    }
}
