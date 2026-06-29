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
