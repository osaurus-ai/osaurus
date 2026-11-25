//
//  DatabaseWorkspaceView.swift
//  osaurus
//
//  One approachable home for everything the agent stores: Overview
//  (summary + pinned dashboard), Tables (merged Schema + Data), Saved
//  Views, and History (runs + changelog audit). Replaces the five
//  separate technical tabs (Home / Schema / Data / Views / Activity)
//  that used to crowd the agent detail strip.
//
//  The section switcher lives in the agent page header (like the
//  Abilities sub-tabs); this view renders the selected section.
//
//  The workspace is reachable even when the database feature is off —
//  it renders an explanatory row with an Enable action instead of
//  vanishing from navigation, so users can discover the feature.
//
//  Deep links: the workspace listens to `.agentDetailDeeplink` directly
//  (filtered by agent id) so legacy `tab: "schema" / "data" / "views" /
//  "activity" / "home"` payloads and `tableRef` / `viewRef` focus hints
//  keep working while the view is already mounted.
//

import SwiftUI

struct DatabaseWorkspaceView: View {
    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }

    let agentId: UUID
    let isEnabled: Bool
    let isRemoteProvider: Bool
    let onEnable: () -> Void
    let onExportBundle: () -> Void
    let onImportBundle: () -> Void
    let onDeleteData: () -> Void
    let isBundleBusy: Bool

    @Binding private var section: AgentDatabaseSection
    @State private var focusedTableName: String?
    @State private var focusedViewName: String?

    init(
        agentId: UUID,
        isEnabled: Bool,
        isRemoteProvider: Bool,
        section: Binding<AgentDatabaseSection>,
        initialTableName: String? = nil,
        initialViewName: String? = nil,
        isBundleBusy: Bool = false,
        onEnable: @escaping () -> Void,
        onExportBundle: @escaping () -> Void,
        onImportBundle: @escaping () -> Void,
        onDeleteData: @escaping () -> Void
    ) {
        self.agentId = agentId
        self.isEnabled = isEnabled
        self.isRemoteProvider = isRemoteProvider
        self.isBundleBusy = isBundleBusy
        self.onEnable = onEnable
        self.onExportBundle = onExportBundle
        self.onImportBundle = onImportBundle
        self.onDeleteData = onDeleteData
        _section = section
        _focusedTableName = State(initialValue: initialTableName)
        _focusedViewName = State(initialValue: initialViewName)
    }

    var body: some View {
        Group {
            if isEnabled {
                sectionContent
            } else {
                disabledState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .onReceive(NotificationCenter.default.publisher(for: .agentDetailDeeplink)) { note in
            // Warm-mounted deep-link routing: flip section + focus when a
            // notification targets this agent's database surfaces. Cold
            // opens flow through the initializer instead.
            guard let info = note.userInfo,
                let targetId = info["agentId"] as? UUID,
                targetId == agentId
            else { return }
            guard let tabRaw = info["tab"] as? String,
                let route = AgentDetailTabRoute.resolve(tabRaw),
                route.tabRawValue == "database"
            else { return }
            if let target = route.databaseSection {
                section = target
            }
            if let tableRef = info["tableRef"] as? String, !tableRef.isEmpty {
                focusedTableName = tableRef
                section = .tables
            }
            if let viewRef = info["viewRef"] as? String, !viewRef.isEmpty {
                focusedViewName = viewRef
                section = .savedViews
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .overview:
            DatabaseOverviewView(
                agentId: agentId,
                onOpenSection: { section = $0 },
                onExportBundle: onExportBundle,
                onImportBundle: onImportBundle,
                onDeleteData: onDeleteData,
                isBundleBusy: isBundleBusy
            )
        case .tables:
            DatabaseTablesView(agentId: agentId, focusedTableName: focusedTableName)
        case .savedViews:
            DatabaseSavedViewsView(agentId: agentId, initialFocusedViewName: focusedViewName)
        case .history:
            DatabaseHistoryView(agentId: agentId)
        }
    }

    // MARK: - Disabled state

    private var disabledState: some View {
        ScrollView {
            SettingsPageContent {
                SettingsSection(
                    title: "Database",
                    footer: isRemoteProvider
                        // Same schema-leak disclaimer the Configure toggle shows
                        // (spec §5.5.5): with a remote model, table/column names
                        // cross the wire on every request — row data does not.
                        ? L("This agent uses a remote model, so its schema (table names and column types) is sent with each request. Row data is not.")
                        : nil
                ) {
                    SettingsEmptyState(
                        inline: "cylinder.split.1x2",
                        title: "Give this agent its own database",
                        hint: "With a database, the agent can keep notes, lists, and records between conversations — stored encrypted on this Mac. You can browse and edit everything it saves right here.",
                        action: SettingsEmptyState.Action(title: L("Enable Database"), icon: "power", handler: onEnable)
                    )
                }
            }
        }
    }
}
