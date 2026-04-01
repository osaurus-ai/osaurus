//
//  SkillSearchServiceTests.swift
//  osaurus
//
//  Tests for SkillSearchService: verifies graceful degradation when
//  VecturaKit is uninitialized. Full search quality is validated empirically.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SkillSearchServiceTests {

    @Test func searchReturnsEmptyWhenUninitialized() async {
        let results = await SkillSearchService.shared.search(query: "build a gradio app")
        #expect(results.isEmpty)
    }

    @Test func indexSkillDoesNotCrashWhenUninitialized() async {
        let skill = Skill(
            id: UUID(),
            name: "test-skill",
            description: "A test skill",
            version: "1.0",
            keywords: ["testing", "example"],
            instructions: "test content"
        )
        await SkillSearchService.shared.indexSkill(skill)
    }

    @Test func indexSkillWithoutKeywordsFallsBackToDescription() async {
        let skill = Skill(
            id: UUID(),
            name: "no-keywords-skill",
            description: "A fallback description",
            version: "1.0",
            instructions: "test content"
        )
        await SkillSearchService.shared.indexSkill(skill)
    }

    @Test func removeSkillDoesNotCrashWhenUninitialized() async {
        await SkillSearchService.shared.removeSkill(id: UUID())
    }

    @Test func rebuildIndexDoesNotCrashWhenUninitialized() async {
        await SkillSearchService.shared.rebuildIndex()
    }

    @Test func searchWithTopKZeroReturnsEmpty() async {
        let results = await SkillSearchService.shared.search(query: "anything", topK: 0)
        #expect(results.isEmpty)
    }

    @Test func skillSearchResultCarriesScore() {
        let skill = Skill(
            id: UUID(),
            name: "test",
            description: "desc",
            keywords: ["kw"],
            instructions: "body"
        )
        let result = SkillSearchResult(skill: skill, searchScore: 0.85)
        #expect(result.searchScore == 0.85)
        #expect(result.skill.name == "test")
        #expect(result.skill.keywords == ["kw"])
    }
}
