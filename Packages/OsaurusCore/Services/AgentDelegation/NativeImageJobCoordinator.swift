//
//  NativeImageJobCoordinator.swift
//  osaurus
//
//  Agent-side orchestration for local native image jobs. The chat model sees a
//  compact tool surface; this coordinator owns default model resolution,
//  progress lifecycle, and safe image-model unload after agent-launched jobs.
//

import Foundation

struct NativeImageJobContext: Sendable, Equatable {
    var sessionID: String?
    var assistantTurnID: UUID?
    var toolCallID: String?

    static let empty = NativeImageJobContext()

    static func current() -> NativeImageJobContext {
        NativeImageJobContext(
            sessionID: ChatExecutionContext.currentSessionId,
            assistantTurnID: ChatExecutionContext.currentAssistantTurnId,
            toolCallID: ChatExecutionContext.currentToolCallId
        )
    }
}

struct NativeImageGenerateJobRequest: Sendable {
    var prompt: String
    var model: String?
    var negativePrompt: String?
    var width: Int?
    var height: Int?
    var steps: Int?
    var guidance: Float?
    var seed: UInt64?
    var numImages: Int
    var outputFormat: ImageOutputFormat
    var context: NativeImageJobContext

    init(
        prompt: String,
        model: String? = nil,
        negativePrompt: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        steps: Int? = nil,
        guidance: Float? = nil,
        seed: UInt64? = nil,
        numImages: Int = 1,
        outputFormat: ImageOutputFormat = .png,
        context: NativeImageJobContext = .empty
    ) {
        self.prompt = prompt
        self.model = model
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.guidance = guidance
        self.seed = seed
        self.numImages = max(1, min(4, numImages))
        self.outputFormat = outputFormat
        self.context = context
    }
}

struct NativeImageEditJobRequest: Sendable {
    var prompt: String
    var model: String?
    var sourceImages: [Data]
    var negativePrompt: String?
    var width: Int?
    var height: Int?
    var steps: Int?
    var guidance: Float?
    var strength: Float
    var seed: UInt64?
    var outputFormat: ImageOutputFormat
    var context: NativeImageJobContext

    init(
        prompt: String,
        model: String? = nil,
        sourceImages: [Data],
        negativePrompt: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        steps: Int? = nil,
        guidance: Float? = nil,
        strength: Float = 0.75,
        seed: UInt64? = nil,
        outputFormat: ImageOutputFormat = .png,
        context: NativeImageJobContext = .empty
    ) {
        self.prompt = prompt
        self.model = model
        self.sourceImages = Array(sourceImages.prefix(4))
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.guidance = guidance
        self.strength = min(1, max(0, strength))
        self.seed = seed
        self.outputFormat = outputFormat
        self.context = context
    }
}

enum NativeImageJobPhase: String, Sendable {
    case queued
    case waitingForChatIdle = "waiting_for_chat_idle"
    case unloadingChatModels = "unloading_chat_models"
    case loadingModel = "loading_model"
    case generating
    case unloading
    case restoringChatModels = "restoring_chat_models"
    case completed
    case failed
    case cancelled
}

struct NativeImageJobProgress: Sendable, Equatable {
    var jobID: String
    var phase: NativeImageJobPhase
    var model: String?
    var step: Int?
    var total: Int?
    var etaSeconds: Double?
    var message: String?
    var sessionID: String?
    var assistantTurnID: UUID?
    var toolCallID: String?

    init(
        jobID: String,
        phase: NativeImageJobPhase,
        model: String? = nil,
        step: Int? = nil,
        total: Int? = nil,
        etaSeconds: Double? = nil,
        message: String? = nil,
        context: NativeImageJobContext = .empty
    ) {
        self.jobID = jobID
        self.phase = phase
        self.model = model
        self.step = step
        self.total = total
        self.etaSeconds = etaSeconds
        self.message = message
        self.sessionID = context.sessionID
        self.assistantTurnID = context.assistantTurnID
        self.toolCallID = context.toolCallID
    }

