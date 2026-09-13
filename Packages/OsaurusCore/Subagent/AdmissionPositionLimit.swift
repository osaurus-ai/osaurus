import Foundation

/// A priced delegation ceiling must hold after the model's real template and
/// tokenizer have processed the complete request. Heuristic history trimming
/// is useful for composition, but is not an allocation safety boundary.
struct AdmissionPositionLimit: Error, LocalizedError, Sendable, Equatable {
    let promptTokens: Int
    let outputTokens: Int
    let limit: Int

    var errorDescription: String? {
        "Delegated context exceeds its RAM admission budget: the prepared prompt has \(promptTokens) tokens and reserves \(outputTokens) output tokens, exceeding the \(limit)-position limit. Reduce the child input or output budget."
    }

    static func validate(promptTokens: Int, outputTokens: Int, limit: Int?) throws {
        guard let limit else { return }
        let (total, overflow) = promptTokens.addingReportingOverflow(outputTokens)
        guard limit > 0, promptTokens >= 0, outputTokens > 0,
            !overflow, total <= limit
        else {
            throw Self(promptTokens: promptTokens, outputTokens: outputTokens, limit: limit)
        }
    }
}
