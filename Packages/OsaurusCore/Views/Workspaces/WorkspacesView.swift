//
//  WorkspacesView.swift
//  osaurus
//
//  Osaurus Workspaces management, built on the Agents tab's component
//  library so both tabs read as one product: `SettingsPageHeader` +
//  a `LazyVGrid` of `WorkspaceCard`s (the `AgentCard` recipe), the shared
//  `SettingsEmptyState` for onboarding and gates, `InlineBanner` for staged
//  deep links and errors, a bottom `ThemedToastView` for success, and a
//  full-pane `WorkspaceDetailView` (the `AgentDetailView` shell) on drill-in.
//

import SwiftUI

struct WorkspacesView: View {
    /// Same grid ↔ detail cross-fade the Agents tab uses.
    @MainActor fileprivate static var navTransition: Animation { ThemeManager.shared.currentTheme.motion.quick }

    /// Two-column grid matching `AgentsView.gridColumns`.
    @MainActor fileprivate static var gridColumns: [GridItem] {
        let gap = ThemeManager.shared.currentTheme.libraryGridGap
        return [GridItem(.flexible(minimum: 300), spacing: gap), GridItem(.flexible(minimum: 300), spacing: gap)]
    }

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var service = WorkspacesService.shared
    @ObservedObject private var providerManager = RemoteProviderManager.shared
    private var theme: any ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    /// Manual invite-code entry (deeplink didn't open, or the user is pasting
    /// a code from a chat message).
    @State private var showManualJoinSheet = false
    @State private var showCreateSheet = false
    /// Non-nil shows the detail pane for that workspace in place of the list.
    @State private var openWorkspace: OsaurusRouterWorkspaceSummary?
    /// Detail tab to land on when `openWorkspace` is set from a card menu.
    @State private var openWorkspaceTab: WorkspaceDetailView.Tab = .overview
    /// Card-level Leave/Delete awaiting confirmation.
    @State private var pendingCardDestruction: OsaurusRouterWorkspaceSummary?
    @State private var successMessage: String?

    private var routerEnabled: Bool { providerManager.isOsaurusRouterEnabled }
    private var identityReady: Bool { OsaurusIdentity.existsCached() }
    /// Everything the router needs for any wallet-signed Workspaces call — a
    /// wallet is the only identity Workspaces requires.
    private var canUseWorkspaces: Bool { routerEnabled && identityReady }

    /// Confirm sheets for deeplinked actions. Presented automatically the
    /// moment a pending action exists and every gate has cleared; cancelling
    /// keeps the pending code (banner) so nothing is lost until the user
    /// explicitly discards it.
    @State private var showDeeplinkActivateSheet = false
    @State private var showDeeplinkJoinSheet = false

    private func presentDeeplinkSheetsIfReady() {
        guard canUseWorkspaces else { return }
        guard service.pendingActivation != nil || service.pendingJoin != nil else { return }
        if openWorkspace != nil {
            withAnimation(Self.navTransition) { openWorkspace = nil }
            service.clearSelection()
        }
        // One at a time; activation first (it creates the workspace the user paid
        // for), the join banner stays visible behind it.
        if service.pendingActivation != nil {
            showDeeplinkActivateSheet = true
        } else if service.pendingJoin != nil {
            showDeeplinkJoinSheet = true
        }
    }

