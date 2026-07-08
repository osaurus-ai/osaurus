//
//  ProviderFailureClassification.swift
//  OsaurusCore
//
//  Pure, post-hoc classification for remote provider failures. This uses only
//  existing state, replay evidence, and proxy diagnostics.
//

import Foundation

enum ProviderFailureBucket: String, Sendable, Equatable, CaseIterable {
    case missingCredential = "missing-credential"
    case oauthTokenMissing = "oauth-token-missing"
    case authRejected = "auth-rejected"
    case endpointUnreachable = "endpoint-unreachable"
    case tlsFailure = "tls-failure"
    case timeout
    case proxyConnectFailed = "proxy-connect-failed"
    case modelsEndpointUnavailable = "models-endpoint-unavailable"
    case modelsSchemaMismatch = "models-schema-mismatch"
    case requestRejected = "request-rejected"
    case unsupportedModel = "unsupported-model"
    case badResponse = "bad-response"
    case unknown
}

struct ProviderFailureClassification: Sendable, Equatable {
    let bucket: ProviderFailureBucket
    let title: String
    let detail: String
    let action: String
    let severity: ProviderDiagnosticSeverity

    var rowID: String {
        switch bucket {
        case .missingCredential, .authRejected:
            return "failure-auth"
        case .oauthTokenMissing:
            return "failure-oauth"
        case .endpointUnreachable:
            return "failure-connection"
        case .tlsFailure:
            return "failure-tls"
        case .timeout:
            return "failure-timeout"
        case .proxyConnectFailed:
            return "failure-proxy"
        case .modelsEndpointUnavailable, .modelsSchemaMismatch, .unsupportedModel:
            return "failure-models"
        case .requestRejected:
            return "failure-format"
        case .badResponse:
            return "failure-response"
        case .unknown:
            return "failure-unknown"
        }
    }
}

enum ProviderFailureClassifier {
    static func classify(
        provider: RemoteProvider,
        state: RemoteProviderState?,
        proxy: GlobalProxyDiagnosticState,
        apiKeyPresent: Bool,
        oauthTokensPresent: Bool
    ) -> ProviderFailureClassification? {
        guard provider.enabled else { return nil }
        if state?.isConnected == true {
            return nil
        }

        guard hasActiveFailure(state) else { return nil }

        switch provider.authType {
        case .apiKey:
            if !apiKeyPresent && !hasCredentialHeader(provider) {
                return classification(
                    .missingCredential,
                    detail: L("No API key or secret credential header is available for this provider.")
                )
            }
        case .openAICodexOAuth, .xaiOAuth:
            if !oauthTokensPresent {
                return classification(
                    .oauthTokenMissing,
                    detail: L("No OAuth tokens are available for this provider.")
                )
            }
        case .none:
            break
        }

        if let replay = state?.lastReplayDiagnostics,
           let replayClassification = classifyReplay(replay, proxy: proxy) {
            return replayClassification
        }

        if let error = state?.lastError, !error.isEmpty {
            return classifyMessage(error, proxy: proxy)
        }

        return nil
    }

    static func connectivityIssueKind(forFailureRowID rowID: String) -> ProviderConnectivityIssueKind? {
        switch rowID {
        case "failure-auth":
            return .authentication
        case "failure-oauth":
            return .oauthContext
        case "failure-models":
            return .models
        case "failure-format":
            return .format
        case "failure-proxy":
            return .proxy
        case "failure-unknown":
            return .uncategorized
        case "failure-connection", "failure-tls", "failure-timeout", "failure-response":
            return .connection
        default:
            return nil
        }
    }

