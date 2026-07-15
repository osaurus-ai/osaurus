//
//  OpenAICodexOAuthService.swift
//  osaurus
//
//  ChatGPT/Codex OAuth support for OpenAI providers.
//

import AppKit
import Foundation
import os

public enum OpenAICodexOAuthError: LocalizedError, Sendable {
    case invalidAuthorizationCallback
    case invalidPKCE
    case invalidTokenResponse
    case missingSignInTokens
    case missingAccountId
    case tokenRequestFailed(String)
    case loopbackBindFailed(String)
    case browserOpenFailed
    case authorizationCallbackFailed(String)
    case authorizationCallbackRejected(String)
    case modelCatalogRequestFailed(String)
    case modelCatalogDecodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorizationCallback:
            return
                L(
                    "ChatGPT sign-in did not return a valid authorization code. Try the sign-in again from the same browser window."
                )
        case .invalidPKCE:
            return L("Could not create a secure login challenge")
        case .invalidTokenResponse:
            return L("OpenAI returned an invalid token response during ChatGPT sign-in")
        case .missingSignInTokens:
            return L("Missing ChatGPT/Codex sign-in tokens. Sign in with ChatGPT again, then retry the provider.")
        case .missingAccountId:
            return
                L(
                    "Could not identify the ChatGPT account from the sign-in token. Sign in with the ChatGPT account that has Codex access, then retry."
                )
        case .tokenRequestFailed(let message):
            return L("OpenAI token request failed: \(OpenAICodexOAuthService.safeDiagnosticFragment(message))")
        case .loopbackBindFailed(let message):
            return
                L(
                    "Could not start the ChatGPT sign-in callback server on localhost:1455. Close any other in-progress sign-in or app using that port, then retry. Details: \(OpenAICodexOAuthService.safeDiagnosticFragment(message))"
                )
        case .browserOpenFailed:
            return
                L(
                    "Could not open the browser for ChatGPT sign-in. Check the macOS default browser setting, then retry."
                )
        case .authorizationCallbackFailed(let message):
            return L("ChatGPT sign-in callback failed: \(OpenAICodexOAuthService.safeDiagnosticFragment(message))")
        case .authorizationCallbackRejected(let message):
            return L(
                "ChatGPT rejected the sign-in callback: \(OpenAICodexOAuthService.safeDiagnosticFragment(message))"
            )
        case .modelCatalogRequestFailed(let message):
            return
                L(
                    "ChatGPT/Codex model catalog request failed: \(OpenAICodexOAuthService.safeDiagnosticFragment(message))"
                )
        case .modelCatalogDecodeFailed(let message):
            return
                L(
                    "OpenAI returned an unreadable Codex model catalog: \(OpenAICodexOAuthService.safeDiagnosticFragment(message))"
                )
        }
    }
}

/// One reasoning level a Codex model advertises in the live `/models`
/// catalog, in the catalog's order. `effort` is the exact wire value
/// (`low`, `xhigh`, `ultra`, ...); `description` is ChatGPT's own copy for
/// the level, surfaced as secondary text in the effort picker.
public struct CodexReasoningLevel: Sendable, Equatable, Hashable {
    public let effort: String
    public let description: String?

    public init(effort: String, description: String? = nil) {
        self.effort = effort
        self.description = description
    }
}

/// Per-model capability metadata decoded from the live Codex `/models`
/// catalog. This is the authoritative source for a model's reasoning
/// surface — sets differ per model (Terra offers `ultra`, Luna stops at
/// `max`) and must never be inferred from model names.
public struct CodexModelMetadata: Sendable, Equatable, Hashable {
    public let slug: String
    public let displayName: String?
    /// Catalog default effort. Display-only: Osaurus shows it when the user
    /// made no explicit choice but never injects it into requests.
    public let defaultReasoningLevel: String?
    /// Supported efforts in catalog order. Empty when the catalog exposes no
    /// reasoning contract for the model.
    public let supportedReasoningLevels: [CodexReasoningLevel]
    public let usesResponsesLite: Bool

    public init(
        slug: String,
        displayName: String? = nil,
        defaultReasoningLevel: String? = nil,
        supportedReasoningLevels: [CodexReasoningLevel] = [],
        usesResponsesLite: Bool = false
    ) {
        self.slug = slug
        self.displayName = displayName
        self.defaultReasoningLevel = defaultReasoningLevel
        self.supportedReasoningLevels = supportedReasoningLevels
        self.usesResponsesLite = usesResponsesLite
    }
}

public enum OpenAICodexOAuthService {

    // MARK: - Configuration

