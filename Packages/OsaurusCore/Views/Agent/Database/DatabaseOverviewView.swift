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
                summaryStrip
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading…", bundle: .module).catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                            .foregroundColor(theme.text.tertiary)
                    }
                } else if let error = loadError {
                    Label {
                        Text(verbatim: error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .componentInspectionText(53, role: .caption, fallback: .footnote, theme: theme)
                    .foregroundColor(theme.status.error.foreground)
                } else {
                    pinnedSection
                }
                manageSection
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

    // MARK: - Summary

    private var userTables: [AgentTableSchema] {
        tables.filter { !$0.name.hasPrefix("_") }
    }

    private var totalRows: Int {
        userTables.reduce(0) { $0 + $1.rowCount }
    }

    @ViewBuilder
    private var summaryStrip: some View {
        HStack(spacing: theme.space.s12) {
            summaryTile(
                icon: "tablecells",
                value: userTables.count.formatted(),
                label: userTables.count == 1 ? L("table") : L("tables")
            )
            summaryTile(
                icon: "list.bullet.rectangle",
                value: totalRows.formatted(),
                label: totalRows == 1 ? L("row") : L("rows")
            )
            Button {
                onOpenSection(.tables)
            } label: {
                Label(localized: "Browse tables", systemImage: "arrow.right")
                    .componentInspectionText(53, role: .caption, fallback: .footnote, weight: 500, theme: theme)
            }
            .assignedSettingsButtonStyle(.secondary, size: .compact)
            .disabled(userTables.isEmpty)
            Spacer()
        }
    }

    @ViewBuilder
    private func summaryTile(icon: String, value: String, label: String) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: icon)
                .glyphSize(13, weight: .medium)
                .foregroundColor(theme.text.link)
                .frame(width: 28, height: 28)
                .background(Circle().fill(theme.status.info.background))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: value)
                    .catalogTypography(.heading, theme: theme, fallback: SettingsFont.detailTitle)
                    .foregroundColor(theme.text.primary)
                Text(verbatim: label)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.surface)
        .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.default, lineWidth: theme.stroke.default))
    }

    // MARK: - Pinned views

    @ViewBuilder
    private var pinnedSection: some View {
        if userTables.isEmpty && pinned.isEmpty {
            SettingsEmptyState(
                inline: "cylinder.split.1x2",
                title: "This agent hasn't stored anything yet.",
                hint: "Ask the agent in chat to remember or track something — it will set up its own tables, and this overview fills in as it works.",
                action: SettingsEmptyState.Action(title: L("Go to Tables"), icon: "tablecells", handler: { onOpenSection(.tables) })
            )
            .frame(maxHeight: .infinity)
            .frame(minHeight: 200)
        } else if pinned.isEmpty {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                sectionLabel("Dashboard")
                Text(
                    "No pinned views yet. Pin a saved view from the Saved Views section to see it here at a glance.",
                    bundle: .module
                )
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                .foregroundColor(theme.text.tertiary)
                Button {
                    onOpenSection(.savedViews)
                } label: {
                    Label(localized: "Open Saved Views", systemImage: "eye")
                        .componentInspectionText(53, role: .caption, fallback: .footnote, weight: 500, theme: theme)
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
            }
        } else {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                sectionLabel("Dashboard")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280, maximum: 600), spacing: theme.space.s16)],
                    spacing: 16
                ) {
                    ForEach(pinned) { card in
                        cardView(card)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text, bundle: .module)
            .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
            .foregroundColor(theme.text.tertiary)
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
        .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.default, lineWidth: theme.stroke.default))
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(result.columns, id: \.self) { col in
                    Text(col)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, theme.space.s2)
            ForEach(Array(result.rows.prefix(8).enumerated()), id: \.offset) { (_, row) in
                HStack(spacing: 0) {
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

    // MARK: - Manage

    @ViewBuilder
    private var manageSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            sectionLabel("Manage")
            VStack(alignment: .leading, spacing: theme.space.s12) {
                HStack(spacing: theme.space.s8) {
                    Button(action: onExportBundle) {
                        Label(localized: "Export Bundle", systemImage: "shippingbox")
                            .componentInspectionText(53, role: .caption, fallback: .footnote, weight: 500, theme: theme)
                    }
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
                    .disabled(isBundleBusy)
                    .localizedHelp(
                        "Save this agent and its database as an encrypted .osaurus-agent bundle you can back up or move to another Mac."
                    )
                    Button(action: onImportBundle) {
                        Label(localized: "Import Bundle", systemImage: "square.and.arrow.down.on.square")
                            .componentInspectionText(53, role: .caption, fallback: .footnote, weight: 500, theme: theme)
                    }
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
                    .disabled(isBundleBusy)
                    .localizedHelp("Restore an agent bundle exported from this or another Mac.")
                    if isBundleBusy {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Button(role: .destructive, action: onDeleteData) {
                        Label(localized: "Delete All Data…", systemImage: "trash")
                            .componentInspectionText(53, role: .caption, fallback: .footnote, weight: 500, theme: theme)
                    }
                    .assignedSettingsButtonStyle(.destructive, size: .compact)
                    .localizedHelp(
                        "Permanently delete every table and row this agent has stored. The agent itself is kept."
                    )
                }
                Text(
                    "Bundles include the agent's configuration and its encrypted database, protected by a passphrase you choose.",
                    bundle: .module
                )
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
            }
            .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(.surface)
            .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.default, lineWidth: theme.stroke.default))
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
