//
//  WelcomeCreditServiceTests.swift
//  osaurusTests
//
//  Pins the client contract for the Router's one-time welcome credit:
//  success (fresh or idempotent retry) settles the flow and refreshes the
//  balance; 403/400 are terminal and hide the offer forever; 429 backs off
//  per `retry-after` without burning attempts; transport failures stay
//  retryable; and no request fires without identity, with the router
//  disabled, without a stable device id, or after a terminal outcome.
//  Also pins the device-id derivation (salted SHA-256, raw UUID never sent).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Welcome credit service", .serialized)
@MainActor
struct WelcomeCreditServiceTests {

    private static let deviceHash = WelcomeCreditDeviceID.derive(platformUUID: "TEST-PLATFORM-UUID")

    // MARK: - Fixture

    /// One test's worth of isolated state: a suite-scoped UserDefaults, a
    /// URLProtocol-mocked API client, and seams pinned to "claimable".
    @MainActor
    private final class Fixture {
        let defaults: UserDefaults
        let suiteName: String
        private(set) var grantedRefreshes = 0
        var identityExists = true
        var routerEnabled = true
        var deviceId: String? = WelcomeCreditServiceTests.deviceHash

        init() {
            suiteName = "welcome-credit-tests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
        }

        func makeService() -> WelcomeCreditService {
            WelcomeCreditService(
                client: Self.makeClient(),
                defaults: defaults,
                identityExists: { [weak self] in self?.identityExists ?? false },
                isRouterEnabled: { [weak self] in self?.routerEnabled ?? false },
                deviceId: { [weak self] in self?.deviceId },
                onGranted: { [weak self] in self?.grantedRefreshes += 1 },
                observesNotifications: false
            )
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            WelcomeURLProtocol.handler = nil
            WelcomeURLProtocol.requestCount = 0
        }

        private static func makeClient() -> OsaurusRouterAPIClient {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [WelcomeURLProtocol.self]
            return OsaurusRouterAPIClient(
                baseURL: URL(string: "https://router.test")!,
                session: URLSession(configuration: config),
                authOverride: { request, _ in
                    request.setValue("0xabc", forHTTPHeaderField: "x-wallet-address")
                }
            )
        }
    }

    private func respond(_ body: String, status: Int = 200, headers: [String: String] = [:]) {
        let allHeaders = headers.merging(["content-type": "application/json"]) { _, new in new }
        WelcomeURLProtocol.handler = { request in
            #expect(request.url?.path == "/credits/welcome/claim")
            return (status, Data(body.utf8), allHeaders)
        }
    }

    // MARK: - Device id derivation

    @Test func deviceId_isSaltedHashNotRawUUID() {
        let derived = WelcomeCreditDeviceID.derive(platformUUID: "TEST-PLATFORM-UUID")
        // 64 lowercase hex chars — inside the server's 8–128 bound.
        #expect(derived.count == 64)
        #expect(derived.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        // The raw hardware UUID must never appear in what crosses the wire.
        #expect(!derived.contains("TEST-PLATFORM-UUID"))
        // Deterministic (stable across restarts/reinstalls)…
        #expect(derived == WelcomeCreditDeviceID.derive(platformUUID: "TEST-PLATFORM-UUID"))
        // …and different machines derive different ids.
        #expect(derived != WelcomeCreditDeviceID.derive(platformUUID: "OTHER-UUID"))
    }

    // MARK: - Success

    @Test func grant_settlesFlowAndRefreshesBalance() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        respond(#"{"granted":true,"already_granted":false,"amount_micro":"2500000"}"#)

        let service = fixture.makeService()
        let settled = await service.claimIfNeeded()

        #expect(settled == true)
        #expect(service.resolution == .granted)
        #expect(fixture.grantedRefreshes == 1)

        // Settled: no further request ever fires.
        let again = await service.claimIfNeeded()
        #expect(again == true)
        #expect(WelcomeURLProtocol.requestCount == 1)
    }