    public static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    public static let redirectURI = "http://localhost:1455/auth/callback"
    public static let scope = "openid profile email offline_access"
    public static let codexBaseHost = "chatgpt.com"
    public static let codexBasePath = "/backend-api"
    /// Codex API base path, matching codex-rs's `CHATGPT_CODEX_BASE_URL`
    /// (`https://chatgpt.com/backend-api/codex`). Model discovery must use this
    /// path: the plain `/backend-api/models` endpoint is the ChatGPT web-app
    /// catalog, which serves experiment slugs (e.g. "gpt-5.5-wm") that the
    /// Codex Responses backend rejects.
    public static let codexAPIBasePath = "\(codexBasePath)/codex"
    public static let modelsURL = URL(string: "https://\(codexBaseHost)\(codexAPIBasePath)/models")!

    // MARK: - Provider Factory

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

    // MARK: - Sign-in / Token Refresh

    @MainActor
    public static func signIn() async throws -> RemoteProviderOAuthTokens {
        let pkce = try makePKCEPair()
        let state = makeState()
        let url = authorizationURL(codeChallenge: pkce.challenge, state: state)

        let callback = try await authorize(url: url, state: state)
        return try await exchangeAuthorizationCode(callback.code, verifier: pkce.verifier)
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

    // MARK: - Model Catalog

    /// Offline / pre-auth fallback list. The live catalog (fetched via
    /// `fetchAvailableModels(tokens:)`) is preferred whenever OAuth tokens are
    /// available, but this list keeps the UI usable before sign-in and when the
    /// `/models` endpoint cannot be reached.
    public static let supportedModels: [String] = [
        "gpt-5.5",
        "gpt-5.5-pro",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark",
        "gpt-5.2",
        "gpt-5.2-codex",
        "gpt-5.1-codex-max",
        "gpt-5.1-codex",
        "gpt-5.1-codex-mini",
        "gpt-5.1",
    ]

    /// Why a live `/models` entry was excluded from the Codex catalog.
    public enum ModelFilterReason: String, Sendable, Equatable {
        case hiddenVisibility
        case shellToolDisabled
        case nonCodexSlug

        /// Short human-readable label for provider diagnostics.
        public var label: String {
            switch self {
            case .hiddenVisibility: return L("hidden from picker")
            case .shellToolDisabled: return L("shell tool disabled")
            case .nonCodexSlug: return L("chat-only slug")
            }
        }
    }

    /// Result of the most recent live `/models` discovery: how many entries
    /// the backend returned, how many survived the Codex-compatibility filter,
    /// and which slugs were dropped and why. Surfaced through provider
    /// diagnostics so "N models" mismatches can be attributed to specific
    /// filtered entries instead of guessed at.
    public struct ModelDiscoverySummary: Sendable, Equatable {
        public struct FilteredModel: Sendable, Equatable {
            public let slug: String
            public let reason: ModelFilterReason
        }

        public let rawEntryCount: Int
        public let compatibleCount: Int
        public let filteredModels: [FilteredModel]
        /// Picker-visible models that require Codex's Responses Lite wire
        /// contract. This comes from the live catalog's
        /// `use_responses_lite` field; do not infer it from model names.
        public let responsesLiteModels: Set<String>
        /// Full per-model capability metadata for every picker-visible model,
        /// keyed by slug. Replaced atomically with the rest of the summary on
        /// each successful discovery so reconnect/refetch never leaves stale
        /// reasoning capabilities behind.
        public let modelMetadata: [String: CodexModelMetadata]
        public let fetchedAt: Date

        public init(
            rawEntryCount: Int,
            compatibleCount: Int,
            filteredModels: [FilteredModel],
            responsesLiteModels: Set<String> = [],
            modelMetadata: [String: CodexModelMetadata] = [:],
            fetchedAt: Date
        ) {
            self.rawEntryCount = rawEntryCount
            self.compatibleCount = compatibleCount
            self.filteredModels = filteredModels
            self.responsesLiteModels = responsesLiteModels
            self.modelMetadata = modelMetadata
            self.fetchedAt = fetchedAt
        }
    }

    private static let lastDiscoverySummaryBox = OSAllocatedUnfairLock<ModelDiscoverySummary?>(initialState: nil)

    /// Most recent live-catalog discovery result, or nil before the first
    /// successful post-sign-in fetch. Process-global: there is one ChatGPT/
    /// Codex catalog endpoint regardless of how many providers point at it.
    public static var lastModelDiscoverySummary: ModelDiscoverySummary? {
        lastDiscoverySummaryBox.withLock { $0 }
    }

    /// Whether the latest authenticated Codex catalog says `modelId` requires
    /// Responses Lite. A missing catalog entry deliberately returns false:
    /// fallback models predate the Lite contract, while live GPT-5.6 entries
    /// carry the authoritative flag.
    public static func usesResponsesLite(modelId: String) -> Bool {
        lastDiscoverySummaryBox.withLock {
            $0?.responsesLiteModels.contains(modelId) == true
        }
    }

    /// Latest catalog capability metadata for `slug`, or nil before the first
    /// successful discovery / for fallback models that predate the catalog.
    public static func modelMetadata(forSlug slug: String) -> CodexModelMetadata? {
        lastDiscoverySummaryBox.withLock { $0?.modelMetadata[slug] }
    }

    /// Live model catalog fetched from the ChatGPT/Codex backend, matching what
    /// `codex-rs`'s `ModelsClient.list_models` does. Filters out chat-only
    /// models so callers only see Codex-Responses-compatible slugs.
    public static func fetchAvailableModels(
        tokens: RemoteProviderOAuthTokens
    ) async throws -> [String] {
        var components = URLComponents(url: modelsURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_version", value: codexClientVersion)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(tokens.accountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue(codexUserAgent(), forHTTPHeaderField: "User-Agent")

        let data = try await performRequest(request, operation: .modelCatalog)
        let (models, summary) = try decodeModelCatalog(data)
        lastDiscoverySummaryBox.withLock { $0 = summary }
        return models
    }

    /// Decode a live `/models` payload into the Codex-compatible slug list
    /// plus a summary of what was filtered out and why. Split from the network
    /// call so the filter can be exercised against wire fixtures in tests.
    static func decodeModelCatalog(_ data: Data) throws -> (models: [String], summary: ModelDiscoverySummary) {
        guard let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "non-text response"
            throw OpenAICodexOAuthError.modelCatalogDecodeFailed(preview)
        }

        var compatible: [ModelEntry] = []
        var filtered: [ModelDiscoverySummary.FilteredModel] = []
        for entry in decoded.models {
            guard !entry.slug.isEmpty else { continue }
            if let reason = incompatibilityReason(for: entry) {
                filtered.append(.init(slug: entry.slug, reason: reason))
            } else {
                compatible.append(entry)
            }
        }

        let models: [String] =
            compatible
            .sorted { ($0.priority ?? .max) < ($1.priority ?? .max) }
            .map(\.slug)
            .uniqued()
        let summary = ModelDiscoverySummary(
            rawEntryCount: decoded.models.count,
            compatibleCount: models.count,
            filteredModels: filtered,
            responsesLiteModels: Set(
                compatible
                    .filter { $0.use_responses_lite == true }
                    .map(\.slug)
            ),
            modelMetadata: Dictionary(
                compatible.map { ($0.slug, $0.capabilityMetadata) },
                uniquingKeysWith: { first, _ in first }
            ),
            fetchedAt: Date()
        )
        return (models, summary)
    }

    /// Nil when a `/models` entry can be used through the Codex Responses
    /// backend with a ChatGPT subscription; otherwise the reason it must be
    /// excluded. The same endpoint also returns chat-only models (e.g.
    /// `gpt-5-4-thinking`), which fail with `HTTP 400 "model is not supported
    /// when using Codex with a ChatGPT account"` if we surface them.
    private static func incompatibilityReason(for entry: ModelEntry) -> ModelFilterReason? {
        // Must be a picker-visible model.
        guard (entry.visibility ?? "list").lowercased() == "list" else { return .hiddenVisibility }

        // Codex requires shell-tool support. Chat-only models come back with
        // `shell_type: "disabled"`. Treat a missing field as "unknown -> allow"
        // and rely on the slug check below to catch it.
        if let shellType = entry.shell_type, shellType.lowercased() == "disabled" {
            return .shellToolDisabled
        }

        // Codex slugs always use a dotted version (e.g. "gpt-5.4-codex").
        // Chat-only slugs use dashes throughout (e.g. "gpt-5-4-thinking",
        // "gpt-4o"). Match the dotted "<family>-<major>.<minor>" prefix.
        if entry.slug.range(of: #"^gpt-\d+\.\d+"#, options: .regularExpression) == nil {
            return .nonCodexSlug
        }
        return nil
    }

    /// Convenience wrapper used by call sites that want a single "best
    /// available" list: prefer the live catalog when we have tokens, otherwise
    /// fall back to `supportedModels`.
    public static func availableModels(for tokens: RemoteProviderOAuthTokens?) async -> [String] {
        guard let tokens,
            let live = try? await fetchAvailableModels(tokens: tokens),
            !live.isEmpty
        else {
            return supportedModels
        }
        return live
    }

    /// Convert Codex OAuth failures into a short, safe-to-paste message for
    /// UI surfaces and GitHub issue replies. The raw failures may include HTTP
    /// bodies, callback URLs, or provider diagnostics, so this always applies
    /// the same redaction rules before text leaves the service boundary.
    public static func diagnosticMessage(for error: Error) -> String {
        if let codexError = error as? OpenAICodexOAuthError {
            return codexError.errorDescription ?? "ChatGPT/Codex sign-in failed"
        }

        if let loopbackError = error as? OAuthLoopbackError {
            return mapLoopbackError(loopbackError).errorDescription ?? "ChatGPT/Codex sign-in failed"
        }

        return "ChatGPT/Codex sign-in failed: \(safeDiagnosticFragment(error.localizedDescription))"
    }

    /// Redact OAuth credentials from provider diagnostics while preserving
    /// enough status/body detail for maintainers to understand what failed.
    public static func safeDiagnosticFragment(_ raw: String, maxLength: Int = 240) -> String {
        var value = raw
        let replacements: [(pattern: String, template: String)] = [
            (#"(?i)authorization\s*[:=]\s*(?:bearer\s+)?[^\s,;}]+\"?"#, "credential=***"),
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "credential=***"),
            (#"(?i)\"(access_token|refresh_token|code_verifier|code|verifier)\"\s*:\s*\"[^\"]*\""#, #""$1":"***""#),
            (#"(?i)\b(access_token|refresh_token|code_verifier|code|verifier)=([^&\s,;}]+)"#, "$1=***"),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "jwt=***"),
        ]
        for replacement in replacements {
            value = value.replacingMatches(of: replacement.pattern, with: replacement.template)
        }

        value = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.contains("  ") {
            value = value.replacingOccurrences(of: "  ", with: " ")
        }

        guard !value.isEmpty else { return "No details returned" }
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength)) + "..."
    }

    // MARK: - OAuth Helpers

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
        do {
            let pair = try PKCE.makePair()
            return (pair.verifier, pair.challenge)
        } catch {
            throw OpenAICodexOAuthError.invalidPKCE
        }
    }

