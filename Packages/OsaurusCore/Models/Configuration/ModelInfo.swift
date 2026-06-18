//
//  ModelInfo.swift
//  osaurus
//
//  Provides detailed model metadata for the show command and API endpoint.
//

import Foundation

/// Detailed model information extracted from config files
struct ModelInfo: Codable, Sendable {
    /// Model name/identifier
    let name: String

    /// Model details section
    let model: ModelDetails

    /// Capabilities section
    let capabilities: [String]

    /// Generation parameters section
    let parameters: ModelParameters

    /// Ollama-compatible model details
    struct ModelDetails: Codable, Sendable {
        let architecture: String?
        let parameters: String?
        let contextLength: Int?
        let embeddingLength: Int?
        let quantization: String?

        private enum CodingKeys: String, CodingKey {
            case architecture
            case parameters
            case contextLength = "context_length"
            case embeddingLength = "embedding_length"
            case quantization
        }
    }

    /// Generation parameters from generation_config.json or defaults
    struct ModelParameters: Codable, Sendable {
        let temperature: Double?
        let topP: Double?
        let topK: Int?
        let stop: [String]?
        let repeatPenalty: Double?

        private enum CodingKeys: String, CodingKey {
            case temperature
            case topP = "top_p"
            case topK = "top_k"
            case stop
            case repeatPenalty = "repeat_penalty"
        }
    }
}

// MARK: - Model Info Extraction

