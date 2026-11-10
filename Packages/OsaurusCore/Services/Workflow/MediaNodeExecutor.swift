//
//  MediaNodeExecutor.swift
//  osaurus
//
//  Media steps. Resolves the step's model (family or id, on this Mac or a
//  connected provider), renders its parameters (values, bindings, and the
//  node input's overrides), runs the job through the same coordinator the
//  chat's `image` and `video` tools use (so residency handoff, memory
//  admission, and activity rows are shared), and saves what it made into the run's files
//  with the settings that made each one. A local job needs no prompt: the
//  step itself is the authorization. A billable provider job still asks,
//  unless the agent's image or video permission is Always Allow.
//

import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a media step calls out to; tests swap it.
struct MediaNodeRuntime: Sendable {
    var candidates: @Sendable () async -> [MediaModelCandidate]
    var preferredModel: @Sendable (MediaAction) -> String?
    var generateLocal: @Sendable (NativeImageGenerateJobRequest, InterruptToken) async throws -> NativeImageJobResult
    var editLocal: @Sendable (NativeImageEditJobRequest, InterruptToken) async throws -> NativeImageJobResult
    var upscaleLocal: @Sendable (NativeImageUpscaleJobRequest, InterruptToken) async throws -> NativeImageJobResult
    var generateLocalVideo:
        @Sendable (
            MediaVideoGenerationRequest, NativeImageJobContext, InterruptToken,
            @escaping @Sendable (MediaGenerationEvent) -> Void
        ) async throws -> GeneratedMedia
    var generateRemoteImage: @Sendable (MediaImageGenerationRequest) async throws -> [GeneratedMedia]
    var quoteVideo: @Sendable (MediaVideoGenerationRequest) async throws -> MediaVideoQuote
    var generateVideo:
        @Sendable (MediaVideoGenerationRequest, MediaVideoQuote, @escaping @Sendable (MediaGenerationEvent) -> Void)
            async throws -> GeneratedMedia
    /// Whether a billable provider job may go ahead: the agent's policy,
    /// else the person's answer.
    var approveRemote:
        @Sendable (_ tool: String, _ caller: WorkflowCaller, _ argumentsJSON: String) async -> MediaRemoteApproval
    /// The installed local model `name` names, when it is loaded right now.
    var residentLocalModel: @Sendable (_ name: String) async -> String? = { name in
        guard let installed = ModelManager.findInstalledModel(named: name),
            await ModelRuntime.shared.residencyIdentity(named: installed.name) != nil
        else { return nil }
        return installed.name
    }

    static let live = MediaNodeRuntime(
        candidates: { await MediaModelResolver.loadedLiveCandidates() },
        preferredModel: { MediaModelResolver.configuredDefault(for: $0) },
        generateLocal: { request, interrupt in
            try await drain { await NativeImageJobCoordinator.shared.generate(request, interrupt: interrupt) }
        },
        editLocal: { request, interrupt in
            try await drain { await NativeImageJobCoordinator.shared.edit(request, interrupt: interrupt) }
        },
        upscaleLocal: { request, interrupt in
            try await drain { await NativeImageJobCoordinator.shared.upscale(request, interrupt: interrupt) }
        },
        generateLocalVideo: { request, context, interrupt, progress in
            try await Task.detached(priority: .userInitiated) {
                try await context.invocation.withContext {
                    try await NativeImageJobCoordinator.shared.generateVideo(
                        request, context: context, interrupt: interrupt, progress: progress)
                }
            }.value
        },
        generateRemoteImage: { try await MediaGenerationCoordinator.shared.generateImage($0) },
        quoteVideo: { try await MediaGenerationCoordinator.shared.quoteVideo($0) },
        generateVideo: { request, quote, progress in
            try await MediaGenerationCoordinator.shared.generateVideo(request, approvedQuote: quote, progress: progress)
        },
        approveRemote: { tool, caller, arguments in await liveApproveRemote(tool: tool, caller: caller, arguments: arguments) }
    )

    /// The job stream is consumed on a detached task: a cancel that the
    /// residency unload itself can trigger must not abort the engine drain
    /// (the same reason `ImageSubagentKind` detaches). A stop reaches the
    /// job through its interrupt token.
    private static func drain(
        _ make: @escaping @Sendable () async -> AsyncThrowingStream<NativeImageJobResult, Error>
    ) async throws -> NativeImageJobResult {
        let result = try await Task.detached(priority: .userInitiated) { () -> NativeImageJobResult? in
            var last: NativeImageJobResult?
            for try await value in await make() { last = value }
            return last
        }.value
        guard let result else { throw WorkflowNodeError.unsupported(L("The image job finished without a result.")) }
        return result
    }

    private static func liveApproveRemote(tool: String, caller: WorkflowCaller, arguments: String) async
        -> MediaRemoteApproval
    {
        let agentID = caller.agentID ?? Agent.defaultId
        let settings = await MainActor.run { AgentManager.shared.agent(for: agentID)?.settings }
        let capability = tool == "video" ? SubagentCapabilityRegistry.video : SubagentCapabilityRegistry.image
        let policy = SubagentToolVisibility.effectivePermission(
            capabilityId: capability.id, isDefault: agentID == Agent.defaultId,
            config: SubagentConfigurationStore.snapshot(), settings: settings)
        return await decide(policy: policy, caller: caller) {
            await ToolPermissionPromptService.requestApproval(
                toolName: tool,
                description: L("A workflow step wants to run a billable \(tool) job on a connected provider."),
                argumentsJSON: arguments)
        }
    }

    /// The prompt has no timeout, so a run nobody is watching must not
    /// reach it.
    static func decide(
        policy: SubagentPermissionPolicy, caller: WorkflowCaller, ask: () async -> Bool
    ) async -> MediaRemoteApproval {
        switch policy {
        case .deny: return .denied
        case .alwaysAllow: return .approved
        case .ask:
            guard WorkflowFolderGrantCoordinator.canAsk(caller) else { return .nobodyToAsk }
            return await ask() ? .approved : .denied
        }
    }
}

