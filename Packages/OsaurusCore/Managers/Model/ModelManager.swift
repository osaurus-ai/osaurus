//
//  ModelManager.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Combine
import Foundation
import MLXLLM
import SwiftUI

extension Notification.Name {
    /// Posted when local model list changes (download completed, model deleted)
    static let localModelsChanged = Notification.Name("localModelsChanged")
}

enum ModelListTab: String, CaseIterable, AnimatedTabItem {
    /// All available models rendered as two sections (Recommended + Others)
    case all = "All"

    /// Only models downloaded locally (includes active downloads)
    case downloaded = "Downloads"

    /// Display name for the tab (required by AnimatedTabItem)
    var title: String {
        switch self {
        case .all: return L("All")
        case .downloaded: return L("Downloads")
        }
    }
}

/// Manages MLX model catalog, discovery, and resolution.
/// Download orchestration is handled by ModelDownloadService.
@MainActor
final class ModelManager: NSObject, ObservableObject {
    static let shared = ModelManager()

    let downloadService = ModelDownloadService.shared

    /// State for filtering the model list
    struct ModelFilterState: Equatable {
        enum ModelTypeFilter: Equatable {
            case all, llm, vlm

            var isVLM: Bool { self == .vlm }
            var isLLM: Bool { self == .llm }
        }

        var typeFilter: ModelTypeFilter = .all
        var sizeCategory: SizeCategory? = nil
        var family: String? = nil
        var paramCategory: ParamCategory? = nil
        var performance: PerformanceFilter? = nil

        enum SizeCategory: String, CaseIterable, Identifiable {
            case small = "Small (<2 GB)"
            case medium = "Medium (2-4 GB)"
            case large = "Large (4 GB+)"
            var id: String { rawValue }

            var displayName: String {
                switch self {
                case .small: return L("Small (<2 GB)")
                case .medium: return L("Medium (2-4 GB)")
                case .large: return L("Large (4 GB+)")
                }
            }

            func matches(bytes: Int64?) -> Bool {
                guard let bytes = bytes else { return false }
                let gb = Double(bytes) / (1024 * 1024 * 1024)
                switch self {
                case .small: return gb < 2.0
                case .medium: return gb >= 2.0 && gb < 4.0
                case .large: return gb >= 4.0
                }
            }
        }

        enum ParamCategory: String, CaseIterable, Identifiable {
            case small = "<1B"
            case medium = "1-3B"
            case large = "3B+"
            var id: String { rawValue }

            func matches(billions: Double?) -> Bool {
                guard let b = billions else { return false }
                switch self {
                case .small: return b < 1.0
                case .medium: return b >= 1.0 && b <= 3.0
                case .large: return b > 3.0
                }
            }
        }

        /// Filters the list by `MLXModel.compatibility(totalMemoryGB:)` —
        /// the same hardware-fit assessment used for the per-row
        /// "Runs Well / Tight Fit / Too Large" badges. Exposes the
        /// already-computed attribute rather than introducing a new one.
        /// When `totalMemoryGB == 0` (monitor hasn't reported yet) this
        /// filter is treated as a no-op so the list isn't emptied during
        /// startup — `compatibility` returns `.unknown` without the
        /// hardware info and we let everything through until we know.
        enum PerformanceFilter: String, CaseIterable, Identifiable {
            /// Only include models whose `compatibility` is `.compatible`
            /// (memory usage below the 75 % ratio threshold).
            case runsWell = "Runs Well"
            /// Only include models whose `compatibility` is `.tight`
            /// (memory usage between 75 % and 95 % of total RAM)
            case tightFit = "Tight Fit"
            /// Exclude models whose `compatibility` is `.tooLarge`
            /// (memory usage above the 95 % ratio threshold). Models with
            /// unknown memory info pass through unchanged
            case hideTooLarge = "Hide Too Large"

            var id: String { rawValue }

            var displayName: String {
                switch self {
                case .runsWell: return L("Runs Well")
                case .tightFit: return L("Tight Fit")
                case .hideTooLarge: return L("Hide Too Large")
                }
            }

            func matches(_ model: MLXModel, totalMemoryGB: Double) -> Bool {
                guard totalMemoryGB > 0 else { return true }
                let compat = model.compatibility(totalMemoryGB: totalMemoryGB)
                switch self {
                case .runsWell:
                    return compat == .compatible
                case .tightFit:
                    return compat == .tight
                case .hideTooLarge:
                    return compat != .tooLarge
                }
            }
        }

        var isActive: Bool {
            typeFilter != .all
                || sizeCategory != nil
                || family != nil
                || paramCategory != nil
                || performance != nil
        }

        mutating func reset() {
            typeFilter = .all
            sizeCategory = nil
            family = nil
            paramCategory = nil
            performance = nil
        }

        /// Apply all filters to a model list. `totalMemoryGB` is only
        /// consulted when the Performance filter is active; pass `0` to
        /// fall through for the other filter dimensions (a reasonable
        /// default when the caller has no `SystemMonitorService` on hand,
        /// e.g. during unit tests). The Performance filter itself no-ops
        /// when `totalMemoryGB <= 0` so the list stays intact.
        func apply(to models: [MLXModel], totalMemoryGB: Double = 0) -> [MLXModel] {
            models.filter { model in
                switch typeFilter {
                case .all: break
                case .vlm: if !model.isVLM { return false }
                case .llm: if model.isVLM { return false }
                }
                if let sizeCat = sizeCategory, !sizeCat.matches(bytes: model.totalSizeEstimateBytes) {
                    return false
                }
                if let fam = family, model.family != fam { return false }
                if let paramCat = paramCategory, !paramCat.matches(billions: model.parameterCountBillions) {
                    return false
                }
                if let perf = performance, !perf.matches(model, totalMemoryGB: totalMemoryGB) {
                    return false
                }
                return true
            }
        }
    }

    // MARK: - Model Deprecation

    struct DeprecationNotice: Identifiable {
        let id: String
        let oldId: String
        let newId: String
    }

    /// Maps deprecated model IDs to their recommended OsaurusAI replacements.
    nonisolated static let deprecatedModelReplacements: [String: String] = [:]

    // MARK: - Published Properties
    @Published var availableModels: [MLXModel] = []
    @Published var isLoadingModels: Bool = false
    @Published var suggestedModels: [MLXModel] = ModelManager.curatedSuggestedModels
    @Published var deprecationNotices: [DeprecationNotice] = []

    /// True while a refresh of the OsaurusAI org listing is in flight. Drives
    /// the spinner on the Recommended tab's refresh button.
    @Published var isLoadingSuggested: Bool = false

    var modelsDirectory: URL {
        return DirectoryPickerService.shared.effectiveModelsDirectory
    }

    private var cancellables = Set<AnyCancellable>()
    private var remoteSearchTask: Task<Void, Never>? = nil

