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
    private(set) var trimStart: CMTime = .zero
    private(set) var trimEnd: CMTime = .zero

    /// Interior cut ranges — regions in source-composition time that have
    /// been excised from the middle of the recording. Sorted, non-
    /// overlapping, strictly inside `[trimStart, trimEnd]`. Mutated via
    /// `insertCut` / `removeCut` / `clearCuts`; use `trimMap` (computed
    /// below) for any read that needs to know the kept ranges.
    private(set) var cutRanges: [CMTimeRange] = []

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
    private(set) var lastExportURL: URL?
    private var exportTask: Task<Void, Never>?

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
                applyLayout()
                registerUndoableChange(\.webcamPosition, from: oldValue,
                                       actionName: "Change Webcam Position",
                                       coalesceKey: "webcamPosition")
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
    /// establishes the dependency; the notification observers in
    /// `attachUndoObservers()` increment it on every stack change.
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
    /// key is touched again within `undoCoalesceInterval`, we suppress
    /// the new registration so a slider drag becomes a single undo
    /// step back to its pre-drag value (not dozens of tiny steps).
    @ObservationIgnored private var lastUndoCoalesceKey: AnyHashable?
    @ObservationIgnored private var lastUndoCoalesceTime: Date = .distantPast
    private let undoCoalesceInterval: TimeInterval = 0.5

    /// Register an inverse for a simple property assignment. `oldValue`
    /// is the pre-mutation value (usually captured via `didSet`'s
    /// implicit `oldValue`). `coalesceKey` groups rapid repeat
    /// mutations of the same logical property.
    ///
    /// Safe to call during `isUndoing` / `isRedoing` — `UndoManager`
    /// automatically detects direction and puts the inverse on the
    /// right stack. We bypass coalescing in those cases so a rapid
    /// undo doesn't swallow the redo registration.
    fileprivate func registerUndoableChange<T>(
        _ keyPath: ReferenceWritableKeyPath<EditorViewModel, T>,
        from oldValue: T,
        actionName: String,
        coalesceKey: AnyHashable
    ) {
        let isUserDriven = !undoManager.isUndoing && !undoManager.isRedoing
        if isUserDriven {
            let now = Date()
            if lastUndoCoalesceKey == coalesceKey,
               now.timeIntervalSince(lastUndoCoalesceTime) < undoCoalesceInterval {
                lastUndoCoalesceTime = now
                return
            }
            lastUndoCoalesceKey = coalesceKey
            lastUndoCoalesceTime = now
        }
        undoManager.registerUndo(withTarget: self) { target in
            target[keyPath: keyPath] = oldValue
        }
        undoManager.setActionName(actionName)
        undoStackRevision &+= 1
    }

    /// Snapshot-based variant with the same coalescing contract as
    /// `registerUndoableChange`. Use this for "continuous" operations
    /// (trim-handle drag, pill drag) on values that aren't backed by a
    /// property's `didSet`, since the direct-assignment undo path relies
    /// on `didSet` firing to register the redo.
    fileprivate func registerCoalescedSnapshot<State>(
        _ actionName: String,
        coalesceKey: AnyHashable,
        capture: @escaping (EditorViewModel) -> State,
        oldState: State,
        restore: @escaping (EditorViewModel, State) -> Void
    ) {
        let isUserDriven = !undoManager.isUndoing && !undoManager.isRedoing
        if isUserDriven {
            let now = Date()
            if lastUndoCoalesceKey == coalesceKey,
               now.timeIntervalSince(lastUndoCoalesceTime) < undoCoalesceInterval {
                lastUndoCoalesceTime = now
                return
            }
            lastUndoCoalesceKey = coalesceKey
            lastUndoCoalesceTime = now
        }
        registerUndoableSnapshot(actionName, capture: capture, oldState: oldState, restore: restore)
    }

    /// Register an inverse for a "snapshot" mutation — used when an
    /// operation changes multiple pieces of state at once (e.g. adding
    /// a keyframe touches both the array and a persisted sidecar).
    /// `restore` re-applies the given state + any follow-up work
    /// (applyLayout, persist…). The helper handles re-registering the
    /// opposite direction so redo works indefinitely.
    fileprivate func registerUndoableSnapshot<State>(
        _ actionName: String,
        capture: @escaping (EditorViewModel) -> State,
        oldState: State,
        restore: @escaping (EditorViewModel, State) -> Void
    ) {
        // Snapshot ops are always discrete — no coalescing.
        lastUndoCoalesceKey = nil
        undoManager.registerUndo(withTarget: self) { target in
            let currentState = capture(target)
            restore(target, oldState)
            target.registerUndoableSnapshot(
                actionName,
                capture: capture,
                oldState: currentState,
                restore: restore
            )
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
                applyLayout()
                registerUndoableChange(\.captionStyle, from: oldValue,
                                       actionName: "Change Captions",
                                       coalesceKey: "captionStyle")
            }
        }
    }

    /// Per-track audio volumes (mic / system / soundboard). Applied to
    /// both live preview (via `AVPlayerItem.audioMix`) and export (via
    /// `AVAssetReaderAudioMixOutput.audioMix`). Persisted.
    var audioMixVolumes: AudioMixBuilder.Volumes {
        didSet {
            if oldValue != audioMixVolumes {
                Settings.shared.editorAudioMixVolumes = audioMixVolumes
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

    init(project: RecordingProject) {
        self.project = project
        self.outputSize = CGSize(
            width: project.metadata.compositedPixelSize.width,
            height: project.metadata.compositedPixelSize.height
        )
        self.backingScale = CGFloat(project.metadata.backingScale ?? 2.0)

        self.webcamPosition = WebcamPosition(rawValue: project.metadata.webcamLayout.position) ?? .bottomRight
        self.webcamShape = WebcamShape(rawValue: project.metadata.webcamLayout.shape) ?? .circle
        self.webcamDiameter = CGFloat(project.metadata.webcamLayout.diameterPoints) * CGFloat(project.metadata.backingScale ?? 2.0)
        self.webcamInset    = CGFloat(project.metadata.webcamLayout.insetPoints)    * CGFloat(project.metadata.backingScale ?? 2.0)

        // Editor defaults — pull from Settings (remembered from the last
        // edit session), falling back to the built-in defaults on first run.
        self.zoomEnabled            = Settings.shared.editorSmartZoomEnabled
        self.cursorRipplesEnabled   = Settings.shared.editorCursorRipplesEnabled
        self.webcamTransitions      = Settings.shared.editorWebcamTransitions ?? .default
        self.startCard              = Settings.shared.editorStartCard ?? .defaultStart
        self.endCard                = Settings.shared.editorEndCard   ?? .defaultEnd
        self.exportQuality          = Settings.shared.exportQuality
        self.audioMixVolumes        = Settings.shared.editorAudioMixVolumes ?? .unity
        self.captionStyle           = Settings.shared.captionStyle ?? .default
        self.transcription          = project.transcription

        // Load any previously-persisted talking-head moments. If no log
        // exists (fresh recording or pre-persistence bundle), we start
        // empty and the first mutation will create the file.
        if let log = project.talkingHeadLog {
            self.talkingHeadKeyframes = log.keyframes.sorted {
                CMTimeCompare($0.startTime, $1.startTime) < 0
            }
        }

        self.player = AVPlayer()

        // Prime the compositor's shared state before AVFoundation instantiates it.
        LiveCompositor.state.update(
            position: webcamPosition,
            shape: webcamShape,
            diameter: webcamDiameter,
            inset: webcamInset,
            zoomKeyframes: [],
            webcamTransitions: webcamTransitions,
            startCard: startCard,
            endCard: endCard,
            trimMap: .entire(CMTimeRange(start: .zero, duration: .zero)),
            cursorRipples: [],
            cursorRippleStyle: .default,
            talkingHeadKeyframes: [],
            transcriptionLines: transcription?.lines ?? [],
            captionStyle: captionStyle
        )

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

    // MARK: - Composition loading

    private func loadComposition() async {
        do {
            let result = try await EditorComposition.build(for: project)
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
                persistZoomLog()
            }
            self.cursorRipples = CursorRippleGenerator.generate(
                from: project.eventLog,
                metadata: project.metadata
            )

            // Auto-trim silence — before flipping isLoading so the
            // editor window appears with the trim already applied (no
            // visible "full → content-range" snap).
            if let detected = await SilenceAnalyzer.detectContentRange(
                audioURL: project.bundle.micAudioURL,
                duration: result.duration
            ) {
                self.trimStart = detected.start
                self.trimEnd   = detected.end
                MentorDebug.log("EDITOR: auto-trim \(CMTimeGetSeconds(detected.start))..\(CMTimeGetSeconds(detected.end))s")
            }

            applyLayout()
            isLoading = false
            MentorDebug.log("EDITOR: zoom keyframes generated: \(self.zoomKeyframes.count)")

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
            MentorDebug.log("EDITOR: composition load failed: \(error)")
        }
    }

    /// Run undo + refresh observation state. Callers (buttons + ⌘Z
    /// handler) should use this instead of calling `undoManager.undo()`
    /// directly — it guarantees `canUndo` / `canRedo` / action names
    /// re-read correctly afterwards.
    func performUndo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
        undoStackRevision &+= 1
    }

    func performRedo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
        undoStackRevision &+= 1
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
        registerCoalescedSnapshot(
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
        registerCoalescedSnapshot(
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
                MentorDebug.log("AUTOCUT: inserted \(merged.count - existing.count) silence cuts (\(candidates.count) candidates, \(existing.count) pre-existing)")
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
                    self.persistTranscription()
                    self.applyLayout()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isTranscribing = false
                    self.transcriptionError = error
                    MentorDebug.log("CAPTIONS: generate failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Remove the persisted transcription + clear the in-memory copy.
    /// Used by the inspector's "Clear" button.
    func clearCaptions() {
        transcription = nil
        try? FileManager.default.removeItem(at: project.transcriptionURL)
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
        registerCoalescedSnapshot(
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
        registerCoalescedSnapshot(
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

    private func persistTranscription() {
        guard let log = transcription else {
            try? FileManager.default.removeItem(at: project.transcriptionURL)
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(log)
            try data.write(to: project.transcriptionURL, options: .atomic)
        } catch {
            MentorDebug.log("CAPTIONS: persist failed: \(error)")
        }
    }

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
        // While an export is running, the render pipeline owns the shared
        // compositor state — any mid-flight mutation would show up as a
        // visible layout change partway through the output file.
        guard !isExporting else { return }
        LiveCompositor.state.update(
            position: webcamPosition,
            shape: webcamShape,
            diameter: webcamDiameter,
            inset: webcamInset,
            zoomKeyframes: zoomEnabled ? zoomKeyframes : [],
            webcamTransitions: webcamTransitions,
            startCard: startCard,
            endCard: endCard,
            trimMap: trimMap,
            cursorRipples: cursorRipplesEnabled ? cursorRipples : [],
            cursorRippleStyle: .default,
            talkingHeadKeyframes: talkingHeadKeyframes,
            transcriptionLines: transcription?.lines ?? [],
            captionStyle: captionStyle
        )
        // Keep cut-skipping in sync with the current cutRanges. Cheap
        // — O(cuts) observer install each call, and cut edits are low-
        // frequency (user action, not drag).
        refreshCutBoundaryObservers()
        forceRedraw()
    }

    // MARK: - Talking-head keyframes

    /// Default parameters for a new talking-head keyframe.
    static let defaultTalkingHeadHold: CMTime = CMTime(seconds: 3.0, preferredTimescale: 600)
    static let talkingHeadInOut: CMTime = CMTime(seconds: 0.5, preferredTimescale: 600)
    static let minTalkingHeadHold: CMTime = CMTime(seconds: 0.25, preferredTimescale: 600)

    /// Total wall-clock length of a default-sized keyframe (in + hold + out).
    var defaultTalkingHeadTotalDuration: CMTime {
        let inOut = CMTimeMultiply(Self.talkingHeadInOut, multiplier: 2)
        return CMTimeAdd(inOut, Self.defaultTalkingHeadHold)
    }

    /// Smallest keyframe we're willing to place: 0.5s in + 0.25s hold + 0.5s out.
    /// Below this the transition barely has time to read as a talking-head
    /// moment, so there's no point offering to place one.
    var minTalkingHeadTotalDuration: CMTime {
        let inOut = CMTimeMultiply(Self.talkingHeadInOut, multiplier: 2)
        return CMTimeAdd(inOut, Self.minTalkingHeadHold)
    }

    /// A slot where a new talking-head keyframe can fit: where it starts
    /// and the maximum total length it's allowed (capped at both the
    /// available gap AND the default length, whichever is smaller).
    private struct TalkingHeadSlot {
        let start: CMTime
        let maxTotalDuration: CMTime
    }

    /// True when there's any gap after the playhead at least
    /// `minTalkingHeadTotalDuration` long. The button uses this to
    /// stay enabled whenever placement is viable — even if the gap is
    /// smaller than the default, we shrink the new keyframe to fit.
    var canAddTalkingHeadAtPlayhead: Bool {
        nextTalkingHeadSlot(from: currentTime) != nil
    }

    /// Walk existing keyframes in order from `time` forward and return
    /// the first gap big enough to hold at least `minTalkingHeadTotalDuration`.
    /// The slot's `maxTotalDuration` is clamped to the default length
    /// when the gap is larger — no point creating an extra-long default
    /// just because the gap happens to be huge.
    private func nextTalkingHeadSlot(from time: CMTime) -> TalkingHeadSlot? {
        let defaultTotal = defaultTalkingHeadTotalDuration
        let minTotal = minTalkingHeadTotalDuration
        let sorted = talkingHeadKeyframes.sorted {
            CMTimeCompare($0.startTime, $1.startTime) < 0
        }

        var cursor = time
        for kf in sorted {
            if CMTimeCompare(kf.endTime, cursor) <= 0 {
                continue  // keyframe ends before cursor — no conflict
            }
            if CMTimeCompare(kf.startTime, cursor) <= 0 {
                // cursor lives inside this keyframe — jump past it
                cursor = kf.endTime
                continue
            }
            // Gap: [cursor, kf.startTime). Is it at least minTotal?
            let gap = CMTimeSubtract(kf.startTime, cursor)
            if CMTimeCompare(gap, minTotal) >= 0 {
                return TalkingHeadSlot(start: cursor, maxTotalDuration: CMTimeMinimum(gap, defaultTotal))
            }
            // Too small — skip past this keyframe and keep looking.
            cursor = kf.endTime
        }
        let tailGap = CMTimeSubtract(duration, cursor)
        guard CMTimeCompare(tailGap, minTotal) >= 0 else { return nil }
        return TalkingHeadSlot(start: cursor, maxTotalDuration: CMTimeMinimum(tailGap, defaultTotal))
    }

    func addTalkingHeadAtPlayhead() {
        guard let slot = nextTalkingHeadSlot(from: currentTime) else { return }
        // hold = (total - in - out), clamped above the 0.25s minimum.
        let inOutS = 2 * CMTimeGetSeconds(Self.talkingHeadInOut)
        let totalS = CMTimeGetSeconds(slot.maxTotalDuration)
        let holdS = max(CMTimeGetSeconds(Self.minTalkingHeadHold), totalS - inOutS)
        let holdEnd = CMTimeAdd(
            CMTimeAdd(slot.start, Self.talkingHeadInOut),
            CMTime(seconds: holdS, preferredTimescale: 600)
        )
        let kf = TalkingHeadKeyframe(
            startTime: slot.start,
            inDuration: Self.talkingHeadInOut,
            holdEndTime: holdEnd,
            outDuration: Self.talkingHeadInOut
        )
        let old = talkingHeadKeyframes
        talkingHeadKeyframes.append(kf)
        talkingHeadKeyframes.sort { CMTimeCompare($0.startTime, $1.startTime) < 0 }
        // Move the playhead to the new keyframe so the user gets a
        // preview and the "Add" button auto-advances again on next click.
        seek(to: slot.start)
        applyLayout()
        persistTalkingHeadLog()
        registerTalkingHeadUndo(oldState: old, actionName: "Add Talking Head")
    }

    func removeTalkingHeadKeyframe(id: UUID) {
        let old = talkingHeadKeyframes
        talkingHeadKeyframes.removeAll { $0.id == id }
        applyLayout()
        persistTalkingHeadLog()
        registerTalkingHeadUndo(oldState: old, actionName: "Remove Talking Head")
    }

    /// Snapshot undo helper for the talking-head keyframes array.
    private func registerTalkingHeadUndo(oldState: [TalkingHeadKeyframe], actionName: String) {
        registerUndoableSnapshot(
            actionName,
            capture: { $0.talkingHeadKeyframes },
            oldState: oldState
        ) { vm, state in
            vm.talkingHeadKeyframes = state
            vm.applyLayout()
            vm.persistTalkingHeadLog()
        }
    }

    private func registerCoalescedTalkingHeadUndo(oldState: [TalkingHeadKeyframe], actionName: String, coalesceKey: AnyHashable) {
        let isUserDriven = !undoManager.isUndoing && !undoManager.isRedoing
        if isUserDriven {
            let now = Date()
            if lastUndoCoalesceKey == coalesceKey,
               now.timeIntervalSince(lastUndoCoalesceTime) < undoCoalesceInterval {
                lastUndoCoalesceTime = now
                return
            }
            lastUndoCoalesceKey = coalesceKey
            lastUndoCoalesceTime = now
        }
        registerTalkingHeadUndo(oldState: oldState, actionName: actionName)
    }

    /// Move a talking-head keyframe so its `startTime` becomes
    /// `newStart`, preserving total duration and clamping against
    /// neighbours + composition bounds. Symmetric to the zoom version.
    func moveTalkingHeadKeyframe(id: UUID, to newStart: CMTime) {
        guard let idx = talkingHeadKeyframes.firstIndex(where: { $0.id == id }) else { return }
        let kf = talkingHeadKeyframes[idx]
        let kfDur = CMTimeSubtract(kf.endTime, kf.startTime)
        let prev = talkingHeadKeyframes
            .filter { $0.id != id && CMTimeCompare($0.startTime, kf.startTime) <= 0 }
            .max(by: { CMTimeCompare($0.startTime, $1.startTime) < 0 })
        let next = talkingHeadKeyframes
            .filter { $0.id != id && CMTimeCompare($0.startTime, kf.startTime) > 0 }
            .min(by: { CMTimeCompare($0.startTime, $1.startTime) < 0 })
        let minStart = prev?.endTime ?? .zero
        let maxStart = CMTimeSubtract(next?.startTime ?? duration, kfDur)
        let clamped = clamp(newStart, lower: minStart, upper: maxStart)
        guard clamped != kf.startTime else { return }
        let oldState = talkingHeadKeyframes
        let delta = CMTimeSubtract(clamped, kf.startTime)
        talkingHeadKeyframes[idx].startTime = clamped
        talkingHeadKeyframes[idx].holdEndTime = CMTimeAdd(kf.holdEndTime, delta)
        talkingHeadKeyframes.sort { CMTimeCompare($0.startTime, $1.startTime) < 0 }
        applyLayout()
        persistTalkingHeadLog()
        registerCoalescedTalkingHeadUndo(oldState: oldState, actionName: "Move Talking Head",
                                         coalesceKey: "thMove:\(id.uuidString)")
    }

    /// Update a keyframe's hold duration (keeping `startTime` + in/out).
    /// Clamps to `minTalkingHeadHold` below, and above to whichever
    /// comes first: the next keyframe's start or the composition end.
    func setTalkingHeadHold(id: UUID, hold: CMTime) {
        guard let idx = talkingHeadKeyframes.firstIndex(where: { $0.id == id }) else { return }
        let kf = talkingHeadKeyframes[idx]

        // Find the next keyframe (by startTime) so we don't let the
        // hold slide through it. Falls back to composition duration.
        let nextStart = talkingHeadKeyframes
            .filter { CMTimeCompare($0.startTime, kf.startTime) > 0 }
            .map(\.startTime)
            .min(by: { CMTimeCompare($0, $1) < 0 }) ?? duration

        // Available room = [end of in-ramp, nextStart - outDuration).
        let holdStart = CMTimeAdd(kf.startTime, kf.inDuration)
        let maxHoldEnd = CMTimeSubtract(nextStart, kf.outDuration)
        let maxHoldSeconds = max(
            CMTimeGetSeconds(Self.minTalkingHeadHold),
            CMTimeGetSeconds(maxHoldEnd) - CMTimeGetSeconds(holdStart)
        )
        let minHoldSeconds = CMTimeGetSeconds(Self.minTalkingHeadHold)
        let requestedSeconds = CMTimeGetSeconds(hold)
        let clampedSeconds = min(max(requestedSeconds, minHoldSeconds), maxHoldSeconds)
        let newHoldEnd = CMTimeAdd(holdStart, CMTime(seconds: clampedSeconds, preferredTimescale: 600))

        guard newHoldEnd != kf.holdEndTime else { return }
        let oldState = talkingHeadKeyframes
        var updated = kf
        updated.holdEndTime = newHoldEnd
        talkingHeadKeyframes[idx] = updated
        applyLayout()
        persistTalkingHeadLog()
        registerCoalescedTalkingHeadUndo(oldState: oldState, actionName: "Change Talking-Head Hold",
                                         coalesceKey: "thHold:\(id.uuidString)")
    }

    /// Update a keyframe's target diameter fraction (0.2 … 0.95).
    func setTalkingHeadDiameterFraction(id: UUID, fraction: CGFloat) {
        guard let idx = talkingHeadKeyframes.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0.2, min(0.95, fraction))
        guard clamped != talkingHeadKeyframes[idx].targetDiameterFraction else { return }
        let oldState = talkingHeadKeyframes
        var updated = talkingHeadKeyframes[idx]
        updated.targetDiameterFraction = clamped
        talkingHeadKeyframes[idx] = updated
        applyLayout()
        persistTalkingHeadLog()
        registerCoalescedTalkingHeadUndo(oldState: oldState, actionName: "Change Talking-Head Size",
                                         coalesceKey: "thSize:\(id.uuidString)")
    }

    // MARK: - Zoom-keyframe editing

    /// Default parameters for a freshly-added zoom keyframe — matches
    /// what the auto-generator uses so manual adds feel consistent
    /// alongside the auto ones.
    static let defaultZoomInOut: CMTime = CMTime(seconds: 0.5, preferredTimescale: 600)
    static let defaultZoomHold: CMTime  = CMTime(seconds: 1.5, preferredTimescale: 600)
    static let defaultZoomScale: CGFloat = 1.5

    var defaultZoomTotalDuration: CMTime {
        let inOut = CMTimeMultiply(Self.defaultZoomInOut, multiplier: 2)
        return CMTimeAdd(inOut, Self.defaultZoomHold)
    }

    /// Zoom's equivalent of `nextTalkingHeadSlot` — same gap-finding
    /// logic so manual adds don't overlap existing keyframes and
    /// auto-advance to the next free spot.
    private func nextZoomSlot(from time: CMTime) -> (start: CMTime, maxTotalDuration: CMTime)? {
        let defaultTotal = defaultZoomTotalDuration
        // Minimum viable size: 0.5 in + 0.25 hold + 0.5 out.
        let minTotal = CMTime(seconds: 1.25, preferredTimescale: 600)
        let sorted = zoomKeyframes.sorted { CMTimeCompare($0.startTime, $1.startTime) < 0 }

        var cursor = time
        for kf in sorted {
            if CMTimeCompare(kf.endTime, cursor) <= 0 { continue }
            if CMTimeCompare(kf.startTime, cursor) <= 0 {
                cursor = kf.endTime
                continue
            }
            let gap = CMTimeSubtract(kf.startTime, cursor)
            if CMTimeCompare(gap, minTotal) >= 0 {
                return (cursor, CMTimeMinimum(gap, defaultTotal))
            }
            cursor = kf.endTime
        }
        let tail = CMTimeSubtract(duration, cursor)
        guard CMTimeCompare(tail, minTotal) >= 0 else { return nil }
        return (cursor, CMTimeMinimum(tail, defaultTotal))
    }

    var canAddZoomAtPlayhead: Bool {
        nextZoomSlot(from: currentTime) != nil
    }

    /// Add a new manual zoom keyframe at (or just after) the playhead.
    /// Target defaults to the centre of the captured canvas — v1 doesn't
    /// offer per-keyframe target editing; users relying on "zoom to this
    /// specific spot" should trigger a click there during recording and
    /// let the auto-generator catch it.
    func addZoomAtPlayhead() {
        guard let slot = nextZoomSlot(from: currentTime) else { return }
        let inOut = Self.defaultZoomInOut
        let totalS = CMTimeGetSeconds(slot.maxTotalDuration)
        let inOutS = 2 * CMTimeGetSeconds(inOut)
        let holdS = max(0.25, totalS - inOutS)
        let holdEnd = CMTimeAdd(CMTimeAdd(slot.start, inOut), CMTime(seconds: holdS, preferredTimescale: 600))

        let canvas = outputSize
        let target = CGPoint(x: canvas.width / 2, y: canvas.height / 2)

        let kf = ZoomKeyframe(
            startTime: slot.start,
            inDuration: inOut,
            holdEndTime: holdEnd,
            outDuration: inOut,
            target: target,
            scale: Self.defaultZoomScale
        )
        let old = zoomKeyframes
        zoomKeyframes.append(kf)
        zoomKeyframes.sort { CMTimeCompare($0.startTime, $1.startTime) < 0 }
        seek(to: slot.start)
        applyLayout()
        persistZoomLog()
        registerZoomKeyframesUndo(oldState: old, actionName: "Add Zoom")
    }

    func removeZoomKeyframe(id: UUID) {
        let old = zoomKeyframes
        zoomKeyframes.removeAll { $0.id == id }
        applyLayout()
        persistZoomLog()
        registerZoomKeyframesUndo(oldState: old, actionName: "Remove Zoom")
    }

    /// Snapshot undo helper for the zoom-keyframes array. Used by add /
    /// remove / regenerate — anything that mutates the whole list.
    /// For scrubbing-style mutations (move, hold, scale), the per-
    /// field setters use their own coalescing wrapper below.
    private func registerZoomKeyframesUndo(oldState: [ZoomKeyframe], actionName: String) {
        registerUndoableSnapshot(
            actionName,
            capture: { $0.zoomKeyframes },
            oldState: oldState
        ) { vm, state in
            vm.zoomKeyframes = state
            vm.applyLayout()
            vm.persistZoomLog()
        }
    }

    /// Move an entire zoom keyframe so its `startTime` becomes `newStart`
    /// (clamped against prev/next keyframes + composition bounds). The
    /// keyframe's total duration stays the same — only the time origin
    /// shifts. Called by the timeline lane's drag gesture.
    func moveZoomKeyframe(id: UUID, to newStart: CMTime) {
        guard let idx = zoomKeyframes.firstIndex(where: { $0.id == id }) else { return }
        let kf = zoomKeyframes[idx]
        let kfDur = CMTimeSubtract(kf.endTime, kf.startTime)
        let prev = zoomKeyframes
            .filter { $0.id != id && CMTimeCompare($0.startTime, kf.startTime) <= 0 }
            .max(by: { CMTimeCompare($0.startTime, $1.startTime) < 0 })
        let next = zoomKeyframes
            .filter { $0.id != id && CMTimeCompare($0.startTime, kf.startTime) > 0 }
            .min(by: { CMTimeCompare($0.startTime, $1.startTime) < 0 })
        let minStart = prev?.endTime ?? .zero
        let maxStart = CMTimeSubtract(next?.startTime ?? duration, kfDur)
        let clamped = clamp(newStart, lower: minStart, upper: maxStart)
        guard clamped != kf.startTime else { return }
        let oldState = zoomKeyframes
        let delta = CMTimeSubtract(clamped, kf.startTime)
        zoomKeyframes[idx].startTime = clamped
        zoomKeyframes[idx].holdEndTime = CMTimeAdd(kf.holdEndTime, delta)
        zoomKeyframes.sort { CMTimeCompare($0.startTime, $1.startTime) < 0 }
        applyLayout()
        persistZoomLog()
        registerCoalescedZoomUndo(oldState: oldState, actionName: "Move Zoom",
                                  coalesceKey: "zoomMove:\(id.uuidString)")
    }

    /// Update a keyframe's hold duration, clamped against the next
    /// keyframe's start.
    func setZoomKeyframeHold(id: UUID, hold: CMTime) {
        guard let idx = zoomKeyframes.firstIndex(where: { $0.id == id }) else { return }
        let kf = zoomKeyframes[idx]
        let nextStart = zoomKeyframes
            .filter { CMTimeCompare($0.startTime, kf.startTime) > 0 }
            .map(\.startTime)
            .min(by: { CMTimeCompare($0, $1) < 0 }) ?? duration

        let holdStart = CMTimeAdd(kf.startTime, kf.inDuration)
        let maxHoldEnd = CMTimeSubtract(nextStart, kf.outDuration)
        let maxHoldS = max(0.25, CMTimeGetSeconds(maxHoldEnd) - CMTimeGetSeconds(holdStart))
        let requestedS = CMTimeGetSeconds(hold)
        let clampedS = min(max(requestedS, 0.25), maxHoldS)
        let newHoldEnd = CMTimeAdd(holdStart, CMTime(seconds: clampedS, preferredTimescale: 600))
        guard newHoldEnd != kf.holdEndTime else { return }
        let oldState = zoomKeyframes
        zoomKeyframes[idx].holdEndTime = newHoldEnd
        applyLayout()
        persistZoomLog()
        registerCoalescedZoomUndo(oldState: oldState, actionName: "Change Zoom Hold",
                                  coalesceKey: "zoomHold:\(id.uuidString)")
    }

    /// Update a keyframe's peak scale (1.1 … 2.5).
    func setZoomKeyframeScale(id: UUID, scale: CGFloat) {
        guard let idx = zoomKeyframes.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(1.0, min(2.5, scale))
        guard clamped != zoomKeyframes[idx].scale else { return }
        let oldState = zoomKeyframes
        zoomKeyframes[idx].scale = clamped
        applyLayout()
        persistZoomLog()
        registerCoalescedZoomUndo(oldState: oldState, actionName: "Change Zoom Scale",
                                  coalesceKey: "zoomScale:\(id.uuidString)")
    }

    /// Wipe persisted keyframes and regenerate from the click log.
    /// Destructive — user explicitly confirms by clicking the button.
    func regenerateZoomFromClicks() {
        let old = zoomKeyframes
        zoomKeyframes = ZoomKeyframeGenerator.generate(
            from: project.eventLog,
            metadata: project.metadata,
            duration: duration
        )
        applyLayout()
        persistZoomLog()
        registerZoomKeyframesUndo(oldState: old, actionName: "Regenerate Zoom")
    }

    /// Coalescing variant of the zoom-keyframes undo registration.
    /// First mutation in a streak captures the pre-streak state; rapid
    /// follow-ups within `undoCoalesceInterval` are suppressed so one
    /// slider drag / pill drag = one undo step back to the pre-drag
    /// state instead of dozens of micro-steps.
    private func registerCoalescedZoomUndo(oldState: [ZoomKeyframe], actionName: String, coalesceKey: AnyHashable) {
        let isUserDriven = !undoManager.isUndoing && !undoManager.isRedoing
        if isUserDriven {
            let now = Date()
            if lastUndoCoalesceKey == coalesceKey,
               now.timeIntervalSince(lastUndoCoalesceTime) < undoCoalesceInterval {
                lastUndoCoalesceTime = now
                return
            }
            lastUndoCoalesceKey = coalesceKey
            lastUndoCoalesceTime = now
        }
        registerZoomKeyframesUndo(oldState: oldState, actionName: actionName)
    }

    private func persistZoomLog() {
        let log = ZoomLog(version: 1, keyframes: zoomKeyframes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = project.zoomURL
        do {
            if zoomKeyframes.isEmpty {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let data = try encoder.encode(log)
            try data.write(to: url, options: .atomic)
        } catch {
            MentorDebug.log("EDITOR: zoom log persist failed: \(error)")
        }
    }

    // MARK: - Talking-head persistence

    /// Serialize `talkingHeadKeyframes` to the sidecar. Writes are
    /// best-effort — a disk error is logged but doesn't interrupt the
    /// editor session (the in-memory state remains correct).
    private func persistTalkingHeadLog() {
        let log = TalkingHeadLog(version: 1, keyframes: talkingHeadKeyframes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = project.talkingHeadURL
        do {
            if talkingHeadKeyframes.isEmpty {
                // Clean removal — don't leave an empty-array file behind.
                try? FileManager.default.removeItem(at: url)
                return
            }
            let data = try encoder.encode(log)
            try data.write(to: url, options: .atomic)
        } catch {
            MentorDebug.log("EDITOR: talking-head persist failed: \(error)")
        }
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

    /// Kick off an async export with the editor's current inspector values
    /// and trim range. Does nothing if an export is already in flight.
    func startExport(to outputURL: URL) {
        guard !isExporting else { return }

        // Pause preview — the player item + the renderer both read the
        // same raw source files; pausing avoids resource contention.
        player.pause()

        let layout = FinalRenderer.ExportLayout(
            position: webcamPosition,
            shape: webcamShape,
            diameterPixels: webcamDiameter,
            insetPixels: webcamInset,
            zoomKeyframes: zoomEnabled ? zoomKeyframes : [],
            webcamTransitions: webcamTransitions,
            startCard: startCard,
            endCard: endCard,
            cursorRipples: cursorRipplesEnabled ? cursorRipples : [],
            cursorRippleStyle: .default,
            talkingHeadKeyframes: talkingHeadKeyframes,
            videoBitrate: exportQuality.bitrate,
            audioMixVolumes: audioMixVolumes,
            transcriptionLines: transcription?.lines ?? [],
            captionStyle: captionStyle
        )
        let bundle = project.bundle
        let metadata = project.metadata
        let exportMap: TrimMap? = trimMap.isTrivial(fullDuration: duration) ? nil : trimMap

        isExporting = true
        exportProgress = 0
        exportError = nil
        lastExportURL = nil

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
                    self.lastExportURL = url
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

    private func finishExport(error: any Error) async {
        await MainActor.run {
            self.isExporting = false
            self.exportError = error
            self.exportProgress = 0
            self.applyLayout()
        }
    }
}
