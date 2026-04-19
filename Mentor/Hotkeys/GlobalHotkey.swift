import AppKit
import Carbon.HIToolbox

enum HotkeyBinding {
    case recordToggle
    case pauseToggle

    var keyCode: UInt32 {
        switch self {
        case .recordToggle: return UInt32(kVK_ANSI_R)
        case .pauseToggle:  return UInt32(kVK_ANSI_P)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .recordToggle: return UInt32(cmdKey | shiftKey)
        case .pauseToggle:  return UInt32(cmdKey | shiftKey)
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
    private var hotKeyRefs: [EventHotKeyRef?] = []
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

    func register(_ binding: HotkeyBinding, handler: @escaping () -> Void) {
        handlersByID[binding.id] = handler
        let id = EventHotKeyID(signature: binding.signature, id: binding.id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        hotKeyRefs.append(ref)
    }

    deinit {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
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
