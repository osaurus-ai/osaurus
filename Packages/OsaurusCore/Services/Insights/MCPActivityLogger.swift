//
//  MCPActivityLogger.swift
//  osaurus
//
//  Activity-log rows for MCP tool calls. A remote (HTTP) server receives the
//  tool arguments, so those rows are cloud egress; a stdio subprocess runs
//  on this Mac and is logged as local so the reviewer still sees the call.
//

import Foundation

enum MCPActivityLogger {

    /// One in-flight call. Create before the network hop (captures
    /// attribution on the caller's task), then `finish` exactly once.
    struct Call {
        let provider: MCPProvider
        let toolName: String
        let exposedToolName: String?
        let argumentsJSON: String
        let attribution: InsightsService.ActivityAttribution
        let started = Date()

        func finish(_ result: Result<String, Error>) {
            let durationMs = Date().timeIntervalSince(started) * 1000
            let recordedArgs = SecretArgumentScrubber.recordedArguments(
                toolName: exposedToolName ?? toolName,
                argumentsJSON: argumentsJSON
            )
            var resultPreview: String?
            var errorMessage: String?
            var bytesReceived: Int?
            switch result {
            case .success(let text):
                resultPreview = String(text.prefix(2_000))
                bytesReceived = text.utf8.count
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
            InsightsService.logEgress(
                category: .mcpToolCall,
                method: "CALL",
                path: "/mcp/\(provider.name)/\(toolName)",
                statusCode: errorMessage == nil ? 200 : 502,
                durationMs: durationMs,
                egress: MCPActivityLogger.egress(
                    provider: provider,
                    toolName: toolName,
                    exposedToolName: exposedToolName,
                    recordedArguments: recordedArgs,
                    resultPreview: resultPreview,
                    bytesReceived: bytesReceived
                ),
                locality: MCPActivityLogger.locality(for: provider),
                errorMessage: errorMessage,
                toolCalls: [
                    ToolCallLog(
                        name: exposedToolName ?? toolName,
                        arguments: recordedArgs,
                        result: resultPreview ?? errorMessage,
                        isError: errorMessage != nil
                    )
                ],
                attribution: attribution
            )
        }
    }

    static func locality(for provider: MCPProvider) -> DataLocality {
        switch provider.transport {
        case .http: return .remote
        case .stdio: return .local
        }
    }

    static func egress(
        provider: MCPProvider,
        toolName: String,
        exposedToolName: String?,
        recordedArguments: String,
        resultPreview: String?,
        bytesReceived: Int?
    ) -> EgressInfo {
        var details: [String: String] = [
            "server": provider.name,
            "tool": toolName,
            "transport": provider.transport.rawValue,
            "arguments": recordedArguments,
        ]
        if let exposedToolName, exposedToolName != toolName { details["exposed_as"] = exposedToolName }
        if let resultPreview { details["result_preview"] = resultPreview }
        switch provider.transport {
        case .http:
            let host = EgressInfo.host(from: provider.url)
            return EgressInfo(
                destinationLabel: provider.name,
                destinationHost: host,
                bytesSent: recordedArguments.utf8.count,
                bytesReceived: bytesReceived,
                dataClasses: ["tool_arguments"],
                details: details
            )
        case .stdio:
            details["execution_host"] = provider.executionHost.rawValue
            if !provider.command.isEmpty { details["command"] = provider.command }
            return EgressInfo(
                destinationLabel: provider.name,
                destinationHost: nil,
                bytesSent: recordedArguments.utf8.count,
                bytesReceived: bytesReceived,
                dataClasses: ["tool_arguments"],
                details: details
            )
        }
    }
}
