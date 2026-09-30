import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 for an OAuth redirect
/// (`http://127.0.0.1:<port>/callback`). Adapted from Muesli's
/// `LoopbackServer`, with two fixes:
///   • a redirect that lands before `waitForCallback` is called (the
///     browser can bounce straight back when the user is already signed
///     in) is kept rather than dropped — Muesli's version would then
///     wait out its timeout;
///   • only `/callback` counts, so a stray `/favicon.ico` or probe can't
///     end the wait.
/// Waiting honours Task cancellation (the Settings "Cancel" button).
final class OAuthLoopbackServer: @unchecked Sendable {
    enum LoopbackError: LocalizedError {
        case listenerFailed(String)
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .listenerFailed(let why): return "Couldn't listen for the sign-in reply: \(why)"
            case .timedOut:                return "Sign-in timed out. Try again."
            case .cancelled:               return "Sign-in was cancelled."
            }
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.darrell.pepper.oauth-loopback")
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<[String: String], Error>?
    /// A result that arrived before anyone was waiting for it.
    private var pendingResult: Result<[String: String], Error>?
    private var connections: [NWConnection] = []
    private let successMessage: String

    init(successMessage: String) throws {
        self.successMessage = successMessage
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw LoopbackError.listenerFailed(error.localizedDescription)
        }
    }

    /// Start listening; returns the port the OS picked.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            lock.lock(); readyContinuation = c; lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.resumeReady(.success(self.listener.port?.rawValue ?? 0))
                case .failed(let error):
                    self.resumeReady(.failure(LoopbackError.listenerFailed(error.localizedDescription)))
                    self.finish(.failure(LoopbackError.listenerFailed(error.localizedDescription)))
                case .cancelled:
                    self.resumeReady(.failure(LoopbackError.cancelled))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    /// The redirect's query parameters (`code` + `state`, or `error`).
    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: String], Error>) in
                lock.lock()
                if let pending = pendingResult {
                    pendingResult = nil
                    lock.unlock()
                    c.resume(with: pending)
                    return
                }
                callbackContinuation = c
                lock.unlock()
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(LoopbackError.timedOut))
                }
            }
        } onCancel: {
            finish(.failure(LoopbackError.cancelled))
        }
    }

    func stop() {
        lock.lock()
        let open = connections
        connections.removeAll()
        lock.unlock()
        open.forEach { $0.cancel() }
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let (path, params) = Self.parse(request)
            let isCallback = path == "/callback" && (params["code"] != nil || params["error"] != nil)
            let body: String
            if !isCallback {
                body = Self.page("Waiting for Orbis sign-in…")
            } else if let error = params["error"] {
                body = Self.page("Sign-in didn't complete (\(Self.escape(params["error_description"] ?? error))). You can close this window and try again from Pepper.")
            } else {
                body = Self.page("\(successMessage) You can close this window.")
            }
            let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            if isCallback { self.finish(.success(params)) }
        }
    }

    private static func parse(_ request: String) -> (path: String, params: [String: String]) {
        guard let firstLine = request.split(separator: "\r\n", maxSplits: 1).first else { return ("", [:]) }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
            return ("", [:])
        }
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] { params[item.name] = item.value ?? "" }
        return (components.path, params)
    }

    private static func page(_ message: String) -> String {
        "<html><head><meta charset='utf-8'><title>Pepper</title></head><body style='font-family:-apple-system;padding:40px'><h2>Pepper</h2><p>\(message)</p></body></html>"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func resumeReady(_ result: Result<UInt16, Error>) {
        lock.lock(); let c = readyContinuation; readyContinuation = nil; lock.unlock()
        c?.resume(with: result)
    }

    /// First result wins; later ones (timeout after success, etc.) are dropped.
    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        if let c = callbackContinuation {
            callbackContinuation = nil
            lock.unlock()
            c.resume(with: result)
            return
        }
        if pendingResult == nil { pendingResult = result }
        lock.unlock()
    }
}
