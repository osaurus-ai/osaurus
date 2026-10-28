import Foundation

/// Usage across model steps only. Tool latency is not decode time; missing
/// runtime measurements must never become an invented token/s value.
struct AgentRunUsage: Sendable {
    private(set) var promptTokens = 0
    private(set) var completionTokens = 0
    /// Prompt tokens restored from the runtime's prefix cache, summed over
    /// the steps that reported a hit (a subset of `promptTokens`). Nil when no
    /// step reported one, so the usage block omits `cached_tokens`.
    private(set) var cachedPromptTokens: Int?
    private var measuredTokens = 0
    private var measuredSeconds = 0.0
    private var allStepsMeasured = true
    private var allCountsReported = true
    private var stepCount = 0

    var hasCompleteTokenCounts: Bool { stepCount > 0 && allCountsReported }

    mutating func append(
        promptTokens: Int?, completionTokens: Int?, tokensPerSecond: Double?, cachedPromptTokens: Int? = nil
    ) {
        stepCount += 1
        if let cachedPromptTokens, cachedPromptTokens > 0 {
            let stepCached = promptTokens.map { min(cachedPromptTokens, max(0, $0)) } ?? cachedPromptTokens
            self.cachedPromptTokens = (self.cachedPromptTokens ?? 0) + stepCached
        }
        if let promptTokens, promptTokens >= 0 { self.promptTokens += promptTokens }
        else { allCountsReported = false }
        if let completionTokens, completionTokens >= 0 { self.completionTokens += completionTokens }
        else { allCountsReported = false }
        guard let completionTokens, completionTokens > 0, let rate = tokensPerSecond, rate.isFinite, rate > 0 else {
            allStepsMeasured = false
            return
        }
        measuredTokens += completionTokens
        measuredSeconds += Double(completionTokens) / rate
    }

    var tokensPerSecond: Double? {
        guard allStepsMeasured, measuredTokens > 0, measuredSeconds > 0 else { return nil }
        return Double(measuredTokens) / measuredSeconds
    }
}
