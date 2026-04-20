import AppKit
import CoreImage
import CoreVideo
import Metal
import QuartzCore

/// Circular floating webcam preview.
///
/// Renders camera frames through Core Image using the same viewport math as
/// the compositor, then displays the result via `CALayer.contents`. This
/// guarantees the preview matches the recording exactly (WYSIWYG) and
/// sidesteps AVCaptureVideoPreviewLayer's Metal-backed mask quirks — a
/// plain CALayer with `cornerRadius` + `masksToBounds` clips cleanly.
final class WebcamPreviewWindow: NSPanel {
    private let contentsLayer = CALayer()
    private let borderLayer = CAShapeLayer()

    private let ciContext: CIContext
    private let renderQueue = DispatchQueue(
        label: "com.darrell.mentor.preview-render",
        qos: .userInteractive
    )

    private let renderingLock = NSLock()
    private var isRendering = false

    private let stateLock = NSLock()
    private var diameter: CGFloat
    private var shape: WebcamShape
    private var sourceMinDimPixels: CGFloat
    private var backingScale: CGFloat = 2.0

    init(diameter: CGFloat, shape: WebcamShape, sourceMinDimPixels: CGFloat) {
        self.diameter = diameter
        self.shape = shape
        self.sourceMinDimPixels = sourceMinDimPixels

        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            self.ciContext = CIContext(options: [
                .useSoftwareRenderer: false,
                .cacheIntermediates: false
            ])
        }

        let initial = NSRect(x: 80, y: 80, width: diameter, height: diameter)
        super.init(
            contentRect: initial,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        // Layer-backed view (let AppKit manage the root layer); add our
        // sublayers to it. Layer-hosting mode was preventing the contents
        // from rendering inside the NSPanel.
        let container = NSView(frame: NSRect(origin: .zero, size: initial.size))
        container.wantsLayer = true
        contentView = container

        let scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        backingScale = scale

        contentsLayer.masksToBounds = true
        contentsLayer.backgroundColor = NSColor.black.cgColor
        contentsLayer.contentsGravity = .resize
        contentsLayer.contentsScale = scale

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        borderLayer.lineWidth = 3
        borderLayer.contentsScale = scale

        container.layer?.addSublayer(contentsLayer)
        container.layer?.addSublayer(borderLayer)

        updateLayout()
    }

    func apply(diameter: CGFloat, shape: WebcamShape, sourceMinDimPixels: CGFloat) {
        let scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        stateLock.lock()
        self.diameter = diameter
        self.shape = shape
        self.sourceMinDimPixels = sourceMinDimPixels
        self.backingScale = scale
        stateLock.unlock()

        let origin = frame.origin
        let newFrame = NSRect(x: origin.x, y: origin.y, width: diameter, height: diameter)
        setFrame(newFrame, display: true)
        contentView?.frame = NSRect(origin: .zero, size: newFrame.size)

        updateLayout()
    }

    private func updateLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        // Don't touch contentView.layer.frame — layer-backed AppKit owns it.

        contentsLayer.frame = bounds
        contentsLayer.cornerRadius = shape.cornerRadius(forSide: diameter)
        contentsLayer.contentsScale = backingScale

        borderLayer.frame = bounds
        borderLayer.contentsScale = backingScale
        let inset = borderLayer.lineWidth / 2
        borderLayer.path = shape.path(in: bounds.insetBy(dx: inset, dy: inset))
    }

    /// Feed a camera frame to the preview. Thread-safe — safe to call from
    /// the camera capture queue.
    func update(with pixelBuffer: CVPixelBuffer) {
        // Coalesce: drop this frame if a render is already in flight.
        renderingLock.lock()
        if isRendering {
            renderingLock.unlock()
            return
        }
        isRendering = true
        renderingLock.unlock()

        stateLock.lock()
        let diameterPt = self.diameter
        let sourceMinPx = self.sourceMinDimPixels
        let scale = self.backingScale
        stateLock.unlock()

        let diameterPx = diameterPt * scale

        renderQueue.async { [weak self] in
            defer {
                self?.renderingLock.lock()
                self?.isRendering = false
                self?.renderingLock.unlock()
            }
            guard let self else { return }
            guard let cgImage = self.renderCGImage(
                from: pixelBuffer,
                diameterPx: diameterPx,
                sourceMinPx: sourceMinPx
            ) else { return }

            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.contentsLayer.contents = cgImage
                CATransaction.commit()
            }
        }
    }

    /// Drop the currently-displayed frame and reveal the black backing
    /// layer. Called when the camera is disconnected so the preview
    /// doesn't sit on a stale freeze-frame.
    func clear() {
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.contentsLayer.contents = nil
            CATransaction.commit()
        }
    }

    private func renderCGImage(
        from pixelBuffer: CVPixelBuffer,
        diameterPx: CGFloat,
        sourceMinPx: CGFloat
    ) -> CGImage? {
        let raw = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = raw.extent
        let side = min(extent.width, extent.height)
        guard side > 0, diameterPx > 0 else { return nil }

        // Matches FrameCompositor: square center-crop of the full source
        // short side, scaled to fill the circle. Gives natural head-and-
        // shoulders framing at default sizes.
        let cropX = (extent.width - side) / 2
        let cropY = (extent.height - side) / 2
        let cropped = raw
            .cropped(to: CGRect(x: cropX, y: cropY, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))

        let scale = diameterPx / side
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Mirror horizontally so the preview reads as a mirror (matches the
        // compositor's baked-in mirroring for the recording).
        let mirrored = scaled
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: diameterPx, y: 0))

        let outputRect = CGRect(x: 0, y: 0, width: diameterPx, height: diameterPx)
        return ciContext.createCGImage(mirrored, from: outputRect)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
