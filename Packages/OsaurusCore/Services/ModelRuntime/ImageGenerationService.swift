//
//  ImageGenerationService.swift
//  osaurus
//
//  Bridge between osaurus and the vendored native mFLUX image engine
//  (`vMLXFlux.FluxEngine`). This is the ONLY file that imports vMLXFlux —
//  the rest of the app talks to images through the osaurus-native types in
//  `ImageGenerationTypes.swift`.
//
//  Concurrency: image generation is a second MLX graph and races LLM token
//  generation on the shared Metal command buffer (the same hazard the
//  Model2Vec embedder hit — see MetalGate). Every GPU-touching call here is
//  wrapped in MetalGate's EXCLUSIVE image-generation lane, held across the
//  FULL engine event-stream drain (model load + every denoise step + the
//  terminal VAE decode) and released only once the engine stream finishes.
//
//  Cancellation is soft: the engine and its concrete models run their denoise
//  loops in unstructured `Task`s, so a cancel from our consuming task does not
//  propagate into the engine's GPU loop. We therefore keep draining the engine
//  stream to completion after a cancel (so the gate is never released while MLX
//  eval is still in flight) but suppress further client events and finish with
//  `.cancelled`.
//

import Foundation
import ImageIO
import MLX
import MLXLMCommon
import vMLXFlux

