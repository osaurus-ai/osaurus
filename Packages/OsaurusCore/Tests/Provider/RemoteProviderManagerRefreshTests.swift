//
//  RemoteProviderManagerRefreshTests.swift
//  osaurusTests
//
//  Covers the picker-open refresh path: throttling, coalescing, and the
//  state/notification contract of `refetchModels` / `refreshConnectedProviders`.
//

import Foundation
import Testing

@testable import OsaurusCore

/// MainActor-isolated mutable counter usable from `@Sendable` notification blocks.
@MainActor
private final class Counter {
    var value = 0
    func increment() { value += 1 }
}

@MainActor
struct RemoteProviderManagerRefreshTests {

    // MARK: - Helpers

    private func makeProvider(name: String = "Test Provider") -> RemoteProvider {
        RemoteProvider(
            name: name,
            host: "127.0.0.1",
            basePath: "/v1",
            authType: .none,
            providerType: .openaiLegacy
        )
    }

    private func install(
        _ manager: RemoteProviderManager,
        discovered: [String] = ["model-a"]
    ) -> RemoteProvider {
        let provider = makeProvider()
        manager._testInstallConnectedProvider(provider, discoveredModels: discovered)
        return provider
    }

    private func observeModelsChanged(_ counter: Counter) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .remoteProviderModelsChanged,
            object: nil,
            queue: .main
        ) { _ in
            // Posted on .main queue, so we can hop onto MainActor synchronously.
            MainActor.assumeIsolated { counter.increment() }
        }
    }

    // MARK: - refetchModels

    @Test func refetchModels_updatesDiscoveredModelsAndPostsNotification() async throws {
        let manager = RemoteProviderManager.shared
        let provider = install(manager, discovered: ["old-model"])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        let counter = Counter()
        let observer = observeModelsChanged(counter)
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.testFetchModelsOverride = { _ in ["new-a", "new-b"] }

        await manager.refetchModels(providerId: provider.id)

        let updated = manager.providerStates[provider.id]?.discoveredModels ?? []
        #expect(updated == ["new-a", "new-b"])

        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(counter.value == 1)
    }

    @Test func refetchModels_skipsNotificationWhenListUnchanged() async throws {
        let manager = RemoteProviderManager.shared
        let provider = install(manager, discovered: ["same-model"])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        let counter = Counter()
        let observer = observeModelsChanged(counter)
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.testFetchModelsOverride = { _ in ["same-model"] }
        await manager.refetchModels(providerId: provider.id)

        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(counter.value == 0)
    }

    @Test func refetchModels_preservesStateOnFetchFailure() async throws {
        let manager = RemoteProviderManager.shared
        let provider = install(manager, discovered: ["keep-me"])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        struct Boom: Error {}
        manager.testFetchModelsOverride = { _ in throw Boom() }

        await manager.refetchModels(providerId: provider.id)

        let state = manager.providerStates[provider.id]
        #expect(state?.discoveredModels == ["keep-me"])
        #expect(state?.isConnected == true)
    }

    @Test func refetchModels_noopWhenProviderNotConnected() async throws {
        let manager = RemoteProviderManager.shared
        let provider = makeProvider(name: "Disconnected")
        manager._testInstallConnectedProvider(provider, discoveredModels: ["x"])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        // Flip to disconnected via the test helper.
        var state = manager.providerStates[provider.id]!
        state.isConnected = false
        manager._testSetState(state, for: provider.id)

        let counter = Counter()
        manager.testFetchModelsOverride = { _ in
            counter.increment()
            return ["should-not-be-fetched"]
        }

        await manager.refetchModels(providerId: provider.id)
        #expect(counter.value == 0)
    }

    // MARK: - refreshConnectedProviders

    @Test func refreshConnectedProviders_throttlesRepeatedCalls() async throws {
        let manager = RemoteProviderManager.shared
        let provider = install(manager)
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        let counter = Counter()
        manager.testFetchModelsOverride = { _ in
            counter.increment()
            return ["a"]
        }

        await manager.refreshConnectedProviders()
        await manager.refreshConnectedProviders()
        await manager.refreshConnectedProviders()

        #expect(counter.value == 1, "second + third calls should be throttled within the window")
    }

    @Test func refreshConnectedProviders_coalescesConcurrentCalls() async throws {
        let manager = RemoteProviderManager.shared
        let provider = install(manager)
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        let counter = Counter()
        manager.testFetchModelsOverride = { _ in
            counter.increment()
            try? await Task.sleep(nanoseconds: 30_000_000)  // 30ms — long enough to overlap
            return ["a"]
        }

        async let r1: Void = manager.refreshConnectedProviders()
        async let r2: Void = manager.refreshConnectedProviders()
        async let r3: Void = manager.refreshConnectedProviders()
        _ = await (r1, r2, r3)

        #expect(counter.value == 1, "concurrent callers should coalesce onto a single fetch")
    }

    @Test func refreshConnectedProviders_skipsDisabledProviders() async throws {
        let manager = RemoteProviderManager.shared
        var provider = makeProvider(name: "Disabled")
        provider.enabled = false
        manager._testInstallConnectedProvider(provider, discoveredModels: ["x"])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        let counter = Counter()
        manager.testFetchModelsOverride = { _ in
            counter.increment()
            return ["y"]
        }

        await manager.refreshConnectedProviders()
        #expect(counter.value == 0)
    }
}