    /// Test-only knob: when `true`, the constructor does NOT kick off the
    /// background OsaurusAI HF org fetch. Production code never sets this;
    /// tests that exercise `applyOsaurusOrgFetch(...)` flip it on so the
    /// async HF response can't race with their assertions and replace
    /// injected entries with whatever HF currently lists.
    nonisolated(unsafe) static var skipBackgroundOrgFetchForTests: Bool = false

    // MARK: - Initialization
    override init() {
        super.init()

        loadAvailableModels()

        NotificationCenter.default.publisher(for: .localModelsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshDownloadStates()
            }
            .store(in: &cancellables)

        downloadService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Pull the OsaurusAI HF org listing once on launch so newly published
        // models surface in the Recommended tab without requiring a code push.
        if !Self.skipBackgroundOrgFetchForTests {
            Task { [weak self] in await self?.loadOsaurusAIOrgModels() }
        }
    }

    // MARK: - Public Methods

    /// Load popular MLX models
    func loadAvailableModels() {
        let curated = Self.curatedSuggestedModels

        suggestedModels = curated
        availableModels = curated
        downloadService.syncStates(for: availableModels + suggestedModels)
        let registry = Self.registryModels()
        mergeAvailable(with: registry)
        let localModels = Self.discoverLocalModels()
        mergeAvailable(with: localModels)

        isLoadingModels = false

        checkForDeprecatedModels()

        let allModels = availableModels + suggestedModels
        Task { [downloadService] in
            await downloadService.topUpCompletedModels(allModels)
        }
    }

    /// Scans locally installed models for deprecated entries and populates deprecation notices.
    func checkForDeprecatedModels() {
        deprecationNotices = Self.deprecatedModelReplacements.compactMap { oldId, newId in
            let probe = MLXModel(id: oldId, name: "", description: "", downloadURL: "")
            guard probe.isDownloaded else { return nil }
            return DeprecationNotice(id: oldId, oldId: oldId, newId: newId)
        }
    }

    /// Returns the replacement model ID if the given model is deprecated, nil otherwise.
    nonisolated static func replacementForDeprecatedModel(_ modelId: String) -> String? {
        deprecatedModelReplacements[modelId]
    }

    /// Re-evaluate download states for all known models against the current
    /// effective models directory. Called when the user changes the storage
    /// location so the UI reflects which models exist at the new path.
    func refreshDownloadStates() {
        downloadService.syncStates(for: availableModels + suggestedModels)
        let localModels = Self.discoverLocalModels()
        mergeAvailable(with: localModels)
        checkForDeprecatedModels()
    }

    /// Fetch MLX-compatible models from Hugging Face and merge into availableModels.
    /// If searchText is empty, fetches top repos from `mlx-community`. Otherwise performs a broader query.
    func fetchRemoteMLXModels(searchText: String) {
        // Cancel any in-flight search
        remoteSearchTask?.cancel()

        // Mark loading to show spinner if needed
        isLoadingModels = true

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // If user pasted a direct HF URL or "org/repo", immediately surface it without requiring SDK allowlist
        if let directId = Self.parseHuggingFaceRepoId(from: query), !directId.isEmpty,
            !findExistingModel(id: directId).found
        {
            let probe = MLXModel(id: directId, name: "", description: "", downloadURL: "")
            let model = MLXModel(
                id: directId,
                name: ModelMetadataParser.friendlyName(from: directId),
                description: probe.isDownloaded ? "Local model (detected)" : "Imported from input",
                downloadURL: "https://huggingface.co/\(directId)"
            )
            availableModels.insert(model, at: 0)
            downloadService.downloadStates[model.id] = model.isDownloaded ? .completed : .notStarted
        }

        remoteSearchTask = Task { [weak self] in
            guard let self else { return }

            // Build candidate URLs
            let limit = 100
            var urls: [URL] = []
            // Always query mlx-community
            if let url = Self.makeHFModelsURL(author: "mlx-community", search: query, limit: limit) {
                urls.append(url)
            }
            // Additional default seeds to find MLX repos outside mlx-community when query is empty
            let defaultSeeds = ["mlx", "mlx 4bit", "MLX"]
            if query.isEmpty {
                for seed in defaultSeeds {
                    if let url = Self.makeHFModelsURL(author: nil, search: seed, limit: limit) {
                        urls.append(url)
                    }
                }
            } else {
                // Broader search across all repos when query present
                if let url = Self.makeHFModelsURL(author: nil, search: query, limit: limit) {
                    urls.append(url)
                }
            }

            // Fetch in parallel
            let results: [[HFModel]] = await withTaskGroup(of: [HFModel].self) { group in
                for u in urls { group.addTask { (try? await Self.requestHFModels(at: u)) ?? [] } }
                var collected: [[HFModel]] = []
                for await arr in group { collected.append(arr) }
                return collected
            }

            var byId: [String: HFModel] = [:]
            for arr in results { for m in arr { byId[m.id] = m } }

            let allow = Self.sdkSupportedModelIds()
            let allowedMapped: [MLXModel] = byId.values.compactMap { hf in
                guard allow.contains(hf.id.lowercased()) else { return nil }
                return MLXModel(
                    id: hf.id,
                    name: ModelMetadataParser.friendlyName(from: hf.id),
                    description: "Discovered on Hugging Face",
                    downloadURL: "https://huggingface.co/\(hf.id)",
                    releasedAt: Self.parseHFTimestamp(hf.lastModified),
                    downloads: hf.downloads
                )
            }

            // Publish to UI on main actor (we already are, but be explicit about ordering)
            await MainActor.run {
                self.mergeAvailable(with: allowedMapped)
                self.isLoadingModels = false
            }
        }
    }

    /// Resolve or construct an MLXModel by Hugging Face repo id (e.g., "mlx-community/Qwen3-1.7B-4bit").
    /// Returns nil if the repo id does not appear MLX-compatible.
    func resolveModel(byRepoId repoId: String) -> MLXModel? {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let probe = MLXModel(id: trimmed, name: "", description: "", downloadURL: "")
        if probe.isDownloaded {
            if let existing = findExistingModel(id: trimmed).model { return existing }
            let localModel = MLXModel(
                id: trimmed,
                name: ModelMetadataParser.friendlyName(from: trimmed),
                description: "Local model (detected)",
                downloadURL: "https://huggingface.co/\(trimmed)"
            )
            insertModel(localModel)
            return localModel
        }

        if let existing = findExistingModel(id: trimmed).model {
            if !availableModels.contains(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                insertModel(existing)
            }
            return existing
        }

        let lower = trimmed.lowercased()
        guard lower.contains("mlx") || lower.hasPrefix("mlx-community/") || lower.contains("-mlx")
        else { return nil }
        guard Self.sdkSupportedModelIds().contains(lower) else { return nil }

        let model = MLXModel(
            id: trimmed,
            name: ModelMetadataParser.friendlyName(from: trimmed),
            description: "Imported from deeplink",
            downloadURL: "https://huggingface.co/\(trimmed)"
        )
        insertModel(model)
        return model
    }

