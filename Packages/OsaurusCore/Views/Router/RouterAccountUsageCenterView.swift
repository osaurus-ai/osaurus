import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RouterAccountUsageCenterView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @StateObject private var model = RouterAccountUsageCenterViewModel()
    @State private var hasAppeared = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            ManagerHeaderWithActions(
                title: L("Router Account"),
                subtitle: L("Account status, usage activity, signed request diagnostics, and support export.")
            ) {
                HeaderIconButton(
                    "arrow.clockwise",
                    isLoading: model.isRefreshing,
                    help: "Refresh"
                ) {
                    Task { await model.refresh() }
                }

                HeaderIconButton(
                    "signature",
                    isLoading: model.isSigningDiagnostics,
                    help: "Signed request diagnostics"
                ) {
                    Task { await model.runSignedRequestDiagnostics() }
                }

                HeaderPrimaryButton("Export support", icon: "square.and.arrow.up") {
                    chooseSupportExportURL()
                }
                .disabled(model.isExportingSupport)
                .opacity(model.isExportingSupport ? 0.6 : 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .task {
            await model.refresh()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.22).delay(0.04)) {
                hasAppeared = true
            }
        }
    }

    private var statusMetrics: some View {
        let snapshot = model.snapshot
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 12)],
            alignment: .leading,
            spacing: 12
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
                detail: OsaurusRouter.formatMicroUSDPrecise(snapshot.credits.costMicro),
                icon: "arrow.left.arrow.right",
                color: theme.accentColor
            )
            metricTile(
                title: L("Ledger rows"),
                value: snapshot.ledger.entryCount.formatted(),
                detail: L("\(snapshot.ledger.pendingCount) pending / \(snapshot.ledger.issueCount) flagged"),
                icon: "list.bullet.rectangle.portrait",
                color: snapshot.ledger.issueCount > 0 ? theme.warningColor : theme.successColor
            )
            metricTile(
                title: L("Net credits"),
                value: OsaurusRouter.formatMicroUSDPrecise(snapshot.transactions.netMicro),
                detail: L("\(snapshot.transactions.transactionCount) transaction(s)"),
                icon: "plus.forwardslash.minus",
                color: RouterAccountUsageCenter.microValue(snapshot.transactions.netMicro) >= 0
                    ? theme.successColor : theme.warningColor
            )
        }
    }

    private var accountStatusSection: some View {
        sectionCard(title: L("Account Status"), icon: "person.badge.key.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    statusPill(
                        statusTitle(model.snapshot.accountStatus.state),
                        icon: statusIcon(model.snapshot.accountStatus.state),
                        color: statusColor(model.snapshot.accountStatus.state)
                    )
                    Spacer()
                    Text(verbatim: model.snapshot.generatedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }

                keyValueGrid([
                    (L("Router"), model.snapshot.accountStatus.routerEnabled ? L("On") : L("Off")),
                    (L("Identity"), model.snapshot.accountStatus.identityAvailable ? L("Available") : L("Missing")),
                    (L("Billing"), model.snapshot.accountStatus.frozen ? L("On hold") : L("Ready")),
                ])

                if let error = model.snapshot.accountStatus.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var creditsActivitySection: some View {
        sectionCard(title: L("Credits Activity"), icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 14) {
                keyValueGrid([
                    (L("Input tokens"), model.snapshot.credits.inputTokens.formatted()),
                    (L("Output tokens"), model.snapshot.credits.outputTokens.formatted()),
                    (L("Usage cost"), OsaurusRouter.formatMicroUSDPrecise(model.snapshot.credits.costMicro)),
                    (L("Top-ups"), OsaurusRouter.formatMicroUSDPrecise(model.snapshot.transactions.creditMicro)),
                ])

                Divider()

                let rows = Array(model.activityRows.prefix(8))
                if rows.isEmpty {
                    emptyState(
                        icon: model.isBusy ? "hourglass" : "tray",
                        title: model.isBusy ? L("Loading activity") : L("No usage activity"),
                        detail: L("Router usage appears here after a hosted model request is billed.")
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
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if !model.transactions.isEmpty {
                    Divider()
                    transactionSummaryRows
                }
            }
        }
    }

    private var transactionSummaryRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transaction ledger", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            ForEach(model.snapshot.transactions.entryTypeBreakdown) { row in
                HStack(spacing: 12) {
                    Text(verbatim: row.entryType)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Spacer()
                    Text(verbatim: "\(row.transactionCount.formatted())")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                    Text(verbatim: OsaurusRouter.formatMicroUSDPrecise(row.netAmountMicro))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.primaryText)
                        .monospacedDigit()
                }
            }
        }
    }

    private var ledgerSection: some View {
        sectionCard(title: L("Billing Ledger"), icon: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 14) {
                keyValueGrid([
                    (L("Local rows"), model.snapshot.ledger.entryCount.formatted()),
                    (L("Ledger cost"), OsaurusRouter.formatMicroUSDPrecise(model.snapshot.ledger.costMicro)),
                    (L("Pending"), model.snapshot.ledger.pendingCount.formatted()),
                    (L("Flagged"), model.snapshot.ledger.issueCount.formatted()),
                ])

                Divider()

                if model.snapshot.ledger.outcomeBreakdown.isEmpty {
                    emptyState(
                        icon: "doc.text.magnifyingglass",
                        title: L("No local ledger rows"),
                        detail: L("The encrypted local billing ledger has no rows available.")
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.snapshot.ledger.outcomeBreakdown) { row in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(outcomeColor(row.outcome))
                                    .frame(width: 8, height: 8)
                                Text(LocalizedStringKey(outcomeLabel(row.outcome)), bundle: .module)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                Spacer()
                                Text(verbatim: "\(row.entryCount.formatted())")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(theme.secondaryText)
                                Text(verbatim: OsaurusRouter.formatMicroUSDPrecise(row.costMicro))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(theme.primaryText)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                if !model.snapshot.ledger.modelBreakdown.isEmpty {
                    Divider()
                    modelBreakdownRows(model.snapshot.ledger.modelBreakdown)
                }
            }
        }
    }

    private var signedDiagnosticsSection: some View {
        sectionCard(title: L("Signed Request Diagnostics"), icon: "signature") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Last signed checks", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
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
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isSigningDiagnostics)
                }

                if model.signedDiagnostics.isEmpty {
                    emptyState(
                        icon: "signature",
                        title: L("No signed checks yet"),
                        detail: L("Run a local signing check to inspect the redacted request shape.")
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
            VStack(alignment: .leading, spacing: 12) {
                keyValueGrid([
                    (L("Schema"), "\(RouterSupportExport.schemaVersion)"),
                    (L("Usage rows"), model.usageItems.count.formatted()),
                    (L("Transaction rows"), model.transactions.count.formatted()),
                    (L("Ledger rows"), model.ledgerEntries.count.formatted()),
                ])

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    Label(localized: "Metadata only", systemImage: "lock.shield")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
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
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.isExportingSupport)
                }
            }
        }
    }

    private func signedDiagnosticRow(_ diagnostic: RouterSignedRequestDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: diagnostic.method)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accentColor)
                Text(verbatim: diagnostic.pathAndQuery)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(verbatim: diagnostic.generatedAt.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }

            keyValueGrid([
                (L("Body SHA-256"), diagnostic.bodySHA256),
                (L("Bytes"), diagnostic.bodyBytes.formatted()),
                (L("Wallet"), diagnostic.walletAddress ?? L("Missing")),
                (L("Signature"), diagnostic.signatureFingerprint ?? L("Missing")),
            ])

            if !diagnostic.warnings.isEmpty {
                Text(verbatim: diagnostic.warnings.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(diagnostic.redactedHeaders.keys.sorted(), id: \.self) { header in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: header)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .frame(minWidth: 150, alignment: .leading)
                        Text(verbatim: diagnostic.redactedHeaders[header] ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func activityRow(_ row: CreditsActivityRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(stateColor(row.stateKind))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(verbatim: row.modelDisplay ?? L("Unknown model"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    outcomeBadge(for: row)
                }

                Text(verbatim: row.metadataLine)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)

                Text(verbatim: row.tokensLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer(minLength: 12)

            Text(verbatim: OsaurusRouter.formatMicroUSDPrecise(row.costMicro))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(theme.primaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(theme.cardBackground)
    }

    private func outcomeBadge(for row: CreditsActivityRow) -> some View {
        HStack(spacing: 4) {
            Text(LocalizedStringKey(row.stateLabel), bundle: .module)
            if let detail = row.stateDetail, !detail.isEmpty {
                Text(verbatim: "·")
                Text(LocalizedStringKey(detail), bundle: .module)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(stateColor(row.stateKind))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(stateColor(row.stateKind).opacity(0.12)))
        .fixedSize()
    }

    private func modelBreakdownRows(_ rows: [RouterUsageBreakdown]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model totals", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            ForEach(rows.prefix(5)) { row in
                HStack(spacing: 12) {
                    Text(verbatim: row.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(verbatim: "\(row.requestCount.formatted())")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                    Text(verbatim: OsaurusRouter.formatMicroUSDPrecise(row.costMicro))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.primaryText)
                        .monospacedDigit()
                }
            }
        }
    }

    private func keyValueGrid(_ items: [(String, String)]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(item.0), bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Text(verbatim: item.1)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func metricTile(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(color.opacity(0.13)))

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Text(verbatim: value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .monospacedDigit()
                Text(LocalizedStringKey(detail), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minHeight: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func sectionCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 20, height: 20)
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            if model.isBusy {
                ProgressView()
                    .scaleEffect(0.75)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(LocalizedStringKey(detail), bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func statusPill(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func messageBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(theme.infoColor)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.infoColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.infoColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func stateColor(_ kind: CreditsActivityStateKind) -> Color {
        switch kind {
        case .success: return theme.successColor
        case .warning: return theme.warningColor
        case .error: return theme.errorColor
        case .secondary: return theme.secondaryText
        }
    }

    private func outcomeColor(_ outcome: RouterBillingOutcome) -> Color {
        switch outcome {
        case .rendered, .toolOnly, .reasoningOnly: return theme.successColor
        case .pending: return theme.secondaryText
        case .cancelled: return theme.warningColor
        case .empty, .error: return theme.errorColor
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
        case .active: return theme.successColor
        case .disabled: return theme.secondaryText
        case .missingIdentity, .frozen: return theme.warningColor
        case .unavailable: return theme.errorColor
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
