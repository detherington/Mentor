import CoreMedia
import CoreGraphics
import CoreText
import CoreImage
import AppKit
import Foundation

/// One renderable keystroke event. Pre-grouped into a single displayable
/// label (e.g. "⌘K", "Space", "↩") by `KeystrokeOverlayGenerator` so the
/// compositor doesn't have to reinterpret raw key codes per frame.
struct KeystrokeChip: Identifiable, Equatable, Sendable {
    let id: UUID
    let time: CMTime
    let label: String

    init(id: UUID = UUID(), time: CMTime, label: String) {
        self.id = id
        self.time = time
        self.label = label
    }
}

/// Styling + behaviour of the keystroke overlay. Persisted via Settings
/// alongside the caption style.
struct KeystrokeOverlayStyle: Codable, Equatable, Sendable {
    /// Master on/off.
    var enabled: Bool
    /// Lifetime of a single chip (seconds). 1.2 s reads comfortably
    /// without overlapping the typical quick succession of a combo like
    /// ⌘S then ⌘Enter.
    var displayDuration: TimeInterval
    /// Font size as a fraction of the canvas's shorter dimension.
    /// 0.028 at 2338 ≈ 65 px — reads clearly against a dense UI without
    /// dominating the frame.
    var fontSizeFraction: CGFloat
    /// Vertical position — distance from the bottom, as a fraction of
    /// canvas height. 0.12 clears both a typical macOS Dock and caption
    /// chips rendered at their default 0.06 inset.
    var bottomInsetFraction: CGFloat
    /// Show plain letter/number/symbol keys too. Off by default because
    /// tutorial overlays usually only want modifier combos + special
    /// keys — stripping plain typing keeps the overlay readable.
    var showPlainKeys: Bool
    /// Maximum chips to render simultaneously. Older ones fade earlier
    /// than `displayDuration` if this cap is exceeded.
    var maxVisibleChips: Int

    static let `default` = KeystrokeOverlayStyle(
        enabled: false,
        displayDuration: 1.2,
        fontSizeFraction: 0.028,
        bottomInsetFraction: 0.12,
        showPlainKeys: false,
        maxVisibleChips: 6
    )
}

// MARK: - Generator

enum KeystrokeOverlayGenerator {
    /// Pull keystroke events out of the event log, turn each keydown
    /// into a display-ready chip. Handles modifier combos (⌘K, ⇧⇥),
    /// special keys (Enter, Tab, Esc, arrows, F-keys), and falls back
    /// to the raw characters the recognizer captured.
    ///
    /// `showPlainKeys` is read off the user's style at generation time;
    /// the compositor never sees chips for keys they've opted out of
    /// (keeps the per-frame scan cheap).
    static func generate(
        from log: EventRecorder.Log?,
        showPlainKeys: Bool
    ) -> [KeystrokeChip] {
        guard let log else { return [] }
        var out: [KeystrokeChip] = []
        for event in log.events where event.type == "key" {
            guard let keyCode = event.keyCode,
                  let modsRaw = event.modifiers else { continue }
            guard let label = Self.label(
                keyCode: keyCode,
                modifiersRaw: modsRaw,
                chars: event.chars,
                showPlainKeys: showPlainKeys
            ) else { continue }
            out.append(KeystrokeChip(
                time: CMTime(seconds: event.t, preferredTimescale: 600),
                label: label
            ))
        }
        return out
    }