    /// Resolve a model only if the Hugging Face repository is MLX-compatible.
    /// Uses network metadata from Hugging Face for a reliable determination.
    func resolveModelIfMLXCompatible(byRepoId repoId: String) async -> MLXModel? {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard Self.sdkSupportedModelIds().contains(trimmed.lowercased()) else { return nil }

        if let existing = findExistingModel(id: trimmed).model { return existing }

        guard await HuggingFaceService.shared.isMLXCompatible(repoId: trimmed) else { return nil }

        let model = MLXModel(
            id: trimmed,
            name: ModelMetadataParser.friendlyName(from: trimmed),
            description: "Imported from deeplink",
            downloadURL: "https://huggingface.co/\(trimmed)"
        )
        insertModel(model)
        return model
    }

    // MARK: - Model Lookup

    /// Search available and suggested models for a match (case-insensitive).
    private func findExistingModel(id: String) -> (model: MLXModel?, found: Bool) {
        if let m = availableModels.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            return (m, true)
        }
        if let m = suggestedModels.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            return (m, true)
        }
        return (nil, false)
    }

    /// Insert a model into the catalog and initialize its download state.
    private func insertModel(_ model: MLXModel) {
        availableModels.insert(model, at: 0)
        downloadService.downloadStates[model.id] = model.isDownloaded ? .completed : .notStarted
    }

    // MARK: - Download Forwarding (delegates to ModelDownloadService)

    func downloadModel(withRepoId repoId: String) {
        guard let model = resolveModel(byRepoId: repoId) else { return }
        downloadService.download(model)
    }

    func downloadModel(_ model: MLXModel) { downloadService.download(model) }
    func cancelDownload(_ modelId: String) { downloadService.cancel(modelId) }
    func deleteModel(_ model: MLXModel) { downloadService.delete(model) }

    func estimateDownloadSize(for model: MLXModel) async -> Int64? {
        await downloadService.estimateSize(for: model)
    }

    func effectiveDownloadState(for model: MLXModel) -> DownloadState {
        downloadService.effectiveState(for: model)
    }

    func downloadProgress(for modelId: String) -> Double {
        downloadService.progress(for: modelId)
    }

    var downloadStates: [String: DownloadState] { downloadService.downloadStates }
    var downloadMetrics: [String: ModelDownloadService.DownloadMetrics] { downloadService.downloadMetrics }
    var totalDownloadedSize: Int64 { downloadService.totalDownloadedSize }
    var totalDownloadedSizeString: String { downloadService.totalDownloadedSizeString }
    var activeDownloadsCount: Int { downloadService.activeDownloadsCount }

    /// Deduplicated merge of suggestedModels + availableModels, preferring curated descriptions.
    func deduplicatedModels() -> [MLXModel] {
        let combined = suggestedModels + availableModels
        var byLowerId: [String: MLXModel] = [:]
        for m in combined {
            let key = m.id.lowercased()
            if let existing = byLowerId[key] {
                let existingIsDiscovered = existing.description == "Discovered on Hugging Face"
                let currentIsDiscovered = m.description == "Discovered on Hugging Face"
                if existingIsDiscovered && !currentIsDiscovered {
                    byLowerId[key] = m
                }
            } else {
                byLowerId[key] = m
            }
        }
        return Array(byLowerId.values)
    }

    // MARK: - Private Methods

    static func sdkSupportedModelIds() -> Set<String> {
        var allowed: Set<String> = []
        for config in LLMRegistry.shared.models {
            allowed.insert(config.name.lowercased())
        }
        return allowed
    }

    static func registryModels() -> [MLXModel] {
        return LLMRegistry.shared.models.map { cfg in
            let id = cfg.name
            return MLXModel(
                id: id,
                name: ModelMetadataParser.friendlyName(from: id),
                description: L("From MLX registry"),
                downloadURL: "https://huggingface.co/\(id)"
            )
        }
    }
}

// MARK: - Dynamic model discovery (Hugging Face)

