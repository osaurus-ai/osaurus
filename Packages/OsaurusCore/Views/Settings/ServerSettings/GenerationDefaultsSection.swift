//
//  GenerationDefaultsSection.swift
//  osaurus
//
//  Generation defaults (temperature/topP/topK/minP/repetitionPenalty/
//  maxTokens/streamInterval) for the Server → Settings tab. Bridged
//  through `MLXBatchAdapter.effectiveGenerationSettings` so per-request
//  overrides still win.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct GenerationDefaultsSection: View {
    @Binding var draft: VMLXServerRuntimeSettings
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsSection(title: "Generation Defaults", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 20) {
                ServerSettingsSectionStatus(
                    status: .engineReady,
                    blurb:
                        "Per-request values override these. Leave blank to use the model's generation_config defaults."
                )

                OptionalDoubleField(
                    label: "Temperature",
                    placeholder: "Empty = model default",
                    help: "Sampling temperature. 0 disables sampling.",
                    value: $draft.generation.temperature,
                    clamp: 0 ... 2
                )

                OptionalDoubleField(
                    label: "Top-P",
                    placeholder: "Empty = model default",
                    help: "Nucleus sampling cutoff (0–1).",
                    value: $draft.generation.topP,
                    clamp: 0 ... 1
                )

                OptionalIntField(
                    label: "Top-K",
                    placeholder: "Empty = model default; 0 = disabled",
                    help: "Top-K sampling cutoff.",
                    value: $draft.generation.topK
                )

                OptionalDoubleField(
                    label: "Min-P",
                    placeholder: "Empty = model default",
                    help: "Min-P sampling threshold (0–1).",
                    value: $draft.generation.minP,
                    clamp: 0 ... 1
                )

                OptionalDoubleField(
                    label: "Repetition Penalty",
                    placeholder: "Empty = model default",
                    help: "Multiplier on repeated tokens. Must be positive.",
                    value: $draft.generation.repetitionPenalty,
                    clamp: 0.01 ... 5
                )

                OptionalIntField(
                    label: "Max Tokens",
                    placeholder: "Empty = model default",
                    help: "Hard cap on generated tokens per request.",
                    value: $draft.generation.maxTokens
                )

                SettingsDivider()

                SettingsSubsection(label: "Streaming") {
                    VStack(alignment: .leading, spacing: 8) {
                        ServerSettingsPlannedBanner(
                            blurb: "Validated today; the streaming coalescer bridge is a follow-up."
                        )
                        OptionalIntField(
                            label: "Stream Interval (tokens)",
                            placeholder: "1 = emit on every token",
                            help: "Coalesce N tokens before emitting an SSE chunk.",
                            value: $draft.generation.streamInterval
                        )
                    }
                }
            }
        }
    }
}
