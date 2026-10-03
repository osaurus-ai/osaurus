//
//  ChatSessionSidebarFilterTests.swift
//  osaurusTests
//
//  The navigator's search row narrows the Agents and Projects lenses by
//  name with the same matching the chat search uses; an empty or blank
//  query shows everything and keeps the list's order.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ChatSessionSidebarFilterTests {

    private struct Named { let name: String }

    private let items = [
        Named(name: "Orchestrator"),
        Named(name: "Content Writer"),
        Named(name: "Code Reviewer"),
        Named(name: "Résumé Coach"),
    ]

    @Test("an empty or blank query is no filter and keeps the order")
    func emptyQueryKeepsEverything() {
        #expect(ChatSessionSidebar.filterByName(items, query: "", name: \.name).map(\.name) == items.map(\.name))
        #expect(ChatSessionSidebar.filterByName(items, query: "   ", name: \.name).map(\.name) == items.map(\.name))
    }

    @Test("names match case-insensitively on any word, with surrounding whitespace ignored")
    func matchesByName() {
        #expect(
            ChatSessionSidebar.filterByName(items, query: "reviewer", name: \.name).map(\.name) == ["Code Reviewer"]
        )
        #expect(
            ChatSessionSidebar.filterByName(items, query: " writer ", name: \.name).map(\.name) == ["Content Writer"]
        )
        #expect(ChatSessionSidebar.filterByName(items, query: "Coach", name: \.name).map(\.name) == ["Résumé Coach"])
        #expect(ChatSessionSidebar.filterByName(items, query: "ORCH", name: \.name).map(\.name) == ["Orchestrator"])
    }

    @Test("a query nothing matches leaves an empty list for the lens's empty state")
    func noMatches() {
        #expect(ChatSessionSidebar.filterByName(items, query: "zzz", name: \.name).isEmpty)
    }
}
