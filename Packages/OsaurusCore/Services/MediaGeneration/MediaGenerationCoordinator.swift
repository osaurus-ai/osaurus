//
//  MediaGenerationCoordinator.swift
//  osaurus
//

import Foundation

extension Notification.Name {
    static let mediaJobChanged = Notification.Name("MediaJobChanged")
    static let cloudMediaCatalogChanged = Notification.Name("CloudMediaCatalogChanged")
}

actor MediaGenerationCoordinator {
    static let shared = MediaGenerationCoordinator()

    private let jobs: MediaJobStore
    private let cloud: OsaurusCloudMediaClient
    private var cloudModels: [MediaModelInfo] = []
    private var cloudSupported = false
    private var recoveryTasks: [UUID: Task<Void, Never>] = [:]

    init(
        jobs: MediaJobStore = .shared,
        cloud: OsaurusCloudMediaClient = OsaurusCloudMediaClient()
    ) {
        self.jobs = jobs
        self.cloud = cloud
    }

    func refreshCloudCatalog() async {
        do {
            switch try await cloud.catalog() {
            case .available(let models):
                cloudModels = models
                cloudSupported = true
            case .unsupported:
                cloudModels = []
                cloudSupported = false
            }
        } catch {
            // Fail closed: transient/error responses never expose stale Cloud
            // choices and never redirect work to direct Venice.
            cloudModels = []
            cloudSupported = false
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .cloudMediaCatalogChanged, object: nil)
        }
    }

    func cachedCloudModels() -> [MediaModelInfo] {
        cloudSupported ? cloudModels : []
    }

    func generateImage(_ request: MediaImageGenerationRequest) async throws -> [GeneratedMedia] {
        try await validateImageRequest(request)
        switch request.target.backend {
        case .local:
            let stream = await NativeImageJobCoordinator.shared.generate(
                NativeImageGenerateJobRequest(
                    prompt: request.prompt,
                    model: request.target.modelID,
                    negativePrompt: request.negativePrompt,
                    width: request.width,
                    height: request.height,
                    steps: request.steps,
                    guidance: request.guidance.map(Float.init),
                    seed: request.seed.flatMap { $0 >= 0 ? UInt64($0) : nil },
                    numImages: request.count,
                    outputFormat: request.format,
                    context: .current()
                )
            )
            for try await result in stream {
                return result.images.map {
                    GeneratedMedia(
                        url: $0.url,
                        mimeType: "image/\(request.format.rawValue)",
                        modelID: result.model,
                        kind: .image
                    )
                }
            }
            throw MediaGenerationError.invalidResponse
        case .remoteProvider(let providerID):
            let provider = await MainActor.run {
                RemoteProviderManager.shared.configuredProvider(id: providerID)
            }
            guard let provider else { throw MediaGenerationError.providerUnavailable }
            return try await VeniceMediaClient(provider: provider).generateImage(request)
        case .osaurusCloud:
            guard cloudSupported else {
                throw MediaGenerationError.unsupported("Osaurus Cloud media is not available.")
            }
            return try await cloud.generateImage(request)
        }
    }

    func quoteVideo(_ request: MediaVideoGenerationRequest) async throws -> MediaVideoQuote {
        try await validateVideoRequest(request)
        switch request.target.backend {
        case .local:
            throw MediaGenerationError.unsupported("Local video generation is not available.")
        case .remoteProvider(let providerID):
            let provider = await MainActor.run {
                RemoteProviderManager.shared.configuredProvider(id: providerID)
            }
            guard let provider else { throw MediaGenerationError.providerUnavailable }
            return try await VeniceMediaClient(provider: provider).quoteVideo(request)
        case .osaurusCloud:
            guard cloudSupported else {
                throw MediaGenerationError.unsupported("Osaurus Cloud media is not available.")
            }
            let quote = try await cloud.quoteVideo(request)
            guard let micro = Decimal(string: quote.quoteMicroUSD) else {
                throw MediaGenerationError.invalidResponse
            }
            return MediaVideoQuote(usd: NSDecimalNumber(decimal: micro / 1_000_000).doubleValue)
        }
    }

    /// Queue and retrieve a video. Once the queue call succeeds, cancellation
    /// detaches UI tracking but recovery continues from the durable job store.
    func generateVideo(
        _ request: MediaVideoGenerationRequest,
        approvedQuote: MediaVideoQuote,
        progress: @escaping @Sendable (MediaGenerationEvent) -> Void
    ) async throws -> GeneratedMedia {
        try await validateVideoRequest(request)
        try Task.checkCancellation()

        var durableID: UUID?
        do {
            let job = try await submitVideo(request, approvedQuote: approvedQuote)
            durableID = job.id
            await notifyJobChanged()
            progress(.queued(jobID: job.id.uuidString))
            switch job.backend {
            case .remoteProvider(let providerID):
                let provider = await MainActor.run {
                    RemoteProviderManager.shared.configuredProvider(id: providerID)
                }
                guard let provider else { throw MediaGenerationError.providerUnavailable }
                return try await retrieveVenice(
                    job: job,
                    client: VeniceMediaClient(provider: provider),
                    progress: progress
                )
            case .osaurusCloud:
                return try await retrieveCloud(job: job, progress: progress)
            case .local:
                throw MediaGenerationError.unsupported("Local video generation is not available.")
            }
        } catch is CancellationError {
            if let durableID, let job = await jobs.job(id: durableID) {
                scheduleRecovery(job)
                throw MediaGenerationError.queuedJobContinues(durableID.uuidString)
            }
            throw CancellationError()
        } catch {
            if let durableID {
                try? await jobs.update(
                    id: durableID,
                    state: .failed,
                    errorMessage: error.localizedDescription
                )
                await notifyJobChanged()
            }
            throw error
        }
    }

    /// Queue a paid video and immediately hand durable tracking to the
    /// coordinator. Used by the HTTP API, which returns 202 instead of holding
    /// the client connection for the full generation.
    func queueVideo(
        _ request: MediaVideoGenerationRequest,
        approvedQuote: MediaVideoQuote
    ) async throws -> DurableMediaJob {
        let job = try await submitVideo(request, approvedQuote: approvedQuote)
        await notifyJobChanged()
        scheduleRecovery(job)
        return job
    }

    func resumePendingJobs() async {
        try? await jobs.pruneTerminalJobs(
            olderThan: Date().addingTimeInterval(-30 * 24 * 60 * 60)
        )
        for job in await jobs.pending() {
            scheduleRecovery(job)
        }
    }

    func videoJobs() async -> [DurableMediaJob] {
        await jobs.all()
    }

    func videoJob(id: UUID) async -> DurableMediaJob? {
        await jobs.job(id: id)
    }

    private func submitVideo(
        _ request: MediaVideoGenerationRequest,
        approvedQuote: MediaVideoQuote
    ) async throws -> DurableMediaJob {
        try await validateVideoRequest(request)
        try Task.checkCancellation()
        switch request.target.backend {
        case .local:
            throw MediaGenerationError.unsupported("Local video generation is not available.")
        case .remoteProvider(let providerID):
            let provider = await MainActor.run {
                RemoteProviderManager.shared.configuredProvider(id: providerID)
            }
            guard let provider else { throw MediaGenerationError.providerUnavailable }
            let client = try VeniceMediaClient(provider: provider)
            let currentQuote = try await client.quoteVideo(request)
            try Self.requireApprovedQuote(approvedQuote, current: currentQuote)
            try Task.checkCancellation()
            let queued = try await client.queueVideo(request)
            let job = DurableMediaJob(
                id: UUID(),
                backend: request.target.backend,
                providerID: providerID,
                modelID: request.target.modelID,
                kind: request.sourceImage == nil ? .textToVideo : .imageToVideo,
                queueID: queued.queueID,
                downloadURL: queued.downloadURL,
                quoteUSD: currentQuote.usd,
                state: .queued,
                outputURL: nil,
                errorMessage: nil,
                cleanupPending: true,
                createdAt: Date(),
                updatedAt: Date()
            )
            try await jobs.upsert(job)
            return job
        case .osaurusCloud:
            guard cloudSupported else {
                throw MediaGenerationError.unsupported("Osaurus Cloud media is not available.")
            }
            let quote = try await cloud.quoteVideo(request)
            guard let micro = Decimal(string: quote.quoteMicroUSD) else {
                throw MediaGenerationError.invalidResponse
            }
            let current = MediaVideoQuote(
                usd: NSDecimalNumber(decimal: micro / 1_000_000).doubleValue
            )
            try Self.requireApprovedQuote(approvedQuote, current: current)
            try Task.checkCancellation()
            let idempotencyKey = UUID().uuidString.lowercased()
            let queued = try await cloud.queueVideo(
                request,
                quoteID: quote.quoteID,
                idempotencyKey: idempotencyKey
            )
            let job = DurableMediaJob(
                id: UUID(),
                backend: .osaurusCloud,
                providerID: nil,
                modelID: request.target.modelID,
                kind: request.sourceImage == nil ? .textToVideo : .imageToVideo,
                queueID: queued.jobID,
                downloadURL: nil,
                quoteUSD: current.usd,
                state: .queued,
                outputURL: nil,
                errorMessage: nil,
                cleanupPending: true,
                createdAt: Date(),
                updatedAt: Date()
            )
            try await jobs.upsert(job)
            return job
        }
    }

    private func scheduleRecovery(_ job: DurableMediaJob) {
        guard recoveryTasks[job.id] == nil else { return }
        recoveryTasks[job.id] = Task { [weak self] in
            guard let self else { return }
            if job.state == .completed, job.cleanupPending == true {
                let cleaned: Bool
                switch job.backend {
                case .remoteProvider(let providerID):
                    let provider = await MainActor.run {
                        RemoteProviderManager.shared.configuredProvider(id: providerID)
                    }
                    if let provider, let client = try? VeniceMediaClient(provider: provider) {
                        cleaned = await client.cleanupVideo(
                            VeniceQueuedVideo(
                                model: job.modelID,
                                queueID: job.queueID,
                                downloadURL: job.downloadURL
                            )
                        )
                    } else {
                        cleaned = false
                    }
                case .osaurusCloud:
                    cleaned = await self.cloud.cleanupVideo(jobID: job.queueID)
                case .local:
                    cleaned = true
                }
                if cleaned {
                    try? await self.jobs.update(
                        id: job.id,
                        state: .completed,
                        cleanupPending: false
                    )
                }
                await self.recoveryFinished(job.id)
                return
            }
            do {
                switch job.backend {
                case .remoteProvider(let providerID):
                    let provider = await MainActor.run {
                        RemoteProviderManager.shared.configuredProvider(id: providerID)
                    }
                    guard let provider else { throw MediaGenerationError.providerUnavailable }
                    let client = try VeniceMediaClient(provider: provider)
                    _ = try await self.retrieveVenice(job: job, client: client, progress: { _ in })
                case .osaurusCloud:
                    _ = try await self.retrieveCloud(job: job, progress: { _ in })
                case .local:
                    throw MediaGenerationError.unsupported("Local jobs are not durable.")
                }
            } catch {
                try? await self.jobs.update(
                    id: job.id,
                    state: .failed,
                    errorMessage: error.localizedDescription
                )
            }
            await self.recoveryFinished(job.id)
        }
    }

    private func recoveryFinished(_ id: UUID) async {
        recoveryTasks[id] = nil
        await notifyJobChanged()
    }

    private func retrieveVenice(
        job: DurableMediaJob,
        client: VeniceMediaClient,
        progress: @escaping @Sendable (MediaGenerationEvent) -> Void
    ) async throws -> GeneratedMedia {
        try await jobs.update(id: job.id, state: .retrieving)
        let queued = VeniceQueuedVideo(
            model: job.modelID,
            queueID: job.queueID,
            downloadURL: job.downloadURL
        )
        var retryDelay = 3.0
        while true {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(job.createdAt) < 26 * 60 * 60 else {
                throw MediaGenerationError.server(
                    status: 410,
                    message: "The video job expired before the provider returned a result."
                )
            }
            do {
                switch try await client.retrieveVideo(queued) {
                case .processing(let eta):
                    retryDelay = 3
                    progress(.running(progress: nil, etaSeconds: eta))
                case .privateDownloadReady:
                    guard let url = queued.downloadURL else {
                        throw MediaGenerationError.invalidResponse
                    }
                    let temporaryURL = try await client.downloadPrivateVideo(from: url)
                    let persisted = try await client.persistCompletedVideo(
                        at: temporaryURL,
                        queued: queued
                    )
                    var media = persisted.media
                    media.kind = job.kind
                    try await jobs.update(
                        id: job.id,
                        state: .completed,
                        outputURL: media.url,
                        cleanupPending: !persisted.cleanupSucceeded
                    )
                    progress(.completed(media))
                    await notifyJobChanged()
                    return media
                case .completed(let temporaryURL):
                    let persisted = try await client.persistCompletedVideo(
                        at: temporaryURL,
                        queued: queued
                    )
                    var media = persisted.media
                    media.kind = job.kind
                    try await jobs.update(
                        id: job.id,
                        state: .completed,
                        outputURL: media.url,
                        cleanupPending: !persisted.cleanupSucceeded
                    )
                    progress(.completed(media))
                    await notifyJobChanged()
                    return media
                }
            } catch let error as MediaGenerationError where Self.isTransient(error) {
                progress(.running(progress: nil, etaSeconds: nil))
                retryDelay = min(30, retryDelay * 2)
            }
            try await Task.sleep(for: .seconds(retryDelay))
        }
    }

    private func retrieveCloud(
        job: DurableMediaJob,
        progress: @escaping @Sendable (MediaGenerationEvent) -> Void
    ) async throws -> GeneratedMedia {
        try await jobs.update(id: job.id, state: .retrieving)
        var retryDelay = 3.0
        while true {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(job.createdAt) < 26 * 60 * 60 else {
                throw MediaGenerationError.server(
                    status: 410,
                    message: "The video job expired before the provider returned a result."
                )
            }
            do {
                let status = try await cloud.job(job.queueID)
                switch status.status.uppercased() {
                case "QUEUED", "RUNNING", "PROCESSING":
                    retryDelay = 3
                    progress(.running(progress: nil, etaSeconds: status.etaSeconds))
                case "COMPLETED":
                    let persisted = try await cloud.downloadAndCleanup(
                        jobID: job.queueID,
                        modelID: job.modelID,
                        kind: job.kind
                    )
                    let media = persisted.media
                    try await jobs.update(
                        id: job.id,
                        state: .completed,
                        outputURL: media.url,
                        cleanupPending: !persisted.cleanupSucceeded
                    )
                    progress(.completed(media))
                    await notifyJobChanged()
                    return media
                case "FAILED":
                    throw MediaGenerationError.server(
                        status: 500,
                        message: "Cloud video generation failed."
                    )
                default:
                    throw MediaGenerationError.invalidResponse
                }
            } catch let error as MediaGenerationError where Self.isTransient(error) {
                progress(.running(progress: nil, etaSeconds: nil))
                retryDelay = min(30, retryDelay * 2)
            }
            try await Task.sleep(for: .seconds(retryDelay))
        }
    }

    private func validateImageRequest(_ request: MediaImageGenerationRequest) async throws {
        guard request.target.isValid else { throw MediaGenerationError.invalidTarget }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MediaGenerationError.invalidRequest("A prompt is required.")
        }
        guard (1 ... 4).contains(request.count) else {
            throw MediaGenerationError.invalidRequest("Image count must be between 1 and 4.")
        }
        guard request.target.backend != .local else { return }
        let model = try await requiredMediaModel(for: request.target)
        guard model.kind == .image else {
            throw MediaGenerationError.invalidRequest(
                "The selected model does not support image generation."
            )
        }
        try Self.validatePrompt(request.prompt, constraints: model.constraints)
        try Self.validateOption(
            request.aspectRatio,
            supported: model.constraints.aspectRatios,
            label: "aspect ratio"
        )
        try Self.validateOption(
            request.resolution,
            supported: model.constraints.resolutions,
            label: "resolution"
        )
        try Self.validateOption(
            request.quality,
            supported: model.constraints.qualities,
            label: "quality"
        )
        if let steps = request.steps, let max = model.constraints.maxSteps, steps > max {
            throw MediaGenerationError.invalidRequest(
                "Steps exceed the selected model's maximum of \(max)."
            )
        }
        if let divisor = model.constraints.dimensionDivisor, divisor > 1 {
            for dimension in [request.width, request.height].compactMap({ $0 }) where dimension % divisor != 0 {
                throw MediaGenerationError.invalidRequest(
                    "Image dimensions must be divisible by \(divisor)."
                )
            }
        }
    }

    private func validateVideoRequest(_ request: MediaVideoGenerationRequest) async throws {
        guard request.target.isValid else { throw MediaGenerationError.invalidTarget }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MediaGenerationError.invalidRequest("A prompt is required.")
        }
        guard !request.duration.isEmpty else {
            throw MediaGenerationError.invalidRequest("A duration is required.")
        }
        guard request.target.backend != .local else { return }
        let model = try await requiredMediaModel(for: request.target)
        let expectedKind: MediaGenerationKind =
            request.sourceImage == nil ? .textToVideo : .imageToVideo
        guard model.kind == expectedKind else {
            throw MediaGenerationError.invalidRequest(
                expectedKind == .imageToVideo
                    ? "The selected model does not support image-to-video generation."
                    : "The selected model does not support text-to-video generation."
            )
        }
        try Self.validatePrompt(request.prompt, constraints: model.constraints)
        try Self.validateOption(
            request.duration,
            supported: model.constraints.durations,
            label: "duration"
        )
        try Self.validateOption(
            request.aspectRatio,
            supported: model.constraints.aspectRatios,
            label: "aspect ratio"
        )
        try Self.validateOption(
            request.resolution,
            supported: model.constraints.resolutions,
            label: "resolution"
        )
        if request.audio != nil, !model.constraints.audioConfigurable {
            throw MediaGenerationError.invalidRequest(
                "Audio cannot be configured for the selected model."
            )
        }
        if let source = request.sourceImage, source.count > 25 * 1_024 * 1_024 {
            throw MediaGenerationError.invalidRequest("The source image must not exceed 25 MB.")
        }
        if request.sourceImage != nil,
            !["image/png", "image/jpeg", "image/webp"].contains(request.sourceImageMIMEType ?? "")
        {
            throw MediaGenerationError.invalidRequest(
                "The source image must be PNG, JPEG, or WebP."
            )
        }
    }

    private func requiredMediaModel(for target: MediaModelTarget) async throws -> MediaModelInfo {
        let model: MediaModelInfo?
        switch target.backend {
        case .local:
            model = nil
        case .remoteProvider:
            model = await MainActor.run {
                RemoteProviderManager.shared.mediaModel(for: target)
            }
        case .osaurusCloud:
            model =
                cloudSupported
                ? cloudModels.first { $0.target == target }
                : nil
        }
        guard let model, model.isAvailable else {
            throw MediaGenerationError.modelUnavailable(target.modelID)
        }
        return model
    }

    private static func validatePrompt(
        _ prompt: String,
        constraints: MediaModelConstraints
    ) throws {
        if let limit = constraints.promptCharacterLimit, prompt.count > limit {
            throw MediaGenerationError.invalidRequest(
                "The prompt exceeds the selected model's \(limit)-character limit."
            )
        }
    }

    private static func validateOption(
        _ value: String?,
        supported: [String],
        label: String
    ) throws {
        guard let value, !supported.isEmpty, !supported.contains(value) else { return }
        throw MediaGenerationError.invalidRequest(
            "Unsupported \(label). Expected one of: \(supported.joined(separator: ", "))."
        )
    }

    private static func requireApprovedQuote(
        _ approved: MediaVideoQuote,
        current: MediaVideoQuote
    ) throws {
        guard current.usd <= approved.usd + 0.000_001 else {
            throw MediaGenerationError.invalidRequest(
                "The video price changed from $\(String(format: "%.4f", approved.usd)) "
                    + "to $\(String(format: "%.4f", current.usd)). Review the new quote."
            )
        }
    }

    private static func isTransient(_ error: MediaGenerationError) -> Bool {
        switch error {
        case .transport: return true
        case .server(let status, _): return status == 429 || status >= 500
        default: return false
        }
    }

    private func notifyJobChanged() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .mediaJobChanged, object: nil)
        }
    }
}
