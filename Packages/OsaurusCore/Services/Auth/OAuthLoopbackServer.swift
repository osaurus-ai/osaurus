//
//  OAuthLoopbackServer.swift
//  osaurus
//
//  RFC 8252 §7.3 loopback redirect server for OAuth on macOS desktop.
//
//  Listens on `127.0.0.1` (loopback IP — *not* `localhost`, per spec) and
//  resolves an awaiter when the browser hits `/<callbackPath>?code=...&state=...`.
//
//  Two modes:
//    - `port: .fixed(N)` — required by servers that have N hardcoded in their
//      registered redirect URI list (the original Codex flow uses 1455).
//    - `port: .ephemeral` — the recommended default per RFC 8252 so concurrent
//      OAuth flows don't collide. The OS picks an unused port and we expose
//      it via `boundPort` so the caller can build the redirect URI.
//

import Foundation
import Network

public enum OAuthLoopbackError: LocalizedError, Sendable {
    case invalidCallback
    case bindFailed(String)
    case stateMismatch
    case missingCode
    case oauthError(error: String, description: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidCallback:
            return "OAuth provider did not return a valid authorization callback"
        case .bindFailed(let message):
            return "Could not bind loopback OAuth callback server: \(message)"
        case .stateMismatch:
            return "OAuth state mismatch — possible CSRF or stale callback"
        case .missingCode:
            return "OAuth provider returned no authorization code"
        case .oauthError(let error, let description):
            if let description, !description.isEmpty {
                return "OAuth provider returned error \(error): \(description)"
            }
            return "OAuth provider returned error \(error)"
        }
    }
}

/// Port-binding strategy for the loopback server.
public enum LoopbackPort: Sendable, Equatable {
    case fixed(UInt16)
    case ephemeral
}

/// Successful callback parameters surfaced to callers.
public struct OAuthCallbackResult: Sendable, Equatable {
    /// `code` query parameter (already validated as non-empty).
    public let code: String
    /// Echoed `state` (already validated to match the expected value).
    public let state: String
    /// Full callback URL including any extra query items the provider added.
    public let url: URL
}

