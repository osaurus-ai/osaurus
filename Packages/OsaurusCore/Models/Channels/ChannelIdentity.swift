//
//  ChannelIdentity.swift
//  osaurus
//
//  Provider-neutral identities for remote agent channels.
//

import Foundation

enum ChannelKind: String, Codable, CaseIterable, Sendable {
    case discord
    case slack
    case telegram
    case jsonAgent = "json_agent"
}

enum ChannelTrustLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case untrusted
    case known
    case verified
    case owner

    static func < (lhs: ChannelTrustLevel, rhs: ChannelTrustLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .untrusted: return 0
        case .known: return 1
        case .verified: return 2
        case .owner: return 3
        }
    }
}

struct ChannelSenderMetadata: Codable, Equatable, Sendable {
    var senderId: String
    var displayName: String?
    var username: String?
    var email: String?
    var avatarURL: String?
    var metadata: [String: String]

    init(
        senderId: String,
        displayName: String? = nil,
        username: String? = nil,
        email: String? = nil,
        avatarURL: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.senderId = ChannelIdentity.normalizedRequiredId(senderId)
        self.displayName = ChannelIdentity.normalizedOptionalId(displayName)
        self.username = ChannelIdentity.normalizedOptionalId(username)
        self.email = ChannelIdentity.normalizedOptionalId(email)
        self.avatarURL = ChannelIdentity.normalizedOptionalId(avatarURL)
        self.metadata = metadata.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private enum CodingKeys: String, CodingKey {
        case senderId, displayName, username, email, avatarURL, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            senderId: try container.decode(String.self, forKey: .senderId),
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            username: try container.decodeIfPresent(String.self, forKey: .username),
            email: try container.decodeIfPresent(String.self, forKey: .email),
            avatarURL: try container.decodeIfPresent(String.self, forKey: .avatarURL),
            metadata: try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        )
    }
}

struct ChannelIdentity: Codable, Equatable, Sendable {
    var kind: ChannelKind
    var installationId: String
    var groupId: String?
    var threadId: String?
    var sender: ChannelSenderMetadata
    var trustLevel: ChannelTrustLevel

    init(
        kind: ChannelKind,
        installationId: String,
        groupId: String? = nil,
        threadId: String? = nil,
        sender: ChannelSenderMetadata,
        trustLevel: ChannelTrustLevel = .untrusted
    ) {
        self.kind = kind
        self.installationId = Self.normalizedRequiredId(installationId)
        self.groupId = Self.normalizedOptionalId(groupId)
        self.threadId = Self.normalizedOptionalId(threadId)
        self.sender = sender
        self.trustLevel = trustLevel
    }

    var senderId: String { sender.senderId }

    var binding: ChannelIdentityBinding {
        ChannelIdentityBinding(identity: self)
    }

    static func normalizedRequiredId(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidRequiredId(_ value: String) -> Bool {
        !normalizedRequiredId(value).isEmpty
    }

    static func normalizedOptionalId(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return
            ids
            .map(normalizedRequiredId)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var hasValidRequiredIds: Bool {
        Self.isValidRequiredId(installationId) && Self.isValidRequiredId(senderId)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, installationId, groupId, threadId, sender, trustLevel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(ChannelKind.self, forKey: .kind),
            installationId: try container.decode(String.self, forKey: .installationId),
            groupId: try container.decodeIfPresent(String.self, forKey: .groupId),
            threadId: try container.decodeIfPresent(String.self, forKey: .threadId),
            sender: try container.decode(ChannelSenderMetadata.self, forKey: .sender),
            // Trust is assigned by adapter-side verification, not accepted from
            // serialized remote input.
            trustLevel: .untrusted
        )
        guard hasValidRequiredIds else {
            throw DecodingError.dataCorruptedError(
                forKey: .installationId,
                in: container,
                debugDescription: "Channel identity requires non-empty installationId and sender.senderId"
            )
        }
    }
}

struct ChannelIdentityBinding: Codable, Equatable, Sendable {
    var kind: ChannelKind
    var installationId: String
    var groupId: String?
    var threadId: String?
    var senderId: String

    init(
        kind: ChannelKind,
        installationId: String,
        groupId: String? = nil,
        threadId: String? = nil,
        senderId: String
    ) {
        self.kind = kind
        self.installationId = ChannelIdentity.normalizedRequiredId(installationId)
        self.groupId = ChannelIdentity.normalizedOptionalId(groupId)
        self.threadId = ChannelIdentity.normalizedOptionalId(threadId)
        self.senderId = ChannelIdentity.normalizedRequiredId(senderId)
    }

    init(identity: ChannelIdentity) {
        self.init(
            kind: identity.kind,
            installationId: identity.installationId,
            groupId: identity.groupId,
            threadId: identity.threadId,
            senderId: identity.senderId
        )
    }

    func matches(_ identity: ChannelIdentity) -> Bool {
        self == identity.binding
    }

    var nonceScopeKey: String {
        [
            kind.rawValue,
            installationId,
            groupId ?? "_",
            threadId ?? "_",
            senderId,
        ].map(Self.scopeComponent).joined(separator: ".")
    }

    private static func scopeComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var hasValidRequiredIds: Bool {
        ChannelIdentity.isValidRequiredId(installationId)
            && ChannelIdentity.isValidRequiredId(senderId)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, installationId, groupId, threadId, senderId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(ChannelKind.self, forKey: .kind),
            installationId: try container.decode(String.self, forKey: .installationId),
            groupId: try container.decodeIfPresent(String.self, forKey: .groupId),
            threadId: try container.decodeIfPresent(String.self, forKey: .threadId),
            senderId: try container.decode(String.self, forKey: .senderId)
        )
        guard hasValidRequiredIds else {
            throw DecodingError.dataCorruptedError(
                forKey: .installationId,
                in: container,
                debugDescription: "Channel identity binding requires non-empty installationId and senderId"
            )
        }
    }
}

struct ChannelCredentialScope: Codable, Equatable, Sendable {
    var kind: ChannelKind
    var installationId: String
    var groupId: String?
    var threadId: String?

    init(
        kind: ChannelKind,
        installationId: String,
        groupId: String? = nil,
        threadId: String? = nil
    ) {
        self.kind = kind
        self.installationId = ChannelIdentity.normalizedRequiredId(installationId)
        self.groupId = ChannelIdentity.normalizedOptionalId(groupId)
        self.threadId = ChannelIdentity.normalizedOptionalId(threadId)
    }

    init(identity: ChannelIdentity) {
        self.init(
            kind: identity.kind,
            installationId: identity.installationId,
            groupId: identity.groupId,
            threadId: identity.threadId
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind, installationId, groupId, threadId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(ChannelKind.self, forKey: .kind),
            installationId: try container.decode(String.self, forKey: .installationId),
            groupId: try container.decodeIfPresent(String.self, forKey: .groupId),
            threadId: try container.decodeIfPresent(String.self, forKey: .threadId)
        )
        guard ChannelIdentity.isValidRequiredId(installationId) else {
            throw DecodingError.dataCorruptedError(
                forKey: .installationId,
                in: container,
                debugDescription: "Channel credential scope requires non-empty installationId"
            )
        }
    }
}
