import Foundation

/// A loaded Mentor recording, consisting of the sidecar `.mentor/` folder
/// plus the adjacent composited `.mp4`. This is the model the editor
/// window operates on.
struct RecordingProject {
    let bundleURL: URL           // …/Mentor_<timestamp>.mentor/
    let finalMP4URL: URL         // …/Mentor_<timestamp>.mp4
    let metadata: RecordingMetadata
    let eventLog: EventRecorder.Log?
    let soundboardLog: SoundboardEventLog?
    let talkingHeadLog: TalkingHeadLog?
    let zoomLog: ZoomLog?

    var screenVideoURL: URL { bundleURL.appendingPathComponent("screen.mov") }
    var webcamVideoURL: URL { bundleURL.appendingPathComponent("webcam.mov") }
    var eventsURL: URL { bundleURL.appendingPathComponent("events.json") }
    var soundboardEventsURL: URL { bundleURL.appendingPathComponent("soundboard-events.json") }
    var talkingHeadURL: URL { bundleURL.appendingPathComponent("talking-head.json") }
    var zoomURL: URL { bundleURL.appendingPathComponent("zoom.json") }
    var metadataURL: URL { bundleURL.appendingPathComponent("metadata.json") }

    var displayName: String {
        bundleURL.deletingPathExtension().lastPathComponent
    }

    /// Adapter back to the `RecordingBundle` shape used by `FinalRenderer`
    /// + `EditorComposition`.
    var bundle: RecordingBundle {
        RecordingBundle(finalMP4URL: finalMP4URL, sidecarURL: bundleURL)
    }

    enum LoadError: Error, LocalizedError {
        case notAMentorBundle(URL)
        case missingMetadata(URL)

        var errorDescription: String? {
            switch self {
            case .notAMentorBundle(let url):
                return "\(url.lastPathComponent) is not a .mentor recording bundle."
            case .missingMetadata(let url):
                return "\(url.lastPathComponent) is missing metadata.json."
            }
        }
    }

    /// Load a `RecordingProject` from a sidecar `.mentor` directory URL.
    static func load(bundleURL: URL) throws -> RecordingProject {
        guard bundleURL.pathExtension == "mentor" else {
            throw LoadError.notAMentorBundle(bundleURL)
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

        // Sibling MP4: strip the .mentor extension and add .mp4.
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
            zoomLog: zoomLog
        )
    }
}
