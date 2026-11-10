import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RouterAccountUsageCenterView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @StateObject private var model = RouterAccountUsageCenterViewModel()
    @ObservedObject private var accountService = OsaurusRouterAccountService.shared

    private var theme: any ThemeProtocol {
        #if OSAURUS_DESIGN_SYSTEM
        if let inspectionTheme { return inspectionTheme }
        #endif
        return themeManager.currentTheme
    }

#if OSAURUS_DESIGN_SYSTEM
    private var inspectionTheme: (any ThemeProtocol)?
    var inspectionSnapshot: RouterAccountUsageSnapshot?
#endif
    private var displayedSnapshot: RouterAccountUsageSnapshot {
#if OSAURUS_DESIGN_SYSTEM
        if let value = inspectionSnapshot { return value }
#endif
        return model.snapshot
    }

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Router Account",
                subtitle: "Account status, usage activity, signed request diagnostics, and support export.",
                onRefresh: { Task { await model.refresh() } },
                isRefreshing: model.isRefreshing,
                utilities: {
                    SettingsIconButton(
                        "signature",
                        isLoading: model.isSigningDiagnostics,
                        help: "Signed request diagnostics"
                    ) {
                        Task { await model.runSignedRequestDiagnostics() }
                    }
                },
                overflow: {
                    Button(L("Export support")) { chooseSupportExportURL() }
                        .disabled(model.isExportingSupport)
                }
            )
        } content: {
            statusMetrics

            if let message = model.message, !message.isEmpty {
                messageBanner(message)
            }

            accountStatusSection
            creditsActivitySection
            ledgerSection
            signedDiagnosticsSection
            supportExportSection
        }
        .task {
            await model.refresh()
        }
        .onChange(of: accountService.usageRevision) { _, _ in
            Task { await model.refreshUsageAfterBilledTurn() }
        }
    }

    private var statusMetrics: some View {
        ViewThatFits(in: .horizontal) {
            statusMetricsGrid(columns: 4)
                .frame(minWidth: 720 + theme.space.s12 * 3)
            statusMetricsGrid(columns: 2)
        }
    }

    private func statusMetricsGrid(columns: Int) -> some View {
        let snapshot = displayedSnapshot
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: theme.space.s12), count: columns),
            alignment: .leading,
            spacing: theme.space.s12
        ) {
            metricTile(
                title: L("Balance"),
                value: snapshot.accountStatus.formattedBalance,
                detail: statusTitle(snapshot.accountStatus.state),
                icon: "creditcard.fill",
                color: statusColor(snapshot.accountStatus.state)
            )
            metricTile(
                title: L("Requests"),
                value: snapshot.credits.requestCount.formatted(),
                detail: OsaurusRouter.formatMicroAsCredits(snapshot.credits.costMicro),
                icon: "arrow.left.arrow.right",
                color: theme.action.primary.default.background
            )
            metricTile(
                title: L("Ledger rows"),
                value: snapshot.ledger.entryCount.formatted(),
                detail: L("\(snapshot.ledger.pendingCount) pending / \(snapshot.ledger.issueCount) flagged"),
                icon: "list.bullet.rectangle.portrait",
                color: snapshot.ledger.issueCount > 0
                    ? theme.status.warning.foreground : theme.status.success.foreground
            )
            metricTile(
                title: L("Net credits"),
                value: OsaurusRouter.formatMicroAsCredits(snapshot.transactions.netMicro),
                detail: snapshot.transactions.transactionCount == 1
                    ? L("1 transaction")
                    : L("\(snapshot.transactions.transactionCount) transactions"),
                icon: "plus.forwardslash.minus",
                color: RouterAccountUsageCenter.microValue(snapshot.transactions.netMicro) >= 0
                    ? theme.status.success.foreground : theme.status.warning.foreground
            )
        }
    }

    private var accountStatusSection: some View {
        sectionCard(title: L("Account Status"), icon: "person.badge.key.fill") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                HStack(alignment: .center, spacing: theme.space.s12) {
                    statusPill(
                        statusTitle(displayedSnapshot.accountStatus.state),
                        icon: statusIcon(displayedSnapshot.accountStatus.state),
                        color: statusColor(displayedSnapshot.accountStatus.state)
                    )
                    Spacer()
                    Text(verbatim: displayedSnapshot.generatedAt.formatted(date: .abbreviated, time: .standard))
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                }

                keyValueGrid([
                    (L("Router"), displayedSnapshot.accountStatus.routerEnabled ? L("On") : L("Off")),
                    (L("Identity"), displayedSnapshot.accountStatus.identityAvailable ? L("Available") : L("Missing")),
                    (L("Billing"), displayedSnapshot.accountStatus.frozen ? L("On hold") : L("Ready")),
                ])

                if let error = displayedSnapshot.accountStatus.lastError {
                    Text(error)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                        .foregroundColor(theme.status.error.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Totals for the Credits Activity card. The "Cached input" row appears
    /// only once the router has echoed a non-zero prompt-cache split, so
    /// accounts on a pre-cache router (or with no hits yet) see the original
    /// four rows unchanged.
    private var creditsTotalsRows: [(String, String)] {
        let credits = displayedSnapshot.credits
        var rows: [(String, String)] = [
            (L("Input tokens"), credits.inputTokens.formatted())
        ]
        if let cached = OsaurusRouter.formatCachedInputLabel(
            cachedTokens: credits.cachedInputTokens,
            inputTokens: credits.inputTokens
        ) {
            rows.append((L("Cached input"), cached))
        }
        rows.append((L("Output tokens"), credits.outputTokens.formatted()))
        rows.append((L("Usage cost"), OsaurusRouter.formatMicroAsCredits(credits.costMicro)))
        rows.append((L("Top-ups"), OsaurusRouter.formatMicroAsCredits(displayedSnapshot.transactions.creditMicro)))
        return rows
    }

    private var creditsActivitySection: some View {
        sectionCard(title: L("Credits Activity"), icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                keyValueGrid(creditsTotalsRows)

                Divider()

                let rows = Array(model.activityRows.prefix(8))
                if rows.isEmpty {
                    SettingsEmptyState(
                        inline: model.isBusy ? "hourglass" : "tray",
                        title: model.isBusy ? "Loading activity" : "No usage activity",
                        hint: "Router usage appears here after a hosted model request is billed.",
                        isLoading: model.isBusy
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            activityRow(row)
                            if row.id != rows.last?.id {
                                Divider()
                            }
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radius.medium)
                            .stroke(theme.border.default, lineWidth: theme.stroke.default)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
                }

                if !model.transactions.isEmpty {
                    Divider()
                    transactionSummaryRows
                }
            }
        }
    }

    private var transactionSummaryRows: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text("Transaction ledger", bundle: .module)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.compactLabel)
                .foregroundColor(theme.text.secondary)
            breakdownGrid {
                ForEach(displayedSnapshot.transactions.entryTypeBreakdown) { row in
                    breakdownRow(count: row.transactionCount.formatted(), amount: row.netAmountMicro) {
                        Text(verbatim: row.entryType)
                    }
                }
            }
        }
    }

    private var ledgerSection: some View {
        sectionCard(title: L("Billing Ledger"), icon: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                keyValueGrid([
                    (L("Local rows"), displayedSnapshot.ledger.entryCount.formatted()),
                    (L("Ledger cost"), OsaurusRouter.formatMicroAsCredits(displayedSnapshot.ledger.costMicro)),
                    (L("Pending"), displayedSnapshot.ledger.pendingCount.formatted()),
                    (L("Flagged"), displayedSnapshot.ledger.issueCount.formatted()),
                ])

                Divider()

                if displayedSnapshot.ledger.outcomeBreakdown.isEmpty {
                    SettingsEmptyState(
                        inline: "doc.text.magnifyingglass",
                        title: "No local ledger rows",
                        hint: "The encrypted local billing ledger has no rows available.",
                        isLoading: model.isBusy
                    )
                } else {
                    breakdownGrid {
                        ForEach(displayedSnapshot.ledger.outcomeBreakdown) { row in
                            breakdownRow(count: row.entryCount.formatted(), amount: row.costMicro) {
                                HStack(spacing: theme.space.s8) {
                                    Circle()
                                        .fill(outcomeColor(row.outcome))
                                        .frame(width: 8, height: 8)
                                    Text(LocalizedStringKey(outcomeLabel(row.outcome)), bundle: .module)
                                }
                            }
                        }
                    }
                }

                if !displayedSnapshot.ledger.modelBreakdown.isEmpty {
                    Divider()
                    modelBreakdownRows(displayedSnapshot.ledger.modelBreakdown)
                }
            }
        }
    }

    private var signedDiagnosticsSection: some View {
        sectionCard(title: L("Signed Request Diagnostics"), icon: "signature") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                HStack(alignment: .center, spacing: theme.space.s12) {
                    Text("Last signed checks", bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(theme.text.secondary)
                    Spacer()
                    Button {
                        Task { await model.runSignedRequestDiagnostics() }
                    } label: {
                        if model.isSigningDiagnostics {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Label(localized: "Run", systemImage: "checkmark.seal")
                        }
                    }
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
                    .disabled(model.isSigningDiagnostics)
                }

                if model.signedDiagnostics.isEmpty {
                    SettingsEmptyState(
                        inline: "signature",
                        title: "No signed checks yet",
                        hint: "Run a local signing check to inspect the redacted request shape.",
                        isLoading: model.isBusy
                    )
                } else {
                    let diagnostics = model.signedDiagnostics
                    ForEach(diagnostics) { diagnostic in
                        signedDiagnosticRow(diagnostic)
                        if diagnostic.id != diagnostics.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var supportExportSection: some View {
        sectionCard(title: L("Support Export"), icon: "square.and.arrow.up") {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                keyValueGrid([
                    (L("Schema"), "\(RouterSupportExport.schemaVersion)"),
                    (L("Usage rows"), model.usageItems.count.formatted()),
                    (L("Transaction rows"), model.transactions.count.formatted()),
                    (L("Ledger rows"), model.ledgerEntries.count.formatted()),
                ])

                Divider()

                HStack(alignment: .center, spacing: theme.space.s12) {
                    Label(localized: "Metadata only", systemImage: "lock.shield")
                        .componentInspectionText(51, role: .caption, fallback: .caption, weight: 500, theme: theme)
                        .foregroundColor(theme.text.secondary)
                    Spacer()
                    Button {
                        chooseSupportExportURL()
                    } label: {
                        if model.isExportingSupport {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Label(localized: "Export", systemImage: "square.and.arrow.up")
                        }
                    }
                    .assignedSettingsButtonStyle(.primary, size: .compact)
                    .disabled(model.isExportingSupport)
                }
            }
        }
    }

    private func signedDiagnosticRow(_ diagnostic: RouterSignedRequestDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                Text(verbatim: diagnostic.method)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(theme.text.link)
                Text(verbatim: diagnostic.pathAndQuery)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(verbatim: diagnostic.generatedAt.formatted(date: .omitted, time: .standard))
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
            }

            keyValueGrid([
                (L("Body SHA-256"), diagnostic.bodySHA256),
                (L("Bytes"), diagnostic.bodyBytes.formatted()),
                (L("Wallet"), diagnostic.walletAddress ?? L("Missing")),
                (L("Signature"), diagnostic.signatureFingerprint ?? L("Missing")),
            ])

            if !diagnostic.warnings.isEmpty {
                Text(verbatim: diagnostic.warnings.joined(separator: " · "))
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.status.warning.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: theme.space.s6) {
                ForEach(diagnostic.redactedHeaders.keys.sorted(), id: \.self) { header in
                    HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                        Text(verbatim: header)
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                            .foregroundColor(theme.text.secondary)
                            .frame(minWidth: 150, alignment: .leading)
                        Text(verbatim: diagnostic.redactedHeaders[header] ?? "")
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                            .foregroundColor(theme.text.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.top, theme.space.s2)
        }
        .padding(.vertical, theme.space.s4)
    }

    private func activityRow(_ row: CreditsActivityRow) -> some View {
        HStack(alignment: .top, spacing: theme.space.s8) {
            Circle()
                .fill(stateColor(row.stateKind))
                .frame(width: 8, height: 8)
                .padding(.top, theme.space.s6)

            VStack(alignment: .leading, spacing: theme.space.s4) {
                HStack(spacing: theme.space.s8) {
                    Text(verbatim: row.modelDisplay ?? L("Unknown model"))
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.sectionTitle)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    outcomeBadge(for: row)
                }

                Text(verbatim: row.metadataLine)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(1)

                Text(verbatim: row.tokensLine)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
            }

            Spacer(minLength: 0)

            Text(verbatim: OsaurusRouter.formatMicroAsCredits(row.costMicro))
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.sectionTitle.monospacedDigit())
                .foregroundColor(theme.text.primary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .background(theme.surface.raised)
    }

    private func outcomeBadge(for row: CreditsActivityRow) -> some View {
        StatusChip(
            [row.stateLabel, row.stateDetail].compactMap { $0 }.filter { !$0.isEmpty }.map { LCached($0) }
                .joined(separator: " · "),
            tint: stateColor(row.stateKind)
        )
            .fixedSize()
    }

    private func modelBreakdownRows(_ rows: [RouterUsageBreakdown]) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text("Model totals", bundle: .module)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.compactLabel)
                .foregroundColor(theme.text.secondary)
            breakdownGrid {
                ForEach(rows.prefix(5)) { row in
                    breakdownRow(count: row.requestCount.formatted(), amount: row.costMicro) {
                        Text(verbatim: row.name)
                    }
                }
            }
        }
    }

    private func breakdownGrid<Rows: View>(@ViewBuilder rows: () -> Rows) -> some View {
        Grid(alignment: .leading, horizontalSpacing: theme.space.s12, verticalSpacing: theme.space.s4) {
            rows()
        }
    }

    private func breakdownRow<Label: View>(count: String, amount: String, @ViewBuilder label: () -> Label) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            label()
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: count)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall.monospacedDigit())
                .foregroundColor(theme.text.secondary)
                .gridColumnAlignment(.trailing)
            Text(verbatim: OsaurusRouter.formatMicroAsCredits(amount))
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.compactLabel.monospacedDigit())
                .foregroundColor(theme.text.primary)
                .gridColumnAlignment(.trailing)
        }
    }

    private func keyValueGrid(_ items: [(String, String)]) -> some View {
        ViewThatFits(in: .horizontal) {
            keyValueGrid(items, columns: items.count)
                .frame(minWidth: CGFloat(items.count) * 104 + CGFloat(items.count - 1) * theme.space.s12)
            keyValueGrid(items, columns: 2)
        }
    }

    private func keyValueGrid(_ items: [(String, String)], columns: Int) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: theme.space.s12), count: columns),
            alignment: .leading,
            spacing: theme.space.s8
        ) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(LocalizedStringKey(item.0), bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)
                    Text(verbatim: item.1)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.sectionTitle.monospacedDigit())
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func metricTile(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: icon)
                    .glyphSize(12, weight: .semibold)
                    .foregroundColor(color)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(color.opacity(0.13)))
                Text(LocalizedStringKey(title), bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
            }
            Text(verbatim: value)
                .catalogTypography(.heading, theme: theme, fallback: SettingsFont.detailTitle.monospacedDigit())
                .foregroundColor(theme.text.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(LocalizedStringKey(detail), bundle: .module)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.surface)
    }

    private func sectionCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: icon)
                    .glyphSize(13, weight: .semibold)
                    .foregroundColor(theme.text.link)
                    .frame(width: 20, height: 20)
                Text(LocalizedStringKey(title), bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                Spacer()
            }

            content()
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.surface)
    }

    private func statusPill(_ title: String, icon: String, color: Color) -> some View {
        StatusChip(title, tint: color, icon: icon)
    }

    private func messageBanner(_ message: String) -> some View {
        InlineBanner(kind: .info, title: message)
    }

    private func stateColor(_ kind: CreditsActivityStateKind) -> Color {
        switch kind {
        case .success: return theme.status.success.foreground
        case .warning: return theme.status.warning.foreground
        case .error: return theme.status.error.foreground
        case .secondary: return theme.text.secondary
        }
    }

    private func outcomeColor(_ outcome: RouterBillingOutcome) -> Color {
        switch outcome {
        case .rendered, .toolOnly, .reasoningOnly: return theme.status.success.foreground
        case .pending: return theme.text.secondary
        case .cancelled: return theme.status.warning.foreground
        case .empty, .error: return theme.status.error.foreground
        }
    }

    private func outcomeLabel(_ outcome: RouterBillingOutcome) -> String {
        switch outcome {
        case .pending: return L("Pending")
        case .rendered: return L("Rendered")
        case .reasoningOnly: return L("Reasoning only")
        case .toolOnly: return L("Tools only")
        case .empty: return L("No reply")
        case .error: return L("Error")
        case .cancelled: return L("Stopped")
        }
    }

    private func statusTitle(_ state: RouterAccountStatusSnapshot.State) -> String {
        switch state {
        case .active: return L("Active")
        case .disabled: return L("Router off")
        case .missingIdentity: return L("Identity required")
        case .frozen: return L("On hold")
        case .unavailable: return L("Unavailable")
        }
    }

    private func statusIcon(_ state: RouterAccountStatusSnapshot.State) -> String {
        switch state {
        case .active: return "checkmark.circle.fill"
        case .disabled: return "bolt.slash.fill"
        case .missingIdentity: return "person.badge.key.fill"
        case .frozen: return "pause.circle.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ state: RouterAccountStatusSnapshot.State) -> Color {
        switch state {
        case .active: return theme.status.success.foreground
        case .disabled: return theme.text.secondary
        case .missingIdentity, .frozen: return theme.status.warning.foreground
        case .unavailable: return theme.status.error.foreground
        }
    }

    private func chooseSupportExportURL() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "osaurus-router-support-export.json"
        panel.canCreateDirectories = true
        panel.title = L("Export Router Support Bundle")
        panel.message = L("Metadata only - no prompts, replies, tool payloads, private keys, or signatures.")

        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            await model.exportSupport(to: url)
        }
    }
}

