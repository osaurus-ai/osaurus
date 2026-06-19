//
//  DecodePerformanceSection.swift
//  osaurus
//
//  User-facing controls for `VMLXServerRuntimeSettings.performance`:
//  the tied-LM-head load codec and the experimental compiled decode
//  toggle. Both act through `ModelRuntime.applyPerformancePolicy(_:)`
//  on the next model load; compiled decode additionally flows through
//  `makeGenerateParameters` per request.
//
//  Measured context (M5 Max, Gemma 4 E2B QAT, greedy, 2026-06-12):
//  fp16 head 120.1 tok/s -> q6 head 132.5 -> + compiled decode 165.3,
//  vs the documented llama.cpp GGUF decode baseline of 173.7 tok/s.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct DecodePerformanceSection: View {
    @Binding var draft: VMLXServerRuntimeSettings

    private var performanceBinding: Binding<VMLXServerPerformanceSettings> {
        Binding(
            get: { draft.effectivePerformance },
            set: { draft.performance = $0 }
        )
    }

    var body: some View {
        ServerSettingsCard(
            section: .decodePerformance,
            status: .engineReady,
            blurb:
                "Decode-throughput options for local vMLX models. Changes apply on the next model load."
        ) {
            SettingsField(
                label: "Tied LM Head Codec",
                hint:
                    "Quantizes a tied output head that ships unquantized inside an otherwise-quantized bundle (e.g. Gemma 4 QAT's fp16 262k-vocab head, ~1 GB read per decoded token on E2B). q6 matches the precision class of llama.cpp's GGUF Q6_K output head. Never alters heads the bundle ships pre-quantized, and never applies to full-precision bundles."
            ) {
                Picker("", selection: performanceBinding.tiedHeadCodec) {
                    ForEach(VMLXTiedHeadCodec.allCases, id: \.self) { codec in
                        Text(codecTitle(codec)).tag(codec)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            SettingsField(
                label: "Compiled Decode (Experimental)",
                hint:
                    "Fuses the per-token decode graph with MLX compile (+25% measured on Gemma 4 QAT). Takes effect after restarting Osaurus — MLX fixes its compile state at the first model load of the process, so toggling this mid-session cannot turn it on/off live (the setting is saved and applies on next launch). Experimental: kept off by default until the historical model-switch corruption (PR #1173) is root-caused. If model switching misbehaves with this on, turn it off and restart."
            ) {
                Toggle("", isOn: performanceBinding.compiledDecode)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    private func codecTitle(_ codec: VMLXTiedHeadCodec) -> String {
        switch codec {
        case .fp16Passthrough: return L("As shipped (fp16 passthrough)")
        case .q8: return L("8-bit (q8, conservative)")
        case .q6: return L("6-bit (q6, GGUF-head parity)")
        case .q4: return L("4-bit (q4, fastest)")
        }
    }
}
