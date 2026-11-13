//
//  SourceConnection.swift
//  osaurus
//
//  An account an automation source reads from (a mail account, an API
//  token, an OAuth sign-in). Many automations share one connection; the
//  connection owns the credentials (`SourceCredentialVault`), the
//  automation only stores its id. Stored as
//  `~/.osaurus/connections/<id>.json`; secrets never touch that file.
//
//  Channels keep `AgentChannelConnection`; this is for the other sources.
//

import Foundation

/// How a connection type authenticates.
public enum SourceConnectionAuth: Equatable, Sendable {
    /// Nothing to store (a local app the OS already grants access to).
    case none
    /// Named secrets kept in the vault (API tokens, passwords).
    case secret(fields: [String])
    /// An OAuth 2 authorization-code sign-in with PKCE; tokens kept in the
    /// vault under `SourceOAuth2Service.tokenField`.
    case oauth2(SourceOAuth2ProviderProfile)
}

/// Endpoints and scopes for one OAuth 2 provider. Providers are data: a
/// profile plus a client id, signed in through `SourceOAuth2Service`.
public struct SourceOAuth2ProviderProfile: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var scopes: [String]
    public var clientId: String
    /// Extra authorize-URL parameters (`access_type=offline`, `prompt=consent`).
    public var extraAuthorizationParameters: [String: String]

    public init(
        id: String, displayName: String, authorizationEndpoint: URL, tokenEndpoint: URL, scopes: [String],
        clientId: String, extraAuthorizationParameters: [String: String] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.scopes = scopes
        self.clientId = clientId
        self.extraAuthorizationParameters = extraAuthorizationParameters
    }
}

public enum SourceConnectionType: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A provider API token sent as a bearer credential.
    case apiToken = "api_token"
    /// Accounts set up in the Mail app, read over AppleScript.
    case mailApp = "mail_app"
    /// An IMAP server, signed in with a password (an app password for
    /// providers with two-step sign-in).
    case imap

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apiToken: L("API token")
        case .mailApp: L("Mail app")
        case .imap: L("IMAP account")
        }
    }

    public var icon: String {
        switch self {
        case .apiToken: "key.fill"
        case .mailApp: "envelope.fill"
        case .imap: "server.rack"
        }
    }

    public var auth: SourceConnectionAuth {
        switch self {
        case .apiToken: .secret(fields: [SourceCredentialVault.tokenField])
        case .mailApp: .none
        case .imap: .secret(fields: [SourceCredentialVault.passwordField])
        }
    }
}

public struct MailAppConnectionConfig: Codable, Equatable, Sendable {
    /// The Mail account's name; nil = every account (the unified inbox).
    public var account: String?

    public init(account: String? = nil) {
        self.account = account?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
    }
}

public enum IMAPSecurity: String, Codable, CaseIterable, Sendable {
    /// TLS from the first byte (port 993).
    case tls
    /// No encryption: only to this Mac (a local bridge such as Proton Mail Bridge).
    case none

    public var displayName: String {
        switch self {
        case .tls: L("TLS (port 993)")
        case .none: L("None (this Mac only)")
        }
    }

    public var defaultPort: Int { self == .tls ? 993 : 143 }
}

public enum SMTPSecurity: String, Codable, CaseIterable, Sendable {
    /// TLS from the first byte (port 465). STARTTLS on 587 is not supported.
    case tls
    /// No encryption: only to this Mac (a local bridge such as Proton Mail Bridge).
    case none

    public var displayName: String {
        switch self {
        case .tls: L("TLS (port 465)")
        case .none: L("None (this Mac only)")
        }
    }

    public var defaultPort: Int { self == .tls ? 465 : 1025 }
}

