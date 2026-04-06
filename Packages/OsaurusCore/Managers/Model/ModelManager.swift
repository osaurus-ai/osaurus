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
    var title: String { rawValue }
}

/// Manages MLX model downloads and storage
@MainActor
final class ModelManager: NSObject, ObservableObject {
    static let shared = ModelManager()

    /// Detailed metrics for an in-flight download
    struct DownloadMetrics: Equatable {
        let bytesReceived: Int64?
        let totalBytes: Int64?
        let bytesPerSecond: Double?
        let etaSeconds: Double?
    }

    /// State for filtering the model list
    struct ModelFilterState: Equatable {
        var type: MLXModel.ModelType? = nil
        var sizeCategory: SizeCategory? = nil
        var family: String? = nil
        var paramCategory: ParamCategory? = nil

        enum SizeCategory: String, CaseIterable, Identifiable {
            case small = "Small (<2 GB)"
            case medium = "Medium (2-4 GB)"
            case large = "Large (4 GB+)"
            var id: String { rawValue }

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
            type != nil || sizeCategory != nil || family != nil || paramCategory != nil
        }

        mutating func reset() {
            type = nil
            sizeCategory = nil
            family = nil
            paramCategory = nil
        }
    }

    // MARK: - Model Deprecation

    struct DeprecationNotice: Identifiable {
        let id: String
        let oldId: String
        let newId: String
    }

    /// Maps deprecated model IDs to their recommended OsaurusAI replacements.
    nonisolated static let deprecatedModelReplacements: [String: String] = [
        "mlx-community/gemma-4-31b-it-4bit": "OsaurusAI/Gemma-4-31B-it-JANG_4M",
        "mlx-community/gemma-4-26b-a4b-it-4bit": "OsaurusAI/Gemma-4-26B-A4B-it-JANG_2L",
        "mlx-community/gemma-4-e4b-it-8bit": "OsaurusAI/gemma-4-E4B-it-8bit",
        "mlx-community/gemma-4-e2b-it-4bit": "OsaurusAI/gemma-4-E2B-it-4bit",
        "mlx-community/Qwen3.5-27B-4bit": "OsaurusAI/Qwen3.5-122B-A10B-JANG_2S",
        "mlx-community/Qwen3.5-9B-MLX-4bit": "OsaurusAI/Qwen3.5-35B-A3B-JANG_4K",
        "mlx-community/Qwen3.5-4B-MLX-4bit": "OsaurusAI/Qwen3.5-35B-A3B-JANG_2S",
        "mlx-community/Qwen3.5-2B-MLX-4bit": "OsaurusAI/Qwen3.5-35B-A3B-JANG_2S",
        "mlx-community/Qwen3.5-0.8B-MLX-4bit": "OsaurusAI/Qwen3.5-35B-A3B-JANG_2S",
    ]

    // MARK: - Published Properties
    @Published var availableModels: [MLXModel] = []
    @Published var downloadStates: [String: DownloadState] = [:]
    @Published var isLoadingModels: Bool = false
    @Published var suggestedModels: [MLXModel] = ModelManager.curatedSuggestedModels
    @Published var downloadMetrics: [String: DownloadMetrics] = [:]
    @Published var deprecationNotices: [DeprecationNotice] = []

    // MARK: - Properties
    /// Glob patterns for files to download from a Hugging Face model repo
    static let downloadFilePatterns: [String] = [
        "config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "generation_config.json",
        "chat_template.jinja",
        "preprocessor_config.json",  // Required for VLM models
        "processor_config.json",  // Required for some models (e.g., Ministral)
        "*.safetensors",
    ]
    /// Current models directory (uses DirectoryPickerService for user selection)
    var modelsDirectory: URL {
        return DirectoryPickerService.shared.effectiveModelsDirectory
    }