    var body: some View {
        ZStack {
            if openWorkspace == nil {
                listPane
                    .transition(.opacity)
            }

            if let workspace = openWorkspace {
                WorkspaceDetailView(
                    workspace: workspace,
                    initialTab: openWorkspaceTab,
                    onBack: {
                        withAnimation(Self.navTransition) { openWorkspace = nil }
                        service.clearSelection()
                        Task { await service.refreshWorkspaces() }
                    },
                    showSuccess: showSuccess
                )
                .id(workspace.id)
                .transition(.opacity)
            }

            if let message = successMessage {
                VStack {
                    Spacer()
                    ThemedToastView(message, type: .success)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, theme.space.s16)
                }
                .zIndex(100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
        .task {
            await service.refreshWorkspaces()
            // Opening the tab is a natural moment to make sure every shared
            // agent across the user's workspaces is paired (throttled).
            await WorkspaceAgentConnectService.shared.sweepWorkspaces()
        }
        .onAppear {
            withAnimation(theme.motion.standard.delay(0.05)) {
                hasAppeared = true
            }
            presentDeeplinkSheetsIfReady()
        }
        .onChange(of: service.pendingActivation) { _, pending in
            if pending == nil {
                showDeeplinkActivateSheet = false
            } else {
                presentDeeplinkSheetsIfReady()
            }
        }
        .onChange(of: service.pendingJoin) { _, pending in
            if pending == nil {
                showDeeplinkJoinSheet = false
            } else {
                presentDeeplinkSheetsIfReady()
            }
        }
        .onChange(of: canUseWorkspaces) { _, ready in
            // Gates cleared (identity restored / router on) while a deep link
            // was waiting: pick up where it left off.
            if ready {
                presentDeeplinkSheetsIfReady()
            }
        }
        .onReceive(service.$selectedWorkspaceId) { selected in
            // A `@Published` publisher fires before the property stores the
            // new value, so pass the delivered id instead of re-reading it.
            applyPendingSelection(selected: selected)
        }
        .onChange(of: service.workspaces) { _, _ in
            // The list can load after a deep link selected a workspace.
            applyPendingSelection(selected: service.selectedWorkspaceId)
        }
        .onChange(of: service.deepLinkTab) { _, tab in
            // A search result for the workspace that's already selected but
            // closed: the selection doesn't change, so open it here.
            if tab != nil { applyPendingSelection(selected: service.selectedWorkspaceId) }
        }
        .sheet(isPresented: $showDeeplinkActivateSheet) {
            ActivateWorkspaceSheet(pending: service.pendingActivation) { detail in
                openWorkspace(from: detail)
            }
            .environment(\.theme, theme)
        }
        .sheet(isPresented: $showDeeplinkJoinSheet) {
            JoinWorkspaceSheet(pending: service.pendingJoin) { detail in
                openWorkspace(from: detail)
            }
            .environment(\.theme, theme)
        }
        .sheet(isPresented: $showManualJoinSheet) {
            JoinWorkspaceSheet(pending: nil) { detail in
                openWorkspace(from: detail)
            }
            .environment(\.theme, theme)
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateWorkspaceSheet { detail in
                openWorkspace(from: detail)
            }
            .environment(\.theme, theme)
        }
        .themedAlert(
            pendingCardDestruction.map { $0.typedRole == .owner ? L("Delete Workspace?") : L("Leave Workspace?") }
                ?? "",
            isPresented: Binding(
                get: { pendingCardDestruction != nil },
                set: { if !$0 { pendingCardDestruction = nil } }
            ),
            message: pendingCardDestruction.map(cardDestructionMessage),
            primaryButton: .destructive(
                pendingCardDestruction?.typedRole == .owner ? L("Delete") : L("Leave")
            ) {
                guard let workspace = pendingCardDestruction else { return }
                pendingCardDestruction = nil
                Task { await performCardDestruction(workspace) }
            },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    /// Land on a freshly created/activated/joined workspace. The service
    /// already refreshed the list and selected the detail; we just need the
    /// summary row to drive the drill-in.
    private func openWorkspace(from detail: OsaurusRouterWorkspaceDetail) {
        let summary = service.workspaces.first { $0.id == detail.id } ?? detail.asSummary
        open(summary, tab: .overview)
    }

    private func open(_ workspace: OsaurusRouterWorkspaceSummary, tab: WorkspaceDetailView.Tab) {
        openWorkspaceTab = tab
        withAnimation(Self.navTransition) { openWorkspace = workspace }
        Task { await service.selectWorkspace(id: workspace.id) }
    }

    /// Deep link from the chat sidebar / Agents tab: `selectWorkspace(id:)`
    /// ran before this tab appeared (or before the list loaded), so land on
    /// that workspace's detail as soon as its summary is known.
    private func applyPendingSelection(selected: String?) {
        guard let selected,
            openWorkspace?.id != selected,
            let summary = service.workspaces.first(where: { $0.id == selected })
        else { return }
        // The detail view consumes `deepLinkTab` itself (it also handles the
        // already-open case, where this method doesn't run).
        openWorkspaceTab = service.deepLinkTab ?? .overview
        withAnimation(Self.navTransition) { openWorkspace = summary }
    }

    // MARK: - Success toast

    private func showSuccess(_ message: String) {
        withAnimation(theme.motion.springAnimation) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.motion.quick) {
                successMessage = nil
            }
        }
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: theme.space.s0) {
            headerView
                .settingsHeaderEntrance(hasAppeared: hasAppeared)
                .settingsLandingAnchor("workspaces.overview")

            content
                .opacity(hasAppeared ? 1 : 0)
        }
    }

    private var headerView: some View {
        SettingsPageHeader(
            title: "Workspaces",
            subtitle: L(
                "Invite your team and share agents. Teammates chat with shared agents from their own Osaurus."
            ),
            count: service.workspaces.count,
            onRefresh: canUseWorkspaces ? { Task { await service.refreshWorkspaces() } } : nil,
            isRefreshing: service.isLoadingWorkspaces,
            secondary: {
                SettingsButton(.secondary, "Join…", icon: "person.badge.plus", help: "Join a workspace with an invite code") {
                    showManualJoinSheet = true
                }
                .disabled(!canUseWorkspaces)
            },
            primary: {
                SettingsButton(.primary, "New Workspace", icon: "plus", help: "Create a workspace") {
                    showCreateSheet = true
                }
                .disabled(!canUseWorkspaces)
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        if !routerEnabled {
            SettingsEmptyState(
                icon: "bolt.slash.fill",
                title: "Osaurus Router is off",
                subtitle: L(
                    "Workspaces run on the Osaurus Router. Turn it on in Wallet & Credits to create a workspace, join through an invite link, and share agents."
                ),
                examples: [],
                primaryAction: .init(
                    title: L("Open Wallet & Credits"),
                    icon: "bolt.fill",
                    handler: { ManagementStateManager.shared.selectedTab = .credits }
                ),
                hasAppeared: hasAppeared
            )
        } else if !identityReady {
            SettingsEmptyState(
                icon: "person.badge.key.fill",
                title: "Set up your Osaurus ID",
                subtitle: L(
                    "Workspaces are tied to your Osaurus ID — it signs every workspace action and is how teammates recognize you. Create or restore it first."
                ),
                examples: [],
                primaryAction: .init(
                    title: L("Open Osaurus ID"),
                    icon: "person.badge.key.fill",
                    handler: { ManagementStateManager.shared.selectedTab = .identity }
                ),
                hasAppeared: hasAppeared
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    SettingsPageContent {
                        banners

                        // Skeletons stand in only until the first list arrives.
                        // A later refresh of an empty account must not flash
                        // them over the empty state.
                        if service.isLoadingWorkspaces && !service.hasLoadedWorkspaces {
                            loadingGrid
                        } else if service.workspaces.isEmpty {
                            emptyState
                        } else {
                            workspaceGrid
                        }
                    }
                }
                .settingsLandingScroll(proxy)
            }
        }
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        if let lastError = service.lastError {
            InlineBanner(kind: .error, title: lastError) { service.lastError = nil }
        }

        if case .checkout(_, let name, _) = service.pendingConfirmation {
            InlineBanner(
                kind: .info,
                title: String(format: L("Finishing checkout for “%@”"), name),
                caption: L(
                    "Complete the payment in your browser. The workspace appears here as soon as Stripe confirms — usually within a few seconds of returning to Osaurus."
                ),
                icon: "creditcard",
                action: .init(title: L("Check now"), icon: "arrow.clockwise") {
                    Task { await service.refreshWorkspaces() }
                },
                secondaryAction: .init(title: L("Stop waiting")) {
                    service.dismissSubscriptionWait()
                }
            )
        }

        if let billing = service.billing, let subscription = billing.subscription,
            subscription.isPastDue || (subscription.isTrialing && subscription.trialEndsAt != nil)
                || (subscription.cancelAtPeriodEnd == true && subscription.isActive)
        {
            billingStrip(subscription)
        }

        if service.pendingActivation != nil {
            InlineBanner(
                kind: .action,
                title: L("Workspace ready to activate"),
                caption: service.pendingActivation?.planLabel.map {
                    String(format: L("%@ plan from osaurus.ai — name your workspace to finish."), $0)
                } ?? L("From osaurus.ai — name your workspace to finish."),
                icon: "checkmark.seal.fill",
                action: .init(title: L("Activate"), icon: "sparkles") {
                    showDeeplinkActivateSheet = true
                },
                secondaryAction: .init(title: L("Discard")) {
                    service.dismissPendingActivation()
                }
            )
        }

        if service.pendingJoin != nil {
            InlineBanner(
                kind: .action,
                title: L("Workspace invite ready"),
                caption: L("A teammate shared an invite link with you. Join to see the workspace."),
                icon: "person.badge.plus",
                action: .init(title: L("Join"), icon: "arrow.right") {
                    showDeeplinkJoinSheet = true
                },
                secondaryAction: .init(title: L("Discard")) {
                    service.dismissPendingJoin()
                }
            )
            .settingsLandingAnchor("workspaces.invites")
        }
    }

    /// Account-level subscription state worth a line above the grid: the free
    /// trial (with its conversion date and price), a failed payment, or a
    /// subscription winding down. A healthy paid subscription stays quiet.
    @ViewBuilder
    private func billingStrip(_ subscription: OsaurusRouterWorkspaceBillingSummary.Subscription) -> some View {
        let portalAction = InlineBanner.Action(title: L("Manage billing"), icon: "arrow.up.right.square") {
            Task { await service.openBillingPortal() }
        }
        if subscription.isPastDue {
            InlineBanner(
                kind: .warning,
                title: L("Payment failed"),
                caption: L(
                    "Your workspaces are paused until the payment method is fixed. Update your card in the billing portal."
                ),
                icon: "exclamationmark.circle.fill",
                action: portalAction
            )
        } else if subscription.isTrialing, let raw = subscription.trialEndsAt,
            let date = WorkspacesFormatting.date(raw)
        {
            InlineBanner(
                kind: .info,
                title: L("Free trial"),
                caption: subscription.price?.displayLabel.map {
                    String(format: L("Converts to %@ per workspace on %@. Cancel anytime in the billing portal."), $0, date)
                } ?? String(format: L("Converts to a paid subscription on %@. Cancel anytime in the billing portal."), date),
                icon: "sparkles",
                action: portalAction
            )
        } else if subscription.cancelAtPeriodEnd == true, let raw = subscription.currentPeriodEnd,
            let date = WorkspacesFormatting.date(raw)
        {
            InlineBanner(
                kind: .info,
                title: String(format: L("Subscription ends %@"), date),
                caption: L(
                    "No more charges. Your paid time keeps running until then; creating a workspace before that date resumes the subscription."
                ),
                icon: "calendar.badge.clock",
                action: portalAction
            )
        }
    }

    // MARK: - Grid / empty / loading

    private var workspaceGrid: some View {
        LazyVGrid(columns: Self.gridColumns, spacing: theme.libraryGridGap) {
            ForEach(Array(service.workspaces.enumerated()), id: \.element.id) { index, workspace in
                WorkspaceCard(
                    workspace: workspace,
                    ownerIsTrialing: service.isTrialing,
                    animationDelay: Double(index) * 0.05,
                    hasAppeared: hasAppeared,
                    onSelect: { open(workspace, tab: .overview) },
                    onInvite: { open(workspace, tab: .members) },
                    onShareAgent: { open(workspace, tab: .sharedAgents) },
                    onLeaveOrDelete: { pendingCardDestruction = workspace }
                )
                .gridDiffCell()
            }
        }
        .gridDiffAnimation(token: service.workspaces.map(\.id).joined(separator: ","))
    }

    /// "14-day free trial, then $20/month or $200/year per workspace. Cancel
    /// anytime." from the public plan/prices; falls back to a priceless line
    /// when the router hasn't answered yet. Shown as the footnote beneath the
    /// empty state's buttons, so it reads as the fine print of the call to
    /// action rather than as part of the pitch.
    private var pricingLine: String {
        let prices = service.prices
        // A price label like "$20/month" breaks after the slash under
        // SwiftUI's line breaking, orphaning "month" on the next line. A
        // word joiner after the slash keeps each price on one line.
        func unbreakable(_ label: String) -> String {
            label.replacingOccurrences(of: "/", with: "/\u{2060}")
        }
        let priceText: String? = {
            switch (prices?.monthly?.displayLabel, prices?.yearly?.displayLabel) {
            case (let m?, let y?):
                return String(format: L("%@ or %@ per workspace"), unbreakable(m), unbreakable(y))
            case (let m?, nil): return String(format: L("%@ per workspace"), unbreakable(m))
            case (nil, let y?): return String(format: L("%@ per workspace"), unbreakable(y))
            default: return nil
            }
        }()
        if service.trialEligible, let days = service.trialDays, days > 0 {
            if let priceText {
                return String(format: L("%d-day free trial, then %@. Cancel anytime."), days, priceText)
            }
            return String(format: L("Start with a %d-day free trial. Cancel anytime."), days)
        }
        if let priceText {
            return String(format: L("%@, with shared monthly workspace credits."), priceText)
        }
        return L("Every workspace comes with shared monthly workspace credits.")
    }

    private var emptyState: some View {
        SettingsEmptyState(
            icon: "rectangle.3.group.fill",
            title: "Bring your team in",
            subtitle: L(
                "Create a workspace, share your agents, and invite teammates with a link. They chat with your agents from their own Osaurus."
            ),
            examples: [],
            primaryAction: .init(
                title: service.trialEligible ? L("Start Free Trial") : L("New Workspace"),
                icon: "plus",
                handler: { showCreateSheet = true }
            ),
            secondaryAction: .init(
                title: L("Have an invite code?"),
                icon: "person.badge.plus",
                handler: { showManualJoinSheet = true }
            ),
            hasAppeared: hasAppeared,
            // The interactive five-stage explainer (agents grouped, set up
            // once, handed out, your rules, one bill) stands in for the
            // example cards; it scales to the pane's width.
            content: AnyView(WorkspacesIntroExplainer()),
            compact: true,
            footnote: pricingLine
        )
    }

    private var loadingGrid: some View {
        LazyVGrid(columns: Self.gridColumns, spacing: theme.libraryGridGap) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    HStack(spacing: theme.space.s12) {
                        Circle()
                            .fill(theme.surface.hover)
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: theme.space.s6) {
                            SettingsSkeletonBar(width: 140, height: 12)
                            SettingsSkeletonBar(width: 200, height: 9)
                        }
                        Spacer()
                    }
                    Spacer(minLength: 0)
                    SettingsSkeletonBar(width: 160, height: 9)
                }
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .top)
                .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
                .settingsChrome(.card)
            }
        }
        .redacted(reason: .placeholder)
    }

    // MARK: - Card-level Leave / Delete

    private func cardDestructionMessage(_ workspace: OsaurusRouterWorkspaceSummary) -> String {
        if workspace.typedRole == .owner {
            return workspace.typedSource == .subscription
                ? L(
                    "This removes the workspace for every member, revokes all shared agents and pending invites, and removes it from your subscription."
                )
                : L("This removes the workspace for every member and revokes all shared agents and pending invites.")
        }
        return L("You'll lose access to the workspace's shared agents and workspace credits. Your shared agents are revoked.")
    }

    private func performCardDestruction(_ workspace: OsaurusRouterWorkspaceSummary) async {
        if workspace.typedRole == .owner {
            if await service.deleteWorkspace(id: workspace.id) {
                showSuccess(String(format: L("Deleted “%@”"), workspace.name))
            }
        } else {
            // Self-leave needs our account id from the roster, so load the
            // detail first (the card has no member list).
            await service.selectWorkspace(id: workspace.id)
            guard let me = service.members.first(where: { service.isSelf($0) }) else {
                service.clearSelection()
                service.lastError = L(
                    "Couldn't identify your membership because the member list didn't load. Check your connection, refresh, and try again."
                )
                return
            }
            let left = await service.removeMember(workspaceId: workspace.id, accountId: me.accountId)
            service.clearSelection()
            if left {
                showSuccess(String(format: L("Left “%@”"), workspace.name))
                await service.refreshWorkspaces()
            }
        }
    }
}

