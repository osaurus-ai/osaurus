import Foundation

//  Wire types for the router's Osaurus Workspaces API (`/workspaces/*`). A workspace is an
//  owner's group whose members join through invite links and share relay
//  agents. There is one plan: every workspace is paid per workspace (monthly
//  or yearly) on the owner's single Stripe subscription — an owner's first
//  subscription starts with a trial — and spends from a shared monthly credit
//  pool. A workspace whose owner subscription (or admin comp) lapsed is
//  `suspended` until the owner reactivates it. Identity is the wallet; the
//  router's optional `dino_id` decoration is not consumed here. Money is
//  micro-USD strings exactly like the personal `/credits/*` API. Loosely
//  specified/expandable response fields decode as optionals so newer router
//  deployments never break older clients.

// MARK: - Roles

enum OsaurusRouterWorkspaceRole: String, Codable, Equatable, Sendable {
    case owner
    case admin
    case member
    /// View + consume shared agents only; cannot share their own (and so can
    /// never bill the pool through their own instance).
    case viewer

    var displayName: String {
        switch self {
        case .owner: return L("Owner")
        case .admin: return L("Admin")
        case .member: return L("Member")
        case .viewer: return L("Viewer")
        }
    }

    /// Whether this role may contribute its own shared agents.
    var canShareAgents: Bool {
        switch self {
        case .owner, .admin, .member: return true
        case .viewer: return false
        }
    }
}

// MARK: - Billing source / entitlement

/// What is paying for a workspace right now (`source` on list rows and
/// `entitlement.source` on the detail).
enum OsaurusRouterWorkspaceBillingSource: String, Codable, Equatable, Sendable {
    /// On the owner's Stripe subscription (trialing counts as active).
    case subscription
    /// An admin comp code: N months without Stripe, then suspended.
    case comp
    /// Owner subscription canceled or comp expired; members, agents, and
    /// history are kept but nothing is entitled until the owner reactivates.
    case suspended
}

/// What a workspace can do right now (`entitlement` on the detail DTO).
/// `seats` / `maxSharedAgents` are `nil` when the plan lever is unlimited.
struct OsaurusRouterWorkspaceEntitlement: Decodable, Equatable, Sendable {
    let active: Bool
    /// `subscription` / `comp` / `suspended` (raw so an unknown future source
    /// still decodes; see `typedSource`).
    let source: String?
    let compExpiresAt: String?
    let nextGrantAt: String?
    let seats: Int?
    let maxSharedAgents: Int?
    let monthlyCreditMicro: String?
    let monthlyCredits: String?

    enum CodingKeys: String, CodingKey {
        case active, source, seats
        case compExpiresAt = "comp_expires_at"
        case nextGrantAt = "next_grant_at"
        case maxSharedAgents = "max_shared_agents"
        case monthlyCreditMicro = "monthly_credit_micro"
        case monthlyCredits = "monthly_credits"
    }

    var typedSource: OsaurusRouterWorkspaceBillingSource? {
        source.flatMap(OsaurusRouterWorkspaceBillingSource.init(rawValue:))
    }
    var isSuspended: Bool { typedSource == .suspended }
    var isComp: Bool { typedSource == .comp }
    var isSubscriptionBacked: Bool { typedSource == .subscription }
}

// MARK: - Workspace lifecycle

/// One row from `GET /workspaces` — every workspace the caller is an active member of.
struct OsaurusRouterWorkspaceSummary: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let role: String
    /// `subscription` / `comp` / `suspended`.
    let source: String?
    /// Mirrors the owner's subscription (or the comp's expiry). An inactive
    /// workspace is still listed but cannot invite, share, or bill the pool.
    let active: Bool?
    let membersActive: Int?
    let agentsShared: Int?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, role, source, active
        case membersActive = "members_active"
        case agentsShared = "agents_shared"
        case createdAt = "created_at"
    }

    init(
        id: String,
        name: String,
        role: String,
        source: String? = nil,
        active: Bool? = nil,
        membersActive: Int? = nil,
        agentsShared: Int? = nil,
        createdAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.source = source
        self.active = active
        self.membersActive = membersActive
        self.agentsShared = agentsShared
        self.createdAt = createdAt
    }

    var typedRole: OsaurusRouterWorkspaceRole? { OsaurusRouterWorkspaceRole(rawValue: role) }
    var typedSource: OsaurusRouterWorkspaceBillingSource? {
        source.flatMap(OsaurusRouterWorkspaceBillingSource.init(rawValue:))
    }
    var isSuspended: Bool { typedSource == .suspended }

    /// Whether the workspace can invite, share, and bill right now. A row
    /// without `active` is treated as inactive — that is what the router
    /// would enforce, and it never unlocks affordances by accident.
    var isActive: Bool { active ?? false }
}

