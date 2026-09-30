import AppKit
import Carbon.HIToolbox
import Foundation

/// A global-hotkey binding for a `SoundCue` — also reused for the app's
/// own record / pause shortcuts. Captured from a key-down event's
/// `keyCode` + the four primary modifier flags (⌃ ⌥ ⇧ ⌘).
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

    /// ⌘ / ⌥ / ⌃ — the modifiers that make a combo safe to bind globally.
    static let requiredMask: UInt =
        NSEvent.ModifierFlags.command.rawValue
        | NSEvent.ModifierFlags.option.rawValue
        | NSEvent.ModifierFlags.control.rawValue

    /// Build a `CueHotkey` from the event that captured the binding.
    /// Returns nil unless ⌘, ⌥ or ⌃ is held. Unmodified keys would fire
    /// constantly in the user's focused app — and so would Shift-only
    /// combos: a cue on ⇧A fired on every capital A typed anywhere.
    init?(capturing event: NSEvent) {
        let rawMods = event.modifierFlags.rawValue & Self.relevantMask
        guard rawMods & Self.requiredMask != 0 else { return nil }
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

    /// False for bindings saved before Shift-only combos were rejected.
    var isSafeGlobalBinding: Bool {
        modifierRaw & Self.requiredMask != 0
    }

    /// Carbon `RegisterEventHotKey` modifier mask for this combo.
    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifierRaw)
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    /// Menu-item key equivalent (+ mask) for single-character keys, so
    /// the status menu shows the shortcut. Named keys (F5, arrows) get
    /// no equivalent rather than a wrong one.
    var menuKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags)? {
        guard displayChar.count == 1 else { return nil }
        let mask = NSEvent.ModifierFlags(rawValue: modifierRaw)
            .intersection([.command, .option, .control, .shift])
        return (displayChar.lowercased(), mask)
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
