//
//  LoginConsentPromptService.swift
//  OsaurusCore
//
//  The "Sign in to <site>?" panel shown before a website receives a login
//  assertion. Panel mechanics (one prompt at a time; auto-deny;
//  close = Cancel) live in `ConsentPanelPresenter`.
//

import AppKit
import Foundation

public struct LoginConsentRequest: Equatable, Sendable {
    /// Canonical origin (`https://store.osaurus.ai`).
    public let origin: String
    public let host: String
    /// The claimed Osaurus ID (no `@`), when this Mac knows it.
    public let osaurusHandle: String?
}

public enum LoginConsentResult: Equatable, Sendable {
    case approved
    case denied
    case timedOut
    /// Another consent panel is already on screen.
    case busy
}

@MainActor
enum LoginConsentPromptService {
    static func requestConsent(_ request: LoginConsentRequest) async -> LoginConsentResult {
        let result = await ConsentPanelPresenter.present(
            minSize: NSSize(width: 400, height: 320), confirmsOnReturn: true
        ) { approve, cancel in
            LoginConsentView(request: request, onContinue: approve, onCancel: cancel)
        }
        switch result {
        case .approved: return .approved
        case .denied: return .denied
        case .timedOut: return .timedOut
        case .busy: return .busy
        }
    }
}
