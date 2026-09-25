import Foundation

/// Usage across model steps only. Tool latency is not decode time; missing
/// runtime measurements must never become an invented token/s value.
struct AgentRunUsage: Sendable {
    private(set) var promptTokens = 0
    private(set) var completionTokens = 0
    private var measuredTokens = 0
    private var measuredSeconds = 0.0
    private var allStepsMeasured = true

    mutating func append(promptTokens: Int, completionTokens: Int, tokensPerSecond: Double?) {
        self.promptTokens += max(0, promptTokens)
        self.completionTokens += max(0, completionTokens)
        guard completionTokens > 0, let rate = tokensPerSecond, rate.isFinite, rate > 0 else {
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