    var dictionary: [String: Any] {
        var payload: [String: Any] = [
            "job_id": jobID,
            "phase": phase.rawValue,
        ]
        if let model { payload["model"] = model }
        if let step { payload["step"] = step }
        if let total { payload["total"] = total }
        if let etaSeconds { payload["eta_seconds"] = etaSeconds }
        if let message { payload["message"] = message }
        if let sessionID { payload["session_id"] = sessionID }
        if let assistantTurnID { payload["assistant_turn_id"] = assistantTurnID.uuidString }
        if let toolCallID { payload["tool_call_id"] = toolCallID }
        return payload
    }
}

struct NativeImageJobResult: Sendable, Equatable {
    var jobID: String
    var model: String
    var images: [GeneratedImage]
    var progress: [NativeImageJobProgress]
    var unloadedAfterJob: Bool
    var unloadedChatModels: [String]
    var restoredChatModels: [String]

    var toolPayload: [String: Any] {
        [
            "kind": "native_image_generation_job",
            "job_id": jobID,
            "model": model,
            "status": NativeImageJobPhase.completed.rawValue,
            // The result auto-renders as an image card in the chat, so the
            // model must not re-share it. Without this, models call
            // `share_artifact` on the generated path, which fails on the
            // sandbox path restriction and produces a misleading error note.
            "already_displayed": true,
            "display_note":
                "The generated image is already shown to the user in the chat. "
                + "Do NOT call share_artifact for it. If the user asked for a follow-up edit "
                + "or transformation of this image, continue now by calling image_edit with "
                + "source_paths set to this result's images[].path; otherwise just briefly "
                + "confirm the image was created.",
            "unloaded_after_job": unloadedAfterJob,
            "unloaded_chat_models": unloadedChatModels,
            "restored_chat_models": restoredChatModels,
            "images": images.map { image in
                [
                    "path": image.url.path,
                    "url": image.url.absoluteString,
                    "seed": image.seed,
                ] as [String: Any]
            },
            // NOTE: the per-step `progress` telemetry is deliberately NOT included
            // in the model-facing tool result. It is ~8KB of repetitive UUID-laden
            // JSON (queued/running/… events × every step) that the model never
            // needs — it only has to know the image was created and is already
            // shown. Feeding it back bloats context and, on small quantized chat
            // models (e.g. gemma-4 4-bit), measurably pushes them toward
            // post-handoff degeneration/looping. The live UI consumes progress via
            // `NativeImageJobProgress` NotificationCenter events, and the inline
            // render bridge only reads `job_id`/`images` — so dropping it here is
            // safe for both surfaces.
        ]
    }
}

struct NativeImageChatResidencyLease: Sendable, Equatable {
    var unloadedModelNames: [String]

    static let empty = NativeImageChatResidencyLease(unloadedModelNames: [])
}

enum NativeImageChatResidencyPolicy {
    static func shouldUnloadChatModels(for config: AgentDelegationConfiguration) -> Bool {
        config.imageJobLoadPolicy == .agentSingleResidency
    }
}

enum NativeImageJobCoordinatorError: Error, CustomStringConvertible {
    case noReadyModel(kind: AgentDelegationModelKind)
    case selectedModelUnavailable(model: String, kind: AgentDelegationModelKind)
    case selectedModelIncomplete(model: String, reasons: [String])
    case selectedModelWrongKind(model: String, expected: AgentDelegationModelKind)
    case requestFailed(String)
    case cancelled

    var description: String {
        switch self {
        case .noReadyModel(let kind):
            return "no ready local model configured or installed for \(kind.rawValue)"
        case .selectedModelUnavailable(let model, let kind):
            return "selected local image model '\(model)' is not installed for \(kind.rawValue)"
        case .selectedModelIncomplete(let model, let reasons):
            let suffix = reasons.isEmpty ? "" : ": \(reasons.joined(separator: ", "))"
            return "selected local image model '\(model)' is incomplete\(suffix)"
        case .selectedModelWrongKind(let model, let expected):
            return "selected local image model '\(model)' is not compatible with \(expected.rawValue)"
        case .requestFailed(let message):
            return message
        case .cancelled:
            return "image job cancelled"
        }
    }
}

