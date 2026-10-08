//
//  MCPRobustnessTests.swift
//  OsaurusCoreTests
//
//  Plain-language connector errors, auth-on-call detection, connect
//  coalescing, progress-extended deadlines, and elicitation.
//

import Foundation
import MCP
import Testing

@testable import OsaurusCore

@Suite("MCP robustness")
struct MCPRobustnessTests {

    // MARK: Error presenter

    @Test func protocolDumpIsRewrittenWithDetails() {
        let raw = "[-32603] Internal error: Client disconnected"
        let p = MCPProviderErrorPresenter.present(raw, providerName: "Clio")
        #expect(p.message.contains("Clio"))
        #expect(!p.message.contains("-32603"))
        #expect(p.details == raw)
    }

    @Test func expiredSignInAsksToSignInAgain() {
        let p = MCPProviderErrorPresenter.present("invalid_token: token expired", providerName: "Xero")
        #expect(p.message.contains("sign in"))
        #expect(p.details != nil)
    }

    @Test func networkFailureSuggestsCheckingConnection() {
        let p = MCPProviderErrorPresenter.present(
            "The Internet connection appears to be offline.", providerName: "Box")
        #expect(p.message.contains("internet connection"))
    }

    @Test func serverErrorStatusIsRecognizedButJSONRPCInternalErrorIsNot() {
        let http = MCPProviderErrorPresenter.present("HTTP 503 Service Unavailable", providerName: "S")
        #expect(http.message.contains("having problems"))
        let rpc = MCPProviderErrorPresenter.present("[-32603] Internal error: boom", providerName: "S")
        #expect(!rpc.message.contains("having problems"))
    }

    @Test func readableMessagesPassThroughUnchanged() {
        let raw = "Sign in again to grant the extra access this tool needs."
        let p = MCPProviderErrorPresenter.present(raw, providerName: "Notion")
        #expect(p.message == raw)
        #expect(p.details == nil)
    }

    // MARK: Auth required on tool call

    @Test func authRequiredErrorIsRecognized() {
        #expect(MCPProviderManager.isAuthRequiredError(MCPError.internalError("Authentication required")))
        #expect(!MCPProviderManager.isAuthRequiredError(MCPError.internalError("Access forbidden")))
        #expect(!MCPProviderManager.isAuthRequiredError(MCPError.connectionClosed))
    }

    @Test func authRequiredToolMessageNamesTheRightAction() {
        let oauth = MCPProviderManager.authRequiredToolMessage(providerName: "Descrybe", authType: .none)
        #expect(oauth.contains("sign in to Descrybe"))
        #expect(oauth.contains("call the tool again"))
        let bearer = MCPProviderManager.authRequiredToolMessage(providerName: "GitHub", authType: .bearerToken)
        #expect(bearer.contains("API token"))
    }

    @Test func commandNotFoundIsLeftForTheEditButton() {
        let raw = MCPStdioTransportError.commandNotFound(command: "uvx", searchedPath: nil).localizedDescription
        let p = MCPProviderErrorPresenter.present(raw, providerName: "Local")
        #expect(p.message == raw)
        #expect(p.details == nil)
    }
}

/// Real `MCPProviderManager` connects over the SDK's in-memory transport.
/// Serialized: the manager is a process-wide singleton.
@Suite("MCP provider connect coalescing", .serialized)
@MainActor
struct MCPConnectCoalescingTests {
    private func install(_ name: String) -> MCPProvider {
        let provider = MCPProvider(
            name: name, url: "https://\(name).example.invalid/mcp", autoConnect: false, authType: .none)
        MCPProviderManager.shared._testInstallProviders([provider])
        return provider
    }

    private func cleanup(_ provider: MCPProvider) {
        let manager = MCPProviderManager.shared
        manager.disconnect(providerId: provider.id)
        manager.testTransportFactory = nil
        manager._testRemoveProviders(ids: [provider.id])
    }

    /// Each connect gets a fresh in-memory server whose `tools/list` takes
    /// `delay`, so overlapping connects really overlap.
    private func installFactory(delay: Duration, counter: TransportCounter) {
        MCPProviderManager.shared.testTransportFactory = { _ in
            await counter.increment()
            let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
            let server = Server(name: "fake", version: "1", capabilities: .init(tools: .init()))
            await server.withMethodHandler(ListTools.self) { _ in
                try await Task.sleep(for: delay)
                return .init(tools: [
                    Tool(name: "lookup", description: "Look up", inputSchema: .object(["type": .string("object")]))
                ])
            }
            try await server.start(transport: serverTransport)
            await counter.retain(server)
            return clientTransport
        }
    }

    @Test func overlappingConnectsShareOneAttempt() async throws {
        let provider = install("coalesce-overlap")
        defer { cleanup(provider) }
        let counter = TransportCounter()
        installFactory(delay: .milliseconds(300), counter: counter)

        let manager = MCPProviderManager.shared
        async let first: Void = manager.connect(providerId: provider.id)
        async let second: Void = manager.connect(providerId: provider.id)
        async let third: Void = manager.connect(providerId: provider.id)
        _ = try await (first, second, third)

        #expect(await counter.count == 1)
        let state = try #require(manager.providerStates[provider.id])
        #expect(state.isConnected)
        #expect(state.discoveredToolCount == 1)
        #expect(state.lastError == nil)
    }

