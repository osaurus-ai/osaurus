import Foundation
import Testing
@testable import OsaurusCore

struct AgentRunUsageTests {
    @Test func aggregateUsesMeasuredDecodeTimeRatherThanAveragingRates() {
        var usage = AgentRunUsage()
        usage.append(promptTokens: 20, completionTokens: 100, tokensPerSecond: 50)
        usage.append(promptTokens: 30, completionTokens: 100, tokensPerSecond: 25)
        #expect(usage.promptTokens == 50)
        #expect(usage.completionTokens == 200)
        #expect(abs((usage.tokensPerSecond ?? 0) - 200.0 / 6.0) < 0.0001)
    }

    @Test(arguments: [Double.nan, Double.infinity, 0, -1])
    func missingOrInvalidMeasurementsNeverBecomeSyntheticThroughput(rate: Double) {
        var usage = AgentRunUsage()
        usage.append(promptTokens: 20, completionTokens: 100, tokensPerSecond: 50)
        usage.append(promptTokens: 30, completionTokens: 100, tokensPerSecond: rate)
        #expect(usage.tokensPerSecond == nil)
        var absent = AgentRunUsage()
        absent.append(promptTokens: 3, completionTokens: 2, tokensPerSecond: nil)
        #expect(absent.tokensPerSecond == nil)
    }
}

extension AgentRunUsageTests {
    @Test func missingCountsDoNotBecomeCompleteUsage() {
        var usage = AgentRunUsage()
        #expect(!usage.hasCompleteTokenCounts)
        usage.append(promptTokens: 20, completionTokens: 10, tokensPerSecond: 5)
        #expect(usage.hasCompleteTokenCounts)
        usage.append(promptTokens: nil, completionTokens: 3, tokensPerSecond: 5)
        #expect(!usage.hasCompleteTokenCounts)
        #expect(usage.promptTokens == 20 && usage.completionTokens == 13)
        var absent = AgentRunUsage()
        absent.append(promptTokens: 3, completionTokens: nil, tokensPerSecond: 50)
        #expect(!absent.hasCompleteTokenCounts && absent.tokensPerSecond == nil)
    }
}

extension AgentRunUsageTests {
    /// `/agents/{id}/run` streaming usage reports prefix-cache hits like chat completions do.
    @Test func cachedPromptTokensSumAcrossStepsAndStayAbsentWhenCold() {
        var usage = AgentRunUsage()
        usage.append(promptTokens: 6012, completionTokens: 40, tokensPerSecond: 20, cachedPromptTokens: 6000)
        usage.append(promptTokens: 6100, completionTokens: 10, tokensPerSecond: 20, cachedPromptTokens: nil)
        usage.append(promptTokens: 6200, completionTokens: 10, tokensPerSecond: 20, cachedPromptTokens: 6090)
        #expect(usage.cachedPromptTokens == 12090)
        #expect(usage.promptTokens == 18312)

        var clamped = AgentRunUsage()
        clamped.append(promptTokens: 10, completionTokens: 1, tokensPerSecond: 5, cachedPromptTokens: 50)
        #expect(clamped.cachedPromptTokens == 10)

        var cold = AgentRunUsage()
        cold.append(promptTokens: 10, completionTokens: 1, tokensPerSecond: 5, cachedPromptTokens: 0)
        cold.append(promptTokens: 10, completionTokens: 1, tokensPerSecond: 5)
        #expect(cold.cachedPromptTokens == nil)
    }
}
