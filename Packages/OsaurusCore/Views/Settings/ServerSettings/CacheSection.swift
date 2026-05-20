//
//  CacheSection.swift
//  osaurus
//
//  Cache controls (prefix / paged KV / disk / codec / rotating-window /
//  SSM rederive) for the Server → Settings tab. Bridged end-to-end
//  through `settings.cacheCoordinatorConfig(...)` inside
//  `ModelRuntime.buildCacheCoordinatorConfig`.
//

@preconcurrency import MLXLMCommon
import SwiftUI

struct CacheSection: View {
    @Binding var draft: VMLXServerRuntimeSettings
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsSection(title: "Cache", icon: "externaldrive.connected.to.line.below") {
            VStack(alignment: .leading, spacing: 20) {
                ServerSettingsSectionStatus(
                    status: .engineReady,
                    blurb:
                        "Bridged through settings.cacheCoordinatorConfig(...) into BatchEngine. Auto defaults derive from the model's resolved cache topology."
                )

                SettingsToggle(
                    title: L("Prefix Cache"),
                    description: "Master switch. When off, paged KV and disk reuse are also disabled.",
                    isOn: $draft.cache.prefix.enabled
                )

                SettingsDivider()

                SettingsSubsection(label: "Paged KV (L1)") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsToggle(
                            title: L("Enable Paged KV"),
                            description: "Block-based KV cache in GPU memory.",
                            isOn: $draft.cache.pagedKV.enabled
                        )

                        OptionalIntField(
                            label: "Paged Block Size",
                            placeholder: "Empty = engine default (64)",
                            help: "Tokens per paged block.",
                            value: $draft.cache.pagedKV.blockSize
                        )

                        OptionalIntField(
                            label: "Max Paged Blocks",
                            placeholder: "Empty = engine default (1000)",
                            help: "Cap on total paged blocks across slots.",
                            value: $draft.cache.pagedKV.maxBlocks
                        )
                    }
                }

                SettingsDivider()

                SettingsSubsection(label: "Disk Cache (L2)") {
                    diskCacheControls
                }

                SettingsDivider()

                SettingsSubsection(label: "Live KV Codec") {
                    liveKVCodecControls
                }

                SettingsDivider()

                SettingsSubsection(label: "Rotating Window") {
                    VStack(alignment: .leading, spacing: 12) {
                        OptionalIntField(
                            label: "Default Max KV Size (tokens)",
                            placeholder: "Empty = engine default",
                            help: "Per-slot ring window. 65536 is the recommended default.",
                            value: $draft.cache.defaultMaxKVSize
                        )

                        OptionalDoubleField(
                            label: "Long Prompt Multiplier",
                            placeholder: "Default 2.0",
                            help: "Cap kicks in past defaultMaxKVSize × multiplier.",
                            value: longPromptBinding,
                            format: "%.2f"
                        )
                    }
                }

                SettingsDivider()

                SettingsToggle(
                    title: L("SSM Re-derive"),
                    description:
                        "Runs a post-generation SSM-state re-derive for hybrid Mamba/Arrays caches.",
                    isOn: $draft.cache.enableSSMReDerive
                )

                SettingsDivider()

                SettingsSubsection(label: "Planned Cache Controls") {
                    plannedControls
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var diskCacheControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if draft.cache.pagedKV.enabled {
                SettingsToggle(
                    title: L("Block Disk Cache"),
                    description: "Persists paged blocks to disk for cross-process reuse.",
                    isOn: $draft.cache.blockDisk.enabled
                )
                OptionalDoubleField(
                    label: "Block Disk Max Size (GB)",
                    placeholder: "Empty = engine default (10 GB)",
                    help: "Soft cap before eviction.",
                    value: $draft.cache.blockDisk.maxSizeGB,
                    format: "%.1f"
                )
            } else {
                SettingsToggle(
                    title: L("Legacy Disk Cache"),
                    description: "Falls back to legacy disk layout when paged KV is off.",
                    isOn: $draft.cache.legacyDisk.enabled
                )
                OptionalDoubleField(
                    label: "Legacy Disk Max Size (GB)",
                    placeholder: "Empty = engine default (10 GB)",
                    help: "Soft cap before eviction.",
                    value: $draft.cache.legacyDisk.maxSizeGB,
                    format: "%.1f"
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
                    "TurboQuant requires explicit key/value bit widths. Other modes use the engine default."
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
                blurb: "Persisted today; cacheCoordinatorConfig does not yet consume these."
            )

            SettingsToggle(
                title: L("Legacy Entry-Count Cache"),
                description: "Use the older entry-count prefix cache instead of the new heap cache.",
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
