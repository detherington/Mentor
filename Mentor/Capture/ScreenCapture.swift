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

    // Per-session drop counters. All reads + writes happen on `videoQueue`.
    // `idle` frames are the common case (SCStream stops emitting when the
    // screen hasn't changed) and they're NOT a drop — we skip them
    // deliberately. `blank`, `suspended` and `started` are transitional;
    // we count them but they should be rare. `nonComplete` is a catch-all
    // for anything we don't recognise.
    private var frameStatusIdleCount: Int = 0
    private var frameStatusBlankCount: Int = 0
    private var frameStatusSuspendedCount: Int = 0
    private var frameStatusStartedCount: Int = 0
    private var frameStatusOtherCount: Int = 0
    private var frameCompleteCount: Int = 0
    private var delegateNilCount: Int = 0   // frames where our delegate was nil
    private var noImageBufferCount: Int = 0 // frames with no pixel buffer

    func start(source: CaptureSource, captureSystemAudio: Bool) async throws {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        let size = source.pixelSize(scale: scale)
        pixelSize = size

        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // queueDepth is the number of frames SCStream will buffer before
        // dropping. Default docs say 3; we bump to 10 to absorb bursts
        // where the H.264 encoder stalls briefly (e.g. keyframe insertion,
        // thermal throttle, concurrent encoder contention with the
        // webcam). Each buffered frame at retina 60fps is ~33MB
        // (3600×2338×4 bytes), so 10 frames is ~330MB peak — acceptable
        // for a desktop recorder, and the pool is recycled.
        config.queueDepth = 10
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
        // Hop onto videoQueue to read the counters safely; all mutations
        // also happen there, so this snapshot is consistent.
        let snapshot: (Int, Int, Int, Int, Int, Int, Int, Int) = await withCheckedContinuation { cont in
            videoQueue.async {
                cont.resume(returning: (
                    self.frameCompleteCount,
                    self.frameStatusIdleCount,
                    self.frameStatusBlankCount,
                    self.frameStatusSuspendedCount,
                    self.frameStatusStartedCount,
                    self.frameStatusOtherCount,
                    self.delegateNilCount,
                    self.noImageBufferCount
                ))
            }
        }
        MentorDebug.log("SCSTREAM drops: complete=\(snapshot.0) idle=\(snapshot.1) blank=\(snapshot.2) suspended=\(snapshot.3) started=\(snapshot.4) other=\(snapshot.5) delegateNil=\(snapshot.6) noImage=\(snapshot.7)")
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
                switch status {
                case .idle:      frameStatusIdleCount &+= 1
                case .blank:     frameStatusBlankCount &+= 1
                case .suspended: frameStatusSuspendedCount &+= 1
                case .started:   frameStatusStartedCount &+= 1
                @unknown default: frameStatusOtherCount &+= 1
                }
                return
            }
            frameCompleteCount &+= 1
            if CMSampleBufferGetImageBuffer(sampleBuffer) == nil {
                noImageBufferCount &+= 1
            }
            if let d = delegate {
                d.screenCapture(self, didOutputVideo: sampleBuffer)
            } else {
                delegateNilCount &+= 1
            }

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
