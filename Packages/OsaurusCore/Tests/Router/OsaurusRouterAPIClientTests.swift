import Foundation
import CFNetwork
import Testing

@testable import OsaurusCore

@Suite("Osaurus router API client", .serialized)
struct OsaurusRouterAPIClientTests {
    @Test func defaultSessionUsesGlobalProxySetting() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-router-proxy-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }

            try OsaurusPaths.ensureExists(OsaurusPaths.config())
            var configuration = ServerConfiguration.default
            configuration.globalProxyURL = "socks5://proxy.example.com:1080"
            try JSONEncoder().encode(configuration).write(to: OsaurusPaths.serverConfigFile(), options: .atomic)

            let session = OsaurusRouterAPIClient.makeSession()
            defer { session.invalidateAndCancel() }

            let dictionary = session.configuration.connectionProxyDictionary
            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSEnable)] as? Int == 1)
            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSProxy)] as? String == "proxy.example.com")
            #expect(dictionary?[proxyKey(kCFNetworkProxiesSOCKSPort)] as? Int == 1080)
            #expect(session.configuration.timeoutIntervalForRequest == 30)
            #expect(session.configuration.timeoutIntervalForResource == 120)
        }
    }

    @Test func balance_decodesMicroStringAndSendsAuthHeaders() async throws {
        let client = try makeClient { request in
            #expect(request.url?.path == "/credits/balance")
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") == TestKeys.aliceAddress.lowercased())
            return json(#"{"balance_micro":"7250000","frozen":false}"#)
        }

        let balance = try await client.balance()
        #expect(balance.balanceMicro == "7250000")
        #expect(balance.frozen == false)
    }

    @Test func checkout_encodesAmountAndDecodesURL() async throws {
        let client = try makeClient { request in
            let body = String(data: request.httpBodyStreamData ?? request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(body.contains(#""amount_micro":"5000000""#))
            return json(#"{"client_secret":"cs_test","checkout_url":"https://checkout.stripe.com/c/pay"}"#)
        }

        let checkout = try await client.checkout(amountMicro: "5000000")
        #expect(checkout.clientSecret == "cs_test")
        #expect(checkout.checkoutURL == "https://checkout.stripe.com/c/pay")
    }

    @Test func models_decodesRouterModelList() async throws {
        let client = try makeClient { _ in
            json(
                """
                {"data":[{"id":"llama-3.3","provider":"venice","context_length":131072,"capabilities":{"tools":true},"input_micro_per_mtok":"2000000","output_micro_per_mtok":"4000000","input_display":"$2.00/M","output_display":"$4.00/M","stale":false}]}
                """
            )
        }

        let models = try await client.models()
        #expect(models.map(\.id) == ["llama-3.3"])
        #expect(models[0].inputDisplay == "$2.00/M")
    }

    @Test func usage_includesCursorInSignedPath() async throws {
        let client = try makeClient { request in
            #expect(request.url?.path == "/credits/usage")
            #expect(request.url?.query?.contains("limit=2") == true)
            #expect(request.url?.query?.contains("cursor=cursor-1") == true)
            return json(
                """
                {"data":[{"id":"u1","model":"m","provider":"venice","input_tokens":1,"output_tokens":2,"cost_micro":"123","status":"completed","token_source":"provider","created_at":"2026-06-13T18:00:00Z"}],"next_cursor":null}
                """
            )
        }

        let response = try await client.usage(limit: 2, cursor: "cursor-1")
        #expect(response.data.count == 1)
        #expect(response.data[0].costMicro == "123")
        #expect(response.nextCursor == nil)
    }

    @Test func transactions_includesCursorAndDecodesLedgerItems() async throws {
        let client = try makeClient { request in
            #expect(request.url?.path == "/credits/transactions")
            #expect(request.url?.query?.contains("limit=3") == true)
            #expect(request.url?.query?.contains("cursor=cursor-2") == true)
            return json(
                """
                {"data":[{"id":"tx_1","amount_micro":"5000000","entry_type":"topup","ref_type":"stripe_checkout","ref_id":"cs_test","created_at":"2026-06-13T18:00:00Z"}],"next_cursor":"cursor-3"}
                """
            )
        }

        let response = try await client.transactions(limit: 3, cursor: "cursor-2")
        #expect(response.data.count == 1)
        #expect(response.data[0].amountMicro == "5000000")
        #expect(response.data[0].entryType == "topup")
        #expect(response.data[0].refType == "stripe_checkout")
        #expect(response.nextCursor == "cursor-3")
    }

    @Test func welcomeClaim_postsDeviceIdAndDecodesGrant() async throws {
        let client = try makeClient { request in
            #expect(request.url?.path == "/credits/welcome/claim")
            #expect(request.httpMethod == "POST")
            let body = String(data: request.httpBodyStreamData ?? request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(body == #"{"device_id":"stable-device-hash"}"#)
            return json(#"{"granted":true,"already_granted":false,"amount_micro":"2500000"}"#)
        }

        let claim = try await client.claimWelcomeCredit(deviceId: "stable-device-hash")
        #expect(claim.granted == true)
        #expect(claim.alreadyGranted == false)
        #expect(claim.amountMicro == "2500000")
    }

    @Test func welcomeClaim_decodesIdempotentRetry() async throws {
        let client = try makeClient { _ in
            json(#"{"granted":true,"already_granted":true,"amount_micro":"2500000"}"#)
        }

        let claim = try await client.claimWelcomeCredit(deviceId: "stable-device-hash")
        #expect(claim.granted == true)
        #expect(claim.alreadyGranted == true)
    }

    @Test func redeemCode_postsExactCodeAndDecodesCampaignResult() async throws {
        let client = try makeClient { request in
            #expect(request.url?.path == "/credits/redeem")
            #expect(request.httpMethod == "POST")
            let body = String(
                data: request.httpBodyStreamData ?? request.httpBody ?? Data(),
                encoding: .utf8
            ) ?? ""
            #expect(body == #"{"code":"LAUNCH25"}"#)
            return json(
                """
                {"redeemed":true,"already_redeemed":false,"campaign_kind":"first_time","amount_micro":"5000000","referral_pending":false,"redemption_message":"Welcome to Osaurus — $5 in credits was added."}
                """
            )
        }

        let response = try await client.redeemCode("LAUNCH25")
        #expect(response.redeemed)
        #expect(response.alreadyRedeemed == false)
        #expect(response.campaignKind == "first_time")
        #expect(response.amountMicro == "5000000")
        #expect(response.referralPending == false)
        #expect(response.redemptionMessage == "Welcome to Osaurus — $5 in credits was added.")
    }

    @Test func redeemCode_decodesIdempotentReferralResult() async throws {
        let client = try makeClient { _ in
            json(
                """
                {"redeemed":true,"already_redeemed":true,"campaign_kind":"referral","amount_micro":"0","referral_pending":true,"redemption_message":"Referral linked."}
                """
            )
        }

        let response = try await client.redeemCode("OSA-TEST")
        #expect(response.alreadyRedeemed)
        #expect(response.referralPending)
        #expect(response.amountMicro == "0")
    }

    @Test func searchSession_timeoutSitsAboveRouterUpstreamBudget() {
        let session = OsaurusRouterAPIClient.makeSearchSession()
        defer { session.invalidateAndCancel() }
        // Slightly above the router's ~30s upstream timeout so the router —
        // not the local URLSession — decides timeout outcomes and can refund
        // the hold before responding.
        #expect(session.configuration.timeoutIntervalForRequest > 30)
    }

    @Test func webSettings_decodesAutoPayAndGrants() async throws {
        let client = try makeClient { request in
            #expect(request.url?.path == "/credits/web-settings")
            #expect(request.httpMethod == "GET")
            return json(
                """
                {"auto_pay_enabled":true,
                 "grants":{"search":{"included_total":20,"used_total":3,"remaining_total":17},
                           "contents":{"included_total":0,"used_total":0,"remaining_total":0}}}
                """
            )
        }

        let settings = try await client.webSettings()
        #expect(settings.autoPayEnabled)
        #expect(settings.grants?.search?.remainingTotal == 17)
        #expect(settings.grants?.contents?.includedTotal == 0)
    }

    @Test func updateWebSettings_postsPreferenceAndDecodesResult() async throws {
        let client = try makeClient { request in
            #expect(request.url?.path == "/credits/web-settings")
            #expect(request.httpMethod == "POST")
            let body = String(data: request.httpBodyStreamData ?? request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(body == #"{"auto_pay_enabled":false}"#)
            return json(#"{"auto_pay_enabled":false,"grants":null}"#)
        }

        let settings = try await client.updateWebSettings(autoPayEnabled: false)
        #expect(settings.autoPayEnabled == false)
    }

    @Test func webUsage_includesCursorAndDecodesMetadataOnlyRows() async throws {
        let client = try makeClient { request in
            #expect(request.url?.path == "/credits/web-usage")
            #expect(request.url?.query?.contains("limit=25") == true)
            #expect(request.url?.query?.contains("cursor=web-cursor") == true)
            return json(
                """
                {"data":[{"id":"wu1","request_id":"idem-1","operation":"search","provider":"exa",
                          "billing":"free","units":{"requests":1,"extra_results":0,"content_pages":2,"summary_pages":0},
                          "cost_micro":"0","status":"completed","created_at":"2026-07-01T10:00:00Z"}],
                 "next_cursor":null}
                """
            )
        }

        let response = try await client.webUsage(limit: 25, cursor: "web-cursor")
        #expect(response.data.count == 1)
        #expect(response.data[0].operation == "search")
        #expect(response.data[0].billing == "free")
        #expect(response.data[0].units?.contentPages == 2)
        #expect(response.nextCursor == nil)
    }

    @Test func errorEnvelope_mapsPaidWebDisabled() async throws {
        let client = try makeClient { _ in
            json(#"{"error":{"code":"PAID_WEB_DISABLED","message":"auto-pay off"}}"#, status: 402)
        }

        do {
            _ = try await client.webSettings()
            Issue.record("Expected paid-web-disabled error")
        } catch let error as OsaurusRouterAPIError {
            guard case .paidWebDisabled = error else {
                Issue.record("Expected .paidWebDisabled, got \(error)")
                return
            }
        }
    }

    @Test func errorEnvelope_mapsIdempotencyConflict() async throws {
        let client = try makeClient { _ in
            json(#"{"error":{"code":"IDEMPOTENCY_CONFLICT","message":"reuse"}}"#, status: 409)
        }

        do {
            _ = try await client.webSettings()
            Issue.record("Expected idempotency-conflict error")
        } catch let error as OsaurusRouterAPIError {
            guard case .idempotencyConflict = error else {
                Issue.record("Expected .idempotencyConflict, got \(error)")
                return
            }
        }
    }

    @Test func errorEnvelope_mapsInsufficientFunds() async throws {
        let client = try makeClient { _ in
            json(#"{"error":{"code":"INSUFFICIENT_FUNDS","message":"top up required"}}"#, status: 402)
        }

        do {
            _ = try await client.balance()
            Issue.record("Expected insufficient funds error")
        } catch let error as OsaurusRouterAPIError {
            guard case .insufficientFunds = error else {
                Issue.record("Expected .insufficientFunds, got \(error)")
                return
            }
        }
    }

    // MARK: - Announcements (unauthenticated feed)

    /// The feed is public and IP rate-limited: no wallet headers may be
    /// attached (the signer would otherwise leak the address on a call
    /// that happens on every launch), and the version travels as a query
    /// item so the router can filter by `min_app_version`.
    @Test func announcements_isUnsignedAndCarriesAppVersion() async throws {
        let client = try makeClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/announcements")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query == [URLQueryItem(name: "app_version", value: "1.42.0")])
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") == nil)
            #expect(request.value(forHTTPHeaderField: "x-wallet-timestamp") == nil)
            #expect(request.value(forHTTPHeaderField: "x-wallet-signature") == nil)
            return json(
                #"{"server_time":"2026-10-02T10:00:00Z","announcements":[{"id":"a1","slug":"raptor-launch","title":"Raptor is live","body":"**Today** on Product Hunt.","body_format":"markdown","image_url":"https://cdn.osaurus.ai/raptor.png","ctas":[{"label":"Upvote","kind":"external_url","url":"https://www.producthunt.com/posts/osaurus","style":"primary"},{"label":"Credits","kind":"deeplink","url":"osaurus://settings?tab=credits"}],"starts_at":"2026-10-02T07:00:00Z","ends_at":"2026-10-03T07:00:00Z","priority":10}]}"#
            )
        }

        let response = try await client.announcements(appVersion: "1.42.0")
        #expect(response.serverTime == "2026-10-02T10:00:00Z")
        #expect(response.announcements.count == 1)
        let a = try #require(response.announcements.first)
        #expect(a.slug == "raptor-launch")
        #expect(a.priority == 10)
        #expect(a.resolvedImageURL?.host == "cdn.osaurus.ai")
        #expect(a.actionableCTAs.count == 2)
        #expect(a.actionableCTAs[0].isPrimary)
        #expect(a.actionableCTAs[1].isDeepLink)
    }

    @Test func announcements_omitsEmptyAppVersionAndMapsRateLimit() async throws {
        let client = try makeClient { request in
            #expect(request.url?.query == nil)
            return (429, Data(#"{"error":{"code":"RATE_LIMITED","message":"slow down"}}"#.utf8),
                ["content-type": "application/json", "retry-after": "120"])
        }

        do {
            _ = try await client.announcements(appVersion: nil)
            Issue.record("Expected rate-limited error")
        } catch let error as OsaurusRouterAPIError {
            guard case .rateLimited(let retryAfter) = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
            #expect(retryAfter == "120")
        }
    }

    /// Insights must not record the public feed or health probe (no account
    /// data leaves), but every signed control-plane call stays logged.
    @Test func controlPlaneLogging_excludesUnauthenticatedProbes() {
        #expect(!OsaurusRouterAPIClient.shouldLogControlPlaneCall(path: "/announcements"))
        #expect(!OsaurusRouterAPIClient.shouldLogControlPlaneCall(path: "/health"))
        #expect(!OsaurusRouterAPIClient.shouldLogControlPlaneCall(path: "/v1/search"))
        #expect(OsaurusRouterAPIClient.shouldLogControlPlaneCall(path: "/credits/balance"))
        #expect(OsaurusRouterAPIClient.shouldLogControlPlaneCall(path: "/workspaces"))
        #expect(OsaurusRouterAPIClient.shouldLogControlPlaneCall(path: nil))
    }

    // MARK: - Help (/support/*)

    private static let supportThreadJSON = #"""
        {"id":"7d0f0c2e-0000-4000-8000-000000000001","subject":"Chat freezes","status":"open","unread":false,
         "last_user_message_at":"2026-11-13T21:22:28.955Z","last_staff_message_at":null,
         "created_at":"2026-11-13T21:22:28.955Z","updated_at":"2026-11-13T21:22:28.955Z",
         "messages":[{"id":"m1","author":"user","body":"Chat freezes","created_at":"2026-11-13T21:22:28.955Z"}]}
        """#

    @Test func supportThreads_isSignedAndDecodesUnreadCount() async throws {
        let client = try makeClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/support/threads")
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") == TestKeys.aliceAddress.lowercased())
            #expect(request.value(forHTTPHeaderField: "x-wallet-signature") != nil)
            return json(
                #"""
                {"data":[{"id":"t1","subject":"S","status":"answered","unread":true,
                  "last_user_message_at":"2026-11-13T21:22:28Z","last_staff_message_at":"2026-11-13T22:00:00Z",
                  "created_at":"2026-11-13T21:22:28Z","updated_at":"2026-11-13T22:00:00Z"}],"unread_count":1}
                """#
            )
        }

        let response = try await client.supportThreads()
        #expect(response.unreadCount == 1)
        #expect(response.data.map(\.status) == [.answered])
    }

    /// The report body on the wire: literal `consent: true`, snake_case
    /// app and hardware keys, and the diagnostics value untouched.
    @Test func createSupportThread_postsConsentAndReportFields() async throws {
        let client = try makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/support/threads")
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") == TestKeys.aliceAddress.lowercased())
            let data = request.httpBodyStreamData ?? request.httpBody ?? Data()
            let body = try JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object(let fields) = body else {
                Issue.record("report body is not a JSON object")
                return json(Self.supportThreadJSON, status: 201)
            }
            #expect(fields["consent"] == .bool(true))
            #expect(fields["description"] == .string("Chat freezes when I attach a PDF"))
            #expect(
                fields["app"]
                    == .object([
                        "version": .string("1.2.3"), "build": .string("456"), "os_version": .string("macOS test"),
                    ]))
            #expect(
                fields["hardware"]
                    == .object(["model": .string("MacBook Air"), "chip": .string("M4"), "memory_gb": .number(24)]))
            #expect(fields["diagnostics"] == .object(["schemaVersion": .number(1)]))
            return json(Self.supportThreadJSON, status: 201)
        }

        let thread = try await client.createSupportThread(
            OsaurusRouterSupportReportBody(
                description: "Chat freezes when I attach a PDF",
                consent: true,
                app: .init(version: "1.2.3", build: "456", osVersion: "macOS test"),
                hardware: .init(model: "MacBook Air", chip: "M4", memoryGB: 24),
                diagnostics: .object(["schemaVersion": .number(1)])
            ))
        #expect(thread.id == "7d0f0c2e-0000-4000-8000-000000000001")
        #expect(thread.messages?.count == 1)
    }

    @Test func supportThreadDetailReplyAndRead_useTheThreadPath() async throws {
        let id = "7d0f0c2e-0000-4000-8000-000000000001"
        let seen = RequestRecorder()
        let client = try makeClient { request in
            let body = String(data: request.httpBodyStreamData ?? request.httpBody ?? Data(), encoding: .utf8) ?? ""
            seen.record("\(request.httpMethod ?? "") \(request.url?.path ?? "") \(body)")
            #expect(request.value(forHTTPHeaderField: "x-wallet-signature") != nil)
            return json(Self.supportThreadJSON)
        }

        _ = try await client.supportThread(id: id)
        _ = try await client.replyToSupportThread(id: id, body: "Still happening")
        _ = try await client.markSupportThreadRead(id: id)

        #expect(
            seen.entries == [
                "GET /support/threads/\(id) ",
                #"POST /support/threads/\#(id)/messages {"body":"Still happening"}"#,
                "POST /support/threads/\(id)/read ",
            ])
    }

    /// A thread id is a path segment the app got from the router; anything
    /// that could change the path is refused before a request is signed.
    @Test func supportThread_rejectsIdsThatAreNotOnePathSegment() async throws {
        let seen = RequestRecorder()
        let client = try makeClient { request in
            seen.record(request.url?.path ?? "")
            return json(Self.supportThreadJSON)
        }

        for id in ["../credits/balance", "a/b", "a?x=1", ""] {
            await #expect(throws: (any Error).self) { _ = try await client.supportThread(id: id) }
            await #expect(throws: (any Error).self) { _ = try await client.markSupportThreadRead(id: id) }
            await #expect(throws: (any Error).self) {
                _ = try await client.replyToSupportThread(id: id, body: "x")
            }
        }
        #expect(seen.entries.isEmpty)
    }

    @Test func supportErrors_mapOpenLimitAndRateLimit() async throws {
        let limited = try makeClient { _ in
            (429, Data(#"{"error":{"code":"RATE_LIMITED","message":"slow down"}}"#.utf8), ["retry-after": "120"])
        }
        do {
            _ = try await limited.supportThreads()
            Issue.record("expected a rate-limit error")
        } catch let error as OsaurusRouterAPIError {
            guard case .rateLimited(let retryAfter) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(retryAfter == "120")
        }

        let capped = try makeClient { _ in
            json(#"{"error":{"code":"INVALID_STATE","message":"too many open threads"}}"#, status: 409)
        }
        do {
            _ = try await capped.createSupportThread(
                OsaurusRouterSupportReportBody(
                    description: "Chat freezes when I attach a PDF", consent: true,
                    app: .init(version: nil, build: nil, osVersion: nil),
                    hardware: .init(model: nil, chip: nil, memoryGB: nil), diagnostics: nil))
            Issue.record("expected the open-report cap error")
        } catch let error as OsaurusRouterAPIError {
            guard case .server(let code, _, let status) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(code == "INVALID_STATE")
            #expect(status == 409)
            #expect(
                SupportService.userMessage(for: error)
                    == L("You already have 3 open reports. Add to one of them, or wait until one is closed."))
        }
    }

    @Test func supportCalls_areLabeledHelpInInsights() {
        #expect(OsaurusRouterAPIClient.controlPlanePurpose(path: "/support/threads") == L("Help & feedback"))
        #expect(
            OsaurusRouterAPIClient.controlPlanePurpose(path: "/support/threads/abc/messages")
                == L("Help & feedback"))
        #expect(OsaurusRouterAPIClient.controlPlanePurpose(path: "/credits/balance") != L("Help & feedback"))
    }

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (Int, Data, [String: String])
    ) throws -> OsaurusRouterAPIClient {
        RouterURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouterURLProtocol.self]
        let session = URLSession(configuration: config)
        let baseURL = try #require(URL(string: "https://router.test"))
        return OsaurusRouterAPIClient(
            baseURL: baseURL,
            session: session,
            authOverride: { request, _ in
                request.setValue(TestKeys.aliceAddress.lowercased(), forHTTPHeaderField: "x-wallet-address")
                request.setValue("1717171717", forHTTPHeaderField: "x-wallet-timestamp")
                request.setValue("0x" + String(repeating: "1", count: 130), forHTTPHeaderField: "x-wallet-signature")
            }
        )
    }

    private func json(_ body: String, status: Int = 200) -> (Int, Data, [String: String]) {
        (status, Data(body.utf8), ["content-type": "application/json"])
    }
}

/// Requests the stub saw, in order.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String] = []

    var entries: [String] { lock.withLock { _entries } }
    func record(_ entry: String) { lock.withLock { _entries.append(entry) } }
}

private final class RouterURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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

private extension URLRequest {
    var httpBodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private func proxyKey(_ value: CFString) -> AnyHashable {
    AnyHashable(value as String)
}
