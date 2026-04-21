import AVFoundation
import CoreImage
import CoreVideo
import CoreMedia
import Metal

/// Custom `AVVideoCompositing` that re-runs our Core Image compositing math
/// for every frame of playback — letting the editor preview layout changes
/// (webcam position / shape / diameter) live against the raw screen + webcam
/// tracks recorded into the `.mentor` sidecar.
///
/// State flow: the editor view model writes to `LiveCompositor.state`; AVFoundation
/// instantiates the compositor and calls `startRequest(_:)` for each frame,
/// where we snapshot state and render. To trigger a redraw when paused, the
/// view model re-seeks to the current time.
final class LiveCompositor: NSObject, AVVideoCompositing {

    // MARK: - Shared state

    /// Thread-safe container for the editor's current overlay settings.
    final class State: @unchecked Sendable {
        struct Snapshot {
            let position: WebcamPosition
            let shape: WebcamShape
            let diameter: CGFloat       // output pixels
            let inset: CGFloat          // output pixels
            /// If set, overrides the corner-preset placement with an
            /// explicit bottom-left origin in output-pixel space.
            /// Populated by drag-to-reposition in the editor; cleared
            /// when the user picks a preset corner from the inspector.
            let webcamCustomOrigin: CGPoint?
            let zoomKeyframes: [ZoomKeyframe]
            let webcamTransitions: WebcamTransitions
            let startCard: TitleCard
            let endCard: TitleCard
            /// Effective output time map — the outer trim window plus
            /// any interior cuts. Webcam fades + title cards key to
            /// `trimMap.outputDuration` (the true length of what the
            /// viewer sees), NOT the full composition, so trimming /
            /// cutting doesn't push cards out of view. Defaults to zero
            /// for the initial snapshot; replaced by the editor /
            /// renderer once the composition is known.
            let trimMap: TrimMap
            let cursorRipples: [CursorRipple]
            let cursorRippleStyle: CursorRippleStyle
            let talkingHeadKeyframes: [TalkingHeadKeyframe]
            /// Burned-in subtitles. Empty `lines` or `style.enabled`
            /// false → compositor short-circuits before per-frame lookup.
            let transcriptionLines: [TranscriptionLine]
            let captionStyle: CaptionStyle
            /// Keystroke overlay chips. Same short-circuit rule —
            /// empty or `style.enabled == false` bypasses the overlay
            /// pass entirely.
            let keystrokeChips: [KeystrokeChip]
            let keystrokeOverlayStyle: KeystrokeOverlayStyle
            /// Always-on cursor highlight halo. Position is interpolated
            /// from the samples in `cursorTrack`. Empty track or
            /// `style.enabled == false` skips the overlay entirely.
            let cursorTrack: CursorHighlightTrack
            let cursorHighlightStyle: CursorHighlightStyle
            /// Webcam background processing (blur / color). `off` skips
            /// the per-frame segmentation pass entirely.
            let webcamBackgroundStyle: WebcamBackgroundStyle
        }

        private let lock = NSLock()
        private var current: Snapshot

        init(_ initial: Snapshot) {
            self.current = initial
        }

        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            return current
        }

