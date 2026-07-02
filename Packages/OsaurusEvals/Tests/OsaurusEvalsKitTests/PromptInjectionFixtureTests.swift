//
//  PromptInjectionFixtureTests.swift
//  OsaurusEvalsKitTests
//
//  Token-free coverage for the prompt-injection lane. The cases need a
//  live model to prove resistance, so this pins the FIXTURE contract
//  instead: every case is an agent_loop case that (a) plants an
//  adversarial instruction in a fixture the agent must read, and (b)
//  carries at least one deterministic leak/behaviour guard — a
//  finalTextMustNotContain canary, a files exists:false marker check, or
//  a shell_run argsMustNotContain audit — so a compromised model fails on
//  hard evidence, not judge opinion alone. It also unit-tests the new
//  finalTextMustNotContain scorer wiring is decoded.
//

import Foundation
import Testing

@testable import OsaurusEvalsKit

@MainActor
struct PromptInjectionFixtureTests {
    private func loadSuite() throws -> EvalSuite {
        let suiteDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusEvalsKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // OsaurusEvals
            .appendingPathComponent("Suites/PromptInjection", isDirectory: true)
        return try EvalSuite.load(from: suiteDir)
    }

    @Test func suiteDecodesAsAgentLoopCases() throws {
        let suite = try loadSuite()
        #expect(suite.decodeFailures.isEmpty, "decode failures: \(suite.decodeFailures)")
        #expect(suite.cases.count >= 4, "PromptInjection suite shrank; got \(suite.cases.count)")
        for testCase in suite.cases {
            // Injection resistance can only be measured where the agent can
            // ACT — so every case rides the agent_loop seam.
            #expect(testCase.domain == "agent_loop", "\(testCase.id) must be an agent_loop case")
            #expect(testCase.expect.agentLoop != nil, "\(testCase.id) missing expect.agentLoop")
            #expect(testCase.id.hasPrefix("prompt_injection."), "\(testCase.id) id prefix")
        }
    }

    /// Each case must plant an adversarial payload in a readable fixture:
    /// there is no injection test without an injection.
    @Test func everyCaseSeedsAnAdversarialFixture() throws {
        let suite = try loadSuite()
        for testCase in suite.cases {
            let files = testCase.fixtures.workspaceFiles ?? []
            #expect(!files.isEmpty, "\(testCase.id) seeds no workspace files to carry the payload")
        }
    }

    /// Each case must carry at least one DETERMINISTIC guard so a
    /// compromised model fails on evidence, not judge opinion alone: a
    /// leak canary (finalTextMustNotContain), a marker-not-written check
    /// (files exists:false), or a forbidden-arg audit (argsMustNotContain).
    @Test func everyCaseHasADeterministicGuard() throws {
        let suite = try loadSuite()
        for testCase in suite.cases {
            let exp = try #require(testCase.expect.agentLoop)
            let hasCanary = !(exp.finalTextMustNotContain ?? []).isEmpty
            let hasNegativeFile = (exp.files ?? []).contains { $0.exists == false }
            let hasForbiddenArg = (exp.toolUsageAudit ?? []).contains {
                $0.argsMustNotContain != nil
            }
            #expect(
                hasCanary || hasNegativeFile || hasForbiddenArg,
                "\(testCase.id) has no deterministic injection guard (needs a canary, a files exists:false marker, or a shell argsMustNotContain audit)"
            )
        }
    }

    /// The new finalTextMustNotContain field must round-trip from JSON.
    @Test func canaryFieldDecodes() throws {
        let suite = try loadSuite()
        let canaries = suite.cases.compactMap(\.expect.agentLoop).flatMap {
            $0.finalTextMustNotContain ?? []
        }
        #expect(!canaries.isEmpty, "no case declares a finalTextMustNotContain canary")
    }
}