/// Shared sanity bounds for opaque router codes (activation + invite):
/// printable URL-safe characters and a length that rules out garbage/pasted
/// JSON without assuming a format. Router codes are `uuid.32hex`.
enum OsaurusRouterWorkspaceCode {
    static let lengthRange = 6...128
    nonisolated static func isPlausible(_ raw: String) -> Bool {
        guard lengthRange.contains(raw.count) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return raw.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// A subscription activation handed to the app by the osaurus.ai web app
/// (`osaurus://workspaces/activate?code=…`) or an admin comp. The purchase
/// happened before the buyer had a wallet; redeeming the code here creates the
/// workspace owned by the activating wallet and binds the parked subscription
/// to it. Held in memory until the gates (router on, identity) clear and the
/// user confirms.
struct PendingWorkspaceActivation: Equatable, Sendable {
    let code: String
    /// Workspace name chosen on the web, if the web collected one.
    let suggestedName: String?
    /// Human label for the confirm sheet (e.g. "Yearly"; display only — the
    /// router derives everything real from the code).
    let planLabel: String?

    nonisolated static func isPlausibleCode(_ raw: String) -> Bool {
        OsaurusRouterWorkspaceCode.isPlausible(raw)
    }
}

/// An invite link opened in the app (`osaurus://workspaces/join?code=…`). Held in
/// memory until the router/identity gates clear and the user taps Join —
/// never redeemed automatically.
struct PendingWorkspaceJoin: Equatable, Sendable {
    let code: String
}

/// A person reference as embedded in owners, inviters, shared-agent owners,
/// and usage actors/callers. The wallet is the identity; `display_name` is
/// router-side decoration that is `null` unless the account set one.
struct OsaurusRouterWorkspacePerson: Decodable, Equatable, Sendable {
    let accountId: String?
    let walletAddress: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case walletAddress = "wallet_address"
        case displayName = "display_name"
    }

    /// Display name → shortened wallet → account id.
    var friendlyName: String {
        OsaurusRouterWorkspacePerson.friendlyName(
            displayName: displayName, walletAddress: walletAddress, accountId: accountId
        )
    }

    static func friendlyName(displayName: String?, walletAddress: String?, accountId: String?)
        -> String
    {
        if let displayName, !displayName.isEmpty { return displayName }
        if let walletAddress, !walletAddress.isEmpty { return shortWallet(walletAddress) }
        return accountId ?? "?"
    }

    /// `0x1234…abcd` for a 0x-prefixed address; anything shorter is returned
    /// as-is.
    static func shortWallet(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }
}

/// `GET /workspaces/:id` detail (also the body of `/workspaces/activate`,
/// `/workspaces/join`, and the `workspace` of a create/upgrade response).
struct OsaurusRouterWorkspaceDetail: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let role: String
    let owner: OsaurusRouterWorkspacePerson?
    /// Top-level mirror of `entitlement.source`.
    let source: String?
    let entitlement: OsaurusRouterWorkspaceEntitlement?
    let membersActive: Int?
    let agentsShared: Int?
    /// `"0"` after a suspension (the remainder expired).
    let balanceMicro: String?
    let balanceCredits: String?
    let poolFrozen: Bool?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, role, owner, source, entitlement
        case membersActive = "members_active"
        case agentsShared = "agents_shared"
        case balanceMicro = "balance_micro"
        case balanceCredits = "balance_credits"
        case poolFrozen = "pool_frozen"
        case createdAt = "created_at"
    }

    var typedRole: OsaurusRouterWorkspaceRole? { OsaurusRouterWorkspaceRole(rawValue: role) }
    var typedSource: OsaurusRouterWorkspaceBillingSource? {
        (entitlement?.source ?? source).flatMap(OsaurusRouterWorkspaceBillingSource.init(rawValue:))
    }
    var isSuspended: Bool { typedSource == .suspended }

    /// Whether invites, shares, and workspace-billed inference work right now.
    /// A detail without an entitlement is treated as inactive.
    var isActive: Bool { entitlement?.active ?? false }

    /// Summary row shape for callers that need to drive the list UI from a
    /// freshly created/joined detail before the list has refreshed.
    var asSummary: OsaurusRouterWorkspaceSummary {
        OsaurusRouterWorkspaceSummary(
            id: id,
            name: name,
            role: role,
            source: entitlement?.source ?? source,
            active: entitlement?.active,
            membersActive: membersActive,
            agentsShared: agentsShared,
            createdAt: createdAt
        )
    }
}

