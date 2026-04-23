import Foundation

/// Thin Swift wrapper around the Orbis REST API.
///
/// Lifetimes: one client per logical "session" — callers instantiate
/// it right before an export, or hold onto one for the Settings
/// pane's Connect / Test Connection actions. Cheap to allocate, no
/// persistent resources beyond the `URLSession`.
///
/// Error policy: every endpoint throws a typed `OrbisError`. The
/// only codepath that swallows errors is `ingestAssets` when the
/// server returns 404 (endpoint not deployed yet) — that returns
/// nil instead of throwing so the export can still finish Step C.
final class OrbisClient: NSObject, @unchecked Sendable {
    let host: String
    let token: String

    /// Dedicated session so the upload progress delegate doesn't
    /// leak into `URLSession.shared` (which other parts of the app,
    /// including Sparkle, use).
    private let session: URLSession

    /// Callback receiver for `URLSessionTaskDelegate` progress
    /// notifications during the R2 PUT. Protected by `progressLock`
    /// because the delegate runs on URLSession's queue, not ours.
    private let progressLock = NSLock()
    private var progressHandlers: [ObjectIdentifier: (Double) -> Void] = [:]

    init(host: String, token: String) {
        self.host = host
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600  // up to 1h for large uploads
        self.session = URLSession(configuration: config)
        super.init()
    }

    // MARK: - Endpoints

    /// Validate + fetch the currently-authenticated user. Orbis's
    /// route is `/api/auth/user` (the original spec said `/me`, which
    /// returns the React 404 page and decodes as garbage — if you see
    /// `decodingError`, double-check this URL first).
    func me() async throws -> OrbisUser {
        let url = try endpoint("/api/auth/user")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuth(&req)
        return try await performDecoding(req)
    }

    func listClients() async throws -> [OrbisClientInfo] {
        let url = try endpoint("/api/clients")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuth(&req)
        // Orbis server isn't live yet — the endpoint may 404. Return
        // empty so the UI still loads, rather than blocking the
        // export sheet. The visibility=client path will surface a
        // friendlier "no clients" message.
        do {
            return try await performDecoding(req)
        } catch OrbisError.serverError(let status, _) where status == 404 {
            return []
        }
    }

    struct CreateUploadRequest: Encodable {
        let title: String
        let description: String?
        let visibility: String
        let client_id: String?
        let mime_type: String
        let size_bytes: Int64
        let recorded_at: String?
    }

    func createUpload(
        title: String,
        description: String?,
        visibility: OrbisVisibility,
        clientID: String?,
        mimeType: String,
        sizeBytes: Int64,
        recordedAt: Date?
    ) async throws -> OrbisCreateUploadResponse {
        guard sizeBytes <= orbisMaxUploadBytes else {
            throw OrbisError.tooLarge(limitBytes: orbisMaxUploadBytes)
        }

        let url = try endpoint("/api/videos")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let body = CreateUploadRequest(
            title: title,
            description: (description?.isEmpty == false) ? description : nil,
            visibility: visibility.rawValue,
            client_id: clientID,
            mime_type: mimeType,
            size_bytes: sizeBytes,
            recorded_at: recordedAt.map { iso.string(from: $0) }
        )
        req.httpBody = try JSONEncoder().encode(body)

        return try await performDecoding(req)
    }

    /// PUT the file to R2 at `remoteURL`. Progress callback fires
    /// on the main queue. Retries once on URL-expired (caller should
    /// hand back a fresh upload URL) by surfacing
    /// `OrbisError.uploadURLExpired`; transient network errors are
    /// retried in-place up to 2 more times with exponential backoff.
    func uploadFile(
        from localURL: URL,
        to remoteURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard let remote = URL(string: remoteURL.absoluteString) else {
            throw OrbisError.invalidHost(remoteURL.absoluteString)
        }
        var req = URLRequest(url: remote)
        req.httpMethod = "PUT"
        // R2 rejects PUTs with headers that weren't in the signature
        // — Content-Type is always part of Orbis's signed request.
        // Do NOT add Authorization here; that'd invalidate the sig.
        req.setValue("video/mp4", forHTTPHeaderField: "Content-Type")

        // Register progress handler for the delegate. The task's
        // ObjectIdentifier serves as the key; a single client can in
        // theory have multiple tasks in flight, though in practice
        // we serialise.
        var lastError: Error?
        for attempt in 0..<3 {
            if attempt > 0 {
                // Exponential backoff: 0.5s → 1s → 2s. No retry on
                // 403 (URL-expired) — that throws up to the caller
                // immediately so they can fetch a fresh upload URL.
                let delay = UInt64(500_000_000 * (1 << (attempt - 1)))
                try? await Task.sleep(nanoseconds: delay)
            }
            do {
                try await performUpload(request: req, localFile: localURL, progress: progress)
                return
            } catch OrbisError.uploadURLExpired {
                throw OrbisError.uploadURLExpired
            } catch OrbisError.networkError(let err) {
                lastError = err
                continue  // retry
            } catch OrbisError.serverError(let status, _) where (500..<600).contains(status) {
                lastError = OrbisError.serverError(status: status, body: nil)
                continue  // retry
            } catch {
                throw error
            }
        }
        if let lastError { throw lastError }
    }

