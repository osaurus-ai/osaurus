//
//  OsaurusCloudMediaClient.swift
//  osaurus
//

import Foundation

struct CloudMediaCatalogResponse: Codable, Sendable {
    var version: String
    var models: [CloudMediaModelDTO]
}

struct CloudMediaModelDTO: Codable, Sendable {
    var id: String
    var displayName: String
    var operation: MediaGenerationKind?
    var constraints: MediaModelConstraints
    var pricing: MediaModelPricing?
    var privacy: String?
    var offline: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case operation, constraints, pricing, privacy, offline
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        operation = try? c.decode(MediaGenerationKind.self, forKey: .operation)
        constraints =
            (try? c.decode(MediaModelConstraints.self, forKey: .constraints))
            ?? MediaModelConstraints()
        pricing = try? c.decodeIfPresent(MediaModelPricing.self, forKey: .pricing)
        privacy = try? c.decodeIfPresent(String.self, forKey: .privacy)
        offline = (try? c.decode(Bool.self, forKey: .offline)) ?? false
    }

    var modelInfo: MediaModelInfo? {
        guard let operation else { return nil }
        return MediaModelInfo(
            target: MediaModelTarget(backend: .osaurusCloud, modelID: id),
            displayName: displayName,
            providerName: "Osaurus",
            kind: operation,
            constraints: constraints,
            pricing: pricing,
            privacy: privacy,
            offline: offline,
            deprecatedAt: nil
        )
    }
}

struct CloudImageGenerationBody: Encodable, Sendable {
    var idempotencyKey: String
    var model: String
    var prompt: String
    var negativePrompt: String?
    var width: Int?
    var height: Int?
    var aspectRatio: String?
    var resolution: String?
    var quality: String?
    var steps: Int?
    var guidance: Double?
    var seed: Int?
    var count: Int
    var format: String

    private enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case model, prompt, width, height, resolution, quality, steps, guidance, seed, count, format
        case negativePrompt = "negative_prompt"
        case aspectRatio = "aspect_ratio"
    }
}

struct CloudImageGenerationResponse: Decodable, Sendable {
    var images: [String]
    var billing: CloudMediaBilling
}

struct CloudMediaBilling: Codable, Sendable, Equatable {
    var exactCostMicroUSD: String
    var balanceAfterMicroUSD: String?
    var usageID: String

    private enum CodingKeys: String, CodingKey {
        case exactCostMicroUSD = "exact_cost_micro_usd"
        case balanceAfterMicroUSD = "balance_after_micro_usd"
        case usageID = "usage_id"
    }
}

struct CloudVideoQuoteBody: Encodable, Sendable {
    var model: String
    var duration: String
    var aspectRatio: String?
    var resolution: String?
    var audio: Bool?

    private enum CodingKeys: String, CodingKey {
        case model, duration, resolution, audio
        case aspectRatio = "aspect_ratio"
    }
}

struct CloudVideoQuoteResponse: Decodable, Sendable {
    var quoteMicroUSD: String
    var quoteID: String
    var expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case quoteMicroUSD = "quote_micro_usd"
        case quoteID = "quote_id"
        case expiresAt = "expires_at"
    }
}

struct CloudVideoJobBody: Encodable, Sendable {
    var idempotencyKey: String
    var quoteID: String
    var model: String
    var prompt: String
    var negativePrompt: String?
    var duration: String
    var aspectRatio: String?
    var resolution: String?
    var audio: Bool?
    var imageDataURL: String?

    private enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case quoteID = "quote_id"
        case model, prompt, duration, resolution, audio
        case negativePrompt = "negative_prompt"
        case aspectRatio = "aspect_ratio"
        case imageDataURL = "image_url"
    }
}

struct CloudVideoJobResponse: Codable, Sendable {
    var jobID: String
    var status: String
    var etaSeconds: Double?
    var billing: CloudMediaBilling?

    private enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case status
        case etaSeconds = "eta_seconds"
        case billing
    }
}

enum OsaurusCloudMediaAvailability: Sendable {
    case available([MediaModelInfo])
    case unsupported
}

