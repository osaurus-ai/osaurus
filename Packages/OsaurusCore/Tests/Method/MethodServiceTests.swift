//
//  MethodServiceTests.swift
//  osaurus
//
//  Unit tests for MethodService: YAML tool/skill extraction and score formula.
//

import Foundation
import Testing

@testable import OsaurusCore

struct MethodServiceExtractToolIdsTests {

    @Test func extractsToolIdsFromYAML() async {
        let yaml = """
            steps:
              - tool: terminal
                action: git status
              - tool: web_fetch
                action: GET /health
              - tool: sandbox_execute_code
                action: run test
            """
        let result = await MethodService.shared.extractToolIds(from: yaml)
        #expect(result == ["terminal", "web_fetch", "sandbox_execute_code"])
    }

    @Test func extractsToolIdsDeduplicates() async {
        let yaml = """
            steps:
              - tool: terminal
                action: ls
              - tool: terminal
                action: pwd
              - tool: web_fetch
                action: GET /
            """
        let result = await MethodService.shared.extractToolIds(from: yaml)
        #expect(result == ["terminal", "web_fetch"])
    }

    @Test func extractsToolIdsFromEmptyYAML() async {
        let result = await MethodService.shared.extractToolIds(from: "")
        #expect(result.isEmpty)
    }

    @Test func extractsToolIdsIgnoresNonToolLines() async {
        let yaml = """
            description: This is a method
            failure_modes:
              - "timeout → retry"
            steps:
              - tool: terminal
                action: echo hello
                expect: hello
            """
        let result = await MethodService.shared.extractToolIds(from: yaml)
        #expect(result == ["terminal"])
    }

    @Test func extractsToolIdsStripsQuotes() async {
        let yaml = """
            steps:
              - tool: "terminal"
                action: test
              - tool: 'web_fetch'
                action: fetch
            """
        let result = await MethodService.shared.extractToolIds(from: yaml)
        #expect(result == ["terminal", "web_fetch"])
    }
}

struct MethodServiceExtractSkillIdsTests {

    @Test func extractsSkillIdsFromYAML() async {
        let yaml = """
            steps:
              - tool: terminal
            skill_context: gemini-api
            """
        let result = await MethodService.shared.extractSkillIds(from: yaml)
        #expect(result == ["gemini-api"])
    }

    @Test func extractsSkillIdsDeduplicates() async {
        let yaml = """
            skill_context: gemini-api
            steps:
              - tool: terminal
            skill_context: gemini-api
            """
        let result = await MethodService.shared.extractSkillIds(from: yaml)
        #expect(result == ["gemini-api"])
    }

    @Test func extractsNoSkillIdsFromPlainYAML() async {
        let yaml = """
            steps:
              - tool: terminal
                action: echo
            """
        let result = await MethodService.shared.extractSkillIds(from: yaml)
        #expect(result.isEmpty)
    }
}

struct MethodScoreFormulaTests {

    @Test func perfectScoreRecentlyUsed() {
        var score = MethodScore(
            methodId: "test",
            timesSucceeded: 10,
            timesFailed: 0,
            lastUsedAt: Date()
        )
        score.recalculate()
        #expect(score.successRate == 1.0)
        #expect(score.score > 0.9)
    }

    @Test func mixedOutcomeFiveDaysAgo() {
        var score = MethodScore(
            methodId: "test",
            timesLoaded: 10,
            timesSucceeded: 8,
            timesFailed: 2,
            lastUsedAt: Date().addingTimeInterval(-5 * 86400)
        )
        score.recalculate()

        let expectedRate = 8.0 / 10.0
        #expect(abs(score.successRate - expectedRate) < 0.001)

        let expectedRecency = 1.0 / (1.0 + 5.0 / 30.0)
        let expectedScore = expectedRate * expectedRecency
        #expect(abs(score.score - expectedScore) < 0.01)
    }

    @Test func zeroUsesReturnsZeroScore() {
        var score = MethodScore(methodId: "test")
        score.recalculate()
        #expect(score.successRate == 0.0)
        #expect(score.score == 0.0)
    }

    @Test func neverUsedDecaysHeavily() {
        var score = MethodScore(
            methodId: "test",
            timesSucceeded: 5,
            timesFailed: 0,
            lastUsedAt: nil
        )
        score.recalculate()
        #expect(score.successRate == 1.0)
        #expect(score.score < 0.1)
    }

    @Test func allFailsZeroSuccessRate() {
        var score = MethodScore(
            methodId: "test",
            timesSucceeded: 0,
            timesFailed: 10,
            lastUsedAt: Date()
        )
        score.recalculate()
        #expect(score.successRate == 0.0)
        #expect(score.score == 0.0)
    }
}
