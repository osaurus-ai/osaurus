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

    static func hasUnsupportedEditOverrides(controls: Controls, settings: ImageComposerSettings, canonical: String? = nil) -> Bool {
        guard controls.operation == .edit else { return false }
        return (!controls.strength && settings.hasExplicitStrength && settings.strength != 1)
            || (!controls.negativePrompt && canonical != "flux3-image-klein" && settings.normalizedNegativePrompt != nil)
    }

    // Picker adapter: the pure builder below owns all request semantics.
    static func build(item: ModelPickerItem, prompt: String, sourceImages: [Data],
        expectedSourceCount: Int? = nil, settings: ImageComposerSettings) throws -> Request {
        try build(modelID: item.id, canonical: item.imageCanonicalName, capabilities: item.imageCapabilities,
            fallbackKind: item.imageKind, prompt: prompt, sourceImages: sourceImages,
            expectedSourceCount: expectedSourceCount, settings: settings)
    }

    // Pure request composer; no runtime or picker lookup is performed here.
    static func build(modelID: String, canonical: String?, capabilities: ImageModelCapabilities?,
        fallbackKind: String?, prompt: String, sourceImages: [Data],
        expectedSourceCount: Int? = nil, settings: ImageComposerSettings) throws -> Request {
        if let expectedSourceCount, expectedSourceCount != sourceImages.count {
            // A missing spilled reference must not become a text-only generation
            // or silently renumber the remaining ordered source images.
            throw RequestError.sourceUnavailable
        }
        let controls = controls(capabilities: capabilities,
            fallbackKind: fallbackKind, hasReferences: !sourceImages.isEmpty)
        guard let operation = controls.operation else {
            throw sourceImages.isEmpty ? RequestError.unsupported : RequestError.sourceUnsupported
        }
        let seedText = settings.seed.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = UInt64(seedText)
        if !seedText.isEmpty, seed == nil { throw RequestError.invalidSeed }
        let bundleParameters = ImageModelRequestPolicy.usesBundleParameters(canonical)
        let width: Int? = bundleParameters && !settings.hasExplicitImageSize ? nil
            : bundleParameters ? settings.width : settings.clampedWidth
        let height: Int? = bundleParameters && !settings.hasExplicitImageSize ? nil
            : bundleParameters ? settings.height : settings.clampedHeight
        let steps: Int? = bundleParameters && !settings.hasExplicitSteps ? nil
            : bundleParameters ? settings.steps : settings.clampedSteps
        let guidance: Float? = canonical == "flux3-image-klein" ? nil : bundleParameters && !settings.hasExplicitGuidance ? nil
            : bundleParameters ? Float(settings.guidance) : settings.clampedGuidance
        switch operation {
        case .generate:
            return .generate(.init(model: modelID, prompt: prompt,
                negativePrompt: canonical == "flux3-image-klein" ? nil : settings.normalizedNegativePrompt,
                width: width, height: height, steps: steps, guidance: guidance, seed: seed,
                numImages: 1, outputFormat: .png))
        case .edit:
            guard !sourceImages.isEmpty else { throw RequestError.sourceRequired }
            let strength: Float? = !controls.strength && !settings.hasExplicitStrength ? nil
                : bundleParameters ? Float(settings.strength) : settings.clampedStrength
            // Preserve explicit strength for runtime validation. Distilled FLUX 3
            // ignores stale negative conditioning; other families keep their policy.
            return .edit(.init(model: modelID, prompt: prompt, sourceImages: sourceImages,
                negativePrompt: canonical == "flux3-image-klein" ? nil : settings.normalizedNegativePrompt, strength: strength,
                width: width, height: height, steps: steps, guidance: guidance, seed: seed))
        }
    }
}
