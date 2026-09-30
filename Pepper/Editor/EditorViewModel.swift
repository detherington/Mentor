import SwiftUI
import AVFoundation
import AppKit

/// Owns the editor's runtime state: the player item (a live composition over
/// raw screen + webcam + original audio), the current overlay overrides,
/// playback + trim state, and the plumbing that keeps the compositor's
/// shared state in sync.
@MainActor
@Observable
final class EditorViewModel {
    let project: RecordingProject
    let outputSize: CGSize
    let backingScale: CGFloat

    let player: AVPlayer

    private(set) var isLoading = true
    private(set) var loadError: (any Error)?

    // Timeline / playback state
    private(set) var duration: CMTime = .zero
    private(set) var currentTime: CMTime = .zero
    private(set) var isPlaying: Bool = false

    /// Trim range in composition time. `trimStart` defaults to .zero and
    /// `trimEnd` defaults to the full duration once the composition loads.
    private(set) var trimStart: CMTime = .zero { didSet { scheduleEditStateSave() } }
    private(set) var trimEnd: CMTime = .zero { didSet { scheduleEditStateSave() } }

    /// Interior cut ranges — regions in source-composition time that have
    /// been excised from the middle of the recording. Sorted, non-
    /// overlapping, strictly inside `[trimStart, trimEnd]`. Mutated via
    /// `insertCut` / `removeCut` / `clearCuts`; use `trimMap` (computed
    /// below) for any read that needs to know the kept ranges.
    private(set) var cutRanges: [CMTimeRange] = [] { didSet { scheduleEditStateSave() } }

    /// `edit-state.json` as loaded at open — seeds webcam layout in init
    /// and trim/cuts once the composition's duration is known.
    @ObservationIgnored private let savedEditState: EditState?

    /// Fixed for the life of the editor, so computed once rather than on
    /// every inspector render (a file-exists check and an event-log scan).
    let hasSoundboardTrack: Bool
    let loggedClickCount: Int
    @ObservationIgnored private let sidecars = SidecarStore()
    /// Cuts the playback boundary observers were last installed for.
    @ObservationIgnored private var observedCutRanges: [CMTimeRange]?

    /// Derived view of trim + cuts — the editor's single source of truth
    /// for "what's in the output timeline". Built fresh on every read;
    /// TrimMap's initializer re-normalises defensively so this is always
    /// valid even if the inputs drift.
    var trimMap: TrimMap {
        TrimMap(outerTrim: trimRange, cuts: cutRanges)
    }

    /// Anchor for an in-progress range selection. When non-nil, the
    /// selection runs between this point and `currentTime` (order-
    /// independent). Used by the cut workflow: user hits "Mark" here,
    /// scrubs to the other end, hits "Cut".
    var selectionStart: CMTime?

    /// ID of the caption line the user most recently targeted via the
    /// timeline's caption lane. Non-nil values (a) expand the inspector
    /// caption-edit disclosure, (b) scroll that line's row into view,
    /// (c) focus its text field. Cleared by other inspector actions
    /// so selection doesn't linger.
    var focusedCaptionLineId: UUID?

    /// The inspector row that's open (one at a time). Lives here, not in
    /// the view, so the timeline and preview can open a row: clicking a
    /// zoom opens Smart zoom, dragging the webcam opens the webcam row.
    var openInspectorFeature: InspectorFeature?
    /// The zoom picked on the timeline, edited on its own in the Smart
    /// zoom row. Cleared when that zoom is removed.
    var selectedZoomID: UUID?

    /// Convenience: normalised range from `selectionStart` to
    /// `currentTime`, or nil if no mark is set. Clamped to the outer
    /// trim so you can't select into already-trimmed regions.
    var selectionRange: CMTimeRange? {
        guard let anchor = selectionStart, duration > .zero else { return nil }
        let a = clamp(anchor, lower: trimStart, upper: trimEnd)
        let b = clamp(currentTime, lower: trimStart, upper: trimEnd)
        let lo = CMTimeCompare(a, b) <= 0 ? a : b
        let hi = CMTimeCompare(a, b) <= 0 ? b : a
        guard CMTimeCompare(hi, lo) > 0 else { return nil }
        return CMTimeRange(start: lo, end: hi)
    }

    // Export state
    private(set) var isExporting = false
    private(set) var exportProgress: Float = 0
    var exportError: (any Error)?
    private var exportTask: Task<Void, Never>?

    /// When non-nil, the preview is in "click to place zoom focus"
    /// mode — the EditorView overlays a hit-catcher that turns the
    /// next click in the preview into a new `target` for this
    /// keyframe. Observable so the UI can draw a banner + change the
    /// row button's label while we wait.
    var zoomTargetBeingPlaced: UUID?


    // AVPlayer observers (torn down in deinit — marked nonisolated(unsafe)
    // so deinit can reference them without @MainActor hops).
    nonisolated(unsafe) private var timeObserverToken: Any?
    nonisolated(unsafe) private var rateObservation: NSKeyValueObservation?
    /// Boundary observers that seek past each interior cut during
    /// playback. Rebuilt whenever `cutRanges` changes via
    /// `refreshCutBoundaryObservers()`. One token per observer registration.
    nonisolated(unsafe) private var cutBoundaryTokens: [Any] = []

    // Editable overlay parameters. `didSet` writes through to the compositor's
    // shared state and nudges the player to redraw if paused.
    var webcamPosition: WebcamPosition {
        didSet {
            if oldValue != webcamPosition {
                // Picking a preset corner supersedes any custom drag
                // placement — otherwise the user would toggle the
                // picker and see nothing happen.
                webcamCustomOrigin = nil
                applyLayout()
                registerUndoableChange(\.webcamPosition, from: oldValue,
                                       actionName: "Change Webcam Position",
                                       coalesceKey: "webcamPosition")
                scheduleEditStateSave()
            }
        }
    }
    /// Explicit drag-placed webcam origin (output-pixel, bottom-left).
    /// Nil means use the preset corner + inset. The editor preview
    /// exposes a drag gesture on the webcam rect that sets this; the
    /// inspector picker clears it when the user switches to a preset.
    var webcamCustomOrigin: CGPoint? {
        didSet {
            if oldValue != webcamCustomOrigin {
                applyLayout()
                registerUndoableChange(\.webcamCustomOrigin, from: oldValue,
                                       actionName: "Move Webcam",
                                       coalesceKey: "webcamCustomOrigin")
                scheduleEditStateSave()
            }
        }
    }
    var webcamShape: WebcamShape {
        didSet {
            if oldValue != webcamShape {
                applyLayout()
                registerUndoableChange(\.webcamShape, from: oldValue,
                                       actionName: "Change Webcam Shape",
                                       coalesceKey: "webcamShape")
                scheduleEditStateSave()
            }
        }
    }
    /// In output pixels.
    var webcamDiameter: CGFloat {
        didSet {
            if oldValue != webcamDiameter {
                applyLayout()
                registerUndoableChange(\.webcamDiameter, from: oldValue,
                                       actionName: "Change Webcam Size",
                                       coalesceKey: "webcamDiameter")
                scheduleEditStateSave()
            }
        }
    }
    /// In output pixels.
    var webcamInset: CGFloat {
        didSet {
            if oldValue != webcamInset {
                applyLayout()
                registerUndoableChange(\.webcamInset, from: oldValue,
                                       actionName: "Change Webcam Inset",
                                       coalesceKey: "webcamInset")
                scheduleEditStateSave()
            }
        }
    }

