import AppKit

/// Quits and starts a fresh copy of the app — after Screen Recording is
/// switched on, since macOS only applies that grant to a new process.
@MainActor
enum AppRelauncher {
    /// The new copy starts only after this process exits — the single-
    /// instance check would otherwise make it quit on sight. If quitting
    /// is cancelled (e.g. at a "still recording" prompt), the helper gives
    /// up after 30 s rather than relaunching whenever Pepper later quits.
    /// The path is passed as an argument, never spliced into the script.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "i=0; while /bin/kill -0 \(pid) 2>/dev/null; do i=$((i+1)); [ $i -gt 150 ] && exit 0; /bin/sleep 0.2; done; exec /usr/bin/open -a \"$0\"",
            Bundle.main.bundleURL.path
        ]
        do {
            try helper.run()
        } catch {
            // Still quit: the user reopens Pepper by hand.
            PepperDebug.log("APP: relaunch helper failed: \(error.localizedDescription)")
        }
        NSApp.terminate(nil)
    }
}
