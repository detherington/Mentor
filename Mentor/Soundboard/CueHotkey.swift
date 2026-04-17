import AppKit
import Foundation

/// A global-hotkey binding for a `SoundCue`. Captured from a key-down
/// event's `keyCode` + the four primary modifier flags (⌃ ⌥ ⇧ ⌘).
///
/// Matching is modifier-sensitive and modifier-strict: the event's flags
/// must match the stored flags exactly (no extra modifiers allowed),
/// which prevents accidental triggers when the user is mid-shortcut in
/// another app (e.g. ⌘⇧1 should not fire a cue bound to ⌘1).
///
/// We also persist a small `displayChar` derived from
/// `NSEvent.charactersIgnoringModifiers` at capture time so the UI can
/// show "⌥1" / "⌘⇧F5" without a separate virtual-key-code → character
/// lookup table.
struct CueHotkey: Equatable, Codable, Sendable {
    let keyCode: UInt16
    /// Stores only the subset of `NSEvent.ModifierFlags` we care about
    /// (command / option / control / shift). Other flags like numeric
    /// pad / function are normalised out at capture time.
    let modifierRaw: UInt
    /// Human-readable key label, e.g. "1", "F5", "Space".
    let displayChar: String

    /// Mask for the four modifiers we recognise.
    static let relevantMask: UInt =
        NSEvent.ModifierFlags.command.rawValue
        | NSEvent.ModifierFlags.option.rawValue
        | NSEvent.ModifierFlags.control.rawValue
        | NSEvent.ModifierFlags.shift.rawValue

    /// Build a `CueHotkey` from the event that captured the binding.
    /// Returns nil if the event has no modifiers — unmodified keys would
    /// constantly fire in the user's focused app and aren't a sensible
    /// binding for a global hotkey.
    init?(capturing event: NSEvent) {
        let rawMods = event.modifierFlags.rawValue & Self.relevantMask
        guard rawMods != 0 else { return nil }
        self.keyCode = event.keyCode
        self.modifierRaw = rawMods
        self.displayChar = CueHotkey.label(for: event)
    }

    /// Direct initialiser — used by Codable synthesis + tests.
    init(keyCode: UInt16, modifierRaw: UInt, displayChar: String) {
        self.keyCode = keyCode
        self.modifierRaw = modifierRaw
        self.displayChar = displayChar
    }

    /// Rendered symbol for the UI, e.g. "⌥⇧1".
    var displayString: String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifierRaw)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(displayChar.uppercased())
        return parts.joined()
    }

    /// True iff `event` should fire this hotkey.
    func matches(event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let eventMods = event.modifierFlags.rawValue & Self.relevantMask
        return eventMods == (modifierRaw & Self.relevantMask)
    }

    // MARK: - Key labelling

    private static func label(for event: NSEvent) -> String {
        // Prefer the character without modifiers so ⇧2 reads as "2" not "@".
        if let chars = event.charactersIgnoringModifiers,
           let scalar = chars.unicodeScalars.first,
           scalar.isASCII {
            let v = scalar.value
            if v >= 0x20 && v < 0x7f {
                return String(scalar)
            }
        }
        // Named / function keys.
        return namedKey(for: event.keyCode) ?? "?"
    }

    private static func namedKey(for code: UInt16) -> String? {
        // Virtual key codes from HIToolbox/Events.h. Only the ones users
        // are likely to actually bind — not trying to be exhaustive.
        switch code {
        case 0x31: return "Space"
        case 0x24: return "Return"
        case 0x33: return "Delete"
        case 0x35: return "Esc"
        case 0x30: return "Tab"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        case 0x7A: return "F1"
        case 0x78: return "F2"
        case 0x63: return "F3"
        case 0x76: return "F4"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x62: return "F7"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x6D: return "F10"
        case 0x67: return "F11"
        case 0x6F: return "F12"
        default: return nil
        }
    }
}
