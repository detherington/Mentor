import AppKit
import SwiftUI

/// The main window's content, in the setup walkthrough's and the "Signed
/// in to Orbis" page's look: black ground, the app icon, a Neon kicker,
/// a headline pairing the expanded display face with the serif, body
/// text in white at 72%, and one Neon action.
struct HomeView: View {
    static let size = NSSize(width: 760, height: 660)

    let model: HomeModel
    let actions: HomeWindowController.Actions
    private let account = OrbisAccount.shared
    @State private var orbisError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            recordAction
                .padding(.top, 26)
            if model.needsSetup {
                setupNotice
                    .padding(.top, 16)
            }
            devices
                .padding(.top, 16)

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)
                .padding(.vertical, 26)

            recents
            Spacer(minLength: 18)
            footer
        }
        .padding(.horizontal, 40)
        .padding(.top, 48)  // clear of the transparent title bar's buttons
        .padding(.bottom, 26)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .tint(Brand.accent)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 22) {
                // The icon file is square artwork; round it the way macOS shows icons.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 84 * 0.225, style: .continuous))
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 10)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pepper").brandKicker(11, color: Brand.neon)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Record a").brandDisplay(40)
                        Text("walkthrough").font(Brand.serif(40)).textCase(.uppercase).tracking(-0.8)
                    }
                }
            }
            Text("Pick a screen, a window or part of one. Pepper records you, your voice and your clicks along with it, and opens the editor when you stop.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private var recordAction: some View {
        HStack(spacing: 16) {
            Button(action: actions.record) {
                HStack(spacing: 8) {
                    // Red, as everywhere Pepper means "recording".
                    Circle().fill(Color(nsColor: .systemRed)).frame(width: 10, height: 10)
                    Text("Start Recording")
                }
                .padding(.horizontal, 8)
            }
            .buttonStyle(NeonButtonStyle(height: 44))
            .keyboardShortcut(.defaultAction)
            if let shortcut = model.recordShortcut {
                Text("or press \(shortcut) in any app")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var setupNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text("Pepper still needs permission for your screen, camera or microphone.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 8)
            Button("Finish Setup…") { OnboardingWindowController.shared.show() }
                .buttonStyle(QuietButtonStyle(height: 28))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous))
    }

    private var devices: some View {
        HStack(spacing: 16) {
            deviceLabel(model.cameraLabel, systemImage: "video")
            deviceLabel(model.microphoneLabel, systemImage: "mic")
            Button("Change…", action: actions.showSettings)
                .buttonStyle(.link)
                .font(.system(size: 12.5))
        }
    }

    private func deviceLabel(_ name: String, systemImage: String) -> some View {
        Label(name, systemImage: systemImage)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.72))
            .lineLimit(1)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent recordings").brandKicker(10.5, color: .white.opacity(0.55))
                Spacer()
                Button("Open…", action: actions.showOpenPanel)
                    .buttonStyle(.link)
                Button("Show in Finder", action: actions.revealRecordings)
                    .buttonStyle(.link)
                    .padding(.leading, 10)
            }
            .font(.system(size: 12.5))

            if model.recents.isEmpty {
                Text("Your recordings will show up here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, minHeight: 112)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous))
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(model.recents) { recent in
                        RecentTile(
                            title: recent.title,
                            thumbnail: model.thumbnails[recent.url],
                            duration: model.durations[recent.url],
                            open: { actions.open(recent.url) },
                            reveal: { actions.reveal(recent.url) },
                            trash: { actions.trash(recent.url) }
                        )
                    }
                    // Keep tiles the same width when there are fewer than four.
                    ForEach(model.recents.count..<HomeModel.recentCount, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.isConnected ? Brand.emerald : Color.white.opacity(0.3))
                .frame(width: 7, height: 7)
            if account.isConnected {
                Text("Connected to Orbis\(account.userName.map { " as \($0)" } ?? "")")
                    .foregroundStyle(.white.opacity(0.72))
            } else if account.isSigningIn {
                Text("Waiting for sign-in in your browser…")
                    .foregroundStyle(.white.opacity(0.72))
                Button("Cancel") { account.cancelSignIn() }
                    .buttonStyle(.link)
            } else {
                Text(orbisError ?? "Not connected to Orbis")
                    .foregroundStyle(orbisError == nil ? .white.opacity(0.55) : .orange)
                    .lineLimit(1)
                Button("Sign In…") { signIn() }
                    .buttonStyle(.link)
            }
            Spacer()
            Button(action: actions.showSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.link)
        }
        .font(.system(size: 12.5))
    }

    private func signIn() {
        orbisError = nil
        Task {
            do {
                try await account.signIn()
            } catch {
                orbisError = "Couldn't sign in to Orbis. Try again?"
            }
        }
    }
}

/// One recent recording: a frame from it, its length, when it was made.
/// Click to open it in the editor.
private struct RecentTile: View {
    let title: String
    let thumbnail: NSImage?
    let duration: String?
    let open: () -> Void
    let reveal: () -> Void
    let trash: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle()
                                .fill(.white.opacity(0.06))
                                .overlay(Image(systemName: "play.rectangle").font(.system(size: 20)).foregroundStyle(.white.opacity(0.3)))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipped()

                    if let duration {
                        Text(duration)
                            .brandTimecode(10.5)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(isHovering ? 0.55 : 0.12), lineWidth: isHovering ? 1.5 : 1)
                )

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(isHovering ? 1 : 0.85))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { isHovering = $0 }
        .help("Open in the editor")
        // Deleting a recording used to mean finding its two files in
        // Finder.
        .contextMenu {
            Button("Open in Editor", action: open)
            Button("Show in Finder", action: reveal)
            Divider()
            Button("Move to Trash…", role: .destructive, action: trash)
        }
        .accessibilityLabel("Open the recording from \(title)\(duration.map { ", \($0) long" } ?? "")")
    }
}
