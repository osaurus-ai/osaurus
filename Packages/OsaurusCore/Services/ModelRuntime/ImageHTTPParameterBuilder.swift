import Foundation
import ImageIO

/// Local HTTP job plus the request parameters resolved for its actual installed bundle.
/// Final activity logs merge these facts, so wide Q21 requests are not reported
/// as their former 1024-clamped dimensions. No deferred/shared snapshot state.
struct ImageHTTPPreparedJob: Sendable {
    let stream: AsyncThrowingStream<ImageGenerationEvent, Error>
    var width: Int? = nil
    var height: Int? = nil
    var sourceCount: Int? = nil

    var activityDetails: [String: String] {
        var result: [String: String] = [:]
        if let width, let height { result["size"] = "\(width)x\(height)" }
        if let sourceCount { result["source_images"] = String(sourceCount) }
        return result
    }

    static func failure(_ message: String) -> Self {
        Self(stream: AsyncThrowingStream { continuation in
            continuation.yield(.failed(message: message, hfAuth: false))
            continuation.finish()
        })
    }
}

/// The existing endpoint envelope is retained for older image families.
/// Q21 consumes explicit supported values without rounding or step clamping.
/// Classification is exclusively the resolved ImageModelInfo canonical field.
enum ImageHTTPParameterBuilder {
    /// Provider adapters currently accept one base seed, not native seed arrays
    /// or GPU batch sizing. Reject these before any billable remote request.
    static func validateRemoteBatch(_ request: ImageGenerationRequestDTO) throws {
        guard request.seeds == nil, request.batch_size == nil,
            request.sampler == nil, request.scheduler == nil, request.shift == nil,
            request.preview_interval == nil, request.preview_max_pixel == nil, request.adapters == nil else {
            throw ImageGenerationError.invalidRequest("seeds, batch_size, sampler, scheduler, shift, adapters and previews require a local image model")
        }
    }

    static func limits(for info: ImageModelInfo) -> ImageLimitsDTO {
        limits(canonicalName: info.canonicalName, capabilities: info.capabilities, runtime: info.requestLimits)
    }

    /// The same limits from a picker item's fields, for `/models/picker`.
    static func limits(canonicalName: String?, capabilities: ImageModelCapabilities,
                       runtime: ImageRequestLimits? = nil) -> ImageLimitsDTO {
        if let runtime {
            return ImageLimitsDTO(min_steps: runtime.minimumSteps, max_steps: runtime.maximumSteps,
                size_multiple: runtime.dimensionMultiple, max_pixels: runtime.maximumPixels,
                supported_sizes: [], min_dimension: runtime.minimumDimension,
                max_dimension: runtime.maximumDimension, fixed_steps: runtime.fixedSteps,
                max_images: runtime.maximumImages, max_source_images: runtime.maximumSourceImages,
                formats: runtime.formats, samplers: runtime.samplers, schedulers: runtime.schedulers)
        }
        let q21 = ImageModelRequestPolicy.isQwen21Family(canonicalName)
        return ImageLimitsDTO(min_steps: q21 ? 2 : 1, max_steps: 50,
            size_multiple: capabilities.dimensionMultiple,
            max_pixels: q21 ? 2048 * 2048 : 1024 * 1024,
            supported_sizes: q21
                ? ["512x512", "768x768", "1024x1024", "1248x832", "2048x2048"]
                : ["512x512", "768x768", "1024x1024"])
    }

    static func generation(_ request: ImageGenerationRequestDTO, info: ImageModelInfo) throws
        -> ImageGenerationParameters
    {
        let q21 = ImageModelRequestPolicy.isQwen21Family(info.canonicalName)
        let (width, height) = try dimensions(size: request.size, width: request.width,
            height: request.height, isQwen21: q21)
        return ImageGenerationParameters(model: info.id, prompt: request.prompt,
            negativePrompt: request.negative_prompt, width: width, height: height,
            steps: request.steps,
            guidance: request.guidance.map(Float.init), seed: request.seed,
            numImages: request.n ?? 1, seeds: request.seeds, batchSize: request.batch_size ?? 1, outputFormat: try outputFormat(request.output_format, isQwen21: q21),
            sampler: request.sampler, scheduler: request.scheduler, shift: request.shift,
            previewInterval: request.preview_interval, previewMaxPixel: request.preview_max_pixel ?? 256, adapters: request.adapters ?? [])
    }

