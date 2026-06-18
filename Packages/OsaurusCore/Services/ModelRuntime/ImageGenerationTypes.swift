//
//  ImageGenerationTypes.swift
//  osaurus
//
//  Osaurus-native request / event / catalog types for on-device image
//  generation. These deliberately do NOT expose any vMLXFlux symbols so the
//  HTTP layer and the chat UI can consume them without importing the engine
//  (only `ImageGenerationService` links vMLXFlux). The service translates
//  between these and the engine's `ImageGenRequest` / `ImageGenEvent`.
//

import Foundation

/// Output container format. PNG is the only fully-wired writer in the engine
/// today; jpeg/webp are accepted for forward compatibility.
public enum ImageOutputFormat: String, Sendable, Codable {
    case png
    case jpeg
    case webp
}

/// Capability flags the UI uses to show/hide controls for a given model.
public struct ImageModelCapabilities: Sendable, Equatable, Hashable {
    public var textToImage: Bool
    public var imageEdit: Bool
    public var upscale: Bool
    public var negativePrompt: Bool
    public var mask: Bool
    public var multipleSourceImages: Bool
    public var lora: Bool

    public init(
        textToImage: Bool = false,
        imageEdit: Bool = false,
        upscale: Bool = false,
        negativePrompt: Bool = false,
        mask: Bool = false,
        multipleSourceImages: Bool = false,
        lora: Bool = false
    ) {
        self.textToImage = textToImage
        self.imageEdit = imageEdit
        self.upscale = upscale
        self.negativePrompt = negativePrompt
        self.mask = mask
        self.multipleSourceImages = multipleSourceImages
        self.lora = lora
    }
}

/// A locally installed image model as surfaced to the catalog / API. `id` is
/// the exact bundle directory name and is what callers must send back in a
/// request (exact-name resolution preserves the `-4bit`/`-8bit`/`-qN` quant
/// suffix so co-installed quants never collapse onto each other).
public struct ImageModelInfo: Sendable, Equatable {
    public let id: String
    public let canonicalName: String?
    public let displayName: String
    /// Engine `ModelKind.rawValue`: "imageGen" | "imageEdit" | "imageUpscale" | "videoGen".
    public let kind: String
    /// `true` when the bundle is a complete, loadable scaffold.
    public let ready: Bool
    public let quantizationBits: Int?
    public let defaultSteps: Int?
    public let defaultGuidance: Float?
    public let capabilities: ImageModelCapabilities
    /// Human-readable reasons the bundle is not ready (missing components,
    /// missing indexed shards). Surfaced to the UI as a "Download required" /
    /// "incomplete" hint.
    public let blockedReasons: [String]
    public let totalBytes: UInt64

    public init(
        id: String,
        canonicalName: String?,
        displayName: String,
        kind: String,
        ready: Bool,
        quantizationBits: Int?,
        defaultSteps: Int?,
        defaultGuidance: Float?,
        capabilities: ImageModelCapabilities,
        blockedReasons: [String],
        totalBytes: UInt64
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.displayName = displayName
        self.kind = kind
        self.ready = ready
        self.quantizationBits = quantizationBits
        self.defaultSteps = defaultSteps
        self.defaultGuidance = defaultGuidance
        self.capabilities = capabilities
        self.blockedReasons = blockedReasons
        self.totalBytes = totalBytes
    }
}

/// Parameters for a text→image generation. `nil` `steps`/`guidance` fall back
/// to the model's registry defaults; `nil` `width`/`height` default to 1024.
public struct ImageGenerationParameters: Sendable {
    public var model: String
    public var prompt: String
    public var negativePrompt: String?
    public var width: Int?
    public var height: Int?
    public var steps: Int?
    public var guidance: Float?
    public var seed: UInt64?
    public var numImages: Int
    public var outputFormat: ImageOutputFormat

    public init(
        model: String,
        prompt: String,
        negativePrompt: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        steps: Int? = nil,
        guidance: Float? = nil,
        seed: UInt64? = nil,
        numImages: Int = 1,
        outputFormat: ImageOutputFormat = .png
    ) {
        self.model = model
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.guidance = guidance
        self.seed = seed
        self.numImages = numImages
        self.outputFormat = outputFormat
    }
}

/// Parameters for an image edit. Source/mask images are passed as raw bytes;
/// the service stages them to temp files for the engine's URL-based API.
/// `sourceImages` is the ordered multi-reference list (qwen-image-edit); a
/// single-image edit is just a one-element array.
public struct ImageEditParameters: Sendable {
    public var model: String
    public var prompt: String
    public var sourceImages: [Data]
    public var maskImage: Data?
    public var negativePrompt: String?
    public var strength: Float
    public var width: Int?
    public var height: Int?
    public var steps: Int?
    public var guidance: Float?
    public var seed: UInt64?
    public var outputFormat: ImageOutputFormat

