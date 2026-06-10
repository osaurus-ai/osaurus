//
//  SecureChannelClient.swift
//  osaurus
//
//  Client side of the Osaurus Secure Channel. Owns one established session
//  per remote Osaurus provider (keyed by provider id + pinned agent address),
//  performs the `/secure/session` handshake on demand, verifies the server's
//  transcript signature against the address pinned at pairing time, and
//  re-handshakes when a session expires or the server forgets it (restart).
//
//  `RemoteProviderService` hands its fully built plaintext `URLRequest` to
//  `wrappedRequest(for:provider:urlSession:)` and sends the returned envelope
//  instead — the Bearer token, path, and body all travel inside the
//  ciphertext, so after pairing no credential or prompt content ever crosses
//  the LAN or the relay in plaintext.
//

import Foundation

public enum SecureChannelClientError: Error, LocalizedError, Equatable {
    /// The peer answered 404 on `/secure/session` — it predates the Secure
    /// Channel and cannot accept encrypted agent traffic.
    case peerUnsupported
    /// The provider has no pinned remote agent address to verify against.
    case missingAgentAddress
    /// The peer's transcript signature did not recover the pinned address.
    case identityMismatch
    case handshakeFailed(String)
    /// The encrypted response stream ended without an authenticated `fin`
    /// frame — silent truncation by a relay or middlebox.
    case streamTruncated
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .peerUnsupported:
            return
                "This peer's Osaurus version does not support end-to-end encryption. Ask them to upgrade Osaurus."
        case .missingAgentAddress:
            return "This provider has no pinned agent identity. Re-pair with the remote agent."
        case .identityMismatch:
            return
                "The remote peer failed identity verification — it is not the agent you paired with. Connection refused."
        case .handshakeFailed(let message):
            return "Secure channel handshake failed: \(message)"
        case .streamTruncated:
            return "The encrypted response stream was truncated before completion."
        case .decryptionFailed:
            return "Failed to decrypt the peer's response."
        }
    }
}

