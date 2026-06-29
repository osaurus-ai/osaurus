//
//  ProviderNetworkDiagnostics.swift
//  osaurus
//
//  Human-readable diagnostics for inference providers, MCP providers, and the
//  shared network policy they depend on.
//

import Foundation

/// Severity used by provider diagnostics rows. The raw values are stable so
/// tests and copied reports can reason about status without parsing UI text.
public enum ProviderDiagnosticSeverity: String, Codable, Sendable, Equatable {
    case ok
    case info
    case warning
    case blocked
}

/// One safe-to-display provider diagnostic row.
public struct ProviderDiagnosticRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let value: String
    public let detail: String?
    public let action: String?
    public let severity: ProviderDiagnosticSeverity

    public init(
        id: String,
        title: String,
        value: String,
        severity: ProviderDiagnosticSeverity,
        detail: String? = nil,
        action: String? = nil
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.detail = detail
        self.action = action
        self.severity = severity
    }
}

/// A copyable diagnostics snapshot for one provider row.
public struct ProviderDiagnosticReport: Sendable, Equatable {
    public let title: String
    public let subtitle: String
    public let rows: [ProviderDiagnosticRow]

    public init(title: String, subtitle: String, rows: [ProviderDiagnosticRow]) {
        self.title = title
        self.subtitle = subtitle
        self.rows = rows
    }

    /// Pasteboard text intentionally contains status and hints, but never raw
    /// credential values, request bodies, callback URLs, or provider headers.
    public var pasteboardText: String {
        var lines = [
            title,
            subtitle,
        ]
        lines.append(
            contentsOf: rows.map { row in
                var line = "[\(row.severity.rawValue)] \(row.title): \(row.value)"
                if let detail = row.detail, !detail.isEmpty {
                    line += " - \(detail)"
                }
                if let action = row.action, !action.isEmpty {
                    line += " Action: \(action)"
                }
                return line
            }
        )
        return lines.joined(separator: "\n")
    }
}

/// Builds provider diagnostics from existing configuration/state so UI, tests,
/// and support docs all describe the same behavior.
public enum ProviderNetworkDiagnostics {
    public static func remoteProviderReport(
        provider: RemoteProvider,
        state: RemoteProviderState?,
        proxy: GlobalProxyDiagnosticState,
        apiKeyPresent: Bool,
        oauthTokensPresent: Bool
    ) -> ProviderDiagnosticReport {
        var rows = [
            remoteStateRow(provider: provider, state: state),
            remoteAuthRow(
                provider: provider,
                state: state,
                apiKeyPresent: apiKeyPresent,
                oauthTokensPresent: oauthTokensPresent
            ),
        ]
        if let oauthContext = remoteOAuthContextRow(
            provider: provider,
            state: state,
            oauthTokensPresent: oauthTokensPresent
        ) {
            rows.append(oauthContext)
        }
        if let replay = remoteReplayDiagnosticsRow(state: state) {
            rows.append(replay)
        }
        rows.append(
            contentsOf: [
                remoteModelDiscoveryRow(provider: provider),
                remoteRequestFormatRow(provider: provider),
                proxyRow(proxy, appliesTo: "Remote provider requests"),
            ]
        )

        return ProviderDiagnosticReport(
            title: "Remote provider diagnostics",
            subtitle: "\(provider.name) | \(provider.displayEndpoint)",
            rows: rows
        )
    }

    public static func mcpProviderReport(
        provider: MCPProvider,
        state: MCPProviderState?,
        proxy: GlobalProxyDiagnosticState,
        bearerTokenPresent: Bool,
        oauthTokensPresent: Bool
    ) -> ProviderDiagnosticReport {
        ProviderDiagnosticReport(
            title: "MCP provider diagnostics",
            subtitle: "\(provider.name) | \(mcpEndpointSubtitle(for: provider))",
            rows: [
                mcpStateRow(provider: provider, state: state),
                mcpAuthRow(
                    provider: provider,
                    state: state,
                    bearerTokenPresent: bearerTokenPresent,
                    oauthTokensPresent: oauthTokensPresent
                ),
                mcpTransportRow(provider: provider),
                mcpProxyRow(provider: provider, proxy: proxy),
                mcpFailureReproRow(provider: provider, state: state),
            ]
        )
    }

    // MARK: - Remote Providers

