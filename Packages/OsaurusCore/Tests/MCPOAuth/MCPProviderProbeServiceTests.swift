//
//  MCPProviderProbeServiceTests.swift
//  osaurusTests
//
//  Regression coverage for local MCP probes, health snapshots, and capture
//  capability policy gates.
//

import Foundation
import Logging
import MCP
import Testing

@testable import OsaurusCore

@Suite("MCP local provider probes", .serialized)
struct MCPProviderProbeServiceTests {
    @Test func stdioProbeCompletesFakeServerTransportAndPersistsHealthSnapshot() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotFile = root.appendingPathComponent("mcp-health.json")
        MCPProviderHealthSnapshotStore.overrideURL = snapshotFile
        defer { MCPProviderHealthSnapshotStore.overrideURL = nil }

        let provider = MCPProvider(
            id: UUID(),
            name: "Fake local MCP",
            url: "",
            discoveryTimeout: 5,
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "fake-mcp"
        )

        let result = await MCPProviderProbeService.probeForTesting(
            provider: provider,
            transport: FakeMCPTransport()
        )
        MCPProviderHealthSnapshotStore.record(result, for: provider)

        #expect(result.succeeded)
        #expect(result.reasonCode == .succeeded)
        #expect(result.toolCount == 1)
        #expect(result.toolNames == ["fake_echo"])
        #expect(result.pasteboardText.contains("Reason: succeeded"))

        let snapshot = MCPProviderHealthSnapshotStore.snapshot(providerId: provider.id)
        #expect(snapshot?.lastProbe.reasonCode == .succeeded)
        #expect(snapshot?.lastProbe.toolNames == ["fake_echo"])
        #expect(FileManager.default.fileExists(atPath: snapshotFile.path))
    }

    @Test func stdioProbeMapsMissingCommandToStableReasonCode() async {
        let provider = MCPProvider(
            id: UUID(),
            name: "Broken local MCP",
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: ""
        )

        let result = await MCPProviderProbeService.probeStdio(provider: provider)

        #expect(!result.succeeded)
        #expect(result.reasonCode == .missingCommand)
        #expect(result.stage == .configuration)
        #expect(result.action?.contains("command") == true)
    }

    @Test func capturePolicyRequiresExplicitOptInAndPermission() {
        let defaultDecision = MCPCaptureCapabilityPolicy.defaultScreenshotDecision
        #expect(!defaultDecision.allowed)
        #expect(defaultDecision.denialReason == .pluginNotInstalled)

        let optedInButNoPermission = MCPCaptureCapabilityPolicy.evaluate(
            MCPCapturePolicyRequest(
                capability: .screenshot,
                pluginInstalled: true,
                pluginEnabled: true,
                userOptedIn: true,
                permissionGranted: false,
                interactiveRequest: true
            )
        )
        #expect(!optedInButNoPermission.allowed)
        #expect(optedInButNoPermission.denialReason == .missingPermissionGrant)
    }

    @Test func capturePolicyRejectsBackgroundCaptureEvenWhenPluginIsAllowed() {
        let decision = MCPCaptureCapabilityPolicy.evaluate(
            MCPCapturePolicyRequest(
                capability: .screenshot,
                pluginInstalled: true,
                pluginEnabled: true,
                userOptedIn: true,
                permissionGranted: true,
                interactiveRequest: false
            )
        )

        #expect(!decision.allowed)
        #expect(decision.denialReason == .backgroundCaptureDenied)
    }

    @Test func probePasteboardTextRedactsCredentialFragments() {
        let provider = MCPProvider(
            id: UUID(),
            name: "Secretive MCP",
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "node",
            args: ["server.js", "--token=secret-token"]
        )
        let result = MCPProviderProbeResult.failure(
            provider: provider,
            startedAt: Date(),
            stage: .connect,
            reasonCode: .authRequired,
            message:
                #"HTTP 401 {"access_token":"secret-token","client_secret":"secret-code"} Authorization: Bearer raw-token"#,
            action: "Retry after rotating password=hunter2."
        )

        #expect(!result.pasteboardText.contains("secret-token"))
        #expect(!result.pasteboardText.contains("secret-code"))
        #expect(!result.pasteboardText.contains("raw-token"))
        #expect(!result.pasteboardText.contains("hunter2"))
        #expect(result.pasteboardText.contains("client_secret"))
        #expect(result.pasteboardText.contains("***"))

        let legacyRawResult = MCPProviderProbeResult(
            providerId: provider.id,
            providerName: provider.name,
            transportSummary: "stdio host node server.js --client_secret=legacy-secret",
            startedAt: Date(),
            finishedAt: Date(),
            succeeded: false,
            stage: .connect,
            reasonCode: .authRequired,
            toolCount: 0,
            toolNames: [],
            message: "legacy access_token=legacy-token",
            action: "legacy password=legacy-password"
        )

        #expect(!legacyRawResult.pasteboardText.contains("legacy-secret"))
        #expect(!legacyRawResult.pasteboardText.contains("legacy-token"))
        #expect(!legacyRawResult.pasteboardText.contains("legacy-password"))
    }

    @Test func diagnosticsAppendHealthAndCaptureRows() {
        let provider = MCPProvider(
            id: UUID(),
            name: "Local MCP",
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "/bin/sh"
        )
        let probe = MCPProviderProbeResult.failure(
            provider: provider,
            startedAt: Date(),
            stage: .spawn,
            reasonCode: .commandNotFound,
            message: "`npx` was not found on this app's PATH.",
            action: "Use a full executable path."
        )
        let snapshot = MCPProviderHealthSnapshot(
            providerId: provider.id,
            providerName: provider.name,
            transportSummary: probe.transportSummary,
            lastProbe: probe
        )
        let base = ProviderNetworkDiagnostics.mcpProviderReport(
            provider: provider,
            state: nil,
            proxy: .disabled,
            bearerTokenPresent: false,
            oauthTokensPresent: false
        )

        let augmented = MCPLocalProviderDiagnostics.augment(
            report: base,
            provider: provider,
            healthSnapshot: snapshot
        )

        #expect(row("local-health", in: augmented).value == "commandNotFound")
        #expect(row("capture-policy", in: augmented).value == "pluginNotInstalled")
        #expect(augmented.pasteboardText.contains("commandNotFound"))
        #expect(!augmented.pasteboardText.contains("secret-token"))
    }

    private func row(_ id: String, in report: ProviderDiagnosticReport) -> ProviderDiagnosticRow {
        guard let found = report.rows.first(where: { $0.id == id }) else {
            Issue.record("Missing diagnostics row \(id)")
            return ProviderDiagnosticRow(id: id, title: "missing", value: "missing", severity: .blocked)
        }
        return found
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-mcp-probe-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor FakeMCPTransport: MCP.Transport {
    nonisolated let logger = Logger(
        label: "osaurus.tests.fake-mcp-transport",
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
