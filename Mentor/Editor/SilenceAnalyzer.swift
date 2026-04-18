import AVFoundation
import CoreMedia
import Foundation

/// Scans an audio file for the time range where actual content exists,
/// skipping leading + trailing silence. Used by `EditorViewModel` to set
/// sensible trim defaults so the user doesn't have to manually clip the
/// "fumble to hit record / fumble to hit stop" seconds off every
/// recording.
///
/// Algorithm: decode to PCM in ~50ms windows, RMS-threshold each window.
/// First window above threshold = content start; last = content end.
/// Padded by a few hundred ms on each side so the very start of speech
/// isn't clipped.
enum SilenceAnalyzer {

    struct Config {
        /// Amplitude threshold in dBFS. Above this is "content"; below
        /// is considered silence. -35 dB catches normal conversation
        /// while ignoring typical room noise / mic self-noise floors.
        var thresholdDB: Float = -35
        /// Analysis window size in seconds. Shorter = tighter trim
        /// bounds, but noisier (a single loud spike bumps the start
        /// earlier). 50ms is a standard VAD-ish window size.
        var windowSeconds: Double = 0.05
        /// Pad subtracted from the detected content start — so the
        /// very onset of speech isn't clipped.
        var leadPadSeconds: Double = 0.2
        /// Pad added to the detected content end.
        var trailPadSeconds: Double = 0.4
        /// Below this total trimmed length we give up and leave the
        /// full duration — otherwise an entirely-silent recording
        /// would collapse to a sub-second range.
        var minDetectedDurationSeconds: Double = 0.5
        /// Minimum number of silent→active transitions required for us
        /// to treat the mic signal as speech-like. Speech has one per
        /// syllable boundary (dozens per second); a single continuous
        /// sting (e.g. soundboard audio bleeding in through a speaker)
        /// has exactly one. Requiring 3+ rejects the "single burst"
        /// case while still accepting any real speech with at least
        /// two audible phrases.
        var minRisingEdges: Int = 3

        /// Minimum interior silence length to propose as a cut. Default
        /// 0.8s is long enough to skip "thinking pauses" and "ok so…"
        /// stalls without touching natural breath gaps between phrases
        /// (which are typically <0.5s). Bumped up to 1.2s+ for more
        /// conservative trimming.
        var interiorMinSilenceSeconds: Double = 0.8
        /// Pad kept INSIDE each detected silence on both sides so the
        /// cut doesn't clip the tail of the previous word or the
        /// attack of the next. At 0.15s each side, a 0.8s detected
        /// silence becomes a 0.5s cut.
        var interiorEndpointPadSeconds: Double = 0.15

        static let `default` = Config()
    }

    /// Richer result returned by `scan(...)`: the outer content range
    /// (same as the old `detectContentRange`) plus any long interior
    /// silences that are candidates for auto-jumpcut.
    struct Scan {
        let contentRange: CMTimeRange
        /// Interior silences, in source-time, already clamped to sit
        /// strictly inside `contentRange` and padded inwards by
        /// `interiorEndpointPadSeconds`. Sorted by start time.
        let interiorSilences: [CMTimeRange]
    }

    /// Detect the content range within `audioURL`. Returns nil if the
    /// file is missing, un-openable, entirely silent, or the detected
    /// range is too short to be useful.
    static func detectContentRange(
        audioURL: URL,
        duration: CMTime,
        config: Config = .default
    ) async -> CMTimeRange? {
        await scan(audioURL: audioURL, duration: duration, config: config)?.contentRange
    }

