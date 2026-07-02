//
//  ModelManager.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Combine
import Darwin
import Foundation
import MLXLLM
import SwiftUI
import os

extension Notification.Name {
    /// Posted when local model list changes (download completed, model deleted)
    static let localModelsChanged = Notification.Name("localModelsChanged")
}

enum ModelListTab: String, CaseIterable, AnimatedTabItem {
    /// Models the user owns locally (includes active downloads). Listed
    /// first so returning users land on their own models.
    case downloaded = "On Device"

    /// Full catalog rendered as a Recommended carousel + a newest-first grid.
    /// Image models live in the dedicated Images pane; the catalog links to
    /// it inline instead of carrying a fake hand-off tab.
    case all = "Catalog"

    /// Display name for the tab (required by AnimatedTabItem)
    var title: String {
        switch self {
        case .downloaded: return L("On Device")
        case .all: return L("Catalog")
        }
    }
}

/// Manages MLX model catalog, discovery, and resolution.
/// Download orchestration is handled by ModelDownloadService.
@MainActor
final class ModelManager: NSObject, ObservableObject {
    static let shared = ModelManager()

    /// Diagnostics logger usable from the `nonisolated static` discovery paths.
    nonisolated static let discoveryLog = Logger(
        subsystem: "com.dinoki.osaurus",
        category: "ModelManager.discovery"
    )

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
            /// Exclude models whose advisory `compatibility` is `.tooLarge`
            /// (memory usage above the 95 % ratio threshold). This filter is
            /// user-selected catalog triage only; runtime load/download does
            /// not block RAM pressure from this estimate.
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

