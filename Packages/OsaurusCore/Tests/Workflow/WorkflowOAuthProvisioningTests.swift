//
//  WorkflowOAuthProvisioningTests.swift
//  OsaurusCoreTests
//
//  The workflow OAuth sign-in as each catalog provider needs it: the fixed
//  redirect URL, cancelling a waiting sign-in, tokens without an expiry,
//  token errors inside a 2xx body, and the per-provider request shapes.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WorkflowOAuthProvisioningTests {

    private static func spec(scopes: [String] = ["read"], secret: Bool = false) -> OAuth2Spec {
        OAuth2Spec(
            authorizeURL: "https://accounts.example.com/authorize", tokenURL: "https://accounts.example.com/token",
            scopes: scopes, requiresClientSecret: secret)
    }

    private static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// Answers the browser step by sending the loopback callback the
    /// service would redirect to.
    private static func redirectBack(code: String) -> @MainActor (URL) async -> Bool {
        { url in
            let state = query(url, "state") ?? ""
            let callback = URL(string: "\(OAuth2ConnectionFlow.redirectURL)?code=\(code)&state=\(state)")!
            Task.detached { _ = try? await URLSession.shared.data(from: callback) }
            return true
        }
    }

    // MARK: - Token responses

    @Test func parseTokenResponse_surfacesErrorsInsideA2xxBody() {
        #expect(throws: MCPOAuthError.self) {
            _ = try MCPOAuthService.parseTokenResponse(Data(#"{"ok":false,"error":"invalid_code"}"#.utf8))
        }
        do {
            _ = try MCPOAuthService.parseTokenResponse(
                Data(#"{"error":"bad_verification_code","error_description":"The code passed is incorrect."}"#.utf8))
            Issue.record("expected a token error")
        } catch let MCPOAuthError.tokenError(error, description) {
            #expect(error == "bad_verification_code")
            #expect(description == "The code passed is incorrect.")
            #expect(MCPOAuthError.tokenError(error: error, description: description).errorDescription?.contains(error) == true)
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(throws: MCPOAuthError.self) {
            _ = try MCPOAuthService.parseTokenResponse(Data(#"{"ok":false}"#.utf8))
        }
        #expect(MCPOAuthService.isPermanentAuthFailure(MCPOAuthError.tokenError(error: "invalid_grant", description: nil)))
        #expect(!MCPOAuthService.isPermanentAuthFailure(MCPOAuthError.tokenError(error: "invalid_code", description: nil)))
    }

    @Test func parseTokenResponse_keepsWhetherAnExpiryWasStated() throws {
        let slack = try MCPOAuthService.parseTokenResponse(
            Data(#"{"ok":true,"access_token":"xoxb-1","token_type":"bot","scope":"chat:write"}"#.utf8))
        #expect(slack.accessToken == "xoxb-1")
        #expect(slack.expiresIn == nil)
        #expect(OAuth2ConnectionFlow.expiry(of: slack) == nil, "a token with no stated expiry does not expire")
        // MCP keeps its one-hour default.
        #expect(slack.expiresAt > Date().addingTimeInterval(3500))

        let linear = try MCPOAuthService.parseTokenResponse(
            Data(#"{"access_token":"lin","expires_in":86399,"refresh_token":"r"}"#.utf8))
        #expect(linear.expiresIn == 86399)
        let expiry = try #require(OAuth2ConnectionFlow.expiry(of: linear))
        #expect(abs(expiry.timeIntervalSinceNow - 86399) < 5)
    }

    // MARK: - Request shapes

    @Test func authorizationURL_usesTheFixedRedirectAndTheSpecsScopeSeparator() throws {
        let slack = try #require(ConnectionProviders.provider(id: "slack")?.oauth2)
        let url = OAuth2ConnectionFlow.authorizationURL(spec: slack, clientID: "123.456", codeChallenge: "c", state: "s")
        #expect(Self.query(url, "redirect_uri") == "http://127.0.0.1:47823/callback")
        #expect(Self.query(url, "scope") == "channels:read,chat:write")
        #expect(Self.query(url, "client_id") == "123.456")
        #expect(Self.query(url, "code_challenge_method") == "S256")

        let google = OAuth2Spec(
            authorizeURL: "https://accounts.google.com/o/oauth2/v2/auth", tokenURL: "https://oauth2.googleapis.com/token",
            scopes: ["openid", "email"], authorizeParameters: ["access_type": "offline"])
        let googleURL = OAuth2ConnectionFlow.authorizationURL(spec: google, clientID: "g", codeChallenge: "c", state: "s")
        #expect(Self.query(googleURL, "scope") == "openid email")
        #expect(Self.query(googleURL, "access_type") == "offline")
        #expect(URLComponents(url: googleURL, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "scope" }.count == 1)
    }

    @Test func tokenRequest_sendsNotionsSecretAsBasicAuthWithAJSONBody() throws {
        let notion = try #require(ConnectionProviders.provider(id: "notion")?.oauth2)
        let form = ["grant_type": "authorization_code", "code": "abc", "redirect_uri": OAuth2ConnectionFlow.redirectURL]
        let request = OAuth2ConnectionFlow.tokenURLRequest(
            spec: notion, url: URL(string: notion.tokenURL)!, form: form, clientID: "id", clientSecret: "shh")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let basic = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(basic == "Basic " + Data("id:shh".utf8).base64EncodedString())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["code"] == "abc")
        #expect(json["redirect_uri"] == "http://127.0.0.1:47823/callback")
        #expect(json["client_secret"] == nil)

        let slack = try #require(ConnectionProviders.provider(id: "slack")?.oauth2)
        let slackRequest = OAuth2ConnectionFlow.tokenURLRequest(
            spec: slack, url: URL(string: slack.tokenURL)!, form: form, clientID: "id", clientSecret: "shh")
        #expect(slackRequest.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(slackRequest.value(forHTTPHeaderField: "Authorization") == nil)
        let slackBody = String(decoding: slackRequest.httpBody ?? Data(), as: UTF8.self)
        #expect(slackBody.contains("client_secret=shh"))
    }

    @Test func oauth2Spec_roundTripsTheProviderRequestFields_andOldTemplatesDecode() throws {
        let notion = try #require(ConnectionProviders.provider(id: "notion")?.oauth2)
        let decoded = try JSONDecoder().decode(OAuth2Spec.self, from: JSONEncoder().encode(notion))
        #expect(decoded == notion)
        #expect(decoded.clientSecretBasic && decoded.jsonTokenBody)

        let old = try JSONDecoder().decode(
            OAuth2Spec.self, from: Data(#"{"authorize_url":"https://a.example/x","token_url":"https://a.example/t"}"#.utf8))
        #expect(old.scopeSeparator == " ")
        #expect(!old.clientSecretBasic && !old.jsonTokenBody)
    }

    // MARK: - Catalog

    @Test func everyCatalogSignInSaysWhichRedirectURLToRegister() {
        for provider in ConnectionProviders.all where provider.oauth2 != nil {
            let help = provider.oauthHelp ?? ""
            #expect(!help.isEmpty, "\(provider.id) has no app setup steps")
            #expect(provider.appSetupURL != nil, "\(provider.id) has no developer settings link")
            if provider.id != "google" {
                #expect(help.contains(OAuth2ConnectionFlow.redirectURL), "\(provider.id) help omits the redirect URL")
            }
        }
    }

    @Test func declareConnection_refusesGoogleWithoutScopes() throws {
        #expect(throws: WorkflowDraftOp.ParseError.self) {
            try WorkflowDraftOp.parse(.object(["op": .string("declare_connection"), "provider": .string("google")]))
        }
        _ = try WorkflowDraftOp.parse(
            .object([
                "op": .string("declare_connection"), "provider": .string("google"),
                "scopes": .array([.string("https://www.googleapis.com/auth/gmail.readonly")]),
            ]))
    }

    // MARK: - Stored connections

    @Test func clearingDefaultExpiry_onlyClearsTheOneHourTheOldParserInvented() {
        var fake = WorkflowConnection(name: "Slack", service: "slack.com", kind: .oauth2, oauth2: Self.spec())
        fake.expiresAt = fake.createdAt.addingTimeInterval(3600.4)
        #expect(WorkflowConnectionStore.clearingDefaultExpiry(fake).expiresAt == nil)

        var resigned = fake
        resigned.updatedAt = fake.createdAt.addingTimeInterval(86400)
        resigned.expiresAt = resigned.updatedAt.addingTimeInterval(3601)
        #expect(WorkflowConnectionStore.clearingDefaultExpiry(resigned).expiresAt == nil, "re-signed in later")

        var stated = fake
        stated.expiresAt = fake.createdAt.addingTimeInterval(7200)
        #expect(WorkflowConnectionStore.clearingDefaultExpiry(stated).expiresAt == stated.expiresAt)

        var refreshable = fake
        refreshable.canRefresh = true
        #expect(WorkflowConnectionStore.clearingDefaultExpiry(refreshable).expiresAt == fake.expiresAt)

        let pasted = WorkflowConnection(name: "Key", kind: .value)
        #expect(WorkflowConnectionStore.clearingDefaultExpiry(pasted) == pasted)
    }

    @Test func reload_repairsAndPersistsFakeExpiries() throws {
        let store = WorkflowConnectionStore.shared
        store.resetForTesting()
        defer { store.resetForTesting() }
        var fake = WorkflowConnection(name: "Slack", service: "slack.com", kind: .oauth2, oauth2: Self.spec())
        fake.expiresAt = fake.createdAt.addingTimeInterval(3600)
        store.upsert(fake)
        store.reload()
        let repaired = try #require(store.connection(id: fake.id))
        #expect(repaired.expiresAt == nil)
        #expect(!repaired.needsSignIn(now: Date().addingTimeInterval(7200)))
        store.reload()
        #expect(store.connection(id: fake.id)?.expiresAt == nil, "the repair was saved")
    }

    // MARK: - Sign-in flow

    @Test func signIn_storesNoExpiryForATokenThatStatesNone() async throws {
        let store = WorkflowConnectionStore.shared
        store.resetForTesting()
        defer {
            store.resetForTesting()
            OAuth2ConnectionFlow.openBrowserOverride = nil
            MCPOAuthService.tokenRequestOverride = nil
        }
        nonisolated(unsafe) var sentForm: [String: String] = [:]
        MCPOAuthService.tokenRequestOverride = { _, form in
            sentForm = form
            return try MCPOAuthService.parseTokenResponse(Data(#"{"ok":true,"access_token":"xoxb-live"}"#.utf8))
        }
        OAuth2ConnectionFlow.openBrowserOverride = Self.redirectBack(code: "the-code")

        let connection = try await OAuth2ConnectionFlow.signIn(
            spec: Self.spec(secret: true), name: "Slack", clientID: "client", clientSecret: "secret")
        #expect(connection.expiresAt == nil)
        #expect(!connection.canRefresh)
        #expect(!connection.needsSignIn(now: Date().addingTimeInterval(86400)))
        #expect(sentForm["code"] == "the-code")
        #expect(sentForm["redirect_uri"] == OAuth2ConnectionFlow.redirectURL)
        #expect(sentForm["client_secret"] == "secret")
    }

    @Test func signIn_cancelledWhileWaiting_throwsCancellation_andFreesThePort() async throws {
        defer { OAuth2ConnectionFlow.openBrowserOverride = nil }
        OAuth2ConnectionFlow.openBrowserOverride = { _ in true }
        let task = Task { @MainActor in
            try await OAuth2ConnectionFlow.signIn(spec: Self.spec(), name: "Waits", clientID: "client")
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.result
        switch result {
        case .success: Issue.record("a cancelled sign-in must not succeed")
        case .failure(let error): #expect(error is CancellationError, "got \(error)")
        }

        // The port is free for the next sign-in right away.
        OAuth2ConnectionFlow.openBrowserOverride = { _ in true }
        let next = Task { @MainActor in
            try await OAuth2ConnectionFlow.signIn(spec: Self.spec(), name: "Next", clientID: "client")
        }
        try await Task.sleep(for: .milliseconds(300))
        next.cancel()
        if case .failure(let error) = await next.result {
            #expect(error is CancellationError, "the second sign-in could not bind: \(error)")
        }
    }

    @Test func signIn_whileAnotherSignInWaits_failsAsPortBusy() async throws {
        defer { OAuth2ConnectionFlow.openBrowserOverride = nil }
        OAuth2ConnectionFlow.openBrowserOverride = { _ in true }
        let first = Task { @MainActor in
            try await OAuth2ConnectionFlow.signIn(spec: Self.spec(), name: "First", clientID: "client")
        }
        defer { first.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        do {
            _ = try await OAuth2ConnectionFlow.signIn(spec: Self.spec(), name: "Second", clientID: "client")
            Issue.record("expected portBusy")
        } catch OAuth2ConnectionFlow.Failure.portBusy {
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test(arguments: [false, true])
    func signIn_whenAnotherListenerHoldsThePort_failsAsPortBusy(holderReuses: Bool) async throws {
        let holder = try OAuthLoopbackServer(
            expectedState: "other", port: .fixed(OAuth2ConnectionFlow.redirectPort), reuseAddress: holderReuses)
        try await holder.start()
        defer { holder.stop() }
        defer { OAuth2ConnectionFlow.openBrowserOverride = nil }
        nonisolated(unsafe) var opened = false
        OAuth2ConnectionFlow.openBrowserOverride = { _ in
            opened = true
            return true
        }
        do {
            _ = try await OAuth2ConnectionFlow.signIn(spec: Self.spec(), name: "Blocked", clientID: "client")
            Issue.record("expected portBusy")
        } catch OAuth2ConnectionFlow.Failure.portBusy {
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(!opened, "the browser must not open when the redirect can't be caught")
    }
}
