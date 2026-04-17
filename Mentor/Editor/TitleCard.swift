import AppKit
import CoreImage
import CoreText
import CoreGraphics
import Foundation
import SwiftUI

/// Configuration for a fading title card displayed at the start or end of
/// a recording. Cards aren't part of the captured `.mentor` bundle —
/// they're set in the editor and baked into the export.
struct TitleCard: Equatable, Codable, Sendable {
    enum Position: Sendable { case start, end }

    var enabled: Bool
    var title: String
    var subtitle: String
    var textColor: ColorRGBA
    var backgroundColor: ColorRGBA
    /// Length of the cross-fade between card and recording, in seconds.
    var fadeDuration: TimeInterval

    static let defaultStart = TitleCard(
        enabled: false,
        title: "Untitled",
        subtitle: "",
        textColor: .white,
        backgroundColor: ColorRGBA(red: 0.07, green: 0.07, blue: 0.10, alpha: 1.0),
        fadeDuration: 2.0
    )

    static let defaultEnd = TitleCard(
        enabled: false,
        title: "Thanks for watching",
        subtitle: "",
        textColor: .white,
        backgroundColor: ColorRGBA(red: 0.07, green: 0.07, blue: 0.10, alpha: 1.0),
        fadeDuration: 2.0
    )

    /// Hash that ignores `enabled` + `fadeDuration` (those don't affect the
    /// rendered image, only its visibility/opacity envelope). Used by the
    /// compositor's CIImage cache to know when to re-render.
    var renderKey: Int {
        var hasher = Hasher()
        hasher.combine(title)
        hasher.combine(subtitle)
        hasher.combine(textColor)
        hasher.combine(backgroundColor)
        return hasher.finalize()
    }
}

/// Codable / Sendable color for storing in compositor state. Has helpers
/// to bridge to CGColor (renderer) and SwiftUI Color (inspector picker).
struct ColorRGBA: Equatable, Hashable, Codable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    static let white = ColorRGBA(red: 1, green: 1, blue: 1)
    static let black = ColorRGBA(red: 0, green: 0, blue: 0)

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// SwiftUI `Color` for binding into ColorPicker.
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// Round-trip through `NSColor.sRGB` so we extract correct sRGB
    /// components — `Color`'s direct accessors aren't reliable across
    /// catalog colors / system colors.
    init(swiftUI color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.red   = Double(ns.redComponent)
        self.green = Double(ns.greenComponent)
        self.blue  = Double(ns.blueComponent)
        self.alpha = Double(ns.alphaComponent)
    }
}

/// Renders a `TitleCard` to a CIImage at the given output size. Pure
/// Core Text on a CGContext; result is cached upstream by the compositor.
enum TitleCardRenderer {
    /// Render `card` filling `size`, with title centred horizontally +
    /// vertically, optional subtitle below it. Output is sRGB, premultiplied.
    static func render(card: TitleCard, size: CGSize) -> CIImage? {
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // 1. Fill background.
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(card.backgroundColor.cgColor)
        ctx.fill(bounds)

        // 2. Compose attributed strings. Sizes scale with canvas height so
        // a 4K render and a 1080p render both look proportionally right.
        let titleSize = max(36, size.height * 0.085)
        let subtitleSize = max(20, size.height * 0.04)
        let lineSpacing: CGFloat = size.height * 0.02

        let title = makeAttributedString(
            text: card.title,
            font: NSFont.systemFont(ofSize: titleSize, weight: .bold),
            color: card.textColor.cgColor
        )
        let subtitle = card.subtitle.isEmpty ? nil : makeAttributedString(
            text: card.subtitle,
            font: NSFont.systemFont(ofSize: subtitleSize, weight: .regular),
            color: ColorRGBA(
                red: card.textColor.red,
                green: card.textColor.green,
                blue: card.textColor.blue,
                alpha: card.textColor.alpha * 0.75
            ).cgColor
        )

        // 3. Measure each line so we can vertically centre the block.
        let textMaxWidth = CGFloat(w) * 0.85
        let titleHeight = measureBlockHeight(text: title, maxWidth: textMaxWidth)
        let subHeight   = subtitle.map { measureBlockHeight(text: $0, maxWidth: textMaxWidth) } ?? 0
        let totalHeight = titleHeight + (subtitle != nil ? lineSpacing + subHeight : 0)

        // 4. Draw — Core Text uses bottom-up coords like CIImage, so y
        // grows up. Block sits centred vertically.
        let blockTop = (CGFloat(h) + totalHeight) / 2
        var cursorY = blockTop - titleHeight
        let textRect = CGRect(
            x: (CGFloat(w) - textMaxWidth) / 2,
            y: cursorY,
            width: textMaxWidth,
            height: titleHeight
        )
        drawAttributedBlock(text: title, in: textRect, ctx: ctx)

        if let subtitle {
            cursorY -= (lineSpacing + subHeight)
            let subRect = CGRect(
                x: (CGFloat(w) - textMaxWidth) / 2,
                y: cursorY,
                width: textMaxWidth,
                height: subHeight
            )
            drawAttributedBlock(text: subtitle, in: subRect, ctx: ctx)
        }

        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    private static func makeAttributedString(
        text: String,
        font: NSFont,
        color: CGColor
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ])
    }

    private static func measureBlockHeight(text: NSAttributedString, maxWidth: CGFloat) -> CGFloat {
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            nil
        )
        // Add a small padding so descenders don't get clipped.
        return ceil(suggested.height) + 4
    }

    private static func drawAttributedBlock(
        text: NSAttributedString,
        in rect: CGRect,
        ctx: CGContext
    ) {
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        CTFrameDraw(frame, ctx)
    }
}