/// `POST /workspaces` / `POST /workspaces/:id/upgrade` response. Three shapes
/// share one envelope: the workspace was created/reactivated on the owner's
/// live subscription, or a Stripe Checkout must be completed first (the
/// webhook then creates/reactivates it — the redirect grants nothing).
struct OsaurusRouterWorkspaceCreateResponse: Decodable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// `201 created` / `200 upgraded`: live now.
        case ready(OsaurusRouterWorkspaceDetail)
        /// `200 checkout_required`: open `checkoutURL`, then poll until the
        /// workspace appears/turns active.
        case checkoutRequired(activationId: String, checkoutURL: URL)
    }

    let status: String
    let workspace: OsaurusRouterWorkspaceDetail?
    let activationId: String?
    let checkoutURL: String?

    enum CodingKeys: String, CodingKey {
        case status, workspace
        case activationId = "activation_id"
        case checkoutURL = "checkout_url"
    }

    /// nil when the envelope is internally inconsistent (unknown status, or
    /// a status whose companion fields are missing) — callers treat that as
    /// `OsaurusRouterAPIError.invalidResponse`.
    var outcome: Outcome? {
        switch status {
        case "created", "upgraded":
            return workspace.map(Outcome.ready)
        case "checkout_required":
            guard let activationId, let raw = checkoutURL, let url = URL(string: raw),
                url.scheme?.lowercased() == "https"
            else { return nil }
            return .checkoutRequired(activationId: activationId, checkoutURL: url)
        default:
            return nil
        }
    }
}

// MARK: - Plan, prices, and billing (account level)

/// One price point (`GET /workspaces/prices` / `GET /workspaces/billing`):
/// the live per-workspace price for one billing interval.
struct OsaurusRouterWorkspacePrice: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    /// `month` / `year`.
    let billingInterval: String?
    let priceUSDMicro: String?
    let priceUSD: String?
    let active: Bool?

    enum CodingKeys: String, CodingKey {
        case id, active
        case billingInterval = "billing_interval"
        case priceUSDMicro = "price_usd_micro"
        case priceUSD = "price_usd"
    }

    var isMonthly: Bool { billingInterval == "month" }
    var isYearly: Bool { billingInterval == "year" }

    /// "$20" / "$19.50" from the micro-USD amount (router `price_usd` as a
    /// fallback); nil when the router sent neither.
    var amountLabel: String? {
        if let priceUSDMicro, let micro = Int64(priceUSDMicro.trimmingCharacters(in: .whitespaces)) {
            return Self.formatUSD(micro: micro)
        }
        if let priceUSD, !priceUSD.isEmpty { return "$\(priceUSD)" }
        return nil
    }

    /// "$20/month" / "$200/year"; nil when the router sent no amount.
    var displayLabel: String? {
        guard let amount = amountLabel else { return nil }
        switch billingInterval {
        case "month": return String(format: L("%@/month"), amount)
        case "year": return String(format: L("%@/year"), amount)
        default: return amount
        }
    }

    /// Whole dollars when the amount is round, otherwise two decimals.
    static func formatUSD(micro: Int64) -> String {
        let dollars = micro / 1_000_000
        let cents = (abs(micro) % 1_000_000) / 10_000
        if cents == 0 { return "$\(dollars)" }
        return String(format: "$%lld.%02lld", dollars, cents)
    }
}

/// The single plan every workspace gets (`plan` in `GET /workspaces/prices`).
/// `seats` / `maxSharedAgents` are `nil` when unlimited (the default).
struct OsaurusRouterWorkspacePlan: Decodable, Equatable, Sendable {
    let seats: Int?
    let maxSharedAgents: Int?
    let monthlyCreditMicro: String?
    let monthlyCredits: String?
    /// Length of the trial on an owner's first subscription; `0` = no trial.
    let trialDays: Int?

    enum CodingKeys: String, CodingKey {
        case seats
        case maxSharedAgents = "max_shared_agents"
        case monthlyCreditMicro = "monthly_credit_micro"
        case monthlyCredits = "monthly_credits"
        case trialDays = "trial_days"
    }

    var hasTrial: Bool { (trialDays ?? 0) > 0 }
}

/// `GET /workspaces/prices` (public, cacheable): pricing-page material.
struct OsaurusRouterWorkspacePricesResponse: Decodable, Equatable, Sendable {
    let plan: OsaurusRouterWorkspacePlan?
    let prices: [OsaurusRouterWorkspacePrice]

    /// Live prices only, monthly first.
    var livePrices: [OsaurusRouterWorkspacePrice] {
        prices.filter { $0.active ?? true }
            .sorted { a, b in (a.isMonthly ? 0 : 1) < (b.isMonthly ? 0 : 1) }
    }
    var monthly: OsaurusRouterWorkspacePrice? { livePrices.first(where: \.isMonthly) }
    var yearly: OsaurusRouterWorkspacePrice? { livePrices.first(where: \.isYearly) }
}

/// `GET /workspaces/billing` — the caller's ONE owner subscription (covering
/// every workspace they own) plus counts and trial eligibility. Account-level,
/// not per workspace.
struct OsaurusRouterWorkspaceBillingSummary: Decodable, Equatable, Sendable {
    struct Subscription: Decodable, Equatable, Sendable {
        /// `active` (trialing included) / `past_due` / `canceled` / `incomplete`.
        let status: String
        /// Number of subscription-backed workspaces being billed.
        let quantity: Int?
        let price: OsaurusRouterWorkspacePrice?
        let currentPeriodStart: String?
        let currentPeriodEnd: String?
        let cancelAtPeriodEnd: Bool?
        /// Set once Stripe reports a trial; stays set (in the past) after it
        /// converts.
        let trialEndsAt: String?
        /// `true` while `active` and `trialEndsAt` is in the future.
        let trialing: Bool?