    private var activeDownloadTasks: [String: Task<Void, Never>] = [:]  // modelId -> Task
    private var downloadTokens: [String: UUID] = [:]  // modelId -> token to gate progress/state updates
    private var cancellables = Set<AnyCancellable>()
    private var progressSamples: [String: [(timestamp: TimeInterval, completed: Int64)]] = [:]
    /// Last non-zero speed per download, used as fallback during upstream stalls
    private var lastKnownSpeed: [String: Double] = [:]
    private var remoteSearchTask: Task<Void, Never>? = nil

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
    }

    // MARK: - Public Methods

    /// Load popular MLX models
    func loadAvailableModels() {
        // Use full curated suggestions regardless of SDK allowlist so they are visible in All & Suggested
        let curated = Self.curatedSuggestedModels

        suggestedModels = curated
        availableModels = curated
        downloadStates = [:]
        for model in availableModels {
            downloadStates[model.id] = model.isDownloaded ? .completed : .notStarted
        }
        for sm in suggestedModels {
            downloadStates[sm.id] = sm.isDownloaded ? .completed : .notStarted
        }
        // Merge MLX registry-supported models into All
        let registry = Self.registryModels()
        mergeAvailable(with: registry)
        // Also surface any locally-downloaded models even if not on the SDK allowlist
        let localModels = Self.discoverLocalModels()
        mergeAvailable(with: localModels)

        isLoadingModels = false

        checkForDeprecatedModels()
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
        for model in availableModels {
            if activeDownloadTasks[model.id] != nil { continue }
            downloadStates[model.id] = model.isDownloaded ? .completed : .notStarted
        }
        for model in suggestedModels {
            if activeDownloadTasks[model.id] != nil { continue }
            downloadStates[model.id] = model.isDownloaded ? .completed : .notStarted
        }
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
        if let directId = Self.parseHuggingFaceRepoId(from: query), !directId.isEmpty {
            let exists = (availableModels + suggestedModels)
                .contains { $0.id.caseInsensitiveCompare(directId) == .orderedSame }
            if !exists {
                let friendly = Self.friendlyName(from: directId)
                var desc = "Imported from input"
                var model = MLXModel(
                    id: directId,
                    name: friendly,
                    description: desc,
                    downloadURL: "https://huggingface.co/\(directId)"
                )
                if model.isDownloaded {
                    desc = "Local model (detected)"
                    model = MLXModel(
                        id: directId,
                        name: friendly,
                        description: desc,
                        downloadURL: "https://huggingface.co/\(directId)"
                    )
                }
                availableModels.insert(model, at: 0)
                downloadStates[model.id] = model.isDownloaded ? .completed : .notStarted
            }
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

            // Merge and unique by id
            var byId: [String: HFModel] = [:]
            for arr in results { for m in arr { byId[m.id] = m } }

            // Filter to likely MLX-compatible
            let filtered = byId.values.filter { Self.isLikelyMLXCompatible($0) }

            // Map to MLXModel
            let mapped: [MLXModel] = filtered.map { hf in
                MLXModel(
                    id: hf.id,
                    name: Self.friendlyName(from: hf.id),
                    description: "Discovered on Hugging Face",
                    downloadURL: "https://huggingface.co/\(hf.id)",
                    rootDirectory: nil
                )
            }

            // Keep only SDK-supported models
            let allow = Self.sdkSupportedModelIds()
            let allowedMapped = mapped.filter { allow.contains($0.id.lowercased()) }

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

        // If the model exists locally, allow it regardless of allowlist membership
        let localModel = MLXModel(
            id: trimmed,
            name: Self.friendlyName(from: trimmed),
            description: "Local model (detected)",
            downloadURL: "https://huggingface.co/\(trimmed)"
        )
        if localModel.isDownloaded {
            if let existing = availableModels.first(where: {
                $0.id.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                return existing
            }
            if let existing = suggestedModels.first(where: {
                $0.id.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                return existing
            }
            availableModels.insert(localModel, at: 0)
            downloadStates[localModel.id] = .completed
            return localModel
        }
        // If already present in available or suggested (case-insensitive), return that instance.
        // Check this before the MLX heuristic so curated OsaurusAI models are always resolvable.
        if let existing = availableModels.first(where: { $0.id.lowercased() == trimmed.lowercased() }) {
            return existing
        }
        if let existing = suggestedModels.first(where: { $0.id.lowercased() == trimmed.lowercased() }) {
            availableModels.insert(existing, at: 0)
            downloadStates[existing.id] = existing.isDownloaded ? .completed : .notStarted
            return existing
        }

        // Validate MLX compatibility heuristically: org contains "mlx" or id contains "mlx"
        let lower = trimmed.lowercased()
        guard lower.contains("mlx") || lower.hasPrefix("mlx-community/") || lower.contains("-mlx")
        else {
            return nil
        }

        // Only allow models supported by the SDK
        let allow = Self.sdkSupportedModelIds()
        guard allow.contains(lower) else { return nil }

        // Construct a minimal MLXModel entry
        let name = Self.friendlyName(from: trimmed)
        let model = MLXModel(
            id: trimmed,
            name: name,
            description: "Imported from deeplink",
            downloadURL: "https://huggingface.co/\(trimmed)"
        )
        // Add to available list for UI visibility
        availableModels.insert(model, at: 0)
        // Initialize download state entry
        downloadStates[model.id] = model.isDownloaded ? .completed : .notStarted
        return model
    }

    /// Resolve a model only if the Hugging Face repository is MLX-compatible.
    /// Uses network metadata from Hugging Face for a reliable determination.
    /// Returns the existing or newly inserted `MLXModel` when compatible; otherwise nil.
    func resolveModelIfMLXCompatible(byRepoId repoId: String) async -> MLXModel? {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Only allow models supported by the SDK
        let allow = Self.sdkSupportedModelIds()
        guard allow.contains(trimmed.lowercased()) else { return nil }

        // If already present, return immediately
        if let existing = availableModels.first(where: {
            $0.id.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return existing
        }
        if let existing = suggestedModels.first(where: {
            $0.id.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return existing
        }

        // Ask HF for definitive compatibility
        let isCompatible = await HuggingFaceService.shared.isMLXCompatible(repoId: trimmed)
        guard isCompatible else { return nil }

        // Insert minimal entry so it appears in UI and can be downloaded
        let model = MLXModel(
            id: trimmed,
            name: Self.friendlyName(from: trimmed),
            description: "Imported from deeplink",
            downloadURL: "https://huggingface.co/\(trimmed)"
        )
        availableModels.insert(model, at: 0)
        downloadStates[model.id] = model.isDownloaded ? .completed : .notStarted
        return model
    }

    /// Kick off a download for a given Hugging Face repo id if resolvable to MLX.
    func downloadModel(withRepoId repoId: String) {
        guard let model = resolveModel(byRepoId: repoId) else { return }
        downloadModel(model)
    }

    /// Estimate total download size for a model.
    /// Only called from the detail view to avoid excessive API requests.
    func estimateDownloadSize(for model: MLXModel) async -> Int64? {
        return await HuggingFaceService.shared.estimateTotalSize(
            repoId: model.id,
            patterns: Self.downloadFilePatterns
        )
    }

    /// Download a model's files from Hugging Face
    func downloadModel(_ model: MLXModel) {
        let patterns = Self.downloadFilePatterns

        // If core assets are present but optional files from patterns are missing, we'll top-up.
        let needsTopUp = Self.isMissingExactPatternFiles(at: model.localDirectory, patterns: patterns)
        if model.isDownloaded && !needsTopUp {
            downloadStates[model.id] = .completed
            return
        }
        let state = downloadStates[model.id] ?? .notStarted
        switch state {
        case .downloading, .completed:
            return
        default:
            break
        }

        // Reset any previous task
        activeDownloadTasks[model.id]?.cancel()
        // Create a new token for this download session
        let token = UUID()
        downloadTokens[model.id] = token

        downloadStates[model.id] = .downloading(progress: 0.0)
        downloadMetrics[model.id] = DownloadMetrics(
            bytesReceived: 0,
            totalBytes: nil,
            bytesPerSecond: nil,
            etaSeconds: nil
        )
        progressSamples[model.id] = []

        // Ensure local directory exists
        do {
            try FileManager.default.createDirectory(
                at: model.localDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            downloadStates[model.id] = .failed(
                error: "Failed to create directory: \(error.localizedDescription)"
            )
            clearDownloadTracking(for: model.id)
            return
        }

        let task = Task { [weak self] in
            guard let self = self else { return }

            defer {
                Task { @MainActor [weak self] in
                    self?.activeDownloadTasks[model.id] = nil
                }
            }

            do {
                guard
                    let files = await HuggingFaceService.shared.fetchMatchingFiles(
                        repoId: model.id,
                        patterns: patterns
                    ), !files.isEmpty
                else {
                    await MainActor.run {
                        if self.downloadTokens[model.id] == token {
                            self.downloadStates[model.id] = .failed(
                                error: "Could not retrieve file list from Hugging Face"
                            )
                            self.clearDownloadTracking(for: model.id)
                        }
                    }
                    return
                }

                let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
                var completedFileBytes: Int64 = 0

                // Skip files already present with matching size (resume support)
                var filesToDownload: [HuggingFaceService.MatchedFile] = []
                for file in files {
                    let dest = model.localDirectory.appendingPathComponent(file.path)
                    let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                    let existingSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    if existingSize == file.size {
                        completedFileBytes += file.size
                    } else {
                        filesToDownload.append(file)
                    }
                }

                await MainActor.run {
                    guard self.downloadTokens[model.id] == token else { return }
                    let fraction = totalBytes > 0 ? Double(completedFileBytes) / Double(totalBytes) : 0
                    self.downloadStates[model.id] = .downloading(progress: fraction)
                    self.downloadMetrics[model.id] = DownloadMetrics(
                        bytesReceived: completedFileBytes > 0 ? completedFileBytes : 0,
                        totalBytes: totalBytes,
                        bytesPerSecond: nil,
                        etaSeconds: nil
                    )
                }

                let downloader = DirectDownloader()
                defer { downloader.invalidate() }

                for file in filesToDownload {
                    try Task.checkCancellation()

                    let encodedPath =
                        file.path.addingPercentEncoding(
                            withAllowedCharacters: .urlPathAllowed
                        ) ?? file.path
                    guard
                        let downloadURL = URL(
                            string: "https://huggingface.co/\(model.id)/resolve/main/\(encodedPath)"
                        )
                    else { continue }
                    let destination = model.localDirectory.appendingPathComponent(file.path)

                    let baseCompleted = completedFileBytes
                    let onProgress: @Sendable (Int64, Int64) -> Void = {
                        [weak self] bytesWritten, _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.updateDownloadProgress(
                                modelId: model.id,
                                token: token,
                                completedBytes: baseCompleted + bytesWritten,
                                totalBytes: totalBytes
                            )
                        }
                    }

                    try await downloader.download(
                        from: downloadURL,
                        to: destination,
                        expectedSize: file.size,
                        onProgress: onProgress
                    )
                    completedFileBytes += file.size
                }

                let completed = model.isDownloaded
                await MainActor.run {
                    if self.downloadTokens[model.id] == token {
                        self.downloadStates[model.id] =
                            completed ? .completed : .failed(error: "Download incomplete")
                        self.clearDownloadTracking(for: model.id)
                        if completed {
                            NotificationService.shared.postModelReady(
                                modelId: model.id,
                                modelName: model.name
                            )
                            Self.invalidateLocalModelsCache()
                            NotificationCenter.default.post(name: .localModelsChanged, object: nil)
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self.downloadTokens[model.id] == token {
                        self.downloadStates[model.id] = .notStarted
                        self.clearDownloadTracking(for: model.id)
                    }
                }
            } catch {
                await MainActor.run {
                    if self.downloadTokens[model.id] == token {
                        self.downloadStates[model.id] = .failed(error: error.localizedDescription)
                        self.clearDownloadTracking(for: model.id)
                    }
                }
            }
        }

        activeDownloadTasks[model.id] = task
    }

    /// Clears all transient download tracking state for a model.
    private func clearDownloadTracking(for modelId: String) {
        downloadTokens[modelId] = nil
        downloadMetrics[modelId] = nil
        progressSamples[modelId] = nil
        lastKnownSpeed[modelId] = nil
    }

    /// Updates download progress, speed, and ETA for a single model.
    private func updateDownloadProgress(
        modelId: String,
        token: UUID,
        completedBytes: Int64,
        totalBytes: Int64
    ) {
        guard downloadTokens[modelId] == token else { return }

        let fraction =
            totalBytes > 0
            ? min(1.0, Double(completedBytes) / Double(totalBytes)) : 0
        downloadStates[modelId] = .downloading(progress: fraction)

        let now = Date().timeIntervalSince1970
        var samples = progressSamples[modelId] ?? []
        samples.append((timestamp: now, completed: completedBytes))
        let window: TimeInterval = 5.0
        samples = samples.filter { now - $0.timestamp <= window }
        progressSamples[modelId] = samples

        var speed: Double? = nil
        if let first = samples.first, let last = samples.last,
            last.timestamp > first.timestamp
        {
            let bytesDelta = Double(last.completed - first.completed)
            let timeDelta = last.timestamp - first.timestamp
            if timeDelta > 0 { speed = max(0, bytesDelta / timeDelta) }
        }
        if let speed, speed > 0 {
            lastKnownSpeed[modelId] = speed
        } else {
            speed = lastKnownSpeed[modelId]
        }

        var eta: Double? = nil
        if let speed, speed > 0, totalBytes > 0 {
            let remaining = Double(totalBytes - completedBytes)
            if remaining > 0 { eta = remaining / speed }
        }

        downloadMetrics[modelId] = DownloadMetrics(
            bytesReceived: completedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: speed,
            etaSeconds: eta
        )
    }

    /// Cancel a download
    func cancelDownload(_ modelId: String) {
        activeDownloadTasks[modelId]?.cancel()
        activeDownloadTasks[modelId] = nil
        clearDownloadTracking(for: modelId)
        downloadStates[modelId] = .notStarted
    }

    /// Delete a downloaded model
    func deleteModel(_ model: MLXModel) {
        activeDownloadTasks[model.id]?.cancel()
        activeDownloadTasks[model.id] = nil
        clearDownloadTracking(for: model.id)

        let fm = FileManager.default

        let localPath = model.localDirectory.path
        if fm.fileExists(atPath: localPath) {
            do {
                try fm.removeItem(atPath: localPath)
            } catch {
                downloadStates[model.id] = .failed(
                    error: "Could not delete model: \(error.localizedDescription)"
                )
                return
            }
        }

        // Best-effort cleanup of legacy HF cache entries (non-fatal if these fail)
        let cacheDirName = "models--\(model.id.replacingOccurrences(of: "/", with: "--"))"
        for cacheRoot in Self.hfCacheRoots() {
            let cacheModelDir = cacheRoot.appendingPathComponent(cacheDirName)
            if fm.fileExists(atPath: cacheModelDir.path) {
                try? fm.removeItem(at: cacheModelDir)
            }
        }

        downloadStates[model.id] = .notStarted
        Self.invalidateLocalModelsCache()
        NotificationCenter.default.post(name: .localModelsChanged, object: nil)
    }

    /// Possible root directories for the HF hub cache.
    private static func hfCacheRoots() -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = []

        if let envCache = ProcessInfo.processInfo.environment["HF_HUB_CACHE"], !envCache.isEmpty {
            roots.append(URL(fileURLWithPath: (envCache as NSString).expandingTildeInPath, isDirectory: true))
        }
        if let envHome = ProcessInfo.processInfo.environment["HF_HOME"], !envHome.isEmpty {
            let expanded = (envHome as NSString).expandingTildeInPath
            roots.append(URL(fileURLWithPath: expanded, isDirectory: true).appendingPathComponent("hub"))
        }

        let home = fm.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent(".cache/huggingface/hub"))

        if let appCaches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(appCaches.appendingPathComponent("huggingface/hub"))
        }

        return roots
    }

    /// Get download progress for a model
    func downloadProgress(for modelId: String) -> Double {
        switch downloadStates[modelId] {
        case .downloading(let progress):
            return progress
        case .completed:
            return 1.0
        default:
            return 0.0
        }
    }

    /// Get total size of downloaded models
    var totalDownloadedSize: Int64 {
        // Build a unique list of models by id from both available and suggested
        let combined = (availableModels + suggestedModels)
        let uniqueById: [String: MLXModel] = combined.reduce(into: [:]) { dict, model in
            if dict[model.id] == nil { dict[model.id] = model }
        }
        // Sum actual on-disk sizes for models that are fully downloaded
        return uniqueById.values
            .filter { $0.isDownloaded }
            .reduce(Int64(0)) { partial, model in
                partial + (Self.directoryAllocatedSize(at: model.localDirectory) ?? 0)
            }
    }

    /// Effective state for a model combining in-memory state with on-disk detection
    func effectiveDownloadState(for model: MLXModel) -> DownloadState {
        if case .downloading = downloadStates[model.id] {
            return downloadStates[model.id] ?? .notStarted
        }
        return model.isDownloaded ? .completed : (downloadStates[model.id] ?? .notStarted)
    }

    var totalDownloadedSizeString: String {
        ByteCountFormatter.string(fromByteCount: totalDownloadedSize, countStyle: .file)
    }

    /// Number of models currently being downloaded
    var activeDownloadsCount: Int {
        downloadStates.values.filter {
            if case .downloading = $0 { return true }
            return false
        }.count
    }

    // MARK: - Private Methods

    /// Compute the set of SDK-supported model ids from MLXLLM's registry
    static func sdkSupportedModelIds() -> Set<String> {
        // The registry contains Apple-curated supported configurations.
        // We normalize to lowercase for comparison.
        var allowed: Set<String> = []
        for config in LLMRegistry.shared.models {
            allowed.insert(config.name.lowercased())
        }
        return allowed
    }

    /// Build MLXModel entries from the MLX registry of supported models
    static func registryModels() -> [MLXModel] {
        return LLMRegistry.shared.models.map { cfg in
            let id = cfg.name
            return MLXModel(
                id: id,
                name: friendlyName(from: id),
                description: "From MLX registry",
                downloadURL: "https://huggingface.co/\(id)"
            )
        }
    }

    /// Check for any missing exact files from the provided patterns.
    /// Only exact filenames are considered (globs like *.safetensors are ignored here).
    private static func isMissingExactPatternFiles(at directory: URL, patterns: [String]) -> Bool {
        let fileManager = FileManager.default
        let exactNames = patterns.filter { !$0.contains("*") && !$0.contains("?") }
        for name in exactNames {
            let path = directory.appendingPathComponent(name).path
            if !fileManager.fileExists(atPath: path) {
                return true
            }
        }
        return false
    }

    /// Compute allocated size on disk for a directory (recursively)
    /// Falls back to logical file size when allocated size is unavailable
    private static func directoryAllocatedSize(at url: URL) -> Int64? {
        let fileManager = FileManager.default
        var total: Int64 = 0
        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [
                    .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey,
                ],
                options: [],
                errorHandler: nil
            )
        else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [
                    .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
                ])
                guard resourceValues.isRegularFile == true else { continue }
                if let allocated = resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize {
                    total += Int64(allocated)
                } else if let size = resourceValues.fileSize {
                    total += Int64(size)
                }
            } catch {
                continue
            }
        }
        return total
    }
}

