import AppKit
import Carbon.HIToolbox

enum HotkeyBinding: CaseIterable {
    case recordToggle
    case pauseToggle

    /// Built-in combos, used until the user rebinds (or clears) one in
    /// Settings.
    var defaultCombo: CueHotkey {
        let cmdShift = NSEvent.ModifierFlags([.command, .shift]).rawValue
        switch self {
        case .recordToggle: return CueHotkey(keyCode: UInt16(kVK_ANSI_R), modifierRaw: cmdShift, displayChar: "R")
        case .pauseToggle:  return CueHotkey(keyCode: UInt16(kVK_ANSI_P), modifierRaw: cmdShift, displayChar: "P")
        }
    }

    var displayName: String {
        switch self {
        case .recordToggle: return "Start / stop recording"
        case .pauseToggle:  return "Pause / resume recording"
        }
    }

    var signature: FourCharCode {
        switch self {
        case .recordToggle: return fourCharCode("MNTR")
        case .pauseToggle:  return fourCharCode("MNTP")
        }
    }

    var id: UInt32 {
        switch self {
        case .recordToggle: return 1
        case .pauseToggle:  return 2
        }
    }
}

private var handlersByID: [UInt32: () -> Void] = [:]

private let hotkeyCallback: EventHandlerUPP = { _, eventRef, _ in
    guard let eventRef else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    if let handler = handlersByID[hotKeyID.id] {
        DispatchQueue.main.async { handler() }
    }
    return noErr
}

final class GlobalHotkey {
    /// Posted by the Settings shortcut recorder around a capture, so the
    /// live bindings can be dropped while the user presses keys —
    /// otherwise pressing the current combo to "rebind" it would start
    /// a recording instead of reaching the recorder.
    static let captureWillBegin = Notification.Name("MentorShortcutCaptureWillBegin")
    static let captureDidEnd = Notification.Name("MentorShortcutCaptureDidEnd")

    private var registered: [UInt32: (ref: EventHotKeyRef, combo: CueHotkey)] = [:]
    private var eventHandler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyCallback,
            1,
            &spec,
            nil,
            &eventHandler
        )
    }

    /// Bind `combo` to `binding`, replacing any previous combo for it.
    /// No-op when that exact combo is already live. Returns false when
    /// Carbon refuses — typically another app already owns the combo —
    /// which used to be ignored, leaving a shortcut that silently did
    /// nothing.
    @discardableResult
    func register(_ binding: HotkeyBinding, combo: CueHotkey, handler: @escaping () -> Void) -> Bool {
        handlersByID[binding.id] = handler
        if let existing = registered[binding.id], existing.combo == combo { return true }
        unregister(binding)
        let id = EventHotKeyID(signature: binding.signature, id: binding.id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            combo.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            MentorDebug.log("HOTKEY: couldn't register \(combo.displayString) for \(binding) (status \(status))")
            return false
        }
        registered[binding.id] = (ref, combo)
        return true
    }

    func unregister(_ binding: HotkeyBinding) {
        guard let existing = registered.removeValue(forKey: binding.id) else { return }
        UnregisterEventHotKey(existing.ref)
    }

    func unregisterAll() {
        for binding in HotkeyBinding.allCases { unregister(binding) }
    }

    deinit {
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        if let h = eventHandler { RemoveEventHandler(h) }
    }
}

func fourCharCode(_ str: String) -> FourCharCode {
    var code: FourCharCode = 0
    for byte in str.utf8.prefix(4) {
        code = (code << 8) + FourCharCode(byte)
    }
    return code
}
