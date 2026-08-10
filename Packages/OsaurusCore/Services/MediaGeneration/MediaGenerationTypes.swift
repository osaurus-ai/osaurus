//
//  MediaGenerationTypes.swift
//  osaurus
//
//  Provider-neutral catalog, selection, request, and progress types for local
//  and hosted image/video generation.
//

import Foundation

enum MediaGenerationKind: String, Codable, Sendable, Hashable {
    case image
    case textToVideo = "text_to_video"
    case imageToVideo = "image_to_video"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased().filter(\.isLetter) {
        case "image":
            self = .image
        case "texttovideo":
            self = .textToVideo
        case "imagetovideo":
            self = .imageToVideo
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown media generation operation: \(raw)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var isVideo: Bool {
        self == .textToVideo || self == .imageToVideo
    }
}

public enum MediaGenerationBackend: Sendable, Hashable {
    case local
    case remoteProvider(UUID)
    case osaurusCloud
}

extension MediaGenerationBackend: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case providerID = "provider_id"
    }

    private enum Kind: String, Codable {
        case local
        case remoteProvider = "remote_provider"
        case osaurusCloud = "osaurus_cloud"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local:
            self = .local
        case .remoteProvider:
            self = .remoteProvider(try container.decode(UUID.self, forKey: .providerID))
        case .osaurusCloud:
            self = .osaurusCloud
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(Kind.local, forKey: .kind)
        case .remoteProvider(let providerID):
            try container.encode(Kind.remoteProvider, forKey: .kind)
            try container.encode(providerID, forKey: .providerID)
        case .osaurusCloud:
            try container.encode(Kind.osaurusCloud, forKey: .kind)
        }
    }
}

public struct MediaModelTarget: Codable, Sendable, Hashable {
    public var backend: MediaGenerationBackend
    public var modelID: String

    public init(backend: MediaGenerationBackend, modelID: String) {
        self.backend = backend
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool { !modelID.isEmpty }
}

struct MediaPrice: Codable, Sendable, Hashable {
    var usd: Double
    var diem: Double?
}

struct MediaModelPricing: Codable, Sendable, Hashable {
    var generation: MediaPrice?
    var resolutions: [String: MediaPrice]
    var quality: [String: [String: MediaPrice]]

    init(
        generation: MediaPrice? = nil,
        resolutions: [String: MediaPrice] = [:],
        quality: [String: [String: MediaPrice]] = [:]
    ) {
        self.generation = generation
        self.resolutions = resolutions
        self.quality = quality
    }

    private enum CodingKeys: String, CodingKey {
        case generation, resolutions, quality
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generation = try? container.decodeIfPresent(MediaPrice.self, forKey: .generation)
        resolutions =
            (try? container.decode([String: MediaPrice].self, forKey: .resolutions))
            ?? [:]
        quality =
            (try? container.decode([String: [String: MediaPrice]].self, forKey: .quality))
            ?? [:]
    }

    var minimumUSD: Double? {
        let values =
            [generation?.usd].compactMap { $0 }
            + resolutions.values.map(\.usd)
            + quality.values.flatMap { $0.values.map(\.usd) }
        return values.min()
    }
}

struct MediaModelConstraints: Codable, Sendable, Hashable {
    var aspectRatios: [String]
    var defaultAspectRatio: String?
    var resolutions: [String]
    var defaultResolution: String?
    var qualities: [String]
    var defaultQuality: String?
    var durations: [String]
    var defaultSteps: Int?
    var maxSteps: Int?
    var dimensionDivisor: Int?
    var promptCharacterLimit: Int?
    var supportsAudio: Bool
    var audioConfigurable: Bool

    init(
        aspectRatios: [String] = [],
        defaultAspectRatio: String? = nil,
        resolutions: [String] = [],
        defaultResolution: String? = nil,
        qualities: [String] = [],
        defaultQuality: String? = nil,
        durations: [String] = [],
        defaultSteps: Int? = nil,
        maxSteps: Int? = nil,
        dimensionDivisor: Int? = nil,
        promptCharacterLimit: Int? = nil,
        supportsAudio: Bool = false,
        audioConfigurable: Bool = false
    ) {
        self.aspectRatios = aspectRatios
        self.defaultAspectRatio = defaultAspectRatio
        self.resolutions = resolutions
        self.defaultResolution = defaultResolution
        self.qualities = qualities
        self.defaultQuality = defaultQuality
        self.durations = durations
        self.defaultSteps = defaultSteps
        self.maxSteps = maxSteps
        self.dimensionDivisor = dimensionDivisor
        self.promptCharacterLimit = promptCharacterLimit
        self.supportsAudio = supportsAudio
        self.audioConfigurable = audioConfigurable
    }

