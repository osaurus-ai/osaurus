//
//  AllChatsModel.swift
//  osaurus
//
//  The All chats page's list, as a pure function of its inputs: every chat
//  on this Mac through the filter chip, the agent chip and the search
//  (titles, agent names, and the message matches the full-text search
//  found), newest first, grouped by day and paged.
//

import Foundation

struct AllChatsModel: Equatable {

    enum GroupKey: Hashable, Sendable {
        case today
        case yesterday
        case previous7Days
        case month(year: Int, month: Int)
    }

    struct Group: Equatable, Identifiable {
        let key: GroupKey
        let rows: [ChatSessionData]
        var id: GroupKey { key }

        static func == (lhs: Group, rhs: Group) -> Bool {
            lhs.key == rhs.key && lhs.rows.map(\.id) == rhs.rows.map(\.id)
        }
    }

    /// Chats per filter chip, after the agent chip and the search.
    let counts: [AllChatsFilter: Int]
    /// The page so far, grouped by day.
    let groups: [Group]
    /// Every chat the chips and search let through, beyond the page too.
    let matchingIds: [UUID]
    /// Whether another page follows.
    let hasMore: Bool

    static let pageSize = 50

    /// The default title a chat keeps until it is named.
    nonisolated static func isUntitled(_ session: ChatSessionData) -> Bool {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || title.caseInsensitiveCompare("New Chat") == .orderedSame
    }

    /// `All`, `Pinned` and `Untitled` leave archived chats out; `Archived`
    /// is only them.
    nonisolated static func passes(_ session: ChatSessionData, filter: AllChatsFilter) -> Bool {
        switch filter {
        case .all: return !session.archived
        case .pinned: return !session.archived && session.pinned
        case .untitled: return !session.archived && isUntitled(session)
        case .archived: return session.archived
        }
    }

    nonisolated static func build(
        sessions: [ChatSessionData],
        agentNames: [UUID: String],
        query: String,
        filter: AllChatsFilter,
        agentId: UUID?,
        contentMatches: Set<UUID>,
        limit: Int = pageSize,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AllChatsModel {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let prepared = SearchService.PreparedQuery(trimmed)
        let scoped = sessions.filter { session in
            let owner = session.agentId ?? Agent.defaultId
            if let agentId, owner != agentId { return false }
            guard !trimmed.isEmpty else { return true }
            return contentMatches.contains(session.id)
                || SearchService.matches(prepared, in: session.title)
                || agentNames[owner].map { SearchService.matches(prepared, in: $0) } == true
        }
        var counts: [AllChatsFilter: Int] = [:]
        for chip in AllChatsFilter.allCases {
            counts[chip] = scoped.reduce(0) { $0 + (passes($1, filter: chip) ? 1 : 0) }
        }
        let matching = scoped.filter { passes($0, filter: filter) }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
        let page = Array(matching.prefix(max(limit, 0)))
        return AllChatsModel(
            counts: counts,
            groups: group(page, now: now, calendar: calendar),
            matchingIds: matching.map(\.id),
            hasMore: matching.count > page.count
        )
    }

    /// Today, Yesterday, Previous 7 days, then one group per month. Rows
    /// arrive newest first, so groups come out in order.
    nonisolated static func group(_ rows: [ChatSessionData], now: Date, calendar: Calendar) -> [Group] {
        var keys: [GroupKey] = []
        var buckets: [GroupKey: [ChatSessionData]] = [:]
        for row in rows {
            let key = groupKey(for: row.updatedAt, now: now, calendar: calendar)
            if buckets[key] == nil { keys.append(key) }
            buckets[key, default: []].append(row)
        }
        return keys.map { Group(key: $0, rows: buckets[$0] ?? []) }
    }

    nonisolated static func groupKey(for date: Date, now: Date, calendar: Calendar) -> GroupKey {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return .today }
        if days == 1 { return .yesterday }
        if days <= 7 { return .previous7Days }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return .month(year: parts.year ?? 0, month: parts.month ?? 0)
    }

    /// A group's header: the month alone in the current year, with the
    /// year otherwise.
    nonisolated static func title(
        for key: GroupKey, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        switch key {
        case .today: return L("Today")
        case .yesterday: return L("Yesterday")
        case .previous7Days: return L("Previous 7 days")
        case .month(let year, let month):
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return "" }
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            let thisYear = calendar.component(.year, from: now)
            formatter.setLocalizedDateFormatFromTemplate(year == thisYear ? "MMMM" : "MMMM yyyy")
            return formatter.string(from: date)
        }
    }
}
