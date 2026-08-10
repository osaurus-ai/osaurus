import AppKit
import Foundation

@MainActor
final class OsaurusRouterAccountService: ObservableObject {
    static let shared = OsaurusRouterAccountService()

    @Published private(set) var balance: OsaurusRouterBalanceResponse?
    @Published private(set) var usage: [OsaurusRouterUsageItem] = []
    @Published private(set) var nextUsageCursor: String?
    @Published private(set) var transactions: [OsaurusRouterTransactionItem] = []
    @Published private(set) var nextTransactionsCursor: String?
    @Published private(set) var isLoadingBalance = false
    @Published private(set) var isLoadingUsage = false
    @Published private(set) var isLoadingTransactions = false
    @Published private(set) var isCreatingCheckout = false
    @Published var lastError: String?

    // MARK: Hosted web search state

    /// Auto-pay preference + lifetime free-grant state from
    /// `GET /credits/web-settings`; nil until first fetched.
    @Published private(set) var webSettings: OsaurusRouterWebSettingsResponse?
    /// Metadata-only history of billed web requests (`/credits/web-usage`).
    @Published private(set) var webUsage: [OsaurusRouterWebUsageItem] = []
    @Published private(set) var nextWebUsageCursor: String?
    @Published private(set) var isLoadingWebSettings = false
    @Published private(set) var isLoadingWebUsage = false
    @Published private(set) var isUpdatingWebSettings = false
    /// Billing outcome of the most recent hosted search/contents call this
    /// session; drives the search-credit balance hint.
    @Published private(set) var lastWebBilling: RouterWebBillingSummary?
    /// Set when a hosted web search hit `402 INSUFFICIENT_FUNDS` — premium
    /// search is falling back to built-in sources until the user tops up. Cleared
    /// when the balance rises or a hosted request succeeds again.
    @Published private(set) var webSearchNeedsTopUp = false

    private let client: OsaurusRouterAPIClient
    // Retained for the lifetime of the singleton so balance refreshes when the
    // user returns from Stripe Checkout or another app.
    private var activationObserver: NSObjectProtocol?
    /// Set when a Checkout session is created; cleared once an observed balance
    /// increase confirms it. Gates `balance_topup_succeeded` so it fires for a
    /// real top-up rather than any incidental balance refresh.
    private var awaitingTopUpConfirmation = false

