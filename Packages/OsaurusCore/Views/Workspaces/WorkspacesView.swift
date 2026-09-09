//
//  WorkspacesView.swift
//  osaurus
//
//  Osaurus Workspaces management, built on the Agents tab's component
//  library so both tabs read as one product: `ManagerHeaderWithActions` +
//  a `LazyVGrid` of `WorkspaceCard`s (the `AgentCard` recipe), the shared
//  `SettingsEmptyState` for onboarding and gates, `InlineBanner` for staged
//  deep links and errors, a bottom `ThemedToastView` for success, and a
//  full-pane `WorkspaceDetailView` (the `AgentDetailView` shell) on drill-in.
//

import SwiftUI

struct WorkspacesView: View {
    /// Same grid ↔ detail cross-fade the Agents tab uses.
    fileprivate static let navTransition = Animation.easeInOut(duration: 0.2)

    /// Two-column grid matching `AgentsView.gridColumns`.
    fileprivate static let gridColumns: [GridItem] = [
        GridItem(.flexible(minimum: 300), spacing: 20),
        GridItem(.flexible(minimum: 300), spacing: 20),
    ]

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var service = WorkspacesService.shared
    @ObservedObject private var providerManager = RemoteProviderManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

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
                        .padding(.bottom, 20)
                }
                .zIndex(100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .task {
            await service.refreshWorkspaces()
            // Opening the tab is a natural moment to make sure every shared
            // agent across the user's workspaces is paired (throttled).
            await WorkspaceAgentConnectService.shared.sweepWorkspaces()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
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
            if ready { presentDeeplinkSheetsIfReady() }
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
        withAnimation(theme.springAnimation()) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.animationQuick()) {
                successMessage = nil
            }
        }
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)
                .settingsLandingAnchor("workspaces.overview")

            content
                .opacity(hasAppeared ? 1 : 0)
        }
    }

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Workspaces"),
            subtitle: L(
                "Invite your team and share agents. Teammates chat with shared agents from their own Osaurus."
            ),
            count: service.workspaces.isEmpty ? nil : service.workspaces.count
        ) {
            HeaderIconButton(
                "arrow.clockwise",
                isLoading: service.isLoadingWorkspaces,
                help: "Refresh"
            ) {
                Task { await service.refreshWorkspaces() }
            }
            .disabled(!canUseWorkspaces)

            HeaderSecondaryButton("Join…", icon: "person.badge.plus") {
                showManualJoinSheet = true
            }
            .disabled(!canUseWorkspaces)
            .help(L("Join a workspace with an invite code"))

            HeaderPrimaryButton("New workspace", icon: "plus") {
                showCreateSheet = true
            }
            .disabled(!canUseWorkspaces)
            .help(L("Create a workspace"))
        }
    }

    @ViewBuilder
    private var content: some View {
        if !routerEnabled {
            SettingsEmptyState(
                icon: "bolt.slash.fill",
                title: L("Osaurus Router is off"),
                subtitle: L(
                    "Workspaces run on the Osaurus Router. Turn it on in the Credits tab to create a workspace, join through an invite link, and share agents."
                ),
                examples: [],
                primaryAction: .init(
                    title: L("Open Credits"),
                    icon: "bolt.fill",
                    handler: { ManagementStateManager.shared.selectedTab = .credits }
                ),
                hasAppeared: hasAppeared
            )
        } else if !identityReady {
            SettingsEmptyState(
                icon: "person.badge.key.fill",
                title: L("Set up your Osaurus Identity"),
                subtitle: L(
                    "Workspaces are tied to your identity master key — it signs every workspace action and is how teammates recognize you. Create or restore an identity first."
                ),
                examples: [],
                primaryAction: .init(
                    title: L("Open Identity"),
                    icon: "person.badge.key.fill",
                    handler: { ManagementStateManager.shared.selectedTab = .identity }
                ),
                hasAppeared: hasAppeared
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    banners

                    if service.isLoadingWorkspaces && service.workspaces.isEmpty {
                        loadingGrid
                    } else if service.workspaces.isEmpty {
                        emptyState
                    } else {
                        workspaceGrid
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
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
        LazyVGrid(columns: Self.gridColumns, spacing: 20) {
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

    /// "14-day free trial, then $20/month or $200/year per workspace." from
    /// the public plan/prices; falls back to a priceless line when the router
    /// hasn't answered yet.
    private var pricingLine: String {
        let prices = service.prices
        let priceText: String? = {
            switch (prices?.monthly?.displayLabel, prices?.yearly?.displayLabel) {
            case (let m?, let y?): return String(format: L("%@ or %@ per workspace"), m, y)
            case (let m?, nil): return String(format: L("%@ per workspace"), m)
            case (nil, let y?): return String(format: L("%@ per workspace"), y)
            default: return nil
            }
        }()
        if service.trialEligible, let days = service.trialDays, days > 0 {
            if let priceText {
                return String(format: L("%d-day free trial, then %@."), days, priceText)
            }
            return String(format: L("Start with a %d-day free trial."), days)
        }
        if let priceText { return String(format: L("%@, with a shared monthly credit pool."), priceText) }
        return L("Every workspace comes with a shared monthly credit pool.")
    }

    private var emptyState: some View {
        SettingsEmptyState(
            icon: "rectangle.3.group.fill",
            title: L("Bring your team in"),
            subtitle: L(
                "Create a workspace, invite people with a link, and share your agents. Teammates chat with them from their own Osaurus."
            ) + " " + pricingLine,
            examples: [
                .init(
                    icon: "link.badge.plus",
                    title: L("Invite with a link"),
                    description: L("Teammates join in one click")
                ),
                .init(
                    icon: "person.2.fill",
                    title: L("Share agents"),
                    description: L("They run on your Mac")
                ),
                .init(
                    icon: "creditcard.fill",
                    title: L("Shared credit pool"),
                    description: L("Refills every month")
                ),
            ],
            primaryAction: .init(
                title: service.trialEligible ? L("Start free trial") : L("New workspace"),
                icon: "plus",
                handler: { showCreateSheet = true }
            ),
            secondaryAction: .init(
                title: L("Have an invite code?"),
                icon: "person.badge.plus",
                handler: { showManualJoinSheet = true }
            ),
            hasAppeared: hasAppeared
        )
        .frame(minHeight: 420)
    }

    private var loadingGrid: some View {
        LazyVGrid(columns: Self.gridColumns, spacing: 20) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(theme.tertiaryBackground)
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(theme.tertiaryBackground)
                                .frame(width: 140, height: 12)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(theme.tertiaryBackground.opacity(0.6))
                                .frame(width: 200, height: 9)
                        }
                        Spacer()
                    }
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.tertiaryBackground.opacity(0.6))
                        .frame(width: 160, height: 9)
                }
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .top)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(theme.cardBorder, lineWidth: 1)
                        )
                )
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
        return L("You'll lose access to the workspace's shared agents and credit pool. Your shared agents are revoked.")
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

