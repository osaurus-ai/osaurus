import Foundation

enum OsaurusRouter {
    static let productionBaseURL = URL(string: "https://router.osaurus.ai")!
    static let stagingBaseURL = URL(string: "https://osaurus-router.fly.dev")!

    static var defaultBaseURL: URL {
        // The UserDefaults override exists for staging/local Router testing
        // only. Router requests are master-key-signed and credit-billed, so
        // in release builds a writable base URL would let anything that can
        // write this process's defaults (e.g. `defaults write`) redirect
        // signed spend to an arbitrary host. DEBUG-only, hard-locked to
        // production otherwise.
        #if DEBUG
            if let override = UserDefaults.standard.string(forKey: "ai.osaurus.router.baseURL"),
                let url = URL(string: override.trimmingCharacters(in: .whitespacesAndNewlines)),
                url.scheme != nil,
                url.host != nil
            {
                return url
            }
        #endif
        return productionBaseURL
    }

    /// UserDefaults key backing the user's master on/off switch for the Osaurus
    /// Router. Absent = enabled, so the router is on by default for everyone and
    /// only an explicit opt-out turns it off.
    static let enabledDefaultsKey = "ai.osaurus.router.enabled"

    /// Whether the Osaurus Router is enabled for this user. Defaults to `true`
    /// when the key was never written, so existing installs (and tests) stay on.
    /// When `false`, the managed router provider is dropped from the model
    /// picker and every router/credits server request is suppressed.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// Persist the user's master on/off choice for the Osaurus Router.
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledDefaultsKey)
    }

    /// UserDefaults key backing the opt-in that lets *key-less* loopback API
    /// callers route requests through the Osaurus Router.
    static let allowUnkeyedLoopbackSpendDefaultsKey =
        "ai.osaurus.router.allowUnkeyedLoopbackSpend"

    /// Whether local (loopback) HTTP callers that did not present a valid
    /// access key may route requests to the Osaurus Router. Router requests
    /// are signed with the user's master key and spend real credits, so this
    /// defaults to `false`: without the opt-in, any local process could spend
    /// the user's balance through the unauthenticated loopback API. Keyed
    /// callers (valid `Authorization: Bearer <access key>`) are always
    /// allowed.
    static var allowsUnkeyedLoopbackSpend: Bool {
        UserDefaults.standard.bool(forKey: allowUnkeyedLoopbackSpendDefaultsKey)
    }

    /// Persist the user's explicit opt-in for key-less loopback Router spend.
    static func setAllowsUnkeyedLoopbackSpend(_ allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: allowUnkeyedLoopbackSpendDefaultsKey)
    }

    static let minimumTopUpMicro = 5_000_000

    static func formatMicroUSD(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNegative = trimmed.hasPrefix("-")
        let unsigned = String(trimmed.drop { $0 == "-" || $0 == "+" })
        guard let micro = Int64(unsigned) else { return "$0.00" }

        let dollars = micro / 1_000_000
        let cents = (micro % 1_000_000) / 10_000
        let sign = isNegative ? "-" : ""
        return "\(sign)$\(dollars).\(String(format: "%02d", cents))"
    }

    /// Like `formatMicroUSD` but keeps sub-cent precision so tiny per-request
    /// charges don't all collapse to "$0.00". Two decimals at or above one cent,
    /// four decimals below it, and "<$0.0001" for a non-zero amount smaller than
    /// that. Intended for per-row cost display, not the headline balance.
    static func formatMicroUSDPrecise(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNegative = trimmed.hasPrefix("-")
        let unsigned = String(trimmed.drop { $0 == "-" || $0 == "+" })
        guard let micro = Int64(unsigned), micro != 0 else { return "$0.00" }

        let sign = isNegative ? "-" : ""
        let dollars = Double(micro) / 1_000_000.0
        if micro >= 10_000 {
            return "\(sign)$\(String(format: "%.2f", dollars))"
        }
        if micro < 100 {
            return "\(sign)<$0.0001"
        }
        return "\(sign)$\(String(format: "%.4f", dollars))"
    }

    /// True when a chat/stream error string indicates the router rejected the
    /// request for lack of credits (HTTP 402 `INSUFFICIENT_FUNDS`). The
    /// streaming path surfaces the raw server body inside a
    /// `RemoteProviderServiceError.requestFailed("HTTP 402: {json}")` string,
    /// so match the stable server error code rather than a localized message.
    static func isInsufficientFundsError(_ message: String) -> Bool {
        message.range(of: "INSUFFICIENT_FUNDS", options: .caseInsensitive) != nil
    }
}