    private static func remoteStateRow(
        provider: RemoteProvider,
        state: RemoteProviderState?
    ) -> ProviderDiagnosticRow {
        guard provider.enabled else {
            return ProviderDiagnosticRow(
                id: "connection",
                title: L("Connection"),
                value: L("Disabled"),
                severity: .warning,
                detail: L("Osaurus will not auto-connect this provider while the row toggle is off."),
                action: L("Enable the provider before testing or selecting its models.")
            )
        }

        if state?.isConnecting == true {
            return ProviderDiagnosticRow(
                id: "connection",
                title: L("Connection"),
                value: L("Connecting"),
                severity: .info,
                detail: L("A bounded model-discovery request is in flight.")
            )
        }

        if state?.isConnected == true {
            return ProviderDiagnosticRow(
                id: "connection",
                title: L("Connection"),
                value: L("Connected"),
                severity: .ok,
                detail: L("\(state?.modelCount ?? 0) model(s) currently available.")
            )
        }

        if let error = state?.lastError, !error.isEmpty {
            return ProviderDiagnosticRow(
                id: "connection",
                title: L("Connection"),
                value: L("Failed"),
                severity: .blocked,
                detail: safeDiagnostic(error),
                action: L("Use the Test button or copy diagnostics when reporting the issue.")
            )
        }

        return ProviderDiagnosticRow(
            id: "connection",
            title: L("Connection"),
            value: L("Not connected"),
            severity: .info,
            detail: L("The provider is configured but has not completed model discovery yet.")
        )
    }

    private static func remoteAuthRow(
        provider: RemoteProvider,
        state: RemoteProviderState?,
        apiKeyPresent: Bool,
        oauthTokensPresent: Bool
    ) -> ProviderDiagnosticRow {
        switch provider.authType {
        case .none:
            return ProviderDiagnosticRow(
                id: "auth",
                title: L("Authentication"),
                value: L("None"),
                severity: .info,
                detail: L("No Authorization header is added by Osaurus.")
            )
        case .apiKey:
            if apiKeyPresent {
                return ProviderDiagnosticRow(
                    id: "auth",
                    title: L("Authentication"),
                    value: L("API key in Keychain"),
                    severity: .ok,
                    detail: L("The saved key is injected using the provider-specific header.")
                )
            }
            if hasCredentialHeader(provider) {
                return ProviderDiagnosticRow(
                    id: "auth",
                    title: L("Authentication"),
                    value: L("Credential header configured"),
                    severity: .ok,
                    detail: L("A regular or secret credential header is configured for this provider.")
                )
            }
            return ProviderDiagnosticRow(
                id: "auth",
                title: L("Authentication"),
                value: L("Missing API key"),
                severity: .blocked,
                detail: state?.lastError.map(safeDiagnostic),
                action: L("Edit the provider and save an API key or secret Authorization header.")
            )
        case .openAICodexOAuth:
            if oauthTokensPresent {
                return ProviderDiagnosticRow(
                    id: "auth",
                    title: L("Authentication"),
                    value: L("ChatGPT signed in"),
                    severity: .ok,
                    detail: L("Codex OAuth tokens are present and refreshed before model discovery.")
                )
            }
            return ProviderDiagnosticRow(
                id: "auth",
                title: L("Authentication"),
                value: L("ChatGPT sign-in required"),
                severity: .blocked,
                detail: state?.lastError.map(safeDiagnostic)
                    ?? L("No Codex OAuth tokens are saved for this provider."),
                action: L("Sign in with the ChatGPT account that has Codex access.")
            )
        case .xaiOAuth:
            if oauthTokensPresent {
                return ProviderDiagnosticRow(
                    id: "auth",
                    title: L("Authentication"),
                    value: L("xAI signed in"),
                    severity: .ok,
                    detail: L("xAI OAuth tokens are present and refreshed before model discovery.")
                )
            }
            return ProviderDiagnosticRow(
                id: "auth",
                title: L("Authentication"),
                value: L("xAI sign-in required"),
                severity: .blocked,
                detail: state?.lastError.map(safeDiagnostic)
                    ?? L("No xAI OAuth tokens are saved for this provider."),
                action: L("Sign in with the xAI account that has Grok API access.")
            )
        }
    }

