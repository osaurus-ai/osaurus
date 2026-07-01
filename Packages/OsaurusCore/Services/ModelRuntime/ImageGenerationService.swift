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
    /// One-time registry population (decentralized self-registration).
    private var registered = false
    /// Job ids that have been asked to cancel. Checked per event in the drain
    /// loop; the loop keeps consuming the engine stream to completion so the
    /// gate is never released mid-eval (soft cancel).
    private var cancelledJobIDs: Set<String> = []

    public init() {}

    /// Request cancellation of an in-flight job by id. Safe to call from any
    /// connection/actor; the matching drain loop stops yielding at the next
    /// event boundary and finishes with `.cancelled`.
    public func cancel(jobID: String) {
        cancelledJobIDs.insert(jobID)
    }

    /// Release the resident image model after agent-triggered jobs or memory
    /// pressure handoffs. Manual image-panel flows may choose to keep the
    /// engine warm and skip this through `SubagentImageLoadPolicy`.
    public func unload() async {
        guard let engine else {
            loadedDirectoryName = nil
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
        await MetalGate.shared.enterImageGeneration()
        await engine.unload()
        loadedDirectoryName = nil
        MLXCacheIOLock.withSerializedMLXCacheIO {
            Memory.clearCache()
        }
        await MetalGate.shared.exitImageGeneration()
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
        let userModelsImageDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("image", isDirectory: true)
        let legacy = MLXStudioModelStore.defaultImageRoot
        for candidate in [osaurusImageDir, userModelsImageDir, legacy] where holdsBundles(candidate) {
            return candidate
        }
        return osaurusImageDir
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

    static func info(for local: LocalFluxModel) -> ImageModelInfo {
        let kind = local.kind ?? .imageGen
        let entry = local.canonicalName.flatMap { ModelRegistry.lookup(name: $0) }
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
            totalBytes: local.totalBytes
        )
    }

    static func capabilities(
        kind: ModelKind,
        canonical: String?,
        entry: ModelEntry?
    ) -> ImageModelCapabilities {
        ImageModelCapabilities(
            textToImage: kind == .imageGen,
            imageEdit: kind == .imageEdit,
            upscale: kind == .imageUpscale,
            // negative_prompt is honored whenever guidance > 0 (gen + edit).
            negativePrompt: kind == .imageGen || kind == .imageEdit,
            // No current model has a real mask/inpaint path; qwen-edit masks
            // are rejected by the engine. Hide the control everywhere.
            mask: false,
            // Ordered multi-reference is qwen-image-edit only.
            multipleSourceImages: canonical == "qwen-image-edit",
            lora: entry?.supportsLoRA ?? false
        )
    }

    // MARK: - Generate / edit / upscale

    public func generate(
        _ params: ImageGenerationParameters,
        jobID: String? = nil
    ) -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        drive(model: params.model, expected: .imageGen, jobID: jobID) { engine, outputDir in
            let count = max(1, params.numImages)
            var streams: [AsyncThrowingStream<ImageGenEvent, Error>] = []
            streams.reserveCapacity(count)
            for index in 0 ..< count {
                // n > 1 is not engine-batched; run sequentially with distinct
                // seeds so each image differs while staying reproducible.
                let seed = params.seed.map { $0 &+ UInt64(index) }
                let request = ImageGenRequest(
                    prompt: params.prompt,
                    negativePrompt: params.negativePrompt,
                    width: params.width ?? 1024,
                    height: params.height ?? 1024,
                    steps: Self.safeDenoiseSteps(for: params.model, requested: params.steps),
                    guidance: params.guidance ?? Self.defaultGuidance(for: params.model),
                    seed: seed,
                    numImages: 1,
                    outputDir: outputDir,
                    outputFormat: Self.engineFormat(params.outputFormat)
                )
                streams.append(await engine.generate(request))
            }
            return streams
        }
    }

    public func edit(
        _ params: ImageEditParameters,
        jobID: String? = nil
    ) -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        drive(model: params.model, expected: .imageEdit, jobID: jobID) { engine, outputDir in
            let sources = try Self.stageInputs(params.sourceImages)
            guard !sources.isEmpty else {
                throw ImageGenerationError.invalidRequest("edit requires at least one source image")
            }
            let mask = try params.maskImage.map { try Self.stageInput($0) }
            let request = try ImageEditRequest(
                prompt: params.prompt,
                sourceImages: sources,
                mask: mask,
                strength: params.strength,
                width: params.width,
                height: params.height,
                steps: Self.safeDenoiseSteps(for: params.model, requested: params.steps),
                guidance: params.guidance ?? Self.defaultGuidance(for: params.model),
                seed: params.seed,
                outputDir: outputDir,
                outputFormat: Self.engineFormat(params.outputFormat)
            )
            return [await engine.edit(request)]
        }
    }

    public func upscale(
        _ params: ImageUpscaleParameters,
        jobID: String? = nil
    ) -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        drive(model: params.model, expected: .imageUpscale, jobID: jobID) { engine, outputDir in
            let source = try Self.stageInput(params.sourceImage)
            let request = UpscaleRequest(
                sourceImage: source,
                scale: params.scale,
                steps: params.steps ?? 10,
                seed: params.seed,
                outputDir: outputDir,
                outputFormat: Self.engineFormat(params.outputFormat)
            )
            return [await engine.upscale(request)]
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
        _ build: @escaping @Sendable (FluxEngine, URL) async throws -> [AsyncThrowingStream<ImageGenEvent, Error>]
    ) -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await MetalGate.shared.enterImageGeneration()
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
                MLXCacheIOLock.withSerializedMLXCacheIO {
                    Memory.clearCache()
                }
                var cancelled = false
                var produced: [GeneratedImage] = []
                func cancelRequested() -> Bool {
                    if Task.isCancelled { return true }
                    if let jobID, self.cancelledJobIDs.contains(jobID) { return true }
                    return false
                }
                do {
                    if cancelRequested() { cancelled = true }
                    // Load (or switch) the model under the gate — quantized
                    // bundles decode their weights with MLX eval at load time.
                    if !cancelled {
                        continuation.yield(.loadingModel(model: requestedModel))
                        try await self.ensureLoaded(requestedModel, expected: kind)
                    }
                    // Honor a cancel that arrived during the (uninterruptible)
                    // weight load so generation never starts. The gate-drain
                    // tail below still runs on every path.
                    if cancelRequested() { cancelled = true }
                    let engine = self.ensureEngine()
                    let outputDir = OsaurusPaths.generatedImages()
                    OsaurusPaths.ensureExistsSilent(outputDir)
                    let streams = cancelled ? [] : try await build(engine, outputDir)

                    for stream in streams {
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
                            case .completed(let url, let seed):
                                produced.append(GeneratedImage(url: url, seed: seed))
                            case .failed(let message, let hfAuth):
                                // Drain remaining work for gate safety, but the
                                // job has failed — propagate and stop yielding.
                                if !cancelled {
                                    continuation.yield(.failed(message: message, hfAuth: hfAuth))
                                }
                                cancelled = true
                            case .cancelled:
                                cancelled = true
                            }
                        }
                    }

                    if cancelled {
                        continuation.yield(.cancelled)
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
                MLXCacheIOLock.withSerializedMLXCacheIO {
                    Memory.clearCache()
                }
                await MetalGate.shared.exitImageGeneration()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func ensureLoaded(_ requestedModel: String, expected kind: ModelKind) async throws {
        ensureRegistered()
        let store = store()
        guard let local = try store.resolve(name: requestedModel) else {
            throw ImageGenerationError.modelNotFound(requestedModel)
        }
        guard local.canEnterNativeLoadPath else {
            throw ImageGenerationError.modelIncomplete(model: requestedModel, reasons: local.blockedReasons)
        }
        guard let canonical = local.canonicalName else {
            throw ImageGenerationError.unknownModel(local.directoryName)
        }
        if let modelKind = local.kind, modelKind != kind {
            throw ImageGenerationError.wrongModelKind(expected: kind.rawValue, actual: modelKind.rawValue)
        }
        guard loadedDirectoryName != local.directoryName else { return }
        let engine = ensureEngine()
        // Free the previous model before loading a new one (bundles are large;
        // unload between switches per the integration spec).
        await engine.unload()
        loadedDirectoryName = nil
        try await engine.load(
            name: canonical,
            modelPath: local.directory,
            quantize: local.quantizationBits
        )
        loadedDirectoryName = local.directoryName
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
