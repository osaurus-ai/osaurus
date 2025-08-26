//
//  ModelManager.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation
import SwiftUI
import Combine
import Hub
import IkigaJSON

/// Download task information
struct DownloadTaskInfo {
    let modelId: String
    let fileName: String
    let fileIndex: Int
    let totalFiles: Int
}

/// Manages MLX model downloads and storage
@MainActor
final class ModelManager: NSObject, ObservableObject {
    static let shared = ModelManager()
    
    // MARK: - Published Properties
    @Published var availableModels: [MLXModel] = []
    @Published var downloadStates: [String: DownloadState] = [:]
    @Published var isLoadingModels: Bool = false
    @Published var suggestedModels: [MLXModel] = ModelManager.curatedSuggestedModels
    
    // MARK: - Properties
    /// Current models directory (uses DirectoryPickerService for user selection)
    var modelsDirectory: URL {
        return DirectoryPickerService.shared.effectiveModelsDirectory
    }
    
    private var activeDownloadTasks: [String: Task<Void, Never>] = [:] // modelId -> Task
    private var downloadTokens: [String: UUID] = [:] // modelId -> token to gate progress/state updates
    private var cancellables = Set<AnyCancellable>()
    private var inFlightDetailFetches: Set<String> = [] // modelId set for size/detail fetches
    
    // MARK: - Initialization
    override init() {
        super.init()
        
        loadAvailableModels()
    }
    
    // MARK: - Public Methods
    
    /// Load popular MLX models
    func loadAvailableModels() {
        // Start with an empty list, then fetch dynamically from Hugging Face Hub (mlx-community only)
        availableModels = []
        downloadStates = [:]
        isLoadingModels = true
        
        // Fetch dynamically from Hugging Face Hub (mlx-community only), then update
        Task {
            do {
                let repos = try await Self.fetchHFRepos()
                let models = Self.mapReposToMLXModels(repos)
                await MainActor.run {
                    self.availableModels = models
                    // Re-initialize download states for the new list
                    self.downloadStates = [:]
                    for model in models {
                        self.downloadStates[model.id] = model.isDownloaded ? .completed : .notStarted
                    }
                    // Ensure suggested models also have state entries
                    for sm in self.suggestedModels {
                        self.downloadStates[sm.id] = sm.isDownloaded ? .completed : .notStarted
                    }
                    self.isLoadingModels = false
                }
            } catch {
                // Leave list empty on failure; optionally log
                print("Failed to fetch models from HF: \(error)")
                await MainActor.run {
                    self.isLoadingModels = false
                }
            }
        }
    }

