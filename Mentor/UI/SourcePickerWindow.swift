import AppKit
import SwiftUI
import ScreenCaptureKit

@MainActor
final class SourcePickerWindow {
    private var window: NSWindow?
    private var regionSelector: RegionSelectorWindow?  // strong ref so it lives until done
    private var highlight = ScreenHighlightWindow()
    private var onPicked: ((CaptureSource) -> Void)?
    private var onCancel: (() -> Void)?

    func show(
        onPicked: @escaping (CaptureSource) -> Void,
        onCancel: @escaping () -> Void
    ) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            self.onPicked = onPicked
            self.onCancel = onCancel
            present(content: content)
        } catch {
            onCancel()
        }
    }

    private func present(content: SCShareableContent) {
        let myBundleID = Bundle.main.bundleIdentifier
        let visibleWindows = content.windows.filter {
            $0.isOnScreen &&
            ($0.title?.isEmpty == false) &&
            $0.frame.width > 80 && $0.frame.height > 80 &&
            $0.owningApplication?.bundleIdentifier != myBundleID
        }

        let view = SourcePickerView(
            displays: content.displays,
            windows: visibleWindows,
            onHoverDisplay: { [weak self] display, hovering in
                guard let self else { return }
                if hovering, let screen = Self.screen(for: display) {
                    self.highlight.show(on: screen)
                } else {
                    self.highlight.hide()
                }
            },
            onPick: { [weak self] source in
                self?.complete(source)
            },
            onPickRegion: { [weak self] in
                guard let self else { return }
                self.window?.orderOut(nil)
                let selector = RegionSelectorWindow()
                self.regionSelector = selector  // retain so closures stay alive
                selector.show(
                    onPicked: { [weak self] screen, rect in
                        guard let self else { return }
                        self.regionSelector = nil
                        // Match the NSScreen the user drew on to its
                        // SCDisplay so the resulting `.region` source
                        // captures from the correct display (+ so
                        // countdown / border / scale lookups all
                        // agree on the target).
                        guard let display = Self.display(for: screen, in: content.displays) else {
                            self.cancel()
                            return
                        }
                        self.complete(.region(display: display, rect: rect))
                    },
                    onCancel: { [weak self] in
                        self?.regionSelector = nil
                        self?.cancel()
                    }
                )
            },
            onCancel: { [weak self] in self?.cancel() }
        )

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Choose Source"
        win.contentView = NSHostingView(rootView: view)
        win.center()
        win.isReleasedWhenClosed = false
        self.window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func complete(_ source: CaptureSource) {
        highlight.hide()
        window?.orderOut(nil)
        window = nil
        let cb = onPicked
        onPicked = nil
        onCancel = nil
        cb?(source)
    }

    private func cancel() {
        highlight.hide()
        window?.orderOut(nil)
        window = nil
        let cb = onCancel
        onPicked = nil
        onCancel = nil
        cb?()
    }

    private static func screen(for display: SCDisplay) -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[key] as? NSNumber)?.uint32Value == display.displayID
        }
    }

    private static func display(for screen: NSScreen, in displays: [SCDisplay]) -> SCDisplay? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        let displayID = number.uint32Value
        return displays.first { $0.displayID == displayID }
    }
}

private struct SourcePickerView: View {
    let displays: [SCDisplay]
    let windows: [SCWindow]
    let onHoverDisplay: (SCDisplay, Bool) -> Void
    let onPick: (CaptureSource) -> Void
    let onPickRegion: () -> Void
    let onCancel: () -> Void

    @State private var tab: Tab = .display

    enum Tab: String, CaseIterable, Identifiable {
        case display = "Display"
        case window  = "Window"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 16)],
                    spacing: 16
                ) {
                    if tab == .display {
                        ForEach(displays, id: \.displayID) { display in
                            SourceCard(
                                title: "Display \(display.displayID)",
                                subtitle: "\(display.width) × \(display.height)",
                                systemImage: "display"
                            ) { onPick(.display(display)) }
                            .onHover { hovering in
                                onHoverDisplay(display, hovering)
                            }
                        }
                    } else {
                        ForEach(windows, id: \.windowID) { window in
                            SourceCard(
                                title: window.owningApplication?.applicationName ?? "Window",
                                subtitle: window.title ?? "",
                                systemImage: "macwindow"
                            ) { onPick(.window(window)) }
                        }
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Button("Select Region…", action: onPickRegion)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.escape)
            }
            .padding()
        }
        .frame(width: 760, height: 520)
    }
}

private struct SourceCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                    Image(systemName: systemImage)
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 110)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.gray.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