    static func edit(_ request: ImageEditRequestDTO, info: ImageModelInfo, decodedSources: [Data?]) throws
        -> ImageEditParameters
    {
        let q21 = ImageModelRequestPolicy.isQwen21Family(info.canonicalName)
        let rawCount = (request.images ?? [request.image].compactMap { $0 }).count
        let sources: [Data]
        if q21 {
            guard request.mask == nil else {
                throw ImageGenerationError.invalidRequest("mask editing is not supported by this model")
            }
            guard decodedSources.count == rawCount,
                rawCount > 0, decodedSources.allSatisfy({ $0 != nil })
            else { throw ImageGenerationError.invalidRequest("edit requires valid ordered source images") }
            sources = decodedSources.compactMap { $0 }
            try validateSourceImages(sources)
        } else {
            guard decodedSources.count == rawCount, rawCount > 0, decodedSources.allSatisfy({ $0 != nil }) else {
                throw ImageGenerationError.invalidRequest("edit requires valid ordered source images")
            }
            sources = decodedSources.compactMap { $0 }
            try validateSourceImages(sources)
        }
        let (width, height) = try dimensions(size: request.size, width: request.width,
            height: request.height, isQwen21: q21)
        return ImageEditParameters(model: info.id, prompt: request.prompt, sourceImages: sources,
            negativePrompt: request.negative_prompt, strength: request.strength.map(Float.init),
            width: width, height: height,
            steps: request.steps,
            guidance: request.guidance.map(Float.init), seed: request.seed,
            outputFormat: try outputFormat(request.output_format, isQwen21: q21),
            sampler: request.sampler, scheduler: request.scheduler, shift: request.shift,
            previewInterval: request.preview_interval, previewMaxPixel: request.preview_max_pixel ?? 256, adapters: request.adapters ?? [])
    }

    static func dimensions(size: String?, width: Int?, height: Int?, isQwen21: Bool) throws -> (Int?, Int?) {
        var fromSize: (Int, Int)?
        if let size {
            let parts = size.lowercased().split(separator: "x", omittingEmptySubsequences: false)
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
                throw ImageGenerationError.invalidRequest("size must be a valid WIDTHxHEIGHT pair")
            }
            fromSize = (width, height)
        }
        // Explicit duplicate representations must agree. Neither a partial
        // dimension nor a size pair may silently disappear behind the other.
        if let fromSize {
            guard width == nil || width == fromSize.0, height == nil || height == fromSize.1 else {
                throw ImageGenerationError.invalidRequest("explicit dimensions conflict with size")
            }
            return (fromSize.0, fromSize.1)
        }
        return (width, height)
    }

    static func validateSourceImages(_ sources: [Data]) throws {
        for (index, data) in sources.enumerated() {
            guard !data.isEmpty, data.count <= 80 * 1024 * 1024,
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCache: false] as CFDictionary) != nil
            else {
                throw ImageGenerationError.invalidRequest("source image \(index + 1) is invalid or exceeds 80 MB")
            }
        }
    }

    private static func outputFormat(_ raw: String?, isQwen21: Bool) throws -> ImageOutputFormat {
        if isQwen21, let raw, raw.lowercased() != "png" {
            throw ImageGenerationError.invalidRequest("Qwen-Image-2.1 supports PNG output only")
        }
        switch raw?.lowercased() {
        case "jpeg", "jpg": return .jpeg
        case "webp": return .webp
        default: return .png
        }
    }
}