/// Local media jobs from every workflow run go one at a time. The coordinator
/// unloads the chat model before the GPU gate and restores it after, so
/// overlapping jobs swap it out and back repeatedly. A job keeps the lane
/// until its stream ends, residency restore included, even when the step
/// that started it was stopped or timed out: the stop reaches the engine
/// (generate, edit and upscale all stop at their next step), and a stopped
/// job still queued leaves at once through its interrupt.
actor MediaJobLane {
    static let shared = MediaJobLane()

    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task.detached(priority: .userInitiated) { () async throws -> T in
            await previous?.value
            return try await body()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

enum MediaRemoteApproval: Equatable, Sendable {
    case approved
    case denied
    /// The policy is Ask, but no one can answer for this caller.
    case nobodyToAsk
}

/// The parameters one run of a media step uses, after bindings and
/// overrides.
struct ResolvedMediaParameters: Equatable, Sendable {
    var prompt: String
    var negativePrompt: String?
    var sources: [String]
    var width: Int?
    var height: Int?
    var steps: Int?
    var guidance: Double?
    var strength: Double?
    var seed: UInt64
    var seedMode: MediaSeedMode
    var count: Int
    var format: ImageOutputFormat
    var scale: Int
    var duration: String?
    var resolution: String?
    var aspectRatio: String?
    var audio: Bool?
    var batchSize: Int = 1
    var sampler: String? = nil
    var scheduler: String? = nil
    var shift: Double? = nil
    var previewInterval: Int? = nil
    var frameCount: Int? = nil
    var fps: Int? = nil

    /// One seed per image, consecutive from `seed`.
    var seeds: [UInt64] { (0 ..< count).map { seed &+ UInt64($0) } }

    var sampling: ImageRequestLimits.Sampling {
        ImageRequestLimits.Sampling(
            sampler: sampler, scheduler: scheduler, shift: shift.map(Float.init), previewInterval: previewInterval)
    }
}

enum MediaNodeExecutor {

    nonisolated(unsafe) static var runtime: MediaNodeRuntime = .live

    static func run(spec: MediaSpec, context: WorkflowNodeContext) async throws -> WorkflowNodeOutcome {
        let runtime = Self.runtime
        let started = Date()
        let params = try resolveParameters(spec, context: context)
        let candidates = await runtime.candidates()
        let model: MediaModelCandidate
        switch MediaModelResolver.resolve(
            spec.model, action: spec.action, candidates: candidates, preferred: runtime.preferredModel(spec.action))
        {
        case .success(let hit): model = hit
        case .failure(let failure): throw failure
        }

        var logs = [L("Model: \(model.displayName) (\(model.isLocal ? L("this Mac") : L("provider")))")]
        logs.append(describe(params, action: spec.action))

        let sourceURLs = try resolveSources(params.sources, action: spec.action, context: context)
        let produced: [Produced]
        do {
            if model.isLocal {
                produced = try await runLocal(
                    spec: spec, params: params, model: model, sources: sourceURLs, context: context, runtime: runtime,
                    logs: &logs)
            } else {
                produced = try await runRemote(
                    spec: spec, params: params, model: model, sources: sourceURLs, context: context, runtime: runtime,
                    logs: &logs)
            }
        } catch let partial as PartialBatch {
            // A failed step records no files, so the finished images are
            // kept in the run's folder and named in the error.
            let kept = (try? save(partial.produced, spec: spec, params: params, model: model, context: context)) ?? []
            let underlying = stepError(partial.underlying, model: model)
            guard !kept.isEmpty else { throw underlying }
            let reason = WorkflowFailure.message(underlying)
            let paths = kept.map(\.artifact.path).joined(separator: ", ")
            throw WorkflowNodeError.unsupported(
                L("\(model.displayName) failed after \(kept.count) of \(params.count) images: \(reason) The finished images were kept: \(paths)"))
        } catch {
            throw stepError(error, model: model)
        }

        let saved = try save(produced, spec: spec, params: params, model: model, context: context)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let took = WorkflowStepRisk.duration(elapsed).replacingOccurrences(of: "~", with: "")
        logs.append(
            saved.isEmpty
                ? L("Nothing was made.")
                : saved.count == 1 ? L("Made 1 file in \(took).") : L("Made \(saved.count) files in \(took).")
        )
        let images = saved.filter { !$0.isVideo }.map(\.outputValue)
        let videos = saved.filter(\.isVideo).map(\.outputValue)
        let output: JSONValue = .object([
            "images": .array(images),
            "videos": .array(videos),
            "model": .string(model.displayName),
            "backend": .string(model.isLocal ? "local" : "remote"),
            "count": .number(Double(saved.count)),
            "duration_ms": .number(Double(elapsed)),
        ])
        return WorkflowNodeOutcome(
            output: output, model: model.displayName, logs: logs, artifacts: saved.map(\.artifact))
    }

    // MARK: - Parameters

    /// The step's parameters for this run: an input override wins over the
    /// spec, a binding renders against the run, and the seed follows the
    /// seed mode (`increment` adds the map item's index).
    static func resolveParameters(_ spec: MediaSpec, context: WorkflowNodeContext) throws -> ResolvedMediaParameters {
        let ctx = context.bindings
        let overrides = context.input.objectValue ?? [:]
        func text(_ key: String, _ template: String?) -> String? {
            if let o = overrides[key] { return BindingRenderer.textValue(o).trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil }
            return template.map { BindingRenderer.renderText($0, in: ctx).trimmingCharacters(in: .whitespacesAndNewlines) }?.nonEmptyOrNil
        }
        func scalar<T: MediaScalar>(_ key: String, _ value: MediaValue<T>?) throws -> T? {
            if let o = overrides[key] {
                guard let v = T(json: o) else {
                    throw WorkflowNodeError.unsupported(L("Media input `\(key)` is \(BindingRenderer.textValue(o)), which is not a valid value."))
                }
                return v
            }
            guard let value else { return nil }
            guard let v = value.resolve(in: ctx) else {
                throw WorkflowNodeError.unsupported(
                    L("Media `\(key)` binds \(value.binding ?? ""), which rendered to nothing usable."))
            }
            return v
        }

        let mode =
            overrides["seed_mode"]?.stringValue.flatMap(MediaSeedMode.init(rawValue:))
            ?? (spec.seedMode == nil && overrides["seed"] != nil ? .fixed : spec.effectiveSeedMode)
        let baseSeed = try scalar("seed", spec.seed)
        let seed: UInt64
        switch mode {
        case .random: seed = UInt64.random(in: 0...UInt64(UInt32.max))
        case .fixed: seed = UInt64(max(0, baseSeed ?? Int.random(in: 0...Int(UInt32.max))))
        case .increment: seed = UInt64(max(0, baseSeed ?? 0)) &+ UInt64(max(0, ctx.index ?? 0))
        }
        let format = overrides["format"]?.stringValue.flatMap(ImageOutputFormat.init(rawValue:)) ?? spec.format ?? .png

        let params = ResolvedMediaParameters(
            prompt: text("prompt", spec.prompt) ?? "",
            negativePrompt: text("negative_prompt", spec.negativePrompt),
            sources: MediaSourceList.paths(spec.sources, overrides: context.input, in: ctx),
            width: try scalar("width", spec.width),
            height: try scalar("height", spec.height),
            steps: try scalar("steps", spec.steps),
            guidance: try scalar("guidance", spec.guidance),
            strength: try scalar("strength", spec.strength),
            seed: seed,
            seedMode: mode,
            count: min(MediaSpec.maximumCount, max(1, try scalar("count", spec.count) ?? 1)),
            format: format,
            scale: try scalar("scale", spec.scale) ?? 2,
            duration: text("duration", spec.duration),
            resolution: text("resolution", spec.resolution),
            aspectRatio: text("aspect_ratio", spec.aspectRatio),
            audio: try scalar("audio", spec.audio),
            batchSize: max(1, try scalar("batch_size", spec.batchSize) ?? 1),
            sampler: text("sampler", spec.sampler),
            scheduler: text("scheduler", spec.scheduler),
            shift: try scalar("shift", spec.shift),
            previewInterval: try scalar("preview_interval", spec.previewInterval),
            frameCount: try scalar("frame_count", spec.frameCount),
            fps: try scalar("fps", spec.fps))
        if spec.action.usesPrompt, params.prompt.isEmpty {
            throw WorkflowNodeError.unsupported(L("The media prompt rendered empty."))
        }
        if spec.action.usesSources, params.sources.isEmpty {
            throw WorkflowNodeError.unsupported(L("The media step has no source image: `sources` rendered empty."))
        }
        if spec.action == .upscale, !MediaSpec.upscaleScales.contains(params.scale) {
            throw WorkflowNodeError.unsupported(L("Upscale `scale` is \(params.scale); it must be 2 or 4."))
        }
        return params
    }

    static func describe(_ p: ResolvedMediaParameters, action: MediaAction) -> String {
        var parts = [L("seed \(p.seed) (\(p.seedMode.rawValue))")]
        if let w = p.width, let h = p.height { parts.append("\(w)×\(h)") }
        if let s = p.steps { parts.append(L("\(s) steps")) }
        if let g = p.guidance { parts.append(L("guidance \(BindingRenderer.textValue(.number(g)))")) }
        if action == .edit, let s = p.strength { parts.append(L("strength \(BindingRenderer.textValue(.number(s)))")) }
        if action == .generate, p.count > 1 { parts.append(L("\(p.count) images")) }
        if action == .generate, p.batchSize > 1 { parts.append(L("batch \(p.batchSize)")) }
        if let v = p.sampler { parts.append(L("sampler \(v)")) }
        if let v = p.scheduler { parts.append(L("scheduler \(v)")) }
        if let v = p.shift { parts.append(L("shift \(BindingRenderer.textValue(.number(v)))")) }
        if action == .upscale { parts.append("\(p.scale)×") }
        if action == .video, let d = p.duration { parts.append(d.hasSuffix("s") ? d : L("\(d)s")) }
        if action == .video, let f = p.frameCount { parts.append(L("\(f) frames")) }
        if action == .video, let f = p.fps { parts.append(L("\(f) fps")) }
        return parts.joined(separator: " · ")
    }

    /// Each source as a file inside the run's folders or this workflow's
    /// earlier files.
    static func resolveSources(_ paths: [String], action: MediaAction, context: WorkflowNodeContext) throws -> [URL] {
        guard action.usesSources || action == .video else { return [] }
        let scope = WorkflowFileScope(context: context)
        return try paths.prefix(MediaSpec.maximumSources).map { path in
            switch scope.resolve(path) {
            case .success(let url): return url
            case .failure(.notFound(let p)):
                throw WorkflowNodeError.unsupported(L("The source image does not exist: \(p)"))
            case .failure(.outside(let p)):
                throw WorkflowNodeError.unsupported(L("The source image is outside this run's folders: \(p)"))
            }
        }
    }

    // MARK: - Local

    struct Produced {
        var url: URL
        var seed: UInt64?
        var mimeType: String?
        /// What the engine ran, when the family reports it.
        var effective: ImageEffectiveParameters? = nil
        var effectiveVideo: VideoEffectiveParameters? = nil

        init(
            url: URL, seed: UInt64?, mimeType: String?, effective: ImageEffectiveParameters? = nil,
            effectiveVideo: VideoEffectiveParameters? = nil
        ) {
            self.url = url
            self.seed = seed
            self.mimeType = mimeType
            self.effective = effective
            self.effectiveVideo = effectiveVideo
        }

        init(_ image: GeneratedImage) {
            self.init(url: image.url, seed: image.seed, mimeType: nil, effective: image.effectiveParameters)
        }
    }

    /// A batch that failed after finishing some images.
    struct PartialBatch: Error {
        var produced: [Produced]
        var underlying: any Error
    }

    /// The step's words for an engine refusal that names a setting.
    static func stepError(_ error: Error, model: MediaModelCandidate) -> Error {
        guard case ImageGenerationError.memoryAdmission(let field, let bytes, let budget, let message) = error
        else { return error }
        let peak = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
        if let budget {
            let allowed = ByteCountFormatter.string(fromByteCount: budget, countStyle: .memory)
            return WorkflowSettingBlock(
                message: L("\(model.displayName) needs about \(peak) at its peak, but Server → Memory Safety (`\(field)`) allows \(allowed). Make fewer or smaller images, or change Memory Safety."),
                setting: "Server → Memory Safety", kind: "memory_admission")
        }
        return WorkflowSettingBlock(
            message: L("\(model.displayName) needs about \(peak) at its peak, which Server → Memory Safety does not allow (`\(field)`): \(message) Make fewer or smaller images, or change Memory Safety."),
            setting: "Server → Memory Safety", kind: "memory_admission")
    }

    /// Who a local job runs on behalf of. When the run's latest inference
    /// step left its model loaded, that model is the job's parent: the
    /// residency planner may swap it out and back (or keep it beside the
    /// job) instead of refusing it as somebody else's model. Otherwise the
    /// job has no parent, as before.
    static func invocation(context: WorkflowNodeContext, runtime: MediaNodeRuntime) async -> ModelJobInvocation {
        guard let model = context.residentParentModel, let resident = await runtime.residentLocalModel(model) else {
            return ModelJobInvocation(parentModelName: nil, source: nil)
        }
        return ModelJobInvocation(parentModelName: resident, source: context.caller.residencySource)
    }

    /// Runs one local job in the lane, keeping a failed batch's finished
    /// images.
    private static func laneJob(
        _ body: @escaping @Sendable () async throws -> NativeImageJobResult
    ) async throws -> NativeImageJobResult {
        do {
            return try await MediaJobLane.shared.run(body)
        } catch let partial as NativeImageJobPartialFailure {
            throw PartialBatch(produced: partial.images.map(Produced.init), underlying: partial.underlying)
        }
    }

    private static func runLocal(
        spec: MediaSpec, params: ResolvedMediaParameters, model: MediaModelCandidate, sources: [URL],
        context: WorkflowNodeContext, runtime: MediaNodeRuntime, logs: inout [String]
    ) async throws -> [Produced] {
        if spec.action == .video {
            return try await runLocalVideo(
                params: params, model: model, sources: sources, context: context, runtime: runtime, logs: &logs)
        }
        let q21 = ImageModelRequestPolicy.isQwen21Family(model.family)
        var width = params.width
        var height = params.height
        var steps = params.steps
        if !q21 && model.limits == nil {
            // Older families keep the image tool's envelope; say so when a
            // value moves rather than changing it quietly.
            let clamp: (Int?) -> Int? = { $0.map(HTTPHandler.clampImageDimension) }
            if clamp(width) != width || clamp(height) != height {
                logs.append(L("\(model.displayName) takes 256 to 1024 pixels in multiples of 16; the size became \(clamp(width) ?? 0)×\(clamp(height) ?? 0)."))
            }
            width = clamp(width)
            height = clamp(height)
            if let s = steps, HTTPHandler.clampImageSteps(s) != s {
                logs.append(L("\(model.displayName) takes 1 to 50 steps; steps became \(HTTPHandler.clampImageSteps(s))."))
                steps = HTTPHandler.clampImageSteps(s)
            }
        }
        let sourceData: [Data]
        do {
            sourceData = sources.isEmpty ? [] : try ImageSubagentKind.loadSourceImages(paths: sources.map(\.path))
        } catch {
            throw WorkflowNodeError.unsupported(String(describing: error))
        }
        if let limits = model.limits {
            try validate(
                spec.action, against: limits, model: model, params: params, width: width, height: height, steps: steps,
                sources: sourceData)
        } else if spec.action != .upscale,
            let key = [("sampler", params.sampler), ("scheduler", params.scheduler)].first(where: { $0.1 != nil })?.0
                ?? (params.shift != nil ? "shift" : nil)
        {
            throw WorkflowNodeError.unsupported(
                L("\(model.displayName) lists no sampler, scheduler, or shift choices, so `\(key)` cannot be set; remove it."))
        }
        if spec.action != .upscale {
            do {
                try ImageModelRequestPolicy(canonical: model.family).validate(
                    width: width, height: height, isEdit: spec.action == .edit,
                    guidance: Float(params.guidance ?? model.defaultGuidance.map(Double.init) ?? 1),
                    negativePrompt: params.negativePrompt, strength: params.strength.map(Float.init),
                    sourceCount: sourceData.count, steps: steps, outputFormat: params.format)
                if q21, spec.action == .edit { try ImageHTTPParameterBuilder.validateSourceImages(sourceData) }
            } catch {
                throw WorkflowNodeError.unsupported(String(describing: error))
            }
        }

        let progressKey = "workflow:\(context.runID.uuidString):\(context.node.id):\(UUID().uuidString)"
        var jobContext = NativeImageJobContext.current()
        jobContext.toolCallID = progressKey
        jobContext.trigger = .workflow
        jobContext.agentID = jobContext.agentID ?? context.caller.agentID
        jobContext.returnsPartialImages = true
        jobContext.invocation = await invocation(context: context, runtime: runtime)
        let interrupt = InterruptToken()
        let bridge = progressBridge(key: progressKey, context: context)
        defer { bridge?.cancel() }

        return try await withTaskCancellationHandler {
            switch spec.action {
            case .generate:
                // One job for every image: families that batch share the
                // prompt encoding; the others run the seeds in turn.
                let parallel = model.limits?.maximumParallelImages ?? 1
                if params.batchSize > parallel {
                    logs.append(
                        L("\(model.displayName) makes at most \(parallel) image(s) at once, so `batch_size` \(params.batchSize) ran as \(min(parallel, params.count))."))
                }
                let request = NativeImageGenerateJobRequest(
                    prompt: params.prompt, model: model.id, negativePrompt: params.negativePrompt,
                    width: width, height: height, steps: steps, guidance: params.guidance.map(Float.init),
                    seed: params.seed, numImages: params.count, seeds: params.seeds, batchSize: params.batchSize,
                    outputFormat: params.format, sampler: params.sampler, scheduler: params.scheduler,
                    shift: params.shift.map(Float.init), previewInterval: params.previewInterval, context: jobContext)
                let out = try await laneJob { try await runtime.generateLocal(request, interrupt) }.images
                    .map(Produced.init)
                logs += Self.adjustments(out, params: params)
                return out
            case .edit:
                let request = NativeImageEditJobRequest(
                    prompt: params.prompt, model: model.id, sourceImages: sourceData,
                    negativePrompt: params.negativePrompt, width: width, height: height, steps: steps,
                    guidance: params.guidance.map(Float.init), strength: params.strength.map(Float.init),
                    seed: params.seed, outputFormat: params.format, sampler: params.sampler,
                    scheduler: params.scheduler, shift: params.shift.map(Float.init),
                    previewInterval: params.previewInterval, context: jobContext)
                let out = try await laneJob { try await runtime.editLocal(request, interrupt) }.images
                    .map(Produced.init)
                logs += Self.adjustments(out, params: params)
                return out
            case .upscale:
                guard let source = sourceData.first else { return [] }
                let request = NativeImageUpscaleJobRequest(
                    model: model.id, sourceImage: source, scale: params.scale, steps: steps, seed: params.seed,
                    outputFormat: params.format, context: jobContext)
                let out = try await laneJob { try await runtime.upscaleLocal(request, interrupt) }.images
                    .map(Produced.init)
                logs += Self.adjustments(out, params: params)
                return out
            case .video:
                return []
            }
        } onCancel: {
            interrupt.interrupt()
        }
    }

    /// A video on this Mac: free, so no approval. The request is checked
    /// against the local video rules before the job unloads the chat model.
    private static func runLocalVideo(
        params: ResolvedMediaParameters, model: MediaModelCandidate, sources: [URL], context: WorkflowNodeContext,
        runtime: MediaNodeRuntime, logs: inout [String]
    ) async throws -> [Produced] {
        guard let media = model.media else {
            throw WorkflowNodeError.unsupported(L("\(model.displayName) is not a video model."))
        }
        let name = model.displayName
        if media.kind == .imageToVideo, sources.isEmpty {
            throw WorkflowNodeError.unsupported(L("\(name) animates a source image; set `sources` to one image."))
        }
        if media.kind == .textToVideo, !sources.isEmpty {
            throw WorkflowNodeError.unsupported(
                L("\(name) makes video from the prompt alone; remove `sources` or pick an image-to-video model."))
        }
        let source = try sources.first.map { url -> (Data, String) in
            (try Data(contentsOf: url, options: .mappedIfSafe), SharedArtifact.mimeType(from: url.lastPathComponent))
        }
        let c = media.constraints
        let duration: String
        if let d = params.duration {
            duration = d
        } else if let frames = params.frameCount {
            let fps = params.fps ?? LocalVideoRequestPolicy.defaultFPS
            duration = BindingRenderer.textValue(.number(Double(frames) / Double(max(1, fps))))
        } else {
            duration = c.durations.first ?? "3.0625s"
        }
        let request = MediaVideoGenerationRequest(
            target: media.target, prompt: params.prompt, negativePrompt: params.negativePrompt,
            sourceImage: source?.0, sourceImageMIMEType: source?.1, duration: duration,
            aspectRatio: params.aspectRatio ?? c.defaultAspectRatio, resolution: params.resolution ?? c.defaultResolution,
            audio: params.audio, width: params.width, height: params.height, frameCount: params.frameCount,
            fps: params.fps, steps: params.steps, guidance: params.guidance.map(Float.init), seed: params.seed)
        do {
            _ = try LocalVideoRequestPolicy(request)
        } catch {
            throw WorkflowNodeError.unsupported(L("\(name) refuses this video: \(WorkflowFailure.message(error))"))
        }

        var job = NativeImageJobContext.current()
        job.trigger = .workflow
        job.agentID = job.agentID ?? context.caller.agentID
        job.invocation = await invocation(context: context, runtime: runtime)
        let jobContext = job
        let interrupt = InterruptToken()
        let onProgress = context.onProgress
        let video = try await withTaskCancellationHandler {
            try await MediaJobLane.shared.run {
                try await runtime.generateLocalVideo(request, jobContext, interrupt) { event in
                    if let progress = Self.videoProgress(event) { onProgress?(progress) }
                }
            }
        } onCancel: {
            interrupt.interrupt()
        }
        if let e = video.effectiveVideo {
            logs.append(L("Made \(e.frameCount) frames at \(e.fps) fps, \(e.width)×\(e.height)."))
        }
        return [
            Produced(
                url: video.url, seed: video.effectiveVideo?.seed ?? params.seed, mimeType: video.mimeType,
                effectiveVideo: video.effectiveVideo)
        ]
    }

    static func videoProgress(_ event: MediaGenerationEvent) -> WorkflowNodeProgress? {
        switch event {
        case .queued: return WorkflowNodeProgress(fraction: nil, detail: L("Queued"))
        case .running(let fraction, let eta):
            var detail = L("Generating video")
            if let eta { detail += " · " + L("~\(Int(eta.rounded()))s left") }
            return WorkflowNodeProgress(fraction: fraction, detail: detail)
        default: return nil
        }
    }

    /// Checks the request against the engine's limits for this bundle before
    /// the job unloads the chat model, naming the step field it refuses.
    static func validate(
        _ action: MediaAction, against limits: ImageRequestLimits, model: MediaModelCandidate,
        params: ResolvedMediaParameters, width: Int?, height: Int?, steps: Int?, sources: [Data]
    ) throws {
        let steps = steps ?? model.defaultSteps ?? limits.fixedSteps ?? limits.minimumSteps
        let guidance = Float(params.guidance ?? model.defaultGuidance.map(Double.init) ?? 1)
        do {
            switch action {
            case .generate:
                // A family that does not batch runs one image per request.
                let batched = limits.maximumImages > 1
                try limits.validateGenerate(
                    width: width ?? 1024, height: height ?? 1024, steps: steps, guidance: guidance,
                    negativePrompt: params.negativePrompt, format: params.format,
                    numImages: batched ? params.count : 1, seeds: batched ? params.seeds : nil,
                    batchSize: params.batchSize, sampling: params.sampling)
            case .edit:
                try limits.validateEdit(
                    width: width, height: height, steps: steps, guidance: guidance, format: params.format,
                    sourceCount: sources.count, hasMask: false, strength: params.strength.map(Float.init),
                    sampling: params.sampling)
            case .upscale:
                guard let source = sources.first, let image = CGImageSourceCreateWithData(source as CFData, nil),
                    let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                    let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
                else { return }
                try ImageRequestLimits.validateUpscale(
                    canonical: model.family, sourceWidth: w, sourceHeight: h, scale: params.scale, format: params.format)
            case .video:
                return
            }
        } catch let refused as ImageRequestFieldError {
            let name = model.displayName
            let key = specKey(refused.field)
            let value = refused.value
            let allowed = refused.allowed
            throw WorkflowNodeError.unsupported(L("\(name) refuses `\(key)` = \(value): it takes \(allowed)."))
        }
    }

    /// The media step's name for an engine request field.
    static func specKey(_ engineField: String) -> String {
        switch engineField {
        case "outputFormat": return "format"
        case "negativePrompt": return "negative_prompt"
        case "sourceImages", "sourceImage": return "sources"
        case "dimensions": return "width × height"
        case "numImages": return "count"
        case "seeds": return "seed"
        case "batchSize": return "batch_size"
        case "previewInterval", "previewMaxPixel": return "preview_interval"
        default: return engineField
        }
    }

    /// One line per value the engine ran differently from what the step
    /// asked for (a fixed schedule, a rounded size), so the log says so.
    static func adjustments(_ produced: [Produced], params: ResolvedMediaParameters) -> [String] {
        guard let e = produced.first?.effective else { return [] }
        var out: [String] = []
        if let asked = params.steps, asked != e.steps {
            out.append(L("The model ran \(e.steps) steps; the step asked for \(asked)."))
        }
        if let w = params.width, let h = params.height, e.scale == nil, w != e.width || h != e.height {
            out.append(L("The model made \(e.width)×\(e.height); the step asked for \(w)×\(h)."))
        }
        if let asked = params.guidance, abs(Double(e.guidance) - asked) > 0.0001 {
            let ran = BindingRenderer.textValue(number(e.guidance))
            let wanted = BindingRenderer.textValue(.number(asked))
            out.append(L("The model ran guidance \(ran); the step asked for \(wanted)."))
        }
        return out
    }

    /// A Float as the JSON number a person typed (0.9, not 0.8999999762).
    static func number(_ value: Float) -> JSONValue { .number(Double("\(value)") ?? Double(value)) }

    /// The engine's report for one image, in the keys the image tool's
    /// result uses.
    static func json(_ e: ImageEffectiveParameters) -> JSONValue {
        var o: [String: JSONValue] = [
            "width": .number(Double(e.width)), "height": .number(Double(e.height)), "steps": .number(Double(e.steps)),
            "guidance": number(e.guidance), "seed": .number(Double(e.seed)),
        ]
        if let v = e.sampler { o["sampler"] = .string(v) }
        if let v = e.scheduler { o["scheduler"] = .string(v) }
        if let v = e.shift { o["shift"] = number(v) }
        if let v = e.strength { o["strength"] = number(v) }
        if let v = e.scale { o["scale"] = .number(Double(v)) }
        if let v = e.modelRevision { o["modelRevision"] = .string(v) }
        if let v = e.sampleSigmas { o["sampleSigmas"] = .array(v.map(number)) }
        return .object(o)
    }

    /// The engine's report for one local video, in the step's keys.
    static func json(_ e: VideoEffectiveParameters) -> JSONValue {
        var o: [String: JSONValue] = [
            "width": .number(Double(e.width)), "height": .number(Double(e.height)),
            "frame_count": .number(Double(e.frameCount)), "fps": .number(Double(e.fps)),
            "steps": .number(Double(e.steps)), "guidance": number(e.guidance), "seed": .number(Double(e.seed)),
        ]
        if let v = e.sampler { o["sampler"] = .string(v) }
        if let v = e.scheduler { o["scheduler"] = .string(v) }
        if let v = e.shift { o["shift"] = number(v) }
        return .object(o)
    }

    /// Image job progress (posted on the main thread) into the step's
    /// live progress.
    /// The latest preview stays on the step until the job leaves the
    /// generating phase.
    private static func progressBridge(key: String, context: WorkflowNodeContext) -> AnyCancellable? {
        guard let onProgress = context.onProgress else { return nil }
        var preview: Data?
        return NotificationCenter.default
            .publisher(for: NativeImageJobProgressCenter.notificationName)
            .compactMap { $0.object as? NativeImageJobProgress }
            .filter { $0.toolCallID == key }
            .sink { progress in onProgress(Self.progress(progress, keeping: &preview)) }
    }

    /// `progress(_:)` carrying the latest preview across step reports.
    static func progress(_ p: NativeImageJobProgress, keeping preview: inout Data?) -> WorkflowNodeProgress {
        if let png = p.previewPNG { preview = png }
        if p.phase != .generating { preview = nil }
        var out = progress(p)
        out.previewPNG = preview
        return out
    }

    static func progress(_ p: NativeImageJobProgress) -> WorkflowNodeProgress {
        switch p.phase {
        case .queued: return WorkflowNodeProgress(fraction: nil, detail: L("Queued"))
        case .waitingForChatIdle: return WorkflowNodeProgress(fraction: nil, detail: L("Waiting for chat to finish"))
        case .unloadingChatModels: return WorkflowNodeProgress(fraction: nil, detail: L("Making room in memory"))
        case .loadingModel: return WorkflowNodeProgress(fraction: nil, detail: L("Loading \(p.model ?? L("the model"))"))
        case .generating:
            guard let step = p.step, let total = p.total, total > 0 else {
                return WorkflowNodeProgress(fraction: nil, detail: L("Generating"))
            }
            var detail = L("Image step \(step) of \(total)")
            if let eta = p.etaSeconds, eta > 0 { detail += " · " + L("~\(Int(eta.rounded()))s left") }
            return WorkflowNodeProgress(fraction: Double(step) / Double(total), detail: detail)
        case .unloading: return WorkflowNodeProgress(fraction: 1, detail: L("Unloading the image model"))
        case .restoringChatModels: return WorkflowNodeProgress(fraction: 1, detail: L("Restoring chat models"))
        case .completed: return WorkflowNodeProgress(fraction: 1, detail: L("Done"))
        case .failed: return WorkflowNodeProgress(fraction: nil, detail: p.message ?? L("Failed"))
        case .cancelled: return WorkflowNodeProgress(fraction: nil, detail: L("Cancelled"))
        }
    }

    // MARK: - Remote

    private static func runRemote(
        spec: MediaSpec, params: ResolvedMediaParameters, model: MediaModelCandidate, sources: [URL],
        context: WorkflowNodeContext, runtime: MediaNodeRuntime, logs: inout [String]
    ) async throws -> [Produced] {
        guard let media = model.media else {
            throw WorkflowNodeError.unsupported(L("\(model.displayName) is not a provider model."))
        }
        let c = media.constraints
        let localOnly = [
            ("sampler", params.sampler != nil), ("scheduler", params.scheduler != nil), ("shift", params.shift != nil),
            ("batch_size", params.batchSize > 1), ("preview_interval", params.previewInterval != nil),
            ("frame_count", params.frameCount != nil), ("fps", params.fps != nil),
        ].filter(\.1).map { "`\($0.0)`" }
        if !localOnly.isEmpty {
            logs.append(
                L("\(media.displayName) runs at a provider, which does not take \(localOnly.joined(separator: ", ")); they were not sent."))
        }
        var approval: [String: JSONValue] = [
            "workflow": .string(context.workflowName), "step": .string(context.node.name),
            "model": .string(media.displayName), "provider": .string(media.providerName),
            "prompt": .string(params.prompt),
        ]
        switch spec.action {
        case .generate:
            let pixel = c.aspectRatios.isEmpty && c.resolutions.isEmpty
            if !pixel, params.width != nil || params.height != nil {
                logs.append(L("\(media.displayName) sizes images by aspect ratio and resolution, so width and height were not sent."))
            }
            let request = MediaImageGenerationRequest(
                target: media.target, prompt: params.prompt, negativePrompt: params.negativePrompt,
                width: pixel ? params.width : nil, height: pixel ? params.height : nil,
                aspectRatio: params.aspectRatio ?? c.defaultAspectRatio ?? c.aspectRatios.first,
                resolution: params.resolution ?? c.defaultResolution ?? c.resolutions.first,
                quality: c.defaultQuality ?? c.qualities.first, steps: params.steps, guidance: params.guidance,
                seed: Int(exactly: params.seed), count: params.count, format: params.format)
            approval["count"] = .number(Double(params.count))
            if let minimum = media.pricing?.minimumUSD { approval["estimated_minimum_usd"] = .number(minimum * Double(params.count)) }
            try requireApproval(
                await runtime.approveRemote("image", context.caller, JSONValue.object(approval).compactJSONString),
                tool: "image")
            let made = try await runtime.generateRemoteImage(request)
            if let cost = made.compactMap(\.settledCostUSD).reduce(nil, { ($0 ?? 0) + $1 }) {
                logs.append(L("Provider charged \(OsaurusRouter.formatUSDAsCredits(cost))."))
            }
            return made.map { Produced(url: $0.url, seed: nil, mimeType: $0.mimeType) }
        case .video:
            if let duration = params.duration, !c.durations.isEmpty, !c.durations.contains(duration) {
                throw WorkflowNodeError.unsupported(
                    L("\(media.displayName) takes durations \(c.durations.joined(separator: ", ")), not \(duration)."))
            }
            let source = try sources.first.map { url -> (Data, String) in
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let mime = SharedArtifact.mimeType(from: url.lastPathComponent)
                return (data, mime)
            }
            let request = MediaVideoGenerationRequest(
                target: media.target, prompt: params.prompt, negativePrompt: params.negativePrompt,
                sourceImage: source?.0, sourceImageMIMEType: source?.1,
                duration: params.duration ?? c.durations.first ?? "5",
                aspectRatio: params.aspectRatio ?? c.defaultAspectRatio,
                resolution: params.resolution ?? c.defaultResolution, audio: params.audio)
            let quote = try await runtime.quoteVideo(request)
            approval["quote_usd"] = .number(quote.usd)
            logs.append(L("Quoted \(OsaurusRouter.formatUSDAsCredits(quote.usd))."))
            try requireApproval(
                await runtime.approveRemote("video", context.caller, JSONValue.object(approval).compactJSONString),
                tool: "video")
            let onProgress = context.onProgress
            let video = try await runtime.generateVideo(request, quote) { event in
                if case .queued = event {
                    onProgress?(WorkflowNodeProgress(fraction: nil, detail: L("Queued at the provider")))
                } else if let progress = Self.videoProgress(event) {
                    onProgress?(progress)
                }
            }
            return [Produced(url: video.url, seed: nil, mimeType: video.mimeType)]
        case .edit, .upscale:
            throw WorkflowNodeError.unsupported(L("Image \(spec.action.rawValue) runs on this Mac, not on a provider."))
        }
    }

    private static func requireApproval(_ approval: MediaRemoteApproval, tool: String) throws {
        switch approval {
        case .approved: return
        case .denied:
            throw WorkflowNodeError.unsupported(
                tool == "video"
                    ? L("The quoted video job was not approved.") : L("The billable image job was not approved."))
        case .nobodyToAsk:
            throw WorkflowNodeError.unsupported(
                tool == "video"
                    ? L("Nobody is watching this run to approve a billable video job. Set the agent's Video permission to Always Allow to make videos in unattended runs.")
                    : L("Nobody is watching this run to approve a billable image job. Set the agent's Image permission to Always Allow to use a provider in unattended runs."))
        }
    }

    // MARK: - Saving

    struct Saved {
        var artifact: WorkflowArtifact
        var outputValue: JSONValue
        var isVideo: Bool
    }

    /// Copies each file into the run's files (PNG gets the settings in its
    /// text chunks, like other image tools write), and describes it.
    static func save(
        _ produced: [Produced], spec: MediaSpec, params: ResolvedMediaParameters, model: MediaModelCandidate,
        context: WorkflowNodeContext
    ) throws -> [Saved] {
        let dir = OsaurusPaths.workflowRunArtifacts(workflowID: context.workflowID, runID: context.runID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stepID = context.node.id.hasSuffix(".item") ? String(context.node.id.dropLast(".item".count)) : context.node.id
        let itemTag = context.bindings.index.map { "-\($0 + 1)" } ?? ""
        let tag = String(UUID().uuidString.prefix(6)).lowercased()

        return try produced.enumerated().map { offset, item in
            let ext = item.url.pathExtension.isEmpty ? params.format.rawValue : item.url.pathExtension.lowercased()
            let seedTag = item.seed.map { "-s\($0)" } ?? ""
            let filename = "\(stepID)\(itemTag)-\(offset + 1)\(seedTag)-\(tag).\(ext)"
            let dest = dir.appendingPathComponent(filename)
            var metadata = settings(
                spec: spec, params: params, model: model, seed: item.seed, effective: item.effective,
                effectiveVideo: item.effectiveVideo)
            metadata["node_id"] = .string(stepID)
            if let index = context.bindings.index { metadata["item_index"] = .number(Double(index)) }
            let mime = item.mimeType ?? SharedArtifact.mimeType(from: filename)
            let isVideo = mime.hasPrefix("video/")
            let size = isVideo ? nil : pixelSize(item.url)
            if let (w, h) = size {
                metadata["width"] = .number(Double(w))
                metadata["height"] = .number(Double(h))
            }
            if ext == "png", !isVideo {
                if !writePNG(from: item.url, to: dest, metadata: metadata) {
                    try copyReplacing(item.url, to: dest)
                }
            } else {
                try copyReplacing(item.url, to: dest)
            }
            discardOriginal(item.url)
            let bytes = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var value: [String: JSONValue] = [
                "path": .string(dest.path), "url": .string(dest.absoluteString),
            ]
            if isVideo {
                value["mime_type"] = .string(mime)
                if let e = item.effectiveVideo { value["effective_parameters"] = json(e) }
            } else {
                if let seed = item.seed { value["seed"] = .number(Double(seed)) }
                if let (w, h) = size {
                    value["width"] = .number(Double(w))
                    value["height"] = .number(Double(h))
                }
                value["format"] = .string(ext)
                if let effective = item.effective { value["effective_parameters"] = json(effective) }
            }
            let artifact = WorkflowArtifact(
                source: .generated, nodeID: stepID, filename: filename, mimeType: mime, path: dest.path,
                fileSize: bytes, description: params.prompt.isEmpty ? nil : String(params.prompt.prefix(200)),
                metadata: metadata)
            return Saved(artifact: artifact, outputValue: .object(value), isVideo: isVideo)
        }
    }

    /// The settings that made one file, enough to make it again. With the
    /// engine's report (`parameters: effective`) the values are what ran,
    /// and a value the step asked for differently is kept as `requested_*`;
    /// without it (`parameters: requested`) they are what was asked for.
    static func settings(
        spec: MediaSpec, params: ResolvedMediaParameters, model: MediaModelCandidate, seed: UInt64?,
        effective: ImageEffectiveParameters? = nil, effectiveVideo: VideoEffectiveParameters? = nil
    ) -> [String: JSONValue] {
        var m: [String: JSONValue] = [
            "action": .string(spec.action.rawValue),
            "model": .string(model.displayName),
            "model_id": .string(model.target.modelID),
            "backend": .string(model.isLocal ? "local" : "remote"),
            "seed_mode": .string(params.seedMode.rawValue),
            "format": .string(params.format.rawValue),
            "parameters": .string(effective == nil && effectiveVideo == nil ? "requested" : "effective"),
        ]
        if let family = model.family { m["family"] = .string(family) }
        if !params.prompt.isEmpty { m["prompt"] = .string(params.prompt) }
        if let v = params.negativePrompt { m["negative_prompt"] = .string(v) }
        if let e = effective {
            m["seed"] = .number(Double(e.seed))
            m["steps"] = .number(Double(e.steps))
            if let asked = params.steps, asked != e.steps { m["requested_steps"] = .number(Double(asked)) }
            m["guidance"] = number(e.guidance)
            if let asked = params.guidance, abs(Double(e.guidance) - asked) > 0.0001 {
                m["requested_guidance"] = .number(asked)
            }
            if spec.action != .upscale {
                if let asked = params.width, asked != e.width { m["requested_width"] = .number(Double(asked)) }
                if let asked = params.height, asked != e.height { m["requested_height"] = .number(Double(asked)) }
            }
            if spec.action == .edit, let v = e.strength.map(number) ?? params.strength.map(JSONValue.number) {
                m["strength"] = v
            }
            if spec.action == .upscale { m["scale"] = .number(Double(e.scale ?? params.scale)) }
            recordSampling(e.sampler, e.scheduler, e.shift, params: params, into: &m)
            if let v = e.modelRevision { m["model_revision"] = .string(v) }
            if let v = e.sampleSigmas { m["sample_sigmas"] = .array(v.map(number)) }
        } else if let e = effectiveVideo {
            m["seed"] = .number(Double(e.seed))
            m["width"] = .number(Double(e.width))
            m["height"] = .number(Double(e.height))
            m["frame_count"] = .number(Double(e.frameCount))
            m["fps"] = .number(Double(e.fps))
            m["steps"] = .number(Double(e.steps))
            m["guidance"] = number(e.guidance)
            if let asked = params.steps, asked != e.steps { m["requested_steps"] = .number(Double(asked)) }
            if let asked = params.guidance, abs(Double(e.guidance) - asked) > 0.0001 {
                m["requested_guidance"] = .number(asked)
            }
            if let asked = params.width, asked != e.width { m["requested_width"] = .number(Double(asked)) }
            if let asked = params.height, asked != e.height { m["requested_height"] = .number(Double(asked)) }
            if let asked = params.frameCount, asked != e.frameCount {
                m["requested_frame_count"] = .number(Double(asked))
            }
            if let asked = params.fps, asked != e.fps { m["requested_fps"] = .number(Double(asked)) }
            recordSampling(e.sampler, e.scheduler, e.shift, params: params, into: &m)
        } else {
            if let v = seed { m["seed"] = .number(Double(v)) }
            if let v = params.steps ?? model.defaultSteps { m["steps"] = .number(Double(v)) }
            if let v = params.guidance ?? model.defaultGuidance.map(Double.init) { m["guidance"] = .number(v) }
            if spec.action == .edit, let v = params.strength { m["strength"] = .number(v) }
            if spec.action == .upscale { m["scale"] = .number(Double(params.scale)) }
            if let v = params.sampler { m["sampler"] = .string(v) }
            if let v = params.scheduler { m["scheduler"] = .string(v) }
            if let v = params.shift { m["shift"] = .number(v) }
            if spec.action == .video {
                if let v = params.frameCount { m["frame_count"] = .number(Double(v)) }
                if let v = params.fps { m["fps"] = .number(Double(v)) }
            }
        }
        if spec.action == .video {
            if let v = params.duration { m["duration"] = .string(v) }
            if let v = params.resolution { m["resolution"] = .string(v) }
            if let v = params.aspectRatio { m["aspect_ratio"] = .string(v) }
        }
        if !params.sources.isEmpty { m["sources"] = .array(params.sources.map(JSONValue.string)) }
        return m
    }

    /// What the engine sampled with, and what the step asked for when that
    /// differs.
    private static func recordSampling(
        _ sampler: String?, _ scheduler: String?, _ shift: Float?, params: ResolvedMediaParameters,
        into m: inout [String: JSONValue]
    ) {
        if let v = sampler { m["sampler"] = .string(v) }
        if let v = scheduler { m["scheduler"] = .string(v) }
        if let v = shift { m["shift"] = number(v) }
        if let asked = params.sampler, asked != sampler { m["requested_sampler"] = .string(asked) }
        if let asked = params.scheduler, asked != scheduler { m["requested_scheduler"] = .string(asked) }
        if let asked = params.shift, shift.map({ abs(Double($0) - asked) > 0.0001 }) ?? true {
            m["requested_shift"] = .number(asked)
        }
    }

    /// The job's own copy in the shared generated-images folder; the run's
    /// copy is the one every output points at. Files elsewhere (a source
    /// the step was handed) are never touched.
    static func discardOriginal(_ url: URL) {
        let folder = OsaurusPaths.generatedImages().standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(folder) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func copyReplacing(_ from: URL, to dest: URL) throws {
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: from, to: dest)
    }

    /// Re-writes a PNG with the settings in its Description text chunk.
    /// PNG is lossless, so the pixels are unchanged.
    static func writePNG(from source: URL, to dest: URL, metadata: [String: JSONValue]) -> Bool {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
            let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        let png: [CFString: Any] = [
            kCGImagePropertyPNGDescription: JSONValue.object(metadata).compactJSONString,
            kCGImagePropertyPNGSoftware: "Osaurus",
            kCGImagePropertyPNGTitle: (metadata["prompt"]?.stringValue).map { String($0.prefix(200)) } ?? "",
        ]
        CGImageDestinationAddImageFromSource(out, src, 0, [kCGImagePropertyPNGDictionary: png] as CFDictionary)
        return CGImageDestinationFinalize(out)
    }

    /// The settings a PNG this step wrote carries, for "reuse settings".
    static func readPNGSettings(_ url: URL) -> [String: JSONValue]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any],
            let text = png[kCGImagePropertyPNGDescription] as? String,
            let data = text.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return value.objectValue
    }

    static func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }
}