    /// Windowed: prefetch model detail (e.g., sizes) when an item becomes visible
    func prefetchModelDetailsIfNeeded(for model: MLXModel) {
        // If size known or a fetch is already running, skip
        guard model.size == 0 else { return }
        if inFlightDetailFetches.contains(model.id) { return }

        inFlightDetailFetches.insert(model.id)
        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.inFlightDetailFetches.remove(model.id) } }
            do {
                let detailed = try await Self.fetchHFRepoDetail(id: model.id)
                let totalSize: Int64 = await Self.computeTotalSafetensorsBytes(for: model.id, siblings: detailed.siblings)
                let newDescription = Self.buildDescription(from: detailed)
                if totalSize > 0 || newDescription != model.description {
                    await MainActor.run {
                        // Update in available models if present
                        if let idx = self.availableModels.firstIndex(where: { $0.id == model.id }) {
                            let current = self.availableModels[idx]
                            let updated = MLXModel(
                                id: current.id,
                                name: current.name,
                                description: newDescription,
                                size: totalSize > 0 ? totalSize : current.size,
                                downloadURL: current.downloadURL,
                                requiredFiles: current.requiredFiles
                            )
                            self.availableModels[idx] = updated
                        }
                        // Update in suggested models if present, but preserve curated description
                        if let sidx = self.suggestedModels.firstIndex(where: { $0.id == model.id }) {
                            let current = self.suggestedModels[sidx]
                            let updated = MLXModel(
                                id: current.id,
                                name: current.name,
                                description: current.description, // keep curated description
                                size: totalSize > 0 ? totalSize : current.size,
                                downloadURL: current.downloadURL,
                                requiredFiles: current.requiredFiles
                            )
                            self.suggestedModels[sidx] = updated
                        }
                    }
                }
            } catch {
                // Ignore detail errors; size remains 0 and UI can keep showing estimating
            }
        }
    }
    
    /// Download a model using Hugging Face Hub snapshot API
    func downloadModel(_ model: MLXModel) {
        // Define patterns here so we can also check for missing optional files (top-up)
        let patterns = [
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "special_tokens_map.json",
            "generation_config.json",
            "chat_template.jinja",
            "*.safetensors"
        ]

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
        
        // Ensure local directory exists
        do {
            try FileManager.default.createDirectory(
                at: model.localDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            downloadStates[model.id] = .failed(error: "Failed to create directory: \(error.localizedDescription)")
            return
        }
        
        // Start snapshot download task
        let task = Task { [weak self] in
            guard let self = self else { return }
            let repo = Hub.Repo(id: model.id)
            
            do {
                // Download a snapshot to a temporary location managed by Hub
                let snapshotDirectory = try await Hub.snapshot(
                    from: repo,
                    matching: patterns,
                    progressHandler: { progress in
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            // Ignore progress updates from stale/canceled tasks
                            guard self.downloadTokens[model.id] == token else { return }
                            // Clamp to [0, 1]
                            let fraction = max(0.0, min(1.0, progress.fractionCompleted))
                            self.downloadStates[model.id] = .downloading(progress: fraction)
                        }
                    }
                )
                
                // Copy snapshot contents into our managed models directory
                try self.copyContents(of: snapshotDirectory, to: model.localDirectory)
                
                // Attempt to remove the Hub snapshot cache directory to free disk space
                // This directory is a cached snapshot; we've already copied the contents
                // into our app-managed models directory above, so it's safe to delete.
                do {
                    try FileManager.default.removeItem(at: snapshotDirectory)
                } catch {
                    // Non-fatal cleanup failure
                    print("Warning: failed to remove Hub snapshot cache at \(snapshotDirectory.path): \(error)")
                }
                
                // Verify
                let completed = model.isDownloaded
                await MainActor.run {
                    // Only update state if this session is still current
                    if self.downloadTokens[model.id] == token {
                        self.downloadStates[model.id] = completed ? .completed : .failed(error: "Downloaded snapshot incomplete")
                        self.downloadTokens[model.id] = nil
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self.downloadTokens[model.id] == token {
                        self.downloadStates[model.id] = .notStarted
                        self.downloadTokens[model.id] = nil
                    }
                }
            } catch {
                await MainActor.run {
                    if self.downloadTokens[model.id] == token {
                        self.downloadStates[model.id] = .failed(error: error.localizedDescription)
                        self.downloadTokens[model.id] = nil
                    }
                }
            }
            
            await MainActor.run {
                self.activeDownloadTasks[model.id] = nil
            }
        }
        
        activeDownloadTasks[model.id] = task
    }
    
    /// Cancel a download
    func cancelDownload(_ modelId: String) {
        // Cancel active snapshot task if any
        activeDownloadTasks[modelId]?.cancel()
        activeDownloadTasks[modelId] = nil
        downloadTokens[modelId] = nil
        downloadStates[modelId] = .notStarted
    }
    
    /// Delete a downloaded model
    func deleteModel(_ model: MLXModel) {
        // Cancel any active download task and reset state first
        activeDownloadTasks[model.id]?.cancel()
        activeDownloadTasks[model.id] = nil
        downloadTokens[model.id] = nil
        downloadStates[model.id] = .notStarted

        // Remove local files if present
        let fm = FileManager.default
        let path = model.localDirectory.path
        if fm.fileExists(atPath: path) {
            do {
                try fm.removeItem(atPath: path)
            } catch {
                // Log but keep state reset
                print("Failed to delete model: \(error)")
            }
        }
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
    
    // MARK: - Private Methods
    
    private func copyContents(of sourceDirectory: URL, to destinationDirectory: URL) throws {
        let fileManager = FileManager.default

        // Ensure destination exists (do not wipe; we will merge/overwrite files)
        if !fileManager.fileExists(atPath: destinationDirectory.path) {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        }

        // Copy/overwrite all items
        let items = try fileManager.contentsOfDirectory(atPath: sourceDirectory.path)
        for item in items {
            let src = sourceDirectory.appendingPathComponent(item)
            let dst = destinationDirectory.appendingPathComponent(item)

            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: src.path, isDirectory: &isDir)

            if isDir.boolValue {
                // Ensure directory exists at destination, then recurse
                if !fileManager.fileExists(atPath: dst.path) {
                    try fileManager.createDirectory(at: dst, withIntermediateDirectories: true)
                }
                try copyContents(of: src, to: dst)
            } else {
                // If a file exists at destination, remove it before copying to allow overwrite
                if fileManager.fileExists(atPath: dst.path) {
                    try fileManager.removeItem(at: dst)
                }
                try fileManager.copyItem(at: src, to: dst)
            }
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
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey], options: [], errorHandler: nil) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
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

private extension ModelManager {
    /// Simple in-memory LRU cache with TTL for HF repo lists
    nonisolated(unsafe) private static var repoCacheStore: [String: (value: [HFRepo], inserted: Date)] = [:]
    nonisolated(unsafe) private static var repoCacheOrder: [String] = []
    nonisolated(unsafe) private static let repoCacheQueue = DispatchQueue(label: "com.osaurus.hf.repos.cache", attributes: .concurrent)
    nonisolated(unsafe) private static var repoCacheTTL: TimeInterval {
        let env = ProcessInfo.processInfo.environment
        if let s = env["OSU_HF_REPO_CACHE_TTL"], let v = TimeInterval(s), v > 0 { return v }
        return 900 // 15 minutes default
    }
    nonisolated(unsafe) private static var repoCacheMaxEntries: Int {
        let env = ProcessInfo.processInfo.environment
        if let s = env["OSU_HF_REPO_CACHE_MAX"], let v = Int(s), v > 0 { return v }
        return 4
    }

    static func repoCacheGet(key: String) -> [HFRepo]? {
        return repoCacheQueue.sync(flags: .barrier) {
            guard let entry = repoCacheStore[key] else { return nil }
            // TTL check
            if Date().timeIntervalSince(entry.inserted) >= repoCacheTTL {
                repoCacheStore.removeValue(forKey: key)
                if let idx = repoCacheOrder.firstIndex(of: key) { repoCacheOrder.remove(at: idx) }
                return nil
            }
            // Promote MRU
            if let idx = repoCacheOrder.firstIndex(of: key) { repoCacheOrder.remove(at: idx) }
            repoCacheOrder.append(key)
            return entry.value
        }
    }

    static func repoCacheSet(key: String, value: [HFRepo]) {
        repoCacheQueue.async(flags: .barrier) {
            repoCacheStore[key] = (value, Date())
            if let idx = repoCacheOrder.firstIndex(of: key) { repoCacheOrder.remove(at: idx) }
            repoCacheOrder.append(key)
            while repoCacheOrder.count > repoCacheMaxEntries {
                let lru = repoCacheOrder.removeFirst()
                repoCacheStore.removeValue(forKey: lru)
            }
        }
    }

    /// Fully curated models with descriptions we control. Order matters.
    static let curatedSuggestedModels: [MLXModel] = [
        // GPT-OSS
        MLXModel(
            id: "lmstudio-community/gpt-oss-20b-MLX-8bit",
            name: friendlyName(from: "lmstudio-community/gpt-oss-20b-MLX-8bit"),
            description: "GPT-OSS 20B (8-bit MLX) by OpenAI. High-quality general model in MLX format.",
            size: 0,
            downloadURL: "https://huggingface.co/lmstudio-community/gpt-oss-20b-MLX-8bit",
            requiredFiles: curatedRequiredFiles
        ),

        MLXModel(
            id: "lmstudio-community/gpt-oss-120b-MLX-8bit",
            name: friendlyName(from: "lmstudio-community/gpt-oss-120b-MLX-8bit"),
            description: "GPT-OSS 120B (MLX 8-bit). ~117B parameters; premium general assistant with strong reasoning and coding. Optimized for Apple Silicon via MLX; requires 64GB+ unified memory; very large download.",
            size: 0,
            downloadURL: "https://huggingface.co/lmstudio-community/gpt-oss-120b-MLX-8bit",
            requiredFiles: curatedRequiredFiles
        ),

        // Qwen family — 3 sizes
        MLXModel(
            id: "mlx-community/Qwen3-1.7B-4bit",
            name: friendlyName(from: "mlx-community/Qwen3-1.7B-4bit"),
            description: "Qwen3 1.7B (4-bit). Tiny and fast. Great for quick tests, code helpers, and lightweight tasks.",
            size: 0,
            downloadURL: "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit",
            requiredFiles: curatedRequiredFiles
        ),
        MLXModel(
            id: "mlx-community/Qwen3-4B-4bit",
            name: friendlyName(from: "mlx-community/Qwen3-4B-4bit"),
            description: "Qwen3 4B (4-bit). Modern small model with strong instruction following.",
            size: 0,
            downloadURL: "https://huggingface.co/mlx-community/Qwen3-4B-4bit",
            requiredFiles: curatedRequiredFiles
        ),
        MLXModel(
            id: "mlx-community/Qwen3-235B-A22B-4bit",
            name: friendlyName(from: "mlx-community/Qwen3-235B-A22B-4bit"),
            description: "Qwen3 235B MoE A22B (4-bit). High quality; heavy memory requirements.",
            size: 0,
            downloadURL: "https://huggingface.co/mlx-community/Qwen3-235B-A22B-4bit",
            requiredFiles: curatedRequiredFiles
        ),

        // New additions — Gemma 3, Qwen3, GPT-OSS
        MLXModel(
            id: "lmstudio-community/gemma-3-270m-it-MLX-8bit",
            name: friendlyName(from: "lmstudio-community/gemma-3-270m-it-MLX-8bit"),
            description: "Gemma 3 270M IT (8-bit MLX). Extremely small and fast for experimentation.",
            size: 0,
            downloadURL: "https://huggingface.co/lmstudio-community/gemma-3-270m-it-MLX-8bit",
            requiredFiles: curatedRequiredFiles
        ),

        // Reasoning-focused choices
        MLXModel(
            id: "mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit",
            name: friendlyName(from: "mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit"),
            description: "Reasoning-focused distilled model. Good for structured steps and chain-of-thought style prompts.",
            size: 0,
            downloadURL: "https://huggingface.co/mlx-community/DeepSeek-R1-Distill-Qwen-1.5B-4bit",
            requiredFiles: curatedRequiredFiles
        ),

        // Popular general models (extra variety)
        MLXModel(
            id: "mlx-community/Mistral-7B-Instruct-4bit",
            name: friendlyName(from: "mlx-community/Mistral-7B-Instruct-4bit"),
            description: "Popular 7B instruct model. Good general assistant with efficient runtime.",
            size: 0,
            downloadURL: "https://huggingface.co/mlx-community/Mistral-7B-Instruct-4bit",
            requiredFiles: curatedRequiredFiles
        ),
        MLXModel(
            id: "mlx-community/Phi-3-mini-4k-instruct-4bit",
            name: friendlyName(from: "mlx-community/Phi-3-mini-4k-instruct-4bit"),
            description: "Very small and speedy. Great for lightweight tasks and constrained devices.",
            size: 0,
            downloadURL: "https://huggingface.co/mlx-community/Phi-3-mini-4k-instruct-4bit",
            requiredFiles: curatedRequiredFiles
        ),

        // Kimi
        MLXModel(
            id: "mlx-community/Kimi-VL-A3B-Thinking-4bit",
            name: friendlyName(from: "mlx-community/Kimi-VL-A3B-Thinking-4bit"),
            description: "Kimi VL A3B thinking variant (4-bit). Versatile assistant with strong reasoning.",
            size: 0,
            downloadURL: "https://huggingface.co/mlx-community/Kimi-VL-A3B-Thinking-4bit",
            requiredFiles: curatedRequiredFiles
        ),

        // Llama family
        MLXModel(
            id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            name: friendlyName(from: "mlx-community/Llama-3.2-1B-Instruct-4bit"),
            description: "Tiny and fast. Great for quick tests, code helpers, and lightweight tasks.",
            size: 0,
            downloadURL: "https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit",
            requiredFiles: curatedRequiredFiles
        ),
        MLXModel(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            name: friendlyName(from: "mlx-community/Llama-3.2-3B-Instruct-4bit"),
            description: "Great quality/speed balance. Strong general assistant at a small memory footprint.",
            size: 0,
            downloadURL: "https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit",
            requiredFiles: curatedRequiredFiles
        )
    ]

    static let curatedRequiredFiles: [String] = [
        "model.safetensors",
        "config.json",
        "tokenizer_config.json",
        "tokenizer.json",
        "special_tokens_map.json"
    ]
    /// Minimal HF API response structures we care about
    struct HFRepo: Decodable {
        let id: String
        let private_: Bool? // "private" is reserved in Swift, map manually
        let likes: Int?
        let downloads: Int?
        let tags: [String]?
        let siblings: [HFSibling]?
        let cardData: HFCardData?

        private enum CodingKeys: String, CodingKey {
            case id
            case private_ = "private"
            case likes
            case downloads
            case tags
            case siblings
            case cardData
        }
    }

    struct HFSibling: Decodable {
        let rfilename: String
        let size: Int64?
    }

    struct HFCardData: Decodable {
        let short_description: String?
        let license: String?
    }

    /// Fetch repos from HF including mlx-community and LM Studio MLX repos, focusing on text-generation models
    /// Applies an in-memory LRU cache with TTL to avoid refetching and rate limits.
    /// This first pulls lightweight lists, merges/dedupes, then fetches detailed metadata (including file sizes)
    /// for the top repositories to compute download sizes.
    static func fetchHFRepos() async throws -> [HFRepo] {
        let cacheKey = "hf:repos:v2:mlx+lmstudio:text-generation"
        // Cache hit check
        if let cached = repoCacheGet(key: cacheKey) {
            return cached
        }

        // Build URLs
        let urlMLX = "https://huggingface.co/api/models?author=mlx-community&pipeline_tag=text-generation&sort=downloads&direction=-1&limit=200"
        let urlLMStudio = "https://huggingface.co/api/models?author=lmstudio-community&pipeline_tag=text-generation&sort=downloads&direction=-1&limit=200"

        func fetchList(_ urlString: String) async throws -> [HFRepo] {
            guard let url = URL(string: urlString) else { return [] }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("osaurus/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "HFAPI", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected status"])
            }
            let decoder = IkigaJSONDecoder()
            return try decoder.decode([HFRepo].self, from: data)
        }

        // Fetch org lists concurrently
        async let listMLX = fetchList(urlMLX)
        async let listLM = fetchList(urlLMStudio)
        var reposMLX = try await listMLX
        let reposLMAll = try await listLM

        // Filter LM Studio to MLX variants only (exclude GGUF-only repos)
        let reposLMXLite = reposLMAll.filter { repo in
            let idLower = repo.id.lowercased()
            if idLower.contains("mlx") { return true }
            if let tags = repo.tags, tags.contains(where: { $0.lowercased().contains("mlx") }) { return true }
            return false
        }

        // Merge and de-duplicate by id
        reposMLX.append(contentsOf: reposLMXLite)
        var seen: Set<String> = []
        var mergedList: [HFRepo] = []
        mergedList.reserveCapacity(reposMLX.count)
        for repo in reposMLX {
            if !seen.contains(repo.id) {
                seen.insert(repo.id)
                mergedList.append(repo)
            }
        }

        // Sort by downloads desc if available
        mergedList.sort { (a, b) -> Bool in
            let da = a.downloads ?? 0
            let db = b.downloads ?? 0
            return da == db ? a.id < b.id : da > db
        }

        // Fetch detailed info (including siblings with sizes) for a subset to avoid rate limits
        let maxDetailCount = 60
        let toDetail = Array(mergedList.prefix(maxDetailCount))

        var detailedRepos: [HFRepo] = []
        detailedRepos.reserveCapacity(toDetail.count)

        try await withThrowingTaskGroup(of: HFRepo?.self) { group in
            for repo in toDetail {
                group.addTask {
                    return try? await fetchHFRepoDetail(id: repo.id)
                }
            }
            for try await result in group {
                if let repo = result {
                    detailedRepos.append(repo)
                }
            }
        }

        // Merge: use detailed entries when available; otherwise fall back to list entries
        let detailedById = Dictionary(uniqueKeysWithValues: detailedRepos.map { ($0.id, $0) })
        let merged = mergedList.map { detailedById[$0.id] ?? $0 }

        // Cache and return
        repoCacheSet(key: cacheKey, value: merged)
        return merged
    }

    /// Fetch a single repo with detailed metadata (siblings and sizes)
    static func fetchHFRepoDetail(id: String) async throws -> HFRepo {
        let base = "https://huggingface.co/api/models/"
        // Ask HF to expand siblings so we have filenames and, when available, sizes
        guard let url = URL(string: base + id + "?expand=siblings") else {
            throw NSError(domain: "HFAPI", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid repo id"])
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("osaurus/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "HFAPI", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected status for detail"])
        }
        let decoder = IkigaJSONDecoder()
        return try decoder.decode(HFRepo.self, from: data)
    }

    /// Compute the total size of all .safetensors files for a repo.
    /// If HF detail lacks sizes, this will issue HEAD requests to resolve sizes.
    static func computeTotalSafetensorsBytes(for repoId: String, siblings: [HFSibling]?) async -> Int64 {
        guard let siblings else { return 0 }
        let safetensors = siblings.filter { $0.rfilename.hasSuffix(".safetensors") }
        if safetensors.isEmpty { return 0 }

        // If all sizes are known, sum and return
        let knownSizes = safetensors.compactMap { $0.size }
        if knownSizes.count == safetensors.count, let total = knownSizes.reduce(0, +) as Int64? {
            return total
        }

        // Otherwise, HEAD each safetensors file to retrieve Content-Length
        var total: Int64 = 0
        for file in safetensors {
            guard let url = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(file.rfilename)") else { continue }
            if let length = await headContentLength(for: url) {
                total += length
            }
        }
        return total
    }

    /// Perform an HTTP HEAD request and return Content-Length if present
    static func headContentLength(for url: URL) async -> Int64? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "HEAD"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("osaurus/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if let value = http.value(forHTTPHeaderField: "Content-Length"), let length = Int64(value) {
                return length
            }
        } catch {
            // Ignore failures; return nil so callers can skip
        }
        return nil
    }

    /// Map HF repos into our MLXModel representation
    static func mapReposToMLXModels(_ repos: [HFRepo]) -> [MLXModel] {
        // Prefer public repos; do not hard-require 'siblings' in list response
        let candidateRepos = repos.filter { repo in
            return repo.private_ != true
        }

        let requiredFiles = [
            "model.safetensors",
            "config.json",
            "tokenizer_config.json",
            "tokenizer.json",
            "special_tokens_map.json"
        ]

        let models: [MLXModel] = candidateRepos.map { repo in
            // Derive a friendly name and description
            let name = friendlyName(from: repo.id)
            let description = buildDescription(from: repo)
            let size: Int64 = {
                // Sum known safetensors sizes if present; fallback to 0
                if let siblings = repo.siblings, !siblings.isEmpty {
                    return siblings
                        .filter { $0.rfilename.hasSuffix(".safetensors") }
                        .compactMap { $0.size }
                        .reduce(0, +)
                }
                // If siblings absent in detail, try estimating: prefer larger common file names
                // Leave 0 if we cannot infer; UI will still function
                return 0
            }()

            return MLXModel(
                id: repo.id,
                name: name,
                description: description,
                size: size,
                downloadURL: "https://huggingface.co/\(repo.id)",
                requiredFiles: requiredFiles
            )
        }

        // Sort by downloads (desc) if available; otherwise by name
        return models.sorted { lhs, rhs in
            let l = repos.first(where: { $0.id == lhs.id })?.downloads ?? 0
            let r = repos.first(where: { $0.id == rhs.id })?.downloads ?? 0
            return l == r ? lhs.name < rhs.name : l > r
        }
    }

    static func friendlyName(from repoId: String) -> String {
        // Take the last path component and title-case-ish
        let last = repoId.split(separator: "/").last.map(String.init) ?? repoId
        let spaced = last.replacingOccurrences(of: "-", with: " ")
        // Keep common tokens uppercase
        return spaced
            .replacingOccurrences(of: "llama", with: "Llama", options: .caseInsensitive)
            .replacingOccurrences(of: "qwen", with: "Qwen", options: .caseInsensitive)
            .replacingOccurrences(of: "gemma", with: "Gemma", options: .caseInsensitive)
            .replacingOccurrences(of: "deepseek", with: "DeepSeek", options: .caseInsensitive)
    }

    static func buildDescription(from repo: HFRepo) -> String {
        if let short = repo.cardData?.short_description, !short.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return short
        }
        // Fall back to tags-based compact summary
        let tags = repo.tags ?? []
        let quant = tags.first { $0.lowercased().contains("4bit") || $0.lowercased().contains("8bit") || $0.lowercased().contains("fp16") || $0.lowercased().contains("bf16") }
        let arch = inferredArch(from: repo.id, tags: tags)
        var parts: [String] = []
        if let arch { parts.append(arch) }
        if let quant { parts.append(quant.uppercased()) }
        if (tags.contains { $0 == "text-generation" }) { parts.append("text-generation") }
        if parts.isEmpty { return "Model from Hugging Face" }
        return parts.joined(separator: " • ")
    }

    static func inferredArch(from id: String, tags: [String]) -> String? {
        let idLower = id.lowercased()
        if idLower.contains("llama") { return "Llama" }
        if idLower.contains("qwen") { return "Qwen" }
        if idLower.contains("gemma") { return "Gemma" }
        if idLower.contains("deepseek") { return "DeepSeek" }
        if idLower.contains("mistral") { return "Mistral" }
        if idLower.contains("mixtral") { return "Mixtral" }
        if idLower.contains("phi") { return "Phi" }
        if let t = tags.first(where: { $0.lowercased().contains("llama") || $0.lowercased().contains("qwen") || $0.lowercased().contains("gemma") || $0.lowercased().contains("deepseek") || $0.lowercased().contains("mistral") }) { return t.capitalized }
        return nil
    }
}


