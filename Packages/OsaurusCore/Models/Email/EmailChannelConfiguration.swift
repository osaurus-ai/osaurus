//
//  EmailChannelConfiguration.swift
//  osaurus
//
//  Non-secret configuration for the native Email channel.
//
//  The channel reads the mail accounts kept as `SourceConnection`s (a Mail
//  app account, or an IMAP server with an optional SMTP server for
//  replies). Each watched account is its own channel connection and lists
//  its mailboxes; a mailbox is a room (`<connection id>/<mailbox>`), a mail
//  thread is a thread. Who may reach an agent is the account's sender
//  allowlist (addresses or `@domain`), default deny. Receive and sending
//  start off.
//

import Foundation

struct EmailChannelAccount: Codable, Equatable, Sendable, Identifiable {
    /// The `SourceConnection` the mail is read from (and replied through).
    var connectionId: String
    /// The channel connection this account is: `email` for the first one,
    /// `email-<mail account id>` for the others. Assigned by
    /// `EmailChannelConfiguration` when empty.
    var channelConnectionId: String
    /// Shown on its Channels card; the mail account's name when empty.
    var name: String
    /// Mailbox paths as the account names them; empty = the inbox.
    var mailboxes: [String]
    var pollIntervalSeconds: Int
    var unreadOnly: Bool
    /// Pass the message text to the agent; off, only subject, sender and a preview.
    var includeBody: Bool
    var maxBodyChars: Int
    /// What the first check after a relaunch does with mail that arrived
    /// while the app was closed.
    var catchUp: SourceCatchUpPolicy
    /// Addresses (`alex@example.com`) or domains (`@example.com`) whose mail
    /// may reach an agent. Empty means receive stays off.
    var senderAllowlist: [String]
    /// Receive gate: the account's mailboxes are only checked when on.
    var receiveEnabled: Bool
    /// Replies may be sent (Mail app or SMTP). Off, nothing leaves this Mac.
    var writeEnabled: Bool
    /// When a reply is not sent automatically, open it as a draft in Mail
    /// (Mail app accounts) for review.
    var draftUnsentReplies: Bool
    var defaultReadLimit: Int
    /// Decoded from a file written when these settings were shared by every
    /// account; `EmailChannelConfiguration` fills them from the old values.
    fileprivate var inheritsSharedSettings = false

    var id: String { connectionId }

    /// Channel messages reach the agent through the remote safety gate,
    /// which keeps the first 8,000 characters; a longer body limit would
    /// only promise text the agent never sees.
    static let maxBodyCharsRange = 500...8_000
    static let defaultMaxBodyChars = 8_000