    private static func classifyReplay(
        _ replay: ProviderReplayDiagnosticBundle,
        proxy: GlobalProxyDiagnosticState
    ) -> ProviderFailureClassification? {
        if case .active = proxy,
           let transportError = replay.transportError?.lowercased(),
           transportError.contains("proxy") {
            return classification(
                .proxyConnectFailed,
                detail: L("The request failed while the global proxy was active. Evidence: \(replay.summary)")
            )
        }

        if let code = replay.transportErrorCode,
           let transportClassification = classifyTransportErrorCode(code, summary: replay.summary) {
            return transportClassification
        }

        if let transportError = replay.transportError, !transportError.isEmpty {
            return classifyMessage(transportError, proxy: proxy, evidence: replay.summary)
        }

        guard let response = replay.response else { return nil }
        let body = response.body?.lowercased() ?? ""
        let phase = replay.phase.lowercased()
        let status = response.statusCode

        if status == 401 || status == 403 {
            return classification(.authRejected, detail: L("HTTP \(status) from provider. Evidence: \(replay.summary)"))
        }

        if bodyLooksLikeAuthRejection(body) {
            return classification(.authRejected, detail: L("HTTP \(status) authentication rejection. Evidence: \(replay.summary)"))
        }

        if phase.contains("model") {
            if status == 404 || status == 405 || status >= 500 {
                return classification(.modelsEndpointUnavailable, detail: L("HTTP \(status) from the models endpoint. Evidence: \(replay.summary)"))
            }
            if status == 200 && bodyLooksLikeSchemaMismatch(body) {
                return classification(.modelsSchemaMismatch, detail: L("The models endpoint responded with an unexpected schema. Evidence: \(replay.summary)"))
            }
        }

        if body.contains("model_not_found")
            || body.contains("model not found")
            || body.contains("does not exist")
            || body.contains("unsupported model") {
            return classification(.unsupportedModel, detail: L("The provider rejected the selected model. Evidence: \(replay.summary)"))
        }

        if status == 400 || status == 422 || bodyLooksLikeRequestShapeRejection(body) {
            return classification(.requestRejected, detail: L("HTTP \(status) suggests the provider rejected the request shape. Evidence: \(replay.summary)"))
        }

        if bodyLooksLikeSchemaMismatch(body) {
            return classification(.modelsSchemaMismatch, detail: L("The provider response did not match the expected schema. Evidence: \(replay.summary)"))
        }

        if status < 200 || status >= 300 {
            return classification(.badResponse, detail: L("HTTP \(status) from provider. Evidence: \(replay.summary)"))
        }

        return nil
    }

    private static func classifyMessage(
        _ message: String,
        proxy: GlobalProxyDiagnosticState,
        evidence: String? = nil
    ) -> ProviderFailureClassification {
        let safeMessage = ProviderDiagnosticRedactor.safe(message, maxLength: 240)
        let lower = safeMessage.lowercased()
        let detail = evidence.map { L("\(safeMessage) Evidence: \($0)") } ?? safeMessage

        if case .active = proxy, lower.contains("proxy") {
            return classification(.proxyConnectFailed, detail: detail)
        }
        if lower.contains("http 401") || lower.contains("http 403") || lower.contains("unauthorized") {
            return classification(.authRejected, detail: detail)
        }
        if bodyLooksLikeAuthRejection(lower) {
            return classification(.authRejected, detail: detail)
        }
        if lower.contains("oauth") && (lower.contains("token") || lower.contains("sign-in")) {
            return classification(.oauthTokenMissing, detail: detail)
        }
        if lower.contains("api key") || lower.contains("apikey") || lower.contains("authorization") {
            return classification(.missingCredential, detail: detail)
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return classification(.timeout, detail: detail)
        }
        if lower.contains("tls") || lower.contains("ssl") || lower.contains("certificate") {
            return classification(.tlsFailure, detail: detail)
        }
        if lower.contains("could not find host")
            || lower.contains("cannot find host")
            || lower.contains("could not connect")
            || lower.contains("cannot connect")
            || lower.contains("dns")
            || lower.contains("offline")
            || lower.contains("not connected to the internet") {
            return classification(.endpointUnreachable, detail: detail)
        }
        if lower.contains("no models available") {
            return classification(.modelsSchemaMismatch, detail: detail)
        }
        if lower.contains("invalid /models response") || lower.contains("invalid response") {
            return classification(.modelsSchemaMismatch, detail: detail)
        }
        if lower.contains("http 404") || lower.contains("http 405") {
            return classification(.modelsEndpointUnavailable, detail: detail)
        }
        if lower.contains("http 400")
            || lower.contains("http 422")
            || bodyLooksLikeRequestShapeRejection(lower) {
            return classification(.requestRejected, detail: detail)
        }

        return classification(.unknown, detail: detail)
    }

    private static func classifyTransportErrorCode(
        _ code: String,
        summary: String
    ) -> ProviderFailureClassification? {
        switch code {
        case "NSURLErrorDomain:-1001", "URLError:-1001":
            return classification(.timeout, detail: L("The provider request timed out. Evidence: \(summary)"))
        case "NSURLErrorDomain:-1003", "URLError:-1003",
             "NSURLErrorDomain:-1004", "URLError:-1004",
             "NSURLErrorDomain:-1005", "URLError:-1005",
             "NSURLErrorDomain:-1009", "URLError:-1009":
            return classification(.endpointUnreachable, detail: L("The provider endpoint could not be reached. Evidence: \(summary)"))
        case "NSURLErrorDomain:-1200", "URLError:-1200",
             "NSURLErrorDomain:-1202", "URLError:-1202",
             "NSURLErrorDomain:-1203", "URLError:-1203",
             "NSURLErrorDomain:-1204", "URLError:-1204",
             "NSURLErrorDomain:-1205", "URLError:-1205",
             "NSURLErrorDomain:-1206", "URLError:-1206":
            return classification(.tlsFailure, detail: L("TLS or certificate validation failed. Evidence: \(summary)"))
        default:
            return nil
        }
    }

