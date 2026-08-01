import Foundation
import Testing

@testable import OsaurusCore

@Suite("Redeem code service", .serialized)
@MainActor
struct RedeemCodeServiceTests {
    @MainActor
    private final class Fixture {
        var identityPreparations = 0
        var fixedCreditRefreshes = 0
        var acquisitionSettlements = 0
        var acquisitionGateBlocking = false
        /// Ordered trace of the side effects a submission performed.
        var events: [String] = []
        var now = Date(timeIntervalSince1970: 1_800_000_000)

        func makeService(context: RedeemCodeService.Context = .credits) -> RedeemCodeService {
            RedeemCodeService(
                context: context,
                client: Self.makeClient(),
                ensureIdentity: { [weak self] in
                    self?.identityPreparations += 1
                    self?.events.append("identity")
                },
                refreshFixedCredit: { [weak self] in
                    self?.fixedCreditRefreshes += 1
                    self?.events.append("refresh")
                },
                onAcquisitionRedemption: { [weak self] in
                    self?.acquisitionSettlements += 1
                    self?.events.append("settle")
                },
                acquisitionGateBlocking: { [weak self] in
                    self?.acquisitionGateBlocking ?? false
                },
                now: { [weak self] in self?.now ?? .distantPast },
                sleep: { _ in }
            )
        }

        func cleanup() {
            RedeemURLProtocol.handler = nil
            RedeemURLProtocol.requestCount = 0
        }

