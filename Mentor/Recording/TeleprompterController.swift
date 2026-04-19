import AVFoundation
import CoreMedia
import Foundation
import Accelerate

/// Autoscroll mode for the teleprompter window.
enum TeleprompterScrollMode: String, Codable, Equatable, CaseIterable, Identifiable {
    /// Scroll only when the user drags or presses arrow keys.
    case manual
    /// Scroll at a constant words-per-minute rate, ignoring whatever
    /// the user is doing with the mic.
    case timer
    /// Use mic amplitude to pace scrolling. While the mic is above an
    /// adaptive threshold, scroll at the configured WPM; during
    /// silence, pause. Gives a "follow the speaker" feel without any
    /// speech-recognition latency.
    case followVoice

    var id: String { rawValue }
    var label: String {
        switch self {
        case .manual:      return "Manual"
        case .timer:       return "Timer"
        case .followVoice: return "Follow voice"
        }
    }
}

/// User-facing teleprompter configuration. Persisted across sessions.
struct TeleprompterSettings: Codable, Equatable, Sendable {
    /// Currently loaded script. Free-form text; scrolls top to bottom.
    var script: String
    /// Autoscroll mode.
    var mode: TeleprompterScrollMode
    /// Words per minute used by `.timer` and `.followVoice` modes.
    /// 150 WPM ≈ natural speaking pace for most narrators.
    var wordsPerMinute: Int
    /// Font point size at 1× backing scale. Large — the window is
    /// meant to be readable from arm's length.
    var fontSize: CGFloat
    /// Maximum line width as a fraction of the window width. Keeps
    /// lines from getting too long for comfortable reading.
    var lineWidthFraction: CGFloat
    /// Mirror the text horizontally for a through-the-glass rig. Rare
    /// but harmless to support.
    var mirrored: Bool

    static let `default` = TeleprompterSettings(
        script: "",
        mode: .manual,
        wordsPerMinute: 150,
        fontSize: 36,
        lineWidthFraction: 0.85,
        mirrored: false
    )
}

/// Runtime controller for the teleprompter. Owns the currently-visible
/// scroll position, ticks forward based on the configured mode, and
/// exposes a VU-style speaking envelope for mic-pacing mode.
///
/// Lives independently of the capture recording — the window can be
/// shown and the script scrolled even when no recording is in progress.
/// When recording starts, `AppDelegate` hooks the coordinator's mic
/// sink into `feedMicSample(_:)` so amplitude mode has audio to work
/// with. During idle, mic sink is nil and `.followVoice` behaves like
/// `.timer` (can't pause on silence you can't hear).
@MainActor
@Observable
final class TeleprompterController {
    /// Persisted settings. Writing through here also writes to
    /// `Settings.shared.teleprompterSettings`.
    var settings: TeleprompterSettings {
        didSet {
            if oldValue != settings {
                Settings.shared.teleprompterSettings = settings
            }
        }
    }

    /// Normalized 0.0–1.0 scroll progress through the script.
    /// The SwiftUI view uses this to position the ScrollViewReader.
    private(set) var progress: Double = 0

    /// Last computed mic envelope (0.0 silent, 1.0 loud). Drives the
    /// on-screen speaking indicator and gates `.followVoice` scroll.
    private(set) var speakingLevel: Float = 0

    /// True when the ticker loop is advancing the scroll.
    private(set) var isTicking: Bool = false

    /// Visual cursor for `.followVoice` — true while mic envelope is
    /// above the threshold, so the UI can hint "listening" to the user.
    private(set) var isSpeaking: Bool = false

    // Ticker internals.
    private var tickerTask: Task<Void, Never>?
    private var lastTickDate: Date?

    // Amplitude-envelope state. We keep a smoothed RMS and compare to
    // an adaptive noise floor — same pattern as MicCleaner, but running
    // live.
    private let amplitudeLock = NSLock()
    nonisolated(unsafe) private var smoothedRMS: Float = 0
    nonisolated(unsafe) private var noiseFloor: Float = 0.0005  // ~-66 dB
    /// Smoothing factor for the RMS envelope. 0.25 = fast attack,
    /// 0.02 = slow release — feels responsive without being jumpy.
    private let attackCoeff: Float = 0.25
    private let releaseCoeff: Float = 0.02

    init() {
        self.settings = Settings.shared.teleprompterSettings ?? .default
    }

