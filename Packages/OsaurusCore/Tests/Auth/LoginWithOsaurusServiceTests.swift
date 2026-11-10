//
//  LoginWithOsaurusServiceTests.swift
//  OsaurusCoreTests
//
//  The end-to-end login flow with every system boundary faked: consent,
//  Touch ID, master-key signing, the browser, and toasts.
//

import Foundation
import LocalAuthentication
import Testing

@testable import OsaurusCore

@MainActor
final class LoginFlowRecorder {
    var opened: [URL] = []
    var errors: [String] = []
    var consentRequests: [LoginConsentRequest] = []
    var identitySetupShown = 0
    var signCalls = 0
    var authReasons: [String] = []
}

struct FakeAuthenticator: LocalAuthenticationGate {
    let outcome: @Sendable () -> LocalAuthenticationOutcome
    let onAuthenticate: @Sendable (String) async -> Void

    func authenticate(reason: String) async -> LocalAuthenticationOutcome {
        await onAuthenticate(reason)
        return outcome()
    }
}

/// Parks the consent prompt until the test answers it.
@MainActor
final class PendingConsent {
    var continuation: CheckedContinuation<LoginConsentResult, Never>?
}

@MainActor
struct LoginWithOsaurusServiceTests {
    static let callback = "https://store.osaurus.ai/auth/osaurus/callback"
    static let nonce = "n0nce-0123456789abcdef"

