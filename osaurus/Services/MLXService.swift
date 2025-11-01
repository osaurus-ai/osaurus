//
//  MLXService.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation
import MLXLLM
@preconcurrency import MLXLMCommon

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

/// Lightweight reference to a local MLX model (name + repo id)
private struct LocalModelRef {
  let name: String
  let modelId: String
}

/// A service class that manages machine learning models for text generation tasks.
/// This class handles model loading, caching, and text generation using various LLM models.
@Observable
final class MLXService: @unchecked Sendable {
  static let shared = MLXService()

  /// Thread-safe cache of available model names
  nonisolated(unsafe) private static let availableModelsCache = NSCache<NSString, NSArray>()

  /// Cache for model lookups to avoid repeated disk scanning
  nonisolated(unsafe) private static let modelLookupCache = NSCache<NSString, LocalModelRefBox>()

  // NSCache requires @objc reference types; wrap LocalModelRef
  private final class LocalModelRefBox: NSObject {
    let value: LocalModelRef
    init(_ value: LocalModelRef) { self.value = value }
  }

  /// Concurrent queue for thread-safe model lookup operations
  private static let modelLookupQueue = DispatchQueue(
    label: "com.osaurus.model.lookup", attributes: .concurrent)

  /// Timestamp for cached models list
  nonisolated(unsafe) private static var modelsListCacheTimestamp: Date?

  /// Cache to store loaded model containers to avoid reloading weights from disk.
  private final class SessionHolder: NSObject {
    let name: String
    let container: ModelContainer
    let weightsSizeBytes: Int64
    init(name: String, container: ModelContainer, weightsSizeBytes: Int64) {
      self.name = name
      self.container = container
      self.weightsSizeBytes = weightsSizeBytes
    }
  }

  private let modelCache = NSCache<NSString, SessionHolder>()

  private let sessionCacheQueue = DispatchQueue(
    label: "com.osaurus.sessioncache", attributes: .concurrent)

  // Track cached model names explicitly since NSCache doesn't expose keys
  private var cachedModelNames: Set<String> = []

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

  // MARK: - Small helpers
  private func makeGenerateParameters(
    temperature: Float,
    maxTokens: Int,
    topP: Float,
    kvBits: Int?,
    kvGroup: Int,
    quantStart: Int,
    maxKV: Int?,
    prefillStep: Int
  ) -> MLXLMCommon.GenerateParameters {
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
  }

  // MARK: - Model Cache Introspection (for UI)
  struct ModelCacheSummary: Sendable {
    let name: String
    let bytes: Int64
    let isCurrent: Bool
  }

  /// Returns a snapshot of currently cached models with approximate memory usage.
  /// This also prunes any names whose entries have been evicted by NSCache.
  func cachedModelSummaries() -> [ModelCacheSummary] {
    return sessionCacheQueue.sync(flags: .barrier) {
      var toRemove: [String] = []
      var results: [ModelCacheSummary] = []
      for name in cachedModelNames {
        if let holder = modelCache.object(forKey: name as NSString) {
          let summary = ModelCacheSummary(
            name: name,
            bytes: holder.weightsSizeBytes,
            isCurrent: (name == currentModelName)
          )
          results.append(summary)
        } else {
          toRemove.append(name)
        }
      }
      if !toRemove.isEmpty {
        for n in toRemove { cachedModelNames.remove(n) }
      }
      // Sort: current model first, then by name
      return results.sorted { lhs, rhs in
        if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
        return lhs.name < rhs.name
      }
    }
  }

  // MARK: - Weights size (disk) estimation
  private func computeWeightsSizeBytes(at url: URL) -> Int64 {
    let fm = FileManager.default
    guard
      let enumerator = fm.enumerator(
        at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
    else {
      return 0
    }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      if fileURL.pathExtension.lowercased() == "safetensors" {
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
          let size = attrs[.size] as? NSNumber
        {
          total += size.int64Value
        }
      }
    }
    return total
  }

