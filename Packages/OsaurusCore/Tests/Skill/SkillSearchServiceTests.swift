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
        // The live lexical fallback only surfaces *enabled* skills, and
        // built-ins ship disabled. Enable one for the duration of the check
        // (under the storage lock so the transient state can't leak into
        // sibling suites) and restore it before releasing.
        await SandboxTestLock.runWithStoragePaths {
            await SkillManager.shared.refresh()
            guard let debugAssistant = SkillManager.shared.skill(named: L("Debug Assistant"))
            else {
                Issue.record("Debug Assistant built-in skill missing")
                return
            }
            let wasEnabled = debugAssistant.enabled
            await SkillManager.shared.setEnabled(true, for: debugAssistant.id)

            let results = await SkillSearchService.shared.search(
                query: "help me debug this crash",
                threshold: 0.25
            )

            await SkillManager.shared.setEnabled(wasEnabled, for: debugAssistant.id)
            #expect(results.contains { $0.skill.name == L("Debug Assistant") })
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
