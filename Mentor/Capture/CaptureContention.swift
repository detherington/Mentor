import AppKit
import Foundation

/// Detects other running apps that commonly compete with Mentor for
/// camera / microphone capture. The macOS capture subsystem doesn't
/// expose "who is holding device X" as a first-class API — but since
/// the offenders are a small, well-known set (always-on meeting
/// recorders, dictation tools, audio routers, video-call apps), we
/// can check bundle IDs against the running-app list and surface a
/// targeted hint to the user.
///
/// Symptom this warns about: stuttery webcam preview, occasional
/// audio crackle, or mid-recording frame drops — all rooted in the
/// capture sessions competing for the AV engine's priority slots.
/// Quitting one of the listed apps almost always clears it up.
enum CaptureContention {
    struct KnownOffender {
        /// Bundle identifier of the offending app.
        let bundleID: String
        /// User-facing app name for the warning text.
        let name: String
        /// What the app typically holds — shown in the warning so the
        /// user can tell why it's a problem ("mic" vs "camera" helps
        /// them triage).
        let holds: String
    }

    /// Curated list of apps known to continuously hold the mic, the
    /// camera, or both. Deliberately conservative — we don't want to
    /// warn about every app that's ever touched AVFoundation, just
    /// the ones that routinely cause real-world contention. Grow this
    /// list as we see new offenders in the wild.
    static let knownOffenders: [KnownOffender] = [
        // Meeting recorders + AI note-takers (always-on mic).
        KnownOffender(bundleID: "com.granola.mac",                name: "Granola",            holds: "mic"),
        KnownOffender(bundleID: "com.granola.granola",            name: "Granola",            holds: "mic"),
        KnownOffender(bundleID: "com.fathom.mac",                 name: "Fathom",             holds: "mic"),
        KnownOffender(bundleID: "ai.otter.Otter",                 name: "Otter",              holds: "mic"),
        KnownOffender(bundleID: "ai.wispr.flow",                  name: "Wispr Flow",         holds: "mic"),
        KnownOffender(bundleID: "ai.wispr.app",                   name: "Wispr",              holds: "mic"),
        KnownOffender(bundleID: "io.krisp.macapp",                name: "Krisp",              holds: "mic"),
        KnownOffender(bundleID: "com.readdle.smartrecorder.mac",  name: "Read.ai",            holds: "mic"),
        // Audio routing / virtual-driver apps. These reroute the
        // system audio graph and usually compound with any mic users.
        KnownOffender(bundleID: "com.rogueamoeba.audiohijack4",   name: "Audio Hijack",       holds: "audio routing"),
        KnownOffender(bundleID: "com.rogueamoeba.Loopback2",      name: "Loopback",           holds: "audio routing"),
        KnownOffender(bundleID: "com.rogueamoeba.farrago",        name: "Farrago",            holds: "audio routing"),
        KnownOffender(bundleID: "com.existential.blackhole",      name: "BlackHole",          holds: "audio routing"),
        // Video-call apps in standby hold both camera and mic even
        // when not in a call, on some configs.
        KnownOffender(bundleID: "us.zoom.xos",                    name: "Zoom",               holds: "mic + camera"),
        KnownOffender(bundleID: "com.microsoft.teams2",           name: "Microsoft Teams",    holds: "mic + camera"),
        KnownOffender(bundleID: "com.microsoft.teams",            name: "Microsoft Teams",    holds: "mic + camera"),
        KnownOffender(bundleID: "com.cisco.webexmeetingsapp",     name: "Webex",              holds: "mic + camera"),
        KnownOffender(bundleID: "com.electron.whereby",           name: "Whereby",            holds: "mic + camera"),
        KnownOffender(bundleID: "com.hnc.Discord",                name: "Discord",            holds: "mic"),
        // Screen-sharing + remote tools that pipe video through.
        KnownOffender(bundleID: "com.screen.studio",              name: "Screen Studio",      holds: "screen + mic"),
        KnownOffender(bundleID: "com.loom.desktop",               name: "Loom",               holds: "screen + mic"),
        KnownOffender(bundleID: "com.loom.macdesktop",            name: "Loom",               holds: "screen + mic"),
    ]

    /// Return currently-running apps from the known-offender list.
    /// De-duplicated by user-facing name so multiple bundle-ID
    /// variants of the same product (Granola ships under two IDs)
    /// only produce one warning row.
    static func detectedOffenders() -> [KnownOffender] {
        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        )
        var seenNames = Set<String>()
        var hits: [KnownOffender] = []
        for offender in knownOffenders where runningBundleIDs.contains(offender.bundleID) {
            if seenNames.insert(offender.name).inserted {
                hits.append(offender)
            }
        }
        return hits
    }
}