// MARK: - Workspace Card

/// Grid card for one workspace: avatar + name + role, a two-line caption
/// slot, a stat strip, and an overflow menu — the same `LibraryCard` as the
/// Agents grid.
private struct WorkspaceCard: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let workspace: OsaurusRouterWorkspaceSummary
    /// The local user's subscription is trialing (only meaningful on cards
    /// they own — a member's card knows nothing about the owner's trial).
    let ownerIsTrialing: Bool
    let animationDelay: Double
    let hasAppeared: Bool
    let onSelect: () -> Void
    let onInvite: () -> Void
    let onShareAgent: () -> Void
    let onLeaveOrDelete: () -> Void

    private var role: OsaurusRouterWorkspaceRole? { workspace.typedRole }
    private var isOwner: Bool { role == .owner }

    var body: some View {
        LibraryCard(
            title: workspace.name,
            subtitle: caption,
            animationDelay: animationDelay,
            hasAppeared: hasAppeared,
            action: onSelect
        ) {
            WorkspaceAvatar(name: workspace.name, size: 36)
        } badges: {
            if let role {
                WorkspaceRoleBadge(role: role)
            }
        } accessory: {
            WorkspaceStatusBadge(
                source: workspace.typedSource,
                active: workspace.isActive,
                trialing: isOwner && ownerIsTrialing
            )
        } content: {
            // Two-line description slot, like the agent card's prompt
            // preview, so card heights line up across the grid.
            LibraryCardPreview(text: descriptionText)
        } footer: {
            LibraryStatRow(stats: statChips)
        } menu: {
            menuItems
        }
    }

    /// "Owned by you" / "You're an admin" — the user's role, so it never
    /// disagrees with the role badge.
    private var caption: String {
        switch workspace.typedRole {
        case .owner: L("Owned by you")
        case .admin: L("You're an admin")
        case .viewer: L("You're a viewer")
        case .member, nil: isOwner ? L("Owned by you") : L("You're a member")
        }
    }

    private var descriptionText: String {
        let members = workspace.membersActive ?? 0
        let agents = workspace.agentsShared ?? 0
        if members <= 1, agents == 0 {
            return isOwner
                ? L("Invite teammates with a link and share an agent to get started.")
                : L("No shared agents yet — they appear here when a teammate shares one.")
        }
        if agents == 0 {
            return L("No shared agents yet. Share one so teammates can chat with it.")
        }
        return agents == 1
            ? L("One shared agent, ready to chat with from the sidebar.")
            : String(format: L("%d shared agents, ready to chat with from the sidebar."), agents)
    }

    @ViewBuilder
    private var menuItems: some View {
        Group {
            Button(action: onSelect) {
                Label {
                    Text("Open", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.right.circle")
                }
            }
            if role == .owner || role == .admin {
                Button(action: onInvite) {
                    Label {
                        Text("Invite teammates…", bundle: .module)
                    } icon: {
                        Image(systemName: "link.badge.plus")
                    }
                }
            }
            if role?.canShareAgents == true {
                Button(action: onShareAgent) {
                    Label {
                        Text("Share an agent…", bundle: .module)
                    } icon: {
                        Image(systemName: "person.2.fill")
                    }
                }
            }
            Divider()
            Button(role: .destructive, action: onLeaveOrDelete) {
                Label {
                    Text(isOwner ? L("Delete…") : L("Leave…"))
                } icon: {
                    Image(systemName: isOwner ? "trash" : "rectangle.portrait.and.arrow.right")
                }
            }
        }
    }

    private var statChips: [LibraryStat] {
        var chips: [LibraryStat] = []
        if let members = workspace.membersActive {
            chips.append(
                LibraryStat(
                    icon: "person.2",
                    text: members == 1 ? L("1 member") : String(format: L("%d members"), members)
                )
            )
        }
        if let agents = workspace.agentsShared {
            chips.append(
                LibraryStat(
                    icon: "antenna.radiowaves.left.and.right",
                    text: agents == 1 ? L("1 shared agent") : String(format: L("%d shared agents"), agents)
                )
            )
        }
        if let created = workspace.createdAt, let date = WorkspacesFormatting.date(created) {
            chips.append(LibraryStat(icon: "clock", text: String(format: L("since %@"), date)))
        }
        return chips
    }
}

