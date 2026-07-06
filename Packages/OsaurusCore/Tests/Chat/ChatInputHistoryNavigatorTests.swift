//
//  ChatInputHistoryNavigatorTests.swift
//  osaurusTests
//

import Testing

@testable import OsaurusCore

struct ChatInputHistoryNavigatorTests {
    @Test
    func previousReturnsMostRecentEntryAndThenOlderEntries() {
        var history = ChatInputHistoryNavigator()
        history.record("first")
        history.record("second")

        #expect(history.previous(currentText: "") == "second")
        #expect(history.previous(currentText: "") == "first")
        #expect(history.previous(currentText: "") == "first")
    }

    @Test
    func nextRestoresDraftAfterNewestEntry() {
        var history = ChatInputHistoryNavigator()
        history.record("first")
        history.record("second")

        #expect(history.previous(currentText: "draft") == "second")
        #expect(history.next() == "draft")
        #expect(history.next() == nil)
    }

    @Test
    func recordTrimsSkipsBlankAndDeduplicatesAdjacentEntries() {
        var history = ChatInputHistoryNavigator()
        history.record("  ")
        history.record("  first  ")
        history.record("first")
        history.record("second")

        #expect(history.entries == ["first", "second"])
    }

    @Test
    func recordCapsEntriesToConfiguredLimit() {
        var history = ChatInputHistoryNavigator(limit: 2)
        history.record("one")
        history.record("two")
        history.record("three")

        #expect(history.entries == ["two", "three"])
        #expect(history.previous(currentText: "") == "three")
        #expect(history.previous(currentText: "") == "two")
    }

    @Test
    func resetClearsEntriesAndDraftNavigation() {
        var history = ChatInputHistoryNavigator()
        history.record("first")

        #expect(history.previous(currentText: "draft") == "first")
        history.reset()

        #expect(history.entries.isEmpty)
        #expect(history.next() == nil)
        #expect(history.previous(currentText: "") == nil)
    }
}
