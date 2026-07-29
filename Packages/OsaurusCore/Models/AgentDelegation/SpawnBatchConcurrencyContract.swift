//
//  SpawnBatchConcurrencyContract.swift
//  osaurus
//
//  One configured concurrency value shared by Server -> Concurrent Sessions
//  and every Spawn editor's Max subagents per batch control.
//

import Foundation
@preconcurrency import MLXLMCommon

enum SpawnBatchConcurrencyContract {
    static var bounds: ClosedRange<Int> {
        SubagentBudgets.parallelSpawnBounds
    }

    static func normalized(_ value: Int) -> Int {
        min(max(value, bounds.lowerBound), bounds.upperBound)
    }

    /// The configured Spawn fan-out represented by Server settings.
    ///
    /// An explicit Concurrent Sessions value is authoritative. In Automatic
    /// mode, mirror the resolved safe profile value without materializing an
    /// explicit override. Runtime RAM admission and current engine occupancy
    /// may still lower an individual wave.
    static func configuredLimit(
        for settings: VMLXServerRuntimeSettings
    ) -> Int {
        if let explicit = settings.concurrency.maxConcurrentSequences {
            return normalized(explicit)
        }
        return normalized(
            ServerRuntimeSettingsStore.resolvedBatchEngineMaxBatchSize(
                for: settings
            )
        )
    }

    static func configuredLimit(
        for configuration: SubagentConfiguration
    ) -> Int {
        normalized(configuration.budgets.maxParallelSpawns)
    }

    /// Preserve an agent's token / turn / tool / elapsed budgets while making
    /// its parallel fan-out read the one shared Server + Spawn value.
    static func applyingSharedLimit(
        from configuration: SubagentConfiguration,
        to budgets: SubagentBudgets
    ) -> SubagentBudgets {
        applyingLimit(
            configuredLimit(for: configuration),
            to: budgets
        )
    }

    /// Apply the canonical Server-owned value to one launcher's independent
    /// token / turn / tool / elapsed budgets. Runtime consumers use this path
    /// directly instead of trusting the UI's persisted Subagent mirror: the
    /// headless eval/API path has no `ServerController` to keep that mirror in
    /// sync, and admission must still see the exact BatchEngine setting.
    static func applyingLimit(
        _ limit: Int,
        to budgets: SubagentBudgets
    ) -> SubagentBudgets {
        var updated = budgets
        updated.maxParallelSpawns = normalized(limit)
        return updated.normalized
    }

    /// Any Spawn editor -> Server. Editing a launcher's limit makes the same
    /// number an explicit BatchEngine ceiling.
    static func applyingMainChatLimit(
        _ configuration: SubagentConfiguration,
        to settings: VMLXServerRuntimeSettings
    ) -> VMLXServerRuntimeSettings {
        var updated = settings
        updated.concurrency.maxConcurrentSequences = configuredLimit(
            for: configuration
        )
        return updated
    }

    /// Server -> every Spawn editor. The shared configuration is the persisted
    /// source of truth for parallel fan-out; custom agents keep independent
    /// token / turn / tool / elapsed budgets.
    static func applyingServerLimit(
        _ settings: VMLXServerRuntimeSettings,
        to configuration: SubagentConfiguration
    ) -> SubagentConfiguration {
        var updated = configuration
        updated.budgets.maxParallelSpawns = configuredLimit(for: settings)
        return updated.normalized
    }
}
