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

    /// "10% of 3.7 TB ≈ 372 GB" — what the chosen share comes out to here.
    ///
    /// Resolved through `VMLXServerRuntimeSettings.resolveDiskCacheMaxGB`, the
    /// same function the engine uses to build `CacheCoordinatorConfig`. A
    /// second, independent estimate in the UI could disagree with the cap
    /// actually enforced, and the user would have no way to tell which was
    /// real. Nil when the volume cannot be measured — better to show nothing
    /// than a fabricated number.
    private var resolvedDiskCacheLabel: String? {
        let dir = ModelRuntime.cacheDiskDirectoryOverride(for: draft.cache)
            ?? OsaurusPaths.diskKVCache()
        guard let capacity = VMLXServerRuntimeSettings.cacheVolumeCapacityGB(for: dir) else {
            return nil
        }
        let resolved = VMLXServerRuntimeSettings.resolveDiskCacheMaxGB(
            percent: draft.cache.blockDisk.maxSizePercent,
            legacyGB: draft.cache.blockDisk.maxSizeGB,
            directory: dir)
        // The share the resolver will ACTUALLY use. A stored value of 0 (or
        // negative) is not honoured — `resolveDiskCacheMaxGB` requires
        // `percent > 0` and falls back to the default share — so echoing the
        // raw field would print "0% ... ≈ 372.2 GB", a label that contradicts
        // itself and hides which number is real.
        let stored = draft.cache.blockDisk.maxSizePercent
        let share =
            (stored.map { $0 > 0 } ?? false)
            ? stored! : (VMLXServerRuntimeSettings.autoDiskCacheFraction * 100)

        // Report what the engine will ACTUALLY enforce, not what the share
        // resolves to in isolation.
        //
        // `applyHostAwareDiskCacheCeiling` additionally bounds the cap to a
        // quarter of the free bytes at load, so a share is not the last word:
        // measured live, 10% of a 3.7 TB volume resolved to 372 GB but the
        // coordinator enforced 242 GB, because only 969 GB was free. A label
        // showing the unbounded number would over-promise by 130 GB and
        // disagree with the "Active" row a few lines below it.
        let effective: Double
        if let freeBytes = OsaurusPaths.volumeFreeBytes(forPath: dir.path), freeBytes > 0 {
            let decision = ModelRuntime.hostAwareDiskCacheDecision(
                configuredCapGB: resolved, freeBytes: freeBytes)
            effective = decision.enabled ? decision.capGB : 0
        } else {
            effective = resolved
        }

        if effective < resolved {
            // Say WHY it is lower, or a user who set 10% and sees a smaller
            // number reads it as the setting being ignored.
            return String(
                format: L("%@%% of %@ ≈ %@ (limited to %@ — disk is nearly full)"),
                String(format: "%g", share),
                DiskCacheUsage.format(bytes: Int(capacity * 1_073_741_824)),
                DiskCacheUsage.format(bytes: Int(resolved * 1_073_741_824)),
                DiskCacheUsage.format(bytes: Int(effective * 1_073_741_824)))
        }
        return String(
            format: L("%@%% of %@ ≈ %@"),
            String(format: "%g", share),
            DiskCacheUsage.format(bytes: Int(capacity * 1_073_741_824)),
            DiskCacheUsage.format(bytes: Int(resolved * 1_073_741_824)))
    }

    private var diskCacheControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsToggle(
                title: L("Disk Cache"),
                description:
                    "Persist content-addressed prompt checkpoints on SSD. Works with paged RAM cache off and restores the longest matching prefix after restart; turn off to disable disk reuse.",
                isOn: $draft.cache.blockDisk.enabled
            )
            // A PERCENT of the disk, not a byte count. KV size scales with the
            // model — a 27B stores ~256 KiB per token, so a 222k window needs
            // ~54 GB — which means one GB figure is simultaneously too small on
            // a 4 TB machine and too large on a 256 GB one. Shipping both units
            // just asked the user to reconcile them.
            OptionalDoubleField(
                label: "Disk Cache Size (% of disk)",
                placeholder: "Blank = 10%",
                help:
                    "Soft cap before older entries are evicted, shared across all models. "
                    + "A share of your disk rather than a fixed size, because cache size "
                    + "scales with the model: a 27B stores ~256 KiB per token, so a fixed "
                    + "cap that suits one machine starves another and long chats re-prefill "
                    + "instead of resuming.",
                value: $draft.cache.blockDisk.maxSizePercent,
                // NOT "%.1f". A share is meaningful far below a tenth of a
                // percent — 0.005% of a 3.7 TB disk is ~190 MB, a perfectly
                // reasonable cap for someone who wants the cache small — and
                // one decimal place silently rewrote it to 0.0 before saving.
                // The stored 0 then failed the resolver's `percent > 0` check
                // and fell back to the 10% auto share, so typing 0.005 handed
                // the user 372 GB while the label read "0%". Found by typing
                // it into the running app.
                format: "%g"
            )
            // What that share actually comes out to on THIS machine, using the
            // same resolver the engine enforces rather than a second estimate
            // that could disagree with it.
            if let resolved = resolvedDiskCacheLabel {
                Text(verbatim: resolved)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
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
