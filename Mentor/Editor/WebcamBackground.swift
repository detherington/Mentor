import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Vision

/// Processing mode for the webcam's background. Person segmentation
/// comes from Core Image's built-in `CIPersonSegmentation` filter,
/// which returns a per-pixel mask (person=1, background=0). The
/// compositor uses that mask to keep the subject sharp while replacing
/// or blurring whatever's behind them.
enum WebcamBackgroundMode: String, Codable, Equatable, CaseIterable, Identifiable {
    /// Pass-through — no segmentation, compositor uses the raw webcam
    /// frame (current default behaviour).
    case off
    /// Gaussian-blur the background; person stays sharp.
    case blur
    /// Replace background with a solid colour; person stays sharp.
    case color
    /// Make the background transparent so the screen recording shows
    /// through — the webcam becomes a silhouette of the subject
    /// inside the configured shape.
    case transparent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:         return "Off"
        case .blur:        return "Blur"
        case .color:       return "Color"
        case .transparent: return "Transparent"
        }
    }
}

/// Persisted styling for the webcam background effect. Separated from
/// `WebcamBackgroundMode` so the user can toggle between modes and
/// keep their preferred parameters for each.
struct WebcamBackgroundStyle: Codable, Equatable, Sendable {
    var mode: WebcamBackgroundMode
    /// Gaussian blur sigma in webcam pixels. Values above ~25 read as
    /// "fully blurred"; below ~8 the background is still recognisable.
    var blurRadius: CGFloat
    /// Replacement colour when `mode == .color`. Stored in sRGB.
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    /// Core Image segmentation quality: 0 = accurate, 1 = balanced,
    /// 2 = fast. `fast` runs well at real-time preview on Apple
    /// Silicon; higher quality is noticeably slower but cleaner on
    /// hair edges / busy backgrounds. Persisted so users who prefer
    /// the slower-but-cleaner pass get it on every reopen.
    var qualityLevel: Int

    static let `default` = WebcamBackgroundStyle(
        mode: .off,
        blurRadius: 18,
        red: 0.08,
        green: 0.12,
        blue: 0.18,
        qualityLevel: 2
    )
}

/// Vision-backed processor that applies the configured background
/// effect to a webcam CIImage. Caller passes the *pre-mirror* square-
/// cropped webcam image; returns the same geometry with the background
/// effect applied. Mirror + shape-mask happen in the compositor as
/// before.
///
/// # Why Vision + not CIPersonSegmentation
///
/// Core Image exposes `CIPersonSegmentation` on all platforms but the
/// macOS implementation returns an empty mask — segmenting here makes
/// the whole frame read as "background" and the entire webcam gets
/// blurred/replaced. `VNGeneratePersonSegmentationRequest` is the
/// supported on-device path on macOS and produces a real mask.
enum WebcamBackgroundProcessor {
    /// Returns the processed image, or the input unchanged when
    /// segmentation is off / fails. Never throws — if anything goes
    /// wrong we silently pass-through so the webcam overlay still
    /// renders (degraded rather than missing).
    static func apply(
        to image: CIImage,
        style: WebcamBackgroundStyle
    ) -> CIImage {
        guard style.mode != .off else { return image }
        guard let mask = personMask(for: image, quality: style.qualityLevel) else {
            // Segmentation failed — pass the frame through. Better
            // than silently rendering a fully-blurred frame (the
            // CIPersonSegmentation failure mode we just fixed).
            return image
        }

        // Build the background layer based on the selected mode.
        let background: CIImage
        switch style.mode {
        case .blur:
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image
            blur.radius = Float(max(1, style.blurRadius))
            // GaussianBlur extends the extent; re-crop to the original
            // so composited size stays square + aligned.
            background = (blur.outputImage ?? image).cropped(to: image.extent)
        case .color:
            background = CIImage(color: CIColor(
                red: style.red,
                green: style.green,
                blue: style.blue,
                alpha: 1.0
            )).cropped(to: image.extent)
        case .transparent:
            // Fully-clear background so the compositor's layers below
            // the webcam (i.e. the screen track) read through. The
            // downstream circle-shape mask still applies, so the user
            // sees a shape-clipped silhouette of the subject.
            background = CIImage(color: CIColor.clear).cropped(to: image.extent)
        case .off:
            return image
        }

        // Scale the mask (Vision returns a reduced-resolution mask) up
        // to match the input image extent. Use Lanczos for a clean
        // edge; the mask's inherent softness hides sub-pixel artefacts.
        let maskExtent = mask.extent
        guard maskExtent.width > 0, maskExtent.height > 0 else { return image }
        let sx = image.extent.width / maskExtent.width
        let sy = image.extent.height / maskExtent.height
        let scaledMask = mask
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: image.extent)

        // CIBlendWithMask: where the mask is white the foreground wins;
        // where it's black the background wins. Vision's mask is
        // person=1, background=0 → input image (sharp webcam of the
        // person) stays, background gets the blur/color.
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = background
        blend.maskImage = scaledMask
        let blended = blend.outputImage ?? image
        return blended.cropped(to: image.extent)
    }

    /// Run `VNGeneratePersonSegmentationRequest` synchronously on the
    /// given image and return a CIImage wrapping the mask pixel
    /// buffer. Returns nil on any Vision failure.
    private static func personMask(for image: CIImage, quality: Int) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        // Vision's quality tiers — map our int (same semantics as the
        // old CIFilter field so user settings persist cleanly):
        //   0 = accurate (slowest, cleanest hair edges)
        //   1 = balanced
        //   2 = fast (real-time preview friendly)
        switch quality {
        case 0: request.qualityLevel = .accurate
        case 1: request.qualityLevel = .balanced
        default: request.qualityLevel = .fast
        }
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let pixelBuffer = request.results?.first?.pixelBuffer else {
            return nil
        }
        return CIImage(cvPixelBuffer: pixelBuffer)
    }
}
