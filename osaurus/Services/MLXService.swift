//
//  MLXService.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation
import MLXLMCommon
import MLXLLM
import IkigaJSON
import NIOCore
import CryptoKit

// MARK: - Debug logging helpers (gated by environment variables)
private enum DebugLog {
    static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["OSU_DEBUG"] == "1"
    }()
    static let promptMode: String? = {
        let env = ProcessInfo.processInfo.environment
        return env["OSU_DEBUG_PROMPT"]
    }()
    @inline(__always)
    static func log(_ category: String, _ message: @autoclosure () -> String) {
        guard enabled else { return }
        print("[Osaurus][\(category)] \(message())")
    }
    @inline(__always)
    static func prompt(_ message: @autoclosure () -> String) {
        guard let mode = promptMode, !mode.isEmpty else { return }
        print("[Osaurus][PROMPT] \(message())")
    }
}

/// Represents a language model configuration
class LMModel {
    let name: String
    let modelId: String  // The model ID from ModelManager (e.g., "mlx-community/Llama-3.2-3B-Instruct-4bit")
    
    init(name: String, modelId: String) {
        self.name = name
        self.modelId = modelId
    }
}

/// Message role for chat interactions
enum MessageRole: String, Codable {
    case system
    case user
    case assistant
}

/// Chat message structure
struct Message: Codable {
    let role: MessageRole
    let content: String
    
