//
//  ImageRequestLimits.swift
//  osaurus
//
//  What an installed image bundle's engine family accepts, read from the
//  bundle's metadata (`config.json`, `model_index.json`) without loading
//  weights. The HTTP catalog, workflow steps, the step editor and the
//  Architect read these instead of a hand-kept table, and check a request
//  against them before a job unloads the chat model. Families the engine has
//  not described yet have no limits and keep `ImageModelRequestPolicy`.
//

import Foundation
import vMLXFlux

/// A nil maximum means the engine sets none; Osaurus's own caps
/// (`ImageModelRequestPolicy`) still apply on top.
public struct ImageRequestLimits: Sendable, Hashable {
    public let minimumSteps: Int
    public let maximumSteps: Int?
    /// The bundle runs a fixed schedule of this many steps; a requested
    /// step count is not used.
    public let fixedSteps: Int?
    public let dimensionMultiple: Int
    public let minimumDimension: Int
    public let maximumDimension: Int?
    public let maximumPixels: Int?
    /// Images one request may ask for; 1 means the family samples one image
    /// per request.
    public let maximumImages: Int
    public let maximumParallelImages: Int
    public let maximumSourceImages: Int
    /// Engine `ImageFormat` raw values.
    public let formats: [String]
    public let samplers: [String]
    public let schedulers: [String]
    public let defaultSampler: String?
    public let defaultScheduler: String?
    public let supportsShift: Bool
    public let supportsNegativePrompt: Bool
    public let supportsEditNegativePrompt: Bool
    public let supportsStrength: Bool
    public let supportsMask: Bool
    /// Nil means negative conditioning is consumed at any guidance.
    public let negativePromptRequiresGuidanceAbove: Float?

    public init(
        minimumSteps: Int, maximumSteps: Int? = nil, fixedSteps: Int? = nil, dimensionMultiple: Int,
        minimumDimension: Int, maximumDimension: Int? = nil, maximumPixels: Int? = nil, maximumImages: Int = 1,
        maximumParallelImages: Int = 1, maximumSourceImages: Int, formats: [String], samplers: [String] = [],
        schedulers: [String] = [], defaultSampler: String? = nil, defaultScheduler: String? = nil,
        supportsShift: Bool = false, supportsNegativePrompt: Bool = false, supportsEditNegativePrompt: Bool = false,
        supportsStrength: Bool = false, supportsMask: Bool = false, negativePromptRequiresGuidanceAbove: Float? = 1
    ) {
        self.minimumSteps = minimumSteps
        self.maximumSteps = maximumSteps
        self.fixedSteps = fixedSteps
        self.dimensionMultiple = dimensionMultiple
        self.minimumDimension = minimumDimension
        self.maximumDimension = maximumDimension
        self.maximumPixels = maximumPixels
        self.maximumImages = maximumImages
        self.maximumParallelImages = maximumParallelImages
        self.maximumSourceImages = maximumSourceImages
        self.formats = formats
        self.samplers = samplers
        self.schedulers = schedulers
        self.defaultSampler = defaultSampler
        self.defaultScheduler = defaultScheduler
        self.supportsShift = supportsShift
        self.supportsNegativePrompt = supportsNegativePrompt
        self.supportsEditNegativePrompt = supportsEditNegativePrompt
        self.supportsStrength = supportsStrength
        self.supportsMask = supportsMask
        self.negativePromptRequiresGuidanceAbove = negativePromptRequiresGuidanceAbove
    }

    /// `formats` as Osaurus output formats.
    public var outputFormats: [ImageOutputFormat] { formats.compactMap(ImageOutputFormat.init(rawValue:)) }
}

/// A request field the engine refuses, named so a caller can point at it.
/// `field` is the engine's name (`width`, `steps`, `outputFormat`, …).
public struct ImageRequestFieldError: Error, LocalizedError, Equatable, Sendable {
    public let field: String
    public let value: String
    public let allowed: String

    public var errorDescription: String? { "\(field) is \(value); allowed: \(allowed)" }
}

extension ImageRequestLimits {
    init(_ engine: FluxModelLimits) {
        self.init(
            minimumSteps: engine.minimumSteps, maximumSteps: engine.maximumSteps, fixedSteps: engine.fixedSteps,
            dimensionMultiple: engine.dimensionMultiple, minimumDimension: engine.minDimension,
            maximumDimension: engine.maxDimension, maximumPixels: engine.maxPixels,
            maximumImages: engine.maximumImages, maximumParallelImages: engine.maximumParallelImages,
            maximumSourceImages: engine.maxSourceImages, formats: engine.supportedFormats.map(\.rawValue),
            samplers: engine.samplers, schedulers: engine.schedulers, defaultSampler: engine.defaultSampler,
            defaultScheduler: engine.defaultScheduler, supportsShift: engine.supportsShift,
            supportsNegativePrompt: engine.supportsNegativePrompt,
            supportsEditNegativePrompt: engine.supportsEditNegativePrompt, supportsStrength: engine.supportsStrength,
            supportsMask: engine.supportsMask,
            negativePromptRequiresGuidanceAbove: engine.negativePromptRequiresGuidanceAbove)
    }

