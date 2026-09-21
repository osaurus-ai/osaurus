//
//  LocalCreditsBalanceTests.swift
//  OsaurusCoreTests
//
//  Pure policy + serialization tests for the local `GET /credits/balance`
//  endpoint.
//

import Foundation
import NIOHTTP1
import Testing

@testable import OsaurusCore

struct LocalCreditsBalanceTests {

    @Test func unkeyedCaller_withoutOptIn_isRefused() {
        #expect(
            !LocalCreditsBalance.isAuthorized(
                callerHasVerifiedAccessKey: false,
                allowsUnkeyedLoopbackSpend: false
            )
        )
    }

    @Test func keyedCaller_orOptIn_isAllowed() {
        #expect(
            LocalCreditsBalance.isAuthorized(callerHasVerifiedAccessKey: true, allowsUnkeyedLoopbackSpend: false)
        )
        #expect(
            LocalCreditsBalance.isAuthorized(callerHasVerifiedAccessKey: false, allowsUnkeyedLoopbackSpend: true)
        )
    }

    @Test func creditsDecimalString_keepsSubCreditResidue() {
        #expect(LocalCreditsBalance.creditsDecimalString(fromMicro: "123456") == "1234.56")
        #expect(LocalCreditsBalance.creditsDecimalString(fromMicro: "5") == "0.05")
        #expect(LocalCreditsBalance.creditsDecimalString(fromMicro: "0") == "0.00")
        #expect(LocalCreditsBalance.creditsDecimalString(fromMicro: "-250") == "-2.50")
        #expect(LocalCreditsBalance.creditsDecimalString(fromMicro: "abc") == nil)
    }

    @Test func balanceResult_serializesRouterShapePlusFreshness() {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let response = LocalCreditsBalance.response(
            for: .balance(
                OsaurusRouterBalanceResponse(balanceMicro: "7250000", frozen: false),
                fetchedAt: fetchedAt,
                stale: true
            )
        )
        #expect(response.status == 200)
        #expect(response.json["balance_micro"] as? String == "7250000")
        #expect(response.json["balance_credits"] as? String == "72500.00")
        #expect(response.json["frozen"] as? Bool == false)
        #expect(response.json["stale"] as? Bool == true)
        #expect(response.json["fetched_at"] as? String == fetchedAt.ISO8601Format())
    }

    @Test func failureResults_mapToDistinctStatusesAndCodes() {
        let cases: [(LocalCreditsBalanceResult, Int, String)] = [
            (.routerDisabled, 409, "router_disabled"),
            (.noIdentity, 409, "no_account"),
            (.unavailable("offline"), 503, "router_unavailable"),
        ]
        for (result, status, code) in cases {
            let response = LocalCreditsBalance.response(for: result)
            let error = response.json["error"] as? [String: Any]
            #expect(response.status == status)
            #expect(error?["code"] as? String == code)
        }
    }

    @Test func legacyAgentScopedKey_cannotReachCredits() {
        #expect(!HTTPHandler.legacyAgentScopedKeyMayReach(method: .GET, path: "/credits/balance"))
        #expect(HTTPHandler.legacyAgentScopedKeyMayReach(method: .GET, path: "/models"))
    }

    @Test func workspaceMintedKey_cannotReachCredits() {
        #expect(
            !HTTPHandler.workspaceKeyMayReach(method: .GET, path: "/credits/balance", peerInferenceEnabled: true)
        )
    }
}