// MARK: - Dynamic model discovery (Hugging Face)

extension ModelManager {
    /// Fully curated models with descriptions we control. Order matters.
    fileprivate static let curatedSuggestedModels: [MLXModel] = [
        // MARK: Top Picks

        MLXModel(
            id: "OsaurusAI/gemma-4-E2B-it-4bit",
            name: friendlyName(from: "OsaurusAI/gemma-4-E2B-it-4bit"),
            description: "Smallest multimodal Gemma 4 model. Runs on any Mac.",
            downloadURL: "https://huggingface.co/OsaurusAI/gemma-4-E2B-it-4bit",
            isTopSuggestion: true,
            downloadSizeBytes: 1_000_000_000
        ),

        MLXModel(
            id: "OsaurusAI/gemma-4-E4B-it-4bit",
            name: friendlyName(from: "OsaurusAI/gemma-4-E4B-it-4bit"),
            description: "Multimodal edge model. Handles images, video, and audio. 128K context.",
            downloadURL: "https://huggingface.co/OsaurusAI/gemma-4-E4B-it-4bit",
            isTopSuggestion: true,
            downloadSizeBytes: 2_000_000_000
        ),

        MLXModel(
            id: "OsaurusAI/Gemma-4-26B-A4B-it-JANG_2L",
            name: friendlyName(from: "OsaurusAI/Gemma-4-26B-A4B-it-JANG_2L"),
            description: "Efficient MoE vision model. Only 4B active params. 256K context.",
            downloadURL: "https://huggingface.co/OsaurusAI/Gemma-4-26B-A4B-it-JANG_2L",
            isTopSuggestion: true,
            downloadSizeBytes: 3_000_000_000
        ),

        MLXModel(
            id: "LiquidAI/LFM2-24B-A2B-MLX-8bit",
            name: friendlyName(from: "LiquidAI/LFM2-24B-A2B-MLX-8bit"),
            description: "Liquid AI's 24B MoE model. Only ~2B active params per token. 128K context.",
            downloadURL: "https://huggingface.co/LiquidAI/LFM2-24B-A2B-MLX-8bit",
            isTopSuggestion: true,
            downloadSizeBytes: 23_600_000_000
        ),

        // MARK: Large Models

        MLXModel(
            id: "lmstudio-community/gpt-oss-20b-MLX-8bit",
            name: friendlyName(from: "lmstudio-community/gpt-oss-20b-MLX-8bit"),
            description: "OpenAI's open-source release. Strong all-around performance.",
            downloadURL: "https://huggingface.co/lmstudio-community/gpt-oss-20b-MLX-8bit"
        ),

        MLXModel(
            id: "lmstudio-community/gpt-oss-120b-MLX-8bit",
            name: friendlyName(from: "lmstudio-community/gpt-oss-120b-MLX-8bit"),
            description: "OpenAI's largest open model. Premium quality, requires 64GB+ unified memory.",
            downloadURL: "https://huggingface.co/lmstudio-community/gpt-oss-120b-MLX-8bit"
        ),

        MLXModel(
            id: "OsaurusAI/Gemma-4-31B-it-JANG_4M",
            name: friendlyName(from: "OsaurusAI/Gemma-4-31B-it-JANG_4M"),
            description: "Gemma 4 31B dense vision model. Top-tier quality with optimized quantization.",
            downloadURL: "https://huggingface.co/OsaurusAI/Gemma-4-31B-it-JANG_4M",
            downloadSizeBytes: 6_000_000_000
        ),

        // MARK: Vision Language Models (VLM)

        MLXModel(
            id: "OsaurusAI/Gemma-4-26B-A4B-it-JANG_4M",
            name: friendlyName(from: "OsaurusAI/Gemma-4-26B-A4B-it-JANG_4M"),
            description: "Higher-quality MoE vision model. 4B active params with 256K context.",
            downloadURL: "https://huggingface.co/OsaurusAI/Gemma-4-26B-A4B-it-JANG_4M",
            downloadSizeBytes: 5_000_000_000
        ),

        MLXModel(
            id: "OsaurusAI/gemma-4-E4B-it-8bit",
            name: friendlyName(from: "OsaurusAI/gemma-4-E4B-it-8bit"),
            description: "Multimodal edge model at 8-bit precision. Best quality for the E4B family.",
            downloadURL: "https://huggingface.co/OsaurusAI/gemma-4-E4B-it-8bit",
            downloadSizeBytes: 3_000_000_000
        ),

        MLXModel(
            id: "OsaurusAI/Qwen3.5-122B-A10B-JANG_4K",
            name: friendlyName(from: "OsaurusAI/Qwen3.5-122B-A10B-JANG_4K"),
            description: "Largest Qwen3.5 MoE vision model. 10B active params with top-tier reasoning.",
            downloadURL: "https://huggingface.co/OsaurusAI/Qwen3.5-122B-A10B-JANG_4K",
            downloadSizeBytes: 18_000_000_000
        ),

        MLXModel(
            id: "OsaurusAI/Qwen3.5-122B-A10B-JANG_2S",
            name: friendlyName(from: "OsaurusAI/Qwen3.5-122B-A10B-JANG_2S"),
            description: "Qwen3.5 122B MoE vision model. Compact quantization, smaller download.",
            downloadURL: "https://huggingface.co/OsaurusAI/Qwen3.5-122B-A10B-JANG_2S",
            downloadSizeBytes: 11_000_000_000
        ),

        MLXModel(
            id: "OsaurusAI/Qwen3.5-35B-A3B-JANG_4K",
            name: friendlyName(from: "OsaurusAI/Qwen3.5-35B-A3B-JANG_4K"),
            description: "Efficient Qwen3.5 MoE vision model. Only 3B active params.",
            downloadURL: "https://huggingface.co/OsaurusAI/Qwen3.5-35B-A3B-JANG_4K",
            downloadSizeBytes: 5_000_000_000
        ),

        MLXModel(
            id: "OsaurusAI/Qwen3.5-35B-A3B-JANG_2S",
            name: friendlyName(from: "OsaurusAI/Qwen3.5-35B-A3B-JANG_2S"),
            description: "Compact Qwen3.5 MoE vision model. Fast and lightweight.",
            downloadURL: "https://huggingface.co/OsaurusAI/Qwen3.5-35B-A3B-JANG_2S",
            downloadSizeBytes: 3_000_000_000
        ),

        // MARK: Compact Models

        MLXModel(
            id: "OsaurusAI/gemma-4-E2B-it-8bit",
            name: friendlyName(from: "OsaurusAI/gemma-4-E2B-it-8bit"),
            description: "Smallest Gemma 4 at 8-bit precision. Better quality, still runs on any Mac.",
            downloadURL: "https://huggingface.co/OsaurusAI/gemma-4-E2B-it-8bit",
            downloadSizeBytes: 2_000_000_000
        ),

    ]