        func update(
            position: WebcamPosition? = nil,
            shape: WebcamShape? = nil,
            diameter: CGFloat? = nil,
            inset: CGFloat? = nil,
            webcamCustomOrigin: CGPoint?? = nil,
            zoomKeyframes: [ZoomKeyframe]? = nil,
            webcamTransitions: WebcamTransitions? = nil,
            startCard: TitleCard? = nil,
            endCard: TitleCard? = nil,
            trimMap: TrimMap? = nil,
            cursorRipples: [CursorRipple]? = nil,
            cursorRippleStyle: CursorRippleStyle? = nil,
            talkingHeadKeyframes: [TalkingHeadKeyframe]? = nil,
            transcriptionLines: [TranscriptionLine]? = nil,
            captionStyle: CaptionStyle? = nil,
            keystrokeChips: [KeystrokeChip]? = nil,
            keystrokeOverlayStyle: KeystrokeOverlayStyle? = nil,
            cursorTrack: CursorHighlightTrack? = nil,
            cursorHighlightStyle: CursorHighlightStyle? = nil,
            webcamBackgroundStyle: WebcamBackgroundStyle? = nil
        ) {
            lock.lock(); defer { lock.unlock() }
            // `CGPoint??` lets us distinguish "don't touch" (.none —
            // caller omitted the arg) from "clear to nil"
            // (.some(nil)). The viewmodel writes the full state on
            // every call, so it always passes the .some branch.
            let newCustomOrigin: CGPoint?
            switch webcamCustomOrigin {
            case .some(let v): newCustomOrigin = v
            case .none:        newCustomOrigin = current.webcamCustomOrigin
            }
            current = Snapshot(
                position: position ?? current.position,
                shape: shape ?? current.shape,
                diameter: diameter ?? current.diameter,
                inset: inset ?? current.inset,
                webcamCustomOrigin: newCustomOrigin,
                zoomKeyframes: zoomKeyframes ?? current.zoomKeyframes,
                webcamTransitions: webcamTransitions ?? current.webcamTransitions,
                startCard: startCard ?? current.startCard,
                endCard: endCard ?? current.endCard,
                trimMap: trimMap ?? current.trimMap,
                cursorRipples: cursorRipples ?? current.cursorRipples,
                cursorRippleStyle: cursorRippleStyle ?? current.cursorRippleStyle,
                talkingHeadKeyframes: talkingHeadKeyframes ?? current.talkingHeadKeyframes,
                transcriptionLines: transcriptionLines ?? current.transcriptionLines,
                captionStyle: captionStyle ?? current.captionStyle,
                keystrokeChips: keystrokeChips ?? current.keystrokeChips,
                keystrokeOverlayStyle: keystrokeOverlayStyle ?? current.keystrokeOverlayStyle,
                cursorTrack: cursorTrack ?? current.cursorTrack,
                cursorHighlightStyle: cursorHighlightStyle ?? current.cursorHighlightStyle,
                webcamBackgroundStyle: webcamBackgroundStyle ?? current.webcamBackgroundStyle
            )
        }
    }

    /// Default state — used by `EditorComposition.build` / `stitched`
    /// to seed each composition's own state instance. Previously a
    /// global singleton, which meant the editor and the post-capture
    /// auto-bake fought for the same mutable state: while the bake was
    /// in flight, the editor's preview was stuck on whatever snapshot
    /// the renderer set up, and inspector changes were suppressed to
    /// avoid polluting the render. Per-instruction state lets them
    /// coexist fully.
    static func defaultState() -> State {
        State(
            State.Snapshot(
                position: .bottomRight,
                shape: .circle,
                diameter: 640,
                inset: 96,
                webcamCustomOrigin: nil,
                zoomKeyframes: [],
                webcamTransitions: .default,
                startCard: .defaultStart,
                endCard: .defaultEnd,
                trimMap: .entire(CMTimeRange(start: .zero, duration: .zero)),
                cursorRipples: [],
                cursorRippleStyle: .default,
                talkingHeadKeyframes: [],
                transcriptionLines: [],
                captionStyle: .default,
                keystrokeChips: [],
                keystrokeOverlayStyle: .default,
                cursorTrack: .empty,
                cursorHighlightStyle: .default,
                webcamBackgroundStyle: .default
            )
        )
    }

    // MARK: - AVVideoCompositing

    let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
    ]

    private let ciContext: CIContext
    private let renderQueue = DispatchQueue(
        label: "com.darrell.mentor.live-compositor",
        qos: .userInteractive
    )
    private let contextLock = NSLock()
    private var renderContext: AVVideoCompositionRenderContext?
    private var cancelled = false

    // Mask cache (regenerated when shape/diameter changes)
    private var cachedMaskShape: WebcamShape?
    private var cachedMaskDiameter: CGFloat = 0
    private var cachedMaskImage: CIImage?

    // Title-card image caches (one per side). Re-rendered when the card's
    // text/colors or output size changes — not every frame.
    private var cachedStartCardKey: Int?
    private var cachedStartCardSize: CGSize = .zero
    private var cachedStartCardImage: CIImage?
    private var cachedEndCardKey: Int?
    private var cachedEndCardSize: CGSize = .zero
    private var cachedEndCardImage: CIImage?

    // Caption cache — one rendered image per (text, style, size). A
    // typical recording has dozens of distinct caption lines so an LRU
    // would be nicer; a single-slot cache is enough in practice because
    // the compositor only ever shows one line at a time, and we only
    // re-render when the active line changes.
    private var cachedCaptionKey: String?
    private var cachedCaptionImage: CIImage?

    // Keystroke chip cache — keyed by label + font-pt + output size.
    // Multiple chips can be active in the same frame (e.g. a burst of
    // ⌘S ⌘Enter), so we need a dict. Size rarely changes after the
    // compositor's first frame; we flush the cache when the sizing key
    // shifts to keep the dict from growing unbounded across style edits.
    private var cachedChipImages: [String: (image: CIImage, size: CGSize)] = [:]
    private var cachedChipSizingKey: String = ""

    private var debugFrameCount: Int64 = 0

    override init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        }
        super.init()
        MentorDebug.log("LIVE: compositor instantiated")
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        contextLock.lock()
        renderContext = newRenderContext
        contextLock.unlock()
        MentorDebug.log("LIVE: render context changed, size=\(newRenderContext.size)")
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // Synchronous log to confirm AVFoundation is invoking us at all.
        // Rate-limited below once we've confirmed.
        let n = OSAtomicIncrement64(&debugFrameCount)
        if n <= 3 || n % 120 == 0 {
            MentorDebug.log("LIVE: startRequest entry #\(n)")
        }

        renderQueue.async { [weak self] in
            guard let self else {
                request.finishCancelledRequest()
                return
            }
            self.contextLock.lock()
            if self.cancelled {
                self.contextLock.unlock()
                request.finishCancelledRequest()
                return
            }
            let ctx = self.renderContext
            self.contextLock.unlock()

            guard let ctx, let outBuffer = ctx.newPixelBuffer() else {
                request.finish(with: NSError(
                    domain: "com.darrell.mentor.editor",
                    code: 100,
                    userInfo: [NSLocalizedDescriptionKey: "No render context / pixel buffer"]
                ))
                return
            }

            guard let instruction = request.videoCompositionInstruction as? Instruction else {
                // Unknown instruction — output black, don't crash playback.
                request.finish(withComposedVideoFrame: outBuffer)
                return
            }

            // Each composition owns its own State (editor preview vs.
            // auto-bake); read whichever the instruction was built with
            // so they don't fight over a shared singleton.
            let snapshot = instruction.state.snapshot()
            let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID)
            let webcamBuffer = instruction.webcamTrackID != kCMPersistentTrackID_Invalid
                ? request.sourceFrame(byTrackID: instruction.webcamTrackID)
                : nil
            let frameTime = request.compositionTime

            if n <= 3 || n % 120 == 0 {
                MentorDebug.log("LIVE: frame #\(n) screen=\(screenBuffer != nil ? "yes" : "NIL") webcam=\(webcamBuffer != nil ? "yes" : "NIL") pos=\(snapshot.position) shape=\(snapshot.shape) diam=\(Int(snapshot.diameter)) zoomKfs=\(snapshot.zoomKeyframes.count)")
            }

            self.render(
                screen: screenBuffer,
                webcam: webcamBuffer,
                layout: snapshot,
                frameTime: frameTime,
                output: outBuffer,
                outputSize: ctx.size
            )

            request.finish(withComposedVideoFrame: outBuffer)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        contextLock.lock()
        cancelled = true
        contextLock.unlock()
        renderQueue.sync { }   // drain
        contextLock.lock()
        cancelled = false
        contextLock.unlock()
    }

    // MARK: - Rendering

    private func render(
        screen: CVPixelBuffer?,
        webcam: CVPixelBuffer?,
        layout: State.Snapshot,
        frameTime: CMTime,
        output: CVPixelBuffer,
        outputSize: CGSize
    ) {
        var composite: CIImage
        if let screen {
            let screenImage = CIImage(cvPixelBuffer: screen)
            var filled = scaledToFill(screenImage, size: outputSize)
            // Cursor highlight halo — rendered UNDER ripples so a click
            // on the halo shows the expanding ripple on top, and BEFORE
            // zoom so the halo gets magnified along with the cursor.
            if let halo = renderCursorHighlight(at: frameTime, layout: layout) {
                filled = halo.composited(over: filled)
            }
            // Ripples ride on the screen layer, so smart zoom magnifies
            // them along with the click point. Order: screen → halo →
            // ripples → zoom → webcam → cards.
            if let ripples = renderCursorRipples(at: frameTime, layout: layout, canvasSize: outputSize) {
                filled = ripples.composited(over: filled)
            }
            composite = applyZoom(to: filled, layout: layout, time: frameTime, outputSize: outputSize)
        } else {
            composite = CIImage(color: CIColor.black)
                .cropped(to: CGRect(origin: .zero, size: outputSize))
        }

        if layout.position != .hidden, let webcam {
            // Compute effective webcam geometry — diameter + origin —
            // interpolated against any active talking-head keyframe.
            let (effDiameter, effOrigin) = webcamGeometry(layout: layout, time: frameTime, outputSize: outputSize)
            if effDiameter > 0,
               var overlay = buildWebcamImage(
                   camera: webcam,
                   shape: layout.shape,
                   diameter: effDiameter,
                   backgroundStyle: layout.webcamBackgroundStyle
               ) {
                let timeInOutput = layout.trimMap.outputTime(forSourceTime: frameTime)
                let webcamAlpha = layout.webcamTransitions.alpha(
                    at: timeInOutput,
                    totalDuration: layout.trimMap.outputDuration
                )
                if webcamAlpha < 0.999 {
                    overlay = applyAlpha(webcamAlpha, to: overlay)
                }
                if webcamAlpha > 0.001 {
                    let translated = overlay.transformed(
                        by: CGAffineTransform(translationX: effOrigin.x, y: effOrigin.y)
                    )
                    composite = translated.composited(over: composite)
                }
            }
        }

        composite = applyTitleCards(over: composite, layout: layout, time: frameTime, outputSize: outputSize)
        composite = applyCaptions(over: composite, layout: layout, time: frameTime, outputSize: outputSize)
        composite = applyKeystrokeOverlay(over: composite, layout: layout, time: frameTime, outputSize: outputSize)

        let cropped = composite.cropped(to: CGRect(origin: .zero, size: outputSize))
        ciContext.render(
            cropped,
            to: output,
            bounds: CGRect(origin: .zero, size: outputSize),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
    }

    /// Render the active cursor ripples (if any) to a transparent canvas-
    /// sized CIImage. Returns nil when no ripple is currently visible —
    /// that's the common case, so we skip the CGContext allocation
    /// entirely. Each ripple is a stroked circle whose radius grows
    /// linearly from `initialRadius` to `finalRadius` over its lifetime,
    /// while opacity fades linearly to 0.
    /// Render the always-on cursor highlight halo at the interpolated
    /// cursor position for the current frame. Returns nil when the
    /// overlay is disabled, the track is empty, or the cursor was off-
    /// canvas at this moment (no sample to interpolate from).
    private func renderCursorHighlight(
        at time: CMTime,
        layout: State.Snapshot
    ) -> CIImage? {
        let style = layout.cursorHighlightStyle
        guard style.enabled, !layout.cursorTrack.points.isEmpty else { return nil }
        let t = CMTimeGetSeconds(time)
        guard t.isFinite else { return nil }
        guard let pos = layout.cursorTrack.position(at: t) else { return nil }
        return CursorHighlightRenderer.render(center: pos, style: style)
    }

    private func renderCursorRipples(
        at time: CMTime,
        layout: State.Snapshot,
        canvasSize: CGSize
    ) -> CIImage? {
        let style = layout.cursorRippleStyle
        guard style.enabled, !layout.cursorRipples.isEmpty else { return nil }

        let now = CMTimeGetSeconds(time)
        guard now.isFinite else { return nil }

        struct Active {
            let center: CGPoint
            let radius: CGFloat
            let opacity: CGFloat
        }
        var active: [Active] = []
        for ripple in layout.cursorRipples {
            let elapsed = now - CMTimeGetSeconds(ripple.time)
            guard elapsed >= 0, elapsed <= style.duration else { continue }
            let p = elapsed / style.duration
            let radius = style.initialRadius + (style.finalRadius - style.initialRadius) * CGFloat(p)
            let opacity = style.initialOpacity * CGFloat(1 - p)
            active.append(Active(center: ripple.target, radius: radius, opacity: opacity))
        }
        guard !active.isEmpty else { return nil }

        let w = max(1, Int(canvasSize.width))
        let h = max(1, Int(canvasSize.height))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setLineWidth(style.strokeWidth)
        ctx.setLineCap(.round)
        for a in active {
            let stroke = CGColor(
                srgbRed: style.color.red,
                green: style.color.green,
                blue: style.color.blue,
                alpha: style.color.alpha * Double(a.opacity)
            )
            ctx.setStrokeColor(stroke)
            // CGContext shares CIImage's bottom-left origin convention,
            // so target.y maps directly without flipping.
            let rect = CGRect(
                x: a.center.x - a.radius,
                y: a.center.y - a.radius,
                width: a.radius * 2,
                height: a.radius * 2
            )
            ctx.strokeEllipse(in: rect)
        }

        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Multiply `image`'s alpha channel by `a` (0...1). Implemented via
    /// `CIColorMatrix` so we don't pay for a full-canvas blend.
    private func applyAlpha(_ a: CGFloat, to image: CIImage) -> CIImage {
        let f = CIFilter(name: "CIColorMatrix")!
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        f.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        f.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        f.setValue(CIVector(x: 0, y: 0, z: 0, w: a), forKey: "inputAVector")
        return f.outputImage ?? image
    }

    /// Composite the start + end title cards over `base` if either is
    /// active at `time`. Card opacity follows an easeInOutCubic envelope
    /// so the cross-fade has the same feel as the smart-zoom ramps.
    /// Time math is in **output time** (i.e. relative to `outputRange.start`),
    /// so trimming the start of the recording doesn't push the start card
    /// out of view.
    /// Composite the active subtitle line (if any) over `base`. Cached
    /// by `{text, style, size}` so the same rendered image is reused
    /// for every frame the line is on screen.
    private func applyCaptions(
        over base: CIImage,
        layout: State.Snapshot,
        time: CMTime,
        outputSize: CGSize
    ) -> CIImage {
        guard layout.captionStyle.enabled, !layout.transcriptionLines.isEmpty else {
            return base
        }
        let secs = CMTimeGetSeconds(time)
        guard secs.isFinite else { return base }
        // Linear scan is fine — editing sessions typically have < ~200
        // lines, binary-search wouldn't win measurably.
        guard let active = layout.transcriptionLines.first(where: { secs >= $0.startSeconds && secs < $0.endSeconds }) else {
            return base
        }

        let key = captionCacheKey(text: active.text, style: layout.captionStyle, size: outputSize)
        let image: CIImage?
        if cachedCaptionKey == key, let cached = cachedCaptionImage {
            image = cached
        } else {
            image = CaptionRenderer.render(text: active.text, style: layout.captionStyle, canvasSize: outputSize)
            cachedCaptionKey = key
            cachedCaptionImage = image
        }
        guard let captionImage = image else { return base }
        return captionImage.composited(over: base)
    }

    private func captionCacheKey(text: String, style: CaptionStyle, size: CGSize) -> String {
        // Enough state to invalidate when anything visible changes,
        // stringly-typed for trivial equality. Font sizing is derived
        // from `size` + `fontSizeFraction`, so both are in the key.
        "\(text)|\(Int(size.width))x\(Int(size.height))|\(style.fontSizeFraction)|\(style.bottomInsetFraction)|\(style.textColor.red),\(style.textColor.green),\(style.textColor.blue),\(style.textColor.alpha)|\(style.backgroundColor.red),\(style.backgroundColor.green),\(style.backgroundColor.blue),\(style.backgroundColor.alpha)"
    }

    /// Composite the keystroke-chip row over `base`. For each active
    /// chip (time within the style's display window), we render a
    /// rounded pill and fade it via a short in/out envelope. Chips are
    /// laid out left-to-right by original press time, so the newest
    /// appears on the right — matches how the on-screen keystrokes
    /// naturally read.
    private func applyKeystrokeOverlay(
        over base: CIImage,
        layout: State.Snapshot,
        time: CMTime,
        outputSize: CGSize
    ) -> CIImage {
        let style = layout.keystrokeOverlayStyle
        guard style.enabled, !layout.keystrokeChips.isEmpty else { return base }
        let now = CMTimeGetSeconds(time)
        guard now.isFinite else { return base }

        // Collect active chips (still inside their display lifetime).
        struct Active {
            let label: String
            let elapsed: TimeInterval
            let progress: Double   // 0..1 through lifetime
        }
        var active: [Active] = []
        for chip in layout.keystrokeChips {
            let elapsed = now - CMTimeGetSeconds(chip.time)
            guard elapsed >= 0, elapsed <= style.displayDuration else { continue }
            let progress = elapsed / max(style.displayDuration, 0.001)
            active.append(Active(label: chip.label, elapsed: elapsed, progress: progress))
        }
        guard !active.isEmpty else { return base }

        // Cap to the most recent `maxVisibleChips` (i.e. smallest
        // elapsed first). The cap is on the rendered count — older
        // ones still silently expire but we just don't place them.
        if active.count > style.maxVisibleChips {
            active.sort { $0.elapsed < $1.elapsed }
            active = Array(active.prefix(style.maxVisibleChips))
        }
        // Order-to-draw: oldest leftmost → newest rightmost.
        active.sort { $0.elapsed > $1.elapsed }

        // Derive rasterisation params. Font size is fraction of the
        // shorter canvas dimension — consistent across 16:9 / 4:3 /
        // vertical sources.
        let shortSide = min(outputSize.width, outputSize.height)
        let fontSize = max(12, shortSide * style.fontSizeFraction)
        let textColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let bgColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.72)

        // Flush cache if the sizing parameters moved; otherwise old
        // rasterisations at the old font size would linger.
        let sizingKey = "\(Int(outputSize.width))x\(Int(outputSize.height))|\(fontSize)"
        if sizingKey != cachedChipSizingKey {
            cachedChipImages.removeAll(keepingCapacity: true)
            cachedChipSizingKey = sizingKey
        }

        // Render (or fetch) each chip, accumulate composited frames.
        var composite = base
        let spacing: CGFloat = fontSize * 0.4
        var totalWidth: CGFloat = 0
        var rendered: [(image: CIImage, size: CGSize, opacity: CGFloat)] = []
        for a in active {
            let img: (image: CIImage, size: CGSize)
            if let cached = cachedChipImages[a.label] {
                img = cached
            } else {
                guard let new = KeystrokeChipRenderer.render(
                    label: a.label,
                    fontSize: fontSize,
                    textColor: textColor,
                    backgroundColor: bgColor
                ) else { continue }
                cachedChipImages[a.label] = new
                img = new
            }
            // Fade envelope: quick ease-in, long plateau, ease-out for
            // the last 25%. Opacity peaks at 1 for ~half the lifetime.
            let opacity: CGFloat
            if a.progress < 0.12 {
                opacity = CGFloat(a.progress / 0.12)
            } else if a.progress > 0.75 {
                opacity = CGFloat(1 - (a.progress - 0.75) / 0.25)
            } else {
                opacity = 1
            }
            rendered.append((img.image, img.size, opacity))
            totalWidth += img.size.width
        }
        guard !rendered.isEmpty else { return base }
        totalWidth += spacing * CGFloat(rendered.count - 1)

        // Bottom-center the row.
        let startX = (outputSize.width - totalWidth) / 2
        let y = style.bottomInsetFraction * outputSize.height
        var cursor = startX
        for item in rendered {
            if item.opacity > 0.001 {
                let positioned = item.image
                    .transformed(by: CGAffineTransform(translationX: cursor, y: y))
                let faded = item.opacity < 0.999
                    ? applyAlpha(item.opacity, to: positioned)
                    : positioned
                composite = faded.composited(over: composite)
            }
            cursor += item.size.width + spacing
        }
        return composite
    }

    private func applyTitleCards(
        over base: CIImage,
        layout: State.Snapshot,
        time: CMTime,
        outputSize: CGSize
    ) -> CIImage {
        var out = base
        let timeInOutput = layout.trimMap.outputTime(forSourceTime: time)
        let secs  = CMTimeGetSeconds(timeInOutput)
        let total = CMTimeGetSeconds(layout.trimMap.outputDuration)
        guard secs.isFinite else { return out }

        // ---- Start card: opacity 1 at t=0, decays to 0 at fadeDuration.
        if layout.startCard.enabled, layout.startCard.fadeDuration > 0, secs < layout.startCard.fadeDuration {
            let p = secs / max(layout.startCard.fadeDuration, 0.001)
            let opacity = 1.0 - ZoomKeyframe.easeInOutCubic(p)
            if opacity > 0.001,
               let cardImage = startCardImage(layout: layout, size: outputSize) {
                out = applyAlpha(CGFloat(opacity), to: cardImage).composited(over: out)
            }
        }

        // ---- End card: opacity 0 at t=duration-fadeDuration, ramps to 1 at duration.
        // Same trick as the webcam fade-out — compress the ramp so it
        // reaches full opacity `endMargin` before the actual end, since
        // the last rendered frame's PTS sits a fraction below `total`.
        if layout.endCard.enabled, layout.endCard.fadeDuration > 0,
           total > 0, secs > total - layout.endCard.fadeDuration {
            let fadeDur = layout.endCard.fadeDuration
            let effectiveDur = max(fadeDur - WebcamTransitions.endMargin, fadeDur * 0.5)
            let into = secs - (total - fadeDur)
            let p = min(1, into / effectiveDur)
            let opacity = ZoomKeyframe.easeInOutCubic(p)
            if opacity > 0.001,
               let cardImage = endCardImage(layout: layout, size: outputSize) {
                out = applyAlpha(CGFloat(opacity), to: cardImage).composited(over: out)
            }
        }

        return out
    }

    private func startCardImage(layout: State.Snapshot, size: CGSize) -> CIImage? {
        let key = layout.startCard.renderKey
        if let cached = cachedStartCardImage,
           cachedStartCardKey == key,
           cachedStartCardSize == size {
            return cached
        }
        let img = TitleCardRenderer.render(card: layout.startCard, size: size)
        cachedStartCardImage = img
        cachedStartCardKey = key
        cachedStartCardSize = size
        return img
    }

    private func endCardImage(layout: State.Snapshot, size: CGSize) -> CIImage? {
        let key = layout.endCard.renderKey
        if let cached = cachedEndCardImage,
           cachedEndCardKey == key,
           cachedEndCardSize == size {
            return cached
        }
        let img = TitleCardRenderer.render(card: layout.endCard, size: size)
        cachedEndCardImage = img
        cachedEndCardKey = key
        cachedEndCardSize = size
        return img
    }

    private func scaledToFill(_ image: CIImage, size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let s = max(size.width / extent.width, size.height / extent.height)
        return image.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }

    /// Apply the active zoom keyframe (if any) to the screen image.
    ///
    /// `target` is stored in source-screen pixels (bottom-left origin). For
    /// every capture source we currently support, the screen track is
    /// recorded at the composite output's pixel dimensions (`CaptureSource.
    /// pixelSize` is what we both write and render at), so source pixels
    /// map 1:1 to composite pixels — no mapping needed here. After scaling,
    /// crop back to `outputSize` so the canvas stays the expected size.
    private func applyZoom(
        to image: CIImage,
        layout: State.Snapshot,
        time: CMTime,
        outputSize: CGSize
    ) -> CIImage {
        guard let active = layout.zoomKeyframes.first(where: { $0.contains(time) }) else {
            return image
        }
        let scale = active.currentScale(at: time)
        if abs(scale - 1.0) < 0.001 { return image }

        // Affine that scales by `scale` around the fixed point `target`:
        //   t(p) = scale*p + target*(1 - scale)
        let s = scale
        let tx = active.target.x * (1 - s)
        let ty = active.target.y * (1 - s)
        let xform = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: tx, ty: ty)
        let zoomed = image.transformed(by: xform)
        return zoomed.cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    /// Origin for the webcam's bounding box at a given position + size.
    /// Factored out of the old `webcamOrigin(layout:outputSize:)` so the
    /// talking-head interpolator can pass an arbitrary diameter (not the
    /// snapshot's baseline).
    private func webcamCornerOrigin(
        position: WebcamPosition,
        diameter: CGFloat,
        inset: CGFloat,
        outputSize: CGSize
    ) -> CGPoint {
        // CIImage origin is bottom-left.
        switch position {
        case .bottomRight: return CGPoint(x: outputSize.width - diameter - inset, y: inset)
        case .bottomLeft:  return CGPoint(x: inset, y: inset)
        case .topRight:    return CGPoint(x: outputSize.width - diameter - inset, y: outputSize.height - diameter - inset)
        case .topLeft:     return CGPoint(x: inset, y: outputSize.height - diameter - inset)
        case .hidden:      return .zero
        }
    }

    /// Effective webcam geometry (diameter + origin in canvas-pixel
    /// space) for the current frame. When a talking-head keyframe is
    /// active, interpolates between the normal corner geometry and a
    /// centred, large-format target; otherwise returns the normal
    /// geometry unchanged.
    private func webcamGeometry(
        layout: State.Snapshot,
        time: CMTime,
        outputSize: CGSize
    ) -> (diameter: CGFloat, origin: CGPoint) {
        let normalDiameter = layout.diameter
        // Custom origin (from editor drag-to-reposition) overrides the
        // preset corner + inset math. Still clamp to the canvas so
        // a stale offset from a prior session with a different output
        // size can't push the webcam fully offscreen.
        let normalOrigin: CGPoint = {
            if let custom = layout.webcamCustomOrigin {
                let maxX = max(0, outputSize.width - normalDiameter)
                let maxY = max(0, outputSize.height - normalDiameter)
                return CGPoint(
                    x: min(max(0, custom.x), maxX),
                    y: min(max(0, custom.y), maxY)
                )
            }
            return webcamCornerOrigin(
                position: layout.position,
                diameter: normalDiameter,
                inset: layout.inset,
                outputSize: outputSize
            )
        }()

        guard let active = layout.talkingHeadKeyframes.first(where: { $0.contains(time) }) else {
            return (normalDiameter, normalOrigin)
        }

        let p = CGFloat(active.progress(at: time))
        let shortSide = min(outputSize.width, outputSize.height)
        let targetDiameter = max(16, shortSide * active.targetDiameterFraction)
        let effDiameter = normalDiameter + (targetDiameter - normalDiameter) * p
        // Target: centred bounding box — webcam fills the middle of the canvas.
        let targetOrigin = CGPoint(
            x: (outputSize.width - effDiameter) / 2,
            y: (outputSize.height - effDiameter) / 2
        )
        // Lerping origin + diameter independently produces the same
        // motion as lerping centre + diameter (the bounding box follows
        // both endpoints smoothly).
        let effOrigin = CGPoint(
            x: normalOrigin.x + (targetOrigin.x - normalOrigin.x) * p,
            y: normalOrigin.y + (targetOrigin.y - normalOrigin.y) * p
        )
        return (effDiameter, effOrigin)
    }

    private func buildWebcamImage(
        camera: CVPixelBuffer,
        shape: WebcamShape,
        diameter: CGFloat,
        backgroundStyle: WebcamBackgroundStyle
    ) -> CIImage? {
        let raw = CIImage(cvPixelBuffer: camera)
        let extent = raw.extent
        let side = min(extent.width, extent.height)
        guard side > 0, diameter > 0 else { return nil }

        let cropX = (extent.width - side) / 2
        let cropY = (extent.height - side) / 2
        let cropped = raw
            .cropped(to: CGRect(x: cropX, y: cropY, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))

        // Person-segmentation pass happens BEFORE the scale-to-diameter
        // step. Running segmentation on the native webcam resolution
        // gives the cleanest mask; scaling afterwards is a cheap
        // bilinear resample. Uses Vision (`VNGeneratePersonSegmentation-
        // Request`) on macOS — CIPersonSegmentation returns an empty
        // mask on macOS and effectively blurs the whole frame.
        let processed: CIImage
        if backgroundStyle.mode != .off {
            processed = WebcamBackgroundProcessor.apply(to: cropped, style: backgroundStyle)
        } else {
            processed = cropped
        }

        let scale = diameter / side
        let scaled = processed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Mirror horizontally for natural self-view (matches recorded composite).
        let mirrored = scaled
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: diameter, y: 0))

        let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        // Skip the shape-mask pass entirely when the user picked
        // "No Shape" — the webcam's own alpha (for transparent bg
        // mode) carries through untouched, giving a free-floating
        // silhouette. For Circle / RoundedSquare we fall back to the
        // standard luminance-mask clip.
        guard shape != .none else {
            return mirrored.cropped(to: bounds)
        }
        let mask = maskImage(shape: shape, diameter: diameter)
        let background = CIImage(color: CIColor.clear).cropped(to: bounds)
        // Use luminance-based mask (matches FrameCompositor); our mask has no
        // alpha channel, so `CIBlendWithAlphaMask` renders the webcam as a
        // plain rectangle with no shape.
        return mirrored.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask
        ]).cropped(to: bounds)
    }

    private func maskImage(shape: WebcamShape, diameter: CGFloat) -> CIImage {
        if let cached = cachedMaskImage,
           cachedMaskShape == shape,
           cachedMaskDiameter == diameter {
            return cached
        }
        let img = Self.makeShapeMask(shape: shape, diameter: diameter)
        cachedMaskShape = shape
        cachedMaskDiameter = diameter
        cachedMaskImage = img
        return img
    }

    private static func makeShapeMask(shape: WebcamShape, diameter: CGFloat) -> CIImage {
        let size = max(1, Int(diameter))
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return CIImage.empty()
        }
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(rect)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(shape.path(in: rect))
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg)
    }

    // MARK: - Instruction

    /// Custom instruction conforming to `AVVideoCompositionInstructionProtocol`.
    /// Subclassing `AVVideoCompositionInstruction` directly caused AVFoundation
    /// to treat the instruction as invalid and skip rendering (compositor
    /// instantiated + render context set, but `startRequest` never called).
    ///
    /// Holds a strong reference to the composition's `State`, which the
    /// compositor reads per frame. AVFoundation retains the instruction
    /// for the lifetime of the video composition, so the state lives as
    /// long as its composition does.
    final class Instruction: NSObject, AVVideoCompositionInstructionProtocol {
        let timeRange: CMTimeRange
        let enablePostProcessing: Bool = false
        let containsTweening: Bool = false
        let requiredSourceTrackIDs: [NSValue]?
        let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

        let screenTrackID: CMPersistentTrackID
        let webcamTrackID: CMPersistentTrackID
        let state: State

        init(
            timeRange: CMTimeRange,
            screenTrackID: CMPersistentTrackID,
            webcamTrackID: CMPersistentTrackID,
            state: State
        ) {
            self.timeRange = timeRange
            self.screenTrackID = screenTrackID
            self.webcamTrackID = webcamTrackID
            self.state = state
            var ids: [NSValue] = [NSNumber(value: screenTrackID)]
            if webcamTrackID != kCMPersistentTrackID_Invalid {
                ids.append(NSNumber(value: webcamTrackID))
            }
            self.requiredSourceTrackIDs = ids
            super.init()
        }
    }
}

