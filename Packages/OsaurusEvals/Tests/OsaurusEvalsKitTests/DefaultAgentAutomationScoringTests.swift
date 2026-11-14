//
//  DefaultAgentAutomationScoringTests.swift
//  OsaurusEvalsKitTests
//
//  Pins the DefaultAgent state assertions: `expectAutomations` matches the
//  automations the case created (read from the store, not the transcript)
//  and `expectAutomationCount` pins how many were created.
//

import Foundation
import Testing

@testable import OsaurusEvalsKit

@Suite
struct DefaultAgentAutomationScoringTests {
    private typealias Matcher = EvalCase.DefaultAgentExpectations.AutomationMatcher
    private typealias Snapshot = EvalRunner.EvalAutomationSnapshot

    private static let digest = Snapshot(
        name: "Weekday digest", sourceKind: "schedule", action: "workflow", workflow: "Daily Digest",
        boundInputs: ["day"], cron: "0  8 * * 1-5")
    private static let quote = Snapshot(
        name: "Morning quote", sourceKind: "schedule", action: "prompt",
        instructions: "Give me a short motivational quote.")

    @MainActor
    @Test func matcherChecksEveryPresentField() {
        let digest = Self.digest
        #expect(digest.matches(Matcher(sourceKind: "schedule", action: "workflow", workflow: "daily digest")))
        #expect(digest.matches(Matcher(inputKeys: ["day"], cron: "0 8 * * 1-5")))
        #expect(!digest.matches(Matcher(action: "agent")))
        #expect(!digest.matches(Matcher(workflow: "Issue Triage")))
        #expect(!digest.matches(Matcher(inputKeys: ["day", "topic"])))
        #expect(!digest.matches(Matcher(cron: "0 8 * * *")))
        #expect(!digest.matches(Matcher(agent: "Eval News Agent")))

        #expect(Self.quote.matches(Matcher(action: "prompt", instructionsContain: "QUOTE")))
        #expect(!Self.quote.matches(Matcher(instructionsContain: "weather")))
    }

    @MainActor
    @Test func scoringReportsCountAndMissingMatchers() {
        let exp = EvalCase.DefaultAgentExpectations(
            expectAutomations: [Matcher(action: "workflow", workflow: "Daily Digest")],
            expectAutomationCount: 1)
        let ok = EvalRunner.scoreAutomations(exp, created: [Self.digest])
        #expect(ok.allSatisfy { $0.passed })

        let wrong = EvalRunner.scoreAutomations(exp, created: [Self.quote, Self.digest])
        #expect(wrong.filter { !$0.passed }.count == 1)
        #expect(wrong.contains { !$0.passed && $0.note.contains("expected 1, created 2") })

        let none = EvalRunner.scoreAutomations(exp, created: [])
        #expect(none.filter { !$0.passed }.count == 2)
        #expect(none.contains { $0.note.contains("created [none]") })

        let handoff = EvalCase.DefaultAgentExpectations(expectAutomationCount: 0)
        #expect(EvalRunner.scoreAutomations(handoff, created: []).allSatisfy { $0.passed })
        #expect(EvalRunner.scoreAutomations(EvalCase.DefaultAgentExpectations(), created: [Self.quote]).isEmpty)
    }

    @Test func automationCasesDecodeTheirStateAssertions() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Suites/Configurator/automation-workflow-weekday-schedule.json")
        let evalCase = try JSONDecoder().decode(EvalCase.self, from: Data(contentsOf: url))
        let seeds = try #require(evalCase.fixtures.seedInstalledWorkflows)
        #expect(seeds.map(\.name) == ["Daily Digest"])
        #expect(seeds.first?.required == ["day"])
        let exp = try #require(evalCase.expect.defaultAgent)
        #expect(exp.expectAutomationCount == 1)
        #expect(exp.expectAutomations?.first?.cron == "0 8 * * 1-5")
    }
}
