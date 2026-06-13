import AppKit
import Foundation

@MainActor
final class OsaurusRouterAccountService: ObservableObject {
    static let shared = OsaurusRouterAccountService()

    @Published private(set) var balance: OsaurusRouterBalanceResponse?
    @Published private(set) var usage: [OsaurusRouterUsageItem] = []
    @Published private(set) var nextUsageCursor: String?
    @Published private(set) var isLoadingBalance = false
    @Published private(set) var isLoadingUsage = false
    @Published private(set) var isCreatingCheckout = false
    @Published var lastError: String?

    private let client: OsaurusRouterAPIClient
    // Retained for the lifetime of the singleton so balance refreshes when the
    // user returns from Stripe Checkout or another app.
    private var activationObserver: NSObjectProtocol?

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

    var isFrozen: Bool {
        balance?.frozen == true
    }

    func refreshAll() async {
        await RemoteProviderManager.shared.connectOsaurusRouterIfPossible()
        await refreshBalance()
        await refreshUsage(reset: true)
    }

    func refreshBalance() async {
        guard OsaurusIdentity.exists() else {
            balance = nil
            lastError = OsaurusRouterAPIError.noIdentity.localizedDescription
            return
        }

        isLoadingBalance = true
        defer { isLoadingBalance = false }
        do {
            balance = try await client.balance()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshUsage(reset: Bool = true) async {
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