extension ModelManager {
    /// Parses a "yyyy-MM-dd" string into a UTC `Date`.
    /// Used to keep the curated date literals readable. Falls back to the epoch
    /// on parse failure so the sort order stays deterministic.
    nonisolated fileprivate static func date(_ ymd: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd) ?? Date(timeIntervalSince1970: 0)
    }

    /// Fully curated models with descriptions we control.
    /// Order is a fallback only — `ModelDownloadView.filteredSuggestedModels`
    /// sorts by curated-first → top-pick → `releasedAt` desc → name.
    nonisolated fileprivate static let curatedSuggestedModels: [MLXModel] = [
        // MARK: Top Picks

        MLXModel(
            id: "OsaurusAI/gemma-4-E2B-it-4bit",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/gemma-4-E2B-it-4bit"),
            description: "Smallest multimodal Gemma 4 model. Runs on any Mac.",
            downloadURL: "https://huggingface.co/OsaurusAI/gemma-4-E2B-it-4bit",
            isTopSuggestion: false,
            downloadSizeBytes: 4_392_120_539,
            modelType: "gemma4",
            releasedAt: date("2026-04-06")
        ),

        MLXModel(
            id: "OsaurusAI/gemma-4-E4B-it-4bit",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/gemma-4-E4B-it-4bit"),
            description: "Multimodal edge model. Handles images, video, and audio. 128K context.",
            downloadURL: "https://huggingface.co/OsaurusAI/gemma-4-E4B-it-4bit",
            isTopSuggestion: true,
            downloadSizeBytes: 6_901_389_946,
            modelType: "gemma4",
            releasedAt: date("2026-04-06")
        ),

        MLXModel(
            id: "OsaurusAI/gemma-4-26B-A4B-it-mxfp4",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/gemma-4-26B-A4B-it-mxfp4"),
            description: "Best all-around vision model. MoE with only 4B active params. 128K context.",
            downloadURL: "https://huggingface.co/OsaurusAI/gemma-4-26B-A4B-it-mxfp4",
            isTopSuggestion: true,
            downloadSizeBytes: 14_869_637_520,
            modelType: "gemma4",
            releasedAt: date("2026-04-07")
        ),

        // MARK: Qwen 3.6
        //
        // Qwen 3.6 keeps the `qwen3_5_moe` / `qwen3_5` model_type identifier,
        // so vmlx-swift-lm's existing Qwen35Model / Qwen35MoEModel classes
        // handle it. JANGTQ variants use the same model_type but are routed
        // to Qwen35JANGTQModel at load time based on jang_config.weight_format
        // (`"mxtq"`) — no osaurus-side branching required.

        MLXModel(
            id: "OsaurusAI/Qwen3.6-35B-A3B-mxfp4",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/Qwen3.6-35B-A3B-mxfp4"),
            description: "Qwen 3.6 35B MoE vision model. MXFP4 quantization — best quality per byte.",
            downloadURL: "https://huggingface.co/OsaurusAI/Qwen3.6-35B-A3B-mxfp4",
            isTopSuggestion: true,
            downloadSizeBytes: 19_350_002_112,
            modelType: "qwen3_5_moe",
            releasedAt: date("2026-04-16")
        ),

        MLXModel(
            id: "LiquidAI/LFM2-24B-A2B-MLX-8bit",
            name: ModelMetadataParser.friendlyName(from: "LiquidAI/LFM2-24B-A2B-MLX-8bit"),
            description: "Liquid AI's 24B MoE model. Only ~2B active params per token. 128K context.",
            downloadURL: "https://huggingface.co/LiquidAI/LFM2-24B-A2B-MLX-8bit",
            isTopSuggestion: true,
            downloadSizeBytes: 23_600_000_000
        ),

        // MARK: MiniMax M2.7 (JANGTQ MoE)
        //
        // 228.7B total / ~1.4B active MoE (256 experts, top-8) with 192K context.
        // Always-reasoning chat template. Auto-routed to MiniMaxJANGTQModel via
        // jang_config.json (`weight_format: mxtq`) at load time — no osaurus-side
        // branching required.

        MLXModel(
            id: "OsaurusAI/MiniMax-M2.7-JANGTQ4",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/MiniMax-M2.7-JANGTQ4"),
            description:
                "MiniMax M2.7 228B agentic MoE, 4-bit TurboQuant routed experts. Near-bf16 quality at ~25% of bf16 disk. 192K context.",
            downloadURL: "https://huggingface.co/OsaurusAI/MiniMax-M2.7-JANGTQ4",
            downloadSizeBytes: 116_874_305_053,
            modelType: "minimax_m2",
            releasedAt: date("2026-04-17")
        ),

        MLXModel(
            id: "OsaurusAI/MiniMax-M2.7-JANGTQ",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/MiniMax-M2.7-JANGTQ"),
            description:
                "MiniMax M2.7 228B agentic MoE, 2-bit TurboQuant routed experts. Smallest footprint of the family. 192K context.",
            downloadURL: "https://huggingface.co/OsaurusAI/MiniMax-M2.7-JANGTQ",
            downloadSizeBytes: 60_705_324_126,
            modelType: "minimax_m2",
            releasedAt: date("2026-04-17")
        ),

        // MARK: Nemotron-3 Nano Omni Reasoning (hybrid Mamba-2 SSM + Attn + MoE)
        //
        // 30B total / ~3B active. 52-layer hybrid: 23 Mamba-2 SSM layers,
        // 23 MoE layers (128 routed × 6 active + 1 shared, ReLU² activation),
        // 6 attention layers (GQA 32q × 2kv, NO RoPE — position info from
        // Mamba). 262K native context. Reasoning ON by default — chat
        // template emits `<think>...</think>` segments parsed by vmlx's
        // think_xml stamp (auto-resolved from `model_type=nemotron_h`).
        //
        // Tool format: `nemotron` (NeMo-style) — auto-resolved by vmlx via
        // jang_config.capabilities or model-type heuristic.
        // Cache: hybrid — `MambaCache(size=2)` for the 23 M layers,
        // `KVCacheSimple` for the 6 * layers, nil for E layers. vmlx's
        // `CacheCoordinator.isHybrid` auto-flips on first slot admission
        // via `BatchEngine.admitPendingRequests`; osaurus *also* calls
        // `setHybrid(true)` eagerly in `ModelRuntime.installCacheCoordinator`
        // for any name matching `isKnownHybridModel(name:)` — Nemotron-3
        // matches via the `nemotron-3` substring. The eager set is harmless
        // (per OMNI-OSAURUS-HOOKUP.md §5.1) and avoids a one-frame stale-flag
        // window if a request lands via the single-slot Evaluate path before
        // BatchEngine has flipped the flag.
        // Sampling recipe per `research/NEMOTRON-OMNI-RUNTIME-2026-04-28.md`:
        // T=0.6 top_p=0.95 (DeepSeek-style). Bundles ship those defaults
        // in `generation_config.json`; `LocalGenerationDefaults` reads them.

        MLXModel(
            id: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4",
            name: ModelMetadataParser.friendlyName(
                from: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4"
            ),
            description:
                "NVIDIA Nemotron-3 30B Reasoning hybrid (Mamba-2 + MoE). MXFP4 quantization — fastest decode path. 262K context.",
            downloadURL:
                "https://huggingface.co/OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4",
            isTopSuggestion: true,
            downloadSizeBytes: 18_002_117_870,
            modelType: "nemotron_h",
            releasedAt: date("2026-04-28")
        ),

        MLXModel(
            id: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4",
            name: ModelMetadataParser.friendlyName(
                from: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4"
            ),
            description:
                "Nemotron-3 30B Reasoning hybrid, 4-bit TurboQuant routed experts. Near-bf16 quality at ~16 GB. 262K context.",
            downloadURL:
                "https://huggingface.co/OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4",
            downloadSizeBytes: 16_009_341_440,
            modelType: "nemotron_h",
            releasedAt: date("2026-04-28")
        ),

        MLXModel(
            id: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ",
            name: ModelMetadataParser.friendlyName(
                from: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ"
            ),
            description:
                "Nemotron-3 30B Reasoning hybrid, 2-bit TurboQuant routed experts. Smallest footprint (~9 GB). 262K context.",
            downloadURL:
                "https://huggingface.co/OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ",
            downloadSizeBytes: 9_136_488_448,
            modelType: "nemotron_h",
            releasedAt: date("2026-04-28")
        ),

        // MARK: Laguna-XS.2 (preview — vmlx engine support pending)
        //
        // Poolside's `model_type=laguna` — agentic-coding 33B/3B-active MoE,
        // 40 layers, hybrid SWA + full attention with per-layer head counts,
        // dual RoPE (full=YaRN, swa=default), 256 routed experts top-8 + 1
        // shared expert, sigmoid routing with per-head gating, q_norm/k_norm
        // in attention. Text-only. 131K context.
        //
        // The hybrid here is SLIDING-WINDOW + full attention (handled by
        // `RotatingKVCache` + `KVCacheSimple` per-layer in vmlx), NOT the
        // Mamba/Attn/MoE pattern used by Nemotron-3. So `isKnownHybridModel`
        // intentionally does NOT match Laguna — `setHybrid(true)` is for
        // SSM-state companion caches, which Laguna doesn't have.
        //
        // The chat template (`laguna_glm_thinking_v5/chat_template.jinja`)
        // ships an `enable_thinking` Jinja kwarg that defaults to false;
        // the per-model `LagunaThinkingProfile` in `ModelOptions.swift`
        // exposes a "Disable Thinking" toggle so reasoning can be flipped
        // on per request.
        //
        // Quant + bundle metadata per `jang_tools/convert_laguna_jangtq.py`
        // and `jang_tools/convert_laguna_mxfp4.py`. `jang_config.json` v2:
        //   { "weight_format": "mxtq" | "mxfp4",
        //     "source_model.architecture": "laguna",
        //     "has_vision/audio/video": false,
        //     "mxtq_bits": { attention=8, shared_expert=8,
        //                    routed_expert=2|4, embed_lm_head=8 } }
        // The shared `validateJANGTQSidecarIfRequired` preflight catches
        // mislabeled bundles (sidecar present but `weight_format != "mxtq"`)
        // for any JANGTQ family — Laguna inherits that protection.

        MLXModel(
            id: "OsaurusAI/Laguna-XS.2-mxfp4",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/Laguna-XS.2-mxfp4"),
            description:
                "Poolside Laguna-XS.2 33B/3B-active agentic-coding MoE. MXFP4 quant — fastest decode. 131K context, 256 experts top-8.",
            downloadURL:
                "https://huggingface.co/OsaurusAI/Laguna-XS.2-mxfp4",
            downloadSizeBytes: 17_500_000_000,
            modelType: "laguna",
            releasedAt: date("2026-04-30")
        ),

        MLXModel(
            id: "OsaurusAI/Laguna-XS.2-JANGTQ2",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/Laguna-XS.2-JANGTQ2"),
            description:
                "Poolside Laguna-XS.2 33B/3B-active agentic-coding MoE, 2-bit TurboQuant routed experts. Smallest footprint (~7 GB). 131K context.",
            downloadURL:
                "https://huggingface.co/OsaurusAI/Laguna-XS.2-JANGTQ2",
            downloadSizeBytes: 7_300_000_000,
            modelType: "laguna",
            releasedAt: date("2026-04-30")
        ),

        // MARK: Mistral-Medium-3.5-128B (preview — architecturally supported, end-to-end load unverified)
        //
        // `model_type=mistral3` outer wrapper with `text_config.model_type=
        // ministral3` (88 layers, hidden 12288, 96/8 GQA, head_dim 128, 256K
        // YaRN). Pixtral vision tower (48 layers, hidden 1664, image_size
        // 1540, patch 14, spatial_merge 2). Text + image. Source FP8 e4m3
        // with per-tensor scales; vision tower / projector / lm_head stay
        // in bf16/fp16.
        //
        // vmlx-swift-lm's `mistral3` factory branches on
        // `text_config.model_type == "mistral4"` and falls through to
        // `Mistral3VLM` otherwise. `Mistral3VLM.LanguageModel`
        // (Libraries/MLXVLM/Models/Mistral3.swift:516) is explicitly
        // documented to handle BOTH `ministral3` (sliding + llama4 scaling)
        // AND vanilla `mistral` model_types via `Ministral3ModelInner`.
        // Vision shapes (image_size, num_layers, spatial_merge) are
        // config-parametric. So Mistral 3.5 should load through the
        // existing factory dispatch — but no end-to-end smoke test has
        // been run on real 3.5 weights yet, hence "preview". Marked top
        // suggestion only after a real load + decode pass on bundle.
        //
        // Quant + bundle metadata per `jang_tools/convert_mistral3_jangtq.py`
        // and `jang_tools/convert_mistral3_mxfp4.py`. `jang_config.json` v2:
        //   { "weight_format": "mxtq" | "mxfp4",
        //     "source_model.architecture": "mistral3",
        //     "has_vision": true, "vision_arch": "pixtral",
        //     "mxtq_bits": { text_decoder=2|4, embed_tokens=8,
        //                    vision_tower="passthrough_fp16",
        //                    multi_modal_projector="passthrough_fp16",
        //                    lm_head="passthrough_fp16" } }
        //
        // Not a Mamba/SSM hybrid — `isKnownHybridModel` does NOT match.

        MLXModel(
            id: "OsaurusAI/Mistral-Medium-3.5-128B-mxfp4",
            name: ModelMetadataParser.friendlyName(
                from: "OsaurusAI/Mistral-Medium-3.5-128B-mxfp4"
            ),
            description:
                "Mistral Medium 3.5 128B + Pixtral vision. MXFP4 quant — fastest decode. 256K context, 24-language coverage.",
            downloadURL:
                "https://huggingface.co/OsaurusAI/Mistral-Medium-3.5-128B-mxfp4",
            downloadSizeBytes: 70_400_000_000,
            modelType: "mistral3",
            releasedAt: date("2026-04-30")
        ),

        MLXModel(
            id: "OsaurusAI/Mistral-Medium-3.5-128B-JANGTQ2",
            name: ModelMetadataParser.friendlyName(
                from: "OsaurusAI/Mistral-Medium-3.5-128B-JANGTQ2"
            ),
            description:
                "Mistral Medium 3.5 128B + Pixtral vision, 2-bit TurboQuant text decoder. ~36 GB footprint. 256K context, 24-language coverage.",
            downloadURL:
                "https://huggingface.co/OsaurusAI/Mistral-Medium-3.5-128B-JANGTQ2",
            downloadSizeBytes: 36_700_000_000,
            modelType: "mistral3",
            releasedAt: date("2026-04-30")
        ),

        // MARK: Large Models

        MLXModel(
            id: "lmstudio-community/gpt-oss-20b-MLX-8bit",
            name: ModelMetadataParser.friendlyName(from: "lmstudio-community/gpt-oss-20b-MLX-8bit"),
            description: "OpenAI's open-source release. Strong all-around performance.",
            downloadURL: "https://huggingface.co/lmstudio-community/gpt-oss-20b-MLX-8bit"
        ),

        MLXModel(
            id: "lmstudio-community/gpt-oss-120b-MLX-8bit",
            name: ModelMetadataParser.friendlyName(from: "lmstudio-community/gpt-oss-120b-MLX-8bit"),
            description: "OpenAI's largest open model. Premium quality, requires 64GB+ unified memory.",
            downloadURL: "https://huggingface.co/lmstudio-community/gpt-oss-120b-MLX-8bit"
        ),

        MLXModel(
            id: "OsaurusAI/Gemma-4-31B-it-JANG_4M",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/Gemma-4-31B-it-JANG_4M"),
            description: "Gemma 4 31B dense vision model. Top-tier quality with optimized quantization.",
            downloadURL: "https://huggingface.co/OsaurusAI/Gemma-4-31B-it-JANG_4M",
            downloadSizeBytes: 22_692_183_936,
            modelType: "gemma4",
            releasedAt: date("2026-04-16")
        ),

        // MARK: Vision Language Models (VLM)

        MLXModel(
            id: "OsaurusAI/gemma-4-26B-A4B-it-4bit",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/gemma-4-26B-A4B-it-4bit"),
            description: "MoE vision model with standard 4-bit quantization. 4B active params.",
            downloadURL: "https://huggingface.co/OsaurusAI/gemma-4-26B-A4B-it-4bit",
            downloadSizeBytes: 15_641_238_761,
            modelType: "gemma4",
            releasedAt: date("2026-04-07")
        ),

        MLXModel(
            id: "OsaurusAI/Gemma-4-26B-A4B-it-JANG_2L",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/Gemma-4-26B-A4B-it-JANG_2L"),
            description: "Efficient MoE vision model. Only 4B active params. 256K context.",
            downloadURL: "https://huggingface.co/OsaurusAI/Gemma-4-26B-A4B-it-JANG_2L",
            downloadSizeBytes: 10_676_011_439,
            modelType: "gemma4",
            releasedAt: date("2026-04-16")
        ),

        MLXModel(
            id: "OsaurusAI/Gemma-4-26B-A4B-it-JANG_4M",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/Gemma-4-26B-A4B-it-JANG_4M"),
            description: "Higher-quality MoE vision model. 4B active params with 256K context.",
            downloadURL: "https://huggingface.co/OsaurusAI/Gemma-4-26B-A4B-it-JANG_4M",
            downloadSizeBytes: 16_200_957_903,
            modelType: "gemma4",
            releasedAt: date("2026-04-16")
        ),

        MLXModel(
            id: "OsaurusAI/gemma-4-E4B-it-8bit",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/gemma-4-E4B-it-8bit"),
            description: "Multimodal edge model at 8-bit precision. Best quality for the E4B family.",
            downloadURL: "https://huggingface.co/OsaurusAI/gemma-4-E4B-it-8bit",
            downloadSizeBytes: 8_997_820_763,
            modelType: "gemma4",
            releasedAt: date("2026-04-06")
        ),

        MLXModel(
            id: "OsaurusAI/Qwen3.5-122B-A10B-JANG_4K",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/Qwen3.5-122B-A10B-JANG_4K"),
            description: "Largest Qwen3.5 MoE vision model. 10B active params with top-tier reasoning.",
            downloadURL: "https://huggingface.co/OsaurusAI/Qwen3.5-122B-A10B-JANG_4K",
            downloadSizeBytes: 66_458_339_463,
            modelType: "qwen3_5_moe",
            releasedAt: date("2026-04-16")
        ),

        MLXModel(
            id: "OsaurusAI/Qwen3.5-122B-A10B-JANG_2S",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/Qwen3.5-122B-A10B-JANG_2S"),
            description: "Qwen3.5 122B MoE vision model. Compact quantization, smaller download.",
            downloadURL: "https://huggingface.co/OsaurusAI/Qwen3.5-122B-A10B-JANG_2S",
            downloadSizeBytes: 37_770_467_212,
            modelType: "qwen3_5_moe",
            releasedAt: date("2026-04-16")
        ),

        MLXModel(
            id: "OsaurusAI/Qwen3.5-35B-A3B-JANG_4K",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/Qwen3.5-35B-A3B-JANG_4K"),
            description: "Efficient Qwen3.5 MoE vision model. Only 3B active params.",
            downloadURL: "https://huggingface.co/OsaurusAI/Qwen3.5-35B-A3B-JANG_4K",
            downloadSizeBytes: 19_667_902_931,
            modelType: "qwen3_5_moe",
            releasedAt: date("2026-04-16")
        ),

        MLXModel(
            id: "OsaurusAI/Qwen3.5-35B-A3B-JANG_2S",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/Qwen3.5-35B-A3B-JANG_2S"),
            description: "Compact Qwen3.5 MoE vision model. Fast and lightweight.",
            downloadURL: "https://huggingface.co/OsaurusAI/Qwen3.5-35B-A3B-JANG_2S",
            downloadSizeBytes: 11_665_353_755,
            modelType: "qwen3_5_moe",
            releasedAt: date("2026-04-16")
        ),

        // MARK: Compact Models

        MLXModel(
            id: "OsaurusAI/gemma-4-E2B-it-8bit",
            name: ModelMetadataParser.friendlyName(from: "OsaurusAI/gemma-4-E2B-it-8bit"),
            description: "Smallest Gemma 4 at 8-bit precision. Better quality, still runs on any Mac.",
            downloadURL: "https://huggingface.co/OsaurusAI/gemma-4-E2B-it-8bit",
            downloadSizeBytes: 5_932_058_274,
            modelType: "gemma4",
            releasedAt: date("2026-04-06")
        ),

    ]

    /// Lowercased IDs of curated entries. Used by the Recommended-tab sort to
    /// pin curated models above auto-fetched org listings.
    nonisolated static let curatedSuggestedIds: Set<String> = Set(
        curatedSuggestedModels.map { $0.id.lowercased() }
    )
}

