import Foundation

/// A loaded Pepper recording, consisting of the sidecar `.pepper/` folder
/// plus the adjacent composited `.mp4`. This is the model the editor
/// window operates on.
struct RecordingProject {
    let bundleURL: URL           // …/Pepper_<timestamp>.pepper/
    let finalMP4URL: URL         // …/Pepper_<timestamp>.mp4
    let metadata: RecordingMetadata
    let eventLog: EventRecorder.Log?
    let soundboardLog: SoundboardEventLog?
    let talkingHeadLog: TalkingHeadLog?
    let zoomLog: ZoomLog?
    let transcription: TranscriptionLog?
    let cursorLog: CursorSampler.Log?

    // Sidecar file URLs live on `bundle` (`RecordingBundle`) — one
    // source of truth for the layout.

    var displayName: String {
        bundleURL.deletingPathExtension().lastPathComponent
    }

    /// Adapter back to the `RecordingBundle` shape used by `FinalRenderer`
    /// + `EditorComposition`.
    var bundle: RecordingBundle {
        RecordingBundle(finalMP4URL: finalMP4URL, sidecarURL: bundleURL)
    }

    enum LoadError: Error, LocalizedError {
        case notARecordingBundle(URL)
        case missingMetadata(URL)

        var errorDescription: String? {
            switch self {
            case .notARecordingBundle(let url):
                return "\(url.lastPathComponent) isn't a Pepper recording."
            case .missingMetadata(let url):
                return "\(url.lastPathComponent) is missing metadata.json."
            }
        }
    }

    /// Load a `RecordingProject` from a sidecar `.pepper` directory URL.
    static func load(bundleURL: URL) throws -> RecordingProject {
        guard RecordingBundle.isRecording(bundleURL) else {
            throw LoadError.notARecordingBundle(bundleURL)
        }

        let metadataURL = bundleURL.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw LoadError.missingMetadata(bundleURL)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(
            RecordingMetadata.self,
            from: Data(contentsOf: metadataURL)
        )

        var log: EventRecorder.Log? = nil
        let eventsURL = bundleURL.appendingPathComponent("events.json")
        if let data = try? Data(contentsOf: eventsURL) {
            log = try? decoder.decode(EventRecorder.Log.self, from: data)
        }

        var soundboardLog: SoundboardEventLog? = nil
        let sbURL = bundleURL.appendingPathComponent("soundboard-events.json")
        if let data = try? Data(contentsOf: sbURL) {
            soundboardLog = try? decoder.decode(SoundboardEventLog.self, from: data)
        }

        var talkingHeadLog: TalkingHeadLog? = nil
        let thURL = bundleURL.appendingPathComponent("talking-head.json")
        if let data = try? Data(contentsOf: thURL) {
            talkingHeadLog = try? decoder.decode(TalkingHeadLog.self, from: data)
        }

        var zoomLog: ZoomLog? = nil
        let zURL = bundleURL.appendingPathComponent("zoom.json")
        if let data = try? Data(contentsOf: zURL) {
            zoomLog = try? decoder.decode(ZoomLog.self, from: data)
        }

        var transcription: TranscriptionLog? = nil
        let tURL = bundleURL.appendingPathComponent("transcription.json")
        if let data = try? Data(contentsOf: tURL) {
            transcription = try? decoder.decode(TranscriptionLog.self, from: data)
        }

        var cursorLog: CursorSampler.Log? = nil
        let cURL = bundleURL.appendingPathComponent("cursor.json")
        if let data = try? Data(contentsOf: cURL) {
            cursorLog = try? decoder.decode(CursorSampler.Log.self, from: data)
        }

        // Sibling MP4: strip the bundle extension and add .mp4.
        let stem = bundleURL.deletingPathExtension().lastPathComponent
        let finalMP4URL = bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(stem).mp4")

        return RecordingProject(
            bundleURL: bundleURL,
            finalMP4URL: finalMP4URL,
            metadata: metadata,
            eventLog: log,
            soundboardLog: soundboardLog,
            talkingHeadLog: talkingHeadLog,
            zoomLog: zoomLog,
            transcription: transcription,
            cursorLog: cursorLog
        )
    }
}
