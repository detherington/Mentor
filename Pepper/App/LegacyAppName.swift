import AppKit

/// One-time move of the installed app from "Mentor.app" to "Pepper.app".
///
/// Sparkle updates an app in place and keeps its file name, so a copy
/// that updated from Mentor 1.x runs Pepper from /Applications/Mentor.app,
/// and Finder, Spotlight and the Dock go on calling it "Mentor". Moving
/// the bundle while it runs would leave `Bundle.main` and Sparkle pointing
/// at a path that no longer exists, so this runs at the start of launch —
/// before Sparkle or any window — moves the bundle, relaunches from the
/// new path and quits.
///
/// It leaves the app alone if it has any other name, if a Pepper.app is
/// already next to it, if macOS is running it from a translocated
/// (read-only, randomised) path, or if the move fails (a standard user
/// can't write to /Applications). The bundle ID doesn't change, so
/// privacy permissions, settings and the Orbis sign-in carry over.
@MainActor
enum LegacyAppName {
    private static let legacyBundleName = "Mentor.app"
    private static let bundleName = "Pepper.app"

    /// True when the app was moved and a relaunch is under way; the
    /// caller should stop launching. `files` are recordings Finder asked
    /// this launch to open — the relaunched copy opens them instead.
    static func moveAndRelaunchIfNeeded(opening files: [URL]) -> Bool {
        let current = Bundle.main.bundleURL
        guard current.lastPathComponent == legacyBundleName,
              !current.path.contains("/AppTranslocation/") else { return false }
        let target = current.deletingLastPathComponent().appendingPathComponent(bundleName)
        guard !FileManager.default.fileExists(atPath: target.path) else { return false }
        do {
            try FileManager.default.moveItem(at: current, to: target)
        } catch {
            PepperDebug.log("APP: couldn't rename \(legacyBundleName) to \(bundleName): \(error.localizedDescription)")
            return false
        }
        PepperDebug.log("APP: renamed \(current.path) → \(target.path); relaunching")

        // Start the new copy only after this process exits: the single-
        // instance check would otherwise make it quit on sight. Paths are
        // passed as arguments, never spliced into the script.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
            "-c",
            "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open -a \"$0\" \"$@\"",
            target.path
        ] + files.map(\.path)
        do {
            try relaunch.run()
        } catch {
            // Still quit: carrying on from a bundle that's been moved
            // would break Sparkle. The user reopens Pepper by hand.
            PepperDebug.log("APP: relaunch after rename failed: \(error.localizedDescription)")
        }
        NSApp.terminate(nil)
        return true
    }
}