    init(role: MessageRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// A service class that manages machine learning models for text generation tasks.
/// This class handles model loading, caching, and text generation using various LLM models.
@Observable
final class MLXService: @unchecked Sendable {
    static let shared = MLXService()
    
    struct GenerationSettings {
        var topP: Float
        var kvBits: Int?
        var kvGroupSize: Int
        var quantizedKVStart: Int
        var maxKVSize: Int?
        var prefillStepSize: Int
    }
    
    /// Thread-safe cache of available model names
    nonisolated(unsafe) private static let availableModelsCache = NSCache<NSString, NSArray>()
    
    /// Cache for model lookups to avoid repeated disk scanning
    nonisolated(unsafe) private static let modelLookupCache = NSCache<NSString, LMModel>()
    
    
    /// Concurrent queue for thread-safe model lookup operations
    private static let modelLookupQueue = DispatchQueue(label: "com.osaurus.model.lookup", attributes: .concurrent)
    
    /// Timestamp for cached models list
    nonisolated(unsafe) private static var modelsListCacheTimestamp: Date?
    
    /// List of available models that can be used for generation.
    /// Dynamically generated from downloaded models
    @MainActor var availableModels: [LMModel] {
        // Get downloaded models from ModelManager
        let downloadedModels = ModelManager.shared.availableModels.filter { $0.isDownloaded }
        
        // Map downloaded models to LMModel
        return downloadedModels.map { downloadedModel in
            LMModel(
                name: downloadedModel.name.lowercased().replacingOccurrences(of: " ", with: "-"),
                modelId: downloadedModel.id
            )
        }
    }
    
    /// Cache to store loaded model containers to avoid reloading weights from disk.
    private final class SessionHolder: NSObject {
        let container: ModelContainer
        init(container: ModelContainer) {
            self.container = container
        }
    }
    
    private let modelCache = NSCache<NSString, SessionHolder>()

    // MARK: - In-memory prefix cache (LRU with TTL)
    private final class PrefixCacheBox: NSObject {
        let caches: [KVCache]
        let inserted: Date
        init(caches: [KVCache], inserted: Date) {
            self.caches = caches
            self.inserted = inserted
        }
    }
    nonisolated(unsafe) private static let prefixCacheLRU = NSCache<NSString, PrefixCacheBox>()
    private static let prefixCacheQueue = DispatchQueue(label: "com.osaurus.prefixcache", attributes: .concurrent)
    private static let prefixLRUMaxEntries: Int = {
        let env = ProcessInfo.processInfo.environment
        return Int(env["OSU_PREFIX_LRU_MAX"] ?? "") ?? 8
    }()
    private static let prefixLRUTTLSeconds: TimeInterval = {
        let env = ProcessInfo.processInfo.environment
        return TimeInterval(Int(env["OSU_PREFIX_LRU_TTL"] ?? "") ?? 900)
    }()

    /// LRU cache for reusable ChatSession keyed by (modelName, sessionId)
    private struct SessionKey: Hashable, Sendable { let model: String; let session: String }
    private var reusableSessions: [SessionKey: (session: ChatSession, lastUsed: Date)] = [:]
    private var reusableOrder: [SessionKey] = []
    private let sessionCacheQueue = DispatchQueue(label: "com.osaurus.sessioncache", attributes: .concurrent)
    private var activeReuseKeys: Set<SessionKey> = []

    /// Per-model concurrency gates to protect underlying MLX containers
    private final class ConcurrencyGate {
        private let semaphore: DispatchSemaphore
        init(limit: Int) { self.semaphore = DispatchSemaphore(value: max(1, limit)) }
        func wait() { semaphore.wait() }
        func signal() { semaphore.signal() }
    }
    private var modelGates: [String: ConcurrencyGate] = [:]
    private let reusableMaxCount: Int = {
        let env = ProcessInfo.processInfo.environment
        return Int(env["OSU_SESSION_CACHE_MAX"] ?? "") ?? 32
    }()
    private let reusableTTLSeconds: TimeInterval = {
        let env = ProcessInfo.processInfo.environment
        return TimeInterval(Int(env["OSU_SESSION_CACHE_TTL"] ?? "") ?? 300)
    }()
    
    /// Currently loaded model name
    private(set) var currentModelName: String?
    
    /// Tracks the current model download progress.
    /// Access this property to monitor model download status.
    private(set) var modelDownloadProgress: Progress?
    
    // Adjustable generation settings (can be tuned via UI)
    private(set) var generationSettings: GenerationSettings = {
        let env = ProcessInfo.processInfo.environment
        let topP: Float = Float(env["OSU_TOP_P"] ?? "") ?? 0.95
        let kvBits: Int? = Int(env["OSU_KV_BITS"] ?? "") ?? 4
        let kvGroup: Int = Int(env["OSU_KV_GROUP"] ?? "") ?? 64
        let quantStart: Int = Int(env["OSU_QUANT_KV_START"] ?? "") ?? 0
        let maxKV: Int? = Int(env["OSU_MAX_KV_SIZE"] ?? "")
        let prefillStep: Int = Int(env["OSU_PREFILL_STEP"] ?? "") ?? 4096
        return GenerationSettings(
            topP: topP,
            kvBits: kvBits,
            kvGroupSize: kvGroup,
            quantizedKVStart: quantStart,
            maxKVSize: maxKV,
            prefillStepSize: prefillStep
        )
    }()
    
    private init() {
        // Initialize the cache with current available models
        updateAvailableModelsCache()
        // Configure in-memory prefix cache
        Self.prefixCacheLRU.countLimit = Self.prefixLRUMaxEntries
        
        // Update cache whenever ModelManager changes
        Task { @MainActor in
            // Observe changes and update cache
            // This ensures the cache stays in sync
            updateAvailableModelsCache()
        }
    }
    
    /// Warm up a model by loading it and generating a tiny response to compile kernels and populate caches.
    /// - Parameters:
    ///   - modelName: Optional model name to warm up. If nil, attempts a best-effort default.
    ///   - prefillChars: If > 0, use a long user message with this many characters to exercise prefill compilation.
    ///   - maxTokens: Number of tokens to emit during warm-up (default 1)
    func warmUp(modelName: String? = nil, prefillChars: Int = 0, maxTokens: Int = 1) async {
        // Choose a model: explicit name -> find; otherwise pick first available
        let chosen: LMModel? = {
            if let name = modelName, let m = Self.findModel(named: name) { return m }
            if let first = Self.getAvailableModels().first, let m = Self.findModel(named: first) { return m }
            return nil
        }()
        guard let model = chosen else {
            if let requested = modelName {
                print("[Osaurus] Warm-up skipped: requested model not found: \(requested)")
                DebugLog.log("WARMUP", "Requested warm-up model not found: \(requested)")
            } else {
                let available = Self.getAvailableModels()
                if available.isEmpty {
                    print("[Osaurus] Warm-up skipped: no available models found on disk")
                    DebugLog.log("WARMUP", "No available models found during warm-up")
                } else {
                    print("[Osaurus] Warm-up skipped: unable to select a model (\(available.count) available)")
                    DebugLog.log("WARMUP", "Unable to select a warm-up model from available list: \(available)")
                }
            }
            return
        }

        // Validate model files are present before attempting warm-up
        guard Self.findLocalDirectory(forModelId: model.modelId) != nil else {
            print("[Osaurus] Warm-up skipped: model not downloaded locally: \(model.name)")
            DebugLog.log("WARMUP", "Model not downloaded for warm-up: \(model.name)")
            return
        }

        DebugLog.log("WARMUP", "Starting warm-up for model=\(model.name), prefillChars=\(prefillChars), maxTokens=\(maxTokens)")

        let warmupContent: String = prefillChars > 0 ? String(repeating: "A", count: max(1, prefillChars)) : String(repeating: "A", count: 1024)
        let messages = [Message(role: .user, content: warmupContent)]        
        do {
            let stream = try await generate(messages: messages, model: model, temperature: 0.0, maxTokens: maxTokens)
            // Consume the small warm-up stream
            for await _ in stream { /* no-op */ }
        } catch {
            // Non-fatal: warm-up is best effort, but log for visibility
            print("[Osaurus] Warm-up failed for model \(model.name): \(error)")
            DebugLog.log("WARMUP", "Warm-up failed for model=\(model.name): \(error.localizedDescription)")
        }
    }
    
    /// Update the cached list of available models
    func updateAvailableModelsCache() {
        let pairs = Self.scanDiskForModels()
        let modelNames = pairs.map { $0.name }
        Self.availableModelsCache.setObject(modelNames as NSArray, forKey: "models" as NSString)

        // Also cache model info for findModel
        let modelInfo = pairs.map { pair in
            ["name": pair.name, "id": pair.id]
        }
        Self.availableModelsCache.setObject(modelInfo as NSArray, forKey: "modelInfo" as NSString)
        // Model set may have changed; clear any derived caches
    }
    
    /// Get list of available models that are downloaded (thread-safe)
    nonisolated static func getAvailableModels() -> [String] {
        return modelLookupQueue.sync(flags: .barrier) {
            if let cached = availableModelsCache.object(forKey: "models" as NSString) as? [String],
               let timestamp = modelsListCacheTimestamp,
               Date().timeIntervalSince(timestamp) < 5.0 {
                return cached
            }
            let pairs = Self.scanDiskForModels()
            let modelNames = pairs.map { $0.name }
            Self.availableModelsCache.setObject(modelNames as NSArray, forKey: "models" as NSString)
            let modelInfo = pairs.map { ["name": $0.name, "id": $0.id] }
            Self.availableModelsCache.setObject(modelInfo as NSArray, forKey: "modelInfo" as NSString)
            Self.modelsListCacheTimestamp = Date()
            return modelNames
        }
    }
    
    /// Find a model by name
    nonisolated static func findModel(named name: String) -> LMModel? {
        // Check cache first for fast lookups
        if let cached = modelLookupCache.object(forKey: name as NSString) {
            return cached
        }
        
        // Use concurrent queue for thread-safe disk scanning
        return modelLookupQueue.sync(flags: .barrier) {
            // Double-check cache after acquiring barrier (in case another thread just populated it)
            if let cached = modelLookupCache.object(forKey: name as NSString) {
                return cached
            }
            
            // Only scan disk if not in cache
            let pairs = Self.scanDiskForModels()
            
            // Try exact repo-name match first (lowercased)
            if let match = pairs.first(where: { $0.name == name }) {
                let model = LMModel(name: match.name, modelId: match.id)
                modelLookupCache.setObject(model, forKey: name as NSString)
                return model
            }
            
            // Try matching against full id's repo component (case-insensitive)
            if let match = pairs.first(where: { pair in
                let repo = pair.id.split(separator: "/").last.map(String.init)?.lowercased()
                return repo == name.lowercased()
            }) {
                let model = LMModel(name: match.name, modelId: match.id)
                modelLookupCache.setObject(model, forKey: name as NSString)
                return model
            }
            
            // Try full id match (case-insensitive)
            if let match = pairs.first(where: { $0.id.lowercased() == name.lowercased() }) {
                let model = LMModel(name: match.name, modelId: match.id)
                modelLookupCache.setObject(model, forKey: name as NSString)
                return model
            }
            
            // Update available models cache for consistency
            let modelNames = pairs.map { $0.name }
            Self.availableModelsCache.setObject(modelNames as NSArray, forKey: "models" as NSString)
            let modelInfo = pairs.map { ["name": $0.name, "id": $0.id] }
            Self.availableModelsCache.setObject(modelInfo as NSArray, forKey: "modelInfo" as NSString)
            
            return nil
        }
    }

    // MARK: - Disk Scanning for Downloaded Models
    /// Discover models on disk by inspecting the models directory.
    /// Returns pairs of (name, id) where id is "org/repo" and name is the repo lowercased.
    nonisolated private static func scanDiskForModels() -> [(name: String, id: String)] {
        let fm = FileManager.default
        let root = DirectoryPickerService.shared.effectiveModelsDirectory
        guard let topLevel = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var results: [(String, String)] = []

        func validateAndAppend(org: String, repo: String, repoURL: URL) {
            // Required JSON metadata files
            let jsonFiles = [
                "config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "special_tokens_map.json"
            ]
            let jsonOk = jsonFiles.allSatisfy { name in
                fm.fileExists(atPath: repoURL.appendingPathComponent(name).path)
            }
            guard jsonOk else { return }

            // At least one weights file
            guard let items = try? fm.contentsOfDirectory(at: repoURL, includingPropertiesForKeys: nil),
                  items.contains(where: { $0.pathExtension == "safetensors" }) else { return }

            let id = "\(org)/\(repo)"
            let name = repo.lowercased()
            results.append((name, id))
        }

        // Nested org/repo directories
        for orgURL in topLevel {
            var isOrgDir: ObjCBool = false
            guard fm.fileExists(atPath: orgURL.path, isDirectory: &isOrgDir), isOrgDir.boolValue else { continue }
            guard let repos = try? fm.contentsOfDirectory(at: orgURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for repoURL in repos {
                var isRepoDir: ObjCBool = false
                guard fm.fileExists(atPath: repoURL.path, isDirectory: &isRepoDir), isRepoDir.boolValue else { continue }
                validateAndAppend(org: orgURL.lastPathComponent, repo: repoURL.lastPathComponent, repoURL: repoURL)
            }
        }

        // De-duplicate while preserving order
        var seen: Set<String> = []
        var unique: [(String, String)] = []
        for (name, id) in results {
            if !seen.contains(id) {
                seen.insert(id)
                unique.append((name, id))
            }
        }
        return unique
    }

    /// Locate local directory for a given model id ("org/repo") if files exist
    nonisolated private static func findLocalDirectory(forModelId id: String) -> URL? {
        let parts = id.split(separator: "/").map(String.init)
        let url: URL = parts.reduce(DirectoryPickerService.shared.effectiveModelsDirectory) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
        let fm = FileManager.default
        let hasConfig = fm.fileExists(atPath: url.appendingPathComponent("config.json").path)
        if let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
           hasConfig && items.contains(where: { $0.pathExtension == "safetensors" }) {
            return url
        }
        return nil
    }

    /// Loads a model container from local storage or retrieves it from cache.
    private func load(model: LMModel) async throws -> SessionHolder {
        // Return cached model immediately without any disk I/O
        if let holder = modelCache.object(forKey: model.name as NSString) {
            return holder
        }

        // Find the local directory - findLocalDirectory already validates files exist
        guard let localURL = Self.findLocalDirectory(forModelId: model.modelId) else {
            throw NSError(domain: "MLXService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Model not downloaded: \(model.name)"
            ])
        }

        // Load the model container
        let container = try await loadModelContainer(directory: localURL)
        let holder = SessionHolder(container: container)
        
        // Cache for future requests
        modelCache.setObject(holder, forKey: model.name as NSString)
        currentModelName = model.name
        updateAvailableModelsCache()
        
        return holder
    }
    
    /// Generates text based on the provided messages using the specified model.
    /// - Parameters:
    ///   - messages: Array of chat messages including user, assistant, and system messages
    ///   - model: The language model to use for generation
    ///   - temperature: Controls randomness in generation (0.0 to 1.0)
    ///   - maxTokens: Maximum number of tokens to generate
    /// - Returns: An AsyncStream of generated text tokens
    /// - Throws: Errors that might occur during generation
    func generate(
        messages: [Message],
        model: LMModel,
        temperature: Float = 0.7,
        maxTokens: Int = 2048,
        tools: [Tool]? = nil,
        toolChoice: ToolChoiceOption? = nil,
        sessionId: String? = nil
    ) async throws -> AsyncStream<String> {
        // Load or retrieve the model container from cache
        let holder = try await load(model: model)

        // Acquire a per-model gate to avoid concurrent use of the same container
        let gate: ConcurrencyGate = sessionCacheQueue.sync(flags: .barrier) {
            if let g = modelGates[model.name] { return g }
            let env = ProcessInfo.processInfo.environment
            let limit = Int(env["OSU_MODEL_MAX_CONCURRENCY"] ?? "") ?? 1
            let g = ConcurrencyGate(limit: limit)
            modelGates[model.name] = g
            return g
        }
        
        // Determine system instructions and last user content efficiently.
        // Use only the most recent system message as instructions to respect templates expecting a single system prompt.
        let systemText: String = {
            for m in messages where m.role == .system { return m.content }
            return ""
        }()
        // Determine the user content to send. MLX ChatSession applies chat templates internally.
        // We send only the most recent user message text; if none, fallback to the most recent non-system message.
        let lastUserText: String = {
            for m in messages.reversed() where m.role == .user { return m.content }
            for m in messages.reversed() where m.role != .system { return m.content }
            return ""
        }()
        DebugLog.log("PROMPT", "Using ChatSession with instructionsLen=\(systemText.count), lastUserLen=\(lastUserText.count), msgs=\(messages.count)")

        // Build MLX generation parameters (temperature, sampling, KV cache, etc.)
        // Prefer UI configuration when available
        let cfg = await ServerController.sharedConfiguration()
        let topP: Float = cfg?.genTopP ?? 0.95
        let kvBits: Int? = cfg?.genKVBits
        let kvGroup: Int = cfg?.genKVGroupSize ?? 64
        let quantStart: Int = cfg?.genQuantizedKVStart ?? 0
        let maxKV: Int? = cfg?.genMaxKVSize
        let prefillStep: Int = cfg?.genPrefillStepSize ?? 4096

        let genParamsLocal = MLXLMCommon.GenerateParameters(
            maxTokens: maxTokens,
            maxKVSize: maxKV,
            kvBits: kvBits,
            kvGroupSize: kvGroup,
            quantizedKVStart: quantStart,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: nil,
            repetitionContextSize: 20
        )
        var genParams = genParamsLocal
        genParams.prefillStepSize = prefillStep

        // Optionally reuse a ChatSession (KV cache) for the same sessionId
        let (session, cacheKey, _): (ChatSession, SessionKey?, Bool) = {
            guard let sessionId, !sessionId.isEmpty else { return (ChatSession(holder.container, instructions: systemText.isEmpty ? nil : systemText, generateParameters: genParams), nil, false) }
            let key = SessionKey(model: model.name, session: sessionId)
            return sessionCacheQueue.sync(flags: .barrier) {
                evictExpiredReusableSessionsLocked(now: Date())
                // If a session exists but is actively in use, avoid reusing it concurrently
                if let existing = reusableSessions[key], !activeReuseKeys.contains(key), Date().timeIntervalSince(existing.lastUsed) < reusableTTLSeconds {
                    // Mark this key as active to prevent concurrent reuse
                    activeReuseKeys.insert(key)
                    // MRU update
                    if let idx = reusableOrder.firstIndex(of: key) { reusableOrder.remove(at: idx) }
                    reusableOrder.append(key)
                    return (existing.session, key, true)
                }
                // Either none exists, it expired, or it's currently in use — create a fresh session
                let newSession = ChatSession(holder.container, instructions: systemText.isEmpty ? nil : systemText, generateParameters: genParams)
                // Insert or refresh cache entry for future reuse
                reusableSessions[key] = (newSession, Date())
                if let idx = reusableOrder.firstIndex(of: key) { reusableOrder.remove(at: idx) }
                reusableOrder.append(key)
                // Mark as active so no one else reuses it concurrently
                activeReuseKeys.insert(key)
                while reusableOrder.count > reusableMaxCount {
                    if let idx = reusableOrder.firstIndex(where: { !activeReuseKeys.contains($0) }) {
                        let lru = reusableOrder.remove(at: idx)
                        reusableSessions.removeValue(forKey: lru)
                        DebugLog.log("CACHE", "Evicted LRU reusable session for key=\(lru)")
                    } else {
                        DebugLog.log("CACHE", "Cache at capacity but all sessions are active; deferring eviction")
                        break
                    }
                }
                return (newSession, key, false)
            }
        }()
        // Stream directly via ChatSession; it performs templating/tokenization per model
        let sessionStream = session.streamResponse(to: lastUserText)
        
        // Return a stream that forwards tokens; MLX enforces maxTokens internally
        return AsyncStream<String> { continuation in
            Task {
                gate.wait()
                defer { gate.signal() }
                do {
                    for try await token in sessionStream {
                        continuation.yield(token)
                    }
                } catch {
                    DebugLog.log("GEN", "Generation error for model=\(model.name): \(error.localizedDescription)")
                }
                // Release active flag for reused sessions
                if let key = cacheKey {
                    sessionCacheQueue.async(flags: .barrier) { [weak self] in
                        guard let self = self else { return }
                        self.activeReuseKeys.remove(key)
                        if let entry = self.reusableSessions[key] {
                            self.reusableSessions[key] = (entry.session, Date())
                        }
                        self.evictExpiredReusableSessionsLocked(now: Date())
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Generate event stream from MLX that can include both text chunks and tool call events.
    func generateEvents(
        messages: [Message],
        model: LMModel,
        temperature: Float = 0.7,
        maxTokens: Int = 2048,
        tools: [Tool]? = nil,
        toolChoice: ToolChoiceOption? = nil,
        sessionId: String? = nil
    ) async throws -> AsyncStream<MLXLMCommon.Generation> {
        let holder = try await load(model: model)

        // Acquire a per-model gate to avoid concurrent use of the same container
        let gate: ConcurrencyGate = sessionCacheQueue.sync(flags: .barrier) {
            if let g = modelGates[model.name] { return g }
            let env = ProcessInfo.processInfo.environment
            let limit = Int(env["OSU_MODEL_MAX_CONCURRENCY"] ?? "") ?? 1
            let g = ConcurrencyGate(limit: limit)
            modelGates[model.name] = g
            return g
        }

        // Prepare generation parameters from server configuration
        let cfg = await ServerController.sharedConfiguration()
        let topP: Float = cfg?.genTopP ?? 0.95
        let kvBits: Int? = cfg?.genKVBits
        let kvGroup: Int = cfg?.genKVGroupSize ?? 64
        let quantStart: Int = cfg?.genQuantizedKVStart ?? 0
        let maxKV: Int? = cfg?.genMaxKVSize
        let prefillStep: Int = cfg?.genPrefillStepSize ?? 4096

        let genParams: MLXLMCommon.GenerateParameters = {
            var p = MLXLMCommon.GenerateParameters(
                maxTokens: maxTokens,
                maxKVSize: maxKV,
                kvBits: kvBits,
                kvGroupSize: kvGroup,
                quantizedKVStart: quantStart,
                temperature: temperature,
                topP: topP,
                repetitionPenalty: nil,
                repetitionContextSize: 20
            )
            p.prefillStepSize = prefillStep
            return p
        }()

        // Map internal messages to MLX Chat.Message
        let chat: [MLXLMCommon.Chat.Message] = messages.map { m in
            let role: MLXLMCommon.Chat.Message.Role = {
                switch m.role {
                case .system: return .system
                case .user: return .user
                case .assistant: return .assistant
                }
            }()
            return MLXLMCommon.Chat.Message(role: role, content: m.content, images: [], videos: [])
        }

        // Convert OpenAI-style tools to Tokenizers.ToolSpec and honor tool_choice
        let tokenizerTools: [[String: Any]]? = {
            guard let tools, !tools.isEmpty else { return nil }
            if let toolChoice {
                switch toolChoice {
                case .none:
                    return nil
                case .auto:
                    return tools.map { $0.toTokenizerToolSpec() }
                case .function(let target):
                    let name = target.function.name
                    let filtered = tools.filter { $0.function.name == name }
                    return filtered.isEmpty ? nil : filtered.map { $0.toTokenizerToolSpec() }
                }
            } else {
                return tools.map { $0.toTokenizerToolSpec() }
            }
        }()

        // Build and return a wrapper stream that forwards MLX events and releases the gate on completion
        return AsyncStream<MLXLMCommon.Generation> { continuation in
            Task {
                gate.wait()
                defer { gate.signal() }
                do {
                    let stream: AsyncStream<MLXLMCommon.Generation> = try await holder.container.perform { (context: MLXLMCommon.ModelContext) in
                        // If there is no system prefix, fall back to normal generation
                        let maybeSystem: String? = {
                            for m in messages where m.role == .system { return m.content }
                            return nil
                        }()

                        // Prepare full chat input (for tokenization and to get delta tokens later)
                        let fullInput = MLXLMCommon.UserInput(chat: chat, processing: .init(), tools: tokenizerTools)
                        let fullLMInput = try await context.processor.prepare(input: fullInput)

                        guard let systemText = maybeSystem, !systemText.isEmpty else {
                            // No static system prefix -> no prefix cache
                            return try MLXLMCommon.generate(
                                input: fullLMInput,
                                cache: nil,
                                parameters: genParams,
                                context: context
                            )
                        }

                        // 1) Compute prefix tokens for the system prompt only (stable template)
                        let prefixChat: [MLXLMCommon.Chat.Message] = [.system(systemText)]
                        let prefixInput = MLXLMCommon.UserInput(chat: prefixChat, processing: .init(), tools: tokenizerTools)
                        let prefixLMInput = try await context.processor.prepare(input: prefixInput)

                        // Hash the prefix token ids to form a cache key per model+prefix
                        let prefixIds: [Int] = prefixLMInput.text.tokens.asArray(Int.self)
                        let prefixHash = Self.hashTokenIds(prefixIds)

                        // Determine on-disk cache location
                        let cacheURL = Self.prefixCacheURL(modelId: model.modelId, hash: prefixHash)

                        // 2) Load/build immutable base prefix cache and return a working clone
                        let workingCache: [KVCache] = try Self.getOrCreatePrefixWorkingCache(
                            modelId: model.modelId,
                            context: context,
                            prefixLMInput: prefixLMInput,
                            genParams: genParams,
                            prefixHash: prefixHash,
                            prefixTokenCount: prefixIds.count
                        )

                        // 3) Extend session cache with the delta tokens (full chat minus prefix)
                        let fullCount = fullLMInput.text.tokens.size
                        let prefixCount = prefixLMInput.text.tokens.size
                        let startIndex = min(prefixCount, fullCount)
                        let deltaTokens = fullLMInput.text.tokens[startIndex...]
                        let deltaLMInput = MLXLMCommon.LMInput(tokens: deltaTokens)

                        // 4) Generate with the combined cache; new tokens append to workingCache (session-specific)
                        return try MLXLMCommon.generate(
                            input: deltaLMInput,
                            cache: workingCache,
                            parameters: genParams,
                            context: context
                        )
                    }
                    for await event in stream {
                        continuation.yield(event)
                    }
                } catch {
                    DebugLog.log("GEN", "Event generation error for model=\(model.name): \(error.localizedDescription)")
                }
                continuation.finish()
            }
        }
    }

    private func evictExpiredReusableSessionsLocked(now: Date) {
        if reusableSessions.isEmpty { return }
        reusableOrder.removeAll { key in
            if let entry = reusableSessions[key] {
                if now.timeIntervalSince(entry.lastUsed) >= reusableTTLSeconds {
                    if activeReuseKeys.contains(key) {
                        DebugLog.log("CACHE", "Skipping eviction for in-use session key=\(key) (expired)")
                        return false
                    }
                    reusableSessions.removeValue(forKey: key)
                    DebugLog.log("CACHE", "Evicted expired reusable session for key=\(key)")
                    return true
                }
            }
            return false
        }
    }
    
    /// Unload a model from memory
    func unloadModel(named name: String) {
        modelCache.removeObject(forKey: name as NSString)
        if currentModelName == name {
            currentModelName = nil
        }
        
        // Update available models cache
        updateAvailableModelsCache()
    }
    
    /// Clear all cached models
    func clearCache() {
        modelCache.removeAllObjects()
        currentModelName = nil
        
        // Update available models cache
        updateAvailableModelsCache()
    }
}

// MARK: - Prompt Cache Utilities

extension MLXService {
    // MARK: - In-memory Prefix LRU helpers
    private static func prefixKey(modelId: String, hash: String) -> NSString {
        "\(modelId)::\(hash)" as NSString
    }

    private static func cloneCaches(_ caches: [KVCache]) -> [KVCache] {
        // Deep copy by round-tripping through state/metaState into new instances
        return caches.map { cache in
            switch cache {
            case let simple as KVCacheSimple:
                let copy = KVCacheSimple()
                copy.state = simple.state
                copy.metaState = simple.metaState
                return copy
            case let rot as RotatingKVCache:
                let initialMax = rot.maxSize ?? (rot.state.first?.dim(2) ?? 0)
                let copy = RotatingKVCache(maxSize: max(1, initialMax))
                copy.state = rot.state
                copy.metaState = rot.metaState
                return copy
            case let q as QuantizedKVCache:
                let copy = QuantizedKVCache(groupSize: q.groupSize, bits: q.bits)
                copy.state = q.state
                copy.metaState = q.metaState
                return copy
            case let chunked as ChunkedKVCache:
                let copy = ChunkedKVCache()
                copy.state = chunked.state
                copy.metaState = chunked.metaState
                return copy
            case let mamba as MambaCache:
                let copy = MambaCache()
                copy.state = mamba.state
                copy.metaState = mamba.metaState
                return copy
            default:
                let copy = KVCacheSimple()
                copy.state = cache.state
                copy.metaState = cache.metaState
                return copy
            }
        }
    }

    private static func getPrefixFromLRU(modelId: String, hash: String) -> [KVCache]? {
        let key = prefixKey(modelId: modelId, hash: hash)
        return prefixCacheQueue.sync {
            guard let box = prefixCacheLRU.object(forKey: key) else { return nil }
            if Date().timeIntervalSince(box.inserted) >= prefixLRUTTLSeconds {
                prefixCacheLRU.removeObject(forKey: key)
                return nil
            }
            return cloneCaches(box.caches)
        }
    }

    private static func putPrefixIntoLRU(modelId: String, hash: String, caches: [KVCache]) {
        let key = prefixKey(modelId: modelId, hash: hash)
        let cloned = cloneCaches(caches)
        let box = PrefixCacheBox(caches: cloned, inserted: Date())
        prefixCacheQueue.async(flags: .barrier) {
            prefixCacheLRU.setObject(box, forKey: key)
        }
    }

    /// Get a working (mutable) prefix cache for this request.
    /// Prefers in-memory LRU; falls back to on-disk; otherwise builds and persists.
    private static func getOrCreatePrefixWorkingCache(
        modelId: String,
        context: MLXLMCommon.ModelContext,
        prefixLMInput: MLXLMCommon.LMInput,
        genParams: MLXLMCommon.GenerateParameters,
        prefixHash: String,
        prefixTokenCount: Int
    ) throws -> [KVCache] {
        // Preferred: in-memory LRU
        if let mem = getPrefixFromLRU(modelId: modelId, hash: prefixHash) {
            return mem
        }

        // Next: on-disk cache
        let cacheURL = prefixCacheURL(modelId: modelId, hash: prefixHash)
        if FileManager.default.fileExists(atPath: cacheURL.path),
           let loaded = try? loadPromptCache(url: cacheURL).0 {
            // Store immutable base into LRU and return a working clone
            putPrefixIntoLRU(modelId: modelId, hash: prefixHash, caches: loaded)
            return cloneCaches(loaded)
        }

        // Build fresh: prefill with prefix tokens only
        var working = context.model.newCache(parameters: genParams)
        var prefillParams = genParams
        prefillParams.maxTokens = 0
        _ = try MLXLMCommon.TokenIterator(
            input: prefixLMInput,
            model: context.model,
            cache: working,
            parameters: prefillParams
        )
        // Persist immutable base and place into LRU. Then return a working clone
        try ensureParentDirectoryExists(for: cacheURL)
        try savePromptCache(url: cacheURL, cache: working, metadata: [
            "modelId": modelId,
            "prefixTokenCount": String(prefixTokenCount)
        ])
        putPrefixIntoLRU(modelId: modelId, hash: prefixHash, caches: working)
        return cloneCaches(working)
    }

    /// Compute a stable SHA-256 hash for a list of token ids
    private static func hashTokenIds(_ tokens: [Int]) -> String {
        var data = Data(capacity: tokens.count * 4)
        for t in tokens { var v = Int32(t); withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Directory to store prompt caches for a given model id (org/repo).
    /// IMPORTANT: Store outside the model weights directory to avoid model loaders picking them up.
    private static func promptCacheDirectory(modelId: String) -> URL {
        let base = DirectoryPickerService.shared.effectiveModelsDirectory
        let cachesRoot = base.appendingPathComponent("_osaurus_prompt_caches", isDirectory: true)
        let parts = modelId.split(separator: "/").map(String.init)
        let dir = parts.reduce(cachesRoot) { partial, comp in
            partial.appendingPathComponent(comp, isDirectory: true)
        }
        return dir
    }

    /// Full URL for a given prefix cache file
    private static func prefixCacheURL(modelId: String, hash: String) -> URL {
        let dir = promptCacheDirectory(modelId: modelId)
        return dir.appendingPathComponent("prefix-\(hash).safetensors", isDirectory: false)
    }

    /// Ensure the parent directory exists for a file URL
    private static func ensureParentDirectoryExists(for url: URL) throws {
        let dir = url.deletingLastPathComponent()
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) || !isDir.boolValue {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
