//
//  OrchestratorHarnessReadinessTests.swift
//  osaurusTests
//
//  Settings → Orchestrator's Model Readiness row for a Default agent on a
//  harness: it names the runtime's model and grades the Claude Code
//  switches instead of a local model's context window.
//

import Foundation
import Testing

@testable import OsaurusCore

struct OrchestratorHarnessReadinessTests {
    private typealias Verdict = OrchestratorModelReadinessRow.Verdict
    private let claudeCode = HarnessSelection.resolved(.builtInClaudeCode)

    @Test func claudeCodeWithToolsAndConfigWritesIsReady() {
        let verdict = Verdict.make(
            harness: claudeCode,
            claudeCode: ClaudeCodeAgentConfig(allowOsaurusConfigWrites: true, model: "opus")
        )
        #expect(verdict.tools == .ok)
        #expect(verdict.hint == nil)
        #expect(verdict.modelName == "\(HarnessRuntime.builtInClaudeCode.displayName) · Opus")
        #expect(verdict.contextLength == nil)
        #expect(verdict.runtimeNote != nil)
    }

    @Test func theDefaultsDelegateButCannotChangeSettings() {
        let verdict = Verdict.make(harness: claudeCode, claudeCode: .default)
        #expect(verdict.tools == .limited)
        #expect(verdict.hint?.contains("Allow Osaurus configuration changes") == true)
        #expect(verdict.modelName?.hasSuffix("· Sonnet") == true)
    }

    @Test func osaurusToolsOffIsLimitedAndNamesTheSwitch() {
        let verdict = Verdict.make(harness: claudeCode, claudeCode: ClaudeCodeAgentConfig(osaurusTools: false))
        #expect(verdict.tools == .limited)
        #expect(verdict.hint?.contains("Use Osaurus Tools") == true)
    }

    @Test func textOnlyHasNoTools() {
        let verdict = Verdict.make(
            harness: claudeCode,
            claudeCode: ClaudeCodeAgentConfig(mode: .textOnly, allowOsaurusConfigWrites: true)
        )
        #expect(verdict.tools == .off)
    }

    @Test func aFullModelIdIsShownAsIs() {
        let verdict = Verdict.make(harness: claudeCode, claudeCode: ClaudeCodeAgentConfig(model: "claude-sonnet-4-5"))
        #expect(verdict.modelName?.hasSuffix("· claude-sonnet-4-5") == true)
    }

    @Test func aMissingRuntimeCannotRun() {
        let verdict = Verdict.make(harness: .missing(UUID()), claudeCode: .default)
        #expect(verdict.tools == .off)
        #expect(verdict.hint != nil)
    }

    @Test func piIsNotGradedOnClaudeCodeSwitches() {
        let pi = HarnessRuntime(name: "Pi", kind: .piRPC)
        let verdict = Verdict.make(
            harness: .resolved(pi),
            claudeCode: ClaudeCodeAgentConfig(allowOsaurusConfigWrites: true)
        )
        #expect(verdict.tools == .limited)
        #expect(verdict.modelName == "Pi")
    }
}
