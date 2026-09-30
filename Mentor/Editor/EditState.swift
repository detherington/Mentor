import Foundation

/// Per-recording editor state that has no sidecar of its own (zoom,
/// talking-head and transcription each have theirs): the trim window,
/// interior cuts, the webcam overlay layout, and the recording's look
/// (title cards, transitions, overlay styles, audio mix). Persisted as
/// `edit-state.json` so closing the editor no longer silently throws
/// away trims, cuts, or a drag-placed webcam — previously reopening
/// re-ran auto-trim and every cut was gone.
///
/// Times are stored in seconds (readable, timescale-agnostic) and
/// clamped to the composition's duration when rehydrated. Webcam
/// geometry is in output pixels, same as the editor's live values.
struct EditState: Codable, Equatable {
    struct Cut: Codable, Equatable {
        let start: Double
        let end: Double
    }

    struct Point: Codable, Equatable {
        let x: Double
        let y: Double
    }

    var version: Int = 1
    var trimStart: Double
    var trimEnd: Double
    var cuts: [Cut]
    var webcamPosition: String
    var webcamShape: String
    var webcamDiameter: Double
    var webcamInset: Double
    var webcamCustomOrigin: Point?

    // The recording's look. These used to live only in the global
    // Settings, so editing one recording's captions or title card changed
    // how every other recording opened (and two open editors overwrote
    // each other). Settings now just seeds recordings that were never
    // edited; optional so earlier edit-state files still decode.
    var webcamTransitions: WebcamTransitions?
    var startCard: TitleCard?
    var endCard: TitleCard?
    var zoomEnabled: Bool?
    var cursorRipplesEnabled: Bool?
    var audioMixVolumes: AudioMixBuilder.Volumes?
    var captionStyle: CaptionStyle?
    var keystrokeOverlayStyle: KeystrokeOverlayStyle?
    var cursorHighlightStyle: CursorHighlightStyle?
    var zoomTuning: ZoomTuning?
    var webcamBackgroundStyle: WebcamBackgroundStyle?
    var noiseReductionStyle: NoiseReductionStyle?

    static func load(from url: URL) -> EditState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(EditState.self, from: data)
        } catch {
            MentorDebug.log("EDITOR: edit-state decode failed: \(error)")
            return nil
        }
    }
}