// MARK: - Installed models helpers for services

extension ModelManager {
    /// List installed MLX model names (repo component, lowercased), unique and sorted by name.
    nonisolated static func installedModelNames() -> [String] {
        let models = discoverLocalModels()
        var seen: Set<String> = []
        var names: [String] = []
        for m in models {
            let repo = m.id.split(separator: "/").last.map(String.init)?.lowercased() ?? m.id.lowercased()
            if !seen.contains(repo) {
                seen.insert(repo)
                names.append(repo)
            }
        }
        return names.sorted()
    }

    /// Find an installed model by user-provided name.
    /// Accepts repo name (case-insensitive) or full id (case-insensitive).
    nonisolated static func findInstalledModel(named name: String) -> (name: String, id: String)? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let models = discoverLocalModels()

        // Try repo component first
        if let match = models.first(where: { m in
            m.id.split(separator: "/").last.map(String.init)?.lowercased() == trimmed.lowercased()
        }) {
            let repo =
                match.id.split(separator: "/").last.map(String.init)?.lowercased() ?? trimmed.lowercased()
            return (repo, match.id)
        }

        // Try full id match
        if let match = models.first(where: { m in m.id.lowercased() == trimmed.lowercased() }) {
            let repo =
                match.id.split(separator: "/").last.map(String.init)?.lowercased() ?? trimmed.lowercased()
            return (repo, match.id)
        }
        return nil
    }
}

