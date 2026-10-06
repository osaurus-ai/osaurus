import Foundation

/// The local chat send path and its controls use this same operation contract.
/// Reference presence selects edit for dual-capability models. Kind is only a
/// fallback for older picker entries without capability metadata.
enum ImageComposerRequestBuilder {
    enum Operation: Sendable, Equatable { case generate, edit }
    enum Request: Sendable {
        case generate(ImageGenerationParameters)
        case edit(ImageEditParameters)
    }
    struct Controls {
        let operation: Operation?
        let negativePrompt: Bool
        let strength: Bool
    }
    enum RequestError: Error {
        case sourceRequired, sourceUnsupported, sourceUnavailable, unsupported, invalidSeed
        var localizedMessage: String {
            switch self {
            case .sourceRequired: return L("Attach one source image to edit with this model.")
            case .sourceUnsupported: return L("Selected image model does not accept source images.")
            case .sourceUnavailable: return L("Failed to load image")
            case .unsupported: return L("Image generation failed: selected model is not an image model.")
            case .invalidSeed: return L("Enter a seed from 0 to 18446744073709551615.")
            }
        }
    }

    private static func effectiveCapabilities(_ caps: ImageModelCapabilities?, kind: String?) -> ImageModelCapabilities {
        caps ?? .init(textToImage: kind == "imageGen", imageEdit: kind == "imageEdit",
            negativePrompt: kind == "imageGen" || kind == "imageEdit")
    }

    static func controls(capabilities: ImageModelCapabilities?, fallbackKind: String?, hasReferences: Bool) -> Controls {
        let caps = effectiveCapabilities(capabilities, kind: fallbackKind)
        let operation: Operation?
        if hasReferences { operation = caps.imageEdit ? .edit : nil }
        else if caps.textToImage { operation = .generate }
        else { operation = caps.imageEdit ? .edit : nil }
        return Controls(operation: operation,
            negativePrompt: operation == .edit ? caps.editNegativePrompt : operation == .generate && caps.negativePrompt,
            strength: operation == .edit && caps.editStrength)
    }

    static func hasUnsupportedEditOverrides(controls: Controls, settings: ImageComposerSettings) -> Bool {
        guard controls.operation == .edit else { return false }
        return (!controls.strength && settings.hasExplicitStrength && settings.strength != 1)
            || (!controls.negativePrompt && settings.normalizedNegativePrompt != nil)
    }

    static func build(
        item: ModelPickerItem, prompt: String, sourceImages: [Data],
        expectedSourceCount: Int? = nil, settings: ImageComposerSettings
    ) throws -> Request {
        if let expectedSourceCount, expectedSourceCount != sourceImages.count {
            // A missing spilled reference must not become a text-only generation
            // or silently renumber the remaining ordered source images.
            throw RequestError.sourceUnavailable
        }
        let controls = controls(capabilities: item.imageCapabilities,
            fallbackKind: item.imageKind, hasReferences: !sourceImages.isEmpty)
        guard let operation = controls.operation else {
            throw sourceImages.isEmpty ? RequestError.unsupported : RequestError.sourceUnsupported
        }
        let seedText = settings.seed.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = UInt64(seedText)
        if !seedText.isEmpty, seed == nil { throw RequestError.invalidSeed }
        let q21 = item.imageCanonicalName == "qwen-image-2.1"
        let width: Int? = q21 && !settings.hasExplicitImageSize ? nil
            : q21 ? settings.width : settings.clampedWidth
        let height: Int? = q21 && !settings.hasExplicitImageSize ? nil
            : q21 ? settings.height : settings.clampedHeight
        let steps: Int? = q21 && !settings.hasExplicitSteps ? nil
            : q21 ? settings.steps : settings.clampedSteps
        let guidance: Float? = q21 && !settings.hasExplicitGuidance ? nil
            : q21 ? Float(settings.guidance) : settings.clampedGuidance
        switch operation {
        case .generate:
            return .generate(.init(model: item.id, prompt: prompt,
                negativePrompt: settings.normalizedNegativePrompt,
                width: width, height: height, steps: steps, guidance: guidance, seed: seed,
                numImages: 1, outputFormat: .png))
        case .edit:
            guard !sourceImages.isEmpty else { throw RequestError.sourceRequired }
            let strength: Float? = !controls.strength && !settings.hasExplicitStrength ? nil
                : q21 ? Float(settings.strength) : settings.clampedStrength
            // Explicit unsupported strength/negative fields remain present for
            // service admission to reject. The API admission policy is unchanged.
            return .edit(.init(model: item.id, prompt: prompt, sourceImages: sourceImages,
                negativePrompt: settings.normalizedNegativePrompt, strength: strength,
                width: width, height: height, steps: steps, guidance: guidance, seed: seed))
        }
    }
}