enum NativeImageJobModelResolver {
    static func resolve(
        requested: String?,
        configured: String?,
        available: [ImageModelInfo],
        kind: AgentDelegationModelKind
    ) throws -> String {
        if let requested = normalizedID(requested) {
            return try requireReadyModel(requested, available: available, kind: kind)
        }
        if let configured = normalizedID(configured) {
            return try requireReadyModel(configured, available: available, kind: kind)
        }
        if let candidate = available.first(where: { isReady($0, for: kind) }) {
            return candidate.id
        }
        throw NativeImageJobCoordinatorError.noReadyModel(kind: kind)
    }

    private static func normalizedID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isReady(_ model: ImageModelInfo, for kind: AgentDelegationModelKind) -> Bool {
        guard model.ready else { return false }
        switch kind {
        case .imageGeneration:
            return model.capabilities.textToImage
        case .imageEdit:
            return model.capabilities.imageEdit
        case .localTextDelegate:
            return false
        }
    }

    private static func requireReadyModel(
        _ id: String,
        available: [ImageModelInfo],
        kind: AgentDelegationModelKind
    ) throws -> String {
        guard let model = available.first(where: { matches($0, id: id) }) else {
            throw NativeImageJobCoordinatorError.selectedModelUnavailable(model: id, kind: kind)
        }
        guard model.ready else {
            throw NativeImageJobCoordinatorError.selectedModelIncomplete(model: id, reasons: model.blockedReasons)
        }
        guard isReady(model, for: kind) else {
            throw NativeImageJobCoordinatorError.selectedModelWrongKind(model: id, expected: kind)
        }
        return model.id
    }

    private static func matches(_ model: ImageModelInfo, id: String) -> Bool {
        model.id == id || model.canonicalName == id || model.displayName == id
    }
}