    init(client: OsaurusRouterAPIClient = .shared) {
        self.client = client
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshBalance()
            }
        }
    }

    var formattedBalance: String {
        OsaurusRouter.formatMicroUSD(balance?.balanceMicro ?? "0")
    }

    /// Current balance in micro-USD (0 when unknown or unparseable).
    var balanceMicroValue: Int64 {
        Int64(balance?.balanceMicro ?? "") ?? 0
    }

    var isFrozen: Bool {
        balance?.frozen == true
    }

    func refreshAll() async {
        guard OsaurusRouter.isEnabled else { return }
        await RemoteProviderManager.shared.connectOsaurusRouterIfPossible()
        await refreshBalance()
        await refreshUsage(reset: true)
    }

    /// Clear all cached account state when the user turns the router off. Called
    /// from `RemoteProviderManager.setOsaurusRouterEnabled(false)` so the Credits
    /// UI doesn't show a stale balance/activity while server polling is stopped.
    func clearForDisabledRouter() {
        balance = nil
        usage = []
        nextUsageCursor = nil
        transactions = []
        nextTransactionsCursor = nil
        lastError = nil
        webSettings = nil
        webUsage = []
        nextWebUsageCursor = nil
        lastWebBilling = nil
        webSearchNeedsTopUp = false
    }

    func refreshBalance() async {
        // Master switch off: never hit `/credits/balance`. This also neutralizes
        // the `didBecomeActive` observer below, which calls straight in here.
        guard OsaurusRouter.isEnabled else { return }
        // Eventually-consistent gate: `exists()` issues a synchronous keychain
        // query that blocks the main actor for seconds. The memo is updated
        // in-process on identity install/delete, so the balance refresh never
        // needs a per-call `SecItemCopyMatching` here.
        guard OsaurusIdentity.existsCached() else {
            balance = nil
            lastError = OsaurusRouterAPIError.noIdentity.localizedDescription
            return
        }

        isLoadingBalance = true
        defer { isLoadingBalance = false }
        do {
            let previousMicro = balanceMicroValue
            let newBalance = try await client.balance()
            balance = newBalance
            lastError = nil
            // Best-effort top-up confirmation: a balance increase after we
            // initiated a Checkout (and returned to the app) means the funds
            // landed. Server-side webhook confirmation isn't available client-
            // side, so this stands in — and it never fires on mere sheet
            // dismissal because the balance wouldn't have moved.
            let newMicro = Int64(newBalance.balanceMicro) ?? 0
            if awaitingTopUpConfirmation, newMicro > previousMicro {
                awaitingTopUpConfirmation = false
                FeatureTelemetry.balanceTopUpSucceeded()
            }
            // A top-up lifts the premium-search exhaustion state; the next
            // hosted search can bill the balance again.
            if webSearchNeedsTopUp, newMicro > previousMicro {
                webSearchNeedsTopUp = false
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshUsage(reset: Bool = true) async {
        guard OsaurusRouter.isEnabled else { return }
        guard OsaurusIdentity.exists() else {
            usage = []
            nextUsageCursor = nil
            lastError = OsaurusRouterAPIError.noIdentity.localizedDescription
            return
        }

        if reset {
            nextUsageCursor = nil
        }
        isLoadingUsage = true
        defer { isLoadingUsage = false }
        do {
            let response = try await client.usage(limit: 50, cursor: reset ? nil : nextUsageCursor)
            usage = reset ? response.data : usage + response.data
            nextUsageCursor = response.nextCursor
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadMoreUsage() async {
        guard nextUsageCursor != nil, !isLoadingUsage else { return }
        await refreshUsage(reset: false)
    }

    func refreshTransactions(reset: Bool = true) async {
        guard OsaurusRouter.isEnabled else { return }
        guard OsaurusIdentity.exists() else {
            transactions = []
            nextTransactionsCursor = nil
            lastError = OsaurusRouterAPIError.noIdentity.localizedDescription
            return
        }

        if reset {
            nextTransactionsCursor = nil
        }
        isLoadingTransactions = true
        defer { isLoadingTransactions = false }
        do {
            let response = try await client.transactions(limit: 50, cursor: reset ? nil : nextTransactionsCursor)
            transactions = reset ? response.data : transactions + response.data
            nextTransactionsCursor = response.nextCursor
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadMoreTransactions() async {
        guard nextTransactionsCursor != nil, !isLoadingTransactions else { return }
        await refreshTransactions(reset: false)
    }

    func createCheckout(amountMicro: Int = OsaurusRouter.minimumTopUpMicro) async -> URL? {
        guard amountMicro >= OsaurusRouter.minimumTopUpMicro else {
            lastError = OsaurusRouterAPIError.belowMinimumTopUp.localizedDescription
            return nil
        }
        guard OsaurusIdentity.exists() else {
            lastError = OsaurusRouterAPIError.noIdentity.localizedDescription
            return nil
        }

        isCreatingCheckout = true
        defer { isCreatingCheckout = false }
        do {
            let checkout = try await client.checkout(amountMicro: String(amountMicro))
            guard let url = URL(string: checkout.checkoutURL) else {
                throw OsaurusRouterAPIError.invalidResponse
            }
            lastError = nil
            // A Checkout session exists and is about to open. Arm the
            // confirmation watcher so the next balance increase counts as a
            // completed top-up.
            awaitingTopUpConfirmation = true
            FeatureTelemetry.balanceTopUpInitiated()
            return url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func noteRouterSummary(_ summary: OsaurusRouterSummaryEvent.Summary) {
        guard let current = balance, let currentMicro = Int64(current.balanceMicro),
            let costMicro = Int64(summary.costMicro)
        else {
            Task { await refreshBalance() }
            return
        }
        let updated = max(0, currentMicro - costMicro)
        balance = OsaurusRouterBalanceResponse(balanceMicro: String(updated), frozen: current.frozen)
        Task { await refreshUsage(reset: true) }
    }

    // MARK: - Hosted web search

    func refreshWebSettings() async {
        guard OsaurusRouter.isEnabled, OsaurusIdentity.existsCached() else { return }
        isLoadingWebSettings = true
        defer { isLoadingWebSettings = false }
        do {
            webSettings = try await client.webSettings()
        } catch {
            // 404 = hosted web search disabled server-side; leave settings nil
            // without surfacing an error (the Credits card hides itself).
            if !Self.isFeatureUnavailable(error) {
                lastError = error.localizedDescription
            }
        }
    }

    func setWebAutoPay(_ enabled: Bool) async {
        guard OsaurusRouter.isEnabled, OsaurusIdentity.existsCached() else { return }
        isUpdatingWebSettings = true
        defer { isUpdatingWebSettings = false }
        do {
            webSettings = try await client.updateWebSettings(autoPayEnabled: enabled)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshWebUsage(reset: Bool = true) async {
        guard OsaurusRouter.isEnabled, OsaurusIdentity.existsCached() else {
            webUsage = []
            nextWebUsageCursor = nil
            return
        }
        if reset {
            nextWebUsageCursor = nil
        }
        isLoadingWebUsage = true
        defer { isLoadingWebUsage = false }
        do {
            let response = try await client.webUsage(limit: 50, cursor: reset ? nil : nextWebUsageCursor)
            webUsage = reset ? response.data : webUsage + response.data
            nextWebUsageCursor = response.nextCursor
        } catch {
            if !Self.isFeatureUnavailable(error) {
                lastError = error.localizedDescription
            }
        }
    }

    func loadMoreWebUsage() async {
        guard nextWebUsageCursor != nil, !isLoadingWebUsage else { return }
        await refreshWebUsage(reset: false)
    }

    /// Apply the billing outcome of a hosted search/contents response: an
    /// optimistic balance decrement for paid requests (same pattern as
    /// `noteRouterSummary`) plus a cached grant snapshot for the Credits UI.
    /// Called after every hosted response, so a success also clears the
    /// exhaustion flag.
    func noteWebBilling(_ summary: RouterWebBillingSummary) {
        lastWebBilling = summary
        webSearchNeedsTopUp = false

        // Keep the cached grant counters current without another round-trip.
        if let included = summary.allowanceIncluded,
            let used = summary.allowanceUsed,
            let remaining = summary.allowanceRemaining
        {
            let allowance = OsaurusRouterWebAllowance(
                includedTotal: included, usedTotal: used, remainingTotal: remaining)
            var settings =
                webSettings
                ?? OsaurusRouterWebSettingsResponse(autoPayEnabled: true, grants: nil)
            var grants = settings.grants ?? .init(search: nil, contents: nil)
            if summary.operation == "contents" {
                grants.contents = allowance
            } else {
                grants.search = allowance
            }
            settings.grants = grants
            webSettings = settings
        }

        guard let current = balance, let currentMicro = Int64(current.balanceMicro),
            let costMicro = Int64(summary.costMicro), costMicro > 0
        else { return }
        let updated = max(0, currentMicro - costMicro)
        balance = OsaurusRouterBalanceResponse(balanceMicro: String(updated), frozen: current.frozen)
    }

    /// A hosted web request failed with `402 INSUFFICIENT_FUNDS`. The search
    /// itself falls back to built-in sources, but the billing state must still
    /// reach the UI: refresh server truth and surface the top-up hint.
    func noteWebInsufficientFunds() {
        webSearchNeedsTopUp = true
        Task { await refreshBalance() }
    }

    /// A hosted web request returned `402 PAID_WEB_DISABLED`: the user's
    /// auto-pay switch is off and the grant is exhausted. Not an error —
    /// just keep the cached setting truthful.
    func noteWebPaidDisabled() {
        if var settings = webSettings {
            settings.autoPayEnabled = false
            webSettings = settings
        }
    }

    private static func isFeatureUnavailable(_ error: Error) -> Bool {
        if case .server(_, _, let status) = error as? OsaurusRouterAPIError {
            return status == 404
        }
        return false
    }

    // MARK: - Missing-summary reconciliation

    /// Debounce window before the server-truth refresh fires. Long enough to
    /// collapse a burst of failing streams (e.g. brief offline window, agent
    /// loop erroring repeatedly) into one refresh pass, short enough that the
    /// Credits UI catches up while the user is still looking at it.
    nonisolated static let missingSummaryReconcileDebounce: TimeInterval = 5

    private var missingSummaryReconcileTask: Task<Void, Never>?

    /// A Router stream reached the wire but terminated without its billing
    /// summary frame (mid-stream error, user cancel, truncation). The server
    /// may still have charged for the partial generation, and the optimistic
    /// local decrement (`noteRouterSummary`) never ran — so the cached
    /// balance/usage can drift from server truth. Schedule a debounced
    /// balance + usage refresh as reconciliation; the server is authoritative.
    func reconcileAfterStreamWithoutSummary() {
        guard OsaurusRouter.isEnabled else { return }
        missingSummaryReconcileTask?.cancel()
        missingSummaryReconcileTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.missingSummaryReconcileDebounce * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            await self?.refreshBalance()
            await self?.refreshUsage(reset: true)
        }
    }
}
