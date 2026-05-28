//
//  CacheSection.swift
//  osaurus
//
//  Cache controls (prefix / paged KV / disk / codec / per-session
//  window / SSM rederive) for the Server → Settings tab. Bridged
//  end-to-end through `settings.cacheCoordinatorConfig(...)` inside
//  `ModelRuntime.buildCacheCoordinatorConfig`.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct CacheSection: View {
    @Binding var draft: VMLXServerRuntimeSettings

    var body: some View {
        ServerSettingsCard(
            section: .cache,
            status: .engineReady,
            blurb:
                "Reuses previously-computed prompt prefixes so the second turn of a conversation starts faster than the first."
        ) {
            SettingsToggle(
                title: L("Prefix Cache"),
                description:
                    "Reuse cached prompt prefixes across requests for faster TTFT. When off, GPU and disk reuse are also disabled.",
                isOn: $draft.cache.prefix.enabled
            )

            SettingsDivider()

            SettingsSubsection(label: "GPU Cache (Paged KV)") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggle(
                        title: L("Enable GPU Cache"),
                        description:
                            "Block-based KV cache held in GPU memory. Required for cross-request sharing.",
                        isOn: $draft.cache.pagedKV.enabled
                    )

                    OptionalIntField(
                        label: "Block Size (tokens)",
                        placeholder: "Blank = engine default (64)",
                        help: "Tokens per paged block.",
                        value: $draft.cache.pagedKV.blockSize
                    )

                    OptionalIntField(
                        label: "Max Blocks",
                        placeholder: "Blank = engine default (1000)",
                        help: "Upper bound on GPU cache memory.",
                        value: $draft.cache.pagedKV.maxBlocks
                    )
                }
            }

            SettingsDivider()

            SettingsSubsection(label: "Disk Spillover") {
                diskCacheControls
            }

            SettingsDivider()

            SettingsSubsection(label: "On-the-fly Compression") {
                liveKVCodecControls
            }

            SettingsDivider()

            SettingsSubsection(label: "Per-Session Window Cap") {
                VStack(alignment: .leading, spacing: 12) {
                    OptionalIntField(
                        label: "Per-Session Window (tokens)",
                        placeholder: "Blank = engine default",
                        help:
                            "Maximum cached tokens per chat slot. 65 536 is the recommended default.",
                        value: $draft.cache.defaultMaxKVSize
                    )

                    OptionalDoubleField(
                        label: "Long-Prompt Window Multiplier",
                        placeholder: "Default 2.0",
                        help:
                            "Allow prompts up to (window × multiplier) before the cap kicks in.",
                        value: longPromptBinding,
                        format: "%.2f"
                    )
                }
            }

            SettingsDivider()

            SettingsToggle(
                title: L("Re-derive SSM State After Generation"),
                description:
                    "Hybrid Mamba models only. On by default so SSM companion state can be restored with prefix/L2 cache hits.",
                isOn: $draft.cache.enableSSMReDerive
            )

            SettingsDivider()

            SettingsSubsection(label: "Planned Cache Controls") {
                plannedControls
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var diskCacheControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if draft.cache.pagedKV.enabled {
                SettingsToggle(
                    title: L("Disk Cache"),
                    description:
                        "Spill paged blocks to disk so cache survives restarts and shares across processes.",
                    isOn: $draft.cache.blockDisk.enabled
                )
                OptionalDoubleField(
                    label: "Disk Cache Size (GB)",
                    placeholder: "Blank = engine default (10 GB)",
                    help: "Soft cap before older entries are evicted.",
                    value: $draft.cache.blockDisk.maxSizeGB,
                    format: "%.1f"
                )
                OptionalStringField(
                    label: "Disk Cache Directory",
                    placeholder: "Blank = Osaurus default cache directory",
                    help: "Absolute path or ~/... path for persisted block-cache entries.",
                    value: $draft.cache.blockDisk.directory
                )
            } else {
                SettingsToggle(
                    title: L("Legacy Disk Cache"),
                    description: "Used when the GPU paged cache is off.",
                    isOn: $draft.cache.legacyDisk.enabled
                )
                OptionalDoubleField(
                    label: "Disk Cache Size (GB)",
                    placeholder: "Blank = engine default (10 GB)",
                    help: "Soft cap before older entries are evicted.",
                    value: $draft.cache.legacyDisk.maxSizeGB,
                    format: "%.1f"
                )
                OptionalStringField(
                    label: "Legacy Disk Cache Directory",
                    placeholder: "Blank = Osaurus default cache directory",
                    help: "Absolute path or ~/... path for legacy disk-cache entries.",
                    value: $draft.cache.legacyDisk.directory
                )
            }
        }
    }

    @ViewBuilder
    private var liveKVCodecControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsField(
                label: "Codec",
                hint:
                    "Compress KV cache entries in memory. TurboQuant trades quality for footprint and needs explicit bit widths."
            ) {
                Picker("", selection: $draft.cache.liveKVCodec) {
                    ForEach(VMLXKVCacheCodec.allCases, id: \.self) { codec in
                        Text(codec.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                            .tag(codec)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if draft.cache.liveKVCodec == .turboQuant {
                OptionalIntField(
                    label: "TurboQuant Key Bits (2–8)",
                    placeholder: "Required",
                    help: "Quantization bit width for the key cache.",
                    value: $draft.cache.turboQuantKeyBits,
                    clamp: 2 ... 8
                )

                OptionalIntField(
                    label: "TurboQuant Value Bits (2–8)",
                    placeholder: "Required",
                    help: "Quantization bit width for the value cache.",
                    value: $draft.cache.turboQuantValueBits,
                    clamp: 2 ... 8
                )
            }
        }
    }

    @ViewBuilder
    private var plannedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ServerSettingsPlannedBanner(
                blurb:
                    "Persisted today; the cache coordinator does not yet consume these. Ships in a follow-up."
            )

            SettingsToggle(
                title: L("Legacy Entry-Count Cache"),
                description:
                    "Use the older entry-count prefix cache instead of the new heap-based one.",
                isOn: $draft.cache.prefix.legacyEntryCountCache
            )

            SettingsField(
                label: "Stored KV Codec",
                hint: "Codec used when serializing KV blocks to disk."
            ) {
                Picker("", selection: $draft.cache.storedKVCodec) {
                    ForEach(VMLXStoredKVCacheCodec.allCases, id: \.self) { codec in
                        Text(codec.rawValue.capitalized).tag(codec)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    // MARK: - Helpers

    /// `longPromptMultiplier` is a non-optional `Double` on the cache
    /// struct but the shared text-field helper needs `Binding<Double?>`.
    /// We wrap it so empty input collapses to the engine default
    /// (`2.0`) rather than zero.
    private var longPromptBinding: Binding<Double?> {
        Binding(
            get: { draft.cache.longPromptMultiplier },
            set: { newValue in
                let value = newValue ?? 2.0
                guard value > 0 else { return }
                draft.cache.longPromptMultiplier = value
            }
        )
    }
}
