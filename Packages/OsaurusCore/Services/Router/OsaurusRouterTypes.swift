import Foundation

enum OsaurusRouter {
    static let productionBaseURL = URL(string: "https://router.osaurus.ai")!
    static let stagingBaseURL = URL(string: "https://osaurus-router.fly.dev")!

    static var defaultBaseURL: URL {
        if let override = UserDefaults.standard.string(forKey: "ai.osaurus.router.baseURL"),
            let url = URL(string: override.trimmingCharacters(in: .whitespacesAndNewlines)),
            url.scheme != nil,
            url.host != nil
        {
            return url
        }
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
