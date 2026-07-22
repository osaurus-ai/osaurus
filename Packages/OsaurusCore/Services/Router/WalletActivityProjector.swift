import Foundation

/// Merges router usage items (billed model requests) and ledger transactions
/// (top-ups today; agent-initiated purchases later — `entryType`/`refType`
/// already discriminate them) into a single date-sorted "recent activity"
/// list for the composer wallet panel. Kept out of the view so agent
/// transaction row types have one place to land.
struct WalletActivityProjector {
    /// Newest-first merged rows, capped at `limit`. Ledger debits with an
    /// unrecognized `entry_type` are dropped: they mirror per-request spend the
    /// usage rows already list, and including both double-counts every charge.
    /// Web `settle` debits are likewise dropped — `webUsageItems` already
    /// carries every billed web request.
    func rows(
        usageItems: [OsaurusRouterUsageItem],
        transactions: [OsaurusRouterTransactionItem],
        webUsageItems: [OsaurusRouterWebUsageItem] = [],
        limit: Int = 4
    ) -> [WalletActivityRow] {
        let merged =
            usageItems.map(WalletActivityRow.init(usage:))
            + webUsageItems.map(WalletActivityRow.init(webUsage:))
            + transactions
                .filter(WalletActivityRow.isWalletVisible)
                .map(WalletActivityRow.init(transaction:))
        return Array(
            merged
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                .prefix(max(0, limit))
        )
    }
}

/// One line in the wallet panel's recent-activity list.
struct WalletActivityRow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A billed model request (from `/credits/usage`).
        case usage
        /// A ledger transaction (top-up, refund, future agent purchase).
        case transaction
        /// A billed web search/contents request (from `/credits/web-usage`).
        case webUsage
    }

    let id: String
    let kind: Kind
    /// Primary label. Plain English vocabulary like `CreditsActivityRow`'s
    /// state labels; views localize via `LocalizedStringKey`.
    let title: String
    /// Signed display amount: "+$5.00" for balance credits, "-$0.0012" for
    /// spend. Empty when the amount is unparseable.
    let amountLabel: String
    /// True when the amount adds to the balance (row tints as a credit).
    let isCredit: Bool
    let stateKind: CreditsActivityStateKind
    /// True for a hosted web request that rode the lifetime free grant —
    /// rendered in the premium (accent) family, one shade apart from paid.
    let isIncludedWebRequest: Bool
    /// Parsed timestamp used for merge ordering; nil when the server value is
    /// unparseable (such rows sort last).
    let date: Date?

    init(
        id: String,
        kind: Kind,
        title: String,
        amountLabel: String,
        isCredit: Bool,
        stateKind: CreditsActivityStateKind,
        isIncludedWebRequest: Bool = false,
        date: Date?
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.amountLabel = amountLabel
        self.isCredit = isCredit
        self.stateKind = stateKind
        self.isIncludedWebRequest = isIncludedWebRequest
        self.date = date
    }
}

extension WalletActivityRow {
    init(usage item: OsaurusRouterUsageItem) {
        let title: String
        if !item.model.isEmpty {
            title = item.model
        } else if !item.provider.isEmpty {
            title = item.provider
        } else {
            title = "Model request"
        }
        let micro = Int64(item.costMicro) ?? 0
        self.init(
            id: "usage-\(item.id)",
            kind: .usage,
            title: title,
            amountLabel: micro > 0
                ? "-" + OsaurusRouter.formatMicroUSDPrecise(item.costMicro)
                : OsaurusRouter.formatMicroUSDPrecise(item.costMicro),
            isCredit: false,
            stateKind: CreditsActivityRow.state(forStatus: item.status).kind,
            date: CreditsActivityProjector.date(fromRouterTimestamp: item.createdAt)
        )
    }

    init(transaction item: OsaurusRouterTransactionItem) {
        let micro = Int64(item.amountMicro) ?? 0
        self.init(
            id: "txn-\(item.id)",
            kind: .transaction,
            title: Self.transactionTitle(entryType: item.entryType, isCredit: micro >= 0),
            amountLabel: micro >= 0
                ? "+" + OsaurusRouter.formatMicroUSD(item.amountMicro)
                : OsaurusRouter.formatMicroUSD(item.amountMicro),
            isCredit: micro >= 0,
            stateKind: micro >= 0 ? .success : .secondary,
            date: CreditsActivityProjector.date(fromRouterTimestamp: item.createdAt)
        )
    }

    init(webUsage item: OsaurusRouterWebUsageItem) {
        let included = item.billing.lowercased() == "free"
        let micro = Int64(item.costMicro) ?? 0
        let amountLabel: String
        if included {
            amountLabel = "Included"
        } else if micro > 0 {
            amountLabel = "-" + OsaurusRouter.formatMicroUSDPrecise(item.costMicro)
        } else {
            amountLabel = OsaurusRouter.formatMicroUSDPrecise(item.costMicro)
        }
        self.init(
            id: "web-\(item.id)",
            kind: .webUsage,
            title: item.operation == "contents" ? "Page extract" : "Web search",
            amountLabel: amountLabel,
            isCredit: false,
            stateKind: CreditsActivityRow.state(forStatus: item.status).kind,
            isIncludedWebRequest: included,
            date: CreditsActivityProjector.date(fromRouterTimestamp: item.createdAt)
        )
    }

    /// Whether a ledger transaction belongs in the wallet's mini activity list.
    /// Credits (top-ups, grants, refunds — including future agent purchases,
    /// which add balance) always show; debits show only for recognized
    /// balance-adjustment types. Unrecognized debits are the ledger's mirror of
    /// per-request usage, which the usage rows already cover.
    static func isWalletVisible(_ item: OsaurusRouterTransactionItem) -> Bool {
        if (Int64(item.amountMicro) ?? 0) >= 0 { return true }
        switch item.entryType.lowercased() {
        case "refund", "adjustment":
            return true
        default:
            return false
        }
    }

    /// Map a ledger `entry_type` onto the wallet vocabulary. Unknown credit
    /// types fall back to "Credits added" so future server-side entry types
    /// (e.g. agent purchases) render sensibly before this map learns about
    /// them; unknown debits never reach here (see `isWalletVisible`).
    private static func transactionTitle(entryType: String, isCredit: Bool) -> String {
        switch entryType.lowercased() {
        case "topup", "top_up", "top-up", "purchase", "deposit", "credit":
            return "Credits added"
        case "refund":
            return "Refund"
        case "promo", "promotion", "grant", "bonus":
            return "Credits granted"
        case "adjustment":
            return "Adjustment"
        default:
            return "Credits added"
        }
    }
}
