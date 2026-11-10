//
//  LoginWithOsaurusService.swift
//  OsaurusCore
//
//  Runs one "Log in with Osaurus" request end to end:
//
//    validate the link → identity present? → consent panel → Touch ID /
//    password → sign the assertion with the master key → open redirect_uri
//
//  Every answer, success or error, goes back through the browser to the
//  validated `redirect_uri`. Requests that can't be answered safely (unknown
//  website, bad `redirect_uri`) only show an in-app error.
//

import AppKit
import Foundation

@MainActor
public final class LoginWithOsaurusService {
    public static let shared = LoginWithOsaurusService()

    struct Dependencies {
        var clients: @MainActor () -> LoginWithOsaurusClients
        var identityExists: @MainActor () -> Bool
        var osaurusHandle: @MainActor () -> String?
        var consent: @MainActor (LoginConsentRequest) async -> LoginConsentResult
        var authenticator: any LocalAuthenticationGate
        /// Reads the master key under `context` and signs. The key never
        /// leaves this call.
        var sign:
            @Sendable (_ request: LoginWithOsaurusRequest, _ context: AuthenticatedContext, _ handle: String?, _ now: Date)
                async throws -> LoginAssertion
        var openURL: @MainActor (URL) -> Void
        var showIdentitySetup: @MainActor () -> Void
        var showError: @MainActor (_ title: String, _ message: String?) -> Void
        var now: @Sendable () -> Date

        static let live = Dependencies(
            clients: { LoginWithOsaurusClients.current() },
            identityExists: { OsaurusIdentity.existsCached() },
            osaurusHandle: { OsaurusIDService.shared.claimedHandle },
            consent: { await LoginConsentPromptService.requestConsent($0) },
            authenticator: LiveLocalAuthenticationGate(),
            sign: { request, context, handle, now in
                try await Task.detached(priority: .userInitiated) {
                    var key = try MasterKey.getPrivateKey(context: context.context)
                    defer { key.zeroOut() }
                    return try LoginAssertion.sign(
                        request: request, privateKey: key, osaurusID: handle,
                        deviceID: try? DeviceKey.currentDeviceId(), now: now)
                }.value
            },
            openURL: { NSWorkspace.shared.open($0) },
            showIdentitySetup: { AppDelegate.shared?.showManagementWindow(initialTab: .identity) },
            showError: { title, message in _ = ToastManager.shared.error(title, message: message) },
            now: { Date() }
        )
    }

    public enum Outcome: Equatable, Sendable {
        case signedIn(URL)
        /// The error was delivered to the website.
        case answeredWithError(LoginWithOsaurusError, URL)
        /// The request could not be answered safely; only the user saw it.
        case rejectedLocally(LoginWithOsaurusError)
    }

    private let dependencies: Dependencies
    private let history: LoginWithOsaurusHistory
    private var inFlight = false

    init(dependencies: Dependencies = .live, history: LoginWithOsaurusHistory = .shared) {
        self.dependencies = dependencies
        self.history = history
    }

    @discardableResult
    public func handle(_ url: URL) async -> Outcome {
        let request: LoginWithOsaurusRequest
        switch LoginWithOsaurusRequest.parse(url, clients: dependencies.clients()) {
        case .success(let parsed):
            request = parsed
        case .failure(let rejection):
            guard let reply = rejection.reply else {
                dependencies.showError(L("Sign-in request rejected"), rejection.error.detail)
                return .rejectedLocally(rejection.error)
            }
            return answer(rejection.error, target: reply, origin: nil)
        }

        guard !inFlight else {
            return answer(.temporarilyUnavailable, target: request.replyTarget, origin: request.clientID)
        }
        inFlight = true
        defer { inFlight = false }

        guard dependencies.identityExists() else {
            dependencies.showIdentitySetup()
            dependencies.showError(
                L("Set up your Osaurus identity first"),
                L("\(request.displayHost) asked you to sign in, but this Mac has no Osaurus identity yet."))
            return answer(.loginRequired, target: request.replyTarget, origin: request.clientID)
        }

        let handle = dependencies.osaurusHandle()
        let consent = await dependencies.consent(
            LoginConsentRequest(origin: request.clientID, host: request.displayHost, osaurusHandle: handle))
        switch consent {
        case .approved:
            break
        case .denied, .timedOut:
            return answer(.accessDenied, target: request.replyTarget, origin: request.clientID)
        case .busy:
            return answer(.temporarilyUnavailable, target: request.replyTarget, origin: request.clientID)
        }

        let context: AuthenticatedContext
        switch await dependencies.authenticator.authenticate(reason: L("sign in to \(request.displayHost)")) {
        case .authenticated(let authenticated):
            context = authenticated
        case .cancelled:
            return answer(.accessDenied, target: request.replyTarget, origin: request.clientID)
        case .unavailable(let reason), .failed(let reason):
            dependencies.showError(L("Couldn't verify it's you"), reason)
            return answer(.accessDenied, target: request.replyTarget, origin: request.clientID)
        }

        let assertion: LoginAssertion
        do {
            assertion = try await dependencies.sign(request, context, handle, dependencies.now())
        } catch {
            dependencies.showError(L("Couldn't sign in"), error.localizedDescription)
            return answer(
                .serverError("Osaurus could not sign the login."), target: request.replyTarget,
                origin: request.clientID)
        }

        guard let redirect = LoginWithOsaurusResponse.successURL(for: request, assertion: assertion) else {
            return .rejectedLocally(.serverError("Could not build the redirect."))
        }
        dependencies.openURL(redirect)
        history.record(
            LoginWithOsaurusHistoryEntry(
                origin: request.clientID, outcome: .signedIn, date: dependencies.now(),
                address: assertion.payload.iss))
        return .signedIn(redirect)
    }

    private func answer(_ error: LoginWithOsaurusError, target: LoginWithOsaurusReplyTarget, origin: String?)
        -> Outcome
    {
        if let origin {
            history.record(
                LoginWithOsaurusHistoryEntry(
                    origin: origin, outcome: error == .accessDenied ? .cancelled : .failed,
                    errorCode: error.oauthCode, date: dependencies.now()))
        }
        guard let url = LoginWithOsaurusResponse.errorURL(target: target, error: error) else {
            return .rejectedLocally(error)
        }
        dependencies.openURL(url)
        return .answeredWithError(error, url)
    }
}