public struct IMAPConnectionConfig: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var security: IMAPSecurity
    public var username: String
    /// The SMTP server replies are sent through; empty = this account only reads.
    /// Signs in with the same user name and password as IMAP.
    public var smtpHost: String
    public var smtpPort: Int
    public var smtpSecurity: SMTPSecurity
    /// The From address of replies; empty = the user name when it is an address.
    public var fromAddress: String

    public init(
        host: String = "", port: Int? = nil, security: IMAPSecurity = .tls, username: String = "",
        smtpHost: String = "", smtpPort: Int? = nil, smtpSecurity: SMTPSecurity = .tls, fromAddress: String = ""
    ) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port ?? security.defaultPort
        self.security = security
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.smtpHost = smtpHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.smtpPort = smtpPort ?? smtpSecurity.defaultPort
        self.smtpSecurity = smtpSecurity
        self.fromAddress = fromAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, security, username, smtpHost, smtpPort, smtpSecurity, fromAddress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let security = try c.decodeIfPresent(IMAPSecurity.self, forKey: .security) ?? .tls
        let smtpSecurity = try c.decodeIfPresent(SMTPSecurity.self, forKey: .smtpSecurity) ?? .tls
        self.init(
            host: try c.decodeIfPresent(String.self, forKey: .host) ?? "",
            port: try c.decodeIfPresent(Int.self, forKey: .port),
            security: security,
            username: try c.decodeIfPresent(String.self, forKey: .username) ?? "",
            smtpHost: try c.decodeIfPresent(String.self, forKey: .smtpHost) ?? "",
            smtpPort: try c.decodeIfPresent(Int.self, forKey: .smtpPort),
            smtpSecurity: smtpSecurity,
            fromAddress: try c.decodeIfPresent(String.self, forKey: .fromAddress) ?? "")
    }

    /// Plain IMAP sends the password in the clear, so it is allowed only to
    /// a server on this Mac.
    public var securityProblem: String? {
        if security == .none, !Self.isLoopback(host) {
            return L("Without TLS, only a server on this Mac can be used.")
        }
        if smtpSecurity == .none, !smtpHost.isEmpty, !Self.isLoopback(smtpHost) {
            return L("Without TLS, only an SMTP server on this Mac can be used.")
        }
        return nil
    }

    /// Whether replies can be sent from this account.
    public var canSend: Bool { !smtpHost.isEmpty && effectiveFromAddress != nil }

    public var effectiveFromAddress: String? {
        if fromAddress.contains("@") { return fromAddress }
        let user = username.lowercased()
        return user.contains("@") ? user : nil
    }

    /// The usual SMTP server for an IMAP server (`imap.gmail.com` → `smtp.gmail.com`).
    public static func suggestedSMTPHost(forIMAPHost host: String) -> String? {
        let lowered = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lowered.hasPrefix("imap.") else { return nil }
        return "smtp." + lowered.dropFirst("imap.".count)
    }

    /// Servers that only take SMTP with STARTTLS on 587.
    public var smtpNote: String? {
        let startTLSOnly = ["smtp.mail.me.com", "smtp.office365.com", "smtp-mail.outlook.com"]
        guard startTLSOnly.contains(smtpHost) else { return nil }
        return L(
            "This server only accepts STARTTLS on port 587, which Osaurus doesn't support. Add the account to the Mail app and choose Mail app to reply from it."
        )
    }

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }

    /// Microsoft 365 and Outlook.com turned off password sign-in for IMAP;
    /// they only accept OAuth, which this connection does not do.
    public var passwordSignInNote: String? {
        let microsoft = ["outlook.office365.com", "outlook.office.com", "imap-mail.outlook.com", "imap.outlook.com"]
        guard microsoft.contains(host) || host.hasSuffix(".office365.com") else { return nil }
        return L(
            "Microsoft 365 and Outlook.com don't allow password sign-in over IMAP. Add the account to the Mail app and choose Mail app here instead."
        )
    }
}

public struct APITokenConnectionConfig: Codable, Equatable, Sendable {
    /// The service the token is for (`github.com`, `api.stripe.com`).
    public var service: String

    public init(service: String = "") {
        self.service = service
    }
}

public enum SourceConnectionConfig: Equatable, Sendable {
    case apiToken(APITokenConnectionConfig)
    case mailApp(MailAppConnectionConfig)
    case imap(IMAPConnectionConfig)

    public var type: SourceConnectionType {
        switch self {
        case .apiToken: .apiToken
        case .mailApp: .mailApp
        case .imap: .imap
        }
    }

    /// One line under the connection's name.
    public var summary: String {
        switch self {
        case .apiToken(let c): c.service
        case .mailApp(let c): c.account ?? L("All Mail accounts")
        case .imap(let c): "\(c.username) · \(c.host)"
        }
    }
}

extension SourceConnectionConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, apiToken, mailApp, imap
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(SourceConnectionType.self, forKey: .type) {
        case .apiToken: self = .apiToken(try c.decode(APITokenConnectionConfig.self, forKey: .apiToken))
        case .mailApp: self = .mailApp(try c.decode(MailAppConnectionConfig.self, forKey: .mailApp))
        case .imap: self = .imap(try c.decode(IMAPConnectionConfig.self, forKey: .imap))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .apiToken(let config): try c.encode(config, forKey: .apiToken)
        case .mailApp(let config): try c.encode(config, forKey: .mailApp)
        case .imap(let config): try c.encode(config, forKey: .imap)
        }
    }
}

public struct SourceConnection: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var displayName: String
    public var config: SourceConnectionConfig
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        displayName: String,
        config: SourceConnectionConfig,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.config = config
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var type: SourceConnectionType { config.type }
}