actor OsaurusCloudMediaClient {
    private let router: OsaurusRouterAPIClient

    init(router: OsaurusRouterAPIClient = .shared) {
        self.router = router
    }

    func catalog() async throws -> OsaurusCloudMediaAvailability {
        do {
            let response = try await router.cloudMediaCatalog()
            return .available(response.models.compactMap(\.modelInfo))
        } catch let error as OsaurusRouterAPIError {
            if case .server(_, _, let status) = error, status == 404 {
                return .unsupported
            }
            throw Self.map(error)
        }
    }

    func generateImage(_ request: MediaImageGenerationRequest) async throws -> [GeneratedMedia] {
        let idempotencyKey = UUID().uuidString.lowercased()
        let response: CloudImageGenerationResponse
        do {
            response = try await router.cloudGenerateImage(
                CloudImageGenerationBody(
                    idempotencyKey: idempotencyKey,
                    model: request.target.modelID,
                    prompt: request.prompt,
                    negativePrompt: request.negativePrompt,
                    width: request.width,
                    height: request.height,
                    aspectRatio: request.aspectRatio,
                    resolution: request.resolution,
                    quality: request.quality,
                    steps: request.steps,
                    guidance: request.guidance,
                    seed: request.seed,
                    count: request.count,
                    format: request.format.rawValue
                )
            )
        } catch let error as OsaurusRouterAPIError {
            throw Self.map(error)
        }
        guard !response.images.isEmpty, response.images.count <= max(1, request.count) else {
            throw MediaGenerationError.invalidResponse
        }
        let settledCostUSD = Self.usd(fromMicroUSD: response.billing.exactCostMicroUSD)
        return try response.images.enumerated().map { index, payload in
            let encoded = payload.split(separator: ",", maxSplits: 1).last.map(String.init) ?? payload
            guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
                throw MediaGenerationError.invalidResponse
            }
            try MediaFileValidation.validateImage(data, expectedFormat: request.format)
            let directory = OsaurusPaths.generatedImages()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let usageID = MediaFileValidation.safeFileComponent(
                response.billing.usageID,
                fallback: UUID().uuidString.lowercased()
            )
            let url = directory.appendingPathComponent(
                "osaurus-\(usageID)-\(index + 1).\(request.format.rawValue)"
            )
            try data.write(to: url, options: .atomic)
            return GeneratedMedia(
                url: url,
                mimeType: "image/\(request.format.rawValue)",
                modelID: request.target.modelID,
                kind: .image,
                settledCostUSD: settledCostUSD
            )
        }
    }

    func quoteVideo(_ request: MediaVideoGenerationRequest) async throws -> CloudVideoQuoteResponse {
        do {
            return try await router.cloudQuoteVideo(
                CloudVideoQuoteBody(
                    model: request.target.modelID,
                    duration: request.duration,
                    aspectRatio: request.aspectRatio,
                    resolution: request.resolution,
                    audio: request.audio
                )
            )
        } catch let error as OsaurusRouterAPIError {
            throw Self.map(error)
        }
    }

    func queueVideo(
        _ request: MediaVideoGenerationRequest,
        quoteID: String,
        idempotencyKey: String
    ) async throws -> CloudVideoJobResponse {
        let dataURL = request.sourceImage.map {
            "data:\(request.sourceImageMIMEType ?? "image/png");base64,\($0.base64EncodedString())"
        }
        do {
            return try await router.cloudQueueVideo(
                CloudVideoJobBody(
                    idempotencyKey: idempotencyKey,
                    quoteID: quoteID,
                    model: request.target.modelID,
                    prompt: request.prompt,
                    negativePrompt: request.negativePrompt,
                    duration: request.duration,
                    aspectRatio: request.aspectRatio,
                    resolution: request.resolution,
                    audio: request.audio,
                    imageDataURL: dataURL
                )
            )
        } catch let error as OsaurusRouterAPIError {
            throw Self.map(error)
        }
    }

    func job(_ id: String) async throws -> CloudVideoJobResponse {
        do {
            return try await router.cloudVideoJob(id: id)
        } catch let error as OsaurusRouterAPIError {
            throw Self.map(error)
        }
    }

    func downloadAndCleanup(
        jobID: String,
        modelID: String,
        kind: MediaGenerationKind
    ) async throws -> (media: GeneratedMedia, cleanupSucceeded: Bool) {
        let temporaryURL: URL
        do {
            temporaryURL = try await router.cloudVideoContent(jobID: jobID)
        } catch let error as OsaurusRouterAPIError {
            throw Self.map(error)
        }
        try MediaFileValidation.validateVideo(at: temporaryURL)
        let directory = OsaurusPaths.generatedVideos()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeJobID = MediaFileValidation.safeFileComponent(
            jobID,
            fallback: UUID().uuidString.lowercased()
        )
        let url = directory.appendingPathComponent("osaurus-\(safeJobID).mp4")
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: temporaryURL, to: staging)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: staging, to: url)
        let cleanupSucceeded = await cleanupVideo(jobID: jobID)
        return (
            GeneratedMedia(url: url, mimeType: "video/mp4", modelID: modelID, kind: kind),
            cleanupSucceeded
        )
    }

    func cleanupVideo(jobID: String) async -> Bool {
        do {
            try await router.cloudDeleteVideoContent(jobID: jobID)
            return true
        } catch {
            return false
        }
    }

    private static func map(_ error: OsaurusRouterAPIError) -> MediaGenerationError {
        switch error {
        case .insufficientFunds: return .insufficientFunds
        case .unauthorized, .noIdentity: return .authenticationRequired
        case .accountFrozen: return .server(status: 403, message: error.localizedDescription)
        case .rateLimited: return .server(status: 429, message: error.localizedDescription)
        case .idempotencyConflict:
            return .invalidRequest("The Cloud idempotency key was reused with different media.")
        case .transport(let message): return .transport(message)
        case .server(let code, let message, let status):
            switch code {
            case "CONTENT_POLICY": return .contentPolicy(message)
            case "REGION_RESTRICTED": return .regionRestricted
            case "MODEL_UNAVAILABLE", "JOB_NOT_FOUND": return .modelUnavailable(message)
            case "INVALID_REQUEST", "QUOTE_EXPIRED", "QUOTE_MISMATCH", "UNSUPPORTED_OPERATION":
                return .invalidRequest(message)
            default: return .server(status: status, message: message)
            }
        default: return .transport(error.localizedDescription)
        }
    }

    private static func usd(fromMicroUSD value: String) -> Double? {
        guard let micro = Decimal(string: value) else { return nil }
        return NSDecimalNumber(decimal: micro / 1_000_000).doubleValue
    }
}