// MARK: - Hugging Face discovery helpers

extension ModelManager {
    fileprivate struct HFModel: Decodable {
        let id: String
        let tags: [String]?
        let lastModified: String?
        let downloads: Int?
    }

    /// Build the HF models API URL
    fileprivate static func makeHFModelsURL(author: String?, search: String, limit: Int) -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/api/models"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "full", value: "1"),
            URLQueryItem(name: "sort", value: "downloads"),
        ]
        if let author, !author.isEmpty { items.append(URLQueryItem(name: "author", value: author)) }
        if !search.isEmpty { items.append(URLQueryItem(name: "search", value: search)) }
        comps.queryItems = items
        return comps.url
    }

    /// Per-repo info we care about. Currently just `usedStorage` (total
    /// bytes across all files in the repo) so we can populate
    /// `MLXModel.downloadSizeBytes` for repo ids whose names don't carry a
    /// parseable parameter token.
    fileprivate struct HFRepoInfo: Decodable {
        let usedStorage: Int64?
    }

    /// Fetch `usedStorage` for a single repo. Returns `nil` on any error
    /// (network, decode, missing field) so callers can fall through to
    /// the existing parameter-count estimate.
    fileprivate static func fetchUsedStorage(repoId: String) async -> Int64? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/api/models/\(repoId)"
        comps.queryItems = [URLQueryItem(name: "expand[]", value: "usedStorage")]
        guard let url = comps.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            (200 ..< 300).contains(http.statusCode)
        else { return nil }

        return (try? JSONDecoder().decode(HFRepoInfo.self, from: data))?.usedStorage
    }

    /// Request HF models at URL
    fileprivate static func requestHFModels(at url: URL) async throws -> [HFModel] {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            return []
        }
        do {
            return try JSONDecoder().decode([HFModel].self, from: data)
        } catch {
            return []
        }
    }

    /// Parse a HF `lastModified` ISO8601 string into a `Date`.
    fileprivate static func parseHFTimestamp(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: s) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: s)
    }

    /// Map HF tags to a known `model_type` string when possible.
    /// Returns the first tag that matches the VLM type registry, otherwise nil
    /// (auto-fetched LLM entries fall back to post-download detection).
    fileprivate static func inferModelType(from tags: [String]?) -> String? {
        guard let tags else { return nil }
        for tag in tags {
            if VLMDetection.isVLM(modelType: tag) { return tag }
        }
        return nil
    }

    fileprivate func mergeAvailable(with newModels: [MLXModel]) {
        // Repo tail (everything after the last "/") is the basename a user actually
        // recognises; when two ids share a tail, treat them as the same model — this
        // collapses cases like flat-layout `Nemotron-3-...` colliding with curated
        // `OsaurusAI/Nemotron-3-...`.
        func tail(_ id: String) -> String {
            (id.split(separator: "/").last.map(String.init) ?? id).lowercased()
        }

        var existingLower: Set<String> = Set(
            (availableModels + suggestedModels).map { $0.id.lowercased() }
        )
        var existingTails: [String: MLXModel] = [:]
        for m in availableModels + suggestedModels {
            existingTails[tail(m.id)] = m
        }

        var appended: [MLXModel] = []
        var replacements: [(oldId: String, new: MLXModel)] = []

        for m in newModels {
            let key = m.id.lowercased()
            if existingLower.contains(key) { continue }

            let mTail = tail(m.id)
            if let existing = existingTails[mTail], existing.id.lowercased() != key {
                // Tail collision: prefer the entry that's actually on disk so users
                // never see a duplicate "downloaded vs not-downloaded" pair.
                if m.isDownloaded && !existing.isDownloaded {
                    replacements.append((oldId: existing.id, new: m))
                    existingLower.insert(key)
                    existingTails[mTail] = m
                }
                continue
            }

            existingLower.insert(key)
            existingTails[mTail] = m
            appended.append(m)
        }

        for r in replacements {
            if let idx = availableModels.firstIndex(where: { $0.id == r.oldId }) {
                availableModels[idx] = r.new
            } else if let idx = suggestedModels.firstIndex(where: { $0.id == r.oldId }) {
                // Suggested entry's id pointed at a path the user doesn't
                // actually have on disk (curated `OsaurusAI/Foo` vs the user's
                // flat `Foo`). Drop the curated entry from suggested and add
                // the on-disk one to available — otherwise the model shows
                // twice (once "downloaded", once "not downloaded").
                suggestedModels.remove(at: idx)
                availableModels.append(r.new)
            } else {
                availableModels.append(r.new)
            }
        }

        guard !appended.isEmpty || !replacements.isEmpty else { return }
        availableModels.append(contentsOf: appended)
        downloadService.syncStates(for: appended + replacements.map { $0.new })
    }
}

