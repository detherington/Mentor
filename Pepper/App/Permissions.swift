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
    /// macOS has one of its own requests on screen (possibly behind our
    /// window), for the walkthrough's "Show It" link.
    private(set) var systemPromptShowing = false

    /// Asked macOS for these this launch. Kept in memory, not in
    /// UserDefaults: saved state outlives deleting the app and resetting
    /// its permissions (Muesli hit this), and a saved "asked" would then
    /// skip the request that puts Pepper back in System Settings' list,
    /// opening a pane without Pepper in it.
    @ObservationIgnored private var askedThisLaunch: Set<SystemSettingsPane> = []

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
        systemPromptShowing = SystemPrompts.isShowing
        #if DEBUG
        if debugReportNothingGranted {
            (screenRecording, camera, microphone, accessibility) = (.notDetermined, .notDetermined, .notDetermined, .notDetermined)
            // The render hook's un-granted pass also shows the "macOS is
            // asking" note, which otherwise only appears mid-request.
            systemPromptShowing = true
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

    /// The first time, asks macOS, which lists Pepper under Screen
    /// Recording and shows its own request, whose Open System Settings
    /// button goes to the pane. Afterwards the request does nothing, so
    /// straight to the pane. (See `askOnceThenOpen`.)
    func requestScreenRecording() {
        refresh()
        guard screenRecording != .granted else { return }
        askOnceThenOpen(.screenRecording) {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    func requestCamera() { request(.video) }
    func requestMicrophone() { request(.audio) }

    /// The first time, asks macOS, which lists Pepper under Accessibility
    /// and usually shows its own request; afterwards, straight to the pane.
    func requestAccessibility() {
        refresh()
        guard accessibility != .granted else { return }
        askOnceThenOpen(.accessibility) {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
    }

    /// Muesli's pattern. Asking macOS and opening System Settings at once
    /// put two things on screen: the pane, and macOS's request, which
    /// nothing dismissed and which ended up behind the windows. So: the
    /// first time this launch, only ask (which also lists Pepper in the
    /// pane), and open the pane after a moment only if macOS showed
    /// nothing (it stays quiet when it has asked before). After that, the
    /// pane.
    private func askOnceThenOpen(_ pane: SystemSettingsPane, ask: () -> Void) {
        guard askedThisLaunch.insert(pane).inserted else {
            openSettings(pane)
            return
        }
        ask()
        Task { @MainActor in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(250))
                if SystemPrompts.isShowing {
                    systemPromptShowing = true
                    return
                }
            }
            refresh()
            let state = pane == .screenRecording ? screenRecording : accessibility
            if state != .granted { openSettings(pane) }
        }
    }

    /// Opens a System Settings pane, unless macOS is asking something
    /// right now: then that request comes to the front instead, so it
    /// isn't left behind the Settings window.
    func openSettings(_ pane: SystemSettingsPane) {
        if SystemPrompts.bringToFront() { return }
        pane.open()
    }

    /// A denied camera or mic can't be asked again — only System Settings
    /// can turn it back on.
    private func request(_ type: AVMediaType) {
        guard Self.state(for: type) == .notDetermined else {
            openSettings(SystemSettingsPane(mediaType: type))
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
