import Foundation
import Testing

@testable import OsaurusCore

@Suite("Computer Use context admission")
struct ComputerUseContextAdmissionTests {
    private let goal = "Open Calculator and add 12 and 30."

    @Test func minimumCoversOneScreenshotOnlyForImageModels() {
        let text = ComputerUseLoop.minimumStepPositions(
            goal: goal, policySummary: "", vision: .none
        )
        let pixels = ComputerUseLoop.minimumStepPositions(
            goal: goal, policySummary: "",
            vision: VisionContext(modelAcceptsImages: true, modelIsLocal: true, cloudConsent: false)
        )
        #expect(pixels - text == Attachment.imageTokenCeiling)
    }

    @Test func minimumIsTheOneStepComposition() {
        let prompt = ComputerUseLoop.systemPrompt(
            policySummary: "", pointing: PointingSurface(VisionContext.none.grounding)
        )
        let textTokens = ((prompt.count + goal.count) * 3 + 7) / 8
        let expected =
            textTokens + ComputerUseLoop.toolSchemaReserveTokens
            + DelegatedRunContract.toolResultAllowancePerTurn
            + AgentLoopBudget.defaultResponseReservation
        #expect(
            ComputerUseLoop.minimumStepPositions(goal: goal, policySummary: "", vision: .none) == expected
        )
    }

    @Test func longerPolicyRaisesTheMinimum() {
        let bare = ComputerUseLoop.minimumStepPositions(goal: goal, policySummary: "", vision: .none)
        let withPolicy = ComputerUseLoop.minimumStepPositions(
            goal: goal, policySummary: String(repeating: "Ask before sending. ", count: 40), vision: .none
        )
        #expect(withPolicy > bare)
    }

    @Test func limitsDefaultToTheResolvedWindow() {
        #expect(RunLimits().contextPositions == nil)
        #expect(RunLimits(contextPositions: 0).contextPositions == 1)
    }

    @Test func unresolvedKindFailsClosedToModelWindowPricing() {
        let kind = ComputerUseKind(goal: goal, limits: RunLimits())
        #expect(kind.admissionRequestEstimate() == nil)
        #expect(kind.minimumAdmissionContextPositions == nil)
        #expect(!kind.tightenAdmissionContextPositions(to: 8_192))
        #expect(!kind.admissionContextWasMemoryFitted)
    }
}
