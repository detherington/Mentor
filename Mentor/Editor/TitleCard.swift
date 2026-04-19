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
    /// Font family name for the title + subtitle. Nil = macOS system
    /// font (SF Pro Display). Picking a family here replaces the
    /// typeface wholesale; weight logic (bold title / regular
    /// subtitle) is preserved via `NSFontManager`.
    var fontName: String?
    /// Filename (not a full path) of a user-chosen background image
    /// living under `TitleCardAssets.directory`. When non-nil and
    /// the file exists, the renderer aspect-fills this image over
    /// `backgroundColor`. Otherwise the solid colour wins.
    var backgroundImageFilename: String?

    static let defaultStart = TitleCard(
        enabled: false,
        title: "Untitled",
        subtitle: "",
        textColor: .white,
        backgroundColor: ColorRGBA(red: 0.07, green: 0.07, blue: 0.10, alpha: 1.0),
        fadeDuration: 2.0,
        fontName: nil,
        backgroundImageFilename: nil
    )

    static let defaultEnd = TitleCard(
        enabled: false,
        title: "Thanks for watching",
        subtitle: "",
        textColor: .white,
        backgroundColor: ColorRGBA(red: 0.07, green: 0.07, blue: 0.10, alpha: 1.0),
        fadeDuration: 2.0,
        fontName: nil,
        backgroundImageFilename: nil
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
        hasher.combine(fontName)
        hasher.combine(backgroundImageFilename)
        return hasher.finalize()
    }

    // MARK: - Codable with backward compatibility

    private enum CodingKeys: String, CodingKey {
        case enabled, title, subtitle, textColor, backgroundColor, fadeDuration
        case fontName, backgroundImageFilename
    }

    init(
        enabled: Bool,
        title: String,
        subtitle: String,
        textColor: ColorRGBA,
        backgroundColor: ColorRGBA,
        fadeDuration: TimeInterval,
        fontName: String? = nil,
        backgroundImageFilename: String? = nil
    ) {
        self.enabled = enabled
        self.title = title
        self.subtitle = subtitle
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.fadeDuration = fadeDuration
        self.fontName = fontName
        self.backgroundImageFilename = backgroundImageFilename
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled        = try c.decode(Bool.self,           forKey: .enabled)
        self.title          = try c.decode(String.self,         forKey: .title)
        self.subtitle       = try c.decode(String.self,         forKey: .subtitle)
        self.textColor      = try c.decode(ColorRGBA.self,      forKey: .textColor)
        self.backgroundColor = try c.decode(ColorRGBA.self,     forKey: .backgroundColor)
        self.fadeDuration   = try c.decode(TimeInterval.self,   forKey: .fadeDuration)
        // Both added post-v1.0.6. Absent fields map to "system
        // default font, no background image" so old saved cards
        // keep looking exactly the way the user left them.
        self.fontName               = try c.decodeIfPresent(String.self, forKey: .fontName)
        self.backgroundImageFilename = try c.decodeIfPresent(String.self, forKey: .backgroundImageFilename)
    }
}

// MARK: - System font catalog

/// Curated list of families that make good title-card fonts on
/// macOS. Stored as family names so the renderer can ask
/// NSFontManager for bold/regular variants at draw time. `name == nil`
/// represents the OS-default system font (SF Pro Display).
enum TitleCardFont {
    struct Option: Identifiable, Hashable {
        /// Nil → use the built-in `NSFont.systemFont(ofSize:weight:)`
        /// which tracks whichever system typeface the running macOS
        /// picks. All other values are PostScript family names
        /// passed to `NSFontManager`.
        let familyName: String?
        /// Display label shown in the inspector picker.
        let label: String
        var id: String { familyName ?? "<system>" }
    }

    /// Options are ordered by how commonly they're used on title
    /// cards — system first, then sans, then serif, then mono.
    static let options: [Option] = [
        Option(familyName: nil,                  label: "System"),
        Option(familyName: "Helvetica Neue",     label: "Helvetica Neue"),
        Option(familyName: "Avenir Next",        label: "Avenir Next"),
        Option(familyName: "Futura",             label: "Futura"),
        Option(familyName: "Gill Sans",          label: "Gill Sans"),
        Option(familyName: "Optima",             label: "Optima"),
        Option(familyName: "Georgia",            label: "Georgia"),
        Option(familyName: "Times New Roman",    label: "Times New Roman"),
        Option(familyName: "New York",           label: "New York (Serif)"),
        Option(familyName: "Baskerville",        label: "Baskerville"),
        Option(familyName: "Menlo",              label: "Menlo (Mono)"),
        Option(familyName: "Courier New",        label: "Courier New"),
    ]

    /// Build the title NSFont (bold) for a given family name + size.
    /// Falls back to the system font if the family isn't available
    /// on this machine — keeps cards renderable even if the user
    /// ships settings between Macs that have different font sets.
    static func titleFont(name: String?, size: CGFloat) -> NSFont {
        guard let name else { return .systemFont(ofSize: size, weight: .bold) }
        // New York is a system design variant — not a normal family
        // lookup. Resolve via NSFontDescriptor's `.withDesign(.serif)`.
        if name == "New York" {
            let base = NSFont.systemFont(ofSize: size, weight: .bold)
            if let serifDescriptor = base.fontDescriptor.withDesign(.serif),
               let font = NSFont(descriptor: serifDescriptor, size: size) {
                return font
            }
            return base
        }
        if let bold = NSFontManager.shared.font(
            withFamily: name,
            traits: .boldFontMask,
            weight: 5,
            size: size
        ) {
            return bold
        }
        return .systemFont(ofSize: size, weight: .bold)
    }

