import Foundation
import Testing

@testable import OsaurusCore

@Suite("Support diagnostics bundle", .serialized)
struct SupportDiagnosticsBundleTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let app = SupportDiagnosticsBundle.AppSnapshot(
        name: "OsaurusTests",
        version: "1.2.3",
        build: "456",
        osVersion: "macOS test"
    )

    @Test func redactsSensitiveRequestAndToolPayloads() throws {
        let sessionId = "session-raw-value-do-not-export"
        let accessKeyId = "access-key-raw-value-do-not-export"
        let secretToken = "live-secret-token-do-not-export"
        let bearerToken = "sk-test-secret-token-do-not-export"
        let basicToken = "dXNlcjpwYXNzLWRvLW5vdC1leHBvcnQ="
        let privatePrompt = "please search the private account history"
        let privateResponse = "private diagnosis response"
        let wirePrompt = "wire prompt payload"
        let wireResponse = "wire response payload"
        let pluginMessage = "plugin log private project path"
        let toolQueryValue = "private account lookup"
        let argumentKeySecret = "alice@example.com"
        let agentAddress = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let providerId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let toolCallId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let requestId = "router-request-secret-do-not-export"
        let log = RequestLog(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            timestamp: Self.now,
            source: .chatUI,
            turnId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            requestId: requestId,
            method: "POST",
            path: "/agents/\(agentAddress)/run?token=\(secretToken)",
            statusCode: 500,
            durationMs: 250,
            requestBody: #"{"prompt":"\#(privatePrompt)","api_key":"\#(secretToken)"}"#,
            responseBody: privateResponse,
            userAgent: "Osaurus Authorization: Basic \(basicToken)",
            pluginId: "search-plugin",
            model: "provider/model",
            inputTokens: 12,
            outputTokens: 3,
            temperature: 0.3,
            maxTokens: 256,
            toolCalls: [
                ToolCallLog(
                    id: toolCallId,
                    name: "web_search",
                    arguments: #"{"query":"\#(toolQueryValue)","\#(argumentKeySecret)":true}"#,
                    result: "result with \(secretToken)",
                    durationMs: 10,
                    isError: true
                )
            ],
            finishReason: .error,
            errorMessage: "provider rejected bearer \(bearerToken) token=\(secretToken)",
            wireRequestBody: wirePrompt,
            wireResponseBody: wireResponse,
            connection: RequestConnectionInfo(
                providerId: providerId,
                remoteEndpoint: "https://user:\(secretToken)@provider.example/run?api_key=\(secretToken)",
                transport: .direct,
                mode: .remoteInference,
                accessKeyId: accessKeyId,
                audience: "agent-support"
            )
        )
        let pluginLog = RequestLog(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            timestamp: Self.now.addingTimeInterval(-1),
            source: .plugin,
            method: "INFO",
            path: "[info] \(pluginMessage)",
            statusCode: 200,
            durationMs: 1,
            pluginId: "diagnostics-plugin"
        )
        let state = SessionToolState(
            loadedToolNames: ["web_search"],
            initialAlwaysLoadedNames: ["capabilities_load"],
            sessionFingerprint: "sandbox/auto"
        )

        let bundle = SupportDiagnosticsBundleBuilder.make(
            generatedAt: Self.now,
            app: Self.app,
            sessionId: sessionId,
            agentId: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            agentAddress: agentAddress,
            agentName: #"Support Agent {"api_key":"\#(secretToken)"}"#,
            modelId: "provider/model",
            providerId: "provider token=\(secretToken)",
            registeredTools: [
                SupportDiagnosticsToolInput(name: "capabilities_load", enabled: true),
                SupportDiagnosticsToolInput(name: "web_search", enabled: true, groupName: "search"),
            ],
            dynamicToolNames: ["web_search"],
            sessionState: state,
            logs: [pluginLog, log]
        )

        let payload = try encodedPayload(bundle)

        #expect(!payload.contains(secretToken))
        #expect(!payload.contains(bearerToken))
        #expect(!payload.contains(basicToken))
        #expect(!payload.contains(privatePrompt))
        #expect(!payload.contains(privateResponse))
        #expect(!payload.contains(wirePrompt))
        #expect(!payload.contains(wireResponse))
        #expect(!payload.contains(pluginMessage))
        #expect(!payload.contains(toolQueryValue))
        #expect(!payload.contains(argumentKeySecret))
        #expect(!payload.contains(sessionId))
        #expect(!payload.contains(accessKeyId))
        #expect(!payload.contains(requestId))
        #expect(!payload.contains(agentAddress))
        #expect(payload.contains(SupportDiagnosticsBundleBuilder.redactedValue))
        #expect(bundle.context.sessionIdFingerprint?.hasPrefix("sha256:") == true)
        #expect(bundle.context.agentIdFingerprint?.hasPrefix("sha256:") == true)
        #expect(bundle.context.agentAddressFingerprint?.hasPrefix("sha256:") == true)
        #expect(bundle.context.providerIdFingerprint?.hasPrefix("sha256:") == true)
        #expect(bundle.recentRequests[0].idFingerprint.hasPrefix("sha256:"))
        #expect(bundle.recentRequests[0].turnIdFingerprint?.hasPrefix("sha256:") == true)
        #expect(bundle.recentRequests[0].requestIdFingerprint?.hasPrefix("sha256:") == true)
        #expect(bundle.recentRequests[0].path == "/agents/0x[REDACTED]/run")
        #expect(bundle.recentRequests[0].errorMessageCaptured)
        #expect(bundle.recentRequests[0].bodyPresence.localRequestCaptured)
        #expect(bundle.recentRequests[0].bodyPresence.localResponseCaptured)
        #expect(bundle.recentRequests[0].bodyPresence.wireRequestCaptured)
        #expect(bundle.recentRequests[0].bodyPresence.wireResponseCaptured)
        #expect(bundle.recentRequests[0].toolCalls[0].argumentKeyCount == 2)
        #expect(bundle.recentRequests[0].toolCalls[0].idFingerprint.hasPrefix("sha256:"))
        #expect(bundle.recentRequests[0].toolCalls[0].resultCaptured)
        #expect(bundle.recentRequests[0].connection?.accessKeyIdFingerprint?.hasPrefix("sha256:") == true)
        #expect(bundle.recentRequests[0].connection?.providerIdFingerprint?.hasPrefix("sha256:") == true)
        #expect(bundle.recentRequests[0].connection?.audienceFingerprint?.hasPrefix("sha256:") == true)
        #expect(bundle.recentRequests[1].path == "[plugin path omitted]")
    }

    @Test func summarizesToolsAndRecentRequestsDeterministically() throws {
        let firstLog = RequestLog(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            timestamp: Self.now,
            source: .httpAPI,
            method: "POST",
            path: "/chat/completions",
            statusCode: 200,
            durationMs: 100,
            model: "model-a",
            outputTokens: 20
        )
        let secondLog = RequestLog(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            timestamp: Self.now.addingTimeInterval(-60),
            source: .plugin,
            method: "LOG",
            path: "/plugin/log",
            statusCode: 200,
            durationMs: 1
        )
        let state = SessionToolState(
            loadedToolNames: ["z_tool", "a_tool", "a_tool"],
            initialAlwaysLoadedNames: ["capabilities_load", "todo_write"]
        )

        let bundle = SupportDiagnosticsBundleBuilder.make(
            generatedAt: Self.now,
            app: Self.app,
            registeredTools: [
                SupportDiagnosticsToolInput(name: "z_tool", enabled: false, groupName: "plugin-z"),
                SupportDiagnosticsToolInput(name: "a_tool", enabled: true, groupName: "plugin-a"),
                SupportDiagnosticsToolInput(name: "capabilities_load", enabled: true),
            ],
            dynamicToolNames: ["z_tool", "a_tool", "a_tool"],
            sessionState: state,
            logs: [firstLog, secondLog],
            recentLogLimit: 1
        )

        #expect(bundle.schemaVersion == SupportDiagnosticsBundle.schemaVersion)
        #expect(bundle.recentRequests.count == 1)
        #expect(bundle.recentRequests[0].idFingerprint.hasPrefix("sha256:"))
        #expect(bundle.recentRequests[0].model == "model-a")
        #expect(bundle.tools.registered.map(\.name) == ["a_tool", "capabilities_load", "z_tool"])
        #expect(bundle.tools.enabledNames == ["a_tool", "capabilities_load"])
        #expect(bundle.tools.dynamicNames == ["a_tool", "z_tool"])
        #expect(bundle.tools.loadedNames == ["a_tool", "z_tool"])
        #expect(bundle.tools.initialAlwaysLoadedNames == ["capabilities_load", "todo_write"])
        #expect(bundle.recentRequests[0].tokensPerSecond == 200)
    }

    private func encodedPayload(_ bundle: SupportDiagnosticsBundle) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(bundle)
        return String(decoding: data, as: UTF8.self)
    }
}
