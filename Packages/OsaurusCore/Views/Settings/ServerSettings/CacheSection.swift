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
    @Binding var contextLengthCap: Int?
    let savedSettings: VMLXServerRuntimeSettings
    let savedMetadataFallbackTokens: Int?
    let savedContextLengthCap: Int?

    @State private var loadedModels: [ModelRuntime.ModelCacheSummary] = []
    @State private var isClearingDiskCache = false
    @State private var clearedCacheSummary: String?
    @AppStorage(DiskCacheQuotaNoticeSuppression.defaultsKey) private var ssdNoticesSuppressed = false

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
            .settingsLandingAnchor("settings.server.contextMetadataFallback")

            // The fallback above cannot constrain a local bundle — metadata
            // wins. This is the field that actually lowers the window, so it
            // needs its own control or the user has no way to reach it.
            OptionalIntField(
                label: "Context Window Cap (tokens)",
                placeholder: "Blank = follow the model",
                help:
                    "Applied as min(cap, model maximum), so it can only ever LOWER the window — a smaller window prefills faster and costs less KV per turn. Unlike the fallback above, this DOES constrain local bundles.",
                value: $contextLengthCap,
                clamp: 2_048 ... 4_194_304
            )
            .settingsLandingAnchor("settings.chat.contextLength")

            OptionalIntField(
                label: "KV Retention Override (tokens)",
                placeholder: "Blank = Memory Safety profile",
                help:
                    "The one explicit per-session KV retention override. Blank lets Memory Safety resolve the cap. Saving a changed cap unloads resident models so their next load cannot retain stale coordinator settings.",
                value: $draft.cache.defaultMaxKVSize,
                clamp: 1_024 ... 4_194_304
            )
            .settingsLandingAnchor("settings.server.kvRetention")

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
                label: "Saved context window cap",
                value: savedContextLengthCap.map { "\($0) tokens" } ?? "Follow the model",
                detail: savedContextLengthCap == nil
                    ? "No cap saved — each model uses its own declared maximum."
                    : "Lowers every model whose maximum exceeds it."
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
                                "Live coordinator policy, including saved disk-size changes. It is not inferred from the unsaved draft."
                        )
                    }
                }
            }
        }
    }

    private var resolvedDiskCacheLabel: String {
        let directory = ModelRuntime.diskCacheDirectoryForDisplay(for: draft.cache)
        let result = ModelRuntime.diskCacheCap(for: draft.cache, directory: directory)
        let effective = DiskCacheUsage.format(bytes: Int(clamping: result.capBytes))
        let requested = DiskCacheUsage.format(bytes: Int(clamping: result.requestedBytes))
        let label: String
        switch result.rule {
        case .automatic:
            label = String(format: L("Automatic: %@ (30%% of free space plus this cache)"), effective)
        case .explicitPercent:
            label = String(format: L("%@%% of disk: %@ effective"), String(format: "%g", draft.cache.blockDisk.maxSizePercent ?? 0), effective)
        case .legacyGB:
            label = String(format: L("Saved legacy size: %@ effective"), effective)
        case .unknownVolume:
            label = String(format: L("Disk measurement unavailable: %@ fallback"), effective)
        }
        let limit = result.limitedByHost
            ? String(format: L("Requested %@; limited to 25%% of free space plus this cache."), requested) : ""
        let warning = result.lowFreeSpace && ModelRuntime.cacheDiskDirectoryOverride(for: draft.cache) != nil ? L("Disk space is low. SSD caching remains enabled.") : ""
        return [label, limit, warning].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var diskCachePercentBinding: Binding<Double?> {
        Binding(
            get: { draft.cache.blockDisk.maxSizePercent },
            set: {
                draft.cache.blockDisk.maxSizePercent = $0
                // Explicitly editing this control supersedes a saved legacy GB choice.
                draft.cache.blockDisk.maxSizeGB = nil
                draft.cache.legacyDisk.maxSizeGB = nil
            }
        )
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
                label: "Disk Cache Size (% of disk)",
                placeholder: "Blank = Automatic (30% of available space)",
                help: "Automatic uses 30% of free space plus this cache's own bytes. An explicit percentage uses total disk size, bounded by 25% of free space plus this cache. Saving a size change updates loaded models without unloading them; a lower cap is enforced on the next cache write.",
                value: diskCachePercentBinding,
                format: "%g"
            )
            .settingsLandingAnchor("settings.server.diskCacheSize")
            Text(verbatim: resolvedDiskCacheLabel)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            HStack(spacing: 10) {
                Button {
                    Task {
                        isClearingDiskCache = true
                        let result = await ModelRuntime.shared.clearDiskCaches()
                        clearedCacheSummary =
                            result.error
                            ?? (result.reclaimedBytes > 0
                                ? String(
                                    format: L("Cleared %@"),
                                    DiskCacheUsage.format(bytes: result.reclaimedBytes)
                                )
                                : L("Cache was already empty"))
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
                .accessibilityLabel(Text("Clear SSD Cache", bundle: .module))
                if let clearedCacheSummary {
                    Text(verbatim: clearedCacheSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(
                "Clears indexed conversation cache files. Chats and models are not deleted. Unrecognized files are left untouched; future replies may rebuild a cold cache.",
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

            SettingsToggle(
                title: L("Show SSD Cache Capacity Notices"),
                description: "Show one notice per chat per app launch when its latest saved progress exceeds the SSD cache limit. Changes apply immediately.",
                isOn: Binding(
                    get: { !ssdNoticesSuppressed },
                    set: { ssdNoticesSuppressed = !$0 }
                )
            )
            .settingsLandingAnchor("settings.server.diskCacheNotices")
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
