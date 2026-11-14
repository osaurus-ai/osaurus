import Foundation

/// Empty fields mean bundle defaults/random seed; invalid explicit text never
/// silently becomes nil or random. Qwen's existing minimum-2-step adapter is
/// applied later by ImageGenerationService, preserving explicit steps here.
struct ImagePanelParameterInput {
    let steps: Int?
    let guidance: Float?
    let seed: UInt64?

    enum InputError: Error {
        case steps, guidance, seed
        var localizedMessage: String {
            switch self {
            case .steps: return L("Enter a positive whole number of steps.")
            case .guidance: return L("Guidance must be a finite number.")
            case .seed: return L("Enter a seed from 0 to 18446744073709551615.")
            }
        }
    }

    init(steps: String, guidance: String, seed: String) throws {
        let steps = steps.trimmingCharacters(in: .whitespacesAndNewlines)
        let guidance = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        if steps.isEmpty { self.steps = nil }
        else {
            guard let value = Int(steps), value > 0 else { throw InputError.steps }
            self.steps = value
        }
        if guidance.isEmpty { self.guidance = nil }
        else {
            guard let value = Float(guidance), value.isFinite else { throw InputError.guidance }
            self.guidance = value
        }
        if seed.isEmpty { self.seed = nil }
        else {
            guard let value = UInt64(seed) else { throw InputError.seed }
            self.seed = value
        }
    }
}