    init(
        connectionId: String,
        channelConnectionId: String = "",
        name: String = "",
        mailboxes: [String] = [],
        pollIntervalSeconds: Int = EmailSourceConfig.defaultPollIntervalSeconds,
        unreadOnly: Bool = false,
        includeBody: Bool = true,
        maxBodyChars: Int = EmailChannelAccount.defaultMaxBodyChars,
        catchUp: SourceCatchUpPolicy = .sinceCursor,
        senderAllowlist: [String] = [],
        receiveEnabled: Bool = false,
        writeEnabled: Bool = false,
        draftUnsentReplies: Bool = true,
        defaultReadLimit: Int = 25
    ) {
        self.connectionId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.channelConnectionId = channelConnectionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mailboxes = ChannelMessageSourceConfig.normalizedRooms(mailboxes)
        self.pollIntervalSeconds = min(
            max(pollIntervalSeconds, EmailSourceConfig.pollIntervalRange.lowerBound),
            EmailSourceConfig.pollIntervalRange.upperBound)
        self.unreadOnly = unreadOnly
        self.includeBody = includeBody
        self.maxBodyChars = min(
            max(maxBodyChars, Self.maxBodyCharsRange.lowerBound), Self.maxBodyCharsRange.upperBound)
        self.catchUp = catchUp
        self.senderAllowlist = EmailChannelConfiguration.normalizedSenders(senderAllowlist)
        self.receiveEnabled = receiveEnabled
        self.writeEnabled = writeEnabled
        self.draftUnsentReplies = draftUnsentReplies
        self.defaultReadLimit = EmailChannelConfiguration.clampReadLimit(defaultReadLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case connectionId, channelConnectionId, name, mailboxes, pollIntervalSeconds, unreadOnly, includeBody,
            maxBodyChars, catchUp, senderAllowlist, receiveEnabled, writeEnabled, draftUnsentReplies,
            defaultReadLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            connectionId: try c.decode(String.self, forKey: .connectionId),
            channelConnectionId: try c.decodeIfPresent(String.self, forKey: .channelConnectionId) ?? "",
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            mailboxes: try c.decodeIfPresent([String].self, forKey: .mailboxes) ?? [],
            pollIntervalSeconds: try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds)
                ?? EmailSourceConfig.defaultPollIntervalSeconds,
            unreadOnly: try c.decodeIfPresent(Bool.self, forKey: .unreadOnly) ?? false,
            includeBody: try c.decodeIfPresent(Bool.self, forKey: .includeBody) ?? true,
            maxBodyChars: try c.decodeIfPresent(Int.self, forKey: .maxBodyChars) ?? Self.defaultMaxBodyChars,
            catchUp: try c.decodeIfPresent(SourceCatchUpPolicy.self, forKey: .catchUp) ?? .sinceCursor,
            senderAllowlist: try c.decodeIfPresent([String].self, forKey: .senderAllowlist) ?? [],
            receiveEnabled: try c.decodeIfPresent(Bool.self, forKey: .receiveEnabled) ?? false,
            writeEnabled: try c.decodeIfPresent(Bool.self, forKey: .writeEnabled) ?? false,
            draftUnsentReplies: try c.decodeIfPresent(Bool.self, forKey: .draftUnsentReplies) ?? true,
            defaultReadLimit: try c.decodeIfPresent(Int.self, forKey: .defaultReadLimit) ?? 25)
        inheritsSharedSettings = !c.contains(.receiveEnabled)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(connectionId, forKey: .connectionId)
        try c.encode(channelConnectionId, forKey: .channelConnectionId)
        try c.encode(name, forKey: .name)
        try c.encode(mailboxes, forKey: .mailboxes)
        try c.encode(pollIntervalSeconds, forKey: .pollIntervalSeconds)
        try c.encode(unreadOnly, forKey: .unreadOnly)
        try c.encode(includeBody, forKey: .includeBody)
        try c.encode(maxBodyChars, forKey: .maxBodyChars)
        try c.encode(catchUp, forKey: .catchUp)
        try c.encode(senderAllowlist, forKey: .senderAllowlist)
        try c.encode(receiveEnabled, forKey: .receiveEnabled)
        try c.encode(writeEnabled, forKey: .writeEnabled)
        try c.encode(draftUnsentReplies, forKey: .draftUnsentReplies)
        try c.encode(defaultReadLimit, forKey: .defaultReadLimit)
    }

    static func == (lhs: EmailChannelAccount, rhs: EmailChannelAccount) -> Bool {
        lhs.connectionId == rhs.connectionId && lhs.channelConnectionId == rhs.channelConnectionId
            && lhs.name == rhs.name && lhs.mailboxes == rhs.mailboxes
            && lhs.pollIntervalSeconds == rhs.pollIntervalSeconds && lhs.unreadOnly == rhs.unreadOnly
            && lhs.includeBody == rhs.includeBody && lhs.maxBodyChars == rhs.maxBodyChars
            && lhs.catchUp == rhs.catchUp && lhs.senderAllowlist == rhs.senderAllowlist
            && lhs.receiveEnabled == rhs.receiveEnabled && lhs.writeEnabled == rhs.writeEnabled
            && lhs.draftUnsentReplies == rhs.draftUnsentReplies && lhs.defaultReadLimit == rhs.defaultReadLimit
    }

    var effectiveMailboxes: [String] { mailboxes.isEmpty ? [EmailSourceConfig.inbox] : mailboxes }

    var roomIds: [String] {
        effectiveMailboxes.map { EmailChannelConfiguration.roomId(connectionId: connectionId, mailbox: $0) }
    }

    func canRead(roomId: String) -> Bool { roomIds.contains(roomId.trimmingCharacters(in: .whitespaces)) }

    func canWrite(roomId: String) -> Bool { writeEnabled && canRead(roomId: roomId) }

    /// Whether this account's mailboxes should be checked.
    func canStartReceive() -> Bool { receiveEnabled && !senderAllowlist.isEmpty }

    /// An exact address, or any address at an allowlisted `@domain`.
    func allowsSender(_ address: String) -> Bool {
        EmailChannelConfiguration.allowlist(senderAllowlist, contains: address)
    }
}

struct EmailChannelConfiguration: Codable, Equatable, Sendable {
    /// Each one is its own channel connection with its own senders and
    /// receive and send switches.
    var accounts: [EmailChannelAccount]

    init(accounts: [EmailChannelAccount] = []) {
        var seen = Set<String>()
        var kept = accounts.filter { !$0.connectionId.isEmpty && seen.insert($0.connectionId).inserted }
        var usedIds = Set<String>()
        for index in kept.indices {
            let id = kept[index].channelConnectionId
            if id.isEmpty || !usedIds.insert(id).inserted { kept[index].channelConnectionId = "" }
        }
        let primary = AgentChannelConnection.nativeEmailConnectionId
        for index in kept.indices where kept[index].channelConnectionId.isEmpty {
            let id =
                usedIds.contains(primary)
                ? ChannelAccounts.connectionId(emailAccount: kept[index].connectionId) : primary
            kept[index].channelConnectionId = id
            usedIds.insert(id)
        }
        self.accounts = kept
    }

