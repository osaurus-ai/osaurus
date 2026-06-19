//
//  MemorySafetySection.swift
//  osaurus
//
//  User-facing controls for the vMLX memory-safety policy. These
//  controls persist into `VMLXServerRuntimeSettings.memorySafety` and
//  take effect through `ModelRuntime.resolveMemorySafetyLoadPlan(...)`
//  on the next model load.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct MemorySafetySection: View {
    @Binding var draft: VMLXServerRuntimeSettings

    private var resolvedPlan: VMLXResolvedMemorySafetyPlan {
        draft.resolvedMemorySafetyPlan(
            baseLoadConfiguration: .osaurusProduction,
            host: MemoryStatus.snapshot()
        )
    }

    var body: some View {
        ServerSettingsCard(
            section: .memorySafety,
            status: .engineReady,
            blurb:
                "Controls the load-time memory policy used by local vMLX models. Changes apply on the next model load."
        ) {
            SettingsField(
                label: "Mode",
                hint:
                    "Safe Auto is the default. Strict can refuse before load when a request cannot fit the selected budget."
            ) {
                Picker("", selection: $draft.memorySafety.mode) {
                    ForEach(VMLXMemorySafetyMode.allCases, id: \.self) { mode in
                        Text(modeTitle(mode)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            SettingsField(
                label: "Safety Level",
                hint:
                    "0 favors performance, 2 is Safe Auto, 3 is strict, and 4 is diagnostic/custom."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Slider(value: sliderBinding, in: 0 ... 4, step: 1)
                    Text(sliderLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsDivider()

            SettingsSubsection(label: "Resolved Plan") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(resolvedPlan.displaySummary)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)

                    HStack(spacing: 12) {
                        summaryPill(L("Load"), value: loadCapSummary)
                        summaryPill(L("Allocator"), value: allocatorCapSummary)
                        summaryPill(L("KV"), value: kvCapSummary)
                        summaryPill(L("Concurrency"), value: concurrencySummary)
                    }

                    ForEach(resolvedPlan.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsDivider()

            SettingsSubsection(label: "Advanced Overrides") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggle(
                        title: L("Allow Experimental MLXPress"),
                        description:
                            "Only routed bundles with proven support should use this. It is never enabled by default.",
                        isOn: $draft.memorySafety.allowExperimentalMLXPress
                    )

                    SettingsToggle(
                        title: L("Fail Closed When Estimate Is Unknown"),
                        description:
                            "Strict diagnostic behavior for environments that prefer refusal over unknown memory risk.",
                        isOn: $draft.memorySafety.failClosedWhenEstimateUnknown
                    )

                    OptionalDoubleField(
                        label: "Custom Physical Memory Fraction",
                        placeholder: "Blank = mode default",
                        help: "Fraction from 0.10 to 1.00.",
                        value: $draft.memorySafety.customPhysicalMemoryFraction,
                        clamp: 0.10 ... 1.00,
                        format: "%.2f"
                    )

                    OptionalIntField(
                        label: "Allocator Cache Cap (MB)",
                        placeholder: "Blank = mode default",
                        help: "Maximum MLX allocator cache, in MiB.",
                        value: allocatorCacheMB,
                        clamp: 1 ... 262144
                    )

                    OptionalIntField(
                        label: "Per-Session KV Cap (tokens)",
                        placeholder: "Blank = mode default",
                        help: "Maximum cached tokens per chat slot for this memory mode.",
                        value: $draft.memorySafety.customDefaultMaxKVSize
                    )

                    OptionalIntField(
                        label: "Max Concurrent Sequences",
                        placeholder: "Blank = mode default",
                        help: "Upper bound for concurrent decode slots under this memory mode.",
                        value: $draft.memorySafety.customMaxConcurrentSequences,
                        clamp: 1 ... 32
                    )
                }
            }
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(draft.memorySafety.slider) },
            set: { newValue in
                draft.memorySafety.slider = Int(newValue.rounded()).clamped(to: 0 ... 4)
            }
        )
    }

    private var allocatorCacheMB: Binding<Int?> {
        Binding(
            get: {
                draft.memorySafety.customAllocatorCacheBytes.map {
                    Int($0 / UInt64(1 << 20))
                }
            },
            set: { newValue in
                guard let newValue else {
                    draft.memorySafety.customAllocatorCacheBytes = nil
                    return
                }
                draft.memorySafety.customAllocatorCacheBytes = UInt64(max(1, newValue)) * UInt64(1 << 20)
            }
        )
    }

    private var sliderLabel: String {
        switch draft.memorySafety.slider {
        case 0: return L("Performance")
        case 1: return L("Balanced")
        case 2: return L("Safe Auto")
        case 3: return L("Strict")
        default: return L("Diagnostic / Custom")
        }
    }

    private var loadCapSummary: String {
        capSummary(resolvedPlan.loadConfiguration.memoryLimit)
    }

    private var allocatorCapSummary: String {
        capSummary(resolvedPlan.loadConfiguration.maxResidentBytes)
    }

    private var kvCapSummary: String {
        resolvedPlan.cache.defaultMaxKVSize.map(String.init) ?? "default"
    }

    private var concurrencySummary: String {
        resolvedPlan.concurrency.maxConcurrentSequences.map(String.init) ?? "default"
    }

    private func summaryPill(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func capSummary(_ cap: ResidentCap) -> String {
        switch cap {
        case .unlimited:
            return "unlimited"
        case .fraction(let fraction):
            return String(format: "%.0f%%", fraction * 100)
        case .absolute(let bytes):
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        }
    }

    private func modeTitle(_ mode: VMLXMemorySafetyMode) -> String {
        switch mode {
        case .performance: return "Performance"
        case .balanced: return "Balanced"
        case .safeAuto: return "Safe Auto"
        case .strict: return "Strict"
        case .diagnosticDangerous: return "Diagnostic / Dangerous"
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