    private enum CodingKeys: String, CodingKey {
        case aspectRatios
        case snakeAspectRatios = "aspect_ratios"
        case defaultAspectRatio
        case snakeDefaultAspectRatio = "default_aspect_ratio"
        case resolutions
        case defaultResolution
        case snakeDefaultResolution = "default_resolution"
        case qualities
        case quality
        case defaultQuality
        case snakeDefaultQuality = "default_quality"
        case durations
        case duration
        case defaultSteps
        case snakeDefaultSteps = "default_steps"
        case maxSteps
        case snakeMaxSteps = "max_steps"
        case steps
        case dimensionDivisor
        case snakeDimensionDivisor = "dimension_divisor"
        case widthHeightDivisor
        case promptCharacterLimit
        case snakePromptCharacterLimit = "prompt_character_limit"
        case supportsAudio
        case snakeSupportsAudio = "supports_audio"
        case audio
        case audioConfigurable
        case snakeAudioConfigurable = "audio_configurable"
    }

    private struct StepLimits: Decodable {
        var `default`: Int?
        var max: Int?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aspectRatios =
            (try? container.decode([String].self, forKey: .aspectRatios))
            ?? (try? container.decode([String].self, forKey: .snakeAspectRatios))
            ?? []
        defaultAspectRatio =
            (try? container.decodeIfPresent(String.self, forKey: .defaultAspectRatio))
            ?? (try? container.decodeIfPresent(String.self, forKey: .snakeDefaultAspectRatio))
        resolutions = (try? container.decode([String].self, forKey: .resolutions)) ?? []
        defaultResolution =
            (try? container.decodeIfPresent(String.self, forKey: .defaultResolution))
            ?? (try? container.decodeIfPresent(String.self, forKey: .snakeDefaultResolution))
        qualities =
            (try? container.decode([String].self, forKey: .qualities))
            ?? (try? container.decode([String].self, forKey: .quality))
            ?? []
        defaultQuality =
            (try? container.decodeIfPresent(String.self, forKey: .defaultQuality))
            ?? (try? container.decodeIfPresent(String.self, forKey: .snakeDefaultQuality))
        durations =
            Self.decodeStringValues(container, forKey: .durations)
            + Self.decodeStringValues(container, forKey: .duration)
        let stepLimits = try? container.decode(StepLimits.self, forKey: .steps)
        defaultSteps =
            (try? container.decodeIfPresent(Int.self, forKey: .defaultSteps))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .snakeDefaultSteps))
            ?? stepLimits?.default
        maxSteps =
            (try? container.decodeIfPresent(Int.self, forKey: .maxSteps))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .snakeMaxSteps))
            ?? stepLimits?.max
        dimensionDivisor =
            (try? container.decodeIfPresent(Int.self, forKey: .dimensionDivisor))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .snakeDimensionDivisor))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .widthHeightDivisor))
        promptCharacterLimit =
            (try? container.decodeIfPresent(Int.self, forKey: .promptCharacterLimit))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .snakePromptCharacterLimit))
        supportsAudio =
            (try? container.decodeIfPresent(Bool.self, forKey: .supportsAudio))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .snakeSupportsAudio))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .audio))
            ?? false
        audioConfigurable =
            (try? container.decodeIfPresent(Bool.self, forKey: .audioConfigurable))
            ?? (try? container.decodeIfPresent(Bool.self, forKey: .snakeAudioConfigurable))
            ?? supportsAudio
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(aspectRatios, forKey: .aspectRatios)
        try container.encodeIfPresent(defaultAspectRatio, forKey: .defaultAspectRatio)
        try container.encode(resolutions, forKey: .resolutions)
        try container.encodeIfPresent(defaultResolution, forKey: .defaultResolution)
        try container.encode(qualities, forKey: .qualities)
        try container.encodeIfPresent(defaultQuality, forKey: .defaultQuality)
        try container.encode(durations, forKey: .durations)
        try container.encodeIfPresent(defaultSteps, forKey: .defaultSteps)
        try container.encodeIfPresent(maxSteps, forKey: .maxSteps)
        try container.encodeIfPresent(dimensionDivisor, forKey: .dimensionDivisor)
        try container.encodeIfPresent(promptCharacterLimit, forKey: .promptCharacterLimit)
        try container.encode(supportsAudio, forKey: .supportsAudio)
        try container.encode(audioConfigurable, forKey: .audioConfigurable)
    }

    private static func decodeStringValues(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [String] {
        if let strings = try? container.decode([String].self, forKey: key) {
            return strings
        }
        if let integers = try? container.decode([Int].self, forKey: key) {
            return integers.map(String.init)
        }
        if let string = try? container.decode(String.self, forKey: key) {
            return [string]
        }
        if let integer = try? container.decode(Int.self, forKey: key) {
            return [String(integer)]
        }
        return []
    }
}

