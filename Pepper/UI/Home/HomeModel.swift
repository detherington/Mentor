import AppKit
import AVFoundation
import Foundation

/// What the main window shows: the latest recordings (with a frame and
/// length, loaded in the background and kept), the camera and microphone
/// a recording will use, the record shortcut, and whether setup is done.
@MainActor
@Observable
final class HomeModel {
    struct Recent: Identifiable {
        let url: URL
        let title: String
        var id: URL { url }
    }

    /// Newest first.
    private(set) var recents: [Recent] = []
    private(set) var thumbnails: [URL: NSImage] = [:]
    private(set) var durations: [URL: String] = [:]
    /// The camera and microphone a recording will use, or why there isn't one.
    private(set) var cameraLabel = ""
    private(set) var microphoneLabel = ""
    private(set) var recordShortcut: String?
    /// Screen Recording, camera or microphone still to allow.
    private(set) var needsSetup = false

    static let recentCount = 4

    @ObservationIgnored private var loading: Set<URL> = []

    func refresh() {
        recents = Self.latestRecordings(limit: Self.recentCount).map {
            Recent(url: $0, title: RecordingBundle.displayTitle($0))
        }
        for recent in recents where thumbnails[recent.url] == nil && !loading.contains(recent.url) {
            load(recent.url)
        }

        recordShortcut = Settings.shared.shortcut(for: .recordToggle)?.displayString

        let permissions = Permissions.shared
        permissions.refresh()
        // Without access macOS lists no cameras at all, so "no camera"
        // would be wrong.
        cameraLabel = permissions.camera != .granted ? "Camera not allowed yet"
            : Self.deviceName(id: Settings.shared.cameraDeviceID, type: .video) ?? "No camera connected"
        microphoneLabel = permissions.microphone != .granted ? "Microphone not allowed yet"
            : Self.deviceName(id: Settings.shared.microphoneDeviceID, type: .audio) ?? "No microphone connected"
        needsSetup = [permissions.screenRecording, permissions.camera, permissions.microphone]
            .contains { $0 != .granted }
    }

    /// A frame from a fifth of the way into the screen track (past the
    /// fumble for the source window, before the wrap-up) and its length.
    private func load(_ recording: URL) {
        loading.insert(recording)
        let screen = recording.appendingPathComponent("screen.mov")
        Task { [weak self] in
            let asset = AVURLAsset(url: screen)
            let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 270)
            let at = CMTime(seconds: max(0, seconds * 0.2), preferredTimescale: 600)
            let image = try? await generator.image(at: at).image
            guard let self else { return }
            self.loading.remove(recording)
            if let image {
                self.thumbnails[recording] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
            if seconds.isFinite, seconds > 0 {
                let total = Int(seconds.rounded())
                self.durations[recording] = String(format: "%d:%02d", total / 60, total % 60)
            }
        }
    }

    private static func latestRecordings(limit: Int) -> [URL] {
        let bundles = ((try? FileManager.default.contentsOfDirectory(
            at: CaptureCoordinator.outputDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter(RecordingBundle.isRecording)
        // Creation date, not modification: every editor save touches the
        // bundle, which would reorder the list by what was edited last.
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        return Array(bundles.sorted { created($0) > created($1) }.prefix(limit))
    }

    /// The chosen device's name, or the system default's.
    private static func deviceName(id: String?, type: AVMediaType) -> String? {
        if let id, let device = AVCaptureDevice(uniqueID: id) { return device.localizedName }
        return AVCaptureDevice.default(for: type)?.localizedName
    }
}