struct OsaurusRouterErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let message: String
    }

    let error: Body
}

enum OsaurusRouterAPIError: LocalizedError, Sendable {
    case noIdentity
    case invalidURL
    case invalidResponse
    case transport(String)
    case server(code: String, message: String, status: Int)
    case belowMinimumTopUp
    case insufficientFunds
    case accountFrozen
    case unauthorized
    case rateLimited(retryAfter: String?)
    /// 402 `PAID_WEB_DISABLED`: the user turned off balance billing for web
    /// search; the free grant is exhausted. Not an error state for the UI —
    /// the client falls back to the local cascade silently.
    case paidWebDisabled
    /// 409 `IDEMPOTENCY_CONFLICT`: same key reused with a different body or
    /// while the original is still in flight. Indicates a client bug.
    case idempotencyConflict

    var errorDescription: String? {
        switch self {
        case .noIdentity:
            return "Set up your Osaurus Identity before using the router."
        case .invalidURL:
            return "Router URL is invalid."
        case .invalidResponse:
            return "Router returned an invalid response."
        case .transport(let message):
            return message
        case .server(_, let message, _):
            return message
        case .belowMinimumTopUp:
            return "Minimum top-up is $5.00."
        case .insufficientFunds:
            return "Insufficient credits. Add balance to continue."
        case .accountFrozen:
            return "Your Osaurus billing account is on hold."
        case .unauthorized:
            return "Router authentication failed. Check your clock and identity."
        case .rateLimited:
            return "Too many router requests. Please try again in a moment."
        case .paidWebDisabled:
            return "Paid web search is turned off. Remaining search credits still work."
        case .idempotencyConflict:
            return "Duplicate router request detected."
        }
    }

    static func from(code: String, message: String, status: Int, retryAfter: String? = nil) -> OsaurusRouterAPIError {
        switch code {
        case "BELOW_MINIMUM_TOPUP":
            return .belowMinimumTopUp
        case "INSUFFICIENT_FUNDS":
            return .insufficientFunds
        case "ACCOUNT_FROZEN":
            return .accountFrozen
        case "UNAUTHORIZED", "INVALID_SIGNATURE":
            return .unauthorized
        case "RATE_LIMITED":
            return .rateLimited(retryAfter: retryAfter)
        case "PAID_WEB_DISABLED":
            return .paidWebDisabled
        case "IDEMPOTENCY_CONFLICT":
            return .idempotencyConflict
        default:
            return .server(code: code, message: message, status: status)
        }
    }
}

struct OsaurusRouterBalanceResponse: Decodable, Equatable, Sendable {
    let balanceMicro: String
    let frozen: Bool

    enum CodingKeys: String, CodingKey {
        case balanceMicro = "balance_micro"
        case frozen
    }
}

/// `POST /credits/welcome/claim` result. `granted` with
/// `already_granted == true` is a deduped retry of a claim that landed
/// earlier — both shapes are success for the client.
struct OsaurusRouterWelcomeClaimResponse: Decodable, Equatable, Sendable {
    let granted: Bool
    let alreadyGranted: Bool
    let amountMicro: String

    enum CodingKeys: String, CodingKey {
        case granted
        case alreadyGranted = "already_granted"
        case amountMicro = "amount_micro"
    }
}

