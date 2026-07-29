// Copyright © 2026 osaurus.

import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("Spawn batch concurrency contract")
struct SpawnBatchConcurrencyContractTests {
    @Test("explicit Server limit becomes the built-in main-chat batch limit")
    func serverLimitUpdatesMainChat() {
        var settings = VMLXServerRuntimeSettings()
        settings.concurrency.maxConcurrentSequences = 5

        var configuration = SubagentConfiguration()
        configuration.budgets.maxParallelSpawns = 2

        let updated = SpawnBatchConcurrencyContract.applyingServerLimit(
            settings,
            to: configuration
        )

        #expect(updated.budgets.maxParallelSpawns == 5)
        #expect(settings.concurrency.maxConcurrentSequences == 5)
    }

    @Test("main-chat batch limit becomes the explicit Server limit")
    func mainChatLimitUpdatesServer() {
        var settings = VMLXServerRuntimeSettings()
        settings.concurrency.maxConcurrentSequences = 2

        var configuration = SubagentConfiguration()
        configuration.budgets.maxParallelSpawns = 6

        let updated = SpawnBatchConcurrencyContract.applyingMainChatLimit(
            configuration,
            to: settings
        )

        #expect(updated.concurrency.maxConcurrentSequences == 6)
        #expect(configuration.budgets.maxParallelSpawns == 6)
    }

    @Test("custom agents preserve their other budgets and inherit shared fan-out")
    func sharedLimitUpdatesCustomAgentBudgets() {
        var configuration = SubagentConfiguration()
        configuration.budgets.maxParallelSpawns = 5
        let custom = SubagentBudgets(
            maxDelegateTokens: 1_024,
            maxDelegateTurns: 4,
            maxToolCalls: 6,
            maxElapsedSeconds: 75,
            maxParallelSpawns: 2
        )

        let updated = SpawnBatchConcurrencyContract.applyingSharedLimit(
            from: configuration,
            to: custom
        )

        #expect(updated.maxDelegateTokens == 1_024)
        #expect(updated.maxDelegateTurns == 4)
        #expect(updated.maxToolCalls == 6)
        #expect(updated.maxElapsedSeconds == 75)
        #expect(updated.maxParallelSpawns == 5)
    }

    @Test("runtime application uses the canonical Server value over a stale UI mirror")
    func runtimeLimitOverridesStaleSubagentMirror() {
        var staleMirror = SubagentConfiguration()
        staleMirror.budgets.maxParallelSpawns = 3
        let custom = SubagentBudgets(
            maxDelegateTokens: 1_024,
            maxDelegateTurns: 4,
            maxToolCalls: 6,
            maxElapsedSeconds: 75,
            maxParallelSpawns: staleMirror.budgets.maxParallelSpawns
        )

        let updated = SpawnBatchConcurrencyContract.applyingLimit(
            2,
            to: custom
        )

        #expect(updated.maxDelegateTokens == 1_024)
        #expect(updated.maxDelegateTurns == 4)
        #expect(updated.maxToolCalls == 6)
        #expect(updated.maxElapsedSeconds == 75)
        #expect(updated.maxParallelSpawns == 2)
        #expect(staleMirror.budgets.maxParallelSpawns == 3)
    }

    @Test("automatic Server mode mirrors its safe resolved capacity")
    func automaticServerModeUsesResolvedCapacity() {
        var settings = VMLXServerRuntimeSettings()
        settings.concurrency.continuousBatching = true
        settings.concurrency.maxConcurrentSequences = nil

        let expected = ServerRuntimeSettingsStore.resolvedBatchEngineMaxBatchSize(
            for: settings
        )
        let actual = SpawnBatchConcurrencyContract.configuredLimit(
            for: settings
        )

        #expect(actual == expected)
        #expect(settings.concurrency.maxConcurrentSequences == nil)
    }

    @Test("configured values share the complete bounded range")
    func sharedBoundsClampBothDirections() {
        #expect(SpawnBatchConcurrencyContract.bounds == 1 ... 32)
        #expect(SpawnBatchConcurrencyContract.normalized(-9) == 1)
        #expect(SpawnBatchConcurrencyContract.normalized(100) == 32)

        var settings = VMLXServerRuntimeSettings()
        settings.concurrency.maxConcurrentSequences = 100
        var configuration = SubagentConfiguration()
        configuration.budgets.maxParallelSpawns = -9

        let fromServer = SpawnBatchConcurrencyContract.applyingServerLimit(
            settings,
            to: configuration
        )
        let fromMainChat = SpawnBatchConcurrencyContract.applyingMainChatLimit(
            configuration,
            to: settings
        )

        #expect(fromServer.budgets.maxParallelSpawns == 32)
        #expect(fromMainChat.concurrency.maxConcurrentSequences == 1)
    }

    @Test("RAM safety remains a lower runtime clamp, not a second configured value")
    func ramSafetyCanClampBelowSharedSetting() {
        var settings = VMLXServerRuntimeSettings()
        settings.concurrency.continuousBatching = true
        settings.concurrency.maxConcurrentSequences = 5
        settings.memorySafety.customMaxConcurrentSequences = 1

        #expect(
            SpawnBatchConcurrencyContract.configuredLimit(for: settings) == 5
        )
        #expect(
            ServerRuntimeSettingsStore.resolvedBatchEngineMaxBatchSize(
                for: settings
            ) == 1
        )
    }
}
