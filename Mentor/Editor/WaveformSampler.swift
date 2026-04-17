import AVFoundation
import Foundation

/// Precomputes a coarse peak-amplitude profile of an audio file for the
/// editor's timeline waveform overlay. Produces a fixed-count `[Float]`
/// array (0...1) — the view scales it to whatever width the timeline
/// currently has.
///
/// Sampling strategy: walk the PCM buffers in chunks sized so that we
/// land ~`bucketCount` bucket boundaries across the whole file. For each
/// bucket, track the peak absolute amplitude across all channels + all
/// frames that fall into it. Normalise by the global peak so a quiet
/// recording still maps its loudest moments to ≈1.0.
enum WaveformSampler {
    /// Default number of peak samples. 400 gives a dense enough strip at
    /// typical window widths without being perf-sensitive — each bucket
    /// is just a running max + one compare per frame.
    static let defaultBucketCount = 400

    static func sample(
        audioURL: URL,
        bucketCount: Int = defaultBucketCount
    ) async -> [Float] {
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return [] }
        return await Task.detached(priority: .utility) {
            sampleSync(audioURL: audioURL, bucketCount: bucketCount)
        }.value
    }

    private static func sampleSync(audioURL: URL, bucketCount: Int) -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioURL)
        } catch {
            return []
        }

        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0, bucketCount > 0 else { return [] }

        let framesPerBucket = max(1, Int(totalFrames / AVAudioFramePosition(bucketCount)))
        let windowFrames = AVAudioFrameCount(max(1024, framesPerBucket))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            return []
        }

        var buckets = [Float](repeating: 0, count: bucketCount)
        var globalPeak: Float = 0
        var cursor: AVAudioFramePosition = 0

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

            let bucketIndex = min(bucketCount - 1, Int(cursor * AVAudioFramePosition(bucketCount) / totalFrames))
            let peak = peakAmplitude(
                buffer: buffer,
                channels: Int(format.channelCount),
                frames: read
            )
            if peak > buckets[bucketIndex] { buckets[bucketIndex] = peak }
            if peak > globalPeak { globalPeak = peak }

            cursor += AVAudioFramePosition(read)
        }

        // Normalise so the loudest peak in the whole recording hits 1.0
        // — the waveform strip is a visual aid, not a dB meter, and a
        // quiet recording still deserves a readable silhouette.
        if globalPeak > 0.0001 {
            let scale = 1.0 / globalPeak
            for i in 0..<buckets.count { buckets[i] = min(1, buckets[i] * scale) }
        }
        return buckets
    }

    private static func peakAmplitude(
        buffer: AVAudioPCMBuffer,
        channels: Int,
        frames: Int
    ) -> Float {
        guard frames > 0, channels > 0 else { return 0 }
        var peak: Float = 0

        if let floats = buffer.floatChannelData {
            for c in 0..<channels {
                let ptr = floats[c]
                for i in 0..<frames {
                    let v = abs(ptr[i])
                    if v > peak { peak = v }
                }
            }
        } else if let int16s = buffer.int16ChannelData {
            for c in 0..<channels {
                let ptr = int16s[c]
                for i in 0..<frames {
                    let v = Float(abs(Int(ptr[i]))) / 32768.0
                    if v > peak { peak = v }
                }
            }
        } else if let int32s = buffer.int32ChannelData {
            for c in 0..<channels {
                let ptr = int32s[c]
                for i in 0..<frames {
                    let v = Float(abs(Int(ptr[i]))) / 2_147_483_648.0
                    if v > peak { peak = v }
                }
            }
        }
        return peak
    }
}