    private static func remoteModelDiscoveryRow(provider: RemoteProvider) -> ProviderDiagnosticRow {
        guard let modelsURL = provider.url(for: provider.providerType.modelsEndpoint) else {
            return ProviderDiagnosticRow(
                id: "models",
                title: L("Model discovery"),
                value: L("Invalid URL"),
                severity: .blocked,
                detail: L("Host, port, or base path could not be converted into a /models URL."),
                action: L("Edit the endpoint fields and test again.")
            )
        }

        switch provider.providerType {
        case .openAICodex:
            return ProviderDiagnosticRow(
                id: "models",
                title: L("Model discovery"),
                value: L("ChatGPT/Codex catalog"),
                severity: .info,
                detail:
                    L(
                        "Uses the live ChatGPT model catalog after sign-in, with the static Codex fallback before sign-in."
                    )
            )
        case .azureOpenAI:
            let hasManual = !provider.mergedModelIds(discovered: []).isEmpty
            return ProviderDiagnosticRow(
                id: "models",
                title: L("Model discovery"),
                value: hasManual ? L("Manual deployments") : L("/models probe"),
                severity: hasManual ? .ok : .warning,
                detail: hasManual
                    ? L("Azure deployment IDs are configured, so connect can proceed even when /models is unavailable.")
                    : L("Azure often requires manual deployment IDs because /models may be unavailable."),
                action: hasManual ? nil : L("Add at least one deployment/model ID in Advanced.")
            )
        case .openaiLegacy, .openResponses:
            let manual = provider.mergedModelIds(discovered: [])
            let detail =
                manual.isEmpty
                ? L("Requires \(modelsURL.absoluteString) to return an OpenAI-shaped model list.")
                : L("Manual IDs are used if /models is missing or returns a non-OpenAI schema.")
            return ProviderDiagnosticRow(
                id: "models",
                title: L("Model discovery"),
                value: manual.isEmpty ? L("/models required") : L("Fallback available"),
                severity: manual.isEmpty ? .info : .ok,
                detail: detail
            )
        case .anthropic:
            return ProviderDiagnosticRow(
                id: "models",
                title: L("Model discovery"),
                value: "Anthropic /models",
                severity: .info,
                detail: L("Uses Anthropic's paginated model catalog endpoint.")
            )
        case .gemini:
            return ProviderDiagnosticRow(
                id: "models",
                title: L("Model discovery"),
                value: L("Gemini model list"),
                severity: .info,
                detail: L("Filters the Gemini catalog to models that support generateContent.")
            )
        case .osaurus:
            return ProviderDiagnosticRow(
                id: "models",
                title: L("Model discovery"),
                value: L("Remote Osaurus"),
                severity: .info,
                detail: L("Tries the remote /models endpoint, then falls back to the agent default model.")
            )
        case .osaurusRouter:
            return ProviderDiagnosticRow(
                id: "models",
                title: L("Model discovery"),
                value: L("Osaurus Router"),
                severity: .info,
                detail: L("Fetches the signed router /models endpoint and hides stale prices.")
            )
        }
    }

    private static func remoteOAuthContextRow(
        provider: RemoteProvider,
        state: RemoteProviderState?,
        oauthTokensPresent: Bool
    ) -> ProviderDiagnosticRow? {
        guard provider.authType == .openAICodexOAuth || provider.providerType == .openAICodex else {
            return nil
        }

        var details = [
            "providerType=\(provider.providerType.rawValue)",
            "authType=\(provider.authType.rawValue)",
            "redirectURI=\(OpenAICodexOAuthService.redirectURI)",
            "callbackPort=1455",
            "tokens=\(oauthTokensPresent ? "present" : "missing")",
        ]
        if let error = state?.lastError, !error.isEmpty {
            details.append("lastError=\(safeDiagnostic(error))")
        }

        return ProviderDiagnosticRow(
            id: "oauth-context",
            title: L("OAuth context"),
            value: L("Codex subscription"),
            severity: oauthTokensPresent ? .info : .warning,
            detail: details.joined(separator: "; "),
            action: L("Copy diagnostics after a failed sign-in attempt and include this row in the issue.")
        )
    }

    private static func remoteReplayDiagnosticsRow(state: RemoteProviderState?) -> ProviderDiagnosticRow? {
        guard let diagnostics = state?.lastReplayDiagnostics else { return nil }
        return ProviderDiagnosticRow(
            id: "request-evidence",
            title: L("Request evidence"),
            value: diagnostics.summary,
            severity: .warning,
            detail: diagnostics.pasteboardText,
            action: L("Copy diagnostics and include this redacted request/response evidence with the report.")
        )
    }

