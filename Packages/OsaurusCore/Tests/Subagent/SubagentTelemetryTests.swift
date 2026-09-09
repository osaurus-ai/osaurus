import Testing

@testable import OsaurusCore

@Suite("Subagent usage telemetry")
struct SubagentTelemetryTests {
    @Test("Delegated completion-only usage does not invent a zero prompt count")
    func completionOnly() {
        #expect(
            SubagentTelemetry.usageDescription([
                "completion_tokens": 101,
                "tokens_per_second": 47.6,
            ]) == " promptTokens=unknown completionTokens=101 tokPerSec=47.6"
        )
    }

    @Test("Measured zero and populated token counts remain measurements")
    func measuredCounts() {
        #expect(
            SubagentTelemetry.usageDescription([
                "prompt_tokens": 1534,
                "completion_tokens": 0,
            ]) == " promptTokens=1534 completionTokens=0"
        )
        #expect(
            SubagentTelemetry.usageDescription([
                "prompt_tokens": 0,
                "completion_tokens": 101,
            ]) == " promptTokens=0 completionTokens=101"
        )
    }

    @Test("Missing and malformed counts are not reported as measured zeros")
    func missingCounts() {
        #expect(SubagentTelemetry.usageDescription(nil).isEmpty)
        #expect(
            SubagentTelemetry.usageDescription([:])
                == " promptTokens=unknown completionTokens=unknown"
        )
        #expect(
            SubagentTelemetry.usageDescription(["prompt_tokens": "1534"])
                == " promptTokens=unknown completionTokens=unknown"
        )
    }
}
