//
//  ConcurrencySection.swift
//  osaurus
//
//  Concurrency & batching controls. `continuousBatching` gates the
//  multi-slot scheduler, `maxConcurrentSequences` hot-resizes the resident
//  BatchEngine, and `prefillStepSize` is passed per request. The remaining
//  contract fields persist for a follow-up runtime bridge.
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

    var body: some View {
        ServerSettingsCard(
            section: .concurrency,
            status: .engineReady,
            blurb:
                "How many requests the engine can decode at once. Higher = more throughput, more wired memory."
        ) {
            SettingsStepperField(
                label: "Concurrent Sessions",
                help:
                    "BatchEngine max batch size. 1 keeps the compile fast-path engaged; >1 enables continuous batching.",
                text: $maxConcurrentText,
                range: 1 ... 32,
                step: 1,
                defaultValue: 1
            )
            .onChange(of: maxConcurrentText) { _, _ in commitMaxConcurrent() }

            SettingsToggle(
                title: L("Continuous Batching"),
                description:
                    "When off, Osaurus pins the BatchEngine to one active slot even if Concurrent Sessions is higher.",
                isOn: $draft.concurrency.continuousBatching
            )

            OptionalIntField(
                label: "Prompt Prefill Chunk Size",
                placeholder: "Empty = engine default",
                help: "How many prompt tokens are prefilled per step.",
                value: $draft.concurrency.prefillStepSize
            )

            SettingsDivider()

            SettingsSubsection(label: "Planned Batching Controls") {
                VStack(alignment: .leading, spacing: 12) {
                    ServerSettingsPlannedBanner(
                        blurb: "Persisted today; runtime consumers for these fields are not yet implemented."
                    )

                    OptionalIntField(
                        label: "Prefill Batch Size",
                        placeholder: "Empty = engine default",
                        help: "Number of prefill chunks decoded together.",
                        value: $draft.concurrency.prefillBatchSize
                    )

                    OptionalIntField(
                        label: "Completion Batch Size",
                        placeholder: "Empty = engine default",
                        help: "Number of decode steps run together.",
                        value: $draft.concurrency.completionBatchSize
                    )

                    SettingsField(
                        label: "SMELT Mode",
                        hint: "Selects the SMELT execution mode when supported by the model."
                    ) {
                        Picker("", selection: $draft.concurrency.smeltMode) {
                            ForEach(VMLXServerSmeltMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            syncFromDraft()
        }
        .onChange(of: draft.concurrency.maxConcurrentSequences) { _, _ in syncFromDraft() }
    }

    private func syncFromDraft() {
        let desired = draft.concurrency.maxConcurrentSequences.map(String.init) ?? "1"
        if maxConcurrentText != desired { maxConcurrentText = desired }
    }

    private func commitMaxConcurrent() {
        let trimmed = maxConcurrentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed), parsed > 0 else { return }
        let clamped = min(parsed, 32)
        if draft.concurrency.maxConcurrentSequences != clamped {
            draft.concurrency.maxConcurrentSequences = clamped
        }
    }
}