struct OsaurusRouterCheckoutResponse: Decodable, Equatable, Sendable {
    let clientSecret: String
    let checkoutURL: String

    enum CodingKeys: String, CodingKey {
        case clientSecret = "client_secret"
        case checkoutURL = "checkout_url"
    }
}

struct OsaurusRouterModelListResponse: Decodable, Sendable {
    let data: [OsaurusRouterModel]
}

struct OsaurusRouterModelDiscovery: Equatable, Sendable {
    let models: [String]
    let totalCount: Int
    let staleCount: Int
    /// Full per-model metadata for the fresh (non-stale) models, keyed by the
    /// unprefixed model id (matching `models`). Lets the picker show provider,
    /// pricing, and context without re-fetching `/models`.
    let catalog: [String: OsaurusRouterModel]

    init(
        models: [String],
        totalCount: Int,
        staleCount: Int,
        catalog: [String: OsaurusRouterModel] = [:]
    ) {
        self.models = models
        self.totalCount = totalCount
        self.staleCount = staleCount
        self.catalog = catalog
    }
}

struct OsaurusRouterModel: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let provider: String
    let contextLength: Int
    let inputMicroPerMTok: String
    let outputMicroPerMTok: String
    let inputDisplay: String
    let outputDisplay: String
    let stale: Bool
    let capabilities: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case id, provider, capabilities, stale
        case contextLength = "context_length"
        case inputMicroPerMTok = "input_micro_per_mtok"
        case outputMicroPerMTok = "output_micro_per_mtok"
        case inputDisplay = "input_display"
        case outputDisplay = "output_display"
    }
}

struct OsaurusRouterUsageResponse: Decodable, Sendable {
    let data: [OsaurusRouterUsageItem]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextCursor = "next_cursor"
    }
}

struct OsaurusRouterUsageItem: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let requestId: String?
    let model: String
    let provider: String
    let inputTokens: Int
    let outputTokens: Int
    let costMicro: String
    let status: String
    let tokenSource: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, model, provider, status
        case requestId = "request_id"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costMicro = "cost_micro"
        case tokenSource = "token_source"
        case createdAt = "created_at"
    }
}

struct OsaurusRouterTransactionsResponse: Decodable, Sendable {
    let data: [OsaurusRouterTransactionItem]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextCursor = "next_cursor"
    }
}

struct OsaurusRouterTransactionItem: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let amountMicro: String
    let entryType: String
    let refType: String?
    let refId: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case amountMicro = "amount_micro"
        case entryType = "entry_type"
        case refType = "ref_type"
        case refId = "ref_id"
        case createdAt = "created_at"
    }
}

struct OsaurusRouterEstimateResponse: Decodable, Equatable, Sendable {
    let estimatedMaxMicro: String
    let typicalMicro: String

    enum CodingKeys: String, CodingKey {
        case estimatedMaxMicro = "estimated_max_micro"
        case typicalMicro = "typical_micro"
    }
}

struct OsaurusRouterSummaryEvent: Decodable, Equatable, Sendable {
    struct Summary: Decodable, Equatable, Sendable {
        let requestId: String?
        let costMicro: String
        let status: String
        let tokenSource: String
        let inputTokens: Int
        let outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case costMicro = "cost_micro"
            case status
            case tokenSource = "token_source"
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    let osaurus: Summary
}

/// Local, persistable snapshot of a single Osaurus Router billing event.
///
/// `OsaurusRouterSummaryEvent.Summary` is the wire shape (`Decodable`-only); this
/// is the decoupled value the app actually carries around — encoded onto the chat
/// stream as a `StreamingBillingHint`, stamped on the assistant `ChatTurn`, and
/// written to the on-device billing ledger. Metadata only: no prompt/response text.
public struct RouterBillingSummary: Codable, Equatable, Sendable {
    public var requestId: String?
    public var costMicro: String
    public var status: String
    public var tokenSource: String
    public var inputTokens: Int
    public var outputTokens: Int

