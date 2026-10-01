import AppKit

/// Whether Pepper shows in the Dock. By default it always does: a
/// menu-bar-only app was easy to lose, and new users went looking for it
/// in the Dock. Settings › "Hide Pepper from the Dock" makes it live in
/// the menu bar (`.accessory`) except while a window that needs the Dock
/// and keyboard focus is open — the main window, an editor, the open
/// panel, setup. Each
/// holds a claim; with the Dock icon hidden, the app returns to the menu
/// bar when the last one lets go. Editors used to flip the policy
/// themselves, which would have demoted the app from under the setup
/// window (and vice versa) once there was more than one kind of window.
@MainActor
enum DockPresence {
    private static var claims = Set<ObjectIdentifier>()

    static func claim(_ owner: AnyObject) {
        claims.insert(ObjectIdentifier(owner))
        apply()
    }

    static func release(_ owner: AnyObject) {
        claims.remove(ObjectIdentifier(owner))
        apply()
    }

    /// Set the policy for the current claims and setting. Called at
    /// launch and whenever Settings change.
    static func apply() {
        let policy: NSApplication.ActivationPolicy =
            claims.isEmpty && Settings.shared.hideDockIcon ? .accessory : .regular
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }
}