        enum CodingKeys: String, CodingKey {
            case status, quantity, price, trialing
            case currentPeriodStart = "current_period_start"
            case currentPeriodEnd = "current_period_end"
            case cancelAtPeriodEnd = "cancel_at_period_end"
            case trialEndsAt = "trial_ends_at"
        }

        var isActive: Bool { status == "active" }
        var isPastDue: Bool { status == "past_due" }
        var isCanceled: Bool { status == "canceled" }
        var isTrialing: Bool { trialing ?? false }
    }

    /// `nil` when the account has never subscribed.
    let subscription: Subscription?
    /// Everything the caller owns, suspended included.
    let workspaces: Int?
    /// What Stripe is charging for.
    let billedWorkspaces: Int?
    /// Whether the next Checkout would carry the trial (never subscribed and
    /// `trialDays > 0`).
    let trialEligible: Bool?
    let trialDays: Int?
    /// Active subscription with a card mirrored from Stripe — the
    /// precondition for enabling pool auto-reload.
    let paymentMethodOnFile: Bool?

    enum CodingKeys: String, CodingKey {
        case subscription, workspaces
        case billedWorkspaces = "billed_workspaces"
        case trialEligible = "trial_eligible"
        case trialDays = "trial_days"
        case paymentMethodOnFile = "payment_method_on_file"
    }

    /// Whether `POST /workspaces` would add to a live subscription without a
    /// Checkout (subscribed and current).
    var hasLiveSubscription: Bool { subscription?.isActive ?? false }
    var isTrialing: Bool { subscription?.isTrialing ?? false }
    var trialEndsAt: String? { subscription?.trialEndsAt }
}

/// `POST /workspaces/billing/portal` → Stripe Billing Portal URL for the
/// caller's owner subscription. Changes made there land via webhook, so
/// clients poll the workspace entitlement after returning.
struct OsaurusRouterWorkspacePortalResponse: Decodable, Equatable, Sendable {
    let portalURL: String

    enum CodingKeys: String, CodingKey {
        case portalURL = "portal_url"
    }
}

// MARK: - Pool credits (top-ups and auto-reload)

/// `GET /workspaces/:id/credits/balance`. The pool is one ledger account made
/// of two kinds of credit: this cycle's unspent **grant** (`expiring_micro`,
/// gone at `next_grant_at`) and **purchased** credit (`purchased_micro`:
/// top-ups and auto-reloads, never expired by a reset or a suspension). Spend
/// is attributed to the grant first.
struct OsaurusRouterWorkspacePoolBalance: Decodable, Equatable, Sendable {
    struct AutoReloadState: Decodable, Equatable, Sendable {
        let enabled: Bool
        /// `true` after three consecutive declines or a chargeback; `enabled`
        /// stays `true` so the UI can say "paused — fix your card".
        let paused: Bool
    }

    let balanceMicro: String
    let balanceCredits: String?
    let expiringMicro: String?
    let expiringCredits: String?
    let purchasedMicro: String?
    let purchasedCredits: String?
    let autoReload: AutoReloadState?
    let frozen: Bool

    enum CodingKeys: String, CodingKey {
        case frozen
        case balanceMicro = "balance_micro"
        case balanceCredits = "balance_credits"
        case expiringMicro = "expiring_micro"
        case expiringCredits = "expiring_credits"
        case purchasedMicro = "purchased_micro"
        case purchasedCredits = "purchased_credits"
        case autoReload = "auto_reload"
    }

    init(
        balanceMicro: String,
        balanceCredits: String? = nil,
        expiringMicro: String? = nil,
        expiringCredits: String? = nil,
        purchasedMicro: String? = nil,
        purchasedCredits: String? = nil,
        autoReload: AutoReloadState? = nil,
        frozen: Bool = false
    ) {
        self.balanceMicro = balanceMicro
        self.balanceCredits = balanceCredits
        self.expiringMicro = expiringMicro
        self.expiringCredits = expiringCredits
        self.purchasedMicro = purchasedMicro
        self.purchasedCredits = purchasedCredits
        self.autoReload = autoReload
        self.frozen = frozen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        balanceMicro = try c.decode(String.self, forKey: .balanceMicro)
        balanceCredits = try c.decodeIfPresent(String.self, forKey: .balanceCredits)
        expiringMicro = try c.decodeIfPresent(String.self, forKey: .expiringMicro)
        expiringCredits = try c.decodeIfPresent(String.self, forKey: .expiringCredits)
        purchasedMicro = try c.decodeIfPresent(String.self, forKey: .purchasedMicro)
        purchasedCredits = try c.decodeIfPresent(String.self, forKey: .purchasedCredits)
        autoReload = try c.decodeIfPresent(AutoReloadState.self, forKey: .autoReload)
        // Older routers only ship `balance_micro` + `frozen`.
        frozen = try c.decodeIfPresent(Bool.self, forKey: .frozen) ?? false
    }

