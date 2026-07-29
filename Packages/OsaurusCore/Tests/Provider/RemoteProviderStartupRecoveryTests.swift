// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

/// MainActor-isolated mutable counter usable from `@Sendable` override blocks.
@MainActor
private final class Counter {
    var value = 0
    func increment() { value += 1 }
}

/// Launch/recovery behavior for user-configured remote providers: the first
/// satisfied network observation, wake, and app activation are recovery
/// opportunities for transiently-failed auto-connect providers, and no
/// recovery path requires toggling a provider off and on.
@Suite(.serialized)
@MainActor
struct RemoteProviderStartupRecoveryTests {

    private func installTransientlyFailedProvider(
        _ manager: RemoteProviderManager, name: String
    ) -> RemoteProvider {
        let provider = RemoteProvider(name: name, host: "\(name).example.invalid")
        manager._testInstallConnectedProvider(provider, discoveredModels: [])
        var state = RemoteProviderState(providerId: provider.id)
        state.isConnected = false
        state.lastFailureWasTransient = true
        manager._testSetState(state, for: provider.id)
        return provider
    }

    @Test func firstSatisfiedNetworkObservation_recoversTransientlyFailedProvider() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            // The manager's real NWPathMonitor may already have consumed the
            // launch baseline; reset connectivity bookkeeping so this test
            // owns the "first observation".
            manager._testRemoveProviders(ids: [])
            let provider = installTransientlyFailedProvider(manager, name: "recovery-baseline")
            defer { manager._testRemoveProviders(ids: [provider.id]) }

            manager.testFetchModelsOverride = { _ in ["recovered/model"] }
            manager.testNetworkRecoverySettleDelayOverride = 0

            // First path observation at launch — not a down→up edge — must
            // still sweep providers that failed transiently moments earlier.
            manager.handleNetworkPathUpdate(satisfied: true)
            await manager._testAwaitNetworkRecoverySweep()

            let state = manager.providerStates[provider.id]
            #expect(state?.isConnected == true)
            #expect(state?.discoveredModels == ["recovered/model"])
        }
    }

    @Test func appActivation_recoversTransientlyFailedProvider() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            manager._testRemoveProviders(ids: [])
            let provider = installTransientlyFailedProvider(manager, name: "recovery-activate")
            defer { manager._testRemoveProviders(ids: [provider.id]) }

            // No identity → the router leg of activation is a no-op; only the
            // transient sweep should act.
            manager.testIdentityExistsOverride = false
            manager.testFetchModelsOverride = { _ in ["activated/model"] }

            await manager.handleAppDidBecomeActive()

            #expect(manager.providerStates[provider.id]?.isConnected == true)
        }
    }

    @Test func recoverySweep_skipsTerminalFailuresAndConnectedProviders() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            manager._testRemoveProviders(ids: [])

            let terminal = RemoteProvider(name: "terminal", host: "terminal.example.invalid")
            manager._testInstallConnectedProvider(terminal, discoveredModels: [])
            var terminalState = RemoteProviderState(providerId: terminal.id)
            terminalState.isConnected = false
            terminalState.lastFailureWasTransient = false
            manager._testSetState(terminalState, for: terminal.id)

            let connected = RemoteProvider(name: "healthy", host: "healthy.example.invalid")
            manager._testInstallConnectedProvider(connected, discoveredModels: ["m"])
            defer { manager._testRemoveProviders(ids: [terminal.id, connected.id]) }

            let counter = Counter()
            manager.testFetchModelsOverride = { _ in
                counter.increment()
                return ["should-not-fetch"]
            }

            await manager.reconnectTransientlyFailedProviders()

            #expect(counter.value == 0)
            #expect(manager.providerStates[terminal.id]?.isConnected == false)
        }
    }
}
