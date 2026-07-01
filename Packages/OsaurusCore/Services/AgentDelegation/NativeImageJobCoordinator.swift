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
    var unloadedAfterJob: Bool
    var unloadedChatModels: [String]
    var restoredChatModels: [String]
    /// Whether this job edited existing source images (`true`) or generated a
    /// fresh image (`false`). Surfaced as `mode` so the gen→edit nudge, the
    /// AgentToolLoop continuation promotion, and the artifact bridge can
    /// distinguish the two now that one `image` tool serves both.
    var isEdit: Bool = false

    /// Whether a ready edit model is installed. When false, the result steers
    /// the model to confirm only (the edit-continuation clause is dropped) and
    /// `edit_available` is surfaced so `AgentTaskState` suppresses its
    /// post-generation "now edit it" nudge — both would otherwise point at an
    /// edit the runtime can't perform. Defaults true (edit available).
    var editModelAvailable: Bool = true

    var toolPayload: [String: Any] {
        // Always: the result auto-renders as an image card, so the model must
        // not re-share it (`share_artifact` on the path fails the sandbox path
        // restriction and produces a misleading error note). The edit-
        // continuation clause is CONDITIONAL — kept only when an edit model is
        // installed so a requested follow-up edit still fires, dropped otherwise
        // so the model doesn't attempt an unavailable edit.
        let displayNote: String = {
            let base =
                "The image is already shown to the user in the chat; "
                + "do NOT call share_artifact for it."
            guard editModelAvailable else {
                return base + " Confirm briefly."
            }
            return base
                + " If the user asked for a follow-up edit of this image, call the `image` tool "
                + "again with source_paths set to this result's images[].path; otherwise confirm "
                + "briefly."
        }()
        return [
            "kind": "native_image_generation_job",
            "mode": isEdit ? "edit" : "generate",
            "job_id": jobID,
            "model": model,
            "status": NativeImageJobPhase.completed.rawValue,
            "already_displayed": true,
            "display_note": displayNote,
            // Read by `AgentTaskState.classify` to gate the post-generation edit
            // nudge on installed edit capability.
            "edit_available": editModelAvailable,
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
            // NOTE: per-step progress telemetry is deliberately NOT surfaced to the
            // model — neither stored on the result nor in this payload. It is ~8KB
            // of repetitive UUID-laden JSON (queued/running/… × every step) the
            // model never needs (it only has to know the image was created and is
            // already shown); feeding it back bloats context and, on small
            // quantized chat models (e.g. gemma-4 4-bit), measurably pushes them
            // toward post-handoff degeneration/looping. The live UI consumes
            // progress via `NativeImageJobProgress` NotificationCenter events, and
            // the inline render bridge only reads `job_id`/`images`.
        ]
    }
}

enum NativeImageJobCoordinatorError: Error, CustomStringConvertible {
    case noReadyModel(kind: SubagentModelKind)
    case selectedModelUnavailable(model: String, kind: SubagentModelKind)
    case selectedModelIncomplete(model: String, reasons: [String])
    case selectedModelWrongKind(model: String, expected: SubagentModelKind)
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
        kind: SubagentModelKind
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

    private static func isReady(_ model: ImageModelInfo, for kind: SubagentModelKind) -> Bool {
        guard model.ready else { return false }
        switch kind {
        case .imageGeneration:
            return model.capabilities.textToImage
        case .imageEdit:
            return model.capabilities.imageEdit
        }
    }

