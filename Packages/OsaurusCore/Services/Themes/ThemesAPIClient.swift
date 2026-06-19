//
//  ThemesAPIClient.swift
//  osaurus
//
//  Pure transport for the themes.osaurus.ai sharing API. Handles nonce
//  challenges, signed POST uploads, and public GETs for theme JSON.
//
//  See osaurus-ai/osaurus-themes for the reference server.
//

import Foundation

// MARK: - Public types

public struct ThemesShareResult: Sendable {
    public let hash: String
    public let url: URL
}

/// Strongly-typed mapping of the JSON `error` codes the themes server
/// returns. Anything we don't recognize lands in `.server(message:)` so
/// the UI can still surface it.
public enum ThemesAPIError: LocalizedError, Sendable {
    case bodyTooLarge
    case rateLimited
    case notFound
    case timestampOutOfWindow
    case invalidNonce
    case signatureVerificationFailed
    case forbidden
    case missingAuthHeaders
    case storageUnavailable(rawCode: String, status: Int)
    case server(code: String, message: String?, status: Int)
    case transport(Error)
    case invalidResponse
    case payloadTooLarge

    public var errorDescription: String? {
        switch self {
        case .bodyTooLarge:
            return "Theme JSON is too large to upload (limit 5 MB)."
        case .rateLimited:
            return "Too many requests. Please try again in a moment."
        case .notFound:
            return "Theme not found on the server."
        case .timestampOutOfWindow:
            return "Your clock is out of sync with the server."
        case .invalidNonce:
            return "Authentication challenge expired. Please try again."
        case .signatureVerificationFailed:
            return "Signature verification failed."
        case .forbidden:
            return "Only the original uploader can modify this theme."
        case .missingAuthHeaders:
            return "Missing authentication headers."
        case .storageUnavailable:
            return "Themes server is temporarily unavailable."
        case .server(_, let message, let status):
            return message ?? "Themes server error (HTTP \(status))."
        case .transport(let error):
            return error.localizedDescription
        case .invalidResponse:
            return "Themes server returned an invalid response."
        case .payloadTooLarge:
            return "Downloaded theme exceeds the 5 MB safety cap."
        }
    }

    /// A short technical hint suitable for a "Details" footnote in the UI.
    /// Lets users (and us) tell `storage_unavailable` from
    /// `metadata_write_failed` even though both surface the same friendly
    /// description.
    public var diagnosticHint: String? {
        switch self {
        case .storageUnavailable(let raw, let status):
            return "\(raw) (HTTP \(status))"
        case .server(let code, _, let status):
            return "\(code) (HTTP \(status))"
        case .transport(let error):
            let ns = error as NSError
            return "\(ns.domain) \(ns.code)"
        case .bodyTooLarge, .rateLimited, .notFound, .timestampOutOfWindow,
            .invalidNonce, .signatureVerificationFailed, .forbidden,
            .missingAuthHeaders, .invalidResponse, .payloadTooLarge:
            return nil
        }
    }

    fileprivate static func from(code: String, message: String?, status: Int) -> ThemesAPIError {
        switch code {
        case "body_too_large": return .bodyTooLarge
        case "rate_limited": return .rateLimited
        case "not_found": return .notFound
        case "timestamp_out_of_window": return .timestampOutOfWindow
        case "invalid_nonce": return .invalidNonce
        case "signature_verification_failed": return .signatureVerificationFailed
        case "forbidden": return .forbidden
        case "missing_auth_headers": return .missingAuthHeaders
        case "storage_unavailable", "metadata_write_failed", "metadata_read_failed",
            "storage_read_failed", "storage_write_failed", "storage_delete_failed":
            return .storageUnavailable(rawCode: code, status: status)
        default:
            return .server(code: code, message: message, status: status)
        }
    }
}

// MARK: - Client