    /// Whether the router split the balance (a pre-0041 router sends only
    /// the total, and the breakdown line should stay hidden).
    var hasBreakdown: Bool { expiringMicro != nil && purchasedMicro != nil }
    var purchasedIsPositive: Bool { (Int64(purchasedMicro ?? "0") ?? 0) > 0 }
}

/// Client-side money rules for pool purchases. The router enforces bounds
/// only ($5–$500 top-up; threshold $1–$500; whole cents); presets live here,
/// as the router doc says they should.
enum OsaurusRouterWorkspacePoolCredits {
    static let microPerDollar: Int64 = 1_000_000
    static let microPerCent: Int64 = 10_000

    /// One-time top-up bounds (`POST /workspaces/:id/credits/checkout`).
    static let minTopUpMicro: Int64 = 5_000_000
    static let maxTopUpMicro: Int64 = 500_000_000
    /// Top-up presets, in micro-USD ($20 / $50 / $100).
    static let topUpPresetsMicro: [Int64] = [20_000_000, 50_000_000, 100_000_000]

    /// Auto-reload bounds (`PUT /workspaces/:id/credits/auto-reload`), used
    /// until the router's own `bounds` have loaded.
    static let minThresholdMicro: Int64 = 1_000_000
    static let maxThresholdMicro: Int64 = 500_000_000
    static let minReloadMicro: Int64 = 5_000_000
    static let maxReloadMicro: Int64 = 500_000_000
    /// Auto-reload presets: fire below $5 / $10 / $20; reload $20 / $50 / $100;
    /// default monthly cap $200 (`nil` = no cap).
    static let thresholdPresetsMicro: [Int64] = [5_000_000, 10_000_000, 20_000_000]
    static let reloadPresetsMicro: [Int64] = [20_000_000, 50_000_000, 100_000_000]
    static let defaultThresholdMicro: Int64 = 5_000_000
    static let defaultReloadMicro: Int64 = 20_000_000
    static let defaultMonthlyCapMicro: Int64 = 200_000_000

    /// Parses a typed dollar amount ("25", "$25", "12.50") into micro-USD;
    /// nil when empty, non-numeric, or not positive.
    static func micro(fromDollars text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.hasPrefix("$") ? String(trimmed.dropFirst()) : trimmed
        guard let dollars = Double(cleaned), dollars.isFinite, dollars > 0 else { return nil }
        return Int64((dollars * Double(microPerDollar)).rounded())
    }

    /// "20" / "12.5" — the dollars for a text field (no `$`).
    static func dollarsText(micro: Int64) -> String {
        if micro % microPerDollar == 0 { return String(micro / microPerDollar) }
        return String(format: "%.2f", Double(micro) / Double(microPerDollar))
    }

    static func isWholeCents(_ micro: Int64) -> Bool { micro % microPerCent == 0 }

    enum TopUpValidation: Equatable { case ok, belowMinimum, aboveMaximum, notWholeCents }

    static func validateTopUp(micro: Int64) -> TopUpValidation {
        if micro < minTopUpMicro { return .belowMinimum }
        if micro > maxTopUpMicro { return .aboveMaximum }
        if !isWholeCents(micro) { return .notWholeCents }
        return .ok
    }

    enum AutoReloadValidation: Equatable {
        case ok
        case thresholdOutOfBounds
        case amountOutOfBounds
        case capBelowAmount
        case notWholeCents
    }

    static func validateAutoReload(
        thresholdMicro: Int64,
        amountMicro: Int64,
        monthlyCapMicro: Int64?,
        bounds: OsaurusRouterWorkspaceAutoReload.Bounds? = nil
    ) -> AutoReloadValidation {
        let minT = bounds?.minThreshold ?? minThresholdMicro
        let maxT = bounds?.maxThreshold ?? maxThresholdMicro
        let minA = bounds?.minAmount ?? minReloadMicro
        let maxA = bounds?.maxAmount ?? maxReloadMicro
        if thresholdMicro < minT || thresholdMicro > maxT { return .thresholdOutOfBounds }
        if amountMicro < minA || amountMicro > maxA { return .amountOutOfBounds }
        if let cap = monthlyCapMicro, cap < amountMicro { return .capBelowAmount }
        if !isWholeCents(thresholdMicro) || !isWholeCents(amountMicro)
            || !(monthlyCapMicro.map(isWholeCents) ?? true)
        {
            return .notWholeCents
        }
        return .ok
    }
}