    /// Shared label resolver — exposed for the inspector preview.
    static func label(
        keyCode: Int,
        modifiersRaw: UInt,
        chars: String?,
        showPlainKeys: Bool
    ) -> String? {
        let flags = NSEvent.ModifierFlags(rawValue: modifiersRaw)
        let hasInterestingMod = !flags.intersection([.command, .control, .option]).isEmpty
        let specialLabel = specialKeyLabel(keyCode: keyCode)
        // Filter early when the user only wants combos + specials.
        if !showPlainKeys, !hasInterestingMod, specialLabel == nil {
            return nil
        }

        var mods = ""
        if flags.contains(.control) { mods += "⌃" }
        if flags.contains(.option)  { mods += "⌥" }
        if flags.contains(.shift)   { mods += "⇧" }
        if flags.contains(.command) { mods += "⌘" }

        if let special = specialLabel {
            return mods + special
        }

        // Use `chars` (charactersIgnoringModifiers) for letters +
        // symbols. When any modifier is present we uppercase for
        // the conventional combo rendering (⌘K, not ⌘k).
        guard var body = chars, !body.isEmpty else { return nil }
        // Skip unprintable control characters that sneak through
        // `charactersIgnoringModifiers` on some layouts (e.g. \u{00}).
        if body.unicodeScalars.allSatisfy({ $0.value < 0x20 }) {
            return nil
        }
        if !mods.isEmpty {
            body = body.uppercased()
        }
        return mods + body
    }

    /// Map common virtual key codes to their display symbols. Only
    /// covers keys with a meaningful non-character label — printable
    /// keys fall through to `chars`.
    private static func specialKeyLabel(keyCode: Int) -> String? {
        switch keyCode {
        case 36:  return "↩"        // Return
        case 48:  return "⇥"        // Tab
        case 49:  return "Space"
        case 51:  return "⌫"        // Delete (backspace)
        case 53:  return "esc"
        case 71:  return "Clear"
        case 76:  return "⌅"        // Numpad Enter
        case 117: return "⌦"        // Forward Delete
        case 114: return "Help"
        case 115: return "Home"
        case 116: return "PgUp"
        case 119: return "End"
        case 121: return "PgDn"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:  return nil
        }
    }
}

// MARK: - Renderer

/// Draws a single keystroke chip (rounded-rect pill with centred text)
/// into a canvas-sized CIImage with transparent background. The
/// compositor composes multiple chips side-by-side per frame.
enum KeystrokeChipRenderer {

    /// Render a pill at a given alpha. `size` is the target chip size
    /// in output pixels; a larger `size` renders the text larger (i.e.
    /// we don't scale the final CIImage — the rasterisation is at the
    /// correct pixel density from the start).
    static func render(
        label: String,
        fontSize: CGFloat,
        textColor: CGColor,
        backgroundColor: CGColor
    ) -> (image: CIImage, size: CGSize)? {
        guard !label.isEmpty else { return nil }

        // Measure the label so we can size the pill + canvas. Core
        // Text's line-typesetting gives tighter metrics than NSString
        // drawing, which matters for getting even padding on each side.
        let font = CTFontCreateWithName("SFProText-Medium" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let attributed = NSAttributedString(string: label, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let textHeight = ceil(ascent + descent)

        // Pill geometry. Vertical padding matches horizontal so the
        // corner radius reads consistently.
        let paddingH = fontSize * 0.55
        let paddingV = fontSize * 0.35
        let pillWidth  = ceil(textWidth + paddingH * 2)
        let pillHeight = ceil(textHeight + paddingV * 2)
        let canvasWidth  = Int(pillWidth)
        let canvasHeight = Int(pillHeight)
        guard canvasWidth > 0, canvasHeight > 0 else { return nil }

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Background pill
        let radius = min(pillWidth, pillHeight) * 0.28
        let rect = CGRect(x: 0, y: 0, width: pillWidth, height: pillHeight)
        let pillPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.setFillColor(backgroundColor)
        ctx.addPath(pillPath)
        ctx.fillPath()

        // Text — baseline = paddingV + descent. Horizontal centre.
        ctx.textPosition = CGPoint(
            x: (pillWidth - textWidth) / 2,
            y: paddingV + descent
        )
        CTLineDraw(line, ctx)

        guard let cg = ctx.makeImage() else { return nil }
        return (CIImage(cgImage: cg), CGSize(width: pillWidth, height: pillHeight))
    }
}
