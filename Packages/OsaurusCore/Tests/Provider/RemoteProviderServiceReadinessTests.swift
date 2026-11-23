//
//  RemoteProviderServiceReadinessTests.swift
//  OsaurusCoreTests
//
//  A request for a provider's model waits while that provider is
//  connecting (at launch, or reconnecting) and says why when it is down,
//  instead of failing at once with "model not found".
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct RemoteProviderServiceReadinessTests {

    private func install(_ manager: RemoteProviderManager, name: String, state: (inout RemoteProviderState) -> Void)
        -> RemoteProvider
    {
        let provider = RemoteProvider(name: name, host: "\(name).example.invalid")
        manager._testInstallConnectedProvider(provider, discoveredModels: [])
        var providerState = RemoteProviderState(providerId: provider.id)
        state(&providerState)
        manager._testSetState(providerState, for: provider.id)
        return provider
    }

    @Test func modelOfNoConfiguredProvider_doesNotWait() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            manager._testRemoveProviders(ids: [])
            #expect(await manager.awaitService(forModel: "nobody-here/model", limit: 5) == nil)
            #expect(await manager.awaitService(forModel: "mlx-community/some-local", limit: 5) == nil)
        }
    }

    @Test func liveService_isReady() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            manager._testRemoveProviders(ids: [])
            let provider = RemoteProvider(name: "readiness-live", host: "live.example.invalid")
            _ = manager._testInstallConnectedProvider(provider, discoveredModels: ["m"], installService: true)
            defer { manager._testRemoveProviders(ids: [provider.id]) }
            #expect(await manager.awaitService(forModel: "readiness-live/m", limit: 5) == nil)
        }
    }

    @Test func connectingProvider_isWaitedFor_untilItSettles() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            manager._testRemoveProviders(ids: [])
            let provider = install(manager, name: "readiness-connecting") { $0.isConnecting = true }
            defer { manager._testRemoveProviders(ids: [provider.id]) }

            let settle = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                var failed = RemoteProviderState(providerId: provider.id)
                failed.lastError = "HTTP 401: bad key"
                manager._testSetState(failed, for: provider.id)
            }
            let started = Date()
            let result = await manager.awaitService(forModel: "readiness-connecting/m", limit: 10)
            await settle.value

            #expect(Date().timeIntervalSince(started) >= 0.35, "returned before the connect settled")
            #expect(result?.reason == .connectFailed)
            #expect(result?.provider == "readiness-connecting")
            #expect(result?.errorDescription?.contains("didn't connect") == true)
        }
    }

    @Test func launchPassNotYetAtProvider_waits_thenTimesOutAsStillConnecting() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            manager._testRemoveProviders(ids: [])
            let provider = install(manager, name: "readiness-launch") { _ in }
            defer {
                RemoteProviderManager.launchConnectPending = false
                manager._testRemoveProviders(ids: [provider.id])
            }
            RemoteProviderManager.launchConnectPending = true

            let started = Date()
            let result = await manager.awaitService(forModel: "readiness-launch/m", limit: 0.5)
            #expect(Date().timeIntervalSince(started) >= 0.45)
            #expect(result?.reason == .stillConnecting)
            #expect(result?.retryable == true)
        }
    }

    @Test func nothingConnecting_failsAtOnce_withTheReason() async {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            manager._testRemoveProviders(ids: [])
            let idle = install(manager, name: "readiness-idle") { _ in }
            let auth = install(manager, name: "readiness-auth") { $0.requiresAuth = true }
            let failed = install(manager, name: "readiness-failed") {
                $0.lastError = "HTTP 403"
                $0.lastFailureWasTransient = false
            }
            defer { manager._testRemoveProviders(ids: [idle.id, auth.id, failed.id]) }
            RemoteProviderManager.launchConnectPending = false

            let started = Date()
            #expect(await manager.awaitService(forModel: "readiness-idle/m", limit: 10)?.reason == .notConnected)
            #expect(await manager.awaitService(forModel: "readiness-auth/m", limit: 10)?.reason == .signInRequired)
            #expect(await manager.awaitService(forModel: "readiness-failed/m", limit: 10)?.reason == .connectFailed)
            #expect(Date().timeIntervalSince(started) < 2, "a provider nobody is connecting must not be waited for")
        }
    }

    @Test func unavailable_classifiesAsProviderDisconnected() {
        let down = RemoteProviderUnavailable(provider: "Osaurus", reason: .connectFailed, detail: "HTTP 500")
        let failure = WorkflowFailure.classify(down)
        #expect(failure.kind == "provider_disconnected")
        #expect(failure.errorType == "RemoteProviderUnavailable.connectFailed")
        #expect(failure.hint?.contains("Settings → Providers") == true)

        let signIn = WorkflowFailure.classify(RemoteProviderUnavailable(provider: "OpenAI", reason: .signInRequired))
        #expect(signIn.fixIn == .setup && !signIn.retryable)

        let engine = WorkflowFailure.classify(
            ChatEngine.EngineError(kind: .providerUnavailable(.init(provider: "X", reason: .stillConnecting))))
        #expect(engine.kind == "provider_disconnected")
        #expect(engine.errorType == "ChatEngine.EngineError.providerUnavailable")
        #expect(engine.retryable)
        #expect(ChatEngine.EngineError(kind: .providerUnavailable(.init(provider: "X", reason: .offline))).httpStatus == 503)
        #expect(!CoreModelService.isRetryable(down))
        #expect(!CoreModelService.countsTowardBreaker(down))
    }
}
