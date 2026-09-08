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

    /// Redeem a promotion or referral code. The canonical encoder produces the
    /// exact bytes used for both EIP-191 signing and the HTTP request body.
    func redeemCode(_ code: String) async throws -> OsaurusRouterRedeemCodeResponse {
        struct Body: Encodable { let code: String }
        return try await post("/credits/redeem", body: Body(code: code))
    }

    func models() async throws -> [OsaurusRouterModel] {
        let response: OsaurusRouterModelListResponse = try await get("/models")
        return response.data
    }

    // MARK: - Workspaces (`/workspaces/*`)

    func observeWorkspaceSync(_ receive: @Sendable (WorkspaceSyncFrame) async -> Void) async throws {
        var request = try await signedJSONRequest(method: "GET", path: "/workspaces/sync")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-ndjson") == true
        else { throw OsaurusRouterAPIError.invalidResponse }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.utf8.count <= 1_048_576 else { throw OsaurusRouterAPIError.invalidResponse }
            let frame = try JSONDecoder().decode(WorkspaceSyncFrame.self, from: Data(line.utf8))
            await receive(frame)
        }
    }

    func verifyWorkspaceAgentAccess(workspaceId: String, agentAddress: String, attestation: String) async throws {
        struct Body: Encodable { let attestation: String }
        struct Response: Decodable { let allowed: Bool }
        let body = try JSONEncoder.osaurusCanonical().encode(Body(attestation: attestation))
        var request = try await signedJSONRequest(
            method: "POST",
            path:
                "/workspaces/\(try routerPathComponent(workspaceId))/agents/\(try routerPathComponent(agentAddress))/access",
            body: body
        )
        request.timeoutInterval = 2
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        let result = try decoder.decode(Response.self, from: data)
        guard result.allowed else { throw OsaurusRouterAPIError.invalidResponse }
    }

    /// Redeems an activation code (web purchase made before the buyer had a
    /// wallet, or an admin comp), creating the workspace owned by the caller
    /// and binding the parked subscription to them. Wallet-signed.
    /// Re-presenting a code this wallet already redeemed returns the existing
    /// workspace (idempotent retry after a dropped response).
    func workspaceActivate(code: String, name: String) async throws -> OsaurusRouterWorkspaceDetail {
        struct Body: Encodable {
            let code: String
            let name: String
        }
        return try await post("/workspaces/activate", body: Body(code: code, name: name))
    }

    /// Creates a workspace owned by the caller. Immediate (`201 created`) when
    /// the owner already has a live, non-trialing subscription; otherwise
    /// `200 checkout_required` with a Stripe Checkout URL (carrying the trial
    /// on a first subscription). `409 TRIAL_WORKSPACE_LIMIT` while trialing
    /// with a workspace already. `price_id` is only consulted on the Checkout
    /// path (default: the live monthly price).
    func createWorkspace(name: String, priceId: String? = nil) async throws
        -> OsaurusRouterWorkspaceCreateResponse
    {
        struct Body: Encodable {
            let name: String
            let price_id: String?
        }
        return try await post("/workspaces", body: Body(name: name, price_id: priceId))
    }

    /// Puts a suspended workspace back on the owner's subscription in place:
    /// `200 upgraded` on a live subscription, else `200 checkout_required`.
    func upgradeWorkspace(id: String, priceId: String? = nil) async throws
        -> OsaurusRouterWorkspaceCreateResponse
    {
        struct Body: Encodable { let price_id: String? }
        return try await post(
            "/workspaces/\(try routerPathComponent(id))/upgrade", body: Body(price_id: priceId)
        )
    }

    func listWorkspaces() async throws -> [OsaurusRouterWorkspaceSummary] {
        struct Response: Decodable { let data: [OsaurusRouterWorkspaceSummary] }
        let response: Response = try await get("/workspaces")
        return response.data
    }

    /// The single plan (levers + trial length) and the live per-workspace
    /// prices. Public and unsigned (pricing-page material, cacheable).
    func workspacePrices() async throws -> OsaurusRouterWorkspacePricesResponse {
        let url = try url(path: "/workspaces/prices")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        return try decoder.decode(OsaurusRouterWorkspacePricesResponse.self, from: data)
    }

    /// The caller's owner subscription (one per account, covering every
    /// workspace they own) with trial state, plus owned/billed counts and
    /// trial eligibility.
    func workspaceBilling() async throws -> OsaurusRouterWorkspaceBillingSummary {
        try await get("/workspaces/billing")
    }

    /// Stripe Billing Portal for the caller's owner subscription. `409
    /// INVALID_STATE` when the account has never subscribed.
    func workspaceBillingPortal() async throws -> OsaurusRouterWorkspacePortalResponse {
        struct Body: Encodable {}
        return try await post("/workspaces/billing/portal", body: Body())
    }

    func workspaceDetail(id: String) async throws -> OsaurusRouterWorkspaceDetail {
        try await get("/workspaces/\(try routerPathComponent(id))")
    }

    func renameWorkspace(id: String, name: String) async throws {
        struct Body: Encodable { let name: String }
        try await sendVoid(
            method: "PATCH",
            path: "/workspaces/\(try routerPathComponent(id))",
            body: Body(name: name)
        )
    }

    func deleteWorkspace(id: String) async throws {
        try await sendVoid(method: "DELETE", path: "/workspaces/\(try routerPathComponent(id))")
    }

    /// Mints an invite link. `max_uses` is omitted when 1 (the server
    /// default) so the body stays minimal; up to 100 distinct wallets may
    /// join through one link.
    func createWorkspaceInvite(
        id: String,
        role: OsaurusRouterWorkspaceRole,
        maxUses: Int = 1
    ) async throws -> OsaurusRouterWorkspaceInvite {
        struct Body: Encodable {
            let role: String
            let max_uses: Int?
        }
        return try await post(
            "/workspaces/\(try routerPathComponent(id))/invites",
            body: Body(role: role.rawValue, max_uses: maxUses > 1 ? maxUses : nil)
        )
    }

    /// Redeems an invite link (`osaurus://workspaces/join?code=…`). Wallet-signed;
    /// the first call from a new wallet also creates its router account.
    /// Idempotent: an existing member gets `200` without consuming a use.
    func workspaceJoin(code: String) async throws -> OsaurusRouterWorkspaceDetail {
        struct Body: Encodable { let code: String }
        return try await post("/workspaces/join", body: Body(code: code))
    }

    func workspaceInvites(id: String) async throws -> [OsaurusRouterWorkspaceInvite] {
        let response: OsaurusRouterWorkspaceInviteListResponse = try await get(
            "/workspaces/\(try routerPathComponent(id))/invites"
        )
        return response.data
    }

    func revokeWorkspaceInvite(id: String, inviteId: String) async throws {
        try await sendVoid(
            method: "DELETE",
            path: "/workspaces/\(try routerPathComponent(id))/invites/\(try routerPathComponent(inviteId))"
        )
    }

    func workspaceMembers(id: String) async throws -> [OsaurusRouterWorkspaceMember] {
        let response: OsaurusRouterWorkspaceMemberListResponse = try await get(
            "/workspaces/\(try routerPathComponent(id))/members"
        )
        return response.data
    }

    func setWorkspaceMemberRole(
        id: String,
        accountId: String,
        role: OsaurusRouterWorkspaceRole
    ) async throws {
        struct Body: Encodable { let role: String }
        try await sendVoid(
            method: "PATCH",
            path: "/workspaces/\(try routerPathComponent(id))/members/\(try routerPathComponent(accountId))",
            body: Body(role: role.rawValue)
        )
    }

    /// Owner/admin removal, or self-leave when `accountId` is the caller.
    func removeWorkspaceMember(id: String, accountId: String) async throws {
        try await sendVoid(
            method: "DELETE",
            path: "/workspaces/\(try routerPathComponent(id))/members/\(try routerPathComponent(accountId))"
        )
    }

    func shareWorkspaceAgent(
        id: String,
        body: OsaurusRouterWorkspaceShareAgentBody
    ) async throws -> OsaurusRouterWorkspaceAgent {
        try await post("/workspaces/\(try routerPathComponent(id))/agents", body: body)
    }

    func workspaceAgents(id: String) async throws -> [OsaurusRouterWorkspaceAgent] {
        let response: OsaurusRouterWorkspaceAgentListResponse = try await get(
            "/workspaces/\(try routerPathComponent(id))/agents"
        )
        return response.data
    }

    func unshareWorkspaceAgent(id: String, agentAddress: String) async throws {
        try await sendVoid(
            method: "DELETE",
            path: "/workspaces/\(try routerPathComponent(id))/agents/\(try routerPathComponent(agentAddress))"
        )
    }

    /// Mints a short-lived (10 min) membership attestation for the caller.
    /// Wallet-signed; any active member. `409 INVALID_STATE` when the router
    /// has no attestation key configured (feature off).
    func workspaceAttestation(id: String) async throws -> OsaurusRouterWorkspaceAttestationResponse {
        try await postEmpty("/workspaces/\(try routerPathComponent(id))/attestation")
    }

    /// The router's Ed25519 attestation verification key. Public and
    /// unsigned (like the package list); callers should cache it (≤1h).
    func workspacesAttestationKey() async throws -> OsaurusRouterWorkspaceAttestationKeyResponse {
        let url = try url(path: "/workspaces/attestation-key")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
        return try decoder.decode(OsaurusRouterWorkspaceAttestationKeyResponse.self, from: data)
    }

    /// Pool balance with its grant/purchased split and the auto-reload state
    /// (any active member).
    func workspaceBalance(id: String) async throws -> OsaurusRouterWorkspacePoolBalance {
        try await get("/workspaces/\(try routerPathComponent(id))/credits/balance")
    }

    /// One-time pool top-up (owner only): a Stripe Checkout for `amountMicro`
    /// ($5–$500, whole cents). Nothing is credited by the redirect — the
    /// webhook posts the `workspace_topup` ledger entry.
    func workspacePoolCheckout(
        id: String, amountMicro: Int64
    ) async throws -> OsaurusRouterWorkspaceTopUpCheckoutResponse {
        struct Body: Encodable { let amount_micro: String }
        return try await post(
            "/workspaces/\(try routerPathComponent(id))/credits/checkout",
            body: Body(amount_micro: String(amountMicro))
        )
    }

    /// Auto-reload settings + state (any member may read).
    func workspaceAutoReload(id: String) async throws -> OsaurusRouterWorkspaceAutoReload {
        try await get("/workspaces/\(try routerPathComponent(id))/credits/auto-reload")
    }

    /// Saves auto-reload settings (owner only). Saving clears a pause and the
    /// failure count; enabling needs an active owner subscription with a
    /// saved card (`AUTO_RELOAD_UNAVAILABLE` otherwise).
    func updateWorkspaceAutoReload(
        id: String, _ update: OsaurusRouterWorkspaceAutoReloadUpdate
    ) async throws -> OsaurusRouterWorkspaceAutoReload {
        try await send(
            method: "PUT",
            path: "/workspaces/\(try routerPathComponent(id))/credits/auto-reload",
            body: update
        )
    }

    func workspaceUsage(
        id: String,
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> OsaurusRouterUsageResponse {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await get(
            "/workspaces/\(try routerPathComponent(id))/credits/usage",
            queryItems: queryItems
        )
    }

    func workspaceTransactions(
        id: String,
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> OsaurusRouterTransactionsResponse {
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await get(
            "/workspaces/\(try routerPathComponent(id))/credits/transactions",
            queryItems: queryItems
        )
    }

    // MARK: - Cloud media

    func cloudMediaCatalog() async throws -> CloudMediaCatalogResponse {
        try await get("/v1/media/models")
    }

    func cloudGenerateImage(
        _ body: CloudImageGenerationBody
    ) async throws -> CloudImageGenerationResponse {
        try await post(
            "/v1/media/images/generations",
            body: body,
            idempotencyKey: body.idempotencyKey
        )
    }

    func cloudQuoteVideo(_ body: CloudVideoQuoteBody) async throws -> CloudVideoQuoteResponse {
        try await post("/v1/media/videos/quote", body: body)
    }

    func cloudQueueVideo(_ body: CloudVideoJobBody) async throws -> CloudVideoJobResponse {
        try await post(
            "/v1/media/videos/jobs",
            body: body,
            idempotencyKey: body.idempotencyKey
        )
    }

    func cloudVideoJob(id: String) async throws -> CloudVideoJobResponse {
        try await get("/v1/media/videos/jobs/\(try mediaJobIDPathComponent(id))")
    }

    func cloudVideoContent(jobID: String) async throws -> URL {
        let id = try mediaJobIDPathComponent(jobID)
        let url = try url(path: "/v1/media/videos/jobs/\(id)/content")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("video/mp4", forHTTPHeaderField: "Accept")
        try await sign(request: &request, body: Data())
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch {
            throw OsaurusRouterAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OsaurusRouterAPIError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let data = (try? Data(contentsOf: temporaryURL)) ?? Data()
            try ensureOK(data: data, response: response)
            throw OsaurusRouterAPIError.invalidResponse
        }
        return temporaryURL
    }

    func cloudDeleteVideoContent(jobID: String) async throws {
        let id = try mediaJobIDPathComponent(jobID)
        let url = try url(path: "/v1/media/videos/jobs/\(id)/content")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await sign(request: &request, body: Data())
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
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
        idempotencyKey: String? = nil,
        session: URLSession? = nil
    ) async throws -> T {
        try await send(
            method: "POST", path: path, body: body, idempotencyKey: idempotencyKey, session: session
        )
    }

    /// Signed JSON request with a body (POST / PUT / PATCH) that decodes the
    /// response.
    private func send<Body: Encodable, T: Decodable>(
        method: String,
        path: String,
        body: Body,
        idempotencyKey: String? = nil,
        session: URLSession? = nil
    ) async throws -> T {
        // Encode once with the canonical encoder: these exact bytes are both
        // signed (body hash binding) and sent.
        let bodyData = try JSONEncoder.osaurusCanonical(prettyPrinted: false).encode(body)
        var request = try await signedJSONRequest(method: method, path: path, body: bodyData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        let (data, response) = try await perform(request, session: session)
        try ensureOK(data: data, response: response)
        return try decoder.decode(T.self, from: data)
    }

    /// Signed request whose response body the client doesn't consume
    /// (renames, deletes, role changes, invite create/revoke/decline).
    private func sendVoid(method: String, path: String, bodyData: Data? = nil) async throws {
        let request = try await signedJSONRequest(method: method, path: path, body: bodyData)
        let (data, response) = try await perform(request)
        try ensureOK(data: data, response: response)
    }

    private func sendVoid<Body: Encodable>(method: String, path: String, body: Body) async throws {
        // Canonical encoder: these exact bytes are both signed and sent.
        let bodyData = try JSONEncoder.osaurusCanonical(prettyPrinted: false).encode(body)
        try await sendVoid(method: method, path: path, bodyData: bodyData)
    }

    /// Signed POST with an empty body (the empty string is what gets hashed
    /// into the signature) that decodes the response.
    private func postEmpty<T: Decodable>(_ path: String) async throws -> T {
        let request = try await signedJSONRequest(method: "POST", path: path, body: nil)
        let (data, response) = try await perform(request)
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

    private func mediaJobIDPathComponent(_ value: String) throws -> String {
        try routerPathComponent(value)
    }

    /// Validates a caller-supplied path segment (media job id, workspace id,
    /// invite id, account id, `0x…` agent address) so it can never smuggle
    /// separators or query syntax into a signed path.
    private func routerPathComponent(_ value: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !value.isEmpty, value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw OsaurusRouterAPIError.invalidURL
        }
        return value
    }
}
