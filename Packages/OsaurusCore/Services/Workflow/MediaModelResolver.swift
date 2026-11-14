//
//  MediaModelResolver.swift
//  osaurus
//
//  Which installed or connected model a media step runs on. A step names a
//  family (`qwen-image-2.1`), an exact id, or nothing (the person's default
//  image model), plus where it may run. Setup, the run, and the Architect's
//  `media_models` action all resolve through here, so "Setup says ready"
//  and "the run found a model" never disagree.
//

import Foundation

/// One model a media step could run on.
struct MediaModelCandidate: Equatable, Sendable, Identifiable {
    /// Local image: the installed bundle id. Video and remote: `MediaModelInfo.id`.
    var id: String
    var displayName: String
    /// Local: the bundle's canonical family (`qwen-image-2.1`).
    var family: String?
    var isLocal: Bool
    var ready: Bool
    /// Local only.
    var capabilities: ImageModelCapabilities?
    var defaultSteps: Int?
    var defaultGuidance: Float?
    /// Local only: the engine's request limits, when its family has them.
    var limits: ImageRequestLimits? = nil
    /// Remote models and local video models.
    var media: MediaModelInfo?

    var target: MediaModelTarget { media?.target ?? MediaModelTarget(backend: .local, modelID: id) }

    func supports(_ action: MediaAction) -> Bool {
        guard ready else { return false }
        switch action {
        case .generate: return isLocal ? capabilities?.textToImage == true : media?.kind == .image
        case .edit: return isLocal && capabilities?.imageEdit == true
        case .upscale: return isLocal && capabilities?.upscale == true
        case .video: return media?.kind.isVideo == true
        }
    }

    private var makesImages: Bool { capabilities?.textToImage == true || capabilities?.imageEdit == true }

    /// The largest side a step may ask for: the engine's maximum tightened
    /// by the app's capacity cap (2048 for Qwen-Image 2.1, 1024 otherwise).
    var maxDimension: Int? {
        guard makesImages else { return limits?.maximumDimension }
        let cap = ImageModelRequestPolicy.isQwen21Family(family) ? ImageModelRequestPolicy.q21MaximumDimension : 1024
        return min(limits?.maximumDimension ?? cap, cap)
    }

    var maxSteps: Int? {
        guard makesImages else { return limits?.maximumSteps }
        return min(limits?.maximumSteps ?? 50, 50)
    }

    /// The nearest size this model takes when `value` is off its engine
    /// grid, else nil. Nil too when the engine publishes no limits.
    func sizeFix(_ value: Int) -> Int? {
        guard let l = limits else { return nil }
        let step = max(1, l.dimensionMultiple)
        let maximum = (maxDimension ?? Int.max) / step * step
        guard value % step != 0 || value < l.minimumDimension || value > maximum else { return nil }
        let rounded = Int((Double(value) / Double(step)).rounded()) * step
        return min(maximum, max(l.minimumDimension, rounded))
    }