    private static func requireReadyModel(
        _ id: String,
        available: [ImageModelInfo],
        kind: SubagentModelKind
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
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runJob(
                    context: request.context,
                    kind: .imageGeneration,
                    isEdit: false,
                    requestedModel: request.model,
                    configuredModel: { $0.defaultImageGenerationModelId },
                    makeStream: { model, jobID in
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
                        return await self.imageService.generate(params, jobID: jobID)
                    },
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func edit(_ request: NativeImageEditJobRequest) async -> AsyncThrowingStream<NativeImageJobResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runJob(
                    context: request.context,
                    kind: .imageEdit,
                    isEdit: true,
                    requestedModel: request.model,
                    configuredModel: { $0.defaultImageEditModelId },
                    makeStream: { model, jobID in
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
                        return await self.imageService.edit(params, jobID: jobID)
                    },
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Shared driver for both image kinds. `generate`/`edit` were ~95% identical
    /// — resolve-before-evict, RAM-safety preflight, single-residency handoff,
    /// stream consumption, unload, restore, and the compact result are all the
    /// same. Only the model kind, the configured-default key, the engine stream
    /// factory, and the `isEdit` flag differ; everything else lives here once.
    ///
    /// The residency unload stays INSIDE this producer task (not the host's
    /// `ResidencyHandoff` middleware) on purpose: a chat-turn cancel that the
    /// unload itself can trigger must not cascade into the engine drain and lose
    /// the image (see `ImageSubagentKind`, whose `makeHandoff()` stays the
    /// passthrough default so the coordinator remains the residency authority).
    private func runJob(
        context: NativeImageJobContext,
        kind: SubagentModelKind,
        isEdit: Bool,
        requestedModel: String?,
        configuredModel: @Sendable (SubagentConfiguration) -> String?,
        makeStream:
            @Sendable (_ model: String, _ jobID: String) async -> AsyncThrowingStream<
                ImageGenerationEvent, Error
            >,
        continuation: AsyncThrowingStream<NativeImageJobResult, Error>.Continuation
    ) async {
        let jobID = UUID().uuidString
        func record(_ event: NativeImageJobProgress) {
            var contextualEvent = event
            contextualEvent.sessionID = context.sessionID
            contextualEvent.assistantTurnID = context.assistantTurnID
            contextualEvent.toolCallID = context.toolCallID
            NativeImageJobProgressCenter.post(contextualEvent)
        }

        let config = SubagentConfigurationStore.snapshot()
        var chatLease = ChatResidencyLease.empty
        do {
            record(NativeImageJobProgress(jobID: jobID, phase: .queued))
            // Resolve the image model BEFORE any unload so the RAM-safety
            // preflight can refuse-before-evict (never strand the user with the
            // orchestrator unloaded and the image model too big).
            let models = (try? await imageService.availableModels()) ?? []
            let model = try NativeImageJobModelResolver.resolve(
                requested: requestedModel,
                configured: configuredModel(config),
                available: models,
                kind: kind
            )
            try await ChatResidencyHandoff.memoryPreflight(
                requiredBytes: Int64(models.first { $0.id == model }?.totalBytes ?? 0),
                enabled: config.ramSafetyPreflightEnabled
            )
            chatLease = try await self.prepareChatResidencyIfNeeded(
                config: config,
                jobID: jobID,
                record: record
            )
            var produced: [GeneratedImage] = []
            let stream = await makeStream(model, jobID)
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
            let restoredChatModels = await self.restoreChatResidencyIfNeeded(
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
                    unloadedAfterJob: shouldUnload,
                    unloadedChatModels: chatLease.unloadedModelNames,
                    restoredChatModels: restoredChatModels,
                    isEdit: isEdit
                )
            )
            continuation.finish()
        } catch {
            if config.imageJobLoadPolicy != .manualPanelKeepsImageLoaded {
                await imageService.unload()
            }
            if !chatLease.unloadedModelNames.isEmpty {
                _ = await self.restoreChatResidencyIfNeeded(
                    lease: chatLease,
                    jobID: jobID,
                    record: record
                )
            }
            continuation.finish(throwing: error)
        }
    }

    /// Single-residency handoff for an image job, delegating to the shared
    /// `ChatResidencyHandoff` (no private residency copy). Only evicts when the
    /// load policy calls for it. Phase events are recorded around the shared
    /// calls (rather than threading the actor-isolated `record` into the
    /// nonisolated handoff) so the image job's live progress stream keeps its
    /// `waiting_for_chat_idle` / `unloading_chat_models` rows.
    private func prepareChatResidencyIfNeeded(
        config: SubagentConfiguration,
        jobID: String,
        record: (NativeImageJobProgress) -> Void
    ) async throws -> ChatResidencyLease {
        guard config.imageJobUnloadsChatModels else { return .empty }
        record(
            NativeImageJobProgress(
                jobID: jobID,
                phase: .waitingForChatIdle,
                message: "waiting for local chat generation to become idle"
            )
        )
        let lease: ChatResidencyLease
        do {
            lease = try await ChatResidencyHandoff.unloadResidentChatModels(
                maxElapsedSeconds: config.budgets.maxElapsedSeconds
            )
        } catch ChatResidencyHandoff.HandoffError.chatBusy {
            throw NativeImageJobCoordinatorError.requestFailed(
                "local chat generation did not become idle before the native image job memory gate"
            )
        }
        if !lease.unloadedModelNames.isEmpty {
            record(
                NativeImageJobProgress(
                    jobID: jobID,
                    phase: .unloadingChatModels,
                    message: lease.unloadedModelNames.joined(separator: ", ")
                )
            )
        }
        return lease
    }

    /// Best-effort restore: the image has already been produced and written to
    /// disk by the time this runs, so a reload hiccup must NOT fail the job and
    /// lose the user's image. `restoreBestEffort` already retries + verifies
    /// residency and logs a persistent failure; if the orchestrator still isn't
    /// resident, the next chat turn reloads it on demand (cold load through the
    /// gated `loadContainer`). Returns the names actually restored.
    private func restoreChatResidencyIfNeeded(
        lease: ChatResidencyLease,
        jobID: String,
        record: (NativeImageJobProgress) -> Void
    ) async -> [String] {
        guard !lease.unloadedModelNames.isEmpty else { return [] }
        record(
            NativeImageJobProgress(
                jobID: jobID,
                phase: .restoringChatModels,
                message: lease.unloadedModelNames.joined(separator: ", ")
            )
        )
        return await ChatResidencyHandoff.restoreBestEffort(lease)
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
