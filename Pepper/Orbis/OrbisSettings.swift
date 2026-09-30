import Foundation

/// UserDefaults-backed container for non-secret Orbis state: host,
/// connected user display name (per host), last-used export form values.
/// Credentials live in `OrbisKeychain` and are managed by `OrbisAccount`
/// — keeping secrets out of UserDefaults (which is plist-readable) is the
/// whole point of the split.
///
/// Singleton pattern matches the existing `Settings` class. Posts
/// `OrbisSettings.didChange` on mutation so the Settings pane can
/// refresh its "connected as…" badge without an explicit observer
/// wire-up.
@MainActor
final class OrbisSettings {
    static let shared = OrbisSettings()
    static let didChange = Notification.Name("OrbisSettings.didChange")

    private let defaults = UserDefaults.standard

    private enum Key {
        static let host              = "orbis.host"
        /// Suffixed with "@<host>".
        static let userName          = "orbis.userName"
        static let lastVisibility    = "orbis.lastVisibility"
        static let lastClientID      = "orbis.lastClientID"
        static let ingestAssets      = "orbis.ingestAssets"
    }

    private init() {
        defaults.register(defaults: [
            Key.host:           defaultHost,
            Key.lastVisibility: OrbisVisibility.privateVisibility.rawValue,
            Key.ingestAssets:   true,
        ])
    }

    /// Production Orbis host. User-editable in case of staging setups
    /// or self-hosted deploys.
    static let defaultHost = "sbsorbis.com"
    private var defaultHost: String { Self.defaultHost }

    var host: String {
        get {
            // Always sanitize on read too — tolerate legacy values
            // stored before the sanitizer existed, or a user who
            // edited UserDefaults by hand.
            Self.sanitizeHost(defaults.string(forKey: Key.host) ?? defaultHost)
        }
        set {
            let cleaned = Self.sanitizeHost(newValue)
            defaults.set(cleaned.isEmpty ? defaultHost : cleaned, forKey: Key.host)
            post()
        }
    }

    /// Strip scheme, trailing slashes, whitespace so we can always
    /// safely prefix `https://` and append `/api/...`. A user pasting
    /// `https://sbsorbis.com/` or `sbsorbis.com ` or
    /// `http://sbsorbis.com/api/` all end up as `sbsorbis.com`.
    static func sanitizeHost(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] {
            if s.lowercased().hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                break
            }
        }
        // Drop anything after the host (path / query / trailing slash)
        // — if a user pastes `sbsorbis.com/api/auth/user` we still want
        // just the hostname.
        if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        return s
    }

    /// Display name of the account connected on `host`. Cosmetic —
    /// whether we're connected is `OrbisAccount.isConnected`.
    func userName(forHost host: String) -> String? {
        defaults.string(forKey: "\(Key.userName)@\(host.lowercased())")
    }

    func setUserName(_ name: String?, forHost host: String) {
        let key = "\(Key.userName)@\(host.lowercased())"
        if let name { defaults.set(name, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    var lastVisibility: OrbisVisibility {
        get {
            guard let raw = defaults.string(forKey: Key.lastVisibility),
                  let v = OrbisVisibility(rawValue: raw) else {
                return .privateVisibility
            }
            return v
        }
        set { defaults.set(newValue.rawValue, forKey: Key.lastVisibility); post() }
    }

    /// Last-selected client ID for `visibility == .client`. Nil when
    /// not applicable. Saved so the export sheet re-prefills the
    /// picker next time.
    var lastClientID: String? {
        get { defaults.string(forKey: Key.lastClientID) }
        set {
            if let v = newValue { defaults.set(v, forKey: Key.lastClientID) }
            else { defaults.removeObject(forKey: Key.lastClientID) }
            post()
        }
    }

    var ingestAssetsEnabled: Bool {
        get { defaults.bool(forKey: Key.ingestAssets) }
        set { defaults.set(newValue, forKey: Key.ingestAssets); post() }
    }

    /// Deep-link URL to a specific uploaded video in Orbis, for the
    /// post-upload "View in Orbis" button.
    func videoURL(videoID: String) -> URL? {
        URL(string: "https://\(host)/videos/\(videoID)")
    }

    private func post() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
