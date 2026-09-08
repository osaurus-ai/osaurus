//
//  WorkspaceDetailView.swift
//  osaurus
//
//  One workspace, on the `AgentDetailView` shell: the shared header bar
//  (back · identity · status · actions), the grouped tab strip with
//  Overview / Members / Shared Agents / Audit, and `AgentDetailSection` cards
//  in each tab. Confirmations go through `themedAlert`, success through the
//  parent's toast, errors through `InlineBanner` — the same vocabulary the
//  Agents tab uses, so a workspace reads like any other thing you manage.
//

import AppKit
import SwiftUI

struct WorkspaceDetailView: View {
    enum Tab: Hashable {
        case overview
        case members
        case sharedAgents
        case audit
    }

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var service = WorkspacesService.shared
    @ObservedObject private var connectService = WorkspaceAgentConnectService.shared
    /// Observed so a completed connect flips the row's button to "Chat".
    @ObservedObject private var remoteAgents = RemoteAgentManager.shared
    /// Observed for own-agent rows: their presence is the relay tunnel state.
    @ObservedObject private var relayManager = RelayTunnelManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let workspace: OsaurusRouterWorkspaceSummary
    var initialTab: Tab = .overview
    let onBack: () -> Void
    /// Bottom toast owned by `WorkspacesView` (same as the Agents tab).
    var showSuccess: (String) -> Void = { _ in }

    @State private var selectedTab: Tab = .overview
    @State private var showInviteSheet = false
    @State private var showShareSheet = false
    @State private var showPoolActivity = false
    @State private var showTopUp = false
    @State private var showAutoReload = false
    @State private var showDeleteConfirm = false
    @State private var showLeaveConfirm = false
    @State private var renameDraft = ""
    /// Member awaiting the "demote to viewer revokes their agents" confirm.
    @State private var pendingViewerDemotion: OsaurusRouterWorkspaceMember?
    /// Row-level destructive action awaiting its confirm alert.
    @State private var pendingDestruction: PendingDestruction?
    /// Invite row whose link was just copied (button reads "Copied").
    @State private var copiedInviteId: String?
    @State private var copiedInviteTask: Task<Void, Never>?

    private enum PendingDestruction: Identifiable {
        case removeMember(OsaurusRouterWorkspaceMember)
        case revokeInvite(OsaurusRouterWorkspaceInvite)
        case unshareAgent(SharedAgentIdentity)

        var id: String {
            switch self {
            case .removeMember(let member): return "member.\(member.accountId)"
            case .revokeInvite(let invite): return "invite.\(invite.id)"
            case .unshareAgent(let identity): return "agent.\(identity.address)"
            }
        }
    }

    private var detail: OsaurusRouterWorkspaceDetail? { service.detail }
    /// Unknown/future roles fall back to `.viewer` (least privilege) so a
    /// newer server can't accidentally unlock member/admin affordances.
    private var myRole: OsaurusRouterWorkspaceRole {
        detail?.typedRole ?? workspace.typedRole ?? .viewer
    }
    private var isOwner: Bool { myRole == .owner }
    private var canManageInvites: Bool { myRole == .owner || myRole == .admin }
    private var entitlement: OsaurusRouterWorkspaceEntitlement? { detail?.entitlement }
    private var billingSource: OsaurusRouterWorkspaceBillingSource? { detail?.typedSource ?? workspace.typedSource }
    /// Whether invites, shares, and pool billing work right now (follows the
    /// owner's subscription or the comp's expiry).
    private var workspaceActive: Bool { detail?.isActive ?? workspace.isActive }
    private var isSuspended: Bool { billingSource == .suspended }
    /// The owner's own subscription is trialing (only meaningful when the
    /// viewer owns this workspace).
    private var ownerTrialing: Bool { isOwner && service.isTrialing }
    private var workspaceName: String { detail?.name ?? workspace.name }
    private var workspaceColor: Color { agentColorFor(workspaceName) }

