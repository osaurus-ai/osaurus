//
//  SettingsSearchResultsView.swift
//  osaurus
//
//  Cross-tab results for the settings sidebar search (Phase 1 of global
//  settings search). Replaces the tab content while the search field has a
//  query, listing matching settings from every tab grouped by tab. Selecting a
//  result navigates to its tab.
//

import SwiftUI

struct SettingsSearchResultsView: View {
    let query: String
    let onSelect: (SettingsSearchEntry) -> Void

    @Environment(\.theme) private var theme

    private var results: [SettingsSearchEntry] {
        SettingsSearchIndex.search(query)
    }

    /// Results grouped by tab, tabs ordered by their first (best-ranked) hit.
    private var grouped: [(tab: ManagementTab, entries: [SettingsSearchEntry])] {
        var order: [ManagementTab] = []
        var byTab: [ManagementTab: [SettingsSearchEntry]] = [:]
        for entry in results {
            if byTab[entry.tab] == nil { order.append(entry.tab) }
            byTab[entry.tab, default: []].append(entry)
        }
        return order.map { ($0, byTab[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if results.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Search Results", bundle: .module)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(theme.primaryText)
            Text("\(results.count) settings match \"\(query)\"", bundle: .module)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(grouped, id: \.tab) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        groupHeader(group.tab)
                        ForEach(group.entries) { entry in
                            resultRow(entry)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func groupHeader(_ tab: ManagementTab) -> some View {
        HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.accentColor)
            Text(tab.label)
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.secondaryText)
                .tracking(0.5)
        }
        .padding(.bottom, 2)
    }

    private func resultRow(_ entry: SettingsSearchEntry) -> some View {
        Button {
            onSelect(entry)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(entry.title), bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    if !entry.section.isEmpty {
                        Text(LocalizedStringKey(entry.section), bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26))
                .foregroundColor(theme.tertiaryText)
            Text("No settings match \"\(query)\"", bundle: .module)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
            Text("Try a different term, like \u{201C}hotkey\u{201D} or \u{201C}transcription\u{201D}.", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
