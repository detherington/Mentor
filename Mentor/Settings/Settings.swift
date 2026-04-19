import Foundation
import CoreGraphics

enum WebcamPosition: String, CaseIterable, Identifiable {
    case bottomRight, bottomLeft, topRight, topLeft, hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomRight: return "Bottom Right"
        case .bottomLeft:  return "Bottom Left"
        case .topRight:    return "Top Right"
        case .topLeft:     return "Top Left"
        case .hidden:      return "Hidden"
        }
    }
}

enum WebcamShape: String, CaseIterable, Identifiable {
    case circle
    case roundedSquare
    /// No shape mask — the full square webcam frame (or, when paired
    /// with `WebcamBackgroundMode.transparent`, the raw person
    /// silhouette) passes through. Useful for free-floating talking-
    /// head compositions.
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .circle:        return "Circle"
        case .roundedSquare: return "Rounded Square"
        case .none:          return "No Shape"
        }
    }

    /// Corner-radius as a fraction of the shorter side length of the
    /// bounding square. Circle is exactly half (a full circle); the
    /// rounded square uses a ~iOS-app-icon-like corner. `.none`
    /// reports 0 (no rounding — but it's also not drawn at all).
    private var cornerRadiusFactor: CGFloat {
        switch self {
        case .circle:        return 0.5
        case .roundedSquare: return 0.18
        case .none:          return 0.0
        }
    }

    func cornerRadius(forSide side: CGFloat) -> CGFloat {
        side * cornerRadiusFactor
    }

    /// CGPath outlining the shape within `rect`.
    func path(in rect: CGRect) -> CGPath {
        switch self {
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)
        case .roundedSquare:
            let r = min(rect.width, rect.height) * cornerRadiusFactor
            return CGPath(
                roundedRect: rect,
                cornerWidth: r,
                cornerHeight: r,
                transform: nil
            )
        case .none:
            // Full square — used only when callers explicitly render
            // a shape path (preview borders, etc.); the compositor
            // skips the mask entirely when shape == .none.
            return CGPath(rect: rect, transform: nil)
        }
    }
}

