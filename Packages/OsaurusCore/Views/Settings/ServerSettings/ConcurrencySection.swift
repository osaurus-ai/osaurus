//
//  ConcurrencySection.swift
//  osaurus
//
//  Concurrency & batching controls. `continuousBatching` gates the
//  multi-slot scheduler, `maxConcurrentSequences` hot-resizes the resident
//  BatchEngine, and `prefillStepSize` is passed per request. Other serialized
//  contract fields remain hidden until they have real runtime consumers.
//
//  Live BatchEngine diagnostics live in `LiveActivitySection` (its own
//  sidebar anchor) so users can monitor activity without scrolling
//  through this editing surface.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct ConcurrencySection: View {
    @Binding var draft: VMLXServerRuntimeSettings

    @State private var maxConcurrentText: String = ""
    @State private var initialized: Bool = false

    private var effectiveBatchEngineLimit: Int {
        ServerRuntimeSettingsStore.resolvedBatchEngineMaxBatchSize(
            for: draft
        )
    }

    var body: some View {
        ServerSettingsCard(
            section: .concurrency,
            status: .engineReady,
            blurb:
                "How many same-model requests, including local subagents, the engine can decode at once. Higher = more throughput, more wired memory."
        ) {
            SettingsStepperField(
                label: "Concurrent Sessions",
                help:
                    "Shared with Main Chat Spawn and every agent's Max subagents per batch. This is the BatchEngine ceiling for same-model local waves; RAM safety and current occupancy may run a smaller wave. 1 keeps the compile fast-path engaged; >1 allows concurrent decode when Continuous Batching is on.",
                text: $maxConcurrentText,
                range: SpawnBatchConcurrencyContract.bounds,
                step: 1,
                defaultValue: effectiveBatchEngineLimit
            )
            .onChange(of: maxConcurrentText) { _, _ in commitMaxConcurrent() }

            Text(effectiveBatchEngineSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            SettingsToggle(
                title: L("Continuous Batching"),
                description:
                    "When off, Osaurus pins each local model to one active job even if Concurrent Sessions is higher. Remote jobs can still overlap, and jobs targeting different local models remain serialized by model residency.",
                isOn: $draft.concurrency.continuousBatching
            )

            OptionalIntField(
                label: "Prompt Prefill Chunk Size",
                placeholder: "Empty = engine default",
                help: "How many prompt tokens are prefilled per step.",
                value: $draft.concurrency.prefillStepSize
            )

        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            syncFromDraft()
        }
        .onChange(of: draft.concurrency.maxConcurrentSequences) { _, _ in syncFromDraft() }
    }

    private func syncFromDraft() {
        // Empty is the persisted "automatic" state. The stepper placeholder
        // renders the same profile-resolved capacity BatchEngine receives
        // without materializing that automatic value as an explicit override.
        let desired = draft.concurrency.maxConcurrentSequences.map(String.init) ?? ""
        if maxConcurrentText != desired { maxConcurrentText = desired }
    }

    private func commitMaxConcurrent() {
        let trimmed = maxConcurrentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty is the documented Automatic state. Clearing an explicit
            // override must therefore restore nil instead of silently leaving
            // the prior engine ceiling active behind a blank field.
            if draft.concurrency.maxConcurrentSequences != nil {
                draft.concurrency.maxConcurrentSequences = nil
            }
            return
        }
        guard let parsed = Int(trimmed), parsed > 0 else { return }
        let clamped = SpawnBatchConcurrencyContract.normalized(parsed)

        if draft.concurrency.maxConcurrentSequences != clamped {
            draft.concurrency.maxConcurrentSequences = clamped
        }
    }

    private var effectiveBatchEngineSummary: String {
        if !draft.concurrency.continuousBatching {
            return
                "Effective BatchEngine limit: 1 — Continuous Batching is off."
        }
        if draft.memorySafety.customMaxConcurrentSequences != nil {
            return
                "Effective BatchEngine limit: \(effectiveBatchEngineLimit) — overridden by Memory Safety → Max Concurrent Sequences."
        }
        if draft.concurrency.maxConcurrentSequences != nil {
            return
                "Effective BatchEngine limit: \(effectiveBatchEngineLimit) — explicit Concurrent Sessions override."
        }
        let mode =
            draft.memorySafety.mode.rawValue
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        return
            "Effective BatchEngine limit: \(effectiveBatchEngineLimit) — automatic \(mode) Memory Safety profile."
    }
}
