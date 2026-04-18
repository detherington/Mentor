import AVFoundation
import Foundation
import Speech

/// Post-capture speech-to-text for the mic track. Tries, in order:
///
///  1. **macOS 26+ modern API** — `SpeechAnalyzer` driving a
///     `Speech.SpeechTranscriber` module. This is the path Apple
///     actively maintains and the one Dictation itself uses
///     on-device. `AssetInventory` is asked to install the model for
///     the requested locale before analysis if it isn't already.
///  2. **Legacy `SFSpeechRecognizer`** with `requiresOnDeviceRecognition`
///     = `true`. This is the old API, fully deprecated in macOS 26 —
///     functional below 26, but returns empty results on 26 (the bug
///     that made captions appear to do nothing on first ship).
///  3. **Cloud fallback** (`allowCloudFallback: true`). Drops the
///     on-device constraint on the legacy recognizer so the request
///     goes through Apple's servers. Privacy-sensitive — only used
///     when the user explicitly opts in via the editor inspector.
///
/// The type is named `CaptionTranscriber` (not `SpeechTranscriber`)
/// deliberately — Apple's new API introduces a class named
/// `Speech.SpeechTranscriber` and a collision here would shadow it.
enum CaptionTranscriber {
    enum TranscriberError: Error, LocalizedError {
        case notAuthorized
        case unavailable(String)
        case recognizerFailed(String)
        case onDeviceUnsupported
        case siriOrDictationDisabled
        case noSpeechDetected
        /// macOS 26+ modern API couldn't install the speech model
        /// (network needed for first-time download, or locale isn't
        /// supported at all). Caller can fall back to a different
        /// locale or the legacy path.
        case assetUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Mentor needs Speech Recognition permission to transcribe. Grant it in System Settings → Privacy & Security → Speech Recognition, then try again."
            case .unavailable(let reason):
                return "Speech recognition isn't available: \(reason)"
            case .recognizerFailed(let reason):
                return "Transcription failed: \(reason)"
            case .onDeviceUnsupported:
                return "On-device speech recognition isn't supported on this Mac for the selected language. (Mentor only uses on-device mode so audio stays local.)"
            case .siriOrDictationDisabled:
                return "Mentor needs the on-device Speech model, which Apple only loads when either Siri or Dictation is enabled. Turn one on in System Settings → Apple Intelligence & Siri, or System Settings → Keyboard → Dictation, then click Generate again."
            case .noSpeechDetected:
                return "No speech was detected in the recording. Two likely causes: (1) the mic was silent or too quiet — check the waveform strip on the timeline, or (2) macOS is still downloading the on-device Speech model after you enabled Siri / Dictation — wait a few minutes and try again."
            case .assetUnavailable(let reason):
                return "The on-device Speech model for this language isn't installed and couldn't be downloaded: \(reason)"
            }
        }
    }

    static func transcribe(
        audioURL: URL,
        allowCloudFallback: Bool
    ) async throws -> TranscriptionLog {
        let auth: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard auth == .authorized else {
            throw TranscriberError.notAuthorized
        }

        let preferred = preferredLocale()
        MentorDebug.log("CAPTIONS: preferredLocale=\(preferred.identifier) systemLocale=\(Locale.current.identifier) allowCloudFallback=\(allowCloudFallback)")

        // ---- Tier 1: modern SpeechAnalyzer API (macOS 26+) ----
        if #available(macOS 26.0, *) {
            // Try preferred locale, then en-US as fallback.
            for loc in dedup([preferred, Locale(identifier: "en-US")]) {
                do {
                    return try await modernTranscribe(audioURL: audioURL, locale: loc)
                } catch TranscriberError.assetUnavailable(let reason) {
                    MentorDebug.log("CAPTIONS: modern API asset unavailable for \(loc.identifier): \(reason) — trying next locale")
                } catch TranscriberError.noSpeechDetected {
                    MentorDebug.log("CAPTIONS: modern API returned no speech for \(loc.identifier)")
                    // For "no speech" we can still try the legacy /
                    // cloud paths — it might be a real silent clip, or
                    // this locale's modern model failed silently.
                    break
                } catch {
                    MentorDebug.log("CAPTIONS: modern API failed on \(loc.identifier): \(error.localizedDescription) — trying next")
                }
            }
        }

        // ---- Tier 2: legacy on-device, system locale then en-US ----
        let legacyLocales = dedup([preferred, Locale(identifier: "en-US")])
        for loc in legacyLocales {
            do {
                return try await legacyTranscribe(audioURL: audioURL, locale: loc, onDeviceOnly: true)
            } catch TranscriberError.noSpeechDetected {
                MentorDebug.log("CAPTIONS: legacy on-device returned empty for \(loc.identifier)")
            }
        }

        // ---- Tier 3: cloud fallback (explicit opt-in) ----
        guard allowCloudFallback else {
            throw TranscriberError.noSpeechDetected
        }
        MentorDebug.log("CAPTIONS: falling back to cloud recognition (audio leaves device)")
        return try await legacyTranscribe(audioURL: audioURL, locale: Locale(identifier: "en-US"), onDeviceOnly: false)
    }

    // MARK: - Modern path

    @available(macOS 26.0, *)
    private static func modernTranscribe(audioURL: URL, locale: Locale) async throws -> TranscriptionLog {
        guard Speech.SpeechTranscriber.isAvailable else {
            throw TranscriberError.unavailable("modern SpeechTranscriber not available")
        }

        // `timeIndexedTranscriptionWithAlternatives` preset: emits
        // finalized results with `CMTimeRange` per result (exactly what
        // our line grouping wants) plus an alternatives list we ignore.
        let transcriber = Speech.SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )

        // Ensure the locale's model is installed. On first use, this
        // kicks off a download (can take a minute on a slow network).
        let status = await AssetInventory.status(forModules: [transcriber])
        MentorDebug.log("CAPTIONS: asset status for \(locale.identifier) = \(status)")
        switch status {
        case .unsupported:
            throw TranscriberError.assetUnavailable("\(locale.identifier) not supported")
        case .supported, .downloading:
            do {
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    MentorDebug.log("CAPTIONS: installing asset for \(locale.identifier)…")
                    try await req.downloadAndInstall()
                    MentorDebug.log("CAPTIONS: asset installed for \(locale.identifier)")
                }
            } catch {
                throw TranscriberError.assetUnavailable(error.localizedDescription)
            }
        case .installed:
            break
        @unknown default:
            break
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw TranscriberError.recognizerFailed("can't open \(audioURL.lastPathComponent): \(error.localizedDescription)")
        }

        // Creating the analyzer with a file + `finishAfterFile: true`
        // auto-starts analysis and closes the results stream when the
        // file is fully consumed. That makes iteration a simple
        // `for try await`.
        let analyzer: SpeechAnalyzer
        do {
            analyzer = try await SpeechAnalyzer(
                inputAudioFile: audioFile,
                modules: [transcriber],
                finishAfterFile: true
            )
        } catch {
            throw TranscriberError.recognizerFailed("SpeechAnalyzer init: \(error.localizedDescription)")
        }
        _ = analyzer  // keep the actor alive for the duration of the stream

        var lines: [TranscriptionLine] = []
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = CMTimeGetSeconds(result.range.start)
                let end = CMTimeGetSeconds(result.range.end)
                guard !text.isEmpty, end > start else { continue }
                lines.append(TranscriptionLine(text: text, startSeconds: start, endSeconds: end))
            }
        } catch {
            throw TranscriberError.recognizerFailed("SpeechAnalyzer stream: \(error.localizedDescription)")
        }

        MentorDebug.log("CAPTIONS: modern API produced \(lines.count) lines for \(locale.identifier)")
        guard !lines.isEmpty else {
            throw TranscriberError.noSpeechDetected
        }
        return TranscriptionLog(
            version: 1,
            locale: locale.identifier,
            createdAt: Date(),
            lines: lines
        )
    }

    // MARK: - Legacy path

    private static func legacyTranscribe(
        audioURL: URL,
        locale: Locale,
        onDeviceOnly: Bool
    ) async throws -> TranscriptionLog {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriberError.unavailable("no recognizer for \(locale.identifier)")
        }
        guard recognizer.isAvailable else {
            throw TranscriberError.unavailable("recognizer temporarily unavailable")
        }
        if onDeviceOnly && !recognizer.supportsOnDeviceRecognition {
            throw TranscriberError.onDeviceUnsupported
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = onDeviceOnly
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { cont in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    let msg = error.localizedDescription.lowercased()
                    if msg.contains("siri") && msg.contains("dictation") && msg.contains("disabled") {
                        cont.resume(throwing: TranscriberError.siriOrDictationDisabled)
                    } else {
                        cont.resume(throwing: TranscriberError.recognizerFailed(error.localizedDescription))
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                cont.resume(returning: result)
            }
        }

        let segs = result.bestTranscription.segments
        MentorDebug.log("CAPTIONS: legacy locale=\(locale.identifier) onDevice=\(onDeviceOnly) segments=\(segs.count)")

        let rawLines = groupIntoLines(segments: segs)
        let lines = rawLines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.endSeconds > $0.startSeconds }
        guard !lines.isEmpty else {
            throw TranscriberError.noSpeechDetected
        }
        return TranscriptionLog(
            version: 1,
            locale: locale.identifier,
            createdAt: Date(),
            lines: lines
        )
    }

    // MARK: - Locale resolution

    private static func preferredLocale() -> Locale {
        let supported = SFSpeechRecognizer.supportedLocales()
        let system = Locale.current
        if let exact = supported.first(where: { $0.identifier == system.identifier }) {
            return exact
        }
        let normalised = system.identifier.replacingOccurrences(of: "_", with: "-")
        if let match = supported.first(where: { $0.identifier == normalised }) {
            return match
        }
        if let lang = system.language.languageCode?.identifier,
           let byLang = supported.first(where: { $0.language.languageCode?.identifier == lang }) {
            return byLang
        }
        return Locale(identifier: "en-US")
    }

    private static func dedup(_ locales: [Locale]) -> [Locale] {
        var seen = Set<String>()
        return locales.filter { seen.insert($0.identifier).inserted }
    }

    // MARK: - Legacy-path line grouping

    /// Collapse word-level segments from `SFSpeechRecognizer` into rows
    /// of subtitles. Only used by the legacy + cloud paths — the modern
    /// API returns pre-grouped results with their own `CMTimeRange`.
    static func groupIntoLines(segments: [SFTranscriptionSegment]) -> [TranscriptionLine] {
        let maxChars: Int = 42
        let maxDuration: TimeInterval = 4.0
        let gapThreshold: TimeInterval = 0.6

        var lines: [TranscriptionLine] = []
        var bucket: [SFTranscriptionSegment] = []

        func flush() {
            guard let first = bucket.first, let last = bucket.last else { return }
            let text = bucket.map(\.substring).joined(separator: " ")
            lines.append(TranscriptionLine(
                text: text,
                startSeconds: first.timestamp,
                endSeconds: last.timestamp + last.duration
            ))
            bucket.removeAll(keepingCapacity: true)
        }

        for seg in segments {
            if bucket.isEmpty {
                bucket.append(seg)
                continue
            }
            let last = bucket.last!
            let gap = seg.timestamp - (last.timestamp + last.duration)
            let runningText = bucket.map(\.substring).joined(separator: " ")
            let runningSpan = (last.timestamp + last.duration) - bucket.first!.timestamp
            let wouldOverflow = runningText.count + 1 + seg.substring.count > maxChars
            let wouldOvershoot = runningSpan > maxDuration

            if gap > gapThreshold || wouldOverflow || wouldOvershoot {
                flush()
            }
            bucket.append(seg)
        }
        flush()
        return lines
    }
}