    public init(
        requestId: String? = nil,
        costMicro: String,
        status: String,
        tokenSource: String,
        inputTokens: Int,
        outputTokens: Int
    ) {
        self.requestId = requestId
        self.costMicro = costMicro
        self.status = status
        self.tokenSource = tokenSource
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    init(_ summary: OsaurusRouterSummaryEvent.Summary) {
        self.requestId = summary.requestId
        self.costMicro = summary.costMicro
        self.status = summary.status
        self.tokenSource = summary.tokenSource
        self.inputTokens = summary.inputTokens
        self.outputTokens = summary.outputTokens
    }
}

// MARK: - Hosted web search (`/v1/search`, `/v1/contents`, `/credits/web-*`)

/// `POST /v1/search` body. Field names are the wire names; the canonical
/// encoder sorts keys so the signed bytes equal the sent bytes.
struct OsaurusRouterWebSearchRequestBody: Encodable, Sendable {
    var query: String
    var category: String?
    var num_results: Int?
    var site: String?
    var file_type: String?
    var time_range: String?
    var region: String?
    var contents: OsaurusRouterWebContentsSpec?
    var idempotency_key: String
}

/// `POST /v1/contents` body.
struct OsaurusRouterWebContentsRequestBody: Encodable, Sendable {
    var urls: [String]
    var contents: OsaurusRouterWebContentsSpec?
    var idempotency_key: String
}

/// The optional `contents` extraction spec shared by both POST routes.
struct OsaurusRouterWebContentsSpec: Encodable, Sendable {
    struct Text: Encodable, Sendable {
        var max_characters: Int
    }

    var text: Text?
    var highlights: Bool?
}

/// Lifetime free-request grant state for one operation. Grants never refill;
/// `nil` on a response means the account holds no one-time grant.
struct OsaurusRouterWebAllowance: Decodable, Equatable, Sendable {
    let includedTotal: Int
    let usedTotal: Int
    let remainingTotal: Int

    enum CodingKeys: String, CodingKey {
        case includedTotal = "included_total"
        case usedTotal = "used_total"
        case remainingTotal = "remaining_total"
    }
}

/// The `osaurus` billing object every hosted search/contents response carries.
struct OsaurusRouterWebBilling: Decodable, Equatable, Sendable {
    let requestId: String?
    let operation: String
    let provider: String?
    /// "free" (inside the grant) or "paid" (billed against the balance).
    let billing: String
    let costMicro: String
    let allowance: OsaurusRouterWebAllowance?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case operation, provider, billing, allowance, status
        case requestId = "request_id"
        case costMicro = "cost_micro"
    }
}

/// One result row from `/v1/search` or `/v1/contents`. `text` / `highlights`
/// / `summary` appear only when requested and returned.
struct OsaurusRouterWebResult: Decodable, Sendable {
    let title: String?
    let url: String?
    let publishedDate: String?
    let author: String?
    let highlights: [String]?
    let text: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case title, url, author, highlights, text, summary
        case publishedDate = "published_date"
    }
}

struct OsaurusRouterWebSearchResponse: Decodable, Sendable {
    let requestId: String?
    let results: [OsaurusRouterWebResult]
    let warnings: [String]?
    /// True when this idempotency key already completed server-side: billing
    /// metadata is authoritative but `results` is empty (content is never
    /// persisted, so it cannot be replayed).
    let replayed: Bool?
    let osaurus: OsaurusRouterWebBilling?

    enum CodingKeys: String, CodingKey {
        case results, warnings, replayed, osaurus
        case requestId = "request_id"
    }
}

/// Per-URL fetch outcome in a `/v1/contents` response. Failed pages are not
/// billed; the client falls back locally per URL.
struct OsaurusRouterWebURLStatus: Decodable, Equatable, Sendable {
    let url: String
    let status: String
    let error: String?
}

