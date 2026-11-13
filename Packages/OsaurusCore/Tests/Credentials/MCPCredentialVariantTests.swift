// Copyright © 2026 osaurus.

import Foundation
import MCP
import Testing

@testable import OsaurusCore

/// An agent with its own, different value for a key an MCP server reads
/// calls through its own client; everyone else shares one client. Each test runs on its
/// own Keys store; the manager only applies a store's changes to clients
/// built from it.
@Suite("MCP per-agent credential clients", .serialized)
@MainActor
struct MCPCredentialVariantTests {
    private func install() -> (MCPProvider, String) {
        let name = "VariantTest\(UUID().uuidString.prefix(6))"
        let provider = MCPProvider(
            name: name, url: "https://\(name.lowercased()).example.invalid/mcp", autoConnect: false,
            secretHeaderKeys: ["X-Api-Key"], authType: .none)
        MCPProviderManager.shared._testInstallProviders([provider])
        let key = MCPCredentials.headerSlot(provider, header: "X-Api-Key").effectiveKey()
        return (provider, key)
    }

    private func cleanup(_ provider: MCPProvider, key: String, agents: [UUID]) {
        let manager = MCPProviderManager.shared
        manager.evictVariants { $0.providerId == provider.id }
        manager.disconnect(providerId: provider.id)
        manager.testTransportFactories[provider.id] = nil
        manager._testRemoveProviders(ids: [provider.id])
        CredentialStore.current.delete(key, scope: .global)
        for agent in agents { CredentialStore.current.deleteAll(agentId: agent) }
    }

    private func installFactory(_ log: ConnectLog, for provider: MCPProvider) {
        MCPProviderManager.shared.testTransportFactories[provider.id] = { provider in
            let header = provider.resolvedHeaders()["X-Api-Key"]
            await log.record(agentId: provider.credentialAgentId, header: header)
            let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
            let server = Server(name: "fake", version: "1", capabilities: .init(tools: .init()))
            await server.withMethodHandler(ListTools.self) { _ in
                .init(tools: [Tool(name: "whoami", description: "Echo", inputSchema: .object(["type": .string("object")]))])
            }
            await server.withMethodHandler(CallTool.self) { _ in
                .init(content: [.text(header ?? "none")])
            }
            try await server.start(transport: serverTransport)
            await log.retain(server)
            return clientTransport
        }
    }

    private func call(_ provider: MCPProvider, as agent: UUID) async throws -> String {
        try await ChatExecutionContext.$currentAgentId.withValue(agent) {
            try await MCPProviderManager.shared.executeTool(
                providerId: provider.id, toolName: "whoami", argumentsJSON: "{}")
        }
    }

    private func overrideGetsItsOwnClientAndOthersShareBody() async throws {
        let (provider, key) = install()
        let shared = UUID()
        let overriding = UUID()
        defer { cleanup(provider, key: key, agents: [shared, overriding]) }
        let log = ConnectLog()
        installFactory(log, for: provider)
        let store = CredentialStore.current
        store.save(key, scope: .global, value: "global-value", origin: .mcp)
        store.save(key, scope: .agent(overriding), value: "agent-value", origin: .user)

        let manager = MCPProviderManager.shared
        try await manager.connect(providerId: provider.id)

        #expect(try await call(provider, as: shared).contains("global-value"))
        #expect(manager._testVariantKeys().isEmpty)

        #expect(try await call(provider, as: overriding).contains("agent-value"))
        #expect(manager._testVariantKeys() == [.init(providerId: provider.id, agentId: overriding)])

        // A second call reuses the agent's client.
        let connectsBefore = await log.count
        _ = try await call(provider, as: overriding)
        #expect(await log.count == connectsBefore)
        #expect(await log.agents.contains(overriding))
    }

    private func changedOverrideEvictsTheAgentClientBody() async throws {
        let (provider, key) = install()
        let agent = UUID()
        defer { cleanup(provider, key: key, agents: [agent]) }
        let log = ConnectLog()
        installFactory(log, for: provider)
        let store = CredentialStore.current
        store.save(key, scope: .global, value: "global-value", origin: .mcp)
        store.save(key, scope: .agent(agent), value: "first", origin: .user)
        let manager = MCPProviderManager.shared
        try await manager.connect(providerId: provider.id)

        #expect(try await call(provider, as: agent).contains("first"))
        store.save(key, scope: .agent(agent), value: "second", origin: .user)
        await manager.handleCredentialsChanged(keys: [key])
        #expect(manager._testVariantKeys().isEmpty)

        #expect(try await call(provider, as: agent).contains("second"))

        // Removing the override sends the agent back to the shared client.
        store.delete(key, scope: .agent(agent))
        await manager.handleCredentialsChanged(keys: [key])
        #expect(try await call(provider, as: agent).contains("global-value"))
        #expect(manager._testVariantKeys().isEmpty)
    }

