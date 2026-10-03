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

    /// An omitted output budget inherits a model ceiling, not a promise to
    /// allocate that entire ceiling. Fit it to the actual prepared prompt's
    /// remaining admitted positions. Explicit request/user budgets stay strict.
    static func resolveOutputTokens(
        promptTokens: Int, outputTokens: Int, limit: Int?, isExplicit: Bool
    ) throws -> Int {
        guard let limit, !isExplicit else {
            try validate(promptTokens: promptTokens, outputTokens: outputTokens, limit: limit)
            return outputTokens
        }
        let (remaining, overflow) = limit.subtractingReportingOverflow(promptTokens)
        guard !overflow, promptTokens >= 0, outputTokens > 0, remaining > 0 else {
            throw Self(promptTokens: promptTokens, outputTokens: outputTokens, limit: limit)
        }
        let resolved = min(outputTokens, remaining)
        try validate(promptTokens: promptTokens, outputTokens: resolved, limit: limit)
        return resolved
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
