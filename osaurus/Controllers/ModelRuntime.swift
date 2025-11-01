//
//  ModelRuntime.swift
//  osaurus
//
//  Holds MLX runtime state (containers, gates, caches) behind an actor.
//

import Foundation
import MLXLLM
@preconcurrency import MLXLMCommon

actor ModelRuntime {
  // MARK: - Types

  struct ModelCacheSummary: Sendable {
    let name: String
    let bytes: Int64
    let isCurrent: Bool
  }

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

  // No explicit concurrency gate; underlying MLX containers are used directly.

  // MARK: - Singleton

  static let shared = ModelRuntime()

  // MARK: - State

  private let modelCache = NSCache<NSString, SessionHolder>()
  private var cachedModelNames: Set<String> = []
  private var currentModelName: String?

  private init() {}

  // MARK: - Public API

  func cachedModelSummaries() -> [ModelCacheSummary] {
    var toRemove: [String] = []
    var results: [ModelCacheSummary] = []
    for name in cachedModelNames {
      if let holder = modelCache.object(forKey: name as NSString) {
        results.append(
          ModelCacheSummary(
            name: name, bytes: holder.weightsSizeBytes, isCurrent: name == currentModelName)
        )
      } else {
        toRemove.append(name)
      }
    }
    if !toRemove.isEmpty {
      for n in toRemove { cachedModelNames.remove(n) }
    }
    return results.sorted { lhs, rhs in
      if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
      return lhs.name < rhs.name
    }
  }

  func unload(name: String) {
    modelCache.removeObject(forKey: name as NSString)
    cachedModelNames.remove(name)
    if currentModelName == name { currentModelName = nil }
  }

  func clearAll() {
    modelCache.removeAllObjects()
    cachedModelNames.removeAll()
    currentModelName = nil
  }

  func warmUp(modelId: String, modelName: String, prefillChars: Int = 0, maxTokens: Int = 1) async {
    let warmupContent: String =
      prefillChars > 0
      ? String(repeating: "A", count: max(1, prefillChars))
      : String(repeating: "A", count: 1024)
    let messages = [Message(role: .user, content: warmupContent)]
    do {
      let stream = try await deltasStream(
        messages: messages,
        modelId: modelId,
        modelName: modelName,
        temperature: 0.0,
        maxTokens: maxTokens,
        tools: nil,
        toolChoice: nil
      )
      for await _ in stream { /* no-op */  }
    } catch {
      // Best-effort warm-up; ignore errors
    }
  }

  func deltasStream(
    messages: [Message],
    modelId: String,
    modelName: String,
    temperature: Float,
    maxTokens: Int,
    tools: [Tool]?,
    toolChoice: ToolChoiceOption?
  ) async throws -> AsyncStream<String> {
    let (stream, continuation) = AsyncStream<String>.makeStream()
    Task.detached {
      await ModelRuntime.shared.runDeltas(
        messages: messages,
        modelId: modelId,
        modelName: modelName,
        temperature: temperature,
        maxTokens: maxTokens,
        tools: tools,
        toolChoice: toolChoice,
        continuation: continuation
      )
    }
    return stream
  }

  func respondWithTools(
    prompt: String,
    parameters: GenerationParameters,
    stopSequences: [String],
    tools: [Tool],
    toolChoice: ToolChoiceOption?,
    modelId: String,
    modelName: String
  ) async throws -> String {
    let messages = [Message(role: .user, content: prompt)]
    let cfg = await ServerController.sharedConfiguration()
    let topP: Float = cfg?.genTopP ?? 1.0
    let kvBits: Int? = cfg?.genKVBits
    let kvGroup: Int = cfg?.genKVGroupSize ?? 64
    let quantStart: Int = cfg?.genQuantizedKVStart ?? 0
    let maxKV: Int? = cfg?.genMaxKVSize
    let prefillStep: Int = cfg?.genPrefillStepSize ?? 512
    let holder = try await loadContainer(id: modelId, name: modelName)

    var accumulated = ""
    try await withTaskCancellationHandler(
      operation: {
        do {
          let stream: AsyncStream<MLXLMCommon.Generation> = try await holder.container.perform {
            (context: MLXLMCommon.ModelContext) in
            let chat = ModelRuntime.mapMessagesToMLX(messages)
            let params = ModelRuntime.makeGenerateParameters(
              temperature: parameters.temperature,
              maxTokens: parameters.maxTokens,
              topP: topP,
              kvBits: kvBits,
              kvGroup: kvGroup,
              quantStart: quantStart,
              maxKV: maxKV,
              prefillStep: prefillStep
            )
            let tt = ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: toolChoice)
            let fullInput = MLXLMCommon.UserInput(chat: chat, processing: .init(), tools: tt)
            let fullLMInput = try await context.processor.prepare(input: fullInput)

            var contextWithEOS = context
            let existing = context.configuration.extraEOSTokens
            let extra: Set<String> = Set(["</end_of_turn>", "<end_of_turn>", "<|end|>", "<eot>"])
            contextWithEOS.configuration.extraEOSTokens = existing.union(extra)

            return try MLXLMCommon.generate(
              input: fullLMInput,
              cache: nil,
              parameters: params,
              context: contextWithEOS
            )
          }
          for await event in stream {
            if let toolCall = event.toolCall {
              let argsData = try? JSONSerialization.data(
                withJSONObject: toolCall.function.arguments.mapValues { $0.anyValue })
              let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
              throw ServiceToolInvocation(
                toolName: toolCall.function.name, jsonArguments: argsString)
            }
            if let token = event.chunk, !token.isEmpty {
              accumulated += token
              if !stopSequences.isEmpty,
                let stopIndex = stopSequences.compactMap({ s in accumulated.range(of: s)?.lowerBound
                  }).first
              {
                accumulated = String(accumulated[..<stopIndex])
                break
              }
            }
          }
        } catch {
          throw error
        }
      },
      onCancel: {
        // no-op
      })
    return accumulated
  }

  func streamWithTools(
    prompt: String,
    parameters: GenerationParameters,
    stopSequences: [String],
    tools: [Tool],
    toolChoice: ToolChoiceOption?,
    modelId: String,
    modelName: String
  ) async throws -> AsyncThrowingStream<String, Error> {
    let messages = [Message(role: .user, content: prompt)]
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    Task.detached {
      await ModelRuntime.shared.runStreamWithTools(
        messages: messages,
        parameters: parameters,
        stopSequences: stopSequences,
        tools: tools,
        toolChoice: toolChoice,
        modelId: modelId,
        modelName: modelName,
        continuation: continuation
      )
    }
    return stream
  }

  // MARK: - Internals

  // No gate needed.

  // removed prepareInputs; parameters and chat are built inside perform closures to avoid
  // capturing non-Sendable MLX types across tasks.

  private func loadContainer(id: String, name: String) async throws -> SessionHolder {
    if let existing = modelCache.object(forKey: name as NSString) { return existing }
    guard let localURL = findLocalDirectory(forModelId: id) else {
      throw NSError(
        domain: "ModelRuntime", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Model not downloaded: \(name)"])
    }
    let container = try await loadModelContainer(directory: localURL)
    let weightsBytes = computeWeightsSizeBytes(at: localURL)
    let holder = SessionHolder(name: name, container: container, weightsSizeBytes: weightsBytes)
    modelCache.setObject(holder, forKey: name as NSString)
    cachedModelNames.insert(name)
    currentModelName = name
    return holder
  }

  // MARK: - Driver helpers (actor-isolated)

  private func runDeltas(
    messages: [Message],
    modelId: String,
    modelName: String,
    temperature: Float,
    maxTokens: Int,
    tools: [Tool]?,
    toolChoice: ToolChoiceOption?,
    continuation: AsyncStream<String>.Continuation
  ) async {
    let cfg = await ServerController.sharedConfiguration()
    let topP: Float = cfg?.genTopP ?? 1.0
    let kvBits: Int? = cfg?.genKVBits
    let kvGroup: Int = cfg?.genKVGroupSize ?? 64
    let quantStart: Int = cfg?.genQuantizedKVStart ?? 0
    let maxKV: Int? = cfg?.genMaxKVSize
    let prefillStep: Int = cfg?.genPrefillStepSize ?? 512
    do {
      let holder = try await loadContainer(id: modelId, name: modelName)
      let stream: AsyncStream<MLXLMCommon.Generation> = try await holder.container.perform {
        (context: MLXLMCommon.ModelContext) in
        let chat = ModelRuntime.mapMessagesToMLX(messages)
        let params = ModelRuntime.makeGenerateParameters(
          temperature: temperature,
          maxTokens: maxTokens,
          topP: topP,
          kvBits: kvBits,
          kvGroup: kvGroup,
          quantStart: quantStart,
          maxKV: maxKV,
          prefillStep: prefillStep
        )
        let tt = ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: toolChoice)
        let fullInput = MLXLMCommon.UserInput(chat: chat, processing: .init(), tools: tt)
        let fullLMInput = try await context.processor.prepare(input: fullInput)

        var contextWithEOS = context
        let existing = context.configuration.extraEOSTokens
        let extra: Set<String> = Set(["</end_of_turn>", "<end_of_turn>", "<|end|>", "<eot>"])
        contextWithEOS.configuration.extraEOSTokens = existing.union(extra)

        return try MLXLMCommon.generate(
          input: fullLMInput,
          cache: nil,
          parameters: params,
          context: contextWithEOS
        )
      }
      for await event in stream {
        if let chunk = event.chunk, !chunk.isEmpty { continuation.yield(chunk) }
      }
    } catch {
      // ignore, best-effort
    }
    continuation.finish()
  }

  private func runStreamWithTools(
    messages: [Message],
    parameters: GenerationParameters,
    stopSequences: [String],
    tools: [Tool],
    toolChoice: ToolChoiceOption?,
    modelId: String,
    modelName: String,
    continuation: AsyncThrowingStream<String, Error>.Continuation
  ) async {
    let cfg = await ServerController.sharedConfiguration()
    let topP: Float = cfg?.genTopP ?? 1.0
    let kvBits: Int? = cfg?.genKVBits
    let kvGroup: Int = cfg?.genKVGroupSize ?? 64
    let quantStart: Int = cfg?.genQuantizedKVStart ?? 0
    let maxKV: Int? = cfg?.genMaxKVSize
    let prefillStep: Int = cfg?.genPrefillStepSize ?? 512
    var accumulated = ""
    var alreadyEmitted = 0
    let shouldCheckStop = !stopSequences.isEmpty
    do {
      let holder = try await loadContainer(id: modelId, name: modelName)
      let events: AsyncStream<MLXLMCommon.Generation> = try await holder.container.perform {
        (context: MLXLMCommon.ModelContext) in
        let chat = ModelRuntime.mapMessagesToMLX(messages)
        let params = ModelRuntime.makeGenerateParameters(
          temperature: parameters.temperature,
          maxTokens: parameters.maxTokens,
          topP: topP,
          kvBits: kvBits,
          kvGroup: kvGroup,
          quantStart: quantStart,
          maxKV: maxKV,
          prefillStep: prefillStep
        )
        let tt = ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: toolChoice)
        let fullInput = MLXLMCommon.UserInput(chat: chat, processing: .init(), tools: tt)
        let fullLMInput = try await context.processor.prepare(input: fullInput)

        var contextWithEOS = context
        let existing = context.configuration.extraEOSTokens
        let extra: Set<String> = Set(["</end_of_turn>", "<end_of_turn>", "<|end|>", "<eot>"])
        contextWithEOS.configuration.extraEOSTokens = existing.union(extra)

        return try MLXLMCommon.generate(
          input: fullLMInput,
          cache: nil,
          parameters: params,
          context: contextWithEOS
        )
      }
      for await event in events {
        if let toolCall = event.toolCall {
          let argsData = try? JSONSerialization.data(
            withJSONObject: toolCall.function.arguments.mapValues { $0.anyValue })
          let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
          continuation.finish(
            throwing: ServiceToolInvocation(
              toolName: toolCall.function.name, jsonArguments: argsString)
          )
          return
        }
        guard let token = event.chunk, !token.isEmpty else { continue }
        accumulated += token
        let newSlice = String(accumulated.dropFirst(alreadyEmitted))
        if shouldCheckStop {
          if let stopIndex = stopSequences.compactMap({ s in accumulated.range(of: s)?.lowerBound })
            .first
          {
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
    } catch {
      continuation.finish(throwing: error)
    }
  }

  nonisolated static func makeGenerateParameters(
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

  nonisolated static func mapMessagesToMLX(_ messages: [Message]) -> [MLXLMCommon.Chat.Message] {
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

  nonisolated static func makeTokenizerTools(
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

  private func computeWeightsSizeBytes(at url: URL) -> Int64 {
    let fm = FileManager.default
    guard
      let enumerator = fm.enumerator(
        at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
    else { return 0 }
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

  private func findLocalDirectory(forModelId id: String) -> URL? {
    let parts = id.split(separator: "/").map(String.init)
    let base = DirectoryPickerService.defaultModelsDirectory()
    let url = parts.reduce(base) { partial, component in
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
}
