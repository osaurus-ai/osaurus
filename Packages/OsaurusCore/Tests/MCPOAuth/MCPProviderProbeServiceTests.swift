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
            command: "/Users/alice/private/fake-mcp",
            args: ["--workspace", "/Users/alice/customer-data"]
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
        #expect(!result.transportSummary.contains("/Users/alice"))
        let persisted = try String(contentsOf: snapshotFile, encoding: .utf8)
        #expect(!persisted.contains("/Users/alice"))
        #expect(!persisted.contains("customer-data"))
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

    @Test func healthSnapshotStoreSerializesConcurrentProviderWrites() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        MCPProviderHealthSnapshotStore.overrideURL = root.appendingPathComponent("mcp-health.json")
        defer { MCPProviderHealthSnapshotStore.overrideURL = nil }

        let providers = (0..<24).map { index in
            MCPProvider(id: UUID(), name: "Provider \(index)", url: "https://example.com/mcp")
        }
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask {
                    let result = MCPProviderProbeResult(
                        providerId: provider.id,
                        providerName: provider.name,
                        transportSummary: "HTTP https://example.com/redacted-path",
                        startedAt: Date(timeIntervalSince1970: 1),
                        finishedAt: Date(timeIntervalSince1970: 2),
                        succeeded: true,
                        stage: .listTools,
                        reasonCode: .succeeded,
                        toolCount: 1,
                        toolNames: ["fixture"],
                        message: "Connected",
                        action: nil
                    )
                    MCPProviderHealthSnapshotStore.record(result, for: provider)
                }
            }
        }

        let snapshots = MCPProviderHealthSnapshotStore.load()
        #expect(snapshots.count == providers.count)
        #expect(Set(snapshots.keys) == Set(providers.map(\.id)))
    }

    #if os(macOS)
    @Test func hostStdioProbeRejectsProcessControlEnvironmentWithoutLeakingValue() async {
        let provider = MCPProvider(
            id: UUID(),
            name: "Unsafe environment fixture",
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "/bin/sh",
            env: ["DYLD_INSERT_LIBRARIES": "secret-canary"]
        )

        let result = await MCPProviderProbeService.probeStdio(provider: provider)

        #expect(!result.succeeded)
        #expect(result.reasonCode == .unsafeEnvironment)
        #expect(result.stage == .configuration)
        #expect(result.action?.contains("Sandbox") == true)
        #expect(!result.message.contains("secret-canary"))
        #expect(!result.pasteboardText.contains("secret-canary"))
    }
    #endif

    @Test func failedStdioProbeDoesNotCopyOrPersistConfiguredPath() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotFile = root.appendingPathComponent("mcp-health.json")
        MCPProviderHealthSnapshotStore.overrideURL = snapshotFile
        defer { MCPProviderHealthSnapshotStore.overrideURL = nil }
        let privatePath = "/Users/alice/customer-work/missing-mcp"
        let provider = MCPProvider(
            name: "Missing fixture",
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: privatePath
        )

        let result = await MCPProviderProbeService.probeStdio(provider: provider)
        MCPProviderHealthSnapshotStore.record(result, for: provider)
        let persisted = try String(contentsOf: snapshotFile, encoding: .utf8)

        #expect(result.reasonCode == .spawnFailed)
        #expect(!result.pasteboardText.contains(privatePath))
        #expect(!result.message.contains(privatePath))
        #expect(!persisted.contains(privatePath))
        #expect(!persisted.contains("customer-work"))
    }

    #if os(macOS)
    @Test func hostStdioProbeReportsEarlyProcessExitWithoutWaitingForTimeout() async {
        let provider = MCPProvider(
            name: "Early exit fixture",
            url: "",
            discoveryTimeout: 5,
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "/bin/sh",
            args: ["-c", "exit 42"]
        )
        let clock = ContinuousClock()
        let started = clock.now

        let result = await MCPProviderProbeService.probeStdio(provider: provider)

        #expect(!result.succeeded)
        #expect(result.reasonCode == .processExited)
        #expect(result.stage == .connect)
        #expect(result.message.contains("42"))
        #expect(!result.pasteboardText.contains("exit 42"))
        #expect(started.duration(to: clock.now) < .seconds(1))
    }

    @Test func hostStdioProbeUsesDraftSecretAndDiscoversFixtureTool() async {
        let provider = MCPProvider(
            name: "Host fixture",
            url: "",
            discoveryTimeout: 5,
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "/bin/sh",
            args: ["-c", Self.hostFixtureScript],
            secretEnvKeys: ["MCP_TEST_TOKEN"]
        )

        let result = await MCPProviderProbeService.probeStdio(
            provider: provider,
            secretEnvOverrides: ["MCP_TEST_TOKEN": "draft-secret"]
        )

        #expect(result.succeeded)
        #expect(result.reasonCode == .succeeded)
        #expect(result.toolNames == ["fixture_echo"])
        #expect(!result.transportSummary.contains("/bin/sh"))
        #expect(!result.transportSummary.contains(Self.hostFixtureScript))
        #expect(!result.pasteboardText.contains("draft-secret"))
    }

    @Test func hostStdioFixtureExecutesToolAndTerminatesCleanly() async throws {
        let provider = MCPProvider(
            name: "Host fixture",
            url: "",
            discoveryTimeout: 5,
            authType: .none,
            transport: .stdio,
            executionHost: .host,
            command: "/bin/sh",
            args: ["-c", Self.hostFixtureScript],
            secretEnvKeys: ["MCP_TEST_TOKEN"]
        )
        let runner = try MCPStdioHostRunner(
            provider: provider,
            secretEnvOverrides: ["MCP_TEST_TOKEN": "draft-secret"]
        )
        try await runner.start()
        let client = MCP.Client(name: "Osaurus fixture test", version: "1.0")

        do {
            _ = try await MCPAsyncTimeout.run(seconds: 5) {
                try await client.connect(transport: runner.transport)
            }
            let result = try await MCPAsyncTimeout.run(seconds: 5) {
                try await client.callTool(name: "fixture_echo", arguments: [:])
            }
            #expect(result.isError != true)
            #expect(result.content == [.text(text: "fixture-ok", annotations: nil, _meta: nil)])
            await client.disconnect()
            await runner.stop()
        } catch {
            await client.disconnect()
            await runner.stop()
            throw error
        }
    }
    #endif

    @Test func timeoutReturnsWithoutWaitingForCancellationIgnoringOperation() async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await MCPAsyncTimeout.run(seconds: 0.05) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        continuation.resume(returning: "late")
                    }
                }
            }
            Issue.record("Expected timeout")
        } catch MCPProviderError.timeout {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(started.duration(to: clock.now) < .milliseconds(500))
    }

    @Test func externalFailureSignalEndsOperationBeforeTimeout() async {
        let signal = MCPAsyncFailureSignal()
        let clock = ContinuousClock()
        let started = clock.now
        Task {
            try? await Task.sleep(for: .milliseconds(25))
            signal.fail(MCPProviderError.providerDisabled)
        }

        do {
            _ = try await MCPAsyncTimeout.run(seconds: 5, failureSignal: signal) {
                try await Task.sleep(for: .seconds(5))
                return "late"
            }
            Issue.record("Expected process failure")
        } catch MCPProviderError.providerDisabled {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(started.duration(to: clock.now) < .milliseconds(500))
    }

    @Test func failureSignalLatchedBeforeObservationIsNotLost() async {
        let signal = MCPAsyncFailureSignal()
        signal.fail(MCPProviderError.providerDisabled)

        do {
            _ = try await MCPAsyncTimeout.run(seconds: 5, failureSignal: signal) {
                "unexpected"
            }
            Issue.record("Expected the latched failure")
        } catch MCPProviderError.providerDisabled {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
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

    private static let hostFixtureScript = #"""
    [ "$MCP_TEST_TOKEN" = "draft-secret" ] || exit 42
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
      case "$line" in
        *notifications/initialized*)
          ;;
        *initialize*)
          printf '{"jsonrpc":"2.0","id":"%s","result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1.0"}}}\n' "$id"
          ;;
        *tools*list*)
          printf '{"jsonrpc":"2.0","id":"%s","result":{"tools":[{"name":"fixture_echo","description":"Fixture echo","inputSchema":{"type":"object","properties":{}}}]}}\n' "$id"
          ;;
        *tools*call*)
          printf '{"jsonrpc":"2.0","id":"%s","result":{"content":[{"type":"text","text":"fixture-ok"}],"isError":false}}\n' "$id"
          ;;
      esac
    done
    """#

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