    private static func classification(
        _ bucket: ProviderFailureBucket,
        detail: String
    ) -> ProviderFailureClassification {
        ProviderFailureClassification(
            bucket: bucket,
            title: title(for: bucket),
            detail: ProviderDiagnosticRedactor.safe(detail, maxLength: 360),
            action: action(for: bucket),
            severity: bucket == .unknown ? .warning : .blocked
        )
    }

    private static func title(for bucket: ProviderFailureBucket) -> String {
        switch bucket {
        case .missingCredential:
            return L("Missing credential")
        case .oauthTokenMissing:
            return L("OAuth token missing")
        case .authRejected:
            return L("Authentication rejected")
        case .endpointUnreachable:
            return L("Endpoint unreachable")
        case .tlsFailure:
            return L("TLS failure")
        case .timeout:
            return L("Request timed out")
        case .proxyConnectFailed:
            return L("Proxy connection failed")
        case .modelsEndpointUnavailable:
            return L("Models endpoint unavailable")
        case .modelsSchemaMismatch:
            return L("Models response mismatch")
        case .requestRejected:
            return L("Request format rejected")
        case .unsupportedModel:
            return L("Model unavailable")
        case .badResponse:
            return L("Bad provider response")
        case .unknown:
            return L("Unclassified failure")
        }
    }

    private static func action(for bucket: ProviderFailureBucket) -> String {
        switch bucket {
        case .missingCredential:
            return L("Save an API key or secret credential header, then test again.")
        case .oauthTokenMissing:
            return L("Sign in again and test after OAuth tokens are saved.")
        case .authRejected:
            return L("Verify the credential, account access, and provider-specific auth header.")
        case .endpointUnreachable:
            return L("Check the host, port, base path, DNS, VPN, and whether a local server is running.")
        case .tlsFailure:
            return L("Check the endpoint certificate, HTTPS setting, and any TLS-intercepting proxy.")
        case .timeout:
            return L("Retry after confirming the endpoint is reachable and not blocked by a firewall or proxy.")
        case .proxyConnectFailed:
            return L("Test with the proxy disabled or verify the proxy host, port, and authentication.")
        case .modelsEndpointUnavailable:
            return L("Add manual model IDs if this OpenAI-compatible provider does not expose /models.")
        case .modelsSchemaMismatch:
            return L("Confirm the endpoint returns an OpenAI-shaped model list or add manual model IDs.")
        case .requestRejected:
            return L("Review provider compatibility for unsupported request fields, tools, or response formats.")
        case .unsupportedModel:
            return L("Select a model exposed by this provider or add the correct manual model ID.")
        case .badResponse:
            return L("Copy diagnostics with the redacted response and check provider status or compatibility.")
        case .unknown:
            return L("Copy diagnostics and include the redacted request evidence when reporting this issue.")
        }
    }

    private static func bodyLooksLikeRequestShapeRejection(_ body: String) -> Bool {
        body.contains("invalid request")
            || body.contains("invalid_request")
            || body.contains("unknown parameter")
            || body.contains("unsupported parameter")
            || body.contains("unsupported field")
            || body.contains("tool_choice")
            || body.contains("response_format")
            || body.contains("json_schema")
    }

    private static func bodyLooksLikeSchemaMismatch(_ body: String) -> Bool {
        body.contains("schema")
            || body.contains("decode")
            || body.contains("not valid json")
            || body.contains("invalid json")
    }

    private static func bodyLooksLikeAuthRejection(_ body: String) -> Bool {
        body.contains("invalid_api_key")
            || body.contains("invalid api key")
            || body.contains("invalid authorization")
            || body.contains("authentication failed")
            || body.contains("auth failed")
            || body.contains("bad api key")
            || body.contains("bad token")
            || body.contains("invalid token")
            || body.contains("expired token")
            || body.contains("token expired")
    }

    private static func hasActiveFailure(_ state: RemoteProviderState?) -> Bool {
        guard let state else { return false }
        return state.lastError?.isEmpty == false || state.lastReplayDiagnostics != nil
    }

    private static func hasCredentialHeader(_ provider: RemoteProvider) -> Bool {
        let names = Array(provider.customHeaders.keys) + provider.secretHeaderKeys
        return names.contains {
            RemoteProviderHeaderRedactor.isSensitiveHeader(
                $0,
                configuredSecretHeaderKeys: provider.secretHeaderKeys
            )
        }
    }
}