    /// What the step's fields can be for this model, for the editor and the
    /// Architect.
    var constraintsSummary: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if let l = limits {
            out["dimension_multiple"] = .number(Double(l.dimensionMultiple))
            out["min_dimension"] = .number(Double(l.minimumDimension))
            if let max = maxDimension { out["max_dimension"] = .number(Double(max)) }
            if let pixels = l.maximumPixels { out["max_pixels"] = .number(Double(pixels)) }
            out["min_steps"] = .number(Double(l.minimumSteps))
            if let max = maxSteps { out["max_steps"] = .number(Double(max)) }
            if let fixed = l.fixedSteps { out["fixed_steps"] = .number(Double(fixed)) }
            out["negative_prompt"] = .bool(l.supportsNegativePrompt)
            out["edit_strength"] = .bool(l.supportsStrength)
            out["max_sources"] = .number(Double(min(l.maximumSourceImages, MediaSpec.maximumSources)))
            out["formats"] = .array(l.formats.map(JSONValue.string))
            out["png_only"] = .bool(l.formats == [ImageOutputFormat.png.rawValue])
            out["max_images"] = .number(Double(min(l.maximumImages, MediaSpec.maximumCount)))
            out["max_parallel_images"] = .number(Double(l.maximumParallelImages))
            if !l.samplers.isEmpty { out["samplers"] = .array(l.samplers.map(JSONValue.string)) }
            if !l.schedulers.isEmpty { out["schedulers"] = .array(l.schedulers.map(JSONValue.string)) }
            if let v = l.defaultSampler { out["default_sampler"] = .string(v) }
            if let v = l.defaultScheduler { out["default_scheduler"] = .string(v) }
            out["shift"] = .bool(l.supportsShift)
        } else if let c = capabilities {
            out["dimension_multiple"] = .number(Double(c.dimensionMultiple))
            out["negative_prompt"] = .bool(c.negativePrompt)
            out["edit_strength"] = .bool(c.editStrength)
            out["multiple_sources"] = .bool(c.multipleSourceImages)
            out["max_dimension"] = .number(Double(maxDimension ?? 1024))
            out["png_only"] = .bool(ImageModelRequestPolicy.isQwen21Family(family))
        }
        if let s = defaultSteps { out["default_steps"] = .number(Double(s)) }
        if let g = defaultGuidance { out["default_guidance"] = .number(Double(g)) }
        if let c = media?.constraints {
            if !c.durations.isEmpty { out["durations"] = .array(c.durations.map(JSONValue.string)) }
            if !c.resolutions.isEmpty { out["resolutions"] = .array(c.resolutions.map(JSONValue.string)) }
            if !c.aspectRatios.isEmpty { out["aspect_ratios"] = .array(c.aspectRatios.map(JSONValue.string)) }
            if c.audioConfigurable { out["audio"] = .bool(true) }
            if let limit = c.promptCharacterLimit { out["prompt_character_limit"] = .number(Double(limit)) }
            if isLocal {
                out["frame_rule"] = .string("frame_count is 4n+1 and equals duration × fps (49 frames at 16 fps)")
                out["default_fps"] = .number(16)
                if let s = c.defaultSteps { out["default_steps"] = .number(Double(s)) }
                if let d = c.dimensionDivisor { out["dimension_multiple"] = .number(Double(d)) }
                out["audio"] = .bool(false)
                out["source_image"] = .bool(media?.kind == .imageToVideo)
            }
        }
        if let price = media?.pricing?.minimumUSD { out["minimum_usd"] = .number(price) }
        return out
    }
}

enum MediaModelResolver {

    enum Failure: Error, Equatable, LocalizedError {
        /// Nothing here can do this action at all.
        case noneInstalled(MediaAction, MediaLocality)
        /// The named family or id is not here (or cannot do the action).
        case notFound(MediaAction, String)

        var errorDescription: String? {
            switch self {
            case .noneInstalled(let action, let locality):
                switch action {
                case .video where locality == .local:
                    return L("No local video model is installed. Download a Wan 2.1 bundle in Local Models → Image.")
                case .video:
                    return L("No video model is installed or connected. Download a Wan 2.1 bundle in Local Models → Image, or choose a provider model in Model Defaults → Images & Video.")
                case .generate where locality == .remote:
                    return L("No remote image model is connected. Connect a provider in Model Defaults → Images & Video.")
                case .generate:
                    return L("No image generation model is installed. Download one in Local Models → Image.")
                case .edit:
                    return L("No image editing model is installed. Download one in Local Models → Image.")
                case .upscale:
                    return L("No image upscaling model is installed. Download one in Local Models → Image.")
                }
            case .notFound(let action, let name):
                return L("\(name) is not installed or cannot \(MediaModelResolver.verb(action)) here. Install it in Local Models → Image, or pick another model for this step.")
            }
        }
    }

    static func verb(_ action: MediaAction) -> String {
        switch action {
        case .generate: return L("make images")
        case .edit: return L("edit images")
        case .upscale: return L("upscale images")
        case .video: return L("make videos")
        }
    }

    /// Candidates from the model picker's items: ready local image and
    /// video bundles and available remote image/video models.
    static func candidates(from items: [ModelPickerItem]) -> [MediaModelCandidate] {
        var out: [MediaModelCandidate] = []
        for item in items {
            if let media = item.mediaModel, media.target.backend == .local {
                guard media.kind.isVideo else { continue }
                out.append(
                    MediaModelCandidate(
                        id: media.id, displayName: media.displayName, family: nil, isLocal: true,
                        ready: media.isAvailable, defaultSteps: media.constraints.defaultSteps, media: media))
            } else if item.source.isImageGeneration {
                out.append(
                    MediaModelCandidate(
                        id: item.id, displayName: item.displayName, family: item.imageCanonicalName, isLocal: true,
                        ready: item.imageReady, capabilities: item.imageCapabilities,
                        defaultSteps: item.imageDefaultSteps, defaultGuidance: item.imageDefaultGuidance,
                        limits: item.imageRequestLimits))
            } else if let media = item.mediaModel, media.target.backend != .local {
                out.append(
                    MediaModelCandidate(
                        id: media.id, displayName: media.displayName, family: nil, isLocal: false,
                        ready: media.isAvailable, media: media))
            }
        }
        return out
    }

