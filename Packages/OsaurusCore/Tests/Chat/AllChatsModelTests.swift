//
//  AllChatsModelTests.swift
//  osaurusTests
//
//  The All chats page's list: filter chips and their counts, the agent
//  chip, the search (titles, agent names, message matches), day and month
//  groups, and paging.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct AllChatsModelTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Noon, Thursday 19 November 2026 (UTC).
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 12))! }

    private func daysAgo(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: now)! }

    private func chat(
        _ title: String, agent: UUID? = nil, daysAgo days: Int = 0, archived: Bool = false, pinned: Bool = false
    ) -> ChatSessionData {
        ChatSessionData(title: title, updatedAt: daysAgo(days), agentId: agent, archived: archived, pinned: pinned)
    }

    private func build(
        _ sessions: [ChatSessionData], query: String = "", filter: AllChatsFilter = .all, agentId: UUID? = nil,
        agentNames: [UUID: String] = [:], contentMatches: Set<UUID> = [], limit: Int = AllChatsModel.pageSize
    ) -> AllChatsModel {
        AllChatsModel.build(
            sessions: sessions, agentNames: agentNames, query: query, filter: filter, agentId: agentId,
            contentMatches: contentMatches, limit: limit, now: now, calendar: calendar)
    }

    @Test("All, Pinned and Untitled leave archived chats out; Archived is only them; each chip counts")
    func filtersAndCounts() {
        let plain = chat("Trip plan")
        let pinned = chat("Budget", pinned: true)
        let untitled = chat("New Chat")
        let blank = chat("  ")
        let archived = chat("Old notes", archived: true)
        let archivedUntitled = chat("New Chat", archived: true, pinned: true)
        let all = [plain, pinned, untitled, blank, archived, archivedUntitled]

        let model = build(all)
        #expect(model.counts == [.all: 4, .pinned: 1, .untitled: 2, .archived: 2])
        #expect(Set(model.matchingIds) == [plain.id, pinned.id, untitled.id, blank.id])
        #expect(Set(build(all, filter: .pinned).matchingIds) == [pinned.id])
        #expect(Set(build(all, filter: .untitled).matchingIds) == [untitled.id, blank.id])
        #expect(Set(build(all, filter: .archived).matchingIds) == [archived.id, archivedUntitled.id])
    }

    @Test("the agent chip keeps one agent's chats; chats with no agent belong to the Orchestrator")
    func agentChip() {
        let writer = UUID()
        let mine = chat("Draft", agent: writer)
        let orchestrator = chat("Hello", agent: nil)
        let model = build([mine, orchestrator], agentId: writer)
        #expect(model.matchingIds == [mine.id])
        #expect(build([mine, orchestrator], agentId: Agent.defaultId).matchingIds == [orchestrator.id])
        #expect(model.counts[.all] == 1)
    }

    @Test("search matches the title, the agent's name, or a message the full-text search found")
    func search() {
        let writer = UUID()
        let byTitle = chat("Quarterly taxes")
        let byAgent = chat("Chapter one", agent: writer)
        let byMessage = chat("New Chat")
        let miss = chat("Groceries")
        let all = [byTitle, byAgent, byMessage, miss]
        let names = [writer: "Taxman"]
        #expect(Set(build(all, query: "tax", agentNames: names, contentMatches: [byMessage.id]).matchingIds)
            == [byTitle.id, byAgent.id, byMessage.id])
        // A message match is enough on its own: the title says nothing.
        #expect(build(all, query: "zebra", contentMatches: [byMessage.id]).matchingIds == [byMessage.id])
        #expect(build(all, query: "zebra").matchingIds.isEmpty)
    }

    @Test("rows are newest first, grouped Today, Yesterday, Previous 7 days, then by month")
    func dayGroups() {
        let today = chat("a", daysAgo: 0)
        let yesterday = chat("b", daysAgo: 1)
        let lastWeek = chat("c", daysAgo: 6)
        let thisMonth = chat("d", daysAgo: 12)
        let lastYear = chat("e", daysAgo: 400)
        let model = build([lastYear, thisMonth, today, lastWeek, yesterday])
        #expect(model.groups.map(\.key) == [
            .today, .yesterday, .previous7Days, .month(year: 2026, month: 11), .month(year: 2025, month: 10),
        ])
        #expect(model.groups.flatMap(\.rows).map(\.id) == [today.id, yesterday.id, lastWeek.id, thisMonth.id, lastYear.id])
    }

    @Test("a month header names the year only outside the current year")
    func monthTitles() {
        let locale = Locale(identifier: "en_US")
        #expect(AllChatsModel.title(for: .month(year: 2026, month: 3), now: now, calendar: calendar, locale: locale) == "March")
        #expect(AllChatsModel.title(for: .month(year: 2025, month: 3), now: now, calendar: calendar, locale: locale) == "March 2025")
        #expect(AllChatsModel.title(for: .today) == "Today")
    }

    @Test("the list pages in batches of 50; the counts and matches cover every chat")
    func paging() {
        let chats = (0..<120).map { chat("Chat \($0)", daysAgo: $0 % 30) }
        let first = build(chats)
        #expect(first.groups.flatMap(\.rows).count == 50)
        #expect(first.hasMore)
        #expect(first.matchingIds.count == 120)
        #expect(first.counts[.all] == 120)
        let last = build(chats, limit: 150)
        #expect(last.groups.flatMap(\.rows).count == 120)
        #expect(!last.hasMore)
    }

    @Test("the sidebar's counts are the page's All chip, for everyone or one agent")
    func sidebarCountsMatchThePage() {
        let dinoki = UUID()
        let chats = [
            chat("Mine", agent: dinoki),
            chat("Pinned", agent: dinoki, pinned: true),
            chat("Old", agent: dinoki, archived: true),
            chat("Orchestrator"),
        ]
        #expect(ChatSessionSidebar.allChatsCount(chats) == build(chats).counts[.all])
        #expect(ChatSessionSidebar.allChatsCount(chats, agentId: dinoki) == build(chats, agentId: dinoki).counts[.all])
        #expect(Set(ChatSessionSidebar.allChatsIds(chats, agentId: dinoki)) == Set(build(chats, agentId: dinoki).matchingIds))
        #expect(ChatSessionSidebar.allChatsCount(chats, agentId: Agent.defaultId) == 1)
    }

    @Test("New Agent chats (the hidden Configurator's) are not listed or counted")
    func hiddenBuiltInChatsLeftOut() {
        let creator = chat("New agent: Trip Planner", agent: Agent.configuratorId)
        let mine = chat("Hello")
        #expect(build([creator, mine]).matchingIds == [mine.id])
        #expect(build([creator, mine]).counts[.all] == 1)
        #expect(build([creator, mine], query: "trip").matchingIds.isEmpty)
        #expect(ChatSessionSidebar.allChatsCount([creator, mine]) == 1)
    }

    @Test("a chip or a search narrows the list; All with no agent and no query does not")
    func narrowedList() {
        #expect(!AllChatsPage.isNarrowed(filter: .all, agentId: nil, query: "  "))
        #expect(AllChatsPage.isNarrowed(filter: .untitled, agentId: nil, query: ""))
        #expect(AllChatsPage.isNarrowed(filter: .all, agentId: UUID(), query: ""))
        #expect(AllChatsPage.isNarrowed(filter: .all, agentId: nil, query: "tax"))
    }
}
