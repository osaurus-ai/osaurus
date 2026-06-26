//
//  ImageSubagentKind.swift
//  OsaurusCore — Subagent framework
//
//  The native-image sub-agent kind that serves the single `image` tool:
//  generate when `source_paths` is empty, edit when it is set. Resolves the
//  configured local image model (separate gen vs edit defaults), runs the job
//  through `NativeImageJobCoordinator`, bridges the job's live progress onto the
//  shared `SubagentFeed`, and hands back the same compact image payload the
//  inline-render bridge already reads.
//
//  `needsHandoff = false`: unlike spawn, the image residency handoff is NOT run
//  by the host middleware. The coordinator must unload the chat model INSIDE its
//  own detached producer task — a chat-turn cancel (which the unload itself can
//  trigger) must not cascade into the engine drain and lose the image. Moving
//  the unload into the host's chat-turn-task `around` would reintroduce that
//  cancel cascade, so the coordinator stays the residency authority for images
//  and the host only owns the guard, feed, result, and telemetry.
//

import Combine
import Foundation

/// Parsed, validated `image` tool arguments. `sourcePaths` non-empty selects
/// edit mode (`source_paths` → edit); empty selects generation.
struct ImageJobParams: Sendable {
    var prompt: String
    var sourcePaths: [String]
    var model: String?
    var negativePrompt: String?
    var width: Int?
    var height: Int?
    var steps: Int?
    var guidance: Float?
    var strength: Float?
    var seed: UInt64?
    var numImages: Int?

    /// `source_paths` present → edit an existing image; otherwise generate.
    var isEdit: Bool { !sourcePaths.isEmpty }
}

final class ImageSubagentKind: SubagentKind, @unchecked Sendable {
    let capability = AgentCapability(id: "image", toolNames: ["image"], guidance: nil)
    let needsHandoff = false

    private let params: ImageJobParams
    private let argumentsJSON: String

    init(params: ImageJobParams, argumentsJSON: String) {
        self.params = params
        self.argumentsJSON = argumentsJSON
    }

    var feedTitle: String {
        let trimmed = params.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = params.isEdit ? "image edit" : "image"
        let body = trimmed.count > 72 ? String(trimmed.prefix(72)) + "…" : trimmed
        return body.isEmpty ? prefix : "\(prefix): \(body)"
    }

