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
}