    nonisolated fileprivate static func friendlyName(from repoId: String) -> String {
        // Take the last path component and title-case-ish
        let last = repoId.split(separator: "/").last.map(String.init) ?? repoId
        let spaced = last.replacingOccurrences(of: "-", with: " ")
        // Keep common tokens uppercase
        return
            spaced
            .replacingOccurrences(of: "llama", with: "Llama", options: .caseInsensitive)
            .replacingOccurrences(of: "qwen", with: "Qwen", options: .caseInsensitive)
            .replacingOccurrences(of: "gemma", with: "Gemma", options: .caseInsensitive)
            .replacingOccurrences(of: "deepseek", with: "DeepSeek", options: .caseInsensitive)
            .replacingOccurrences(of: "granite", with: "Granite", options: .caseInsensitive)
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
        let siblings: [HFSibling]?
    }

    fileprivate struct HFSibling: Decodable {
        let rfilename: String
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

    /// Heuristic to decide if an HF model is likely MLX-compatible
    fileprivate static func isLikelyMLXCompatible(_ model: HFModel) -> Bool {
        let lowerId = model.id.lowercased()
        // Strong signals: org or id contains "mlx"
        if lowerId.contains("mlx") { return true }
        // Tags sometimes include library identifiers
        if let tags = model.tags?.map({ $0.lowercased() }) {
            if tags.contains("mlx") || tags.contains("apple-mlx") || tags.contains("library:mlx") {
                return true
            }
        }
        // File-based heuristic: config + safetensors + some tokenizer asset present
        if let siblings = model.siblings {
            var hasConfig = false
            var hasWeights = false
            var hasTokenizer = false
            for s in siblings {
                let f = s.rfilename.lowercased()
                if f == "config.json" { hasConfig = true }
                if f.hasSuffix(".safetensors") { hasWeights = true }
                if f == "tokenizer.json" || f == "tokenizer.model" || f == "spiece.model"
                    || f == "vocab.json" || f == "vocab.txt"
                {
                    hasTokenizer = true
                }
            }
            if hasConfig && hasWeights && hasTokenizer { return true }
        }
        return false
    }

    /// Merge new models into availableModels without duplicates; initialize downloadStates
    fileprivate func mergeAvailable(with newModels: [MLXModel]) {
        // Build a case-insensitive set of existing ids across available and suggested
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
        for m in appended {
            downloadStates[m.id] = m.isDownloaded ? .completed : .notStarted
        }
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
                    name: friendlyName(from: id),
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

// MARK: - Vision Language Model (VLM) Detection

extension ModelManager {
    /// Check if a downloaded model supports vision/multimodal input.
    ///
    /// Reads config.json from the local model directory and checks:
    /// 1. Structural keys (vision_config, image_processor, etc.)
    /// 2. preprocessor_config.json as a final fallback
    nonisolated static func isVisionModel(modelId: String) -> Bool {
        guard let localDir = findLocalModelDirectory(forModelId: modelId) else {
            return false
        }
        return isVisionModel(at: localDir)
    }

    /// Check if a model at the given directory supports vision input.
    nonisolated static func isVisionModel(at directory: URL) -> Bool {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }

        // Structural keys that indicate vision capability in config.json.
        // This is the primary signal — it correctly disambiguates dual-registered
        // model types (e.g. gemma4 appears in both VLM and LLM registries, but only
        // the VLM variant has vision_config).
        let visionKeys: Set<String> = [
            "vision_config",
            "image_processor",
            "vision_encoder",
            "vision_tower",
            "image_encoder",
            "visual_encoder",
            "num_image_tokens",
            "vision_feature_layer",
        ]

        if json.keys.contains(where: { visionKeys.contains($0) }) {
            return true
        }

        // Fallback: preprocessor_config.json presence with image-related processor.
        let preprocessorURL = directory.appendingPathComponent("preprocessor_config.json")
        if let prepData = try? Data(contentsOf: preprocessorURL),
            let prepJson = try? JSONSerialization.jsonObject(with: prepData) as? [String: Any]
        {
            if let processorClass = prepJson["processor_class"] as? String,
                processorClass.lowercased().contains("image")
            {
                return true
            }
            if let imageProcessorType = prepJson["image_processor_type"] as? String,
                !imageProcessorType.isEmpty
            {
                return true
            }
        }

        return false
    }

    /// Find the local directory for a model id
    nonisolated private static func findLocalModelDirectory(forModelId id: String) -> URL? {
        let parts = id.split(separator: "/").map(String.init)
        let base = DirectoryPickerService.effectiveModelsDirectory()
        let url = parts.reduce(base) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
        let fm = FileManager.default
        let hasConfig = fm.fileExists(atPath: url.appendingPathComponent("config.json").path)
        if hasConfig {
            return url
        }
        return nil
    }

}

// MARK: - Direct file downloader with session-level delegate

/// Downloads files using a session-level URLSessionDownloadDelegate for reliable
/// per-byte progress reporting. Works around an Apple platform issue where per-task
/// delegates passed to URLSession.download(for:delegate:) may not fire didWriteData.
private final class DirectDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var currentContinuation: CheckedContinuation<Void, Error>?
    private var currentDestination: URL?
    private var currentExpectedSize: Int64?
    private var onProgress: (@Sendable (Int64, Int64) -> Void)?
    private var lastProgressTime: CFAbsoluteTime = 0
    private static let progressInterval: CFAbsoluteTime = 0.25

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    func download(
        from url: URL,
        to destination: URL,
        expectedSize: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.currentContinuation = continuation
            self.currentDestination = destination
            self.currentExpectedSize = expectedSize
            self.onProgress = onProgress
            self.lastProgressTime = 0
            lock.unlock()
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let elapsed = now - lastProgressTime
        let isFileComplete =
            totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard elapsed >= Self.progressInterval || isFileComplete else {
            lock.unlock()
            return
        }
        lastProgressTime = now
        let progress = onProgress
        lock.unlock()
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let continuation = currentContinuation
        let destination = currentDestination
        let expectedSize = currentExpectedSize
        currentContinuation = nil
        currentDestination = nil
        currentExpectedSize = nil
        onProgress = nil
        lock.unlock()
        guard let continuation, let destination else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
            !(200 ..< 300).contains(http.statusCode)
        {
            continuation.resume(
                throwing: URLError(
                    .badServerResponse,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
                )
            )
            return
        }

        do {
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)

            if let expectedSize, expectedSize > 0 {
                let attrs = try fm.attributesOfItem(atPath: destination.path)
                let actualSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                if actualSize != expectedSize {
                    try? fm.removeItem(at: destination)
                    continuation.resume(
                        throwing: URLError(
                            .cannotDecodeContentData,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Size mismatch: expected \(expectedSize), got \(actualSize)"
                            ]
                        )
                    )
                    return
                }
            }

            continuation.resume()
        } catch {
            continuation.resume(throwing: error)
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        lock.lock()
        let continuation = currentContinuation
        currentContinuation = nil
        currentDestination = nil
        currentExpectedSize = nil
        onProgress = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