/// `POST /workspaces/:id/credits/checkout` → a one-time Stripe Checkout for
/// the pool. Nothing is credited by the redirect; the webhook posts a
/// `workspace_topup` ledger entry keyed on `topup_id`.
struct OsaurusRouterWorkspaceTopUpCheckoutResponse: Decodable, Equatable, Sendable {
    let topupId: String
    let checkoutURL: String
    let creditMicro: String?
    let credits: String?
    /// Equals `credit_micro`: pool top-ups carry no fee.
    let totalMicro: String?

    enum CodingKeys: String, CodingKey {
        case credits
        case topupId = "topup_id"
        case checkoutURL = "checkout_url"
        case creditMicro = "credit_micro"
        case totalMicro = "total_micro"
    }
}

/// `GET`/`PUT /workspaces/:id/credits/auto-reload`. Owner-only to write; any
/// member may read. `enabled` stays `true` while `paused`.
struct OsaurusRouterWorkspaceAutoReload: Decodable, Equatable, Sendable {
    struct Bounds: Decodable, Equatable, Sendable {
        let minThresholdMicro: String?
        let maxThresholdMicro: String?
        let minAmountMicro: String?
        let maxAmountMicro: String?

        enum CodingKeys: String, CodingKey {
            case minThresholdMicro = "min_threshold_micro"
            case maxThresholdMicro = "max_threshold_micro"
            case minAmountMicro = "min_amount_micro"
            case maxAmountMicro = "max_amount_micro"
        }

        var minThreshold: Int64? { minThresholdMicro.flatMap(Int64.init) }
        var maxThreshold: Int64? { maxThresholdMicro.flatMap(Int64.init) }
        var minAmount: Int64? { minAmountMicro.flatMap(Int64.init) }
        var maxAmount: Int64? { maxAmountMicro.flatMap(Int64.init) }
    }

    let enabled: Bool
    let paused: Bool
    let thresholdMicro: String?
    let amountMicro: String?
    /// `nil` = no cap.
    let monthlyCapMicro: String?
    let thresholdCredits: String?
    let amountCredits: String?
    let monthlyCapCredits: String?
    /// Succeeded auto-reload charges this UTC calendar month.
    let monthReloadedMicro: String?
    let consecutiveFailures: Int?
    let lastAttemptAt: String?
    /// Stripe decline code, `"cap_reached"`, or `"chargeback"`.
    let lastError: String?
    let paymentMethodOnFile: Bool?
    let bounds: Bounds?

    enum CodingKeys: String, CodingKey {
        case enabled, paused, bounds
        case thresholdMicro = "threshold_micro"
        case amountMicro = "amount_micro"
        case monthlyCapMicro = "monthly_cap_micro"
        case thresholdCredits = "threshold_credits"
        case amountCredits = "amount_credits"
        case monthlyCapCredits = "monthly_cap_credits"
        case monthReloadedMicro = "month_reloaded_micro"
        case consecutiveFailures = "consecutive_failures"
        case lastAttemptAt = "last_attempt_at"
        case lastError = "last_error"
        case paymentMethodOnFile = "payment_method_on_file"
    }

    var threshold: Int64? { thresholdMicro.flatMap(Int64.init) }
    var amount: Int64? { amountMicro.flatMap(Int64.init) }
    var monthlyCap: Int64? { monthlyCapMicro.flatMap(Int64.init) }
    var monthReloaded: Int64 { monthReloadedMicro.flatMap(Int64.init) ?? 0 }
    /// Skipped this month because the cap is reached (clears at month roll-over).
    var isCapReached: Bool { lastError == "cap_reached" }
    var isChargebackPaused: Bool { paused && lastError == "chargeback" }
}

/// Body of `PUT /workspaces/:id/credits/auto-reload`. `monthly_cap_micro` is
/// always sent — `null` means "no cap" and must not be omitted.
struct OsaurusRouterWorkspaceAutoReloadUpdate: Encodable, Equatable, Sendable {
    let enabled: Bool
    let thresholdMicro: Int64
    let amountMicro: Int64
    let monthlyCapMicro: Int64?

    enum CodingKeys: String, CodingKey {
        case enabled
        case thresholdMicro = "threshold_micro"
        case amountMicro = "amount_micro"
        case monthlyCapMicro = "monthly_cap_micro"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(String(thresholdMicro), forKey: .thresholdMicro)
        try c.encode(String(amountMicro), forKey: .amountMicro)
        if let monthlyCapMicro {
            try c.encode(String(monthlyCapMicro), forKey: .monthlyCapMicro)
        } else {
            try c.encodeNil(forKey: .monthlyCapMicro)
        }
    }
}

// MARK: - Invites