    private func idleAgentClientsAreClosedBody() async throws {
        let (provider, key) = install()
        let agent = UUID()
        defer { cleanup(provider, key: key, agents: [agent]) }
        installFactory(ConnectLog(), for: provider)
        CredentialStore.current.save(key, scope: .agent(agent), value: "v", origin: .user)
        let manager = MCPProviderManager.shared
        try await manager.connect(providerId: provider.id)

        _ = try await call(provider, as: agent)
        #expect(!manager._testVariantKeys().isEmpty)
        manager.sweepIdleVariants(now: Date().addingTimeInterval(manager.variantIdleTimeout + 1))
        #expect(manager._testVariantKeys().isEmpty)
    }

    private func sameValueOverrideUsesTheSharedClientBody() async throws {
        let (provider, key) = install()
        let agent = UUID()
        defer { cleanup(provider, key: key, agents: [agent]) }
        let log = ConnectLog()
        installFactory(log, for: provider)
        let store = CredentialStore.current
        store.save(key, scope: .global, value: "same", origin: .mcp)
        store.save(key, scope: .agent(agent), value: "same", origin: .user)
        let manager = MCPProviderManager.shared
        try await manager.connect(providerId: provider.id)
        let connectsBefore = await log.count

        #expect(try await call(provider, as: agent).contains("same"))
        #expect(manager._testVariantKeys().isEmpty)
        #expect(await log.count == connectsBefore)
    }

    private func variantsAreCappedPerProviderBody() async throws {
        let (provider, key) = install()
        let agents = (0..<3).map { _ in UUID() }
        let manager = MCPProviderManager.shared
        let cap = manager.maxVariantsPerProvider
        manager.maxVariantsPerProvider = 2
        defer {
            manager.maxVariantsPerProvider = cap
            cleanup(provider, key: key, agents: agents)
        }
        installFactory(ConnectLog(), for: provider)
        let store = CredentialStore.current
        store.save(key, scope: .global, value: "global-value", origin: .mcp)
        for (index, agent) in agents.enumerated() {
            store.save(key, scope: .agent(agent), value: "agent-\(index)", origin: .user)
        }
        try await manager.connect(providerId: provider.id)

        _ = try await call(provider, as: agents[0])
        _ = try await call(provider, as: agents[1])
        _ = try await call(provider, as: agents[0])
        _ = try await call(provider, as: agents[2])

        #expect(
            manager._testVariantKeys() == [
                .init(providerId: provider.id, agentId: agents[0]),
                .init(providerId: provider.id, agentId: agents[2]),
            ])
    }

    @Test func sameValueOverrideUsesTheSharedClient() async throws {
        try await CredentialStore.$taskLocalStore.withValue(CredentialStore.makeIsolated()) {
            try await sameValueOverrideUsesTheSharedClientBody()
        }
    }

    @Test func variantsAreCappedPerProvider() async throws {
        try await CredentialStore.$taskLocalStore.withValue(CredentialStore.makeIsolated()) {
            try await variantsAreCappedPerProviderBody()
        }
    }

    @Test func overrideGetsItsOwnClientAndOthersShare() async throws {
        try await CredentialStore.$taskLocalStore.withValue(CredentialStore.makeIsolated()) {
            try await overrideGetsItsOwnClientAndOthersShareBody()
        }
    }

    @Test func changedOverrideEvictsTheAgentClient() async throws {
        try await CredentialStore.$taskLocalStore.withValue(CredentialStore.makeIsolated()) {
            try await changedOverrideEvictsTheAgentClientBody()
        }
    }

    @Test func idleAgentClientsAreClosed() async throws {
        try await CredentialStore.$taskLocalStore.withValue(CredentialStore.makeIsolated()) {
            try await idleAgentClientsAreClosedBody()
        }
    }
}

private actor ConnectLog {
    private(set) var count = 0
    private(set) var agents: [UUID] = []
    private var servers: [Server] = []

    func record(agentId: UUID?, header: String?) {
        count += 1
        if let agentId { agents.append(agentId) }
    }

    func retain(_ server: Server) { servers.append(server) }
}