/// Grid card for one workspace, on the `AgentCard` recipe: avatar + name +
/// badges, a two-line caption slot, a stat strip, an overflow menu, and the
/// hover chevron — so the Workspaces grid and the Agents grid share one
/// rhythm.
private struct WorkspaceCard: View {
    @Environment(\.theme) private var theme

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

    @State private var isHovered = false

    private var color: Color { agentColorFor(workspace.name) }
    private var role: OsaurusRouterWorkspaceRole? { workspace.typedRole }
    private var isOwner: Bool { role == .owner }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    WorkspaceAvatar(name: workspace.name, size: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(workspace.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                            if let role {
                                WorkspaceRoleBadge(role: role)
                            }
                        }
                        Text(caption)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 8)

                    WorkspaceStatusBadge(
                        source: workspace.typedSource,
                        active: workspace.isActive,
                        trialing: isOwner && ownerIsTrialing
                    )

                    overflowMenu
                }

                // Two-line description slot, like the agent card's prompt
                // preview, so card heights line up across the grid.
                Text(descriptionText)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
                stats
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .top)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))
            .overlay(hoverGradient)
            .overlay(alignment: .bottomTrailing) { hoverChevron }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isHovered ? color.opacity(0.25) : theme.cardBorder,
                        lineWidth: isHovered ? 1.5 : 1
                    )
            )
            .shadow(
                color: Color.black.opacity(isHovered ? 0.08 : 0.04),
                radius: isHovered ? 10 : 5,
                x: 0,
                y: isHovered ? 3 : 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay), value: hasAppeared)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }

    /// "Owned by you" / "Shared with you" — who this workspace is to the user.
    private var caption: String {
        isOwner ? L("Owned by you") : L("You're a member")
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

    private var overflowMenu: some View {
        Menu {
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
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.tertiaryBackground))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
    }

    private var stats: some View {
        HStack(spacing: 0) {
            let chips = statChips
            ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                if index > 0 {
                    Circle()
                        .fill(theme.tertiaryText.opacity(0.4))
                        .frame(width: 3, height: 3)
                        .padding(.horizontal, 8)
                }
                HStack(spacing: 3) {
                    Image(systemName: chip.icon)
                        .font(.system(size: 9, weight: .medium))
                    Text(chip.text)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(theme.tertiaryText)
            }
            Spacer(minLength: 0)
        }
    }

    private var statChips: [(icon: String, text: String)] {
        var chips: [(icon: String, text: String)] = []
        if let members = workspace.membersActive {
            chips.append(
                ("person.2", members == 1 ? L("1 member") : String(format: L("%d members"), members))
            )
        }
        if let agents = workspace.agentsShared {
            chips.append(
                (
                    "antenna.radiowaves.left.and.right",
                    agents == 1 ? L("1 shared agent") : String(format: L("%d shared agents"), agents)
                )
            )
        }
        if let created = workspace.createdAt, let date = WorkspacesFormatting.date(created) {
            chips.append(("clock", String(format: L("since %@"), date)))
        }
        return chips
    }

    private var hoverGradient: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: [color.opacity(isHovered ? 0.06 : 0), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    private var hoverChevron: some View {
        Image(systemName: "arrow.up.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(color)
            .frame(width: 22, height: 22)
            .background(Circle().fill(color.opacity(0.12)))
            .padding(10)
            .opacity(isHovered ? 1 : 0)
            .scaleEffect(isHovered ? 1 : 0.85)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Shared Workspaces components

/// Workspace monogram on the shared `AgentAvatarView` (no mascot → initial on
/// a tinted disc), tinted by the workspace name like agent cards are.
struct WorkspaceAvatar: View {
    let name: String
    var size: CGFloat = 38

    var body: some View {
        AgentAvatarView(
            mascotId: nil,
            name: name,
            tint: agentColorFor(name),
            diameter: size,
            monogramFontSize: size * 0.42,
            borderWidth: size >= 32 ? 2 : 1.5
        )
    }
}

/// Role chip (OWNER / ADMIN / MEMBER / VIEWER) on the shared `CapsuleBadge`.
struct WorkspaceRoleBadge: View {
    @Environment(\.theme) private var theme
    let role: OsaurusRouterWorkspaceRole

    var body: some View {
        CapsuleBadge(role.displayName, tint: tint, style: .tag)
    }

    private var tint: Color {
        switch role {
        case .owner: return theme.accentColor
        case .admin, .member: return theme.secondaryText
        case .viewer: return theme.tertiaryText
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
    @Environment(\.theme) private var theme
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
            CapsuleBadge(
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
        case .trial: return theme.accentColor
        case .comp: return theme.successColor
        case .suspended, .pastDue: return theme.warningColor
        case .inactive: return theme.errorColor
        }
    }

    private func help(for kind: Kind) -> String {
        switch kind {
        case .trial:
            return L("Free trial — full credit pool now; converts to a paid subscription when the trial ends")
        case .comp:
            return L("Complimentary — provided without a subscription until it expires")
        case .suspended:
            return L("Suspended — the owner's subscription ended; only the owner can reactivate it")
        case .pastDue:
            return L("Past due — the owner's last payment failed; paused until the card is updated")
        case .inactive:
            return L("Inactive — invites, sharing, and pool billing are paused until the owner is current")
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