    @Test func disconnectSupersedesAnInFlightAttempt() async throws {
        let provider = install("coalesce-supersede")
        defer { cleanup(provider) }
        let counter = TransportCounter()
        installFactory(delay: .milliseconds(400), counter: counter)

        let manager = MCPProviderManager.shared
        let stale = Task { try await manager.connect(providerId: provider.id) }
        try await Task.sleep(for: .milliseconds(100))
        manager.disconnect(providerId: provider.id)
        try await manager.connect(providerId: provider.id)

        await #expect(throws: CancellationError.self) { try await stale.value }
        // Give the superseded attempt time to finish discovery; it must not
        // tear down or replace the fresh connection.
        try await Task.sleep(for: .milliseconds(500))
        let state = try #require(manager.providerStates[provider.id])
        #expect(state.isConnected)
        #expect(state.discoveredToolCount == 1)
        #expect(await counter.count == 2)
    }
}

private actor TransportCounter {
    var count = 0
    private var servers: [Server] = []
    func increment() { count += 1 }
    func retain(_ server: Server) { servers.append(server) }
}

@Suite("MCP tool-call progress")
struct MCPToolProgressTests {
    @Test func displayTextCombinesMessageAndPercent() {
        let token = ProgressToken.string("t")
        #expect(
            MCPToolProgressRegistry.displayText(
                .init(progressToken: token, progress: 3, total: 4, message: "Searching case law")
            ) == "Searching case law · 75%")
        #expect(MCPToolProgressRegistry.displayText(.init(progressToken: token, progress: 1)) == nil)
        let long = String(repeating: "a", count: 200)
        let text = try? #require(
            MCPToolProgressRegistry.displayText(.init(progressToken: token, progress: 1, message: long)))
        #expect(text?.count == 80)
    }

    @Test func activityKeepsASlowCallAlive() async throws {
        let clock = MCPActivityClock()
        let work = Task<String, Error> {
            for _ in 0 ..< 6 {
                try await Task.sleep(for: .milliseconds(150))
                clock.touch()
            }
            return "done"
        }
        let value = try await valueWithActivityDeadline(
            idleTimeout: 0.4, hardCap: 5, clock: clock, operationName: "slow", work: work)
        #expect(value == "done")
    }

    @Test func silenceStillTimesOut() async {
        let work = Task<String, Error> {
            try await Task.sleep(for: .seconds(5))
            return "late"
        }
        await #expect(throws: DeadlineExceededError.self) {
            try await valueWithActivityDeadline(
                idleTimeout: 0.3, hardCap: 5, clock: MCPActivityClock(), operationName: "quiet", work: work)
        }
    }

    @Test func hardCapBoundsEndlessProgress() async {
        let clock = MCPActivityClock()
        let work = Task<String, Error> {
            while true {
                try await Task.sleep(for: .milliseconds(100))
                clock.touch()
            }
        }
        let start = Date()
        await #expect(throws: DeadlineExceededError.self) {
            try await valueWithActivityDeadline(
                idleTimeout: 0.3, hardCap: 0.8, clock: clock, operationName: "chatty", work: work)
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    /// End to end over the real SDK: the server reads the progressToken from
    /// `_meta`, reports progress past the idle timeout, and the call completes
    /// while the tool card's registry sees the message.
    @Test func serverProgressExtendsTheIdleTimeout() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "slow", version: "1", capabilities: .init(tools: .init()))
        let seen = ProgressSeen()
        await server.withMethodHandler(CallTool.self) { [weak server] params in
            guard let token = params._meta?.progressToken else {
                return .init(content: [.text(text: "no token", annotations: nil, _meta: nil)], isError: true)
            }
            for step in 1 ... 4 {
                try await Task.sleep(for: .milliseconds(200))
                try await server?.notify(
                    ProgressNotification.message(
                        .init(progressToken: token, progress: Double(step), total: 4, message: "Step \(step)")))
            }
            // Same process: read what the tool card would show before the
            // call completes and clears it.
            for _ in 0 ..< 20 {
                if let text = MCPToolProgressRegistry.shared.message(for: "call-progress") {
                    await seen.record(text)
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            return .init(content: [.text(text: "finished", annotations: nil, _meta: nil)])
        }
        try await server.start(transport: serverTransport)
        defer { Task { await server.stop() } }

        let client = Client(name: "osaurus-test", version: "1")
        await MCPProviderManager.routeProgressNotifications(from: client)
        _ = try await client.connect(transport: clientTransport)

        let result = try await ChatExecutionContext.$currentToolCallId.withValue("call-progress") {
            try await MCPProviderManager.callMCPTool(
                client: client, toolName: "research", arguments: [:], timeout: 0.5)
        }
        #expect(result.isError != true)
        #expect(MCPToolProgressRegistry.shared.message(for: "call-progress") == nil)
        let messages = await seen.messages
        #expect(messages.count == 1 && messages.allSatisfy { $0.hasPrefix("Step ") }, "\(messages)")
        await client.disconnect()
    }
}

private actor ProgressSeen {
    var messages: [String] = []
    func record(_ text: String) { messages.append(text) }
}
