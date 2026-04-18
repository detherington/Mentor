import AVFoundation
import Accelerate
import Foundation

/// Offline mic-noise pre-processor. Reads a .m4a (or any AVFoundation-
/// readable audio file), runs it through a high-pass filter to kill
/// low-frequency rumble (AC hum, HVAC, mechanical desk noise), applies
/// an adaptive noise gate that learns the silence floor from the
/// quietest windows in the recording, and writes a cleaned CAF file
/// suitable for drop-in use as a replacement mic track in the editor's
/// `AVMutableComposition`.
///
/// We write CAF rather than re-encode to AAC because `AVAudioFile` can
/// only emit PCM — the AAC re-encode happens anyway when the export
/// pipeline's `AVAssetWriter` bakes the final MP4, so adding another
/// round-trip encode here would just stack loss.
enum MicCleaner {
    struct Settings {
        /// Lower cutoff of the pre-gate HPF. 80 Hz is the conventional
        /// "everything below this is room noise" boundary; 120 Hz
        /// tightens further for voices that don't need deep bass
        /// (matters if the user has a bassy male voice we don't want
        /// to thin out). Exposed via the Strength preset below.
        var hpfHz: Float
        /// Floor (dBFS) above which audio passes the gate. Computed
        /// later as (learned noise floor + headroom), but we clamp to
        /// this minimum so the gate never opens on pure silence even
        /// if the noise-floor estimator undershoots.
        var gateFloorDB: Float
        /// Headroom above the learned noise floor. Higher → gate
        /// triggers closed more aggressively (cleaner but risks
        /// chopping quiet speech). 6–12 dB is conservative.
        var gateHeadroomDB: Float
        /// Gate attack/release ramp in ms. Keeps the gate edges from
        /// clicking at frame boundaries.
        var gateFadeMs: Float

        static let light = Settings(
            hpfHz: 80,
            gateFloorDB: -60,
            gateHeadroomDB: 6,
            gateFadeMs: 25
        )
        static let strong = Settings(
            hpfHz: 110,
            gateFloorDB: -55,
            gateHeadroomDB: 10,
            gateFadeMs: 20
        )
    }

