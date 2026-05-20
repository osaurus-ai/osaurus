//
//  GenerationDefaultsSection.swift
//  osaurus
//
//  Sampling Defaults (temperature/topP/topK/minP/repetitionPenalty/
//  maxTokens/streamInterval) for the Server → Settings tab. Bridged
//  through `MLXBatchAdapter.effectiveGenerationSettings` so per-request
//  overrides still win.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct GenerationDefaultsSection: View {
    @Binding var draft: VMLXServerRuntimeSettings

    var body: some View {
        ServerSettingsCard(
            section: .sampling,
            status: .engineReady,
            blurb:
                "Used when a request doesn't specify these. Leave blank to honor the model's own defaults."
        ) {
            OptionalDoubleField(
                label: "Temperature",
                placeholder: "Blank = model default",
                help: "Lower = focused. Higher = creative. 0 picks the single most-likely token.",
                value: $draft.generation.temperature,
                clamp: 0 ... 2
            )

            OptionalDoubleField(
                label: "Top-P (Nucleus)",
                placeholder: "Blank = model default",
                help: "Pick from the smallest set of tokens whose probabilities sum to P.",
                value: $draft.generation.topP,
                clamp: 0 ... 1
            )

            OptionalIntField(
                label: "Top-K",
                placeholder: "Blank = model default; 0 = disabled",
                help: "Only consider the K most-likely tokens per step.",
                value: $draft.generation.topK
            )

            OptionalDoubleField(
                label: "Min-P",
                placeholder: "Blank = model default",
                help: "Drop tokens less likely than P × the top token.",
                value: $draft.generation.minP,
                clamp: 0 ... 1
            )

            OptionalDoubleField(
                label: "Repetition Penalty",
                placeholder: "Blank = model default",
                help: "Discourage repeats. 1.0 = off; ~1.05–1.15 is typical.",
                value: $draft.generation.repetitionPenalty,
                clamp: 0.01 ... 5
            )

            OptionalIntField(
                label: "Max Tokens",
                placeholder: "Blank = model default",
                help: "Cap the response length per request.",
                value: $draft.generation.maxTokens
            )

            SettingsDivider()

            SettingsSubsection(label: "Streaming") {
                VStack(alignment: .leading, spacing: 8) {
                    ServerSettingsPlannedBanner(
                        blurb:
                            "Validated today; the streaming coalescer bridge ships in a follow-up."
                    )
                    OptionalIntField(
                        label: "Tokens Per Chunk",
                        placeholder: "1 = emit on every token",
                        help: "Batch this many tokens before sending an SSE chunk to the client.",
                        value: $draft.generation.streamInterval
                    )
                }
            }
        }
    }
}