    private enum CodingKeys: String, CodingKey {
        case accounts
        // Shared by every account before each account had its own.
        case senderAllowlist, receiveEnabled, writeEnabled, draftUnsentReplies, defaultReadLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var accounts = try c.decodeIfPresent([EmailChannelAccount].self, forKey: .accounts) ?? []
        let senders = try c.decodeIfPresent([String].self, forKey: .senderAllowlist) ?? []
        let receive = try c.decodeIfPresent(Bool.self, forKey: .receiveEnabled) ?? false
        let write = try c.decodeIfPresent(Bool.self, forKey: .writeEnabled) ?? false
        let drafts = try c.decodeIfPresent(Bool.self, forKey: .draftUnsentReplies) ?? true
        let readLimit = try c.decodeIfPresent(Int.self, forKey: .defaultReadLimit) ?? 25
        for index in accounts.indices where accounts[index].inheritsSharedSettings {
            accounts[index].senderAllowlist = Self.normalizedSenders(senders)
            accounts[index].receiveEnabled = receive
            accounts[index].writeEnabled = write
            accounts[index].draftUnsentReplies = drafts
            accounts[index].defaultReadLimit = Self.clampReadLimit(readLimit)
            accounts[index].inheritsSharedSettings = false
        }
        self.init(accounts: accounts)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accounts, forKey: .accounts)
    }

    var normalized: EmailChannelConfiguration { EmailChannelConfiguration(accounts: accounts) }

    /// The account reading the mail account (`SourceConnection`) id.
    func account(connectionId: String) -> EmailChannelAccount? {
        accounts.first { $0.connectionId == connectionId }
    }

    /// The account that is the channel connection.
    func account(channelConnectionId: String) -> EmailChannelAccount? {
        let id = channelConnectionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return accounts.first { $0.channelConnectionId == id }
    }

    /// The account a room (`<mail account id>/<mailbox>`) belongs to.
    func account(roomId: String) -> EmailChannelAccount? {
        Self.parseRoomId(roomId).flatMap { account(connectionId: $0.connectionId) }
    }

    /// Every watched mailbox, as room ids.
    var roomIds: [String] { accounts.flatMap(\.roomIds) }

    /// Whether any account's mailboxes should be checked.
    func canStartReceive() -> Bool { accounts.contains { $0.canStartReceive() } }

    // MARK: - Rooms

    /// A watched mailbox: `<connection id>/<mailbox>`. Connection ids never
    /// contain `/`; mailbox paths may.
    static func roomId(connectionId: String, mailbox: String) -> String {
        "\(connectionId)/\(mailbox)"
    }

    static func parseRoomId(_ roomId: String) -> (connectionId: String, mailbox: String)? {
        let trimmed = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let connectionId = String(trimmed[..<slash])
        let mailbox = String(trimmed[trimmed.index(after: slash)...])
        guard !connectionId.isEmpty, !mailbox.isEmpty else { return nil }
        return (connectionId, mailbox)
    }

    // MARK: - Senders

    static func allowlist(_ entries: [String], contains address: String) -> Bool {
        let address = normalizedSender(address)
        guard address.contains("@") else { return false }
        return entries.contains { entry in
            entry.hasPrefix("@") ? address.hasSuffix(entry) : entry == address
        }
    }

    /// Lowercased; a bare domain (`example.com`) becomes `@example.com`.
    static func normalizedSender(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>")).lowercased()
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("@") { return trimmed }
        return trimmed.contains(".") ? "@" + trimmed : ""
    }

    static func normalizedSenders(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map(normalizedSender).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func clampReadLimit(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }
}

enum EmailChannelConfigurationStore {
    nonisolated(unsafe) static var overrideDirectory: URL?

    private static let fileName = "email.json"

    static func load() -> EmailChannelConfiguration {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return EmailChannelConfiguration()
        }
        do {
            return try JSONDecoder()
                .decode(EmailChannelConfiguration.self, from: Data(contentsOf: url))
                .normalized
        } catch {
            NSLog("[Email] Failed to load Email channel configuration: \(error.localizedDescription)")
            return EmailChannelConfiguration()
        }
    }

    static func save(_ configuration: EmailChannelConfiguration) throws {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration.normalized).write(to: url, options: [.atomic])
        NotificationCenter.default.post(name: .emailChannelConfigurationChanged, object: nil)
    }

    static func configurationFileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent(fileName)
        }
        return OsaurusPaths.config().appendingPathComponent(fileName)
    }
}

extension Notification.Name {
    static let emailChannelConfigurationChanged = Notification.Name("osaurusEmailChannelConfigurationChanged")
}
