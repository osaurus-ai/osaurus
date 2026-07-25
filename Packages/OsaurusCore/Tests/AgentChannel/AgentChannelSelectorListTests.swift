//
//  AgentChannelSelectorListTests.swift
//  osaurusTests
//
//  Locks the shaping rules for large discovery selector lists (channel setup
//  channels/people): query matching, selected-first pinning, and the browse
//  cap that keeps 1000+-entry lists navigable without ever hiding selections.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentChannelSelectorListTests {
    private struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
    }

    private func entries(_ count: Int, prefix: String = "user") -> [Entry] {
        (0..<count).map { Entry(id: "\(prefix)-id-\($0)", name: "\(prefix) \($0)") }
    }

    private func shape(
        _ all: [Entry],
        query: String = "",
        selected: Set<String> = [],
        browseLimit: Int = 3
    ) -> AgentChannelSelectorList.Shaped<Entry, Bool> {
        AgentChannelSelectorList.shape(
            all,
            query: query,
            fields: { [$0.name, $0.id] },
            state: { selected.contains($0.id) },
            isSelected: { $0 },
            browseLimit: browseLimit
        )
    }

    // MARK: - Browsing (no query)

    @Test func browsingCapsUnselectedAndReportsHiddenCount() {
        let all = entries(10)
        let shaped = shape(all, browseLimit: 3)

        #expect(shaped.selected.isEmpty)
        #expect(shaped.unselected.map(\.entry) == Array(all.prefix(3)))
        #expect(shaped.hiddenCount == 7)
        #expect(!shaped.isSearching)
        #expect(!shaped.isEmpty)
    }

    @Test func browsingUnderTheCapShowsEverythingWithNoHiddenCount() {
        let all = entries(3)
        let shaped = shape(all, browseLimit: 3)

        #expect(shaped.unselected.map(\.entry) == all)
        #expect(shaped.hiddenCount == 0)
    }

    @Test func selectedEntriesArePinnedAndNeverCapped() {
        let all = entries(10)
        // More selections than the browse limit, scattered through the list.
        let selectedIds = Set(["user-id-1", "user-id-4", "user-id-7", "user-id-9"])
        let shaped = shape(all, selected: selectedIds, browseLimit: 3)

        #expect(shaped.selected.map(\.id) == ["user-id-1", "user-id-4", "user-id-7", "user-id-9"])
        // The cap applies only to the unselected tail.
        #expect(shaped.unselected.count == 3)
        #expect(shaped.unselected.allSatisfy { !selectedIds.contains($0.id) })
        #expect(shaped.hiddenCount == 3)
    }

    /// The selection state is baked into each row item so a toggle produces
    /// unequal ForEach data — that difference is what forces lazy list cells
    /// to re-render instead of showing stale checkmarks.
    @Test func itemsCarrySelectionStateAndDifferAfterAToggle() {
        let all = entries(2)

        let before = shape(all, browseLimit: 10)
        let after = shape(all, selected: ["user-id-0"], browseLimit: 10)

        #expect(before.unselected.map(\.state) == [false, false])
        #expect(after.selected.map(\.state) == [true])
        #expect(after.selected.first?.entry == all.first)
        #expect(after.selected.first != before.unselected.first)
    }

    // MARK: - Searching

    @Test func queryMatchesAnyFieldCaseInsensitively() {
        let all = [
            Entry(id: "327141414565", name: "amul74"),
            Entry(id: "132821713671", name: "Andrewzhang_D"),
            Entry(id: "151111719190", name: "andypaddy"),
        ]

        let byName = shape(all, query: "ANDREW")
        #expect(byName.unselected.map(\.entry.name) == ["Andrewzhang_D"])

        let byId = shape(all, query: "327141")
        #expect(byId.unselected.map(\.entry.name) == ["amul74"])
    }

    /// The cap applies to search matches too — rows render in a non-lazy
    /// stack, so the visible set must stay bounded even for broad queries.
    @Test func searchingCapsMatchesAndFlagsSearchingForTheNotice() {
        let all = entries(10)
        let shaped = shape(all, query: "user", browseLimit: 3)

        #expect(shaped.unselected.count == 3)
        #expect(shaped.hiddenCount == 7)
        #expect(shaped.isSearching)
    }

    @Test func searchKeepsSelectedMatchesPinnedFirst() {
        let all = entries(10)
        let shaped = shape(all, query: "user", selected: ["user-id-5"], browseLimit: 3)

        #expect(shaped.selected.map(\.id) == ["user-id-5"])
        #expect(shaped.unselected.count == 3)
        #expect(shaped.unselected.allSatisfy { !$0.state })
        #expect(shaped.hiddenCount == 6)
    }

    @Test func whitespaceOnlyQueryBehavesLikeBrowsing() {
        let all = entries(10)
        let shaped = shape(all, query: "  \n", browseLimit: 3)

        #expect(shaped.unselected.count == 3)
        #expect(shaped.hiddenCount == 7)
    }

    @Test func noMatchesIsEmpty() {
        let shaped = shape(entries(5), query: "zzz-no-such-person")

        #expect(shaped.isEmpty)
        #expect(shaped.hiddenCount == 0)
    }
}
