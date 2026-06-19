//
//  MLXService.swift
//  osaurus
//
//  Migrated to Swift 6 actors; delegates runtime state to ModelManager/ModelRuntime.
//

import Combine
import Foundation
@preconcurrency import MLXLMCommon

/// Lightweight reference to a local MLX model (name + repo id)
private struct LocalModelRef {
    let name: String
    let modelId: String
}

actor MLXService: ToolCapableService {

    /// Shared instance for convenience (actor is stateless, delegates to ModelRuntime.shared)
    static let shared = MLXService()

    struct RuntimePolicyError: Error, LocalizedError, Sendable {
        let modelName: String
        let issues: [String]

        var errorDescription: String? {
            let detail = issues.joined(separator: "; ")
            return "Request is blocked by local MLX runtime policy for \(modelName): \(detail)"
        }
    }

    nonisolated var id: String { "mlx" }

    // MARK: - Availability / Routing

    nonisolated func isAvailable() -> Bool {
        return !Self.getAvailableModels().isEmpty
    }

    nonisolated func handles(requestedModel: String?) -> Bool {
        let trimmed = (requestedModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return Self.findModel(named: trimmed) != nil
    }

    // MARK: - Static discovery wrappers (delegate to ModelManager)

    nonisolated static func getAvailableModels() -> [String] {
        return ModelManager.installedModelNames()
    }

    fileprivate nonisolated static func findModel(named name: String) -> LocalModelRef? {
        if let found = ModelManager.findInstalledModel(named: name) {
            return LocalModelRef(name: found.name, modelId: found.id)
        }
        return nil
    }

    // MARK: - ModelService

    func streamDeltas(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        let model = try selectModel(requestedName: requestedModel)
        try Self.validateRuntimePolicy(
            modelName: model.name,
            modelId: model.modelId,
            messages: messages,
            parameters: parameters,
            tools: [],
            runtime: ServerRuntimeSettingsStore.snapshot()
        )
        return try await ModelRuntime.shared.streamWithTools(
            messages: messages,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: [],
            toolChoice: nil,
            modelId: model.modelId,
            modelName: model.name
        )
    }

    func generateOneShot(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        requestedModel: String?
    ) async throws -> String {
        let stream = try await streamDeltas(
            messages: messages,
            parameters: parameters,
            requestedModel: requestedModel,
            stopSequences: []
        )
        var out = ""
        for try await s in stream {
            // `streamDeltas` wraps `ModelRuntime.streamWithTools`, which
            // encodes non-token events (reasoning, stats, tool calls) as
            // in-band `\u{FFFE}…` sentinel strings so the SSE/NDJSON writer
            // can peel them off and route to their own response channels.
            // For non-streaming `chat/completions` the caller wants a plain
            // text answer; concatenating sentinels verbatim made them leak
            // into `content` — e.g. a reasoning model's thought content
            // arrived as
            // `"\u{FFFE}reasoning:thought…\u{FFFE}stats:80;8.83"` embedded
            // in the response. Skip every delta that starts with the
            // sentinel marker; `StreamingToolHint.isSentinel` covers
            // tool/args/done, reasoning, stats, and any future sentinel
            // that adheres to the `\u{FFFE}` prefix contract.
            if StreamingToolHint.isSentinel(s) { continue }
            out += s
        }
        return out
    }

    /// Stream a completion from a raw prompt, bypassing the chat template.
    /// Backs the OpenAI-legacy `/v1/completions` endpoint (FIM autocomplete).
    func streamRawCompletion(
        prompt: String,
        parameters: GenerationParameters,
        requestedModel: String?,
        stopSequences: [String]
    ) async throws -> AsyncThrowingStream<String, Error> {
        let model = try selectModel(requestedName: requestedModel)
        try Self.validateRuntimePolicy(
            modelName: model.name,
            modelId: model.modelId,
            messages: [],
            parameters: parameters,
            tools: [],
            runtime: ServerRuntimeSettingsStore.snapshot()
        )
        return try await ModelRuntime.shared.streamRawText(
            prompt: prompt,
            parameters: parameters,
            stopSequences: stopSequences,
            modelId: model.modelId,
            modelName: model.name
        )
    }

    // MARK: - Message-based Tool-capable bridge

    func respondWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> String {
        let model = try selectModel(requestedName: requestedModel)
        try Self.validateRuntimePolicy(
            modelName: model.name,
            modelId: model.modelId,
            messages: messages,
            parameters: parameters,
            tools: tools,
            runtime: ServerRuntimeSettingsStore.snapshot()
        )
        return try await ModelRuntime.shared.respondWithTools(
            messages: messages,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            modelId: model.modelId,
            modelName: model.name
        )
    }

    func streamWithTools(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        stopSequences: [String],
        tools: [Tool],
        toolChoice: ToolChoiceOption?,
        requestedModel: String?
    ) async throws -> AsyncThrowingStream<String, Error> {
        let model = try selectModel(requestedName: requestedModel)
        try Self.validateRuntimePolicy(
            modelName: model.name,
            modelId: model.modelId,
            messages: messages,
            parameters: parameters,
            tools: tools,
            runtime: ServerRuntimeSettingsStore.snapshot()
        )
        return try await ModelRuntime.shared.streamWithTools(
            messages: messages,
            parameters: parameters,
            stopSequences: stopSequences,
            tools: tools,
            toolChoice: toolChoice,
            modelId: model.modelId,
            modelName: model.name
        )
    }

    // MARK: - Runtime cache management

    func cachedRuntimeSummaries() async -> [ModelRuntime.ModelCacheSummary] {
        await ModelRuntime.shared.cachedModelSummaries()
    }

    func unloadRuntimeModel(named name: String) async {
        await ModelRuntime.shared.unload(name: name)
    }

    func clearRuntimeCache() async {
        await ModelRuntime.shared.clearAll()
    }

    // MARK: - Helpers

    private func selectModel(requestedName: String?) throws -> LocalModelRef {
        let trimmed = (requestedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "MLXService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Requested model is required"]
            )
        }
        if let m = Self.findModel(named: trimmed) {
            return m
        }
        throw NSError(
            domain: "MLXService",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Requested model not found: \(trimmed)"]
        )
    }

    static func validateRuntimePolicy(
        modelName: String,
        modelId: String,
        messages: [ChatMessage],
        parameters: GenerationParameters,
        tools: [Tool],
        runtime: VMLXServerRuntimeSettings,
        modelDirectory: URL? = nil
    ) throws {
        let modalities = requestedModalities(
            messages: messages,
            parameters: parameters,
            tools: tools
        )
        let request = ModelRuntimeCapabilityRequest(modalities: modalities)
        let serverResult = runtime.validateRequest(
            request,
            capabilitySnapshot: nil,
            unknownPolicy: .allowUnknown
        )

        var issues = serverResult.issues.map { $0.message }
        let mediaModalities: Set<ModelRuntimeRequestModality> = [.vision, .video, .audio]
        if !modalities.isDisjoint(with: mediaModalities) {
            let mediaDescriptor = mediaCapabilityDescriptor(
                modelId: modelId,
                modelDirectory: modelDirectory
            )
            let media = mediaDescriptor.capabilities
            if modalities.contains(.vision), !media.supportsImage {
                issues.append(mediaDescriptor.descriptor(for: .image).reason)
            }
            if modalities.contains(.video), !media.supportsVideo {
                issues.append(mediaDescriptor.descriptor(for: .video).reason)
            }
            if modalities.contains(.audio), !media.supportsAudio {
                issues.append(mediaDescriptor.descriptor(for: .audio).reason)
            }
        }
        if !tools.isEmpty,
            !supportsLocalToolCalling(
                modelName: modelName,
                modelId: modelId,
                modelDirectory: modelDirectory
            )
        {
            issues.append("Model capability detection reports tool calling as unsupported.")
        }
        if isBlockedProductionModel(modelName: modelName, modelId: modelId) {
            issues.append(
                "ZAYA1-VL JANGTQ_K is a diagnostic artifact with a proven first-token fidelity failure; use zaya1-vl-8b-mxfp4 or zaya1-vl-8b-jangtq4 for production serving."
            )
        }

        if !issues.isEmpty {
            throw RuntimePolicyError(modelName: modelName, issues: issues)
        }
    }

    private nonisolated static func isBlockedProductionModel(
        modelName: String,
        modelId: String
    ) -> Bool {
        let combined = "\(modelName) \(modelId)"
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return combined.contains("zaya1_vl_8b_jangtq_k")
    }

    nonisolated static func supportsLocalToolCalling(
        modelName: String,
        modelId: String,
        modelDirectory: URL? = nil
    ) -> Bool {
        let combined = "\(modelName) \(modelId)"
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        if combined.contains("gemma_3n") || combined.contains("gemma3n") {
            return false
        }

        // VibeThinker-3B is a qwen2 reasoning fine-tune. Its chat_template is the
        // standard Qwen2.5 Hermes tool template, so format detection would mark it
        // tool-capable — but in practice it reasons at length and then wraps the
        // (otherwise-correct) call in a hallucinated `<assemble>` tag instead of
        // `<tool_call>`, so nothing parses. Treat it as text/reasoning-only.
        if combined.contains("vibethinker") {
            return false
        }

        if ModelFamilyNames.isStepFamily(modelName) || ModelFamilyNames.isStepFamily(modelId) {
            // Step 3.7 tool parsing/template selection is owned by the pinned
            // vMLX runtime. Do not block request preflight on large external
            // bundle metadata reads before vMLX can load the model.
            return true
        }
        if isKnownTextOnlyJANGRuntimeFamily(modelId: modelId) {
            // MiMo/N2 JANG and JANGTQ tool parsing/template selection is owned
            // by the pinned vMLX runtime. Keep Osaurus request preflight from
            // synchronously walking large or symlinked model bundles before
            // vMLX can load and validate the actual runtime contract.
            return true
        }
        if ModelFamilyNames.isGemmaFamily(modelName) || ModelFamilyNames.isGemmaFamily(modelId) {
            // Gemma/Gemma4 tool parser/template selection is owned by vMLX.
            // Avoid synchronous external-bundle metadata reads on text/tool
            // preflight; media requests are gated separately above.
            return true
        }

        if let directory = modelDirectory ?? localModelDirectory(modelId: modelId),
            let format = resolvedToolCallFormat(in: directory)
        {
            return format != nil
        }

        // Unknown/local-unscanned bundles remain permissive; vmlx still owns
        // parsing for supported models. Explicitly known unsupported families
        // are blocked above so the API does not leak template/tool markers.
        return true
    }

    private nonisolated static func localModelDirectory(modelId: String) -> URL? {
        let parts = modelId.split(separator: "/").map(String.init)
        let base = DirectoryPickerService.effectiveModelsDirectory()
        let url = parts.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
        let resolved = url.resolvingSymlinksInPath()
        if FileManager.default.fileExists(
            atPath: resolved.appendingPathComponent("config.json").path
        ) {
            return resolved
        }
        // Fall back to externally-discovered bundles (HF cache, LM Studio).
        return ExternalModelLocator.path(forId: modelId)
    }

    private nonisolated static func resolvedToolCallFormat(in directory: URL) -> ToolCallFormat?? {
        if let jangData = try? Data(contentsOf: directory.appendingPathComponent("jang_config.json")),
            let explicit = explicitToolFormat(inJangConfig: jangData)
        {
            return explicit
        }

        guard
            let configData = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
            let modelType = modelType(inConfig: configData)
        else {
            return nil
        }
        // `ToolCallFormat.infer` returns nil to mean "no model-specific format —
        // use the default JSON `<tool_call>{…}</tool_call>` parser" (its
        // documented contract), NOT "tools unsupported". Base Qwen3
        // (`model_type == "qwen3"`) has no dedicated infer case and lands here;
        // folding nil into the default `.json` format keeps the supports-check
        // from misreading a tool-capable default-format model as unsupported.
        // Genuinely tool-less families (e.g. gemma3n) are gated by name in
        // `supportsLocalToolCalling` before this is ever consulted.
        return ToolCallFormat.infer(from: modelType, configData: configData) ?? .json
    }

    private nonisolated static func explicitToolFormat(inJangConfig data: Data) -> ToolCallFormat?? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let candidates: [Any?] = [
            ((root["chat"] as? [String: Any])?["tool_calling"] as? [String: Any])?["parser"],
            ((root["chat"] as? [String: Any])?["tool_calling"] as? [String: Any])?["format"],
            (root["tool_calling"] as? [String: Any])?["parser"],
            (root["tool_calling"] as? [String: Any])?["format"],
        ]
        for candidate in candidates {
            if let raw = candidate as? String {
                return ToolCallFormat.fromCapabilityName(raw)
            }
        }
        return nil
    }

    private nonisolated static func modelType(inConfig data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let text = root["text_config"] as? [String: Any],
            let modelType = text["model_type"] as? String,
            !modelType.isEmpty
        {
            return modelType
        }
        if let modelType = root["model_type"] as? String, !modelType.isEmpty {
            return modelType
        }
        return nil
    }

    private nonisolated static func requestedModalities(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        tools: [Tool]
    ) -> Set<ModelRuntimeRequestModality> {
        var modalities: Set<ModelRuntimeRequestModality> = [.text]
        if messages.contains(where: { !$0.imageUrls.isEmpty }) {
            modalities.insert(.vision)
        }
        if messages.contains(where: { !$0.videoUrls.isEmpty }) {
            modalities.insert(.video)
        }
        if messages.contains(where: { !$0.audioInputs.isEmpty }) {
            modalities.insert(.audio)
        }
        if !tools.isEmpty {
            modalities.insert(.tools)
        }
        if requestUsesReasoning(parameters) {
            modalities.insert(.reasoning)
        }
        return modalities
    }

    private nonisolated static func requestUsesReasoning(
        _ parameters: GenerationParameters
    ) -> Bool {
        if let disableThinking = parameters.modelOptions["disableThinking"]?.boolValue {
            return !disableThinking
        }
        guard let rawEffort = parameters.modelOptions["reasoningEffort"]?.stringValue else {
            return false
        }
        let effort =
            rawEffort
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !effort.isEmpty else { return false }
        switch effort {
        case "none", "off", "disabled", "false", "no_think", "nothink", "instruct", "chat":
            return false
        default:
            return true
        }
    }

    private nonisolated static func mediaCapabilities(
        modelId: String
    ) -> ModelMediaCapabilities.Capabilities {
        mediaCapabilityDescriptor(modelId: modelId).capabilities
    }

    private nonisolated static func mediaCapabilityDescriptor(
        modelId: String,
        modelDirectory: URL? = nil
    ) -> ModelMediaCapabilities.Descriptor {
        if isKnownMediaTextOnlyJANGRuntimeFamily(modelId: modelId) {
            // MiMo JANG/JANGTQ text/tool rows are supported through the vMLX
            // text runtime. The bundle carries visual/audio weights, but vMLX
            // has no MiMo VLM/omni factory yet and the text loader drops those
            // weights. Keep media disabled until that real path exists.
            return ModelMediaCapabilities.Descriptor(
                modelId: modelId,
                capabilities: .textOnly,
                image: .init(
                    modality: .image,
                    status: .unsupported,
                    reason: "Image input is not advertised for this text/tool runtime family."
                ),
                video: .init(
                    modality: .video,
                    status: .unsupported,
                    reason: "Video input is not advertised for this text/tool runtime family."
                ),
                audio: .init(
                    modality: .audio,
                    status: .unsupported,
                    reason: "Audio input is not advertised for this text/tool runtime family."
                )
            )
        }
        if ModelFamilyNames.isStepFamily(modelId) {
            // Step 3.7 currently runs through vMLX's Step text runtime in
            // Osaurus. Some source bundles carry vision metadata, but the
            // Step VLM path is not wired or proven here; keep request gating
            // text-only and avoid blocking runtime preflight on large
            // external-bundle metadata reads.
            return ModelMediaCapabilities.descriptor(modelId: modelId)
        }
        let localDirectory =
            modelDirectory
            ?? modelId.split(separator: "/").map(String.init).reduce(
                DirectoryPickerService.effectiveModelsDirectory()
            ) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
        if FileManager.default.fileExists(atPath: localDirectory.path) {
            return ModelMediaCapabilities.descriptor(directory: localDirectory, modelId: modelId)
        }
        return ModelMediaCapabilities.descriptor(modelId: modelId)
    }

    private nonisolated static func isKnownTextOnlyJANGRuntimeFamily(modelId: String) -> Bool {
        let normalized = modelId.lowercased().replacingOccurrences(of: "_", with: "-")
        guard normalized.contains("jang") else { return false }
        if normalized.contains("-vl") || normalized.contains("omni") {
            return false
        }
        return normalized.contains("mimo-v2.5")
            || normalized.contains("nex-n2-pro")
    }

    private nonisolated static func isKnownMediaTextOnlyJANGRuntimeFamily(modelId: String) -> Bool {
        let normalized = modelId.lowercased().replacingOccurrences(of: "_", with: "-")
        guard normalized.contains("jang") else { return false }
        if normalized.contains("-vl") || normalized.contains("omni") {
            return false
        }
        return normalized.contains("mimo-v2.5")
    }
}
