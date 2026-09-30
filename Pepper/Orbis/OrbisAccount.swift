import AppKit
import CryptoKit
import Foundation

/// Pepper's connection to Orbis, for the host in `OrbisSettings`: "Sign
/// In with Orbis", OAuth 2.1 authorization code + PKCE with a loopback
/// redirect as public client `pepper-mac` (scope `videos`) — the flow
/// Muesli uses against the same server.
///
/// Pepper starts the sign-in and holds the verifier and `state`, so
/// nothing arriving from outside can plant a credential. The access
/// token (≈1 h) lives in memory, the rotating
/// refresh token in the Keychain per host (see `OrbisKeychain`), and
/// sign-out revokes it on the server.
///
/// Everything that talks to Orbis gets its `OrbisClient` from `client()`.
@MainActor
@Observable
final class OrbisAccount {
    static let shared = OrbisAccount()

    /// Public OAuth client registered in Orbis for Pepper.
    static let clientID = "pepper-mac"
    /// Upload + manage the user's videos.
    static let scope = "videos"

    private(set) var isConnected = false
    private(set) var userName: String?
    private(set) var isSigningIn = false

    @ObservationIgnored private var host: String
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessTokenExpiry = Date.distantPast
    @ObservationIgnored private var refreshTask: Task<OrbisTokenResponse, Error>?
    @ObservationIgnored private var signInTask: Task<OrbisTokenResponse, Error>?

