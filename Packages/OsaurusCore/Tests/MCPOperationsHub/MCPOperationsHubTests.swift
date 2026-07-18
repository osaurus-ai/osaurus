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
    @Test func operationsDisplayNeverExposesEndpointOrLocalPaths() {
        let endpoint = MCPOperationsDisplaySanitizer.endpoint(
            "https://user:password@example.test/private/mcp?token=secret-canary#fragment"
        )
        #expect(endpoint == "https://example.test/redacted-path")
        #expect(!endpoint.contains("secret-canary"))
        #expect(!endpoint.contains("password"))

        let executable = MCPOperationsDisplaySanitizer.resolvedExecutable(
            "/Users/alice/private/bin/customer-mcp"
        )
        let workingDirectory = MCPOperationsDisplaySanitizer.workingDirectory(
            "/Users/alice/customer-data"
        )
        let warning = MCPOperationsDisplaySanitizer.warning(
            "Working directory does not exist: /Users/alice/customer-data"
        )
        #expect(executable == "Resolved")
        #expect(workingDirectory == "Configured")
        #expect(!warning.contains("/Users/alice"))
        #expect(!warning.contains("customer-data"))
    }

    @Test func declaredSecretAuthorizationHeaderRequiresStoredValueForHealthyAuth() {
        let provider = MCPProvider(
            id: UUID(),
            name: "Remote",
            url: "https://example.test/mcp",
            secretHeaderKeys: ["Authorization"],
            authType: .none,
            transport: .http
        )

        let missing = MCPProviderOperationsHub.authStatus(
            provider: provider,
            state: nil,
            credentialPresence: MCPProviderCredentialPresence()
        )
        let present = MCPProviderOperationsHub.authStatus(
            provider: provider,
            state: nil,
            credentialPresence: MCPProviderCredentialPresence(authorizationHeaderPresent: true)
        )

        #expect(missing.kind == .none)
        #expect(missing.severity == .info)
        #expect(present.kind == .headerCredentialPresent)
        #expect(present.severity == .ok)
    }

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
        #expect(!plan.pasteboardText.contains("/custom/bin"))
        #expect(!plan.pasteboardText.contains("/Projects"))
        #expect(!plan.pasteboardText.contains("server-filesystem"))
        #expect(!plan.pasteboardText.contains("npx"))
        #expect(plan.pasteboardText.contains("PATH entries searched: 10"))
    }

    @Test func duplicateHeaderAndEnvRowsNormalizeWithoutTrap() {
        let normalized = MCPProviderOperationsFieldNormalizer.normalize([
            (key: "Authorization", value: "plain-old", isSecret: false),
            (key: "API_TOKEN", value: "first", isSecret: true),
            (key: " Authorization ", value: "secret-new", isSecret: true),
            (key: "API_TOKEN", value: "plain-new", isSecret: false),
            (key: "EMPTY", value: "ignored", isSecret: false),
            (key: "EMPTY", value: "", isSecret: true),
            (key: "BLANK", value: "", isSecret: false),
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
        #expect(!plan.detail.contains("not-installed"))
        #expect(plan.resolvedExecutablePath == nil)
        #expect(plan.searchPath?.contains("/empty/bin") == true)
    }

    @Test func hostLaunchPlanDetailDoesNotExposeCommandPathCanaries() {
        for command in [
            "raw-command-canary",
            "/private/customer-work/absolute-command-canary",
            "~/customer-work/tilde-command-canary",
        ] {
            let provider = MCPProvider(
                id: UUID(),
                name: "Missing",
                url: "",
                authType: .none,
                transport: .stdio,
                executionHost: .host,
                command: command
            )

            let plan = MCPProviderOperationsHub.launchPlan(
                for: provider,
                processEnvironment: ["PATH": "/empty/bin"],
                secretEnvValues: [:],
                isExecutable: { _ in false },
                directoryExists: { _ in true }
            )

            #expect(!plan.detail.contains(command))
            #expect(!plan.detail.contains("customer-work"))
            #expect(!plan.detail.contains("command-canary"))
        }
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
        #expect(pasteboard.contains("https://mcp.example.com/redacted-path"))
        #expect(!pasteboard.contains("/mcp/private"))
        #expect(!pasteboard.contains("user:pass"))
        #expect(!pasteboard.contains("workspace=secret"))
        #expect(!pasteboard.contains("token=raw"))
        #expect(!pasteboard.contains("#fragment"))
    }

    @Test func diagnosticRedactorHidesPrefixedKeysAndOpaqueTokenFormats() {
        let diagnostic = MCPProviderProbeRedactor.safeDiagnosticFragment(
            "OPENAI_API_KEY=sk-1234567890 GH_TOKEN=ghp_1234567890 slack=xoxb-1234567890"
        )

        #expect(!diagnostic.contains("sk-1234567890"))
        #expect(!diagnostic.contains("ghp_1234567890"))
        #expect(!diagnostic.contains("xoxb-1234567890"))
        #expect(diagnostic.contains("OPENAI_API_KEY=***"))
        #expect(diagnostic.contains("GH_TOKEN=***"))
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

    @Test func transportScopingDropsInactiveConfigurationAndSecretReferences() {
        let id = UUID()
        let mixed = MCPProvider(
            id: id,
            name: "Mixed",
            url: "https://private.example/mcp",
            customHeaders: ["X-Visible": "value"],
            streamingEnabled: true,
            secretHeaderKeys: ["Authorization"],
            authType: .bearerToken,
            transport: .stdio,
            command: "/private/bin/server",
            args: ["--serve"],
            env: ["VISIBLE": "value"],
            secretEnvKeys: ["API_TOKEN"],
            workingDirectory: "/private/work"
        )

        let stdio = mixed.scopedToActiveTransport()
        #expect(stdio.url.isEmpty)
        #expect(stdio.customHeaders.isEmpty)
        #expect(stdio.secretHeaderKeys.isEmpty)
        #expect(stdio.authType == .none)
        #expect(!stdio.streamingEnabled)
        #expect(stdio.command == "/private/bin/server")
        #expect(stdio.secretEnvKeys == ["API_TOKEN"])

        var httpInput = mixed
        httpInput.transport = .http
        let http = httpInput.scopedToActiveTransport()
        #expect(http.command.isEmpty)
        #expect(http.args.isEmpty)
        #expect(http.env.isEmpty)
        #expect(http.secretEnvKeys.isEmpty)
        #expect(http.workingDirectory == nil)
        #expect(http.secretHeaderKeys == ["Authorization"])
    }

    @Test func bearerTokenEditReplacesOrClearsOnlyByExplicitIntent() {
        var saved: [String] = []
        var deleteCount = 0

        let explicitClear = MCPProviderBearerTokenEdit.fromBearerField(
            "",
            authType: .bearerToken,
            clearRequested: true
        )
        let clearAfterAuthSwitch = MCPProviderBearerTokenEdit.fromBearerField(
            "",
            authType: .none,
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
        clearAfterAuthSwitch.apply(
            save: { _ in false },
            delete: {
                deleteCount += 1
                return true
            }
        )

        #expect(explicitClear == .clear)
        #expect(clearAfterAuthSwitch == .clear)
        #expect(saved == ["new-token"])
        #expect(deleteCount == 2)
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

@Suite("MCP provider secret persistence")
struct MCPProviderSecretPersistenceTests {
    @Test func failedWriteRollsBackEarlierMutationsWithoutExposingValues() {
        let providerId = UUID()
        let writes = [
            MCPProviderSecretWrite(storage: .header, key: "Authorization", value: "header-secret"),
            MCPProviderSecretWrite(storage: .environment, key: "API_TOKEN", value: "env-secret"),
        ]
        var headerValues = ["Authorization": "old-header"]
        var environmentValues: [String: String] = [:]
        var events: [String] = []

        let succeeded = MCPProviderSecretPersistence.persist(
            writes,
            for: providerId,
            readHeader: { key, _ in headerValues[key] },
            readEnvironment: { key, _ in environmentValues[key] },
            writeHeader: { value, key, id in
                events.append("set-header:\(key):\(id)")
                headerValues[key] = value
                return true
            },
            writeEnvironment: { _, key, id in
                events.append("set-environment:\(key):\(id)")
                return false
            },
            deleteHeader: { key, id in
                events.append("delete-header:\(key):\(id)")
                headerValues.removeValue(forKey: key)
                return true
            },
            deleteEnvironment: { key, id in
                events.append("delete-environment:\(key):\(id)")
                environmentValues.removeValue(forKey: key)
                return true
            }
        )

        #expect(!succeeded)
        #expect(headerValues == ["Authorization": "old-header"])
        #expect(environmentValues.isEmpty)
        #expect(events == [
            "set-header:Authorization:\(providerId)",
            "set-environment:API_TOKEN:\(providerId)",
            "delete-environment:API_TOKEN:\(providerId)",
            "set-header:Authorization:\(providerId)",
        ])
        #expect(!events.joined().contains("header-secret"))
        #expect(!events.joined().contains("env-secret"))
    }

    @Test func emptyWriteSetSucceedsWithoutCallingStorage() {
        let succeeded = MCPProviderSecretPersistence.persist(
            [],
            for: UUID(),
            readHeader: { _, _ in Issue.record("unexpected header read"); return nil },
            readEnvironment: { _, _ in Issue.record("unexpected environment read"); return nil },
            writeHeader: { _, _, _ in Issue.record("unexpected header write"); return false },
            writeEnvironment: { _, _, _ in Issue.record("unexpected environment write"); return false },
            deleteHeader: { _, _ in Issue.record("unexpected header delete"); return false },
            deleteEnvironment: { _, _ in Issue.record("unexpected environment delete"); return false }
        )

        #expect(succeeded)
    }

    @Test func credentialTransactionRestoresBearerTokenWhenSecretPersistenceFails() {
        let providerId = UUID()
        var storedToken: String? = "old-token"
        var events: [String] = []

        let succeeded = MCPProviderCredentialPersistence.persist(
            providerId: providerId,
            tokenEdit: .replace("new-token"),
            secretWrites: [MCPProviderSecretWrite(storage: .header, key: "Authorization", value: "secret")],
            readToken: { _ in storedToken },
            saveToken: { token, _ in
                events.append(token == "new-token" ? "replace" : "restore")
                storedToken = token
                return true
            },
            deleteToken: { _ in
                events.append("delete")
                storedToken = nil
                return true
            },
            persistSecrets: { _, _ in false }
        )

        #expect(!succeeded)
        #expect(storedToken == "old-token")
        #expect(events == ["replace", "restore"])
    }

    @Test func bearerClearIntentChangesProbeAndFingerprintWithoutUsingStoredSecret() {
        let stored = "stored-secret"
        let preserved = MCPProviderBearerProbeInput.resolved(
            fieldValue: "",
            clearRequested: false,
            storedValue: stored
        )
        let cleared = MCPProviderBearerProbeInput.resolved(
            fieldValue: "",
            clearRequested: true,
            storedValue: stored
        )
        let preservedFingerprint = MCPProviderBearerProbeInput.fingerprint(
            fieldValue: "",
            clearRequested: false
        )
        let clearedFingerprint = MCPProviderBearerProbeInput.fingerprint(
            fieldValue: "",
            clearRequested: true
        )

        #expect(preserved == stored)
        #expect(cleared == nil)
        #expect(preservedFingerprint != clearedFingerprint)
        #expect(!clearedFingerprint.contains(stored))
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
