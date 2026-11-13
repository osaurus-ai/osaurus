import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CreditsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var accountService = OsaurusRouterAccountService.shared
    @ObservedObject private var insightsService = InsightsService.shared
    @ObservedObject private var providerManager = RemoteProviderManager.shared
    @ObservedObject private var searchManager = SearchProviderManager.shared

    private static let activityPageSize = 10
    private static let ledgerMatchLimit = 500

    private var theme: any ThemeProtocol {
        if let inspectionTheme { return inspectionTheme }
        return themeManager.currentTheme
    }

    private var inspectionTheme: (any ThemeProtocol)?
    var inspectionBalance: InspectorWalletBalance?
    private var displayedFrozen: Bool {
        if let value = inspectionBalance { return value.frozen }
        return accountService.isFrozen
    }
    private var displayedBalance: String {
        if let value = inspectionBalance { return value.value }
        return accountService.formattedBalanceValue
    }
    private var displayedLoading: Bool {
        if let value = inspectionBalance { return value.loading }
        return accountService.isLoadingBalance
    }
    private var displayedError: String? {
        if let value = inspectionBalance { return value.error }
        return accountService.lastError
    }

    @State private var timelinePageIndex = 0
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
    /// `existsCached()` because this recomputes with every body pass: the
    /// synchronous `exists()` blocks on securityd's keychain mutex, which has
    /// hung the main thread for seconds. Gating chrome is eventually
    /// consistent by design; the checkout/redeem services still verify the
    /// identity authoritatively before billing.
    private var canAddCredits: Bool { routerEnabled && OsaurusIdentity.existsCached() }

    var body: some View {
        if showRouterUsageCenter {
            RouterAccountUsageCenterView()
                .settingsBackDestination(L("Wallet & Credits"), verbatim: true) { showRouterUsageCenter = false }
        } else {
            creditsPage
        }
    }

    private var creditsPage: some View {
        SettingsPage {
            headerView
        } content: {
            routerSection
            if routerEnabled {
                if !OsaurusIdentity.existsCached() {
                    identityRequiredCard
                }
                balanceCard
                CreditsRedeemCodeCard(isEnabled: canAddCredits)
                webSearchCard
                activityCard
            }
        }
        .environment(\.theme, theme)
        .task {
            await refreshCredits(resetPages: true)
        }
        .onChange(of: accountService.usage) { _, _ in
            Task { await reloadLedger() }
        }
        // A billed turn settled while Credits is open: refetch the usage
        // rows (debounced upstream). Fires only while this tab is mounted.
        .onChange(of: accountService.usageRevision) { _, _ in
            Task { await accountService.refreshUsage(reset: true) }
        }
        .onChange(of: providerManager.isOsaurusRouterEnabled) { _, isEnabled in
            // Re-enabling while viewing Credits should populate balance/activity
            // immediately (the toggle action itself only reconnects the router).
            if isEnabled {
                Task { await refreshCredits(resetPages: true) }
            }
        }
        .sheet(isPresented: $showTopUpSheet) {
            CreditsTopUpSheet()
                .environment(\.theme, theme)
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
        SettingsPageHeader(
            title: "Wallet & Credits",
            subtitle: "Osaurus Router, balance, top-ups and search credits.",
            onRefresh: routerEnabled ? { Task { await refreshCredits(resetPages: true) } } : nil,
            isRefreshing: accountService.isLoadingBalance || accountService.isLoadingUsage || isLoadingLedger,
            utilities: {
                SettingsIconButton("chart.bar.xaxis", help: "Account details") {
                    withAnimation(theme.motion.quick) { showRouterUsageCenter = true }
                }
                .disabled(!routerEnabled)
            },
            primary: {
                SettingsButton(.primary, "Add Credits", icon: "creditcard.fill") {
                    showTopUpSheet = true
                }
                .disabled(!canAddCredits)
            }
        )
    }

    private var identityRequiredCard: some View {
        SettingsCallout(
            icon: "person.badge.key.fill",
            title: "Set up your Osaurus Identity",
            message:
                "The router uses your identity master key as your billing account. Create or restore an identity before adding credits or calling Osaurus models.",
            tone: .warning
        ) {
            SettingsButton(.secondary, "Open Identity", size: .compact) {
                ManagementStateManager.shared.selectedTab = .identity
            }
        }
    }

    // MARK: - Router master switch

    /// Always renders, below everything else: turning the router off routes
    /// through a confirmation, turning it back on is a single tap.
    /// The master switch for everything on this page. While it is off the
    /// wallet cards are hidden and the callout explains what that means.
    private var routerSection: some View {
        SettingsSection(title: "Osaurus Router") {
            SettingsToggle(
                title: "Use Osaurus Router",
                description:
                    "Lets Osaurus transact on your behalf - cloud models, provider load-balancing, and future routed services; requests spend credits. Keeping it on helps support Osaurus development - thank you.",
                anchorId: "credits.router",
                isOn: routerToggleBinding
            )
            if !routerEnabled {
                routerOffCard
            }
        }
    }

    /// Drives the router switch. Enabling is immediate; disabling defers to the
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
        SettingsCallout(
            icon: "bolt.slash.fill",
            title: "Osaurus Router is off",
            message:
                "Osaurus is running fully local and free. Cloud models routed through Osaurus are hidden, and no requests are sent to Osaurus servers. Turn it back on whenever you like."
        )
    }

    /// Same language as the composer wallet panel (monospaced hero balance,
    /// "Available balance" microcopy) scaled up for the page.
    private var balanceCard: some View {
        SettingsSection(title: "Wallet") {
            if displayedFrozen {
                StatusChip(L("Paused"), tone: .warning, icon: "pause.circle.fill")
            } else if OsaurusIdentity.existsCached() {
                StatusChip(L("Active"), tone: .success, icon: "checkmark.circle.fill")
            }
        } content: {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                    HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                        Text(verbatim: displayedBalance)
                            .catalogTypography(.heading, theme: theme, fallback: SettingsFont.detailTitle.monospacedDigit())
                            .foregroundColor(
                                displayedFrozen ? theme.status.warning.foreground : theme.text.primary
                            )
                            .contentTransition(.numericText())
                            .fixedSize(horizontal: false, vertical: true)
                        Text("credits", bundle: .module)
                            .catalogTypography(.caption, theme: theme, fallback: SettingsFont.rowTitle)
                            .foregroundColor(theme.text.secondary)
                    }
                    if displayedLoading {
                        SettingsSpinner()
                    }
                }
                Group {
                    if displayedFrozen {
                        Text("Account paused - add credits to resume.", bundle: .module)
                    } else {
                        Text("Available balance", bundle: .module)
                    }
                }
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                Text(
                    "Credits let Osaurus transact on your behalf - cloud model access today, with more routed services to come.",
                    bundle: .module
                )
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, theme.space.s6)
            }

            SettingsRow(title: "Minimum top-up is $5.00", description: "") {
                SettingsButton(
                    .primary,
                    "Add Credits",
                    icon: "creditcard.fill",
                    isLoading: accountService.isCreatingCheckout,
                    size: .compact
                ) {
                    showTopUpSheet = true
                }
                .disabled(!OsaurusIdentity.existsCached() || accountService.isCreatingCheckout)
            }

            if let error = displayedError, !error.isEmpty {
                Text(error)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.status.error.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Web search

    /// Premium web search billing: search credit balances, the auto-pay
    /// switch, and the graceful fallback state when credits ran out. The
    /// Premium Search on/off switch itself lives only on Web Search.
    private var webSearchCard: some View {
        SettingsSection(
            title: "Web Search",
            subtitle:
                "Premium search runs the `web_search` tool through Osaurus - better results with zero setup. Search credits cover requests first; after that, requests bill this wallet. If credits run out, search continues on the built-in sources automatically."
        ) {
            if accountService.webSearchNeedsTopUp {
                StatusChip(L("Using built-in sources"), tone: .warning, icon: "exclamationmark.circle.fill")
            } else if searchManager.hostedSearchEnabled {
                StatusChip(L("Premium"), tone: .accent, icon: "magnifyingglass.circle.fill")
            }
        } content: {
            SettingsLinkRow(
                title: "Premium Search",
                description: searchManager.hostedSearchEnabled
                    ? "On. Searches go through Osaurus first."
                    : "Off. Searches use your own providers and the built-in sources.",
                icon: "arrow.right",
                actionTitle: "Manage in Web Search"
            ) {
                SettingsHighlightCoordinator.shared.request("search.premium")
                ManagementStateManager.shared.selectedTab = .search
            }

            if searchManager.hostedSearchEnabled {
                if accountService.webSearchNeedsTopUp {
                    Label {
                        Text(
                            "Premium search ran out of credits and is quietly using the built-in sources. Add credits to resume - nothing else to reset.",
                            bundle: .module
                        )
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .glyphSize(.micro)
                            .foregroundColor(theme.status.warning.foreground)
                    }
                }

                if let grants = accountService.webSettings?.grants {
                    HStack(spacing: theme.space.s8) {
                        if let search = grants.search, search.includedTotal > 0 {
                            grantMeter(
                                title: L("Search credits"),
                                allowance: search,
                                icon: "magnifyingglass"
                            )
                        }
                        if let contents = grants.contents, contents.includedTotal > 0 {
                            grantMeter(
                                title: L("Extract credits"),
                                allowance: contents,
                                icon: "doc.text.magnifyingglass"
                            )
                        }
                        if (grants.search?.includedTotal ?? 0) == 0
                            && (grants.contents?.includedTotal ?? 0) == 0
                        {
                            Text(
                                "Searches bill your balance at cost.",
                                bundle: .module
                            )
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                        }
                        Spacer()
                    }
                }

                if let settings = accountService.webSettings {
                    SettingsToggle(
                        title: "Use Osaurus Balance When Search Credits Run Out",
                        description:
                            "Off means premium search stops at your remaining credits; everything else uses the built-in sources.",
                        isOn: Binding(
                            get: { settings.autoPayEnabled },
                            set: { newValue in
                                Task { await accountService.setWebAutoPay(newValue) }
                            }
                        )
                    )
                    .disabled(accountService.isUpdatingWebSettings)
                }
            }
        }
    }

    /// Remaining-credit balance for one bucket, styled like the wallet's
    /// dollar balance — a single number, not a coupon-style "X of Y" counter.
    /// Credits never refill, so an exhausted bucket reads as spent rather
    /// than erroring.
    private func grantMeter(
        title: String,
        allowance: OsaurusRouterWebAllowance,
        icon: String
    ) -> some View {
        let exhausted = allowance.remainingTotal <= 0
        return HStack(spacing: theme.space.s8) {
            Image(systemName: icon)
                .glyphSize(.footnote, weight: .semibold)
                .foregroundColor(exhausted ? theme.text.tertiary : theme.text.link)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: title)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                Text(verbatim: "\(allowance.remainingTotal)")
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(exhausted ? theme.text.tertiary : theme.text.primary)
            }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s6)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .fill(exhausted ? theme.surface.hover : theme.status.info.background)
        )
    }

    // MARK: - Credits activity

    private var activityCard: some View {
        // Build the merged timeline once per render. It re-projects the whole
        // loaded history (ledger matching + date parsing), so reading the
        // computed property repeatedly from body hung the main thread.
        let timeline = mergedTimeline
        let timelineCount = timeline.count
        let entries = Self.page(of: timeline, pageIndex: timelinePageIndex)
        return SettingsSection(
            title: "Recent Activity",
            subtitle:
                "Model requests and balance changes, newest first. Open the chat or Insights when this Mac has the matching copy."
        ) {
            SettingsButton(
                .secondary,
                "Export diagnostics",
                icon: "square.and.arrow.up",
                isLoading: isExportingDiagnostics,
                size: .compact
            ) {
                exportDiagnostics()
            }
            .disabled(isExportingDiagnostics || ledgerTotalCount == 0)
        } content: {
            if entries.isEmpty {
                SettingsEmptyState(
                    inline: "clock.arrow.circlepath",
                    title: "No activity yet",
                    hint:
                        "When you add credits or use an Osaurus Router model, it shows up here with its amount. If this Mac made a request, you can jump to the chat or Insights.",
                    isLoading: isLoadingCurrentActivity
                )
            } else {
                activityList(entries)
                activityPaginationControls(timelineCount: timelineCount, pageCount: entries.count)
            }

            if let diagnosticsMessage {
                Text(diagnosticsMessage)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func activityList(_ entries: [CreditsTimelineEntry]) -> some View {
        VStack(spacing: theme.space.s4) {
            ForEach(entries) { entry in
                Group {
                    switch entry {
                    case .request(let row, _):
                        activityRow(row)
                    case .transaction(let row):
                        transactionRow(row)
                    case .webUsage(let row):
                        webUsageRow(row)
                    }
                }
                .background(theme.surface.raised, in: RoundedRectangle(cornerRadius: theme.radius.medium))
            }
        }
    }

    private func activityPaginationControls(timelineCount: Int, pageCount: Int) -> some View {
        HStack(spacing: theme.space.s8) {
            Text(verbatim: timelineRangeLabel(timelineCount: timelineCount, pageCount: pageCount))
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                .foregroundColor(theme.text.secondary)

            Spacer()

            SettingsButton(.secondary, "Previous", icon: "chevron.left", size: .compact) {
                goToPreviousActivityPage()
            }
            .disabled(!canGoToPreviousActivityPage || isLoadingCurrentActivity)

            SettingsButton(
                .secondary,
                canLoadMoreFromServer(timelineCount: timelineCount) ? "Load more" : "Next",
                icon: canLoadMoreFromServer(timelineCount: timelineCount) ? "arrow.down.circle" : "chevron.right",
                isLoading: isLoadingCurrentActivity,
                size: .compact
            ) {
                goToNextTimelinePage()
            }
            .disabled(!canGoToNextActivityPage(timelineCount: timelineCount) || isLoadingCurrentActivity)
        }
    }

    /// The full merged timeline: billed model requests (with ledger matching
    /// and chat/Insights references) interleaved with wallet-visible ledger
    /// transactions (top-ups, grants, refunds — later agent purchases), newest
    /// first. Uses the same visibility filter as the composer wallet panel so
    /// per-request debit mirrors never double-count spend.
    private var mergedTimeline: [CreditsTimelineEntry] {
        let usageItems = accountService.usage
        let requestRows = CreditsActivityProjector(
            hasInsightsLogForRequestId: { insightsService.hasLog(requestId: $0) },
            hasInsightsLogForTurnId: { insightsService.hasLog(turnId: $0) }
        )
        .rows(usageItems: usageItems, ledgerEntries: ledgerEntries)
        let requests = zip(requestRows, usageItems).map { row, item in
            CreditsTimelineEntry.request(
                row,
                date: CreditsActivityProjector.date(fromRouterTimestamp: item.createdAt)
            )
        }
        let transactions = accountService.transactions
            .filter(WalletActivityRow.isWalletVisible)
            .map { CreditsTimelineEntry.transaction(WalletActivityRow(transaction: $0)) }
        let webRequests = accountService.webUsage
            .map { CreditsTimelineEntry.webUsage(WalletActivityRow(webUsage: $0)) }
        return (requests + transactions + webRequests)
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private static func page(of timeline: [CreditsTimelineEntry], pageIndex: Int) -> [CreditsTimelineEntry] {
        let start = pageIndex * activityPageSize
        guard start < timeline.count else { return [] }
        let end = min(start + activityPageSize, timeline.count)
        return Array(timeline[start ..< end])
    }

    private var isLoadingCurrentActivity: Bool {
        accountService.isLoadingUsage || accountService.isLoadingTransactions || isLoadingLedger
    }

    private var canGoToPreviousActivityPage: Bool {
        timelinePageIndex > 0
    }

    private func canGoToNextActivityPage(timelineCount: Int) -> Bool {
        let nextStart = (timelinePageIndex + 1) * Self.activityPageSize
        return nextStart < timelineCount || hasMoreOnServer
    }

    private var hasMoreOnServer: Bool {
        accountService.nextUsageCursor != nil || accountService.nextTransactionsCursor != nil
    }

    /// True only when the next page isn't already loaded but the server says more
    /// rows exist — i.e. the advance button should fetch instead of just paging.
    private func canLoadMoreFromServer(timelineCount: Int) -> Bool {
        let nextStart = (timelinePageIndex + 1) * Self.activityPageSize
        return nextStart >= timelineCount && hasMoreOnServer
    }

    /// Honest range over what we've actually loaded. The router never returns a
    /// true total, so "loaded" makes clear more may exist behind "Load more"
    /// rather than implying a misleading grand total.
    private func timelineRangeLabel(timelineCount: Int, pageCount: Int) -> String {
        let loaded = timelineCount
        guard loaded > 0 else { return "" }
        let start = timelinePageIndex * Self.activityPageSize
        let end = min(start + pageCount, loaded)
        if hasMoreOnServer {
            return L("Showing \(start + 1)-\(end) of \(loaded) loaded")
        }
        return L("Showing \(start + 1)-\(end) of \(loaded)")
    }

    private func activityRow(_ row: CreditsActivityRow) -> some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            timelineBadge(
                icon: "sparkles",
                tint: requestBadgeTint(row.stateKind)
            )

            VStack(alignment: .leading, spacing: theme.space.s4) {
                HStack(spacing: theme.space.s8) {
                    modelName(for: row)
                    outcomeBadge(for: row)
                }

                if !row.metadataLine.isEmpty {
                    Text(verbatim: row.metadataLine)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: theme.space.s12) {
                    Text(verbatim: row.tokensLine)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                    referenceLinks(for: row)
                }
            }

            Spacer(minLength: 0)

            Text(verbatim: signedCostLabel(row.costMicro))
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.mono.monospacedDigit())
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(theme.text.secondary)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
    }

    /// A balance-changing ledger transaction (top-up, grant, refund — later
    /// agent purchases): the wallet panel's row vocabulary at timeline scale.
    private func transactionRow(_ row: WalletActivityRow) -> some View {
        HStack(alignment: .center, spacing: theme.space.s12) {
            timelineBadge(
                icon: row.isCredit ? "arrow.down.left" : "arrow.up.right",
                tint: row.isCredit ? theme.status.success.foreground : theme.text.secondary
            )

            VStack(alignment: .leading, spacing: theme.space.s4) {
                Text(LocalizedStringKey(row.title), bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                if let date = row.date {
                    Text(verbatim: date.formatted(date: .abbreviated, time: .shortened))
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                }
            }

            Spacer(minLength: 0)

            Text(verbatim: row.amountLabel)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.mono.monospacedDigit())
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(row.isCredit ? theme.status.success.foreground : theme.text.secondary)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
    }

    /// A billed hosted web search/contents request. The premium (accent)
    /// family distinguishes it from model spend — full strength when the
    /// request used a search credit, softened when it billed the balance.
    private func webUsageRow(_ row: WalletActivityRow) -> some View {
        HStack(alignment: .center, spacing: theme.space.s12) {
            timelineBadge(
                icon: "magnifyingglass",
                tint: webUsageTint(row)
            )

            VStack(alignment: .leading, spacing: theme.space.s4) {
                HStack(spacing: theme.space.s8) {
                    Text(LocalizedStringKey(row.title), bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.sectionTitle)
                        .foregroundColor(theme.text.primary)
                    StatusChip(row.isIncludedWebRequest ? L("Credit") : L("Premium"), tint: webUsageTint(row))
                        .fixedSize()
                }
                if let date = row.date {
                    Text(verbatim: date.formatted(date: .abbreviated, time: .shortened))
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                }
            }

            Spacer(minLength: 0)

            Group {
                if row.isIncludedWebRequest {
                    Text("Included", bundle: .module)
                } else {
                    Text(verbatim: row.amountLabel)
                }
            }
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.mono.monospacedDigit())
                .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(theme.text.secondary)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
    }

    private func webUsageTint(_ row: WalletActivityRow) -> Color {
        switch row.stateKind {
        case .warning: return theme.status.warning.foreground
        case .error: return theme.status.error.foreground
        case .success, .secondary:
            return row.isIncludedWebRequest ? theme.status.info.foreground : theme.status.info.foreground
        }
    }

    /// Tinted circular icon badge shared by both timeline row types, matching
    /// the composer wallet panel's row treatment.
    private func timelineBadge(icon: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(theme.wash(behind: tint))
            Image(systemName: icon)
                .glyphSize(.micro, weight: .semibold)
                .foregroundColor(tint)
        }
        .frame(width: 26, height: 26)
    }

    /// Spends stay neutral (the outcome pill already carries status); only
    /// attention states color the badge, mirroring the wallet panel.
    private func requestBadgeTint(_ kind: CreditsActivityStateKind) -> Color {
        switch kind {
        case .warning: return theme.status.warning.foreground
        case .error: return theme.status.error.foreground
        case .success, .secondary: return theme.text.secondary
        }
    }

    /// Request costs render signed ("-13 credits") so the timeline reads like
    /// a statement next to "+50,000 credits" transaction rows.
    private func signedCostLabel(_ costMicro: String) -> String {
        let formatted = OsaurusRouter.formatMicroAsCredits(costMicro)
        if (Int64(costMicro) ?? 0) > 0 {
            return "-" + formatted
        }
        return formatted
    }

    @ViewBuilder
    private func modelName(for row: CreditsActivityRow) -> some View {
        if let name = row.modelDisplay {
            Text(verbatim: name)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.sectionTitle)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("Unknown model", bundle: .module)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.sectionTitle)
                .foregroundColor(theme.text.secondary)
                .lineLimit(1)
        }
    }

    private func outcomeBadge(for row: CreditsActivityRow) -> some View {
        StatusChip(
            [row.stateLabel, row.stateDetail].compactMap { $0 }.filter { !$0.isEmpty }.map { LCached($0) }
                .joined(separator: " · "),
            tint: stateColor(row.stateKind)
        )
            .fixedSize()
    }

    @ViewBuilder
    private func referenceLinks(for row: CreditsActivityRow) -> some View {
        HStack(spacing: theme.space.s12) {
            if let reference = row.localReference {
                Button {
                    openLocalReference(reference)
                } label: {
                    Label(localized: "Chat", systemImage: "arrow.up.right.square")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .componentInspectionText(51, role: .caption, fallback: .footnote, weight: 500, theme: theme)
                .foregroundColor(theme.text.link)
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
                .componentInspectionText(51, role: .caption, fallback: .footnote, weight: 500, theme: theme)
                .foregroundColor(theme.text.link)
                .help(reference.insightsHelpText)
            }
        }
    }

    private func stateColor(_ kind: CreditsActivityStateKind) -> Color {
        switch kind {
        case .success:
            return theme.status.success.foreground
        case .warning:
            return theme.status.warning.foreground
        case .error:
            return theme.status.error.foreground
        case .secondary:
            return theme.text.secondary
        }
    }

    private func goToPreviousActivityPage() {
        timelinePageIndex = max(0, timelinePageIndex - 1)
    }

    private func goToNextTimelinePage() {
        let nextIndex = timelinePageIndex + 1
        let nextStart = nextIndex * Self.activityPageSize
        if nextStart < mergedTimeline.count {
            timelinePageIndex = nextIndex
            return
        }
        guard hasMoreOnServer else { return }
        Task {
            let previousCount = mergedTimeline.count
            if accountService.nextUsageCursor != nil {
                await accountService.loadMoreUsage()
            }
            if accountService.nextTransactionsCursor != nil {
                await accountService.loadMoreTransactions()
            }
            if mergedTimeline.count > previousCount {
                await reloadLedger()
                timelinePageIndex = nextIndex
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

    // MARK: - Data loading

    private func refreshCredits(resetPages: Bool) async {
        if resetPages {
            timelinePageIndex = 0
        }
        await accountService.refreshAll()
        // Transactions feed the merged timeline (top-ups, grants, refunds)
        // alongside the usage rows `refreshAll` already fetched.
        await accountService.refreshTransactions(reset: true)
        // Web search settings (grants + auto-pay) and billed web requests
        // feed the Web search card and the merged timeline.
        await accountService.refreshWebSettings()
        await accountService.refreshWebUsage(reset: true)
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
            let count = diagnostics.entries.count
            diagnosticsMessage = count == 1
                ? L("Exported 1 row to \(url.lastPathComponent).")
                : L("Exported \(count) rows to \(url.lastPathComponent).")
        } catch {
            diagnosticsMessage = error.localizedDescription
        }
    }

}

/// One row in the merged Credits timeline: a billed model request (projected
/// with ledger matching and chat/Insights references) or a balance-changing
/// ledger transaction reusing the composer wallet panel's row model.
private enum CreditsTimelineEntry: Identifiable {
    case request(CreditsActivityRow, date: Date?)
    case transaction(WalletActivityRow)
    /// A billed hosted web search/contents request (metadata-only).
    case webUsage(WalletActivityRow)

    var id: String {
        switch self {
        case .request(let row, _): return row.id
        case .transaction(let row): return row.id
        case .webUsage(let row): return row.id
        }
    }

    var date: Date? {
        switch self {
        case .request(_, let date): return date
        case .transaction(let row): return row.date
        case .webUsage(let row): return row.date
        }
    }
}

extension CreditsView {
    static func inspectionBalances(_ state: String, theme: any ThemeProtocol) -> some View {
        var view = CreditsView()
        view.inspectionTheme = theme
        view.inspectionBalance = InspectorWalletBalance(value: "12,345.67", frozen: state == "Frozen", loading: state == "Loading", error: state == "Error" ? "Local account error display." : nil)
        return VStack(alignment: .leading, spacing: theme.space.s12) {
            view.balanceCard
            HStack {
                view.grantMeter(title: "Search credits", allowance: OsaurusRouterWebAllowance(includedTotal: 100, usedTotal: 23, remainingTotal: 77), icon: "magnifyingglass")
                view.grantMeter(title: "Extract credits", allowance: OsaurusRouterWebAllowance(includedTotal: 100, usedTotal: 100, remainingTotal: 0), icon: "doc.text.magnifyingglass")
            }
        }.environment(\.theme, view.theme).allowsHitTesting(false)
    }
    /// Original populated activity-row renderer without mounting the account page's tasks.
    static func inspectionActivityRows(theme: any ThemeProtocol) -> some View {
        var view = CreditsView()
        view.inspectionTheme = theme
        let rows = ["completed", "failed", "pending"].enumerated().map { index, status in
            CreditsActivityRow(usage: OsaurusRouterUsageItem(id: "inspector-\(index)", requestId: nil,
                model: "Local display model", provider: "Local sample", inputTokens: 1234, outputTokens: 56,
                costMicro: "1234", status: status, tokenSource: "provider", createdAt: "2026-10-22T12:00:00Z"),
                match: nil, insightsReference: nil)
        }
        return view.activityList(rows.map { .request($0, date: nil) })
            .environment(\.theme, view.theme)
            .allowsHitTesting(false)
    }
}

struct InspectorWalletBalance {
    var value: String
    var frozen: Bool
    var loading: Bool
    var error: String?
}