final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("MentorSettingsDidChange")

    private let defaults = UserDefaults.standard

    private enum Key {
        static let webcamPosition  = "webcamPosition"
        static let webcamShape     = "webcamShape"
        static let webcamDiameter  = "webcamDiameter"
        static let webcamInset     = "webcamInset"
        static let captureSystemAudio = "captureSystemAudio"
        static let countdownEnabled   = "countdownEnabled"
        static let countdownSeconds   = "countdownSeconds"
        /// Beep on each tick of the pre-record countdown. Helpful
        /// for off-screen cues; distracting for silent demos. Opt-in.
        static let countdownBeepEnabled = "countdownBeepEnabled"
        /// Flash "Go!" when the countdown reaches zero before the
        /// countdown overlay dismisses. Satisfying visual cue; some
        /// users find it corny. Opt-in.
        static let countdownShowGo    = "countdownShowGo"
        static let hideMenuBarIconWhenRecording = "hideMenuBarIconWhenRecording"
        static let showWebcamPreview = "showWebcamPreview"
        static let cameraDeviceID = "cameraDeviceID"
        static let microphoneDeviceID = "microphoneDeviceID"

        // Editor defaults — last-used values are remembered so the next
        // recording opens with the same cards + fades + toggles.
        static let editorStartCard        = "editorStartCard"
        static let editorEndCard          = "editorEndCard"
        static let editorWebcamTransitions = "editorWebcamTransitions"
        static let editorSmartZoomEnabled = "editorSmartZoomEnabled"
        static let editorCursorRipplesEnabled = "editorCursorRipplesEnabled"

        /// Editor export quality preset (low/medium/high), stored as the
        /// enum's rawValue.
        static let exportQuality = "exportQuality"
        /// Per-track mix volumes used in the editor + baked into export.
        static let editorAudioMixVolumes = "editorAudioMixVolumes"
        /// Last-used caption styling (font size, colors, position).
        static let captionStyle = "captionStyle"
        /// Last-used keystroke overlay style (enable flag, size,
        /// position, show-plain-keys toggle).
        static let keystrokeOverlayStyle = "keystrokeOverlayStyle"
        /// Last-used cursor highlight halo style (enable, radius,
        /// color, opacity).
        static let cursorHighlightStyle = "cursorHighlightStyle"
        /// User-facing smart-zoom tuning knobs (scale, hold, sensitivity).
        static let zoomTuning = "zoomTuning"
        /// Webcam background mode (off / blur / color) + parameters.
        static let webcamBackgroundStyle = "webcamBackgroundStyle"
        /// Mic noise-reduction preference (enabled + strength preset).
        static let noiseReductionStyle = "noiseReductionStyle"
        /// Whether export writes a `.srt` sidecar alongside the MP4.
        static let exportSRTSidecar = "exportSRTSidecar"
        /// Teleprompter script + scroll mode + display prefs.
        static let teleprompterSettings = "teleprompterSettings"
        /// Whether the Teleprompter window is currently shown
        /// (persisted so it reopens across launches if left on).
        static let teleprompterVisible = "teleprompterVisible"
        /// Per-lane timeline visibility overrides (auto/show/hide).
        static let timelineLanePrefs = "timelineLanePrefs"

        // Live soundboard cues — shared across all recordings.
        static let soundboardCues = "soundboardCues"
        /// When true, silence the soundboard's speaker output during
        /// recording. The recording tap still captures cues; this just
        /// prevents mic double-capture if the user isn't on headphones.
        static let soundboardMuteSpeakersDuringRecording = "soundboardMuteSpeakersDuringRecording"
    }

    private init() {
        defaults.register(defaults: [
            Key.webcamPosition: WebcamPosition.bottomRight.rawValue,
            Key.webcamShape: WebcamShape.circle.rawValue,
            Key.webcamDiameter: 320.0,
            Key.webcamInset: 48.0,
            Key.captureSystemAudio: true,
            Key.countdownEnabled: true,
            Key.countdownSeconds: 3,
            Key.hideMenuBarIconWhenRecording: false,
            Key.showWebcamPreview: true,
            Key.editorSmartZoomEnabled: true,
            Key.editorCursorRipplesEnabled: true,
            // Users who go to the trouble of generating captions
            // almost always want a matching .srt for YouTube / Premiere /
            // DaVinci. Default on; togglable per session.
            Key.exportSRTSidecar: true
        ])
    }

    var webcamPosition: WebcamPosition {
        get {
            (defaults.string(forKey: Key.webcamPosition).flatMap(WebcamPosition.init(rawValue:))) ?? .bottomRight
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.webcamPosition)
            post()
        }
    }

    var webcamShape: WebcamShape {
        get {
            (defaults.string(forKey: Key.webcamShape).flatMap(WebcamShape.init(rawValue:))) ?? .circle
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.webcamShape)
            post()
        }
    }

    var webcamDiameter: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.webcamDiameter)) }
        set { defaults.set(Double(newValue), forKey: Key.webcamDiameter); post() }
    }

    var webcamInset: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.webcamInset)) }
        set { defaults.set(Double(newValue), forKey: Key.webcamInset); post() }
    }

    var captureSystemAudio: Bool {
        get { defaults.bool(forKey: Key.captureSystemAudio) }
        set { defaults.set(newValue, forKey: Key.captureSystemAudio); post() }
    }

    var countdownEnabled: Bool {
        get { defaults.bool(forKey: Key.countdownEnabled) }
        set { defaults.set(newValue, forKey: Key.countdownEnabled); post() }
    }

    var countdownSeconds: Int {
        get { max(1, defaults.integer(forKey: Key.countdownSeconds)) }
        set { defaults.set(max(1, newValue), forKey: Key.countdownSeconds); post() }
    }

    var countdownBeepEnabled: Bool {
        get { defaults.bool(forKey: Key.countdownBeepEnabled) }
        set { defaults.set(newValue, forKey: Key.countdownBeepEnabled); post() }
    }

    var countdownShowGo: Bool {
        get { defaults.bool(forKey: Key.countdownShowGo) }
        set { defaults.set(newValue, forKey: Key.countdownShowGo); post() }
    }

    var hideMenuBarIconWhenRecording: Bool {
        get { defaults.bool(forKey: Key.hideMenuBarIconWhenRecording) }
        set { defaults.set(newValue, forKey: Key.hideMenuBarIconWhenRecording); post() }
    }

    var showWebcamPreview: Bool {
        get { defaults.bool(forKey: Key.showWebcamPreview) }
        set { defaults.set(newValue, forKey: Key.showWebcamPreview); post() }
    }

    /// `AVCaptureDevice.uniqueID` of the preferred camera. `nil` = use
    /// the system default (front-facing / built-in / first discovered).
    var cameraDeviceID: String? {
        get { defaults.string(forKey: Key.cameraDeviceID) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.cameraDeviceID)
            } else {
                defaults.removeObject(forKey: Key.cameraDeviceID)
            }
            post()
        }
    }

    /// `AVCaptureDevice.uniqueID` of the preferred microphone. `nil` =
    /// system default.
    var microphoneDeviceID: String? {
        get { defaults.string(forKey: Key.microphoneDeviceID) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.microphoneDeviceID)
            } else {
                defaults.removeObject(forKey: Key.microphoneDeviceID)
            }
            post()
        }
    }

    // MARK: - Editor defaults

    /// Last-used start card. `nil` until the user opens the editor once —
    /// EditorViewModel then falls back to `TitleCard.defaultStart`.
    var editorStartCard: TitleCard? {
        get { readJSON(Key.editorStartCard) }
        set { writeJSON(newValue, forKey: Key.editorStartCard) }
    }

    var editorEndCard: TitleCard? {
        get { readJSON(Key.editorEndCard) }
        set { writeJSON(newValue, forKey: Key.editorEndCard) }
    }

    var editorWebcamTransitions: WebcamTransitions? {
        get { readJSON(Key.editorWebcamTransitions) }
        set { writeJSON(newValue, forKey: Key.editorWebcamTransitions) }
    }

    var editorSmartZoomEnabled: Bool {
        get { defaults.bool(forKey: Key.editorSmartZoomEnabled) }
        set { defaults.set(newValue, forKey: Key.editorSmartZoomEnabled); post() }
    }

    var editorCursorRipplesEnabled: Bool {
        get { defaults.bool(forKey: Key.editorCursorRipplesEnabled) }
        set { defaults.set(newValue, forKey: Key.editorCursorRipplesEnabled); post() }
    }

    var exportQuality: ExportQuality {
        get {
            (defaults.string(forKey: Key.exportQuality).flatMap(ExportQuality.init(rawValue:))) ?? .high
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.exportQuality)
            post()
        }
    }

    var editorAudioMixVolumes: AudioMixBuilder.Volumes? {
        get { readJSON(Key.editorAudioMixVolumes) }
        set { writeJSON(newValue, forKey: Key.editorAudioMixVolumes) }
    }

    var captionStyle: CaptionStyle? {
        get { readJSON(Key.captionStyle) }
        set { writeJSON(newValue, forKey: Key.captionStyle) }
    }

    var keystrokeOverlayStyle: KeystrokeOverlayStyle? {
        get { readJSON(Key.keystrokeOverlayStyle) }
        set { writeJSON(newValue, forKey: Key.keystrokeOverlayStyle) }
    }

    var cursorHighlightStyle: CursorHighlightStyle? {
        get { readJSON(Key.cursorHighlightStyle) }
        set { writeJSON(newValue, forKey: Key.cursorHighlightStyle) }
    }

    var zoomTuning: ZoomTuning? {
        get { readJSON(Key.zoomTuning) }
        set { writeJSON(newValue, forKey: Key.zoomTuning) }
    }

    var webcamBackgroundStyle: WebcamBackgroundStyle? {
        get { readJSON(Key.webcamBackgroundStyle) }
        set { writeJSON(newValue, forKey: Key.webcamBackgroundStyle) }
    }

    var noiseReductionStyle: NoiseReductionStyle? {
        get { readJSON(Key.noiseReductionStyle) }
        set { writeJSON(newValue, forKey: Key.noiseReductionStyle) }
    }

    var exportSRTSidecar: Bool {
        get { defaults.bool(forKey: Key.exportSRTSidecar) }
        set { defaults.set(newValue, forKey: Key.exportSRTSidecar); post() }
    }

    var teleprompterSettings: TeleprompterSettings? {
        get { readJSON(Key.teleprompterSettings) }
        set { writeJSON(newValue, forKey: Key.teleprompterSettings) }
    }

    var teleprompterVisible: Bool {
        get { defaults.bool(forKey: Key.teleprompterVisible) }
        set { defaults.set(newValue, forKey: Key.teleprompterVisible); post() }
    }

    var timelineLanePrefs: TimelineLanePrefs? {
        get { readJSON(Key.timelineLanePrefs) }
        set { writeJSON(newValue, forKey: Key.timelineLanePrefs) }
    }

    /// Live soundboard cues. Never nil — defaults to an empty array.
    var soundboardCues: [SoundCue] {
        get { readJSON(Key.soundboardCues) ?? [] }
        set { writeJSON(newValue, forKey: Key.soundboardCues) }
    }

    var soundboardMuteSpeakersDuringRecording: Bool {
        get { defaults.bool(forKey: Key.soundboardMuteSpeakersDuringRecording) }
        set { defaults.set(newValue, forKey: Key.soundboardMuteSpeakersDuringRecording); post() }
    }

    // MARK: - JSON-blob helpers

    /// Encode via `JSONEncoder`; a nil `value` removes the key. Keeps the
    /// accessors above a single line each without each of them rolling
    /// its own encoder.
    private func writeJSON<T: Encodable>(_ value: T?, forKey key: String) {
        if let value {
            if let data = try? JSONEncoder().encode(value) {
                defaults.set(data, forKey: key)
            }
        } else {
            defaults.removeObject(forKey: key)
        }
        post()
    }

    private func readJSON<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func post() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
