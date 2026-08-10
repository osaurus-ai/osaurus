//
//  VeniceMediaCatalog.swift
//  osaurus
//
//  Tolerant decoding for Venice's richer `/models` catalog. Venice adds
//  `type` and `model_spec` to the OpenAI-compatible model envelope.
//

import Foundation

struct VeniceModelDiscovery: Sendable, Equatable {
    var chatModelIDs: [String]
    var mediaModels: [MediaModelInfo]
}

struct VeniceModelsResponse: Decodable, Sendable {
    var data: [VeniceModelRecord]
}

struct VeniceModelRecord: Decodable, Sendable {
    var id: String
    var type: String?
    var modelSpec: VeniceModelSpec?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case modelSpec = "model_spec"
    }
}

struct VeniceModelSpec: Decodable, Sendable {
    var name: String?
    var type: String?
    var modelType: String?
    var constraints: VeniceModelConstraints?
    var pricing: VeniceModelPricing?
    var offline: Bool?
    var privacy: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case modelType = "model_type"
        case constraints
        case pricing
        case offline
        case privacy
    }
}

struct VeniceModelConstraints: Decodable, Sendable {
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
    var modelType: String?

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
        case steps
        case defaultSteps = "default_steps"
        case maxSteps = "max_steps"
        case dimensionDivisor = "dimension_divisor"
        case widthHeightDivisor
        case promptCharacterLimit
        case snakePromptCharacterLimit = "prompt_character_limit"
        case supportsAudio = "supports_audio"
        case camelSupportsAudio = "supportsAudio"
        case audio
        case audioConfigurable = "audio_configurable"
        case camelAudioConfigurable = "audioConfigurable"
        case modelType = "model_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspectRatios =
            (try? c.decode([String].self, forKey: .aspectRatios))
            ?? (try? c.decode([String].self, forKey: .snakeAspectRatios))
            ?? []
        defaultAspectRatio =
            (try? c.decode(String.self, forKey: .defaultAspectRatio))
            ?? (try? c.decode(String.self, forKey: .snakeDefaultAspectRatio))
        resolutions = (try? c.decode([String].self, forKey: .resolutions)) ?? []
        defaultResolution =
            (try? c.decode(String.self, forKey: .defaultResolution))
            ?? (try? c.decode(String.self, forKey: .snakeDefaultResolution))
        qualities =
            (try? c.decode([String].self, forKey: .qualities))
            ?? (try? c.decode([String].self, forKey: .quality))
            ?? []
        defaultQuality =
            (try? c.decode(String.self, forKey: .defaultQuality))
            ?? (try? c.decode(String.self, forKey: .snakeDefaultQuality))
        durations =
            Self.decodeStringValues(c, forKey: .durations)
            + Self.decodeStringValues(c, forKey: .duration)
        let stepLimits = try? c.decode(StepLimits.self, forKey: .steps)
        defaultSteps =
            (try? c.decode(Int.self, forKey: .defaultSteps))
            ?? (try? c.decode(Int.self, forKey: .steps))
            ?? stepLimits?.default
        maxSteps = try? c.decode(Int.self, forKey: .maxSteps)
        maxSteps = maxSteps ?? stepLimits?.max
        dimensionDivisor =
            (try? c.decode(Int.self, forKey: .widthHeightDivisor))
            ?? (try? c.decode(Int.self, forKey: .dimensionDivisor))
        promptCharacterLimit =
            (try? c.decode(Int.self, forKey: .promptCharacterLimit))
            ?? (try? c.decode(Int.self, forKey: .snakePromptCharacterLimit))
        supportsAudio =
            (try? c.decode(Bool.self, forKey: .supportsAudio))
            ?? (try? c.decode(Bool.self, forKey: .camelSupportsAudio))
            ?? (try? c.decode(Bool.self, forKey: .audio))
            ?? false
        audioConfigurable =
            (try? c.decode(Bool.self, forKey: .audioConfigurable))
            ?? (try? c.decode(Bool.self, forKey: .camelAudioConfigurable))
            ?? supportsAudio
        modelType = try? c.decode(String.self, forKey: .modelType)
    }

    private struct StepLimits: Decodable {
        let `default`: Int?
        let max: Int?
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

struct VeniceModelPricing: Decodable, Sendable {
    var generation: MediaPrice?
    var resolutions: [String: MediaPrice]
    var quality: [String: [String: MediaPrice]]

    private enum CodingKeys: String, CodingKey {
        case generation
        case resolutions
        case quality
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try? c.decode(MediaPrice.self, forKey: .generation)
        resolutions = (try? c.decode([String: MediaPrice].self, forKey: .resolutions)) ?? [:]
        quality = (try? c.decode([String: [String: MediaPrice]].self, forKey: .quality)) ?? [:]
    }
}

extension VeniceModelDiscovery {
    static func decode(
        _ data: Data,
        providerID: UUID,
        providerName: String
    ) throws -> VeniceModelDiscovery {
        let response = try JSONDecoder().decode(VeniceModelsResponse.self, from: data)
        var chatIDs: [String] = []
        var media: [MediaModelInfo] = []

        for record in response.data {
            let modelType = (record.type ?? record.modelSpec?.type ?? "text").lowercased()
            switch modelType {
            case "text":
                chatIDs.append(record.id)
            case "image":
                media.append(
                    makeMediaModel(
                        record,
                        providerID: providerID,
                        providerName: providerName,
                        kind: .image
                    )
                )
            case "video":
                guard
                    let kind = videoKind(
                        record.modelSpec?.modelType ?? record.modelSpec?.constraints?.modelType
                    ),
                    isInitialVideoWorkflow(record.id)
                else { continue }
                media.append(
                    makeMediaModel(
                        record,
                        providerID: providerID,
                        providerName: providerName,
                        kind: kind
                    )
                )
            default:
                continue
            }
        }

        return VeniceModelDiscovery(
            chatModelIDs: chatIDs.sorted(),
            mediaModels: media.sorted {
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        )
    }

    private static func videoKind(_ raw: String?) -> MediaGenerationKind? {
        switch raw?.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "text_to_video": return .textToVideo
        case "image_to_video": return .imageToVideo
        default: return nil
        }
    }

    /// Reference-to-video, transition, edit, extend, and upscale models require
    /// richer multi-input contracts and are intentionally outside the first
    /// release even when Venice groups them under image-to-video.
    private static func isInitialVideoWorkflow(_ modelID: String) -> Bool {
        let id = modelID.lowercased()
        return !["reference-to-video", "transition", "video-to-video", "upscale", "extend", "stitch"]
            .contains(where: id.contains)
    }

    private static func makeMediaModel(
        _ record: VeniceModelRecord,
        providerID: UUID,
        providerName: String,
        kind: MediaGenerationKind
    ) -> MediaModelInfo {
        let source = record.modelSpec?.constraints
        let constraints = MediaModelConstraints(
            aspectRatios: source?.aspectRatios ?? [],
            defaultAspectRatio: source?.defaultAspectRatio,
            resolutions: source?.resolutions ?? [],
            defaultResolution: source?.defaultResolution,
            qualities: source?.qualities ?? [],
            defaultQuality: source?.defaultQuality,
            durations: source?.durations ?? [],
            defaultSteps: source?.defaultSteps,
            maxSteps: source?.maxSteps,
            dimensionDivisor: source?.dimensionDivisor,
            promptCharacterLimit: source?.promptCharacterLimit,
            supportsAudio: source?.supportsAudio ?? false,
            audioConfigurable: source?.audioConfigurable ?? false
        )
        let pricing = record.modelSpec?.pricing.map {
            MediaModelPricing(
                generation: $0.generation,
                resolutions: $0.resolutions,
                quality: $0.quality
            )
        }
        return MediaModelInfo(
            target: MediaModelTarget(backend: .remoteProvider(providerID), modelID: record.id),
            displayName: record.modelSpec?.name?.nilIfBlank ?? shortDisplayName(record.id),
            providerName: providerName,
            kind: kind,
            constraints: constraints,
            pricing: pricing,
            privacy: record.modelSpec?.privacy,
            offline: record.modelSpec?.offline ?? false,
            deprecatedAt: nil
        )
    }

    private static func shortDisplayName(_ id: String) -> String {
        guard let slash = id.lastIndex(of: "/") else { return id }
        return String(id[id.index(after: slash)...])
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
