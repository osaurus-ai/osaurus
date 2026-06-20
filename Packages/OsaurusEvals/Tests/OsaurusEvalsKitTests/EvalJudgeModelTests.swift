import Foundation
import Testing

@testable import OsaurusEvalsKit

/// Locks the W2 eval-trust contract for judge resolution: an explicit
/// `JUDGE_MODEL` always wins; an unset `JUDGE_MODEL` auto-upgrades to a
/// strong remote judge whose API key is exported; and self-judge is the
/// last resort, always flagged so an unreliable grade is never silent.
@Suite
struct EvalJudgeModelTests {

    @Test func explicitJudgeWins() {
        let resolution = EvalJudgeModel.resolve(
            runModelId: "mlx-community/Qwen3-4B-4bit",
            environment: ["JUDGE_MODEL": "xai/grok-4.3", "XAI_API_KEY": "k"]
        )
        #expect(resolution.modelId == "xai/grok-4.3")
        #expect(resolution.isSelfJudge == false)
        #expect(resolution.note == nil)
    }

    @Test func explicitJudgeEqualToRunModelIsFlaggedSelfJudge() {
        let resolution = EvalJudgeModel.resolve(
            runModelId: "xai/grok-4.3",
            environment: ["JUDGE_MODEL": "xai/grok-4.3"]
        )
        #expect(resolution.modelId == "xai/grok-4.3")
        #expect(resolution.isSelfJudge == true)
        #expect(resolution.note?.contains("self-judging") == true)
    }

    @Test func autoUpgradesToStrongJudgeWhenKeyPresent() {
        let resolution = EvalJudgeModel.resolve(
            runModelId: "mlx-community/Qwen3-4B-4bit",
            environment: ["XAI_API_KEY": "secret"]
        )
        #expect(resolution.modelId == "xai/grok-4.3")
        #expect(resolution.isSelfJudge == false)
        #expect(resolution.note?.contains("auto-selected strong judge") == true)
    }

    @Test func strongJudgePriorityOrder() {
        // XAI wins over Anthropic/OpenAI when multiple keys are present.
        let resolution = EvalJudgeModel.resolve(
            runModelId: "local/x",
            environment: ["OPENAI_API_KEY": "o", "XAI_API_KEY": "x", "ANTHROPIC_API_KEY": "a"]
        )
        #expect(resolution.modelId == "xai/grok-4.3")
    }

    @Test func doesNotUpgradeToJudgeEqualToRunModel() {
        // Running grok itself with only XAI_API_KEY: the strong-judge
        // candidate equals the run model, so it must NOT be auto-selected;
        // fall through to self-judge (flagged).
        let resolution = EvalJudgeModel.resolve(
            runModelId: "xai/grok-4.3",
            environment: ["XAI_API_KEY": "x"]
        )
        #expect(resolution.modelId == nil)
        #expect(resolution.isSelfJudge == true)
        #expect(resolution.note?.contains("SELF-JUDGE") == true)
    }

    @Test func fallsBackToSelfJudgeWithLoudWarningWhenNoKey() {
        let resolution = EvalJudgeModel.resolve(
            runModelId: "mlx-community/Qwen3-4B-4bit",
            environment: [:]
        )
        #expect(resolution.modelId == nil)
        #expect(resolution.isSelfJudge == true)
        #expect(resolution.note?.contains("WARNING") == true)
        #expect(resolution.note?.contains("SELF-JUDGE") == true)
    }

    @Test func blankJudgeModelIsTreatedAsUnset() {
        let resolution = EvalJudgeModel.resolve(
            runModelId: "local/x",
            environment: ["JUDGE_MODEL": "   ", "ANTHROPIC_API_KEY": "a"]
        )
        #expect(resolution.modelId == "anthropic/claude-sonnet-4-5")
    }
}
