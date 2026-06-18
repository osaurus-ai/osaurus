import Foundation

actor OsaurusRouterAPIClient {
    static let shared = OsaurusRouterAPIClient()

    private let baseURL: URL
    private let session: URLSession
    private let signer: OsaurusRouterAuthSigner
    private let authOverride: (@Sendable (inout URLRequest, Data?) async throws -> Void)?
    private let decoder: JSONDecoder

    init(
        baseURL: URL = OsaurusRouter.defaultBaseURL,
        session: URLSession? = nil,
        signer: OsaurusRouterAuthSigner = OsaurusRouterAuthSigner(),
        authOverride: (@Sendable (inout URLRequest, Data?) async throws -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.signer = signer
        self.authOverride = authOverride
        self.session = session ?? Self.makeSession()
        self.decoder = JSONDecoder()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
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

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        let bodyData = try JSONEncoder.osaurusCanonical(prettyPrinted: false).encode(body)
        var request = try await signedJSONRequest(method: "POST", path: path, body: bodyData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        return try decoder.decode(T.self, from: data)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
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
