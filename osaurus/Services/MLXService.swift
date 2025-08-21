//
//  MLXService.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation
import MLXLMCommon
import MLXLLM

/// Represents a language model configuration
struct LMModel {
    let name: String
    let modelId: String  // The model ID from ModelManager (e.g., "mlx-community/Llama-3.2-3B-Instruct-4bit")
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
@MainActor
class MLXService {
    static let shared = MLXService()
    
    /// Thread-safe cache of available model names
    nonisolated(unsafe) private static let availableModelsCache = NSCache<NSString, NSArray>()
    
    /// List of available models that can be used for generation.
    /// Dynamically generated from downloaded models
    var availableModels: [LMModel] {
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
    
    /// Cache to store loaded chat sessions to avoid reloading.
    private final class SessionHolder: NSObject {
        let container: ModelContainer
        let session: ChatSession
        init(container: ModelContainer, session: ChatSession) {
            self.container = container
            self.session = session
        }
    }
    private let modelCache = NSCache<NSString, SessionHolder>()
    
    /// Currently loaded model name
    private(set) var currentModelName: String?
    
    /// Tracks the current model download progress.
    /// Access this property to monitor model download status.
    private(set) var modelDownloadProgress: Progress?
    
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
        // Always rescan disk to ensure fresh and reliable results
        let pairs = Self.scanDiskForModels()
        let modelNames = pairs.map { $0.name }
        // Keep cache in sync for other callers
        Self.availableModelsCache.setObject(modelNames as NSArray, forKey: "models" as NSString)
        let modelInfo = pairs.map { ["name": $0.name, "id": $0.id] }
        Self.availableModelsCache.setObject(modelInfo as NSArray, forKey: "modelInfo" as NSString)
        return modelNames
    }
    
    /// Find a model by name
    nonisolated static func findModel(named name: String) -> LMModel? {
        // Prefer scanning disk to reflect newly downloaded models immediately
        let pairs = Self.scanDiskForModels()
        // Try exact repo-name match first (lowercased)
        if let match = pairs.first(where: { $0.name == name }) {
            return LMModel(name: match.name, modelId: match.id)
        }
        // Try matching against full id's repo component (case-insensitive)
        if let match = pairs.first(where: { pair in
            let repo = pair.id.split(separator: "/").last.map(String.init)?.lowercased()
            return repo == name.lowercased()
        }) {
            return LMModel(name: match.name, modelId: match.id)
        }
        // Try full id match (case-insensitive)
        if let match = pairs.first(where: { $0.id.lowercased() == name.lowercased() }) {
            return LMModel(name: match.name, modelId: match.id)
        }
        // Update cache for consistency even if not found
        let modelNames = pairs.map { $0.name }
        Self.availableModelsCache.setObject(modelNames as NSArray, forKey: "models" as NSString)
        let modelInfo = pairs.map { ["name": $0.name, "id": $0.id] }
        Self.availableModelsCache.setObject(modelInfo as NSArray, forKey: "modelInfo" as NSString)
        return nil
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
    
    /// Loads a model container from local storage or retrieves it from cache.
    private func load(model: LMModel) async throws -> SessionHolder {
        if let holder = modelCache.object(forKey: model.name as NSString) {
            return holder
        }

        // Prefer ModelManager knowledge when available; otherwise derive the directory from the id
        let localURL: URL = {
            if let downloadedModel = ModelManager.shared.availableModels.first(where: { $0.id == model.modelId && $0.isDownloaded }) {
                return downloadedModel.localDirectory
            }
            if let url = Self.findLocalDirectory(forModelId: model.modelId) {
                return url
            }
            return ModelManager.modelsDirectory // placeholder; will fail validation below
        }()
        
        // Validate the directory has required files
        let fm = FileManager.default
        let hasConfig = fm.fileExists(atPath: localURL.appendingPathComponent("config.json").path)
        let hasWeights: Bool = (try? fm.contentsOfDirectory(at: localURL, includingPropertiesForKeys: nil))?.contains(where: { $0.pathExtension == "safetensors" }) ?? false
        guard hasConfig && hasWeights else {
            throw NSError(domain: "MLXService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Model not downloaded: \(model.name)"
            ])
        }

        let container = try await loadModelContainer(directory: localURL)
        let session = ChatSession(container)
        let holder = SessionHolder(container: container, session: session)
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
        maxTokens: Int = 2048
    ) async throws -> AsyncStream<String> {
        // Load or retrieve chat session from cache
        let holder = try await load(model: model)

        // Build a simple prompt from chat messages
        let prompt = buildPrompt(from: messages)

        // Run generation using MLXLMCommon's ChatSession
        return AsyncStream<String> { continuation in
            Task {
                // Stream if possible for responsiveness; if not, fall back to single response
                let stream = holder.session.streamResponse(to: prompt)
                do {
                    for try await token in stream {
                        continuation.yield(token)
                    }
                } catch {
                    // On error, finish the stream; upstream will send error JSON
                }
                continuation.finish()
            }
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
private func buildPrompt(from messages: [Message]) -> String {
    var systemPrompt = ""
    var conversation = ""
    for message in messages {
        switch message.role {
        case .system:
            if !systemPrompt.isEmpty { systemPrompt += "\n" }
            systemPrompt += message.content
        case .user:
            conversation += "User: \(message.content)\n"
        case .assistant:
            conversation += "Assistant: \(message.content)\n"
        }
    }
    let fullPrompt: String
    if systemPrompt.isEmpty {
        fullPrompt = conversation
    } else {
        fullPrompt = "\(systemPrompt)\n\n\(conversation)Assistant:"
    }
    return fullPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
}
