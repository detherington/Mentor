import Foundation

/// UserDefaults-backed container for non-secret Orbis state: host,
/// last-connected user display name, last-used export form values.
/// The PAT itself lives in `OrbisKeychain` — keeping secrets out of
/// UserDefaults (which is plist-readable) is the whole point of the
/// split.
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
        static let connectedUserName = "orbis.connectedUserName"
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
        get { defaults.string(forKey: Key.host) ?? defaultHost }
        set {
            let cleaned = newValue.trimmingCharacters(in: .whitespaces)
            defaults.set(cleaned.isEmpty ? defaultHost : cleaned, forKey: Key.host)
            post()
        }
    }

    /// Display name returned by `/api/auth/me` after a successful
    /// connect. Purely cosmetic — the source of truth for "is
    /// connected" is `OrbisKeychain.hasToken`.
    var connectedUserName: String? {
        get { defaults.string(forKey: Key.connectedUserName) }
        set {
            if let v = newValue { defaults.set(v, forKey: Key.connectedUserName) }
            else { defaults.removeObject(forKey: Key.connectedUserName) }
            post()
        }
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

    /// `true` when a PAT is stored *and* we have a cached user name —
    /// both together mean "ready to upload". The PAT without a user
    /// name happens transiently between callback-URL receipt and
    /// the first `me()` succeeding.
    var isConnected: Bool {
        OrbisKeychain.hasToken && connectedUserName != nil
    }

    /// Full callback URL the Orbis PAT page redirects back to with
    /// `?token=…&user=…`.
    static let callbackURL = "mentor://orbis-token"

    /// URL to open in the user's browser for the Connect flow.
    func connectURL() -> URL? {
        guard var components = URLComponents(string: "https://\(host)/settings/api-tokens") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "source",   value: "mentor"),
            URLQueryItem(name: "callback", value: Self.callbackURL),
        ]
        return components.url
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
