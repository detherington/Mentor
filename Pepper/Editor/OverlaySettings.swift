import CoreGraphics
import CoreMedia

/// Everything the compositor draws over the screen track, as one value
/// shared by the editor preview (`LiveCompositor.State`) and exports
/// (`FinalRenderer.ExportLayout`), and built in one place by
/// `EditorViewModel.currentOverlay()`.
///
/// These used to be three parallel field lists — the compositor's state
/// snapshot, the export layout, and a 20-parameter `State.update` — kept
/// in sync by hand. A field missed in one of them is how the dragged
/// webcam position silently dropped out of exports.
///
/// Times are source-recording time; `remapped(by:)` moves the time-based
/// parts onto a trimmed / cut output timeline.
struct OverlaySettings {
    var position: WebcamPosition = .bottomRight
    var shape: WebcamShape = .circle
    /// Output pixels.
    var diameter: CGFloat = 640
    /// Output pixels.
    var inset: CGFloat = 96
    /// Drag-to-reposition override (output pixels, bottom-left origin);
    /// nil → the `position` corner preset.
    var webcamCustomOrigin: CGPoint?
    var webcamTransitions: WebcamTransitions = .default
    /// `off` skips the per-frame segmentation pass entirely.
    var webcamBackgroundStyle: WebcamBackgroundStyle = .default
    var zoomKeyframes: [ZoomKeyframe] = []
    var talkingHeadKeyframes: [TalkingHeadKeyframe] = []
    var startCard: TitleCard = .defaultStart
    var endCard: TitleCard = .defaultEnd
    var cursorRipples: [CursorRipple] = []
    var cursorRippleStyle: CursorRippleStyle = .default
    /// Burned-in subtitles. Empty, or `captionStyle.enabled == false`,
    /// short-circuits before any per-frame lookup.
    var transcriptionLines: [TranscriptionLine] = []
    var captionStyle: CaptionStyle = .default
    /// Same short-circuit rule as captions.
    var keystrokeChips: [KeystrokeChip] = []
    var keystrokeOverlayStyle: KeystrokeOverlayStyle = .default
    /// Cursor halo, interpolated from `cursorTrack`'s samples. Empty track
    /// or style disabled skips the overlay.
    var cursorTrack: CursorHighlightTrack = .empty
    var cursorHighlightStyle: CursorHighlightStyle = .default

    /// The time-based parts moved onto `map`'s output timeline — cut
    /// content dropped, trim start at zero. Used by exports with cuts,
    /// which render a stitched composition.
    func remapped(by map: TrimMap) -> OverlaySettings {
        var out = self
        out.zoomKeyframes = map.remap(zoomKeyframes: zoomKeyframes)
        out.talkingHeadKeyframes = map.remap(talkingHeadKeyframes: talkingHeadKeyframes)
        out.cursorRipples = map.remap(cursorRipples: cursorRipples)
        out.transcriptionLines = map.remap(transcriptionLines: transcriptionLines)
        out.keystrokeChips = map.remap(keystrokeChips: keystrokeChips)
        out.cursorTrack = map.remap(cursorTrack: cursorTrack)
        return out
    }
}