    @MainActor
    static func liveCandidates() -> [MediaModelCandidate] {
        candidates(from: ModelPickerItemCache.shared.items)
    }

    /// The live candidates once the model cache has loaded. Until its first
    /// build finishes the cache is empty, which reads as "no model".
    @MainActor
    static func loadedLiveCandidates() async -> [MediaModelCandidate] {
        if !ModelPickerItemCache.shared.isLoaded { await ModelPickerItemCache.shared.prewarmModelCache() }
        return liveCandidates()
    }

    /// "Qwen-Image 2.1" and "qwen-image-2.1" are the same family.
    static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func matches(_ candidate: MediaModelCandidate, id: String) -> Bool {
        let wanted = id.lowercased()
        return candidate.id.lowercased() == wanted
            || candidate.target.modelID.lowercased() == wanted
            || candidate.displayName.lowercased() == wanted
            || candidate.family?.lowercased() == wanted
    }

    static func matches(_ candidate: MediaModelCandidate, family: String) -> Bool {
        let wanted = normalized(family)
        guard !wanted.isEmpty else { return false }
        if let f = candidate.family, normalized(f) == wanted { return true }
        if let f = candidate.family.flatMap({ ImageModelRequestPolicy.catalogCanonical($0) }), normalized(f) == wanted {
            return true
        }
        return normalized(candidate.target.modelID).contains(wanted) || normalized(candidate.displayName).contains(wanted)
    }

    /// The model for `selector` doing `action`. `preferred` is the
    /// person's configured default for the action (a picker id), used when
    /// the selector names nothing. Local beats remote under `.any`.
    static func resolve(
        _ selector: MediaModelSelector, action: MediaAction, candidates: [MediaModelCandidate],
        preferred: String? = nil
    ) -> Result<MediaModelCandidate, Failure> {
        let locality = selector.locality
        let pool = candidates.filter { c in
            c.supports(action) && (c.isLocal ? locality.allowsLocal : locality.allowsRemote)
        }.sorted { a, b in a.isLocal && !b.isLocal }

        if let id = selector.id {
            if let hit = pool.first(where: { matches($0, id: id) }) { return .success(hit) }
            return .failure(.notFound(action, id))
        }
        if let family = selector.family {
            // An exact family beats a substring of a longer one
            // (`qwen-image-2.1` over `qwen-image-2.1-turbo`).
            let exact = pool.first { c in c.family.map { normalized($0) == normalized(family) } ?? false }
            if let hit = exact ?? pool.first(where: { matches($0, family: family) }) { return .success(hit) }
            return .failure(.notFound(action, family))
        }
        if let preferred, let hit = pool.first(where: { matches($0, id: preferred) }) { return .success(hit) }
        if let first = pool.first { return .success(first) }
        return .failure(.noneInstalled(action, locality))
    }

    /// Why a workflow's media requirement cannot run here, or nil.
    static func blockReason(_ requirement: MediaModelRequirement, candidates: [MediaModelCandidate]) -> String? {
        switch resolve(requirement.model, action: requirement.action, candidates: candidates) {
        case .success: return nil
        case .failure(let failure): return failure.localizedDescription
        }
    }

    /// The person's configured default model for an action, as a picker id.
    static func configuredDefault(for action: MediaAction) -> String? {
        let config = SubagentConfigurationStore.snapshot()
        switch action {
        case .generate:
            if let target = config.defaultImageGenerationTarget {
                switch target.backend {
                case .local: return target.modelID
                case .remoteProvider(let id): return "provider:\(id.uuidString):\(target.modelID)"
                case .osaurusCloud: return "cloud:\(target.modelID)"
                }
            }
            return config.defaultImageGenerationModelId
        case .edit: return config.defaultImageEditModelId
        case .upscale, .video: return nil
        }
    }
}
