//
//  WorkspacePoolActivityView.swift
//  osaurus
//
//  The workspace's activity: who spent what, when, and on which model —
//  including who *asked* (caller attribution) when a teammate drove a
//  shared agent. Rows reuse the credits activity projector so a workspace row
//  reads exactly like a personal row, with the actor/caller line added. Every
//  workspace has a pool, so this is the pool's ledger: balance headline,
//  usage, and the grant/expiry/usage transaction entries.
//

import SwiftUI

struct WorkspacePoolActivityView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: any ThemeProtocol { themeManager.currentTheme }

    let workspace: OsaurusRouterWorkspaceSummary
    #if OSAURUS_DESIGN_INSPECTOR
    @Environment(\.inspectorWorkspaceDisplayOnly) private var inspectionDisplayOnly
    #endif

    @State private var balance: OsaurusRouterWorkspacePoolBalance?
    @State private var usageItems: [OsaurusRouterUsageItem] = []
    @State private var usageCursor: String?
    @State private var transactions: [OsaurusRouterTransactionItem] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    /// Server rows through the shared projector (no local ledger matching:
    /// most workspace rows were billed by other members' instances, so local
    /// records don't exist by design).
    private var activityRows: [CreditsActivityRow] {
        CreditsActivityProjector().rows(usageItems: usageItems, ledgerEntries: [])
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            SettingsSheetHeader(
                icon: "creditcard.fill",
                title: "Credit Activity",
                subtitleText: workspace.name,
                onClose: { dismiss() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s16) {
                    if let errorMessage {
                        InlineBanner(
                            kind: .error,
                            title: errorMessage,
                            action: .init(title: L("Retry"), icon: "arrow.clockwise") {
                                Task { await load() }
                            },
                            onDismiss: { self.errorMessage = nil }
                        )
                    }

                    balanceRow
                    usageSection
                    transactionsSection
                }
                .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            SettingsSheetFooter(
                primary: .init(label: "Done", handler: { dismiss() }),
                secondary: nil,
                hint: nil
            )
        }
        .fittedSheetFrame(width: 560, height: 620)
        .settingsSheetSurface()
        .task { await load() }
    }

    // MARK: - Balance

    @ViewBuilder
    private var balanceRow: some View {
        HStack(spacing: theme.space.s12) {
            WorkspaceAvatar(name: workspace.name, size: 32)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(workspace.name)
                    .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                Text("Workspace credits", bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
            Spacer()
            if let balance {
                VStack(alignment: .trailing, spacing: theme.space.s2) {
                    Text(verbatim: OsaurusRouter.formatMicroAsCreditsValue(balance.balanceMicro))
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.mono)
                        .foregroundColor(theme.text.primary)
                    Text(breakdownCaption(balance))
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                }
            }
            Button {
                Task { await load() }
            } label: {
                HStack(spacing: theme.space.s6) {
                    Image(systemName: "arrow.clockwise")
                        .glyphSize(.footnote, weight: .semibold)
                    Text("Refresh", bundle: .module)
                }
            }
            .assignedSettingsButtonStyle(.secondary, isLoading: isLoading, size: .compact)
            .disabled(isLoading)
        }
    }

    /// "credits left" or, when the router splits the pool, how much of it is
    /// this cycle's grant versus purchased credit that never expires.
    private func breakdownCaption(_ balance: OsaurusRouterWorkspacePoolBalance) -> String {
        guard balance.hasBreakdown, balance.purchasedIsPositive,
            let expiring = balance.expiringMicro, let purchased = balance.purchasedMicro
        else { return L("credits left") }
        return String(
            format: L("%@ grant · %@ purchased"),
            OsaurusRouter.formatMicroAsCreditsValue(expiring),
            OsaurusRouter.formatMicroAsCreditsValue(purchased)
        )
    }

    // MARK: - Usage

    private var usageSection: some View {
        SettingsSection(title: "Usage") {
            if activityRows.isEmpty {
                if isLoading {
                    SettingsEmptyState(loading: "Loading usage…")
                } else {
                    SettingsEmptyState(
                        inline: "clock.arrow.circlepath",
                        title: "No spending yet",
                        hint: "Workspace-billed requests appear here."
                    )
                }
            } else {
                VStack(spacing: theme.space.s0) {
                    ForEach(activityRows) { row in
                        usageRow(row)
                        if row.id != activityRows.last?.id {
                            ThemeHairlineDivider()
                        }
                    }
                }

                if usageCursor != nil {
                    Button {
                        Task { await loadMoreUsage() }
                    } label: {
                        Text("Load more", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary, isLoading: isLoadingMore, size: .compact)
                    .disabled(isLoadingMore)
                }
            }
        }
    }

    private func usageRow(_ row: CreditsActivityRow) -> some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            Circle()
                .fill(stateColor(row.stateKind))
                .frame(width: 8, height: 8)
                .padding(.top, theme.space.s6)

            VStack(alignment: .leading, spacing: theme.space.s4) {
                HStack(spacing: theme.space.s8) {
                    Text(verbatim: row.modelDisplay ?? L("Unknown model"))
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    StatusChip(LCached(row.stateLabel), tint: stateColor(row.stateKind))
                }

                Text(verbatim: row.metadataLine)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(1)

                if let attribution = attributionLine(for: row) {
                    // actor = whose instance billed · caller = who asked.
                    Text(verbatim: attribution)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                }

                Text(verbatim: row.tokensLine)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
            }

            Spacer(minLength: 12)

            Text(verbatim: OsaurusRouter.formatMicroAsCredits(row.costMicro))
                .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                .foregroundColor(theme.text.primary)
                .monospacedDigit()
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
    }

    /// "billed by dino-a · asked by dino-b" — omitted entirely when the row
    /// carries no attribution (personal-shaped rows).
    private func attributionLine(for row: CreditsActivityRow) -> String? {
        guard let item = usageItems.first(where: { "usage-\($0.id)" == row.id }) else {
            return nil
        }
        var parts: [String] = []
        if let actor = item.actor, let name = actorName(actor) {
            parts.append(String(format: L("billed by %@"), name))
        }
        if let caller = item.caller, let name = actorName(caller) {
            parts.append(String(format: L("asked by %@"), name))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Display name → short wallet; `nil` when the router sent nothing to
    /// name the person by (rows then read like personal usage).
    private func actorName(_ actor: OsaurusRouterUsageItem.Actor) -> String? {
        if WorkspacesService.shared.isSelf(actor) { return L("you") }
        let hasName = (actor.displayName?.isEmpty == false)
            || (actor.walletAddress?.isEmpty == false)
            || (actor.accountId?.isEmpty == false)
        return hasName ? actor.friendlyName : nil
    }

    // MARK: - Transactions

    private var transactionsSection: some View {
        SettingsSection(title: "Ledger") {
            if transactions.isEmpty {
                if isLoading {
                    SettingsEmptyState(loading: "Loading ledger…")
                } else {
                    SettingsEmptyState(
                        inline: "list.bullet.rectangle",
                        title: "No ledger entries yet",
                        hint: "Monthly grants, expirations, and top-ups appear here."
                    )
                }
            } else {
                VStack(spacing: theme.space.s0) {
                    ForEach(transactions) { item in
                        transactionRow(item)
                        if item.id != transactions.last?.id {
                            ThemeHairlineDivider()
                        }
                    }
                }
            }
        }
    }

    private func transactionRow(_ item: OsaurusRouterTransactionItem) -> some View {
        let isCredit = !item.amountMicro.hasPrefix("-")
        return HStack(spacing: theme.space.s12) {
            Image(systemName: entryTypeIcon(item.entryType))
                .glyphSize(.caption, weight: .medium)
                .foregroundColor(isCredit ? theme.status.success.foreground : theme.text.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: entryTypeLabel(item.entryType))
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                if let date = WorkspacesFormatting.date(item.createdAt) {
                    Text(verbatim: date)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                        .foregroundColor(theme.text.tertiary)
                }
            }

            Spacer(minLength: 12)

            Text(verbatim: OsaurusRouter.formatMicroAsCredits(item.amountMicro))
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                .foregroundColor(isCredit ? theme.status.success.foreground : theme.text.primary)
                .monospacedDigit()
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
    }

    private func entryTypeLabel(_ entryType: String) -> String {
        switch entryType {
        case "subscription_grant": return L("Monthly credit grant")
        case "grant_expiry": return L("Unused credits expired")
        case "usage": return L("Usage")
        case "refund": return L("Refund")
        case "topup", "top_up": return L("Top-up")
        case "workspace_topup": return L("Top-up")
        default:
            return entryType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func entryTypeIcon(_ entryType: String) -> String {
        switch entryType {
        case "subscription_grant": return "sparkles"
        case "grant_expiry": return "hourglass.bottomhalf.filled"
        case "usage": return "arrow.left.arrow.right"
        case "refund": return "arrow.uturn.backward.circle"
        case "workspace_topup", "topup", "top_up": return "plus.circle.fill"
        default: return "circle.grid.cross"
        }
    }

    // MARK: - Loading

    private func load() async {
        #if OSAURUS_DESIGN_INSPECTOR
        if inspectionDisplayOnly { return }
        #endif
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        async let balanceTask = try? WorkspacesService.shared.fetchWorkspaceBalance(workspaceId: workspace.id)
        async let usageTask = try? WorkspacesService.shared.fetchWorkspaceUsage(workspaceId: workspace.id)
        async let transactionsTask = try? WorkspacesService.shared.fetchWorkspaceTransactions(
            workspaceId: workspace.id)

        let (balance, usage, txns) = await (balanceTask, usageTask, transactionsTask)
        self.balance = balance ?? self.balance
        if let usage {
            usageItems = usage.data
            usageCursor = usage.nextCursor
        }
        if let txns {
            transactions = txns.data
        }
        if balance == nil, usage == nil, txns == nil {
            errorMessage = L(
                "Couldn't load the workspace's activity. Check your connection and try again.")
        }
    }

    private func loadMoreUsage() async {
        #if OSAURUS_DESIGN_INSPECTOR
        if inspectionDisplayOnly { return }
        #endif
        guard let cursor = usageCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard
            let page = try? await WorkspacesService.shared.fetchWorkspaceUsage(
                workspaceId: workspace.id, cursor: cursor)
        else { return }
        let known = Set(usageItems.map(\.id))
        usageItems.append(contentsOf: page.data.filter { !known.contains($0.id) })
        usageCursor = page.nextCursor
    }

    private func stateColor(_ kind: CreditsActivityStateKind) -> Color {
        switch kind {
        case .success: return theme.status.success.foreground
        case .warning: return theme.status.warning.foreground
        case .error: return theme.status.error.foreground
        case .secondary: return theme.text.secondary
        }
    }
}

extension WorkspacePoolActivityView {
    static func inspectionSample() -> Self {
        var view = Self(workspace: .init(id: "local-display", name: "Local workspace", role: "owner"))
        view._balance = State(initialValue: .init(balanceMicro: "750000", expiringMicro: "250000", purchasedMicro: "500000"))
        view._usageItems = State(initialValue: [.init(id: "local-pool-usage", requestId: nil, model: "Local display model", provider: "Local sample", inputTokens: 1234, outputTokens: 56, costMicro: "1234", status: "completed", tokenSource: "provider", createdAt: "2026-10-22T12:00:00Z")])
        let data = Data(#"{"id":"local-grant","amount_micro":"250000","entry_type":"workspace_grant","created_at":"2026-10-22T12:00:00Z"}"#.utf8)
        if let value = try? JSONDecoder().decode(OsaurusRouterTransactionItem.self, from: data) { view._transactions = State(initialValue: [value]) }
        return view
    }
}
