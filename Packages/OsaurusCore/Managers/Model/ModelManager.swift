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
    /// All available models from Hugging Face
    case all = "All"

    /// Curated list of recommended models
    case suggested = "Recommended"

    /// Only models downloaded locally (includes active downloads)
    case downloaded = "Downloads"

    /// Display name for the tab (required by AnimatedTabItem)
    var title: String {
        switch self {
        case .all: return L("All")
        case .suggested: return L("Recommended")
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

        var isActive: Bool {
            typeFilter != .all || sizeCategory != nil || family != nil || paramCategory != nil
        }

        mutating func reset() {
            typeFilter = .all
            sizeCategory = nil
            family = nil
            paramCategory = nil
        }

        func apply(to models: [MLXModel]) -> [MLXModel] {
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
                    downloadURL: "https://huggingface.co/\(hf.id)"
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
        var existingLower: Set<String> = Set(
            (availableModels + suggestedModels).map { $0.id.lowercased() }
        )
        var appended: [MLXModel] = []
        for m in newModels {
            let key = m.id.lowercased()
            if !existingLower.contains(key) {
                existingLower.insert(key)
                appended.append(m)
            }
        }
        guard !appended.isEmpty else { return }
        availableModels.append(contentsOf: appended)
        downloadService.syncStates(for: appended)
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
            releasedAt: parseHFTimestamp(hf.lastModified)
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

        applyOsaurusOrgFetch(autoFetched: autoFetched)
    }

    /// Replace the auto-fetched portion of `suggestedModels` while preserving
    /// curated entries (and any unrelated entries that may have been added).
    /// Internal so tests can drive the merge without hitting the network.
    func applyOsaurusOrgFetch(autoFetched: [MLXModel]) {
        let curated = Self.curatedSuggestedModels
        let curatedIds = Self.curatedSuggestedIds

        // Drop previous OsaurusAI auto-fetched entries, keeping curated and
        // any non-OsaurusAI entries other code may have injected.
        let preserved = suggestedModels.filter { model in
            let key = model.id.lowercased()
            if curatedIds.contains(key) { return false }
            return !Self.isOsaurusOrgRepo(model.id)
        }

        var merged: [MLXModel] = curated + preserved
        var seen = Set(merged.map { $0.id.lowercased() })
        for model in autoFetched {
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
        let fm = FileManager.default
        let root = DirectoryPickerService.effectiveModelsDirectory()
        guard
            let orgDirs = try? fm.contentsOfDirectory(
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

        for orgURL in orgDirs {
            guard let resolvedOrgURL = resolvedDirectory(orgURL) else { continue }
            guard
                let repos = try? fm.contentsOfDirectory(
                    at: resolvedOrgURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }
            for repoURL in repos {
                guard let resolvedRepoURL = resolvedDirectory(repoURL) else { continue }

                // Validate minimal required files (aligned with MLXModel.isDownloaded)
                guard exists(resolvedRepoURL, "config.json") else { continue }
                let hasTokenizerJSON = exists(resolvedRepoURL, "tokenizer.json")
                let hasBPE =
                    exists(resolvedRepoURL, "merges.txt")
                    && (exists(resolvedRepoURL, "vocab.json") || exists(resolvedRepoURL, "vocab.txt"))
                let hasSentencePiece =
                    exists(resolvedRepoURL, "tokenizer.model") || exists(resolvedRepoURL, "spiece.model")
                guard hasTokenizerJSON || hasBPE || hasSentencePiece else { continue }
                guard
                    let items = try? fm.contentsOfDirectory(
                        at: resolvedRepoURL,
                        includingPropertiesForKeys: nil
                    ),
                    items.contains(where: { $0.pathExtension == "safetensors" })
                else { continue }

                let org = orgURL.lastPathComponent
                let repo = repoURL.lastPathComponent
                let id = "\(org)/\(repo)"
                let model = MLXModel(
                    id: id,
                    name: ModelMetadataParser.friendlyName(from: id),
                    description: "Local model (detected)",
                    downloadURL: "https://huggingface.co/\(id)"
                )
                models.append(model)
            }
        }

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
