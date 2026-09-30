import AppKit
import SwiftUI

/// "Your video is ready": a small card at the top right of the screen
/// when the as-recorded MP4 finishes rendering after a recording, with
/// Show in Finder and Edit. Before, the only sign was the menu-bar icon
/// dropping its "Finalizing…" title.
///
/// Pepper's own card rather than a system notification, as in Muesli:
/// a notification needs its own permission prompt, and nothing should
/// prompt out of the blue. The card doesn't take focus, floats over
/// full-screen apps, and goes away on its own unless the pointer is on
/// it.
@MainActor
final class VideoReadyNotice {
    static let shared = VideoReadyNotice()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// How long the card stays when left alone.
    private static let lifetime: Duration = .seconds(12)

    func show(video: URL, onEdit: @escaping () -> Void) {
        close()
        let card = VideoReadyCard(
            onShowInFinder: { [weak self] in
                NSWorkspace.shared.activateFileViewerSelecting([video])
                self?.close()
            },
            onEdit: { [weak self] in
                onEdit()
                self?.close()
            },
            onClose: { [weak self] in self?.close() }
        )
        let panel = Self.makePanel(for: card)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        scheduleDismiss()
    }

    func close() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Wait out the lifetime, then keep waiting while the pointer is on
    /// the card, so it never vanishes from under a click.
    private func scheduleDismiss() {
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            while let panel = self?.panel, panel.frame.contains(NSEvent.mouseLocation) {
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    fileprivate static func makePanel(for card: VideoReadyCard) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        let host = NSHostingView(rootView: card)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        return panel
    }
}

private struct VideoReadyCard: View {
    let onShowInFinder: () -> Void
    let onEdit: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Your video is ready")
                    .font(.system(size: 13, weight: .semibold))
                Text("Saved in Movies › Pepper, as recorded.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Show in Finder", action: onShowInFinder)
                        .buttonStyle(NeonButtonStyle(height: 28))
                    Button("Edit", action: onEdit)
                        .buttonStyle(QuietButtonStyle(height: 28))
                }
                .padding(.top, 7)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close")
        }
        .padding(14)
        .frame(width: 340)
        .brandCard()
    }
}

#if DEBUG
extension VideoReadyNotice {
    /// Review hook: `-pepper.debug.renderReadyNotice <dir>` writes the
    /// card in light and dark as PNGs. True when it ran; the caller then
    /// quits. Debug builds only.
    static func renderIfRequested() -> Bool {
        guard let path = UserDefaults.standard.string(forKey: "pepper.debug.renderReadyNotice") else { return false }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let panel = makePanel(for: VideoReadyCard(onShowInFinder: {}, onEdit: {}, onClose: {}))
            panel.appearance = NSAppearance(named: appearance)
            panel.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            guard let view = panel.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("ready-notice-\(name).png"))
            panel.orderOut(nil)
        }
        return true
    }
}
#endif