extension WorkspacesView {
    @MainActor static func inspectionCards(action: @escaping () -> Void) -> some View {
        let theme = ThemeManager.shared.currentTheme
        return VStack(spacing: theme.space.s12) {
            WorkspaceCard(workspace: .init(id: "local-workspace-owner", name: "Local workspace", role: "owner", source: "subscription", active: true, membersActive: 3, agentsShared: 2), ownerIsTrialing: true, animationDelay: 0, hasAppeared: true, onSelect: action, onInvite: action, onShareAgent: action, onLeaveOrDelete: action)
            WorkspaceCard(workspace: .init(id: "local-workspace-viewer", name: "Shared display sample", role: "viewer", source: "suspended", active: false, membersActive: 2, agentsShared: 1), ownerIsTrialing: false, animationDelay: 0, hasAppeared: true, onSelect: action, onInvite: action, onShareAgent: action, onLeaveOrDelete: action)
        }
    }
}

// MARK: - Shared Workspaces components

/// Workspace monogram on the shared `AgentAvatarView` (no mascot → initial on
/// a tinted disc), tinted by the workspace name like agent cards are.
struct WorkspaceAvatar: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let name: String
    var size: CGFloat = 38

    var body: some View {
        AgentAvatarView(
            mascotId: nil,
            name: name,
            tint: theme.dataInk(seed: name),
            diameter: size,
            monogramFontSize: size * 0.42,
            borderWidth: size >= 32 ? 2 : 1.5
        )
    }
}