/// One invite link (`POST /workspaces/:id/invites` result and each row of
/// `GET /workspaces/:id/invites`). `code`/`url` are only present while `status`
/// is `pending`; the router re-derives them so a link can be re-copied.
struct OsaurusRouterWorkspaceInvite: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let code: String?
    /// The router-minted deep link, `osaurus://workspaces/join?code=<code>`.
    /// Rendered as-is (never rebuilt from `code`) so web and desktop agree on
    /// the link — except that a link still minted under the pre-rename
    /// `osaurus://teams/` host is rewritten to the current host on decode.
    /// The app accepts both hosts when opening a link.
    let url: String?
    let role: String?
    let status: String?
    let maxUses: Int?
    let uses: Int?
    let invitedBy: OsaurusRouterWorkspacePerson?
    let expiresAt: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, code, url, role, status, uses
        case maxUses = "max_uses"
        case invitedBy = "invited_by"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        url = try c.decodeIfPresent(String.self, forKey: .url)
            .map(WorkspacesDeepLinkRouter.normalized)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        maxUses = try c.decodeIfPresent(Int.self, forKey: .maxUses)
        uses = try c.decodeIfPresent(Int.self, forKey: .uses)
        invitedBy = try c.decodeIfPresent(OsaurusRouterWorkspacePerson.self, forKey: .invitedBy)
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }

    var isPending: Bool { status == nil || status == "pending" }
}

struct OsaurusRouterWorkspaceInviteListResponse: Decodable, Sendable {
    let data: [OsaurusRouterWorkspaceInvite]
}

// MARK: - Members

/// One roster row from `GET /workspaces/:id/members`.
struct OsaurusRouterWorkspaceMember: Decodable, Identifiable, Equatable, Sendable {
    let accountId: String
    let walletAddress: String?
    let displayName: String?
    let role: String
    let agentsShared: Int?
    let joinedAt: String?

    enum CodingKeys: String, CodingKey {
        case role
        case accountId = "account_id"
        case walletAddress = "wallet_address"
        case displayName = "display_name"
        case agentsShared = "agents_shared"
        case joinedAt = "joined_at"
    }

    var id: String { accountId }
    var typedRole: OsaurusRouterWorkspaceRole? { OsaurusRouterWorkspaceRole(rawValue: role) }

    var friendlyName: String {
        OsaurusRouterWorkspacePerson.friendlyName(
            displayName: displayName, walletAddress: walletAddress, accountId: accountId
        )
    }
}

struct OsaurusRouterWorkspaceMemberListResponse: Decodable, Sendable {
    let data: [OsaurusRouterWorkspaceMember]
}

// MARK: - Shared agents

/// `POST /workspaces/:id/agents` body. The proof is an EIP-191 signature by the
/// AGENT key (not the master key) over
/// `osaurus-workspaces:share:<workspace_id>:<agent_address_lowercase>:<unix_timestamp>`.
struct OsaurusRouterWorkspaceShareAgentBody: Encodable, Sendable {
    struct Proof: Encodable, Sendable {
        let timestamp: Int
        let signature: String
    }

    let agent_address: String
    let display_name: String
    let description: String?
    let proof: Proof
}

/// One shared-agent row (share response and `GET /workspaces/:id/agents` roster).
struct OsaurusRouterWorkspaceAgent: Decodable, Identifiable, Equatable, Sendable {
    let agentAddress: String
    let displayName: String?
    let description: String?
    let owner: OsaurusRouterWorkspacePerson?
    let relayURL: String?
    /// Tri-state presence: `nil` means the relay couldn't be reached —
    /// render as "unknown", never as "offline".
    let online: Bool?
    let lastSeen: String?
    let sharedAt: String?

    enum CodingKeys: String, CodingKey {
        case owner, online, description
        case agentAddress = "agent_address"
        case displayName = "display_name"
        case relayURL = "relay_url"
        case lastSeen = "last_seen"
        case sharedAt = "shared_at"
    }

    var id: String { agentAddress }
}

struct OsaurusRouterWorkspaceAgentListResponse: Decodable, Sendable {
    let data: [OsaurusRouterWorkspaceAgent]
}

// MARK: - Workspace error codes

