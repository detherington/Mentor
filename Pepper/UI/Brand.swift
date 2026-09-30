import AppKit
import SwiftUI

/// SBS Comms brand tokens, shared with Muesli (its `Brand.swift`) so the two
/// apps look like one family. Colours come from the asset catalog so light
/// and dark variants resolve on their own; type is the brand pairing —
/// Maison Neue Extended Demi (SF Pro Expanded Semibold until a desktop file
/// is bundled) with Nantes Light, bundled in Resources/Fonts.
///
/// As in Muesli, the brand is an accent layer on macOS: toolbars, menus,
/// forms and sheets stay native. Cobalt is the app-wide tint (AccentColor);
/// Persimmon means live; Violet means automatic; Emerald means you or done;
/// Neon is one call to action per surface, always with black text.
enum Brand {
    // MARK: Colours

    /// Cobalt as a fill: prominent buttons, progress, selection.
    static let accent = Color("BrandCobalt")
    /// Cobalt as text or an icon on a surface; lighter in dark mode for contrast.
    static let accentText = Color("BrandAccentText")
    /// Persimmon: recording state.
    static let live = Color("BrandLive")
    /// Neon: one call to action per surface, always with black text.
    static let neon = Color("BrandNeon")
    /// Emerald: success, and "you" (full-screen webcam moments).
    static let emerald = Color("BrandEmerald")
    /// Emerald as small text.
    static let emeraldInk = Color("BrandEmeraldInk")
    /// Violet: what Pepper does automatically (smart zoom, Quick polish).
    static let violet = Color("BrandViolet")
    /// Violet as small text.
    static let violetInk = Color("BrandVioletInk")
    /// Violet panel / chip fill.
    static let violetTint = Color("BrandVioletTint")
    /// Teal: a fill only (caption blocks on the timeline).
    static let teal = Color("BrandTeal")
    /// Off White strips (timeline, inspector) in light mode; near-black in dark.
    static let ground = Color("BrandGround")
    /// Card surface: white in light mode, elevated grey in dark.
    static let surface = Color("BrandSurface")
    /// Neutral chip / quiet-button fill.
    static let chip = Color("BrandChip")
    /// One hairline for borders.
    static let hairline = Color("BrandHairline")
    /// Text on Neon or Persimmon fills.
    static let onCTA = Color.black

    /// The iridescent brand gradient. Never behind text.
    static let gradient = LinearGradient(
        colors: [Color(red: 0.149, green: 0.318, blue: 0.788), Color(red: 0.529, green: 0.451, blue: 0.745),
                 Color(red: 1.0, green: 0.373, blue: 0.106), Color(red: 0.808, green: 1.0, blue: 0.345),
                 Color(red: 0.251, green: 0.663, blue: 0.443), Color(red: 0.612, green: 0.804, blue: 0.8)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Shape

    enum Radius {
        static let chip: CGFloat = 8
        static let field: CGFloat = 12
        static let card: CGFloat = 16
        static let pill: CGFloat = 22
    }

    // MARK: Type

    /// Display face: Maison Neue Extended Demi when its desktop file is
    /// bundled, else SF Pro Expanded Semibold.
    static func display(_ size: CGFloat) -> Font {
        if NSFont(name: "MaisonNeueExtended-Demi", size: size) != nil {
            return .custom("MaisonNeueExtended-Demi", size: size)
        }
        return .system(size: size, weight: .semibold).width(.expanded)
    }

    /// Contrasting serif: Nantes Light (New York Light if it fails to load).
    static func serif(_ size: CGFloat) -> Font {
        if NSFont(name: "Nantes-Light", size: size) != nil {
            return .custom("Nantes-Light", size: size)
        }
        return .system(size: size, weight: .light, design: .serif)
    }
}

extension View {
    /// Uppercase expanded headline with the brand's −2% tracking and tight leading.
    func brandDisplay(_ size: CGFloat) -> some View {
        font(Brand.display(size)).textCase(.uppercase).tracking(-0.02 * size).lineSpacing(0)
    }

    /// Small uppercase label with open tracking. Single line at its own
    /// width: SwiftUI measures tracked text without the tracking, and in a
    /// content-sized layout the last glyph would otherwise wrap.
    func brandKicker(_ size: CGFloat = 10.5, color: Color = .secondary) -> some View {
        font(Brand.display(size)).textCase(.uppercase).tracking(0.06 * size).foregroundStyle(color)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }

    /// Button label on a Neon or Persimmon fill (single line, see `brandKicker`).
    func brandCTA(_ size: CGFloat = 11) -> some View {
        font(Brand.display(size)).textCase(.uppercase).tracking(0.05 * size)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }

    /// A card on a ground strip: surface fill, one hairline, continuous corners.
    func brandCard(radius: CGFloat = Brand.Radius.card) -> some View {
        background(Brand.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Brand.hairline))
    }

    /// Clocks and timecodes: SF Mono, as in Muesli's recording pill.
    func brandTimecode(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> some View {
        font(.system(size: size, weight: weight, design: .monospaced))
    }
}

/// Neon call to action: black uppercase label on the highlight colour. One per surface.
struct NeonButtonStyle: ButtonStyle {
    var height: CGFloat = 34
    /// Stretch to the container's width (a card's one action).
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brandCTA()
            .foregroundStyle(Brand.onCTA)
            .padding(.horizontal, 16)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(Brand.neon, in: RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous))
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
    }
}

/// Quiet secondary action next to a Neon button.
struct QuietButtonStyle: ButtonStyle {
    var height: CGFloat = 34
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(Brand.chip, in: RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
