import AppKit

/// Pepper lives in the menu bar (`.accessory`) except while a window that
/// needs the Dock and keyboard focus is open — an editor, the open panel,
/// setup. Each holds a claim; the app returns to the menu bar when the
/// last one lets go. Editors used to flip the policy themselves, which
/// would have demoted the app from under the setup window (and vice
/// versa) once there was more than one kind of window.
@MainActor
enum DockPresence {
    private static var claims = Set<ObjectIdentifier>()

    static func claim(_ owner: AnyObject) {
        claims.insert(ObjectIdentifier(owner))
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    static func release(_ owner: AnyObject) {
        claims.remove(ObjectIdentifier(owner))
        if claims.isEmpty, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
