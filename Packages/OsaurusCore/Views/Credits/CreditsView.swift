import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CreditsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var accountService = OsaurusRouterAccountService.shared
    @ObservedObject private var insightsService = InsightsService.shared
    @ObservedObject private var providerManager = RemoteProviderManager.shared

    private static let activityPageSize = 10
    private static let ledgerMatchLimit = 500

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var usagePageIndex = 0
    @State private var ledgerEntries: [RouterBillingEntry] = []
    @State private var ledgerTotalCount = 0
    @State private var isLoadingLedger = false
    @State private var isExportingDiagnostics = false
    @State private var diagnosticsMessage: String?
    @State private var showTopUpSheet = false
    @State private var showDisableRouterConfirm = false
    @State private var showRouterUsageCenter = false

    /// User master switch state. When off, the Credits screen hides the
    /// balance/activity cards (the router is no longer polled) and shows the
    /// "router off" explainer instead.
    private var routerEnabled: Bool { providerManager.isOsaurusRouterEnabled }

    /// Top-ups need both an active router and an identity to bill against.
    private var canAddCredits: Bool { routerEnabled && OsaurusIdentity.exists() }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if routerEnabled {
                        if !OsaurusIdentity.exists() {
                            identityRequiredCard
                        }
                        balanceCard
                        activityCard
                    } else {
                        routerOffCard
                    }
                    routerToggleFooter
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
            await refreshCredits(resetPages: true)
        }
        .onChange(of: accountService.usage) { _, _ in
            Task { await reloadLedger() }
        }
        .onChange(of: providerManager.isOsaurusRouterEnabled) { _, isEnabled in
            // Re-enabling while viewing Credits should populate balance/activity
            // immediately (the toggle action itself only reconnects the router).
            if isEnabled {
                Task { await refreshCredits(resetPages: true) }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .sheet(isPresented: $showTopUpSheet) {
            CreditsTopUpSheet()
                .environment(\.theme, themeManager.currentTheme)
        }
        .sheet(isPresented: $showRouterUsageCenter) {
            RouterAccountUsageCenterView()
                .environment(\.theme, themeManager.currentTheme)
                .frame(width: 980, height: 760)
        }
        .confirmationDialog(
            Text("Turn off Osaurus Router?", bundle: .module),
            isPresented: $showDisableRouterConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                providerManager.setOsaurusRouterEnabled(false)
            } label: {
                Text("Turn Off", bundle: .module)
            }
            Button(role: .cancel) {
            } label: {
                Text("Keep On", bundle: .module)
            }
        } message: {
            Text(
                "Osaurus will run fully local and free. Cloud models routed through Osaurus will be hidden, and any chat using one will switch to a local model. You can turn it back on anytime. Thanks for supporting Osaurus.",
                bundle: .module
            )
        }
    }

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Credits"),
            subtitle: L("Add credits and see what each Osaurus Router request costs.")
        ) {
            HeaderIconButton(
                "arrow.clockwise",
                isLoading: accountService.isLoadingBalance || accountService.isLoadingUsage || isLoadingLedger,
                help: "Refresh"
            ) {
                Task { await refreshCredits(resetPages: true) }
            }
            .disabled(!routerEnabled)
            .opacity(routerEnabled ? 1 : 0.55)
            HeaderIconButton(
                "chart.bar.xaxis",
                help: "Account details"
            ) {
                showRouterUsageCenter = true
            }
            .disabled(!routerEnabled)
            .opacity(routerEnabled ? 1 : 0.55)
            HeaderPrimaryButton("Add credits", icon: "creditcard.fill") {
                showTopUpSheet = true
            }
            .disabled(!canAddCredits)
            .opacity(canAddCredits ? 1 : 0.55)
        }
    }

    private var identityRequiredCard: some View {
        card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Set up your Osaurus Identity", bundle: .module)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "The router uses your identity master key as your billing account. Create or restore an identity before adding credits or calling Osaurus models.",
                        bundle: .module
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                    Button {
                        ManagementStateManager.shared.selectedTab = .identity
                    } label: {
                        Text("Open Identity", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
            }
        }
    }

    // MARK: - Router master switch

    /// Quiet, bottom-anchored footer that always renders. Deliberately
    /// understated (no card chrome) so it stays discoverable without inviting a
    /// casual opt-out: turning the router off routes through a confirmation,
    /// turning it back on is a single tap.
    private var routerToggleFooter: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Osaurus Router", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Text(
                    "Runs cloud models and provider load-balancing; requests spend credits. Keeping it on helps support Osaurus development - thank you.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: routerToggleBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(theme.accentColor)
        }
        .padding(.top, 8)
    }

    /// Drives the footer switch. Enabling is immediate; disabling defers to the
    /// confirmation dialog and leaves the published value (and the switch) on
    /// until the user confirms, so an accidental flip is recoverable.
    private var routerToggleBinding: Binding<Bool> {
        Binding(
            get: { providerManager.isOsaurusRouterEnabled },
            set: { newValue in
                if newValue {
                    providerManager.setOsaurusRouterEnabled(true)
                } else {
                    showDisableRouterConfirm = true
                }
            }
        )
    }

    /// Shown in place of the balance/activity cards while the router is off.
    private var routerOffCard: some View {
        card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "bolt.slash.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Osaurus Router is off", bundle: .module)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "Osaurus is running fully local and free. Cloud models routed through Osaurus are hidden, and no requests are sent to Osaurus servers. Turn it back on below whenever you like.",
                        bundle: .module
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    private var balanceCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Credit balance", bundle: .module)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(verbatim: accountService.formattedBalance)
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundColor(theme.primaryText)
                            if accountService.isLoadingBalance {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                        }
                    }

                    Spacer()

                    if accountService.isFrozen {
                        statusPill(L("On hold"), icon: "pause.circle.fill", color: theme.warningColor)
                    } else {
                        statusPill(L("Active"), icon: "checkmark.circle.fill", color: theme.successColor)
                    }
                }

                Text(
                    "Credits pay for cloud models and provider load-balancing routed through Osaurus.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(spacing: 12) {
                    Label(localized: "Minimum top-up is $5.00", systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)

                    Spacer()

                    if accountService.isCreatingCheckout {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Button {
                        showTopUpSheet = true
                    } label: {
                        Label(localized: "Add credits", systemImage: "creditcard.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!OsaurusIdentity.exists() || accountService.isCreatingCheckout)
                }

                if let error = accountService.lastError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Credits activity

    private var activityCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent activity", bundle: .module)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text(
                            "Requests routed through Osaurus, newest first. Open the chat or Insights when this Mac has the matching copy.",
                            bundle: .module
                        )
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button {
                        exportDiagnostics()
                    } label: {
                        if isExportingDiagnostics {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Label(localized: "Export diagnostics", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isExportingDiagnostics || ledgerTotalCount == 0)
                }

                if currentActivityRows.isEmpty {
                    emptyActivityState
                } else {
                    activityList
                    activityPaginationControls
                }

                if let diagnosticsMessage {
                    Text(diagnosticsMessage)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var activityList: some View {
        let rows = currentActivityRows
        return VStack(spacing: 0) {
            ForEach(rows) { row in
                activityRow(row)
                if row.id != rows.last?.id {
                    Divider()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.cardBorder, lineWidth: 1)
        )
    }

    private var emptyActivityState: some View {
        VStack(spacing: 10) {
            if isLoadingCurrentActivity {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 24))
                    .foregroundColor(theme.tertiaryText)
            }
            Text("No requests yet", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(
                "When you use an Osaurus Router model, each request shows up here with its cost and tokens. If this Mac made the request, you can jump to the chat or Insights.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var activityPaginationControls: some View {
        HStack(spacing: 10) {
            Text(verbatim: usageRangeLabel)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

            Spacer()

            Button {
                goToPreviousActivityPage()
            } label: {
                Label(localized: "Previous", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canGoToPreviousActivityPage || isLoadingCurrentActivity)

            Button {
                goToNextUsagePage()
            } label: {
                if isLoadingCurrentActivity {
                    ProgressView().scaleEffect(0.7)
                } else if canLoadMoreFromServer {
                    Label(localized: "Load more", systemImage: "arrow.down.circle")
                } else {
                    Label(localized: "Next", systemImage: "chevron.right")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canGoToNextActivityPage || isLoadingCurrentActivity)
        }
    }

    private var currentActivityRows: [CreditsActivityRow] {
        CreditsActivityProjector(
            hasInsightsLogForRequestId: { insightsService.hasLog(requestId: $0) },
            hasInsightsLogForTurnId: { insightsService.hasLog(turnId: $0) }
        )
        .rows(usageItems: pagedUsageRows, ledgerEntries: ledgerEntries)
    }

    private var pagedUsageRows: [OsaurusRouterUsageItem] {
        let start = usagePageIndex * Self.activityPageSize
        guard start < accountService.usage.count else { return [] }
        let end = min(start + Self.activityPageSize, accountService.usage.count)
        return Array(accountService.usage[start ..< end])
    }

    private var isLoadingCurrentActivity: Bool {
        accountService.isLoadingUsage || isLoadingLedger
    }

    private var canGoToPreviousActivityPage: Bool {
        usagePageIndex > 0
    }

    private var canGoToNextActivityPage: Bool {
        let nextStart = (usagePageIndex + 1) * Self.activityPageSize
        return nextStart < accountService.usage.count || accountService.nextUsageCursor != nil
    }

    /// True only when the next page isn't already loaded but the server says more
    /// rows exist — i.e. the advance button should fetch instead of just paging.
    private var canLoadMoreFromServer: Bool {
        let nextStart = (usagePageIndex + 1) * Self.activityPageSize
        return nextStart >= accountService.usage.count && accountService.nextUsageCursor != nil
    }

    /// Honest range over what we've actually loaded. The router never returns a
    /// true total, so "loaded" makes clear more may exist behind "Load more"
    /// rather than implying a misleading grand total.
    private var usageRangeLabel: String {
        let loaded = accountService.usage.count
        guard loaded > 0 else { return "" }
        let start = usagePageIndex * Self.activityPageSize
        let end = min(start + currentActivityRows.count, loaded)
        if accountService.nextUsageCursor != nil {
            return L("Showing \(start + 1)-\(end) of \(loaded) loaded")
        }
        return L("Showing \(start + 1)-\(end) of \(loaded)")
    }

    private func activityRow(_ row: CreditsActivityRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(stateColor(row.stateKind))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    modelName(for: row)
                    outcomeBadge(for: row)
                }

                if !row.metadataLine.isEmpty {
                    Text(verbatim: row.metadataLine)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                HStack(spacing: 14) {
                    Text(verbatim: row.tokensLine)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                    referenceLinks(for: row)
                }
            }

            Spacer(minLength: 12)

            Text(verbatim: OsaurusRouter.formatMicroUSDPrecise(row.costMicro))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(theme.primaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.cardBackground)
    }

    @ViewBuilder
    private func modelName(for row: CreditsActivityRow) -> some View {
        if let name = row.modelDisplay {
            Text(verbatim: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("Unknown model", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
        }
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

    @ViewBuilder
    private func referenceLinks(for row: CreditsActivityRow) -> some View {
        HStack(spacing: 14) {
            if let reference = row.localReference {
                Button {
                    openLocalReference(reference)
                } label: {
                    Label(localized: "Chat", systemImage: "arrow.up.right.square")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.accentColor)
                .help(reference.chatHelpText)
            }

            if let reference = row.insightsReference {
                Button {
                    openInsightsReference(reference)
                } label: {
                    Label(localized: "Insights", systemImage: "waveform.path.ecg.magnifyingglass")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.accentColor)
                .help(reference.insightsHelpText)
            }
        }
    }

    private func stateColor(_ kind: CreditsActivityStateKind) -> Color {
        switch kind {
        case .success:
            return theme.successColor
        case .warning:
            return theme.warningColor
        case .error:
            return theme.errorColor
        case .secondary:
            return theme.secondaryText
        }
    }

    private func goToPreviousActivityPage() {
        usagePageIndex = max(0, usagePageIndex - 1)
    }

    private func goToNextUsagePage() {
        let nextIndex = usagePageIndex + 1
        let nextStart = nextIndex * Self.activityPageSize
        if nextStart < accountService.usage.count {
            usagePageIndex = nextIndex
            return
        }
        guard accountService.nextUsageCursor != nil else { return }
        Task {
            let previousCount = accountService.usage.count
            await accountService.loadMoreUsage()
            if accountService.usage.count > previousCount {
                await reloadLedger()
                usagePageIndex = nextIndex
            }
        }
    }

    private func openLocalReference(_ reference: CreditsActivityReference) {
        guard let sessionId = reference.sessionUUID else { return }
        if let existingWindow = ChatWindowManager.shared.findWindow(bySessionId: sessionId) {
            ChatWindowManager.shared.showWindow(id: existingWindow.id)
            return
        }
        guard let sessionData = ChatSessionStore.load(id: sessionId) else {
            diagnosticsMessage = String(
                localized: "The referenced chat session is no longer available.",
                bundle: .module
            )
            return
        }
        ChatWindowManager.shared.createWindow(agentId: sessionData.agentId, sessionData: sessionData)
    }

    private func openInsightsReference(_ reference: CreditsActivityReference) {
        if let requestId = reference.requestId,
            InsightsService.shared.focus(requestId: requestId)
        {
            AppDelegate.shared?.showManagementWindow(initialTab: .insights)
            return
        }
        if let turnId = reference.turnUUID,
            InsightsService.shared.focus(turnId: turnId)
        {
            AppDelegate.shared?.showManagementWindow(initialTab: .insights)
        } else {
            diagnosticsMessage = String(
                localized: "The detailed Insights log for this usage row is no longer available.",
                bundle: .module
            )
        }
    }

    // MARK: - Shared view helpers

    private func statusPill(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
            )
    }

    // MARK: - Data loading

    private func refreshCredits(resetPages: Bool) async {
        if resetPages {
            usagePageIndex = 0
        }
        await accountService.refreshAll()
        await reloadLedger()
    }

    /// Pull the local ledger off the main actor. Opening the encrypted SQLite
    /// file and running migrations should not block the UI.
    private func reloadLedger() async {
        isLoadingLedger = true
        defer { isLoadingLedger = false }

        let limit = Self.ledgerMatchLimit
        let requestIds = accountService.usage.compactMap(\.correlationRequestId)
        let result = await Task.detached(priority: .utility) {
            let total = RouterBillingLedger.shared.count()
            let exactRows = RouterBillingLedger.shared.findByRequestIds(requestIds)
            let legacyRows = RouterBillingLedger.shared.recent(limit: limit).filter { $0.requestId == nil }
            var rowsById = Dictionary(uniqueKeysWithValues: exactRows.map { ($0.id, $0) })
            for row in legacyRows {
                rowsById[row.id] = row
            }
            let rows = rowsById.values.sorted { $0.createdAt > $1.createdAt }
            return (rows: rows, total: total)
        }.value

        ledgerEntries = result.rows
        ledgerTotalCount = result.total
    }

    /// Write a metadata-only diagnostics file via a save panel. It does not
    /// trigger biometric authentication only to derive wallet-address metadata.
    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "osaurus-billing-diagnostics.json"
        panel.canCreateDirectories = true
        panel.title = L("Export Billing Diagnostics")
        panel.message = L("Metadata only - no prompts or replies are included.")
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            await writeDiagnostics(to: url)
        }
    }

    private func writeDiagnostics(to url: URL) async {
        isExportingDiagnostics = true
        defer { isExportingDiagnostics = false }

        let diagnostics = RouterBillingLedger.shared.buildDiagnostics(
            walletAddress: nil,
            walletAddressStatus: OsaurusIdentity.existsCached() ? .unavailableWithoutPrompt : .identityMissing
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(diagnostics)
            try data.write(to: url, options: .atomic)
            diagnosticsMessage = String(
                localized: "Exported \(diagnostics.entries.count) row(s) to \(url.lastPathComponent).",
                bundle: .module
            )
        } catch {
            diagnosticsMessage = error.localizedDescription
        }
    }

}
