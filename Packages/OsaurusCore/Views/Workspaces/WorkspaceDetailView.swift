//
//  WorkspaceDetailView.swift
//  osaurus
//
//  One workspace, on the `AgentDetailView` shell: the shared header bar
//  (back · identity · status · actions), an Overview page whose last group
//  pushes Members / Shared agents / Workflows / Audit sub-pages, and `SettingsSection`
//  groups on every page. Confirmations go through `themedAlert`, success through the
//  parent's toast, errors through `InlineBanner` — the same vocabulary the
//  Agents tab uses, so a workspace reads like any other thing you manage.
//

import AppKit
import SwiftUI

struct WorkspaceDetailView: View {
    enum Tab: Hashable, SettingsDrillInItem {
        case overview
        case members
        case sharedAgents
        case workflows
        case audit

        var id: Self { self }

        /// The catalog's `subTab` value for each page (`SettingsSearchEntry.subTab`).
        init?(subTab: String) {
            switch subTab {
            case "overview": self = .overview
            case "members": self = .members
            case "sharedAgents": self = .sharedAgents
            case "workflows": self = .workflows
            case "audit": self = .audit
            default: return nil
            }
        }

        var title: String {
            switch self {
            case .overview: return L("Overview")
            case .members: return L("Members")
            case .sharedAgents: return L("Shared agents")
            case .workflows: return L("Workflows")
            case .audit: return L("Audit (this Mac)")
            }
        }

        var icon: String {
            switch self {
            case .overview: return "info.circle"
            case .members: return "person.2.fill"
            case .sharedAgents: return "antenna.radiowaves.left.and.right"
            case .workflows: return "square.stack.3d.up"
            case .audit: return "list.bullet.clipboard.fill"
            }
        }

        var subtitle: String {
            switch self {
            case .overview: return ""
            case .members: return L("People in this workspace and invite links.")
            case .sharedAgents: return L("Agents teammates have shared here.")
            case .workflows: return L("Workflows and agents members shared here to install.")
            case .audit: return L("What this Mac recorded: who changed what, and when.")
            }
        }
    }

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var service = WorkspacesService.shared
    @ObservedObject private var connectService = WorkspaceAgentConnectService.shared
    /// Observed so a completed connect flips the row's button to "Chat".
    @ObservedObject private var remoteAgents = RemoteAgentManager.shared
    /// Observed for own-agent rows: their presence is the relay tunnel state.
    @ObservedObject private var relayManager = RelayTunnelManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @Environment(\.themedAlertScope) private var alertScope
    private var theme: any ThemeProtocol { themeManager.currentTheme }

    let workspace: OsaurusRouterWorkspaceSummary
    var initialTab: Tab = .overview
    let onBack: () -> Void
    /// Bottom toast owned by `WorkspacesView` (same as the Agents tab).
    var showSuccess: (String) -> Void = { _ in }

    @State private var selectedTab: Tab = .overview
    @State private var showInviteSheet = false
    @State private var showShareSheet = false
    /// Agent the Share agent sheet opens with (deep link from the chat
    /// sidebar); nil when opened from the tab's own button.
    @State private var shareSheetPreselectedAgentId: UUID?
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
    @State private var orchestratorAutoJoin = true

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
    private var workspaceColor: Color { theme.dataInk(seed: workspaceName) }