    @Test func alreadyGranted_retryAlsoSettles() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        respond(#"{"granted":true,"already_granted":true,"amount_micro":"2500000"}"#)

        let service = fixture.makeService()
        let settled = await service.claimIfNeeded()

        #expect(settled == true)
        #expect(service.resolution == .granted)
        #expect(fixture.grantedRefreshes == 1)
    }

    // MARK: - Terminal refusals

    @Test func forbidden_hidesOfferAndNeverRetries() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        respond(#"{"error":{"code":"FORBIDDEN","message":"forbidden"}}"#, status: 403)

        let service = fixture.makeService()
        let settled = await service.claimIfNeeded()

        #expect(settled == false)
        #expect(service.resolution == .hidden)
        #expect(fixture.grantedRefreshes == 0)

        _ = await service.claimIfNeeded()
        #expect(WelcomeURLProtocol.requestCount == 1)
    }

    @Test func invalidRequest_isTerminal() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        respond(#"{"error":{"code":"INVALID_REQUEST","message":"bad device_id"}}"#, status: 400)

        let service = fixture.makeService()
        _ = await service.claimIfNeeded()

        #expect(service.resolution == .hidden)
    }

    // MARK: - Rate limiting

    @Test func rateLimited_honorsRetryAfterAndStaysPending() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        respond(
            #"{"error":{"code":"RATE_LIMITED","message":"slow down"}}"#,
            status: 429,
            headers: ["retry-after": "120"]
        )

        let service = fixture.makeService()
        let settled = await service.claimIfNeeded()

        #expect(settled == false)
        #expect(service.resolution == nil)
        let deadline = service.retryNotBefore?.timeIntervalSinceNow ?? 0
        #expect(deadline > 100 && deadline <= 121)

        // Do not burn attempts: inside the backoff window nothing is sent.
        _ = await service.claimIfNeeded()
        #expect(WelcomeURLProtocol.requestCount == 1)
    }

    @Test func backoffInterval_parsesSecondsAndFallsBack() {
        #expect(WelcomeCreditService.backoffInterval(retryAfter: "120") == 120)
        #expect(
            WelcomeCreditService.backoffInterval(retryAfter: "garbage")
                == WelcomeCreditService.defaultRateLimitBackoff
        )
        #expect(
            WelcomeCreditService.backoffInterval(retryAfter: nil)
                == WelcomeCreditService.defaultRateLimitBackoff
        )
    }

    // MARK: - Transient failures

    @Test func transportFailure_staysRetryable() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        WelcomeURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        let service = fixture.makeService()
        let settled = await service.claimIfNeeded()

        #expect(settled == false)
        #expect(service.resolution == nil)

        // The connection comes back: the retry (idempotent server-side) lands.
        respond(#"{"granted":true,"already_granted":false,"amount_micro":"2500000"}"#)
        let retried = await service.claimIfNeeded()
        #expect(retried == true)
        #expect(service.resolution == .granted)
    }

    // MARK: - Preconditions

    @Test func claim_requiresIdentityRouterAndDeviceId() async {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        WelcomeURLProtocol.handler = { _ in
            Issue.record("no request may fire when preconditions fail")
            throw URLError(.cancelled)
        }
        let service = fixture.makeService()

        // No identity yet (fresh install before onboarding).
        fixture.identityExists = false
        #expect(await service.claimIfNeeded() == false)

        // Identity but the router master switch is off.
        fixture.identityExists = true
        fixture.routerEnabled = false
        #expect(await service.claimIfNeeded() == false)

        // No stable per-Mac device id: skip rather than send a random one.
        fixture.routerEnabled = true
        fixture.deviceId = nil
        #expect(await service.claimIfNeeded() == false)

        #expect(WelcomeURLProtocol.requestCount == 0)
    }
}

// MARK: - URLProtocol mock

private final class WelcomeURLProtocol: URLProtocol {
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