            // Discover external bundles (HF cache, LM Studio) off the main
            // thread. `rescan()` posts `.localModelsChanged` when the set
            // changes, which re-runs `refreshDownloadStates()` to merge them.
            Task.detached(priority: .utility) {
                ExternalModelLocator.rescan()
            }
        }
    }

    // MARK: - Public Methods

    /// Load popular MLX models
    func loadAvailableModels() {
        // Seed sizes synchronously from the on-disk cache so the first
        // paint shows last-known-accurate download sizes even offline.
        // Sizes are no longer hand-coded; they're fetched + cached by the
        // OsaurusAI org refresh / on-demand estimate and persisted in
        // `ModelSizeCache`.
        let curated = Self.curatedSuggestedModels.map { model in
            model.withDownloadSize(ModelSizeCache.bytes(forId: model.id))
        }

        suggestedModels = curated
        availableModels = curated
        downloadService.syncStates(for: availableModels + suggestedModels)
        let registry = Self.registryModels()
        mergeAvailable(with: registry)

        // Discover locally downloaded models off the main thread. The scan
        // runs on a background queue but `discoverLocalModels()` blocks the
        // caller waiting for it (up to a 10s limit), and this runs inside the
        // synchronous `ModelManager.shared` init forced on the main thread at
        // launch — long enough on a cold disk to trip the app-hang watchdog.
        // Merge the results back on the main actor when they land. The wait
        // is pushed off-main by `discoverLocalModelsOffMain()`; this `Task`
        // stays main-actor isolated so `self` never crosses actor boundaries.
        Task { [weak self] in
            let localModels = await Self.discoverLocalModelsOffMain()
            self?.mergeAvailable(with: localModels)
        }

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
        let models = availableModels + suggestedModels
        // Warm each model's on-disk cache and discover local models off the
        // main thread, then apply published state on main. Both otherwise run a
        // `contentsOfDirectory` scan on the main thread per refresh. The
        // off-main step captures only Sendable values (no `self`) and returns
        // its result, so nothing isolated crosses the task boundary.
        Task { @MainActor [weak self] in
            let localModels = await Task.detached(priority: .utility) { () -> [MLXModel] in
                for model in models { _ = model.isDownloaded }
                return ModelManager.discoverLocalModels()
            }.value
            guard let self else { return }
            self.downloadService.syncStates(for: models)
            self.mergeAvailable(with: localModels)
            self.checkForDeprecatedModels()
        }
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
                description: probe.isDownloaded ? L("Local model (detected)") : L("Imported from input"),
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
                description: L("Local model (detected)"),
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

        // OsaurusAI repos must already be in the registry (curated or org-fetched)
        // if we fell through `findExistingModel` above, this OsaurusAI id is unknown so reject
        if trimmed.lowercased().hasPrefix("osaurusai/") { return nil }

        guard trimmed.lowercased().hasPrefix("mlx-community/") || Self.nameLooksLikeMLX(trimmed)
        else { return nil }

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
    /// Policy:
    ///   - `mlx-community/*`: trust the org; HF compat check confirms.
    ///   - `OsaurusAI/*`: must already exist in the registry (curated or org-fetched)
    ///     unknown OsaurusAI ids are rejected.
    ///   - Other orgs: require an MLX/vMLX artifact-family hint in the repo id
    ///     AND HF metadata confirming MLX compatibility.
    func resolveModelIfMLXCompatible(byRepoId repoId: String) async -> MLXModel? {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let existing = findExistingModel(id: trimmed).model { return existing }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("osaurusai/") {
            // Not in registry (would have returned above) — reject.
            return nil
        }

        if lower.hasPrefix("mlx-community/") {
            guard await HuggingFaceService.shared.isMLXCompatible(repoId: trimmed) else { return nil }
        } else {
            guard Self.nameLooksLikeMLX(trimmed),
                await HuggingFaceService.shared.isMLXCompatible(repoId: trimmed)
            else { return nil }
        }

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
    func pauseDownload(_ modelId: String) { downloadService.pause(modelId) }
    func resumeDownload(_ modelId: String) {
        guard let model = resolveModel(byRepoId: modelId) else { return }
        downloadService.resume(model)
    }
    func deleteModel(_ model: MLXModel) async { await downloadService.delete(model) }

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
    var downloadAlert: ModelDownloadService.DownloadAlertInfo? {
        get { downloadService.downloadAlert }
        set { downloadService.downloadAlert = newValue }
    }

    /// Deduplicated merge of suggestedModels + availableModels, preferring curated descriptions.
    ///
    /// Order is deterministic: rows keep the insertion order of `combined`
    /// (suggestedModels first, then availableModels). Earlier this returned
    /// `Dictionary.values`, whose iteration order is unspecified and reshuffles
    /// between calls — so any view that recomputed on a tick (e.g. the
    /// onboarding picker observing `SystemMonitorService`'s 2s timer) saw the
    /// rows jump around. Preserving insertion order keeps the list stable.
    func deduplicatedModels() -> [MLXModel] {
        let combined = suggestedModels + availableModels
        var ordered: [MLXModel] = []
        var indexByLowerId: [String: Int] = [:]
        for m in combined {
            let key = m.id.lowercased()
            if let existingIndex = indexByLowerId[key] {
                let existingIsDiscovered =
                    ordered[existingIndex].description == "Discovered on Hugging Face"
                let currentIsDiscovered = m.description == "Discovered on Hugging Face"
                // Swap a richer (curated) entry into the slot a discovered
                // placeholder already occupies, keeping the original position.
                if existingIsDiscovered && !currentIsDiscovered {
                    ordered[existingIndex] = m
                }
            } else {
                indexByLowerId[key] = ordered.count
                ordered.append(m)
            }
        }
        return ordered
    }

    // MARK: - Private Methods

    /// Heuristic for non-allowlisted orgs: the repo id should advertise MLX/vMLX
    /// compatibility in its name. Do not require the literal token `MLX` only:
    /// JANG/JANGTQ/MXFP/TurboQuant uploads are MLX-native artifact families and
    /// should reach the Hugging Face metadata check instead of being rejected by
    /// title text alone.
    nonisolated static func nameLooksLikeMLX(_ repoId: String) -> Bool {
        let lower = repoId.lowercased()
        return lower.contains("-mlx") || lower.contains("_mlx") || lower.hasSuffix("/mlx")
            || lower.contains("mlx-")
            || lower.contains("-mxfp") || lower.contains("_mxfp")
            || lower.contains("-jang") || lower.contains("_jang")
            || lower.contains("-jangtq") || lower.contains("_jangtq")
            || lower.contains("turboquant")
    }

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

    /// Builds a curated `MLXModel` from a single HF repo id. The id is the
    /// canonical source for `name` (via `friendlyName`) and `downloadURL`,
    /// so all three can never drift out of sync — the duplication that
    /// previously hid the `Nemotron-3-Nano-Omni-30B-A3B-JANGTQ` slug typo
    /// is no longer possible.
    nonisolated fileprivate static func curated(
        id: String,
        description: String,
        isTopSuggestion: Bool = false,
        modelType: String? = nil,
        releasedAt: Date? = nil,
        useCase: ModelUseCase? = nil
    ) -> MLXModel {
        MLXModel(
            id: id,
            name: ModelMetadataParser.friendlyName(from: id),
            description: description,
            downloadURL: "https://huggingface.co/\(id)",
            isTopSuggestion: isTopSuggestion,
            downloadSizeBytes: nil,
            modelType: modelType,
            releasedAt: releasedAt,
            useCase: useCase
        )
    }

    /// Fully curated models with descriptions we control.
    /// Order is a fallback only — `ModelDownloadView.filteredSuggestedModels`
    /// sorts by curated-first → top-pick → `releasedAt` desc → name.
    nonisolated fileprivate static let curatedSuggestedModels: [MLXModel] = [
        // MARK: Top Picks

        curated(
            id: "OsaurusAI/LFM2.5-8B-A1B-MXFP8",
            description:
                "Liquid AI LFM2.5 8B hybrid MoE (~1B active), MXFP8 — high-precision, fast Apple Silicon chat. 128K context.",
            isTopSuggestion: true,
            modelType: "lfm2_moe",
            releasedAt: date("2026-05-29"),
            useCase: .general
        ),

        // MARK: Gemma 4 — multimodal (onboarding default spine)
        //
        // The dense Gemma 4 QAT line (E2B/E4B/12B/31B, `qat-MXFP4`) is the
        // onboarding auto-default spine: quantization-aware training beats
        // post-training quant at equal bit-width, and these are the newest
        // Gemma builds. `ConfigureAIState.recommendedLocalPick` auto-selects
        // the largest *dense* QAT model that comfortably fits. The 26B-A4B
        // QAT MoE below stays a Top Pick but is intentionally excluded from
        // the auto-default (its footprint is the 36%-bounce risk), and the
        // E-series QAT entries are excluded from the auto-default until the
        // 8-bit-vs-QAT-4bit retention A/B clears (small tiers stay on the
        // 8-bit builds). Top-Pick promotion of the QAT line is gated on the
        // required AgentLoop tool-use proof for the active Gemma 4 QAT
        // checkpoint (load, executed tool, tool-result continuation, clean
        // visible text, no marker leakage, cache telemetry).

        curated(
            id: "OsaurusAI/gemma-4-12B-it-MXFP8",
            description:
                "Gemma 4 12B multimodal — images, video, and audio at high-precision MXFP8. 128K context.",
            isTopSuggestion: true,
            modelType: "gemma4",
            releasedAt: date("2026-06-01"),
            useCase: .vision
        ),

        curated(
            id: "OsaurusAI/gemma-4-E2B-it-qat-MXFP4",
            description:
                "Gemma 4 E2B QAT — quantization-aware 4-bit. Smallest multimodal floor; better quality-per-byte than post-training 4-bit. Runs on any Mac. 128K context.",
            isTopSuggestion: true,
            modelType: "gemma4",
            releasedAt: date("2026-06-09"),
            useCase: .smallest
        ),

        curated(
            id: "OsaurusAI/gemma-4-E4B-it-qat-MXFP4",
            description:
                "Gemma 4 E4B QAT — quantization-aware 4-bit multimodal edge model. Images, video, and audio. 128K context.",
            isTopSuggestion: true,
            modelType: "gemma4",
            releasedAt: date("2026-06-09"),
            useCase: .vision
        ),

        curated(
            id: "OsaurusAI/gemma-4-12B-it-qat-MXFP4",
            description:
                "Gemma 4 12B dense QAT — quantization-aware 4-bit. The mainstream multimodal default for 16–24 GB Macs. 128K context.",
            isTopSuggestion: true,
            modelType: "gemma4",
            releasedAt: date("2026-06-09"),
            useCase: .vision
        ),

        curated(
            id: "OsaurusAI/gemma-4-31B-it-qat-MXFP4",
            description:
                "Gemma 4 31B dense QAT — quantization-aware 4-bit. Top-tier multimodal quality for 32 GB+ Macs. 128K context.",
            isTopSuggestion: true,
            modelType: "gemma4",
            releasedAt: date("2026-06-09"),
            useCase: .vision
        ),

        curated(
            id: "OsaurusAI/gemma-4-26B-A4B-it-qat-MXFP4",
            description:
                "Gemma 4 26B-A4B QAT — quantization-aware 4-bit MoE (~4B active) vision model. Selectable Top Pick; excluded from the low-RAM auto-default. 128K context.",
            isTopSuggestion: true,
            modelType: "gemma4",
            releasedAt: date("2026-06-09"),
            useCase: .vision
        ),

        // Lower-precision Gemma 4 edge fallbacks (NOT defaults). Within the
        // E-series, 8-bit retains far better than 4-bit (E4B: 17% vs 33%
        // bounce; E2B: median 19 vs 2 messages). The 4-bit builds stay listed
        // only as the smallest-download option for the most RAM-constrained
        // Macs; the 8-bit builds (below) are the recommended edge picks.
        curated(
            id: "OsaurusAI/gemma-4-E4B-it-4bit",
            description:
                "Smallest-download E4B build — lower-precision 4-bit fallback. Prefer the 8-bit or QAT E4B for better first-run quality.",
            modelType: "gemma4",
            releasedAt: date("2026-04-06"),
            useCase: .vision
        ),

        curated(
            id: "OsaurusAI/gemma-4-E2B-it-4bit",
            description:
                "Smallest-download Gemma 4 build — lowest-precision 4-bit fallback. Runs on any Mac.",
            modelType: "gemma4",
            releasedAt: date("2026-04-06"),
            useCase: .smallest
        ),

        // MARK: Qwen 3.6
        //
        // Qwen 3.6 keeps the `qwen3_5_moe` / `qwen3_5` model_type identifier,
        // so vmlx-swift's existing Qwen35Model / Qwen35MoEModel classes
        // handle it. JANGTQ variants use the same model_type but are routed
        // to Qwen35JANGTQModel at load time based on jang_config.weight_format
        // (`"mxtq"`) — no osaurus-side branching required.

        curated(
            id: "OsaurusAI/Qwen3.6-27B-MXFP4",
            description:
                "Qwen 3.6 27B dense vision model. MXFP4 — best quality per byte. The org's most-downloaded model. 256K context.",
            isTopSuggestion: true,
            modelType: "qwen3_5",
            releasedAt: date("2026-05-20"),
            useCase: .vision
        ),

        curated(
            id: "OsaurusAI/Qwen3.6-27B-MXFP8-MTP",
            description:
                "Qwen 3.6 27B dense vision model. MXFP8 + multi-token-prediction speculative decode — high precision, fast. 256K context.",
            isTopSuggestion: true,
            modelType: "qwen3_5",
            releasedAt: date("2026-05-20"),
            useCase: .vision
        ),

        curated(
            id: "OsaurusAI/Qwen3.6-35B-A3B-MXFP8-MTP",
            description:
                "Qwen 3.6 35B MoE (~3B active) vision model. MXFP8 + multi-token-prediction speculative decode — the precision-first sibling of the MXFP4 build. 256K context.",
            isTopSuggestion: true,
            modelType: "qwen3_5_moe",
            releasedAt: date("2026-05-20"),
            useCase: .vision
        ),

        // Lower-precision MoE sibling — kept in the catalog, demoted from Top
        // Pick in favour of the MXFP8-MTP build above (precision-first; avoids
        // two near-identical Qwen 3.6 35B top picks).
        curated(
            id: "OsaurusAI/Qwen3.6-35B-A3B-mxfp4",
            description:
                "Qwen 3.6 35B MoE vision model. MXFP4 quantization — best quality per byte. 256K context.",
            modelType: "qwen3_5_moe",
            releasedAt: date("2026-04-16"),
            useCase: .vision
        ),

        // MARK: MiniMax M2.7 (JANGTQ MoE)
        //
        // 228.7B total / ~1.4B active MoE (256 experts, top-8) with 192K context.
        // Always-reasoning chat template. Auto-routed to MiniMaxJANGTQModel via
        // jang_config.json (`weight_format: mxtq`) at load time — no osaurus-side
        // branching required.

        curated(
            id: "OsaurusAI/MiniMax-M2.7-JANGTQ4",
            description:
                "MiniMax M2.7 228B agentic MoE, 4-bit TurboQuant routed experts. Near-bf16 quality at ~25% of bf16 disk. 192K context.",
            modelType: "minimax_m2",
            releasedAt: date("2026-04-17"),
            useCase: .general
        ),

        curated(
            id: "OsaurusAI/MiniMax-M2.7-JANGTQ",
            description:
                "MiniMax M2.7 228B agentic MoE, 2-bit TurboQuant routed experts. Smallest footprint of the family. 192K context.",
            modelType: "minimax_m2",
            releasedAt: date("2026-04-17"),
            useCase: .general
        ),

        curated(
            id: "OsaurusAI/MiniMax-M2.7-Small-JANGTQ",
            description:
                "MiniMax M2.7 Small agentic MoE, TurboQuant routed experts — the most-liked OsaurusAI model. 192K context.",
            modelType: "minimax_m2",
            releasedAt: date("2026-06-05"),
            useCase: .general
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

        // AUDIT FLAG (quality decision, not hard-changed): this MXFP4 build
        // is the Top Pick ("fastest decode"), but its `JANGTQ4` sibling below
        // is described as "near-bf16 quality." If near-bf16 holds, JANGTQ4 may
        // be the better first-impression default. Decide MXFP4-speed vs
        // JANGTQ4-quality (with real decode + quality proof) before swapping
        // the Top-Pick flag.
        curated(
            id: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4",
            description:
                "NVIDIA Nemotron-3 30B Reasoning hybrid (Mamba-2 + MoE). MXFP4 quantization — fastest decode path. 262K context.",
            isTopSuggestion: true,
            modelType: "nemotron_h",
            releasedAt: date("2026-04-28"),
            useCase: .reasoning
        ),

        curated(
            id: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ4",
            description:
                "Nemotron-3 30B Reasoning hybrid, 4-bit TurboQuant routed experts. Near-bf16 quality at ~37 GB. 262K context.",
            modelType: "nemotron_h",
            releasedAt: date("2026-04-28"),
            useCase: .reasoning
        ),

        curated(
            id: "OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-JANGTQ2",
            description:
                "Nemotron-3 30B Reasoning hybrid, 2-bit TurboQuant routed experts. Smallest footprint (~21 GB). 262K context.",
            modelType: "nemotron_h",
            releasedAt: date("2026-04-28"),
            useCase: .reasoning
        ),

        // MARK: ZAYA1 (CCA hybrid attention — reasoning + tool use)
        //
        // 8B reasoning + tool-use model with CCA hybrid attention. Kept as
        // catalog (non-Top-Pick) pending the ZAYA CCA companion-cache +
        // pooling proof required by the runtime non-negotiables; promote to a
        // Top Pick (it's small) only after that proof lands. `modelType` is
        // left to runtime auto-detection from config.json — no pre-download
        // hint is hardcoded for a family whose `model_type` isn't confirmed.

        curated(
            id: "OsaurusAI/ZAYA1-8B-MXFP4",
            description:
                "ZAYA1 8B reasoning + tool-use model with CCA hybrid attention. MXFP4 quantization.",
            releasedAt: date("2026-06-05"),
            useCase: .reasoning
        ),

        curated(
            id: "OsaurusAI/ZAYA1-8B-JANGTQ4",
            description:
                "ZAYA1 8B reasoning + tool-use, 4-bit TurboQuant routed experts. CCA hybrid attention.",
            releasedAt: date("2026-06-05"),
            useCase: .reasoning
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

        curated(
            id: "OsaurusAI/Laguna-XS.2-mxfp4",
            description:
                "Poolside Laguna-XS.2 33B/3B-active agentic-coding MoE. MXFP4 quant — fastest decode. 131K context, 256 experts top-8.",
            modelType: "laguna",
            releasedAt: date("2026-04-30"),
            useCase: .coding
        ),

        curated(
            id: "OsaurusAI/Laguna-XS.2-JANGTQ",
            description:
                "Poolside Laguna-XS.2 33B/3B-active agentic-coding MoE, 2-bit TurboQuant routed experts. Smallest footprint (~10 GB). 131K context.",
            modelType: "laguna",
            releasedAt: date("2026-04-30"),
            useCase: .coding
        ),

        // MARK: Ling-2.6 Flash (BailingHybrid)
        //
        // Alibaba Ling-2.6 Flash ships as BailingHybrid (`model_type=
        // bailing_hybrid`) with Linear-Attn + MLA + routed MoE. vmlx routes
        // both MXFP4 and JANGTQ bundles through the same BailingHybrid
        // factory based on config / jang_config metadata; osaurus only needs
        // to surface the curated entries and pass the model_type hint early.
        //
        // The chat template does not consume the generic `enable_thinking`
        // kwarg used by Qwen/Nemotron/Laguna directly. The vmlx pin maps
        // the shared Disable Thinking option to the template's required
        // "detailed thinking on/off" system directive inside the Bailing
        // input processor, before tokenizer rendering.

        curated(
            id: "OsaurusAI/Ling-2.6-flash-MXFP4",
            description:
                "Ling-2.6 Flash BailingHybrid MoE. MXFP4 quantization for the highest quality Ling local path.",
            modelType: "bailing_hybrid",
            releasedAt: date("2026-05-06"),
            useCase: .general
        ),

        curated(
            id: "OsaurusAI/Ling-2.6-flash-JANGTQ",
            description:
                "Ling-2.6 Flash BailingHybrid MoE with TurboQuant routed experts. Smaller local footprint for Mac inference.",
            modelType: "bailing_hybrid",
            releasedAt: date("2026-05-06"),
            useCase: .general
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
        // vmlx-swift's `mistral3` factory branches on
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

        curated(
            id: "OsaurusAI/Mistral-Medium-3.5-128B-mxfp4",
            description:
                "Mistral Medium 3.5 128B + Pixtral vision. MXFP4 quant — fastest decode. 256K context, 24-language coverage.",
            modelType: "mistral3",
            releasedAt: date("2026-04-30"),
            useCase: .vision
        ),

        curated(
            id: "OsaurusAI/Mistral-Medium-3.5-128B-JANGTQ",
            description:
                "Mistral Medium 3.5 128B + Pixtral vision, 2-bit TurboQuant text decoder. ~41 GB footprint. 256K context, 24-language coverage.",
            modelType: "mistral3",
            releasedAt: date("2026-04-30"),
            useCase: .vision
        ),

        // MARK: gemma-4-12B (lower-precision companion)

        curated(
            id: "OsaurusAI/gemma-4-12B-it-MXFP4",
            description:
                "Gemma 4 12B multimodal at MXFP4 — smaller, lower-precision companion to the 12B MXFP8 Top Pick. 128K context.",
            modelType: "gemma4",
            releasedAt: date("2026-06-01"),
            useCase: .vision
        ),

        // MARK: Large / specialist catalog
        //
        // Never onboarding auto-defaults. Each is gated on real Osaurus load +
        // decode + architecture-correct cache proof before any Top-Pick
        // promotion. `modelType` hints below are inferred from HF tags and are
        // confirmed/overridden by runtime auto-detection from each repo's
        // config.json at load time.

        curated(
            id: "OsaurusAI/DeepSeek-V4-Flash-JANGTQ2",
            description:
                "DeepSeek V4 Flash reasoning model, 2-bit TurboQuant. CSA/HSA/SWA hybrid attention. Large specialist footprint.",
            modelType: "deepseek_v4",
            releasedAt: date("2026-06-05"),
            useCase: .reasoning
        ),

        curated(
            id: "OsaurusAI/DeepSeek-V4-Flash-JANGTQ-K",
            description:
                "DeepSeek V4 Flash reasoning model, K-quant TurboQuant. CSA/HSA/SWA hybrid attention. Large specialist footprint.",
            modelType: "deepseek_v4",
            releasedAt: date("2026-06-05"),
            useCase: .reasoning
        ),

        curated(
            id: "OsaurusAI/Kimi-K2.6-JANGTQ_K",
            description:
                "Kimi K2.6 vision model, K-quant TurboQuant. Large specialist footprint.",
            modelType: "kimi_k25",
            releasedAt: date("2026-06-05"),
            useCase: .vision
        ),

        curated(
            id: "OsaurusAI/Hy3-preview-JANGTQ_K",
            description:
                "Hunyuan 3 (295B MoE) preview, K-quant TurboQuant. Very large specialist footprint.",
            modelType: "hy_v3",
            releasedAt: date("2026-06-05"),
            useCase: .general
        ),

        curated(
            id: "OsaurusAI/NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L",
            description:
                "NVIDIA Nemotron-3 Ultra 550B (~55B active) reasoning MoE, TurboQuant. Showcase — requires very high unified memory.",
            modelType: "nemotron_h",
            releasedAt: date("2026-06-05"),
            useCase: .reasoning
        ),

        curated(
            id: "OsaurusAI/Step-3.7-Flash-JANG_K",
            description:
                "Step 3.7 Flash vision-language model, JANG K-quant. Specialist.",
            modelType: "step3p7",
            releasedAt: date("2026-06-05"),
            useCase: .vision
        ),

        curated(
            id: "OsaurusAI/Holo3-35B-A3B-mxfp4",
            description:
                "Holo3 35B-A3B computer-use GUI agent. MXFP4 vision MoE. Specialist.",
            modelType: "qwen3_5_moe",
            releasedAt: date("2026-06-05"),
            useCase: .coding
        ),

        curated(
            id: "OsaurusAI/Holo3-35B-A3B-JANGTQ4",
            description:
                "Holo3 35B-A3B computer-use GUI agent, 4-bit TurboQuant. Vision MoE. Specialist.",
            modelType: "qwen3_5_moe",
            releasedAt: date("2026-06-05"),
            useCase: .coding
        ),

        // MARK: Gemma 4 E-series — 8-bit retention builds (Top Picks)
        //
        // Within the E-series, 8-bit retains far better than 4-bit, so these
        // are the recommended high-precision edge picks (not the demoted
        // 4-bit fallbacks above). `releasedAt` is bumped to mid-2026 so the
        // newest-first Top Picks carousel surfaces these retention builds near
        // the top instead of stranding them at the tail with the April dates.

        curated(
            id: "OsaurusAI/gemma-4-E4B-it-8bit",
            description:
                "Recommended multimodal edge model — 8-bit precision, the best first-run quality for the E4B family (highest retention). Images, video, audio. 128K context.",
            isTopSuggestion: true,
            modelType: "gemma4",
            releasedAt: date("2026-06-02"),
            useCase: .vision
        ),

        curated(
            id: "OsaurusAI/gemma-4-E2B-it-8bit",
            description:
                "Smallest high-precision multimodal model — 8-bit, the best quality that still runs on any Mac. 128K context.",
            isTopSuggestion: true,
            modelType: "gemma4",
            releasedAt: date("2026-06-02"),
            useCase: .smallest
        ),
    ]

    /// Lowercased IDs of curated entries. Used by the Recommended-tab sort to
    /// pin curated models above auto-fetched org listings.
    nonisolated static let curatedSuggestedIds: Set<String> = Set(
        curatedSuggestedModels.map { $0.id.lowercased() }
    )

    /// OsaurusAI org repos intentionally retired from the catalog (superseded
    /// / lower-precision dupes). The org auto-fetch would otherwise re-surface
    /// them as plain non-curated rows, defeating the removal — so the merge in
    /// `applyOsaurusOrgFetch` drops any auto-fetched entry whose id is in this
    /// set. Lowercased for matching.
    nonisolated static let retiredOsaurusOrgIds: Set<String> = [
        "osaurusai/qwen3.5-122b-a10b-jang_4k",
        "osaurusai/qwen3.5-122b-a10b-jang_2s",
        "osaurusai/qwen3.5-35b-a3b-jang_4k",
        "osaurusai/qwen3.5-35b-a3b-jang_2s",
        "osaurusai/gemma-4-31b-it-jang_4m",
        "osaurusai/gemma-4-26b-a4b-it-4bit",
        "osaurusai/gemma-4-26b-a4b-it-jang_2l",
        "osaurusai/gemma-4-26b-a4b-it-jang_4m",
        "osaurusai/gemma-4-26b-a4b-it-mxfp4",
        "osaurusai/diffusiongemma-26b-a4b-it-mxfp8",
    ]

    /// HF `pipeline_tag` values that mark a repo as chat-capable (text or
    /// multimodal generation). The org auto-fetch only admits repos whose
    /// pipeline tag is in this set — guards (`token-classification`),
    /// embeddings (`feature-extraction`/`sentence-similarity`), image
    /// pipelines, and speech repos all belong to other Settings panels and
    /// must not surface as chat cards in the Models catalog.
    nonisolated static let chatCapablePipelineTags: Set<String> = [
        "text-generation",
        "text2text-generation",
        "image-text-to-text",
        "audio-text-to-text",
        "video-text-to-text",
        "any-to-any",
    ]

    /// OsaurusAI org repos owned by other Settings panels (Privacy, Voice,
    /// Memory, Images) that must never appear as chat cards, even when the
    /// repo has no `pipeline_tag` on HF. Belt-and-braces alongside the
    /// pipeline-tag gate; lowercased for matching.
    nonisolated static var panelOwnedOrgIds: Set<String> {
        [
            RampartModelManager.repoId.lowercased()
        ]
    }

    /// True when an OsaurusAI org repo may appear in the LLM catalog.
    /// Untagged repos pass (MLX conversions frequently omit `pipeline_tag`,
    /// so `nil` is not evidence of a non-chat repo) unless they are owned by
    /// another Settings panel.
    nonisolated static func isChatCatalogEligible(id: String, pipelineTag: String?) -> Bool {
        if panelOwnedOrgIds.contains(id.lowercased()) { return false }
        guard let tag = pipelineTag?.lowercased(), !tag.isEmpty else { return true }
        return chatCapablePipelineTags.contains(tag)
    }
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
    nonisolated static func findInstalledMLXModel(named name: String) -> MLXModel? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let models = discoverLocalModels()

        // Try repo component first
        if let match = models.first(where: { m in
            m.id.split(separator: "/").last.map(String.init)?.lowercased() == trimmed.lowercased()
        }) {
            return match
        }

        // Try full id match
        if let match = models.first(where: { m in m.id.lowercased() == trimmed.lowercased() }) {
            return match
        }
        return nil
    }

    /// Find an installed model by user-provided name, returning the canonical
    /// picker key and model id. Callers that need files inside the bundle must
    /// use `findInstalledMLXModel(named:)` and `MLXModel.localDirectory` so
    /// externally-discovered and symlinked bundles keep their real path.
    nonisolated static func findInstalledModel(named name: String) -> (name: String, id: String)? {
        guard let match = findInstalledMLXModel(named: name) else { return nil }
        let repo =
            match.id.split(separator: "/").last.map(String.init)?.lowercased()
            ?? name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (repo, match.id)
    }
}

// MARK: - Hugging Face discovery helpers

extension ModelManager {
    fileprivate struct HFModel: Decodable {
        let id: String
        let tags: [String]?
        let pipeline_tag: String?
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

    /// Resolve the accurate download size for `repoId`, preferring the
    /// `ModelSizeCache` and only hitting the network when the cache is
    /// missing or its revision no longer matches `revision`.
    ///
    /// "Download size" here is the sum of just the files Osaurus actually
    /// writes to disk (the `ModelDownloadService.downloadFilePatterns`
    /// set), not the whole-repo `usedStorage` HF reports — that over-counts
    /// READMEs, `.gitattributes`, alternate-format weights, etc.
    ///
    /// `revision` is the HF `lastModified` string from the org listing.
    /// When it matches the cached entry we skip the network entirely, so a
    /// steady-state launch issues no tree requests at all. When `nil`
    /// (callers without a cheap revision signal) the cache's TTL applies.
    fileprivate static func resolveDownloadSize(
        repoId: String,
        revision: String?
    ) async -> Int64? {
        if let cached = ModelSizeCache.bytes(forId: repoId, matchingRevision: revision) {
            return cached
        }
        let fetched = await HuggingFaceService.shared.estimateTotalSize(
            repoId: repoId,
            patterns: ModelDownloadService.downloadFilePatterns,
            excludedFiles: ModelDownloadService.downloadExcludedFiles
        )
        if let fetched {
            ModelSizeCache.record(id: repoId, bytes: fetched, revision: revision)
        }
        return fetched
    }

    /// Request HF models at URL
    fileprivate static func requestHFModels(at url: URL) async throws -> [HFModel] {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await GlobalProxySettings.sharedSession().data(for: request)
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
    /// The use-case pill is inferred where the HF metadata supports it
    /// (multimodal tags → Vision) so auto-fetched cards aren't all blank
    /// next to curated ones.
    fileprivate static func makeAutoFetchedModel(from hf: HFModel) -> MLXModel {
        let modelType = inferModelType(from: hf.tags)
        let isMultimodal =
            modelType.map { VLMDetection.isVLM(modelType: $0) } ?? false
            || (hf.pipeline_tag?.lowercased() == "image-text-to-text")
        return MLXModel(
            id: hf.id,
            name: ModelMetadataParser.friendlyName(from: hf.id),
            description: "From OsaurusAI on Hugging Face.",
            downloadURL: "https://huggingface.co/\(hf.id)",
            modelType: modelType,
            releasedAt: parseHFTimestamp(hf.lastModified),
            downloads: hf.downloads,
            useCase: isMultimodal ? .vision : nil
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

        let fetched = (try? await Self.requestHFModels(at: url)) ?? []
        guard !fetched.isEmpty else { return }

        // Drop repos that other Settings panels own (rampart PII guard,
        // embeddings, image/speech pipelines) before they can become chat
        // cards. Curated entries never pass through this gate — they merge
        // from `curatedSuggestedModels` directly.
        let raw = fetched.filter {
            Self.isChatCatalogEligible(id: $0.id, pipelineTag: $0.pipeline_tag)
        }
        guard !raw.isEmpty else { return }

        let curatedIds = Self.curatedSuggestedIds
        let autoFetched: [MLXModel] =
            raw
            .filter { !curatedIds.contains($0.id.lowercased()) }
            .map(Self.makeAutoFetchedModel(from:))

        var statsById: [String: Int] = [:]
        // HF `lastModified` per repo — the revision used to gate the size
        // cache so we only re-fetch a repo's tree when it actually changes.
        var revisionById: [String: String] = [:]
        for hf in raw {
            if let count = hf.downloads {
                statsById[hf.id.lowercased()] = count
            }
            if let revision = hf.lastModified {
                revisionById[hf.id.lowercased()] = revision
            }
        }

        // Repos to size: every repo in the org listing plus any curated
        // entries that aren't OsaurusAI-org-published (e.g.
        // `lmstudio-community/gpt-oss-*`, `LiquidAI/...`) so their sizes get
        // fetched + cached too. Curated repos absent from the listing have
        // no `lastModified`, so they fall back to the cache's TTL.
        var repoIdsToSize: [String] = raw.map { $0.id }
        var seenSizeIds = Set(repoIdsToSize.map { $0.lowercased() })
        for model in Self.curatedSuggestedModels where seenSizeIds.insert(model.id.lowercased()).inserted {
            repoIdsToSize.append(model.id)
        }

        // The /api/models listing endpoint doesn't return file sizes, so
        // fan out one tree request per repo that needs (re)sizing. The
        // revision gate means cached repos resolve without any network, so
        // a steady-state refresh issues just the single listing request.
        // URLSession multiplexes the rest over a few HTTP/2 connections.
        let sizesById: [String: Int64] = await withTaskGroup(of: (String, Int64?).self) { group in
            for repoId in repoIdsToSize {
                let revision = revisionById[repoId.lowercased()]
                group.addTask {
                    (
                        repoId.lowercased(),
                        await Self.resolveDownloadSize(repoId: repoId, revision: revision)
                    )
                }
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
    /// per-repo download-size byte counts (sum of the files Osaurus
    /// downloads, resolved via `ModelSizeCache` + the tree API). Both flow
    /// into curated entries and auto-fetched entries at merge time.
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
        let enrichedAutoFetched =
            autoFetched
            .filter { !Self.retiredOsaurusOrgIds.contains($0.id.lowercased()) }
            .filter { !Self.panelOwnedOrgIds.contains($0.id.lowercased()) }
            .map(enrich)

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
    private static nonisolated let localModelsCacheCondition = NSCondition()
    private static nonisolated(unsafe) var cachedLocalModels: [MLXModel]?
    private static nonisolated(unsafe) var localModelsScanInFlight = false
    private static nonisolated let localModelsScanWaitLimit: TimeInterval = 10
    private static nonisolated(unsafe) var lastLocalModelsScanDiagnostic: [String: Any]?
    nonisolated(unsafe) static var scanLocalModelsOverrideForTests: ((URL) -> [MLXModel])?
    nonisolated(unsafe) static var localModelsScanWaitLimitOverrideForTests: TimeInterval?

    nonisolated static func invalidateLocalModelsCache() {
        localModelsCacheCondition.lock()
        cachedLocalModels = nil
        localModelsScanInFlight = false
        localModelsCacheCondition.broadcast()
        localModelsCacheCondition.unlock()
        LocalReasoningCapability.invalidate()
        LocalGenerationDefaults.invalidate()
    }

    nonisolated static func localModelsScanDiagnosticJSONObject() -> [String: Any]? {
        localModelsCacheCondition.lock()
        let diagnostic = lastLocalModelsScanDiagnostic
        localModelsCacheCondition.unlock()
        return diagnostic
    }

    /// Run the blocking local-model discovery off the main actor.
    /// `discoverLocalModels()` waits (up to 10s) on the background scan, so it
    /// is dispatched to a GCD queue that can grow on demand. Calling it
    /// directly from an `async` context would block a Swift cooperative-pool
    /// thread for the duration of that wait and can starve the pool (delaying
    /// every other in-flight `Task`); the continuation suspends the caller
    /// instead of blocking it.
    nonisolated static func discoverLocalModelsOffMain() async -> [MLXModel] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: discoverLocalModels())
            }
        }
    }

    /// Discover locally downloaded models. Cached until invalidated by model download/delete.
    nonisolated static func discoverLocalModels() -> [MLXModel] {
        func waitForLocalModelsScan(until deadline: Date) -> [MLXModel]? {
            while localModelsScanInFlight && cachedLocalModels == nil {
                if !localModelsCacheCondition.wait(until: deadline) {
                    break
                }
            }
            return cachedLocalModels
        }

        localModelsCacheCondition.lock()
        if let cached = cachedLocalModels {
            localModelsCacheCondition.unlock()
            return mergeExternalModels(into: cached)
        }

        // Cache miss: the call below parks on `localModelsCacheCondition.wait`
        // (up to `localModelsScanWaitLimit`, ~10s) for the background scan. On
        // the main thread that is a user-visible hang/beachball — UI and hot
        // paths (chat greeting, residency planning) must call
        // `discoverLocalModelsOffMain()` instead. Surface a regression loudly
        // rather than letting it silently beachball; behavior is unchanged.
        if Thread.isMainThread {
            Self.discoveryLog.error(
                "discoverLocalModels() called on the MAIN THREAD with a cold cache — it may block up to \(localModelsScanWaitLimitOverrideForTests ?? localModelsScanWaitLimit, privacy: .public)s. Use discoverLocalModelsOffMain() from UI/handoff paths."
            )
        }

        if localModelsScanInFlight {
            let waitLimit = localModelsScanWaitLimitOverrideForTests ?? localModelsScanWaitLimit
            let cached = waitForLocalModelsScan(until: Date().addingTimeInterval(waitLimit)) ?? []
            localModelsCacheCondition.unlock()
            return mergeExternalModels(into: cached)
        }

        let waitLimit = localModelsScanWaitLimitOverrideForTests ?? localModelsScanWaitLimit
        let deadline = Date().addingTimeInterval(waitLimit)
        localModelsScanInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let scanned = scanLocalModels()

            localModelsCacheCondition.lock()
            cachedLocalModels = scanned
            localModelsScanInFlight = false
            localModelsCacheCondition.broadcast()
            localModelsCacheCondition.unlock()
        }

        if let cached = waitForLocalModelsScan(until: deadline) {
            localModelsCacheCondition.unlock()
            return mergeExternalModels(into: cached)
        } else {
            let cached = cachedLocalModels ?? []
            localModelsCacheCondition.unlock()
            return mergeExternalModels(into: cached)
        }
    }

    private nonisolated static func mergeExternalModels(into scanned: [MLXModel]) -> [MLXModel] {
        // Append externally-discovered bundles (HF cache, LM Studio). Read
        // fresh from the locator's in-memory registry each call (cheap) so a
        // background rescan is reflected without invalidating the disk-scan
        // cache above. Locally-present models win on id collision.
        let external = ExternalModelLocator.models()
        guard !external.isEmpty else { return scanned }
        let scannedIds = Set(scanned.map { $0.id.lowercased() })
        return scanned + external.filter { !scannedIds.contains($0.id.lowercased()) }
    }

    private nonisolated static func scanLocalModels() -> [MLXModel] {
        let root = DirectoryPickerService.effectiveModelsDirectory()
        if let override = scanLocalModelsOverrideForTests {
            return override(root)
        }
        return scanLocalModels(at: root)
    }

    /// Internal entry point used by tests so they can supply a fixture root.
    /// Detects both the flat (`<root>/<modelDir>/`) and nested (`<root>/<org>/<repo>/`)
    /// layouts.
    internal nonisolated static func scanLocalModels(at root: URL) -> [MLXModel] {
        let fm = FileManager.default
        var rootIsDir: ObjCBool = false
        let rootExists = fm.fileExists(atPath: root.path, isDirectory: &rootIsDir)
        let rootReadable = access(root.path, R_OK | X_OK) == 0

        func publishDiagnostic(status: String, modelCount: Int, error: String?, currentPath: String? = nil) {
            let diagnostic: [String: Any] = [
                "root": root.path,
                "root_exists": rootExists,
                "root_is_directory": rootExists && rootIsDir.boolValue,
                "root_readable": rootReadable,
                "status": status,
                "current_path": currentPath as Any? ?? NSNull(),
                "model_count": modelCount,
                "error": error as Any? ?? NSNull(),
                "scanned_at": Date().ISO8601Format(),
            ]
            localModelsCacheCondition.lock()
            lastLocalModelsScanDiagnostic = diagnostic
            localModelsCacheCondition.unlock()
        }
        publishDiagnostic(status: "started", modelCount: 0, error: nil)

        guard rootExists, rootIsDir.boolValue else {
            publishDiagnostic(status: "failed", modelCount: 0, error: "Model root is missing or is not a directory.")
            return []
        }

        var models: [MLXModel] = []
        var scanError: String?

        func exists(_ base: URL, _ name: String) -> Bool {
            access(base.appendingPathComponent(name).path, F_OK) == 0
        }

        func directoryEntryNames(_ dir: URL) -> [String]? {
            errno = 0
            guard let handle = opendir(dir.path) else { return nil }
            defer { closedir(handle) }

            var names: [String] = []
            while let entry = readdir(handle) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(
                        to: CChar.self,
                        capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
                    ) { cString in
                        String(cString: cString)
                    }
                }
                if name != "." && name != ".." {
                    names.append(name)
                }
            }
            return names
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

        /// True if `dir` contains config.json + a recognised tokenizer + model weights.
        ///
        /// Keep this probe bounded. Some local model roots point through
        /// symlinks to large external-drive bundles; a full directory listing
        /// can block the `/models` API path even though Hugging Face-style
        /// bundles expose stable weight sentinels.
        func isModelBundle(_ dir: URL) -> Bool {
            guard exists(dir, "config.json") else { return false }
            let hasTokenizerJSON = exists(dir, "tokenizer.json")
            let hasBPE =
                exists(dir, "merges.txt")
                && (exists(dir, "vocab.json") || exists(dir, "vocab.txt"))
            let hasSentencePiece =
                exists(dir, "tokenizer.model") || exists(dir, "spiece.model")
            guard hasTokenizerJSON || hasBPE || hasSentencePiece else { return false }

            if exists(dir, "model.safetensors") || exists(dir, "model.safetensors.index.json") {
                return true
            }

            // Common sharded names used by HF exports. Do not list plausible
            // model leaves here: external-drive bundles can block in opendir.
            // A bounded sentinel probe stays responsive and still covers high
            // shard counts seen in local JANG/JANGTQ bundles.
            for total in 1 ... 4096 {
                if exists(dir, "model-00001-of-\(String(format: "%05d", total)).safetensors") {
                    return true
                }
            }
            return false
        }

        func isModelLikeLeaf(_ dir: URL) -> Bool {
            exists(dir, "config.json")
                || exists(dir, "model.safetensors.index.json")
                || exists(dir, "model.safetensors")
                || exists(dir, "model_index.json")
                || exists(dir, "tokenizer.json")
                || exists(dir, "processor_config.json")
                || exists(dir, "preprocessor_config.json")
                || exists(dir, "audio_config.json")
                || exists(dir, "video_config.json")
        }

        func shouldDescendIntoLocalModelCandidate(_ entry: URL) -> Bool {
            let name = entry.lastPathComponent.lowercased()
            let skippedInfrastructureDirectories: Set<String> = [
                "__pycache__",
                "sources",
                "source",
                "cache",
                "tokenizer",
                "text_encoder",
                "transformer",
                "vae",
            ]
            return !skippedInfrastructureDirectories.contains(name)
        }

        func isLikelyOrganizationContainer(_ entry: URL) -> Bool {
            let name = entry.lastPathComponent
            // Model-leaf directory names carry several hyphen-separated parts
            // (e.g. "gemma-4-12B-it-qat-MXFP4"); organization containers are
            // short ("google", "JANGQ"). Hyphen count is the primary signal.
            guard name.split(separator: "-").count <= 2 else { return false }
            // Allow a domain-style org name such as "dealign.ai": a single dot
            // separating a short alphabetic top-level suffix. Without this,
            // every bundle under ~/models/dealign.ai/ (LFM2.5, Qwen3.6-MTP,
            // DeepSeek-V4) is silently invisible to discovery, while a
            // version-dotted model leaf like "laguna-xs.2" is still rejected
            // (its suffix "2" is non-alphabetic).
            let dotParts = name.split(separator: ".")
            if dotParts.count == 1 { return true }
            if dotParts.count == 2,
                let suffix = dotParts.last,
                (2 ... 4).contains(suffix.count),
                suffix.allSatisfy({ $0.isLetter })
            {
                return true
            }
            return false
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
            publishDiagnostic(status: "enumerating", modelCount: models.count, error: nil, currentPath: root.path)
            guard maxDepth > 0,
                let entryNames = directoryEntryNames(root)
            else {
                if prefix.isEmpty {
                    let code = errno
                    let message =
                        code == 0
                        ? "Unable to enumerate model root."
                        : String(cString: strerror(code))
                    scanError = "Unable to enumerate model root: \(message)"
                }
                return
            }

            let modelCountBeforeDirectPass = models.count
            for entryName in entryNames where !entryName.hasPrefix(".") {
                let entry = root.appendingPathComponent(entryName, isDirectory: true)
                guard shouldDescendIntoLocalModelCandidate(entry) else { continue }
                guard let resolved = resolvedDirectory(entry) else { continue }
                let nameComponents = prefix + [entry.lastPathComponent]
                if isModelBundle(resolved) {
                    let id = nameComponents.joined(separator: "/")
                    let model = MLXModel(
                        id: id,
                        name: ModelMetadataParser.friendlyName(from: id),
                        description: L("Local model (detected)"),
                        downloadURL: "https://huggingface.co/\(id)"
                    )
                    models.append(model)
                }
            }

            let foundDirectBundles = models.count > modelCountBeforeDirectPass

            for entryName in entryNames where !entryName.hasPrefix(".") {
                let entry = root.appendingPathComponent(entryName, isDirectory: true)
                guard shouldDescendIntoLocalModelCandidate(entry) else { continue }
                if foundDirectBundles && !isLikelyOrganizationContainer(entry) {
                    continue
                }
                guard let resolved = resolvedDirectory(entry) else { continue }
                if isModelLikeLeaf(resolved) {
                    continue
                }
                if maxDepth > 1 {
                    let nameComponents = prefix + [entry.lastPathComponent]
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
        publishDiagnostic(status: scanError == nil ? "finished" : "failed", modelCount: unique.count, error: scanError)
        return unique
    }
}