    // MARK: - Model resolution (reject-before-evict)

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let config = SubagentConfigurationStore.snapshot()
        guard config.imageDelegationActive else {
            throw SubagentError.denied(
                params.isEdit
                    ? "Image edit is disabled in Agent Delegation settings."
                    : "Image generation is disabled in Agent Delegation settings."
            )
        }
        let modelKind: SubagentModelKind = params.isEdit ? .imageEdit : .imageGeneration
        let configured =
            params.isEdit ? config.defaultImageEditModelId : config.defaultImageGenerationModelId
        do {
            let models = try await ImageGenerationService.shared.availableModels()
            let model = try NativeImageJobModelResolver.resolve(
                requested: params.model,
                configured: configured,
                available: models,
                kind: modelKind
            )
            return ResolvedModel(name: model, id: model, isLocal: true)
        } catch {
            throw SubagentError.unavailable(String(describing: error))
        }
    }

    // MARK: - Permission

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        let config = SubagentConfigurationStore.snapshot()
        let approvalJSON = SubagentApprovalArguments.enrichedJSON(
            from: argumentsJSON,
            values: [
                "resolved_model": resolved.name,
                "image_job_load_policy": config.imageJobLoadPolicy.rawValue,
            ]
        )
        return params.isEdit
            ? await editPermission(config: config, argumentsJSON: approvalJSON)
            : await generatePermission(config: config, argumentsJSON: approvalJSON)
    }

    private func generatePermission(
        config: SubagentConfiguration,
        argumentsJSON: String
    ) async -> SubagentDecision {
        switch config.permissionDefaults.image {
        case .deny:
            return .denied("Image generation is denied by Agent Delegation settings.")
        case .alwaysAllow:
            return .allow
        case .ask:
            if ChatExecutionContext.autoApproveToolPrompts { return .allow }
            // First use (no default image model chosen yet): show the spawn-model
            // picker inside the permission prompt so the user picks the image
            // model once and the choice persists.
            if config.defaultImageGenerationModelId == nil {
                let options = await Self.imageGenModelChoices()
                let outcome = await ToolPermissionPromptService.requestSpawnApproval(
                    toolName: "image",
                    description: ImageTool.toolDescription,
                    argumentsJSON: argumentsJSON,
                    modelPickerTitle: "Image model",
                    modelOptions: options,
                    currentModel: nil
                )
                switch outcome {
                case .denied:
                    return .userDenied("User denied image generation.")
                case .allowed(let model, let always):
                    Self.persistImagePreferences(model: model, always: always)
                    return .allow
                }
            }
            let approved = await ToolPermissionPromptService.requestApproval(
                toolName: "image",
                description: ImageTool.toolDescription,
                argumentsJSON: argumentsJSON
            )
            return approved ? .allow : .userDenied("User denied image generation.")
        }
    }

    private func editPermission(
        config: SubagentConfiguration,
        argumentsJSON: String
    ) async -> SubagentDecision {
        switch config.permissionDefaults.image {
        case .deny:
            return .denied("Image edit is denied by Agent Delegation settings.")
        case .alwaysAllow:
            return .allow
        case .ask:
            if ChatExecutionContext.autoApproveToolPrompts { return .allow }
            let approved = await ToolPermissionPromptService.requestApproval(
                toolName: "image",
                description: ImageTool.toolDescription,
                argumentsJSON: argumentsJSON
            )
            return approved ? .allow : .userDenied("User denied image edit.")
        }
    }

    // MARK: - Run

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        // Bridge the coordinator's live job progress (posted on the main thread
        // via NotificationCenter) onto the shared feed so the chat row shows a
        // live image-progress pane — previously unwired for the agent path. The
        // bridge is read-only: if it misses events the job result is unaffected.
        let toolCallId = scope.toolCallId
        let bridge =
            NotificationCenter.default
            .publisher(for: NativeImageJobProgressCenter.notificationName)
            .compactMap { $0.object as? NativeImageJobProgress }
            .filter { $0.toolCallID == toolCallId }
            .sink { [weak feed] progress in
                Self.emit(progress, to: feed)
            }
        defer { bridge.cancel() }

        feed.emitPhase(params.isEdit ? "editing" : "generating", detail: resolved.name)

        let finalResult: NativeImageJobResult?
        do {
            if params.isEdit {
                let sources = try Self.loadSourceImages(paths: params.sourcePaths)
                let request = NativeImageEditJobRequest(
                    prompt: params.prompt,
                    model: resolved.name,
                    sourceImages: sources,
                    negativePrompt: params.negativePrompt,
                    width: params.width,
                    height: params.height,
                    steps: params.steps,
                    guidance: params.guidance,
                    strength: params.strength ?? 0.75,
                    seed: params.seed,
                    outputFormat: .png,
                    context: NativeImageJobContext.current()
                )
                finalResult = try await Self.consumeEdit(request)
            } else {
                let request = NativeImageGenerateJobRequest(
                    prompt: params.prompt,
                    model: resolved.name,
                    negativePrompt: params.negativePrompt,
                    width: params.width,
                    height: params.height,
                    steps: params.steps,
                    guidance: params.guidance,
                    seed: params.seed,
                    // Force single-image: multi-image (n>1) sequential generation
                    // trips the MLX CommandEncoder race (no per-image drain).
                    numImages: 1,
                    outputFormat: .png,
                    context: NativeImageJobContext.current()
                )
                finalResult = try await Self.consumeGenerate(request)
            }
        } catch let inputError as NativeImageToolInputError {
            throw SubagentError.invalidArgs(
                message: String(describing: inputError),
                field: "source_paths",
                expected: "existing local image files under 80 MB each"
            )
        } catch {
            throw SubagentError.executionFailed(
                message: String(describing: error),
                retryable: false
            )
        }

        guard let finalResult else {
            throw SubagentError.executionFailed(
                message: params.isEdit
                    ? "image edit finished without a result"
                    : "image generation finished without a result",
                retryable: false
            )
        }

        let count = finalResult.images.count
        let verb = params.isEdit ? "Edited" : "Generated"
        let summary = "\(verb) \(count) image\(count == 1 ? "" : "s") with \(resolved.name)."
        return SubagentResult(payload: finalResult.toolPayload, summary: summary)
    }

    // MARK: - Stream consumption (detached)

    /// Consume an image job stream on a DETACHED task. A chat-turn cancel (which
    /// the residency unload can incidentally trigger) must not cascade into the
    /// engine drain and abort generation; the detached consumer keeps the
    /// producer alive to completion. Explicit user cancel still works via the
    /// coordinator / `ImageGenerationService` jobID cancel path.
    private static func consumeGenerate(
        _ request: NativeImageGenerateJobRequest
    ) async throws -> NativeImageJobResult? {
        try await Task.detached(priority: .userInitiated) {
            let stream = await NativeImageJobCoordinator.shared.generate(request)
            var last: NativeImageJobResult?
            for try await result in stream { last = result }
            return last
        }.value
    }

    private static func consumeEdit(
        _ request: NativeImageEditJobRequest
    ) async throws -> NativeImageJobResult? {
        try await Task.detached(priority: .userInitiated) {
            let stream = await NativeImageJobCoordinator.shared.edit(request)
            var last: NativeImageJobResult?
            for try await result in stream { last = result }
            return last
        }.value
    }

    // MARK: - Progress → feed mapping

    private static func emit(_ progress: NativeImageJobProgress, to feed: SubagentFeed?) {
        guard let feed else { return }
        switch progress.phase {
        case .queued:
            feed.emitPhase("queued")
        case .waitingForChatIdle:
            feed.emitPhase("waiting for chat idle")
        case .unloadingChatModels:
            feed.emitPhase("unloading chat models", detail: progress.message)
        case .loadingModel:
            feed.emitPhase("loading model", detail: progress.model)
        case .generating:
            let fraction: Double?
            if let step = progress.step, let total = progress.total, total > 0 {
                fraction = Double(step) / Double(total)
            } else {
                fraction = nil
            }
            feed.emitProgress("generating", fraction: fraction, step: progress.step ?? 0)
        case .unloading:
            feed.emitPhase("unloading image model")
        case .restoringChatModels:
            feed.emitPhase("restoring chat models", detail: progress.message)
        case .completed:
            // The host finishes the feed with the run's terminal status.
            break
        case .failed:
            feed.emit(
                SubagentActivityEvent(
                    kind: .error,
                    title: "failed",
                    detail: progress.message,
                    success: false
                )
            )
        case .cancelled:
            feed.emitPhase("cancelled")
        }
    }

    // MARK: - First-use model picker

    /// Ready text→image bundles, as first-use permission-prompt choices.
    private static func imageGenModelChoices() async -> [SpawnModelChoice] {
        let models = (try? await ImageGenerationService.shared.availableModels()) ?? []
        return
            models
            .filter { $0.ready && $0.kind == "imageGen" }
            .map { SpawnModelChoice(id: $0.id, label: $0.displayName) }
    }

    /// Persist the first-use spawn-model + permission choice so Settings → Spawn
    /// reflects it and subsequent jobs use it.
    private static func persistImagePreferences(model: String?, always: Bool) {
        var cfg = SubagentConfigurationStore.snapshot()
        if let model, !model.isEmpty { cfg.defaultImageGenerationModelId = model }
        if always { cfg.permissionDefaults.image = .alwaysAllow }
        SubagentConfigurationStore.save(cfg)
    }

    // MARK: - Source image loading (edit)

    static func loadSourceImages(paths: [String]) throws -> [Data] {
        let trimmed = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty, trimmed.count <= 4 else {
            throw NativeImageToolInputError.invalidSourceCount
        }
        return try trimmed.map { path in
            let url = URL.osaurusImageFileURL(path)
            let ext = url.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "webp", "heic"].contains(ext) else {
                throw NativeImageToolInputError.unsupportedExtension(path)
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw NativeImageToolInputError.notAFile(path)
            }
            if let size = values.fileSize, size > 80 * 1024 * 1024 {
                throw NativeImageToolInputError.fileTooLarge(path)
            }
            return try Data(contentsOf: url)
        }
    }
}

enum NativeImageToolInputError: Error, CustomStringConvertible {
    case invalidSourceCount
    case unsupportedExtension(String)
    case notAFile(String)
    case fileTooLarge(String)

    var description: String {
        switch self {
        case .invalidSourceCount:
            return "source_paths must contain one to four image paths"
        case .unsupportedExtension(let path):
            return "unsupported source image extension: \(path)"
        case .notAFile(let path):
            return "source image path is not a regular file: \(path)"
        case .fileTooLarge(let path):
            return "source image exceeds 80 MB limit: \(path)"
        }
    }
}

extension URL {
    fileprivate static func osaurusImageFileURL(_ path: String) -> URL {
        if let url = URL(string: path), url.isFileURL {
            return url
        }
        return URL(fileURLWithPath: path)
    }
}