    /// Full silence scan — returns both the outer content range (for
    /// auto-trim) and the list of interior silent regions (for
    /// auto-jumpcut). Single pass over the audio, so callers that want
    /// both should use this rather than calling `detectContentRange`
    /// twice.
    static func scan(
        audioURL: URL,
        duration: CMTime,
        config: Config = .default
    ) async -> Scan? {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return nil
        }
        // Decoding + RMS math is CPU-bound — offload so we don't stall
        // the main actor while `loadComposition` awaits us.
        return await Task.detached(priority: .userInitiated) {
            analyzeSync(audioURL: audioURL, duration: duration, config: config)
        }.value
    }

    private static func analyzeSync(
        audioURL: URL,
        duration: CMTime,
        config: Config
    ) -> Scan? {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioURL)
        } catch {
            return nil
        }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let totalFrames = file.length
        let windowFrames = AVAudioFrameCount(max(1, sampleRate * config.windowSeconds))

        guard totalFrames > 0, sampleRate > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            return nil
        }

        // dB → linear amplitude: 10 ** (dB/20).
        let thresholdLinear = pow(10.0, Double(config.thresholdDB) / 20.0)

        var firstActiveFrame: AVAudioFramePosition?
        var lastActiveFrame: AVAudioFramePosition?
        var risingEdges = 0
        var wasActive = false
        var cursor: AVAudioFramePosition = 0

        // Interior silence tracking. We record [start, end) of each
        // silent run that begins AFTER the first active window — leading
        // silence is handled by the outer trim. Silences still open at
        // EOF are discarded because they're tail silence (ditto).
        var silenceRuns: [(start: AVAudioFramePosition, end: AVAudioFramePosition)] = []
        var currentSilenceStart: AVAudioFramePosition?
        let minSilenceFrames = AVAudioFramePosition(config.interiorMinSilenceSeconds * sampleRate)

        while cursor < totalFrames {
            let remaining = totalFrames - cursor
            let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(windowFrames), remaining))
            buffer.frameLength = 0
            file.framePosition = cursor
            do {
                try file.read(into: buffer, frameCount: framesToRead)
            } catch {
                break
            }
            let read = Int(buffer.frameLength)
            guard read > 0 else { break }

            let isActive = rms(of: buffer, channels: channelCount, frames: read) > thresholdLinear
            if isActive {
                if firstActiveFrame == nil {
                    firstActiveFrame = cursor
                }
                lastActiveFrame = cursor + AVAudioFramePosition(read)
                if !wasActive {
                    risingEdges += 1
                    // Close the silent run (if we were inside one and
                    // had at least one prior active window).
                    if let s = currentSilenceStart {
                        let runLen = cursor - s
                        if runLen >= minSilenceFrames {
                            silenceRuns.append((start: s, end: cursor))
                        }
                        currentSilenceStart = nil
                    }
                }
            } else {
                // Silent window. Start a new silent run only if we've
                // already seen speech — leading silence is outer trim.
                if firstActiveFrame != nil, currentSilenceStart == nil {
                    currentSilenceStart = cursor
                }
            }
            wasActive = isActive
            cursor += AVAudioFramePosition(read)
        }

        guard let firstFrame = firstActiveFrame, let lastFrame = lastActiveFrame else {
            return nil
        }

        // Reject single-burst detections — these are almost always a
        // soundboard cue / system sound bleeding through the mic, not
        // the user speaking. Real speech ticks this counter up quickly.
        guard risingEdges >= config.minRisingEdges else {
            return nil
        }

        let durationSec = CMTimeGetSeconds(duration)
        let startSec = max(0, Double(firstFrame) / sampleRate - config.leadPadSeconds)
        let endSec   = min(durationSec, Double(lastFrame) / sampleRate + config.trailPadSeconds)

        guard endSec - startSec >= config.minDetectedDurationSeconds else {
            return nil
        }

        let contentRange = CMTimeRange(
            start: CMTime(seconds: startSec, preferredTimescale: 600),
            end:   CMTime(seconds: endSec,   preferredTimescale: 600)
        )

        // Convert each silence run to a padded CMTimeRange. The padding
        // keeps `interiorEndpointPadSeconds` of audio before and after
        // each cut so speech tails/attacks aren't clipped — e.g. a raw
        // 0.8s silence becomes a 0.5s cut with 0.15s buffer each side.
        let pad = config.interiorEndpointPadSeconds
        let interiorSilences: [CMTimeRange] = silenceRuns.compactMap { run in
            let rawStart = Double(run.start) / sampleRate
            let rawEnd   = Double(run.end) / sampleRate
            let padStart = rawStart + pad
            let padEnd   = rawEnd - pad
            // Drop if padding collapses the cut to nothing.
            guard padEnd - padStart >= 0.1 else { return nil }
            // Clamp inside the content range so we don't cut into outer
            // trim regions (the outer trim already handles those).
            guard padStart >= CMTimeGetSeconds(contentRange.start),
                  padEnd   <= CMTimeGetSeconds(contentRange.end) else {
                return nil
            }
            return CMTimeRange(
                start: CMTime(seconds: padStart, preferredTimescale: 600),
                end:   CMTime(seconds: padEnd,   preferredTimescale: 600)
            )
        }

        return Scan(contentRange: contentRange, interiorSilences: interiorSilences)
    }

    /// RMS across all channels of a PCM buffer. Handles float32,
    /// int16, and int32 backing stores — AVAudioFile's processing
    /// format for a decoded AAC is usually float32 but we cover the
    /// others for robustness.
    private static func rms(
        of buffer: AVAudioPCMBuffer,
        channels: Int,
        frames: Int
    ) -> Double {
        guard frames > 0, channels > 0 else { return 0 }
        var sumSq: Double = 0
        var totalCount: Int = 0

        if let floats = buffer.floatChannelData {
            for c in 0..<channels {
                let ptr = floats[c]
                for i in 0..<frames {
                    let s = Double(ptr[i])
                    sumSq += s * s
                }
                totalCount += frames
            }
        } else if let int16s = buffer.int16ChannelData {
            for c in 0..<channels {
                let ptr = int16s[c]
                for i in 0..<frames {
                    let s = Double(ptr[i]) / 32768.0
                    sumSq += s * s
                }
                totalCount += frames
            }
        } else if let int32s = buffer.int32ChannelData {
            for c in 0..<channels {
                let ptr = int32s[c]
                for i in 0..<frames {
                    let s = Double(ptr[i]) / 2_147_483_648.0
                    sumSq += s * s
                }
                totalCount += frames
            }
        } else {
            return 0
        }

        return sqrt(sumSq / Double(totalCount))
    }
}