    private static func remoteRequestFormatRow(provider: RemoteProvider) -> ProviderDiagnosticRow {
        ProviderDiagnosticRow(
            id: "format",
            title: L("Request format"),
            value: L("\(provider.providerType.displayName) \(provider.providerType.chatEndpoint)"),
            severity: .info,
            detail:
                L(
                    "Local OpenAI-compatible validation returns typed 400 errors for unsupported sampler fields such as n > 1 or response_format=json_schema."
                )
        )
    }

    // MARK: - MCP Providers

    private static func mcpStateRow(provider: MCPProvider, state: MCPProviderState?) -> ProviderDiagnosticRow {
        guard provider.enabled else {
            return ProviderDiagnosticRow(
                id: "connection",
                title: L("Connection"),
                value: L("Disabled"),
                severity: .warning,
                detail: L("Osaurus will not auto-connect this MCP provider while the row toggle is off.")
            )
        }
        if state?.isConnecting == true {
            return ProviderDiagnosticRow(
                id: "connection",
                title: L("Connection"),
                value: L("Connecting"),
                severity: .info,
                detail: L("Tool discovery is running with a \(Int(provider.discoveryTimeout))s timeout.")
            )
        }
        if state?.isConnected == true {
            return ProviderDiagnosticRow(
                id: "connection",
                title: L("Connection"),
                value: L("Connected"),
                severity: .ok,
                detail: L("\(state?.discoveredToolCount ?? 0) tool(s) discovered.")
            )
        }
        if state?.requiresAuth == true {
            return ProviderDiagnosticRow(
                id: "connection",
                title: L("Connection"),
                value: L("Auth required"),
                severity: .blocked,
                detail: state?.lastError.map(safeDiagnostic),
                action: L("Use the inline Sign In or token prompt.")
            )
        }
        if let error = state?.lastError, !error.isEmpty {
            return ProviderDiagnosticRow(
                id: "connection",
                title: L("Connection"),
                value: L("Failed"),
                severity: .blocked,
                detail: safeDiagnostic(error),
                action: L("Use the Test button in Edit to reproduce the failure.")
            )
        }
        return ProviderDiagnosticRow(
            id: "connection",
            title: L("Connection"),
            value: L("Not connected"),
            severity: .info,
            detail: L("The provider is configured but no tools are registered yet.")
        )
    }

    private static func mcpAuthRow(
        provider: MCPProvider,
        state: MCPProviderState?,
        bearerTokenPresent: Bool,
        oauthTokensPresent: Bool
    ) -> ProviderDiagnosticRow {
        switch provider.authType {
        case .none:
            return ProviderDiagnosticRow(
                id: "auth",
                title: L("Authentication"),
                value: L("None"),
                severity: .info,
                detail: L("No Authorization header is added by Osaurus.")
            )
        case .bearerToken:
            if bearerTokenPresent || hasMCPHeaderCredential(provider) {
                return ProviderDiagnosticRow(
                    id: "auth",
                    title: L("Authentication"),
                    value: L("Bearer credential configured"),
                    severity: .ok,
                    detail: L("The token or secret header is stored outside plain provider config.")
                )
            }
            return ProviderDiagnosticRow(
                id: "auth",
                title: L("Authentication"),
                value: state?.requiresAuth == true ? L("Token required") : L("No token saved"),
                severity: state?.requiresAuth == true ? .blocked : .warning,
                detail: state?.lastError.map(safeDiagnostic),
                action: L("Paste an API token in the inline prompt or edit the provider.")
            )
        case .oauth:
            if oauthTokensPresent {
                return ProviderDiagnosticRow(
                    id: "auth",
                    title: L("Authentication"),
                    value: L("OAuth tokens saved"),
                    severity: .ok,
                    detail: L("Tokens are refreshed before HTTP MCP discovery.")
                )
            }
            return ProviderDiagnosticRow(
                id: "auth",
                title: L("Authentication"),
                value: L("OAuth sign-in required"),
                severity: state?.requiresAuth == true ? .blocked : .warning,
                detail: state?.lastError.map(safeDiagnostic)
                    ?? L("No OAuth tokens are saved for this provider."),
                action: L("Sign in from the provider row.")
            )
        }
    }