    private init() {
        host = OrbisSettings.shared.host
        reload()
        NotificationCenter.default.addObserver(
            forName: OrbisSettings.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncHost() }
        }
    }

    /// A client authenticated as the current session. Requests fetch the
    /// access token as they go, so a long export survives it expiring
    /// mid-way.
    func client() -> OrbisClient {
        OrbisClient(
            host: host,
            token: { [weak self] in
                guard let self else { throw OrbisError.tokenMissing }
                return try await self.currentToken()
            },
            onRejected: { [weak self] in
                await self?.credentialRejected() ?? false
            }
        )
    }

    // MARK: - Sign in / out

    /// Browser sign-in. Returns once the user finishes in the browser;
    /// throws a user-facing error otherwise (including `cancelSignIn()`).
    func signIn() async throws {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer {
            isSigningIn = false
            signInTask = nil
        }
        let host = self.host
        let task = Task { try await Self.authorize(host: host) }
        signInTask = task
        let response = try await task.value
        guard self.host == host else { throw OrbisError.signInFailed("The Orbis host changed during sign-in.") }

        // Prove the token works for the video API before calling it
        // connected, so a server-side misconfiguration shows up here
        // rather than mid-export.
        let probe = OrbisClient(host: host, token: { response.access_token })
        let me: OrbisUser
        do {
            me = try await probe.me()
        } catch let error as OrbisError {
            if let refresh = response.refresh_token { await Self.revoke(refresh, host: host) }
            switch error {
            case .tokenInvalid, .permissionDenied:
                throw OrbisError.signInFailed("Orbis signed you in, but its video API refused the sign-in. Check that the Pepper app is enabled for your Orbis account.")
            default:
                throw error
            }
        }

        guard let refresh = response.refresh_token, !refresh.isEmpty else {
            throw OrbisError.signInFailed("Orbis didn't return a refresh token, so Pepper can't stay signed in.")
        }
        try OrbisKeychain.saveRefreshToken(refresh, host: host)
        accessToken = response.access_token
        accessTokenExpiry = Date().addingTimeInterval(response.expires_in ?? 3600)
        isConnected = true
        setUserName(response.user ?? me)
        PepperDebug.log("ORBIS: signed in as \(userName ?? "?")")
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    /// Forget this host's session and revoke it on the server.
    func signOut() async {
        let host = self.host
        let refresh = OrbisKeychain.loadRefreshToken(host: host)
        forgetSession()
        if let refresh { await Self.revoke(refresh, host: host) }
    }

    /// Re-check who we're connected as (Settings' "Test connection").
    func verify() async throws -> String {
        let me = try await client().me()
        setUserName(me)
        return userName ?? "?"
    }

    // MARK: - Credentials

    private func currentToken() async throws -> String {
        guard isConnected else { throw OrbisError.tokenMissing }
        if let accessToken, accessTokenExpiry.timeIntervalSinceNow > 60 { return accessToken }
        return try await refreshAccessToken()
    }

    /// Concurrent callers share one refresh. Only an explicit rejection
    /// of the refresh token ends the session; network or server errors
    /// keep it so a later attempt can succeed.
    private func refreshAccessToken() async throws -> String {
        // Joiners just take the token; the first caller stores the result.
        if let refreshTask { return try await refreshTask.value.access_token }
        let host = self.host
        guard let refresh = OrbisKeychain.loadRefreshToken(host: host) else {
            forgetSession()
            throw OrbisError.tokenInvalid
        }
        let task = Task {
            try await Self.exchange(host: host, form: [
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": Self.clientID,
            ])
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let response = try await task.value
            guard self.host == host else { throw OrbisError.tokenMissing }
            if let rotated = response.refresh_token, !rotated.isEmpty {
                try OrbisKeychain.saveRefreshToken(rotated, host: host)
            }
            accessToken = response.access_token
            accessTokenExpiry = Date().addingTimeInterval(response.expires_in ?? 3600)
            if let user = response.user { setUserName(user) }
            return response.access_token
        } catch OrbisError.oauthRejected(let code) where code == "invalid_grant" || code == "401" {
            // Revoked from Orbis's Connected Devices, expired, or replayed.
            PepperDebug.log("ORBIS: refresh token rejected (\(code)); signing out")
            forgetSession()
            throw OrbisError.tokenInvalid
        }
    }

    /// The API refused the access token (401): drop it and refresh once —
    /// true means "retry with the new one". If the refresh is refused too,
    /// the session is forgotten and Settings shows "Not connected".
    private func credentialRejected() async -> Bool {
        guard isConnected else { return false }
        accessToken = nil
        accessTokenExpiry = .distantPast
        return (try? await refreshAccessToken()) != nil
    }

    // MARK: - State

    /// Pick up a host change. Also called directly by Settings right
    /// after it commits the field, so an action that immediately follows
    /// uses the new host (the notification hop is asynchronous).
    func syncHost() {
        let newHost = OrbisSettings.shared.host
        guard newHost != host else { return }
        cancelSignIn()
        host = newHost
        accessToken = nil
        accessTokenExpiry = .distantPast
        reload()
    }

    /// Re-derive state from the Keychain for the current host.
    private func reload() {
        isConnected = OrbisKeychain.loadRefreshToken(host: host) != nil
        userName = isConnected ? OrbisSettings.shared.userName(forHost: host) : nil
    }

    private func forgetSession() {
        OrbisKeychain.deleteRefreshToken(host: host)
        accessToken = nil
        accessTokenExpiry = .distantPast
        isConnected = false
        userName = nil
        OrbisSettings.shared.setUserName(nil, forHost: host)
    }

    private func setUserName(_ user: OrbisUser) {
        userName = user.name ?? user.email ?? "Connected"
        OrbisSettings.shared.setUserName(userName, forHost: host)
    }

    // MARK: - OAuth (PKCE + loopback)

    private static func authorize(host: String) async throws -> OrbisTokenResponse {
        let verifier = randomURLSafe(bytes: 48)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(bytes: 16)

        let server = try OAuthLoopbackServer()
        let port = try await server.start()
        defer { server.stop() }
        let redirectURI = "http://127.0.0.1:\(port)/callback"

        guard var components = URLComponents(string: "https://\(host)/oauth/authorize") else {
            throw OrbisError.invalidHost(host)
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scope),
        ]
        guard let url = components.url else { throw OrbisError.invalidHost(host) }
        NSWorkspace.shared.open(url)

        let params = try await server.waitForCallback(timeout: 300)
        if let error = params["error"] {
            throw OrbisError.signInFailed(params["error_description"] ?? error)
        }
        // The reply must answer *this* request — the check that makes an
        // injected or replayed redirect useless.
        guard params["state"] == state else {
            throw OrbisError.signInFailed("The sign-in reply didn't match this request.")
        }
        guard let code = params["code"], !code.isEmpty else {
            throw OrbisError.signInFailed("Orbis didn't return an authorization code.")
        }
        return try await exchange(host: host, form: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "client_id": clientID,
            "redirect_uri": redirectURI,
        ])
    }

    private static func exchange(host: String, form: [String: String]) async throws -> OrbisTokenResponse {
        guard let url = URL(string: "https://\(host)/oauth/token") else { throw OrbisError.invalidHost(host) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncode(form).utf8)
        request.timeoutInterval = 30
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let e as URLError {
            throw OrbisError.networkError(e)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let code = body?["error"] as? String, status == 400 || status == 401 {
                throw OrbisError.oauthRejected(code)
            }
            if status == 401 { throw OrbisError.oauthRejected("401") }
            throw OrbisError.serverError(status: status, body: String(data: data, encoding: .utf8))
        }
        do {
            return try JSONDecoder().decode(OrbisTokenResponse.self, from: data)
        } catch {
            throw OrbisError.decodingError(error)
        }
    }

    /// Best effort — sign-out shouldn't hang on the network.
    private static func revoke(_ refreshToken: String, host: String) async {
        guard let url = URL(string: "https://\(host)/oauth/revoke") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(["token": refreshToken, "client_id": clientID]).utf8)
        request.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