public actor SecureChannelClient {
    public static let shared = SecureChannelClient()

    private struct CacheKey: Hashable {
        let providerId: UUID
        let agentAddress: String
    }

    private var sessions: [CacheKey: SecureChannelSession] = [:]
    private var pendingHandshakes: [CacheKey: Task<SecureChannelSession, Error>] = [:]
    /// Don't reuse a session that's about to expire mid-stream.
    private let expiryMargin: TimeInterval = 60

    init() {}

    // MARK: - Session Management

    /// Returns an established (cached or fresh) session for the provider.
    /// Concurrent callers share one handshake.
    public func session(
        for provider: RemoteProvider,
        urlSession: URLSession
    ) async throws -> SecureChannelSession {
        guard let agentAddress = provider.remoteAgentAddress, !agentAddress.isEmpty else {
            throw SecureChannelClientError.missingAgentAddress
        }
        let key = CacheKey(providerId: provider.id, agentAddress: agentAddress.lowercased())

        if let cached = sessions[key],
            Date().addingTimeInterval(expiryMargin) < cached.expiresAt
        {
            return cached
        }
        sessions.removeValue(forKey: key)

        if let pending = pendingHandshakes[key] {
            return try await pending.value
        }

        let task = Task<SecureChannelSession, Error> {
            try await Self.handshake(
                provider: provider,
                agentAddress: agentAddress,
                urlSession: urlSession
            )
        }
        pendingHandshakes[key] = task
        defer { pendingHandshakes.removeValue(forKey: key) }

        let session = try await task.value
        sessions[key] = session
        return session
    }

    /// Drop the cached session (server restarted / answered
    /// `secure_session_unknown`); the next call re-handshakes.
    public func invalidateSession(for provider: RemoteProvider) {
        guard let agentAddress = provider.remoteAgentAddress else { return }
        sessions.removeValue(
            forKey: CacheKey(providerId: provider.id, agentAddress: agentAddress.lowercased())
        )
    }

    // MARK: - Request Wrapping

    /// Seal a fully built plaintext request into a `/secure/call` envelope.
    /// Returns the outer request to send and the opener for its response
    /// frames. Re-handshakes once internally if the cached session expired.
    public func wrappedRequest(
        for original: URLRequest,
        provider: RemoteProvider,
        urlSession: URLSession
    ) async throws -> (request: URLRequest, opener: SecureResponseOpener) {
        var channel = try await session(for: provider, urlSession: urlSession)

        guard let url = original.url else {
            throw SecureChannelClientError.handshakeFailed("Request has no URL")
        }
        var innerPath = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            innerPath += "?\(query)"
        }
        // Carry custom headers (provider customHeaders etc.) inside the
        // envelope; transport-level headers are rebuilt by the receiver.
        let handledHeaders: Set<String> = [
            "authorization", "accept", "content-type", "content-length", "host", "connection",
        ]
        let extraHeaders = (original.allHTTPHeaderFields ?? [:]).filter {
            !handledHeaders.contains($0.key.lowercased())
        }
        let inner = SecureChannel.InnerRequest(
            method: original.httpMethod ?? "GET",
            path: innerPath,
            authorization: original.value(forHTTPHeaderField: "Authorization"),
            accept: original.value(forHTTPHeaderField: "Accept"),
            contentType: original.value(forHTTPHeaderField: "Content-Type"),
            headers: extraHeaders.isEmpty ? nil : extraHeaders,
            body: original.httpBody?.base64urlEncoded
        )
        let innerData = try JSONEncoder().encode(inner)

        let sealed: (call: SecureChannel.CallRequest, requestSeq: UInt64)
        do {
            sealed = try channel.sealCall(innerRequest: innerData)
        } catch SecureChannelError.sessionExpired {
            invalidateSession(for: provider)
            channel = try await session(for: provider, urlSession: urlSession)
            sealed = try channel.sealCall(innerRequest: innerData)
        }

        guard let callURL = provider.url(for: "/secure/call") else {
            throw SecureChannelClientError.handshakeFailed("Could not build /secure/call URL")
        }
        var outer = URLRequest(url: callURL)
        outer.httpMethod = "POST"
        outer.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The outer Accept mirrors the inner one so URLSession / proxies keep
        // streaming semantics for SSE responses.
        outer.setValue(
            inner.accept ?? "application/json",
            forHTTPHeaderField: "Accept"
        )
        outer.timeoutInterval = original.timeoutInterval
        outer.httpBody = try JSONEncoder().encode(sealed.call)

        return (outer, channel.makeResponseOpener(requestSeq: sealed.requestSeq))
    }

    // MARK: - Response Helpers

    /// `true` when an HTTP error body is the server's "unknown/expired
    /// session" rejection — the caller should invalidate and retry once.
    public static func isSessionUnknownError(statusCode: Int, body: Data) -> Bool {
        guard statusCode == 401 else { return false }
        return String(decoding: body, as: UTF8.self).contains("secure_session_unknown")
    }

    /// Decrypt a buffered (non-streaming) `/secure/call` response: a single
    /// `fin` frame whose plaintext is the inner response envelope.
    public static func openBufferedResponse(
        _ data: Data,
        opener: SecureResponseOpener
    ) throws -> SecureChannel.InnerResponse {
        guard let frame = try? JSONDecoder().decode(SecureChannel.Frame.self, from: data) else {
            throw SecureChannelClientError.decryptionFailed
        }
        let plaintext: Data
        let fin: Bool
        do {
            (plaintext, fin) = try opener.open(frame)
        } catch {
            throw SecureChannelClientError.decryptionFailed
        }
        guard fin else { throw SecureChannelClientError.streamTruncated }
        guard let inner = try? JSONDecoder().decode(SecureChannel.InnerResponse.self, from: plaintext)
        else {
            throw SecureChannelClientError.decryptionFailed
        }
        return inner
    }

    // MARK: - Handshake

    private static func handshake(
        provider: RemoteProvider,
        agentAddress: String,
        urlSession: URLSession
    ) async throws -> SecureChannelSession {
        guard let url = provider.url(for: "/secure/session") else {
            throw SecureChannelClientError.handshakeFailed("Could not build /secure/session URL")
        }

        let (ephemeralKey, hello) = SecureChannel.makeClientHello(agentAddress: agentAddress)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(hello)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SecureChannelClientError.handshakeFailed("Invalid response")
        }
        switch http.statusCode {
        case 200:
            break
        case 404:
            throw SecureChannelClientError.peerUnsupported
        case 429:
            throw SecureChannelClientError.handshakeFailed(
                "Peer is rate-limiting handshakes. Try again shortly."
            )
        default:
            let message = String(decoding: data.prefix(300), as: UTF8.self)
            throw SecureChannelClientError.handshakeFailed("HTTP \(http.statusCode): \(message)")
        }

        guard let serverHello = try? JSONDecoder().decode(SecureChannel.ServerHello.self, from: data)
        else {
            throw SecureChannelClientError.handshakeFailed("Malformed server hello")
        }

        do {
            return try SecureChannel.establishClientSession(
                hello: hello,
                ephemeralKey: ephemeralKey,
                serverHello: serverHello,
                expectedAgentAddress: agentAddress
            )
        } catch SecureChannelError.identityMismatch {
            throw SecureChannelClientError.identityMismatch
        } catch {
            throw SecureChannelClientError.handshakeFailed("Key agreement failed")
        }
    }
}

