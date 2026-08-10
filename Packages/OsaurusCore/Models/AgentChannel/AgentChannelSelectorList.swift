//
//  AgentChannelSelectorList.swift
//  osaurus
//
//  Pure shaping for the discovery selector lists in channel setup (channels
//  and people). Servers can return thousands of entries; the lists stay
//  usable by matching a search query, pinning already-selected entries to
//  the top, and capping the unselected browse tail until the user searches.
//

import Foundation

enum AgentChannelSelectorList {
    /// Maximum unselected entries shown while browsing (no search query).
    /// Selected entries are always shown in full so the current allowlist is
    /// never hidden; typing a query lifts the cap for matches.
    static let browseLimit = 50

    /// One display row: the discovered entry plus its current selection
    /// state. The state is part of the row value (not recomputed inside the
    /// row view) so lazy list cells are re-rendered when a toggle changes
    /// only the selection — cell identity and entry data alone would look
    /// unchanged and leave stale checkmarks on screen.
    struct Item<Entry: Identifiable & Equatable, State: Equatable>: Identifiable, Equatable {
        let entry: Entry
        let state: State
        var id: Entry.ID { entry.id }
    }

    struct Shaped<Entry: Identifiable & Equatable, State: Equatable> {
        /// Query matches that are already selected, pinned above the rest.
        let selected: [Item<Entry, State>]
        /// Query matches that are not selected, capped at the browse limit.
        let unselected: [Item<Entry, State>]
        /// Unselected matches hidden by the cap.
        let hiddenCount: Int
        /// Whether a search query was active, so the truncation copy can say
        /// "narrow the search" instead of "search".
        let isSearching: Bool

        var isEmpty: Bool { selected.isEmpty && unselected.isEmpty }
    }

    /// Shape `entries` for display: filter by `query` against the strings
    /// `fields` yields (case-insensitive substring), attach each entry's
    /// selection `state`, split matches into selected-first groups per
    /// `isSelected`, and cap the unselected group at `browseLimit`. The cap
    /// applies while searching too — the rows render in a non-lazy stack (see
    /// `AgentChannelSelectorListCard`), so the visible set must stay bounded;
    /// selected entries are never capped.
    static func shape<Entry, State>(
        _ entries: [Entry],
        query: String,
        fields: (Entry) -> [String],
        state: (Entry) -> State,
        isSelected: (State) -> Bool,
        browseLimit: Int = Self.browseLimit
    ) -> Shaped<Entry, State> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = needle.isEmpty
            ? entries
            : entries.filter { entry in
                fields(entry).contains { $0.lowercased().contains(needle) }
            }
        let items = matches.map { Item(entry: $0, state: state($0)) }
        let selected = items.filter { isSelected($0.state) }
        let unselected = items.filter { !isSelected($0.state) }
        return Shaped(
            selected: selected,
            unselected: Array(unselected.prefix(browseLimit)),
            hiddenCount: max(0, unselected.count - browseLimit),
            isSearching: !needle.isEmpty
        )
    }
}

/// Read/write selection flags for a channel row, shared by the Discord and
/// Slack channel selectors.
struct AgentChannelReadWriteSelection: Equatable {
    let read: Bool
    let write: Bool

    var isSelected: Bool { read || write }
}