/// Role chip (Owner / Admin / Member / Viewer).
struct WorkspaceRoleBadge: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    let role: OsaurusRouterWorkspaceRole

    var body: some View {
        StatusChip(role.displayName, tint: tint)
    }

    private var tint: Color {
        switch role {
        case .owner: return theme.action.primary.default.background
        case .admin, .member: return theme.text.secondary
        case .viewer: return theme.text.tertiary
        }
    }
}

/// Entitlement pill: "Trial" (the owner's first subscription is still in its
/// trial), "Complimentary" (admin comp), "Suspended" (owner subscription
/// canceled or comp expired — only the owner can reactivate), or "Inactive"
/// (subscription-backed but not entitled: past due / incomplete). A healthy
/// paid workspace renders nothing — there is only one plan, so there is no
/// plan name to label.
struct WorkspaceStatusBadge: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    let source: OsaurusRouterWorkspaceBillingSource?
    let active: Bool
    /// Whether the viewer owns this workspace and their subscription is
    /// trialing (members never see the owner's trial).
    var trialing: Bool = false
    /// Owner-side Stripe status for an inactive subscription-backed
    /// workspace, when the billing summary knows it (`past_due` / …).
    var ownerSubscriptionStatus: String? = nil

    enum Kind: Equatable {
        case trial, comp, suspended, pastDue, inactive
    }

    /// nil for a healthy paid workspace: nothing to label.
    static func kind(
        source: OsaurusRouterWorkspaceBillingSource?,
        active: Bool,
        trialing: Bool,
        ownerSubscriptionStatus: String?
    ) -> Kind? {
        if source == .suspended { return .suspended }
        if !active {
            return ownerSubscriptionStatus == "past_due" ? .pastDue : .inactive
        }
        if source == .comp { return .comp }
        if trialing { return .trial }
        return nil
    }

    private var kind: Kind? {
        Self.kind(
            source: source, active: active, trialing: trialing,
            ownerSubscriptionStatus: ownerSubscriptionStatus
        )
    }

    @ViewBuilder
    var body: some View {
        if let kind {
            StatusChip(
                label(for: kind),
                tint: color(for: kind),
                icon: icon(for: kind),
                help: help(for: kind)
            )
        }
    }

    private func label(for kind: Kind) -> String {
        switch kind {
        case .trial: return L("Trial")
        case .comp: return L("Complimentary")
        case .suspended: return L("Suspended")
        case .pastDue: return L("Past due")
        case .inactive: return L("Inactive")
        }
    }

    private func icon(for kind: Kind) -> String {
        switch kind {
        case .trial: return "sparkles"
        case .comp: return "gift.fill"
        case .suspended: return "pause.circle.fill"
        case .pastDue: return "exclamationmark.circle.fill"
        case .inactive: return "xmark.circle.fill"
        }
    }

    private func color(for kind: Kind) -> Color {
        switch kind {
        case .trial: return theme.action.primary.default.background
        case .comp: return theme.status.success.foreground
        case .suspended, .pastDue: return theme.status.warning.foreground
        case .inactive: return theme.status.error.foreground
        }
    }

    private func help(for kind: Kind) -> String {
        switch kind {
        case .trial:
            return L("Free trial — full workspace credits now; converts to a paid subscription when the trial ends")
        case .comp:
            return L("Complimentary — provided without a subscription until it expires")
        case .suspended:
            return L("Suspended — the owner's subscription ended; only the owner can reactivate it")
        case .pastDue:
            return L("Past due — the owner's last payment failed; paused until the card is updated")
        case .inactive:
            return L("Inactive — invites, sharing, and workspace credits are paused until the owner is current")
        }
    }
}

enum WorkspacesFormatting {
    /// ISO-8601 timestamp → "Aug 23, 2026"; nil when unparseable.
    static func date(_ raw: String) -> String? {
        guard let date = parse(raw) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// ISO-8601 timestamp (with or without fractional seconds) → `Date`.
    nonisolated static func parse(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }
}