        private static func makeClient() -> OsaurusRouterAPIClient {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RedeemURLProtocol.self]
            return OsaurusRouterAPIClient(
                baseURL: URL(string: "https://router.test")!,
                session: URLSession(configuration: config),
                authOverride: { request, _ in
                    request.setValue("0xabc", forHTTPHeaderField: "x-wallet-address")
                }
            )
        }
    }

    private func respond(
        _ body: String,
        status: Int = 200,
        headers: [String: String] = [:]
    ) {
        let allHeaders = headers.merging(["content-type": "application/json"]) { _, new in new }
        RedeemURLProtocol.handler = { request in
            #expect(request.url?.path == "/credits/redeem")
            return (status, Data(body.utf8), allHeaders)
        }
    }

    @Test func fixedCreditTrimsCodeRefreshesAccountAndCompletesOnboarding() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        respond(
            """
            {"redeemed":true,"already_redeemed":false,"campaign_kind":"first_time","amount_micro":"5000000","referral_pending":false,"redemption_message":"Welcome."}
            """
        )
        let service = fixture.makeService(context: .onboarding)
        service.code = "  LAUNCH25 \n"

        await service.submit()

        #expect(service.code == "LAUNCH25")
        #expect(fixture.identityPreparations == 1)
        #expect(fixture.acquisitionSettlements == 1)
        #expect(fixture.fixedCreditRefreshes == 1)
        guard case .success(let response) = service.state else {
            Issue.record("Expected successful redemption")
            return
        }
        #expect(response.campaignKind == "first_time")
    }

    @Test func referralDoesNotRefreshBalanceAndShowsPendingResult() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        respond(
            """
            {"redeemed":true,"already_redeemed":false,"campaign_kind":"referral","amount_micro":"0","referral_pending":true,"redemption_message":"Referral linked."}
            """
        )
        let service = fixture.makeService()
        service.code = "OSA-TEST"

        await service.submit()

        #expect(fixture.fixedCreditRefreshes == 0)
        guard case .success(let response) = service.state else {
            Issue.record("Expected referral success")
            return
        }
        #expect(response.referralPending)
    }

    @Test func creditsRedemptionWhileGatePendingSettlesAcquisitionBeforeRefresh() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        // Onboarding finished offline: the welcome claim never completed, so
        // the first-action gate still blocks general signed traffic.
        fixture.acquisitionGateBlocking = true
        respond(
            """
            {"redeemed":true,"already_redeemed":false,"campaign_kind":"first_time","amount_micro":"5000000","referral_pending":false,"redemption_message":"Welcome."}
            """
        )
        let service = fixture.makeService(context: .credits)
        service.code = "LATECODE"

        await service.submit()

        guard case .success = service.state else {
            Issue.record("Expected successful redemption")
            return
        }
        #expect(fixture.acquisitionSettlements == 1)
        // The gate must open before the balance refresh, which is the next
        // signed Router request — otherwise it fails with firstActionPending.
        #expect(fixture.events == ["identity", "settle", "refresh"])
    }

    @Test func creditsRedemptionAfterGateResolvedLeavesWelcomeStateUntouched() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        respond(
            """
            {"redeemed":true,"already_redeemed":false,"campaign_kind":"ongoing","amount_micro":"1000000","referral_pending":false,"redemption_message":"Applied."}
            """
        )
        let service = fixture.makeService(context: .credits)
        service.code = "ONGOING"

        await service.submit()

        guard case .success = service.state else {
            Issue.record("Expected successful redemption")
            return
        }
        // An existing install redeeming an ongoing code must not disturb the
        // historical welcome-claim behavior.
        #expect(fixture.acquisitionSettlements == 0)
        #expect(fixture.fixedCreditRefreshes == 1)
    }

    @Test func forbiddenUsesNeutralMessageAndPreservesCode() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        respond(
            #"{"error":{"code":"FORBIDDEN","message":"campaign expired and account is ineligible"}}"#,
            status: 403
        )
        let service = fixture.makeService()
        service.code = "SECRET-CODE"

        await service.submit()

        #expect(service.code == "SECRET-CODE")
        guard case .failure(let message) = service.state else {
            Issue.record("Expected forbidden failure")
            return
        }
        #expect(message == "This code isn’t available for this account.")
        #expect(!message.contains("expired"))
        #expect(fixture.fixedCreditRefreshes == 0)
    }

    @Test func rateLimitHonorsRetryAfterAndDisablesSubmission() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        respond(
            #"{"error":{"code":"RATE_LIMITED","message":"slow down"}}"#,
            status: 429,
            headers: ["retry-after": "120"]
        )
        let service = fixture.makeService()
        service.code = "WAIT"

        await service.submit()

        #expect(service.retryNotBefore == fixture.now.addingTimeInterval(120))
        #expect(!service.canSubmit)
        #expect(RedeemURLProtocol.requestCount == 1)

        fixture.now = fixture.now.addingTimeInterval(121)
        #expect(service.canSubmit)
    }

    @Test func successMessageIsClampedAndIdempotentRetryIsSuccess() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let longMessage = String(repeating: "x", count: 700)
        respond(
            """
            {"redeemed":true,"already_redeemed":true,"campaign_kind":"ongoing","amount_micro":"1000000","referral_pending":false,"redemption_message":"\(longMessage)"}
            """
        )
        let service = fixture.makeService()
        service.code = "AGAIN"

        await service.submit()

        guard case .success(let response) = service.state else {
            Issue.record("Expected idempotent success")
            return
        }
        #expect(response.alreadyRedeemed)
        #expect(response.redemptionMessage.count == 500)
        #expect(fixture.fixedCreditRefreshes == 1)
    }

    @Test func transportFailureKeepsExactCodeForManualRetry() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        RedeemURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let service = fixture.makeService()
        service.code = "RETRY-ME"

        await service.submit()

        #expect(service.code == "RETRY-ME")
        guard case .failure = service.state else {
            Issue.record("Expected retryable failure")
            return
        }

        respond(
            """
            {"redeemed":true,"already_redeemed":false,"campaign_kind":"ongoing","amount_micro":"1000000","referral_pending":false,"redemption_message":"Applied."}
            """
        )
        await service.submit()
        guard case .success = service.state else {
            Issue.record("Expected retry success")
            return
        }
        #expect(RedeemURLProtocol.requestCount == 2)
    }
}

private final class RedeemURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler:
        (@Sendable (URLRequest) throws -> (Int, Data, [String: String]))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