#if OSAURUS_DESIGN_SYSTEM
extension RouterAccountUsageCenterView {
    static func inspectionAccount(_ state: String, theme: any ThemeProtocol) -> some View {
        var view = RouterAccountUsageCenterView()
        view.inspectionTheme = theme
        let balance = OsaurusRouterBalanceResponse(balanceMicro: "1234567", frozen: state == "Frozen")
        let usage = OsaurusRouterUsageItem(id: "local-account-display", requestId: nil, model: "Local display model", provider: "Local sample", inputTokens: 1234, outputTokens: 56, costMicro: "1234", status: "completed", tokenSource: "provider", createdAt: "2026-10-22T12:00:00Z")
        view.inspectionSnapshot = RouterAccountUsageCenter.snapshot(routerEnabled: state != "Disabled", identityAvailable: state != "Missing identity", balance: state == "Error" ? nil : balance, lastError: state == "Error" ? "Local account error display." : nil, usageItems: [usage], transactions: [], ledgerEntries: [])
        return VStack(alignment: .leading, spacing: 12) {
            view.statusMetrics
            view.accountStatusSection
            view.sectionCard(title: "Populated totals", icon: "chart.bar") { view.keyValueGrid(view.creditsTotalsRows) }
        }.environment(\.theme, view.theme).allowsHitTesting(false)
    }
}
#endif