// MARK: - OsaurusAI org auto-discovery

extension ModelManager {
    /// HF org whose entire repo listing is auto-discovered into the Recommended tab.
    fileprivate static let osaurusOrgAuthor = "OsaurusAI"

    /// True if `id` is `"<osaurusOrgAuthor>/<repo>"` (case-insensitive).
    fileprivate static func isOsaurusOrgRepo(_ id: String) -> Bool {
        guard let org = id.split(separator: "/").first.map(String.init) else { return false }
        return org.caseInsensitiveCompare(osaurusOrgAuthor) == .orderedSame
    }

    /// Builds an `MLXModel` for an HF repo that isn't in the curated list.
    fileprivate static func makeAutoFetchedModel(from hf: HFModel) -> MLXModel {
        MLXModel(
            id: hf.id,
            name: ModelMetadataParser.friendlyName(from: hf.id),
            description: "From OsaurusAI on Hugging Face.",
            downloadURL: "https://huggingface.co/\(hf.id)",
            modelType: inferModelType(from: hf.tags),
            releasedAt: parseHFTimestamp(hf.lastModified),
            downloads: hf.downloads
        )
    }

    /// Fetch every repo published under the OsaurusAI org from HF and merge
    /// them into `suggestedModels`. Curated entries always win on duplicate
    /// IDs so editorial descriptions and Top-Pick flags survive.
    func loadOsaurusAIOrgModels() async {
        guard
            let url = Self.makeHFModelsURL(
                author: Self.osaurusOrgAuthor,
                search: "",
                limit: 100
            )
        else { return }

        let raw = (try? await Self.requestHFModels(at: url)) ?? []
        guard !raw.isEmpty else { return }

        let curatedIds = Self.curatedSuggestedIds
        let autoFetched: [MLXModel] =
            raw
            .filter { !curatedIds.contains($0.id.lowercased()) }
            .map(Self.makeAutoFetchedModel(from:))

        var statsById: [String: Int] = [:]
        for hf in raw {
            if let count = hf.downloads {
                statsById[hf.id.lowercased()] = count
            }
        }

        // The /api/models listing endpoint doesn't return file sizes, so
        // fan out one request per repo to `/api/models/<id>?expand[]=usedStorage`
        // and fold the results in. URLSession multiplexes these over a few
        // HTTP/2 connections; with ~100 repos this completes in a second
        // or two and is only triggered by the OsaurusAI org refresh
        // (Recommended tab refresh button + initial load), not by search.
        let sizesById: [String: Int64] = await withTaskGroup(of: (String, Int64?).self) { group in
            for hf in raw {
                group.addTask { (hf.id.lowercased(), await Self.fetchUsedStorage(repoId: hf.id)) }
            }
            var collected: [String: Int64] = [:]
            for await (key, value) in group {
                if let value { collected[key] = value }
            }
            return collected
        }

        applyOsaurusOrgFetch(autoFetched: autoFetched, statsById: statsById, sizesById: sizesById)
    }

