//
//  ImageSubagentKind.swift
//  OsaurusCore — Subagent framework
//
//  The native-image subagent kind that serves the single `image` tool:
//  generate when `source_paths` is empty, edit when it is set. Resolves the
//  configured local image model (separate gen vs edit defaults), runs the job
//  through `NativeImageJobCoordinator`, bridges the job's live progress onto the
//  shared `SubagentFeed`, and hands back the same compact image payload the
//  inline-render bridge already reads.
//
//  `modelSource = .dedicatedConfigured` but the image residency handoff is NOT
//  run by the host middleware (`makeHandoff()` stays the passthrough default).
//  The coordinator must unload the chat model INSIDE its own detached producer
//  task — a chat-turn cancel (which the unload itself can trigger) must not
//  cascade into the engine drain and lose the image. Moving the unload into the
//  host's chat-turn-task `around` would reintroduce that cancel cascade, so the
//  coordinator stays the residency authority for images and the host only owns
//  the guard, feed, result, and telemetry.
//
//  Model divergence (deliberate): `image` is the ONE kind that does NOT use the
//  standard per-agent model picker. Its capability sets
//  `supportsModelOverride = false`, so it is NOT a `SubagentModelResolution`
//  client and AgentsView does not render the shared override row for it. Instead
//  it owns a dedicated model system — separate gen vs edit ids
//  (`imageGenerationModelId` / `imageEditModelId`), resolved via
//  `SubagentToolVisibility.effectiveImageModel`, with their own readiness +
//  "first ready" fallback and the coordinator-owned residency above. The
//  chat-driven kinds (computer_use, spawn) instead share
//  `subagentModelOverrides` → `effectiveSubagentModel` → `SubagentModelResolution`.
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
    let capability = SubagentCapabilityRegistry.image

    private let params: ImageJobParams
    private let argumentsJSON: String
    /// Load policy snapshotted in `resolveModel`, read by `admissionClass`:
    /// `.agentSingleResidency` unloads chat models inside the coordinator, so
    /// the run must hold the GPU exclusively even though the host handoff
    /// stays passthrough (the coordinator is the residency authority).
    private var loadPolicy: SubagentImageLoadPolicy = .agentSingleResidency

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
        // Per-agent image enable + model (no global master switch): Default /
        // main chat → its own image switch + configured model; a custom agent →
        // its own `imageEnabled` toggle + per-agent model, resolved from the
        // launching agent (`scope`). A nil model falls through to the resolver's
        // first-ready-model fallback below.
        let isDefault = scope.agentId == Agent.defaultId
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }
        let imageAllowed = SubagentToolVisibility.imageAvailable(
            isDefault: isDefault,
            config: config,
            perAgentEnabled: settings?.imageEnabled ?? false
        )
        guard imageAllowed else {
            throw SubagentError.denied(
                params.isEdit
                    ? "Image edit is not enabled for this agent."
                    : "Image generation is not enabled for this agent."
            )
        }
        let modelKind: SubagentModelKind = params.isEdit ? .imageEdit : .imageGeneration
        self.loadPolicy = config.imageJobLoadPolicy
        let configured = SubagentToolVisibility.effectiveImageModel(
            isEdit: params.isEdit,
            isDefault: isDefault,
            config: config,
            settings: settings
        )
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

    /// The image model is always a local MLX graph; under `.agentSingleResidency`
    /// the coordinator additionally unloads/restores chat models, which is a
    /// full residency handoff — exclusive. Other policies keep the image model
    /// alongside (in-place local).
    func admissionClass(_ resolved: ResolvedModel) -> SubagentAdmissionClass {
        loadPolicy == .agentSingleResidency ? .localExclusive : .localInPlace
    }

    // MARK: - Permission

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        let config = SubagentConfigurationStore.snapshot()
        // Per-agent permission: Default / main chat → global permission map; a
        // custom agent → its own `subagentPermissions`, resolved from the
        // launching agent (`scope`). The model is now chosen in the agent's
        // Subagents tab, so the prompt is a plain allow / deny (the `.ask`
        // policy); `.alwaysAllow` is set per-agent in that tab.
        let isDefault = scope.agentId == Agent.defaultId
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }
        let policy = SubagentToolVisibility.effectivePermission(
            capabilityId: capability.id,
            isDefault: isDefault,
            config: config,
            settings: settings
        )
        let approvalJSON = SubagentApprovalArguments.enrichedJSON(
            from: argumentsJSON,
            values: [
                "resolved_model": resolved.name,
                "image_job_load_policy": config.imageJobLoadPolicy.rawValue,
            ]
        )
        return params.isEdit
            ? await editPermission(policy: policy, argumentsJSON: approvalJSON)
            : await generatePermission(policy: policy, argumentsJSON: approvalJSON)
    }

    private func generatePermission(
        policy: SubagentPermissionPolicy,
        argumentsJSON: String
    ) async -> SubagentDecision {
        switch policy {
        case .deny:
            return .denied("Image generation is denied by this agent's permission settings.")
        case .alwaysAllow:
            return .allow
        case .ask:
            if ChatExecutionContext.autoApproveToolPrompts { return .allow }
            let approved = await ToolPermissionPromptService.requestApproval(
                toolName: "image",
                description: ImageTool.toolDescription,
                argumentsJSON: argumentsJSON
            )
            return approved ? .allow : .userDenied("User denied image generation.")
        }
    }

    private func editPermission(
        policy: SubagentPermissionPolicy,
        argumentsJSON: String
    ) async -> SubagentDecision {
        switch policy {
        case .deny:
            return .denied("Image edit is denied by this agent's permission settings.")
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

        // Stamp installed edit capability onto the result so its payload's
        // edit-continuation steer + the loop's post-generation edit nudge are
        // suppressed when no ready edit model exists (they'd otherwise point the
        // model at an edit the runtime can't perform). Read off the same warmed
        // picker cache the schema/guidance gates use.
        var result = finalResult
        result.editModelAvailable = await MainActor.run {
            ModelPickerItemCache.shared.hasReadyImageEditModel
        }

        let count = result.images.count
        let verb = params.isEdit ? "Edited" : "Generated"
        let summary = "\(verb) \(count) image\(count == 1 ? "" : "s") with \(resolved.name)."
        return SubagentResult(payload: result.toolPayload, summary: summary)
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
            // One coalesced "generating" row whose bar + "step 12/30 · ~8s left"
            // detail advance in place, mirroring the manual image panel.
            let fraction: Double? = {
                guard let step = progress.step, let total = progress.total, total > 0 else {
                    return nil
                }
                return Double(step) / Double(total)
            }()
            feed.emitProgress(
                "generating",
                fraction: fraction,
                step: progress.step ?? 0,
                detail: Self.generatingDetail(progress)
            )
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

    /// Compact human detail for a generating tick — "step 12/30 · ~8s left",
    /// with each piece dropped when the job hasn't reported it yet, and `nil`
    /// when there's nothing useful to show.
    private static func generatingDetail(_ progress: NativeImageJobProgress) -> String? {
        var parts: [String] = []
        if let step = progress.step {
            if let total = progress.total, total > 0 {
                parts.append("step \(step)/\(total)")
            } else {
                parts.append("step \(step)")
            }
        }
        if let eta = progress.etaSeconds, eta > 0 {
            parts.append(String(format: "~%.0fs left", eta))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            // A missing file makes `resourceValues` throw NSCocoaErrorDomain 260
            // BEFORE the isRegularFile guard can run — without this mapping a
            // bad source path surfaced as `execution_error` ("the edit
            // subsystem broke") instead of `invalid_args` ("fix your path"),
            // pointing the calling model away from the actual repair.
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            } catch {
                throw NativeImageToolInputError.notAFile(path)
            }
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