actor NativeImageJobCoordinator {
    static let shared = NativeImageJobCoordinator()

    private let imageService: ImageGenerationService

    init(imageService: ImageGenerationService = .shared) {
        self.imageService = imageService
    }

    func generate(_ request: NativeImageGenerateJobRequest) async -> AsyncThrowingStream<NativeImageJobResult, Error> {
        let jobID = UUID().uuidString
        return AsyncThrowingStream { continuation in
            let task = Task {
                var progress: [NativeImageJobProgress] = []
                func record(_ event: NativeImageJobProgress) {
                    var contextualEvent = event
                    contextualEvent.sessionID = request.context.sessionID
                    contextualEvent.assistantTurnID = request.context.assistantTurnID
                    contextualEvent.toolCallID = request.context.toolCallID
                    progress.append(contextualEvent)
                    NativeImageJobProgressCenter.post(contextualEvent)
                }

                let config = AgentDelegationConfigurationStore.snapshot()
                var chatLease = NativeImageChatResidencyLease.empty
                do {
                    record(NativeImageJobProgress(jobID: jobID, phase: .queued))
                    // Resolve the image model BEFORE any unload so the RAM-safety
                    // preflight can refuse-before-evict (never strand the user
                    // with the orchestrator unloaded and the image model too big).
                    let models = (try? await imageService.availableModels()) ?? []
                    let model = try NativeImageJobModelResolver.resolve(
                        requested: request.model,
                        configured: config.defaultImageGenerationModelId,
                        available: models,
                        kind: .imageGeneration
                    )
                    try await ChatResidencyHandoff.memoryPreflight(
                        requiredBytes: Int64(models.first { $0.id == model }?.totalBytes ?? 0),
                        enabled: config.ramSafetyPreflightEnabled)
                    chatLease = try await self.prepareChatResidencyIfNeeded(
                        config: config,
                        jobID: jobID,
                        record: record
                    )
                    var produced: [GeneratedImage] = []
                    let params = ImageGenerationParameters(
                        model: model,
                        prompt: request.prompt,
                        negativePrompt: request.negativePrompt,
                        width: request.width,
                        height: request.height,
                        steps: request.steps,
                        guidance: request.guidance,
                        seed: request.seed,
                        numImages: request.numImages,
                        outputFormat: request.outputFormat
                    )
                    let stream = await imageService.generate(params, jobID: jobID)
                    for try await event in stream {
                        switch event {
                        case .loadingModel(let loadedModel):
                            record(NativeImageJobProgress(jobID: jobID, phase: .loadingModel, model: loadedModel))
                        case .step(let step, let total, let eta):
                            record(
                                NativeImageJobProgress(
                                    jobID: jobID,
                                    phase: .generating,
                                    model: model,
                                    step: step,
                                    total: total,
                                    etaSeconds: eta
                                )
                            )
                        case .preview:
                            continue
                        case .completed(let images):
                            produced = images
                        case .failed(let message, _):
                            record(NativeImageJobProgress(jobID: jobID, phase: .failed, model: model, message: message))
                            throw NativeImageJobCoordinatorError.requestFailed(message)
                        case .cancelled:
                            record(NativeImageJobProgress(jobID: jobID, phase: .cancelled, model: model))
                            throw NativeImageJobCoordinatorError.cancelled
                        }
                    }

                    let shouldUnload = config.imageJobLoadPolicy != .manualPanelKeepsImageLoaded
                    if shouldUnload {
                        record(NativeImageJobProgress(jobID: jobID, phase: .unloading, model: model))
                        await imageService.unload()
                    }
                    let restoredChatModels = try await self.restoreChatResidencyIfNeeded(
                        lease: chatLease,
                        jobID: jobID,
                        record: record
                    )
                    record(NativeImageJobProgress(jobID: jobID, phase: .completed, model: model))
                    continuation.yield(
                        NativeImageJobResult(
                            jobID: jobID,
                            model: model,
                            images: produced,
                            progress: progress,
                            unloadedAfterJob: shouldUnload,
                            unloadedChatModels: chatLease.unloadedModelNames,
                            restoredChatModels: restoredChatModels
                        )
                    )
                    continuation.finish()
                } catch {
                    if config.imageJobLoadPolicy != .manualPanelKeepsImageLoaded {
                        await imageService.unload()
                    }
                    if !chatLease.unloadedModelNames.isEmpty {
                        _ = try? await self.restoreChatResidencyIfNeeded(
                            lease: chatLease,
                            jobID: jobID,
                            record: record
                        )
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func edit(_ request: NativeImageEditJobRequest) async -> AsyncThrowingStream<NativeImageJobResult, Error> {
        let jobID = UUID().uuidString
        return AsyncThrowingStream { continuation in
            let task = Task {
                var progress: [NativeImageJobProgress] = []
                func record(_ event: NativeImageJobProgress) {
                    var contextualEvent = event
                    contextualEvent.sessionID = request.context.sessionID
                    contextualEvent.assistantTurnID = request.context.assistantTurnID
                    contextualEvent.toolCallID = request.context.toolCallID
                    progress.append(contextualEvent)
                    NativeImageJobProgressCenter.post(contextualEvent)
                }

                let config = AgentDelegationConfigurationStore.snapshot()
                var chatLease = NativeImageChatResidencyLease.empty
                do {
                    record(NativeImageJobProgress(jobID: jobID, phase: .queued))
                    // Resolve before unload → RAM-safety preflight (refuse-before-evict).
                    let models = (try? await imageService.availableModels()) ?? []
                    let model = try NativeImageJobModelResolver.resolve(
                        requested: request.model,
                        configured: config.defaultImageEditModelId,
                        available: models,
                        kind: .imageEdit
                    )
                    try await ChatResidencyHandoff.memoryPreflight(
                        requiredBytes: Int64(models.first { $0.id == model }?.totalBytes ?? 0),
                        enabled: config.ramSafetyPreflightEnabled)
                    chatLease = try await self.prepareChatResidencyIfNeeded(
                        config: config,
                        jobID: jobID,
                        record: record
                    )
                    var produced: [GeneratedImage] = []
                    let params = ImageEditParameters(
                        model: model,
                        prompt: request.prompt,
                        sourceImages: request.sourceImages,
                        negativePrompt: request.negativePrompt,
                        strength: request.strength,
                        width: request.width,
                        height: request.height,
                        steps: request.steps,
                        guidance: request.guidance,
                        seed: request.seed,
                        outputFormat: request.outputFormat
                    )
                    let stream = await imageService.edit(params, jobID: jobID)
                    for try await event in stream {
                        switch event {
                        case .loadingModel(let loadedModel):
                            record(NativeImageJobProgress(jobID: jobID, phase: .loadingModel, model: loadedModel))
                        case .step(let step, let total, let eta):
                            record(
                                NativeImageJobProgress(
                                    jobID: jobID,
                                    phase: .generating,
                                    model: model,
                                    step: step,
                                    total: total,
                                    etaSeconds: eta
                                )
                            )
                        case .preview:
                            continue
                        case .completed(let images):
                            produced = images
                        case .failed(let message, _):
                            record(NativeImageJobProgress(jobID: jobID, phase: .failed, model: model, message: message))
                            throw NativeImageJobCoordinatorError.requestFailed(message)
                        case .cancelled:
                            record(NativeImageJobProgress(jobID: jobID, phase: .cancelled, model: model))
                            throw NativeImageJobCoordinatorError.cancelled
                        }
                    }

                    let shouldUnload = config.imageJobLoadPolicy != .manualPanelKeepsImageLoaded
                    if shouldUnload {
                        record(NativeImageJobProgress(jobID: jobID, phase: .unloading, model: model))
                        await imageService.unload()
                    }
                    let restoredChatModels = try await self.restoreChatResidencyIfNeeded(
                        lease: chatLease,
                        jobID: jobID,
                        record: record
                    )
                    record(NativeImageJobProgress(jobID: jobID, phase: .completed, model: model))
                    continuation.yield(
                        NativeImageJobResult(
                            jobID: jobID,
                            model: model,
                            images: produced,
                            progress: progress,
                            unloadedAfterJob: shouldUnload,
                            unloadedChatModels: chatLease.unloadedModelNames,
                            restoredChatModels: restoredChatModels
                        )
                    )
                    continuation.finish()
                } catch {
                    if config.imageJobLoadPolicy != .manualPanelKeepsImageLoaded {
                        await imageService.unload()
                    }
                    if !chatLease.unloadedModelNames.isEmpty {
                        _ = try? await self.restoreChatResidencyIfNeeded(
                            lease: chatLease,
                            jobID: jobID,
                            record: record
                        )
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func prepareChatResidencyIfNeeded(
        config: AgentDelegationConfiguration,
        jobID: String,
        record: (NativeImageJobProgress) -> Void
    ) async throws -> NativeImageChatResidencyLease {
        guard NativeImageChatResidencyPolicy.shouldUnloadChatModels(for: config) else {
            return .empty
        }

        let waitMs = max(15, min(config.budgets.maxElapsedSeconds, 300)) * 1000
        record(
            NativeImageJobProgress(
                jobID: jobID,
                phase: .waitingForChatIdle,
                message: "waiting for local chat generation to become idle"
            )
        )
        let wentIdle = await InferenceLoadCoordinator.shared.waitForChatIdle(timeoutMs: waitMs)
        guard wentIdle else {
            throw NativeImageJobCoordinatorError.requestFailed(
                "local chat generation did not become idle before the native image job memory gate"
            )
        }

        let resident = await ModelRuntime.shared.cachedModelSummaries()
            .map(\.name)
            .sorted()
        guard !resident.isEmpty else { return .empty }

        record(
            NativeImageJobProgress(
                jobID: jobID,
                phase: .unloadingChatModels,
                message: resident.joined(separator: ", ")
            )
        )
        for name in resident {
            await ModelRuntime.shared.unload(name: name)
        }
        return NativeImageChatResidencyLease(unloadedModelNames: resident)
    }

    private func restoreChatResidencyIfNeeded(
        lease: NativeImageChatResidencyLease,
        jobID: String,
        record: (NativeImageJobProgress) -> Void
    ) async throws -> [String] {
        guard !lease.unloadedModelNames.isEmpty else { return [] }
        record(
            NativeImageJobProgress(
                jobID: jobID,
                phase: .restoringChatModels,
                message: lease.unloadedModelNames.joined(separator: ", ")
            )
        )

        var restored: [String] = []
        for name in lease.unloadedModelNames {
            try await ModelRuntime.shared.preload(name: name)
            restored.append(name)
        }
        return restored
    }
}

enum NativeImageJobProgressCenter {
    static let notificationName = Foundation.Notification.Name("nativeImageJobProgressChanged")

    static func post(_ progress: NativeImageJobProgress) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: notificationName, object: progress)
        }
    }
}