    var body: some View {
        SettingsPage {
            header
        } content: {
            banners
            tabSections
        }
        .id(selectedTab)
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
            // Presence: while the sync stream is verified it reconciles
            // `online`/`last_seen` every ~15s and pushes the roster here, so
            // no request is made. Only without a verified stream (older
            // router, offline) does this fall back to a 30s presence poll.
            // Each pass also auto-connects any shared agent this member
            // hasn't paired with yet (hosts that just came online included),
            // so the roster is "ready to chat" without a Connect click.
            await autoConnectSharedAgents()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                if !WorkspaceSyncService.shared.isVerified {
                    await service.refreshAgentsPresence()
                }
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
        .sheet(isPresented: $showShareSheet, onDismiss: { shareSheetPreselectedAgentId = nil }) {
            WorkspaceShareAgentSheet(
                workspaceId: workspace.id,
                preselectedAgentId: shareSheetPreselectedAgentId,
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
            message: L("You'll lose access to the workspace's shared agents, workflows, and workspace credits. Your shared agents are revoked and your shared workflows leave its catalog."),
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
        let onOverview = selectedTab == .overview
        return SettingsPageHeader(
            title: onOverview ? workspaceName : selectedTab.title,
            verbatimTitle: true,
            subtitle: onOverview && !overviewCaption.isEmpty ? overviewCaption : nil,
            verbatimSubtitle: true,
            onRefresh: { Task { await service.refreshSelectedWorkspace() } },
            isRefreshing: service.isLoadingDetail,
            leading: {
                AgentHeaderAvatar(mascotId: nil, name: workspaceName, tint: workspaceColor)
            },
            status: {
                WorkspaceRoleBadge(role: myRole)
                statusBadge
            },
            utilities: {
                SettingsIconButton("clock.arrow.circlepath", help: "Credit Activity") { showPoolActivity = true }
            }
        )
        .settingsBackDestination(onOverview ? L("Workspaces") : workspaceName, verbatim: true) {
            if onOverview { onBack() } else { selectedTab = .overview }
        }
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

    // MARK: - Pages

    private var subPageBadges: [Tab: Int] {
        var badges: [Tab: Int] = [:]
        if !service.members.isEmpty { badges[.members] = service.members.count }
        if !service.workspaceAgents.isEmpty { badges[.sharedAgents] = service.workspaceAgents.count }
        return badges
    }

    @ViewBuilder
    private var tabSections: some View {
        switch selectedTab {
        case .overview:
            poolSection
            if isOwner {
                nameSection
            }
            SettingsDrillInList(
                items: [.members, .sharedAgents, .workflows, .audit],
                badges: subPageBadges
            ) { selectedTab = $0 }
            dangerZoneSection
        case .members:
            membersSection
            if canManageInvites {
                inviteLinksSection
            }
        case .sharedAgents:
            sharedAgentsSection
        case .workflows:
            WorkspaceWorkflowsSection(
                workspaceId: workspace.id, workspaceActive: workspaceActive && !isSuspended,
                canModerate: canManageInvites)
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
        SettingsSection(
            title: "Workspace Credits",
            accessory: { statusBadge }
        ) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                    Text(
                        verbatim: OsaurusRouter.formatMicroAsCreditsValue(
                            service.poolBalance?.balanceMicro ?? detail?.balanceMicro ?? "0"
                        )
                    )
                    .componentInspectionText(49, role: .body, fallback: .code, weight: 600, theme: theme)
                    .foregroundColor(
                        detail?.poolFrozen == true || !workspaceActive
                            ? theme.status.warning.foreground : theme.text.primary
                    )
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    Text("credits", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.rowTitle)
                        .foregroundColor(theme.text.secondary)
                }
                if service.isLoadingDetail && detail == nil {
                    SettingsSpinner()
                }
                Spacer(minLength: 8)
                // Owner-only money: buy credits that never expire, or arm
                // auto-reload. Both need an active workspace (a suspended
                // pool is refused with SUBSCRIPTION_INACTIVE).
                if isOwner, !isSuspended {
                    Button {
                        showTopUp = true
                    } label: {
                        HStack(spacing: theme.space.s6) {
                            Image(systemName: "plus.circle.fill")
                                .glyphSize(.footnote, weight: .semibold)
                            Text("Add credits…", bundle: .module)
                        }
                    }
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
                    .disabled(service.pendingConfirmation != nil)
                    .help(L("Buy workspace credits ($5–$500). Purchased credits never expire."))
                    Button {
                        showAutoReload = true
                    } label: {
                        HStack(spacing: theme.space.s6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .glyphSize(.footnote, weight: .semibold)
                            Text("Auto-reload…", bundle: .module)
                        }
                    }
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
                    .help(L("Refill workspace credits from your saved card when they run low"))
                }
            }

            Text(poolSubline)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)

            if let breakdown = poolBreakdown {
                HStack(spacing: theme.space.s6) {
                    Text(breakdown)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                    if let chip = autoReloadChip {
                        StatusChip(chip.label, tint: chip.tint, icon: "arrow.triangle.2.circlepath", help: chip.help)
                    }
                }
            } else if let chip = autoReloadChip {
                StatusChip(chip.label, tint: chip.tint, icon: "arrow.triangle.2.circlepath", help: chip.help)
            }

            if let syncingCopy {
                HStack(spacing: theme.space.s8) {
                    SettingsSpinner(size: .mini)
                    Text(syncingCopy)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)

                    Spacer(minLength: 8)

                    // Escape hatch for a portal/checkout visit that changed
                    // nothing — the wait also self-clears after a bounded
                    // number of polls.
                    Button(action: { service.dismissSubscriptionWait() }) {
                        Image(systemName: "xmark")
                            .glyphSize(.tiny, weight: .semibold)
                            .foregroundColor(theme.text.tertiary)
                            .padding(.horizontal, theme.space.s4).padding(.vertical, theme.space.s4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Stop waiting (e.g. you closed the browser tab without changes)"))
                }
            }

            Divider()

            HStack(alignment: .top, spacing: theme.space.s12) {
                planFacts
                Spacer()
                Button {
                    showPoolActivity = true
                } label: {
                    HStack(spacing: theme.space.s6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .glyphSize(.footnote, weight: .semibold)
                        Text("Credit Activity", bundle: .module)
                    }
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
                .help(L("Who spent what from workspace credits, plus monthly grants and expirations"))
                if isOwner, isSuspended {
                    Button {
                        Task { await service.reactivateWorkspace(id: workspace.id) }
                    } label: {
                        HStack(spacing: theme.space.s6) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .glyphSize(.footnote, weight: .semibold)
                            Text("Reactivate…", bundle: .module)
                        }
                    }
                    .buttonStyle(
                        .settings(.primary, isLoading: service.isBusy("workspace.reactivate"))
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
                        HStack(spacing: theme.space.s6) {
                            Image(systemName: "arrow.up.right.square")
                                .glyphSize(.footnote, weight: .semibold)
                            Text("Manage billing", bundle: .module)
                        }
                    }
                    .buttonStyle(
                        .settings(.secondary, isLoading: service.isBusy("subscription.portal"), size: .compact)
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
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
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
                format: L("Finish the %@ payment in your browser. Workspace credits update automatically once Stripe confirms."),
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
                L("Auto-reload paused"), theme.status.warning.foreground,
                isOwner
                    ? L("Reloads stopped after failed charges. Open Auto-reload… to fix the card and re-arm.")
                    : L("The owner's auto-reload stopped after failed charges.")
            )
        }
        return (
            L("Auto-reload on"), theme.status.success.foreground,
            L("The owner's saved card refills workspace credits when they run low.")
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
                ? L("Credits paused until the owner reactivates this workspace.")
                : L("Credits paused until the owner's subscription is current.")
        }
        if detail?.poolFrozen == true {
            return L("Credits paused.")
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
            ? L("Invites, shared agents, and inference billed to workspace credits are paused until your subscription is current. Past-due? Update the card under Manage billing.")
            : L("The workspace's subscription isn't active right now, so invites, shared agents, and inference billed to workspace credits are paused. Only the owner can renew.")
    }

    /// "Credits · trial ends/renews date · seats 2/5 · agents 1/3 · owner"
    /// fact line. Seat and agent caps only appear when the plan actually has
    /// one — an unlimited lever (`nil`) is not worth a "∞" fact.
    @ViewBuilder
    private var planFacts: some View {
        HStack(spacing: theme.space.s12) {
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
        VStack(alignment: .leading, spacing: theme.space.s2) {
            Text(label)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                .foregroundColor(theme.text.tertiary)
                .kerning(0.4)
            Text(value)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
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
        SettingsSection(title: "Name") {
            HStack(spacing: theme.space.s8) {
                SettingsTextField(
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
                .assignedSettingsButtonStyle(.primary, isLoading: service.isBusy("workspace.rename"))
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
            .componentInspectionText(49, role: .caption, fallback: .footnote, theme: theme)
            .foregroundColor(renameIsValid ? theme.text.tertiary : theme.status.warning.foreground)
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
        let busyKey = isOwner ? "workspace.delete" : "member.leave"
        return SettingsDestructiveZone {
            SettingsRow(
                title: isOwner ? "Delete This Workspace" : "Leave This Workspace",
                description: isOwner
                    ? "Removes the workspace for everyone and revokes shared agents and invites."
                    : "You'll lose access to shared agents; agents you shared are revoked."
            ) {
                SettingsButton(
                    .destructive,
                    isOwner ? "Delete…" : "Leave…",
                    icon: isOwner ? "trash" : "rectangle.portrait.and.arrow.right",
                    isLoading: service.isBusy(busyKey),
                    size: .compact
                ) {
                    if isOwner {
                        showDeleteConfirm = true
                    } else {
                        showLeaveConfirm = true
                    }
                }
                .disabled(service.isBusy(busyKey))
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
            return L("They lose access to the workspace's shared agents and workspace credits, and any agents they shared are revoked.")
        case .revokeInvite:
            return L(
                "Anyone who still has this link won't be able to join with it. People who already joined stay on the workspace."
            )
        case .unshareAgent:
            return L("Teammates lose access immediately, and the agent can no longer bill workspace credits.")
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
        SettingsSection(
            title: "Members",
            caption: service.members.isEmpty ? nil : "\(service.members.count)",
            accessory: {
                if canManageInvites {
                    Button {
                        showInviteSheet = true
                    } label: {
                        HStack(spacing: theme.space.s6) {
                            Image(systemName: "link.badge.plus")
                                .glyphSize(.footnote, weight: .semibold)
                            Text("Invite", bundle: .module)
                        }
                    }
                    .assignedSettingsButtonStyle(.primary, size: .compact)
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
                    SettingsEmptyState(loading: "Loading members…")
                } else {
                    SettingsEmptyState(
                        inline: "person.2",
                        title: "No members loaded",
                        hint: "Refresh to load the member list.",
                        action: SettingsEmptyState.Action(title: L("Refresh"), icon: "", handler: { Task { await service.refreshSelectedWorkspace() } })
                    )
                }
            } else {
                VStack(spacing: theme.space.s8) {
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
        return HStack(spacing: theme.space.s8) {
            ParticipantAvatar(name: member.friendlyName, seed: member.walletAddress ?? member.accountId)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s6) {
                    Text(member.friendlyName)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    if isSelf {
                        StatusChip(L("You"), tint: theme.text.secondary)
                    }
                }
                if let wallet = member.walletAddress, !wallet.isEmpty {
                    let short = OsaurusRouterWorkspacePerson.shortWallet(wallet)
                    if short != member.friendlyName {
                        Text(short)
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                            .foregroundColor(theme.text.tertiary)
                            .help(wallet)
                    }
                }
            }

            Spacer()

            if let count = member.agentsShared, count > 0 {
                StatusChip(
                    count == 1 ? L("1 agent") : String(format: L("%d agents"), count),
                    tint: theme.text.tertiary,
                    icon: "antenna.radiowaves.left.and.right"
                )
            }

            if isOwner, role != .owner {
                SettingsMenuButton(.secondary, role.displayName, size: .compact, verbatim: true) {
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
                }
                .help(L("Change role"))
            } else {
                WorkspaceRoleBadge(role: role)
            }

            if canRemove(member, isSelf: isSelf) {
                Button(action: { pendingDestruction = .removeMember(member) }) {
                    Image(systemName: "xmark.circle.fill")
                        .glyphSize(.label)
                        .foregroundColor(theme.text.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Remove from workspace"))
                .disabled(service.isBusy("member.\(member.accountId)"))
            }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.inset)
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
        SettingsSection(
            title: "Invite Links",
            caption: pendingInvites.isEmpty ? nil : "\(pendingInvites.count)"
        ) {
            if pendingInvites.isEmpty {
                SettingsEmptyState(
                    inline: "link.badge.plus",
                    title: "No active invite links",
                    hint: "Create a link and send it to a teammate. Links expire in 14 days.",
                    action: workspaceActive
                        ? SettingsEmptyState.Action(title: L("Create invite link"), icon: "", handler: { showInviteSheet = true }) : nil
                )
            } else {
                VStack(spacing: theme.space.s8) {
                    ForEach(pendingInvites) { invite in
                        inviteRow(invite)
                    }
                }
            }
        }
    }

    private func inviteRow(_ invite: OsaurusRouterWorkspaceInvite) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: "link")
                .glyphSize(.footnote, weight: .medium)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(inviteTitle(invite))
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Text(workspaceInviteCaption(invite))
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }

            Spacer()

            if let url = invite.url {
                Button {
                    copyInviteLink(invite.id, url: url)
                } label: {
                    HStack(spacing: theme.space.s6) {
                        Image(systemName: copiedInviteId == invite.id ? "checkmark" : "doc.on.doc")
                            .glyphSize(.footnote, weight: .semibold)
                        Text(copiedInviteId == invite.id ? L("Copied") : L("Copy link"))
                    }
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
            }

            Button {
                pendingDestruction = .revokeInvite(invite)
            } label: {
                Text("Revoke", bundle: .module)
            }
            .buttonStyle(
                .settings(.destructive, isLoading: service.isBusy("invite.\(invite.id)"), size: .compact)
            )
            .disabled(service.isBusy("invite.\(invite.id)"))
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.inset)
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
        withAnimation(theme.motion.quick) { copiedInviteId = inviteId }
        copiedInviteTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(theme.motion.quick) { copiedInviteId = nil }
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
        SettingsSection(
            title: "Shared Agents",
            caption: sharedAgentCap.map { "\($0.used) / \($0.max)" }
                ?? (service.workspaceAgents.isEmpty ? nil : "\(service.workspaceAgents.count)"),
            accessory: {
                if myRole.canShareAgents {
                    Button {
                        showShareSheet = true
                    } label: {
                        HStack(spacing: theme.space.s6) {
                            Image(systemName: "plus")
                                .glyphSize(.footnote, weight: .semibold)
                            Text("Share agent", bundle: .module)
                        }
                    }
                    .assignedSettingsButtonStyle(.primary, size: .compact)
                    .disabled(!workspaceActive || service.isWorking || isAtSharedAgentCap)
                    .help(shareHelp)
                }
            }
        ) {
            orchestratorAutoJoinToggle
            if service.workspaceAgents.isEmpty {
                if service.isLoadingDetail {
                    SettingsEmptyState(loading: "Loading shared agents…")
                } else if myRole.canShareAgents {
                    SettingsEmptyState(
                        inline: "antenna.radiowaves.left.and.right",
                        title: "No shared agents yet",
                        hint: "Share one so teammates can chat with it from their own Osaurus.",
                        action: workspaceActive && !isAtSharedAgentCap
                            ? SettingsEmptyState.Action(title: L("Share agent"), icon: "", handler: { showShareSheet = true }) : nil
                    )
                } else {
                    SettingsEmptyState(
                        inline: "antenna.radiowaves.left.and.right",
                        title: "No shared agents yet",
                        hint: "Agents your teammates share appear here and in your chat sidebar."
                    )
                }
            } else {
                VStack(spacing: theme.space.s8) {
                    // The billing switch renders per hosted-here row; only the
                    // first carries the search anchor so the id is unique.
                    let firstHostedHere = service.workspaceAgents.first {
                        agentManager.agent(byAddress: $0.agentAddress) != nil
                    }?.agentAddress.lowercased()
                    ForEach(service.workspaceAgents) { agent in
                        WorkspaceSharedAgentRow(
                            identity: identity(for: agent),
                            status: status(for: agent),
                            workspaceId: workspace.id,
                            canManage: canManageInvites,
                            billsThisWorkspace: service.billingWorkspaceId(forAgentAddress: agent.agentAddress)
                                == workspace.id,
                            billingAnchorId: agent.agentAddress.lowercased() == firstHostedHere
                                ? "workspaces.agents.billPool" : nil,
                            approvalAnchorId: agent.agentAddress.lowercased() == firstHostedHere
                                ? "workspaces.agents.askOwnerApproval" : nil,
                            isUnsharing: service.isBusy("agent.\(agent.agentAddress.lowercased())"),
                            onConnect: { connect(agent) },
                            onChat: { chat(with: agent) },
                            onTurnOnRelay: {
                                if let local = AgentManager.shared.agent(byAddress: agent.agentAddress) {
                                    RemoteAccessConsent.request(for: local, scope: alertScope)
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

    /// Per-workspace switch for the Orchestrator's delegation pool: on
    /// (default), every teammate agent shared here joins "Allowed
    /// subagents" automatically as the roster loads; off prunes this
    /// workspace's agents from the pool and stops auto-joining. Declarative
    /// twin: `delegation.workspace_auto_join`.
    private var orchestratorAutoJoinToggle: some View {
        SettingsToggle(
            title: "Let the Orchestrator delegate to shared agents",
            description: L(
                "Teammates' agents shared in this workspace join the Orchestrator's Allowed subagents automatically. Off removes them from that list; delegating still asks for permission (Settings → Orchestrator)."
            ),
            anchorId: "workspaces.agents.orchestratorAutoJoin",
            isOn: Binding(
                get: { orchestratorAutoJoin },
                set: { enabled in
                    orchestratorAutoJoin = enabled
                    SubagentConfigurationStore.mutate { config in
                        config.setWorkspaceAutoJoin(enabled, workspaceId: workspace.id)
                    }
                    // Re-run the join/prune step now instead of waiting for
                    // the next roster tick so the pool reflects the switch.
                    WorkspaceRosterStore.shared.reconcileSpawnPoolNow()
                }
            )
        )
        .padding(.bottom, theme.space.s4)
        .onAppear {
            orchestratorAutoJoin =
                SubagentConfigurationStore.snapshot().workspaceAutoJoinEnabled(workspace.id)
        }
    }

    /// Identity scoped to THIS workspace (an agent shared into several
    /// workspaces resolves to this one, not the first roster match).
    private func identity(for agent: OsaurusRouterWorkspaceAgent) -> SharedAgentIdentity {
        let address = agent.agentAddress
        let local = agentManager.agent(byAddress: address)
        return SharedAgentIdentity.make(
            address: address,
            rosterAgent: agent,
            workspace: detail?.asSummary ?? workspace,
            paired: remoteAgents.remoteAgent(forAddress: address, workspaceId: workspace.id),
            localAgent: local,
            localEffectiveModel: local.flatMap { agentManager.effectiveModel(for: $0.id) },
            liveEffectiveModel: nil,
            lastKnownName: nil,
            isOwnedByMe: service.isSelf(agent.owner)
        )
    }

    /// Apply and clear a pending deep-link tab when it targets this workspace.
    private func consumeDeepLinkTab() {
        guard let tab = service.deepLinkTab, service.selectedWorkspaceId == workspace.id else { return }
        selectedTab = tab
        service.deepLinkTab = nil
        // "Share to Workspace" from the chat sidebar: open the Share agent
        // sheet with that agent already selected. Viewers can't share, so
        // for them the link just lands on the Shared agents tab.
        if let agentId = service.deepLinkShareAgentId {
            service.deepLinkShareAgentId = nil
            if myRole.canShareAgents {
                shareSheetPreselectedAgentId = agentId
                showShareSheet = true
            }
        }
    }

    private func status(for agent: OsaurusRouterWorkspaceAgent) -> SharedAgentStatus {
        let identity = identity(for: agent)
        // Only an agent hosted on THIS Mac reports relay state. An own agent
        // on another of the user's devices is remote from here and takes
        // the teammate path (presence + pairing).
        if let local = identity.localAgent {
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
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let identity: SharedAgentIdentity
    let status: SharedAgentStatus
    let workspaceId: String
    /// Owner/admin: may unshare teammates' agents too.
    let canManage: Bool
    let billsThisWorkspace: Bool
    /// Settings-search landing anchor for the billing switch; set on the
    /// first hosted-here row only, so the id stays unique in the list.
    var billingAnchorId: String? = nil
    /// Same rule for the owner-approval switch.
    var approvalAnchorId: String? = nil
    let isUnsharing: Bool
    let onConnect: () -> Void
    let onChat: () -> Void
    let onTurnOnRelay: () -> Void
    let onUnshare: () -> Void
    let onSetBilling: (Bool) -> Void

    /// Hosted on this Mac: relay/billing/local-chat affordances.
    private var isMine: Bool { identity.isHostedHere }
    /// Shared by this identity from another device: labelled yours, reached
    /// like a teammate's.
    private var isOwnedElsewhere: Bool { identity.isOwnedElsewhere }
    private var isPaired: Bool { identity.paired != nil }
    private var isConnecting: Bool { status == .connecting }
    private var relayOff: Bool {
        if isMine, case .notConnected(_, let attempted) = status { return !attempted }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(alignment: .top, spacing: theme.space.s8) {
                avatar

                VStack(alignment: .leading, spacing: theme.space.s2) {
                    titleRow
                    captionRow
                    if let description = identity.description, !description.isEmpty {
                        Text(description)
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    statusLine
                }

                Spacer(minLength: 8)

                actions
            }

            if isMine {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    billingToggle
                    ownerApprovalToggle
                }
                .padding(.leading, theme.space.s40)
            }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.inset)
    }

    private var avatar: some View {
        AgentAvatarView(
            mascotId: identity.avatar,
            name: identity.name,
            tint: theme.dataInk(seed: identity.name),
            diameter: 30,
            customImageURL: identity.customAvatarURL,
            monogramFontSize: 12,
            borderWidth: 1.5
        )
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(theme.surface.raised, lineWidth: theme.stroke.default))
                .offset(x: 1, y: 1)
        }
    }

    private var titleRow: some View {
        HStack(spacing: theme.space.s6) {
            Text(identity.name)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
            if isMine {
                StatusChip(L("Yours"), tint: theme.action.primary.default.background)
            } else if isOwnedElsewhere {
                StatusChip(
                    L("Yours · other device"),
                    tint: theme.action.primary.default.background,
                    help: L(
                        "Shared by your identity from another device. Reached through the relay like a teammate's agent."
                    )
                )
            }
            if let model = identity.modelLabel {
                StatusChip(
                    model,
                    tint: theme.text.secondary,
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
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
            .foregroundColor(theme.text.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(identity.address)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
            if isConnecting {
                SettingsSpinner(size: .mini)
            } else {
                Image(systemName: status.symbolName)
                    .glyphSize(.micro, weight: .semibold)
                    .foregroundColor(statusColor)
            }
            Text(statusText)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                .foregroundColor(statusTextColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, theme.space.s2)
    }

    private var statusText: String {
        switch status {
        case .ready:
            return isMine
                ? L("Remote access on — teammates can reach it")
                : (isPaired ? L("Connected — ready to chat") : L("Online"))
        case .checking: return L("Checking access and availability…")
        case .connecting:
            return isMine ? L("Remote access connecting…") : L("Connecting…")
        case .offline(let lastSeen):
            if let lastSeen {
                return String(format: L("Offline · last seen %@"), SharedAgentStatus.relative(lastSeen))
            }
            return L("Offline — the host's Osaurus isn't reachable")
        case .notConnected(let reason, let attempted):
            if isMine {
                return L("Remote access off — teammates can't reach it")
            }
            if attempted, let reason, !reason.isEmpty {
                return String(format: L("Couldn't connect: %@"), SharedAgentStatus.sentence(reason))
            }
            return L("Not connected on this Mac yet")
        case .unavailable(let reason, _):
            return SharedAgentStatus.sentence(reason)
        case .accessRevoked, .readOnlyTeammate:
            return status.shortLabel
        }
    }

    private var statusColor: Color {
        switch status.tint {
        case .success: return theme.status.success.foreground
        case .accent: return theme.action.primary.default.background
        case .warning: return theme.status.warning.foreground
        case .muted: return theme.text.tertiary
        }
    }

    private var statusTextColor: Color {
        if case .notConnected(_, let attempted) = status, attempted || isMine {
            return theme.status.warning.foreground
        }
        return theme.text.tertiary
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: theme.space.s8) {
            if isMine {
                if relayOff {
                    Button(action: onTurnOnRelay) {
                        HStack(spacing: theme.space.s6) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .glyphSize(.footnote, weight: .semibold)
                            Text("Turn on remote access", bundle: .module)
                        }
                    }
                    .assignedSettingsButtonStyle(.primary, size: .compact)
                    .help(L("Teammates reach this agent through remote access"))
                }
                Button(action: onChat) {
                    Text("Chat", bundle: .module)
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
            } else if isPaired {
                Button(action: onChat) {
                    Text("Chat", bundle: .module)
                }
                .assignedSettingsButtonStyle(.primary, size: .compact)
            } else {
                Button(action: onConnect) {
                    Text(isConnecting ? L("Connecting…") : (status.actionLabel ?? L("Connect")))
                }
                .assignedSettingsButtonStyle(.primary, isLoading: isConnecting, size: .compact)
                .disabled(isConnecting)
            }

            // Unshare is an ownership right (any of the owner's devices), or
            // an owner/admin management right.
            if identity.isOwnedByMe || canManage {
                Button(action: onUnshare) {
                    Text("Unshare", bundle: .module)
                }
                .assignedSettingsButtonStyle(.destructive, isLoading: isUnsharing, size: .compact)
                .disabled(isUnsharing)
            }
        }
    }

    /// On by default for every agent you share: `WorkspacesService` binds
    /// the agent to the first workspace whose roster lists it. Off records a
    /// per-agent opt-out so the roster-driven default never flips it back.
    private var billingToggle: some View {
        SettingsToggle(
            title: "Bill Workspace Credits",
            description: L(
                "On by default for agents you share: your own chats with this agent use this workspace's credits too. Teammates' chats always do. Off, your own chats bill your personal balance."
            ),
            isOn: Binding(get: { billsThisWorkspace }, set: onSetBilling)
        )
        .settingsLandingAnchor(billingAnchorId)
    }

    /// The agent's `sharedToolApproval`: off fails a teammate's call to a
    /// tool that needs approval; on parks it for the owner. The timeout row
    /// stays in place (disabled while off) so the section doesn't jump.
    @ViewBuilder
    private var ownerApprovalToggle: some View {
        if let local = AgentManager.shared.agent(byAddress: identity.address) {
            let policy = local.sharedToolApproval
            let asksOwner = policy?.mode == .askOwner
            let timeout = Int(
                policy?.effectiveTimeout ?? TimeInterval(SharedToolApprovalPolicy.defaultTimeoutSeconds))
            SettingsToggle(
                title: "Require Approval for Teammate Tool Calls",
                description:
                    "When someone else's chat with this agent reaches a tool that needs approval, it waits for you: allow it in the conversation, from the notification, in the Inbox or on your iPhone. Off, those tool calls fail.",
                isOn: Binding(
                    get: { asksOwner },
                    set: { on in
                        var updated = local
                        updated.sharedToolApproval =
                            on
                            ? SharedToolApprovalPolicy(
                                mode: .askOwner, timeoutSeconds: local.sharedToolApproval?.timeoutSeconds)
                            : nil
                        AgentManager.shared.update(updated)
                    }
                )
            )
            .settingsLandingAnchor(approvalAnchorId)

            SettingsPickerRow(
                title: "Decline Unanswered Requests After",
                description: "The teammate's tool call is declined if you haven't answered by then.",
                anchorId: approvalAnchorId == nil ? nil : "workspaces.agents.ownerApprovalTimeout",
                style: .menu,
                selection: Binding(
                    get: { timeout },
                    set: { seconds in
                        var updated = local
                        updated.sharedToolApproval = SharedToolApprovalPolicy(
                            mode: .askOwner, timeoutSeconds: seconds)
                        AgentManager.shared.update(updated)
                    }
                ),
                options: Self.timeoutOptions(including: timeout)
            )
            .disabled(!asksOwner)
        }
    }

    /// Preset waits, plus a value set declaratively that isn't one of them.
    static func timeoutOptions(including current: Int) -> [SettingsPickerRow<Int>.Option] {
        var options: [SettingsPickerRow<Int>.Option] = [
            .init(300, "5 minutes"), .init(600, "10 minutes"), .init(1800, "30 minutes"),
            .init(3600, "1 hour"), .init(14_400, "4 hours"), .init(86_400, "24 hours"),
        ]
        if !options.contains(where: { $0.value == current }) {
            let label =
                Duration.seconds(current).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
            options.append(.init(current, label, verbatim: true))
            options.sort { $0.value < $1.value }
        }
        return options
    }
}

extension WorkspaceDetailView {
    @MainActor static func inspectionSharedRows(action: @escaping () -> Void) -> some View {
        let theme = ThemeManager.shared.currentTheme
        let states: [SharedAgentStatus] = [.ready, .connecting, .checking, .offline(lastSeen: Date()), .notConnected(reason: "Local connection failure", hasAttempted: true), .unavailable(reason: "Local unavailable display", fix: .none)]
        return VStack(alignment: .leading, spacing: theme.space.s12) {
            ForEach(Array(states.enumerated()), id: \.offset) { index, status in
                WorkspaceSharedAgentRow(identity: SharedAgentIdentity(address: "local-display-\(index)", name: "Local shared agent \(index + 1)", avatar: "green", customAvatarURL: nil, model: "Local model", ownerName: "Local teammate", workspaceId: "local-display", workspaceName: "Local workspace", description: "Local display only; no pairing or sharing action.", isOwnedByMe: index == 0, isHostedHere: index == 0, localAgent: index == 0 ? .default : nil, paired: nil, rosterAgent: nil), status: status, workspaceId: "local-display", canManage: true, billsThisWorkspace: true, isUnsharing: false, onConnect: action, onChat: action, onTurnOnRelay: action, onUnshare: action, onSetBilling: { _ in action() })
            }
        }
    }
}
