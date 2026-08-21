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
    @Binding var metadataFallbackTokens: Int?
    let savedSettings: VMLXServerRuntimeSettings
    let savedMetadataFallbackTokens: Int?

    @State private var loadedModels: [ModelRuntime.ModelCacheSummary] = []
    @State private var isClearingDiskCache = false
    @State private var clearedCacheSummary: String?

    var body: some View {
        ServerSettingsCard(
            section: .cache,
            status: .engineReady,
            blurb:
                "One place for conversation limits, live KV retention, paged RAM, and SSD-backed prefix reuse. Model maximum and conversation budget are not KV-cache capacity."
        ) {
            SettingsSubsection(label: "Context & KV Policy") {
                contextAndKVPolicyControls
            }
            .settingsLandingAnchor("settings.chat.contextLength")

            SettingsDivider()

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
                            "Optional hot tier held in GPU memory. SSD cache can still restore prefixes across requests when this is off.",
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

            SettingsSubsection(label: "SSD Cache (L2)") {
                diskCacheControls
            }

            SettingsDivider()

            SettingsSubsection(label: "On-the-fly Compression") {
                liveKVCodecControls
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
        .task {
            while !Task.isCancelled {
                loadedModels = await ModelRuntime.shared.cachedModelSummaries()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Subviews

    private var contextAndKVPolicyControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            policyRow(
                label: "Model maximum",
                value: "Per selected model",
                detail:
                    "Read from the active model's bundle metadata and shown in that chat's Context Budget popover."
            )
            policyRow(
                label: "Usable conversation budget",
                value: "\(Int(ContextBudgetManager.safetyMargin * 100))% of model maximum",
                detail:
                    "The chat compactor reserves the remaining margin for token-estimation error. This is not the KV retention cap."
            )

            OptionalIntField(
                label: "Unknown-Model Metadata Fallback (tokens)",
                placeholder: "Default 128 000",
                help:
                    "Used only when a model/provider does not report a context maximum. Changing it applies to the next request; known local bundle metadata still wins.",
                value: $metadataFallbackTokens,
                clamp: 2_048 ... 4_194_304
            )

            OptionalIntField(
                label: "KV Retention Override (tokens)",
                placeholder: "Blank = Memory Safety profile",
                help:
                    "The one explicit per-session KV retention override. Blank lets Memory Safety resolve the cap. Saving a changed cap unloads resident models so their next load cannot retain stale coordinator settings.",
                value: $draft.cache.defaultMaxKVSize,
                clamp: 1_024 ... 4_194_304
            )

            OptionalDoubleField(
                label: "Long-Prompt Window Multiplier",
                placeholder: "Default 2.0",
                help:
                    "A blank request inherits the KV cap only after its prompt exceeds (resolved cap × multiplier).",
                value: longPromptBinding,
                format: "%.2f"
            )

            SettingsDivider()

            policyRow(
                label: "Saved metadata fallback",
                value: tokenSummary(savedMetadataFallbackTokens, defaultValue: 128_000),
                detail: "Currently persisted for unknown-metadata models."
            )
            policyRow(
                label: "Saved resolved KV cap",
                value: tokenSummary(savedResolvedKVCap),
                detail:
                    savedSettings.cache.defaultMaxKVSize == nil
                    ? "Resolved from the saved Memory Safety profile."
                    : "Resolved from the saved explicit Cache override."
            )

            if pendingResolvedKVCap != savedResolvedKVCap
                || metadataFallbackTokens != savedMetadataFallbackTokens
            {
                policyRow(
                    label: "Pending after Save",
                    value:
                        "fallback \(tokenSummary(metadataFallbackTokens, defaultValue: 128_000)); KV \(tokenSummary(pendingResolvedKVCap))",
                    detail:
                        "Unsaved draft. A KV-policy change unloads resident models; an unknown-model fallback change applies on the next request."
                )
            }

            if loadedModels.isEmpty {
                policyRow(
                    label: "Active loaded policy",
                    value: "No model loaded",
                    detail: "The next local model load will capture the saved resolved policy."
                )
            } else {
                ForEach(loadedModels, id: \.name) { model in
                    if let active = model.activeCachePolicy {
                        policyRow(
                            label: "Active · \(model.name)",
                            value:
                                "KV \(tokenSummary(active.maxKVSize)); RAM \(active.pagedRAMEnabled ? "on" : "off"); SSD \(active.diskL2Enabled ? diskSizeSummary(active.diskL2MaxGB) : "off")",
                            detail:
                                "Live coordinator captured at this model's last load. It is intentionally not inferred from the saved draft."
                        )
                    }
                }
            }
        }
    }

    private var diskCacheControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsToggle(
                title: L("Disk Cache"),
                description:
                    "Persist content-addressed prompt checkpoints on SSD. Works with paged RAM cache off and restores the longest matching prefix after restart; turn off to disable disk reuse.",
                isOn: $draft.cache.blockDisk.enabled
            )
            OptionalDoubleField(
                label: "Disk Cache Size (GB)",
                placeholder: "Blank = Auto (10% of disk)",
                help:
                    "Soft cap before older entries are evicted, shared across all models. "
                    + "Auto scales with your disk because KV size scales with the model: a "
                    + "27B stores ~256 KiB per token, so a fixed cap that suits one machine "
                    + "starves another and long chats re-prefill instead of resuming.",
                value: $draft.cache.blockDisk.maxSizeGB,
                format: "%.1f"
            )
            HStack(spacing: 10) {
                Button {
                    Task {
                        isClearingDiskCache = true
                        let result = await ModelRuntime.shared.clearDiskCaches()
                        clearedCacheSummary =
                            result.reclaimedBytes > 0
                            ? String(
                                format: L("Cleared %@"),
                                DiskCacheUsage.format(bytes: result.reclaimedBytes))
                            : L("Cache was already empty")
                        isClearingDiskCache = false
                    }
                } label: {
                    if isClearingDiskCache {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Clear SSD Cache", bundle: .module)
                    }
                }
                .disabled(isClearingDiskCache)
                if let clearedCacheSummary {
                    Text(verbatim: clearedCacheSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(
                "Deletes all saved conversation data from disk, including leftover files from an interrupted write. Your chats are not affected — the next reply just takes a little longer to start.",
                bundle: .module
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            OptionalStringField(
                label: "Disk Cache Directory",
                placeholder: "Blank = Osaurus default cache directory",
                help: "Absolute path or ~/... path for persisted disk-cache entries.",
                value: $draft.cache.blockDisk.directory
            )
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

    private var savedResolvedKVCap: Int? {
        ServerRuntimeSettingsStore.resolvedKVRetentionCap(for: savedSettings)
    }

    private var pendingResolvedKVCap: Int? {
        ServerRuntimeSettingsStore.resolvedKVRetentionCap(for: draft)
    }

    private func tokenSummary(_ value: Int?, defaultValue: Int? = nil) -> String {
        if let value { return value.formatted() + " tokens" }
        if let defaultValue { return defaultValue.formatted() + " tokens (default)" }
        return "Unlimited"
    }

    private func diskSizeSummary(_ gigabytes: Double) -> String {
        String(format: "%.1f GB", gigabytes)
    }

    private func policyRow(label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(LocalizedStringKey(label), bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            Text(LocalizedStringKey(detail), bundle: .module)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
