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
//  The workspace is reachable even when the database feature is off —
//  it renders an explanatory empty state with an Enable action instead
//  of vanishing from navigation, so users can discover the feature.
//
//  Deep links: the workspace listens to `.agentDetailDeeplink` directly
//  (filtered by agent id) so legacy `tab: "schema" / "data" / "views" /
//  "activity" / "home"` payloads and `tableRef` / `viewRef` focus hints
//  keep working while the view is already mounted.
//

import SwiftUI

struct DatabaseWorkspaceView: View {
    @Environment(\.theme) private var theme

    let agentId: UUID
    let isEnabled: Bool
    let isRemoteProvider: Bool
    let onEnable: () -> Void
    let onExportBundle: () -> Void
    let onImportBundle: () -> Void
    let onDeleteData: () -> Void
    let isBundleBusy: Bool

    @State private var section: AgentDatabaseSection
    @State private var focusedTableName: String?
    @State private var focusedViewName: String?

    init(
        agentId: UUID,
        isEnabled: Bool,
        isRemoteProvider: Bool,
        initialSection: AgentDatabaseSection? = nil,
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
        _section = State(initialValue: initialSection ?? .overview)
        _focusedTableName = State(initialValue: initialTableName)
        _focusedViewName = State(initialValue: initialViewName)
    }

    var body: some View {
        Group {
            if isEnabled {
                VStack(spacing: 0) {
                    sectionBar
                    Divider().foregroundColor(theme.primaryBorder)
                    sectionContent
                }
            } else {
                disabledState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
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

    // MARK: - Section bar

    private struct SectionDescriptor {
        let section: AgentDatabaseSection
        let label: String
        let icon: String
        let help: String
    }

    private var sectionDescriptors: [SectionDescriptor] {
        [
            .init(
                section: .overview,
                label: L("Overview"),
                icon: "square.grid.2x2",
                help: L("What the agent has stored, at a glance.")
            ),
            .init(
                section: .tables,
                label: L("Tables"),
                icon: "tablecells",
                help: L("Browse and edit the rows in each table.")
            ),
            .init(
                section: .savedViews,
                label: L("Saved Views"),
                icon: "eye",
                help: L("Reusable queries the agent has saved.")
            ),
            .init(
                section: .history,
                label: L("History"),
                icon: "clock.arrow.circlepath",
                help: L("Every run and every change, with a full audit trail.")
            ),
        ]
    }

    @ViewBuilder
    private var sectionBar: some View {
        HStack(spacing: 4) {
            ForEach(sectionDescriptors, id: \.section) { descriptor in
                sectionButton(descriptor)
            }
            Spacer(minLength: 8)
            // Workspace-wide status lives on the bar (not per-section
            // headers) so it's visible from every section and the
            // section headers stay slim.
            StorageQuotaBadge(agentId: agentId, theme: theme)
            MutationsInFlightIndicator(agentId: agentId, theme: theme)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(theme.secondaryBackground.opacity(0.4))
    }

    @ViewBuilder
    private func sectionButton(_ descriptor: SectionDescriptor) -> some View {
        let isSelected = section == descriptor.section
        Button {
            section = descriptor.section
        } label: {
            HStack(spacing: 5) {
                Image(systemName: descriptor.icon)
                    .font(.system(size: 10, weight: .medium))
                // Constant weight so pills don't change width (and shift
                // their neighbors) when the selection moves.
                Text(verbatim: descriptor.label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? theme.accentColor.opacity(0.14) : Color.clear)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accentColor.opacity(0.25) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(descriptor.help)
        .accessibilityLabel(descriptor.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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

    @ViewBuilder
    private var disabledState: some View {
        VStack(spacing: 0) {
            DatabaseEmptyState(
                systemImage: "cylinder.split.1x2",
                title: "Give this agent its own database",
                subtitle:
                    "With a database, the agent can keep notes, lists, and records between conversations — stored encrypted on this Mac. You can browse and edit everything it saves right here.",
                actionTitle: "Enable Database",
                actionSystemImage: "power",
                action: onEnable,
                theme: theme
            )
            if isRemoteProvider {
                // Same schema-leak disclaimer the Configure toggle shows
                // (spec §5.5.5): with a remote model, table/column names
                // cross the wire on every request — row data does not.
                Text(
                    "Note: this agent uses a remote model, so its schema (table names and column types) is sent with each request. Row data is not.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
            }
        }
    }
}
