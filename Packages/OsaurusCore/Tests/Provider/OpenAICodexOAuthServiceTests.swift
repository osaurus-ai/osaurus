//
//  OpenAICodexOAuthServiceTests.swift
//  osaurusTests
//
//  Unit coverage for pure ChatGPT/Codex OAuth helpers.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("OpenAI Codex OAuth helpers")
struct OpenAICodexOAuthServiceTests {
    @Test func authorizationURL_containsCodexParameters() {
        let url = OpenAICodexOAuthService.authorizationURL(codeChallenge: "challenge", state: "state123")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components?.scheme == "https")
        #expect(components?.host == "auth.openai.com")
        #expect(params["client_id"] == OpenAICodexOAuthService.clientId)
        #expect(params["redirect_uri"] == OpenAICodexOAuthService.redirectURI)
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["code_challenge"] == "challenge")
        #expect(params["state"] == "state123")
        #expect(params["originator"] == "codex_cli_rs")
        #expect(params["codex_cli_simplified_flow"] == "true")
    }

    @Test func makePKCEPair_usesURLSafeValues() throws {
        let pair = try OpenAICodexOAuthService.makePKCEPair()

        #expect(pair.verifier.count >= 43)
        #expect(pair.challenge.count >= 43)
        #expect(!pair.verifier.contains("+"))
        #expect(!pair.verifier.contains("/"))
        #expect(!pair.verifier.contains("="))
        #expect(!pair.challenge.contains("+"))
        #expect(!pair.challenge.contains("/"))
        #expect(!pair.challenge.contains("="))
    }

    @Test func extractAccountId_readsChatGPTAccountClaim() throws {
        let token = try Self.makeJWT(
            payload: [
                "https://api.openai.com/auth": [
                    "chatgpt_account_id": "acct_123"
                ]
            ]
        )

        #expect(OpenAICodexOAuthService.extractAccountId(from: token) == "acct_123")
    }

    @Test func oauthTokens_expireWithRefreshSkew() {
        let tokens = RemoteProviderOAuthTokens(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(30),
            accountId: "acct"
        )

        #expect(tokens.isExpired)
    }

    @Test func modelsURL_usesCodexAPICatalogPath() {
        // Discovery must hit the Codex catalog (`/backend-api/codex/models`),
        // matching codex-rs's CHATGPT_CODEX_BASE_URL. The plain
        // `/backend-api/models` endpoint is the ChatGPT web-app catalog, which
        // serves experiment slugs (e.g. "gpt-5.5-wm") that the Codex
        // Responses backend rejects.
        let components = URLComponents(
            url: OpenAICodexOAuthService.modelsURL,
            resolvingAgainstBaseURL: false
        )
        #expect(components?.scheme == "https")
        #expect(components?.host == "chatgpt.com")
        #expect(components?.path == "/backend-api/codex/models")
    }

    @Test func codexClientVersion_isPlainSemver() {
        // The backend gates the catalog by `client_version` and expects a
        // Codex CLI semver; non-semver values (like the old
        // "osaurus-<version>" scheme) silently get the wrong model subset.
        let version = OpenAICodexOAuthService.codexClientVersion
        #expect(
            version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
            "client_version \(version) must be a plain Codex CLI semver"
        )
    }

    @Test func codexUserAgent_matchesCodexCLIFormat() {
        // Backend model routing (e.g. gpt-5.6-luna) depends on a Codex
        // CLI-shaped User-Agent: `codex_cli_rs/<semver> (<os> <ver>; <arch>)
        // <terminal>`. A default CFNetwork user agent routes those models to
        // a missing internal engine (HTTP 404 "Model not found").
        let userAgent = OpenAICodexOAuthService.codexUserAgent()
        #expect(
            userAgent.range(
                of: #"^codex_cli_rs/\d+\.\d+\.\d+ \(Mac OS \d+\.\d+\.\d+; (arm64|x86_64|unknown)\) unknown$"#,
                options: .regularExpression
            ) != nil,
            "User-Agent \(userAgent) does not match the Codex CLI format"
        )
        #expect(userAgent.contains("/\(OpenAICodexOAuthService.codexClientVersion) "))
    }

    @Test func supportedModels_containsCurrentCatalog() {
        let models = OpenAICodexOAuthService.supportedModels
        let expected = [
            "gpt-5.5",
            "gpt-5.5-pro",
            "gpt-5.4",
            "gpt-5.4-mini",
            "gpt-5.4-nano",
            "gpt-5.3-codex",
            "gpt-5.3-codex-spark",
        ]
        for slug in expected {
            #expect(models.contains(slug), "static fallback is missing \(slug)")
        }
        #expect(Set(models).count == models.count, "static fallback has duplicate slugs")
    }

    @Test func supportedModels_allUseCodexSlugFormat() {
        // Mirrors the live `/models` filter: Codex-compatible slugs use a
        // dotted version ("gpt-5.4-codex"), chat-only slugs use dashes
        // ("gpt-5-4-thinking") and would 400 if invoked.
        for slug in OpenAICodexOAuthService.supportedModels {
            let matches = slug.range(of: #"^gpt-\d+\.\d+"#, options: .regularExpression) != nil
            #expect(matches, "static fallback slug \(slug) does not use Codex naming")
        }
    }

    @Test func decodeModelCatalog_attributesEachDropReasonInSummary() throws {
        let payload = """
            {"models":[
                {"slug":"gpt-5.5","visibility":"list","priority":2,"shell_type":"local"},
                {"slug":"gpt-5.3-codex","visibility":"list","priority":1},
                {"slug":"gpt-5.2"},
                {"slug":"gpt-5-4-thinking","visibility":"list","priority":3,"shell_type":"disabled"},
                {"slug":"gpt-4o","visibility":"list","priority":4},
                {"slug":"gpt-5.5-internal","visibility":"hidden","priority":5},
                {"slug":""},
                {"slug":"gpt-5.5","visibility":"list","priority":6}
            ]}
            """
        let (models, summary) = try OpenAICodexOAuthService.decodeModelCatalog(Data(payload.utf8))

        // Sorted by priority (missing -> last), duplicates dropped.
        #expect(models == ["gpt-5.3-codex", "gpt-5.5", "gpt-5.2"])
        #expect(summary.rawEntryCount == 8)
        #expect(summary.compatibleCount == 3)
        #expect(
            summary.filteredModels == [
                .init(slug: "gpt-5-4-thinking", reason: .shellToolDisabled),
                .init(slug: "gpt-4o", reason: .nonCodexSlug),
                .init(slug: "gpt-5.5-internal", reason: .hiddenVisibility),
            ]
        )
    }

    @Test func decodeModelCatalog_preservesResponsesLiteCapability() throws {
        let payload = """
            {"models":[
                {"slug":"gpt-5.6-sol","visibility":"list","priority":1,"shell_type":"shell_command","use_responses_lite":true},
                {"slug":"gpt-5.6-terra","visibility":"list","priority":2,"shell_type":"shell_command","use_responses_lite":true},
                {"slug":"gpt-5.6-luna","visibility":"list","priority":3,"shell_type":"shell_command","use_responses_lite":true},
                {"slug":"gpt-5.5","visibility":"list","priority":4,"shell_type":"shell_command","use_responses_lite":false}
            ]}
            """
        let (models, summary) = try OpenAICodexOAuthService.decodeModelCatalog(Data(payload.utf8))

        #expect(models == ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"])
        #expect(summary.responsesLiteModels == ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"])
        #expect(!summary.responsesLiteModels.contains("gpt-5.5"))
    }

    @Test func decodeModelCatalog_preservesReasoningMetadataPerModel() throws {
        // Model-specific reasoning contracts from the live catalog: Terra
        // carries six levels through `ultra`, Luna stops at `max`, and an
        // older slug exposes none. Sets must come from the catalog verbatim
        // (order included) — never inferred from model names.
        let payload = """
            {"models":[
                {"slug":"gpt-5.6-terra","visibility":"list","priority":1,"shell_type":"shell_command",
                 "use_responses_lite":true,"display_name":"GPT-5.6 Terra",
                 "default_reasoning_level":"medium",
                 "supported_reasoning_levels":[
                    {"effort":"low","description":"Fastest"},
                    {"effort":"medium","description":"Balanced"},
                    {"effort":"high"},
                    {"effort":"xhigh"},
                    {"effort":"max"},
                    {"effort":"ultra","description":"Deepest reasoning"}
                 ]},
                {"slug":"gpt-5.6-luna","visibility":"list","priority":2,"shell_type":"shell_command",
                 "use_responses_lite":true,"display_name":"GPT-5.6 Luna",
                 "default_reasoning_level":"medium",
                 "supported_reasoning_levels":[
                    {"effort":"low"},{"effort":"medium"},{"effort":"high"},
                    {"effort":"xhigh"},{"effort":"max"},
                    {"effort":"","description":"malformed level must be dropped"}
                 ]},
                {"slug":"gpt-5.5","visibility":"list","priority":3,"shell_type":"shell_command"},
                {"slug":"gpt-5.5-internal","visibility":"hidden","priority":4,
                 "supported_reasoning_levels":[{"effort":"low"}]}
            ]}
            """
        let (models, summary) = try OpenAICodexOAuthService.decodeModelCatalog(Data(payload.utf8))

        #expect(models == ["gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"])

        let terra = try #require(summary.modelMetadata["gpt-5.6-terra"])
        #expect(terra.displayName == "GPT-5.6 Terra")
        #expect(terra.defaultReasoningLevel == "medium")
        #expect(
            terra.supportedReasoningLevels.map(\.effort)
                == ["low", "medium", "high", "xhigh", "max", "ultra"]
        )
        #expect(terra.supportedReasoningLevels.first?.description == "Fastest")
        #expect(terra.supportedReasoningLevels.last?.description == "Deepest reasoning")
        #expect(terra.usesResponsesLite)

        let luna = try #require(summary.modelMetadata["gpt-5.6-luna"])
        #expect(
            luna.supportedReasoningLevels.map(\.effort)
                == ["low", "medium", "high", "xhigh", "max"],
            "Luna must not gain ultra, and the effort-less level must be dropped"
        )

        let legacy = try #require(summary.modelMetadata["gpt-5.5"])
        #expect(legacy.supportedReasoningLevels.isEmpty)
        #expect(legacy.defaultReasoningLevel == nil)
        #expect(!legacy.usesResponsesLite)

        // Filtered (hidden) entries never publish capability metadata.
        #expect(summary.modelMetadata["gpt-5.5-internal"] == nil)
    }

    @Test func decodeModelCatalog_throwsTypedErrorForUnreadablePayload() {
        #expect(throws: OpenAICodexOAuthError.self) {
            _ = try OpenAICodexOAuthService.decodeModelCatalog(Data(#"{"models":"unexpected"}"#.utf8))
        }
    }

    @Test func diagnostics_redactOAuthSecretsFromPasteableMessages() {
        let raw = """
            Authorization: Bearer access.secret
            {"access_token":"token-123","refresh_token":"refresh-456","code":"auth-code"}
            code_verifier=verifier-789
            eyJheader.eyJpayload.signature
            """

        let sanitized = OpenAICodexOAuthService.safeDiagnosticFragment(raw, maxLength: 500)

        for secret in ["access.secret", "token-123", "refresh-456", "auth-code", "verifier-789"] {
            #expect(!sanitized.contains(secret), "diagnostic leaked \(secret)")
        }
        #expect(sanitized.range(of: "Authorization", options: .caseInsensitive) == nil)
        #expect(sanitized.range(of: "Bearer", options: .caseInsensitive) == nil)
        #expect(sanitized.contains("***"))
    }

    @Test func diagnostics_explainLoopbackPortCollision() {
        let error = OpenAICodexOAuthError.loopbackBindFailed("Address already in use")
        let message = OpenAICodexOAuthService.diagnosticMessage(for: error)

        #expect(message.contains("localhost:1455"))
        #expect(message.contains("Close any other in-progress sign-in"))
        #expect(message.contains("Address already in use"))
    }

    @Test func diagnostics_distinguishCallbackRejectionAndMissingTokens() {
        let callback = OpenAICodexOAuthService.diagnosticMessage(
            for: OpenAICodexOAuthError.authorizationCallbackRejected("state mismatch from browser callback")
        )
        let missing = OpenAICodexOAuthService.diagnosticMessage(for: OpenAICodexOAuthError.missingSignInTokens)

        #expect(callback.contains("rejected the sign-in callback"))
        #expect(callback.contains("state mismatch"))
        #expect(missing.contains("Missing ChatGPT/Codex sign-in tokens"))
        #expect(missing.contains("Sign in with ChatGPT again"))
    }

    @Test func diagnostics_distinguishModelCatalogHTTPAndDecodeFailures() {
        let http = OpenAICodexOAuthService.diagnosticMessage(
            for: OpenAICodexOAuthError.modelCatalogRequestFailed(
                #"HTTP 401: {"error":"bad","access_token":"secret-token"}"#
            )
        )
        let decode = OpenAICodexOAuthService.diagnosticMessage(
            for: OpenAICodexOAuthError.modelCatalogDecodeFailed(#"{"models":"unexpected"}"#)
        )

        #expect(http.contains("model catalog request failed"))
        #expect(http.contains("HTTP 401"))
        #expect(!http.contains("secret-token"))
        #expect(decode.contains("unreadable Codex model catalog"))
    }

    private static func makeJWT(payload: [String: Any]) throws -> String {
        let headerData = try JSONSerialization.data(withJSONObject: ["alg": "none"])
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        return [
            base64URL(headerData),
            base64URL(payloadData),
            "signature",
        ].joined(separator: ".")
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
