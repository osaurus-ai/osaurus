import Foundation
import MCP
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct MCPProviderCatalogLifecycleTests {
    @MainActor
    private final class FetchBarrier {
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var resultWaiter: CheckedContinuation<[MCP.Tool], Never>?

        func fetch() async -> [MCP.Tool] {
            await withCheckedContinuation { continuation in
                resultWaiter = continuation
                entered = true
                enteredWaiter?.resume()
                enteredWaiter = nil
            }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        func resolve(_ tools: [MCP.Tool]) {
            resultWaiter?.resume(returning: tools)
            resultWaiter = nil
        }
    }

    private func withCatalogFixture(_ body: @MainActor @Sendable () async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            try await DynamicCatalogTestLock.shared.run {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let previous = ToolConfigurationStore.overrideDirectory
                ToolConfigurationStore.overrideDirectory = directory
                defer {
                    ToolConfigurationStore.flushPendingWrites()
                    ToolConfigurationStore.overrideDirectory = previous
                    try? FileManager.default.removeItem(at: directory)
                }
                try await body()
            }
        }
    }

    private func provider() -> MCPProvider {
        MCPProvider(
            name: "lifecycle_\(UUID().uuidString.prefix(8))",
            url: "https://example.invalid/mcp",
            enabled: true,
            autoConnect: false
        )
    }

    private func tool(_ name: String) -> MCP.Tool {
        MCP.Tool(name: name, description: "Lifecycle fixture", inputSchema: ["type": "object"])
    }

    @Test
    func disconnectDuringRefreshCannotResurrectCatalog() async throws {
        try await withCatalogFixture {
            let manager = MCPProviderManager.shared
            let provider = provider()
            let original = manager.replaceDiscoveredTools([tool("entry")], for: provider.id, provider: provider)
            let name = original[0].name
            defer { manager.disconnect(providerId: provider.id) }
            let barrier = FetchBarrier()
            let pending = Task { @MainActor in
                try await manager.refreshDiscoveredTools(for: provider.id, provider: provider) {
                    await barrier.fetch()
                }
            }
            await barrier.waitUntilEntered()
            manager.disconnect(providerId: provider.id)
            barrier.resolve([tool("entry")])
            try await pending.value
            #expect(!ToolRegistry.shared.isRegistered(name))
        }
    }

    @Test
    func olderCompletionCannotReplaceNewerRefresh() async throws {
        try await withCatalogFixture {
            let manager = MCPProviderManager.shared
            let provider = provider()
            defer { manager.disconnect(providerId: provider.id) }
            let barrier = FetchBarrier()
            let pending = Task { @MainActor in
                try await manager.refreshDiscoveredTools(for: provider.id, provider: provider) {
                    await barrier.fetch()
                }
            }
            await barrier.waitUntilEntered()
            let before = Set(ToolRegistry.shared.registeredToolNames())
            try await manager.refreshDiscoveredTools(for: provider.id, provider: provider) {
                [tool("fresh")]
            }
            let fresh = Set(ToolRegistry.shared.registeredToolNames()).subtracting(before)
            #expect(fresh.count == 1)
            barrier.resolve([tool("stale")])
            try await pending.value
            #expect(fresh.allSatisfy { ToolRegistry.shared.isRegistered($0) })
            #expect(Set(ToolRegistry.shared.registeredToolNames()).subtracting(before) == fresh)
        }
    }

    @Test
    func directReplacementInvalidatesSuspendedRefresh() async throws {
        try await withCatalogFixture {
            let manager = MCPProviderManager.shared
            let provider = provider()
            defer { manager.disconnect(providerId: provider.id) }
            let barrier = FetchBarrier()
            let pending = Task { @MainActor in
                try await manager.refreshDiscoveredTools(for: provider.id, provider: provider) {
                    await barrier.fetch()
                }
            }
            await barrier.waitUntilEntered()
            let replacement = manager.replaceDiscoveredTools([tool("current")], for: provider.id, provider: provider)
            barrier.resolve([tool("stale")])
            try await pending.value
            #expect(ToolRegistry.shared.isRegistered(replacement[0].name))
        }
    }

    @Test
    func cancelledRefreshKeepsPreviousCatalog() async throws {
        try await withCatalogFixture {
            let manager = MCPProviderManager.shared
            let provider = provider()
            let original = manager.replaceDiscoveredTools([tool("current")], for: provider.id, provider: provider)
            defer { manager.disconnect(providerId: provider.id) }
            let barrier = FetchBarrier()
            let pending = Task { @MainActor in
                try await manager.refreshDiscoveredTools(for: provider.id, provider: provider) {
                    await barrier.fetch()
                }
            }
            await barrier.waitUntilEntered()
            pending.cancel()
            barrier.resolve([tool("stale")])
            do {
                try await pending.value
                Issue.record("Cancelled discovery published instead of throwing")
            } catch is CancellationError {
            }
            #expect(ToolRegistry.shared.isRegistered(original[0].name))
        }
    }
}
