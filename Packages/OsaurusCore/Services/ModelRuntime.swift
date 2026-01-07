//
//  ModelRuntime.swift
//  osaurus
//
//  Holds MLX runtime state (containers, gates, caches) behind an actor.
//

import CoreImage
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

// Force MLXVLM to be linked by referencing VLMModelFactory
// This ensures VLM models can be loaded via the ModelFactoryRegistry
private let _vlmFactory = MLXVLM.VLMModelFactory.shared

actor ModelRuntime {
    // MARK: - Types

    struct ModelCacheSummary: Sendable {
        let name: String
        let bytes: Int64
        let isCurrent: Bool
    }

    private final class SessionHolder: NSObject, @unchecked Sendable {
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

    private var modelCache: [String: SessionHolder] = [:]
    private var loadingTasks: [String: Task<SessionHolder, Error>] = [:]
    private var currentModelName: String?

    private init() {}

    // MARK: - Public API

    func cachedModelSummaries() -> [ModelCacheSummary] {
        return modelCache.values.map { holder in
            ModelCacheSummary(
                name: holder.name,
                bytes: holder.weightsSizeBytes,
                isCurrent: holder.name == currentModelName
            )
        }.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.name < rhs.name
        }
    }

    func unload(name: String) {
        // Remove from cache within autoreleasepool to encourage immediate ARC deallocation
        autoreleasepool {
            modelCache.removeValue(forKey: name)
        }
        loadingTasks[name]?.cancel()
        loadingTasks.removeValue(forKey: name)
        if currentModelName == name { currentModelName = nil }

        // Synchronize GPU stream to ensure all operations complete, then release Metal buffer pool
        Stream.gpu.synchronize()
        GPU.clearCache()
    }

    func clearAll() {
        // Remove all models within autoreleasepool to encourage immediate ARC deallocation
        autoreleasepool {
            modelCache.removeAll()
        }
        for task in loadingTasks.values { task.cancel() }
        loadingTasks.removeAll()
        currentModelName = nil

        // Synchronize GPU stream to ensure all operations complete, then release Metal buffer pool
        Stream.gpu.synchronize()
        GPU.clearCache()
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
                stopSequences: [],
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
        stopSequences: [String],
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?
    ) async throws -> AsyncStream<String> {
        let params = GenerationParameters(
            temperature: temperature,
            maxTokens: maxTokens,
            topPOverride: nil,
            repetitionPenalty: nil
        )
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let producerTask = Task {
            do {
                let events = try await generateEventStream(
                    chatBuilder: { ModelRuntime.mapMessagesToMLX(messages) },
                    parameters: params,
                    stopSequences: stopSequences,
                    tools: tools,
                    toolChoice: toolChoice,
                    modelId: modelId,
                    modelName: modelName
                )
                for try await ev in events {
                    // Check for task cancellation to allow early termination
                    if Task.isCancelled {
                        break
                    }
                    if case .tokens(let s) = ev, !s.isEmpty {
                        continuation.yield(s)
                    } else {
                        // Ignore tool invocations for plain deltas API; finish early.
                        break
                    }
                }
            } catch {
                // ignore errors; best-effort warm-up / streaming
            }
            continuation.finish()
        }

        // Cancel producer task when consumer stops consuming
        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }

        return stream
    }

    // MARK: - Internals

    private func loadContainer(id: String, name: String) async throws -> SessionHolder {
        // 1. Check cache
        if let existing = modelCache[name] { return existing }

        // Check eviction policy
        let policy = await ServerConfigurationStore.load()?.modelEvictionPolicy ?? .strictSingleModel

        if policy == .strictSingleModel {
            // Enforce single-model policy: Unload all other models to free memory
            let otherModels = modelCache.keys.filter { $0 != name }
            for other in otherModels {
                print("[ModelRuntime] Enforcing strict policy: Unloading \(other)")
                unload(name: other)
            }

            // Also cancel any other pending loading tasks
            let otherTasks = loadingTasks.keys.filter { $0 != name }
            for other in otherTasks {
                print("[ModelRuntime] Cancelling pending load for \(other)")
                loadingTasks[other]?.cancel()
                loadingTasks.removeValue(forKey: other)
            }
        } else {
            // Flexible policy: Only warn if multiple large models are loaded
            // We could implement LRU here in the future if needed
            if !modelCache.isEmpty {
                print("[ModelRuntime] Loading \(name) alongside existing models (Flexible Policy)")
            }
        }

        // 2. Check in-flight loading tasks (deduplication)
        if let existingTask = loadingTasks[name] {
            return try await existingTask.value
        }

        guard let localURL = Self.findLocalDirectory(forModelId: id) else {
            throw NSError(
                domain: "ModelRuntime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model not downloaded: \(name)"]
            )
        }

        // 3. Start new loading task
        let task = Task<SessionHolder, Error> {
            // Check if this is a VLM model and use the appropriate factory
            let isVLM = ModelManager.isVisionModel(at: localURL)
            let container: ModelContainer

            if isVLM {
                // Use VLMModelFactory explicitly for vision models
                let configuration = ModelConfiguration(directory: localURL)
                container = try await VLMModelFactory.shared.loadContainer(configuration: configuration)
            } else {
                // Use default loading for LLM models
                container = try await loadModelContainer(directory: localURL)
            }

            let weightsBytes = Self.computeWeightsSizeBytes(at: localURL)
            return SessionHolder(name: name, container: container, weightsSizeBytes: weightsBytes)
        }

        loadingTasks[name] = task

        do {
            let holder = try await task.value
            modelCache[name] = holder
            loadingTasks[name] = nil
            currentModelName = name
            return holder
        } catch {
            loadingTasks[name] = nil
            throw error
        }
    }

    // MARK: - Driver helpers (actor-isolated)

    // Unified generation: engine setup + stream accumulation to typed events
    private func generateEventStream(
        chatBuilder: @Sendable () -> [MLXLMCommon.Chat.Message],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?,
        modelId: String,
        modelName: String
    ) async throws -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        let cfg = await RuntimeConfig.snapshot()
        let holder = try await loadContainer(id: modelId, name: modelName)
        let events = try await MLXGenerationEngine.prepareAndGenerate(
            container: holder.container,
            buildChat: chatBuilder,
            buildToolsSpec: { ModelRuntime.makeTokenizerTools(tools: tools, toolChoice: toolChoice) },
            generation: parameters,
            runtime: cfg
        )
        return StreamAccumulator.accumulate(events: events, stopSequences: stopSequences, tools: tools)
    }

    // MARK: - New message-based (OpenAI ChatMessage) APIs

    func respondWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        modelId: String,
        modelName: String
    ) async throws -> String {
        var accumulated = ""
        let events = try await generateEventStream(
            chatBuilder: { ModelRuntime.mapOpenAIChatToMLX(messages) },
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            modelId: modelId,
            modelName: modelName
        )
        for try await ev in events {
            switch ev {
            case .tokens(let s):
                accumulated += s
            case .toolInvocation(let name, let argsJSON):
                throw ServiceToolInvocation(toolName: name, jsonArguments: argsJSON)
            }
        }
        return accumulated
    }

    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        modelId: String,
        modelName: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        let events = try await generateEventStream(
            chatBuilder: { ModelRuntime.mapOpenAIChatToMLX(messages) },
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            modelId: modelId,
            modelName: modelName
        )
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let producerTask = Task {
            do {
                for try await ev in events {
                    // Check for task cancellation to allow early termination
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    switch ev {
                    case .tokens(let s):
                        if !s.isEmpty { continuation.yield(s) }
                    case .toolInvocation(let name, let argsJSON):
                        continuation.finish(
                            throwing: ServiceToolInvocation(toolName: name, jsonArguments: argsJSON)
                        )
                        return
                    }
                }
                continuation.finish()
            } catch {
                // Handle cancellation gracefully
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }

        // Cancel producer task when consumer stops consuming
        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }

        return stream
    }

    nonisolated static func makeGenerateParameters(
        temperature: Float,
        maxTokens: Int,
        topP: Float,
        repetitionPenalty: Float?,
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
            repetitionPenalty: repetitionPenalty,
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
                case .tool: return .tool
                }
            }()
            return MLXLMCommon.Chat.Message(role: role, content: m.content, images: [], videos: [])
        }
    }

    nonisolated static func makeTokenizerTools(
        tools: [Tool]?,
        toolChoice: ToolChoiceOption?
    ) -> [[String: any Sendable]]? {
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

    // Map OpenAI ChatMessage history to MLX Chat.Message array, preserving tool results
    // by converting them into user-labeled text so the model can reason over outputs.
    // Also extracts images from multimodal content parts for VLM support.
    nonisolated static func mapOpenAIChatToMLX(
        _ msgs: [ChatMessage]
    ) -> [MLXLMCommon.Chat.Message] {
        var toolIdToName: [String: String] = [:]
        for m in msgs where m.role == "assistant" {
            if let calls = m.tool_calls {
                for call in calls { toolIdToName[call.id] = call.function.name }
            }
        }

        var out: [MLXLMCommon.Chat.Message] = []
        out.reserveCapacity(max(6, msgs.count))
        for m in msgs {
            // Extract images from content parts for VLM support
            let images = extractImageSources(from: m)

            switch m.role {
            case "system":
                out.append(
                    MLXLMCommon.Chat.Message(role: .system, content: m.content ?? "", images: images, videos: [])
                )
            case "user":
                out.append(
                    MLXLMCommon.Chat.Message(role: .user, content: m.content ?? "", images: images, videos: [])
                )
            case "assistant":
                // If assistant only signaled tool calls without textual content, drop it.
                if let calls = m.tool_calls, !calls.isEmpty, m.content == nil || m.content?.isEmpty == true {
                    break
                } else {
                    out.append(
                        MLXLMCommon.Chat.Message(
                            role: .assistant,
                            content: m.content ?? "",
                            images: images,
                            videos: []
                        )
                    )
                }
            case "tool":
                out.append(
                    MLXLMCommon.Chat.Message(role: .tool, content: m.content ?? "", images: images, videos: [])
                )
            default:
                out.append(
                    MLXLMCommon.Chat.Message(role: .user, content: m.content ?? "", images: images, videos: [])
                )
            }
        }
        return out
    }

    /// Extract image sources from ChatMessage content parts for VLM models
    nonisolated private static func extractImageSources(
        from message: ChatMessage
    ) -> [MLXLMCommon.UserInput.Image] {
        // Get image URLs from content parts
        let imageUrls = message.imageUrls
        guard !imageUrls.isEmpty else { return [] }

        var sources: [MLXLMCommon.UserInput.Image] = []
        for urlString in imageUrls {
            // Handle data URLs (base64-encoded images)
            if urlString.hasPrefix("data:image/") {
                // Parse data URL: data:image/png;base64,<base64data>
                if let commaIndex = urlString.firstIndex(of: ",") {
                    let base64String = String(urlString[urlString.index(after: commaIndex)...])
                    if let imageData = Data(base64Encoded: base64String),
                        let ciImage = CIImage(data: imageData)
                    {
                        sources.append(.ciImage(ciImage))
                    }
                }
            } else if let url = URL(string: urlString) {
                // Handle regular URLs
                sources.append(.url(url))
            }
        }
        return sources
    }

    // MARK: - Inline tool-call fallback detection moved to ToolDetection.swift

    private static func computeWeightsSizeBytes(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            )
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

    private static func findLocalDirectory(forModelId id: String) -> URL? {
        let parts = id.split(separator: "/").map(String.init)
        let base = DirectoryPickerService.effectiveModelsDirectory()
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
