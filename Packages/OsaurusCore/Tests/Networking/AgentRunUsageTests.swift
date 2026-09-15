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