  private func mapMessagesToMLX(_ messages: [Message]) -> [MLXLMCommon.Chat.Message] {
    return messages.map { m in
      let role: MLXLMCommon.Chat.Message.Role = {
        switch m.role {
        case .system: return .system
        case .user: return .user
        case .assistant: return .assistant
        }
      }()
      return MLXLMCommon.Chat.Message(role: role, content: m.content, images: [], videos: [])
    }
  }

  private func makeTokenizerTools(
    tools: [Tool]?,
    toolChoice: ToolChoiceOption?
  ) -> [[String: Any]]? {
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
  }

  /// Warm up a model by loading it and generating a tiny response to compile kernels and populate caches.
  /// - Parameters:
  ///   - modelName: Optional model name to warm up. If nil, attempts a best-effort default.
  ///   - prefillChars: If > 0, use a long user message with this many characters to exercise prefill compilation.
  ///   - maxTokens: Number of tokens to emit during warm-up (default 1)
  func warmUp(modelName: String? = nil, prefillChars: Int = 0, maxTokens: Int = 1) async {
    // Choose a model: explicit name -> find; otherwise pick first available
    let chosen: LocalModelRef? = {
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
  fileprivate nonisolated static func findModel(named name: String) -> LocalModelRef? {
    // Check cache first for fast lookups
    if let cached = modelLookupCache.object(forKey: name as NSString)?.value {
      return cached
    }

    // Use concurrent queue for thread-safe disk scanning
    return modelLookupQueue.sync(flags: .barrier) {
      // Double-check cache after acquiring barrier (in case another thread just populated it)
      if let cached = modelLookupCache.object(forKey: name as NSString)?.value {
        return cached
      }

      // Only scan disk if not in cache
      let pairs = Self.scanDiskForModels()

      // Try exact repo-name match first (lowercased)
      if let match = pairs.first(where: { $0.name == name }) {
        let model = LocalModelRef(name: match.name, modelId: match.id)
        modelLookupCache.setObject(LocalModelRefBox(model), forKey: name as NSString)
        return model
      }

      // Try matching against full id's repo component (case-insensitive)
      if let match = pairs.first(where: { pair in
        let repo = pair.id.split(separator: "/").last.map(String.init)?.lowercased()
        return repo == name.lowercased()
      }) {
        let model = LocalModelRef(name: match.name, modelId: match.id)
        modelLookupCache.setObject(LocalModelRefBox(model), forKey: name as NSString)
        return model
      }

      // Try full id match (case-insensitive)
      if let match = pairs.first(where: { $0.id.lowercased() == name.lowercased() }) {
        let model = LocalModelRef(name: match.name, modelId: match.id)
        modelLookupCache.setObject(LocalModelRefBox(model), forKey: name as NSString)
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
    let root = DirectoryPickerService.defaultModelsDirectory()
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
    let url: URL = parts.reduce(DirectoryPickerService.defaultModelsDirectory()) {
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
  private func load(model: LocalModelRef) async throws -> SessionHolder {
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

    // Load the model container and compute weights disk size
    let container = try await loadModelContainer(directory: localURL)
    let weightsBytes = computeWeightsSizeBytes(at: localURL)
    let holder = SessionHolder(
      name: model.name, container: container, weightsSizeBytes: weightsBytes)

    // Cache for future requests
    modelCache.setObject(holder, forKey: model.name as NSString)
    sessionCacheQueue.async(flags: .barrier) { [weak self] in
      self?.cachedModelNames.insert(model.name)
    }
    currentModelName = model.name
    updateAvailableModelsCache()

    return holder
  }

  /// Generate event stream from MLX that can include both text chunks and tool call events.
  fileprivate func generateEvents(
    messages: [Message],
    model: LocalModelRef,
    temperature: Float = 0.7,
    maxTokens: Int = 2048,
    tools: [Tool]? = nil,
    toolChoice: ToolChoiceOption? = nil,
    sessionId: String? = nil
  ) async throws -> AsyncStream<MLXLMCommon.Generation> {
    let holder = try await load(model: model)
    let holderBox = UncheckedSendableBox(value: holder)

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

    let genParams: MLXLMCommon.GenerateParameters = makeGenerateParameters(
      temperature: temperature,
      maxTokens: maxTokens,
      topP: topP,
      kvBits: kvBits,
      kvGroup: kvGroup,
      quantStart: quantStart,
      maxKV: maxKV,
      prefillStep: prefillStep
    )

    // Map internal messages to MLX Chat.Message
    let chat: [MLXLMCommon.Chat.Message] = mapMessagesToMLX(messages)
    let chatBox = UncheckedSendableBox(value: chat)

    // Convert OpenAI-style tools to Tokenizers.ToolSpec and honor tool_choice
    let tokenizerTools: [[String: Any]]? = makeTokenizerTools(tools: tools, toolChoice: toolChoice)
    let tokenizerToolsBox = UncheckedSendableBox(value: tokenizerTools)

    // Build and return a wrapper stream that forwards MLX events and releases the gate on completion
    return AsyncStream<MLXLMCommon.Generation> { continuation in
      let gateBox = UncheckedSendableBox(value: gate)
      Task {
        gateBox.value.wait()
        defer { gateBox.value.signal() }
        do {
          let stream: AsyncStream<MLXLMCommon.Generation> = try await holderBox.value.container
            .perform {
              (context: MLXLMCommon.ModelContext) in
              // Prepare full chat input (for tokenization and to get delta tokens later)
              let fullInput = MLXLMCommon.UserInput(
                chat: chatBox.value, processing: .init(), tools: tokenizerToolsBox.value)
              let fullLMInput = try await context.processor.prepare(input: fullInput)

              // Ensure common EOS tokens are recognized to avoid infinite generation loops
              var contextWithEOS = context
              // Merge existing extra EOS tokens with common variants
              let existing = context.configuration.extraEOSTokens
              let extra: Set<String> = Set([
                "</end_of_turn>",  // some models emit this HTML-style tag
                "<end_of_turn>",
                "<|end|>",
                "<eot>",
              ])
              contextWithEOS.configuration.extraEOSTokens = existing.union(extra)

              return try MLXLMCommon.generate(
                input: fullLMInput,
                cache: nil,
                parameters: genParams,
                context: contextWithEOS
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
    sessionCacheQueue.async(flags: .barrier) { [weak self] in
      self?.cachedModelNames.remove(name)
    }
    if currentModelName == name {
      currentModelName = nil
    }

    // Update available models cache
    updateAvailableModelsCache()
  }

  /// Clear all cached models
  func clearCache() {
    modelCache.removeAllObjects()
    sessionCacheQueue.async(flags: .barrier) { [weak self] in
      self?.cachedModelNames.removeAll()
    }
    currentModelName = nil

    // Update available models cache
    updateAvailableModelsCache()
  }
}

// MARK: - ToolCapableService Conformance

extension MLXService: ToolCapableService {
  var id: String { "mlx" }

  func isAvailable() -> Bool {
    return !Self.getAvailableModels().isEmpty
  }

  func handles(requestedModel: String?) -> Bool {
    let trimmed = (requestedModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return Self.findModel(named: trimmed) != nil
  }

  func streamDeltas(
    prompt: String,
    parameters: GenerationParameters,
    requestedModel: String?
  ) async throws -> AsyncStream<String> {
    let model = try selectModel(requestedName: requestedModel)
    let messages = [Message(role: .user, content: prompt)]
    let eventStream = try await generateEvents(
      messages: messages,
      model: model,
      temperature: parameters.temperature,
      maxTokens: parameters.maxTokens,
      tools: nil,
      toolChoice: nil,
      sessionId: nil
    )

    return AsyncStream<String> { continuation in
      Task {
        for await event in eventStream {
          if let chunk = event.chunk, !chunk.isEmpty {
            continuation.yield(chunk)
          }
        }
        continuation.finish()
      }
    }
  }

  func generateOneShot(
    prompt: String,
    parameters: GenerationParameters,
    requestedModel: String?
  ) async throws -> String {
    let model = try selectModel(requestedName: requestedModel)
    let messages = [Message(role: .user, content: prompt)]
    let eventStream = try await generateEvents(
      messages: messages,
      model: model,
      temperature: parameters.temperature,
      maxTokens: parameters.maxTokens,
      tools: nil,
      toolChoice: nil,
      sessionId: nil
    )

    var segments: [String] = []
    segments.reserveCapacity(512)
    for await event in eventStream {
      if let chunk = event.chunk, !chunk.isEmpty { segments.append(chunk) }
    }
    return segments.joined()
  }

  // MARK: - Tool-capable bridge

  func respondWithTools(
    prompt: String,
    parameters: GenerationParameters,
    stopSequences: [String],
    tools: [Tool],
    toolChoice: ToolChoiceOption?,
    requestedModel: String?
  ) async throws -> String {
    let model = try selectModel(requestedName: requestedModel)
    let messages = [Message(role: .user, content: prompt)]
    let eventStream = try await generateEvents(
      messages: messages,
      model: model,
      temperature: parameters.temperature,
      maxTokens: parameters.maxTokens,
      tools: tools,
      toolChoice: toolChoice,
      sessionId: nil
    )

    var accumulated = ""
    for await event in eventStream {
      if let toolCall = event.toolCall {
        // Serialize arguments as JSON string
        let argsData = try? JSONSerialization.data(
          withJSONObject: toolCall.function.arguments.mapValues { $0.anyValue })
        let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        throw ServiceToolInvocation(toolName: toolCall.function.name, jsonArguments: argsString)
      }
      if let token = event.chunk, !token.isEmpty {
        accumulated += token
        if !stopSequences.isEmpty,
          let stopIndex = stopSequences.compactMap({ s in accumulated.range(of: s)?.lowerBound })
            .first
        {
          accumulated = String(accumulated[..<stopIndex])
          break
        }
      }
    }
    return accumulated
  }

  func streamWithTools(
    prompt: String,
    parameters: GenerationParameters,
    stopSequences: [String],
    tools: [Tool],
    toolChoice: ToolChoiceOption?,
    requestedModel: String?
  ) async throws -> AsyncThrowingStream<String, Error> {
    let model = try selectModel(requestedName: requestedModel)
    let messages = [Message(role: .user, content: prompt)]
    let eventStream = try await generateEvents(
      messages: messages,
      model: model,
      temperature: parameters.temperature,
      maxTokens: parameters.maxTokens,
      tools: tools,
      toolChoice: toolChoice,
      sessionId: nil
    )

    return AsyncThrowingStream<String, Error> { continuation in
      Task {
        var accumulated = ""
        var alreadyEmitted = 0
        let shouldCheckStop = !stopSequences.isEmpty
        do {
          for await event in eventStream {
            if let toolCall = event.toolCall {
              let argsData = try? JSONSerialization.data(
                withJSONObject: toolCall.function.arguments.mapValues { $0.anyValue })
              let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
              continuation.finish(
                throwing: ServiceToolInvocation(
                  toolName: toolCall.function.name, jsonArguments: argsString))
              return
            }
            guard let token = event.chunk, !token.isEmpty else { continue }
            accumulated += token

            // Emit only the new slice
            let newSlice = String(accumulated.dropFirst(alreadyEmitted))
            if shouldCheckStop {
              if let stopIndex = stopSequences.compactMap({ s in
                accumulated.range(of: s)?.lowerBound
              }).first {
                let finalRange =
                  accumulated.index(accumulated.startIndex, offsetBy: alreadyEmitted)..<stopIndex
                let finalContent = String(accumulated[finalRange])
                if !finalContent.isEmpty { continuation.yield(finalContent) }
                continuation.finish()
                return
              }
            }
            if !newSlice.isEmpty {
              continuation.yield(newSlice)
              alreadyEmitted += newSlice.count
            }
          }
          continuation.finish()
        }
      }
    }
  }

  // MARK: - Private helpers

  private func selectModel(requestedName: String?) throws -> LocalModelRef {
    let trimmed = (requestedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NSError(
        domain: "MLXService", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Requested model is required"])
    }
    if let m = Self.findModel(named: trimmed) { return m }
    throw NSError(
      domain: "MLXService", code: 4,
      userInfo: [NSLocalizedDescriptionKey: "Requested model not found: \(trimmed)"])
  }
}
