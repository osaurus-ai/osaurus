//
//  MCPProviderProbeService.swift
//  osaurus
//
//  Explicit, short-lived MCP provider probes with stable reason codes.
//

import Foundation
import MCP

public enum MCPProviderProbeStage: String, Codable, Sendable, Equatable {
    case configuration
    case spawn
    case connect
    case listTools
    case teardown
}

public enum MCPProviderProbeReasonCode: String, Codable, Sendable, Equatable {
    case succeeded
    case invalidURL
    case missingCommand
    case commandNotFound
    case sandboxUnavailable
    case spawnFailed
    case timeout
    case authRequired
    case protocolError
    case connectionFailed
    case unknownFailure
}

public struct MCPProviderProbeResult: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID { probeId }

    public let probeId: UUID
    public let providerId: UUID
    public let providerName: String
    public let transportSummary: String
    public let startedAt: Date
    public let finishedAt: Date
    public let succeeded: Bool
    public let stage: MCPProviderProbeStage
    public let reasonCode: MCPProviderProbeReasonCode
    public let toolCount: Int
    public let toolNames: [String]
    public let message: String
    public let action: String?

    public init(
        probeId: UUID = UUID(),
        providerId: UUID,
        providerName: String,
        transportSummary: String,
        startedAt: Date,
        finishedAt: Date,
        succeeded: Bool,
        stage: MCPProviderProbeStage,
        reasonCode: MCPProviderProbeReasonCode,
        toolCount: Int,
        toolNames: [String],
        message: String,
        action: String?
    ) {
        self.probeId = probeId
        self.providerId = providerId
        self.providerName = providerName
        self.transportSummary = transportSummary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.succeeded = succeeded
        self.stage = stage
        self.reasonCode = reasonCode
        self.toolCount = toolCount
        self.toolNames = toolNames
        self.message = message
        self.action = action
    }

    public var redactedTransportSummary: String {
        MCPProviderProbeRedactor.safeDiagnosticFragment(transportSummary, maxLength: 500)
    }

    public var redactedMessage: String {
        MCPProviderProbeRedactor.safeDiagnosticFragment(message, maxLength: 280)
    }

    public var redactedAction: String? {
        guard let action, !action.isEmpty else { return nil }
        let redacted = MCPProviderProbeRedactor.safeDiagnosticFragment(action, maxLength: 280)
        return redacted.isEmpty ? nil : redacted
    }

    public var pasteboardText: String {
        var lines = [
            "MCP provider probe",
            "Provider: \(providerName)",
            "Transport: \(redactedTransportSummary)",
            "Status: \(succeeded ? "succeeded" : "failed")",
            "Reason: \(reasonCode.rawValue)",
            "Stage: \(stage.rawValue)",
            "Tools: \(toolCount)",
            "Message: \(redactedMessage)",
        ]
        if !toolNames.isEmpty {
            lines.append("Tool names: \(toolNames.joined(separator: ", "))")
        }
        if let action = redactedAction {
            lines.append("Action: \(action)")
        }
        return lines.joined(separator: "\n")
    }

    static func success(
        provider: MCPProvider,
        startedAt: Date,
        tools: [MCP.Tool]
    ) -> MCPProviderProbeResult {
        MCPProviderProbeResult(
            providerId: provider.id,
            providerName: provider.name,
            transportSummary: MCPProviderProbeService.transportSummary(for: provider),
            startedAt: startedAt,
            finishedAt: Date(),
            succeeded: true,
            stage: .listTools,
            reasonCode: .succeeded,
            toolCount: tools.count,
            toolNames: tools.map(\.name).sorted(),
            message: L("Probe completed initialize/listTools and found \(tools.count) tool(s)."),
            action: nil
        )
    }

    static func failure(
        provider: MCPProvider,
        startedAt: Date,
        stage: MCPProviderProbeStage,
        reasonCode: MCPProviderProbeReasonCode,
        message: String,
        action: String?
    ) -> MCPProviderProbeResult {
        MCPProviderProbeResult(
            providerId: provider.id,
            providerName: provider.name,
            transportSummary: MCPProviderProbeService.transportSummary(for: provider),
            startedAt: startedAt,
            finishedAt: Date(),
            succeeded: false,
            stage: stage,
            reasonCode: reasonCode,
            toolCount: 0,
            toolNames: [],
            message: MCPProviderProbeRedactor.safeDiagnosticFragment(message, maxLength: 280),
            action: action.map { MCPProviderProbeRedactor.safeDiagnosticFragment($0, maxLength: 280) }
        )
    }
}

private extension String {
    func mcpReplacingMatches(of pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let range = NSRange(startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: template)
    }
}