struct MediaModelInfo: Codable, Identifiable, Sendable, Hashable {
    var target: MediaModelTarget
    var displayName: String
    var providerName: String
    var kind: MediaGenerationKind
    var constraints: MediaModelConstraints
    var pricing: MediaModelPricing?
    var privacy: String?
    var offline: Bool
    var deprecatedAt: Date?

    var id: String {
        switch target.backend {
        case .local:
            return "local:\(target.modelID)"
        case .remoteProvider(let providerID):
            return "provider:\(providerID.uuidString):\(target.modelID)"
        case .osaurusCloud:
            return "cloud:\(target.modelID)"
        }
    }

    var isAvailable: Bool {
        !offline && (deprecatedAt.map { $0 > Date() } ?? true)
    }
}

struct MediaImageGenerationRequest: Sendable, Equatable {
    var target: MediaModelTarget
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
    var format: ImageOutputFormat
}

struct MediaVideoGenerationRequest: Sendable, Equatable {
    var target: MediaModelTarget
    var prompt: String
    var negativePrompt: String?
    var sourceImage: Data?
    var sourceImageMIMEType: String?
    var duration: String
    var aspectRatio: String?
    var resolution: String?
    var audio: Bool?
}

struct MediaVideoQuote: Codable, Sendable, Equatable {
    var usd: Double
}

struct GeneratedMedia: Sendable, Equatable {
    var url: URL
    var mimeType: String
    var modelID: String
    var kind: MediaGenerationKind
    var settledCostUSD: Double? = nil
}

/// Price-affecting video fields bound to an HTTP quote receipt. Prompts and
/// source bytes are deliberately excluded because providers do not price from
/// their contents; only the operation (source present or absent) is relevant.
struct MediaVideoQuoteKey: Sendable, Equatable {
    var target: MediaModelTarget
    var isImageToVideo: Bool
    var duration: String
    var aspectRatio: String?
    var resolution: String?
    var audio: Bool?

    init(request: MediaVideoGenerationRequest) {
        target = request.target
        isImageToVideo = request.sourceImage != nil
        duration = request.duration
        aspectRatio = request.aspectRatio
        resolution = request.resolution
        audio = request.audio
    }
}

enum MediaGenerationEvent: Sendable, Equatable {
    case queued(jobID: String?)
    case running(progress: Double?, etaSeconds: Double?)
    case completed(GeneratedMedia)
    case failed(String)
    case cancelled
}

enum MediaGenerationError: LocalizedError, Sendable, Equatable {
    case invalidTarget
    case providerUnavailable
    case modelUnavailable(String)
    case invalidRequest(String)
    case authenticationRequired
    case insufficientFunds
    case contentPolicy(String)
    case regionRestricted
    case queuedJobContinues(String)
    case unsupported(String)
    case invalidResponse
    case transport(String)
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidTarget: return "The selected media model is invalid."
        case .providerUnavailable: return "The selected media provider is unavailable."
        case .modelUnavailable(let model): return "Media model unavailable: \(model)"
        case .invalidRequest(let message): return message
        case .authenticationRequired: return "The media provider API key is missing or invalid."
        case .insufficientFunds: return "The media provider has insufficient balance."
        case .contentPolicy(let message): return message
        case .regionRestricted: return "This media model is unavailable in your region."
        case .queuedJobContinues(let jobID):
            return "The paid video job \(jobID) is still running and will be recovered automatically."
        case .unsupported(let message): return message
        case .invalidResponse: return "The media provider returned an invalid response."
        case .transport(let message): return message
        case .server(_, let message): return message
        }
    }
}
