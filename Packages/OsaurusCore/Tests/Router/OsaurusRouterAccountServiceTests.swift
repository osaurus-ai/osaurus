//
//  OsaurusRouterAccountServiceTests.swift
//  osaurusTests
//
//  Request-budget contract for the personal-wallet account service: app
//  activation asks the Router only while a Stripe top-up is pending (and
//  only a bounded number of times), billed-stream summaries never fetch
//  `/credits/usage` on their own, and passive balance readers coalesce.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Osaurus router account service", .serialized)
@MainActor
struct OsaurusRouterAccountServiceTests {

    // MARK: - Harness

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var paths: [String] = []
        /// Balances returned, in order (the last repeats).
        var balances: [String]
        /// Optional gate a request waits on before responding (for coalescing).
        var gate: DispatchSemaphore?

        init(balances: [String] = ["1000000"]) { self.balances = balances }

        func record(_ path: String) {
            lock.lock()
            paths.append(path)
            lock.unlock()
        }

        func count(of path: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return paths.filter { $0 == path }.count
        }

        func nextBalance() -> String {
            lock.lock()
            defer { lock.unlock() }
            return balances.count > 1 ? balances.removeFirst() : balances[0]
        }
    }

    private struct Harness {
        let service: OsaurusRouterAccountService
        let log: CallLog
        let restoreRouter: () -> Void
    }

    private func makeHarness(
        balances: [String] = ["1000000"],
        identityExists: @escaping () -> Bool = { true },
        usageRevisionDebounce: TimeInterval = 0.05
    ) throws -> Harness {
        let log = CallLog(balances: balances)
        AccountURLProtocol.handler = { request in
            let path = request.url?.path ?? "?"
            log.record(path)
            log.gate?.wait()
            switch path {
            case "/credits/balance":
                return (200, Data(#"{"balance_micro":"\#(log.nextBalance())","frozen":false}"#.utf8))
            case "/credits/usage":
                return (200, Data(#"{"data":[],"next_cursor":null}"#.utf8))
            case "/credits/checkout":
                return (200, Data(#"{"client_secret":"cs","checkout_url":"https://checkout.stripe.com/c/pay"}"#.utf8))
            default:
                return (404, Data(#"{"error":{"code":"NOT_FOUND","message":"nope"}}"#.utf8))
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = OsaurusRouterAPIClient(
            baseURL: try #require(URL(string: "https://router.test")),
            session: session,
            authOverride: { request, _ in
                request.setValue("0xabc", forHTTPHeaderField: "x-wallet-address")
            }
        )
        let previous = UserDefaults.standard.object(forKey: OsaurusRouter.enabledDefaultsKey)
        OsaurusRouter.setEnabled(true)
        let service = OsaurusRouterAccountService(
            client: client,
            usageRevisionDebounce: usageRevisionDebounce,
            observesNotifications: false,
            identityExists: identityExists
        )
        return Harness(service: service, log: log) {
            if let previous {
                UserDefaults.standard.set(previous, forKey: OsaurusRouter.enabledDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: OsaurusRouter.enabledDefaultsKey)
            }
        }
    }

    private func summary(costMicro: String) -> OsaurusRouterSummaryEvent.Summary {
        OsaurusRouterSummaryEvent.Summary(
            requestId: "req-1", costMicro: costMicro, status: "ok", tokenSource: "provider",
            inputTokens: 10, outputTokens: 5, billedTo: nil)
    }

    // MARK: - Activation

    /// Cmd-Tabbing in and out of the app is not a reason to ask the Router
    /// anything: without a pending Checkout, activation is free.
    @Test func activation_withoutPendingTopUp_makesNoRequest() async throws {
        let h = try makeHarness()
        defer { h.restoreRouter() }

        for _ in 0..<5 {
            await h.service.handleAppActivation()
        }
        #expect(h.log.paths.isEmpty)
        #expect(!h.service.awaitingTopUpConfirmation)
    }

    /// While a Checkout is open, each activation polls the balance once,
    /// until the increase lands or the bound is reached.
    @Test func activation_pollsBalanceOnlyWhileTopUpPending_andIsBounded() async throws {
        let h = try makeHarness(balances: ["1000000"])  // never increases: abandoned tab
        defer { h.restoreRouter() }
        await h.service.refreshBalance()
        #expect(h.log.count(of: "/credits/balance") == 1)

        h.service.armTopUpConfirmation()
        #expect(h.service.awaitingTopUpConfirmation)

        let bound = OsaurusRouterAccountService.maxTopUpConfirmationPolls
        for i in 1...bound {
            await h.service.handleAppActivation()
            #expect(h.log.count(of: "/credits/balance") == 1 + i)
        }
        #expect(!h.service.awaitingTopUpConfirmation)

        // Bound reached: back to free activations.
        await h.service.handleAppActivation()
        await h.service.handleAppActivation()
        #expect(h.log.count(of: "/credits/balance") == 1 + bound)
    }

    @Test func activation_stopsPollingOnceTheIncreaseLands() async throws {
        let h = try makeHarness(balances: ["1000000", "1000000", "6000000"])
        defer { h.restoreRouter() }
        await h.service.refreshBalance()  // 1000000
        h.service.armTopUpConfirmation()

        await h.service.handleAppActivation()  // still 1000000
        #expect(h.service.awaitingTopUpConfirmation)
        await h.service.handleAppActivation()  // 6000000: landed
        #expect(!h.service.awaitingTopUpConfirmation)
        #expect(h.service.balanceMicroValue == 6_000_000)
        #expect(h.log.count(of: "/credits/balance") == 3)

        await h.service.handleAppActivation()
        #expect(h.log.count(of: "/credits/balance") == 3)
    }

    @Test func activation_withRouterDisabled_makesNoRequestEvenWhenPending() async throws {
        let h = try makeHarness()
        defer { h.restoreRouter() }
        h.service.armTopUpConfirmation()
        OsaurusRouter.setEnabled(false)

        await h.service.handleAppActivation()
        #expect(h.log.paths.isEmpty)
    }

    // MARK: - Billed summaries

    /// A tool-heavy agent turn emits one summary per round. None of them may
    /// fetch the usage list; the (debounced) revision moves once so a
    /// mounted usage view refetches exactly once.
    @Test func noteRouterSummary_deductsLocallyAndBumpsRevisionWithoutUsageFetch() async throws {
        let h = try makeHarness(balances: ["1000000"], usageRevisionDebounce: 0.05)
        defer { h.restoreRouter() }
        await h.service.refreshBalance()
        #expect(h.service.usageRevision == 0)

        for _ in 0..<6 {
            h.service.noteRouterSummary(summary(costMicro: "1500"))
        }
        #expect(h.service.balanceMicroValue == 1_000_000 - 6 * 1500)
        #expect(h.service.usageRevision == 0)  // still debouncing

        try await Task.sleep(for: .milliseconds(200))
        #expect(h.service.usageRevision == 1)
        #expect(h.log.count(of: "/credits/usage") == 0)
        #expect(h.log.count(of: "/credits/balance") == 1)

        // A later turn bumps again — one per burst.
        h.service.noteRouterSummary(summary(costMicro: "10"))
        h.service.noteRouterSummary(summary(costMicro: "10"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.service.usageRevision == 2)
        #expect(h.log.count(of: "/credits/usage") == 0)
    }

    /// Without a cached balance the summary cannot deduct locally, so one
    /// balance fetch is allowed — still never a usage fetch.
    @Test func noteRouterSummary_withoutCachedBalance_fetchesBalanceNotUsage() async throws {
        let h = try makeHarness()
        defer { h.restoreRouter() }
        h.service.noteRouterSummary(summary(costMicro: "1500"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.log.count(of: "/credits/balance") == 1)
        #expect(h.log.count(of: "/credits/usage") == 0)
    }

    // MARK: - Balance coalescing

    @Test func refreshBalance_concurrentCallersShareOneRequest() async throws {
        let h = try makeHarness()
        defer { h.restoreRouter() }
        let gate = DispatchSemaphore(value: 0)
        h.log.gate = gate
        let service = h.service

        async let a: Void = service.refreshBalance()
        async let b: Void = service.refreshBalance(ifOlderThan: 300)
        async let c: Void = service.refreshBalance(ifOlderThan: 300)
        async let d: Void = service.refreshBalance()
        // Let the first caller reach the stub before releasing it.
        try await Task.sleep(for: .milliseconds(100))
        h.log.gate = nil
        gate.signal()
        _ = await (a, b, c, d)

        #expect(h.log.count(of: "/credits/balance") == 1)
        #expect(h.service.balanceMicroValue == 1_000_000)
    }

    /// Passive chrome (composer chips) asks with a max age and gets the
    /// cached value; user-opened surfaces (no max age) always refetch.
    @Test func refreshBalance_ifOlderThan_skipsFreshValueButForcedRefreshDoesNot() async throws {
        let h = try makeHarness(balances: ["1000000", "2000000", "3000000"])
        defer { h.restoreRouter() }

        await h.service.refreshBalance(ifOlderThan: 300)
        #expect(h.log.count(of: "/credits/balance") == 1)
        await h.service.refreshBalance(ifOlderThan: 300)
        await h.service.refreshBalance(ifOlderThan: 300)
        #expect(h.log.count(of: "/credits/balance") == 1)
        #expect(h.service.balanceMicroValue == 1_000_000)

        await h.service.refreshBalance()
        #expect(h.log.count(of: "/credits/balance") == 2)
        #expect(h.service.balanceMicroValue == 2_000_000)

        // A zero max age always refetches.
        await h.service.refreshBalance(ifOlderThan: 0)
        #expect(h.log.count(of: "/credits/balance") == 3)
        #expect(h.service.balanceMicroValue == 3_000_000)
    }

    @Test func refreshBalance_withoutIdentity_makesNoRequest() async throws {
        let h = try makeHarness(identityExists: { false })
        defer { h.restoreRouter() }
        await h.service.refreshBalance()
        await h.service.refreshBalance(ifOlderThan: 300)
        #expect(h.log.paths.isEmpty)
        #expect(h.service.balance == nil)
        #expect(h.service.lastError == OsaurusRouterAPIError.noIdentity.localizedDescription)
    }

    @Test func clearForDisabledRouter_dropsFreshnessAndPendingTopUp() async throws {
        let h = try makeHarness()
        defer { h.restoreRouter() }
        await h.service.refreshBalance(ifOlderThan: 300)
        h.service.armTopUpConfirmation()

        h.service.clearForDisabledRouter()
        #expect(h.service.balance == nil)
        #expect(!h.service.awaitingTopUpConfirmation)

        // Freshness was reset: the next aged read goes to the Router again.
        await h.service.refreshBalance(ifOlderThan: 300)
        #expect(h.log.count(of: "/credits/balance") == 2)
    }
}

private final class AccountURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
