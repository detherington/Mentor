import AppKit
import CoreImage
import CoreText
import CoreGraphics
import Foundation

/// Styling for the burned-in subtitle strip. Persisted via `Settings`
/// so the user's preferred look survives across recordings.
struct CaptionStyle: Equatable, Codable, Sendable {
    /// If false, captions don't render even when a `TranscriptionLog`
    /// exists in the project.
    var enabled: Bool
    /// Font size as a fraction of the canvas's shorter dimension —
    /// keeps captions proportional across 720p and 4K exports.
    var fontSizeFraction: Double
    var textColor: ColorRGBA
    var backgroundColor: ColorRGBA
    /// Distance from the bottom of the canvas to the caption's bottom
    /// edge, as a fraction of canvas height.
    var bottomInsetFraction: Double

    static let `default` = CaptionStyle(
        enabled: true,
        fontSizeFraction: 0.045,
        textColor: .white,
        backgroundColor: ColorRGBA(red: 0, green: 0, blue: 0, alpha: 0.65),
        bottomInsetFraction: 0.06
    )
}

/// Renders a single subtitle line to a CIImage the size of the full
/// canvas. The line is horizontally centred and sits `bottomInset`
/// points above the canvas bottom, on a rounded-rect pill sized to the
/// text. The compositor caches the result keyed on (text, style, size).
enum CaptionRenderer {
    static func render(
        text: String,
        style: CaptionStyle,
        canvasSize: CGSize
    ) -> CIImage? {
        let w = max(1, Int(canvasSize.width))
        let h = max(1, Int(canvasSize.height))
        let shortSide = min(canvasSize.width, canvasSize.height)
        let fontSize = max(12, shortSide * CGFloat(style.fontSizeFraction))
        let maxTextWidth = canvasSize.width * 0.85
        let bottomInset = canvasSize.height * CGFloat(style.bottomInsetFraction)
        let pillPadding = CGSize(width: fontSize * 0.7, height: fontSize * 0.3)
        let pillCornerRadius = fontSize * 0.4

        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: style.textColor.cgColor,
            .paragraphStyle: {
                let p = NSMutableParagraphStyle()
                p.alignment = .center
                p.lineBreakMode = .byWordWrapping
                return p
            }()
        ])

        // Measure wrapping block height given the max width.
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let textBounds = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            nil
        )
        let textSize = CGSize(width: ceil(textBounds.width), height: ceil(textBounds.height))
        // Guard against zero-height text blocks (empty string edge case).
        guard textSize.height > 0 else { return nil }

        let pillSize = CGSize(
            width: min(maxTextWidth, textSize.width) + pillPadding.width * 2,
            height: textSize.height + pillPadding.height * 2
        )
        let pillRect = CGRect(
            x: (canvasSize.width - pillSize.width) / 2,
            y: bottomInset,
            width: pillSize.width,
            height: pillSize.height
        )
        let textRect = CGRect(
            x: pillRect.minX + pillPadding.width,
            y: pillRect.minY + pillPadding.height,
            width: pillSize.width - pillPadding.width * 2,
            height: textSize.height
        )

        // Transparent canvas-sized bitmap; only the pill + text have ink.
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

        // Pill background.
        ctx.setFillColor(style.backgroundColor.cgColor)
        let pillPath = CGPath(
            roundedRect: pillRect,
            cornerWidth: pillCornerRadius,
            cornerHeight: pillCornerRadius,
            transform: nil
        )
        ctx.addPath(pillPath)
        ctx.fillPath()

        // Text — CTFrameDraw uses the context's bottom-left origin, so
        // textRect works directly without flipping.
        let framePath = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), framePath, nil)
        CTFrameDraw(frame, ctx)

        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}
