//
//  OpenAICodexOAuthService.swift
//  osaurus
//
//  ChatGPT/Codex OAuth support for OpenAI providers.
//

import AppKit
import CryptoKit
import Foundation
import Network
import Security

public enum OpenAICodexOAuthError: LocalizedError, Sendable {
    case invalidAuthorizationCallback
    case invalidPKCE
    case invalidTokenResponse
    case missingAccountId
    case tokenRequestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorizationCallback:
            return "OpenAI did not return a valid authorization code"
        case .invalidPKCE:
            return "Could not create a secure login challenge"
        case .invalidTokenResponse:
            return "OpenAI returned an invalid token response"
        case .missingAccountId:
            return "Could not identify the ChatGPT account from the sign-in token"
        case .tokenRequestFailed(let message):
            return "OpenAI token request failed: \(message)"
        }
    }
}

public enum OpenAICodexOAuthService {
    public static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    public static let redirectURI = "http://localhost:1455/auth/callback"
    public static let scope = "openid profile email offline_access"
    public static let codexBaseHost = "chatgpt.com"
    public static let codexBasePath = "/backend-api"

    public static let supportedModels: [String] = [
        "gpt-5.2",
        "gpt-5.2-codex",
        "gpt-5.1-codex-max",
        "gpt-5.1-codex",
        "gpt-5.1-codex-mini",
        "gpt-5.1",
    ]

    public static func makeProvider(id: UUID = UUID()) -> RemoteProvider {
        RemoteProvider(
            id: id,
            name: "OpenAI ChatGPT",
            host: codexBaseHost,
            providerProtocol: .https,
            port: nil,
            basePath: codexBasePath,
            customHeaders: [:],
            authType: .openAICodexOAuth,
            providerType: .openAICodex,
            enabled: true,
            autoConnect: true,
            timeout: 300
        )
    }

    @MainActor
    public static func signIn() async throws -> RemoteProviderOAuthTokens {
        let pkce = try makePKCEPair()
        let state = makeState()
        let url = authorizationURL(codeChallenge: pkce.challenge, state: state)

        let callbackURL = try await authorize(url: url, state: state)
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            components.queryItems?.first(where: { $0.name == "state" })?.value == state,
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
            !code.isEmpty
        else {
            throw OpenAICodexOAuthError.invalidAuthorizationCallback
        }

        return try await exchangeAuthorizationCode(code, verifier: pkce.verifier)
    }

    public static func refresh(_ tokens: RemoteProviderOAuthTokens) async throws -> RemoteProviderOAuthTokens {
        try await requestTokens(
            form: [
                "grant_type": "refresh_token",
                "refresh_token": tokens.refreshToken,
                "client_id": clientId,
            ]
        )
    }

    public static func authorizationURL(codeChallenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        return components.url!
    }

    public static func makePKCEPair() throws -> (verifier: String, challenge: String) {
        var random = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        guard status == errSecSuccess else { throw OpenAICodexOAuthError.invalidPKCE }

        let verifier = base64URLEncoded(Data(random))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncoded(Data(digest))
        return (verifier, challenge)
    }

    public static func makeState() -> String {
        var random = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        return random.map { String(format: "%02x", $0) }.joined()
    }

    public static func extractAccountId(from accessToken: String) -> String? {
        let parts = accessToken.split(separator: ".")
        guard parts.count == 3,
            let payload = decodeBase64URL(String(parts[1])),
            let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let auth = json["https://api.openai.com/auth"] as? [String: Any],
            let accountId = auth["chatgpt_account_id"] as? String,
            !accountId.isEmpty
        else {
            return nil
        }
        return accountId
    }

    public static func exchangeAuthorizationCode(_ code: String, verifier: String) async throws
        -> RemoteProviderOAuthTokens
    {
        try await requestTokens(
            form: [
                "grant_type": "authorization_code",
                "client_id": clientId,
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": redirectURI,
            ]
        )
    }

    private static func requestTokens(form: [String: String]) async throws -> RemoteProviderOAuthTokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncoded(form).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICodexOAuthError.invalidTokenResponse
        }
        guard http.statusCode < 400 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw OpenAICodexOAuthError.tokenRequestFailed(body)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: TimeInterval
        }

        guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw OpenAICodexOAuthError.invalidTokenResponse
        }
        guard let accountId = extractAccountId(from: tokenResponse.access_token) else {
            throw OpenAICodexOAuthError.missingAccountId
        }

        return RemoteProviderOAuthTokens(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            expiresAt: Date().addingTimeInterval(tokenResponse.expires_in),
            accountId: accountId
        )
    }

    @MainActor
    private static func authorize(url: URL, state: String) async throws -> URL {
        let server = try OAuthLoopbackServer(expectedState: state)
        try server.start()
        defer { server.stop() }

        guard NSWorkspace.shared.open(url) else {
            throw OpenAICodexOAuthError.invalidAuthorizationCallback
        }

        return try await server.waitForCallback()
    }

    private static func formURLEncoded(_ values: [String: String]) -> String {
        values
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .sorted()
            .joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 =
            value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: base64)
    }
}

private final class OAuthLoopbackServer: @unchecked Sendable {
    private let expectedState: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ai.osaurus.openai-oauth-loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var pendingResult: Result<URL, Error>?
    private var isCompleted = false

    init(expectedState: String) throws {
        self.expectedState = expectedState
        listener = try NWListener(using: .tcp, on: 1455)
    }

    func start() throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.complete(.failure(OpenAICodexOAuthError.invalidAuthorizationCallback))
            }
        }
        listener.start(queue: queue)
    }

    func waitForCallback() async throws -> URL {
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

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let result = parseCallback(from: data)
            sendResponse(for: result, on: connection)
            complete(result)
        }
    }

    private func parseCallback(from data: Data?) -> Result<URL, Error> {
        guard let data,
            let request = String(data: data, encoding: .utf8),
            let requestLine = request.components(separatedBy: "\r\n").first,
            requestLine.hasPrefix("GET ")
        else {
            return .failure(OpenAICodexOAuthError.invalidAuthorizationCallback)
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
            let callbackURL = URL(string: "http://localhost:1455" + parts[1])
        else {
            return .failure(OpenAICodexOAuthError.invalidAuthorizationCallback)
        }

        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let state = components?.queryItems?.first(where: { $0.name == "state" })?.value
        let code = components?.queryItems?.first(where: { $0.name == "code" })?.value
        guard state == expectedState, code?.isEmpty == false else {
            return .failure(OpenAICodexOAuthError.invalidAuthorizationCallback)
        }

        return .success(callbackURL)
    }

    private func sendResponse(for result: Result<URL, Error>, on connection: NWConnection) {
        let success = {
            if case .success = result { return true }
            return false
        }()
        let title = success ? "Sign-in complete" : "Sign-in failed"
        let message =
            success
            ? "You can return to Osaurus."
            : "Osaurus could not complete the ChatGPT sign-in. Please try again."
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

    private func complete(_ result: Result<URL, Error>) {
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