    public init(
        model: String,
        prompt: String,
        sourceImages: [Data],
        maskImage: Data? = nil,
        negativePrompt: String? = nil,
        strength: Float = 0.75,
        width: Int? = nil,
        height: Int? = nil,
        steps: Int? = nil,
        guidance: Float? = nil,
        seed: UInt64? = nil,
        outputFormat: ImageOutputFormat = .png
    ) {
        self.model = model
        self.prompt = prompt
        self.sourceImages = sourceImages
        self.maskImage = maskImage
        self.negativePrompt = negativePrompt
        self.strength = strength
        self.width = width
        self.height = height
        self.steps = steps
        self.guidance = guidance
        self.seed = seed
        self.outputFormat = outputFormat
    }
}

/// User-adjustable image generation/edit settings owned by the chat composer.
/// These values are UI-native but map one-to-one to `ImageGenerationParameters`
/// and `ImageEditParameters`.
public struct ImageComposerSettings: Sendable, Codable, Equatable {
    public var negativePrompt: String
    public var steps: Int
    public var guidance: Double
    public var width: Int
    public var height: Int
    public var seed: String
    public var strength: Double

    public init(
        negativePrompt: String = "",
        steps: Int = 20,
        guidance: Double = 3.5,
        width: Int = 512,
        height: Int = 512,
        seed: String = "",
        strength: Double = 0.75
    ) {
        self.negativePrompt = negativePrompt
        self.steps = steps
        self.guidance = guidance
        self.width = width
        self.height = height
        self.seed = seed
        self.strength = strength
    }

    public var normalizedNegativePrompt: String? {
        let trimmed = negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var normalizedSeed: UInt64? {
        let trimmed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return UInt64(trimmed)
    }

    public var clampedSteps: Int {
        min(50, max(1, steps))
    }

    public var clampedWidth: Int {
        Self.clampDimension(width)
    }

    public var clampedHeight: Int {
        Self.clampDimension(height)
    }

    public var clampedGuidance: Float {
        Float(min(20, max(0, guidance)))
    }

    public var clampedStrength: Float {
        Float(min(1, max(0, strength)))
    }

    public mutating func applyModelDefaults(steps: Int?, guidance: Float?) {
        if let steps {
            self.steps = min(50, max(1, steps))
        }
        if let guidance {
            self.guidance = Double(guidance)
        }
    }

    private static func clampDimension(_ value: Int) -> Int {
        let bounded = min(1024, max(256, value))
        let rounded = (bounded / 16) * 16
        return max(256, rounded)
    }
}

/// Parameters for an upscale (SeedVR2).
public struct ImageUpscaleParameters: Sendable {
    public var model: String
    public var sourceImage: Data
    public var scale: Int
    public var steps: Int?
    public var seed: UInt64?
    public var outputFormat: ImageOutputFormat

    public init(
        model: String,
        sourceImage: Data,
        scale: Int = 4,
        steps: Int? = nil,
        seed: UInt64? = nil,
        outputFormat: ImageOutputFormat = .png
    ) {
        self.model = model
        self.sourceImage = sourceImage
        self.scale = scale
        self.steps = steps
        self.seed = seed
        self.outputFormat = outputFormat
    }
}

/// A single produced image: the saved file on disk plus the seed used.
public struct GeneratedImage: Sendable, Equatable {
    public let url: URL
    public let seed: UInt64

    public init(url: URL, seed: UInt64) {
        self.url = url
        self.seed = seed
    }
}

/// Progress event streamed from `ImageGenerationService`. Mirrors the engine's
/// `ImageGenEvent` plus a server-side `loadingModel` lifecycle phase the UI
/// shows before the first denoise step (first run pages weights from disk).
public enum ImageGenerationEvent: Sendable {
    /// Emitted once before generation when a model load/switch is in progress.
    case loadingModel(model: String)
    /// 1-indexed step counter for a determinate progress bar.
    case step(step: Int, total: Int, etaSeconds: Double?)
    /// Optional partial decode (not all models emit previews).
    case preview(pngData: Data, step: Int)
    /// Terminal success — all requested images saved to disk.
    case completed(images: [GeneratedImage])
    /// Terminal failure. `hfAuth == true` ⇒ a 401/403 → show "Add HF token".
    case failed(message: String, hfAuth: Bool)
    /// Terminal cancellation (user/system stopped the job).
    case cancelled
}

/// Errors the bridge raises before/around the engine call. Maps cleanly to
/// HTTP status codes in the `/v1/images/*` layer.
public enum ImageGenerationError: Error, CustomStringConvertible {
    /// No bundle with the requested id exists under the image models root.
    case modelNotFound(String)
    /// The bundle exists but is missing required components/shards.
    case modelIncomplete(model: String, reasons: [String])
    /// The bundle resolved but has no recognized canonical family.
    case unknownModel(String)
    /// The requested operation doesn't match the model's kind.
    case wrongModelKind(expected: String, actual: String)
    case invalidRequest(String)
    case engine(String)

    public var description: String {
        switch self {
        case .modelNotFound(let m): return "image model not found: \(m)"
        case .modelIncomplete(let m, let r):
            return "image model incomplete: \(m) — \(r.joined(separator: ", "))"
        case .unknownModel(let m): return "unknown image model: \(m)"
        case .wrongModelKind(let e, let a):
            return "wrong model kind: expected \(e), got \(a)"
        case .invalidRequest(let s): return "invalid request: \(s)"
        case .engine(let s): return s
        }
    }
}
