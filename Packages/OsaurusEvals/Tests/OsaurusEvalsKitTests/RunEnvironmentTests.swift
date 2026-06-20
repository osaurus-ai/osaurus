import Foundation
import Testing

@testable import OsaurusEvalsKit

/// Locks the provenance contract that makes a crowdsourced result trustworthy:
/// the `catalogHash` is a deterministic, order-/dup-independent function of the
/// case set (so two machines that ran the same cases agree), and `current()`
/// reads commit / KV regime / judge from the environment exactly as the run
/// path will — including flagging a self-judged run.
@Suite
struct RunEnvironmentTests {

    @Test func catalogHashIsOrderAndDuplicateIndependent() {
        let a = RunEnvironment.catalogHash(forCaseIDs: ["b", "a", "c"])
        let b = RunEnvironment.catalogHash(forCaseIDs: ["c", "c", "a", "b"])
        #expect(a != nil)
        #expect(a == b)
    }

    @Test func catalogHashDiffersForDifferentSets() {
        let a = RunEnvironment.catalogHash(forCaseIDs: ["a", "b"])
        let b = RunEnvironment.catalogHash(forCaseIDs: ["a", "b", "c"])
        #expect(a != b)
    }

    @Test func catalogHashIsNilForEmpty() {
        #expect(RunEnvironment.catalogHash(forCaseIDs: []) == nil)
    }

    @Test func currentReadsCommitKvAndCaseCount() {
        let env = RunEnvironment.current(
            caseIDs: ["x", "y", "y"],
            runModel: "mlx-community/Qwen3-4B-4bit",
            environment: [
                "OSAURUS_EVALS_COMMIT": "abc1234",
                "OSAURUS_EVALS_KV_REGIME": "memory-only",
            ]
        )
        #expect(env.commit == "abc1234")
        #expect(env.kvRegime == "memory-only")
        #expect(env.runModel == "mlx-community/Qwen3-4B-4bit")
        #expect(env.caseCount == 2)  // de-duplicated
        #expect(env.catalogHash == RunEnvironment.catalogHash(forCaseIDs: ["x", "y"]))
        // Probed from the host — always present on a real macOS runner.
        #expect((env.totalRamMb ?? 0) > 0)
        #expect(env.osVersion != nil)
    }

    @Test func currentFlagsSelfJudgeWhenNoStrongKey() {
        let env = RunEnvironment.current(
            caseIDs: ["x"],
            runModel: "mlx-community/Qwen3-4B-4bit",
            environment: [:]  // no JUDGE_MODEL, no strong-judge API key
        )
        #expect(env.judge == "self-judge")
    }

    @Test func currentSelectsStrongRemoteJudge() {
        let env = RunEnvironment.current(
            caseIDs: ["x"],
            runModel: "mlx-community/Qwen3-4B-4bit",
            environment: ["XAI_API_KEY": "key-123"]
        )
        #expect(env.judge == "xai/grok-4.3")
    }

    @Test func currentHonorsExplicitJudgeModel() {
        let env = RunEnvironment.current(
            caseIDs: ["x"],
            runModel: "mlx-community/Qwen3-4B-4bit",
            environment: ["JUDGE_MODEL": "openai/gpt-5.1"]
        )
        #expect(env.judge == "openai/gpt-5.1")
    }

    @Test func blankCommitAndKvBecomeNil() {
        let env = RunEnvironment.current(
            caseIDs: ["x"],
            runModel: nil,
            environment: ["OSAURUS_EVALS_COMMIT": "   ", "OSAURUS_EVALS_KV_REGIME": ""]
        )
        #expect(env.commit == nil)
        #expect(env.kvRegime == nil)
    }
}
