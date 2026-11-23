//
//  LoginWithOsaurusRequestTests.swift
//  OsaurusCoreTests
//
//  Parsing and validation of `osaurus://auth/authorize` links: which
//  requests are accepted, and which rejections may be reported back to the
//  website versus shown only in the app.
//

import Foundation
import Testing

@testable import OsaurusCore

struct LoginWithOsaurusRequestTests {
    static let clients = LoginWithOsaurusClients.firstParty
    static let callback = "https://store.osaurus.ai/auth/osaurus/callback"
    static let nonce = "n0nce-0123456789abcdef"

    static func link(_ params: [(String, String)]) -> URL {
        var components = URLComponents(string: "osaurus://auth/authorize")!
        components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    static func validParams(
        client: String = "https://store.osaurus.ai",
        redirect: String = callback,
        state: String = "st_8f2b1c",
        nonce: String = nonce
    ) -> [(String, String)] {
        [("client_id", client), ("redirect_uri", redirect), ("state", state), ("nonce", nonce)]
    }

    static func rejection(_ url: URL, clients: LoginWithOsaurusClients = clients) -> LoginWithOsaurusRejection? {
        if case .failure(let rejection) = LoginWithOsaurusRequest.parse(url, clients: clients) { return rejection }
        return nil
    }

    @Test func parsesAValidRequestWithFragmentDefault() throws {
        let request = try LoginWithOsaurusRequest.parse(Self.link(Self.validParams()), clients: Self.clients).get()
        #expect(request.clientID == "https://store.osaurus.ai")
        #expect(request.redirectURI.absoluteString == Self.callback)
        #expect(request.state == "st_8f2b1c")
        #expect(request.nonce == Self.nonce)
        #expect(request.responseMode == .fragment)
        #expect(request.displayHost == "store.osaurus.ai")
    }

    @Test func acceptsQueryResponseMode() throws {
        let url = Self.link(Self.validParams() + [("response_mode", "query")])
        #expect(try LoginWithOsaurusRequest.parse(url, clients: Self.clients).get().responseMode == .query)
    }

    @Test func canonicalizesCaseAndDefaultPort() throws {
        let url = Self.link(
            Self.validParams(
                client: "HTTPS://Store.Osaurus.AI:443/",
                redirect: "https://store.osaurus.ai:443/auth/osaurus/callback"))
        let request = try LoginWithOsaurusRequest.parse(url, clients: Self.clients).get()
        #expect(request.clientID == "https://store.osaurus.ai")
    }

    @Test func unknownClientIsRejectedWithoutReply() throws {
        let url = Self.link(Self.validParams(client: "https://evil.example", redirect: "https://evil.example/cb"))
        let rejection = try #require(Self.rejection(url))
        #expect(rejection.error.oauthCode == "unauthorized_client")
        #expect(rejection.reply == nil)
    }

    @Test func lookalikeSubdomainIsNotAllowed() throws {
        let url = Self.link(
            Self.validParams(
                client: "https://store.osaurus.ai.evil.example",
                redirect: "https://store.osaurus.ai.evil.example/cb"))
        #expect(try #require(Self.rejection(url)).error.oauthCode == "unauthorized_client")
    }

    @Test(arguments: [
        "http://store.osaurus.ai",
        "https://store.osaurus.ai/app",
        "https://store.osaurus.ai?x=1",
        "https://user@store.osaurus.ai",
        "store.osaurus.ai",
        "",
    ])
    func malformedClientIDIsRejectedWithoutReply(client: String) throws {
        let rejection = try #require(Self.rejection(Self.link(Self.validParams(client: client))))
        #expect(rejection.error.oauthCode == "invalid_request")
        #expect(rejection.reply == nil)
    }

    @Test(arguments: [
        "https://osaurus.ai/auth/osaurus/callback",
        "https://evil.example/cb",
        "http://store.osaurus.ai/cb",
        "https://store.osaurus.ai:8443/cb",
        "https://store.osaurus.ai/cb#frag",
        "https://attacker@store.osaurus.ai/cb",
        "/auth/osaurus/callback",
    ])
    func redirectOffTheClientOriginIsRejectedWithoutReply(redirect: String) throws {
        let rejection = try #require(Self.rejection(Self.link(Self.validParams(redirect: redirect))))
        #expect(rejection.error.oauthCode == "invalid_request")
        #expect(rejection.reply == nil)
    }

    @Test func redirectMayCarryItsOwnQuery() throws {
        let url = Self.link(Self.validParams(redirect: Self.callback + "?next=%2Fme"))
        let request = try LoginWithOsaurusRequest.parse(url, clients: Self.clients).get()
        #expect(request.redirectURI.query == "next=%2Fme")
    }

    @Test func repeatedParameterIsRejectedWithoutReply() throws {
        let url = Self.link(Self.validParams() + [("redirect_uri", "https://store.osaurus.ai/other")])
        let rejection = try #require(Self.rejection(url))
        #expect(rejection.error.oauthCode == "invalid_request")
        #expect(rejection.reply == nil)
    }

    @Test func badResponseModeIsReportedWithoutState() throws {
        let rejection = try #require(Self.rejection(Self.link(Self.validParams() + [("response_mode", "form_post")])))
        #expect(rejection.error.oauthCode == "invalid_request")
        #expect(rejection.reply?.state == nil)
        #expect(rejection.reply?.responseMode == .fragment)
        #expect(rejection.reply?.redirectURI.absoluteString == Self.callback)
    }

    @Test(arguments: ["", "has space", "semi;colon", String(repeating: "a", count: 513), "émoji"])
    func badStateIsReportedWithoutEchoingIt(state: String) throws {
        let rejection = try #require(Self.rejection(Self.link(Self.validParams(state: state))))
        #expect(rejection.error.oauthCode == "invalid_request")
        #expect(rejection.reply != nil)
        #expect(rejection.reply?.state == nil)
    }

    @Test(arguments: ["short", "has space here and more", "bad/slash-0123456789", String(repeating: "n", count: 129)])
    func badNonceIsReportedWithState(nonce: String) throws {
        let rejection = try #require(Self.rejection(Self.link(Self.validParams(nonce: nonce))))
        #expect(rejection.error.oauthCode == "invalid_request")
        #expect(rejection.reply?.state == "st_8f2b1c")
    }

    @Test func missingNonceIsReportedWithState() throws {
        let params = Self.validParams().filter { $0.0 != "nonce" }
        #expect(try #require(Self.rejection(Self.link(params))).reply?.state == "st_8f2b1c")
    }

    @Test func wrongPathIsRejected() throws {
        let url = URL(string: "osaurus://auth/token?client_id=https://store.osaurus.ai")!
        #expect(LoginWithOsaurusRequest.claims(url))
        #expect(try #require(Self.rejection(url)).reply == nil)
    }

    @Test func claimsOnlyTheAuthHost() {
        #expect(LoginWithOsaurusRequest.claims(URL(string: "osaurus://auth/authorize")!))
        #expect(LoginWithOsaurusRequest.claims(URL(string: "OSAURUS://AUTH/authorize")!))
        #expect(!LoginWithOsaurusRequest.claims(URL(string: "osaurus://0xabc?pair=x")!))
        #expect(!LoginWithOsaurusRequest.claims(URL(string: "https://auth/authorize")!))
    }

    @Test func errorCodesMatchOAuth() {
        #expect(LoginWithOsaurusError.invalidRequest("x").oauthCode == "invalid_request")
        #expect(LoginWithOsaurusError.unauthorizedClient("x").oauthCode == "unauthorized_client")
        #expect(LoginWithOsaurusError.accessDenied.oauthCode == "access_denied")
        #expect(LoginWithOsaurusError.loginRequired.oauthCode == "login_required")
        #expect(LoginWithOsaurusError.temporarilyUnavailable.oauthCode == "temporarily_unavailable")
        #expect(LoginWithOsaurusError.serverError("x").oauthCode == "server_error")
    }

    // MARK: - Clients

    @Test func loopbackHTTPNeedsTheFlagAndAnEntry() throws {
        let dev = LoginWithOsaurusClients(origins: ["http://localhost:3000"], allowsLoopbackHTTP: true)
        let url = Self.link(
            Self.validParams(client: "http://localhost:3000", redirect: "http://localhost:3000/callback"))
        #expect(try LoginWithOsaurusRequest.parse(url, clients: dev).get().clientID == "http://localhost:3000")

        // Same origin, flag off (release behavior).
        let release = LoginWithOsaurusClients(origins: ["http://localhost:3000"], allowsLoopbackHTTP: false)
        #expect(release.origins.isEmpty)
        #expect(try #require(Self.rejection(url, clients: release)).reply == nil)

        // Flag on, different port not listed.
        let other = Self.link(Self.validParams(client: "http://localhost:4000", redirect: "http://localhost:4000/cb"))
        #expect(try #require(Self.rejection(other, clients: dev)).error.oauthCode == "unauthorized_client")
    }

    @Test func plainHTTPIsNeverAllowedForRemoteHosts() {
        let clients = LoginWithOsaurusClients(origins: ["http://example.com"], allowsLoopbackHTTP: true)
        #expect(clients.origins.isEmpty)
    }

    @Test func firstPartyListIsExact() {
        #expect(
            LoginWithOsaurusClients.firstParty.origins == [
                "https://store.osaurus.ai", "https://osaurus.ai", "https://www.osaurus.ai",
            ])
    }

    #if DEBUG
        @Test func debugOverrideAddsOriginsFromDefaults() throws {
            let defaults = try #require(UserDefaults(suiteName: "LoginWithOsaurusRequestTests.\(UUID().uuidString)"))
            defaults.set(
                "https://workflows-registry.vercel.app, http://localhost:3000, http://evil.example",
                forKey: LoginWithOsaurusClients.extraOriginsDefaultsKey)
            let clients = LoginWithOsaurusClients.current(defaults: defaults)
            #expect(clients.allows("https://workflows-registry.vercel.app"))
            #expect(clients.allows("http://localhost:3000"))
            #expect(!clients.allows("http://evil.example"))
            #expect(clients.allows("https://store.osaurus.ai"))

            defaults.set(["https://staging.osaurus.ai"], forKey: LoginWithOsaurusClients.extraOriginsDefaultsKey)
            #expect(LoginWithOsaurusClients.current(defaults: defaults).allows("https://staging.osaurus.ai"))
        }
    #endif
}
