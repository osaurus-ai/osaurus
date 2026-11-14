//
//  MailboxFetching.swift
//  osaurus
//
//  What an email source needs from an account: its mailboxes, the mail
//  that arrived after a cursor, and the newest message (for Run Now). The
//  cursor is the fetcher's own JSON; `EmailEventSource` stores it per
//  connection + mailbox in `event_source_state` and never reads it.
//

import Foundation

struct MailboxFetchOptions: Equatable, Sendable {
    /// Every automation on the mailbox wants unread mail only.
    var unreadOnly = false
    /// Some automation on the mailbox wants the body.
    var includeBody = true
    /// Messages per check; the rest wait for the next one.
    var limit = 50

    static let defaultLimit = 50
}

struct MailboxFetchResult: Sendable {
    /// Oldest first.
    var messages: [EmailMessage]
    var cursor: JSONValue
    /// Where the cursor stands, for the detail ("UID 4120", a date).
    var position: String?
}

protocol MailboxFetching: Sendable {
    /// Mailbox paths as the account names them.
    func mailboxes() async throws -> [String]
    /// Mail after `cursor`. With no cursor nothing is returned: the cursor
    /// is set to the newest message so a new automation starts from now.
    func fetch(mailbox: String, cursor: JSONValue?, options: MailboxFetchOptions) async throws -> MailboxFetchResult
    /// The newest message, for Run Now and trigger-value examples.
    func newest(mailbox: String, options: MailboxFetchOptions) async throws -> EmailMessage?
}

enum EmailFetchError: LocalizedError, Equatable {
    case mailNotRunning
    /// macOS refused to let Osaurus control Mail (AppleScript -1743).
    case automationDenied
    /// Any other failure Mail reported.
    case mailApp(String)
    case accountMissing
    case passwordMissing
    case insecureConnection(String)
    case loginRefused(String)
    case loginDisabled
    case mailboxNotFound(String)
    case server(String)
    case connection(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .mailNotRunning: L("Mail isn't open. Open Mail to check this account.")
        case .automationDenied:
            L(
                "Osaurus isn't allowed to control Mail. Turn on Mail for Osaurus in System Settings → Privacy & Security → Automation."
            )
        case .mailApp(let detail): L("Mail reported a problem: \(detail)")
        case .accountMissing: L("The account this automation reads from was removed.")
        case .passwordMissing: L("No password is saved for this account. Edit the account and enter it again.")
        case .insecureConnection(let reason): reason
        case .loginRefused(let detail): L("The server refused the sign-in: \(detail)")
        case .loginDisabled:
            L("The server only allows sign-in after STARTTLS, which Osaurus doesn't support. Use TLS on port 993.")
        case .mailboxNotFound(let name): L("No mailbox named \(name) on this account.")
        case .server(let detail): L("The mail server answered: \(detail)")
        case .connection(let detail): L("Could not reach the mail server: \(detail)")
        case .timedOut: L("The mail server stopped answering.")
        }
    }

    /// Worth showing as the source's problem but not a reason to back off
    /// harder than a normal failure.
    var isWaitingOnTheUser: Bool {
        switch self {
        case .mailNotRunning, .automationDenied, .accountMissing: true
        default: false
        }
    }

    /// The account itself is wrong. Signing in again with the same details
    /// would fail the same way, and repeated refused sign-ins can get an
    /// account locked, so checks stop until the account is edited.
    var haltsChecks: Bool {
        switch self {
        case .passwordMissing, .insecureConnection, .loginRefused, .loginDisabled: true
        default: false
        }
    }
}

/// Picks the fetcher for a connection.
enum MailboxFetcherFactory {
    static func fetcher(for connection: SourceConnection) -> (any MailboxFetching)? {
        switch connection.config {
        case .mailApp(let config): MailAppMailboxFetcher(account: config.account)
        case .imap(let config): IMAPMailboxFetcher(connectionId: connection.id, config: config)
        case .apiToken: nil
        }
    }
}
