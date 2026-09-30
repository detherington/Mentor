import AppKit

/// Routes "open these files" requests (Finder double-click, `open`,
/// drag onto the Dock icon) to the editor. Requests that arrive before
/// the app is wired up are buffered; a duplicate launch hands them to the
/// instance that's already running.
@MainActor
final class OpenURLRouter: NSObject {
    /// Opens one `.mentor` bundle. Nil until launch has finished wiring
    /// things up; setting it drains anything that arrived first.
    var open: ((URL) -> Void)? {
        didSet { drain() }
    }

    private var pending: [URL] = []

    /// Listen for the raw `kAEOpenDocuments` Apple Event in addition to
    /// `application(_:open:)`. On LSUIElement apps the high-level delegate
    /// method sometimes doesn't fire before the runloop reaches
    /// `applicationDidFinishLaunching` — the raw event is delivered
    /// synchronously whenever it's dispatched, so the buffer is filled in
    /// time for the duplicate check. Both paths feed `receive(_:)`.
    func installAppleEventHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func receive(_ urls: [URL]) {
        MentorDebug.log("APP: open request for \(urls.count) URL(s); ready=\(open != nil)")
        pending.append(contentsOf: urls)
        drain()
    }

    /// Parses the event's direct object as a list of alias / URL
    /// descriptors.
    @objc
    func handleOpenDocumentsEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let listDescriptor = event.paramDescriptor(forKeyword: keyDirectObject) else {
            return
        }
        var urls: [URL] = []
        // A single file can arrive as a bare descriptor rather than a
        // one-item list; `1...0` would trap, so treat it as the item.
        let count = listDescriptor.numberOfItems
        let items = count > 0
            ? (1...count).compactMap { listDescriptor.atIndex($0) }
            : [listDescriptor]
        for item in items {
            // URL-shaped descriptors come in as `typeFileURL`; older
            // senders may use `typeAlias`. Try both.
            if let urlString = item.stringValue, let url = URL(string: urlString) {
                urls.append(url)
                continue
            }
            if let data = item.coerce(toDescriptorType: typeFileURL)?.data,
               let s = String(data: data, encoding: .utf8),
               let url = URL(string: s) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        receive(urls)
    }

    /// Only `.mentor` bundles (file URLs) are opened. The
    /// `mentor://orbis-token` link that used to connect Orbis is gone — it
    /// accepted a token from any page or app without Mentor having asked,
    /// which let a malicious link route later uploads to someone else's
    /// Orbis account. The URL scheme is no longer registered; this guard
    /// only catches a stale LaunchServices registration.
    private func drain() {
        guard let open, !pending.isEmpty else { return }
        let urls = pending
        pending.removeAll()
        for url in urls {
            guard url.isFileURL else {
                MentorDebug.log("APP: ignoring non-file URL (scheme \(url.scheme ?? "nil"))")
                continue
            }
            open(url)
        }
    }

    /// If another Mentor is already running (a second copy of the app, or
    /// a fresh build launched while a previous one is still in the menu
    /// bar), hand it anything we were asked to open and quit — two menu
    /// bar items and two competing capture sessions is always bad, so the
    /// newcomer always defers. Returns false when we're the only instance.
    func deferToRunningInstance() -> Bool {
        guard let other = Self.otherMentorInstance() else { return false }
            MentorDebug.log("APP: another Mentor instance is running (pid=\(other.processIdentifier)); forwarding \(pending.count) pending URLs + quitting.")
            // Forward any .mentor URLs that Finder handed us on launch
            // so the already-running instance opens them — otherwise a
            // double-click would spawn us, we'd terminate as a duplicate,
            // and nothing would end up opening.
            if !pending.isEmpty, let bundleURL = other.bundleURL {
                let urls = pending
                pending.removeAll()
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                config.addsToRecentItems = false
                // `open` is asynchronous. Terminating right after firing
                // it (as before) raced LaunchServices' delivery: when we
                // exited first the hand-off was dropped, so a double-click
                // showed Finder's open animation and then nothing. Quit
                // once delivery completes — with a timeout so a stuck
                // LaunchServices can't strand a half-launched duplicate.
                // Whichever terminate runs first ends the process.
                NSWorkspace.shared.open(urls, withApplicationAt: bundleURL, configuration: config) { _, error in
                    if let error {
                        MentorDebug.log("APP: forwarding to running instance failed: \(error.localizedDescription)")
                    }
                    Task { @MainActor in NSApp.terminate(nil) }
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    NSApp.terminate(nil)
                }
            } else {
                // No URLs to forward — just bring the other instance
                // forward so the user sees which one remains.
                other.activate(options: [])
                NSApp.terminate(nil)
            }
        return true
    }

    /// Returns another running Mentor instance (matched by bundle ID),
    /// or nil if we're the only one. Used to enforce a single menu-bar
    /// instance — running two at once leaves competing capture sessions
    /// + two indistinguishable status items.
    private static func otherMentorInstance() -> NSRunningApplication? {
        guard let myBundleID = Bundle.main.bundleIdentifier else { return nil }
        let me = NSRunningApplication.current.processIdentifier
        return NSWorkspace.shared.runningApplications.first { app in
            app.bundleIdentifier == myBundleID && app.processIdentifier != me
        }
    }
}