    private static func mcpTransportRow(provider: MCPProvider) -> ProviderDiagnosticRow {
        switch provider.transport {
        case .http:
            return ProviderDiagnosticRow(
                id: "transport",
                title: L("Transport"),
                value: provider.streamingEnabled ? "HTTP/SSE" : "HTTP",
                severity: .info,
                detail: L("Discovery and tool calls use URLSession with the global proxy policy applied.")
            )
        case .stdio:
            let command = provider.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if command.isEmpty {
                return ProviderDiagnosticRow(
                    id: "transport",
                    title: L("Transport"),
                    value: L("Stdio command missing"),
                    severity: .blocked,
                    detail: L("A stdio MCP provider needs a command before it can launch."),
                    action: L("Edit the provider and enter the executable.")
                )
            }
            return ProviderDiagnosticRow(
                id: "transport",
                title: L("Transport"),
                value: L("Stdio \(provider.executionHost.rawValue)"),
                severity: provider.executionHost == .host ? .warning : .ok,
                detail: provider.executionHost == .host
                    ? L("Runs directly on the macOS host. Prefer full executable paths for GUI-launched apps.")
                    : L("Runs inside the Osaurus sandbox and is torn down on disconnect.")
            )
        }
    }

    private static func mcpProxyRow(
        provider: MCPProvider,
        proxy: GlobalProxyDiagnosticState
    ) -> ProviderDiagnosticRow {
        switch provider.transport {
        case .http:
            return proxyRow(proxy, appliesTo: "MCP HTTP/SSE requests")
        case .stdio:
            return ProviderDiagnosticRow(
                id: "proxy",
                title: L("Global proxy"),
                value: L("Not used for stdio"),
                severity: .info,
                detail: L(
                    "Stdio providers launch a local subprocess instead of sending HTTP traffic through URLSession."
                )
            )
        }
    }

    private static func mcpFailureReproRow(
        provider: MCPProvider,
        state: MCPProviderState?
    ) -> ProviderDiagnosticRow {
        if let error = state?.lastError, !error.isEmpty {
            let commandMissing = MCPStdioTransportError.isCommandNotFoundMessage(error)
            return ProviderDiagnosticRow(
                id: "repro",
                title: L("Repro path"),
                value: commandMissing ? L("PATH issue") : L("Copyable error"),
                severity: .warning,
                detail: safeDiagnostic(error),
                action: commandMissing
                    ? L("Use a full path such as /opt/homebrew/bin/npx or switch execution host.")
                    : L("Open Edit and press Test to reproduce discovery without saving.")
            )
        }
        if provider.transport == .stdio {
            return ProviderDiagnosticRow(
                id: "repro",
                title: L("Repro path"),
                value: L("Short-lived stdio probe"),
                severity: .info,
                detail: L("The Test button launches the subprocess, runs initialize/listTools, and tears it down.")
            )
        }
        return ProviderDiagnosticRow(
            id: "repro",
            title: L("Repro path"),
            value: L("HTTP discovery probe"),
            severity: .info,
            detail: L("401 challenges surface as inline sign-in or token prompts with the last error preserved.")
        )
    }

    // MARK: - Shared

    private static func proxyRow(_ proxy: GlobalProxyDiagnosticState, appliesTo: String) -> ProviderDiagnosticRow {
        switch proxy {
        case .disabled:
            return ProviderDiagnosticRow(
                id: "proxy",
                title: L("Global proxy"),
                value: L("Off"),
                severity: .info,
                detail: L("\(appliesTo) use direct networking.")
            )
        case .active(let description):
            return ProviderDiagnosticRow(
                id: "proxy",
                title: L("Global proxy"),
                value: description,
                severity: .ok,
                detail: L("\(appliesTo) use this validated proxy endpoint.")
            )
        case .invalid(let reason):
            return ProviderDiagnosticRow(
                id: "proxy",
                title: L("Global proxy"),
                value: L("Ignored"),
                severity: .warning,
                detail: reason,
                action: L("Fix or clear the proxy URL in Server settings.")
            )
        }
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

    private static func hasMCPHeaderCredential(_ provider: MCPProvider) -> Bool {
        let names = Array(provider.customHeaders.keys) + provider.secretHeaderKeys
        return names.contains {
            RemoteProviderHeaderRedactor.isSensitiveHeader(
                $0,
                configuredSecretHeaderKeys: provider.secretHeaderKeys
            )
        }
    }

    private static func mcpEndpointSubtitle(for provider: MCPProvider) -> String {
        switch provider.transport {
        case .http:
            return provider.url
        case .stdio:
            let args = ShellArgs.join(provider.args)
            return args.isEmpty ? provider.command : "\(provider.command) \(args)"
        }
    }

    private static func safeDiagnostic(_ raw: String) -> String {
        ProviderDiagnosticRedactor.safe(raw, maxLength: 280)
    }
}