extension ModelInfo {
    // Process-wide memo for `load(modelId:)`. This is read from view bodies
    // (e.g. `FloatingInputCard.maxContextTokens`), and each miss walks the model
    // directory and reads + parses `config.json` and `generation_config.json` from
    // disk — synchronous I/O that hangs the UI when it runs on every body eval.
    // Only successful loads are cached (so a not-yet-downloaded model is re-probed),
    // and the cache is dropped on `.localModelsChanged` to stay in sync with disk.
    //
    // `.localModelsChanged` only fires when the discovered model *set* changes,
    // NOT when a `config.json` is rewritten in place at the same id/path (e.g. a
    // bundle re-quantized or its context window edited under the same name). To
    // keep the resolved context window — and every other config-derived field —
    // honest across in-place edits, a hit kicks off a throttled background
    // re-stat (`revalidateInBackground`) of the cached `config.json`; when its
    // modification date changed, the memo is dropped and `.localModelsChanged`
    // is posted so dependent UI re-probes. The synchronous hit path itself never
    // touches disk, so it can't hang the UI that reads it on every body eval.
    private struct CacheEntry {
        let info: ModelInfo
        let configPath: String
        let configModDate: Date?
    }
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: CacheEntry] = [:]
    private nonisolated(unsafe) static var didInstallObserver = false

    // Throttle state for the off-main `config.json` re-stat. The synchronous
    // hit path serves the memo without touching disk (it runs on every view
    // body eval), so in-place edits are detected by a background probe spaced
    // at least `revalidateInterval` apart per model id, never more than one
    // in flight at a time.
    private static let revalidateInterval: TimeInterval = 3.0
    private nonisolated(unsafe) static var lastRevalidated: [String: Date] = [:]
    private nonisolated(unsafe) static var revalidatingModelIds: Set<String> = []

    // Per-id in-flight marker for the off-main cold-miss warm (`warmInBackground`),
    // so repeated cold reads from a view body don't spawn a probe on every layout
    // pass while the first one is still walking the disk.
    private nonisolated(unsafe) static var warmingModelIds: Set<String> = []

    /// Modification date of a file, or nil if it is missing/unreadable. Used to
    /// detect in-place `config.json` edits that `.localModelsChanged` misses.
    /// Goes through `FileManager.attributesOfItem` on a path string rather than
    /// `URL.resourceValues`: `NSURL` caches resource values per instance, so
    /// re-statting a stored `URL` would return the date from when it was first
    /// read (never seeing the in-place edit) — exactly the staleness this guards.
    private static func fileModificationDate(atPath path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date
    }

    /// Re-stat a cached model's `config.json` off the main thread to detect
    /// in-place edits, throttled per model id so the hot synchronous path
    /// (called from view bodies) never blocks on disk. If the file changed,
    /// drop the stale memo and post `.localModelsChanged` so dependent UI
    /// re-probes from disk — the same signal the rest of the app uses.
    private static func revalidateInBackground(modelId: String, entry: CacheEntry) {
        let now = Date()
        cacheLock.lock()
        let recentlyChecked =
            lastRevalidated[modelId].map { now.timeIntervalSince($0) < revalidateInterval } ?? false
        if revalidatingModelIds.contains(modelId) || recentlyChecked {
            cacheLock.unlock()
            return
        }
        revalidatingModelIds.insert(modelId)
        lastRevalidated[modelId] = now
        cacheLock.unlock()

        Task.detached(priority: .utility) {
            defer { finishRevalidation(modelId: modelId) }
            // Memo still matches disk — nothing to do.
            if fileModificationDate(atPath: entry.configPath) == entry.configModDate {
                return
            }
            dropCachedEntry(modelId: modelId)
            NotificationCenter.default.post(name: .localModelsChanged, object: nil)
        }
    }

    /// Drop a single memoized entry. Synchronous so the lock is taken outside
    /// any async context (`NSLock.lock()` is unavailable from async code).
    private static func dropCachedEntry(modelId: String) {
        cacheLock.lock()
        cache.removeValue(forKey: modelId)
        cacheLock.unlock()
    }

    /// Clear a model's in-flight revalidation marker. Synchronous for the same
    /// async-context locking reason as `dropCachedEntry`.
    private static func finishRevalidation(modelId: String) {
        cacheLock.lock()
        revalidatingModelIds.remove(modelId)
        cacheLock.unlock()
    }

    /// Load model info from a model identifier (e.g., "mlx-community/Qwen3-1.7B-4bit" or "qwen3-1.7b-4bit")
    static func load(modelId: String) -> ModelInfo? {
        ensureCacheObserverInstalled()
        cacheLock.lock()
        let cached = cache[modelId]
        cacheLock.unlock()
        if let cached {
            // Serve the memo without touching the filesystem — this runs on
            // every view body eval (e.g. `FloatingInputCard.maxContextTokens`),
            // and a synchronous `lstat` here hangs the UI. In-place `config.json`
            // edits (which `.localModelsChanged` misses) are caught by a
            // throttled background re-stat that drops the memo and re-probes.
            revalidateInBackground(modelId: modelId, entry: cached)
            return cached.info
        }
        // Cache miss — re-probe from disk.

        // Try to find the model directory
        guard let directory = findModelDirectory(for: modelId) else {
            return nil
        }

        let info = load(from: directory, modelId: modelId)
        if let info {
            let configPath = directory.appendingPathComponent("config.json").path
            let entry = CacheEntry(
                info: info,
                configPath: configPath,
                configModDate: fileModificationDate(atPath: configPath)
            )
            cacheLock.lock()
            cache[modelId] = entry
            cacheLock.unlock()
        }
        return info
    }

    /// Cache-only variant for synchronous view/layout paths. Returns the memo
    /// when present; on a cold miss it warms the cache off the main thread and
    /// returns nil immediately instead of probing disk on the calling thread.
    /// `load(modelId:)`'s cold path runs `findModelDirectory`, whose
    /// `contentsOfDirectoryAtURL` (a `getattrlistbulk` syscall) plus the
    /// `config.json` read have hung the UI when reached from a SwiftUI getter
    /// during layout (e.g. `ContextSizeResolver.resolve` off a chat body). A
    /// later render serves the now-warm memo; callers treat the transient nil
    /// as "unknown" and fall back conservatively rather than blocking.
    static func loadCachedOrWarm(modelId: String) -> ModelInfo? {
        ensureCacheObserverInstalled()
        cacheLock.lock()
        let cached = cache[modelId]
        cacheLock.unlock()
        if let cached {
            revalidateInBackground(modelId: modelId, entry: cached)
            return cached.info
        }
        warmInBackground(modelId: modelId)
        return nil
    }

    /// Probe disk for `modelId` off the main thread to fill the memo, guarded by
    /// a per-id in-flight marker so cold reads from a view body don't spawn a
    /// probe on every layout pass.
    private static func warmInBackground(modelId: String) {
        cacheLock.lock()
        let alreadyWarming = warmingModelIds.contains(modelId)
        if !alreadyWarming { warmingModelIds.insert(modelId) }
        cacheLock.unlock()
        if alreadyWarming { return }

        Task.detached(priority: .utility) {
            // `finishWarming` is synchronous so the lock is taken outside this
            // async context (`NSLock.lock()` is unavailable from async code).
            defer { finishWarming(modelId: modelId) }
            // Fills `cache[modelId]` from disk as a side effect; the next view
            // render serves the memo. Deliberately no `.localModelsChanged`
            // post — the cache observer clears every entry on that signal, which
            // would drop the memo just filled and re-trigger this warm forever.
            _ = load(modelId: modelId)
        }
    }

    /// Clear a model's in-flight warm marker. Synchronous for the same
    /// async-context locking reason as `finishRevalidation`.
    private static func finishWarming(modelId: String) {
        cacheLock.lock()
        warmingModelIds.remove(modelId)
        cacheLock.unlock()
    }

    private static func ensureCacheObserverInstalled() {
        cacheLock.lock()
        let already = didInstallObserver
        didInstallObserver = true
        cacheLock.unlock()
        if already { return }

        NotificationCenter.default.addObserver(
            forName: .localModelsChanged,
            object: nil,
            queue: nil
        ) { _ in
            ModelInfo.cacheLock.lock()
            ModelInfo.cache.removeAll(keepingCapacity: true)
            ModelInfo.cacheLock.unlock()
        }
    }

    /// Load model info from a local directory
    static func load(from directory: URL, modelId: String) -> ModelInfo? {
        let configURL = directory.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configURL),
            let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any]
        else {
            return nil
        }

        // Extract architecture
        let architecture = extractArchitecture(from: config)

        // Extract context length
        let contextLength = extractContextLength(from: config)

        // Extract embedding length (hidden size)
        let embeddingLength = extractEmbeddingLength(from: config)

        let parameterCount = ModelMetadataParser.parameterCount(from: modelId)
        let quantization = ModelMetadataParser.quantizationOllama(from: modelId)

        // Detect capabilities
        var capabilities = ["completion"]
        if VLMDetection.isVLM(at: directory) {
            capabilities.append("vision")
        }

        // Load generation parameters
        let parameters = loadGenerationParameters(from: directory)

        let details = ModelDetails(
            architecture: architecture,
            parameters: parameterCount,
            contextLength: contextLength,
            embeddingLength: embeddingLength,
            quantization: quantization
        )

        return ModelInfo(
            name: modelId,
            model: details,
            capabilities: capabilities,
            parameters: parameters
        )
    }

    // MARK: - Private Helpers

    private static func findModelDirectory(for modelId: String) -> URL? {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let root = DirectoryPickerService.effectiveModelsDirectory()
        let fm = FileManager.default

        // If modelId contains "/", try as full path (org/repo)
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/").map(String.init)
            let url = parts.reduce(root) { partial, component in
                partial.appendingPathComponent(component, isDirectory: true)
            }
            if fm.fileExists(atPath: url.appendingPathComponent("config.json").path) {
                return url
            }
        }

        // Try to find by repo name only (search all org directories)
        let lowerName = trimmed.lowercased()
        if let orgDirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for orgURL in orgDirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: orgURL.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                if let repos = try? fm.contentsOfDirectory(
                    at: orgURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for repoURL in repos {
                        let repoName = repoURL.lastPathComponent.lowercased()
                        if repoName == lowerName {
                            if fm.fileExists(atPath: repoURL.appendingPathComponent("config.json").path) {
                                return repoURL
                            }
                        }
                    }
                }
            }
        }

        return nil
    }

    private static func extractArchitecture(from config: [String: Any]) -> String? {
        // Try model_type first (most common)
        if let modelType = config["model_type"] as? String {
            return modelType
        }

        // Try architectures array
        if let architectures = config["architectures"] as? [String], let first = architectures.first {
            // Remove "ForCausalLM" suffix if present
            return
                first
                .replacingOccurrences(of: "ForCausalLM", with: "")
                .replacingOccurrences(of: "ForConditionalGeneration", with: "")
        }

        return nil
    }

    private static func extractContextLength(from config: [String: Any]) -> Int? {
        // Try various keys used by different models
        let contextKeys = [
            "max_position_embeddings",
            "max_seq_len",
            "max_sequence_length",
            "n_positions",
            "seq_length",
            "context_length",
            "sliding_window",
        ]

        for key in contextKeys {
            if let value = config[key] as? Int {
                return value
            }
        }

        // Check text_config for VLM models
        if let textConfig = config["text_config"] as? [String: Any] {
            for key in contextKeys {
                if let value = textConfig[key] as? Int {
                    return value
                }
            }
        }

        return nil
    }

    private static func extractEmbeddingLength(from config: [String: Any]) -> Int? {
        // Try hidden_size first (most common)
        if let hiddenSize = config["hidden_size"] as? Int {
            return hiddenSize
        }

        // Try d_model (for some transformer variants)
        if let dModel = config["d_model"] as? Int {
            return dModel
        }

        // Try n_embd (GPT-style)
        if let nEmbd = config["n_embd"] as? Int {
            return nEmbd
        }

        // Check text_config for VLM models
        if let textConfig = config["text_config"] as? [String: Any] {
            if let hiddenSize = textConfig["hidden_size"] as? Int {
                return hiddenSize
            }
        }

        return nil
    }

    private static func loadGenerationParameters(from directory: URL) -> ModelParameters {
        let generationConfigURL = directory.appendingPathComponent("generation_config.json")

        var temperature: Double?
        var topP: Double?
        var topK: Int?
        var stop: [String]?
        var repeatPenalty: Double?

        if let data = try? Data(contentsOf: generationConfigURL),
            let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            temperature = config["temperature"] as? Double
            topP = config["top_p"] as? Double
            topK = config["top_k"] as? Int
            repeatPenalty = config["repetition_penalty"] as? Double

            // Extract stop sequences (eos_token_id or stop_strings)
            if let stopStrings = config["stop_strings"] as? [String] {
                stop = stopStrings
            } else if let eosToken = config["eos_token"] as? String {
                stop = [eosToken]
            }
        }

        return ModelParameters(
            temperature: temperature,
            topP: topP,
            topK: topK,
            stop: stop,
            repeatPenalty: repeatPenalty
        )
    }
}

