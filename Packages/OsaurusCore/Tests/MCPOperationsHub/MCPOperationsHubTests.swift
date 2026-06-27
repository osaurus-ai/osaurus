//
//  MCPOperationsHubTests.swift
//  OsaurusCoreTests
//

import Foundation
import Logging
import MCP
import Testing

@testable import OsaurusCore

@Suite("MCP Operations Hub", .serialized)
struct MCPOperationsHubTests {
    @Test func hostLaunchPlanResolvesExecutableAndRedactsCommandSecrets() {
        let provider = MCPProvider(
            id: UUID(),
            name: "Filesystem",
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "npx",
            args: ["--token=secret-token", "@modelcontextprotocol/server-filesystem"],
            env: ["VISIBLE": "value"],
            secretEnvKeys: ["API_TOKEN", "MISSING_TOKEN"],
            workingDirectory: "~/Projects"
        )

        let plan = MCPProviderOperationsHub.launchPlan(
            for: provider,
            processEnvironment: ["PATH": "/custom/bin"],
            secretEnvValues: ["API_TOKEN": "secret-value"],
            isExecutable: { $0 == "/custom/bin/npx" },
            directoryExists: { $0.hasSuffix("/Projects") }
        )

        #expect(plan.status == .warning)
        #expect(plan.resolvedExecutablePath == "/custom/bin/npx")
        #expect(plan.searchPath?.contains("/custom/bin") == true)
        #expect(plan.workingDirectory?.hasSuffix("/Projects") == true)
        #expect(plan.configuredEnvironmentKeys == ["API_TOKEN", "MISSING_TOKEN", "VISIBLE"])
        #expect(plan.secretEnvironmentKeys == ["API_TOKEN", "MISSING_TOKEN"])
        #expect(plan.missingSecretEnvironmentKeys == ["MISSING_TOKEN"])
        #expect(plan.redactedCommandLine?.contains("secret-token") == false)
        #expect(plan.pasteboardText.contains("secret-value") == false)
    }

    @Test func duplicateHeaderAndEnvRowsNormalizeWithoutTrap() {
        let normalized = MCPProviderOperationsFieldNormalizer.normalize([
            (key: "Authorization", value: "plain-old", isSecret: false),
            (key: "API_TOKEN", value: "first", isSecret: true),
            (key: " Authorization ", value: "secret-new", isSecret: true),
            (key: "API_TOKEN", value: "plain-new", isSecret: false),
            (key: "EMPTY", value: "ignored", isSecret: false),
            (key: "EMPTY", value: "", isSecret: true),
        ])

        #expect(normalized.regular == ["API_TOKEN": "plain-new"])
        #expect(normalized.secretKeys == ["Authorization", "EMPTY"])
    }

    @Test func launchPlanDeduplicatesSecretEnvironmentKeysBeforeKeychainChecks() {
        let provider = MCPProvider(
            id: UUID(),
            name: "Duplicate Env",
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "npx",
            env: ["VISIBLE": "value"],
            secretEnvKeys: ["API_TOKEN", " API_TOKEN ", "MISSING_TOKEN", "MISSING_TOKEN"]
        )

        let plan = MCPProviderOperationsHub.launchPlan(
            for: provider,
            processEnvironment: ["PATH": "/custom/bin"],
            secretEnvValues: ["API_TOKEN": "secret-value"],
            isExecutable: { $0 == "/custom/bin/npx" },
            directoryExists: { _ in true }
        )

        #expect(plan.status == .warning)
        #expect(plan.configuredEnvironmentKeys == ["API_TOKEN", "MISSING_TOKEN", "VISIBLE"])
        #expect(plan.secretEnvironmentKeys == ["API_TOKEN", "MISSING_TOKEN"])
        #expect(plan.missingSecretEnvironmentKeys == ["MISSING_TOKEN"])
    }

    @Test func hostLaunchPlanBlocksWhenCommandIsNotOnPath() {
        let provider = MCPProvider(
            id: UUID(),
            name: "Missing",
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "not-installed"
        )

        let plan = MCPProviderOperationsHub.launchPlan(
            for: provider,
            processEnvironment: ["PATH": "/empty/bin"],
            secretEnvValues: [:],
            isExecutable: { _ in false },
            directoryExists: { _ in true }
        )

        #expect(plan.status == .blocked)
        #expect(plan.title.contains("not found"))
        #expect(plan.resolvedExecutablePath == nil)
        #expect(plan.searchPath?.contains("/empty/bin") == true)
    }

