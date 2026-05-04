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

    // MARK: - refetchModels

    @Test func refetchModels_updatesDiscoveredModelsAndPostsNotification() async throws {
        let manager = RemoteProviderManager.shared
        let provider = install(manager, discovered: ["old-model"])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        // Watch for the notification to verify we post on actual change.
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .remoteProviderModelsChanged,
            object: nil,
            queue: .main
        ) { _ in notificationCount += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.testFetchModelsOverride = { _ in ["new-a", "new-b"] }

        await manager.refetchModels(providerId: provider.id)

        let updated = manager.providerStates[provider.id]?.discoveredModels ?? []
        #expect(updated == ["new-a", "new-b"])

        // Allow the main-queue notification to drain.
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(notificationCount == 1)
    }

    @Test func refetchModels_skipsNotificationWhenListUnchanged() async throws {
        let manager = RemoteProviderManager.shared
        let provider = install(manager, discovered: ["same-model"])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .remoteProviderModelsChanged,
            object: nil,
            queue: .main
        ) { _ in notificationCount += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.testFetchModelsOverride = { _ in ["same-model"] }
        await manager.refetchModels(providerId: provider.id)

        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(notificationCount == 0)
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
        // Force the state to disconnected.
        var state = manager.providerStates[provider.id]!
        state.isConnected = false
        manager.providerStates[provider.id] = state
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        var fetchCalls = 0
        manager.testFetchModelsOverride = { _ in
            fetchCalls += 1
            return ["should-not-be-fetched"]
        }

        await manager.refetchModels(providerId: provider.id)
        #expect(fetchCalls == 0)
    }

    // MARK: - refreshConnectedProviders

    @Test func refreshConnectedProviders_throttlesRepeatedCalls() async throws {
        let manager = RemoteProviderManager.shared
        let provider = install(manager)
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        var fetchCalls = 0
        manager.testFetchModelsOverride = { _ in
            fetchCalls += 1
            return ["a"]
        }

        await manager.refreshConnectedProviders()
        await manager.refreshConnectedProviders()
        await manager.refreshConnectedProviders()

        #expect(fetchCalls == 1, "second + third calls should be throttled within the window")
    }

    @Test func refreshConnectedProviders_coalescesConcurrentCalls() async throws {
        let manager = RemoteProviderManager.shared
        let provider = install(manager)
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        var fetchCalls = 0
        manager.testFetchModelsOverride = { _ in
            fetchCalls += 1
            try? await Task.sleep(nanoseconds: 30_000_000)  // 30ms — long enough to overlap callers
            return ["a"]
        }

        async let r1: Void = manager.refreshConnectedProviders()
        async let r2: Void = manager.refreshConnectedProviders()
        async let r3: Void = manager.refreshConnectedProviders()
        _ = await (r1, r2, r3)

        #expect(fetchCalls == 1, "concurrent callers should coalesce onto a single fetch")
    }

    @Test func refreshConnectedProviders_skipsDisabledProviders() async throws {
        let manager = RemoteProviderManager.shared
        var provider = makeProvider(name: "Disabled")
        provider.enabled = false
        manager._testInstallConnectedProvider(provider, discoveredModels: ["x"])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        var fetchCalls = 0
        manager.testFetchModelsOverride = { _ in
            fetchCalls += 1
            return ["y"]
        }

        await manager.refreshConnectedProviders()
        #expect(fetchCalls == 0)
    }
}