public actor ThemesAPIClient {

    public static let shared = ThemesAPIClient()

    /// 5 MB. Matches the server's body cap so client-side validation lines up
    /// with the server's streamed early-abort.
    public static let maxBodyBytes = 5 * 1024 * 1024

    /// Production base. Override only in tests.
    public static let defaultBaseURL = URL(string: "https://themes.osaurus.ai")!

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = ThemesAPIClient.defaultBaseURL) {
        self.baseURL = baseURL
        self.session = Self.makeSession()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "Accept": "application/json"
        ]
        return GlobalProxySettings.makeSession(base: config)
    }

    // MARK: - POST /auth/challenge

    /// Request a single-use nonce bound to `address`. Server consumes it on
    /// the first signed write within 60s.
    public func requestNonce(address: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/challenge"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["address": address],
            options: []
        )

        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)

        struct ChallengeResponse: Decodable { let nonce: String }
        let decoded = try decodeJSON(ChallengeResponse.self, from: data)
        return decoded.nonce
    }

    // MARK: - POST /themes

    /// Upload a signed theme payload. The signature must already cover the
    /// SHA-256 of `body`; this method does not look at the contents.
    public func uploadTheme(
        body: Data,
        address: String,
        nonce: String,
        timestamp: Int,
        signature: String
    ) async throws -> ThemesShareResult {
        guard body.count <= Self.maxBodyBytes else {
            throw ThemesAPIError.bodyTooLarge
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("themes"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(address, forHTTPHeaderField: "X-Agent-Address")
        request.setValue(nonce, forHTTPHeaderField: "X-Nonce")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")
        request.httpBody = body

        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)

        struct ShareResponse: Decodable {
            let hash: String
            let url: String
        }
        let decoded = try decodeJSON(ShareResponse.self, from: data)
        guard let url = URL(string: decoded.url) else {
            throw ThemesAPIError.invalidResponse
        }
        return ThemesShareResult(hash: decoded.hash, url: url)
    }

    // MARK: - GET /themes/:hash

    /// Fetch a theme's raw JSON. Public; no auth headers needed.
    public func downloadTheme(hash: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("themes/\(hash)"))
        request.httpMethod = "GET"

        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)

        guard data.count <= Self.maxBodyBytes else {
            throw ThemesAPIError.payloadTooLarge
        }
        return data
    }

    public func themeURL(hash: String) -> URL {
        baseURL.appendingPathComponent("themes/\(hash)")
    }

    // MARK: - Internal

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw ThemesAPIError.transport(error)
        }
    }

    private func ensureOK(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ThemesAPIError.invalidResponse
        }
        if (200 ..< 300).contains(http.statusCode) { return }

        let preview = Self.bodyPreview(data)
        let path = http.url?.path ?? "<no path>"
        print("[ThemesAPI] \(path) returned HTTP \(http.statusCode): \(preview)")

        // Try to decode the documented `{ error, message? }` envelope.
        struct ErrorEnvelope: Decodable {
            let error: String?
            let message: String?
        }
        if let envelope = try? decodeJSON(ErrorEnvelope.self, from: data), let code = envelope.error {
            throw ThemesAPIError.from(
                code: code,
                message: envelope.message,
                status: http.statusCode
            )
        }

        // Fall back to status-code-only mapping.
        switch http.statusCode {
        case 404: throw ThemesAPIError.notFound
        case 413: throw ThemesAPIError.bodyTooLarge
        case 429: throw ThemesAPIError.rateLimited
        case 401: throw ThemesAPIError.signatureVerificationFailed
        case 403: throw ThemesAPIError.forbidden
        default:
            throw ThemesAPIError.server(
                code: "http_\(http.statusCode)",
                message: nil,
                status: http.statusCode
            )
        }
    }

    private static func bodyPreview(_ data: Data, limit: Int = 512) -> String {
        guard !data.isEmpty else { return "<empty body>" }
        let trimmed = data.prefix(limit)
        if let str = String(data: trimmed, encoding: .utf8) {
            return data.count > limit ? str + "…(truncated)" : str
        }
        return "<\(data.count) bytes, non-utf8>"
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ThemesAPIError.invalidResponse
        }
    }
}
