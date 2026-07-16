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

@Suite(.serialized)
struct SkillSearchServiceTests {

    @Test func searchFallsBackToBuiltInSkillsWhenUninitialized() async {
        // Every installed skill (built-ins included) is universally
        // searchable, so the lexical fallback should surface Mac Automator
        // with no enablement setup.
        await SandboxTestLock.runWithStoragePaths {
            await SkillManager.shared.refresh()
            guard SkillManager.shared.skill(named: L("Mac Automator")) != nil
            else {
                Issue.record("Mac Automator built-in skill missing")
                return
            }

            let results = await SkillSearchService.shared.search(
                query: "write an applescript to control safari",
                threshold: 0.25
            )

            #expect(results.contains { $0.skill.name == L("Mac Automator") })
        }
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