    /// Auto-generated zoom-in moments derived from the click event log.
    /// Set after the composition loads (we need its duration). Toggleable
    /// from the inspector; persisted to Settings so it survives across
    /// editor sessions.
    private(set) var zoomKeyframes: [ZoomKeyframe] = []
    var zoomEnabled: Bool {
        didSet {
            if oldValue != zoomEnabled {
                Settings.shared.editorSmartZoomEnabled = zoomEnabled
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.zoomEnabled, from: oldValue,
                                       actionName: "Toggle Smart Zoom",
                                       coalesceKey: "zoomEnabled")
            }
        }
    }

    /// Webcam fade in / fade out at the start + end of the recording.
    /// Persisted — the user's preferred feel is remembered across edits.
    var webcamTransitions: WebcamTransitions {
        didSet {
            if oldValue != webcamTransitions {
                Settings.shared.editorWebcamTransitions = webcamTransitions
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.webcamTransitions, from: oldValue,
                                       actionName: "Change Webcam Transitions",
                                       coalesceKey: "webcamTransitions")
            }
        }
    }

    /// Cursor click ripples — one ripple per click in the event log,
    /// generated on composition load. Toggle is persisted.
    private(set) var cursorRipples: [CursorRipple] = []
    var cursorRipplesEnabled: Bool {
        didSet {
            if oldValue != cursorRipplesEnabled {
                Settings.shared.editorCursorRipplesEnabled = cursorRipplesEnabled
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.cursorRipplesEnabled, from: oldValue,
                                       actionName: "Toggle Click Ripples",
                                       coalesceKey: "cursorRipplesEnabled")
            }
        }
    }

    /// Manual "talking head" moments. User adds via "Add at playhead";
    /// each keyframe grows the webcam to fill most of the canvas then
    /// shrinks back. Persisted per-recording to `talking-head.json` in
    /// the sidecar so they survive closing + reopening the editor.
    /// Always sorted by `startTime`.
    private(set) var talkingHeadKeyframes: [TalkingHeadKeyframe] = []

    /// Peak-amplitude samples for the waveform strip behind the trim
    /// track. Computed asynchronously on editor open so it doesn't
    /// block the loading overlay.
    private(set) var waveformSamples: [Float] = []

    // MARK: - Undo / Redo

    /// Standard Cocoa `UndoManager`. Every user-driven editor mutation
    /// registers its inverse here; ⌘Z / ⌘⇧Z in `EditorView` drive it.
    let undoManager = UndoManager()

    /// Bumped whenever the undo stack changes — used to drive SwiftUI
    /// re-evaluation of `canUndo` / `canRedo` + the action-name
    /// tooltips. `UndoManager` is not `@Observable`, so reading its
    /// `canUndo` / `canRedo` directly from views never invalidates.
    /// Reading `undoStackRevision` inside a computed property below
    /// establishes the dependency; every undo registration and
    /// `performUndo` / `performRedo` increments it.
    private(set) var undoStackRevision: Int = 0

    /// SwiftUI-observable accessors that refresh whenever the stack
    /// changes. Views should prefer these over `undoManager.canUndo` /
    /// `undoManager.canRedo` directly.
    var canUndo: Bool {
        _ = undoStackRevision  // dependency
        return undoManager.canUndo
    }
    var canRedo: Bool {
        _ = undoStackRevision
        return undoManager.canRedo
    }
    var undoActionName: String {
        _ = undoStackRevision
        return undoManager.undoActionName
    }
    var redoActionName: String {
        _ = undoStackRevision
        return undoManager.redoActionName
    }

    /// Key of the last coalesceable undo registration. When the same
    /// key is touched again within `undoCoalesceInterval`, the new
    /// registration is suppressed so a slider or handle drag becomes a
    /// single undo step back to its pre-drag value (not dozens of steps).
    @ObservationIgnored private var lastUndoCoalesceKey: AnyHashable?
    @ObservationIgnored private var lastUndoCoalesceTime: Date = .distantPast
    private let undoCoalesceInterval: TimeInterval = 0.5

    /// False for a rapid repeat of `key` (a drag or slider streak) — the
    /// streak's first registration already holds the pre-streak state.
    /// Undo/redo-driven changes always register (so a rapid undo doesn't
    /// swallow the redo) and leave the streak alone.
    private func shouldRegisterUndo(coalescing key: AnyHashable) -> Bool {
        guard !undoManager.isUndoing, !undoManager.isRedoing else { return true }
        let now = Date()
        defer { lastUndoCoalesceTime = now }
        if lastUndoCoalesceKey == key,
           now.timeIntervalSince(lastUndoCoalesceTime) < undoCoalesceInterval {
            return false
        }
        lastUndoCoalesceKey = key
        return true
    }

    /// Register an inverse for a simple property assignment. `oldValue`
    /// is the pre-mutation value (usually captured via `didSet`'s
    /// implicit `oldValue`). `coalesceKey` groups rapid repeat
    /// mutations of the same logical property.
    ///
    /// Safe to call during undo / redo — `UndoManager` detects the
    /// direction and puts the inverse on the right stack.
    fileprivate func registerUndoableChange<T>(
        _ keyPath: ReferenceWritableKeyPath<EditorViewModel, T>,
        from oldValue: T,
        actionName: String,
        coalesceKey: AnyHashable
    ) {
        guard shouldRegisterUndo(coalescing: coalesceKey) else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target[keyPath: keyPath] = oldValue
        }
        undoManager.setActionName(actionName)
        undoStackRevision &+= 1
    }

    /// Register an inverse for a "snapshot" mutation — an operation that
    /// changes several pieces of state at once, or a value whose setter
    /// doesn't register its own undo. `restore` re-applies a state plus
    /// any follow-up work (applyLayout, save…); the opposite direction is
    /// re-registered each time so redo works indefinitely.
    ///
    /// With a `coalesceKey`, rapid repeats (trim-handle, pill and caption
    /// drags) collapse into one step. The coalesced path used to go
    /// through a reset of the streak key, so every tick of a drag became
    /// its own undo step.
    fileprivate func registerUndoableSnapshot<State>(
        _ actionName: String,
        coalesceKey: AnyHashable? = nil,
        capture: @escaping (EditorViewModel) -> State,
        oldState: State,
        restore: @escaping (EditorViewModel, State) -> Void
    ) {
        if let coalesceKey {
            guard shouldRegisterUndo(coalescing: coalesceKey) else { return }
        } else {
            // A discrete operation ends any running streak.
            lastUndoCoalesceKey = nil
        }
        registerSnapshotInverse(actionName, capture: capture, oldState: oldState, restore: restore)
    }

    private func registerSnapshotInverse<State>(
        _ actionName: String,
        capture: @escaping (EditorViewModel) -> State,
        oldState: State,
        restore: @escaping (EditorViewModel, State) -> Void
    ) {
        undoManager.registerUndo(withTarget: self) { target in
            let currentState = capture(target)
            restore(target, oldState)
            target.registerSnapshotInverse(actionName, capture: capture, oldState: currentState, restore: restore)
        }
        undoManager.setActionName(actionName)
        undoStackRevision &+= 1
    }

    /// Title cards baked into the export. Defaults load from Settings (or
    /// the built-in defaults on first run). Each change persists, so the
    /// next recording opens with the same title/colors/fade duration. The
    /// `enabled` flag is remembered too — if you always turn cards on,
    /// they'll stay on by default; if you turned them off last time,
    /// they stay off.
    var startCard: TitleCard {
        didSet {
            if oldValue != startCard {
                Settings.shared.editorStartCard = startCard
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.startCard, from: oldValue,
                                       actionName: "Change Start Card",
                                       coalesceKey: "startCard")
            }
        }
    }
    var endCard: TitleCard {
        didSet {
            if oldValue != endCard {
                Settings.shared.editorEndCard = endCard
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.endCard, from: oldValue,
                                       actionName: "Change End Card",
                                       coalesceKey: "endCard")
            }
        }
    }

    /// Export bitrate preset. Persisted across sessions.
    var exportQuality: ExportQuality {
        didSet {
            if oldValue != exportQuality {
                Settings.shared.exportQuality = exportQuality
                registerUndoableChange(\.exportQuality, from: oldValue,
                                       actionName: "Change Export Quality",
                                       coalesceKey: "exportQuality")
            }
        }
    }

    /// Burned-in captions for the mic track. Starts nil until the user
    /// either opens a bundle that already has a `transcription.json` or
    /// runs `generateCaptions()`.
    private(set) var transcription: TranscriptionLog?
    /// True while `generateCaptions()` is running; drives the spinner /
    /// disabled state in the inspector.
    private(set) var isTranscribing: Bool = false
    /// Surface the last transcription error to the inspector so the user
    /// can see why generation failed (permission denied, on-device
    /// model unavailable, etc).
    var transcriptionError: (any Error)?

    /// True iff the last failure was specifically "no speech detected" —
    /// the case where we might usefully retry with cloud fallback
    /// enabled. Drives visibility of the cloud-retry button in the
    /// inspector.
    var transcriptionErrorIsNoSpeech: Bool {
        guard let err = transcriptionError as? CaptionTranscriber.TranscriberError else { return false }
        if case .noSpeechDetected = err { return true }
        return false
    }
    /// Persisted styling for the caption strip. Default is enabled so a
    /// freshly-generated transcription shows immediately.
    var captionStyle: CaptionStyle {
        didSet {
            if oldValue != captionStyle {
                Settings.shared.captionStyle = captionStyle
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.captionStyle, from: oldValue,
                                       actionName: "Change Captions",
                                       coalesceKey: "captionStyle")
            }
        }
    }

    /// Keystroke-overlay chips generated from the event log at editor
    /// load. Regenerated if `keystrokeOverlayStyle.showPlainKeys`
    /// changes (the generator filters at generation time).
    private(set) var keystrokeChips: [KeystrokeChip] = []

    /// Persisted styling + enable flag for the keystroke overlay.
    /// `didSet` regenerates chips when the plain-keys filter flips,
    /// since the generator bakes that filter in.
    var keystrokeOverlayStyle: KeystrokeOverlayStyle {
        didSet {
            if oldValue != keystrokeOverlayStyle {
                Settings.shared.keystrokeOverlayStyle = keystrokeOverlayStyle
                scheduleEditStateSave()
                if oldValue.showPlainKeys != keystrokeOverlayStyle.showPlainKeys {
                    keystrokeChips = KeystrokeOverlayGenerator.generate(
                        from: project.eventLog,
                        showPlainKeys: keystrokeOverlayStyle.showPlainKeys
                    )
                }
                applyLayout()
                registerUndoableChange(\.keystrokeOverlayStyle, from: oldValue,
                                       actionName: "Change Keystrokes",
                                       coalesceKey: "keystrokeOverlayStyle")
            }
        }
    }

    /// Interpolatable cursor-position track (generated from the
    /// sidecar cursor.json at load time). `empty` for older recordings
    /// that don't have a cursor sidecar.
    private(set) var cursorTrack: CursorHighlightTrack = .empty

    /// Write a `.srt` sidecar alongside the exported MP4 when the
    /// recording has a transcription. Persisted — the user rarely
    /// wants to flip this per-export, but we expose the toggle for
    /// the rare "ship the MP4 without subs" case.
    var exportSRTSidecar: Bool {
        didSet {
            if oldValue != exportSRTSidecar {
                Settings.shared.exportSRTSidecar = exportSRTSidecar
            }
        }
    }

    /// Mic noise-reduction preference. When `enabled` flips on, we
    /// run `MicCleaner` offline to produce `mic_cleaned.caf` in the
    /// sidecar (only if the file doesn't already exist at the chosen
    /// strength — we stamp the strength into the file's existence check
    /// by regenerating on strength change), then rebuild the
    /// composition so both preview + export use the cleaned track.
    var noiseReductionStyle: NoiseReductionStyle {
        didSet {
            if oldValue != noiseReductionStyle {
                Settings.shared.noiseReductionStyle = noiseReductionStyle
                scheduleEditStateSave()
                handleNoiseReductionChange(previous: oldValue)
            }
        }
    }

    /// True while `MicCleaner` is generating `mic_cleaned.caf`. Drives
    /// a progress indicator in the inspector — the cleaner runs on a
    /// detached task so UI stays responsive.
    private(set) var isCleaningMic: Bool = false

    /// Webcam background style (off / blur / color). Persisted so the
    /// user's chosen mode + blur radius + colour follow them across
    /// recordings. `didSet` re-applies the compositor state so the
    /// preview updates live.
    var webcamBackgroundStyle: WebcamBackgroundStyle {
        didSet {
            if oldValue != webcamBackgroundStyle {
                Settings.shared.webcamBackgroundStyle = webcamBackgroundStyle
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.webcamBackgroundStyle, from: oldValue,
                                       actionName: "Change Webcam Background",
                                       coalesceKey: "webcamBackgroundStyle")
            }
        }
    }

    /// User-facing smart-zoom generator knobs (scale, hold, cluster
    /// sensitivity). Persisted so reopens remember the user's feel.
    /// `didSet` doesn't auto-regenerate — the user explicitly applies
    /// via the "Regenerate from clicks" button so they can preview
    /// slider movement before committing.
    var zoomTuning: ZoomTuning {
        didSet {
            if oldValue != zoomTuning {
                Settings.shared.zoomTuning = zoomTuning
                scheduleEditStateSave()
            }
        }
    }

    /// Persisted styling + enable flag for the cursor halo overlay.
    /// Purely visual; doesn't affect the raw recording.
    var cursorHighlightStyle: CursorHighlightStyle {
        didSet {
            if oldValue != cursorHighlightStyle {
                Settings.shared.cursorHighlightStyle = cursorHighlightStyle
                scheduleEditStateSave()
                applyLayout()
                registerUndoableChange(\.cursorHighlightStyle, from: oldValue,
                                       actionName: "Change Cursor Halo",
                                       coalesceKey: "cursorHighlightStyle")
            }
        }
    }

    /// Per-lane visibility overrides. Purely a UI preference — doesn't
    /// affect the baked export. Persisted so the user's chosen layout
    /// follows them across recordings.
    var timelineLanePrefs: TimelineLanePrefs {
        didSet {
            if oldValue != timelineLanePrefs {
                Settings.shared.timelineLanePrefs = timelineLanePrefs
            }
        }
    }

    /// Effective visibility of a secondary timeline lane — combines
    /// the user's stored override with a "has relevant content" rule.
    func isTimelineLaneVisible(_ lane: TimelineLane) -> Bool {
        switch lane {
        case .zoom:
            return resolve(timelineLanePrefs.zoom, auto: !zoomKeyframes.isEmpty)
        case .talkingHead:
            return resolve(timelineLanePrefs.talkingHead, auto: !talkingHeadKeyframes.isEmpty)
        case .soundboard:
            return resolve(timelineLanePrefs.soundboard, auto: !(project.soundboardLog?.events.isEmpty ?? true))
        case .captions:
            return resolve(timelineLanePrefs.captions, auto: !(transcription?.lines.isEmpty ?? true))
        case .keystrokes:
            return resolve(timelineLanePrefs.keystrokes, auto: keystrokeOverlayStyle.enabled)
        }
    }

    private func resolve(_ override: LaneVisibility, auto: Bool) -> Bool {
        switch override {
        case .auto: return auto
        case .show: return true
        case .hide: return false
        }
    }

    /// Per-track audio volumes (mic / system / soundboard). Applied to
    /// both live preview (via `AVPlayerItem.audioMix`) and export (via
    /// `AVAssetReaderAudioMixOutput.audioMix`). Persisted.
    var audioMixVolumes: AudioMixBuilder.Volumes {
        didSet {
            if oldValue != audioMixVolumes {
                Settings.shared.editorAudioMixVolumes = audioMixVolumes
                scheduleEditStateSave()
                rebuildAndApplyAudioMix()
                registerUndoableChange(\.audioMixVolumes, from: oldValue,
                                       actionName: "Change Audio Mix",
                                       coalesceKey: "audioMixVolumes")
            }
        }
    }

    // Retained across the composition's lifetime — needed to rebuild the
    // mix when volumes change without having to re-run EditorComposition.
    private var compositionResult: EditorComposition.Result?

    /// Fraction of the min output dimension — useful for slider range.
    var diameterMax: CGFloat { min(outputSize.width, outputSize.height) * 0.7 }
    var diameterMin: CGFloat { min(outputSize.width, outputSize.height) * 0.08 }

    /// Current webcam bottom-left origin in output-pixel space,
    /// before any talking-head interpolation. Used by the editor's
    /// drag overlay to know where to put the hit-test rect.
    var webcamBaseOrigin: CGPoint {
        if let custom = webcamCustomOrigin { return custom }
        let d = webcamDiameter
        let i = webcamInset
        switch webcamPosition {
        case .bottomRight: return CGPoint(x: outputSize.width - d - i, y: i)
        case .bottomLeft:  return CGPoint(x: i, y: i)
        case .topRight:    return CGPoint(x: outputSize.width - d - i, y: outputSize.height - d - i)
        case .topLeft:     return CGPoint(x: i, y: outputSize.height - d - i)
        case .hidden:      return .zero
        }
    }

    init(project: RecordingProject) {
        self.project = project
        self.outputSize = CGSize(
            width: project.metadata.compositedPixelSize.width,
            height: project.metadata.compositedPixelSize.height
        )
        self.backingScale = CGFloat(project.metadata.backingScale ?? 2.0)

        // A previous editor session's layout wins over capture-time
        // metadata. Trim + cuts are applied in `loadComposition`, once
        // the duration is known to clamp against.
        let saved = EditState.load(from: project.bundle.editStateURL)
        self.savedEditState = saved
        self.hasSoundboardTrack = project.soundboardLog != nil
            || FileManager.default.fileExists(atPath: project.bundle.soundboardAudioURL.path)
        self.loggedClickCount = project.eventLog?.events.filter { $0.type == "click" }.count ?? 0
        let captured = project.metadata.webcamLayout
        let scale = CGFloat(project.metadata.backingScale ?? 2.0)
        self.webcamPosition = saved.flatMap { WebcamPosition(rawValue: $0.webcamPosition) }
            ?? WebcamPosition(rawValue: captured.position) ?? .bottomRight
        self.webcamCustomOrigin = saved?.webcamCustomOrigin.map { CGPoint(x: $0.x, y: $0.y) }
        self.webcamShape = saved.flatMap { WebcamShape(rawValue: $0.webcamShape) }
            ?? WebcamShape(rawValue: captured.shape) ?? .circle
        self.webcamDiameter = saved.map { CGFloat($0.webcamDiameter) } ?? CGFloat(captured.diameterPoints) * scale
        self.webcamInset    = saved.map { CGFloat($0.webcamInset) }    ?? CGFloat(captured.insetPoints) * scale

        // The recording's own look if it's been edited before; otherwise
        // the last-used values from Settings, then the built-in defaults.
        self.zoomEnabled            = saved?.zoomEnabled ?? Settings.shared.editorSmartZoomEnabled
        self.cursorRipplesEnabled   = saved?.cursorRipplesEnabled ?? Settings.shared.editorCursorRipplesEnabled
        self.webcamTransitions      = saved?.webcamTransitions ?? Settings.shared.editorWebcamTransitions ?? .default
        self.startCard              = saved?.startCard ?? Settings.shared.editorStartCard ?? .defaultStart
        self.endCard                = saved?.endCard ?? Settings.shared.editorEndCard ?? .defaultEnd
        self.exportQuality          = Settings.shared.exportQuality
        self.audioMixVolumes        = saved?.audioMixVolumes ?? Settings.shared.editorAudioMixVolumes ?? .unity
        self.captionStyle           = saved?.captionStyle ?? Settings.shared.captionStyle ?? .default
        self.keystrokeOverlayStyle  = saved?.keystrokeOverlayStyle ?? Settings.shared.keystrokeOverlayStyle ?? .default
        self.cursorHighlightStyle   = saved?.cursorHighlightStyle ?? Settings.shared.cursorHighlightStyle ?? .default
        self.zoomTuning             = saved?.zoomTuning ?? Settings.shared.zoomTuning ?? .default
        self.webcamBackgroundStyle  = saved?.webcamBackgroundStyle ?? Settings.shared.webcamBackgroundStyle ?? .default
        self.noiseReductionStyle    = saved?.noiseReductionStyle ?? Settings.shared.noiseReductionStyle ?? .default
        self.exportSRTSidecar       = Settings.shared.exportSRTSidecar
        self.timelineLanePrefs      = Settings.shared.timelineLanePrefs ?? .default
        self.transcription          = project.transcription
        // Build the interpolatable cursor track up-front so the
        // compositor can do a single binary search per frame instead
        // of traversing raw samples each time.
        self.cursorTrack = CursorHighlightTrack.make(
            from: project.cursorLog,
            metadata: project.metadata
        )

        // Load any previously-persisted talking-head moments. If no log
        // exists (fresh recording or pre-persistence bundle), we start
        // empty and the first mutation will create the file.
        if let log = project.talkingHeadLog {
            self.talkingHeadKeyframes = log.keyframes.sorted {
                CMTimeCompare($0.startTime, $1.startTime) < 0
            }
        }

        self.player = AVPlayer()

        // No global state to prime any more — each composition's own
        // `State` instance is created in `EditorComposition.build`
        // (see `compositionResult?.compositorState`). `applyLayout()`
        // writes to it after the composition loads.

        attachPlayerObservers()

        Task { [weak self] in
            await self?.loadComposition()
        }
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        for token in cutBoundaryTokens {
            player.removeTimeObserver(token)
        }
        rateObservation?.invalidate()
        // Pause before tearing down to avoid dangling compositor requests.
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Noise reduction

    /// URL of the cleaned mic file to feed into the composition, or
    /// nil to pass through the raw `mic.m4a`. Nil when noise reduction
    /// is disabled, or enabled-but-file-not-yet-generated (async
    /// generation is in flight).
    private func effectiveMicOverrideURL() -> URL? {
        guard noiseReductionStyle.enabled else { return nil }
        let url = project.bundle.cleanedMicAudioURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Called from `noiseReductionStyle.didSet` when the user toggles
    /// or switches strength. Decides whether we need to regenerate the
    /// cleaned file + rebuild the composition.
    private func handleNoiseReductionChange(previous: NoiseReductionStyle) {
        let cleanedURL = project.bundle.cleanedMicAudioURL
        let needsRegen: Bool = {
            // Strength change invalidates the existing cleaned file —
            // we don't stamp the strength into the file name, so we
            // regenerate whenever the recipe shifts.
            if noiseReductionStyle.enabled,
               previous.strength != noiseReductionStyle.strength {
                return true
            }
            // First time enabling on this recording — generate if
            // missing.
            if noiseReductionStyle.enabled,
               !FileManager.default.fileExists(atPath: cleanedURL.path) {
                return true
            }
            return false
        }()

        if needsRegen {
            generateCleanedMic()
        } else {
            // Toggle without regen — just swap the composition to
            // point at the (possibly now-inactive) cleaned file.
            Task { await self.rebuildComposition() }
        }
    }

    private func generateCleanedMic() {
        guard !isCleaningMic else { return }
        isCleaningMic = true
        let inputURL = project.bundle.micAudioURL
        let outputURL = project.bundle.cleanedMicAudioURL
        let settings = noiseReductionStyle.strength.cleanerSettings
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try MicCleaner.clean(
                        inputURL: inputURL,
                        outputURL: outputURL,
                        settings: settings
                    )
                }.value
                PepperDebug.log("NR: cleaned mic written to \(outputURL.lastPathComponent)")
            } catch {
                PepperDebug.log("NR: cleaner failed: \(error.localizedDescription)")
            }
            await MainActor.run {
                guard let self else { return }
                self.isCleaningMic = false
                Task { await self.rebuildComposition() }
            }
        }
    }

    // MARK: - Composition loading

    private func loadComposition() async {
        do {
            let result = try await EditorComposition.build(
                bundle: project.bundle,
                metadata: project.metadata,
                micOverride: effectiveMicOverrideURL()
            )
            self.compositionResult = result
            let item = EditorComposition.makePlayerItem(from: result)
            // Apply initial audio mix (unity or last-used volumes).
            item.audioMix = AudioMixBuilder.build(
                composition: result.composition,
                micTrackID: result.micTrackID,
                systemTrackID: result.systemTrackID,
                soundboardTrackID: result.soundboardTrackID,
                volumes: audioMixVolumes
            )
            player.replaceCurrentItem(with: item)
            observedCutRanges = nil   // new item — reinstall on the next applyLayout
            self.duration = result.duration
            self.trimStart = .zero
            self.trimEnd = result.duration
            // Generate smart-zoom keyframes from the click log now that we
            // know the composition's duration. Push them through to the
            // shared compositor state via applyLayout.
            // Zoom keyframes: prefer the persisted log if the user has
            // edited them in a previous session. Otherwise auto-generate
            // from the click log and persist the result as a starting
            // point — future sessions will load that instead of re-
            // running the generator (so user edits survive).
            if let zoom = project.zoomLog {
                self.zoomKeyframes = zoom.keyframes
            } else {
                self.zoomKeyframes = ZoomKeyframeGenerator.generate(
                    from: project.eventLog,
                    metadata: project.metadata,
                    duration: result.duration
                )
                scheduleSave(.zoom)
            }
            self.cursorRipples = CursorRippleGenerator.generate(
                from: project.eventLog,
                metadata: project.metadata
            )
            self.keystrokeChips = KeystrokeOverlayGenerator.generate(
                from: project.eventLog,
                showPlainKeys: self.keystrokeOverlayStyle.showPlainKeys
            )

            // Restore a previous session's trim + cuts; only a recording
            // that's never been edited gets auto-trimmed. Either way this
            // runs before flipping isLoading so the editor window appears
            // with the trim already applied (no "full → trimmed" snap).
            if let saved = savedEditState {
                let dur = result.duration
                let start = clamp(CMTime(seconds: saved.trimStart, preferredTimescale: 600), lower: .zero, upper: dur)
                let end = clamp(CMTime(seconds: saved.trimEnd, preferredTimescale: 600), lower: start, upper: dur)
                if CMTimeCompare(end, start) > 0 {
                    self.trimStart = start
                    self.trimEnd = end
                }
                let restoredCuts = saved.cuts.map {
                    CMTimeRange(
                        start: CMTime(seconds: $0.start, preferredTimescale: 600),
                        end: CMTime(seconds: $0.end, preferredTimescale: 600)
                    )
                }
                // TrimMap re-normalises (sorted, merged, inside the trim).
                self.cutRanges = TrimMap(outerTrim: trimRange, cuts: restoredCuts).cuts
                PepperDebug.log("EDITOR: restored edit state trim \(CMTimeGetSeconds(self.trimStart))..\(CMTimeGetSeconds(self.trimEnd))s, \(self.cutRanges.count) cut(s)")
            } else if let detected = await SilenceAnalyzer.detectContentRange(
                audioURL: project.bundle.micAudioURL,
                duration: result.duration
            ) {
                self.trimStart = detected.start
                self.trimEnd   = detected.end
                PepperDebug.log("EDITOR: auto-trim \(CMTimeGetSeconds(detected.start))..\(CMTimeGetSeconds(detected.end))s")
            }

            applyLayout()
            isLoading = false
            PepperDebug.log("EDITOR: zoom keyframes generated: \(self.zoomKeyframes.count)")

            // Kick off the waveform sampler in the background. The
            // editor is already usable — the strip just pops in when
            // ready. Typical 60s recording samples in well under 100ms.
            Task { [weak self] in
                guard let self else { return }
                let samples = await WaveformSampler.sample(audioURL: self.project.bundle.micAudioURL)
                await MainActor.run { self.waveformSamples = samples }
            }
        } catch {
            loadError = error
            isLoading = false
            PepperDebug.log("EDITOR: composition load failed: \(error)")
        }
    }

    /// Swap in a fresh composition — noise reduction switched the mic
    /// source — without touching any edit. `loadComposition` used to be
    /// re-run for this, which reset the trim, re-ran auto-trim and
    /// reloaded zoom keyframes from the stale snapshot taken at open.
    /// Each composition owns a new compositor `State`, so re-apply the
    /// layout, then restore the playhead and play state.
    private func rebuildComposition() async {
        guard compositionResult != nil else { return }
        let resumeAt = currentTime
        let wasPlaying = isPlaying
        do {
            let result = try await EditorComposition.build(
                bundle: project.bundle,
                metadata: project.metadata,
                micOverride: effectiveMicOverrideURL()
            )
            self.compositionResult = result
            let item = EditorComposition.makePlayerItem(from: result)
            item.audioMix = AudioMixBuilder.build(
                composition: result.composition,
                micTrackID: result.micTrackID,
                systemTrackID: result.systemTrackID,
                soundboardTrackID: result.soundboardTrackID,
                volumes: audioMixVolumes
            )
            player.replaceCurrentItem(with: item)
            observedCutRanges = nil   // new item — reinstall on the next applyLayout
            applyLayout()
            await player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
        } catch {
            PepperDebug.log("EDITOR: composition rebuild failed: \(error)")
        }
    }

    // MARK: - Edit-state persistence

    /// Sidecar files the editor writes, each through `sidecars` (debounced).
    private enum SidecarFile: Hashable {
        case editState, zoom, talkingHead, transcription
    }

    private func scheduleSave(_ file: SidecarFile) {
        sidecars.schedule(url(for: file)) { try self.contents(of: file) }
    }

    private func saveNow(_ file: SidecarFile) {
        sidecars.writeNow(url(for: file)) { try self.contents(of: file) }
    }

    /// Write anything pending immediately. Called when the editor window
    /// closes and when the app quits.
    func flushPendingSaves() {
        sidecars.flush()
    }

    /// Skipped during the initial load — only user edits (and undo/redo
    /// of them) are persisted.
    private func scheduleEditStateSave() {
        guard !isLoading else { return }
        scheduleSave(.editState)
    }

    private func url(for file: SidecarFile) -> URL {
        switch file {
        case .editState:     return project.bundle.editStateURL
        case .zoom:          return project.bundle.zoomURL
        case .talkingHead:   return project.bundle.talkingHeadURL
        case .transcription: return project.bundle.transcriptionURL
        }
    }

    /// What `file` should contain right now; nil removes it.
    private func contents(of file: SidecarFile) throws -> Data? {
        switch file {
        case .editState:
            return try SidecarStore.json(currentEditState())
        case .zoom:
            // An empty array is written, not the file removed: a missing
            // zoom.json means "never edited" and triggers regeneration on
            // the next open, which resurrected every zoom the user deleted.
            return try SidecarStore.json(ZoomLog(version: 1, keyframes: zoomKeyframes))
        case .talkingHead:
            // No moments → no file, rather than an empty-array file.
            guard !talkingHeadKeyframes.isEmpty else { return nil }
            return try SidecarStore.json(TalkingHeadLog(version: 1, keyframes: talkingHeadKeyframes))
        case .transcription:
            guard let transcription else { return nil }
            return try SidecarStore.json(transcription, dates: .iso8601)
        }
    }

    private func currentEditState() -> EditState {
        EditState(
            trimStart: CMTimeGetSeconds(trimStart),
            trimEnd: CMTimeGetSeconds(trimEnd),
            cuts: cutRanges.map {
                EditState.Cut(start: CMTimeGetSeconds($0.start), end: CMTimeGetSeconds($0.end))
            },
            webcamPosition: webcamPosition.rawValue,
            webcamShape: webcamShape.rawValue,
            webcamDiameter: Double(webcamDiameter),
            webcamInset: Double(webcamInset),
            webcamCustomOrigin: webcamCustomOrigin.map {
                EditState.Point(x: Double($0.x), y: Double($0.y))
            },
            webcamTransitions: webcamTransitions,
            startCard: startCard,
            endCard: endCard,
            zoomEnabled: zoomEnabled,
            cursorRipplesEnabled: cursorRipplesEnabled,
            audioMixVolumes: audioMixVolumes,
            captionStyle: captionStyle,
            keystrokeOverlayStyle: keystrokeOverlayStyle,
            cursorHighlightStyle: cursorHighlightStyle,
            zoomTuning: zoomTuning,
            webcamBackgroundStyle: webcamBackgroundStyle,
            noiseReductionStyle: noiseReductionStyle
        )
    }

    /// Run undo + refresh observation state. Callers (buttons + ⌘Z
    /// handler) should use this instead of calling `undoManager.undo()`
    /// directly — it guarantees `canUndo` / `canRedo` / action names
    /// re-read correctly afterwards.
    func performUndo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
        undoStackRevision &+= 1
        // A drag right after an undo/redo starts a fresh undo step.
        lastUndoCoalesceKey = nil
    }

    func performRedo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
        undoStackRevision &+= 1
        // A drag right after an undo/redo starts a fresh undo step.
        lastUndoCoalesceKey = nil
    }

    private func attachPlayerObservers() {
        // Periodic time observer — drives the scrubber + trim-end enforcement.
        // ~30 updates/sec is plenty for a timeline UI and is cheap.
        let interval = CMTime(value: 1, timescale: 30)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = time
            if self.isPlaying,
               self.trimEnd.isValid,
               CMTimeCompare(time, self.trimEnd) >= 0 {
                // Stop at the trim-out point.
                self.player.pause()
                // Snap exactly to trimEnd so the UI reads cleanly.
                self.player.seek(to: self.trimEnd, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            // Fallback for interior cuts: if the playhead slipped into
            // a cut (e.g. a system hiccup delayed the boundary observer
            // past the cut.start), jump out. The boundary observer below
            // fires first in the common case, so this rarely runs.
            if let cut = self.cutRanges.first(where: {
                CMTimeCompare(time, $0.start) >= 0 && CMTimeCompare(time, $0.end) < 0
            }) {
                self.player.seek(to: cut.end, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }

        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.rate > 0
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    /// Wire up per-cut boundary observers so playback skips past each
    /// interior cut in real-time. Called whenever `cutRanges` changes
    /// (via `applyLayout`). Each observer fires exactly when the
    /// playhead crosses a cut-start and immediately seeks to the
    /// cut-end. Without this the user would see cut content play back
    /// during preview even though it won't be in the exported file.
    private func refreshCutBoundaryObservers() {
        for token in cutBoundaryTokens {
            player.removeTimeObserver(token)
        }
        cutBoundaryTokens.removeAll(keepingCapacity: true)
        for cut in cutRanges {
            let start = cut.start
            let end = cut.end
            let token = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: start)],
                queue: .main
            ) { [weak self] in
                guard let self else { return }
                // Only seek forward — if the user is scrubbing backward
                // past the cut, the seek clamp in `seek(to:)` has
                // already handled it.
                guard CMTimeCompare(self.player.currentTime(), end) < 0 else { return }
                self.player.seek(to: end, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            cutBoundaryTokens.append(token)
        }
    }

    /// If `time` falls inside an interior cut, return the nearest kept
    /// boundary (snap to `cut.end` for forward motion; caller can still
    /// force backward via `preferBackward`). Otherwise return `time`
    /// unchanged. Used by `seek(to:)` + scrubber drags.
    private func snapOutOfCut(_ time: CMTime, preferBackward: Bool = false) -> CMTime {
        for cut in cutRanges {
            if CMTimeCompare(time, cut.start) > 0 && CMTimeCompare(time, cut.end) < 0 {
                return preferBackward ? cut.start : cut.end
            }
        }
        return time
    }

    // MARK: - Playback controls

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            // If we're at or past trimEnd, or before trimStart, jump to trimStart first.
            if CMTimeCompare(currentTime, trimEnd) >= 0 || CMTimeCompare(currentTime, trimStart) < 0 {
                player.seek(to: trimStart, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
        }
    }

    /// Seek to an arbitrary composition time. Clamped to [0, duration]
    /// and snapped out of any interior cut so the user never parks the
    /// playhead inside a region that won't exist in the exported file.
    func seek(to time: CMTime) {
        let clamped = clamp(time, lower: .zero, upper: duration)
        let snapped = snapOutOfCut(clamped)
        player.seek(to: snapped, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Keyboard navigation

    /// One-frame step at 60fps — smallest resolution the compositor
    /// renders. Used by arrow-key nudges.
    func stepFrame(forward: Bool) {
        let frame = CMTime(value: 1, timescale: 60)
        seek(to: forward ? CMTimeAdd(currentTime, frame) : CMTimeSubtract(currentTime, frame))
    }

    /// Mid-sized jump (1 second). Used by shift-arrow.
    func stepSecond(forward: Bool) {
        let step = CMTime(value: 1, timescale: 1)
        seek(to: forward ? CMTimeAdd(currentTime, step) : CMTimeSubtract(currentTime, step))
    }

    /// Larger jump (5 seconds). Used by J / L.
    func stepFiveSeconds(forward: Bool) {
        let step = CMTime(value: 5, timescale: 1)
        seek(to: forward ? CMTimeAdd(currentTime, step) : CMTimeSubtract(currentTime, step))
    }

    /// K — pauses regardless of current state (spacebar toggles; K is
    /// the "definitely pause now" shortcut matching pro editor apps).
    func pausePlayback() {
        player.pause()
    }

    // MARK: - Trim controls

    /// Set the in-point. Clamped so there's at least 0.25s of trim duration.
    func setTrimStart(_ time: CMTime) {
        let minGap = CMTime(value: 250, timescale: 1000)
        let upperBound = CMTimeSubtract(trimEnd, minGap)
        let clamped = clamp(time, lower: .zero, upper: upperBound)
        guard clamped != trimStart else { return }
        let old = trimStart
        trimStart = clamped
        applyLayout()  // outputRange shifted — re-prime cards/fades
        // trimStart is a plain var (no `didSet`), so the keypath-based
        // helper can't rely on didSet to register the redo. Use the
        // snapshot form, which explicitly re-registers inside its undo
        // closure.
        registerUndoableSnapshot(
            "Change Trim In",
            coalesceKey: "trimStart",
            capture: { $0.trimStart },
            oldState: old
        ) { vm, state in
            vm.trimStart = state
            vm.applyLayout()
        }
    }

    /// Set the out-point. Clamped so there's at least 0.25s of trim duration.
    func setTrimEnd(_ time: CMTime) {
        let minGap = CMTime(value: 250, timescale: 1000)
        let lowerBound = CMTimeAdd(trimStart, minGap)
        let clamped = clamp(time, lower: lowerBound, upper: duration)
        guard clamped != trimEnd else { return }
        let old = trimEnd
        trimEnd = clamped
        applyLayout()
        registerUndoableSnapshot(
            "Change Trim Out",
            coalesceKey: "trimEnd",
            capture: { $0.trimEnd },
            oldState: old
        ) { vm, state in
            vm.trimEnd = state
            vm.applyLayout()
        }
    }

    func setTrimStartToCurrent() { setTrimStart(currentTime) }
    func setTrimEndToCurrent()   { setTrimEnd(currentTime) }

    func clearTrim() {
        let oldStart = trimStart
        let oldEnd = trimEnd
        trimStart = .zero
        trimEnd = duration
        applyLayout()
        registerUndoableSnapshot(
            "Reset Trim",
            capture: { vm in (vm.trimStart, vm.trimEnd) },
            oldState: (oldStart, oldEnd)
        ) { vm, state in
            vm.trimStart = state.0
            vm.trimEnd = state.1
            vm.applyLayout()
        }
    }

    // MARK: - Interior cuts (ripple delete)

    /// Smallest cut we're willing to place. Below this it's almost
    /// certainly a misclick, and it introduces jitter in the exported
    /// file without actually saving anything.
    private static let minCutDuration = CMTime(value: 100, timescale: 1000)  // 0.1s

    /// Excise `range` (in source-composition time) from the output.
    /// Ranges overlapping existing cuts are merged by `TrimMap`;
    /// ranges outside the outer trim are clamped / dropped. No-op if
    /// the clamped range is shorter than `minCutDuration`.
    func insertCut(_ range: CMTimeRange) {
        // Clamp to outer trim before the min-duration check so a cut
        // that extends past trimEnd still counts as long as the clipped
        // portion is long enough to be meaningful.
        let clampedStart = clamp(range.start, lower: trimStart, upper: trimEnd)
        let clampedEnd   = clamp(range.end,   lower: trimStart, upper: trimEnd)
        guard CMTimeCompare(clampedEnd, clampedStart) > 0 else { return }
        let clamped = CMTimeRange(start: clampedStart, end: clampedEnd)
        guard CMTimeCompare(clamped.duration, Self.minCutDuration) >= 0 else { return }
        let old = cutRanges
        // Round-trip through TrimMap to merge + sort with any existing.
        let merged = TrimMap(outerTrim: trimRange, cuts: old + [clamped]).cuts
        guard merged != old else { return }
        cutRanges = merged
        applyLayout()
        registerUndoableSnapshot(
            "Cut Section",
            capture: { $0.cutRanges },
            oldState: old
        ) { vm, state in
            vm.cutRanges = state
            vm.applyLayout()
        }
    }

    /// Remove the cut at `index` (no-op if out of range). Restores the
    /// source region to the output timeline.
    func removeCut(at index: Int) {
        guard cutRanges.indices.contains(index) else { return }
        let old = cutRanges
        var next = cutRanges
        next.remove(at: index)
        cutRanges = next
        applyLayout()
        registerUndoableSnapshot(
            "Restore Cut",
            capture: { $0.cutRanges },
            oldState: old
        ) { vm, state in
            vm.cutRanges = state
            vm.applyLayout()
        }
    }

    /// Anchor a range selection at the current playhead. Subsequent
    /// scrubbing extends the selection to that new playhead position.
    func markSelectionStart() {
        selectionStart = currentTime
    }

    /// Drop the in-progress selection without cutting.
    func clearSelection() {
        selectionStart = nil
    }

    /// If a selection is active, convert it into a cut and clear the
    /// selection anchor. No-op if there's no active selection.
    func cutSelection() {
        guard let range = selectionRange else { return }
        insertCut(range)
        selectionStart = nil
    }

    /// Wipe all interior cuts (keeps outer trim intact).
    func clearCuts() {
        guard !cutRanges.isEmpty else { return }
        let old = cutRanges
        cutRanges = []
        applyLayout()
        registerUndoableSnapshot(
            "Clear Cuts",
            capture: { $0.cutRanges },
            oldState: old
        ) { vm, state in
            vm.cutRanges = state
            vm.applyLayout()
        }
    }

    /// Visible state for the auto-cut button — prevents double-clicks
    /// while detection is in flight and drives a spinner in the UI.
    private(set) var isAutoCutting: Bool = false

    /// Published hint: how many cuts the last auto-cut run inserted.
    /// Nil unless an auto-cut run completed since the editor loaded.
    /// Cleared when the user manually mutates cuts.
    private(set) var lastAutoCutCount: Int?

    /// Scan the mic track for interior silences ≥ ~0.8s and insert them
    /// all as a single undoable batch. Existing cuts are preserved —
    /// silences are merged into the existing list via `TrimMap`'s
    /// normaliser, so re-running is idempotent.
    func autoCutSilences() {
        guard !isAutoCutting else { return }
        isAutoCutting = true
        let audioURL = project.bundle.micAudioURL
        let dur = duration
        let outerTrim = trimRange
        Task { [weak self] in
            let scan = await SilenceAnalyzer.scan(audioURL: audioURL, duration: dur)
            await MainActor.run {
                guard let self else { return }
                defer { self.isAutoCutting = false }
                guard let scan else {
                    self.lastAutoCutCount = 0
                    return
                }
                // Only consider silences strictly inside the user's
                // current outer trim — detections outside are either
                // already covered by the outer trim or irrelevant.
                let candidates = scan.interiorSilences.filter { sil in
                    CMTimeCompare(sil.start, outerTrim.start) >= 0 &&
                    CMTimeCompare(sil.end,   outerTrim.end)   <= 0
                }
                // Merge with existing cuts via the TrimMap normaliser
                // (sorts, clamps, merges overlaps). Skip the operation
                // if nothing new would be added.
                let existing = self.cutRanges
                let merged = TrimMap(outerTrim: outerTrim, cuts: existing + candidates).cuts
                guard merged != existing else {
                    self.lastAutoCutCount = 0
                    return
                }
                let old = existing
                self.cutRanges = merged
                self.applyLayout()
                self.lastAutoCutCount = merged.count - existing.count
                self.registerUndoableSnapshot(
                    "Auto-cut Silences",
                    capture: { $0.cutRanges },
                    oldState: old
                ) { vm, state in
                    vm.cutRanges = state
                    vm.applyLayout()
                }
                PepperDebug.log("AUTOCUT: inserted \(merged.count - existing.count) silence cuts (\(candidates.count) candidates, \(existing.count) pre-existing)")
            }
        }
    }

    /// Re-run silence detection on the mic track and apply the detected
    /// trim. Useful if the user hit "Reset" and now wants the auto-trim
    /// back, or just wants to re-compute after moving files around.
    func autoTrimSilence() {
        let audioURL = project.bundle.micAudioURL
        let dur = duration
        Task { [weak self] in
            guard let detected = await SilenceAnalyzer.detectContentRange(
                audioURL: audioURL,
                duration: dur
            ) else { return }
            await MainActor.run {
                guard let self else { return }
                let oldStart = self.trimStart
                let oldEnd = self.trimEnd
                self.trimStart = detected.start
                self.trimEnd   = detected.end
                self.applyLayout()
                self.registerUndoableSnapshot(
                    "Auto-Trim Silence",
                    capture: { vm in (vm.trimStart, vm.trimEnd) },
                    oldState: (oldStart, oldEnd)
                ) { vm, state in
                    vm.trimStart = state.0
                    vm.trimEnd = state.1
                    vm.applyLayout()
                }
            }
        }
    }

    // MARK: - Captions

    /// Transcribe the mic track on-device via `CaptionTranscriber`,
    /// persist to `transcription.json`, and push into the compositor.
    /// Called by the inspector's "Generate captions" button. Runs async
    /// and can take a while — `isTranscribing` drives the spinner; a
    /// failure populates `transcriptionError` for the UI to surface.
    /// Kick off captions generation. `allowCloudFallback` lets the
    /// transcriber drop the `requiresOnDeviceRecognition` flag as a
    /// last resort — macOS 26 has been observed to return empty
    /// placeholder results from the on-device URL-request path even
    /// when Dictation works locally. Cloud mode sends audio to Apple
    /// for that single request only; the user opts in via the UI.
    func generateCaptions(allowCloudFallback: Bool = false) {
        guard !isTranscribing else { return }
        isTranscribing = true
        transcriptionError = nil
        let audioURL = project.bundle.micAudioURL
        Task { [weak self] in
            do {
                let log = try await CaptionTranscriber.transcribe(
                    audioURL: audioURL,
                    allowCloudFallback: allowCloudFallback
                )
                await MainActor.run {
                    guard let self else { return }
                    self.transcription = log
                    self.isTranscribing = false
                    self.saveNow(.transcription)
                    self.applyLayout()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isTranscribing = false
                    self.transcriptionError = error
                    PepperDebug.log("CAPTIONS: generate failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Remove the persisted transcription + clear the in-memory copy.
    /// Used by the inspector's "Clear" button.
    func clearCaptions() {
        transcription = nil
        try? FileManager.default.removeItem(at: project.bundle.transcriptionURL)
        applyLayout()
    }

    // MARK: - Caption line editing

    /// Replace the text of a single caption line. Writes the file back
    /// and registers an undo step keyed on the line id so multiple
    /// keystrokes within the coalesce window collapse into one entry
    /// (feels like a normal text-edit undo instead of one-per-keystroke).
    func updateCaptionLineText(id: UUID, to newText: String) {
        guard var log = transcription,
              let idx = log.lines.firstIndex(where: { $0.id == id }) else { return }
        let oldLine = log.lines[idx]
        guard oldLine.text != newText else { return }
        log.lines[idx].text = newText
        transcription = log
        persistTranscription()
        applyLayout()
        let capturedID = id
        registerUndoableSnapshot(
            "Edit Caption",
            coalesceKey: "caption-text-\(capturedID.uuidString)",
            capture: { vm -> String in
                vm.transcription?.lines.first(where: { $0.id == capturedID })?.text ?? ""
            },
            oldState: oldLine.text
        ) { vm, state in
            guard var log = vm.transcription,
                  let i = log.lines.firstIndex(where: { $0.id == capturedID }) else { return }
            log.lines[i].text = state
            vm.transcription = log
            vm.persistTranscription()
            vm.applyLayout()
        }
    }

    /// Adjust the start/end seconds of a caption line. Both values are
    /// clamped so start < end with a minimum 100ms length (anything
    /// shorter flashes too briefly to read).
    func updateCaptionLineTiming(id: UUID, start: TimeInterval, end: TimeInterval) {
        guard var log = transcription,
              let idx = log.lines.firstIndex(where: { $0.id == id }) else { return }
        let minLen: TimeInterval = 0.1
        let clampedStart = max(0, start)
        let clampedEnd = max(clampedStart + minLen, end)
        let oldLine = log.lines[idx]
        guard oldLine.startSeconds != clampedStart || oldLine.endSeconds != clampedEnd else { return }
        log.lines[idx].startSeconds = clampedStart
        log.lines[idx].endSeconds = clampedEnd
        transcription = log
        persistTranscription()
        applyLayout()
        let capturedID = id
        let oldPair = (oldLine.startSeconds, oldLine.endSeconds)
        registerUndoableSnapshot(
            "Adjust Caption Timing",
            coalesceKey: "caption-timing-\(capturedID.uuidString)",
            capture: { vm -> (TimeInterval, TimeInterval) in
                if let l = vm.transcription?.lines.first(where: { $0.id == capturedID }) {
                    return (l.startSeconds, l.endSeconds)
                }
                return (0, 0)
            },
            oldState: oldPair
        ) { vm, state in
            guard var log = vm.transcription,
                  let i = log.lines.firstIndex(where: { $0.id == capturedID }) else { return }
            log.lines[i].startSeconds = state.0
            log.lines[i].endSeconds = state.1
            vm.transcription = log
            vm.persistTranscription()
            vm.applyLayout()
        }
    }

    /// Remove a single caption line. Undoable; the full pre-delete
    /// `lines` array is snapshotted so restore preserves order.
    func deleteCaptionLine(id: UUID) {
        guard var log = transcription,
              let idx = log.lines.firstIndex(where: { $0.id == id }) else { return }
        let preDelete = log.lines
        log.lines.remove(at: idx)
        transcription = log
        persistTranscription()
        applyLayout()
        registerUndoableSnapshot(
            "Delete Caption",
            capture: { vm -> [TranscriptionLine] in vm.transcription?.lines ?? [] },
            oldState: preDelete
        ) { vm, state in
            guard var l = vm.transcription else { return }
            l.lines = state
            vm.transcription = l
            vm.persistTranscription()
            vm.applyLayout()
        }
    }

    private func persistTranscription() { scheduleSave(.transcription) }

    /// Currently-selected trim range, or the full duration when the user
    /// hasn't narrowed it.
    var trimRange: CMTimeRange {
        CMTimeRange(start: trimStart, end: trimEnd)
    }

    private func clamp(_ t: CMTime, lower: CMTime, upper: CMTime) -> CMTime {
        if CMTimeCompare(t, lower) < 0 { return lower }
        if CMTimeCompare(t, upper) > 0 { return upper }
        return t
    }

    // MARK: - Layout

    /// Rebuild `player.currentItem.audioMix` from the current volumes.
    /// Called by the `audioMixVolumes` didSet so preview updates as the
    /// user drags a mix slider.
    private func rebuildAndApplyAudioMix() {
        guard let result = compositionResult,
              let item = player.currentItem else { return }
        item.audioMix = AudioMixBuilder.build(
            composition: result.composition,
            micTrackID: result.micTrackID,
            systemTrackID: result.systemTrackID,
            soundboardTrackID: result.soundboardTrackID,
            volumes: audioMixVolumes
        )
    }

    private func applyLayout() {
        // An export renders from a snapshot of these values in its own
        // composition, so the preview isn't needed for correctness — but
        // it's held still mid-export so it keeps showing what's being
        // rendered rather than edits that won't be in this file.
        guard !isExporting else { return }
        guard let state = compositionResult?.compositorState else { return }
        state.set(currentOverlay(), trimMap: trimMap)
        // Boundary observers only change with the cuts; applyLayout runs on
        // every slider tick and used to reinstall them each time.
        if observedCutRanges != cutRanges {
            refreshCutBoundaryObservers()
            observedCutRanges = cutRanges
        }
        forceRedraw()
    }

    // MARK: - Keyframe edits (talking head + zoom)

    /// Apply an edited keyframe list: preview, save, and register undo.
    /// With a `coalesceKey`, rapid repeats (a pill or slider drag)
    /// collapse into one undo step back to the pre-drag list. `seekTo`
    /// moves the playhead before the preview refreshes.
    private func commitKeyframes<K: RampKeyframe>(
        _ keyPath: ReferenceWritableKeyPath<EditorViewModel, [K]>,
        _ updated: [K],
        saving file: SidecarFile,
        actionName: String,
        coalesceKey: AnyHashable? = nil,
        seekTo: CMTime? = nil
    ) {
        let old = self[keyPath: keyPath]
        self[keyPath: keyPath] = updated
        if let seekTo { seek(to: seekTo) }
        applyLayout()
        scheduleSave(file)
        registerUndoableSnapshot(
            actionName,
            coalesceKey: coalesceKey,
            capture: { $0[keyPath: keyPath] },
            oldState: old
        ) { vm, state in
            vm[keyPath: keyPath] = state
            vm.applyLayout()
            vm.scheduleSave(file)
        }
    }

    // MARK: - Talking-head keyframes

    /// Default parameters for a new talking-head keyframe.
    static let defaultTalkingHeadHold = CMTime(seconds: 3.0, preferredTimescale: 600)
    static let talkingHeadInOut = CMTime(seconds: 0.5, preferredTimescale: 600)

    /// Where "Add at playhead" would put a talking-head moment: the first
    /// gap after the playhead that fits at least a minimum-hold keyframe,
    /// capped at the default length.
    private func nextTalkingHeadSlot() -> (start: CMTime, maxTotalDuration: CMTime)? {
        let ramps = CMTimeMultiply(Self.talkingHeadInOut, multiplier: 2)
        return RampKeyframes.nextSlot(
            in: talkingHeadKeyframes,
            from: currentTime,
            duration: duration,
            minTotal: CMTimeAdd(ramps, RampKeyframes.minHold),
            defaultTotal: CMTimeAdd(ramps, Self.defaultTalkingHeadHold)
        )
    }

    var canAddTalkingHeadAtPlayhead: Bool {
        nextTalkingHeadSlot() != nil
    }

    func addTalkingHeadAtPlayhead() {
        guard let slot = nextTalkingHeadSlot() else { return }
        let kf = TalkingHeadKeyframe(
            startTime: slot.start,
            inDuration: Self.talkingHeadInOut,
            holdEndTime: RampKeyframes.holdEnd(start: slot.start, total: slot.maxTotalDuration, inOut: Self.talkingHeadInOut),
            outDuration: Self.talkingHeadInOut
        )
        // Move the playhead to the new keyframe so the user gets a
        // preview and the "Add" button auto-advances again on next click.
        commitKeyframes(\.talkingHeadKeyframes, RampKeyframes.sorted(talkingHeadKeyframes + [kf]),
                        saving: .talkingHead, actionName: "Add Talking Head", seekTo: slot.start)
    }

    func removeTalkingHeadKeyframe(id: UUID) {
        commitKeyframes(\.talkingHeadKeyframes, talkingHeadKeyframes.filter { $0.id != id },
                        saving: .talkingHead, actionName: "Remove Talking Head")
    }

    /// Move a talking-head keyframe so it starts at `newStart`, keeping its
    /// length and staying clear of its neighbours.
    func moveTalkingHeadKeyframe(id: UUID, to newStart: CMTime) {
        guard let moved = RampKeyframes.moving(talkingHeadKeyframes, id: id, to: newStart, duration: duration) else { return }
        commitKeyframes(\.talkingHeadKeyframes, moved, saving: .talkingHead,
                        actionName: "Move Talking Head", coalesceKey: "thMove:\(id.uuidString)")
    }

    /// Change a keyframe's hold (start and ramps unchanged), clamped so it
    /// can't run into the next keyframe or past the end.
    func setTalkingHeadHold(id: UUID, hold: CMTime) {
        guard let updated = RampKeyframes.settingHold(talkingHeadKeyframes, id: id, hold: hold, duration: duration) else { return }
        commitKeyframes(\.talkingHeadKeyframes, updated, saving: .talkingHead,
                        actionName: "Change Talking-Head Hold", coalesceKey: "thHold:\(id.uuidString)")
    }

    /// Update a keyframe's target diameter fraction (0.2 … 0.95).
    func setTalkingHeadDiameterFraction(id: UUID, fraction: CGFloat) {
        guard let idx = talkingHeadKeyframes.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0.2, min(0.95, fraction))
        guard clamped != talkingHeadKeyframes[idx].targetDiameterFraction else { return }
        var updated = talkingHeadKeyframes
        updated[idx].targetDiameterFraction = clamped
        commitKeyframes(\.talkingHeadKeyframes, updated, saving: .talkingHead,
                        actionName: "Change Talking-Head Size", coalesceKey: "thSize:\(id.uuidString)")
    }

    // MARK: - Zoom-keyframe editing

    /// Default timing for a manually added zoom — matches what the
    /// auto-generator uses so manual adds feel consistent alongside the
    /// auto ones. The peak scale comes from `zoomTuning`.
    static let defaultZoomInOut = CMTime(seconds: 0.5, preferredTimescale: 600)
    static let defaultZoomHold = CMTime(seconds: 1.5, preferredTimescale: 600)

    /// Zoom's equivalent of `nextTalkingHeadSlot`.
    private func nextZoomSlot() -> (start: CMTime, maxTotalDuration: CMTime)? {
        let ramps = CMTimeMultiply(Self.defaultZoomInOut, multiplier: 2)
        return RampKeyframes.nextSlot(
            in: zoomKeyframes,
            from: currentTime,
            duration: duration,
            minTotal: CMTimeAdd(ramps, RampKeyframes.minHold),
            defaultTotal: CMTimeAdd(ramps, Self.defaultZoomHold)
        )
    }

    var canAddZoomAtPlayhead: Bool {
        nextZoomSlot() != nil
    }

    /// Add a manual zoom keyframe at (or just after) the playhead,
    /// targeting the centre of the canvas; "Set focus" retargets it.
    func addZoomAtPlayhead() {
        guard let slot = nextZoomSlot() else { return }
        let kf = ZoomKeyframe(
            startTime: slot.start,
            inDuration: Self.defaultZoomInOut,
            holdEndTime: RampKeyframes.holdEnd(start: slot.start, total: slot.maxTotalDuration, inOut: Self.defaultZoomInOut),
            outDuration: Self.defaultZoomInOut,
            target: CGPoint(x: outputSize.width / 2, y: outputSize.height / 2),
            scale: zoomTuning.scale
        )
        commitKeyframes(\.zoomKeyframes, RampKeyframes.sorted(zoomKeyframes + [kf]),
                        saving: .zoom, actionName: "Add Zoom", seekTo: slot.start)
    }

    func removeZoomKeyframe(id: UUID) {
        if selectedZoomID == id { selectedZoomID = nil }
        commitKeyframes(\.zoomKeyframes, zoomKeyframes.filter { $0.id != id },
                        saving: .zoom, actionName: "Remove Zoom")
    }

    /// Inspector "How close": one peak scale for every zoom, and for
    /// zooms added or regenerated later. One undo step (per drag).
    func setScaleForAllZooms(_ scale: CGFloat) {
        let clamped = max(1.0, min(2.5, scale))
        var tuning = zoomTuning
        tuning.scale = clamped
        zoomTuning = tuning
        let updated = zoomKeyframes.map { kf -> ZoomKeyframe in
            var k = kf
            k.scale = clamped
            return k
        }
        guard updated != zoomKeyframes else { return }
        commitKeyframes(\.zoomKeyframes, updated, saving: .zoom,
                        actionName: "Change Zoom Closeness", coalesceKey: "zoomScaleAll")
    }

    /// Inspector "How long it stays zoomed". Shifts every zoom's hold by
    /// the change rather than setting one length: an auto zoom's hold
    /// spans its whole cluster of clicks plus this trailing time, so a
    /// flat value would cut long clusters short.
    func setHoldForAllZooms(_ seconds: TimeInterval) {
        let delta = seconds - zoomTuning.holdSeconds
        guard delta != 0 else { return }
        var tuning = zoomTuning
        tuning.holdSeconds = seconds
        zoomTuning = tuning
        var updated = zoomKeyframes
        for kf in zoomKeyframes {
            guard let current = updated.first(where: { $0.id == kf.id }) else { continue }
            let hold = CMTimeGetSeconds(CMTimeSubtract(current.holdEndTime, CMTimeAdd(current.startTime, current.inDuration)))
            let target = CMTime(seconds: hold + delta, preferredTimescale: 600)
            if let next = RampKeyframes.settingHold(updated, id: kf.id, hold: target, duration: duration) {
                updated = next
            }
        }
        guard updated != zoomKeyframes else { return }
        commitKeyframes(\.zoomKeyframes, updated, saving: .zoom,
                        actionName: "Change Zoom Length", coalesceKey: "zoomHoldAll")
    }

    /// Inspector: one size for every full-screen (talking-head) moment.
    func setSizeForAllTalkingHeads(_ fraction: CGFloat) {
        let clamped = max(0.2, min(0.95, fraction))
        let updated = talkingHeadKeyframes.map { kf -> TalkingHeadKeyframe in
            var k = kf
            k.targetDiameterFraction = clamped
            return k
        }
        guard updated != talkingHeadKeyframes else { return }
        commitKeyframes(\.talkingHeadKeyframes, updated, saving: .talkingHead,
                        actionName: "Change Full-Screen Size", coalesceKey: "thSizeAll")
    }

    /// True while "Polish my video" still has work running.
    var isPolishing: Bool { isTranscribing || isAutoCutting }

    /// Inspector "Polish my video": what most walkthroughs want — zooms
    /// on the clicks, captions, long pauses cut. Each part is its own
    /// undo step, and running it again is safe: auto-cut merges with
    /// existing cuts and captions are only written once.
    func quickPolish() {
        zoomEnabled = true
        if zoomKeyframes.isEmpty, loggedClickCount > 0 {
            regenerateZoomFromClicks()
        }
        if transcription == nil {
            generateCaptions()
        }
        if !captionStyle.enabled {
            var style = captionStyle
            style.enabled = true
            captionStyle = style
        }
        autoCutSilences()
    }

    /// Move a zoom keyframe so it starts at `newStart`, keeping its length
    /// and staying clear of its neighbours. Called by the timeline pill.
    func moveZoomKeyframe(id: UUID, to newStart: CMTime) {
        guard let moved = RampKeyframes.moving(zoomKeyframes, id: id, to: newStart, duration: duration) else { return }
        commitKeyframes(\.zoomKeyframes, moved, saving: .zoom,
                        actionName: "Move Zoom", coalesceKey: "zoomMove:\(id.uuidString)")
    }

    /// Change a keyframe's hold, clamped against the next keyframe's start.
    func setZoomKeyframeHold(id: UUID, hold: CMTime) {
        guard let updated = RampKeyframes.settingHold(zoomKeyframes, id: id, hold: hold, duration: duration) else { return }
        commitKeyframes(\.zoomKeyframes, updated, saving: .zoom,
                        actionName: "Change Zoom Hold", coalesceKey: "zoomHold:\(id.uuidString)")
    }

    /// Update a keyframe's peak scale (1.0 … 2.5).
    func setZoomKeyframeScale(id: UUID, scale: CGFloat) {
        guard let idx = zoomKeyframes.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(1.0, min(2.5, scale))
        guard clamped != zoomKeyframes[idx].scale else { return }
        var updated = zoomKeyframes
        updated[idx].scale = clamped
        commitKeyframes(\.zoomKeyframes, updated, saving: .zoom,
                        actionName: "Change Zoom Scale", coalesceKey: "zoomScale:\(id.uuidString)")
    }

    /// Enter "click to place focus" mode for this keyframe. The editor
    /// preview grows a transparent hit-catcher; the next click inside
    /// the preview rect is routed to `setZoomTarget`. Also seeks the
    /// playhead to the keyframe's peak so the user sees the image at
    /// the zoomed-in moment they're retargeting.
    func beginPlacingZoomTarget(id: UUID) {
        guard let kf = zoomKeyframes.first(where: { $0.id == id }) else { return }
        zoomTargetBeingPlaced = id
        seek(to: kf.peakStartTime)
    }

    /// Cancel focus-placement mode without updating the keyframe.
    /// Wired to both the ESC key and an explicit "Cancel" in the banner.
    func cancelPlacingZoomTarget() {
        zoomTargetBeingPlaced = nil
    }

    /// Apply a user-picked focus point (already converted into
    /// image-pixel coords, bottom-left origin — that's what
    /// `ZoomKeyframe.target` uses and what the compositor consumes).
    func setZoomTarget(id: UUID, imagePixel: CGPoint) {
        guard let idx = zoomKeyframes.firstIndex(where: { $0.id == id }) else { return }
        var updated = zoomKeyframes
        updated[idx].target = imagePixel
        zoomTargetBeingPlaced = nil
        commitKeyframes(\.zoomKeyframes, updated, saving: .zoom, actionName: "Set Zoom Focus")
    }

    /// Replace the keyframes with a fresh run of the generator over the
    /// click log, using the current `zoomTuning`. The user asked for it
    /// explicitly, and it's undoable.
    func regenerateZoomFromClicks() {
        let generated = ZoomKeyframeGenerator.generate(
            from: project.eventLog,
            metadata: project.metadata,
            duration: duration,
            config: zoomTuning.config()
        )
        commitKeyframes(\.zoomKeyframes, generated, saving: .zoom, actionName: "Regenerate Zoom")
    }

    /// Force the AVPlayer to re-run the compositor. Seeking to the CURRENT
    /// time is a no-op (AVPlayer short-circuits), so we nudge by one time
    /// unit to invalidate the cached frame.
    private func forceRedraw() {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let time = player.currentTime()
        guard time.isValid, !time.isIndefinite else { return }

        let nudge = CMTime(value: 1, timescale: 600)
        let forward = CMTimeAdd(time, nudge)
        let duration = item.duration

        let target: CMTime
        if duration.isValid, !duration.isIndefinite, CMTimeCompare(forward, duration) < 0 {
            target = forward
        } else if CMTimeCompare(time, nudge) > 0 {
            target = CMTimeSubtract(time, nudge)
        } else {
            target = time
        }
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Export

    /// Suggested default filename for the save panel.
    var suggestedExportFilename: String {
        let trimmed = !(trimStart == .zero && trimEnd == duration)
        return trimmed
            ? "\(project.displayName)_edited-trim.mp4"
            : "\(project.displayName)_edited.mp4"
    }

    /// Suggested starting directory for the save panel — same folder the
    /// original bundle lives in.
    var suggestedExportDirectory: URL {
        project.bundleURL.deletingLastPathComponent()
    }

    /// Build the `ExportLayout` that reflects the editor's current
    /// inspector values. Shared between the local-file export path
    /// and third-party destinations (Orbis) so both encode exactly
    /// what the user sees in the preview.
    /// The overlay as the editor currently has it — the single source
    /// for both the live preview (`applyLayout`) and exports
    /// (`currentExportLayout`), so the two can't drift apart.
    func currentOverlay() -> OverlaySettings {
        OverlaySettings(
            position: webcamPosition,
            shape: webcamShape,
            diameter: webcamDiameter,
            inset: webcamInset,
            webcamCustomOrigin: webcamCustomOrigin,
            webcamTransitions: webcamTransitions,
            webcamBackgroundStyle: webcamBackgroundStyle,
            zoomKeyframes: zoomEnabled ? zoomKeyframes : [],
            talkingHeadKeyframes: talkingHeadKeyframes,
            startCard: startCard,
            endCard: endCard,
            cursorRipples: cursorRipplesEnabled ? cursorRipples : [],
            cursorRippleStyle: .default,
            transcriptionLines: transcription?.lines ?? [],
            captionStyle: captionStyle,
            keystrokeChips: keystrokeOverlayStyle.enabled ? keystrokeChips : [],
            keystrokeOverlayStyle: keystrokeOverlayStyle,
            cursorTrack: cursorHighlightStyle.enabled ? cursorTrack : .empty,
            cursorHighlightStyle: cursorHighlightStyle
        )
    }

    func currentExportLayout() -> FinalRenderer.ExportLayout {
        FinalRenderer.ExportLayout(
            overlay: currentOverlay(),
            videoBitrate: exportQuality.bitrate,
            audioMixVolumes: audioMixVolumes,
            micOverrideURL: effectiveMicOverrideURL(),
            writeSRTSidecar: exportSRTSidecar
        )
    }

    /// Current editor trim range as a `TrimMap`, returning nil when
    /// the trim is trivial (no-op). Matches what `startExport` feeds
    /// to `FinalRenderer.render`.
    func currentExportTrimMap() -> TrimMap? {
        trimMap.isTrivial(fullDuration: duration) ? nil : trimMap
    }

    /// Kick off an async export with the editor's current inspector values
    /// and trim range. Does nothing if an export is already in flight.
    func startExport(to outputURL: URL) {
        guard !isExporting else { return }

        // Pause preview — the player item + the renderer both read the
        // same raw source files; pausing avoids resource contention.
        player.pause()

        let layout = currentExportLayout()
        let bundle = project.bundle
        let metadata = project.metadata
        let exportMap: TrimMap? = currentExportTrimMap()

        isExporting = true
        exportProgress = 0
        exportError = nil

        exportTask = Task { [weak self] in
            do {
                let url = try await FinalRenderer.render(
                    bundle: bundle,
                    metadata: metadata,
                    layout: layout,
                    trimMap: exportMap,
                    outputURL: outputURL
                ) { fraction in
                    Task { @MainActor in
                        self?.exportProgress = fraction
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.isExporting = false
                    self.exportProgress = 1.0
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    self.applyLayout()
                }
            } catch is CancellationError {
                await self?.finishExport(error: FinalRenderer.RenderError.cancelled)
            } catch {
                await self?.finishExport(error: error)
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    /// The Orbis sheet owns its controller's lifetime; this weak link
    /// just lets app-level quit handling find an in-flight upload.
    @ObservationIgnored weak var activeOrbisExport: OrbisExportController?

    /// Local export or Orbis render/upload currently running.
    var hasActiveExport: Bool {
        isExporting || (activeOrbisExport?.isActive ?? false)
    }

    /// Cancel every export this editor started and wait for them to
    /// unwind (the renderer deletes its partial MP4 on cancel).
    func cancelActiveExportsAndWait() async {
        let running = exportTask
        running?.cancel()
        await activeOrbisExport?.cancelAndWait()
        await running?.value
    }

    private func finishExport(error: any Error) async {
        await MainActor.run {
            self.isExporting = false
            self.exportError = error
            self.exportProgress = 0
            self.applyLayout()
        }
    }
}