struct OsaurusRouterWebContentsResponse: Decodable, Sendable {
    let requestId: String?
    let results: [OsaurusRouterWebResult]
    let statuses: [OsaurusRouterWebURLStatus]?
    let replayed: Bool?
    let osaurus: OsaurusRouterWebBilling?

    enum CodingKeys: String, CodingKey {
        case results, statuses, replayed, osaurus
        case requestId = "request_id"
    }
}

/// `GET/POST /credits/web-settings`: the paid-web-search switch plus the
/// current lifetime grant state per operation.
struct OsaurusRouterWebSettingsResponse: Decodable, Equatable, Sendable {
    struct Grants: Decodable, Equatable, Sendable {
        var search: OsaurusRouterWebAllowance?
        var contents: OsaurusRouterWebAllowance?
    }

    var autoPayEnabled: Bool
    var grants: Grants?

    enum CodingKeys: String, CodingKey {
        case grants
        case autoPayEnabled = "auto_pay_enabled"
    }

    init(autoPayEnabled: Bool, grants: Grants?) {
        self.autoPayEnabled = autoPayEnabled
        self.grants = grants
    }
}

struct OsaurusRouterWebUsageResponse: Decodable, Sendable {
    let data: [OsaurusRouterWebUsageItem]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextCursor = "next_cursor"
    }
}

/// One metadata-only billed web request from `GET /credits/web-usage` — no
/// queries, URLs, or content, by design.
struct OsaurusRouterWebUsageItem: Decodable, Identifiable, Equatable, Sendable {
    struct Units: Decodable, Equatable, Sendable {
        let requests: Int?
        let extraResults: Int?
        let contentPages: Int?
        let summaryPages: Int?

        enum CodingKeys: String, CodingKey {
            case requests
            case extraResults = "extra_results"
            case contentPages = "content_pages"
            case summaryPages = "summary_pages"
        }
    }

    let id: String
    let requestId: String?
    let operation: String
    let provider: String?
    let billing: String
    let units: Units?
    let costMicro: String
    let status: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, operation, provider, billing, units, status
        case requestId = "request_id"
        case costMicro = "cost_micro"
        case createdAt = "created_at"
    }
}

/// Local, persistable snapshot of one hosted web search/contents billing
/// outcome — the web analogue of `RouterBillingSummary`. Metadata only:
/// never a query, URL, or page content.
public struct RouterWebBillingSummary: Codable, Equatable, Sendable {
    public var requestId: String?
    /// "search" or "contents".
    public var operation: String
    /// "free" (grant) or "paid" (balance).
    public var billing: String
    public var costMicro: String
    public var allowanceIncluded: Int?
    public var allowanceUsed: Int?
    public var allowanceRemaining: Int?
    public var status: String?

    public init(
        requestId: String? = nil,
        operation: String,
        billing: String,
        costMicro: String,
        allowanceIncluded: Int? = nil,
        allowanceUsed: Int? = nil,
        allowanceRemaining: Int? = nil,
        status: String? = nil
    ) {
        self.requestId = requestId
        self.operation = operation
        self.billing = billing
        self.costMicro = costMicro
        self.allowanceIncluded = allowanceIncluded
        self.allowanceUsed = allowanceUsed
        self.allowanceRemaining = allowanceRemaining
        self.status = status
    }

    init(_ billing: OsaurusRouterWebBilling) {
        self.requestId = billing.requestId
        self.operation = billing.operation
        self.billing = billing.billing
        self.costMicro = billing.costMicro
        self.allowanceIncluded = billing.allowance?.includedTotal
        self.allowanceUsed = billing.allowance?.usedTotal
        self.allowanceRemaining = billing.allowance?.remainingTotal
        self.status = billing.status
    }

    /// True when the request rode the lifetime free grant.
    public var isIncluded: Bool { billing.lowercased() == "free" }
}