/// Loopback HTTP server that captures one OAuth authorization-code redirect.
///
/// Public-by-default so MCP and Codex paths share the implementation.
public final class OAuthLoopbackServer: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "ai.osaurus.oauth-loopback")

    public let expectedState: String
    public let callbackPath: String
    private let listener: NWListener
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OAuthCallbackResult, Error>?
    private var pendingResult: Result<OAuthCallbackResult, Error>?
    private var isCompleted = false

    /// Continuation that resumes when the listener first reaches `.ready` or
    /// `.failed`. Resumed exactly once from `stateUpdateHandler`; subsequent
    /// state changes still propagate failures into `waitForCallback`.
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var hasReachedReady = false

    /// Create the listener. Throws if the port cannot be bound.
    /// - Parameters:
    ///   - expectedState: CSRF token; must match the `state` echoed by the provider.
    ///   - port: Bind strategy — fixed for legacy Codex, ephemeral for new MCP flow.
    ///   - callbackPath: Path the server will accept; e.g. `/auth/callback` (Codex) or
    ///     `/callback` (recommended for MCP). Path-only; no leading host.
    public init(
        expectedState: String,
        port: LoopbackPort,
        callbackPath: String = "/callback"
    ) throws {
        self.expectedState = expectedState
        self.callbackPath = callbackPath.hasPrefix("/") ? callbackPath : "/" + callbackPath
        do {
            switch port {
            case .fixed(let value):
                let nwPort = NWEndpoint.Port(rawValue: value) ?? .any
                self.listener = try NWListener(using: .tcp, on: nwPort)
            case .ephemeral:
                self.listener = try NWListener(using: .tcp, on: .any)
            }
        } catch {
            throw OAuthLoopbackError.bindFailed(error.localizedDescription)
        }
    }

    /// The port the listener is actually bound to. Only valid after `await start()`
    /// has returned successfully — before that, NWListener may report the
    /// requested port (`0` for `.ephemeral`) instead of the kernel-assigned one.
    public var boundPort: UInt16? {
        listener.port?.rawValue
    }

    /// Bind and begin listening. Returns once the kernel has assigned a port
    /// (`stateUpdateHandler` reached `.ready`) or throws `bindFailed` if the
    /// listener moves directly to `.failed`. After this returns, `boundPort`
    /// is guaranteed to be non-zero.
    public func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleStateChange(state)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            // The state handler may fire `.ready` before we install the continuation
            // if the kernel binds synchronously; that can't happen with NWListener
            // in practice (the start call below is what kicks off binding), but
            // defensively check anyway.
            if hasReachedReady {
                lock.unlock()
                continuation.resume()
                return
            }
            startContinuation = continuation
            lock.unlock()
            listener.start(queue: Self.queue)
        }
    }

    private func handleStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            lock.lock()
            hasReachedReady = true
            let cont = startContinuation
            startContinuation = nil
            lock.unlock()
            cont?.resume()
        case .failed(let error):
            let wrapped = OAuthLoopbackError.bindFailed(error.localizedDescription)
            lock.lock()
            let cont = startContinuation
            startContinuation = nil
            lock.unlock()
            if let cont {
                cont.resume(throwing: wrapped)
            } else {
                // Listener failed *after* binding (e.g. the OS revoked the port).
                // Surface that to anyone awaiting a callback.
                complete(.failure(wrapped))
            }
        default:
            break
        }
    }

    public func waitForCallback() async throws -> OAuthCallbackResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                lock.unlock()
                continuation.resume(with: pendingResult)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    public func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: Self.queue)
        // OAuth callbacks are well under 8KB even with extra params; we only need
        // the request line for HTTP/1.1 GETs from a browser.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let result = self.parseCallback(from: data)
            self.sendResponse(for: result, on: connection)
            self.complete(result)
        }
    }

    private func parseCallback(from data: Data?) -> Result<OAuthCallbackResult, Error> {
        guard let data,
            let request = String(data: data, encoding: .utf8),
            let requestLine = request.components(separatedBy: "\r\n").first,
            requestLine.hasPrefix("GET ")
        else {
            return .failure(OAuthLoopbackError.invalidCallback)
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
            let callbackURL = URL(string: "http://127.0.0.1\(parts[1])")
        else {
            return .failure(OAuthLoopbackError.invalidCallback)
        }

        // Reject anything that isn't on the configured callback path so unrelated
        // browser probes (favicon.ico etc.) don't accidentally complete the flow.
        guard callbackURL.path == callbackPath else {
            return .failure(OAuthLoopbackError.invalidCallback)
        }

        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value: (String) -> String? = { name in
            items.first(where: { $0.name == name })?.value
        }

        // Per RFC 6749 §4.1.2.1: surface server-side errors with description.
        if let error = value("error"), !error.isEmpty {
            return .failure(
                OAuthLoopbackError.oauthError(error: error, description: value("error_description"))
            )
        }
        guard let state = value("state"), state == expectedState else {
            return .failure(OAuthLoopbackError.stateMismatch)
        }
        guard let code = value("code"), !code.isEmpty else {
            return .failure(OAuthLoopbackError.missingCode)
        }
        return .success(OAuthCallbackResult(code: code, state: state, url: callbackURL))
    }

    private func sendResponse(for result: Result<OAuthCallbackResult, Error>, on connection: NWConnection) {
        let success: Bool = {
            if case .success = result { return true }
            return false
        }()
        let title = success ? "Sign-in complete" : "Sign-in failed"
        let message =
            success
            ? "You can return to Osaurus."
            : "Osaurus could not complete the sign-in. Please try again."
        let body = """
            <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
            <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 32px;">
            <h1>\(title)</h1><p>\(message)</p><script>window.close();</script></body></html>
            """
        let status = success ? "200 OK" : "400 Bad Request"
        let response = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
            "",
            body,
        ].joined(separator: "\r\n")
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private func complete(_ result: Result<OAuthCallbackResult, Error>) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }
}
