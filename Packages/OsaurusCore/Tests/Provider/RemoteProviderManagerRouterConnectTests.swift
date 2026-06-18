//
//  RemoteProviderManagerRouterConnectTests.swift
//  osaurusTests
//
//  Covers the launch-time reliability of the managed Osaurus Router:
//  bounded connect retry on transient failures, the transient-vs-terminal
//  error classifier, and the identity-change / app-reactivation recovery
//  hooks that (re)connect the router without a user-driven refresh.
//

import Foundation
import Testing

@testable import OsaurusCore

/// MainActor-isolated mutable counter usable from `@Sendable` override/observer blocks.
@MainActor
private final class Counter {
    var value = 0
    func increment() { value += 1 }
}

@Suite(.serialized)
@MainActor
struct RemoteProviderManagerRouterConnectTests {

    private var routerId: UUID { RemoteProviderManager.osaurusRouterProviderId }

    /// Clean-slate the managed router in the shared singleton (it may already
    /// be present if the test machine has a real identity) and reset seams.
    private func resetRouter(_ manager: RemoteProviderManager) {
        manager._testRemoveProviders(ids: [routerId])
    }

    private func observeModelsChanged(_ counter: Counter) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .remoteProviderModelsChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { counter.increment() }
        }
    }

    // MARK: - Error classification

    @Test func isTransientConnectError_classifiesRetryableFailures() {
        // Transient: network + server 5xx / rate-limit.
        #expect(RemoteProviderManager.isTransientConnectError(URLError(.timedOut)))
        #expect(RemoteProviderManager.isTransientConnectError(URLError(.notConnectedToInternet)))
        #expect(RemoteProviderManager.isTransientConnectError(URLError(.networkConnectionLost)))
        #expect(RemoteProviderManager.isTransientConnectError(URLError(.cannotFindHost)))
        #expect(
            RemoteProviderManager.isTransientConnectError(
                OsaurusRouterAPIError.server(code: "X", message: "boom", status: 503)
            )
        )
        #expect(
            RemoteProviderManager.isTransientConnectError(
                OsaurusRouterAPIError.rateLimited(retryAfter: "1")
            )
        )
        #expect(RemoteProviderManager.isTransientConnectError(OsaurusRouterAPIError.transport("down")))
        #expect(RemoteProviderManager.isTransientConnectError(RemoteProviderServiceError.invalidResponse))

        // Terminal: identity / auth / other 4xx / config / unknown.
        #expect(!RemoteProviderManager.isTransientConnectError(OsaurusRouterAPIError.noIdentity))
        #expect(!RemoteProviderManager.isTransientConnectError(OsaurusRouterAPIError.unauthorized))
        #expect(!RemoteProviderManager.isTransientConnectError(OsaurusRouterAPIError.insufficientFunds))
        #expect(
            !RemoteProviderManager.isTransientConnectError(
                OsaurusRouterAPIError.server(code: "X", message: "bad", status: 400)
            )
        )
        #expect(!RemoteProviderManager.isTransientConnectError(RemoteProviderServiceError.requestFailed("nope")))
        #expect(!RemoteProviderManager.isTransientConnectError(RemoteProviderServiceError.invalidURL))
        #expect(!RemoteProviderManager.isTransientConnectError(URLError(.userAuthenticationRequired)))
    }

    // MARK: - connectOsaurusRouterWithRetry

    @Test func routerConnect_retriesTransientFailureThenSucceeds() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            resetRouter(manager)
            defer { manager._testRemoveProviders(ids: [routerId]) }

            manager.testIdentityExistsOverride = true
            manager.testRetrySleepOverride = { _ in }  // skip real backoff

            let counter = Counter()
            manager.testFetchModelsOverride = { _ in
                counter.increment()
                if counter.value < 3 {
                    throw URLError(.timedOut)  // transient — should retry
                }
                return ["router/model-a"]
            }

            await manager.connectOsaurusRouterWithRetry(maxAttempts: 3)

            #expect(counter.value == 3)
            let state = manager.providerStates[routerId]
            #expect(state?.isConnected == true)
            #expect(state?.discoveredModels == ["router/model-a"])
        }
    }

    @Test func routerConnect_stopsImmediatelyOnTerminalError() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            resetRouter(manager)
            defer { manager._testRemoveProviders(ids: [routerId]) }

            manager.testIdentityExistsOverride = true
            manager.testRetrySleepOverride = { _ in }

            let counter = Counter()
            manager.testFetchModelsOverride = { _ in
                counter.increment()
                throw OsaurusRouterAPIError.unauthorized  // terminal — no retry
            }

            await manager.connectOsaurusRouterWithRetry(maxAttempts: 3)

            #expect(counter.value == 1)
            #expect(manager.providerStates[routerId]?.isConnected != true)
        }
    }

    @Test func routerConnect_givesUpAfterMaxTransientAttempts() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            resetRouter(manager)
            defer { manager._testRemoveProviders(ids: [routerId]) }

            manager.testIdentityExistsOverride = true
            manager.testRetrySleepOverride = { _ in }

            let counter = Counter()
            manager.testFetchModelsOverride = { _ in
                counter.increment()
                throw URLError(.networkConnectionLost)  // always transient
            }

            await manager.connectOsaurusRouterWithRetry(maxAttempts: 3)

            #expect(counter.value == 3)  // exactly maxAttempts, then gives up
            #expect(manager.providerStates[routerId]?.isConnected != true)
        }
    }

    @Test func routerConnect_noopWhenIdentityMissing() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            resetRouter(manager)
            defer { manager._testRemoveProviders(ids: [routerId]) }

            manager.testIdentityExistsOverride = false  // no identity → no managed provider

            let counter = Counter()
            manager.testFetchModelsOverride = { _ in
                counter.increment()
                return ["should-not-fetch"]
            }

            await manager.connectOsaurusRouterWithRetry(maxAttempts: 3)

            #expect(counter.value == 0)
            #expect(manager.configuration.provider(id: routerId) == nil)
        }
    }

    // MARK: - Identity change recovery

    @Test func identityChanged_injectsAndConnectsRouterWhenPresent() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            resetRouter(manager)
            defer { manager._testRemoveProviders(ids: [routerId]) }

            manager.testIdentityExistsOverride = true
            manager.testFetchModelsOverride = { _ in ["router/model-x"] }

            let counter = Counter()
            let observer = observeModelsChanged(counter)
            defer { NotificationCenter.default.removeObserver(observer) }

            await manager.handleIdentityChanged()

            let state = manager.providerStates[routerId]
            #expect(state?.isConnected == true)
            #expect(state?.discoveredModels == ["router/model-x"])

            try? await Task.sleep(nanoseconds: 10_000_000)
            #expect(counter.value >= 1)  // .remoteProviderModelsChanged fired
        }
    }

    @Test func identityChanged_dropsRouterAndNotifiesWhenWiped() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            resetRouter(manager)
            defer { manager._testRemoveProviders(ids: [routerId]) }

            // Bring the router up first.
            manager.testIdentityExistsOverride = true
            manager.testFetchModelsOverride = { _ in ["router/model-x"] }
            await manager.handleIdentityChanged()
            #expect(manager.providerStates[routerId]?.isConnected == true)

            // Now wipe: identity is gone.
            manager.testIdentityExistsOverride = false
            let counter = Counter()
            let observer = observeModelsChanged(counter)
            defer { NotificationCenter.default.removeObserver(observer) }

            await manager.handleIdentityChanged()

            #expect(manager.configuration.provider(id: routerId) == nil)
            #expect(manager.providerStates[routerId] == nil)

            try? await Task.sleep(nanoseconds: 10_000_000)
            #expect(counter.value >= 1)  // picker rebuild signalled
        }
    }

    // MARK: - App re-activation recovery

    @Test func didBecomeActive_reconnectsRouterWhenDisconnected() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            resetRouter(manager)
            defer { manager._testRemoveProviders(ids: [routerId]) }

            manager.testIdentityExistsOverride = true
            manager.testFetchModelsOverride = { _ in ["router/model-y"] }

            await manager.handleAppDidBecomeActive()

            let state = manager.providerStates[routerId]
            #expect(state?.isConnected == true)
            #expect(state?.discoveredModels == ["router/model-y"])
        }
    }

    @Test func didBecomeActive_noopWhenAlreadyConnected() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            resetRouter(manager)
            defer { manager._testRemoveProviders(ids: [routerId]) }

            manager.testIdentityExistsOverride = true
            let counter = Counter()
            manager.testFetchModelsOverride = { _ in
                counter.increment()
                return ["router/model-z"]
            }

            await manager.handleAppDidBecomeActive()
            #expect(manager.providerStates[routerId]?.isConnected == true)
            #expect(counter.value == 1)

            // A second activation must not re-fetch when already connected.
            await manager.handleAppDidBecomeActive()
            #expect(counter.value == 1)
        }
    }

    @Test func didBecomeActive_noopWhenIdentityMissing() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            resetRouter(manager)
            defer { manager._testRemoveProviders(ids: [routerId]) }

            manager.testIdentityExistsOverride = false

            let counter = Counter()
            manager.testFetchModelsOverride = { _ in
                counter.increment()
                return ["nope"]
            }

            await manager.handleAppDidBecomeActive()

            #expect(counter.value == 0)
            #expect(manager.providerStates[routerId]?.isConnected != true)
        }
    }

    // MARK: - Master enable/disable switch

    @Test func disablingRouter_dropsProviderHidesModelsAndStopsConnects() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            resetRouter(manager)
            defer { manager._testRemoveProviders(ids: [routerId]) }

            manager.testIdentityExistsOverride = true
            manager.testRetrySleepOverride = { _ in }

            let counter = Counter()
            manager.testFetchModelsOverride = { _ in
                counter.increment()
                return ["router/model-a"]
            }

            // Enabled + connected: the router is exposed to the picker source.
            await manager.connectOsaurusRouterWithRetry(maxAttempts: 1)
            #expect(manager.providerStates[routerId]?.isConnected == true)
            #expect(manager.cachedAvailableModels().contains { $0.providerId == routerId })
            #expect(counter.value == 1)

            // Disable: provider dropped and excluded from the picker source.
            manager.setOsaurusRouterEnabled(false)
            #expect(manager.isOsaurusRouterEnabled == false)
            #expect(manager.configuration.provider(id: routerId) == nil)
            #expect(!manager.cachedAvailableModels().contains { $0.providerId == routerId })

            // No further connects/fetches happen while the router is off.
            counter.value = 0
            await manager.connectOsaurusRouterWithRetry(maxAttempts: 3)
            #expect(counter.value == 0)
            #expect(manager.providerStates[routerId]?.isConnected != true)
        }
    }

    @Test func reEnablingRouter_reinjectsAndReconnects() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            resetRouter(manager)
            defer { manager._testRemoveProviders(ids: [routerId]) }

            manager.testIdentityExistsOverride = true
            manager.testRetrySleepOverride = { _ in }
            manager.testFetchModelsOverride = { _ in ["router/model-b"] }

            // Off: provider absent, hidden from the picker source.
            manager.setOsaurusRouterEnabled(false)
            #expect(manager.configuration.provider(id: routerId) == nil)

            // On: provider is re-injected synchronously; the spawned connect then
            // reconnects and restores the model to the picker source.
            manager.setOsaurusRouterEnabled(true)
            #expect(manager.isOsaurusRouterEnabled == true)
            #expect(manager.configuration.provider(id: routerId) != nil)

            await manager._testAwaitRouterEnableWork()

            let state = manager.providerStates[routerId]
            #expect(state?.isConnected == true)
            #expect(state?.discoveredModels == ["router/model-b"])
            #expect(manager.cachedAvailableModels().contains { $0.providerId == routerId })
        }
    }
}
