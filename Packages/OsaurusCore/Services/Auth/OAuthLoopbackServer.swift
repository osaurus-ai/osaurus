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
    /// Hosts whose cross-origin requests to the loopback callback get CORS
    /// headers echoed back. Required by providers (e.g. xAI/Grok) whose auth
    /// page delivers the authorization code via a browser `fetch()` rather than
    /// a top-level redirect — without `Access-Control-Allow-Origin` the fetch is
    /// blocked and the page falls back to a manual code-paste screen. Empty for
    /// redirect-based providers (Codex, OpenRouter, MCP), which need no CORS.
    public let corsOriginAllowlist: [String]
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
        callbackPath: String = "/callback",
        corsOriginAllowlist: [String] = []
    ) throws {
        self.expectedState = expectedState
        self.callbackPath = callbackPath.hasPrefix("/") ? callbackPath : "/" + callbackPath
        self.corsOriginAllowlist = corsOriginAllowlist
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

    /// What to do with a parsed HTTP request on the loopback server.
    private enum CallbackOutcome {
        /// Not our authorization callback (favicon probe, CORS preflight, wrong
        /// path/method). Respond politely but keep listening — must NOT resolve
        /// the awaiter, or stray browser requests would abort the flow.
        case ignore(status: String)
        /// A request on the configured callback path. Resolve the awaiter with
        /// this result (success or a real OAuth failure).
        case deliver(Result<OAuthCallbackResult, Error>)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: Self.queue)
        // OAuth callbacks are well under 8KB even with extra params; we only need
        // the request line (and Origin header) for HTTP/1.1 requests from a browser.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) }
            let requestLine = request?.components(separatedBy: "\r\n").first
            let origin = self.parseOrigin(from: request)
            let parts = requestLine?.split(separator: " ") ?? []
            let method = parts.first.map(String.init) ?? ""

            // CORS preflight: the auth page probes the loopback before delivering
            // the code via fetch(). Answer it without completing the flow.
            if method == "OPTIONS" {
                self.sendPreflight(origin: origin, on: connection)
                return
            }

            let outcome = self.parseCallback(requestLine: requestLine)
            switch outcome {
            case .ignore(let status):
                self.sendSimple(status: status, origin: origin, on: connection)
            case .deliver(let result):
                self.sendResponse(for: result, origin: origin, on: connection)
                self.complete(result)
            }
        }
    }

    /// Extract the `Origin` request header value (case-insensitive), if present.
    private func parseOrigin(from request: String?) -> String? {
        guard let request else { return nil }
        for line in request.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("origin:") {
                let value = line.dropFirst("origin:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// `Access-Control-Allow-Origin` value to echo, if `origin`'s host is on the
    /// allowlist; otherwise `nil` (no CORS headers — same-origin/redirect flows).
    private func accessControlAllowOrigin(for origin: String?) -> String? {
        guard !corsOriginAllowlist.isEmpty,
            let origin,
            let host = URLComponents(string: origin)?.host,
            corsOriginAllowlist.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame })
        else {
            return nil
        }
        return origin
    }

    private func parseCallback(requestLine: String?) -> CallbackOutcome {
        guard let requestLine, requestLine.hasPrefix("GET ") else {
            return .ignore(status: "405 Method Not Allowed")
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
            let callbackURL = URL(string: "http://127.0.0.1\(parts[1])")
        else {
            return .ignore(status: "400 Bad Request")
        }

        // Ignore anything that isn't on the configured callback path so unrelated
        // browser probes (favicon.ico etc.) don't abort the flow.
        guard callbackURL.path == callbackPath else {
            return .ignore(status: "404 Not Found")
        }

        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value: (String) -> String? = { name in
            items.first(where: { $0.name == name })?.value
        }

        // Per RFC 6749 §4.1.2.1: surface server-side errors with description.
        if let error = value("error"), !error.isEmpty {
            return .deliver(
                .failure(
                    OAuthLoopbackError.oauthError(error: error, description: value("error_description"))
                )
            )
        }
        guard let state = value("state"), state == expectedState else {
            return .deliver(.failure(OAuthLoopbackError.stateMismatch))
        }
        guard let code = value("code"), !code.isEmpty else {
            return .deliver(.failure(OAuthLoopbackError.missingCode))
        }
        return .deliver(.success(OAuthCallbackResult(code: code, state: state, url: callbackURL)))
    }

    /// CORS preflight response. Does not complete the flow.
    private func sendPreflight(origin: String?, on connection: NWConnection) {
        send(
            status: "204 No Content",
            headers: corsHeaders(for: origin, includePreflight: true),
            on: connection
        )
    }

    /// Minimal status-only response for ignored probes. Does not complete the flow.
    private func sendSimple(status: String, origin: String?, on connection: NWConnection) {
        send(status: status, headers: corsHeaders(for: origin, includePreflight: false), on: connection)
    }

    private func sendResponse(
        for result: Result<OAuthCallbackResult, Error>,
        origin: String?,
        on connection: NWConnection
    ) {
        let success = (try? result.get()) != nil
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
        send(
            status: success ? "200 OK" : "400 Bad Request",
            headers: corsHeaders(for: origin, includePreflight: false),
            contentType: "text/html; charset=utf-8",
            body: body,
            on: connection
        )
    }

    /// CORS response headers to echo for an allowlisted `origin`, in deterministic
    /// order. Empty for non-allowlisted origins (redirect-based flows need none).
    private func corsHeaders(for origin: String?, includePreflight: Bool) -> [(String, String)] {
        guard let allowOrigin = accessControlAllowOrigin(for: origin) else { return [] }
        var headers = [("Access-Control-Allow-Origin", allowOrigin)]
        if includePreflight {
            headers.append(("Access-Control-Allow-Methods", "GET, OPTIONS"))
            headers.append(("Access-Control-Allow-Headers", "*"))
            headers.append(("Access-Control-Max-Age", "600"))
        }
        headers.append(("Vary", "Origin"))
        return headers
    }

    /// Write a minimal HTTP/1.1 response and close the connection.
    private func send(
        status: String,
        headers: [(String, String)] = [],
        contentType: String? = nil,
        body: String = "",
        on connection: NWConnection
    ) {
        var lines = ["HTTP/1.1 \(status)"]
        for (name, value) in headers {
            lines.append("\(name): \(value)")
        }
        if let contentType {
            lines.append("Content-Type: \(contentType)")
        }
        lines.append("Content-Length: \(body.utf8.count)")
        lines.append("Connection: close")
        lines.append("")
        lines.append(body)
        connection.send(
            content: Data(lines.joined(separator: "\r\n").utf8),
            completion: .contentProcessed { _ in connection.cancel() }
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