    private var engine: FluxModelLimits {
        FluxModelLimits(
            dimensionMultiple: dimensionMultiple, minDimension: minimumDimension, maxDimension: maximumDimension,
            maxPixels: maximumPixels, minimumSteps: minimumSteps, maximumSteps: maximumSteps, fixedSteps: fixedSteps,
            supportsNegativePrompt: supportsNegativePrompt, supportsEditNegativePrompt: supportsEditNegativePrompt,
            supportsStrength: supportsStrength, supportsMask: supportsMask, maxSourceImages: maximumSourceImages,
            supportedFormats: formats.compactMap(ImageFormat.init(rawValue:)), maximumImages: maximumImages,
            maximumParallelImages: maximumParallelImages,
            negativePromptRequiresGuidanceAbove: negativePromptRequiresGuidanceAbove, samplers: samplers,
            schedulers: schedulers, defaultSampler: defaultSampler, defaultScheduler: defaultScheduler,
            supportsShift: supportsShift)
    }

    /// The registered family's limits for a bundle, or nil when the family
    /// publishes none or the bundle's metadata is unreadable. The engine
    /// registry must already be populated.
    static func forBundle(canonical: String, directory: URL) -> ImageRequestLimits? {
        guard let query = ModelRegistry.lookup(name: canonical)?.limits else { return nil }
        return (try? query(directory)).map(ImageRequestLimits.init)
    }

    /// The sampling choices a request makes, checked with the size and steps.
    public struct Sampling: Sendable, Equatable {
        public var sampler: String?
        public var scheduler: String?
        public var shift: Float?
        public var previewInterval: Int?
        public var previewMaxPixel: Int

        public init(
            sampler: String? = nil, scheduler: String? = nil, shift: Float? = nil, previewInterval: Int? = nil,
            previewMaxPixel: Int = 256
        ) {
            self.sampler = sampler
            self.scheduler = scheduler
            self.shift = shift
            self.previewInterval = previewInterval
            self.previewMaxPixel = previewMaxPixel
        }
    }

    public func validateGenerate(
        width: Int, height: Int, steps: Int, guidance: Float, negativePrompt: String?, format: ImageOutputFormat,
        numImages: Int = 1, seeds: [UInt64]? = nil, batchSize: Int = 1, sampling: Sampling = Sampling()
    ) throws {
        let request = ImageGenRequest(
            prompt: "", negativePrompt: negativePrompt, width: width, height: height, steps: steps, guidance: guidance,
            numImages: numImages, seeds: seeds, batchSize: batchSize, outputDir: FileManager.default.temporaryDirectory,
            outputFormat: ImageFormat(rawValue: format.rawValue) ?? .png, sampler: sampling.sampler,
            scheduler: sampling.scheduler, shift: sampling.shift, previewInterval: sampling.previewInterval,
            previewMaxPixel: sampling.previewMaxPixel)
        try Self.namingField { try engine.validate(request) }
    }

    public func validateEdit(
        width: Int?, height: Int?, steps: Int, guidance: Float, format: ImageOutputFormat, sourceCount: Int,
        hasMask: Bool, strength: Float?, negativePrompt: String? = nil, sampling: Sampling = Sampling()
    ) throws {
        try Self.namingField {
            try engine.validatePreview(interval: sampling.previewInterval, maxPixel: sampling.previewMaxPixel)
            try engine.validateSampling(sampler: sampling.sampler, scheduler: sampling.scheduler, shift: sampling.shift)
            try engine.validateEdit(
                width: width, height: height, steps: steps, guidance: guidance,
                format: ImageFormat(rawValue: format.rawValue) ?? .png, sourceCount: sourceCount, hasMask: hasMask,
                strength: strength, negativePrompt: negativePrompt)
        }
    }

    /// The sampler, scheduler, or shift the engine refuses, if any.
    public func samplingRefusal(_ sampling: Sampling) -> ImageRequestFieldError? {
        do {
            try Self.namingField {
                try engine.validateSampling(sampler: sampling.sampler, scheduler: sampling.scheduler, shift: sampling.shift)
            }
            return nil
        } catch {
            return error as? ImageRequestFieldError
        }
    }

    /// The upscale envelope for families that publish one (SeedVR2: scale,
    /// format, and output pixels including its padded canvas). Other
    /// upscalers pass.
    public static func validateUpscale(
        canonical: String?, sourceWidth: Int, sourceHeight: Int, scale: Int, format: ImageOutputFormat
    ) throws {
        guard canonical == "seedvr2" else { return }
        try namingField {
            try SeedVR2BundleMetadata.validateUpscale(
                sourceWidth: sourceWidth, sourceHeight: sourceHeight, scale: scale,
                format: ImageFormat(rawValue: format.rawValue) ?? .png)
        }
    }

    private static func namingField(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch FluxError.invalidField(let field, let value, let allowed) {
            throw ImageRequestFieldError(field: field, value: value, allowed: allowed)
        }
    }
}