    /// Start advancing the progress automatically according to
    /// `settings.mode`. Safe to call while already running — no-op.
    func start() {
        guard tickerTask == nil else { return }
        lastTickDate = Date()
        isTicking = true
        tickerTask = Task { [weak self] in
            // ~60 Hz update. The actual movement per tick is tiny; the
            // high refresh rate just keeps scrolling visually smooth.
            while let self, !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    /// Stop auto-advance. Scroll position is preserved — resume with
    /// `start()` or reset with `resetProgress()`.
    func stop() {
        tickerTask?.cancel()
        tickerTask = nil
        isTicking = false
        lastTickDate = nil
        // Don't clear speakingLevel — lets the UI display the final
        // state until next mic sample arrives.
    }

    /// Jump the scroll back to the top. Typical usage: user hits a
    /// "Reset" button before the next take.
    func resetProgress() {
        progress = 0
    }

    /// Nudge scroll by `fraction` of the script. Used for manual
    /// keyboard scrolling (arrow keys).
    func nudgeProgress(by fraction: Double) {
        progress = max(0, min(1, progress + fraction))
    }

    // MARK: - Mic tap

    /// Feed a mic CMSampleBuffer. Called from the capture audio queue
    /// — must not block. Computes RMS via vDSP, updates the envelope
    /// atomically. All the heavier math (smoothing, threshold compare)
    /// happens here on the audio queue; the main-actor tick just reads
    /// the smoothed value.
    nonisolated func feedMicSample(_ sampleBuffer: CMSampleBuffer) {
        guard let rms = Self.rms(of: sampleBuffer) else { return }

        amplitudeLock.lock()
        // Asymmetric smoothing — quick to open, slow to close. Feels
        // snappy on speech onset without flickering on pauses between
        // words.
        let coeff = rms > smoothedRMS ? attackCoeff : releaseCoeff
        smoothedRMS = smoothedRMS + coeff * (rms - smoothedRMS)
        // Track the noise floor via a very slow low-pass on the
        // minimum. When the smoothed RMS dips below the current floor,
        // the floor descends toward it; it only creeps up slowly so a
        // sudden speech burst doesn't re-anchor it.
        if smoothedRMS < noiseFloor {
            noiseFloor = noiseFloor + 0.01 * (smoothedRMS - noiseFloor)
        } else {
            noiseFloor = noiseFloor + 0.0005 * (smoothedRMS - noiseFloor)
        }
        let level = smoothedRMS
        let floor = noiseFloor
        amplitudeLock.unlock()

        // Publish to the UI. `Task { @MainActor in ... }` is cheap per
        // audio buffer (~100 Hz at 48 kHz in 480-sample chunks); well
        // below redraw cost.
        Task { @MainActor [weak self] in
            self?.updateSpeakingMetrics(level: level, floor: floor)
        }
    }

    private func updateSpeakingMetrics(level: Float, floor: Float) {
        // Normalise: map [floor+3dB .. floor+20dB] to [0, 1] for the UI
        // meter. 3 dB above floor is our threshold; 20 dB is "loud".
        let thresholdLinear = floor * 1.4125  // +3 dB
        let loudLinear      = floor * 10.0    // +20 dB
        let clamped = max(0, min(1, Double((level - thresholdLinear) / max(1e-5, loudLinear - thresholdLinear))))
        speakingLevel = Float(clamped)
        isSpeaking = level >= thresholdLinear
    }

    // MARK: - Scroll ticker

    private func tick() async {
        let now = Date()
        let dt = now.timeIntervalSince(lastTickDate ?? now)
        lastTickDate = now
        guard dt > 0 else { return }

        // Words in the script. Empty script → nothing to scroll.
        let words = wordCount(in: settings.script)
        guard words > 0 else { return }

        let activeWPM: Double
        switch settings.mode {
        case .manual:
            // Ticker still runs so the envelope + UI update, but it
            // doesn't move progress.
            return
        case .timer:
            activeWPM = Double(settings.wordsPerMinute)
        case .followVoice:
            // Only advance while the mic is above the threshold. The
            // "speaking" gate is set by `feedMicSample`.
            guard isSpeaking else { return }
            activeWPM = Double(settings.wordsPerMinute)
        }
        let wordsPerSecond = activeWPM / 60.0
        let deltaWords = wordsPerSecond * dt
        let deltaFraction = deltaWords / Double(words)
        progress = min(1.0, progress + deltaFraction)
    }

    private func wordCount(in text: String) -> Int {
        // Cheap: collapse whitespace runs, count tokens.
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: - RMS helper

    /// Compute peak / RMS amplitude of a CMSampleBuffer of audio. Only
    /// handles float / int16 PCM — falls through to nil for other
    /// formats (which AVCaptureAudioDataOutput doesn't emit in practice
    /// but we guard defensively).
    private nonisolated static func rms(of sampleBuffer: CMSampleBuffer) -> Float? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        let asbd = asbdPtr.pointee

        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        guard let data = abl.mBuffers.mData else { return nil }
        let byteCount = Int(abl.mBuffers.mDataByteSize)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frames = byteCount / bytesPerFrame
        guard frames > 0 else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bits = asbd.mBitsPerChannel

        if isFloat, bits == 32 {
            let ptr = data.assumingMemoryBound(to: Float.self)
            var rmsValue: Float = 0
            vDSP_rmsqv(ptr, 1, &rmsValue, vDSP_Length(frames * Int(asbd.mChannelsPerFrame)))
            return rmsValue
        } else if !isFloat, bits == 16 {
            // Int16 → convert to float first.
            let ptr = data.assumingMemoryBound(to: Int16.self)
            let total = frames * Int(asbd.mChannelsPerFrame)
            var scratch = [Float](repeating: 0, count: total)
            vDSP_vflt16(ptr, 1, &scratch, 1, vDSP_Length(total))
            var scale: Float = 1.0 / 32768.0
            vDSP_vsmul(scratch, 1, &scale, &scratch, 1, vDSP_Length(total))
            var rmsValue: Float = 0
            vDSP_rmsqv(scratch, 1, &rmsValue, vDSP_Length(total))
            return rmsValue
        }
        return nil
    }
}
