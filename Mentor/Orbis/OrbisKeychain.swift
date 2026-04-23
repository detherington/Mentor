import Foundation
import Security

/// Persists the user's Orbis Personal Access Token in the macOS
/// login keychain under service `com.sbscomms.mentor.orbis`. One
/// token per user account — we overwrite on save.
///
/// Deliberately no export APIs: nothing else in Mentor should need
/// to read the PAT outside of `OrbisClient` callers that already
/// hold a reference via `tokenForCurrentUser()`.
enum OrbisKeychain {
    private static let service = "com.sbscomms.mentor.orbis"
    private static let account = "orbis_pat"

    /// Write or overwrite the token. Throws if the keychain refuses
    /// the save (rare — usually a sandbox / entitlement issue, which
    /// Mentor isn't sandboxed so shouldn't hit).
    static func saveToken(_ token: String) throws {
        let data = Data(token.utf8)

        // Always delete first so we don't have to juggle
        // SecItemAdd vs SecItemUpdate semantics — the delete is a
        // no-op when there's nothing there.
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecValueData as String:    data,
            // Unlocked sessions only — matches how every other
            // desktop PAT-bearer (GitHub CLI, 1Password etc.) stores
            // credentials.
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

    /// Fetch the token. Returns nil when nothing is stored — callers
    /// should surface "not connected" UX in that case.
    static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    /// Remove the stored token (Disconnect flow + 401 handler).
    static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static var hasToken: Bool { loadToken() != nil }
}