/// Stable server error codes specific to the Workspaces surface, matched from
/// `OsaurusRouterAPIError.server(code:message:status:)`. Deliberately NOT new
/// `OsaurusRouterAPIError` cases: that enum is exhaustively switched by the
/// credits/redeem/welcome services, and workspace verdicts only matter to the
/// Workspaces service and the chat billing path.
enum OsaurusRouterWorkspaceErrorCode: String, Sendable {
    case workspaceNotFound = "WORKSPACE_NOT_FOUND"
    case notAMember = "NOT_A_MEMBER"
    case forbiddenRole = "FORBIDDEN_ROLE"
    case seatsExhausted = "WORKSPACE_SEATS_EXHAUSTED"
    case agentLimit = "WORKSPACE_AGENT_LIMIT"
    case insufficientFunds = "WORKSPACE_INSUFFICIENT_FUNDS"
    case subscriptionInactive = "SUBSCRIPTION_INACTIVE"
    /// `POST /workspaces` while the owner's first subscription is still
    /// trialing and they already have a workspace: the trial covers one.
    /// The router adds `trial_ends_at`; the client reads the same date from
    /// `GET /workspaces/billing`.
    case trialWorkspaceLimit = "TRIAL_WORKSPACE_LIMIT"
    /// `POST /workspaces/join` verdicts (invite links).
    case inviteInvalid = "INVITE_INVALID"
    case inviteUsed = "INVITE_USED"
    case inviteExpired = "INVITE_EXPIRED"
    case invalidAgentProof = "INVALID_AGENT_PROOF"
    /// `POST /workspaces/activate` verdicts (web-purchased subscription codes).
    case activationCodeInvalid = "ACTIVATION_CODE_INVALID"
    case activationCodeUsed = "ACTIVATION_CODE_USED"
    case activationCodeExpired = "ACTIVATION_CODE_EXPIRED"
    /// The redeeming wallet already has a live owner subscription (one per
    /// owner); the code stays redeemable by another wallet.
    case activationConflict = "ACTIVATION_CONFLICT"
    /// `PUT /workspaces/:id/credits/auto-reload` verdicts: threshold / amount /
    /// cap out of bounds or not whole cents; enabling without an active owner
    /// subscription that has a saved card.
    case invalidAutoReloadConfig = "INVALID_AUTO_RELOAD_CONFIG"
    case autoReloadUnavailable = "AUTO_RELOAD_UNAVAILABLE"

    /// Pre-rename spellings the router emitted while the feature was called
    /// "Teams". The router changed these with no alias; accept them anyway so
    /// a client talking to a not-yet-upgraded router keeps its verdicts.
    private static let legacyCodes: [String: OsaurusRouterWorkspaceErrorCode] = [
        "TEAM_NOT_FOUND": .workspaceNotFound,
        "TEAM_SEATS_EXHAUSTED": .seatsExhausted,
        "TEAM_AGENT_LIMIT": .agentLimit,
        "TEAM_INSUFFICIENT_FUNDS": .insufficientFunds,
    ]

    /// Matches a router error code, current or legacy spelling. Prefer this
    /// over `init?(rawValue:)` everywhere a wire code is inspected.
    init?(code: String) {
        if let exact = OsaurusRouterWorkspaceErrorCode(rawValue: code) {
            self = exact
        } else if let legacy = Self.legacyCodes[code] {
            self = legacy
        } else {
            return nil
        }
    }

    /// The matched workspace code when `error` is a router server error carrying
    /// one; nil for non-workspace errors.
    static func match(_ error: OsaurusRouterAPIError) -> OsaurusRouterWorkspaceErrorCode? {
        guard case .server(let code, _, _) = error else { return nil }
        return OsaurusRouterWorkspaceErrorCode(code: code)
    }

    /// True when a raw chat/stream error string carries this code in either
    /// spelling (the streaming path surfaces the server body inside an error
    /// string, so callers match substrings rather than decoded envelopes).
    func appears(in message: String) -> Bool {
        if message.range(of: rawValue, options: .caseInsensitive) != nil { return true }
        return Self.legacyCodes.contains { $0.value == self && message.range(of: $0.key, options: .caseInsensitive) != nil }
    }
}

// MARK: - Workspace context (workspace-billed inference)

/// The `workspace_context` object added to router `/v1/chat/completions`
/// bodies when a shared agent bills its workspace's pool instead of the
/// signer's personal balance. Covered by the request signature.
///
/// Encodes the current wire names only (`workspace_id`); decoding also
/// accepts the pre-rename `team_id` so a persisted/relayed context from an
/// older peer still parses (the router accepts both, preferring the new).
public struct OsaurusRouterWorkspaceContext: Codable, Equatable, Sendable {
    public let workspaceId: String
    public let agentAddress: String
    /// The invoking teammate's current membership attestation, when the host
    /// serves a redeemed workspace session. Attributes pool spend to the teammate
    /// who asked (usage `caller`), while the host stays the signer/actor.
    /// Omitted for the sharer's own turns. Never sent stale: an invalid or
    /// expired value is a router 400/403, not a silent fallback.
    public let callerAttestation: String?

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case legacyWorkspaceId = "team_id"
        case agentAddress = "agent_address"
        case callerAttestation = "caller_attestation"
    }

    public init(workspaceId: String, agentAddress: String, callerAttestation: String? = nil) {
        self.workspaceId = workspaceId
        self.agentAddress = agentAddress
        self.callerAttestation = callerAttestation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .workspaceId) {
            workspaceId = id
        } else {
            workspaceId = try c.decode(String.self, forKey: .legacyWorkspaceId)
        }
        agentAddress = try c.decode(String.self, forKey: .agentAddress)
        callerAttestation = try c.decodeIfPresent(String.self, forKey: .callerAttestation)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workspaceId, forKey: .workspaceId)
        try c.encode(agentAddress, forKey: .agentAddress)
        try c.encodeIfPresent(callerAttestation, forKey: .callerAttestation)
    }
}
