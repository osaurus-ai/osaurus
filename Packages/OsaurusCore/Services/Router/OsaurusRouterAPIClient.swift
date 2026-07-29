import Foundation

actor OsaurusRouterAPIClient {
    static let shared = OsaurusRouterAPIClient()

    private let baseURL: URL
    private let session: URLSession
    /// Session for hosted `/v1/search` and `/v1/contents`: its request timeout
    /// sits slightly above the router's ~30s upstream budget so the router —
    /// not the local URLSession — decides timeout outcomes and can refund the
    /// hold before responding.
    private let searchSession: URLSession
    private let signer: OsaurusRouterAuthSigner
    private let authOverride: (@Sendable (inout URLRequest, Data?) async throws -> Void)?
    private let decoder: JSONDecoder

    init(
        baseURL: URL = OsaurusRouter.defaultBaseURL,
        session: URLSession? = nil,
        searchSession: URLSession? = nil,
        signer: OsaurusRouterAuthSigner = OsaurusRouterAuthSigner(),
        authOverride: (@Sendable (inout URLRequest, Data?) async throws -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.signer = signer
        self.authOverride = authOverride
        self.session = session ?? Self.makeSession()
        // An injected plain `session` (tests) also serves search calls unless
        // a dedicated search session is provided.
        self.searchSession = searchSession ?? session ?? Self.makeSearchSession()
        self.decoder = JSONDecoder()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return GlobalProxySettings.makeSession(base: config)
    }

    static func makeSearchSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return GlobalProxySettings.makeSession(base: config)
    }

    func health() async throws {
        let url = try url(path: "/health")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
    }

    func balance() async throws -> OsaurusRouterBalanceResponse {
        try await get("/credits/balance")
    }

    func checkout(amountMicro: String) async throws -> OsaurusRouterCheckoutResponse {
        struct Body: Encodable { let amount_micro: String }
        return try await post("/credits/checkout", body: Body(amount_micro: amountMicro))
    }

    /// Claim the one-time welcome credit for brand-new users. Signed like
    /// every other route (the wallet proves ownership); `deviceId` is the
    /// stable per-Mac hash from `WelcomeCreditDeviceID` — never the raw
    /// hardware UUID. Idempotent server-side: a retry of the same claim
    /// succeeds with `already_granted: true`.
    func claimWelcomeCredit(deviceId: String) async throws -> OsaurusRouterWelcomeClaimResponse {
        struct Body: Encodable { let device_id: String }
        return try await post("/credits/welcome/claim", body: Body(device_id: deviceId))
    }

    func models() async throws -> [OsaurusRouterModel] {
        let response: OsaurusRouterModelListResponse = try await get("/models")
        return response.data
    }

    func estimate(model: String, inputTokens: Int, maxTokens: Int) async throws -> OsaurusRouterEstimateResponse {
        struct Body: Encodable {
            let model: String
            let input_tokens: Int
            let max_tokens: Int
        }
        return try await post(
            "/credits/estimate",
            body: Body(model: model, input_tokens: inputTokens, max_tokens: maxTokens)
        )
    }

    func usage(limit: Int = 50, cursor: String? = nil) async throws -> OsaurusRouterUsageResponse {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await get("/credits/usage", queryItems: queryItems)
    }

    func transactions(limit: Int = 50, cursor: String? = nil) async throws -> OsaurusRouterTransactionsResponse {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await get("/credits/transactions", queryItems: queryItems)
    }

    // MARK: - Hosted web search

    func webSearch(_ body: OsaurusRouterWebSearchRequestBody) async throws -> OsaurusRouterWebSearchResponse {
        try await post("/v1/search", body: body, session: searchSession)
    }

    func webContents(_ body: OsaurusRouterWebContentsRequestBody) async throws -> OsaurusRouterWebContentsResponse {
        try await post("/v1/contents", body: body, session: searchSession)
    }

    func webSettings() async throws -> OsaurusRouterWebSettingsResponse {
        try await get("/credits/web-settings")
    }

    func updateWebSettings(autoPayEnabled: Bool) async throws -> OsaurusRouterWebSettingsResponse {
        struct Body: Encodable { let auto_pay_enabled: Bool }
        return try await post("/credits/web-settings", body: Body(auto_pay_enabled: autoPayEnabled))
    }

    func webUsage(limit: Int = 50, cursor: String? = nil) async throws -> OsaurusRouterWebUsageResponse {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await get("/credits/web-usage", queryItems: queryItems)
    }

    func signedJSONRequest(method: String, path: String, body: Data? = nil) async throws -> URLRequest {
        let url = try url(path: path)
        return try await signedJSONRequest(method: method, url: url, body: body)
    }

    func signedJSONRequest(method: String, url: URL, body: Data? = nil) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        try await sign(request: &request, body: body)
        return request
    }

    private func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        let url = try url(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await sign(request: &request, body: Data())
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        return try decoder.decode(T.self, from: data)
    }

    private func post<Body: Encodable, T: Decodable>(
        _ path: String,
        body: Body,
        session: URLSession? = nil
    ) async throws -> T {
        // Encode once with the canonical encoder: these exact bytes are both
        // signed (body hash binding) and sent.
        let bodyData = try JSONEncoder.osaurusCanonical(prettyPrinted: false).encode(body)
        var request = try await signedJSONRequest(method: "POST", path: path, body: bodyData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request, session: session)
        try ensureOK(data: data, response: response)
        return try decoder.decode(T.self, from: data)
    }

    private func perform(
        _ request: URLRequest,
        session overrideSession: URLSession? = nil
    ) async throws -> (Data, URLResponse) {
        do {
            return try await (overrideSession ?? session).data(for: request)
        } catch {
            throw OsaurusRouterAPIError.transport(error.localizedDescription)
        }
    }

    private func sign(request: inout URLRequest, body: Data?) async throws {
        if let authOverride {
            try await authOverride(&request, body)
        } else {
            try await signer.sign(request: &request, body: body)
        }
    }

    private func ensureOK(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OsaurusRouterAPIError.invalidResponse
        }
        guard !(200 ..< 300).contains(http.statusCode) else { return }

        if let envelope = try? decoder.decode(OsaurusRouterErrorEnvelope.self, from: data) {
            throw OsaurusRouterAPIError.from(
                code: envelope.error.code,
                message: envelope.error.message,
                status: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "retry-after")
            )
        }

        let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        throw OsaurusRouterAPIError.server(code: "HTTP_\(http.statusCode)", message: message, status: http.statusCode)
    }

    private func url(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw OsaurusRouterAPIError.invalidURL
        }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        components.path = normalizedPath
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw OsaurusRouterAPIError.invalidURL
        }
        return url
    }
}
