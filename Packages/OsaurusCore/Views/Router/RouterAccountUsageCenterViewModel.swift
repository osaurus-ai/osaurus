import Combine
import Foundation

@MainActor
final class RouterAccountUsageCenterViewModel: ObservableObject {
    @Published private(set) var snapshot: RouterAccountUsageSnapshot
    @Published private(set) var ledgerEntries: [RouterBillingEntry] = []
    @Published private(set) var signedDiagnostics: [RouterSignedRequestDiagnostic] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingLedger = false
    @Published private(set) var isSigningDiagnostics = false
    @Published private(set) var isExportingSupport = false
    @Published var message: String?

    private let accountService: OsaurusRouterAccountService
    private let providerManager: RemoteProviderManager
    private let client: OsaurusRouterAPIClient
    private let ledger: RouterBillingLedger
    private let ledgerLimit = 500

    init(
        accountService: OsaurusRouterAccountService = .shared,
        providerManager: RemoteProviderManager = .shared,
        client: OsaurusRouterAPIClient = .shared,
        ledger: RouterBillingLedger = .shared
    ) {
        self.accountService = accountService
        self.providerManager = providerManager
        self.client = client
        self.ledger = ledger
        self.snapshot = RouterAccountUsageCenter.snapshot(
            routerEnabled: providerManager.isOsaurusRouterEnabled,
            identityAvailable: OsaurusIdentity.existsCached(),
            balance: accountService.balance,
            lastError: accountService.lastError,
            usageItems: accountService.usage,
            transactions: accountService.transactions,
            ledgerEntries: []
        )
    }

    var usageItems: [OsaurusRouterUsageItem] {
        accountService.usage
    }

    var transactions: [OsaurusRouterTransactionItem] {
        accountService.transactions
    }

    var isBusy: Bool {
        isRefreshing
            || isLoadingLedger
            || isSigningDiagnostics
            || isExportingSupport
            || accountService.isLoadingBalance
            || accountService.isLoadingUsage
            || accountService.isLoadingTransactions
    }

    var activityRows: [CreditsActivityRow] {
        CreditsActivityProjector().rows(
            usageItems: accountService.usage,
            ledgerEntries: ledgerEntries
        )
    }

    func refresh() async {
        isRefreshing = true
        defer {
            isRefreshing = false
            rebuildSnapshot()
        }

        if providerManager.isOsaurusRouterEnabled {
            await accountService.refreshAll()
            await accountService.refreshTransactions(reset: true)
        }
        await reloadLedger()
    }

    func loadMoreTransactions() async {
        guard providerManager.isOsaurusRouterEnabled else { return }
        await accountService.loadMoreTransactions()
        rebuildSnapshot()
    }

    func runSignedRequestDiagnostics() async {
        guard providerManager.isOsaurusRouterEnabled else {
            message = L("Osaurus Router is off.")
            return
        }
        guard OsaurusIdentity.exists() else {
            message = OsaurusRouterAPIError.noIdentity.localizedDescription
            return
        }

        isSigningDiagnostics = true
        defer { isSigningDiagnostics = false }
        do {
            let balanceRequest = try await client.signedJSONRequest(
                method: "GET",
                path: "/credits/balance",
                body: Data()
            )
            let estimateBody = Data(#"{"input_tokens":1,"max_tokens":1,"model":"diagnostic"}"#.utf8)
            let estimateRequest = try await client.signedJSONRequest(
                method: "POST",
                path: "/credits/estimate",
                body: estimateBody
            )
            signedDiagnostics = [
                RouterSignedRequestDiagnostic(request: balanceRequest, body: Data()),
                RouterSignedRequestDiagnostic(request: estimateRequest, body: estimateBody),
            ]
            message = L("Signed request diagnostics refreshed.")
        } catch {
            message = error.localizedDescription
        }
    }

    func exportSupport(to url: URL) async {
        isExportingSupport = true
        defer { isExportingSupport = false }

        rebuildSnapshot()
        let export = RouterAccountUsageCenter.supportExport(
            walletAddress: nil,
            snapshot: snapshot,
            signedDiagnostics: signedDiagnostics,
            usageItems: accountService.usage,
            transactions: accountService.transactions,
            ledgerEntries: ledgerEntries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(export)
            try data.write(to: url, options: .atomic)
            message = String(
                localized: "Exported router support bundle to \(url.lastPathComponent).",
                bundle: .module
            )
        } catch {
            message = error.localizedDescription
        }
    }

    private func reloadLedger() async {
        isLoadingLedger = true
        defer { isLoadingLedger = false }

        let limit = ledgerLimit
        let ledger = ledger
        let entries = await Task.detached(priority: .utility) {
            ledger.recent(limit: limit)
        }.value
        ledgerEntries = entries
    }

    private func rebuildSnapshot() {
        snapshot = RouterAccountUsageCenter.snapshot(
            routerEnabled: providerManager.isOsaurusRouterEnabled,
            identityAvailable: OsaurusIdentity.existsCached(),
            balance: accountService.balance,
            lastError: accountService.lastError,
            usageItems: accountService.usage,
            transactions: accountService.transactions,
            ledgerEntries: ledgerEntries
        )
    }
}
