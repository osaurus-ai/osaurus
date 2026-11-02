import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct CompactionAcceptanceTests {
    private func covered() -> [ChatTurn] {
        [ChatTurn(role: .user, content: String(repeating: "record ", count: 2000)),
            ChatTurn(role: .assistant, content: "Acknowledged the records.")]
    }

    @Test func blankOutputNeverBecomesASummary() {
        #expect(throws: ContextCompactionError.emptySummary) {
            try ContextCompactionService.validatedSummary(" \n\t", covered: covered(), modelId: "m")
        }
    }

    @Test func nonShrinkingOutputNeverBecomesASummary() {
        #expect(throws: ContextCompactionError.summaryNotSmaller) {
            try ContextCompactionService.validatedSummary(
                String(repeating: "explanation ", count: 4000), covered: covered(), modelId: "m")
        }
    }

    @Test func acceptedSummaryIsSmallerAndDoesNotRewriteTranscript() throws {
        let turns = covered()
        let contents = turns.map(\.content)
        let summary = try ContextCompactionService.validatedSummary(
            "  Preserve all records for the next step.\n", covered: turns, modelId: "m")
        #expect(summary.summaryText == "Preserve all records for the next step.")
        #expect(summary.savedTokensEstimate > 0)
        #expect(summary.coveredTurnIds == turns.map(\.id))
        #expect(ContextCompactionService.summaryIsValid(summary, for: turns))
        #expect(turns.map(\.content) == contents)
    }

    @Test func persistedBlankSummaryCannotHideCoveredTurns() {
        let turns = covered()
        let summary = ConversationSummary(
            summaryText: "  \n", coveredTurnIds: turns.map(\.id),
            modelIdentifier: "m", savedTokensEstimate: 100)
        #expect(!ContextCompactionService.summaryIsValid(summary, for: turns))
    }
}
