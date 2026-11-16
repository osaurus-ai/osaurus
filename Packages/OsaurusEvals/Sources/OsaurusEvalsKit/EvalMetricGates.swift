import Foundation
import OsaurusCore

/// Cost attribution mixes an estimated prompt count with reported output.
/// Missing output is not a reported zero and cannot satisfy a total-cost gate.
enum EvalTokenCost {
    enum CeilingVerdict: Equatable {
        case within(Int)
        case exceeded(Int)
        case unreported
    }

    static func total(estimatedPrompt: Int?, reportedCompletion: Int?) -> Int? {
        guard let prompt = estimatedPrompt, let completion = reportedCompletion,
            prompt >= 0, completion >= 0
        else { return nil }
        let sum = prompt.addingReportingOverflow(completion)
        return sum.overflow ? nil : sum.partialValue
    }

    static func ceiling(
        _ ceiling: Int, estimatedPrompt: Int?, reportedCompletion: Int?
    ) -> CeilingVerdict {
        guard let total = total(estimatedPrompt: estimatedPrompt, reportedCompletion: reportedCompletion)
        else { return .unreported }
        return total <= ceiling ? .within(total) : .exceeded(total)
    }
}

enum CacheProofDecodeGate {
    struct Check: Equatable {
        let passed: Bool
        let note: String
    }

    static func evaluate(
        turns: [CacheProofTurnMetrics], minimumFinal: Double?, minimumRatio: Double?
    ) -> [Check] {
        guard minimumFinal != nil || minimumRatio != nil else { return [] }
        guard let final = turns.last,
            let finalRate = final.decodeTokensPerSecond, finalRate > 0, finalRate.isFinite
        else {
            return [Check(passed: false,
                note: "sustained-decode gate unverified: actual final turn has no positive finite decode measurement")]
        }
        var checks: [Check] = []
        if let floor = minimumRatio {
            // Baseline is the first earlier measured turn. The final turn can
            // never supply its own baseline or replace an unreported final row.
            if let baseline = turns.dropLast().first(where: {
                guard let rate = $0.decodeTokensPerSecond else { return false }
                return rate > 0 && rate.isFinite
            }), let firstRate = baseline.decodeTokensPerSecond {
                let ratio = finalRate / firstRate
                checks.append(Check(passed: ratio.isFinite && ratio >= floor,
                    note: String(format: "sustained decode: final turn %d %.1f tok/s vs measured turn %d %.1f tok/s (ratio %.2f; floor %.2f)",
                        final.turnNumber, finalRate, baseline.turnNumber, firstRate, ratio, floor)))
            } else {
                checks.append(Check(passed: false,
                    note: "sustained-decode ratio unverified: no earlier measured baseline turn"))
            }
        }
        if let floor = minimumFinal {
            checks.append(Check(passed: finalRate >= floor,
                note: String(format: "actual final turn %d decode %.1f tok/s; floor %.1f",
                    final.turnNumber, finalRate, floor)))
        }
        return checks
    }
}
