import Foundation

/// Outcome of a local `GET /credits/balance` lookup, mapped to an HTTP
/// response by `LocalCreditsBalance.response(for:)`.
enum LocalCreditsBalanceResult: Equatable, Sendable {
    case balance(OsaurusRouterBalanceResponse, fetchedAt: Date, stale: Bool)
    case routerDisabled
    case noIdentity
    /// The Router could not be reached (transport failure / timeout).
    case unavailable(String)
    /// The Router answered but refused or failed the balance request.
    case routerRejected(String)
}

/// Pure policy + serialization for the local read-only credit balance
/// endpoint, kept out of `HTTPHandler` so it stays unit-testable.
enum LocalCreditsBalance {
    /// The loopback API is otherwise unauthenticated, so without this gate any
    /// local process could read the account balance. Stricter than the Router
    /// spend gate (`ChatEngine.routerSpendAuthorizationError`) in two ways:
    ///
    /// - the key must be master-scoped. Agent-scoped and workspace-minted keys
    ///   are handed to other parties and must not read the owner's balance,
    ///   including over loopback where the global scope confinement is skipped.
    /// - the key-less opt-in never applies to a request carrying an `Origin`
    ///   header. Loopback responses are sent with `Access-Control-Allow-Origin:
    ///   *`, so honoring it would let any web page open in the user's browser
    ///   read the balance with a plain `fetch`.
    static func isAuthorized(
        callerHasVerifiedMasterKey: Bool,
        allowsUnkeyedLoopbackSpend: Bool,
        requestHasOrigin: Bool
    ) -> Bool {
        if callerHasVerifiedMasterKey { return true }
        return allowsUnkeyedLoopbackSpend && !requestHasOrigin
    }

    static let unauthorizedMessage =
        "The credit balance is account data. Include a valid master Osaurus access key (Authorization: Bearer <key>), or enable 'Allow local API access without a key' for the Router in Osaurus Credits settings. Browser requests always need a key."

    /// Machine-readable credits ("1234.56") from a micro-USD string; nil when
    /// the router value does not parse.
    static func creditsDecimalString(fromMicro rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let micro = Int64(trimmed) else { return nil }
        let per = UInt64(OsaurusRouter.microPerCredit)
        let magnitude = micro.magnitude
        let sign = micro < 0 ? "-" : ""
        // Residue width follows `microPerCredit` (100 -> 2 digits).
        let width = String(per - 1).count
        let residue = String(magnitude % per)
        let padded = String(repeating: "0", count: max(0, width - residue.count)) + residue
        return "\(sign)\(magnitude / per).\(padded)"
    }

    /// Classify a failed balance refresh: only transport failures mean the
    /// Router is unreachable; everything else is the Router's own answer.
    static func result(forRefreshError error: Error) -> LocalCreditsBalanceResult {
        if case OsaurusRouterAPIError.transport = error {
            return .unavailable(error.localizedDescription)
        }
        return .routerRejected(error.localizedDescription)
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
        case .routerRejected(let message):
            return (502, error(code: "router_error", message: message))
        }
    }

    static func error(code: String, message: String) -> [String: Any] {
        ["error": ["code": code, "message": message, "type": "credits_error"]]
    }
}
