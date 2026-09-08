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
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let workspace: OsaurusRouterWorkspaceSummary

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
        VStack(spacing: 0) {
            AgentSheetHeader(
                icon: "creditcard.fill",
                title: "Pool activity",
                subtitleText: workspace.name,
                onClose: { dismiss() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            AgentSheetFooter(
                primary: .init(label: "Done", handler: { dismiss() }),
                secondary: nil,
                hint: nil
            )
        }
        .fittedSheetFrame(width: 560, height: 620)
        .background(theme.primaryBackground)
        .task { await load() }
    }

    // MARK: - Balance

    @ViewBuilder
    private var balanceRow: some View {
        HStack(spacing: 12) {
            WorkspaceAvatar(name: workspace.name, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text("Shared credit pool", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer()
            if let balance {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: OsaurusRouter.formatMicroAsCreditsValue(balance.balanceMicro))
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                    Text(breakdownCaption(balance))
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            Button {
                Task { await load() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("Refresh", bundle: .module)
                }
            }
            .buttonStyle(SecondaryButtonStyle(isLoading: isLoading, size: .compact))
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
        AgentDetailSection(title: L("Usage"), icon: "clock.arrow.circlepath") {
            if activityRows.isEmpty {
                if isLoading {
                    AgentSectionEmptyState(loading: "Loading usage…")
                } else {
                    AgentSectionEmptyState(
                        icon: "clock.arrow.circlepath",
                        title: "No pool spending yet",
                        hint: "Workspace-billed requests appear here."
                    )
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(activityRows) { row in
                        usageRow(row)
                        if row.id != activityRows.last?.id {
                            Divider().opacity(0.5)
                        }
                    }
                }

                if usageCursor != nil {
                    Button {
                        Task { await loadMoreUsage() }
                    } label: {
                        Text("Load more", bundle: .module)
                    }
                    .buttonStyle(SecondaryButtonStyle(isLoading: isLoadingMore, size: .compact))
                    .disabled(isLoadingMore)
                }
            }
        }
    }

    private func usageRow(_ row: CreditsActivityRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(stateColor(row.stateKind))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: row.modelDisplay ?? L("Unknown model"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(LocalizedStringKey(row.stateLabel), bundle: .module)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(stateColor(row.stateKind))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(stateColor(row.stateKind).opacity(0.12)))
                }

                Text(verbatim: row.metadataLine)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)

                if let attribution = attributionLine(for: row) {
                    // actor = whose instance billed · caller = who asked.
                    Text(verbatim: attribution)
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }

                Text(verbatim: row.tokensLine)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer(minLength: 12)

            Text(verbatim: OsaurusRouter.formatMicroAsCredits(row.costMicro))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(theme.primaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        AgentDetailSection(title: L("Ledger"), icon: "list.bullet.rectangle") {
            if transactions.isEmpty {
                if isLoading {
                    AgentSectionEmptyState(loading: "Loading ledger…")
                } else {
                    AgentSectionEmptyState(
                        icon: "list.bullet.rectangle",
                        title: "No ledger entries yet",
                        hint: "Monthly grants, expirations, and top-ups appear here."
                    )
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(transactions) { item in
                        transactionRow(item)
                        if item.id != transactions.last?.id {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    private func transactionRow(_ item: OsaurusRouterTransactionItem) -> some View {
        let isCredit = !item.amountMicro.hasPrefix("-")
        return HStack(spacing: 12) {
            Image(systemName: entryTypeIcon(item.entryType))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isCredit ? theme.successColor : theme.secondaryText)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entryTypeLabel(item.entryType))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                if let date = WorkspacesFormatting.date(item.createdAt) {
                    Text(verbatim: date)
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            Spacer(minLength: 12)

            Text(verbatim: OsaurusRouter.formatMicroAsCredits(item.amountMicro))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundColor(isCredit ? theme.successColor : theme.primaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func entryTypeLabel(_ entryType: String) -> String {
        switch entryType {
        case "subscription_grant": return L("Monthly credit grant")
        case "grant_expiry": return L("Unused credits expired")
        case "usage": return L("Usage")
        case "refund": return L("Refund")
        case "topup", "top_up": return L("Top-up")
        case "workspace_topup": return L("Pool top-up")
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
        case .success: return theme.successColor
        case .warning: return theme.warningColor
        case .error: return theme.errorColor
        case .secondary: return theme.secondaryText
        }
    }
}
