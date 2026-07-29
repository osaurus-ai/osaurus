//
//  SpawnBatchConcurrencyContract.swift
//  osaurus
//
//  One configured concurrency value shared by Server -> Concurrent Sessions
//  and the built-in main chat's Max subagents per batch control.
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

    /// The configured main-chat fan-out represented by Server settings.
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

    /// Main Chat Spawn -> Server. Editing the built-in launcher's limit makes
    /// the same number an explicit BatchEngine ceiling.
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

    /// Server -> Main Chat Spawn. Custom-agent budgets remain independent
    /// per-agent safety caps; only the built-in main chat shares the server
    /// concurrency control.
    static func applyingServerLimit(
        _ settings: VMLXServerRuntimeSettings,
        to configuration: SubagentConfiguration
    ) -> SubagentConfiguration {
        var updated = configuration
        updated.budgets.maxParallelSpawns = configuredLimit(for: settings)
        return updated.normalized
    }
}