    @Test func callHistoryStoreBoundsAndRedactsRecords() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let historyFile = root.appendingPathComponent("mcp-call-history.json")
        MCPProviderCallHistoryStore.overrideURL = historyFile
        defer { MCPProviderCallHistoryStore.overrideURL = nil }

        let providerId = UUID()
        for index in 0..<55 {
            let record = MCPProviderCallRecord(
                providerId: providerId,
                providerName: "Secret MCP",
                toolName: "lookup_\(index)",
                startedAt: Date(timeIntervalSince1970: Double(index)),
                finishedAt: Date(timeIntervalSince1970: Double(index) + 0.25),
                succeeded: index.isMultiple(of: 2),
                argumentSummary: MCPProviderCallRecord.summarizeArguments(
                    #"{"password":"hunter2","query":"status"}"#
                ),
                resultSummary: MCPProviderCallRecord.summarizeResult(
                    #"{"access_token":"secret-token","customer":"bare-private-value"}"#
                ),
                errorMessage: "Authorization: Bearer raw-token"
            )
            MCPProviderCallHistoryStore.record(record)
        }

        let records = MCPProviderCallHistoryStore.recentCalls(providerId: providerId, limit: 100)
        #expect(records.count == MCPProviderCallHistoryStore.maxRecordsPerProvider)
        #expect(records.first?.toolName == "lookup_54")
        #expect(records.last?.toolName == "lookup_5")
        #expect(FileManager.default.fileExists(atPath: historyFile.path))

