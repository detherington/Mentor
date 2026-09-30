import AVFoundation
import CoreMedia

protocol CameraCaptureDelegate: AnyObject {
    func cameraCapture(_ capture: CameraCapture, didOutputVideo sample: CMSampleBuffer)
    func cameraCapture(_ capture: CameraCapture, didOutputAudio sample: CMSampleBuffer)
}

/// Owns the camera+mic AVCaptureSession. The session can be running for live preview
/// independently of recording — recording just hooks the recorder up to consume samples.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var delegate: CameraCaptureDelegate?

    /// Public so SwiftUI / AVCaptureVideoPreviewLayer can attach.
    let session = AVCaptureSession()

    private let videoQueue = DispatchQueue(label: "com.darrell.mentor.camera-video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.darrell.mentor.camera-audio", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private(set) var isConfigured = false

    private let levelLock = NSLock()
    private var smoothedLevel: Float = 0  // 0...1

    /// Build the session with whichever of camera / mic the user has
    /// authorised and has connected. The two are independent: denying
    /// camera access used to skip the whole session, silently recording
    /// with no mic either. Throws only when neither input is usable.
    func configure() throws {
        guard !isConfigured else { return }
        session.beginConfiguration()
        // Commit on every exit — a throw between begin and commit used to
        // leave the session mid-configuration for every later retry.
        defer { session.commitConfiguration() }

        // 1080p gives reasonable FOV headroom without tripping the 4K
        // background-replacement plumbing in newer macOS versions (which
        // was preventing any frames from being delivered on some systems).
        let preferredPresets: [AVCaptureSession.Preset] = [
            .hd1920x1080, .hd1280x720, .high, .medium
        ]
        for preset in preferredPresets where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
        }

        // Video + audio are independently optional. If the Mac has a
        // mic but no camera we still want the session up so the user
        // can record a voiceover over a screen capture; conversely a
        // connected camera with no mic is fine for silent demos. We
        // only bail out if BOTH are missing — there's nothing to do.
        let videoDevice = Self.isAuthorized(.video) ? Self.resolveVideoDevice() : nil
        let audioDevice = Self.isAuthorized(.audio) ? Self.resolveAudioDevice() : nil

        var addedInput = false
        if let videoDevice, addInput(for: videoDevice) {
            Self.applyFrameRateLock(on: videoDevice)
            addedInput = true
        }
        if let audioDevice, addInput(for: audioDevice) {
            addedInput = true
        }
        guard addedInput else { throw CaptureError.noCamera }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        isConfigured = true
    }

    /// `true` if the live session has a connected video input. Used to
    /// decide whether to spin up the webcam sidecar writer — we still
    /// want recording to work when the session is audio-only.
    var hasVideoInput: Bool { currentInput(for: .video) != nil }

    /// Same for the mic writer: a camera-only session (mic denied or
    /// absent) must not create a mic.m4a — an empty one fails to open.
    var hasAudioInput: Bool { currentInput(for: .audio) != nil }

    /// Swap inputs to whatever Settings resolves to — but only the ones
    /// that changed. Any device connect / disconnect (AirPods included)
    /// used to remove and re-add *every* input, gapping the webcam and
    /// mic mid-take and sometimes switching devices under the user.
    ///
    /// `keepConnectedDevices` is for while a recording is in flight: leave
    /// a still-connected device alone even if a preferred one just
    /// appeared or was picked in Settings, and only replace one that's
    /// gone. The caller re-runs this without the flag once idle.
    func reconfigureDevices(keepConnectedDevices: Bool = false) {
        guard isConfigured else { return }
        let currentVideo = currentInput(for: .video)
        let currentAudio = currentInput(for: .audio)
        let wantVideo = Self.isAuthorized(.video) ? Self.resolveVideoDevice() : nil
        let wantAudio = Self.isAuthorized(.audio) ? Self.resolveAudioDevice() : nil

        func needsSwap(_ input: AVCaptureDeviceInput?, _ want: AVCaptureDevice?) -> Bool {
            if keepConnectedDevices, let input, input.device.isConnected { return false }
            return input?.device.uniqueID != want?.uniqueID
        }
        let swapVideo = needsSwap(currentVideo, wantVideo)
        let swapAudio = needsSwap(currentAudio, wantAudio)
        guard swapVideo || swapAudio else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if swapVideo {
            if let currentVideo { session.removeInput(currentVideo) }
            if let wantVideo, addInput(for: wantVideo) {
                Self.applyFrameRateLock(on: wantVideo)
            }
        }
        if swapAudio {
            if let currentAudio { session.removeInput(currentAudio) }
            if let wantAudio { _ = addInput(for: wantAudio) }
        }
        MentorDebug.log("CAMERA: swapped inputs (video=\(swapVideo), audio=\(swapAudio))")
    }

    private func currentInput(for type: AVMediaType) -> AVCaptureDeviceInput? {
        session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(type) }
    }

    /// Must be called inside begin/commitConfiguration. Failures (device
    /// unplugged mid-swap, denied) are logged, not thrown.
    private func addInput(for device: AVCaptureDevice) -> Bool {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return false }
            session.addInput(input)
            return true
        } catch {
            MentorDebug.log("CAMERA: can't add \(device.localizedName): \(error.localizedDescription)")
            return false
        }
    }

    static func isAuthorized(_ type: AVMediaType) -> Bool {
        AVCaptureDevice.authorizationStatus(for: type) == .authorized
    }

    // MARK: - Device discovery + resolution

    /// Resolve the preferred video device from Settings, falling back to
    /// the system default if the saved one isn't connected.
    static func resolveVideoDevice() -> AVCaptureDevice? {
        if let id = Settings.shared.cameraDeviceID,
           let device = AVCaptureDevice(uniqueID: id) {
            return device
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
    }

    static func resolveAudioDevice() -> AVCaptureDevice? {
        if let id = Settings.shared.microphoneDeviceID,
           let device = AVCaptureDevice(uniqueID: id) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    static func availableVideoDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .external,
            .continuityCamera,
            .deskViewCamera
        ]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static func availableAudioDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [.microphone, .external]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    /// Lock the video device to a steady 30fps if its active format
    /// advertises support. Skipping on unsupported formats — setting
    /// these outside supported ranges raises `NSInvalidArgumentException`
    /// which is uncatchable from Swift.
    private static func applyFrameRateLock(on device: AVCaptureDevice) {
        let target = CMTime(value: 1, timescale: 30)
        let supports30fps = device.activeFormat.videoSupportedFrameRateRanges.contains { range in
            range.minFrameRate <= 30.0 && range.maxFrameRate >= 30.0
        }
        guard supports30fps else { return }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = target
            device.activeVideoMaxFrameDuration = target
            device.unlockForConfiguration()
        } catch {
            // swallow — frame rate lock is best-effort
        }
    }

    func startRunning() {
        guard isConfigured, !session.isRunning else { return }
        session.startRunning()
    }

    func stopRunning() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    /// Smoothed mic level in 0...1.
    func currentMicLevel() -> Float {
        levelLock.lock(); defer { levelLock.unlock() }
        return smoothedLevel
    }

    /// Dimensions of the current camera source in pixels (e.g., 1920x1080).
    var sourcePixelSize: CGSize {
        guard let input = session.inputs
            .compactMap({ $0 as? AVCaptureDeviceInput })
            .first(where: { $0.device.hasMediaType(.video) }) else {
            return CGSize(width: 1280, height: 720)
        }
        let dims = CMVideoFormatDescriptionGetDimensions(input.device.activeFormat.formatDescription)
        return CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            delegate?.cameraCapture(self, didOutputVideo: sampleBuffer)
        } else if output === audioOutput {
            updateLevel(from: sampleBuffer)
            delegate?.cameraCapture(self, didOutputAudio: sampleBuffer)
        }
    }

    // MARK: - Level computation via AVAudioPCMBuffer

    private func updateLevel(from sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let numFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard numFrames > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: numFrames) else { return }
        pcmBuffer.frameLength = numFrames

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numFrames),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return }

        let channels = Int(format.channelCount)
        let frames = Int(numFrames)
        var sumSq: Double = 0
        var totalCount: Int = 0

        if let floatChannels = pcmBuffer.floatChannelData {
            for c in 0..<channels {
                let ptr = floatChannels[c]
                for i in 0..<frames {
                    let s = Double(ptr[i])
                    sumSq += s * s
                }
                totalCount += frames
            }
        } else if let int16Channels = pcmBuffer.int16ChannelData {
            for c in 0..<channels {
                let ptr = int16Channels[c]
                for i in 0..<frames {
                    let s = Double(ptr[i]) / 32768.0
                    sumSq += s * s
                }
                totalCount += frames
            }
        } else if let int32Channels = pcmBuffer.int32ChannelData {
            for c in 0..<channels {
                let ptr = int32Channels[c]
                for i in 0..<frames {
                    let s = Double(ptr[i]) / 2147483648.0
                    sumSq += s * s
                }
                totalCount += frames
            }
        } else {
            return
        }

        guard totalCount > 0 else { return }
        let rms = sqrt(sumSq / Double(totalCount))
        let dB = 20 * log10(max(rms, 1e-7))
        // -50 dB = silent (0), 0 dB = max (1)
        let normalized = Float(max(0, min(1, (dB + 50) / 50)))

        levelLock.lock()
        // Peak attack, gentle decay → lively but not flickery
        smoothedLevel = max(normalized, smoothedLevel * 0.85)
        levelLock.unlock()
    }
}