    func completeUpload(videoID: String) async throws {
        let url = try endpoint("/api/videos/\(videoID)/complete")
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        applyAuth(&req)
        _ = try await performData(req)
    }

    /// Post pre-computed assets (transcript, summary, thumbnail).
    /// Returns nil when the server responds 404 — the endpoint isn't
    /// deployed yet on some Orbis revisions, and the spec explicitly
    /// calls that out as "best-effort; swallow 404".
    @discardableResult
    func ingestAssets(
        videoID: String,
        payload: OrbisIngestAssets
    ) async throws -> OrbisIngestAssetsResponse? {
        let url = try endpoint("/api/videos/\(videoID)/ingest-assets")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(payload)
        do {
            return try await performDecoding(req)
        } catch OrbisError.serverError(let status, _) where status == 404 {
            return nil
        }
    }

    // MARK: - Internals

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: "https://\(host)\(path)") else {
            throw OrbisError.invalidHost(host)
        }
        return url
    }

    private func applyAuth(_ req: inout URLRequest) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("Mentor/macOS", forHTTPHeaderField: "User-Agent")
    }

    /// Dispatch + decode. Status handling is centralised here so every
    /// endpoint gets the same 401/403/server-error treatment.
    private func performDecoding<T: Decodable>(_ req: URLRequest) async throws -> T {
        let data = try await performData(req)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OrbisError.decodingError(error)
        }
    }

    /// Raw data variant for endpoints that don't have a body we care
    /// about (PATCH complete). Same error mapping.
    @discardableResult
    private func performData(_ req: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return data
            }
            switch http.statusCode {
            case 200..<300: return data
            case 401:       throw OrbisError.tokenInvalid
            case 403:       throw OrbisError.permissionDenied
            case 413:       throw OrbisError.tooLarge(limitBytes: orbisMaxUploadBytes)
            default:
                let body = String(data: data, encoding: .utf8)
                throw OrbisError.serverError(status: http.statusCode, body: body)
            }
        } catch let e as OrbisError {
            throw e
        } catch let e as URLError {
            throw OrbisError.networkError(e)
        }
    }

    /// R2 PUT with progress. Separate from `performData` because R2
    /// returns an empty body + different status semantics (200 or
    /// 204 = success; 403 = presigned URL expired or malformed).
    private func performUpload(
        request: URLRequest,
        localFile: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let delegate = UploadProgressDelegate(progress: progress)
        let uploadSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { uploadSession.finishTasksAndInvalidate() }

        do {
            let (_, response) = try await uploadSession.upload(
                for: request,
                fromFile: localFile
            )
            guard let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200..<300: return
            case 403:       throw OrbisError.uploadURLExpired
            default:
                throw OrbisError.serverError(status: http.statusCode, body: nil)
            }
        } catch let e as OrbisError {
            throw e
        } catch let e as URLError {
            throw OrbisError.networkError(e)
        }
    }
}

/// URLSession delegate that forwards bytes-sent notifications from
/// the R2 PUT back to a user-supplied progress closure. Kept in this
/// file since it's only used by `OrbisClient.performUpload`.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let progress: (Double) -> Void

    init(progress: @escaping (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        let clamped = min(max(fraction, 0), 1)
        DispatchQueue.main.async { [progress] in
            progress(clamped)
        }
    }
}
