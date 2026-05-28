//
//  Calibration.swift
//  osaurus / PrivacyFilter (vendored sidecar)
//
//  Osaurus-local addition (NOT in upstream
//  kokluch/privacy-filter-swift). Parses
//  `viterbi_calibration.json` as shipped by
//  `mlx-community/openai-privacy-filter-bf16`, which adds bias
//  overrides on top of the BIOES validity mask. The repo's "default"
//  operating point ships with all-zero biases, so this is a no-op for
//  shipping users — but future operating-point tuning (e.g. tighter
//  PERSON precision) lands here without a Swift change.
//

import Foundation

public struct ViterbiBiases: Sendable {
    /// Score added to O → O transitions ("stay in background").
    public var backgroundStay: Float = 0
    /// Score added to O → B / O → S transitions.
    public var backgroundToStart: Float = 0
    /// Score added to E → O and S → O transitions.
    public var endToBackground: Float = 0
    /// Score added to E → B / S → B / S → S / E → S.
    public var endToStart: Float = 0
    /// Score added to B → I and I → I transitions.
    public var insideToContinue: Float = 0
    /// Score added to B → E and I → E transitions.
    public var insideToEnd: Float = 0
}

struct ViterbiCalibration: Decodable {
    let operatingPoints: [String: OperatingPoint]

    struct OperatingPoint: Decodable {
        let biases: BiasSet
    }

    struct BiasSet: Decodable {
        let backgroundStay: Float?
        let backgroundToStart: Float?
        let endToBackground: Float?
        let endToStart: Float?
        let insideToContinue: Float?
        let insideToEnd: Float?

        enum CodingKeys: String, CodingKey {
            case backgroundStay = "transition_bias_background_stay"
            case backgroundToStart = "transition_bias_background_to_start"
            case endToBackground = "transition_bias_end_to_background"
            case endToStart = "transition_bias_end_to_start"
            case insideToContinue = "transition_bias_inside_to_continue"
            case insideToEnd = "transition_bias_inside_to_end"
        }
    }

    enum CodingKeys: String, CodingKey {
        case operatingPoints = "operating_points"
    }

    var defaultBiases: ViterbiBiases? {
        guard let op = operatingPoints["default"] else { return nil }
        var b = ViterbiBiases()
        if let v = op.biases.backgroundStay { b.backgroundStay = v }
        if let v = op.biases.backgroundToStart { b.backgroundToStart = v }
        if let v = op.biases.endToBackground { b.endToBackground = v }
        if let v = op.biases.endToStart { b.endToStart = v }
        if let v = op.biases.insideToContinue { b.insideToContinue = v }
        if let v = op.biases.insideToEnd { b.insideToEnd = v }
        return b
    }

    static func load(from url: URL) throws -> ViterbiCalibration {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ViterbiCalibration.self, from: data)
    }
}

public extension BIOESDecoder {
    /// Validity mask with bias overrides applied. Falls through to the
    /// unbiased mask if no biases are provided.
    static func validityMask(labels: BIOESLabelTable, biases: ViterbiBiases) -> [[Float]] {
        var mask = validityMask(labels: labels)
        let n = labels.count
        for i in 0 ..< n {
            let from = labels[i]
            for j in 0 ..< n {
                guard mask[i][j] > -1e29 else { continue }  // skip invalid
                let to = labels[j]
                mask[i][j] += biasScore(from: from, to: to, biases: biases)
            }
        }
        return mask
    }

    private static func biasScore(from: BIOESLabel, to: BIOESLabel, biases: ViterbiBiases) -> Float {
        switch (from.boundary, to.boundary) {
        case (.outside, .outside):
            return biases.backgroundStay
        case (.outside, .begin), (.outside, .single):
            return biases.backgroundToStart
        case (.end, .outside), (.single, .outside):
            return biases.endToBackground
        case (.end, .begin), (.end, .single), (.single, .begin), (.single, .single):
            return biases.endToStart
        case (.begin, .inside), (.inside, .inside):
            return biases.insideToContinue
        case (.begin, .end), (.inside, .end):
            return biases.insideToEnd
        default:
            return 0
        }
    }
}
