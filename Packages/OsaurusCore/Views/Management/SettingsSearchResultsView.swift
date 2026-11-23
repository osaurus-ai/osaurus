//
//  SettingsSearchResultsView.swift
//  osaurus
//
//  Cross-tab results for the settings sidebar search (Phase 1 of global
//  settings search). Replaces the tab content while the search field has a
//  query, listing matching settings from every tab grouped by tab, then the
//  user's own agents, workflows, models, servers, providers and themes whose
//  name matches. Selecting a result navigates to it.
//

import SwiftUI

struct SettingsSearchResultsView: View {
    @Environment(\.theme) private var theme
    let query: String
    let onSelect: (SettingsSearchEntry) -> Void
    let onOpenEntity: (SettingsEntityCandidate) -> Void

    @State private var candidates: [SettingsEntityCandidate] = []
    /// Results for the last settled query. The ranked search includes a
    /// typo pass, so it runs once per query rather than per render.
    @State private var snapshot: Snapshot?

    struct Snapshot {
        let query: String
        let results: [SettingsSearchEntry]
        let entities: [SettingsEntityCandidate]
        /// Results grouped by tab, tabs ordered by their first (best-ranked) hit.
        let grouped: [(tab: ManagementTab, entries: [SettingsSearchEntry])]

        init(query: String, candidates: [SettingsEntityCandidate]) {
            self.query = query
            results = SettingsSearchIndex.search(query)
            entities = SettingsEntitySearch.match(query, in: candidates)
            var order: [ManagementTab] = []
            var byTab: [ManagementTab: [SettingsSearchEntry]] = [:]
            for entry in results {
                if byTab[entry.tab] == nil { order.append(entry.tab) }
                byTab[entry.tab, default: []].append(entry)
            }
            grouped = order.map { ($0, byTab[$0] ?? []) }
        }
    }

    var body: some View {
        let current = snapshot ?? Snapshot(query: query, candidates: candidates)
        let results = current.results
        let entities = current.entities
        VStack(alignment: .leading, spacing: theme.space.s0) {
            SettingsPageHeader(title: "Search Results", subtitle: matchSummary(current))
            if results.isEmpty && entities.isEmpty {
                SettingsEmptyState(
                    inline: "magnifyingglass",
                    title: L("No settings match \"\(current.query)\""),
                    hint: "Try a different term, like \u{201C}hotkey\u{201D} or \u{201C}transcription\u{201D}."
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    SettingsPageContent {
                        ForEach(current.grouped, id: \.tab) { group in
                            SettingsSection(title: group.tab.label) {
                                ForEach(group.entries) { entry in
                                    resultRow(entry)
                                }
                            }
                        }
                        if !entities.isEmpty {
                            SettingsSection(title: "Your Items") {
                                ForEach(entities) { entity in
                                    entityRow(entity)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            candidates = SettingsEntitySearch.liveCandidates()
            snapshot = Snapshot(query: query, candidates: candidates)
        }
        .task(id: query) {
            guard snapshot?.query != query else { return }
            try? await Task.sleep(for: SearchDebounce.interval)
            guard !Task.isCancelled else { return }
            snapshot = Snapshot(query: query, candidates: candidates)
        }
    }

    private func matchSummary(_ current: Snapshot) -> String {
        current.results.count == 1
            ? L("1 setting matches \"\(current.query)\"")
            : L("\(current.results.count) settings match \"\(current.query)\"")
    }

    private func entityRow(_ entity: SettingsEntityCandidate) -> some View {
        Button {
            onOpenEntity(entity)
        } label: {
            SettingsRow(title: entity.name, verbatimTitle: true) {
                SettingsIconTile(icon: entity.kind.icon)
            } description: {
                Text(LocalizedStringKey(entity.kind.label), bundle: .module)
            } trailing: {
                SettingsChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func resultRow(_ entry: SettingsSearchEntry) -> some View {
        Button {
            onSelect(entry)
        } label: {
            SettingsRow(title: entry.title) {
                if !entry.section.isEmpty {
                    Text(LocalizedStringKey(entry.section), bundle: .module)
                }
                if let note = entry.disambiguation {
                    Text(LocalizedStringKey(note), bundle: .module)
                }
            } trailing: {
                SettingsChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