// MARK: - Streaming Frame Decoder

/// Incremental decoder for an encrypted SSE response: feeds raw outer bytes,
/// returns decrypted inner bytes (the original SSE stream). Frames arrive as
/// `data: {json}\n\n` events; the opener enforces strict ordering and the
/// stream must end with an authenticated `fin` frame (`verifyCompleted()`)
/// or the response was truncated.
public final class SecureFrameStreamDecoder {
    private let opener: SecureResponseOpener
    private var buffer = Data()
    private static let eventSeparator = Data("\n\n".utf8)

    public init(opener: SecureResponseOpener) {
        self.opener = opener
    }

    public var finished: Bool { opener.finished }

    /// Feed raw outer bytes; returns any decrypted plaintext now available.
    public func feed(_ chunk: Data) throws -> Data {
        buffer.append(chunk)
        var plaintext = Data()
        while let separator = buffer.range(of: Self.eventSeparator) {
            let event = buffer.subdata(in: buffer.startIndex ..< separator.lowerBound)
            buffer.removeSubrange(buffer.startIndex ..< separator.upperBound)
            guard let payload = Self.dataPayload(from: event) else { continue }
            guard let frame = try? JSONDecoder().decode(SecureChannel.Frame.self, from: payload) else {
                throw SecureChannelClientError.decryptionFailed
            }
            do {
                plaintext.append(try opener.open(frame).plaintext)
            } catch {
                throw SecureChannelClientError.decryptionFailed
            }
        }
        return plaintext
    }

    /// Call when the outer stream ends. Throws if no authenticated `fin`
    /// frame was seen — the stream was silently truncated.
    public func verifyCompleted() throws {
        guard opener.finished else { throw SecureChannelClientError.streamTruncated }
    }

    /// Extract the `data:` payload from one SSE event's bytes (multi-line
    /// `data:` fields joined with `\n` per the SSE spec). Returns nil for
    /// comment/keepalive events.
    private static func dataPayload(from event: Data) -> Data? {
        var payload = Data()
        var found = false
        for line in event.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            var rest: Data.SubSequence? = nil
            if line.starts(with: Data("data: ".utf8)) {
                rest = line.dropFirst(6)
            } else if line.starts(with: Data("data:".utf8)) {
                rest = line.dropFirst(5)
            }
            guard let rest else { continue }
            if found { payload.append(UInt8(ascii: "\n")) }
            payload.append(contentsOf: rest)
            found = true
        }
        return found ? payload : nil
    }
}
