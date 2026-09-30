import Foundation
import Security

/// Orbis sign-in credentials in the macOS login keychain under service
/// `com.sbscomms.mentor.orbis`: one refresh token per host.
///
/// Keyed by host so a credential is only ever sent to the Orbis that
/// issued it. There used to be one global token with an editable host
/// field — pointing Mentor at another host handed that host your token.
///
/// Only `OrbisAccount` reads or writes these.
enum OrbisKeychain {
    private static let service = "com.sbscomms.mentor.orbis"

    private static func refreshAccount(_ host: String) -> String {
        "oauth_refresh@\(host.lowercased())"
    }

    static func saveRefreshToken(_ token: String, host: String) throws {
        try write(Data(token.utf8), account: refreshAccount(host))
    }

    static func loadRefreshToken(host: String) -> String? {
        read(account: refreshAccount(host))
    }

    static func deleteRefreshToken(host: String) {
        remove(account: refreshAccount(host))
    }

    /// Delete every personal access token Mentor ever stored — the
    /// host-less `orbis_pat` item from 1.1.x and the per-host `pat@…`
    /// items from the build that briefly kept them — now that Orbis
    /// sign-in is the only way in. Returns true if anything was removed,
    /// so the UI can tell an upgrading user to sign in once.
    @discardableResult
    static func purgePersonalTokens() -> Bool {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String:       kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let attributes = items as? [[String: Any]] else {
            return false
        }
        var removed = false
        for item in attributes {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account == "orbis_pat" || account.hasPrefix("pat@") else { continue }
            remove(account: account)
            removed = true
        }
        return removed
    }

    // MARK: - SecItem plumbing

    private static func write(_ data: Data, account: String) throws {
        // Delete then add, so we don't juggle SecItemAdd vs SecItemUpdate
        // semantics — the delete is a no-op when nothing is there.
        remove(account: account)
        let addQuery: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrService as String:    service,
            kSecAttrAccount as String:    account,
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain save failed (\(status))"]
            )
        }
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
