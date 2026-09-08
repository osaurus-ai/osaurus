import AppKit
import Foundation

/// State and actions for the Osaurus Workspaces surface: workspace purchase
/// (in-app Stripe Checkout with the first-subscription trial, or an
/// activation code from the web/admin), reactivation of a suspended
/// workspace, the owner's billing summary/portal, invite links (mint + join),
/// members, shared agents, and the workspace credit pool. Modeled on
/// `OsaurusRouterAccountService`.
///
/// Every route is master-key wallet-signed, so all network work funnels
/// through `OsaurusRouterAPIClient`. Workspace-scoped error codes arrive as
/// `.server(code:…)` and are mapped to friendly copy here via
/// `OsaurusRouterWorkspaceErrorCode`.
@MainActor
final class WorkspacesService: ObservableObject {
    static let shared = WorkspacesService()

    /// Workspace name offered when creating or activating a workspace; the
    /// web may suggest one instead.
    static var defaultActivationName: String { L("My workspace") }

    // MARK: Root state

    @Published private(set) var workspaces: [OsaurusRouterWorkspaceSummary] = []
    @Published private(set) var isLoadingWorkspaces = false
    /// The caller's account-level billing picture: owner subscription (if
    /// any, with trial state), owned/billed counts, and trial eligibility.
    /// Best-effort — refreshed alongside the list, never an error banner.
    @Published private(set) var billing: OsaurusRouterWorkspaceBillingSummary?
    /// The public plan + live prices (`GET /workspaces/prices`), for the
    /// create sheet and empty state. Best-effort, refreshed with `billing`.
    @Published private(set) var prices: OsaurusRouterWorkspacePricesResponse?
    /// A subscription activation delivered by the osaurus.ai web app
    /// (`osaurus://workspaces/activate?code=…`), waiting for the user to confirm
    /// — or for the router/identity gates to clear. Held, never dropped,
    /// until it's redeemed or the user dismisses it.
    @Published var pendingActivation: PendingWorkspaceActivation?
    /// An invite link opened in the app (`osaurus://workspaces/join?code=…`),
    /// waiting for the user's Join tap. Same lifecycle as `pendingActivation`.
    @Published var pendingJoin: PendingWorkspaceJoin?
    /// Keys of mutations currently in flight (e.g. `"invite.<id>"`,
    /// `"member.<accountId>"`), so one row's spinner never freezes the whole
    /// surface. `isWorking` remains as the coarse "anything running" view.
    @Published private(set) var busyKeys: Set<String> = []
    /// User-facing message from the most recent failed action.
    @Published var lastError: String?
    /// The workspace verdict behind `lastError` when the last failure was a
    /// router error code (nil for transport/local validation failures). Lets
    /// the create sheet turn `TRIAL_WORKSPACE_LIMIT` into a dated hint
    /// instead of a bare error line.
    @Published private(set) var lastErrorCode: OsaurusRouterWorkspaceErrorCode?

    var isWorking: Bool { !busyKeys.isEmpty }

    func isBusy(_ key: String) -> Bool { busyKeys.contains(key) }

    // MARK: Selected-workspace state

    @Published private(set) var selectedWorkspaceId: String?
    @Published private(set) var detail: OsaurusRouterWorkspaceDetail?
    @Published private(set) var members: [OsaurusRouterWorkspaceMember] = []
    @Published private(set) var workspaceInvites: [OsaurusRouterWorkspaceInvite] = []
    @Published private(set) var workspaceAgents: [OsaurusRouterWorkspaceAgent] = []
    /// The selected pool's balance split (this cycle's grant vs purchased
    /// credit) and its auto-reload state. Best-effort, refreshed with the
    /// detail; nil on a router without the breakdown endpoint fields.
    @Published private(set) var poolBalance: OsaurusRouterWorkspacePoolBalance?
    /// The selected pool's auto-reload settings (loaded on demand by the
    /// overview/sheet; any member may read, only the owner may save).
    @Published private(set) var autoReload: OsaurusRouterWorkspaceAutoReload?
    @Published private(set) var isLoadingDetail = false
    private var selectionGeneration = UUID()
    private var rootGeneration = UUID()
    /// A Stripe round-trip whose result lands by webhook, not by the redirect:
    /// the Billing Portal, an in-app Checkout for a new workspace, or a
    /// Checkout reactivating a suspended one. While set, app re-activation
    /// polls the router until the change is visible. Self-limits: an
    /// abandoned browser tab would otherwise wait forever, so it clears after
    /// `maxConfirmationPolls` fruitless activation polls (and the UI offers
    /// an explicit dismiss).
    enum PendingConfirmation: Equatable, Sendable {
        /// Portal visit for the selected workspace: poll its detail/billing.
        case portal
        /// New-workspace Checkout: poll the list for an id not in `knownIds`.
        case checkout(activationId: String, name: String, knownIds: Set<String>)
        /// Reactivation Checkout: poll that workspace until `active`.
        case reactivation(workspaceId: String)
        /// Pool top-up Checkout: poll that workspace's ledger until the
        /// `workspace_topup` entry for `amountMicro` lands (or the balance
        /// rises past what it was when the Checkout opened).
        case topUp(
            workspaceId: String, topupId: String, amountMicro: Int64,
            balanceBeforeMicro: Int64?, startedAt: Date
        )
    }
    @Published private(set) var pendingConfirmation: PendingConfirmation?
    /// Coarse "is a Stripe result pending" for the syncing rows.
    var awaitingSubscriptionConfirmation: Bool { pendingConfirmation != nil }
    private var confirmationPollCount = 0
    private static let maxConfirmationPolls = 10

    /// Root refresh throttle for activation-driven polling (membership
    /// changes have no server push). Internal (not private) so throttle
    /// tests can backdate it instead of sleeping through the real interval.
    var lastRootRefresh: Date?
    private static let activationRefreshInterval: TimeInterval = 60

    /// Seam for osaurus.ai / Billing Portal redirects; tests capture the
    /// URL instead of opening a real browser.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// UserDefaults key for the per-agent workspace-billing map:
    /// `[agentAddressLowercased: workspaceId]`. Read (nonisolated) by the router
    /// request builder to attach `workspace_context`.
    nonisolated static let agentBillingDefaultsKey = "ai.osaurus.teams.agentBilling"

    private let client: OsaurusRouterAPIClient
    private let defaults: UserDefaults
    // Retained for the lifetime of the (effectively singleton) service.
    private var activationObserver: NSObjectProtocol?