    public static func makeState() -> String {
        PKCE.makeState()
    }

    public static func extractAccountId(from accessToken: String) -> String? {
        let parts = accessToken.split(separator: ".")
        guard parts.count == 3,
            let payload = PKCE.decodeBase64URL(String(parts[1])),
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

    // MARK: - Internals

    /// `client_version` query parameter sent to the Codex `/models` endpoint.
    /// Tracks the openai/codex CLI release: the backend silently filters the
    /// catalog for older or unrecognized versions (non-semver values like
    /// "osaurus-1.2.3" get the wrong subset entirely). Bump this to the
    /// current Codex CLI release when new models stop appearing in discovery.
    public static let codexClientVersion = "0.144.1"

    /// Codex CLI-style `User-Agent`, mirroring codex-rs's
    /// `get_codex_user_agent()` format:
    /// `codex_cli_rs/<version> (<os> <version>; <arch>) <terminal>`.
    /// The Codex backend routes some models (e.g. gpt-5.6-luna) to internal
    /// engines based on the originator + User-Agent identity; requests with a
    /// non-Codex user agent land in a cohort whose engine does not exist and
    /// fail with HTTP 404 "Model not found" even though the catalog lists the
    /// model (openai/codex#31967).
    public static func codexUserAgent() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
            let arch = "arm64"
        #elseif arch(x86_64)
            let arch = "x86_64"
        #else
            let arch = "unknown"
        #endif
        return
            "codex_cli_rs/\(codexClientVersion) (Mac OS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion); \(arch)) unknown"
    }