        let pasteboard = records.first?.pasteboardText ?? ""
        #expect(pasteboard.contains("password"))
        #expect(!pasteboard.contains("hunter2"))
        #expect(!pasteboard.contains("secret-token"))
        #expect(!pasteboard.contains("bare-private-value"))
        #expect(!pasteboard.contains("raw-token"))
    }

    @Test func callHistoryStoreSerializesConcurrentRecordWrites() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let historyFile = root.appendingPathComponent("mcp-call-history.json")
        MCPProviderCallHistoryStore.overrideURL = historyFile
        defer { MCPProviderCallHistoryStore.overrideURL = nil }

        let providerId = UUID()
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            MCPProviderCallHistoryStore.record(
                MCPProviderCallRecord(
                    providerId: providerId,
                    providerName: "Concurrent MCP",
                    toolName: "lookup_\(index)",
                    startedAt: Date(timeIntervalSince1970: Double(index)),
                    finishedAt: Date(timeIntervalSince1970: Double(index) + 0.1),
                    succeeded: true,
                    argumentSummary: #"{"index":\#(index)}"#
                )
            )
        }

        let records = MCPProviderCallHistoryStore.recentCalls(providerId: providerId, limit: 100)
        #expect(records.count == 20)
        #expect(Set(records.map(\.toolName)).count == 20)
    }

    @Test @MainActor func managerExecuteToolRecordsCallHistoryFromProductionPath() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let historyFile = root.appendingPathComponent("mcp-call-history.json")
        MCPProviderCallHistoryStore.overrideURL = historyFile
        defer { MCPProviderCallHistoryStore.overrideURL = nil }

        let provider = MCPProvider(
            id: UUID(),
            name: "History MCP",
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "fake-mcp",
            args: []
        )
        let client = MCP.Client(name: "OsaurusTests", version: "1.0.0")
        _ = try await client.connect(transport: ToolCallHistoryMCPTransport())

        let manager = MCPProviderManager(configuration: MCPProviderConfiguration(providers: [provider]))
        manager.installConnectedClientForTesting(client, provider: provider)

        let result = try await manager.executeTool(
            providerId: provider.id,
            toolName: "fake_echo",
            argumentsJSON: #"{"password":"hunter2","query":"status"}"#
        )

        #expect(result.contains("Echo: status"))

        let records = MCPProviderCallHistoryStore.recentCalls(providerId: provider.id)
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.providerName == "History MCP")
        #expect(record.toolName == "fake_echo")
        #expect(record.succeeded)
        #expect(record.argumentSummary.contains("password"))
        #expect(record.argumentSummary.contains("query"))
        #expect(record.resultSummary?.contains("character") == true)

        let pasteboard = record.pasteboardText
        #expect(!pasteboard.contains("hunter2"))
        #expect(!pasteboard.contains("server-secret"))
    }

    @Test @MainActor func managerExecuteToolRecordsErrorCallHistoryOnce() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let historyFile = root.appendingPathComponent("mcp-call-history.json")
        MCPProviderCallHistoryStore.overrideURL = historyFile
        defer { MCPProviderCallHistoryStore.overrideURL = nil }

        let provider = MCPProvider(
            id: UUID(),
            name: "Error MCP",
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "fake-mcp",
            args: []
        )
        let client = MCP.Client(name: "OsaurusTests", version: "1.0.0")
        _ = try await client.connect(transport: ToolCallHistoryMCPTransport())

        let manager = MCPProviderManager(configuration: MCPProviderConfiguration(providers: [provider]))
        manager.installConnectedClientForTesting(client, provider: provider)

        do {
            _ = try await manager.executeTool(
                providerId: provider.id,
                toolName: "fake_error",
                argumentsJSON: #"{"password":"hunter2","query":"status"}"#
            )
            Issue.record("Expected fake_error to throw")
        } catch MCPProviderError.toolExecutionFailed(let message) {
            #expect(message.contains("Denied"))
        }

        let records = MCPProviderCallHistoryStore.recentCalls(providerId: provider.id)
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.providerName == "Error MCP")
        #expect(record.toolName == "fake_error")
        #expect(!record.succeeded)
        #expect(record.errorMessage?.contains("Denied") == true)

        let pasteboard = record.pasteboardText
        #expect(!pasteboard.contains("hunter2"))
        #expect(!pasteboard.contains("server-secret"))
    }

    @Test func operationsSnapshotCombinesAuthLaunchHealthAndHistory() {
        let provider = MCPProvider(
            id: UUID(),
            name: "Linear",
            url: "https://mcp.linear.app/mcp",
            authType: .oauth,
            transport: .http
        )
        var state = MCPProviderState(providerId: provider.id)
        state.requiresAuth = true
        state.lastError = #"401 {"access_token":"leaked-token"}"#

        let history = MCPProviderCallRecord(
            providerId: provider.id,
            providerName: provider.name,
            toolName: "linear_search",
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            succeeded: false,
            argumentSummary: MCPProviderCallRecord.summarizeArguments(#"{"query":"issue"}"#),
            errorMessage: "client_secret=secret-code"
        )

        let snapshot = MCPProviderOperationsHub.snapshot(
            providers: [provider],
            states: [provider.id: state],
            proxy: .disabled,
            credentialsByProvider: [:],
            healthSnapshots: [:],
            callHistoryByProvider: [provider.id: [history]]
        )

        let report = snapshot.reports[0]
        #expect(report.status == .needsAttention)
        #expect(report.authStatus.kind == .oauthRequired)
        #expect(report.launchPlan.status == .ready)
        #expect(report.callHistory.map(\.toolName) == ["linear_search"])
        #expect(snapshot.pasteboardText.contains("linear_search"))
        #expect(!snapshot.pasteboardText.contains("leaked-token"))
        #expect(!snapshot.pasteboardText.contains("secret-code"))
    }

    @Test func operationsDiagnosticsRedactHTTPURLUserinfoQueryAndFragment() {
        let provider = MCPProvider(
            id: UUID(),
            name: "Sensitive HTTP",
            url: "https://user:pass@mcp.example.com/mcp?workspace=secret&token=raw#fragment",
            authType: .bearerToken,
            transport: .http
        )
        let probe = MCPProviderProbeResult(
            providerId: provider.id,
            providerName: provider.name,
            transportSummary: "HTTP https://user:pass@mcp.example.com/mcp?workspace=secret&token=raw#fragment",
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            succeeded: true,
            stage: .listTools,
            reasonCode: .succeeded,
            toolCount: 1,
            toolNames: ["lookup"],
            message: "Reached https://user:pass@mcp.example.com/mcp?workspace=secret&token=raw#fragment",
            action: nil
        )
        let health = MCPProviderHealthSnapshot(
            providerId: provider.id,
            providerName: provider.name,
            transportSummary: "HTTP https://user:pass@mcp.example.com/mcp?workspace=secret&token=raw#fragment",
            lastProbe: probe
        )

        let snapshot = MCPProviderOperationsHub.snapshot(
            providers: [provider],
            states: [:],
            proxy: .disabled,
            credentialsByProvider: [:],
            healthSnapshots: [provider.id: health],
            callHistoryByProvider: [:]
        )

        let pasteboard = snapshot.pasteboardText
        #expect(pasteboard.contains("https://mcp.example.com/mcp"))
        #expect(!pasteboard.contains("user:pass"))
        #expect(!pasteboard.contains("workspace=secret"))
        #expect(!pasteboard.contains("token=raw"))
        #expect(!pasteboard.contains("#fragment"))
    }

    @Test func blankBearerTokenFieldPreservesExistingSecret() {
        var saved: [String] = []
        var deleteCount = 0

        let edit = MCPProviderBearerTokenEdit.fromBearerField("   ", authType: .bearerToken)
        edit.apply(
            save: {
                saved.append($0)
                return true
            },
            delete: {
                deleteCount += 1
                return true
            }
        )

        #expect(edit == .preserve)
        #expect(saved.isEmpty)
        #expect(deleteCount == 0)
    }

    @Test func bearerTokenEditReplacesOrClearsOnlyByExplicitIntent() {
        var saved: [String] = []
        var deleteCount = 0

        let explicitClear = MCPProviderBearerTokenEdit.fromBearerField(
            "",
            authType: .bearerToken,
            clearRequested: true
        )
        MCPProviderBearerTokenEdit.replace("new-token").apply(
            save: {
                saved.append($0)
                return true
            },
            delete: {
                deleteCount += 1
                return true
            }
        )
        MCPProviderBearerTokenEdit.replace("").apply(
            save: {
                saved.append($0)
                return true
            },
            delete: {
                deleteCount += 1
                return true
            }
        )
        explicitClear.apply(
            save: {
                saved.append($0)
                return true
            },
            delete: {
                deleteCount += 1
                return true
            }
        )

        #expect(explicitClear == .clear)
        #expect(saved == ["new-token"])
        #expect(deleteCount == 1)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-mcp-ops-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor ToolCallHistoryMCPTransport: MCP.Transport {
    nonisolated let logger = Logger(
        label: "osaurus.tests.mcp-call-history-transport",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )

    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init() {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws {}

    func disconnect() async {
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let object else { return }
        guard let method = object["method"] as? String else { return }
        let id = object["id"] ?? 0

        switch method {
        case "initialize":
            continuation.yield(
                responseData(
                    id: id,
                    result: [
                        "protocolVersion": "2025-11-25",
                        "capabilities": ["tools": [:]],
                        "serverInfo": ["name": "fake", "version": "1.0.0"],
                    ]
                )
            )
        case "tools/list":
            continuation.yield(
                responseData(
                    id: id,
                    result: [
                        "tools": [
                            [
                                "name": "fake_echo",
                                "description": "Echo fixture",
                                "inputSchema": ["type": "object", "properties": [:]],
                            ]
                        ]
                    ]
                )
            )
        case "tools/call":
            let params = object["params"] as? [String: Any]
            let name = params?["name"] as? String ?? "unknown"
            let args = params?["arguments"] as? [String: Any]
            let query = args?["query"] as? String ?? "missing"
            if name == "fake_error" {
                continuation.yield(
                    responseData(
                        id: id,
                        result: [
                            "content": [
                                [
                                    "type": "text",
                                    "text": "Denied access_token=server-secret",
                                ]
                            ],
                            "isError": true,
                        ]
                    )
                )
                return
            }
            continuation.yield(
                responseData(
                    id: id,
                    result: [
                        "content": [
                            [
                                "type": "text",
                                "text": "Echo: \(query) access_token=server-secret",
                            ]
                        ],
                        "isError": false,
                    ]
                )
            )
        default:
            break
        }
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    private func responseData(id: Any, result: [String: Any]) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        return try! JSONSerialization.data(withJSONObject: response)
    }
}
