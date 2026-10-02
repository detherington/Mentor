import AppKit
import CoreGraphics

/// macOS's own permission requests, as in Muesli: Accessibility's comes
/// from universalAccessAuthWarn, the others (Screen Recording, camera,
/// microphone) from UserNotificationCenter. Window owners are readable
/// without Screen Recording permission, so Pepper can tell whether one is
/// on screen and never opens System Settings over one, which used to leave
/// the request sitting unanswered behind the windows.
enum SystemPrompts {
    static let owners: [(name: String, bundleID: String)] = [
        ("universalAccessAuthWarn", "com.apple.accessibility.universalAccessAuthWarn"),
        ("UserNotificationCenter", "com.apple.UserNotificationCenter"),
    ]

    /// Whether one of them has a window on screen.
    static var isShowing: Bool { showingOwner != nil }

    private static var showingOwner: (name: String, bundleID: String)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let names = Set(windows.compactMap { $0[kCGWindowOwnerName as String] as? String })
        return owners.first { names.contains($0.name) }
    }

    /// Brings a request on screen to the front; false when there is none.
    @discardableResult
    static func bringToFront() -> Bool {
        guard let owner = showingOwner else { return false }
        NSRunningApplication.runningApplications(withBundleIdentifier: owner.bundleID).first?.activate()
        return true
    }
}
