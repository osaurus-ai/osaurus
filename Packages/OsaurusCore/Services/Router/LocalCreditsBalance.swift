import Foundation

/// Outcome of a local `GET /credits/balance` lookup, mapped to an HTTP
/// response by `LocalCreditsBalance.response(for:)`.
enum LocalCreditsBalanceResult: Equatable, Sendable {
    case balance(OsaurusRouterBalanceResponse, fetchedAt: Date, stale: Bool)
    case routerDisabled
    case noIdentity
    case unavailable(String)
}

/// Pure policy + serialization for the local read-only credit balance
/// endpoint, kept out of `HTTPHandler` so it stays unit-testable.
enum LocalCreditsBalance {
    /// Same policy as Router credit spend (`ChatEngine
    /// .routerSpendAuthorizationError`): the loopback API is otherwise
    /// unauthenticated, so without this any local process could read the
    /// account balance. Requires a verified access key unless the user opted
    /// in to key-less loopback Router access.
    static func isAuthorized(callerHasVerifiedAccessKey: Bool, allowsUnkeyedLoopbackSpend: Bool) -> Bool {
        callerHasVerifiedAccessKey || allowsUnkeyedLoopbackSpend
    }

    static let unauthorizedMessage =
        "The credit balance is account data. Include a valid Osaurus access key (Authorization: Bearer <key>), or enable 'Allow local API access without a key' for the Router in Osaurus Credits settings."

    /// Machine-readable credits ("1234.56") from a micro-USD string; nil when
    /// the router value does not parse.
    static func creditsDecimalString(fromMicro rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let micro = Int64(trimmed) else { return nil }
        let per = OsaurusRouter.microPerCredit
        let magnitude = micro.magnitude
        let whole = magnitude / UInt64(per)
        let residue = magnitude % UInt64(per)
        let sign = micro < 0 ? "-" : ""
        return "\(sign)\(whole)." + String(format: "%02llu", residue)
    }

    static func response(for result: LocalCreditsBalanceResult) -> (status: Int, json: [String: Any]) {
        switch result {
        case .balance(let balance, let fetchedAt, let stale):
            return (
                200,
                [
                    "balance_micro": balance.balanceMicro,
                    "balance_credits": creditsDecimalString(fromMicro: balance.balanceMicro) ?? NSNull(),
                    "frozen": balance.frozen,
                    "fetched_at": fetchedAt.ISO8601Format(),
                    "stale": stale,
                ]
            )
        case .routerDisabled:
            return (409, error(code: "router_disabled", message: "The Osaurus Router is turned off."))
        case .noIdentity:
            return (409, error(code: "no_account", message: "No Osaurus account is set up on this Mac."))
        case .unavailable(let message):
            return (503, error(code: "router_unavailable", message: message))
        }
    }

    static func error(code: String, message: String) -> [String: Any] {
        ["error": ["code": code, "message": message, "type": "credits_error"]]
    }
}