enum MCPProviderProbeRedactor {
    static func safeDiagnosticFragment(_ raw: String, maxLength: Int = 280) -> String {
        var value = raw
        let replacements: [(pattern: String, template: String)] = [
            (#"(?i)authorization\s*[:=]\s*(?:bearer\s+)?[^\s,;}]+\"?"#, "credential=***"),
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "credential=***"),
            (
                #"(?i)\"(access_token|refresh_token|code_verifier|code|verifier|client_secret|api_key|apikey|password|secret|token)\"\s*:\s*\"[^\"]*\""#,
                #""$1":"***""#
            ),
            (
                #"(?i)\b(access_token|refresh_token|code_verifier|code|verifier|client_secret|api_key|apikey|password|secret|token)=([^&\s,;}]+)"#,
                "$1=***"
            ),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "jwt=***"),
        ]
        for replacement in replacements {
            value = value.mcpReplacingMatches(of: replacement.pattern, with: replacement.template)
        }

        value = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.contains("  ") {
            value = value.replacingOccurrences(of: "  ", with: " ")
        }
        if value.count > maxLength {
            return String(value.prefix(maxLength)) + "..."
        }
        return value
    }
}

public enum MCPProviderProbeService {
    public static func probeHTTP(
        providerId: UUID,
        name: String,
        url: String,
        token: String?,
        headers: [String: String],
        streamingEnabled: Bool,
        discoveryTimeout: TimeInterval
    ) async -> MCPProviderProbeResult {
        let provider = MCPProvider(
            id: providerId,
            name: name.isEmpty ? L("HTTP MCP probe") : name,
            url: url,
            streamingEnabled: streamingEnabled,
            discoveryTimeout: discoveryTimeout,
            authType: token?.isEmpty == false ? .bearerToken : .none,
            transport: .http
        )
        let startedAt = Date()
        guard let endpoint = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return MCPProviderProbeResult.failure(
                provider: provider,
                startedAt: startedAt,
                stage: .configuration,
                reasonCode: .invalidURL,
                message: L("The MCP endpoint URL could not be parsed."),
                action: L("Edit the URL and include the scheme, host, and path.")
            )
        }

        let configuration = GlobalProxySettings.makeConfiguration(base: .default)
        var allHeaders = headers
        if let token, !token.isEmpty {
            allHeaders["Authorization"] = "Bearer \(token)"
        }
        if !allHeaders.isEmpty {
            configuration.httpAdditionalHeaders = allHeaders
        }
        configuration.timeoutIntervalForRequest = discoveryTimeout
        configuration.timeoutIntervalForResource = max(discoveryTimeout, 20)