    enum CleanerError: Error, LocalizedError {
        case cannotRead(String)
        case cannotWrite(String)
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotRead(let s):   return "Noise reduction couldn't read the mic track: \(s)"
            case .cannotWrite(let s):  return "Noise reduction couldn't write the cleaned file: \(s)"
            case .engineFailed(let s): return "Noise reduction audio engine: \(s)"
            }
        }
    }

    /// Run the cleaner synchronously (off the caller's task should be
    /// `Task.detached`). Produces a CAF file at `outputURL`. Overwrites
    /// any existing file there.
    static func clean(
        inputURL: URL,
        outputURL: URL,
        settings: Settings = .light
    ) throws {
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: inputURL)
        } catch {
            throw CleanerError.cannotRead(error.localizedDescription)
        }
        let processingFormat = inputFile.processingFormat

        // ---- Pass 1: estimate noise floor from the quietest windows.
        // Scan in 50ms windows, RMS each, sort, pick the 10th-percentile
        // window's RMS as "this is silence". Adds a touch of headroom
        // so genuinely quiet speech still opens the gate.
        let noiseFloorDB = try estimateNoiseFloorDB(file: inputFile, format: processingFormat)
        let gateThresholdDB = max(settings.gateFloorDB, noiseFloorDB + settings.gateHeadroomDB)
        MentorDebug.log("NR: noise floor \(String(format: "%.1f", noiseFloorDB)) dB → gate @ \(String(format: "%.1f", gateThresholdDB)) dB")

        // ---- Pass 2: offline AVAudioEngine chain with the highpass.
        inputFile.framePosition = 0

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = settings.hpfHz
        eq.bands[0].bypass = false
        eq.bands[0].gain = 0

        engine.attach(player)
        engine.attach(eq)
        engine.connect(player, to: eq, format: processingFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: processingFormat)

        let chunk: AVAudioFrameCount = 4096
        do {
            try engine.enableManualRenderingMode(
                .offline,
                format: processingFormat,
                maximumFrameCount: chunk
            )
        } catch {
            throw CleanerError.engineFailed("manual render mode: \(error.localizedDescription)")
        }
        do {
            try engine.start()
        } catch {
            throw CleanerError.engineFailed("start: \(error.localizedDescription)")
        }

        player.scheduleFile(inputFile, at: nil)
        player.play()

        // ---- Output writer — PCM Float32 CAF at the source's format.
        // AVAudioFile's default write format preserves the processing
        // format's sample rate + channel count.
        try? FileManager.default.removeItem(at: outputURL)
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: processingFormat.settings,
                commonFormat: processingFormat.commonFormat,
                interleaved: processingFormat.isInterleaved
            )
        } catch {
            engine.stop()
            throw CleanerError.cannotWrite(error.localizedDescription)
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunk) else {
            engine.stop()
            throw CleanerError.engineFailed("failed to allocate render buffer")
        }

        let total = inputFile.length
        // Gate state per channel — `gain` tracks the 0..1 envelope.
        // Separate per channel so stereo recordings don't have one
        // channel's silence dragging the other's gate closed.
        let channelCount = Int(processingFormat.channelCount)
        var gateGain = [Float](repeating: 0, count: channelCount)
        let fadeFrames = Float(settings.gateFadeMs * 0.001 * Float(processingFormat.sampleRate))
        let fadeRate = fadeFrames > 0 ? 1.0 / fadeFrames : 1.0
        let gateThresholdLinear = pow(10.0, gateThresholdDB / 20.0)

        while engine.manualRenderingSampleTime < total {
            let framesToRender = min(
                chunk,
                AVAudioFrameCount(total - engine.manualRenderingSampleTime)
            )
            guard framesToRender > 0 else { break }
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(framesToRender, to: buffer)
            } catch {
                engine.stop()
                throw CleanerError.engineFailed("renderOffline: \(error.localizedDescription)")
            }
            switch status {
            case .success:
                applyGate(
                    to: buffer,
                    channels: channelCount,
                    gateThresholdLinear: gateThresholdLinear,
                    fadeRate: fadeRate,
                    gateGain: &gateGain
                )
                do {
                    try outputFile.write(from: buffer)
                } catch {
                    engine.stop()
                    throw CleanerError.cannotWrite(error.localizedDescription)
                }
            case .insufficientDataFromInputNode:
                // Player hasn't queued more yet — retry next pass.
                continue
            case .cannotDoInCurrentContext, .error:
                engine.stop()
                throw CleanerError.engineFailed("renderOffline status \(status.rawValue)")
            @unknown default:
                engine.stop()
                throw CleanerError.engineFailed("renderOffline unknown status")
            }
        }

        player.stop()
        engine.stop()
    }

    // MARK: - Pass 1: noise-floor estimate

    private static func estimateNoiseFloorDB(
        file: AVAudioFile,
        format: AVAudioFormat
    ) throws -> Float {
        file.framePosition = 0
        let windowSamples = AVAudioFrameCount(format.sampleRate * 0.05)  // 50 ms
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowSamples) else {
            throw CleanerError.engineFailed("failed to allocate noise-floor probe buffer")
        }
        var rmsSamples: [Float] = []
        while file.framePosition < file.length {
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: windowSamples)
            } catch {
                break
            }
            guard buffer.frameLength > 0 else { break }
            let rms = peakAbsoluteAmplitude(buffer: buffer)
            if rms > 0 {
                rmsSamples.append(20 * log10f(rms))
            }
        }
        guard !rmsSamples.isEmpty else { return -60 }
        rmsSamples.sort()
        // 10th percentile — the floor noise, ignoring true silence
        // which would pin to -inf. Clamp to -90 dB just in case.
        let idx = max(0, min(rmsSamples.count - 1, rmsSamples.count / 10))
        return max(-90, rmsSamples[idx])
    }

    private static func peakAbsoluteAmplitude(buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var maxAcross: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            var channelMax: Float = 0
            vDSP_maxmgv(channels[c], 1, &channelMax, vDSP_Length(frameCount))
            if channelMax > maxAcross { maxAcross = channelMax }
        }
        return maxAcross
    }

    // MARK: - Pass 2: inline noise gate

    /// Apply a soft noise gate to the in-memory buffer, mutating its
    /// floatChannelData in place. `gateGain` carries envelope state
    /// across calls so the ramp is continuous between render chunks.
    private static func applyGate(
        to buffer: AVAudioPCMBuffer,
        channels: Int,
        gateThresholdLinear: Float,
        fadeRate: Float,
        gateGain: inout [Float]
    ) {
        guard let data = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        for c in 0..<channels {
            let ptr = data[c]
            var gain = gateGain[c]
            for i in 0..<frameCount {
                let s = ptr[i]
                let mag = s < 0 ? -s : s
                if mag >= gateThresholdLinear {
                    gain = min(1, gain + fadeRate)
                } else {
                    gain = max(0, gain - fadeRate)
                }
                ptr[i] = s * gain
            }
            gateGain[c] = gain
        }
    }
}
