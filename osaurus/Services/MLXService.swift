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
class MLXService {
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

    /// LRU cache for reusable ChatSession keyed by (modelName, sessionId)
    private struct SessionKey: Hashable { let model: String; let session: String }
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
        return Int(env["OSU_SESSION_CACHE_MAX"] ?? "") ?? 8
    }()
    private let reusableTTLSeconds: TimeInterval = {
        let env = ProcessInfo.processInfo.environment
        return TimeInterval(Int(env["OSU_SESSION_CACHE_TTL"] ?? "") ?? 120)
    }()
    
    /// Currently loaded model name
    private(set) var currentModelName: String?
    
    /// Tracks the current model download progress.
    /// Access this property to monitor model download status.
    private(set) var modelDownloadProgress: Progress?
    
    // Adjustable generation settings (can be tuned via UI)
    private(set) var generationSettings: GenerationSettings = {
        let env = ProcessInfo.processInfo.environment
        let topP: Float = Float(env["OSU_TOP_P"] ?? "") ?? 1.0
        let kvBits: Int? = Int(env["OSU_KV_BITS"] ?? "")
        let kvGroup: Int = Int(env["OSU_KV_GROUP"] ?? "") ?? 64
        let quantStart: Int = Int(env["OSU_QUANT_KV_START"] ?? "") ?? 0
        let maxKV: Int? = Int(env["OSU_MAX_KV_SIZE"] ?? "")
        let prefillStep: Int = Int(env["OSU_PREFILL_STEP"] ?? "") ?? 1024
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
            // Fallback to curated common default if present
            if let m = Self.findModel(named: "llama-3.2-3b-instruct-4bit") { return m }
            // As last resort, take first available discovered on disk
            if let first = Self.getAvailableModels().first, let m = Self.findModel(named: first) { return m }
            return nil
        }()
        guard let model = chosen else { return }

        let warmupContent: String = prefillChars > 0 ? String(repeating: "A", count: max(1, prefillChars)) : String(repeating: "A", count: 1024)
        let messages = [Message(role: .user, content: warmupContent)]        
        do {
            let stream = try await generate(messages: messages, model: model, temperature: 0.0, maxTokens: maxTokens)
            // Consume the small warm-up stream
            for await _ in stream { /* no-op */ }
        } catch {
            // Non-fatal: warm-up is best effort
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
        let root = ModelManager.modelsDirectory
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
        let url: URL = parts.reduce(ModelManager.modelsDirectory) { partial, component in
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

    /// Best-effort discovery of default stop sequences based on tokenizer configs
    nonisolated static func defaultStopSequences(for model: LMModel) -> [String] {
        guard let dir = findLocalDirectory(forModelId: model.modelId) else { return [] }
        let fm = FileManager.default
        // Prefer special_tokens_map.json then tokenizer_config.json
        let candidates = [
            dir.appendingPathComponent("special_tokens_map.json"),
            dir.appendingPathComponent("tokenizer_config.json")
        ]
        for url in candidates {
            if fm.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // eos_token may be a string or an object with 'content'/'text'
                if let eos = obj["eos_token"] {
                    if let s = eos as? String, !s.isEmpty { return [s] }
                    if let d = eos as? [String: Any] {
                        if let s = d["content"] as? String, !s.isEmpty { return [s] }
                        if let s = d["text"] as? String, !s.isEmpty { return [s] }
                    }
                }
                // Some configs include additional special tokens that can act as stops
                if let add = obj["additional_special_tokens"] as? [String], !add.isEmpty {
                    return add
                }
            }
        }
        return []
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
        gate.wait()

        // Extract a combined system prompt (if any) to pass as ChatSession instructions
        let systemText: String = {
            var acc = ""
            for m in messages {
                if m.role == .system {
                    if !acc.isEmpty { acc += "\n" }
                    acc += m.content
                }
            }
            return acc
        }()
        // Build a prompt from chat messages and optional tool specs
        // Exclude the system section if we are passing instructions to ChatSession
        let prompt = buildPrompt(from: messages, tools: tools, toolChoice: toolChoice, excludeSystem: !systemText.isEmpty)

        // Build MLX generation parameters (temperature, sampling, KV cache, etc.)
        // Prefer UI configuration when available
        let cfg = await ServerController.sharedConfiguration()
        let topP: Float = cfg?.genTopP ?? 1.0
        let kvBits: Int? = cfg?.genKVBits
        let kvGroup: Int = cfg?.genKVGroupSize ?? 64
        let quantStart: Int = cfg?.genQuantizedKVStart ?? 0
        let maxKV: Int? = cfg?.genMaxKVSize
        let prefillStep: Int = cfg?.genPrefillStepSize ?? 512

        var genParams = MLXLMCommon.GenerateParameters(
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
        genParams.prefillStepSize = prefillStep

        // Optionally reuse a ChatSession (KV cache) for the same sessionId
        let (session, cacheKey, reusedFromCache): (ChatSession, SessionKey?, Bool) = {
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
                while reusableOrder.count > reusableMaxCount {
                    let lru = reusableOrder.removeFirst()
                    reusableSessions.removeValue(forKey: lru)
                    activeReuseKeys.remove(lru)
                }
                return (newSession, nil, false)
            }
        }()
        // If this is a freshly created session without reuse, ensure instructions are set
        // (For reused sessions, we keep prior instructions to avoid races.)
        let sessionStream = session.streamResponse(to: prompt)
        
        // Return a stream that forwards tokens; MLX enforces maxTokens internally
        return AsyncStream<String> { continuation in
            Task {
                defer { gate.signal() }
                do {
                    for try await token in sessionStream {
                        continuation.yield(token)
                    }
                } catch {
                    // On error, finish the stream; upstream will send error JSON
                }
                // Release active flag for reused sessions
                if reusedFromCache, let key = cacheKey {
                    sessionCacheQueue.async(flags: .barrier) {
                        self.activeReuseKeys.remove(key)
                        // refresh lastUsed
                        if let entry = self.reusableSessions[key] {
                            self.reusableSessions[key] = (entry.session, Date())
                        }
                    }
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
                    reusableSessions.removeValue(forKey: key)
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

// MARK: - Prompt Formatting

/// Cache for encoded tool specifications to avoid repeated JSON encoding
private let toolsJSONCache = NSCache<NSNumber, NSString>()

func buildPrompt(from messages: [Message], tools: [Tool]?, toolChoice: ToolChoiceOption?, excludeSystem: Bool = false) -> String {
    var systemPrompt = ""
    var conversation = ""
    for message in messages {
        switch message.role {
        case .system:
            if !excludeSystem {
                if !systemPrompt.isEmpty { systemPrompt += "\n" }
                systemPrompt += message.content
            }
        case .user:
            conversation += "User: \(message.content)\n"
        case .assistant:
            conversation += "Assistant: \(message.content)\n"
        }
    }
    // Tool specifications block
    var toolsBlock = ""
    if let tools, !tools.isEmpty {
        // Create a cache key from tool names
        let toolNames = tools.map { $0.function.name }.sorted().joined(separator: ",")
        let cacheKey = NSNumber(value: toolNames.hashValue)
        
        let json: String
        if let cached = toolsJSONCache.object(forKey: cacheKey) {
            json = cached as String
        } else {
            var encoder = IkigaJSONEncoder()
            var buffer = ByteBufferAllocator().buffer(capacity: 1024)
            if let _ = try? encoder.encodeAndWrite(tools, into: &buffer), let encoded = buffer.readString(length: buffer.readableBytes) {
                json = encoded
                toolsJSONCache.setObject(encoded as NSString, forKey: cacheKey)
            } else {
                json = "[]"
            }
        }
        
        if !json.isEmpty {
            // Compact tool-call guidance to reduce prefill tokens.
            // Expect OpenAI-style tool_calls. If invoking a tool, reply with only:
            // {"tool_calls":[{"id":"call_auto","type":"function","function":{"name":"<name>","arguments":"<json-string>"}}]}
            toolsBlock += "\n\nTools:\n"
            toolsBlock += json
            if let toolChoice {
                let encoder = IkigaJSONEncoder()
                var buffer = ByteBufferAllocator().buffer(capacity: 128)
                if let _ = try? encoder.encodeAndWrite(toolChoice, into: &buffer), let jsonChoice = buffer.readString(length: buffer.readableBytes) {
                    toolsBlock += "\ntool_choice: \(jsonChoice)"
                }
            }
        }
    }
    let fullPrompt: String
    if systemPrompt.isEmpty {
        fullPrompt = conversation + toolsBlock
    } else {
        fullPrompt = "\(systemPrompt)\n\n\(conversation)Assistant:\(toolsBlock)"
    }
    return fullPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
}
