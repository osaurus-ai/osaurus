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

    /// Micro-USD per user-facing credit: 1 credit = 100 micro = $0.0001,
    /// so $1 = 10,000 credits. Micro-USD stays the wire/arithmetic unit;
    /// credits exist only for display.
    static let microPerCredit: Int64 = 100

    /// Dollar formatting for the real-money top-up flow (Stripe charges in
    /// USD). Everything else in the UI shows credits via
    /// `formatMicroAsCredits`.
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

    /// Formats a micro-USD amount as user-facing credits (1 credit = 100
    /// micro). New charges are always whole credits; balances predating the
    /// credit system can carry sub-credit residue, rendered as up to two
    /// decimals (e.g. `"7250037"` -> `72,500.37 credits`). Non-zero amounts
    /// below one credit render as `<1 credit` so tiny legacy charges don't
    /// collapse to zero. The sign is preserved for activity rows.
    static func formatMicroAsCredits(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNegative = trimmed.hasPrefix("-")
        let unsigned = String(trimmed.drop { $0 == "-" || $0 == "+" })
        guard let micro = Int64(unsigned), micro != 0 else { return "0 credits" }

        let sign = isNegative ? "-" : ""
        let credits = micro / microPerCredit
        let residue = micro % microPerCredit
        if credits == 0 {
            return "\(sign)<1 credit"
        }
        var body = groupedThousands(credits)
        if residue != 0 {
            body += ".\(String(format: "%02d", residue))"
        }
        let unit = (credits == 1 && residue == 0) ? "credit" : "credits"
        return "\(sign)\(body) \(unit)"
    }

    /// "N cached" label for the router's prompt-cache split: how much of a
    /// turn's (or session's) input was served from the upstream cache and so
    /// billed at the discounted rate. `nil` when nothing was cached, so
    /// callers can hide the label entirely instead of rendering "0 cached".
    /// Pass `inputTokens` to append the hit ratio (`"3,200 cached · 80%"`);
    /// the ratio is omitted when the total is unknown, zero, or the cached
    /// count exceeds it (a defensive guard — the router already clamps).
    static func formatCachedInputLabel(cachedTokens: Int, inputTokens: Int? = nil) -> String? {
        guard cachedTokens > 0 else { return nil }
        var label = "\(groupedThousands(Int64(cachedTokens))) cached"
        if let inputTokens, inputTokens > 0, cachedTokens <= inputTokens {
            let percent = Int((Double(cachedTokens) / Double(inputTokens) * 100).rounded())
            label += " · \(percent)%"
        }
        return label
    }

    /// Hero-figure variant of `formatMicroAsCredits`: the grouped whole-credit
    /// number without the unit, so large balances can render with "credits" as
    /// a small caption instead of inside the oversized monospaced string.
    /// Sub-credit residue is dropped here — it's display noise at headline
    /// size and stays visible in statement/usage views.
    static func formatMicroAsCreditsValue(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNegative = trimmed.hasPrefix("-")
        let unsigned = String(trimmed.drop { $0 == "-" || $0 == "+" })
        guard let micro = Int64(unsigned), micro != 0 else { return "0" }

        let sign = isNegative ? "-" : ""
        let credits = micro / microPerCredit
        if credits == 0 {
            return "\(sign)<1"
        }
        return "\(sign)\(groupedThousands(credits))"
    }

    /// Compact balance for tight chrome like the composer chip: full grouped
    /// number below 10,000 credits, then abbreviated ("212.1K credits",
    /// "1.25M credits") so large balances never truncate. Sub-credit residue
    /// is dropped.
    static func formatMicroAsCreditsCompact(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNegative = trimmed.hasPrefix("-")
        let unsigned = String(trimmed.drop { $0 == "-" || $0 == "+" })
        guard let micro = Int64(unsigned), micro != 0 else { return "0 credits" }

        let sign = isNegative ? "-" : ""
        let credits = micro / microPerCredit
        if credits == 0 {
            return "\(sign)<1 credit"
        }
        if credits < 10_000 {
            let unit = credits == 1 ? "credit" : "credits"
            return "\(sign)\(groupedThousands(credits)) \(unit)"
        }
        // 999,950+ rounds past "999.9K", so promote straight to the M tier
        // instead of rendering "1000.0K".
        let useMillions = credits >= 999_950
        let scaled = useMillions ? Double(credits) / 1_000_000 : Double(credits) / 1_000
        let suffix = useMillions ? "M" : "K"
        var figure = String(format: useMillions ? "%.2f" : "%.1f", scaled)
        while figure.contains("."), figure.hasSuffix("0") {
            figure.removeLast()
        }
        if figure.hasSuffix(".") {
            figure.removeLast()
        }
        return "\(sign)\(figure)\(suffix) credits"
    }

    /// Credits formatting for values the app only holds as a USD `Double`
    /// (cloud media quotes/settled costs). Converts to micro-USD and defers
    /// to `formatMicroAsCredits`.
    static func formatUSDAsCredits(_ usd: Double) -> String {
        guard usd.isFinite else { return "0 credits" }
        let micro = (usd * 1_000_000).rounded()
        guard micro.magnitude < Double(Int64.max) else { return "0 credits" }
        return formatMicroAsCredits(String(Int64(micro)))
    }

    /// Locale-independent thousands grouping (`72500` -> `"72,500"`), matching
    /// the fixed formatting style of `formatMicroUSD`.
    private static func groupedThousands(_ value: Int64) -> String {
        let digits = String(value)
        var grouped: [Character] = []
        for (offset, char) in digits.reversed().enumerated() {
            if offset != 0, offset % 3 == 0 {
                grouped.append(",")
            }
            grouped.append(char)
        }
        return String(grouped.reversed())
    }

    /// True when a chat/stream error string indicates the router rejected the
    /// request for lack of credits (HTTP 402 `INSUFFICIENT_FUNDS`). The
    /// streaming path surfaces the raw server body inside a
    /// `RemoteProviderServiceError.requestFailed("HTTP 402: {json}")` string,
    /// so match the stable server error code rather than a localized message.
    /// A workspace-pool 402 (`WORKSPACE_INSUFFICIENT_FUNDS`) contains this
    /// substring but must NOT trigger the personal top-up flow — there is no
    /// fallback from workspace billing to personal credits — so it is
    /// explicitly excluded.
    static func isInsufficientFundsError(_ message: String) -> Bool {
        message.range(of: "INSUFFICIENT_FUNDS", options: .caseInsensitive) != nil
            && !isWorkspaceInsufficientFundsError(message)
    }

    /// True when a chat/stream error string carries the workspace-pool 402
    /// (`WORKSPACE_INSUFFICIENT_FUNDS`, or the pre-rename `TEAM_…`): the
    /// shared pool is dry. Surface "workspace is out of credits", never a
    /// personal top-up prompt.
    static func isWorkspaceInsufficientFundsError(_ message: String) -> Bool {
        OsaurusRouterWorkspaceErrorCode.insufficientFunds.appears(in: message)
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
    case firstActionPending
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
        case .firstActionPending:
            return "Finish choosing your welcome credit before using the router."
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

/// `POST /credits/redeem` result. The Router is authoritative for campaign
/// eligibility and returns the exact plain-text message the UI should show.
struct OsaurusRouterRedeemCodeResponse: Decodable, Equatable, Sendable {
    let redeemed: Bool
    let alreadyRedeemed: Bool
    let campaignKind: String
    let amountMicro: String
    let referralPending: Bool
    let redemptionMessage: String

    enum CodingKeys: String, CodingKey {
        case redeemed
        case alreadyRedeemed = "already_redeemed"
        case campaignKind = "campaign_kind"
        case amountMicro = "amount_micro"
        case referralPending = "referral_pending"
        case redemptionMessage = "redemption_message"
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
    /// Ready-to-show credits pricing strings (e.g. "28.8 credits/M") shipped
    /// alongside the legacy `$` display fields. Optional so older router
    /// deployments without the credits siblings still decode.
    let inputCreditsDisplay: String?
    let outputCreditsDisplay: String?
    let stale: Bool
    let capabilities: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case id, provider, capabilities, stale
        case contextLength = "context_length"
        case inputMicroPerMTok = "input_micro_per_mtok"
        case outputMicroPerMTok = "output_micro_per_mtok"
        case inputDisplay = "input_display"
        case outputDisplay = "output_display"
        case inputCreditsDisplay = "input_credits_display"
        case outputCreditsDisplay = "output_credits_display"
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
    /// Who spent from the pool — present only on workspace usage rows
    /// (`GET /workspaces/:id/credits/usage`), which otherwise share the personal
    /// usage shape.
    typealias Actor = OsaurusRouterWorkspacePerson

    let id: String
    let requestId: String?
    let model: String
    let provider: String
    let inputTokens: Int
    let outputTokens: Int
    /// Provider-reported prompt-cache split (router `0046_cache_pricing`).
    /// Both are subsets of `inputTokens` (the TOTAL prompt size); cached
    /// input billed at the discounted rate, writes at the premium rate.
    /// `0` when the upstream reported no cache activity or the row predates
    /// cache-aware billing (older routers omit the fields entirely).
    let cachedInputTokens: Int
    let cacheWriteTokens: Int
    let costMicro: String
    let status: String
    let tokenSource: String
    let createdAt: String
    let actor: Actor?
    /// The attested teammate who invoked the agent (workspace usage rows only;
    /// requires the host to have sent `caller_attestation`). `actor` is
    /// whose instance billed; `caller` is who asked. `nil` when the request
    /// carried no attestation.
    let caller: Actor?

    enum CodingKeys: String, CodingKey {
        case id, model, provider, status, actor, caller
        case requestId = "request_id"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheWriteTokens = "cache_write_tokens"
        case costMicro = "cost_micro"
        case tokenSource = "token_source"
        case createdAt = "created_at"
    }

    init(
        id: String,
        requestId: String?,
        model: String,
        provider: String,
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        costMicro: String,
        status: String,
        tokenSource: String,
        createdAt: String,
        actor: Actor? = nil,
        caller: Actor? = nil
    ) {
        self.id = id
        self.requestId = requestId
        self.model = model
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costMicro = costMicro
        self.status = status
        self.tokenSource = tokenSource
        self.createdAt = createdAt
        self.actor = actor
        self.caller = caller
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        model = try c.decode(String.self, forKey: .model)
        provider = try c.decode(String.self, forKey: .provider)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        // Old-server compatibility: pre-cache routers omit the split.
        cachedInputTokens = max(0, try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0)
        cacheWriteTokens = max(0, try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0)
        costMicro = try c.decode(String.self, forKey: .costMicro)
        status = try c.decode(String.self, forKey: .status)
        tokenSource = try c.decode(String.self, forKey: .tokenSource)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        actor = try c.decodeIfPresent(Actor.self, forKey: .actor)
        caller = try c.decodeIfPresent(Actor.self, forKey: .caller)
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
        /// Provider-reported prompt-cache split; subsets of `inputTokens`.
        /// Absent on pre-cache routers → decoded as `0`.
        let cachedInputTokens: Int
        let cacheWriteTokens: Int
        /// `"workspace:<workspace_id>"` when the turn was charged to a
        /// workspace pool (request carried `workspace_context`); absent for
        /// personal spend. Pre-rename routers emitted `"team:<id>"`.
        let billedTo: String?

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case costMicro = "cost_micro"
            case status
            case tokenSource = "token_source"
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case cacheWriteTokens = "cache_write_tokens"
            case billedTo = "billed_to"
        }

        init(
            requestId: String?,
            costMicro: String,
            status: String,
            tokenSource: String,
            inputTokens: Int,
            outputTokens: Int,
            cachedInputTokens: Int = 0,
            cacheWriteTokens: Int = 0,
            billedTo: String?
        ) {
            self.requestId = requestId
            self.costMicro = costMicro
            self.status = status
            self.tokenSource = tokenSource
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cachedInputTokens = cachedInputTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.billedTo = billedTo
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
            costMicro = try c.decode(String.self, forKey: .costMicro)
            status = try c.decode(String.self, forKey: .status)
            tokenSource = try c.decode(String.self, forKey: .tokenSource)
            inputTokens = try c.decode(Int.self, forKey: .inputTokens)
            outputTokens = try c.decode(Int.self, forKey: .outputTokens)
            cachedInputTokens = max(0, try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0)
            cacheWriteTokens = max(0, try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0)
            billedTo = try c.decodeIfPresent(String.self, forKey: .billedTo)
        }

        /// The workspace id when this summary billed a workspace pool, nil otherwise.
        var billedWorkspaceId: String? {
            guard let billedTo else { return nil }
            for prefix in ["workspace:", "team:"] where billedTo.hasPrefix(prefix) {
                let id = String(billedTo.dropFirst(prefix.count))
                return id.isEmpty ? nil : id
            }
            return nil
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
    /// Prompt-cache split reported by the upstream provider and billed by the
    /// router at cache rates. Both are subsets of `inputTokens`. `0` = no
    /// cache activity (or a pre-cache router / ledger row).
    public var cachedInputTokens: Int
    public var cacheWriteTokens: Int
    /// `"workspace:<workspace_id>"` for pool spend; nil = personal. Optional so
    /// ledger entries persisted before Workspaces existed keep decoding.
    public var billedTo: String?

    public init(
        requestId: String? = nil,
        costMicro: String,
        status: String,
        tokenSource: String,
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        billedTo: String? = nil
    ) {
        self.requestId = requestId
        self.costMicro = costMicro
        self.status = status
        self.tokenSource = tokenSource
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.billedTo = billedTo
    }

    init(_ summary: OsaurusRouterSummaryEvent.Summary) {
        self.requestId = summary.requestId
        self.costMicro = summary.costMicro
        self.status = summary.status
        self.tokenSource = summary.tokenSource
        self.inputTokens = summary.inputTokens
        self.outputTokens = summary.outputTokens
        self.cachedInputTokens = summary.cachedInputTokens
        self.cacheWriteTokens = summary.cacheWriteTokens
        self.billedTo = summary.billedTo
    }

    enum CodingKeys: String, CodingKey {
        case requestId, costMicro, status, tokenSource, inputTokens, outputTokens
        case cachedInputTokens, cacheWriteTokens, billedTo
    }

    /// Tolerates hints/ledger payloads persisted before the cache split
    /// existed (fields absent → 0).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        costMicro = try c.decode(String.self, forKey: .costMicro)
        status = try c.decode(String.self, forKey: .status)
        tokenSource = try c.decode(String.self, forKey: .tokenSource)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cachedInputTokens = max(0, try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0)
        cacheWriteTokens = max(0, try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0)
        billedTo = try c.decodeIfPresent(String.self, forKey: .billedTo)
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
