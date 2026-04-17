import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

protocol ScreenCaptureDelegate: AnyObject {
    func screenCapture(_ capture: ScreenCapture, didOutputVideo sample: CMSampleBuffer)
    func screenCapture(_ capture: ScreenCapture, didOutputAudio sample: CMSampleBuffer)
    func screenCapture(_ capture: ScreenCapture, didFailWith error: Error)
}

final class ScreenCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    weak var delegate: ScreenCaptureDelegate?

    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "com.darrell.mentor.screen-capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.darrell.mentor.screen-capture.audio", qos: .userInteractive)

    private(set) var pixelSize: CGSize = .zero

    func start(source: CaptureSource, captureSystemAudio: Bool) async throws {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        let size = source.pixelSize(scale: scale)
        pixelSize = size

        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = captureSystemAudio

        if let rect = source.sourceRect {
            config.sourceRect = rect
            config.destinationRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        }

        // Build filter, excluding our own app's windows so the floating
        // webcam preview doesn't appear baked into the recording.
        let content = try await SCShareableContent.current
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myApp = content.applications.first { $0.processID == myPID }
        let excludedApps: [SCRunningApplication] = myApp.map { [$0] } ?? []

        let filter: SCContentFilter
        switch source {
        case .display(let d):
            filter = SCContentFilter(
                display: d,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )
        case .window(let w):
            filter = SCContentFilter(desktopIndependentWindow: w)
        case .region(let d, _):
            filter = SCContentFilter(
                display: d,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let info = attachments.first,
               let statusRaw = info[.status] as? Int,
               let status = SCFrameStatus(rawValue: statusRaw),
               status != .complete {
                return
            }
            delegate?.screenCapture(self, didOutputVideo: sampleBuffer)

        case .audio:
            delegate?.screenCapture(self, didOutputAudio: sampleBuffer)

        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        delegate?.screenCapture(self, didFailWith: error)
    }
}

enum CaptureError: Error, LocalizedError {
    case noDisplay
    case noCamera
    case noMicrophone
    case writerSetupFailed(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display available for capture."
        case .noCamera: return "No camera found."
        case .noMicrophone: return "No microphone found."
        case .writerSetupFailed(let s): return "Recorder setup failed: \(s)"
        case .permissionDenied(let s): return "Permission denied: \(s)"
        }
    }
}