    /// Build the subtitle NSFont (regular weight). Matches the
    /// family chosen for the title; subtitle weight is always
    /// regular so the title has visual priority.
    static func subtitleFont(name: String?, size: CGFloat) -> NSFont {
        guard let name else { return .systemFont(ofSize: size, weight: .regular) }
        if name == "New York" {
            let base = NSFont.systemFont(ofSize: size, weight: .regular)
            if let serifDescriptor = base.fontDescriptor.withDesign(.serif),
               let font = NSFont(descriptor: serifDescriptor, size: size) {
                return font
            }
            return base
        }
        if let regular = NSFontManager.shared.font(
            withFamily: name,
            traits: [],
            weight: 5,
            size: size
        ) {
            return regular
        }
        return .systemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - System font-panel bridge

/// Bridges SwiftUI's title-card font picker to the full macOS
/// `NSFontPanel`. Needed because the panel uses the responder-chain
/// `changeFont(_:)` pattern, which SwiftUI alone can't satisfy — we
/// need an `@objc`-visible target that receives the message and
/// forwards the newly-selected family name to the caller.
///
/// Singleton because the font panel is a process-wide resource and
/// `NSFontManager.shared.target` only accepts one target at a time.
/// Each `present(...)` call overwrites the previous callback, so a
/// second card editor opening the panel simply takes over.
@MainActor
final class TitleCardFontPanelBridge: NSObject {
    static let shared = TitleCardFontPanelBridge()

    /// Reference font for the current session. Passed to
    /// `NSFontManager.convert(_:)` on each `changeFont` so the manager
    /// can apply the user's selection on top of it. Starts as the
    /// card's current family, updated on each change so back-to-back
    /// family + weight tweaks compound instead of resetting.
    private var referenceFont: NSFont = .systemFont(ofSize: 24)
    private var onPicked: ((String) -> Void)?

    /// Open (or raise) the system font panel. Current `familyName`
    /// pre-selects the matching row in the panel's typeface list.
    /// `onPicked` fires every time the user changes the selection
    /// — modeless, so the user can browse and the card updates live.
    func present(currentFamily familyName: String?, onPicked: @escaping (String) -> Void) {
        self.onPicked = onPicked
        if let familyName {
            self.referenceFont = NSFontManager.shared.font(
                withFamily: familyName,
                traits: .boldFontMask,
                weight: 5,
                size: 24
            ) ?? .systemFont(ofSize: 24, weight: .bold)
        } else {
            self.referenceFont = .systemFont(ofSize: 24, weight: .bold)
        }
        NSFontManager.shared.target = self
        NSFontManager.shared.setSelectedFont(referenceFont, isMultiple: false)
        NSApp.activate(ignoringOtherApps: true)
        NSFontPanel.shared.makeKeyAndOrderFront(nil)
    }

    @objc func changeFont(_ sender: Any?) {
        let manager = NSFontManager.shared
        let newFont = manager.convert(referenceFont)
        referenceFont = newFont
        let family = newFont.familyName ?? newFont.fontName
        onPicked?(family)
    }

    /// Restrict the panel to the parts relevant for a card — font
    /// family, face (weight), and size preview. Hides effects,
    /// colour, and shadow controls that don't map to our renderer.
    @objc func validModesForFontPanel(_ fontPanel: NSFontPanel) -> Int {
        return Int(
            NSFontPanel.ModeMask.collection.rawValue
            | NSFontPanel.ModeMask.face.rawValue
            | NSFontPanel.ModeMask.size.rawValue
        )
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

        // 1. Fill background. Solid colour is always drawn first so
        // transparent / non-filling images composite over a known
        // backdrop instead of whatever colour the CGContext happened
        // to start with.
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(card.backgroundColor.cgColor)
        ctx.fill(bounds)

        // 1a. Optional background image — aspect-fill over the whole
        // card. Missing / unreadable files silently fall through to
        // the solid colour we already drew, so a deleted image file
        // doesn't produce a blank card.
        if let filename = card.backgroundImageFilename,
           !filename.isEmpty,
           let image = NSImage(contentsOf: TitleCardAssets.url(for: filename)),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let imgW = CGFloat(cg.width)
            let imgH = CGFloat(cg.height)
            let outW = CGFloat(w)
            let outH = CGFloat(h)
            // Aspect-fill: scale so the image covers the canvas,
            // crop whichever axis overflows.
            let scale = max(outW / imgW, outH / imgH)
            let drawW = imgW * scale
            let drawH = imgH * scale
            let dx = (outW - drawW) / 2
            let dy = (outH - drawH) / 2
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: dx, y: dy, width: drawW, height: drawH))
            ctx.restoreGState()
        }

        // 2. Compose attributed strings. Sizes scale with canvas height so
        // a 4K render and a 1080p render both look proportionally right.
        let titleSize = max(36, size.height * 0.085)
        let subtitleSize = max(20, size.height * 0.04)
        let lineSpacing: CGFloat = size.height * 0.02

        let title = makeAttributedString(
            text: card.title,
            font: TitleCardFont.titleFont(name: card.fontName, size: titleSize),
            color: card.textColor.cgColor
        )
        let subtitle = card.subtitle.isEmpty ? nil : makeAttributedString(
            text: card.subtitle,
            font: TitleCardFont.subtitleFont(name: card.fontName, size: subtitleSize),
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