public actor ImageGenerationService {
    public static let shared = ImageGenerationService()

    /// Lazily-created single engine for the whole process (MLX ops are not
    /// thread-safe across one allocator; the engine is actor-isolated).
    private var engine: FluxEngine?
    /// Exact bundle directory name currently resident in the engine, for
    /// load-if-different.
    private var loadedDirectoryName: String?
    /// Bundle directory backing `loadedDirectoryName`, kept so the loaded-models
    /// UI can report a footprint without re-resolving through the store.
    private var loadedDirectoryURL: URL?
    /// One-time registry population (decentralized self-registration).
    private var registered = false
    /// Job ids that have been asked to cancel. Checked per event in the drain
    /// loop; the loop keeps consuming the engine stream to completion so the
    /// gate is never released mid-eval (soft cancel).
    private var cancelledJobIDs: Set<String> = []
    /// A stream can terminate before its non-cancellable producer drain. The
    /// coordinator joins this exact job before releasing its parent hold.
    private struct ProducerJob {
        let task: Task<Void, Never>
        let cancel: @Sendable () -> Void
    }
    private var producerJobs: [String: ProducerJob] = [:]

    /// Bundle metadata lookup/peak estimate, gate instance and GPU cleanup are replaceable.
    /// The production service and FluxEngine stream/drain implementations are
    /// used unchanged by no-model producer-lifetime tests.
    struct LoadTarget: Sendable {
        let info: ImageModelInfo
        let directory: URL
        let engineName: String
        let kind: ModelKind?
    }

    enum StreamCheckpoint: Sendable, Hashable {
        case created(Int), willDrain(Int), drained(Int)
    }
    private let testStreamCheckpoint: (@Sendable (StreamCheckpoint) async -> Void)?
    private let testErrorSince: (@Sendable (UInt64) -> String?)?
    private let metalGate: MetalGate
    private let cleanupGPUCache: @Sendable () -> Void
    private let testResolve: (@Sendable (String) throws -> LoadTarget)?
    private let testPeakEstimate: (@Sendable () throws -> Int64)?

    public init() {
        metalGate = .shared
        cleanupGPUCache = {
            MLXCacheIOLock.withSerializedMLXCacheIO {
                Memory.clearCache()
            }
        }
        testResolve = nil
        testPeakEstimate = nil
        testStreamCheckpoint = nil
        testErrorSince = nil
    }

    /// Internal, explicit fixture initializer. No singleton/global MLX state is
    /// changed. Only the injected cleanup callback may omit the GPU barrier.
    init(
        testingEngine: FluxEngine,
        gate: MetalGate,
        cleanup: @escaping @Sendable () -> Void,
        resolve: @escaping @Sendable (String) throws -> LoadTarget,
        peakEstimate: @escaping @Sendable () throws -> Int64,
        streamCheckpoint: (@Sendable (StreamCheckpoint) async -> Void)? = nil,
        errorSince: (@Sendable (UInt64) -> String?)? = nil
    ) {
        engine = testingEngine
        metalGate = gate
        cleanupGPUCache = cleanup
        testResolve = resolve
        testPeakEstimate = peakEstimate
        testStreamCheckpoint = streamCheckpoint
        testErrorSince = errorSince
        registered = true
    }

    /// Request cancellation of an in-flight job by id. Safe to call from any
    /// connection/actor; the matching drain loop stops yielding at the next
    /// event boundary and finishes with `.cancelled`.
    public func cancel(jobID: String) {
        cancelledJobIDs.insert(jobID)
        producerJobs[jobID]?.cancel()
    }

    func waitForJobDrain(jobID: String) async {
        await producerJobs[jobID]?.task.value
    }

    /// Release the resident image model after agent-triggered jobs or memory
    /// pressure handoffs. Manual image-panel flows may choose to keep the
    /// engine warm and skip this through `SubagentImageLoadPolicy`.
    /// What the loaded-models popover shows for the resident image model.
    /// Bytes are the bundle's on-disk size — for weight bundles that tracks the
    /// resident footprint closely enough for a memory-management affordance.
    public struct LoadedModelSummary: Sendable {
        public let name: String
        public let bytes: Int64
    }

    /// The resident image model, or nil when nothing is loaded.
    public func loadedModelSummary() -> LoadedModelSummary? {
        guard let name = loadedDirectoryName, let dir = loadedDirectoryURL else { return nil }
        var bytes: Int64 = 0
        if let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        {
            for case let file as URL in enumerator {
                bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return LoadedModelSummary(name: name, bytes: bytes)
    }

    public func unload() async {
        guard let engine else {
            loadedDirectoryName = nil
            loadedDirectoryURL = nil
            return
        }
        // Image-model teardown is a GPU producer (freeing the FLUX weights
        // enqueues Metal allocator frees/fences). Hold the exclusive image lane
        // across it and drain the device before releasing — symmetric with the
        // `drive()` exit barrier and the `ModelRuntime` teardown gate. The agent
        // image job calls this the instant generation finishes, immediately
        // before the chat-model `restore` (`ModelRuntime.preload` →
        // `enterModelLoad`); without the gate that reload starts while these
        // frees are still settling and races them on the shared Metal command
        // queue (the `MTLReleaseAssertionFailure` / `Gather::eval_gpu` class).
        //
        // Teardown uses the NON-cancellable teardown owner (any distinct
        // owner is exclusive against all others): once we decide to free the
        // FLUX weights, giving up mid-wait on cancellation would either leak
        // the engine or free buffers without the gate.
        await metalGate.enterModelTeardown(model: "image-unload")
        await engine.unload()
        loadedDirectoryName = nil
        loadedDirectoryURL = nil
        cleanupGPUCache()
        await metalGate.exitModelTeardown(model: "image-unload")
        // Same channel the LLM runtime uses; observers either guard-cast the
        // snapshot object (and skip this post) or refresh unconditionally —
        // the loaded-models popover is the latter.
        NotificationCenter.default.post(name: .modelRuntimeResidencyChanged, object: nil)
    }

    // MARK: - Model store root

    /// Root directory scanned for local image bundles. Resolution order:
    ///   1. `OSAURUS_IMAGE_MODELS_DIR` (explicit override / tests)
    ///   2. first **populated** candidate among:
    ///        - `<effective models dir>/image` (the user-chosen LLM volume)
    ///        - `~/models/image` (common manual layout — same SSD volume)
    ///        - `~/.mlxstudio/models/image` (legacy engine default)
    ///   3. else `<effective models dir>/image` (where downloads land).
    ///
    /// Picking the first *populated* candidate keeps scan + load consistent
    /// (a single root) while finding manually-placed bundles under
    /// `~/models/image` without requiring an `OSAURUS_IMAGE_MODELS_DIR` env or
    /// a custom models-dir bookmark. Image weights must stay on an
    /// SSD-resident volume (USB weights trip the GPU watchdog on first
    /// forward); all candidates here are internal-volume paths.
    /// Memoized resolution, keyed on the effective models directory. The
    /// candidate probing below lists up to three directories on disk, and
    /// callers include @MainActor services (download bookkeeping, picker
    /// cache) — under I/O pressure a fresh scan per call is an observed UI
    /// hang. The key invalidates the cache when the user picks a new models
    /// directory; bundle additions land in the resolved root itself, so a
    /// stale "populated candidate" answer cannot point downloads elsewhere.
    private static let rootCacheLock = NSLock()
    nonisolated(unsafe) private static var rootCache: (key: String, url: URL)?

    public static func imageModelsRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["OSAURUS_IMAGE_MODELS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let fm = FileManager.default
        func holdsBundles(_ url: URL) -> Bool {
            guard
                let items = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { return false }
            return items.contains {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        }
        let osaurusImageDir = DirectoryPickerService.effectiveModelsDirectory()
            .appendingPathComponent("image", isDirectory: true)

        let cacheKey = osaurusImageDir.path
        rootCacheLock.lock()
        if let cached = rootCache, cached.key == cacheKey {
            rootCacheLock.unlock()
            return cached.url
        }
        rootCacheLock.unlock()

        let userModelsImageDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("image", isDirectory: true)
        let legacy = MLXStudioModelStore.defaultImageRoot
        var resolved = osaurusImageDir
        for candidate in [osaurusImageDir, userModelsImageDir, legacy] where holdsBundles(candidate) {
            resolved = candidate
            break
        }
        rootCacheLock.lock()
        rootCache = (key: cacheKey, url: resolved)
        rootCacheLock.unlock()
        return resolved
    }

    private func store() -> MLXStudioModelStore {
        MLXStudioModelStore(root: Self.imageModelsRoot())
    }

    private func ensureRegistered() {
        guard !registered else { return }
        VMLXFluxModels.registerAll()
        VMLXFluxVideo.registerAll()
        registered = true
    }

    private func ensureEngine() -> FluxEngine {
        if let engine { return engine }
        let created = FluxEngine()
        engine = created
        return created
    }

    // MARK: - Catalog

    /// Scan the image models root and return catalog entries. Reflects raw
    /// on-disk facts; manifest-driven exposure (hiding unproven variants) is
    /// applied by the catalog layer on top of this.
    public func availableModels() throws -> [ImageModelInfo] {
        ensureRegistered()
        let locals = try store().scan()
        return locals.map { Self.info(for: $0) }
    }

    func availableVideoModels() throws -> [MediaModelInfo] {
        ensureRegistered()
        return try store().scan().compactMap { local in
            guard local.canEnterNativeLoadPath, local.canonicalName == "wan-2.1",
                let data = try? Data(contentsOf: local.directory.appendingPathComponent("config.json")),
                let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = config["model_type"] as? String, ["t2v", "i2v"].contains(type) else { return nil }
            return MediaModelInfo(target: MediaModelTarget(backend: .local, modelID: local.directoryName),
                displayName: local.directoryName, providerName: "Local (MLX)",
                kind: type == "i2v" ? .imageToVideo : .textToVideo,
                constraints: MediaModelConstraints(aspectRatios: ["16:9", "9:16", "1:1"],
                    defaultAspectRatio: "16:9", resolutions: ["480p", "720p"], defaultResolution: "480p",
                    durations: ["3.0625s", "5.0625s"], defaultSteps: 50, dimensionDivisor: 16),
                pricing: nil, privacy: "Runs on this Mac", offline: false, deprecatedAt: nil)
        }
    }

    func validateVideo(_ request: MediaVideoGenerationRequest) throws -> ImageModelInfo {
        _ = try LocalVideoRequestPolicy(request)
        let target = try resolveLoadTarget(request.target.modelID)
        guard target.info.ready, target.kind == .videoGen, target.engineName == "wan-2.1" else {
            throw ImageGenerationError.invalidRequest("A complete native Wan 2.1 bundle is required.")
        }
        let data = try Data(contentsOf: target.directory.appendingPathComponent("config.json"))
        let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (config?["model_type"] as? String == "i2v") == (request.sourceImage != nil) else {
            throw ImageGenerationError.invalidRequest("The source image must match the bundle's text-to-video or image-to-video operation.")
        }
        if let source = request.sourceImage { try ImageHTTPParameterBuilder.validateSourceImages([source]) }
        return target.info
    }

    /// One native producer owns the Metal lane until every GPU operation drains,
    /// including after cancellation. Callers own the shared chat residency handoff.
    func generateVideo(_ request: MediaVideoGenerationRequest, interrupt: InterruptToken?,
                       progress: @escaping @Sendable (MediaGenerationEvent) -> Void) async throws -> GeneratedMedia {
        let resolved = try LocalVideoRequestPolicy(request)
        _ = try validateVideo(request)
        let stop = FluxInterrupt()
        let cancellation = ImageJobCancellation { try await self.metalGate.enterImageGeneration() }
        let producer = Task {
            try await cancellation.enter()
            self.cleanupGPUCache()
            let epoch = MLXErrorRecovery.errorSequence()
            var produced: URL?
            var effectiveVideo: VideoEffectiveParameters?
            var stagedSource: URL?
            do {
                if cancellation.isRequested || interrupt?.isInterrupted == true { throw CancellationError() }
                _ = try await self.ensureLoaded(request.target.modelID, expected: .videoGen,
                    resolvedTarget: nil, validate: { _, _ in })
                if cancellation.isRequested || interrupt?.isInterrupted == true { throw CancellationError() }
                stagedSource = try request.sourceImage.map(Self.stageInput)
                let output = OsaurusPaths.generatedVideos()
                OsaurusPaths.ensureExistsSilent(output)
                let engine = self.ensureEngine()
                let job = VideoGenRequest(prompt: request.prompt, negativePrompt: request.negativePrompt,
                    width: resolved.width, height: resolved.height, numFrames: resolved.frames,
                    fps: resolved.fps, steps: resolved.steps, guidance: resolved.guidance,
                    seed: request.seed, outputDir: output, sourceImage: stagedSource, interrupt: stop)
                var failure: String?
                for try await event in await engine.generateVideo(job, interrupt: stop) {
                    if cancellation.isRequested || interrupt?.isInterrupted == true { stop.cancel() }
                    switch event {
                    case .step(let step, let total, let eta):
                        if !stop.isCancelled { progress(.running(progress: total > 0 ? Double(step) / Double(total) : nil, etaSeconds: eta)) }
                    case .completed(let url, let seed, let fps, let frames, let effective):
                        produced = url
                        if let effective {
                            effectiveVideo = VideoEffectiveParameters(width: effective.width, height: effective.height,
                                frameCount: frames, fps: fps, steps: effective.steps, guidance: effective.guidance,
                                seed: seed, sampler: effective.sampler, scheduler: effective.scheduler, shift: effective.shift)
                        }
                    case .cancelled: stop.cancel()
                    case .failed(let message, _): failure = message
                    case .preview: break
                    }
                }
                if let error = self.recoveredErrorSince(epoch) { throw ImageGenerationError.engine(error) }
                if stop.isCancelled || cancellation.isRequested { throw CancellationError() }
                if let failure { throw ImageGenerationError.engine(failure) }
                guard let produced else { throw MediaGenerationError.invalidResponse }
                if let stagedSource { try? FileManager.default.removeItem(at: stagedSource) }
                self.cleanupGPUCache()
                await self.metalGate.exitImageGeneration()
                let media = GeneratedMedia(url: produced, mimeType: "video/mp4", modelID: request.target.modelID,
                    kind: request.sourceImage == nil ? .textToVideo : .imageToVideo, settledCostUSD: 0,
                    effectiveVideo: effectiveVideo)
                progress(.completed(media))
                return media
            } catch {
                if let produced { try? FileManager.default.removeItem(at: produced) }
                if let stagedSource { try? FileManager.default.removeItem(at: stagedSource) }
                self.cleanupGPUCache()
                await self.metalGate.exitImageGeneration()
                if self.recoveredErrorSince(epoch) != nil { await self.unload() }
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await producer.value
        } onCancel: {
            stop.cancel()
            cancellation.cancel()
        }
    }

    static func info(for local: LocalFluxModel) -> ImageModelInfo {
        let kind = local.kind ?? .imageGen
        let entry = local.canonicalName.flatMap { ModelRegistry.lookup(name: $0) }
        let limits = try? entry?.limits?(local.directory)
        return ImageModelInfo(
            id: local.directoryName,
            canonicalName: local.canonicalName,
            displayName: local.displayName,
            kind: kind.rawValue,
            ready: local.canEnterNativeLoadPath,
            quantizationBits: local.quantizationBits,
            defaultSteps: entry?.defaultSteps,
            defaultGuidance: entry?.defaultGuidance,
            capabilities: capabilities(kind: kind, canonical: local.canonicalName, entry: entry),
            blockedReasons: local.blockedReasons,
            totalBytes: local.totalBytes,
            requestLimits: limits.map {
                ImageRequestLimits(minimumSteps: $0.minimumSteps, maximumSteps: $0.maximumSteps,
                    fixedSteps: $0.fixedSteps, dimensionMultiple: $0.dimensionMultiple,
                    minimumDimension: $0.minDimension, maximumDimension: $0.maxDimension,
                    maximumPixels: $0.maxPixels, maximumImages: $0.maximumImages,
                    maximumSourceImages: $0.maxSourceImages, formats: $0.supportedFormats.map(\.rawValue),
                    samplers: $0.samplers, schedulers: $0.schedulers)
            }
        )
    }

    static func capabilities(
        kind: ModelKind,
        canonical: String?,
        entry: ModelEntry?
    ) -> ImageModelCapabilities {
        ImageModelRequestPolicy.capabilities(
            kind: kind.rawValue, canonical: canonical, supportsLoRA: entry?.supportsLoRA ?? false
        )
    }

    // MARK: - Generate / edit / upscale

    // The HTTP factory resolves one exact store target, then passes that SAME
    // target into the existing gated load/validate path. No second lookup,
    // preflight weight load, or residency change is introduced.
    func generateHTTP(_ request: ImageGenerationRequestDTO, modelID: String, jobID: String)
        -> ImageHTTPPreparedJob
    {
        do {
            let target = try resolveLoadTarget(modelID)
            let params = try ImageHTTPParameterBuilder.generation(request, info: target.info)
            return ImageHTTPPreparedJob(stream: generate(params, jobID: jobID, resolvedTarget: target),
                width: params.width ?? 1024, height: params.height ?? 1024)
        } catch {
            return .failure(Self.message(for: error))
        }
    }

    func editHTTP(_ request: ImageEditRequestDTO, modelID: String, decodedSources: [Data?], jobID: String)
        -> ImageHTTPPreparedJob
    {
        do {
            let target = try resolveLoadTarget(modelID)
            let params = try ImageHTTPParameterBuilder.edit(request, info: target.info,
                decodedSources: decodedSources)
            return ImageHTTPPreparedJob(stream: edit(params, jobID: jobID, resolvedTarget: target),
                width: params.width, height: params.height, sourceCount: params.sourceImages.count)
        } catch {
            return .failure(Self.message(for: error))
        }
    }

    /// Metadata-only request estimate. No weights or GPU lease are acquired.
    /// Keep the request builder shared with execution so admission sees the
    /// actual defaults, batch and preview settings.
    func estimatedPeakBytes(for params: ImageGenerationParameters) async throws -> Int64 {
        if let testPeakEstimate { return try testPeakEstimate() }
        let target = try resolveLoadTarget(params.model)
        let request = Self.generationRequest(params, info: target.info, index: 0,
            outputDir: OsaurusPaths.generatedImages(), nativeBatch: true)
        let query = engine ?? FluxEngine()
        return Int64(try await query.estimatedPeakBytes(for: request,
            modelURL: target.directory, name: target.engineName))
    }

    func estimatedPeakBytes(for params: ImageEditParameters, resolvedTarget: LoadTarget? = nil) async throws -> Int64 {
        let target = try resolvedTarget ?? resolveLoadTarget(params.model)
        let limits = try ModelRegistry.lookup(name: target.engineName)?.limits?(target.directory)
        // Validate app-only fields before the caller admits the job or unloads
        // its parent. ImageEditRequest cannot carry negative conditioning.
        try Self.validateEdit(params, info: target.info, limits: limits)
        if let testPeakEstimate { return try testPeakEstimate() }
        let sources = try Self.stageInputs(params.sourceImages)
        defer { for source in sources { try? FileManager.default.removeItem(at: source) } }
        let mask = try params.maskImage.map(Self.stageInput)
        defer { if let mask { try? FileManager.default.removeItem(at: mask) } }
        let request = try Self.editRequest(params, info: target.info, sources: sources,
            mask: mask, outputDir: OsaurusPaths.generatedImages())
        let query = engine ?? FluxEngine()
        return Int64(try await query.estimatedPeakBytes(for: request,
            modelURL: target.directory, name: target.engineName))
    }

    func estimatedPeakBytes(for params: ImageUpscaleParameters) async throws -> Int64 {
        if let testPeakEstimate { return try testPeakEstimate() }
        let target = try resolveLoadTarget(params.model)
        let source = try Self.stageInput(params.sourceImage)
        defer { try? FileManager.default.removeItem(at: source) }
        let request = UpscaleRequest(sourceImage: source, scale: params.scale,
            steps: params.steps ?? 1, seed: params.seed, outputDir: OsaurusPaths.generatedImages(),
            outputFormat: Self.engineFormat(params.outputFormat))
        let query = engine ?? FluxEngine()
        return Int64(try await query.estimatedPeakBytes(for: request,
            modelURL: target.directory, name: target.engineName))
    }

    public func generate(
        _ params: ImageGenerationParameters,
        jobID: String? = nil,
        interrupt: InterruptToken? = nil
    ) -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        generate(params, jobID: jobID, resolvedTarget: nil, interrupt: interrupt)
    }

    private func generate(
        _ params: ImageGenerationParameters, jobID: String?, resolvedTarget: LoadTarget?, interrupt: InterruptToken? = nil
    ) -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        let producerInterrupt = FluxInterrupt()
        return drive(
            model: params.model, expected: .imageGen, jobID: jobID, resolvedTarget: resolvedTarget, interrupt: interrupt,
            producerInterrupt: producerInterrupt, count: params.numImages,
            estimatePeak: { try await self.estimatedPeakBytes(for: params) }, validate: { info, limits in
                guard (1...8).contains(params.numImages) else {
                    throw ImageGenerationError.invalidRequest("numImages must be between 1 and 8")
                }
                let batchRequest = Self.generationRequest(params, info: info, index: 0,
                    outputDir: OsaurusPaths.generatedImages(), nativeBatch: true)
                try ImageBatchPlan.validate(batchRequest, maximumImages: 8)
                if limits == nil {
                    try ImageModelRequestPolicy(canonical: info.canonicalName).validate(
                    width: params.width, height: params.height, isEdit: false,
                    guidance: params.guidance ?? info.defaultGuidance ?? 3.5,
                    negativePrompt: params.negativePrompt, steps: params.steps ?? info.defaultSteps,
                    outputFormat: params.outputFormat
                )
                }
                let nativeBatch = (limits?.maximumImages ?? 1) > 1
                try limits?.validate(Self.generationRequest(params, info: info, index: 0,
                    outputDir: OsaurusPaths.generatedImages(), nativeBatch: nativeBatch))
            }
        ) { engine, outputDir, index, info, nativeBatch in
            var request = Self.generationRequest(params, info: info, index: index, outputDir: outputDir, nativeBatch: nativeBatch)
            request.interrupt = producerInterrupt
            return await engine.generate(request)
        }
    }

    private static func generationRequest(
        _ params: ImageGenerationParameters, info: ImageModelInfo, index: Int, outputDir: URL, nativeBatch: Bool = false
    ) -> ImageGenRequest {
        // Older backends retain sequential requests. Native batches resolve the
        // same seeds once and reuse conditioning inside the engine.
        let seed = nativeBatch ? params.seed : (params.seeds.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? params.seed.map { $0 &+ UInt64(index) })
        return ImageGenRequest(
            prompt: params.prompt,
            negativePrompt: params.negativePrompt,
            width: params.width ?? 1024,
            height: params.height ?? 1024,
            steps: params.steps ?? info.defaultSteps ?? Self.defaultSteps(for: params.model),
            guidance: params.guidance ?? info.defaultGuidance ?? Self.defaultGuidance(for: params.model),
            seed: seed,
            numImages: nativeBatch ? params.numImages : 1,
            seeds: nativeBatch ? params.seeds : nil,
            batchSize: params.batchSize,
            outputDir: outputDir,
            outputFormat: Self.engineFormat(params.outputFormat),
            sampler: params.sampler, scheduler: params.scheduler, shift: params.shift,
            previewInterval: params.previewInterval, previewMaxPixel: params.previewMaxPixel,
            adapters: params.adapters.map { FluxAdapter(url: $0.url, scale: $0.scale,
                target: FluxAdapter.Target(rawValue: $0.target.rawValue)!) }
        )
    }

    public func edit(
        _ params: ImageEditParameters,
        jobID: String? = nil,
        interrupt: InterruptToken? = nil
    ) -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        edit(params, jobID: jobID, resolvedTarget: nil, interrupt: interrupt)
    }

    private func edit(
        _ params: ImageEditParameters, jobID: String?, resolvedTarget: LoadTarget?, interrupt: InterruptToken? = nil
    ) -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        let producerInterrupt = FluxInterrupt()
        return drive(
            model: params.model, expected: .imageEdit, jobID: jobID, resolvedTarget: resolvedTarget,
            interrupt: interrupt, producerInterrupt: producerInterrupt,
            estimatePeak: { try await self.estimatedPeakBytes(for: params, resolvedTarget: resolvedTarget) },
            validate: { info, limits in
                try Self.validateEdit(params, info: info, limits: limits)
            }
        ) { engine, outputDir, _, info, _ in
            let sources = try Self.stageInputs(params.sourceImages)
            guard !sources.isEmpty else {
                throw ImageGenerationError.invalidRequest("edit requires at least one source image")
            }
            let mask = try params.maskImage.map { try Self.stageInput($0) }
            let request = try Self.editRequest(params, info: info, sources: sources, mask: mask,
                outputDir: outputDir, interrupt: producerInterrupt)
            return await engine.edit(request)
        }
    }

    private static func validateEdit(_ params: ImageEditParameters, info: ImageModelInfo,
        limits: FluxModelLimits?) throws {
        if limits == nil {
            try ImageModelRequestPolicy(canonical: info.canonicalName).validate(
                width: params.width, height: params.height, isEdit: true,
                guidance: params.guidance ?? info.defaultGuidance ?? 3.5,
                negativePrompt: params.negativePrompt, strength: params.strength,
                hasMask: params.maskImage != nil, sourceCount: params.sourceImages.count,
                steps: params.steps ?? info.defaultSteps, outputFormat: params.outputFormat
            )
        }
        try limits?.validatePreview(interval: params.previewInterval, maxPixel: params.previewMaxPixel)
        try limits?.validateSampling(sampler: params.sampler, scheduler: params.scheduler, shift: params.shift)
        try limits?.validateEdit(
            width: params.width, height: params.height,
            steps: params.steps ?? info.defaultSteps ?? Self.defaultSteps(for: params.model),
            guidance: params.guidance ?? info.defaultGuidance ?? Self.defaultGuidance(for: params.model),
            format: Self.engineFormat(params.outputFormat), sourceCount: params.sourceImages.count,
            hasMask: params.maskImage != nil, strength: params.strength, negativePrompt: params.negativePrompt)
    }

    private static func editRequest(_ params: ImageEditParameters, info: ImageModelInfo,
        sources: [URL], mask: URL?, outputDir: URL, interrupt: FluxInterrupt? = nil) throws -> ImageEditRequest {
        try ImageEditRequest(
            prompt: params.prompt,
                sourceImages: sources,
                mask: mask,
                strength: ImageModelRequestPolicy(canonical: info.canonicalName)
                    .editStrength(params.strength),
                width: params.width,
                height: params.height,
                steps: params.steps ?? info.defaultSteps ?? Self.defaultSteps(for: params.model),
                guidance: params.guidance ?? info.defaultGuidance ?? Self.defaultGuidance(for: params.model),
                seed: params.seed,
                outputDir: outputDir,
                outputFormat: Self.engineFormat(params.outputFormat),
            sampler: params.sampler, scheduler: params.scheduler, shift: params.shift,
            previewInterval: params.previewInterval, previewMaxPixel: params.previewMaxPixel,
            adapters: params.adapters.map { FluxAdapter(url: $0.url, scale: $0.scale,
                target: FluxAdapter.Target(rawValue: $0.target.rawValue)!) }, interrupt: interrupt
            )
    }

    public func upscale(
        _ params: ImageUpscaleParameters,
        jobID: String? = nil,
        interrupt: InterruptToken? = nil
    ) -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        let producerInterrupt = FluxInterrupt()
        return drive(model: params.model, expected: .imageUpscale, jobID: jobID,
                     interrupt: interrupt, producerInterrupt: producerInterrupt,
                     estimatePeak: { try await self.estimatedPeakBytes(for: params) },
                     validate: { info, _ in
                         if info.canonicalName == "seedvr2" {
                             guard let source = CGImageSourceCreateWithData(params.sourceImage as CFData, nil),
                                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                                   let width = properties[kCGImagePropertyPixelWidth] as? Int,
                                   let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                                 throw ImageGenerationError.invalidRequest("Cannot read upscale source dimensions")
                             }
                             try SeedVR2BundleMetadata.validateUpscale(sourceWidth: width, sourceHeight: height,
                                 scale: params.scale, format: Self.engineFormat(params.outputFormat))
                         }
                     }) { engine, outputDir, _, _, _ in
            let source = try Self.stageInput(params.sourceImage)
            let request = UpscaleRequest(
                sourceImage: source,
                scale: params.scale,
                steps: params.steps ?? 1,
                seed: params.seed,
                outputDir: outputDir,
                outputFormat: Self.engineFormat(params.outputFormat),
                interrupt: producerInterrupt
            )
            return await engine.upscale(request)
        }
    }

    // MARK: - Core gated drive loop

    /// Acquire the exclusive image lane, ensure the model is loaded, then drain
    /// one or more engine streams in order, translating events. The gate is
    /// released only after every engine stream has fully drained.
    private func drive(
        model requestedModel: String,
        expected kind: ModelKind,
        jobID: String?,
        resolvedTarget: LoadTarget? = nil,
        interrupt: InterruptToken? = nil,
        producerInterrupt: FluxInterrupt? = nil,
        count: Int = 1,
        estimatePeak: (@Sendable () async throws -> Int64)? = nil,
        validate: @escaping @Sendable (ImageModelInfo, FluxModelLimits?) throws -> Void = { _, _ in },
        _ build: @escaping @Sendable (FluxEngine, URL, Int, ImageModelInfo, Bool) async throws -> AsyncThrowingStream<ImageGenEvent, Error>
    ) -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            guard jobID.map({ producerJobs[$0] == nil }) ?? true else {
                continuation.yield(.failed(message: "An image job with this ID is already running.", hfAuth: false))
                continuation.finish()
                return
            }
            // Cancel only the gate waiter, not the producer that consumes the
            // engine stream. Cancelling that consumer makes AsyncStream stop
            // iteration immediately even if the engine still produces work.
            let cancellation = ImageJobCancellation { try await self.metalGate.enterImageGeneration() }
            let cancel: @Sendable () -> Void = {
                cancellation.cancel()
                producerInterrupt?.cancel()
            }
            // SeedVR2 also receives a cooperative producer signal. Never cancel
            // the consumer task: it must retain and drain the engine producer.
            let observer = interrupt?.observeInterrupt(cancel)
            let task = Task {
                defer {
                    if let observer { interrupt?.removeInterruptObserver(observer) }
                    if let jobID { self.producerJobs.removeValue(forKey: jobID) }
                }
                do {
                    // Cancellation-aware: consumer termination (or job cancel)
                    // while another producer holds the GPU releases this task
                    // instead of parking it. No gate is held on the throw
                    // path, so none of the drain tail below applies.
                    try await cancellation.enter()
                } catch {
                    continuation.yield(.cancelled)
                    continuation.finish()
                    if let jobID { self.cancelledJobIDs.remove(jobID) }
                    return
                }
                // Proper GPU handoff barrier. The prior LLM turn's async tail —
                // the post-generation cache store (held under MLXDiskCacheIOLock,
                // submits Metal work) and the chat-model teardown's buffer frees —
                // can still be settling on the shared Metal device after the gen
                // gate released. vMLXFlux is a second MLX graph; without this it
                // races them (encoder coalescing / fence-vs-dealloc) and crashes.
                // Going THROUGH the cache-IO lock waits for any in-flight store to
                // finish (commit + sync) rather than force-committing a mid-flight
                // buffer, then `clearCache()` returns freed teardown buffers and the
                // bracketing syncs drain the device. We hold the exclusive image
                // gate, so no new producer can start during the barrier.
                self.cleanupGPUCache()
                // Recovered-error window for this job. Since the fork's
                // metal completion handlers report GPU command-buffer
                // failures through the global MLX error handler instead of
                // aborting the process, a failed buffer lets the denoise
                // loop run to completion with garbage arrays and the engine
                // stream can end without any `.failed` event. We hold the
                // EXCLUSIVE image lane for the whole window (load through
                // VAE decode), so any error recorded between here and the
                // drain finishing belongs to this job: abandon it rather
                // than report `.completed` with corrupt output.
                let mlxErrorEpoch = MLXErrorRecovery.errorSequence()
                var cancelled = false
                var failed = false
                var produced: [GeneratedImage] = []
                func cancelRequested() -> Bool {
                    if cancellation.isRequested || interrupt?.isInterrupted == true { return true }
                    if let jobID, self.cancelledJobIDs.contains(jobID) { return true }
                    return false
                }
                do {
                    if cancelRequested() { cancelled = true }
                    // Load (or switch) the model under the gate — quantized
                    // bundles decode their weights with MLX eval at load time.
                    var modelInfo: ImageModelInfo?
                    var modelLimits: FluxModelLimits?
                    if !cancelled {
                        // All entry points honor the visible Memory Safety
                        // mode/overrides. The delegation-only checkbox remains
                        // an additional handoff check in its coordinator.
                        if let estimatePeak {
                            let peak = try await estimatePeak()
                            let plan = ServerRuntimeSettingsStore.resolvedMemorySafetyPlan(
                                for: ServerRuntimeSettingsStore.snapshot(),
                                baseLoadConfiguration: .osaurusProduction,
                                host: MemoryStatus.snapshot(),
                                request: VMLXMemoryRequestEstimate(workingSetBytes: UInt64(peak)))
                            if let issue = plan.blockingIssues.first {
                                throw ImageGenerationError.memoryAdmission(field: issue.field,
                                    estimatedBytes: peak, message: issue.message)
                            }
                        }
                        continuation.yield(.loadingModel(model: requestedModel))
                        let prepared = try await self.ensureLoaded(requestedModel, expected: kind,
                            resolvedTarget: resolvedTarget, validate: validate)
                        modelInfo = prepared.0
                        modelLimits = prepared.1
                    }
                    // Honor a cancel that arrived during the (uninterruptible)
                    // weight load so generation never starts. The gate-drain
                    // tail below still runs on every path.
                    if cancelRequested() { cancelled = true }
                    let engine = self.ensureEngine()
                    let outputDir = OsaurusPaths.generatedImages()
                    OsaurusPaths.ensureExistsSilent(outputDir)
                    let nativeBatch = kind == .imageGen && (modelLimits?.maximumImages ?? 1) > 1
                    for index in 0 ..< (nativeBatch ? 1 : count) {
                        if cancelRequested() { cancelled = true }
                        if cancelled { break }
                        // An earlier producer may finish without a failed event
                        // after a recovered GPU error. Do not start another one.
                        if self.recoveredErrorSince(mlxErrorEpoch) != nil { break }
                        guard let modelInfo else { break }
                        let stream = try await build(engine, outputDir, index, modelInfo, nativeBatch)
                        await self.testStreamCheckpoint?(.created(index))
                        await self.testStreamCheckpoint?(.willDrain(index))
                        for try await event in stream {
                            if cancelRequested() { cancelled = true }
                            switch event {
                            case .step(let step, let total, let eta):
                                if !cancelled {
                                    continuation.yield(.step(step: step, total: total, etaSeconds: eta))
                                }
                            case .preview(let data, let step):
                                if !cancelled {
                                    continuation.yield(.preview(pngData: data, step: step))
                                }
                            case .completed(let url, let seed, let effective),
                                 .imageCompleted(let url, let seed, _, let effective):
                                if let message = self.recoveredErrorSince(mlxErrorEpoch) {
                                    if !failed {
                                        continuation.yield(.failed(message: MLXForwardPassError(message: message).localizedDescription, hfAuth: false))
                                    }
                                    failed = true
                                    cancelled = true
                                    cancel()
                                    continue
                                }
                                guard !cancelled, !failed else { continue }
                                let parameters = effective.map {
                                    ImageEffectiveParameters(
                                        width: $0.width, height: $0.height, steps: $0.steps,
                                        guidance: $0.guidance, seed: $0.seed,
                                        sampler: $0.sampler, scheduler: $0.scheduler, shift: $0.shift,
                                        strength: $0.strength, scale: $0.scale, modelRevision: $0.modelRevision,
                                        sampleSigmas: $0.sampleSigmas)
                                }
                                let image = GeneratedImage(url: url, seed: seed, effectiveParameters: parameters)
                                produced.append(image)
                                if !cancelled, count > 1 {
                                    continuation.yield(.imageCompleted(image: image, index: produced.count - 1))
                                }
                            case .failed(let message, let hfAuth):
                                // Drain remaining work for gate safety, but the
                                // job has failed — propagate and stop yielding.
                                if !cancelled, !failed {
                                    continuation.yield(.failed(message: message, hfAuth: hfAuth))
                                }
                                failed = true
                                cancelled = true
                            case .cancelled:
                                cancelled = true
                            }
                        }
                        await self.testStreamCheckpoint?(.drained(index))
                    }

                    // Cancellation can arrive after the last event while the
                    // final producer is finishing; there may be no next event.
                    if cancelRequested() { cancelled = true }
                    if failed {
                        // Failure is terminal. Do not overwrite it with a second
                        // cancellation status after draining the producer.
                    } else if cancelled {
                        continuation.yield(.cancelled)
                    } else if let mlxErr = self.recoveredErrorSince(mlxErrorEpoch) {
                        // The engine stream finished, but a GPU-side error was
                        // recovered during this job's window — any produced
                        // files decode from arrays downstream of the failed
                        // command buffer. Fail the job and discard them.
                        continuation.yield(
                            .failed(message: MLXForwardPassError(message: mlxErr).localizedDescription, hfAuth: false))
                    } else {
                        continuation.yield(.completed(images: produced))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.cancelled)
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(message: Self.message(for: error), hfAuth: Self.isAuthError(error)))
                    continuation.finish()
                }
                if let jobID { self.cancelledJobIDs.remove(jobID) }
                // Drain the image GPU tail BEFORE releasing the exclusive gate —
                // symmetric with the entry barrier above and the BatchEngine
                // stream-finish drain. vMLXFlux submits Metal work (denoise steps,
                // the terminal VAE decode, teardown buffer frees) asynchronously;
                // the event stream ending does NOT mean the device is idle. If we
                // release the gate here while a command buffer is still in flight,
                // the next exclusive producer — a chat-model reload via
                // `enterModelLoad`, which happens immediately after an agent-run
                // image tool returns — starts and races it on the shared Metal
                // command buffer, aborting with `MTLReleaseAssertionFailure` in
                // `-[IOGPUMetalCommandBuffer setCurrentCommandEncoder:]` (observed
                // live on the image_edit → gemma-reload handoff). Going through the
                // cache-IO lock brackets the work in `Stream.gpu.synchronize`, so
                // "gate released" provably means "GPU idle". Covers the success,
                // cancel, and error paths (this runs after the do/catch).
                self.cleanupGPUCache()
                await self.metalGate.exitImageGeneration()
                // A recovered GPU error may have corrupted the resident
                // weights (e.g. the failure hit during load). Drop residency
                // so the next job reloads from disk. Runs after the image
                // gate is released — `unload()` takes the teardown lane
                // itself, which is exclusive against ours.
                if self.recoveredErrorSince(mlxErrorEpoch) != nil {
                    await self.unload()
                }
            }
            if let jobID {
                producerJobs[jobID] = ProducerJob(task: task, cancel: cancel)
                if cancelledJobIDs.contains(jobID) { cancel() }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { cancel() }
            }
        }
    }

    private func recoveredErrorSince(_ epoch: UInt64) -> String? {
        if let testErrorSince { return testErrorSince(epoch) }
        return MLXErrorRecovery.errorSince(epoch)
    }

    func samplingCapabilities(for modelID: String) throws -> ImageSamplingCapabilities {
        let target = try resolveLoadTarget(modelID)
        guard let limits = try ModelRegistry.lookup(name: target.engineName)?.limits?(target.directory) else {
            return ImageSamplingCapabilities()
        }
        return ImageSamplingCapabilities(samplers: limits.samplers,
            schedulers: limits.schedulers, supportsShift: limits.supportsShift, maxSourceImages: limits.maxSourceImages)
    }

    private func resolveLoadTarget(_ requestedModel: String) throws -> LoadTarget {
        if let testResolve { return try testResolve(requestedModel) }
        ensureRegistered()
        guard let local = try store().resolve(name: requestedModel) else {
            throw ImageGenerationError.modelNotFound(requestedModel)
        }
        guard let canonical = local.canonicalName else {
            // Preserve the incomplete-bundle error before unknown identity.
            if !local.canEnterNativeLoadPath {
                throw ImageGenerationError.modelIncomplete(model: requestedModel, reasons: local.blockedReasons)
            }
            throw ImageGenerationError.unknownModel(local.directoryName)
        }
        return LoadTarget(info: Self.info(for: local), directory: local.directory,
            engineName: canonical, kind: local.kind)
    }

    private func ensureLoaded(
        _ requestedModel: String, expected kind: ModelKind, resolvedTarget: LoadTarget?,
        validate: @Sendable (ImageModelInfo, FluxModelLimits?) throws -> Void
    ) async throws -> (ImageModelInfo, FluxModelLimits?) {
        let target = try resolvedTarget ?? resolveLoadTarget(requestedModel)
        let info = target.info
        guard info.ready else {
            throw ImageGenerationError.modelIncomplete(model: requestedModel, reasons: info.blockedReasons)
        }
        guard (kind == .videoGen && info.kind == ModelKind.videoGen.rawValue)
            || ImageModelRequestPolicy.supports(kind.rawValue, capabilities: info.capabilities) else {
            throw ImageGenerationError.wrongModelKind(expected: kind.rawValue, actual: info.kind)
        }
        let limits = try ModelRegistry.lookup(name: target.engineName)?.limits?(target.directory)
        try validate(info, limits)
        guard loadedDirectoryName != info.id else { return (info, limits) }
        let engine = ensureEngine()
        // Free the previous model before loading a new one (bundles are large;
        // unload between switches per the integration spec).
        await engine.unload()
        loadedDirectoryName = nil
        loadedDirectoryURL = nil
        try await engine.load(
            name: target.engineName,
            modelPath: target.directory,
            quantize: info.quantizationBits
        )
        loadedDirectoryName = info.id
        loadedDirectoryURL = target.directory
        NotificationCenter.default.post(name: .modelRuntimeResidencyChanged, object: nil)
        return (info, limits)
    }

    // MARK: - Defaults + helpers

    private static func registryEntry(for model: String) -> ModelEntry? {
        ModelRegistry.lookupFuzzy(name: model)
    }

    private static func defaultSteps(for model: String) -> Int {
        registryEntry(for: model)?.defaultSteps ?? 20
    }

    static func safeDenoiseSteps(for model: String, requested: Int?) -> Int {
        let steps = requested ?? defaultSteps(for: model)
        if model.lowercased().contains("qwen-image") {
            return max(2, steps)
        }
        return steps
    }

    private static func defaultGuidance(for model: String) -> Float {
        registryEntry(for: model)?.defaultGuidance ?? 3.5
    }

    private static func engineFormat(_ format: ImageOutputFormat) -> ImageFormat {
        switch format {
        case .png: return .png
        case .jpeg: return .jpeg
        case .webp: return .webp
        }
    }

    /// Write raw image bytes to a unique temp file the engine can read by URL.
    private static func stageInput(_ data: Data) throws -> URL {
        let dir = OsaurusPaths.cache().appendingPathComponent("image-edit-inputs", isDirectory: true)
        OsaurusPaths.ensureExistsSilent(dir)
        let url = dir.appendingPathComponent("\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    private static func stageInputs(_ datas: [Data]) throws -> [URL] {
        try datas.map { try stageInput($0) }
    }

    private static func message(for error: Error) -> String {
        if let flux = error as? FluxError { return flux.description }
        if let img = error as? ImageGenerationError { return img.description }
        return String(describing: error)
    }

    private static func isAuthError(_ error: Error) -> Bool {
        let text = String(describing: error)
        return text.contains("401") || text.contains("403")
    }
}
