//
//  SettingsSearchTypoToleranceTests.swift
//  osaurusTests
//

import Testing

@testable import OsaurusCore

struct SettingsSearchTypoToleranceTests {
    private func titles(_ query: String) -> [String] {
        SettingsSearchIndex.search(query).map(\.title)
    }

    @Test func oneTypoStillFindsTheSetting() {
        #expect(titles("hotky").contains("Global Hotkey"))
        #expect(titles("transcripton").contains("Enable Transcription Mode"))
        #expect(titles("temprature").contains("Temperature"))
    }

    @Test func typoMatchesNeverJoinStrictResults() {
        // "cache" strictly matches; "catch" is one edit away but must not leak in.
        let results = titles("cache")
        #expect(!results.isEmpty)
        #expect(SettingsSearchIndex.search("cache").allSatisfy { entry in
            ([entry.title, entry.section, entry.tab.label] + entry.keywords)
                .contains { $0.lowercased().contains("cache") }
        })
    }

    @Test func shortWordsAndNonsenseStayStrict() {
        #expect(SettingsSearchIndex.typoBudget(for: "tts") == 0)
        #expect(titles("qzxv").isEmpty)
        #expect(titles("zzzzzzzzzz").isEmpty)
    }

    @Test func editDistanceStopsAtTheLimit() {
        #expect(SettingsSearchIndex.editDistance("hotky", "hotkey", limit: 1) == 1)
        #expect(SettingsSearchIndex.editDistance("kitten", "sitting", limit: 3) == 3)
        #expect(SettingsSearchIndex.editDistance("abc", "abcdefgh", limit: 1) == 2)
        #expect(SettingsSearchIndex.editDistance("", "ab", limit: 2) == 2)
    }
}
