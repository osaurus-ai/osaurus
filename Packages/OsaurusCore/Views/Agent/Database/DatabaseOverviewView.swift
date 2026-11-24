//
//  DatabaseOverviewView.swift
//  osaurus
//
//  The Database workspace's landing section: a plain-language summary
//  of what the agent has stored, the pinned saved-view dashboard cards
//  (formerly the Home tab), and the database-wide management actions
//  (bundle export/import, delete data) that used to hide inside the
//  Configure tab's feature row.
//

import SwiftUI

struct DatabaseOverviewView: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let agentId: UUID
    /// Jump to another workspace section (e.g. "Browse tables").
    let onOpenSection: (AgentDatabaseSection) -> Void
    let onExportBundle: () -> Void
    let onImportBundle: () -> Void
    let onDeleteData: () -> Void
    let isBundleBusy: Bool

    @State private var tables: [AgentTableSchema] = []
    @State private var pinned: [OverviewViewCard] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil

    @ObservedObject private var mutationActivity = AgentMutationActivity.shared

    var body: some View {
        ScrollView {
            SettingsPageContent {
                storedDataSection
                if !isLoading, loadError == nil, !(userTables.isEmpty && pinned.isEmpty) {
                    dashboardSection
                }
                backupSection
                SettingsDestructiveZone {
                    SettingsDestructiveRow(
                        title: "Delete All Data",
                        description: "Permanently delete every table and row this agent has stored. The agent itself is kept.",
                        actionTitle: "Delete All Data…"
                    ) {
                        onDeleteData()
                    }
                }
            }
        }
        .background(theme.surface.canvas)
        .task { await reload() }
        .onChange(of: agentId) { _, _ in Task { await reload() } }
        .onChange(of: mutationActivity[agentId]) { oldValue, newValue in
            guard oldValue > 0, newValue == 0 else { return }
            Task { await reload() }
        }
    }

    // MARK: - Stored data

    private static let tablePreviewLimit = 8

    private var userTables: [AgentTableSchema] {
        tables.filter { !$0.name.hasPrefix("_") }
    }

    private var totalRows: Int {
        userTables.reduce(0) { $0 + $1.rowCount }
    }

    private var storedDataCaption: String? {
        guard !isLoading, loadError == nil, !userTables.isEmpty else { return nil }
        let tableLabel = userTables.count == 1 ? L("1 table") : L("\(userTables.count) tables")
        let rowLabel = totalRows == 1 ? L("1 row") : L("\(totalRows.formatted()) rows")
        return "\(tableLabel) · \(rowLabel)"
    }

    private var storedDataFooter: String? {
        let hidden = userTables.count - Self.tablePreviewLimit
        guard hidden > 0 else { return nil }
        return L("\(hidden) more in Tables.")
    }

    private var storedDataSection: some View {
        SettingsSection(
            title: "Stored Data",
            caption: storedDataCaption,
            subtitle: "Tables the agent created to keep notes, lists, and records.",
            footer: storedDataFooter
        ) {
            if !userTables.isEmpty {
                SettingsButton(.secondary, "Browse Tables", icon: "tablecells", size: .compact) {
                    onOpenSection(.tables)
                }
            }
        } content: {
            if isLoading {
                SettingsEmptyState(loading: "Loading…")
            } else if let error = loadError {
                SettingsRow(
                    title: "Couldn't read the database",
                    description: error,
                    verbatimDescription: true,
                    leading: { SettingsIconTile(icon: "exclamationmark.triangle", tint: theme.status.error.foreground) }
                ) {
                    SettingsButton(.tertiary, "Retry", size: .compact) { Task { await reload() } }
                }
            } else if userTables.isEmpty {
                SettingsEmptyState(
                    inline: "cylinder.split.1x2",
                    title: "Nothing stored yet",
                    hint: "Ask the agent in chat to remember or track something — it sets up its own tables, and they show up here."
                )
            } else {
                ForEach(userTables.prefix(Self.tablePreviewLimit), id: \.name) { table in
                    LibraryRow(
                        title: table.name,
                        subtitle: table.rowCount == 1 ? L("1 row") : L("\(table.rowCount.formatted()) rows"),
                        showsChevron: true,
                        action: { onOpenSection(.tables) }
                    ) {
                        SettingsIconTile(icon: "tablecells")
                    }
                }
            }
        }
    }

    // MARK: - Dashboard

    @ViewBuilder
    private var dashboardSection: some View {
        if pinned.isEmpty {
            SettingsSection(title: "Dashboard") {
                SettingsRow(
                    title: "No pinned views yet",
                    description: "Pin a saved view to see its latest results here at a glance."
                ) {
                    SettingsButton(.secondary, "Open Saved Views", icon: "eye", size: .compact) {
                        onOpenSection(.savedViews)
                    }
                }
            }
        } else {
            SettingsSection(
                title: "Dashboard",
                caption: "\(pinned.count)",
                subtitle: "Saved views you pinned, with their latest results.",
                layout: .plain
            ) {
                SettingsButton(.tertiary, "Saved Views", icon: "eye", size: .compact) {
                    onOpenSection(.savedViews)
                }
            } content: {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280, maximum: 600), spacing: theme.space.s16)],
                    spacing: theme.space.s16
                ) {
                    ForEach(pinned) { card in
                        cardView(card)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cardView(_ card: OverviewViewCard) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack {
                Text(card.view.name)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                Spacer()
                Text(card.view.renderHint)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
            if let desc = card.view.description, !desc.isEmpty {
                Text(desc).catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
            }
            cardBody(card)
        }
        .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s12)
        .settingsChrome(.surface)
    }

    @ViewBuilder
    private func cardBody(_ card: OverviewViewCard) -> some View {
        if let error = card.error {
            Text(error).catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall).foregroundColor(theme.status.error.foreground)
        } else if let result = card.result {
            switch card.view.renderHint.lowercased() {
            case "number":
                kpiBody(result)
            case "bar", "line", "column", "spline", "pie":
                miniChartBody(result, hint: card.view.renderHint)
            default:
                miniTableBody(result)
            }
        }
    }

    @ViewBuilder
    private func kpiBody(_ result: AgentQueryResult) -> some View {
        if let first = result.rows.first, let value = first.first {
            Text(agentSQLDisplayString(value))
                .catalogTypography(.heading, theme: theme, fallback: SettingsFont.pageTitle)
                .foregroundColor(theme.text.primary)
        } else {
            Text("—").catalogTypography(.heading, theme: theme, fallback: SettingsFont.pageTitle).foregroundColor(theme.text.tertiary)
        }
    }

    @ViewBuilder
    private func miniTableBody(_ result: AgentQueryResult) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            HStack(spacing: theme.space.s0) {
                ForEach(result.columns, id: \.self) { col in
                    Text(col)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, theme.space.s2)
            ForEach(Array(result.rows.prefix(8).enumerated()), id: \.offset) { (_, row) in
                HStack(spacing: theme.space.s0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { (_, value) in
                        Text(agentSQLDisplayString(value))
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                            .foregroundColor(theme.text.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            if result.rows.count > 8 {
                Text("+ \(result.rows.count - 8) more").catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
        }
    }

    @ViewBuilder
    private func miniChartBody(_ result: AgentQueryResult, hint: String) -> some View {
        // Phase 2 fallback: until the AAChartKit binding lands we surface
        // a hint that the chart shape is recognised and show the rows as
        // a table. The AAChartKit reuse is wired in via `NativeChartView`
        // in the chat surface; reusing it here is a follow-up.
        VStack(alignment: .leading, spacing: theme.space.s4) {
            Label(
                "Chart preview not yet rendered — showing rows instead.",
                systemImage: "chart.bar"
            )
            .componentInspectionText(53, role: .caption, fallback: .micro, theme: theme)
            .foregroundColor(theme.text.tertiary)
            miniTableBody(result)
        }
    }

    // MARK: - Backup

    private var backupSection: some View {
        SettingsSection(
            title: "Backup & Transfer",
            footer: L("Bundles include the agent's configuration and its encrypted database, protected by a passphrase you choose.")
        ) {
            if isBundleBusy {
                SettingsSpinner()
            }
        } content: {
            SettingsRow(
                title: "Export Bundle",
                description: "Save this agent and its database as an encrypted .osaurus-agent bundle you can back up or move to another Mac."
            ) {
                SettingsButton(.secondary, "Export…", icon: "shippingbox", size: .compact, action: onExportBundle)
                    .disabled(isBundleBusy)
            }
            SettingsRow(
                title: "Import Bundle",
                description: "Restore an agent bundle exported from this or another Mac."
            ) {
                SettingsButton(.secondary, "Import…", icon: "square.and.arrow.down.on.square", size: .compact, action: onImportBundle)
                    .disabled(isBundleBusy)
            }
        }
    }

    // MARK: - Loading

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let schema = try LocalAgentBridge.shared.schema(agentId: agentId)
            tables = schema.tables
            let views = try LocalAgentBridge.shared.listViews(agentId: agentId)
                .filter { $0.pinned }
            var cards: [OverviewViewCard] = []
            cards.reserveCapacity(views.count)
            for view in views {
                do {
                    let res = try LocalAgentBridge.shared.runView(
                        agentId: agentId,
                        name: view.name
                    )
                    cards.append(OverviewViewCard(view: view, result: res, error: nil))
                } catch {
                    cards.append(
                        OverviewViewCard(view: view, result: nil, error: error.localizedDescription)
                    )
                }
            }
            pinned = cards
            loadError = nil
        } catch {
            tables = []
            pinned = []
            loadError = error.localizedDescription
        }
    }
}

private struct OverviewViewCard: Identifiable {
    var id: String { view.name }
    let view: AgentSavedView
    let result: AgentQueryResult?
    let error: String?
}