    /// Replace the auto-fetched portion of `suggestedModels` while preserving
    /// curated entries (and any unrelated entries that may have been added).
    /// Internal so tests can drive the merge without hitting the network.
    /// `statsById` carries HF Hub `downloads` counts; `sizesById` carries
    /// per-repo `usedStorage` byte counts. Both flow into curated entries
    /// (hand-coded, no HF metadata) and auto-fetched entries at merge time.
    func applyOsaurusOrgFetch(
        autoFetched: [MLXModel],
        statsById: [String: Int] = [:],
        sizesById: [String: Int64] = [:]
    ) {
        let curatedIds = Self.curatedSuggestedIds
        let enrich: (MLXModel) -> MLXModel = { model in
            let key = model.id.lowercased()
            return
                model
                .withDownloads(statsById[key] ?? model.downloads)
                .withDownloadSize(sizesById[key])
        }
        let curated = Self.curatedSuggestedModels.map(enrich)
        let enrichedAutoFetched = autoFetched.map(enrich)

        // Drop previous OsaurusAI auto-fetched entries, keeping curated and
        // any non-OsaurusAI entries other code may have injected.
        let preserved = suggestedModels.filter { model in
            let key = model.id.lowercased()
            if curatedIds.contains(key) { return false }
            return !Self.isOsaurusOrgRepo(model.id)
        }

        var merged: [MLXModel] = curated + preserved
        var seen = Set(merged.map { $0.id.lowercased() })
        for model in enrichedAutoFetched {
            let key = model.id.lowercased()
            if seen.insert(key).inserted {
                merged.append(model)
            }
        }

        suggestedModels = merged
        downloadService.syncStates(for: merged)
    }

    /// Public refresh entry point used by the Recommended tab's refresh button.
    func refreshSuggestedModels() async {
        isLoadingSuggested = true
        await loadOsaurusAIOrgModels()
        isLoadingSuggested = false
    }
}

// MARK: - Local discovery and input parsing helpers

extension ModelManager {
    /// Parse a user-provided text into a Hugging Face repo id ("org/repo") if possible.
    static func parseHuggingFaceRepoId(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let host = url.host?.lowercased(), host == "huggingface.co" {
            let components = url.pathComponents.filter { $0 != "/" }
            if components.count >= 2 {
                return "\(components[0])/\(components[1])"
            }
            return nil
        }
        // Raw org/repo
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/").map(String.init)
            if parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty {
                return "\(parts[0])/\(parts[1])"
            }
        }
        return nil
    }

    // MARK: - Local Models Cache (in-memory, cleared on app restart)
    private static nonisolated let localModelsCacheLock = NSLock()
    private static nonisolated(unsafe) var cachedLocalModels: [MLXModel]?

    nonisolated static func invalidateLocalModelsCache() {
        localModelsCacheLock.lock()
        cachedLocalModels = nil
        localModelsCacheLock.unlock()
        LocalReasoningCapability.invalidate()
        LocalGenerationDefaults.invalidate()
    }

    /// Discover locally downloaded models. Cached until invalidated by model download/delete.
    nonisolated static func discoverLocalModels() -> [MLXModel] {
        localModelsCacheLock.lock()
        if let cached = cachedLocalModels {
            localModelsCacheLock.unlock()
            return cached
        }
        localModelsCacheLock.unlock()

        let models = scanLocalModels()

        localModelsCacheLock.lock()
        cachedLocalModels = models
        localModelsCacheLock.unlock()
        return models
    }

    private nonisolated static func scanLocalModels() -> [MLXModel] {
        return scanLocalModels(at: DirectoryPickerService.effectiveModelsDirectory())
    }

    /// Internal entry point used by tests so they can supply a fixture root.
    /// Detects both the flat (`<root>/<modelDir>/`) and nested (`<root>/<org>/<repo>/`)
    /// layouts.
    internal nonisolated static func scanLocalModels(at root: URL) -> [MLXModel] {
        let fm = FileManager.default
        guard
            let topEntries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var models: [MLXModel] = []

        func exists(_ base: URL, _ name: String) -> Bool {
            fm.fileExists(atPath: base.appendingPathComponent(name).path)
        }

        /// Resolve symlinks and return the real directory URL, or `nil` if the entry is not a directory.
        func resolvedDirectory(_ url: URL) -> URL? {
            let resolved = url.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return resolved
        }

        /// True if `dir` contains config.json + a recognised tokenizer + at least one safetensors file.
        func isModelBundle(_ dir: URL) -> Bool {
            guard exists(dir, "config.json") else { return false }
            let hasTokenizerJSON = exists(dir, "tokenizer.json")
            let hasBPE =
                exists(dir, "merges.txt")
                && (exists(dir, "vocab.json") || exists(dir, "vocab.txt"))
            let hasSentencePiece =
                exists(dir, "tokenizer.model") || exists(dir, "spiece.model")
            guard hasTokenizerJSON || hasBPE || hasSentencePiece else { return false }
            guard
                let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { return false }
            return items.contains(where: { $0.pathExtension == "safetensors" })
        }

        // Three layouts are supported and may coexist under the same root:
        //   1. Flat:        <root>/<modelDir>/{config.json,tokenizer.*,*.safetensors}
        //   2. Nested:      <root>/<org>/<repo>/{config.json,...}        (HF style)
        //   3. Multi-org:   <root>/<parentOrg>/<org>/<repo>/{config.json,...}
        //                                                                (when the picker points at
        //                                                                a parent dir containing
        //                                                                multiple HF-style trees,
        //                                                                e.g. `/Volumes/X/dealignai`
        //                                                                next to `/Volumes/X/jangq-ai`)
        //
        // For each top-level entry, prefer flat detection (entry IS a bundle); otherwise descend
        // and try the same heuristic at the next level. Maximum depth of 3 keeps the scan bounded
        // — anything deeper is treated as not-a-bundle.
        func scanDir(_ root: URL, prefix: [String], maxDepth: Int) {
            guard maxDepth > 0,
                let entries = try? fm.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            else { return }
            for entry in entries {
                guard let resolved = resolvedDirectory(entry) else { continue }
                let nameComponents = prefix + [entry.lastPathComponent]
                if isModelBundle(resolved) {
                    let id = nameComponents.joined(separator: "/")
                    let model = MLXModel(
                        id: id,
                        name: ModelMetadataParser.friendlyName(from: id),
                        description: "Local model (detected)",
                        downloadURL: "https://huggingface.co/\(id)"
                    )
                    models.append(model)
                    continue  // a model dir doesn't itself contain other models
                }
                if maxDepth > 1 {
                    scanDir(resolved, prefix: nameComponents, maxDepth: maxDepth - 1)
                }
            }
        }
        scanDir(root, prefix: [], maxDepth: 3)

        // De-duplicate by lowercase id
        var seen: Set<String> = []
        var unique: [MLXModel] = []
        for m in models {
            let key = m.id.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(m)
            }
        }
        return unique
    }
}