    // MARK: Wire types

    private struct ModelsResponse: Decodable {
        let models: [ModelEntry]
    }

    private struct ReasoningLevelEntry: Decodable {
        let effort: String?
        let description: String?
    }

    private struct ModelEntry: Decodable {
        let slug: String
        let visibility: String?
        let priority: Int?
        let shell_type: String?
        let use_responses_lite: Bool?
        let display_name: String?
        let default_reasoning_level: String?
        let supported_reasoning_levels: [ReasoningLevelEntry]?

        /// The publishable capability slice of this entry, preserving the
        /// catalog's level order and dropping malformed (effort-less) levels.
        var capabilityMetadata: CodexModelMetadata {
            CodexModelMetadata(
                slug: slug,
                displayName: display_name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty,
                defaultReasoningLevel: default_reasoning_level?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                supportedReasoningLevels: (supported_reasoning_levels ?? []).compactMap { level in
                    guard let effort = level.effort?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !effort.isEmpty
                    else { return nil }
                    return CodexReasoningLevel(effort: effort, description: level.description)
                },
                usesResponsesLite: use_responses_lite == true
            )
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: TimeInterval
    }

    // MARK: Networking

    private enum RequestOperation {
        case token
        case modelCatalog
    }

    /// Executes `request`, preserving whether the failure happened during token
    /// exchange or catalog lookup so the UI can give the user the right next step.
    private static func performRequest(_ request: URLRequest, operation: RequestOperation) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await GlobalProxySettings.sharedSession().data(for: request)
        } catch {
            let message = "Network error: \(error.localizedDescription)"
            switch operation {
            case .token:
                throw OpenAICodexOAuthError.tokenRequestFailed(message)
            case .modelCatalog:
                throw OpenAICodexOAuthError.modelCatalogRequestFailed(message)
            }
        }
        guard let http = response as? HTTPURLResponse else {
            switch operation {
            case .token:
                throw OpenAICodexOAuthError.invalidTokenResponse
            case .modelCatalog:
                throw OpenAICodexOAuthError.modelCatalogRequestFailed("Non-HTTP response")
            }
        }
        guard http.statusCode < 400 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            let message = "HTTP \(http.statusCode): \(body)"
            switch operation {
            case .token:
                throw OpenAICodexOAuthError.tokenRequestFailed(message)
            case .modelCatalog:
                throw OpenAICodexOAuthError.modelCatalogRequestFailed(message)
            }
        }
        return data
    }

    private static func requestTokens(form: [String: String]) async throws -> RemoteProviderOAuthTokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthFormEncoding.encode(form).data(using: .utf8)

        let data = try await performRequest(request, operation: .token)
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw OpenAICodexOAuthError.invalidTokenResponse
        }
        guard let accountId = extractAccountId(from: response.access_token) else {
            throw OpenAICodexOAuthError.missingAccountId
        }

        return RemoteProviderOAuthTokens(
            accessToken: response.access_token,
            refreshToken: response.refresh_token,
            expiresAt: Date().addingTimeInterval(response.expires_in),
            accountId: accountId
        )
    }

    @MainActor
    private static func authorize(url: URL, state: String) async throws -> OAuthCallbackResult {
        // Codex registered http://localhost:1455/auth/callback as the only redirect URI,
        // so we have to keep this port fixed even though RFC 8252 prefers ephemeral ports.
        let server: OAuthLoopbackServer
        do {
            server = try OAuthLoopbackServer(
                expectedState: state,
                port: .fixed(1455),
                callbackPath: "/auth/callback"
            )
            try await server.start()
        } catch let error as OAuthLoopbackError {
            throw mapLoopbackError(error)
        } catch {
            throw OpenAICodexOAuthError.loopbackBindFailed(error.localizedDescription)
        }
        defer { server.stop() }

        guard await NSWorkspace.shared.openAsync(url) else {
            throw OpenAICodexOAuthError.browserOpenFailed
        }

        do {
            // Bounded wait: an abandoned browser tab must not pin this task
            // (and the fixed loopback port) forever.
            return try await server.waitForCallback(
                timeout: OAuthLoopbackServer.defaultSignInTimeout
            )
        } catch let error as OAuthLoopbackError {
            throw mapLoopbackError(error)
        } catch {
            throw OpenAICodexOAuthError.authorizationCallbackFailed(error.localizedDescription)
        }
    }

    private static func mapLoopbackError(_ error: OAuthLoopbackError) -> OpenAICodexOAuthError {
        switch error {
        case .bindFailed(let message):
            return .loopbackBindFailed(message)
        case .stateMismatch:
            return .authorizationCallbackRejected("state mismatch from browser callback")
        case .missingCode:
            return .authorizationCallbackRejected("missing authorization code")
        case .oauthError(let error, let description):
            let detail = [error, description].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            return .authorizationCallbackRejected(detail.isEmpty ? "OAuth provider returned an error" : detail)
        case .invalidCallback:
            return .authorizationCallbackFailed("invalid callback path or request")
        case .callbackTimeout:
            return .authorizationCallbackFailed("timed out waiting for browser callback")
        }
    }
}

// MARK: - Helpers

extension String {
    fileprivate var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    fileprivate func replacingMatches(of pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let range = NSRange(startIndex ..< endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: template)
    }
}

extension Sequence where Element: Hashable {
    /// Returns the receiver's elements in order, dropping later duplicates.
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
