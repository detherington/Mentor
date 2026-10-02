import AppKit
import SwiftUI

/// The setup walkthrough, modelled on Muesli's onboarding so the SBS
/// apps set up the same way: black window, brand type, one step per
/// permission, one Neon action per screen. Every permission prompt fires
/// from a button here; nothing asks on appear.
///
/// welcome → screen recording → camera → microphone → accessibility →
/// sign in to Orbis → done. Everything after the welcome can be skipped;
/// recording asks for a skipped camera or mic later, when it's obvious
/// why. The step on screen is saved so a relaunch mid-setup (macOS asks
/// to Quit & Reopen once Screen Recording is on) resumes there.
struct OnboardingView: View {
    enum Step: String, CaseIterable {
        case welcome, screenRecording, camera, microphone, accessibility, orbis, done
    }

    var onFinish: () -> Void

    @State private var index: Int
    @State private var orbisError: String?
    private let permissions = Permissions.shared
    private let account = OrbisAccount.shared
    private let steps = Step.allCases

    init(startAt start: Step? = nil, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        let resumed = start ?? Settings.shared.onboardingStep.flatMap(Step.init(rawValue:)) ?? .welcome
        _index = State(initialValue: Step.allCases.firstIndex(of: resumed) ?? 0)
    }

    private var step: Step { steps[min(index, steps.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(index), total: Double(steps.count - 1))
                .padding(.horizontal, 40)
                .padding(.top, 36)  // clear of the transparent title bar's close button
                .opacity(step == .welcome ? 0 : 1)

            VStack(spacing: 20) {
                Spacer(minLength: 0)
                stepContent
                Spacer(minLength: 0)
                if isPermissionStep, permissions.systemPromptShowing {
                    hiddenRequestNote
                }
                navigation
            }
            .padding(40)
        }
        .frame(width: 620, height: 580)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .tint(Brand.accent)
        .watchingPermissions(permissions)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .screenRecording: screenRecordingStep
        case .camera: cameraStep
        case .microphone: microphoneStep
        case .accessibility: accessibilityStep
        case .orbis: orbisStep
        case .done: doneStep
        }
    }

    private var isPermissionStep: Bool {
        [.screenRecording, .camera, .microphone, .accessibility].contains(step)
    }

    /// macOS's request is a window of its own, and clicking this one can
    /// cover it; nothing on screen then says why the step is waiting.
    private var hiddenRequestNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("macOS is asking for permission. Can't see its window? It may be behind this one.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Show It") { SystemPrompts.bringToFront() }
                .buttonStyle(.link)
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        HStack(spacing: 36) {
            // The icon file is square artwork; round it the way macOS shows icons.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 200 * 0.225, style: .continuous))
                .shadow(color: .black.opacity(0.6), radius: 28, y: 18)
            VStack(alignment: .leading, spacing: 16) {
                Text("Welcome").brandKicker(11, color: Brand.neon)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Meet").brandDisplay(54)
                    Text("Pepper").font(Brand.serif(54)).textCase(.uppercase).tracking(-1.1)
                }
                Text("Walkthroughs that edit themselves. Pepper records your screen, camera and voice, zooms in where you click, writes the captions, and sends the finished video straight to Orbis.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340, alignment: .leading)
            }
        }
    }

    private var screenRecordingStep: some View {
        PermissionStepView(
            icon: "rectangle.dashed.badge.record",
            title: "Screen Recording",
            explanation: "Pepper records the display, window or area you pick, along with the sound your Mac plays. macOS asks once; after that it's a switch in System Settings.",
            status: permissions.screenRecording
        ) {
            if permissions.screenRecording != .granted {
                VStack(spacing: 10) {
                    Button("Allow Screen Recording") { permissions.requestScreenRecording() }
                        .buttonStyle(.borderedProminent)
                    // macOS applies the switch to a new process only.
                    Text("Already switched on? macOS applies it once Pepper reopens.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Quit & Reopen Pepper") { relaunchHere() }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private var cameraStep: some View {
        PermissionStepView(
            icon: "video.fill",
            title: "Camera",
            explanation: "Pepper films you for the webcam bubble in your recordings. You can move, restyle or hide it for each recording, or record without it.",
            status: permissions.camera
        ) {
            if permissions.camera != .granted {
                Button(permissions.camera == .denied ? "Open Camera Settings" : "Allow Camera Access") {
                    permissions.requestCamera()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var microphoneStep: some View {
        PermissionStepView(
            icon: "mic.fill",
            title: "Microphone",
            explanation: "Pepper records your narration, then uses it to write captions and trim the silences.",
            status: permissions.microphone
        ) {
            if permissions.microphone != .granted {
                Button(permissions.microphone == .denied ? "Open Microphone Settings" : "Allow Microphone Access") {
                    permissions.requestMicrophone()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// macOS has no Allow button for Accessibility: the person switches
    /// Pepper on themselves, so the step walks them there and turns green
    /// (bringing Pepper back) once it's on.
    private var accessibilityStep: some View {
        let granted = permissions.accessibility == .granted
        return VStack(spacing: 14) {
            Image(systemName: "accessibility").font(.system(size: 36)).foregroundStyle(Brand.accentText)
            Text("Accessibility").brandDisplay(24)
            AccessibilitySetupView(isGranted: granted)
            if !granted {
                Button("Open Accessibility Settings") { permissions.requestAccessibility() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var orbisStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 44)).foregroundStyle(Brand.accentText)
            Text("Sign in to Orbis").brandDisplay(24)
            Text("Export to Orbis sends a finished recording, with its captions and a thumbnail, straight to your Orbis video library. Sign in with your Orbis account; your browser will open.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            if account.isConnected {
                Label("Signed in as \(account.userName ?? "your Orbis account")", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Brand.emerald)
            } else if account.isSigningIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for sign-in in your browser…").font(.callout).foregroundStyle(.secondary)
                }
                Button("Cancel") { account.cancelSignIn() }
                    .buttonStyle(.link)
            } else {
                Button("Sign in to Orbis…") { signInToOrbis() }
                    .buttonStyle(.borderedProminent)
                if let orbisError {
                    Text(orbisError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Brand.emerald)
            Text("You're all set").brandDisplay(30)
            Text(doneMessage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
        }
    }

    private var doneMessage: String {
        let start = Settings.shared.shortcut(for: .recordToggle).map { "Press \($0.displayString) from anywhere" }
            ?? "Click the menu bar icon"
        return "Pepper lives in the menu bar. \(start) to start recording."
    }

    // MARK: - Navigation

    private var navigation: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { go(to: index - 1) }
                    .buttonStyle(QuietButtonStyle())
            }
            Spacer()
            // The one Neon action per screen: steps with their own
            // prominent button (Allow, Sign in) keep the navigation quiet.
            if step == .welcome || step == .done {
                Button(primaryButtonTitle) { advance() }
                    .buttonStyle(NeonButtonStyle(height: 40))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(primaryButtonTitle) { advance() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == .orbis && account.isSigningIn)
            }
        }
    }

    private var primaryButtonTitle: String {
        switch step {
        case .welcome:         return "Get Started"
        case .done:            return "Start Using Pepper"
        case .screenRecording: return permissions.screenRecording == .granted ? "Continue" : "Skip for Now"
        case .camera:          return permissions.camera == .granted ? "Continue" : "Skip for Now"
        case .microphone:      return permissions.microphone == .granted ? "Continue" : "Skip for Now"
        case .accessibility:   return permissions.accessibility == .granted ? "Continue" : "Skip for Now"
        case .orbis:           return account.isConnected ? "Continue" : "Skip for Now"
        }
    }

    private func advance() {
        guard index + 1 < steps.count else {
            Settings.shared.hasCompletedOnboarding = true
            Settings.shared.onboardingStep = nil
            onFinish()
            return
        }
        go(to: index + 1)
    }

    private func go(to newIndex: Int) {
        index = max(0, min(newIndex, steps.count - 1))
        Settings.shared.onboardingStep = step.rawValue
    }

    private func relaunchHere() {
        Settings.shared.onboardingStep = step.rawValue
        AppRelauncher.relaunch()
    }

    private func signInToOrbis() {
        orbisError = nil
        Task { @MainActor in
            do {
                try await account.signIn()
            } catch OAuthLoopbackServer.LoopbackError.cancelled {
                // Cancel pressed: nothing to report.
            } catch is CancellationError {
            } catch {
                orbisError = error.localizedDescription
            }
        }
    }
}

/// Shared layout for one permission: icon, explanation, status, and the
/// step's own action.
private struct PermissionStepView<Actions: View>: View {
    let icon: String
    let title: String
    let explanation: String
    let status: PermissionState
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(Brand.accentText)
            Text(title).brandDisplay(24)
            Text(explanation)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            Label(status.label, systemImage: status.symbolName)
                .font(.callout)
                .foregroundStyle(status == .granted ? Brand.emerald : .secondary)
            actions
        }
    }
}

/// What Pepper reads with Accessibility and why, the switch to turn on in
/// System Settings, and whether it's on. Muesli's walkthrough, with
/// Pepper's reasons.
private struct AccessibilitySetupView: View {
    let isGranted: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("While you record, Pepper notes your clicks and key presses so smart zoom can follow your cursor and your shortcuts can show on screen. It also makes soundboard shortcuts work in any app. They stay with the recording on your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 500)
            if isGranted {
                Label("Pepper is allowed", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Brand.emerald)
            } else {
                walkthrough
            }
        }
    }

    private var walkthrough: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                step(1, "Click **Open Accessibility Settings**.")
                step(2, "Switch **Pepper** on. Not in the list? Click **+** and choose Pepper in Applications.")
                step(3, "Enter your Mac password if asked, then come back here.")
            }
            .frame(maxWidth: 460, alignment: .leading)
            VStack(spacing: 5) {
                settingsRow
                Text("Look for this in the list").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .frame(width: 20, height: 20)
                .background(Brand.chip, in: Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Pepper's row in System Settings with its switch on, drawn in the
    /// person's accent colour like the real one.
    private var settingsRow: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            Text("Pepper").font(.system(size: 13))
            Spacer()
            Capsule()
                .fill(Color(nsColor: .controlAccentColor))
                .frame(width: 32, height: 19)
                .overlay(alignment: .trailing) {
                    Circle()
                        .fill(.white)
                        .frame(width: 15, height: 15)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                        .padding(2)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(width: 300)
        .background(Brand.chip, in: RoundedRectangle(cornerRadius: Brand.Radius.chip, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pepper in the Accessibility list, switched on")
    }
}

private extension View {
    /// While the walkthrough shows, re-reads the permissions every second
    /// (macOS posts nothing when a System Settings switch changes) and
    /// brings Pepper back to the front when one is turned on there, so the
    /// person lands back on the step, now green.
    func watchingPermissions(_ permissions: Permissions) -> some View {
        task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if permissions.poll() { NSApp.activate(ignoringOtherApps: true) }
            }
        }
    }
}
