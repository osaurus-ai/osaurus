//
//  MLXService.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import CryptoKit
import Foundation
import MLXLLM
import MLXLMCommon
import NIOCore

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
  private static let modelLookupQueue = DispatchQueue(
    label: "com.osaurus.model.lookup", attributes: .concurrent)

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

  private let sessionCacheQueue = DispatchQueue(
    label: "com.osaurus.sessioncache", attributes: .concurrent)

  /// Per-model concurrency gates to protect underlying MLX containers
  private final class ConcurrencyGate {
    private let semaphore: DispatchSemaphore
    init(limit: Int) { self.semaphore = DispatchSemaphore(value: max(1, limit)) }
    func wait() { semaphore.wait() }
    func signal() { semaphore.signal() }
  }
  private var modelGates: [String: ConcurrencyGate] = [:]

  /// Currently loaded model name
  private(set) var currentModelName: String?

  /// Tracks the current model download progress.
  /// Access this property to monitor model download status.
  private(set) var modelDownloadProgress: Progress?

  // Adjustable generation settings (can be tuned via UI)
  private(set) var generationSettings: GenerationSettings = {
    let env = ProcessInfo.processInfo.environment
    let topP: Float = Float(env["OSU_TOP_P"] ?? "") ?? 1.0
    let kvBits: Int? = Int(env["OSU_KV_BITS"] ?? "")  // nil by default
    let kvGroup: Int = Int(env["OSU_KV_GROUP"] ?? "") ?? 64
    let quantStart: Int = Int(env["OSU_QUANT_KV_START"] ?? "") ?? 0
    let maxKV: Int? = Int(env["OSU_MAX_KV_SIZE"] ?? "")
    let prefillStep: Int = Int(env["OSU_PREFILL_STEP"] ?? "") ?? 512
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
      if let first = Self.getAvailableModels().first, let m = Self.findModel(named: first) {
        return m
      }
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
          print(
            "[Osaurus] Warm-up skipped: unable to select a model (\(available.count) available)")
          DebugLog.log(
            "WARMUP", "Unable to select a warm-up model from available list: \(available)")
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

    DebugLog.log(
      "WARMUP",
      "Starting warm-up for model=\(model.name), prefillChars=\(prefillChars), maxTokens=\(maxTokens)"
    )

    let warmupContent: String =
      prefillChars > 0
      ? String(repeating: "A", count: max(1, prefillChars)) : String(repeating: "A", count: 1024)
    let messages = [Message(role: .user, content: warmupContent)]
    do {
      let stream = try await generateEvents(
        messages: messages, model: model, temperature: 0.0, maxTokens: maxTokens)
      // Consume the small warm-up stream
      for await _ in stream { /* no-op */  }
    } catch {
      // Non-fatal: warm-up is best effort, but log for visibility
      print("[Osaurus] Warm-up failed for model \(model.name): \(error)")
      DebugLog.log(
        "WARMUP", "Warm-up failed for model=\(model.name): \(error.localizedDescription)")
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
    Self.modelsListCacheTimestamp = Date()
  }

  /// Get list of available models that are downloaded (thread-safe)
  nonisolated static func getAvailableModels() -> [String] {
    return modelLookupQueue.sync(flags: .barrier) {
      if let cached = availableModelsCache.object(forKey: "models" as NSString) as? [String],
        let timestamp = modelsListCacheTimestamp,
        Date().timeIntervalSince(timestamp) < 5.0
      {
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
    guard
      let topLevel = try? fm.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else {
      return []
    }
    var results: [(String, String)] = []

    func validateAndAppend(org: String, repo: String, repoURL: URL) {
      // Core config
      func exists(_ name: String) -> Bool {
        fm.fileExists(atPath: repoURL.appendingPathComponent(name).path)
      }
      guard exists("config.json") else { return }

      // Tokenizer variants (match MLXModel.isDownloaded)
      let hasTokenizerJSON = exists("tokenizer.json")
      let hasBPE = exists("merges.txt") && (exists("vocab.json") || exists("vocab.txt"))
      let hasSentencePiece = exists("tokenizer.model") || exists("spiece.model")
      let hasTokenizerAssets = hasTokenizerJSON || hasBPE || hasSentencePiece
      guard hasTokenizerAssets else { return }

      // At least one weights file
      guard let items = try? fm.contentsOfDirectory(at: repoURL, includingPropertiesForKeys: nil),
        items.contains(where: { $0.pathExtension == "safetensors" })
      else { return }

      let id = "\(org)/\(repo)"
      let name = repo.lowercased()
      results.append((name, id))
    }

    // Nested org/repo directories
    for orgURL in topLevel {
      var isOrgDir: ObjCBool = false
      guard fm.fileExists(atPath: orgURL.path, isDirectory: &isOrgDir), isOrgDir.boolValue else {
        continue
      }
      guard
        let repos = try? fm.contentsOfDirectory(
          at: orgURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
      else { continue }
      for repoURL in repos {
        var isRepoDir: ObjCBool = false
        guard fm.fileExists(atPath: repoURL.path, isDirectory: &isRepoDir), isRepoDir.boolValue
        else { continue }
        validateAndAppend(
          org: orgURL.lastPathComponent, repo: repoURL.lastPathComponent, repoURL: repoURL)
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
    let url: URL = parts.reduce(DirectoryPickerService.shared.effectiveModelsDirectory) {
      partial, component in
      partial.appendingPathComponent(component, isDirectory: true)
    }
    let fm = FileManager.default
    let hasConfig = fm.fileExists(atPath: url.appendingPathComponent("config.json").path)
    if let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
      hasConfig && items.contains(where: { $0.pathExtension == "safetensors" })
    {
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
      throw NSError(
        domain: "MLXService", code: 1,
        userInfo: [
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
    let topP: Float = cfg?.genTopP ?? 1.0
    let kvBits: Int? = cfg?.genKVBits
    let kvGroup: Int = cfg?.genKVGroupSize ?? 64
    let quantStart: Int = cfg?.genQuantizedKVStart ?? 0
    let maxKV: Int? = cfg?.genMaxKVSize
    let prefillStep: Int = cfg?.genPrefillStepSize ?? 512

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
          let stream: AsyncStream<MLXLMCommon.Generation> = try await holder.container.perform {
            (context: MLXLMCommon.ModelContext) in
            // Prepare full chat input (for tokenization and to get delta tokens later)
            let fullInput = MLXLMCommon.UserInput(
              chat: chat, processing: .init(), tools: tokenizerTools)
            let fullLMInput = try await context.processor.prepare(input: fullInput)

            return try MLXLMCommon.generate(
              input: fullLMInput,
              cache: nil,
              parameters: genParams,
              context: context
            )
          }
          for await event in stream {
            continuation.yield(event)
          }
        } catch {
          DebugLog.log(
            "GEN", "Event generation error for model=\(model.name): \(error.localizedDescription)")
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

// MARK: - Hugging Face lightweight metadata fetcher
actor HuggingFaceService {
  static let shared = HuggingFaceService()

  struct RepoFile: Decodable {
    let rfilename: String
    let size: Int64?
  }

  // Minimal model metadata from HF
  struct ModelMeta: Decodable {
    let id: String
    let tags: [String]?
    let siblings: [RepoFile]?
  }

  private init() {}

  /// Estimate the total size for files matching provided patterns.
  /// Uses Hugging Face REST API endpoints that return directory listings with sizes.
  func estimateTotalSize(repoId: String, patterns: [String]) async -> Int64? {
    // Use tree endpoint: /api/models/{repo}/tree/main?recursive=1
    var comps = URLComponents()
    comps.scheme = "https"
    comps.host = "huggingface.co"
    comps.path = "/api/models/\(repoId)/tree/main"
    comps.queryItems = [URLQueryItem(name: "recursive", value: "1")]
    guard let url = comps.url else { return nil }

    struct TreeNode: Decodable {
      let path: String
      let type: String?
      let size: Int64?
      let lfs: LFS?
      struct LFS: Decodable { let size: Int64? }
    }

    var req = URLRequest(url: url)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      let (data, response) = try await URLSession.shared.data(for: req)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        return nil
      }
      let nodes = try JSONDecoder().decode([TreeNode].self, from: data)
      if nodes.isEmpty { return nil }
      let matchers = patterns.compactMap { Glob($0) }
      let total = nodes.reduce(Int64(0)) { acc, node in
        // Only sum files, not directories
        if node.type == "directory" { return acc }
        let filename = (node.path as NSString).lastPathComponent
        let matched = matchers.contains { $0.matches(filename) }
        guard matched else { return acc }
        let sz = node.size ?? node.lfs?.size ?? 0
        return acc + sz
      }
      return total > 0 ? total : nil
    } catch {
      return nil
    }
  }

  /// Determine if a Hugging Face repo is MLX-compatible using repository metadata.
  /// Prefers explicit tags (e.g., "mlx", "apple-mlx", "library:mlx").
  /// Falls back to id hints and required file presence when tags are unavailable.
  func isMLXCompatible(repoId: String) async -> Bool {
    let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let lower = trimmed.lowercased()

    // Fetch model metadata with tags and top-level file listing
    guard let meta = await fetchModelMeta(repoId: trimmed) else {
      // Network failure: conservative allowance for mlx-community repos
      if lower.hasPrefix("mlx-community/") { return true }
      return false
    }

    // Strong signal: tags explicitly indicate MLX
    if let tags = meta.tags?.map({ $0.lowercased() }) {
      if tags.contains("mlx") || tags.contains("apple-mlx") || tags.contains("library:mlx") {
        return true
      }
    }

    // Heuristic fallback: repository naming suggests MLX and core files exist
    if lower.contains("mlx") && hasRequiredFiles(meta: meta) {
      return true
    }

    // As a last resort, trust curated org with required files
    if lower.hasPrefix("mlx-community/") && hasRequiredFiles(meta: meta) {
      return true
    }

    return false
  }

  // MARK: - Private helpers
  private func fetchModelMeta(repoId: String) async -> ModelMeta? {
    var comps = URLComponents()
    comps.scheme = "https"
    comps.host = "huggingface.co"
    comps.path = "/api/models/\(repoId)"
    comps.queryItems = [URLQueryItem(name: "full", value: "1")]
    guard let url = comps.url else { return nil }

    var req = URLRequest(url: url)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      let (data, response) = try await URLSession.shared.data(for: req)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        return nil
      }
      return try JSONDecoder().decode(ModelMeta.self, from: data)
    } catch {
      return nil
    }
  }

  private func hasRequiredFiles(meta: ModelMeta) -> Bool {
    guard let siblings = meta.siblings else { return false }
    var hasConfig = false
    var hasWeights = false
    var hasTokenizer = false
    for s in siblings {
      let f = s.rfilename.lowercased()
      if f == "config.json" { hasConfig = true }
      if f.hasSuffix(".safetensors") { hasWeights = true }
      if f == "tokenizer.json" || f == "tokenizer.model" || f == "spiece.model" || f == "vocab.json"
        || f == "vocab.txt"
      {
        hasTokenizer = true
      }
    }
    return hasConfig && hasWeights && hasTokenizer
  }
}

// MARK: - Simple glob matcher
private struct Glob {
  private let regex: NSRegularExpression

  init?(_ pattern: String) {
    // Escape regex metacharacters except * and ? which we will translate
    var escaped = ""
    for ch in pattern {
      switch ch {
      case "*": escaped += ".*"
      case "?": escaped += "."
      case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\":
        escaped += "\\\(ch)"
      default:
        escaped += String(ch)
      }
    }
    do {
      regex = try NSRegularExpression(pattern: "^\(escaped)$")
    } catch {
      return nil
    }
  }

  func matches(_ text: String) -> Bool {
    let range = NSRange(location: 0, length: (text as NSString).length)
    return regex.firstMatch(in: text, options: [], range: range) != nil
  }
}
