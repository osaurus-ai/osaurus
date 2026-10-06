import Foundation

/// App admission/parameter contract. Engine numerics remain bundle-owned.
struct ImageModelRequestPolicy: Sendable {
    let canonical: String?
    var isQwen21: Bool { canonical == "qwen-image-2.1" }
    var supportsEditNegativePrompt: Bool { !isQwen21 }
    var supportsEditStrength: Bool { !isQwen21 }
    var dimensionMultiple: Int { isQwen21 ? 32 : 16 }
    // App capacity policy: prior REST limits protected against OOM/watchdog.
    // Q21 evidence covers 2048², so admit that envelope explicitly, never round.
    static let q21MaximumDimension = 2048

    static func capabilities(kind: String, canonical: String?, supportsLoRA: Bool = false)
        -> ImageModelCapabilities
    {
        let dual = canonical == "qwen-image-2.1"
        return ImageModelCapabilities(
            textToImage: kind == "imageGen" || dual,
            imageEdit: kind == "imageEdit" || dual,
            upscale: kind == "imageUpscale",
            negativePrompt: kind == "imageGen" || kind == "imageEdit",
            editNegativePrompt: !dual && (kind == "imageGen" || kind == "imageEdit"),
            editStrength: !dual,
            dimensionMultiple: dual ? 32 : 16,
            mask: false,
            multipleSourceImages: canonical == "qwen-image-edit" || dual,
            lora: supportsLoRA
        )
    }

    static func supports(_ kind: String, capabilities: ImageModelCapabilities) -> Bool {
        switch kind {
        case "imageGen": return capabilities.textToImage
        case "imageEdit": return capabilities.imageEdit
        case "imageUpscale": return capabilities.upscale
        default: return false
        }
    }

    func validate(
        width: Int?, height: Int?, isEdit: Bool, guidance: Float,
        negativePrompt: String?, strength: Float? = nil, hasMask: Bool = false,
        sourceCount: Int = 0, steps: Int? = nil, outputFormat: ImageOutputFormat? = nil
    ) throws {
        // Older families keep their existing adapter contract. The Q21 rules
        // describe this port's actual support, rather than coercing requests.
        guard isQwen21 else { return }
        try Self.validateQwen21Steps(steps)
        if let outputFormat, outputFormat != .png {
            throw ImageGenerationError.invalidRequest("Qwen-Image-2.1 supports PNG output only")
        }
        for value in [width, height].compactMap({ $0 }) {
            guard (32...Self.q21MaximumDimension).contains(value), value % 32 == 0 else {
                throw ImageGenerationError.invalidRequest("Qwen-Image-2.1 dimensions must be multiples of 32 from 32 through 2048")
            }
        }
        guard guidance.isFinite else {
            throw ImageGenerationError.invalidRequest("guidance must be finite")
        }
        let hasNegative = !(negativePrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if isEdit {
            guard (1...4).contains(sourceCount) else {
                throw ImageGenerationError.invalidRequest("this app supports one to four ordered source images")
            }
            guard !hasMask else {
                throw ImageGenerationError.invalidRequest("Qwen-Image-2.1 masks are not wired yet")
            }
            guard !hasNegative else {
                throw ImageGenerationError.invalidRequest("Qwen-Image-2.1 edit negative prompts are not exposed by this engine")
            }
            if let strength, strength != 1 {
                throw ImageGenerationError.invalidRequest("Qwen-Image-2.1 edit strength below 1 is not implemented; omit strength")
            }
        } else if hasNegative, guidance <= 1 {
            throw ImageGenerationError.invalidRequest("Qwen-Image-2.1 negative prompts require explicit guidance above 1")
        }
    }

    static func validateQwen21Steps(_ steps: Int?) throws {
        if let steps, !(2...50).contains(steps) {
            throw ImageGenerationError.invalidRequest("Qwen-Image-2.1 steps must be from 2 through 50")
        }
    }

    func editStrength(_ explicit: Float?) -> Float {
        explicit ?? (isQwen21 ? 1 : 0.75)
    }

    static func licenseLabel(canonical: String?) -> String? {
        switch canonical {
        case "qwen-image-2.1": return L("Research / non-commercial license")
        case "ideogram": return L("Non-commercial license")
        default: return nil
        }
    }

    /// Display-only catalog identity; actual load routing stays in the engine.
    static func catalogCanonical(_ name: String) -> String? {
        let name = name.lowercased().replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        if name.contains("qwen-image-2-1") || name.contains("qwen-image-21") || name.contains("qwenimage21") {
            return "qwen-image-2.1"
        }
        if name.contains("ideogram") { return "ideogram" }
        return nil
    }
}
