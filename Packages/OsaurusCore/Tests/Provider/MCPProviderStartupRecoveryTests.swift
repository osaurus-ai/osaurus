// Copyright © 2026 osaurus.

import Foundation
import MCP
import Testing

@testable import OsaurusCore

/// Records the provider IDs a connect path attempted, thread-safely.
private final class ConnectRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var attemptsById: [UUID: Int] = [:]

    func record(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        attemptsById[id, default: 0] += 1
    }

    func attempts(for id: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return attemptsById[id] ?? 0
    }

    var attemptedIds: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(attemptsById.keys)
    }
}

/// Completes `arrive()` only once `expected` callers are waiting inside it
/// simultaneously — proof of concurrency, deadlock under serial execution.
private actor Rendezvous {
    private let expected: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) {
        self.expected = expected
    }

    func arrive() async {
        arrived += 1
        if arrived >= expected {
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor MCPConnectionPause {
    private var reached = false
    private var released = false
    private var reachWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        reached = true
        for waiter in reachWaiters { waiter.resume() }
        reachWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { reachWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

/// Launch/recovery orchestration for MCP providers. Serialized: the manager
/// is a process-wide singleton.
@Suite("MCP provider startup and recovery", .serialized)
@MainActor
struct MCPProviderStartupRecoveryTests {

    private func makeProvider(name: String, enabled: Bool = true, autoConnect: Bool = true)
        -> MCPProvider
    {
        MCPProvider(
            name: name,
            url: "https://\(name).example.invalid/mcp",
            enabled: enabled,
            autoConnect: autoConnect
        )
    }

    private func makeTool(_ name: String) -> MCP.Tool {
        MCP.Tool(
            name: name,
            description: "Lifecycle fixture",
            inputSchema: ["type": "object", "properties": [:]]
        )
    }

    @Test("launch connect honors enabled && autoConnect")
    func launchHonorsAutoConnect() async {
        let manager = MCPProviderManager.shared
        let connecting = makeProvider(name: "auto-on")
        let dormant = makeProvider(name: "auto-off", autoConnect: false)
        let disabled = makeProvider(name: "disabled", enabled: false)
        manager._testInstallProviders([connecting, dormant, disabled])
        defer { manager._testRemoveProviders(ids: [connecting.id, dormant.id, disabled.id]) }

        let recorder = ConnectRecorder()
        manager.testConnectOverride = { id in recorder.record(id) }

        await manager.connectEnabledProviders()

        // Every *other* auto-connect provider in the shared config may also be
        // attempted; what matters is ours: auto-connect connects, the
        // enabled-but-dormant and disabled ones stay untouched.
        #expect(recorder.attempts(for: connecting.id) == 1)
        #expect(recorder.attempts(for: dormant.id) == 0)
        #expect(recorder.attempts(for: disabled.id) == 0)
    }

    @Test("launch connects run concurrently, not serially")
    func launchConnectsAreConcurrent() async {
        let manager = MCPProviderManager.shared
        let first = makeProvider(name: "concurrent-a")
        let second = makeProvider(name: "concurrent-b")
        manager._testInstallProviders([first, second])
        defer { manager._testRemoveProviders(ids: [first.id, second.id]) }

        // Both connects must be in-flight at the same time for either to
        // finish. A serial launch loop would deadlock here, so guard with a
        // timeout that fails the test instead of hanging the suite.
        let rendezvous = Rendezvous(expected: 2)
        let ourIds: Set<UUID> = [first.id, second.id]
        manager.testConnectOverride = { id in
            guard ourIds.contains(id) else { return }
            await rendezvous.arrive()
        }

        // Hoisted out of the group: the region-based isolation checker cannot
        // handle a `@MainActor` child task capturing the manager directly.
        let connectTask = Task { @MainActor in
            await manager.connectEnabledProviders()
        }
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await connectTask.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !completed { connectTask.cancel() }
        #expect(completed, "connectEnabledProviders must run providers concurrently")
    }

    @Test("transient launch failures get bounded retry")
    func transientFailureRetries() async {
        let manager = MCPProviderManager.shared
        let provider = makeProvider(name: "flaky")
        manager._testInstallProviders([provider])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        let recorder = ConnectRecorder()
        manager.testRetrySleepOverride = { _ in }
        manager.testConnectOverride = { id in
            recorder.record(id)
            if recorder.attempts(for: id) < 3 {
                throw URLError(.notConnectedToInternet)
            }
        }

        await manager.connectEnabledProviders()

        #expect(recorder.attempts(for: provider.id) == 3)
    }

    @Test("disconnect during retry backoff prevents another attempt")
    func disconnectCancelsTransientRetry() async {
        let manager = MCPProviderManager.shared
        let provider = makeProvider(name: "disconnect-backoff")
        manager._testInstallProviders([provider])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        let recorder = ConnectRecorder()
        manager.testConnectOverride = { id in
            recorder.record(id)
            throw URLError(.notConnectedToInternet)
        }
        manager.testRetrySleepOverride = { _ in
            manager.disconnect(providerId: provider.id)
        }

        await manager.connectEnabledProviders()

        #expect(recorder.attempts(for: provider.id) == 1)
        #expect(manager.providerStates[provider.id]?.isConnected == false)
    }

    @Test("superseded connection cannot commit connected state")
    func supersededConnectionCannotCommitState() {
        let manager = MCPProviderManager.shared
        let provider = makeProvider(name: "lifecycle-state", autoConnect: false)
        manager._testInstallProviders([provider])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        let first = manager.beginConnectionOperation(providerId: provider.id)
        let second = manager.beginConnectionOperation(providerId: provider.id)

        #expect(!manager.connectionOperationIsCurrent(first))
        #expect(manager.connectionOperationIsCurrent(second))
        #expect(!manager.commitConnectedState(provider: provider, operation: first))
        #expect(manager.commitConnectedState(provider: provider, operation: second))
        #expect(manager.providerStates[provider.id]?.isConnected == true)

        manager.disconnect(providerId: provider.id)
        #expect(!manager.connectionOperationIsCurrent(second))
        #expect(manager.providerStates[provider.id]?.isConnected == false)
    }

    @Test("stale discovery cannot overwrite a newer connection catalog")
    func staleDiscoveryCannotOverwriteNewCatalog() async throws {
        let manager = MCPProviderManager.shared
        let provider = makeProvider(name: "lifecycle-catalog", autoConnect: false)
        let pause = MCPConnectionPause()
        manager._testInstallProviders([provider])
        defer {
            manager.replaceDiscoveredTools([], for: provider.id, provider: provider)
            manager._testRemoveProviders(ids: [provider.id])
        }

        let first = manager.beginConnectionOperation(providerId: provider.id)
        let staleRefresh = Task { @MainActor in
            try await manager.refreshDiscoveredTools(
                for: provider.id,
                provider: provider,
                operation: first
            ) {
                await pause.pause()
                return [makeTool("stale")]
            }
        }
        await pause.waitUntilReached()

        let second = manager.beginConnectionOperation(providerId: provider.id)
        try await manager.refreshDiscoveredTools(
            for: provider.id,
            provider: provider,
            operation: second
        ) {
            [makeTool("current")]
        }
        await pause.release()

        do {
            try await staleRefresh.value
            Issue.record("A superseded discovery unexpectedly committed")
        } catch is CancellationError {
            // Expected: the generation guard rejects the stale result.
        } catch {
            Issue.record("Unexpected stale discovery error: \(error)")
        }

        #expect(manager.providerStates[provider.id]?.discoveredToolNames == ["current"])
    }

    @Test("terminal launch failures are not retried")
    func terminalFailureDoesNotRetry() async {
        let manager = MCPProviderManager.shared
        let provider = makeProvider(name: "terminal")
        manager._testInstallProviders([provider])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        let recorder = ConnectRecorder()
        manager.testRetrySleepOverride = { _ in }
        manager.testConnectOverride = { id in
            recorder.record(id)
            throw MCPProviderError.invalidURL
        }

        await manager.connectEnabledProviders()

        #expect(recorder.attempts(for: provider.id) == 1)
    }

    @Test("an old stdio exit cannot invalidate a replacement connection")
    func supersededStdioExitPreservesReplacement() {
        let manager = MCPProviderManager.shared
        let provider = makeProvider(name: "stdio-replacement", autoConnect: false)
        manager._testInstallProviders([provider])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        let oldOperation = manager.beginConnectionOperation(providerId: provider.id)
        let token = manager._testRegisterStdioRunnerOperation(oldOperation)
        let replacement = manager.beginConnectionOperation(providerId: provider.id)

        var state = MCPProviderState(providerId: provider.id)
        state.isConnecting = true
        manager._testSetState(state, for: provider.id)

        manager._testHandleStdioProcessExit(providerId: provider.id, runnerToken: token)

        #expect(manager.connectionOperationIsCurrent(replacement))
        #expect(manager.providerStates[provider.id]?.isConnecting == true)
        #expect(manager.providerStates[provider.id]?.lastError == nil)
    }

    @Test("terminal stdio exit clears stale transient recovery state")
    func terminalStdioExitClearsTransientFailure() async {
        let manager = MCPProviderManager.shared
        let provider = makeProvider(name: "stdio-terminal", autoConnect: false)
        manager._testInstallProviders([provider])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        let operation = manager.beginConnectionOperation(providerId: provider.id)
        let token = manager._testRegisterStdioRunnerOperation(operation)
        var state = MCPProviderState(providerId: provider.id)
        state.lastFailureWasTransient = true
        manager._testSetState(state, for: provider.id)

        manager._testHandleStdioProcessExit(providerId: provider.id, runnerToken: token)

        #expect(manager.providerStates[provider.id]?.lastFailureWasTransient == false)
        let recorder = ConnectRecorder()
        manager.testConnectOverride = { id in recorder.record(id) }
        await manager.reconnectTransientlyFailedProviders()
        #expect(recorder.attempts(for: provider.id) == 0)
    }

    @Test("stdio connection probes do not mutate live provider state")
    func stdioProbeDoesNotMutateLiveState() async {
        let manager = MCPProviderManager.shared
        var provider = makeProvider(name: "stdio-probe", autoConnect: false)
        provider.transport = .stdio
        provider.executionHost = .host
        provider.command = ""
        manager._testInstallProviders([provider])
        defer { manager._testRemoveProviders(ids: [provider.id]) }

        var state = MCPProviderState(providerId: provider.id)
        state.isConnected = true
        state.discoveredToolCount = 3
        state.discoveredToolNames = ["one", "two", "three"]
        manager._testSetState(state, for: provider.id)

        do {
            _ = try await manager.testStdioConnection(provider: provider)
            Issue.record("A stdio probe without a command unexpectedly succeeded")
        } catch {
            // Expected: the isolated probe reports its own configuration failure.
        }

        #expect(manager.providerStates[provider.id]?.isConnected == true)
        #expect(manager.providerStates[provider.id]?.discoveredToolCount == 3)
        #expect(manager.providerStates[provider.id]?.discoveredToolNames == ["one", "two", "three"])
    }

    @Test("first satisfied network observation recovers transiently-failed providers")
    func firstSatisfiedObservationRecovers() async {
        let manager = MCPProviderManager.shared
        // The manager's real NWPathMonitor may already have consumed the
        // launch baseline; reset connectivity bookkeeping so this test owns
        // the "first observation".
        manager._testRemoveProviders(ids: [])
        let failed = makeProvider(name: "transient-failed")
        let healthy = makeProvider(name: "healthy")
        manager._testInstallProviders([failed, healthy])
        defer { manager._testRemoveProviders(ids: [failed.id, healthy.id]) }

        var failedState = MCPProviderState(providerId: failed.id)
        failedState.lastFailureWasTransient = true
        manager._testSetState(failedState, for: failed.id)

        var healthyState = MCPProviderState(providerId: healthy.id)
        healthyState.isConnected = true
        manager._testSetState(healthyState, for: healthy.id)

        let recorder = ConnectRecorder()
        manager.testConnectOverride = { id in recorder.record(id) }
        manager.testNetworkRecoverySettleDelayOverride = 0

        // The very first path observation (launch baseline) must count as a
        // recovery opportunity — not just a down→up edge.
        manager.handleNetworkPathUpdate(satisfied: true)
        await manager._testAwaitNetworkRecoverySweep()

        #expect(recorder.attempts(for: failed.id) == 1)
        #expect(recorder.attempts(for: healthy.id) == 0)
    }

    @Test("recovery sweep skips terminal failures and providers awaiting sign-in")
    func recoverySweepSkipsTerminalAndAuth() async {
        let manager = MCPProviderManager.shared
        let terminal = makeProvider(name: "terminal-failed")
        let needsAuth = makeProvider(name: "needs-auth")
        manager._testInstallProviders([terminal, needsAuth])
        defer { manager._testRemoveProviders(ids: [terminal.id, needsAuth.id]) }

        var terminalState = MCPProviderState(providerId: terminal.id)
        terminalState.lastFailureWasTransient = false
        manager._testSetState(terminalState, for: terminal.id)

        var authState = MCPProviderState(providerId: needsAuth.id)
        authState.lastFailureWasTransient = true
        authState.requiresAuth = true
        manager._testSetState(authState, for: needsAuth.id)

        let recorder = ConnectRecorder()
        manager.testConnectOverride = { id in recorder.record(id) }

        await manager.reconnectTransientlyFailedProviders()

        #expect(recorder.attempts(for: terminal.id) == 0)
        #expect(recorder.attempts(for: needsAuth.id) == 0)
    }

    @Test("repeated satisfied observations do not re-trigger recovery")
    func repeatedSatisfiedObservationsDoNotRetrigger() async {
        let manager = MCPProviderManager.shared
        manager._testRemoveProviders(ids: [])
        let failed = makeProvider(name: "once-only")
        manager._testInstallProviders([failed])
        defer { manager._testRemoveProviders(ids: [failed.id]) }

        var state = MCPProviderState(providerId: failed.id)
        state.lastFailureWasTransient = true
        manager._testSetState(state, for: failed.id)

        let recorder = ConnectRecorder()
        manager.testConnectOverride = { id in
            recorder.record(id)
            // Stay disconnected so a second sweep would re-attempt.
            throw URLError(.notConnectedToInternet)
        }
        manager.testNetworkRecoverySettleDelayOverride = 0

        manager.handleNetworkPathUpdate(satisfied: true)
        await manager._testAwaitNetworkRecoverySweep()
        #expect(recorder.attempts(for: failed.id) == 1)

        // Satisfied → satisfied is not an edge; no new sweep.
        manager.handleNetworkPathUpdate(satisfied: true)
        await manager._testAwaitNetworkRecoverySweep()
        #expect(recorder.attempts(for: failed.id) == 1)

        // A real outage/recovery cycle sweeps again.
        manager.handleNetworkPathUpdate(satisfied: false)
        manager.handleNetworkPathUpdate(satisfied: true)
        await manager._testAwaitNetworkRecoverySweep()
        #expect(recorder.attempts(for: failed.id) == 2)
    }

    @Test("transient error classification")
    func transientErrorClassification() {
        #expect(MCPProviderManager.isTransientConnectError(URLError(.notConnectedToInternet)))
        #expect(MCPProviderManager.isTransientConnectError(URLError(.timedOut)))
        #expect(MCPProviderManager.isTransientConnectError(URLError(.dnsLookupFailed)))
        #expect(MCPProviderManager.isTransientConnectError(MCPProviderError.timeout))
        #expect(!MCPProviderManager.isTransientConnectError(URLError(.userAuthenticationRequired)))
        #expect(!MCPProviderManager.isTransientConnectError(MCPProviderError.invalidURL))
        #expect(!MCPProviderManager.isTransientConnectError(MCPProviderError.providerNotFound))
    }

    @Test("enabled/auto-connect intent survives an encode/decode relaunch")
    func persistedIntentSurvivesRelaunch() throws {
        let auto = makeProvider(name: "persist-auto")
        let manualOnly = makeProvider(name: "persist-manual", autoConnect: false)
        let off = makeProvider(name: "persist-off", enabled: false)
        let configuration = MCPProviderConfiguration(providers: [auto, manualOnly, off])

        let data = try JSONEncoder().encode(configuration)
        let reloaded = try JSONDecoder().decode(MCPProviderConfiguration.self, from: data)

        #expect(reloaded.provider(id: auto.id)?.enabled == true)
        #expect(reloaded.provider(id: auto.id)?.autoConnect == true)
        #expect(reloaded.provider(id: manualOnly.id)?.enabled == true)
        #expect(reloaded.provider(id: manualOnly.id)?.autoConnect == false)
        #expect(reloaded.provider(id: off.id)?.enabled == false)
        #expect(reloaded.autoConnectProviders.map(\.id) == [auto.id])
    }
}