    static func link(
        client: String = "https://store.osaurus.ai", redirect: String = callback, nonce: String = nonce
    ) -> URL {
        var components = URLComponents(string: "osaurus://auth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "state", value: "st_8f2b1c"),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        return components.url!
    }

    let recorder = LoginFlowRecorder()
    let history = LoginWithOsaurusHistory(
        defaults: UserDefaults(suiteName: "LoginWithOsaurusServiceTests.\(UUID().uuidString)")!)

    func makeService(
        identityExists: Bool = true,
        handle: String? = "alice",
        consent: @escaping @MainActor (LoginConsentRequest) async -> LoginConsentResult = { _ in .approved },
        authOutcome: @escaping @Sendable () -> LocalAuthenticationOutcome = {
            .authenticated(AuthenticatedContext(context: LAContext()))
        },
        signFails: Bool = false
    ) -> LoginWithOsaurusService {
        let recorder = recorder
        let dependencies = LoginWithOsaurusService.Dependencies(
            clients: { .firstParty },
            identityExists: { identityExists },
            osaurusHandle: { handle },
            consent: { request in
                recorder.consentRequests.append(request)
                return await consent(request)
            },
            authenticator: FakeAuthenticator(
                outcome: authOutcome,
                onAuthenticate: { reason in await MainActor.run { recorder.authReasons.append(reason) } }),
            sign: { request, _, handle, now in
                await MainActor.run { recorder.signCalls += 1 }
                if signFails { throw OsaurusIdentityError.keychainReadFailed }
                return try LoginAssertion.sign(
                    request: request, privateKey: TestKeys.alicePrivateKey, osaurusID: handle,
                    deviceID: "a1b2c3d4", now: now)
            },
            openURL: { recorder.opened.append($0) },
            showIdentitySetup: { recorder.identitySetupShown += 1 },
            showError: { title, _ in recorder.errors.append(title) },
            now: { Date() }
        )
        return LoginWithOsaurusService(dependencies: dependencies, history: history)
    }

    static func fragmentItems(_ url: URL) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = url.fragment
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    // MARK: - Success

    @Test func successRedirectsWithAVerifiableAssertion() async throws {
        let outcome = await makeService().handle(Self.link())
        guard case .signedIn(let url) = outcome else {
            Issue.record("expected signedIn, got \(outcome)")
            return
        }
        #expect(recorder.opened == [url])
        #expect(url.absoluteString.hasPrefix(Self.callback + "#"))

        let items = Self.fragmentItems(url)
        #expect(items["state"] == "st_8f2b1c")
        let payload = try LoginAssertion.verify(
            try #require(items["assertion"]), audience: "https://store.osaurus.ai",
            redirectURI: Self.callback, nonce: Self.nonce)
        #expect(payload.iss == TestKeys.aliceAddress.lowercased())
        #expect(payload.osaurusID == "alice")

        #expect(recorder.consentRequests.first?.origin == "https://store.osaurus.ai")
        #expect(recorder.consentRequests.first?.host == "store.osaurus.ai")
        #expect(recorder.consentRequests.first?.osaurusHandle == "alice")
        #expect(recorder.authReasons.count == 1)
        #expect(recorder.signCalls == 1)

        let entry = try #require(history.entries.first)
        #expect(entry.outcome == .signedIn)
        #expect(entry.origin == "https://store.osaurus.ai")
        #expect(entry.address == TestKeys.aliceAddress.lowercased())
    }

    // MARK: - Declines

    @Test(arguments: [LoginConsentResult.denied, .timedOut])
    func declinedConsentAnswersAccessDenied(result: LoginConsentResult) async throws {
        let outcome = await makeService(consent: { _ in result }).handle(Self.link())
        guard case .answeredWithError(.accessDenied, let url) = outcome else {
            Issue.record("expected access_denied, got \(outcome)")
            return
        }
        #expect(Self.fragmentItems(url)["error"] == "access_denied")
        #expect(Self.fragmentItems(url)["state"] == "st_8f2b1c")
        #expect(recorder.authReasons.isEmpty)
        #expect(recorder.signCalls == 0)
        #expect(history.entries.first?.outcome == .cancelled)
    }

    @Test func cancelledTouchIDAnswersAccessDeniedWithoutSigning() async {
        let outcome = await makeService(authOutcome: { .cancelled }).handle(Self.link())
        guard case .answeredWithError(.accessDenied, _) = outcome else {
            Issue.record("expected access_denied, got \(outcome)")
            return
        }
        #expect(recorder.signCalls == 0)
        #expect(recorder.errors.isEmpty)
    }

    @Test func failedTouchIDAnswersAccessDeniedAndTellsTheUser() async {
        let outcome = await makeService(authOutcome: { .failed("Too many attempts") }).handle(Self.link())
        guard case .answeredWithError(.accessDenied, _) = outcome else {
            Issue.record("expected access_denied, got \(outcome)")
            return
        }
        #expect(recorder.signCalls == 0)
        #expect(recorder.errors.count == 1)
    }

    // MARK: - Errors

    @Test func missingIdentityAnswersLoginRequired() async {
        let outcome = await makeService(identityExists: false).handle(Self.link())
        guard case .answeredWithError(.loginRequired, let url) = outcome else {
            Issue.record("expected login_required, got \(outcome)")
            return
        }
        #expect(Self.fragmentItems(url)["error"] == "login_required")
        #expect(recorder.identitySetupShown == 1)
        #expect(recorder.consentRequests.isEmpty)
    }

    @Test func busyConsentAnswersTemporarilyUnavailable() async {
        let outcome = await makeService(consent: { _ in .busy }).handle(Self.link())
        guard case .answeredWithError(.temporarilyUnavailable, _) = outcome else {
            Issue.record("expected temporarily_unavailable, got \(outcome)")
            return
        }
        #expect(recorder.signCalls == 0)
    }

    @Test func secondRequestWhileOneIsPendingIsTurnedAway() async {
        let pending = PendingConsent()
        let service = makeService(consent: { _ in
            await withCheckedContinuation { pending.continuation = $0 }
        })
        let first = Task { await service.handle(Self.link()) }
        while pending.continuation == nil { await Task.yield() }

        let second = await service.handle(Self.link())
        guard case .answeredWithError(.temporarilyUnavailable, _) = second else {
            Issue.record("expected temporarily_unavailable, got \(second)")
            return
        }
        #expect(recorder.consentRequests.count == 1)

        pending.continuation?.resume(returning: .denied)
        guard case .answeredWithError(.accessDenied, _) = await first.value else {
            Issue.record("expected the first request to finish as access_denied")
            return
        }
    }

    @Test func signingFailureAnswersServerError() async {
        let outcome = await makeService(signFails: true).handle(Self.link())
        guard case .answeredWithError(.serverError, let url) = outcome else {
            Issue.record("expected server_error, got \(outcome)")
            return
        }
        #expect(Self.fragmentItems(url)["error"] == "server_error")
        #expect(recorder.errors.count == 1)
    }

    @Test func unknownWebsiteNeverOpensTheBrowser() async {
        let outcome = await makeService().handle(
            Self.link(client: "https://evil.example", redirect: "https://evil.example/cb"))
        guard case .rejectedLocally(let error) = outcome else {
            Issue.record("expected rejectedLocally, got \(outcome)")
            return
        }
        #expect(error.oauthCode == "unauthorized_client")
        #expect(recorder.opened.isEmpty)
        #expect(recorder.consentRequests.isEmpty)
        #expect(recorder.errors.count == 1)
        #expect(history.entries.isEmpty)
    }

    @Test func redirectToAnotherOriginNeverOpensTheBrowser() async {
        let outcome = await makeService().handle(Self.link(redirect: "https://evil.example/cb"))
        guard case .rejectedLocally = outcome else {
            Issue.record("expected rejectedLocally, got \(outcome)")
            return
        }
        #expect(recorder.opened.isEmpty)
    }

    @Test func badNonceIsReportedToTheWebsiteWithoutPrompting() async {
        let outcome = await makeService().handle(Self.link(nonce: "short"))
        guard case .answeredWithError(.invalidRequest, let url) = outcome else {
            Issue.record("expected invalid_request, got \(outcome)")
            return
        }
        #expect(recorder.opened == [url])
        #expect(Self.fragmentItems(url)["state"] == "st_8f2b1c")
        #expect(recorder.consentRequests.isEmpty)
    }

    // MARK: - History

    @Test func historyIsCappedAndClearable() {
        for index in 0 ..< 60 {
            history.record(
                LoginWithOsaurusHistoryEntry(
                    origin: "https://osaurus.ai", outcome: .signedIn, date: Date(timeIntervalSince1970: Double(index))))
        }
        #expect(history.entries.count == LoginWithOsaurusHistory.maxEntries)
        #expect(history.entries.first?.date == Date(timeIntervalSince1970: 59))
        history.clear()
        #expect(history.entries.isEmpty)
    }
}