    init(
        client: OsaurusRouterAPIClient = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.defaults = defaults
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleAppActivation()
            }
        }
    }

    // MARK: - Root refresh

    /// Workspaces the caller belongs to. Membership changes have no server push,
    /// so this runs on tab open and (throttled) on app activation.
    func refreshWorkspaces() async {
        guard OsaurusRouter.isEnabled else { return }
        guard !isLoadingWorkspaces else { return }
        let generation = rootGeneration
        isLoadingWorkspaces = true
        defer { isLoadingWorkspaces = false }

        do {
            let fetched = try await client.listWorkspaces()
            guard generation == rootGeneration else { return }
            workspaces = fetched
            lastRootRefresh = Date()
            // An authoritative workspace list is the reconciliation point for
            // per-agent billing prefs: leaving, being removed, or the workspace
            // being deleted must stop `workspace_context` injection.
            reconcileBillingPreferences(validWorkspaceIds: Set(workspaces.map(\.id)))
            // Membership changed (create / join / leave / removed): the chat
            // sidebar's per-workspace sections follow the same list.
            let known = Set(WorkspaceRosterStore.shared.rosters.map(\.id))
            if known != Set(workspaces.map(\.id)) {
                Task { await WorkspaceRosterStore.shared.refresh(reason: .manual) }
            }
        } catch {
            noteError(error)
            return
        }
        await refreshBilling()
        // A manual refresh while a new-workspace Checkout is pending is a
        // fine moment to notice the webhook landed (not just app activation).
        if case .checkout(_, let name, let knownIds) = pendingConfirmation,
            let created = workspaces.first(where: {
                !knownIds.contains($0.id) && $0.typedRole == .owner && $0.isActive
            })
        {
            endConfirmation()
            await WorkspaceAuditLog.shared.recordOwnerAction(
                .workspaceCreated, workspaceId: created.id, details: ["name": name, "via": "checkout"]
            )
            await selectWorkspace(id: created.id)
        }
    }

    /// Account-level billing summary (owner subscription + trial state) and
    /// the public plan/prices. Quiet on failure: the list is the primary
    /// surface, and a router without these routes must not raise a banner.
    func refreshBilling() async {
        guard OsaurusRouter.isEnabled else { return }
        if let summary = try? await client.workspaceBilling() {
            billing = summary
        }
        if let fetched = try? await client.workspacePrices() {
            prices = fetched
        }
    }

    // MARK: Trial / plan conveniences (nil until billing has loaded)

    /// Whether `POST /workspaces` would add to a live subscription right
    /// away, or bounce through a Stripe Checkout first.
    var hasLiveSubscription: Bool { billing?.hasLiveSubscription ?? false }
    /// The owner's first subscription is still in its trial.
    var isTrialing: Bool { billing?.isTrialing ?? false }
    /// ISO date the trial converts (set once Stripe reports it).
    var trialEndsAt: String? { billing?.trialEndsAt }
    /// Whether the next Checkout would carry the trial. Falls back to the
    /// public plan when the billing summary hasn't loaded (never subscribed
    /// is the common case for a first-time buyer).
    var trialEligible: Bool {
        billing?.trialEligible ?? (prices?.plan?.hasTrial ?? false)
    }
    /// Trial length in days, from billing or the public plan.
    var trialDays: Int? { billing?.trialDays ?? prices?.plan?.trialDays }

    // MARK: - Identity

    /// Whether a roster person is the local user. The wallet is the identity;
    /// the address comes from the most recent signed router call (no
    /// biometric prompt). Unknown until the first signed request lands.
    nonisolated func isSelf(walletAddress: String?) -> Bool {
        guard let walletAddress, !walletAddress.isEmpty,
            let mine = OsaurusRouterWalletCache.lastSignedAddress
        else { return false }
        return walletAddress.lowercased() == mine
    }

    nonisolated func isSelf(_ person: OsaurusRouterWorkspacePerson?) -> Bool {
        isSelf(walletAddress: person?.walletAddress)
    }

    nonisolated func isSelf(_ member: OsaurusRouterWorkspaceMember) -> Bool {
        isSelf(walletAddress: member.walletAddress)
    }

    // MARK: - Workspace lifecycle

    /// Result of a purchase-shaped mutation (`createWorkspace` /
    /// `reactivateWorkspace`).
    enum PurchaseOutcome: Equatable, Sendable {
        /// Live now; the service already refreshed and selected it.
        case ready(OsaurusRouterWorkspaceDetail)
        /// Stripe Checkout opened in the browser; `pendingConfirmation` is set
        /// and app re-activation polls until the webhook lands.
        case checkoutOpened(activationId: String)
    }

    /// Creates a workspace owned by the caller. On a live subscription it is
    /// created immediately and we land on it; otherwise the router hands back
    /// a Stripe Checkout (with the trial on a first subscription), which is
    /// opened in the browser — the webhook creates the workspace and
    /// `handleAppActivation` picks it up. Returns nil with `lastError` set on
    /// failure — notably `TRIAL_WORKSPACE_LIMIT` while the trial already
    /// covers one workspace.
    @discardableResult
    func createWorkspace(name: String, priceId: String? = nil) async -> PurchaseOutcome? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 80 else {
            lastError = L("Workspace names are 1–80 characters.")
            return nil
        }
        var outcome: PurchaseOutcome?
        let ok = await performMutation(key: "workspace.create") {
            let response = try await self.client.createWorkspace(name: trimmedName, priceId: priceId)
            guard let result = response.outcome else { throw OsaurusRouterAPIError.invalidResponse }
            switch result {
            case .ready(let detail):
                outcome = .ready(detail)
                await WorkspaceAuditLog.shared.recordOwnerAction(
                    .workspaceCreated, workspaceId: detail.id, details: ["name": trimmedName]
                )
                await self.refreshWorkspaces()
                await self.selectWorkspace(id: detail.id)
            case .checkoutRequired(let activationId, let url):
                outcome = .checkoutOpened(activationId: activationId)
                self.beginConfirmation(
                    .checkout(
                        activationId: activationId,
                        name: trimmedName,
                        knownIds: Set(self.workspaces.map(\.id))
                    )
                )
                self.openURL(url)
            }
        }
        if !ok, lastErrorCode == .trialWorkspaceLimit {
            // The hint shows the trial's end date; make sure it's fresh.
            await refreshBilling()
        }
        return ok ? outcome : nil
    }

    /// Puts a suspended workspace back on the owner's subscription (owner
    /// only). Immediate on a live subscription; otherwise opens a Stripe
    /// Checkout and polls the workspace until it turns active.
    @discardableResult
    func reactivateWorkspace(id: String, priceId: String? = nil) async -> PurchaseOutcome? {
        var outcome: PurchaseOutcome?
        let ok = await performMutation(key: "workspace.reactivate") {
            let response = try await self.client.upgradeWorkspace(id: id, priceId: priceId)
            guard let result = response.outcome else { throw OsaurusRouterAPIError.invalidResponse }
            switch result {
            case .ready(let detail):
                outcome = .ready(detail)
                await WorkspaceAuditLog.shared.recordOwnerAction(
                    .workspaceReactivated, workspaceId: detail.id, details: ["name": detail.name]
                )
                await self.refreshWorkspaces()
                if self.selectedWorkspaceId == id {
                    await self.refreshSelectedWorkspace()
                } else {
                    await self.selectWorkspace(id: id)
                }
            case .checkoutRequired(let activationId, let url):
                outcome = .checkoutOpened(activationId: activationId)
                self.beginConfirmation(.reactivation(workspaceId: id))
                self.openURL(url)
            }
        }
        return ok ? outcome : nil
    }

    /// Redeems an activation code (web purchase or admin comp): the router
    /// creates the workspace (owned by the caller's wallet, subscription
    /// bound) and we land on it. Returns the new workspace, or nil with
    /// `lastError` set — the pending activation is kept on failure so the
    /// user can retry without going back to the web.
    @discardableResult
    func activate(code: String, name: String) async -> OsaurusRouterWorkspaceDetail? {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PendingWorkspaceActivation.isPlausibleCode(trimmedCode) else {
            lastError = L("That doesn't look like an activation code. Copy it from osaurus.ai and try again.")
            return nil
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 80 else {
            lastError = L("Workspace names are 1–80 characters.")
            return nil
        }
        var created: OsaurusRouterWorkspaceDetail?
        let ok = await performMutation(key: "workspace.activate") {
            let detail = try await self.client.workspaceActivate(code: trimmedCode, name: trimmedName)
            created = detail
            self.pendingActivation = nil
            await WorkspaceAuditLog.shared.recordOwnerAction(
                .workspaceCreated, workspaceId: detail.id,
                details: ["name": trimmedName, "via": "activation_code"]
            )
            await self.refreshWorkspaces()
            await self.selectWorkspace(id: detail.id)
        }
        return ok ? created : nil
    }

    /// User declined the pending web activation (closed the sheet).
    func dismissPendingActivation() {
        pendingActivation = nil
    }

    /// Redeems an invite link: the router adds the caller to the workspace with
    /// the link's role and we land on it. Idempotent for existing members.
    /// The pending join is kept on failure so the user can retry or discard.
    @discardableResult
    func join(code: String) async -> OsaurusRouterWorkspaceDetail? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OsaurusRouterWorkspaceCode.isPlausible(trimmed) else {
            lastError = L("That doesn't look like an invite code. Ask your teammate to share the link again.")
            return nil
        }
        var joined: OsaurusRouterWorkspaceDetail?
        let ok = await performMutation(key: "workspace.join") {
            let detail = try await self.client.workspaceJoin(code: trimmed)
            joined = detail
            self.pendingJoin = nil
            await WorkspaceAuditLog.shared.recordOwnerAction(
                .joinRedeemed, workspaceId: detail.id,
                details: ["role": detail.role]
            )
            await self.refreshWorkspaces()
            await self.selectWorkspace(id: detail.id)
        }
        return ok ? joined : nil
    }

    /// User declined the pending invite link (closed the sheet).
    func dismissPendingJoin() {
        pendingJoin = nil
    }

    @discardableResult
    func renameWorkspace(id: String, name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else {
            lastError = L("Workspace names are 1–80 characters.")
            return false
        }
        return await performMutation(key: "workspace.rename") {
            try await self.client.renameWorkspace(id: id, name: trimmed)
            await WorkspaceAuditLog.shared.recordOwnerAction(
                .workspaceRenamed, workspaceId: id, details: ["name": trimmed]
            )
            await self.refreshWorkspaces()
            if self.selectedWorkspaceId == id { await self.refreshSelectedWorkspace() }
        }
    }

    /// Soft-deletes the workspace, revokes shared agents and pending invites,
    /// and — for a subscription-backed workspace — drops it from the owner's
    /// subscription quantity (owner only). At zero the subscription winds
    /// down at the period end instead of renewing.
    @discardableResult
    func deleteWorkspace(id: String) async -> Bool {
        await performMutation(key: "workspace.delete") {
            try await self.client.deleteWorkspace(id: id)
            await WorkspaceAuditLog.shared.recordOwnerAction(.workspaceDeleted, workspaceId: id)
            if self.selectedWorkspaceId == id { self.clearSelection() }
            // Deleting revokes every shared agent; drop this workspace's billing
            // prefs immediately rather than waiting for the refresh.
            self.clearBillingPreferences(workspaceId: id)
            // Kill any live workspace-minted access keys for this workspace instead of
            // letting teammates ride out the rest of their attestations.
            await WorkspaceAgentAccessHost.shared.invalidateKeys(workspaceId: id)
            await self.refreshWorkspaces()
        }
    }

    // MARK: - Selection

    /// Detail tab a deep link asked for (chat sidebar gear → Shared Agents,
    /// composer pool chip → Overview). `WorkspaceDetailView` consumes and
    /// clears it, so the user's own tab clicks are never overridden later.
    @Published var deepLinkTab: WorkspaceDetailView.Tab?

    /// Land on one workspace's detail in Settings ▸ Workspaces from anywhere
    /// in the app: selects it (so the list pane drills in as soon as its
    /// summary is known), remembers the requested tab, and brings the
    /// management window forward. The one path every "Open workspace"
    /// affordance uses, so they all end on the same screen.
    func openInSettings(workspaceId: String, tab: WorkspaceDetailView.Tab = .overview) {
        deepLinkTab = tab
        Task { await selectWorkspace(id: workspaceId) }
        AppDelegate.shared?.showManagementWindow(initialTab: .workspaces)
    }

    func selectWorkspace(id: String) async {
        selectionGeneration = UUID()
        isLoadingDetail = false
        selectedWorkspaceId = id
        detail = nil
        members = []
        workspaceInvites = []
        workspaceAgents = []
        poolBalance = nil
        autoReload = nil
        await refreshSelectedWorkspace()
    }

    func clearSelection() {
        selectionGeneration = UUID()
        isLoadingDetail = false
        selectedWorkspaceId = nil
        detail = nil
        members = []
        workspaceInvites = []
        workspaceAgents = []
        poolBalance = nil
        autoReload = nil
        // A portal/reactivation wait belongs to the selection; a new-workspace
        // checkout is account-level and must survive navigating away. A pool
        // top-up is credited by webhook whether or not we watch, so its wait
        // ends with the selection too.
        switch pendingConfirmation {
        case .portal, .reactivation, .topUp: endConfirmation()
        case .checkout, .none: break
        }
    }

    func refreshSelectedWorkspace() async {
        guard let id = selectedWorkspaceId else { return }
        guard !isLoadingDetail else { return }
        let generation = selectionGeneration
        isLoadingDetail = true
        defer { if generation == selectionGeneration { isLoadingDetail = false } }

        do {
            let fetched = try await client.workspaceDetail(id: id)
            guard generation == selectionGeneration, selectedWorkspaceId == id else { return }
            detail = fetched
            if fetched.isActive {
                switch pendingConfirmation {
                case .portal, .reactivation(workspaceId: id): endConfirmation()
                default: break
                }
            }
        } catch {
            guard generation == selectionGeneration else { return }
            noteError(error)
            return
        }
        // Pool split + auto-reload state. Quiet on failure: the detail's
        // `balance_micro` already carries the headline figure.
        if let balance = try? await client.workspaceBalance(id: id),
            generation == selectionGeneration, selectedWorkspaceId == id
        {
            poolBalance = balance
        }
        do {
            let fetched = try await client.workspaceMembers(id: id)
            guard generation == selectionGeneration, selectedWorkspaceId == id else { return }
            members = fetched
        } catch {
            guard generation == selectionGeneration else { return }
            noteError(error)
        }
        do {
            // Owner/admin only; plain members get FORBIDDEN_ROLE — that's an
            // expected verdict, not an error banner.
            let fetched = try await client.workspaceInvites(id: id)
            guard generation == selectionGeneration, selectedWorkspaceId == id else { return }
            workspaceInvites = fetched
        } catch {
            guard generation == selectionGeneration else { return }
            if detail?.role == "owner" || detail?.role == "admin" { noteError(error) } else {
            workspaceInvites = []
        }
        }
        do {
            let fetched = try await client.workspaceAgents(id: id)
            guard generation == selectionGeneration, selectedWorkspaceId == id else { return }
            workspaceAgents = fetched
            // Authoritative roster: an admin unsharing my agent (or a viewer
            // demotion auto-revoking it) must clear its billing pref, or
            // every later call fails server-side with no recovery path.
            reconcileBillingPreferences(
                workspaceId: id,
                activeAgentAddresses: Set(workspaceAgents.map { $0.agentAddress.lowercased() })
            )
            WorkspaceRosterStore.shared.update(workspaceId: id, agents: workspaceAgents)
        } catch {
            guard generation == selectionGeneration else { return }
            noteError(error)
        }
    }

    func applySyncSnapshot(_ snapshot: WorkspaceSyncSnapshot) {
        rootGeneration = UUID()
        workspaces = snapshot.workspaces.map(\.workspace)
        lastRootRefresh = Date()
        reconcileBillingPreferences(validWorkspaceIds: Set(workspaces.map(\.id)))
        guard let id = selectedWorkspaceId else { return }
        // Supersede any poll already in flight before publishing this snapshot.
        selectionGeneration = UUID()
        isLoadingDetail = false
        guard let entry = snapshot.workspaces.first(where: { $0.workspace.id == id }) else {
            clearSelection()
            return
        }
        detail = entry.detail
        members = entry.members
        workspaceAgents = entry.agents
        workspaceInvites = entry.invites
        reconcileBillingPreferences(
            workspaceId: id,
            activeAgentAddresses: Set(entry.agents.map { $0.agentAddress.lowercased() })
        )
    }

    // MARK: - Billing

    /// Opens the Stripe Billing Portal for the caller's owner subscription
    /// (account-level: one subscription covers every workspace they own).
    /// Payment method, invoices, interval switch, and cancellation happen
    /// there; the router mirrors the result by webhook.
    @discardableResult
    func openBillingPortal() async -> Bool {
        await performMutation(key: "subscription.portal") {
            let response = try await self.client.workspaceBillingPortal()
            guard let url = URL(string: response.portalURL) else {
                throw OsaurusRouterAPIError.invalidResponse
            }
            // Changes land via webhook; poll on return.
            self.beginConfirmation(.portal)
            self.openURL(url)
        }
    }

    /// User-initiated "stop waiting" for a Stripe round-trip (e.g. they
    /// closed the portal or checkout tab without finishing).
    func dismissSubscriptionWait() {
        endConfirmation()
    }

    // MARK: - Pool credits (top-ups and auto-reload)

    /// Refreshes the selected pool's balance split (grant vs purchased) and
    /// auto-reload flags. Quiet on failure.
    func refreshPoolBalance() async {
        guard let id = selectedWorkspaceId else { return }
        let generation = selectionGeneration
        if let balance = try? await client.workspaceBalance(id: id),
            generation == selectionGeneration, selectedWorkspaceId == id
        {
            poolBalance = balance
        }
    }

    /// Loads the auto-reload settings for `workspaceId` (any member may read).
    /// Returns nil with `lastError` set on failure.
    @discardableResult
    func loadAutoReload(workspaceId: String) async -> OsaurusRouterWorkspaceAutoReload? {
        do {
            let settings = try await client.workspaceAutoReload(id: workspaceId)
            if selectedWorkspaceId == workspaceId { autoReload = settings }
            return settings
        } catch {
            noteError(error)
            return nil
        }
    }

    /// Saves the owner's auto-reload settings. Saving also clears a pause and
    /// the failure counter on the router. `monthlyCapMicro == nil` means no
    /// cap. Client-side bounds are checked first so a typo never round-trips;
    /// the router's `INVALID_AUTO_RELOAD_CONFIG` / `AUTO_RELOAD_UNAVAILABLE`
    /// verdicts land in `lastError` / `lastErrorCode`.
    @discardableResult
    func saveAutoReload(
        workspaceId: String,
        enabled: Bool,
        thresholdMicro: Int64,
        amountMicro: Int64,
        monthlyCapMicro: Int64?
    ) async -> OsaurusRouterWorkspaceAutoReload? {
        let verdict = OsaurusRouterWorkspacePoolCredits.validateAutoReload(
            thresholdMicro: thresholdMicro, amountMicro: amountMicro, monthlyCapMicro: monthlyCapMicro,
            bounds: autoReload?.bounds
        )
        guard verdict == .ok else {
            lastError = Self.autoReloadValidationMessage(verdict)
            lastErrorCode = .invalidAutoReloadConfig
            return nil
        }
        var saved: OsaurusRouterWorkspaceAutoReload?
        let ok = await performMutation(key: "pool.autoReload") {
            let update = OsaurusRouterWorkspaceAutoReloadUpdate(
                enabled: enabled, thresholdMicro: thresholdMicro, amountMicro: amountMicro,
                monthlyCapMicro: monthlyCapMicro
            )
            let response = try await self.client.updateWorkspaceAutoReload(id: workspaceId, update)
            saved = response
            if self.selectedWorkspaceId == workspaceId { self.autoReload = response }
            await WorkspaceAuditLog.shared.recordOwnerAction(
                .poolAutoReloadChanged, workspaceId: workspaceId,
                details: [
                    "enabled": enabled ? "true" : "false",
                    "threshold_micro": String(thresholdMicro),
                    "amount_micro": String(amountMicro),
                    "monthly_cap_micro": monthlyCapMicro.map(String.init) ?? "none",
                ]
            )
            await self.refreshPoolBalance()
        }
        return ok ? saved : nil
    }

    static func autoReloadValidationMessage(
        _ verdict: OsaurusRouterWorkspacePoolCredits.AutoReloadValidation
    ) -> String {
        switch verdict {
        case .ok:
            return ""
        case .thresholdOutOfBounds:
            return L("The reload threshold must be between $1 and $500.")
        case .amountOutOfBounds:
            return L("The reload amount must be between $5 and $500.")
        case .capBelowAmount:
            return L("The monthly cap can't be lower than the reload amount.")
        case .notWholeCents:
            return L("Amounts must be whole cents.")
        }
    }

    /// Starts a one-time pool top-up (owner only): opens a Stripe Checkout
    /// for `amountMicro` and polls the pool on return until the
    /// `workspace_topup` ledger entry lands. Returns the top-up id, or nil
    /// with `lastError` set (a suspended workspace is refused with
    /// `SUBSCRIPTION_INACTIVE`).
    @discardableResult
    func topUpPool(workspaceId: String, amountMicro: Int64) async -> String? {
        let verdict = OsaurusRouterWorkspacePoolCredits.validateTopUp(micro: amountMicro)
        guard verdict == .ok else {
            lastError = Self.topUpValidationMessage(verdict)
            lastErrorCode = nil
            return nil
        }
        var topupId: String?
        let ok = await performMutation(key: "pool.topup") {
            let response = try await self.client.workspacePoolCheckout(id: workspaceId, amountMicro: amountMicro)
            guard let url = URL(string: response.checkoutURL) else {
                throw OsaurusRouterAPIError.invalidResponse
            }
            topupId = response.topupId
            let before = self.selectedWorkspaceId == workspaceId
                ? (self.poolBalance?.balanceMicro ?? self.detail?.balanceMicro).flatMap(Int64.init)
                : nil
            self.beginConfirmation(
                .topUp(
                    workspaceId: workspaceId, topupId: response.topupId,
                    amountMicro: amountMicro, balanceBeforeMicro: before, startedAt: Date()
                )
            )
            self.openURL(url)
        }
        return ok ? topupId : nil
    }

    static func topUpValidationMessage(
        _ verdict: OsaurusRouterWorkspacePoolCredits.TopUpValidation
    ) -> String {
        switch verdict {
        case .ok: return ""
        case .belowMinimum: return L("Minimum top-up is $5.00")
        case .aboveMaximum: return L("Maximum top-up is $500.00")
        case .notWholeCents: return L("Amounts must be whole cents.")
        }
    }

    private func beginConfirmation(_ confirmation: PendingConfirmation) {
        pendingConfirmation = confirmation
        confirmationPollCount = 0
    }

    private func endConfirmation() {
        pendingConfirmation = nil
        confirmationPollCount = 0
    }

    // MARK: - Invite links

    /// Mints an invite link (owner/admin; only owners may mint admin links —
    /// the server enforces it). Returns the invite, whose `url` is the share
    /// payload; nil with `lastError` set on failure.
    @discardableResult
    func mintInvite(
        workspaceId: String,
        role: OsaurusRouterWorkspaceRole,
        maxUses: Int = 1
    ) async -> OsaurusRouterWorkspaceInvite? {
        let clampedUses = min(max(maxUses, 1), 100)
        var minted: OsaurusRouterWorkspaceInvite?
        let ok = await performMutation(key: "invite.create") {
            let invite = try await self.client.createWorkspaceInvite(
                id: workspaceId, role: role, maxUses: clampedUses
            )
            minted = invite
            // Invite id + role + uses only — never the code or URL.
            await WorkspaceAuditLog.shared.recordOwnerAction(
                .inviteCreated, workspaceId: workspaceId, target: invite.id,
                details: ["role": role.rawValue, "max_uses": String(clampedUses)]
            )
            if self.selectedWorkspaceId == workspaceId {
                self.workspaceInvites.removeAll { $0.id == invite.id }
                self.workspaceInvites.insert(invite, at: 0)
            }
        }
        return ok ? minted : nil
    }

    @discardableResult
    func revokeInvite(workspaceId: String, inviteId: String) async -> Bool {
        await performMutation(key: "invite.\(inviteId)") {
            try await self.client.revokeWorkspaceInvite(id: workspaceId, inviteId: inviteId)
            await WorkspaceAuditLog.shared.recordOwnerAction(
                .inviteRevoked, workspaceId: workspaceId, target: inviteId
            )
            self.workspaceInvites.removeAll { $0.id == inviteId }
        }
    }

    // MARK: - Members

    @discardableResult
    func setMemberRole(
        workspaceId: String,
        accountId: String,
        role: OsaurusRouterWorkspaceRole
    ) async -> Bool {
        await performMutation(key: "member.\(accountId)") {
            let previousRole = self.members.first { $0.accountId == accountId }?.role
            try await self.client.setWorkspaceMemberRole(id: workspaceId, accountId: accountId, role: role)
            var details = ["role": role.rawValue]
            if let previousRole { details["previous_role"] = previousRole }
            await WorkspaceAuditLog.shared.recordOwnerAction(
                .memberRoleChanged, workspaceId: workspaceId, target: accountId, details: details
            )
            let generation = self.selectionGeneration
            if let fetched = try? await self.client.workspaceMembers(id: workspaceId),
                self.selectedWorkspaceId == workspaceId, generation == self.selectionGeneration
            {
                self.members = fetched
            }
            if role == .viewer, self.selectedWorkspaceId == workspaceId {
                // Demotion to viewer auto-revokes their shared agents
                // server-side; refresh the roster (and, if it was our own
                // demotion, the reconcile inside will clear billing prefs).
                await self.refreshSelectedWorkspace()
            }
        }
    }

    /// Owner/admin removal or self-leave. Removing a member auto-revokes
    /// their shared agents server-side, so the agent roster refreshes too.
    @discardableResult
    func removeMember(workspaceId: String, accountId: String) async -> Bool {
        await performMutation(key: "member.\(accountId)") {
            let removed = self.members.first { $0.accountId == accountId }
            let isSelfLeave = removed.map { self.isSelf($0) } ?? false
            try await self.client.removeWorkspaceMember(id: workspaceId, accountId: accountId)
            var details: [String: String] = [:]
            if let wallet = removed?.walletAddress { details["wallet"] = wallet.lowercased() }
            if let role = removed?.role { details["role"] = role }
            await WorkspaceAuditLog.shared.recordOwnerAction(
                isSelfLeave ? .workspaceLeft : .memberRemoved,
                workspaceId: workspaceId,
                target: accountId,
                details: details
            )
            if self.selectedWorkspaceId == workspaceId {
                await self.refreshSelectedWorkspace()
            }
            await self.refreshWorkspaces()
        }
    }

    // MARK: - Shared agents

    /// Shares one of the caller's own agents, minting the agent-key proof
    /// locally. Re-sharing an already-shared address is idempotent.
    @discardableResult
    func shareAgent(
        workspaceId: String,
        agentAddress: String,
        agentIndex: UInt32,
        displayName: String,
        description: String?
    ) async -> Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else {
            lastError = L("Agent display names are 1–120 characters.")
            return false
        }
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return await performMutation(key: "agent.share") {
            let proof = try await WorkspacesAgentProofSigner.makeProof(
                workspaceId: workspaceId,
                agentAddress: agentAddress,
                agentIndex: agentIndex
            )
            let body = OsaurusRouterWorkspaceShareAgentBody(
                agent_address: agentAddress.lowercased(),
                display_name: name,
                description: (trimmedDescription?.isEmpty == false) ? trimmedDescription : nil,
                proof: proof
            )
            _ = try await self.client.shareWorkspaceAgent(id: workspaceId, body: body)
            await WorkspaceAuditLog.shared.recordOwnerAction(
                .agentShared, workspaceId: workspaceId,
                agentAddress: agentAddress, agentName: name
            )
            let generation = self.selectionGeneration
            if let fetched = try? await self.client.workspaceAgents(id: workspaceId),
                self.selectedWorkspaceId == workspaceId, generation == self.selectionGeneration
            {
                self.workspaceAgents = fetched
                self.publishRoster(workspaceId: workspaceId)
            }
        }
    }

    @discardableResult
    func unshareAgent(workspaceId: String, agentAddress: String) async -> Bool {
        await performMutation(key: "agent.\(agentAddress.lowercased())") {
            let sharedName =
                self.workspaceAgents.first {
                    $0.agentAddress.lowercased() == agentAddress.lowercased()
                }?.displayName
                ?? WorkspaceRosterStore.shared.agent(forAddress: agentAddress)?.displayName
            try await self.client.unshareWorkspaceAgent(id: workspaceId, agentAddress: agentAddress)
            await WorkspaceAuditLog.shared.recordOwnerAction(
                .agentUnshared, workspaceId: workspaceId,
                agentAddress: agentAddress, agentName: sharedName
            )
            self.workspaceAgents.removeAll {
                $0.agentAddress.lowercased() == agentAddress.lowercased()
            }
            // Unsharing invalidates any workspace-billing preference for it (no-op
            // for other members' agents, which have no local record).
            self.setBillingWorkspace(agentAddress: agentAddress, workspaceId: nil)
            // Revocation contract: immediately kill workspace-minted keys for this
            // agent so a redeemed teammate session ends with the share.
            await WorkspaceAgentAccessHost.shared.invalidateKeys(
                workspaceId: workspaceId, agentAddress: agentAddress
            )
            self.publishRoster(workspaceId: workspaceId)
        }
    }

    /// Mirror this view's freshly fetched agent list into the chat sidebar's
    /// roster store right away, then let the store re-fetch so per-workspace
    /// counts and any workspace it hasn't loaded yet catch up too.
    private func publishRoster(workspaceId: String) {
        // `workspaceAgents` is the SELECTED workspace's list; a share/unshare
        // issued for another workspace (sidebar context menu) must not
        // overwrite that roster with the wrong agents.
        if selectedWorkspaceId == workspaceId {
            WorkspaceRosterStore.shared.update(workspaceId: workspaceId, agents: workspaceAgents)
        }
        Task { await WorkspaceRosterStore.shared.refresh(reason: .manual) }
    }

    // MARK: - Per-agent workspace billing preference

    /// Stored shape: `[agentUUIDString: ["workspace_id": …, "agent_address": …]]`
    /// (entries written before the Teams → Workspaces rename carry `team_id`;
    /// reads accept both, writes use the new key).
    /// Keyed by the agent's UUID because the inference path resolves the
    /// preference from `ChatExecutionContext.currentAgentId`; the address
    /// rides along so `workspace_context` can be built without a main-actor hop
    /// into `AgentManager`. Nonisolated reads — UserDefaults is thread-safe.
    nonisolated static func workspaceContext(
        forAgentId agentId: UUID,
        defaults: UserDefaults = .standard
    ) -> OsaurusRouterWorkspaceContext? {
        guard
            let map = defaults.dictionary(forKey: agentBillingDefaultsKey)
                as? [String: [String: String]],
            let entry = map[agentId.uuidString],
            let workspaceId = billingEntryWorkspaceId(entry), !workspaceId.isEmpty,
            let address = entry["agent_address"], !address.isEmpty
        else { return nil }
        return OsaurusRouterWorkspaceContext(workspaceId: workspaceId, agentAddress: address)
    }

    /// The workspace id of a stored billing entry, current or pre-rename key.
    nonisolated static func billingEntryWorkspaceId(_ entry: [String: String]) -> String? {
        entry["workspace_id"] ?? entry["team_id"]
    }

    nonisolated static func setBillingWorkspace(
        agentId: UUID,
        agentAddress: String,
        workspaceId: String?,
        defaults: UserDefaults = .standard
    ) {
        var map =
            (defaults.dictionary(forKey: agentBillingDefaultsKey)
                as? [String: [String: String]]) ?? [:]
        if let workspaceId {
            map[agentId.uuidString] = [
                "workspace_id": workspaceId,
                "agent_address": agentAddress.lowercased(),
            ]
        } else {
            map.removeValue(forKey: agentId.uuidString)
        }
        defaults.set(map, forKey: agentBillingDefaultsKey)
    }

    /// UI toggle entry point: resolves the local agent by address (only the
    /// user's own agents show the toggle, so a local match always exists).
    func setBillingWorkspace(agentAddress: String, workspaceId: String?) {
        guard
            let agent = AgentManager.shared.agents.first(where: {
                $0.agentAddress?.lowercased() == agentAddress.lowercased()
            })
        else { return }
        let previous = billingWorkspaceId(forAgentAddress: agentAddress)
        Self.setBillingWorkspace(
            agentId: agent.id, agentAddress: agentAddress, workspaceId: workspaceId, defaults: defaults
        )
        objectWillChange.send()
        // Record under whichever workspace(s) the change touches: the one
        // now billed and, when switching away, the one no longer billed.
        let agentName = agent.name
        let touched = Set([previous, workspaceId].compactMap { $0 })
        guard !touched.isEmpty else { return }
        Task {
            for id in touched {
                await WorkspaceAuditLog.shared.recordOwnerAction(
                    .billingPreferenceChanged,
                    workspaceId: id,
                    agentAddress: agentAddress,
                    agentName: agentName,
                    details: [
                        "bills_workspace": workspaceId ?? "none",
                        "previous": previous ?? "none",
                    ]
                )
            }
        }
    }

    /// The workspace an agent (by address) currently bills, for UI state.
    func billingWorkspaceId(forAgentAddress address: String) -> String? {
        guard
            let map = defaults.dictionary(forKey: Self.agentBillingDefaultsKey)
                as? [String: [String: String]]
        else { return nil }
        let lowered = address.lowercased()
        return map.values.first { $0["agent_address"] == lowered }.flatMap(Self.billingEntryWorkspaceId)
    }

    // MARK: - Pool activity (read-only pass-throughs for the activity sheet)

    func fetchWorkspaceBalance(workspaceId: String) async throws -> OsaurusRouterWorkspacePoolBalance {
        try await client.workspaceBalance(id: workspaceId)
    }

    func fetchWorkspaceUsage(
        workspaceId: String, limit: Int = 50, cursor: String? = nil
    ) async throws -> OsaurusRouterUsageResponse {
        try await client.workspaceUsage(id: workspaceId, limit: limit, cursor: cursor)
    }

    func fetchWorkspaceTransactions(
        workspaceId: String, limit: Int = 50, cursor: String? = nil
    ) async throws -> OsaurusRouterTransactionsResponse {
        try await client.workspaceTransactions(id: workspaceId, limit: limit, cursor: cursor)
    }

    /// Lightweight presence poll while a workspace detail view is on screen:
    /// refreshes only the shared-agent roster (whose `online`/`last_seen`
    /// age out in seconds), skipping members/subscription/detail.
    func refreshAgentsPresence() async {
        guard OsaurusRouter.isEnabled, let id = selectedWorkspaceId else { return }
        let generation = selectionGeneration
        guard let agents = try? await client.workspaceAgents(id: id) else { return }
        guard selectedWorkspaceId == id, generation == selectionGeneration else { return }
        workspaceAgents = agents
        reconcileBillingPreferences(
            workspaceId: id,
            activeAgentAddresses: Set(agents.map { $0.agentAddress.lowercased() })
        )
        WorkspaceRosterStore.shared.update(workspaceId: id, agents: agents)
    }

    /// Refreshes the selected workspace's pool balance after a workspace-billed SSE
    /// summary (`billed_to: "workspace:<id>"`) so the UI tracks the right ledger.
    func noteWorkspaceBilled(workspaceId: String) {
        guard selectedWorkspaceId == workspaceId else { return }
        Task { await refreshSelectedWorkspace() }
    }

    // MARK: - Billing-preference reconciliation

    /// Drops billing-map entries whose workspace the caller no longer belongs to.
    /// Called only with an authoritative (successfully fetched) workspace list so
    /// a transport failure can't wipe valid prefs.
    private func reconcileBillingPreferences(validWorkspaceIds: Set<String>) {
        mutateBillingMap { map in
            map.filter { _, entry in
                guard let workspaceId = Self.billingEntryWorkspaceId(entry), !workspaceId.isEmpty else { return false }
                return validWorkspaceIds.contains(workspaceId)
            }
        }
    }

    /// Drops entries for `workspaceId` whose agent is no longer on that workspace's
    /// shared roster (admin unshare, viewer-demotion auto-revoke). Called
    /// only with an authoritative roster.
    private func reconcileBillingPreferences(
        workspaceId: String,
        activeAgentAddresses: Set<String>
    ) {
        mutateBillingMap { map in
            map.filter { _, entry in
                guard Self.billingEntryWorkspaceId(entry) == workspaceId else { return true }
                guard let address = entry["agent_address"] else { return false }
                return activeAgentAddresses.contains(address.lowercased())
            }
        }
    }

    private func clearBillingPreferences(workspaceId: String) {
        mutateBillingMap { map in
            map.filter { _, entry in Self.billingEntryWorkspaceId(entry) != workspaceId }
        }
    }

    private func mutateBillingMap(
        _ transform: ([String: [String: String]]) -> [String: [String: String]]
    ) {
        let map =
            (defaults.dictionary(forKey: Self.agentBillingDefaultsKey)
                as? [String: [String: String]]) ?? [:]
        let next = transform(map)
        guard next != map else { return }
        defaults.set(next, forKey: Self.agentBillingDefaultsKey)
        objectWillChange.send()
    }

    /// Fire-and-forget self-heal for a workspace-billed chat failure
    /// (`NOT_A_MEMBER` / `WORKSPACE_NOT_FOUND`): refresh the workspace list, whose
    /// reconcile drops the dead preference so the next send bills personally.
    /// Nonisolated so the chat error path can call it from any context.
    nonisolated static func scheduleBillingReconciliation() {
        Task { @MainActor in
            await WorkspacesService.shared.refreshWorkspaces()
        }
    }

    // MARK: - Error mapping

    static func message(for error: OsaurusRouterAPIError) -> String {
        if let workspaceCode = OsaurusRouterWorkspaceErrorCode.match(error) {
            switch workspaceCode {
            case .workspaceNotFound:
                return L("This workspace no longer exists.")
            case .notAMember:
                return L("You're not a member of this workspace.")
            case .forbiddenRole:
                return L("Your workspace role doesn't allow that action.")
            case .seatsExhausted:
                return L("This workspace is full. Ask the owner to free a seat.")
            case .agentLimit:
                return L("This workspace has reached its shared-agent limit.")
            case .insufficientFunds:
                return L("This workspace's pool is out of credits. The owner can add credits or turn on auto-reload; otherwise it refills at the next monthly grant.")
            case .subscriptionInactive:
                return L("This workspace isn't active right now. Inviting, sharing, and pool billing are paused until the owner reactivates it.")
            case .trialWorkspaceLimit:
                return L("Your free trial covers one workspace. You can add more once the trial converts to a paid subscription.")
            case .inviteInvalid:
                return L("That invite link isn't valid. Ask your teammate for a new one.")
            case .inviteUsed:
                return L("This invite link has already been used.")
            case .inviteExpired:
                return L("This invite link has expired. Ask your teammate for a new one.")
            case .invalidAgentProof:
                return L("The agent ownership proof was rejected. Check your clock and try again.")
            case .activationCodeInvalid:
                return L("That activation link isn't valid. Open the link from your purchase page again.")
            case .activationCodeUsed:
                return L("This subscription was already activated on another account.")
            case .activationCodeExpired:
                return L("This activation link has expired. Start a new subscription on osaurus.ai.")
            case .activationConflict:
                return L("This account already has a workspace subscription. Add workspaces from the Workspaces tab, or activate the code on another account.")
            case .invalidAutoReloadConfig:
                return L("Auto-reload amounts are out of range: threshold $1–$500, reload $5–$500, cap at least the reload amount, all in whole cents.")
            case .autoReloadUnavailable:
                return L("Auto-reload needs an active workspace subscription with a saved card. Add credits once or update the card under Manage billing, then try again.")
            }
        }
        switch error {
        case .rateLimited:
            return L("Too many attempts. Please wait a moment before trying again.")
        case .unauthorized:
            return L("We couldn’t verify your identity. Check your clock and try again.")
        case .accountFrozen:
            return L("This account can’t manage workspaces right now.")
        case .noIdentity:
            return L("Set up your Osaurus Identity before using Workspaces.")
        case .transport:
            return L("We couldn’t reach the Workspaces service. Check your connection and try again.")
        case .invalidResponse:
            return L("The Workspaces service returned an invalid response. Please try again.")
        case .server(_, let message, let status) where status >= 500:
            return message.isEmpty
                ? L("The Workspaces service is temporarily unavailable. Please try again.")
                : message
        case .server(_, let message, _):
            return message
        case .firstActionPending, .invalidURL, .belowMinimumTopUp, .insufficientFunds,
            .paidWebDisabled, .idempotencyConflict:
            return error.localizedDescription
        }
    }

    // MARK: - Internals

    /// Runs one mutating action with per-key busy/error bookkeeping: the same
    /// operation can't double-fire, but unrelated operations stay usable.
    /// Returns `true` on success; failures land in `lastError`.
    private func performMutation(
        key: String,
        _ action: @MainActor () async throws -> Void
    ) async -> Bool {
        guard !busyKeys.contains(key) else { return false }
        busyKeys.insert(key)
        defer { busyKeys.remove(key) }
        do {
            try await action()
            lastError = nil
            lastErrorCode = nil
            return true
        } catch let error as OsaurusRouterAPIError {
            lastError = Self.message(for: error)
            lastErrorCode = OsaurusRouterWorkspaceErrorCode.match(error)
            return false
        } catch {
            lastError = L("We couldn’t reach the Workspaces service. Check your connection and try again.")
            lastErrorCode = nil
            return false
        }
    }

    private func noteError(_ error: Error) {
        if let routerError = error as? OsaurusRouterAPIError {
            lastError = Self.message(for: routerError)
            lastErrorCode = OsaurusRouterWorkspaceErrorCode.match(routerError)
        } else {
            lastError = L("We couldn’t reach the Workspaces service. Check your connection and try again.")
            lastErrorCode = nil
        }
    }

    /// Internal (not private) so tests can drive activation polling directly
    /// instead of posting `didBecomeActiveNotification` and racing the task.
    func handleAppActivation() async {
        guard OsaurusRouter.isEnabled else { return }
        // Return-from-Stripe path: the redirect grants nothing, the webhook
        // does, so poll the router while waiting — but give up after a
        // bounded number of fruitless polls (the tab was abandoned; the UI
        // also offers an explicit dismiss).
        if let confirmation = pendingConfirmation {
            let settled = await pollConfirmation(confirmation)
            if settled {
                endConfirmation()
            } else {
                confirmationPollCount += 1
                if confirmationPollCount >= Self.maxConfirmationPolls {
                    endConfirmation()
                }
            }
        }

        // Membership has no server push (removals, role changes, deleted
        // workspaces): refresh the list on activation so billing prefs reconcile
        // promptly, throttled so rapid app switching doesn't hammer the router.
        let stale =
            lastRootRefresh.map {
                Date().timeIntervalSince($0) >= Self.activationRefreshInterval
            } ?? true
        if stale {
            await refreshWorkspaces()
        }
    }

    /// One poll for a pending Stripe round-trip. Returns true when the
    /// expected change is visible (and the UI has been moved onto it).
    private func pollConfirmation(_ confirmation: PendingConfirmation) async -> Bool {
        switch confirmation {
        case .portal:
            guard let id = selectedWorkspaceId else { return true }
            guard let refreshed = try? await client.workspaceDetail(id: id) else { return false }
            detail = refreshed
            guard refreshed.isActive else { return false }
            await refreshSelectedWorkspace()
            await refreshWorkspaces()
            return true

        case .reactivation(let id):
            guard let refreshed = try? await client.workspaceDetail(id: id) else { return false }
            if selectedWorkspaceId == id { detail = refreshed }
            guard refreshed.isActive else { return false }
            await WorkspaceAuditLog.shared.recordOwnerAction(
                .workspaceReactivated, workspaceId: id, details: ["name": refreshed.name, "via": "checkout"]
            )
            await refreshWorkspaces()
            if selectedWorkspaceId == id {
                await refreshSelectedWorkspace()
            } else {
                await selectWorkspace(id: id)
            }
            return true

        case .checkout:
            // The list refresh spots the webhook-created workspace itself
            // (a fresh owner-role row we didn't know) and lands on it.
            await refreshWorkspaces()
            return pendingConfirmation == nil

        case .topUp(let id, let topupId, let amountMicro, let before, let startedAt):
            guard let balance = try? await client.workspaceBalance(id: id) else { return false }
            if selectedWorkspaceId == id { poolBalance = balance }
            let ledger = try? await client.workspaceTransactions(id: id, limit: 10)
            let landed = Self.topUpLanded(
                balance: balance, before: before, amountMicro: amountMicro,
                startedAt: startedAt, ledger: ledger
            )
            guard landed else { return false }
            await WorkspaceAuditLog.shared.recordOwnerAction(
                .poolTopUp, workspaceId: id,
                details: ["topup_id": topupId, "amount_micro": String(amountMicro)]
            )
            if selectedWorkspaceId == id {
                await refreshSelectedWorkspace()
            }
            return true
        }
    }

    /// Whether a pending pool top-up is visible: a `workspace_topup` ledger
    /// entry for the amount, posted since the Checkout opened (one minute of
    /// clock skew allowed), is the authoritative signal; a balance that rose
    /// by at least the amount since the Checkout opened is the fallback (a
    /// pre-0041 router's ledger won't carry the entry type).
    nonisolated static func topUpLanded(
        balance: OsaurusRouterWorkspacePoolBalance,
        before: Int64?,
        amountMicro: Int64,
        startedAt: Date,
        ledger: OsaurusRouterTransactionsResponse?
    ) -> Bool {
        let notBefore = startedAt.addingTimeInterval(-60)
        if let ledger,
            ledger.data.contains(where: { entry in
                entry.entryType == "workspace_topup"
                    && Int64(entry.amountMicro) == amountMicro
                    && (WorkspacesFormatting.parse(entry.createdAt).map { $0 >= notBefore } ?? false)
            })
        {
            return true
        }
        guard let before, let now = Int64(balance.balanceMicro) else { return false }
        return now - before >= amountMicro
    }
}