        let transport = HTTPClientTransport(
            endpoint: endpoint,
            configuration: configuration,
            streaming: streamingEnabled
        )
        return await runProbe(provider: provider, transport: transport, startedAt: startedAt)
    }

    public static func probeStdio(provider: MCPProvider) async -> MCPProviderProbeResult {
        let startedAt = Date()
        guard !provider.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MCPProviderProbeResult.failure(
                provider: provider,
                startedAt: startedAt,
                stage: .configuration,
                reasonCode: .missingCommand,
                message: L("The stdio provider is missing a command."),
                action: L("Enter an executable path or command before testing.")
            )
        }

        do {
            let (transport, cleanup) = try await makeStdioTransport(for: provider)
            return await runProbe(
                provider: provider,
                transport: transport,
                startedAt: startedAt,
                cleanup: cleanup
            )
        } catch {
            return mapFailure(provider: provider, startedAt: startedAt, stage: .spawn, error: error)
        }
    }

    public static func transportSummary(for provider: MCPProvider) -> String {
        switch provider.transport {
        case .http:
            return provider.streamingEnabled ? "HTTP/SSE \(provider.url)" : "HTTP \(provider.url)"
        case .stdio:
            let args = ShellArgs.join(provider.args)
            let command = args.isEmpty ? provider.command : "\(provider.command) \(args)"
            return "stdio \(provider.executionHost.rawValue) \(command)"
        }
    }

    static func probeForTesting(
        provider: MCPProvider,
        transport: any MCP.Transport
    ) async -> MCPProviderProbeResult {
        await runProbe(provider: provider, transport: transport, startedAt: Date())
    }

    private static func runProbe(
        provider: MCPProvider,
        transport: any MCP.Transport,
        startedAt: Date,
        cleanup: (@Sendable () async -> Void)? = nil
    ) async -> MCPProviderProbeResult {
        let client = MCP.Client(name: "Osaurus", version: "1.0.0")
        do {
            try await withTimeout(seconds: provider.discoveryTimeout) {
                _ = try await client.connect(transport: transport)
            }
            let (tools, _) = try await withTimeout(seconds: provider.discoveryTimeout) {
                try await client.listTools()
            }
            if let cleanup {
                await cleanup()
            }
            return MCPProviderProbeResult.success(
                provider: provider,
                startedAt: startedAt,
                tools: tools
            )
        } catch {
            if let cleanup {
                await cleanup()
            }
            return mapFailure(provider: provider, startedAt: startedAt, stage: .connect, error: error)
        }
    }

    private static func makeStdioTransport(
        for provider: MCPProvider
    ) async throws -> (any MCP.Transport, @Sendable () async -> Void) {
        switch provider.executionHost {
        case .host:
            #if canImport(Darwin)
                let runner = try MCPStdioHostRunner(provider: provider)
                try await runner.start()
                return (runner.transport, { await runner.stop() })
            #else
                throw MCPStdioTransportError.sandboxUnavailable
            #endif
        case .sandbox:
            #if os(macOS)
                let availability = await SandboxManager.shared.checkAvailability()
                guard availability.isAvailable else {
                    throw MCPStdioTransportError.sandboxUnavailable
                }
                if await SandboxManager.shared.status() != .running {
                    do {
                        try await SandboxManager.shared.startContainer()
                    } catch {
                        throw MCPStdioTransportError.processSpawnFailed(
                            "Could not start the Osaurus sandbox: \(error.localizedDescription)"
                        )
                    }
                }
                let runner = try SandboxStdioRunner(provider: provider)
                try await runner.start()
                return (runner.transport, { await runner.stop() })
            #else
                throw MCPStdioTransportError.sandboxUnavailable
            #endif
        }
    }

    private static func mapFailure(
        provider: MCPProvider,
        startedAt: Date,
        stage: MCPProviderProbeStage,
        error: Error
    ) -> MCPProviderProbeResult {
        let message = error.localizedDescription

        if let mcpError = error as? MCPProviderError {
            switch mcpError {
            case .invalidURL:
                return failure(
                    provider: provider,
                    startedAt: startedAt,
                    stage: .configuration,
                    reasonCode: .invalidURL,
                    message: message,
                    action: L("Edit the endpoint URL and test again.")
                )
            case .timeout:
                return failure(
                    provider: provider,
                    startedAt: startedAt,
                    stage: stage,
                    reasonCode: .timeout,
                    message: message,
                    action: L("Increase discovery timeout or check that the MCP server responds to listTools.")
                )
            default:
                break
            }
        }

        if let stdioError = error as? MCPStdioTransportError {
            switch stdioError {
            case .missingCommand:
                return failure(
                    provider: provider,
                    startedAt: startedAt,
                    stage: .configuration,
                    reasonCode: .missingCommand,
                    message: message,
                    action: L("Enter a command before testing.")
                )
            case .commandNotFound:
                return failure(
                    provider: provider,
                    startedAt: startedAt,
                    stage: .spawn,
                    reasonCode: .commandNotFound,
                    message: message,
                    action: L("Use a full executable path such as /opt/homebrew/bin/npx.")
                )
            case .sandboxUnavailable:
                return failure(
                    provider: provider,
                    startedAt: startedAt,
                    stage: .spawn,
                    reasonCode: .sandboxUnavailable,
                    message: message,
                    action: L("Switch to Host for trusted tools or start the sandbox runtime.")
                )
            case .processSpawnFailed:
                return failure(
                    provider: provider,
                    startedAt: startedAt,
                    stage: .spawn,
                    reasonCode: .spawnFailed,
                    message: message,
                    action: L("Check the command, working directory, and environment.")
                )
            }
        }

        if let urlError = error as? URLError, urlError.code == .timedOut {
            return failure(
                provider: provider,
                startedAt: startedAt,
                stage: stage,
                reasonCode: .timeout,
                message: message,
                action: L("Increase discovery timeout or verify the server is reachable.")
            )
        }

        let looksLikeAuthFailure =
            message.localizedCaseInsensitiveContains("unauthorized")
            || message.localizedCaseInsensitiveContains("forbidden")
            || message.contains("401")
            || message.contains("403")
        if looksLikeAuthFailure {
            return failure(
                provider: provider,
                startedAt: startedAt,
                stage: stage,
                reasonCode: .authRequired,
                message: message,
                action: L("Sign in or save a token, then test again.")
            )
        }

        let looksLikeProtocolFailure =
            message.localizedCaseInsensitiveContains("json")
            || message.localizedCaseInsensitiveContains("protocol")
            || message.localizedCaseInsensitiveContains("decode")
        if looksLikeProtocolFailure {
            return failure(
                provider: provider,
                startedAt: startedAt,
                stage: stage,
                reasonCode: .protocolError,
                message: message,
                action: L("Verify the process speaks MCP JSON-RPC on stdin/stdout.")
            )
        }

        return failure(
            provider: provider,
            startedAt: startedAt,
            stage: stage,
            reasonCode: .connectionFailed,
            message: message,
            action: L("Copy the probe result and check the provider logs.")
        )
    }

    private static func failure(
        provider: MCPProvider,
        startedAt: Date,
        stage: MCPProviderProbeStage,
        reasonCode: MCPProviderProbeReasonCode,
        message: String,
        action: String?
    ) -> MCPProviderProbeResult {
        MCPProviderProbeResult.failure(
            provider: provider,
            startedAt: startedAt,
            stage: stage,
            reasonCode: reasonCode,
            message: message,
            action: action
        )
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MCPProviderError.timeout
            }
            guard let result = try await group.next() else {
                throw MCPProviderError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}