// MARK: - Ollama-compatible response format

/// Request body for /api/show endpoint
struct ShowRequest: Decodable, Sendable {
    let model: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Accept "model" (Ollama spec) and legacy "name"
        if let model = try container.decodeIfPresent(String.self, forKey: .model) {
            self.model = model
        } else {
            self.model = try container.decode(String.self, forKey: .name)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case model, name
    }
}

/// Response body for /api/show endpoint (Ollama-compatible)
struct ShowResponse: Codable, Sendable {
    let modelfile: String
    let parameters: String
    let template: String
    let details: ShowDetails
    let modelInfo: [String: AnyCodable]

    private enum CodingKeys: String, CodingKey {
        case modelfile
        case parameters
        case template
        case details
        case modelInfo = "model_info"
    }

    struct ShowDetails: Codable, Sendable {
        let parentModel: String
        let format: String
        let family: String
        let families: [String]
        let parameterSize: String
        let quantizationLevel: String

        private enum CodingKeys: String, CodingKey {
            case parentModel = "parent_model"
            case format
            case family
            case families
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
        }
    }
}

/// Type-erased Codable wrapper for heterogeneous JSON values
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Show Response Builder

extension ModelInfo {
    /// Convert ModelInfo to Ollama-compatible ShowResponse
    func toShowResponse() -> ShowResponse {
        // Build parameters string (Ollama format)
        var paramLines: [String] = []
        if let temp = parameters.temperature {
            paramLines.append("temperature \(temp)")
        }
        if let topP = parameters.topP {
            paramLines.append("top_p \(topP)")
        }
        if let topK = parameters.topK {
            paramLines.append("top_k \(topK)")
        }
        if let stops = parameters.stop {
            for s in stops {
                paramLines.append("stop \"\(s)\"")
            }
        }
        if let repeat_penalty = parameters.repeatPenalty {
            paramLines.append("repeat_penalty \(repeat_penalty)")
        }

        // Build model_info dictionary
        var modelInfoDict: [String: AnyCodable] = [:]
        if let arch = model.architecture {
            modelInfoDict["general.architecture"] = AnyCodable(arch)
        }
        if let params = model.parameters {
            modelInfoDict["general.parameter_count"] = AnyCodable(params)
        }
        if let ctx = model.contextLength {
            modelInfoDict["\(model.architecture ?? "model").context_length"] = AnyCodable(ctx)
        }
        if let embed = model.embeddingLength {
            modelInfoDict["\(model.architecture ?? "model").embedding_length"] = AnyCodable(embed)
        }

        let details = ShowResponse.ShowDetails(
            parentModel: "",
            format: "safetensors",
            family: model.architecture ?? "unknown",
            families: [model.architecture ?? "unknown"],
            parameterSize: model.parameters ?? "",
            quantizationLevel: model.quantization ?? ""
        )

        return ShowResponse(
            modelfile: "",
            parameters: paramLines.joined(separator: "\n"),
            template: "",
            details: details,
            modelInfo: modelInfoDict
        )
    }
}