    var body: some View {
        VStack(spacing: 0) {
            header

            AgentDetailGroupedTabStrip(groups: tabGroups, selection: $selectedTab)

            Divider()
                .foregroundColor(theme.primaryBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    banners
                    tabSections
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id(selectedTab)
            }
            .background(theme.primaryBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .onAppear {
            selectedTab = initialTab
            renameDraft = workspaceName
            consumeDeepLinkTab()
        }
        .onChange(of: service.deepLinkTab) { _, _ in
            // A deep link into a workspace whose detail is already on screen
            // (chat gear → Shared Agents while Overview is open).
            consumeDeepLinkTab()
        }
        .onChange(of: workspaceName) { _, name in
            // A refresh (or a rename from another device) lands in the field
            // unless the user is mid-edit.
            if renameDraft == workspace.name || renameDraft.isEmpty { renameDraft = name }
        }
        .task(id: workspace.id) {
            // Presence re-poll: `online`/`last_seen` age out fast, so keep
            // the roster live (~30s) while this detail view is on screen.
            // Each pass also auto-connects any shared agent this member
            // hasn't paired with yet (hosts that just came online included),
            // so the roster is "ready to chat" without a Connect click.
            await autoConnectSharedAgents()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await service.refreshAgentsPresence()
                await autoConnectSharedAgents()
            }
        }
        .onChange(of: service.workspaceAgents.map(\.agentAddress)) { _, _ in
            // A freshly loaded/changed roster (initial detail load, a
            // teammate sharing a new agent) gets connected right away.
            Task { await autoConnectSharedAgents() }
        }
        .sheet(isPresented: $showInviteSheet) {
            CreateInviteLinkSheet(
                workspaceId: workspace.id,
                isOwner: isOwner,
                seatsRemaining: seatsRemaining,
                onCreated: { _ in showSuccess(L("Invite link created and copied.")) }
            )
            .environment(\.theme, theme)
        }
        .sheet(isPresented: $showPoolActivity) {
            WorkspacePoolActivityView(workspace: workspace)
                .environment(\.theme, theme)
        }
        .sheet(isPresented: $showTopUp) {
            WorkspacePoolTopUpSheet(workspaceId: workspace.id, workspaceName: workspace.name)
                .environment(\.theme, theme)
        }
        .sheet(isPresented: $showAutoReload) {
            WorkspaceAutoReloadSheet(workspaceId: workspace.id, workspaceName: workspace.name)
                .environment(\.theme, theme)
        }
        .sheet(isPresented: $showShareSheet) {
            WorkspaceShareAgentSheet(
                workspaceId: workspace.id,
                onSuccess: { showSuccess(L("Agent shared with the workspace.")) }
            )
            .environment(\.theme, theme)
        }
        // Row-level confirmations (remove member / revoke invite / unshare).
        .themedAlert(
            pendingDestruction.map(destructionTitle) ?? "",
            isPresented: Binding(
                get: { pendingDestruction != nil },
                set: { if !$0 { pendingDestruction = nil } }
            ),
            message: pendingDestruction.map(destructionMessage),
            primaryButton: .destructive(pendingDestruction.map(destructionButtonTitle) ?? L("Remove")) {
                guard let action = pendingDestruction else { return }
                pendingDestruction = nil
                performDestruction(action)
            },
            secondaryButton: .cancel(L("Cancel"))
        )
        .themedAlert(
            L("Delete Workspace?"),
            isPresented: $showDeleteConfirm,
            message: deleteExplainer,
            primaryButton: .destructive(L("Delete")) {
                Task {
                    if await service.deleteWorkspace(id: workspace.id) {
                        showSuccess(String(format: L("Deleted “%@”"), workspaceName))
                        onBack()
                    }
                }
            },
            secondaryButton: .cancel(L("Cancel"))
        )
        .themedAlert(
            L("Leave Workspace?"),
            isPresented: $showLeaveConfirm,
            message: L("You'll lose access to the workspace's shared agents and credit pool. Your shared agents are revoked."),
            primaryButton: .destructive(L("Leave")) {
                Task { await performLeave() }
            },
            secondaryButton: .cancel(L("Cancel"))
        )
        .themedAlert(
            L("Make Viewer?"),
            isPresented: Binding(
                get: { pendingViewerDemotion != nil },
                set: { if !$0 { pendingViewerDemotion = nil } }
            ),
            message: pendingViewerDemotion.map {
                String(
                    format: L(
                        "Viewers can use teammates' shared agents but can't share their own. %@'s active shared agents will be revoked."
                    ),
                    $0.friendlyName
                )
            },
            primaryButton: .destructive(L("Make Viewer")) {
                guard let member = pendingViewerDemotion else { return }
                pendingViewerDemotion = nil
                Task {
                    await service.setMemberRole(
                        workspaceId: workspace.id, accountId: member.accountId, role: .viewer
                    )
                }
            },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    // MARK: - Header

    private var header: some View {
        AgentDetailHeaderBar(
            onBack: onBack,
            backTitle: "Workspaces",
            identity: {
                AgentDetailIdentityLabel(
                    mascotId: nil,
                    name: workspaceName,
                    tint: workspaceColor,
                    subtitle: overviewCaption,
                    maxWidth: 320
                )
            },
            status: {
                HStack(spacing: 8) {
                    if service.isLoadingDetail {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.8)
                    }
                    WorkspaceRoleBadge(role: myRole)
                    statusBadge
                }
            },
            actions: {
                HStack(spacing: 6) {
                    AgentDetailHeaderActionButton(
                        icon: "clock.arrow.circlepath",
                        tint: theme.secondaryText,
                        help: "Activity",
                        action: { showPoolActivity = true }
                    )
                    AgentDetailHeaderActionButton(
                        icon: "arrow.clockwise",
                        tint: theme.accentColor,
                        help: "Refresh",
                        action: { Task { await service.refreshSelectedWorkspace() } }
                    )
                }
            }
        )
    }

    /// "3 members · 2 shared agents · since Mar 4 · Owned by you".
    private var overviewCaption: String {
        var parts: [String] = []
        let members = detail?.membersActive ?? service.members.count
        if members > 0 {
            parts.append(members == 1 ? L("1 member") : String(format: L("%d members"), members))
        }
        let agents = detail?.agentsShared ?? service.workspaceAgents.count
        if agents > 0 {
            parts.append(agents == 1 ? L("1 shared agent") : String(format: L("%d shared agents"), agents))
        }
        if isOwner {
            parts.append(L("Owned by you"))
        } else if let owner = detail?.owner {
            parts.append(String(format: L("Owned by %@"), owner.friendlyName))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Tabs

    private var tabGroups: [AgentDetailTabGroup<Tab>] {
        let memberCount = service.members.count
        let agentCount = service.workspaceAgents.count
        return [
            AgentDetailTabGroup(
                id: "overview",
                label: L("Overview"),
                icon: "info.circle",
                items: [AgentDetailTabItem(id: .overview, label: L("Overview"), icon: "info.circle")]
            ),
            AgentDetailTabGroup(
                id: "members",
                label: L("Members"),
                icon: "person.2.fill",
                items: [AgentDetailTabItem(id: .members, label: L("Members"), icon: "person.2.fill")],
                badgeCount: memberCount == 0 ? nil : memberCount
            ),
            AgentDetailTabGroup(
                id: "agents",
                label: L("Shared Agents"),
                icon: "antenna.radiowaves.left.and.right",
                items: [
                    AgentDetailTabItem(
                        id: .sharedAgents, label: L("Shared Agents"), icon: "antenna.radiowaves.left.and.right"
                    )
                ],
                badgeCount: agentCount == 0 ? nil : agentCount
            ),
            AgentDetailTabGroup(
                id: "audit",
                label: L("Audit"),
                icon: "list.bullet.clipboard.fill",
                items: [AgentDetailTabItem(id: .audit, label: L("Audit"), icon: "list.bullet.clipboard.fill")]
            ),
        ]
    }

    @ViewBuilder
    private var tabSections: some View {
        switch selectedTab {
        case .overview:
            poolSection
            if isOwner {
                nameSection
            }
            dangerZoneSection
        case .members:
            membersSection
            if canManageInvites {
                inviteLinksSection
            }
        case .sharedAgents:
            sharedAgentsSection
        case .audit:
            WorkspaceAuditCard(workspaceId: workspace.id)
        }
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        if let lastError = service.lastError {
            InlineBanner(kind: .error, title: lastError) { service.lastError = nil }
        }
        if let connectError = connectService.lastError {
            InlineBanner(kind: .error, title: connectError) { connectService.lastError = nil }
        }
        if !workspaceActive, selectedTab != .overview {
            InlineBanner(kind: .warning, title: inactiveExplainer)
        }
    }

    // MARK: - Overview · Pool

    private var statusBadge: WorkspaceStatusBadge {
        WorkspaceStatusBadge(
            source: billingSource,
            active: workspaceActive,
            trialing: ownerTrialing,
            ownerSubscriptionStatus: isOwner ? service.billing?.subscription?.status : nil
        )
    }

    /// The overview hero: the shared balance as the headline figure, the
    /// entitlement's health as the pill, and the trial/renewal/seat facts on
    /// one quiet line below. Every workspace has a pool, so this is the
    /// overview for every workspace.
    private var poolSection: some View {
        AgentDetailSection(
            title: L("Workspace pool"),
            icon: "rectangle.3.group.fill",
            trailing: { statusBadge }
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(
                        verbatim: OsaurusRouter.formatMicroAsCreditsValue(
                            service.poolBalance?.balanceMicro ?? detail?.balanceMicro ?? "0"
                        )
                    )
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .foregroundColor(
                        detail?.poolFrozen == true || !workspaceActive
                            ? theme.warningColor : theme.primaryText
                    )
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    Text("credits", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                if service.isLoadingDetail && detail == nil {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Spacer(minLength: 8)
                // Owner-only money: buy credits that never expire, or arm
                // auto-reload. Both need an active workspace (a suspended
                // pool is refused with SUBSCRIPTION_INACTIVE).
                if isOwner, !isSuspended {
                    Button {
                        showTopUp = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Add credits…", bundle: .module)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(size: .compact))
                    .disabled(service.pendingConfirmation != nil)
                    .help(L("Buy credits for this pool ($5–$500). Purchased credits never expire."))
                    Button {
                        showAutoReload = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Auto-reload…", bundle: .module)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(size: .compact))
                    .help(L("Refill the pool from your saved card when it runs low"))
                }
            }

            Text(poolSubline)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

            if let breakdown = poolBreakdown {
                HStack(spacing: 6) {
                    Text(breakdown)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    if let chip = autoReloadChip {
                        CapsuleBadge(chip.label, tint: chip.tint, icon: "arrow.triangle.2.circlepath", help: chip.help)
                    }
                }
            } else if let chip = autoReloadChip {
                CapsuleBadge(chip.label, tint: chip.tint, icon: "arrow.triangle.2.circlepath", help: chip.help)
            }

            if let syncingCopy {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                    Text(syncingCopy)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)

                    Spacer(minLength: 8)

                    // Escape hatch for a portal/checkout visit that changed
                    // nothing — the wait also self-clears after a bounded
                    // number of polls.
                    Button(action: { service.dismissSubscriptionWait() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Stop waiting (e.g. you closed the browser tab without changes)"))
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                planFacts
                Spacer()
                Button {
                    showPoolActivity = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("Pool activity", bundle: .module)
                    }
                }
                .buttonStyle(SecondaryButtonStyle(size: .compact))
                .help(L("Who spent what from the pool, and monthly grant/expiry entries"))
                if isOwner, isSuspended {
                    Button {
                        Task { await service.reactivateWorkspace(id: workspace.id) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Reactivate…", bundle: .module)
                        }
                    }
                    .buttonStyle(
                        PrimaryButtonStyle(isLoading: service.isBusy("workspace.reactivate"))
                    )
                    .disabled(service.isBusy("workspace.reactivate") || service.pendingConfirmation != nil)
                    .help(reactivateHelp)
                }
                // The portal needs a Stripe subscription record on file
                // (suspended/lapsed owners can still reach invoices and the
                // card).
                if isOwner, service.billing?.subscription != nil {
                    Button {
                        Task { await service.openBillingPortal() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Manage billing", bundle: .module)
                        }
                    }
                    .buttonStyle(
                        SecondaryButtonStyle(isLoading: service.isBusy("subscription.portal"), size: .compact)
                    )
                    .disabled(service.isBusy("subscription.portal"))
                    .help(
                        L(
                            "Payment method, invoices, monthly/yearly switch, and cancellation for your workspace subscription (Stripe)"
                        )
                    )
                }
            }

            if !workspaceActive {
                Text(inactiveExplainer)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The syncing row's copy for whichever Stripe round-trip is pending on
    /// this workspace (nil when none, or when it's a new-workspace checkout —
    /// that one lives on the list).
    private var syncingCopy: String? {
        switch service.pendingConfirmation {
        case .portal:
            return L("Syncing billing changes — this updates automatically after you return from the billing portal.")
        case .reactivation(let id) where id == workspace.id:
            return L("Finish the checkout in your browser — this workspace reactivates automatically once Stripe confirms.")
        case .topUp(let id, _, let amountMicro, _, _) where id == workspace.id:
            return String(
                format: L("Finish the %@ payment in your browser — the pool updates automatically once Stripe confirms."),
                OsaurusRouter.formatMicroUSD(String(amountMicro))
            )
        default:
            return nil
        }
    }

    /// "1,200 expire on Sep 30 · 3,000 purchased (never expire)" — only when
    /// the router splits the balance and there is purchased credit to tell
    /// apart from the grant.
    private var poolBreakdown: String? {
        guard let balance = service.poolBalance, balance.hasBreakdown, balance.purchasedIsPositive,
            let expiring = balance.expiringMicro, let purchased = balance.purchasedMicro
        else { return nil }
        return String(
            format: L("%@ from this month's grant · %@ purchased (never expire)"),
            OsaurusRouter.formatMicroAsCreditsValue(expiring),
            OsaurusRouter.formatMicroAsCreditsValue(purchased)
        )
    }

    /// Auto-reload state from the balance endpoint (any member can see it).
    private var autoReloadChip: (label: String, tint: Color, help: String)? {
        guard let state = service.poolBalance?.autoReload, state.enabled else { return nil }
        if state.paused {
            return (
                L("Auto-reload paused"), theme.warningColor,
                isOwner
                    ? L("Reloads stopped after failed charges. Open Auto-reload… to fix the card and re-arm.")
                    : L("The owner's auto-reload stopped after failed charges.")
            )
        }
        return (
            L("Auto-reload on"), theme.successColor,
            L("The owner's saved card refills this pool when it runs low.")
        )
    }

    private var reactivateHelp: String {
        if service.hasLiveSubscription {
            return L("Adds this workspace back to your subscription right away")
        }
        if let price = service.prices?.monthly?.displayLabel {
            return String(format: L("Start a new subscription for this workspace (%@) — finishes in your browser"), price)
        }
        return L("Start a new subscription for this workspace — finishes in your browser")
    }

    /// Under the balance: refill cadence, or why the pool is paused.
    private var poolSubline: String {
        if !workspaceActive {
            return isSuspended
                ? L("Pool paused — suspended until the owner reactivates this workspace.")
                : L("Pool paused — resumes when the owner's subscription is current.")
        }
        if detail?.poolFrozen == true {
            return L("Pool paused.")
        }
        if let monthly = entitlement?.monthlyCreditMicro, monthly != "0" {
            if let next = entitlement?.nextGrantAt, let date = WorkspacesFormatting.date(next) {
                return String(
                    format: L("Shared balance — resets to %@ credits on %@"),
                    OsaurusRouter.formatMicroAsCreditsValue(monthly), date
                )
            }
            return String(
                format: L("Shared balance — resets to %@ credits monthly"),
                OsaurusRouter.formatMicroAsCreditsValue(monthly)
            )
        }
        return L("Shared balance — resets each monthly cycle")
    }

    /// Why an inactive workspace is paused and who can fix it.
    private var inactiveExplainer: String {
        if isSuspended {
            return isOwner
                ? L("Suspended: your subscription for this workspace ended. Members, agents, and history are kept until you reactivate it.")
                : L("Suspended: the owner's subscription ended. Members, agents, and history are kept; only the owner can reactivate it.")
        }
        if entitlement?.isComp == true {
            return isOwner
                ? L("This complimentary period has ended. Members, agents, and history are kept until you reactivate it.")
                : L("This workspace's complimentary period has ended. Only the owner can reactivate it.")
        }
        return isOwner
            ? L("Invites, shared agents, and pool-billed inference are paused until your subscription is current. Past-due? Update the card under Manage billing.")
            : L("The workspace's subscription isn't active right now, so invites, shared agents, and pool-billed inference are paused. Only the owner can renew.")
    }

    /// "Credits · trial ends/renews date · seats 2/5 · agents 1/3 · owner"
    /// fact line. Seat and agent caps only appear when the plan actually has
    /// one — an unlimited lever (`nil`) is not worth a "∞" fact.
    @ViewBuilder
    private var planFacts: some View {
        HStack(spacing: 14) {
            if let grant = monthlyGrantValue {
                factItem(label: L("Monthly credits"), value: grant, detail: planDetail)
            }
            if let ends = billingDate {
                factItem(label: ends.label, value: ends.value, detail: nil)
            }
            if let seats = entitlement?.seats {
                factItem(
                    label: L("Seats"),
                    value: capFraction(detail?.membersActive ?? service.members.count, seats),
                    detail: nil
                )
            }
            if let maxAgents = entitlement?.maxSharedAgents {
                factItem(
                    label: L("Agents"),
                    value: capFraction(detail?.agentsShared ?? service.workspaceAgents.count, maxAgents),
                    detail: nil
                )
            }
            if let owner = detail?.owner {
                factItem(label: L("Owner"), value: isOwner ? L("You") : owner.friendlyName, detail: nil)
            }
        }
    }

    /// "5,000" from the entitlement's monthly grant (or the public plan while
    /// the detail is loading); nil when neither is known.
    private var monthlyGrantValue: String? {
        let micro = entitlement?.monthlyCreditMicro ?? service.prices?.plan?.monthlyCreditMicro
        guard let micro, micro != "0" else { return nil }
        return OsaurusRouter.formatMicroAsCreditsValue(micro)
    }

    private var planDetail: String? {
        if entitlement?.isComp == true { return L("complimentary") }
        if ownerTrialing { return L("free trial") }
        if isOwner, let price = service.billing?.subscription?.price?.displayLabel { return price }
        return nil
    }

    /// Comp expiry or, for the owner, the trial end / subscription period
    /// end from the account billing summary.
    private var billingDate: (label: String, value: String)? {
        if entitlement?.isComp == true, let raw = entitlement?.compExpiresAt,
            let date = WorkspacesFormatting.date(raw)
        {
            return (L("Comp ends"), date)
        }
        guard isOwner, entitlement?.isSubscriptionBacked == true, let sub = service.billing?.subscription
        else { return nil }
        if sub.isTrialing, let raw = sub.trialEndsAt, let date = WorkspacesFormatting.date(raw) {
            return (L("Trial ends"), date)
        }
        if let raw = sub.currentPeriodEnd, let date = WorkspacesFormatting.date(raw) {
            return (sub.cancelAtPeriodEnd == true ? L("Ends") : L("Renews"), date)
        }
        return nil
    }

    private func factItem(label: String, value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .textCase(.uppercase)
                .kerning(0.4)
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    /// `2/5`.
    private func capFraction(_ used: Int, _ cap: Int) -> String {
        "\(used)/\(cap)"
    }

    // MARK: - Overview · Name (owner)

    private var trimmedRename: String { renameDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var renameIsValid: Bool { !trimmedRename.isEmpty && trimmedRename.count <= 80 }
    private var renameChanged: Bool { trimmedRename != workspaceName }

    private var nameSection: some View {
        AgentDetailSection(title: L("Name"), icon: "pencil") {
            HStack(spacing: 10) {
                StyledTextField(
                    placeholder: L("Workspace name"),
                    text: $renameDraft,
                    icon: "rectangle.3.group"
                )
                .onSubmit { commitRename() }

                Button {
                    commitRename()
                } label: {
                    Text("Save", bundle: .module)
                }
                .buttonStyle(PrimaryButtonStyle(isLoading: service.isBusy("workspace.rename")))
                .disabled(!renameIsValid || !renameChanged || service.isBusy("workspace.rename"))
            }
            Text(
                renameIsValid
                    ? L("Teammates see this name in their sidebar and Workspaces tab.")
                    : String(
                        format: L("Workspace names are capped at 80 characters (currently %d)."),
                        trimmedRename.count
                    )
            )
            .font(.system(size: 11))
            .foregroundColor(renameIsValid ? theme.tertiaryText : theme.warningColor)
        }
    }

    private func commitRename() {
        guard renameIsValid, renameChanged else { return }
        let name = trimmedRename
        Task {
            if await service.renameWorkspace(id: workspace.id, name: name) {
                showSuccess(String(format: L("Renamed to “%@”"), name))
            }
        }
    }

    // MARK: - Overview · Danger zone

    /// Understated destructive section (mirrors the agent detail's delete
    /// affordance): plain copy on the left, one tinted destructive button
    /// on the right. Both routes confirm before doing anything.
    private var dangerZoneSection: some View {
        AgentDetailSection(title: L("Danger zone"), icon: "exclamationmark.triangle") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isOwner ? L("Delete this workspace") : L("Leave this workspace"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        isOwner
                            ? L("Removes the workspace for everyone and revokes shared agents and invites.")
                            : L("You'll lose access to shared agents; agents you shared are revoked.")
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    if isOwner {
                        showDeleteConfirm = true
                    } else {
                        showLeaveConfirm = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isOwner ? "trash" : "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 11))
                        Text(isOwner ? L("Delete…") : L("Leave…"))
                    }
                }
                .buttonStyle(
                    DestructiveButtonStyle(
                        isLoading: service.isBusy(isOwner ? "workspace.delete" : "member.leave")
                    )
                )
                .disabled(service.isBusy(isOwner ? "workspace.delete" : "member.leave"))
            }
        }
    }

    /// Self-leave needs our account id from the roster; if the roster fetch
    /// failed earlier, retry it once instead of leaving the button dead.
    private func performLeave() async {
        var accountId = myAccountId()
        if accountId == nil {
            await service.refreshSelectedWorkspace()
            accountId = myAccountId()
        }
        guard let accountId else {
            service.lastError = L(
                "Couldn't identify your membership because the member list didn't load. Check your connection, refresh, and try again."
            )
            return
        }
        if await service.removeMember(workspaceId: workspace.id, accountId: accountId) {
            showSuccess(String(format: L("Left “%@”"), workspaceName))
            onBack()
        }
    }

    /// Seats left under the plan's cap; nil when the cap is unlimited (the
    /// default) or unknown.
    private var seatsRemaining: Int? {
        guard let total = entitlement?.seats else { return nil }
        let used = detail?.membersActive ?? service.members.count
        return max(0, total - used)
    }

    /// Delete-confirm copy; a subscription-backed workspace also leaves the
    /// owner's subscription (the quantity drops by one).
    private var deleteExplainer: String {
        if entitlement?.isSubscriptionBacked ?? true {
            return L(
                "This removes the workspace for every member, revokes all shared agents and pending invites, and removes it from your subscription."
            )
        }
        return L("This removes the workspace for every member and revokes all shared agents and pending invites.")
    }

    private func autoConnectSharedAgents() async {
        guard !service.workspaceAgents.isEmpty else { return }
        await connectService.autoConnect(
            workspaceId: workspace.id, agents: service.workspaceAgents
        )
    }

    // MARK: - Row-level confirmations

    private func destructionTitle(_ action: PendingDestruction) -> String {
        switch action {
        case .removeMember(let member): return String(format: L("Remove %@?"), member.friendlyName)
        case .revokeInvite: return L("Revoke invite link?")
        case .unshareAgent(let identity): return String(format: L("Unshare %@?"), identity.name)
        }
    }

    private func destructionMessage(_ action: PendingDestruction) -> String {
        switch action {
        case .removeMember:
            return L("They lose access to the workspace's shared agents and credit pool, and any agents they shared are revoked.")
        case .revokeInvite:
            return L(
                "Anyone who still has this link won't be able to join with it. People who already joined stay on the workspace."
            )
        case .unshareAgent:
            return L("Teammates lose access immediately, and the agent can no longer bill the workspace pool.")
        }
    }

    private func destructionButtonTitle(_ action: PendingDestruction) -> String {
        switch action {
        case .removeMember: return L("Remove")
        case .revokeInvite: return L("Revoke")
        case .unshareAgent: return L("Unshare")
        }
    }

    private func performDestruction(_ action: PendingDestruction) {
        switch action {
        case .removeMember(let member):
            Task {
                if await service.removeMember(workspaceId: workspace.id, accountId: member.accountId) {
                    showSuccess(String(format: L("Removed %@"), member.friendlyName))
                }
            }
        case .revokeInvite(let invite):
            Task {
                if await service.revokeInvite(workspaceId: workspace.id, inviteId: invite.id) {
                    showSuccess(L("Invite link revoked"))
                }
            }
        case .unshareAgent(let identity):
            Task {
                if await service.unshareAgent(workspaceId: workspace.id, agentAddress: identity.address) {
                    showSuccess(String(format: L("Unshared %@"), identity.name))
                }
            }
        }
    }

    // MARK: - Members

    private var membersSection: some View {
        AgentDetailSection(
            title: L("Members"),
            icon: "person.2.fill",
            subtitle: service.members.isEmpty ? nil : "\(service.members.count)",
            trailing: {
                if canManageInvites {
                    Button {
                        showInviteSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "link.badge.plus")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Invite", bundle: .module)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(size: .compact))
                    .disabled(!workspaceActive || service.isWorking)
                    .help(
                        workspaceActive
                            ? L("Create an invite link")
                            : L("This workspace isn't active, so invites are paused")
                    )
                }
            }
        ) {
            if service.members.isEmpty {
                if service.isLoadingDetail {
                    AgentSectionEmptyState(loading: "Loading members…")
                } else {
                    AgentSectionEmptyState(
                        icon: "person.2",
                        title: "No members loaded",
                        hint: "Refresh to load the member list.",
                        actionLabel: "Refresh",
                        action: { Task { await service.refreshSelectedWorkspace() } }
                    )
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(service.members) { member in
                        memberRow(member)
                    }
                }
            }
        }
        .settingsLandingAnchor("workspaces.invites")
    }

    private var pendingInvites: [OsaurusRouterWorkspaceInvite] {
        service.workspaceInvites.filter(\.isPending)
    }

    private func memberRow(_ member: OsaurusRouterWorkspaceMember) -> some View {
        let isSelf = service.isSelf(member)
        let role = member.typedRole ?? .member
        return HStack(spacing: 10) {
            WorkspaceAvatar(name: member.friendlyName, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(member.friendlyName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    if isSelf {
                        CapsuleBadge(L("You"), tint: theme.secondaryText, style: .tag)
                    }
                }
                if let wallet = member.walletAddress, !wallet.isEmpty {
                    let short = OsaurusRouterWorkspacePerson.shortWallet(wallet)
                    if short != member.friendlyName {
                        Text(short)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                            .help(wallet)
                    }
                }
            }

            Spacer()

            if let count = member.agentsShared, count > 0 {
                CapsuleBadge(
                    count == 1 ? L("1 agent") : String(format: L("%d agents"), count),
                    tint: theme.tertiaryText,
                    icon: "antenna.radiowaves.left.and.right"
                )
            }

            if isOwner, role != .owner {
                Menu {
                    Button(action: {
                        Task {
                            await service.setMemberRole(
                                workspaceId: workspace.id, accountId: member.accountId, role: .admin
                            )
                        }
                    }) {
                        Text("Make Admin", bundle: .module)
                    }
                    .disabled(role == .admin)
                    Button(action: {
                        Task {
                            await service.setMemberRole(
                                workspaceId: workspace.id, accountId: member.accountId, role: .member
                            )
                        }
                    }) {
                        Text("Make Member", bundle: .module)
                    }
                    .disabled(role == .member)
                    Button(action: { requestViewerDemotion(member) }) {
                        Text("Make Viewer", bundle: .module)
                    }
                    .disabled(role == .viewer)
                } label: {
                    HStack(spacing: 3) {
                        WorkspaceRoleBadge(role: role)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("Change role"))
            } else {
                WorkspaceRoleBadge(role: role)
            }

            if canRemove(member, isSelf: isSelf) {
                Button(action: { pendingDestruction = .removeMember(member) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(theme.tertiaryText.opacity(0.8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Remove from workspace"))
                .disabled(service.isBusy("member.\(member.accountId)"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(rowBackground)
    }

    /// The Agents tab's `connectionRow` recipe.
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(theme.inputBackground.opacity(0.5))
    }

    /// Demoting a member with active shared agents auto-revokes them
    /// server-side (same as removal), so that path confirms first.
    private func requestViewerDemotion(_ member: OsaurusRouterWorkspaceMember) {
        if (member.agentsShared ?? 0) > 0 {
            pendingViewerDemotion = member
        } else {
            Task {
                await service.setMemberRole(
                    workspaceId: workspace.id, accountId: member.accountId, role: .viewer
                )
            }
        }
    }

    /// Owner removes anyone (but not themself — they delete the workspace);
    /// admins remove members and viewers but not other admins. Self-leave
    /// goes through the Overview danger zone, not the roster row.
    private func canRemove(_ member: OsaurusRouterWorkspaceMember, isSelf: Bool) -> Bool {
        guard !isSelf else { return false }
        let role = member.typedRole ?? .member
        switch myRole {
        case .owner: return role != .owner
        case .admin: return role == .member || role == .viewer
        case .member, .viewer: return false
        }
    }

    /// Our roster row, matched by the wallet the router last saw us sign
    /// with (the roster carries `wallet_address`).
    private func myAccountId() -> String? {
        service.members.first { service.isSelf($0) }?.accountId
    }

    // MARK: - Invite links

    private var inviteLinksSection: some View {
        AgentDetailSection(
            title: L("Invite links"),
            icon: "link",
            subtitle: pendingInvites.isEmpty ? nil : "\(pendingInvites.count)"
        ) {
            if pendingInvites.isEmpty {
                AgentSectionEmptyState(
                    icon: "link.badge.plus",
                    title: "No active invite links",
                    hint: "Create a link and send it to a teammate. Links expire in 14 days.",
                    actionLabel: workspaceActive ? "Create invite link" : nil,
                    action: workspaceActive ? { showInviteSheet = true } : nil
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(pendingInvites) { invite in
                        inviteRow(invite)
                    }
                }
            }
        }
    }

    private func inviteRow(_ invite: OsaurusRouterWorkspaceInvite) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(inviteTitle(invite))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(workspaceInviteCaption(invite))
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            if let url = invite.url {
                Button {
                    copyInviteLink(invite.id, url: url)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copiedInviteId == invite.id ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(copiedInviteId == invite.id ? L("Copied") : L("Copy link"))
                    }
                }
                .buttonStyle(SecondaryButtonStyle(size: .compact))
            }

            Button {
                pendingDestruction = .revokeInvite(invite)
            } label: {
                Text("Revoke", bundle: .module)
            }
            .buttonStyle(
                DestructiveButtonStyle(isLoading: service.isBusy("invite.\(invite.id)"), size: .compact)
            )
            .disabled(service.isBusy("invite.\(invite.id)"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(rowBackground)
    }

    private func inviteTitle(_ invite: OsaurusRouterWorkspaceInvite) -> String {
        let role = invite.role.flatMap(OsaurusRouterWorkspaceRole.init(rawValue:)) ?? .member
        return String(format: L("%@ invite link"), role.displayName)
    }

    private func workspaceInviteCaption(_ invite: OsaurusRouterWorkspaceInvite) -> String {
        var parts: [String] = []
        let max = invite.maxUses ?? 1
        let used = invite.uses ?? 0
        parts.append(
            max == 1
                ? L("single use")
                : String(format: L("%d of %d uses"), used, max)
        )
        if let inviter = invite.invitedBy {
            parts.append(
                service.isSelf(inviter)
                    ? L("by you")
                    : String(format: L("by %@"), inviter.friendlyName)
            )
        }
        if let expires = invite.expiresAt, let date = WorkspacesFormatting.date(expires) {
            parts.append(String(format: L("expires %@"), date))
        }
        return parts.joined(separator: " · ")
    }

    private func copyInviteLink(_ inviteId: String, url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        copiedInviteTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { copiedInviteId = inviteId }
        copiedInviteTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { copiedInviteId = nil }
        }
    }

    // MARK: - Shared agents

    /// `used / max` when the tier reports a cap; nil for unlimited.
    private var sharedAgentCap: (used: Int, max: Int)? {
        guard let max = entitlement?.maxSharedAgents else { return nil }
        return (detail?.agentsShared ?? service.workspaceAgents.count, max)
    }

    private var isAtSharedAgentCap: Bool {
        guard let cap = sharedAgentCap else { return false }
        return cap.used >= cap.max
    }

    private var shareHelp: String {
        if !workspaceActive { return L("This workspace isn't active, so sharing is paused") }
        if isAtSharedAgentCap, let cap = sharedAgentCap {
            return String(format: L("This workspace has reached its cap of %d shared agents."), cap.max)
        }
        return L("Share one of your agents with the workspace")
    }

    private var sharedAgentsSection: some View {
        AgentDetailSection(
            title: L("Shared agents"),
            icon: "antenna.radiowaves.left.and.right",
            subtitle: sharedAgentCap.map { "\($0.used) / \($0.max)" }
                ?? (service.workspaceAgents.isEmpty ? nil : "\(service.workspaceAgents.count)"),
            trailing: {
                if myRole.canShareAgents {
                    Button {
                        showShareSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Share agent", bundle: .module)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(size: .compact))
                    .disabled(!workspaceActive || service.isWorking || isAtSharedAgentCap)
                    .help(shareHelp)
                }
            }
        ) {
            if service.workspaceAgents.isEmpty {
                if service.isLoadingDetail {
                    AgentSectionEmptyState(loading: "Loading shared agents…")
                } else if myRole.canShareAgents {
                    AgentSectionEmptyState(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "No shared agents yet",
                        hint: "Share one so teammates can chat with it from their own Osaurus.",
                        actionLabel: workspaceActive && !isAtSharedAgentCap ? "Share agent" : nil,
                        action: workspaceActive && !isAtSharedAgentCap ? { showShareSheet = true } : nil
                    )
                } else {
                    AgentSectionEmptyState(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "No shared agents yet",
                        hint: "Agents your teammates share appear here and in your chat sidebar."
                    )
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(service.workspaceAgents) { agent in
                        WorkspaceSharedAgentRow(
                            identity: identity(for: agent),
                            status: status(for: agent),
                            workspaceId: workspace.id,
                            canManage: canManageInvites,
                            billsThisWorkspace: service.billingWorkspaceId(forAgentAddress: agent.agentAddress)
                                == workspace.id,
                            isUnsharing: service.isBusy("agent.\(agent.agentAddress.lowercased())"),
                            onConnect: { connect(agent) },
                            onChat: { chat(with: agent) },
                            onTurnOnRelay: {
                                if let local = AgentManager.shared.agent(byAddress: agent.agentAddress) {
                                    RelayTunnelManager.shared.setTunnelEnabled(true, for: local.id)
                                }
                            },
                            onUnshare: { pendingDestruction = .unshareAgent(identity(for: agent)) },
                            onSetBilling: { enabled in
                                service.setBillingWorkspace(
                                    agentAddress: agent.agentAddress,
                                    workspaceId: enabled ? workspace.id : nil
                                )
                            }
                        )
                    }
                }
            }
        }
        .settingsLandingAnchor("workspaces.agents")
    }

    /// Identity scoped to THIS workspace (an agent shared into several
    /// workspaces resolves to this one, not the first roster match).
    private func identity(for agent: OsaurusRouterWorkspaceAgent) -> SharedAgentIdentity {
        let address = agent.agentAddress
        let local = agentManager.agent(byAddress: address)
        let isMine = local != nil || service.isSelf(agent.owner)
        return SharedAgentIdentity.make(
            address: address,
            rosterAgent: agent,
            workspace: detail?.asSummary ?? workspace,
            paired: remoteAgents.remoteAgent(forAddress: address, workspaceId: workspace.id),
            localAgent: local,
            localEffectiveModel: local.flatMap { agentManager.effectiveModel(for: $0.id) },
            liveEffectiveModel: nil,
            lastKnownName: nil,
            isMine: isMine
        )
    }

    /// Apply and clear a pending deep-link tab when it targets this workspace.
    private func consumeDeepLinkTab() {
        guard let tab = service.deepLinkTab, service.selectedWorkspaceId == workspace.id else { return }
        selectedTab = tab
        service.deepLinkTab = nil
    }

    private func status(for agent: OsaurusRouterWorkspaceAgent) -> SharedAgentStatus {
        let identity = identity(for: agent)
        if identity.isMine {
            guard let local = identity.localAgent else {
                return .unavailable(reason: L("this agent is no longer on this Mac."), fix: .none)
            }
            return SharedAgentStatus.forOwnAgent(relayStatus: relayManager.agentStatuses[local.id])
        }
        // Touch the observed stores so the row re-renders on pairing changes.
        _ = remoteAgents.remoteAgents
        _ = connectService.connectingAddresses
        return SharedAgentStatus.forTeammateRow(address: agent.agentAddress, workspaceId: workspace.id)
    }

    private func connect(_ agent: OsaurusRouterWorkspaceAgent) {
        Task {
            if await connectService.connect(
                workspaceId: workspace.id,
                agentAddress: agent.agentAddress,
                displayName: agent.displayName
            ) != nil {
                showSuccess(L("Connected. The agent is ready to chat."))
            }
        }
    }

    private func chat(with agent: OsaurusRouterWorkspaceAgent) {
        let identity = identity(for: agent)
        if let local = identity.localAgent {
            ChatWindowManager.shared.openChat(withAgentId: local.id)
        } else if let paired = identity.paired {
            ChatWindowManager.shared.openChat(withRemoteAgentProviderId: paired.providerId)
        }
    }
}

// MARK: - Shared agent row

/// One roster row on the Agents tab's `connectionRow` recipe: identity
/// (avatar · name · badges · short address), the `SharedAgentStatus` line,
/// and the actions that status allows. Own agents show relay presence and
/// a billing toggle; teammates' agents show Chat once paired, else
/// Connect/Retry with the failure reason inline.
private struct WorkspaceSharedAgentRow: View {
    @Environment(\.theme) private var theme

    let identity: SharedAgentIdentity
    let status: SharedAgentStatus
    let workspaceId: String
    /// Owner/admin: may unshare teammates' agents too.
    let canManage: Bool
    let billsThisWorkspace: Bool
    let isUnsharing: Bool
    let onConnect: () -> Void
    let onChat: () -> Void
    let onTurnOnRelay: () -> Void
    let onUnshare: () -> Void
    let onSetBilling: (Bool) -> Void

    private var isMine: Bool { identity.isMine }
    private var isMissingLocally: Bool { identity.isMissingLocally }
    private var isPaired: Bool { identity.paired != nil }
    private var isConnecting: Bool { status == .connecting }
    private var relayOff: Bool {
        if isMine, case .notConnected(_, let attempted) = status { return !attempted }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                avatar

                VStack(alignment: .leading, spacing: 2) {
                    titleRow
                    captionRow
                    if let description = identity.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    statusLine
                }

                Spacer(minLength: 8)

                actions
            }

            if isMine, !isMissingLocally {
                billingToggle
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground.opacity(0.5))
        )
    }

    private var avatar: some View {
        AgentAvatarView(
            mascotId: identity.avatar,
            name: identity.name,
            tint: agentColorFor(identity.name),
            diameter: 30,
            customImageURL: identity.customAvatarURL,
            monogramFontSize: 12,
            borderWidth: 1.5
        )
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(theme.cardBackground, lineWidth: 1.5))
                .offset(x: 1, y: 1)
        }
        .opacity(isMissingLocally ? 0.6 : 1)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(identity.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            if isMine {
                CapsuleBadge(L("Yours"), tint: theme.accentColor, style: .tag)
            }
            if let model = identity.modelLabel {
                CapsuleBadge(
                    model,
                    tint: theme.secondaryText,
                    icon: "cpu",
                    help: identity.model.map { String(format: L("Runs on %@"), $0) }
                )
            }
        }
    }

    /// Short address (full in tooltip) · shared by · shared as — short so
    /// the attribution survives truncation at narrow widths.
    private var captionRow: some View {
        var parts: [String] = [identity.shortAddress]
        if let owner = identity.ownerName {
            parts.append(String(format: L("shared by %@"), owner))
        }
        if let sharedAs = identity.sharedAsName {
            parts.append(String(format: L("shared as “%@”"), sharedAs))
        }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(theme.tertiaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(identity.address)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if isConnecting {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: status.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(statusColor)
            }
            Text(statusText)
                .font(.system(size: 10.5))
                .foregroundColor(statusTextColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private var statusText: String {
        if isMissingLocally {
            return L("No longer on this Mac — teammates can't reach it. Unshare to clean up.")
        }
        switch status {
        case .ready:
            return isMine
                ? L("Relay on — teammates can reach it")
                : (isPaired ? L("Connected — ready to chat") : L("Online"))
        case .checking: return L("Checking access and availability…")
        case .connecting:
            return isMine ? L("Relay connecting…") : L("Connecting…")
        case .offline(let lastSeen):
            if let lastSeen {
                return String(format: L("Offline · last seen %@"), SharedAgentStatus.relative(lastSeen))
            }
            return L("Offline — the host's Osaurus isn't reachable")
        case .notConnected(let reason, let attempted):
            if isMine {
                return L("Relay off — teammates can't reach it")
            }
            if attempted, let reason, !reason.isEmpty {
                return String(format: L("Couldn't connect: %@"), SharedAgentStatus.sentence(reason))
            }
            return L("Not connected on this Mac yet")
        case .unavailable(let reason, _):
            return SharedAgentStatus.sentence(reason)
        case .readOnlyTeammate:
            return status.shortLabel
        }
    }

    private var statusColor: Color {
        if isMissingLocally { return theme.tertiaryText }
        switch status.tint {
        case .success: return theme.successColor
        case .accent: return theme.accentColor
        case .warning: return theme.warningColor
        case .muted: return theme.tertiaryText
        }
    }

    private var statusTextColor: Color {
        if case .notConnected(_, let attempted) = status, attempted || isMine {
            return theme.warningColor
        }
        return theme.tertiaryText
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if isMine {
                if relayOff, !isMissingLocally {
                    Button(action: onTurnOnRelay) {
                        HStack(spacing: 5) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Turn on relay", bundle: .module)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(size: .compact))
                    .help(L("Teammates reach this agent through its relay tunnel"))
                }
                if !isMissingLocally {
                    Button(action: onChat) {
                        Text("Chat", bundle: .module)
                    }
                    .buttonStyle(SecondaryButtonStyle(size: .compact))
                }
            } else if isPaired {
                Button(action: onChat) {
                    Text("Chat", bundle: .module)
                }
                .buttonStyle(PrimaryButtonStyle(size: .compact))
            } else {
                Button(action: onConnect) {
                    Text(isConnecting ? L("Connecting…") : (status.actionLabel ?? L("Connect")))
                }
                .buttonStyle(PrimaryButtonStyle(isLoading: isConnecting, size: .compact))
                .disabled(isConnecting)
            }

            if isMine || canManage {
                Button(action: onUnshare) {
                    Text("Unshare", bundle: .module)
                }
                .buttonStyle(DestructiveButtonStyle(isLoading: isUnsharing, size: .compact))
                .disabled(isUnsharing)
            }
        }
    }

    private var billingToggle: some View {
        SettingsToggle(
            title: L("Bill the workspace pool"),
            description: L(
                "This agent's Osaurus cloud calls draw from the workspace's shared credits. Off, they bill your own balance."
            ),
            isOn: Binding(get: { billsThisWorkspace }, set: onSetBilling)
        )
        .padding(.leading, 40)
    }
}
