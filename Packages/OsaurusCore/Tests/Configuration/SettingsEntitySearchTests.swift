//
//  SettingsEntitySearchTests.swift
//  osaurusTests
//

import Testing

@testable import OsaurusCore

struct SettingsEntitySearchTests {
    private func c(_ kind: SettingsEntityCandidate.Kind, _ name: String) -> SettingsEntityCandidate {
        .init(kind: kind, key: name, name: name)
    }

    @Test func ranksExactThenPrefixThenWordPrefixThenSubstring() {
        let candidates = [
            c(.agent, "Market Researcher"),
            c(.workflow, "research"),
            c(.agent, "Researcher"),
            c(.model, "deep-research-7b"),
        ]
        let names = SettingsEntitySearch.match("research", in: candidates).map(\.name)
        #expect(names == ["research", "Researcher", "Market Researcher", "deep-research-7b"])
    }

    @Test func isCaseAndDiacriticInsensitive() {
        let candidates = [c(.workflow, "Café Noir")]
        #expect(SettingsEntitySearch.match("cafe", in: candidates).count == 1)
        #expect(SettingsEntitySearch.match("CAFÉ noir", in: candidates).count == 1)
    }

    @Test func everyQueryWordMustStartAWord() {
        let candidates = [c(.workflow, "Daily News Digest"), c(.workflow, "Weekly Digest")]
        #expect(SettingsEntitySearch.match("da dig", in: candidates).map(\.name) == ["Daily News Digest"])
    }

    @Test func ignoresQueriesShorterThanTwoCharacters() {
        #expect(SettingsEntitySearch.match("a", in: [c(.agent, "Assistant")]).isEmpty)
        #expect(SettingsEntitySearch.match("  ", in: [c(.agent, "Assistant")]).isEmpty)
    }

    @Test func capsResultsPerKind() {
        let many = (1...9).map { c(.model, "llama-\($0)") } + [c(.agent, "Llama Wrangler")]
        let hits = SettingsEntitySearch.match("llama", in: many)
        #expect(hits.filter { $0.kind == .model }.count == SettingsEntitySearch.limitPerKind)
        #expect(hits.contains { $0.kind == .agent })
    }

    @Test func idsAreUniqueAcrossKinds() {
        let a = SettingsEntityCandidate(kind: .agent, key: "x", name: "Same")
        let w = SettingsEntityCandidate(kind: .workflow, key: "x", name: "Same")
        #expect(a.id != w.id)
    }
}
