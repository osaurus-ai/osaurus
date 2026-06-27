//
//  MCPProviderOperationsHub.swift
//  osaurus
//
//  Operations-focused aggregation for MCP provider management.
//

import Foundation

public enum MCPProviderLaunchPlanStatus: String, Codable, Sendable, Equatable {
    case ready
    case warning
    case blocked
}

public struct MCPProviderLaunchPlan: Sendable, Equatable {
    public let providerId: UUID
    public let transport: MCPProviderTransport
    public let status: MCPProviderLaunchPlanStatus
    public let title: String
    public let detail: String
    public let redactedCommandLine: String?
    public let resolvedExecutablePath: String?
    public let searchPath: String?
    public let workingDirectory: String?
    public let configuredEnvironmentKeys: [String]
    public let secretEnvironmentKeys: [String]
    public let missingSecretEnvironmentKeys: [String]
    public let warnings: [String]

    public var pasteboardText: String {
        var lines = [
            "Launch plan: \(title)",
            "Status: \(status.rawValue)",
            "Detail: \(detail)",
        ]
        if let redactedCommandLine {
            lines.append("Command: \(redactedCommandLine)")
        }
        if let resolvedExecutablePath {
            lines.append("Resolved executable: \(resolvedExecutablePath)")
        }
        if let workingDirectory, !workingDirectory.isEmpty {
            lines.append("Working directory: \(workingDirectory)")
        }
        if !configuredEnvironmentKeys.isEmpty {
            lines.append("Environment keys: \(configuredEnvironmentKeys.joined(separator: ", "))")
        }
        if !secretEnvironmentKeys.isEmpty {
            lines.append("Secret env keys: \(secretEnvironmentKeys.joined(separator: ", "))")
        }
        if !missingSecretEnvironmentKeys.isEmpty {
            lines.append("Missing secret env keys: \(missingSecretEnvironmentKeys.joined(separator: ", "))")
        }
        if let searchPath, !searchPath.isEmpty {
            lines.append("PATH searched: \(searchPath)")
        }
        if !warnings.isEmpty {
            lines.append("Warnings: \(warnings.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }
}

public enum MCPProviderAuthStatusKind: String, Codable, Sendable, Equatable {
    case none
    case bearerTokenPresent
    case bearerTokenMissing
    case oauthSignedIn
    case oauthMissing
    case oauthRequired
    case headerCredentialPresent
}

public struct MCPProviderAuthStatus: Sendable, Equatable {
    public let kind: MCPProviderAuthStatusKind
    public let severity: ProviderDiagnosticSeverity
    public let title: String
    public let detail: String
    public let action: String?
}

public struct MCPProviderOperationsReport: Identifiable, Sendable {
    public var id: UUID { hubReport.id }
    public let hubReport: MCPServerHubProviderReport
    public let launchPlan: MCPProviderLaunchPlan
    public let authStatus: MCPProviderAuthStatus
    public let callHistory: [MCPProviderCallRecord]

    public var provider: MCPProvider { hubReport.provider }
    public var status: MCPServerHubStatus { hubReport.status }
    public var diagnostics: ProviderDiagnosticReport { hubReport.diagnostics }
    public var lastCall: MCPProviderCallRecord? { callHistory.first }

    public var pasteboardText: String {
        var lines = [
            hubReport.diagnostics.pasteboardText,
            "",
            launchPlan.pasteboardText,
            "",
            "Auth status: \(authStatus.title)",
            "Auth detail: \(authStatus.detail)",
        ]
        if let action = authStatus.action {
            lines.append("Auth action: \(action)")
        }
        if callHistory.isEmpty {
            lines.append("")
            lines.append("Recent calls: none")
        } else {
            lines.append("")
            lines.append("Recent calls:")
            for call in callHistory.prefix(10) {
                lines.append("- \(call.toolName): \(call.statusText), \(call.durationMilliseconds)ms, \(call.argumentSummary)")
                if let error = call.errorMessage, !error.isEmpty {
                    lines.append("  Error: \(error)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

public struct MCPProviderOperationsSnapshot: Sendable {
    public let generatedAt: Date
    public let hubSnapshot: MCPServerHubSnapshot
    public let reports: [MCPProviderOperationsReport]

    public var pasteboardText: String {
        var lines = [
            "MCP Operations Hub diagnostics",
            "\(hubSnapshot.connectedCount)/\(hubSnapshot.totalCount) connected, \(hubSnapshot.attentionCount) attention, \(hubSnapshot.toolCount) tools",
            "",
            hubSnapshot.pasteboardText,
        ]
        for report in reports {
            lines.append("")
            lines.append(report.pasteboardText)
        }
        return lines.joined(separator: "\n")
    }

    public func filtered(by filter: MCPServerHubFilter) -> [MCPProviderOperationsReport] {
        reports.filter { filter.includes($0.hubReport) }
    }
}

enum MCPProviderOperationsFieldNormalizer {
    static func normalize(
        _ entries: [(key: String, value: String, isSecret: Bool)]
    ) -> (regular: [String: String], secretKeys: [String]) {
        var regular: [String: String] = [:]
        var secretKeys: [String] = []

        for entry in entries {
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }

            regular.removeValue(forKey: key)
            secretKeys.removeAll { $0 == key }
            if entry.isSecret {
                secretKeys.append(key)
            } else {
                regular[key] = entry.value
            }
        }

        return (regular, secretKeys)
    }
}

public enum MCPProviderOperationsHub {
    static func credentialPresence(
        for providers: [MCPProvider]
    ) -> [UUID: MCPProviderCredentialPresence] {
        var next: [UUID: MCPProviderCredentialPresence] = [:]
        for provider in providers {
            let providerId = provider.id
            next[providerId] = MCPProviderCredentialPresence(
                bearerTokenPresent: MCPProviderKeychain.hasToken(for: providerId),
                oauthTokensPresent: MCPProviderKeychain.hasOAuthTokens(for: providerId)
            )
        }
        return next
    }

    public static func emptySnapshot(
        generatedAt: Date = Date(),
        proxy: GlobalProxyDiagnosticState = .disabled
    ) -> MCPProviderOperationsSnapshot {
        MCPProviderOperationsSnapshot(
            generatedAt: generatedAt,
            hubSnapshot: MCPServerHubSnapshot(reports: [], proxy: proxy),
            reports: []
        )
    }

    public static func snapshot(
        providers: [MCPProvider],
        states: [UUID: MCPProviderState],
        proxy: GlobalProxyDiagnosticState,
        credentialsByProvider: [UUID: MCPProviderCredentialPresence],
        healthSnapshots: [UUID: MCPProviderHealthSnapshot],
        callHistoryByProvider: [UUID: [MCPProviderCallRecord]] = MCPProviderCallHistoryStore.load()
    ) -> MCPProviderOperationsSnapshot {
        let hubSnapshot = MCPServerHub.snapshot(
            providers: providers,
            states: states,
            proxy: proxy,
            credentialsByProvider: credentialsByProvider,
            healthSnapshots: healthSnapshots
        )
        let reports = hubSnapshot.reports.map { report in
            MCPProviderOperationsReport(
                hubReport: report,
                launchPlan: launchPlan(for: report.provider),
                authStatus: authStatus(
                    provider: report.provider,
                    state: report.state,
                    credentialPresence: credentialsByProvider[report.provider.id] ?? MCPProviderCredentialPresence()
                ),
                callHistory: callHistoryByProvider[report.provider.id] ?? []
            )
        }
        return MCPProviderOperationsSnapshot(
            generatedAt: Date(),
            hubSnapshot: hubSnapshot,
            reports: reports
        )
    }

    public static func authStatus(
        provider: MCPProvider,
        state: MCPProviderState?,
        credentialPresence: MCPProviderCredentialPresence
    ) -> MCPProviderAuthStatus {
        switch provider.authType {
        case .none:
            if hasCredentialHeader(provider) {
                return MCPProviderAuthStatus(
                    kind: .headerCredentialPresent,
                    severity: .ok,
                    title: L("Header credential configured"),
                    detail: L("A regular or secret Authorization header is configured."),
                    action: nil
                )
            }
            return MCPProviderAuthStatus(
                kind: .none,
                severity: .info,
                title: L("No auth"),
                detail: L("Osaurus will not add an Authorization header."),
                action: nil
            )
        case .bearerToken:
            if credentialPresence.bearerTokenPresent || hasCredentialHeader(provider) {
                return MCPProviderAuthStatus(
                    kind: .bearerTokenPresent,
                    severity: .ok,
                    title: L("Bearer credential saved"),
                    detail: L("The token or secret header is stored outside the provider JSON."),
                    action: nil
                )
            }
            return MCPProviderAuthStatus(
                kind: .bearerTokenMissing,
                severity: state?.requiresAuth == true ? .blocked : .warning,
                title: L("Bearer token missing"),
                detail: state?.lastError.map(redact) ?? L("No bearer token is present in Keychain."),
                action: L("Paste a token in the editor or inline auth prompt.")
            )
        case .oauth:
            if state?.requiresAuth == true {
                return MCPProviderAuthStatus(
                    kind: .oauthRequired,
                    severity: .blocked,
                    title: L("OAuth sign-in required"),
                    detail: state?.lastError.map(redact) ?? L("The server rejected discovery until sign-in completes."),
                    action: L("Sign in again and retry discovery.")
                )
            }
            if credentialPresence.oauthTokensPresent {
                return MCPProviderAuthStatus(
                    kind: .oauthSignedIn,
                    severity: .ok,
                    title: L("OAuth signed in"),
                    detail: L("OAuth tokens are saved and refreshed before discovery."),
                    action: nil
                )
            }
            return MCPProviderAuthStatus(
                kind: .oauthMissing,
                severity: .warning,
                title: L("OAuth not signed in"),
                detail: L("No OAuth token set is saved for this provider."),
                action: L("Run Sign In before connecting.")
            )
        }
    }

    public static func launchPlan(
        for provider: MCPProvider,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        secretEnvValues: [String: String]? = nil,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) -> MCPProviderLaunchPlan {
        switch provider.transport {
        case .http:
            return httpLaunchPlan(for: provider)
        case .stdio:
            return stdioLaunchPlan(
                for: provider,
                processEnvironment: processEnvironment,
                secretEnvValues: secretEnvValues,
                isExecutable: isExecutable,
                directoryExists: directoryExists
            )
        }
    }

    private static func httpLaunchPlan(for provider: MCPProvider) -> MCPProviderLaunchPlan {
        let trimmedURL = provider.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: trimmedURL), endpoint.scheme?.isEmpty == false, endpoint.host?.isEmpty == false
        else {
            return MCPProviderLaunchPlan(
                providerId: provider.id,
                transport: .http,
                status: .blocked,
                title: L("HTTP endpoint invalid"),
                detail: L("The provider URL must include a scheme, host, and MCP path."),
                redactedCommandLine: nil,
                resolvedExecutablePath: nil,
                searchPath: nil,
                workingDirectory: nil,
                configuredEnvironmentKeys: [],
                secretEnvironmentKeys: [],
                missingSecretEnvironmentKeys: [],
                warnings: [L("Edit the URL before testing or connecting.")]
            )
        }

        let redactedEndpoint = MCPProviderProbeRedactor.safeHTTPURLForDiagnostics(endpoint.absoluteString)
        return MCPProviderLaunchPlan(
            providerId: provider.id,
            transport: .http,
            status: .ready,
            title: provider.streamingEnabled ? "HTTP/SSE" : "HTTP",
            detail: L("Discovery and tool calls target \(redactedEndpoint)."),
            redactedCommandLine: nil,
            resolvedExecutablePath: nil,
            searchPath: nil,
            workingDirectory: nil,
            configuredEnvironmentKeys: [],
            secretEnvironmentKeys: [],
            missingSecretEnvironmentKeys: [],
            warnings: []
        )
    }

    private static func stdioLaunchPlan(
        for provider: MCPProvider,
        processEnvironment: [String: String],
        secretEnvValues: [String: String]?,
        isExecutable: (String) -> Bool,
        directoryExists: (String) -> Bool
    ) -> MCPProviderLaunchPlan {
        let command = provider.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretEnvironmentKeys = uniqueTrimmedKeys(provider.secretEnvKeys).sorted()
        let configuredEnvironmentKeys = Array(Set(provider.env.keys).union(secretEnvironmentKeys)).sorted()
        let missingSecretEnvironmentKeys = missingSecretKeys(
            for: provider,
            secretEnvKeys: secretEnvironmentKeys,
            secretEnvValues: secretEnvValues
        )
        let redactedCommandLine = redact(commandLine(provider: provider))
        var warnings: [String] = []

        guard !command.isEmpty else {
            return MCPProviderLaunchPlan(
                providerId: provider.id,
                transport: .stdio,
                status: .blocked,
                title: L("Stdio command missing"),
                detail: L("A local MCP provider needs an executable command before launch."),
                redactedCommandLine: nil,
                resolvedExecutablePath: nil,
                searchPath: nil,
                workingDirectory: normalizedWorkingDirectory(provider.workingDirectory),
                configuredEnvironmentKeys: configuredEnvironmentKeys,
                secretEnvironmentKeys: secretEnvironmentKeys,
                missingSecretEnvironmentKeys: missingSecretEnvironmentKeys,
                warnings: [L("Enter a command before testing.")]
            )
        }

        if !missingSecretEnvironmentKeys.isEmpty {
            warnings.append(
                L("Missing Keychain values for: \(missingSecretEnvironmentKeys.joined(separator: ", ")).")
            )
        }

        let cwd = normalizedWorkingDirectory(provider.workingDirectory)
        if let cwd, provider.executionHost == .host, !directoryExists(cwd) {
            warnings.append(L("Working directory does not exist: \(cwd)."))
        }

        switch provider.executionHost {
        case .sandbox:
            let status: MCPProviderLaunchPlanStatus =
                missingSecretEnvironmentKeys.isEmpty && warnings.isEmpty ? .ready : .warning
            return MCPProviderLaunchPlan(
                providerId: provider.id,
                transport: .stdio,
                status: status,
                title: L("Sandbox stdio"),
                detail: L("The command runs inside the Osaurus sandbox via a short-lived stdio process."),
                redactedCommandLine: redactedCommandLine,
                resolvedExecutablePath: nil,
                searchPath: nil,
                workingDirectory: cwd,
                configuredEnvironmentKeys: configuredEnvironmentKeys,
                secretEnvironmentKeys: secretEnvironmentKeys,
                missingSecretEnvironmentKeys: missingSecretEnvironmentKeys,
                warnings: warnings
            )
        case .host:
            let fullEnv = resolvedProcessEnvironment(
                provider: provider,
                processEnvironment: processEnvironment,
                secretEnvValues: secretEnvValues
            )
            let searchPath = executableSearchPath(env: fullEnv)
            let expandedCommand = expandUserPath(command)
            var resolvedExecutablePath: String?

            if expandedCommand.contains("/") {
                resolvedExecutablePath = expandedCommand
                if !isExecutable(expandedCommand) {
                    warnings.append(L("Executable path is not executable: \(expandedCommand)."))
                }
            } else if let found = resolveOnPath(expandedCommand, searchPath: searchPath, isExecutable: isExecutable) {
                resolvedExecutablePath = found
            } else {
                return MCPProviderLaunchPlan(
                    providerId: provider.id,
                    transport: .stdio,
                    status: .blocked,
                    title: L("Host command not found"),
                    detail: L("`\(command)` was not found on the app PATH or common local bin directories."),
                    redactedCommandLine: redactedCommandLine,
                    resolvedExecutablePath: nil,
                    searchPath: searchPath,
                    workingDirectory: cwd,
                    configuredEnvironmentKeys: configuredEnvironmentKeys,
                    secretEnvironmentKeys: secretEnvironmentKeys,
                    missingSecretEnvironmentKeys: missingSecretEnvironmentKeys,
                    warnings: warnings + [L("Use a full executable path such as /opt/homebrew/bin/npx.")]
                )
            }

            let status: MCPProviderLaunchPlanStatus = warnings.isEmpty ? .ready : .warning
            return MCPProviderLaunchPlan(
                providerId: provider.id,
                transport: .stdio,
                status: status,
                title: L("Host stdio"),
                detail: L("The command runs directly on macOS and inherits the app environment plus provider env."),
                redactedCommandLine: redactedCommandLine,
                resolvedExecutablePath: resolvedExecutablePath,
                searchPath: searchPath,
                workingDirectory: cwd,
                configuredEnvironmentKeys: configuredEnvironmentKeys,
                secretEnvironmentKeys: secretEnvironmentKeys,
                missingSecretEnvironmentKeys: missingSecretEnvironmentKeys,
                warnings: warnings
            )
        }
    }

    private static func hasCredentialHeader(_ provider: MCPProvider) -> Bool {
        provider.customHeaders.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
            || provider.secretHeaderKeys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }
    }

    private static func missingSecretKeys(
        for provider: MCPProvider,
        secretEnvKeys: [String],
        secretEnvValues: [String: String]?
    ) -> [String] {
        secretEnvKeys.filter { key in
            if let secretEnvValues {
                return secretEnvValues[key]?.isEmpty != false
            }
            return MCPProviderKeychain.getEnvSecret(key: key, for: provider.id)?.isEmpty != false
        }
        .sorted()
    }

    private static func resolvedProcessEnvironment(
        provider: MCPProvider,
        processEnvironment: [String: String],
        secretEnvValues: [String: String]?
    ) -> [String: String] {
        var merged = processEnvironment
        for (key, value) in provider.env {
            merged[key] = value
        }
        for key in uniqueTrimmedKeys(provider.secretEnvKeys) {
            let value = secretEnvValues?[key] ?? MCPProviderKeychain.getEnvSecret(key: key, for: provider.id)
            if let value, !value.isEmpty {
                merged[key] = value
            } else {
                merged.removeValue(forKey: key)
            }
        }
        return merged
    }

    private static func commandLine(provider: MCPProvider) -> String {
        let args = ShellArgs.join(provider.args)
        return args.isEmpty ? provider.command : "\(provider.command) \(args)"
    }

    private static func executableSearchPath(env: [String: String]) -> String {
        var entries =
            (env["PATH"]?.isEmpty == false ? env["PATH"] : nil)?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for fallback in [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ] where !entries.contains(fallback) {
            entries.append(fallback)
        }
        return entries.joined(separator: ":")
    }

    private static func resolveOnPath(
        _ command: String,
        searchPath: String,
        isExecutable: (String) -> Bool
    ) -> String? {
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(directory)/\(command)"
            if isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func normalizedWorkingDirectory(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return expandUserPath(raw)
    }

    private static func expandUserPath(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" { return home }
        return home + String(path.dropFirst())
    }

    private static func redact(_ value: String) -> String {
        MCPProviderProbeRedactor.safeDiagnosticFragment(value, maxLength: 500)
    }

    private static func uniqueTrimmedKeys(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for key in keys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
