//
//  SkillSuggestionsTests.swift
//  osaurus
//
//  Pure-function tests for `SkillSuggestions` — the standalone-skill
//  ranking that feeds the enabled-capabilities manifest's trailing
//  "Skills (no plugin)" group.
//
//  Tests here intentionally avoid the SkillSearchService state path: they
//  exercise `rankSkillSuggestions` and the blank-query short-circuit of
//  `deriveSkillSuggestions` so the suite stays runnable in any harness
//  without an embedder. The integration path (real search) is exercised by
//  the OsaurusEvals package.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SkillSuggestionsTests {

    // MARK: - rankSkillSuggestions

    /// Helper: build a `SkillSearchResult` from a name + score, with
    /// a default description and optional `pluginId` to mark the
    /// skill as plugin-bundled.
    private static func makeHit(
        _ name: String,
        score: Float,
        pluginId: String? = nil
    ) -> SkillSearchResult {
        let skill = Skill(
            id: UUID(),
            name: name,
            description: "desc for \(name)",
            instructions: "body",
            pluginId: pluginId
        )
        return SkillSearchResult(skill: skill, searchScore: score)
    }

    @Test func rankSkillSuggestionsCapsAtThree() {
        // The result feeds a compact manifest group — five ranked hits
        // must surface only the top 3. The cap is policy
        // (`maxSkillSuggestions`), so we test the contract not the
        // literal number.
        let hits = (0 ..< 5).map { Self.makeHit("skill_\($0)", score: Float(10 - $0) / 10) }
        let teasers = SkillSuggestions.rankSkillSuggestions(
            from: hits,
            alreadyLoadedSkillNames: []
        )
        #expect(teasers.count == SkillSuggestions.maxSkillSuggestions)
        // Top 3 by descending score = skill_0..skill_2.
        #expect(teasers.map(\.name) == ["skill_0", "skill_1", "skill_2"])
    }

    @Test func rankSkillSuggestionsExcludesPluginBundledSkills() {
        // Plugin-bundled skills are surfaced via the manifest's per-plugin
        // groups alongside their sibling tools. Showing them again in the
        // standalone "Skills (no plugin)" group would be noise; the
        // post-search filter must drop them.
        let hits = [
            Self.makeHit("standalone-1", score: 0.9),
            Self.makeHit("plugin-skill", score: 0.85, pluginId: "osaurus.browser"),
            Self.makeHit("standalone-2", score: 0.8),
        ]
        let teasers = SkillSuggestions.rankSkillSuggestions(
            from: hits,
            alreadyLoadedSkillNames: []
        )
        #expect(teasers.map(\.name) == ["standalone-1", "standalone-2"])
    }

    @Test func rankSkillSuggestionsExcludesAlreadyLoadedSkills() {
        // After the model calls `capabilities_load("skill/X")`, X
        // shouldn't keep showing up in the manifest every turn — the
        // loader already injected its full body. Callers thread the
        // loaded names in via `alreadyLoadedSkillNames`.
        let hits = [
            Self.makeHit("alpha", score: 0.9),
            Self.makeHit("beta", score: 0.8),
            Self.makeHit("gamma", score: 0.7),
        ]
        let teasers = SkillSuggestions.rankSkillSuggestions(
            from: hits,
            alreadyLoadedSkillNames: ["beta"]
        )
        #expect(teasers.map(\.name) == ["alpha", "gamma"])
    }

    @Test func rankSkillSuggestionsTieBreaksAlphabetically() {
        // KV-cache stability: when two skills tie on score the
        // rendered prompt bytes must be identical across runs. The
        // search service doesn't promise a tie-break order, so the
        // rank step does it explicitly. Three skills on the same
        // score must come back in name order.
        let hits = [
            Self.makeHit("zulu", score: 0.5),
            Self.makeHit("alpha", score: 0.5),
            Self.makeHit("mike", score: 0.5),
        ]
        let teasers = SkillSuggestions.rankSkillSuggestions(
            from: hits,
            alreadyLoadedSkillNames: []
        )
        #expect(teasers.map(\.name) == ["alpha", "mike", "zulu"])
    }

    @Test func rankSkillSuggestionsReturnsEmptyWhenNoStandaloneHits() {
        // Pure plugin-bundled hit set -> nothing to surface as a
        // standalone skill. Tests the guard that returns `[]`.
        let hits = [
            Self.makeHit("p1", score: 0.9, pluginId: "x"),
            Self.makeHit("p2", score: 0.8, pluginId: "y"),
        ]
        let teasers = SkillSuggestions.rankSkillSuggestions(
            from: hits,
            alreadyLoadedSkillNames: []
        )
        #expect(teasers.isEmpty)
    }

    // MARK: - deriveSkillSuggestions short-circuits

    @Test func deriveSkillSuggestionsReturnsEmptyForBlankQuery() async {
        // No query -> no point hitting the search service. The
        // composer wires this gate around preflight too; this test
        // pins the same short-circuit at the function level so a
        // future caller bypassing the gate doesn't fire a useless
        // (and async) search call.
        #expect(await SkillSuggestions.deriveSkillSuggestions(query: "").isEmpty)
        #expect(await SkillSuggestions.deriveSkillSuggestions(query: "   \n\t  ").isEmpty)
    }
}
