//
//  NativeImageJobCoordinator.swift
//  osaurus
//
//  Agent-side orchestration for local native image jobs. The chat model sees a
//  compact tool surface; this coordinator owns default model resolution,
//  progress lifecycle, and safe image-model unload after agent-launched jobs.
//

import Foundation

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
        outputFormat: ImageOutputFormat = .png
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
    }
}

enum NativeImageJobPhase: String, Sendable {
    case queued
    case loadingModel = "loading_model"
    case generating
    case unloading
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

    init(
        jobID: String,
        phase: NativeImageJobPhase,
        model: String? = nil,
        step: Int? = nil,
        total: Int? = nil,
        etaSeconds: Double? = nil,
        message: String? = nil
    ) {
        self.jobID = jobID
        self.phase = phase
        self.model = model
        self.step = step
        self.total = total
        self.etaSeconds = etaSeconds
        self.message = message
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
        return payload
    }
}

struct NativeImageJobResult: Sendable, Equatable {
    var jobID: String
    var model: String
    var images: [GeneratedImage]
    var progress: [NativeImageJobProgress]
    var unloadedAfterJob: Bool

    var toolPayload: [String: Any] {
        [
            "kind": "native_image_generation_job",
            "job_id": jobID,
            "model": model,
            "status": NativeImageJobPhase.completed.rawValue,
            "unloaded_after_job": unloadedAfterJob,
            "images": images.map { image in
                [
                    "path": image.url.path,
                    "url": image.url.absoluteString,
                    "seed": image.seed,
                ] as [String: Any]
            },
            "progress": progress.map(\.dictionary),
        ]
    }
}

enum NativeImageJobCoordinatorError: Error, CustomStringConvertible {
    case noReadyModel(kind: AgentDelegationModelKind)
    case requestFailed(String)
    case cancelled

    var description: String {
        switch self {
        case .noReadyModel(let kind):
            return "no ready local model configured or installed for \(kind.rawValue)"
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
            return requested
        }
        if let configured = normalizedID(configured) {
            return configured
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
                    progress.append(event)
                    NativeImageJobProgressCenter.post(event)
                }

                let config = AgentDelegationConfigurationStore.snapshot()
                do {
                    record(NativeImageJobProgress(jobID: jobID, phase: .queued))
                    let models = (try? await imageService.availableModels()) ?? []
                    let model = try NativeImageJobModelResolver.resolve(
                        requested: request.model,
                        configured: config.defaultImageGenerationModelId,
                        available: models,
                        kind: .imageGeneration
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
                    record(NativeImageJobProgress(jobID: jobID, phase: .completed, model: model))
                    continuation.yield(
                        NativeImageJobResult(
                            jobID: jobID,
                            model: model,
                            images: produced,
                            progress: progress,
                            unloadedAfterJob: shouldUnload
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
