//
//  AgentChannelConfiguration.swift
//  osaurus
//
//  JSON-backed connection definitions for agent communication channels.
//

import Foundation

enum AgentChannelKind: String, Codable, CaseIterable, Sendable {
    case discord
    case slack
    case telegram
    case imessage
    case customHTTP = "custom_http"
}

enum AgentChannelAction: String, Codable, CaseIterable, Sendable {
    case diagnostics
    case listSpaces = "list_spaces"
    case listRooms = "list_rooms"
    case readMessages = "read_messages"
    case readThread = "read_thread"
    case searchMessages = "search_messages"
    case draftMessage = "draft_message"
    case sendMessage = "send_message"
    case replyThread = "reply_thread"
    case editMessage = "edit_message"
    case deleteMessage = "delete_message"
    case addReaction = "add_reaction"
    case removeReaction = "remove_reaction"
    case sendTyping = "send_typing"
}

enum AgentChannelActionEffect: String, Codable, CaseIterable, Sendable {
    case readOnly = "read_only"
    case draft
    case confirmedWrite = "confirmed_write"
    case relayReceive = "relay_receive"
    case unsupportedConfiguredOnly = "unsupported_configured_only"
}

enum AgentChannelActionStatus: String, Codable, CaseIterable, Sendable {
    case available
    case unavailable
    case configuredOnly = "configured_only"
    case unsupported
    case disabled
}

struct AgentChannelActionPolicy: Equatable, Sendable {
    var action: AgentChannelAction
    var effect: AgentChannelActionEffect
    var status: AgentChannelActionStatus
    var reason: String?
    var requiresConfirmation: Bool
    var dedupeKey: String?
    var idempotencyRequired: Bool
    var constraints: [String]

    init(
        action: AgentChannelAction,
        effect: AgentChannelActionEffect,
        status: AgentChannelActionStatus,
        reason: String? = nil,
        requiresConfirmation: Bool = false,
        dedupeKey: String? = nil,
        idempotencyRequired: Bool = false,
        constraints: [String] = []
    ) {
        self.action = action
        self.effect = effect
        self.status = status
        self.reason = reason
        self.requiresConfirmation = requiresConfirmation
        self.dedupeKey = dedupeKey
        self.idempotencyRequired = idempotencyRequired
        self.constraints = constraints
    }

    var dictionary: [String: Any] {
        var row: [String: Any] = [
            "action": action.rawValue,
            "effect": effect.rawValue,
            "status": status.rawValue,
            "requires_confirmation": requiresConfirmation,
            "idempotency_required": idempotencyRequired,
            "constraints": constraints,
        ]
        if let reason {
            row["reason"] = reason
        }
        if let dedupeKey {
            row["dedupe_key"] = dedupeKey
        }
        return row
    }
}

struct AgentChannelRelayReceivePolicy: Equatable, Sendable {
    var effect: AgentChannelActionEffect
    var status: AgentChannelActionStatus
    var reason: String?
    var providerEventIdRequired: Bool
    var duplicateBehavior: String
    var snapshotPersistence: String
    var cursorUpdate: String
    var inboundAuthorization: AgentChannelInboundAuthorizationPolicy

    init(
        status: AgentChannelActionStatus,
        reason: String? = nil,
        providerEventIdRequired: Bool = true,
        duplicateBehavior: String = "acknowledge_without_dispatch",
        snapshotPersistence: String = "normalized_external_message_snapshot",
        cursorUpdate: String = "optional",
        inboundAuthorization: AgentChannelInboundAuthorizationPolicy = AgentChannelInboundAuthorizationPolicy()
    ) {
        self.effect = .relayReceive
        self.status = status
        self.reason = reason
        self.providerEventIdRequired = providerEventIdRequired
        self.duplicateBehavior = duplicateBehavior
        self.snapshotPersistence = snapshotPersistence
        self.cursorUpdate = cursorUpdate
        self.inboundAuthorization = inboundAuthorization
    }

    var dictionary: [String: Any] {
        var row: [String: Any] = [
            "effect": effect.rawValue,
            "status": status.rawValue,
            "provider_event_id_required": providerEventIdRequired,
            "dedupe_key": "connection_id + provider_event_id",
            "duplicate_behavior": duplicateBehavior,
            "snapshot_persistence": snapshotPersistence,
            "cursor_update": cursorUpdate,
            "inbound_authorization": inboundAuthorization.dictionary,
        ]
        if let reason {
            row["reason"] = reason
        }
        return row
    }
}

struct AgentChannelInboundAuthorizationPolicy: Codable, Equatable, Sendable {
    static let defaultDuplicateBehavior = "acknowledge_without_dispatch"
    static let defaultAuditDecisionReason = "inbound_authorization_required_before_agent_context"

    var senderAllowlist: [String]
    var roomAllowlist: [String]
    var allowUnscopedSpaces: Bool
    var allowBotMessages: Bool
    var allowSelfMessages: Bool
    var requireProviderEventId: Bool
    var duplicateBehavior: String
    var auditDecisionReason: String

    init(
        senderAllowlist: [String] = [],
        roomAllowlist: [String] = [],
        allowUnscopedSpaces: Bool = false,
        allowBotMessages: Bool = false,
        allowSelfMessages: Bool = false,
        requireProviderEventId: Bool = true,
        duplicateBehavior: String = Self.defaultDuplicateBehavior,
        auditDecisionReason: String = Self.defaultAuditDecisionReason
    ) {
        self.senderAllowlist = AgentChannelConnection.normalizedIds(senderAllowlist)
        self.roomAllowlist = AgentChannelConnection.normalizedIds(roomAllowlist)
        self.allowUnscopedSpaces = allowUnscopedSpaces
        self.allowBotMessages = allowBotMessages
        self.allowSelfMessages = allowSelfMessages
        self.requireProviderEventId = requireProviderEventId
        self.duplicateBehavior = duplicateBehavior.trimmingCharacters(in: .whitespacesAndNewlines)
        self.auditDecisionReason = auditDecisionReason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            senderAllowlist: try container.decodeIfPresent([String].self, forKey: .senderAllowlist) ?? [],
            roomAllowlist: try container.decodeIfPresent([String].self, forKey: .roomAllowlist) ?? [],
            allowUnscopedSpaces: try container.decodeIfPresent(
                Bool.self,
                forKey: .allowUnscopedSpaces
            ) ?? false,
            allowBotMessages: try container.decodeIfPresent(Bool.self, forKey: .allowBotMessages) ?? false,
            allowSelfMessages: try container.decodeIfPresent(Bool.self, forKey: .allowSelfMessages) ?? false,
            requireProviderEventId: try container.decodeIfPresent(
                Bool.self,
                forKey: .requireProviderEventId
            ) ?? true,
            duplicateBehavior: try container.decodeIfPresent(
                String.self,
                forKey: .duplicateBehavior
            ) ?? Self.defaultDuplicateBehavior,
            auditDecisionReason: try container.decodeIfPresent(
                String.self,
                forKey: .auditDecisionReason
            ) ?? Self.defaultAuditDecisionReason
        )
    }

    var normalized: AgentChannelInboundAuthorizationPolicy {
        AgentChannelInboundAuthorizationPolicy(
            senderAllowlist: senderAllowlist,
            roomAllowlist: roomAllowlist,
            allowUnscopedSpaces: allowUnscopedSpaces,
            allowBotMessages: allowBotMessages,
            allowSelfMessages: allowSelfMessages,
            requireProviderEventId: requireProviderEventId,
            duplicateBehavior: duplicateBehavior.isEmpty ? Self.defaultDuplicateBehavior : duplicateBehavior,
            auditDecisionReason: auditDecisionReason.isEmpty
                ? Self.defaultAuditDecisionReason
                : auditDecisionReason
        )
    }

    var dictionary: [String: Any] {
        let policy = normalized
        return [
            "default_decision": "deny",
            "sender_allowlist": policy.senderAllowlist,
            "room_allowlist": policy.roomAllowlist,
            "allow_unscoped_spaces": policy.allowUnscopedSpaces,
            "bot_messages": policy.allowBotMessages ? "allow" : "deny",
            "self_messages": policy.allowSelfMessages ? "allow" : "deny",
            "provider_event_id_required": policy.requireProviderEventId,
            "dedupe_key": "connection_id + provider_event_id",
            "duplicate_behavior": policy.duplicateBehavior,
            "dispatch_contract": "authorize_before_agent_context_or_tool_input",
            "audit_decision_reason": policy.auditDecisionReason,
        ]
    }
}

struct AgentChannelInboundMessageAuthorizationRequest: Equatable, Sendable {
    var connectionId: String?
    var providerEventId: String?
    var providerMessageId: String?
    var spaceId: String?
    var roomId: String
    var senderId: String?
    var isBotMessage: Bool
    var isSelfMessage: Bool

    init(
        connectionId: String? = nil,
        providerEventId: String? = nil,
        providerMessageId: String? = nil,
        spaceId: String? = nil,
        roomId: String,
        senderId: String? = nil,
        isBotMessage: Bool = false,
        isSelfMessage: Bool = false
    ) {
        self.connectionId = connectionId.map(AgentChannelConnection.normalizedId)
        self.providerEventId = providerEventId.map(AgentChannelConnection.normalizedId)
        self.providerMessageId = providerMessageId.map(AgentChannelConnection.normalizedId)
        self.spaceId = spaceId.map(AgentChannelConnection.normalizedId)
        self.roomId = AgentChannelConnection.normalizedId(roomId)
        self.senderId = senderId.map(AgentChannelConnection.normalizedId)
        self.isBotMessage = isBotMessage
        self.isSelfMessage = isSelfMessage
    }
}

public enum AgentChannelInboundAuthorizationDecisionValue: String, Codable, Equatable, Sendable {
    case allow
    case deny
    case duplicate
}

public struct AgentChannelInboundAuthorizationDecision: Equatable, Sendable {
    var decision: AgentChannelInboundAuthorizationDecisionValue
    var shouldDispatch: Bool
    var reason: String
    var auditDecisionReason: String
    var connectionId: String
    var providerEventId: String?
    var providerMessageId: String?
    var spaceId: String?
    var roomId: String
    var senderId: String?
    var details: [String: String]

    init(
        decision: AgentChannelInboundAuthorizationDecisionValue,
        shouldDispatch: Bool,
        reason: String,
        auditDecisionReason: String,
        connectionId: String,
        providerEventId: String? = nil,
        providerMessageId: String? = nil,
        spaceId: String? = nil,
        roomId: String,
        senderId: String? = nil,
        details: [String: String] = [:]
    ) {
        self.decision = decision
        self.shouldDispatch = shouldDispatch
        self.reason = reason
        self.auditDecisionReason = auditDecisionReason
        self.connectionId = AgentChannelConnection.normalizedId(connectionId)
        self.providerEventId = providerEventId.map(AgentChannelConnection.normalizedId)
        self.providerMessageId = providerMessageId.map(AgentChannelConnection.normalizedId)
        self.spaceId = spaceId.map(AgentChannelConnection.normalizedId)
        self.roomId = AgentChannelConnection.normalizedId(roomId)
        self.senderId = senderId.map(AgentChannelConnection.normalizedId)
        self.details = details
    }

    var dictionary: [String: Any] {
        var row: [String: Any] = [
            "decision": decision.rawValue,
            "should_dispatch": shouldDispatch,
            "reason": reason,
            "audit_decision_reason": auditDecisionReason,
            "connection_id": connectionId,
            "room_id": roomId,
        ]
        if let providerEventId {
            row["provider_event_id"] = providerEventId
        }
        if let providerMessageId {
            row["provider_message_id"] = providerMessageId
        }
        if let spaceId {
            row["space_id"] = spaceId
        }
        if let senderId {
            row["sender_id"] = senderId
        }
        if !details.isEmpty {
            row["details"] = details
        }
        return row
    }
}

extension AgentChannelAction {
    var baseEffect: AgentChannelActionEffect {
        switch self {
        case .diagnostics, .listSpaces, .listRooms, .readMessages, .readThread, .searchMessages:
            return .readOnly
        case .draftMessage:
            return .draft
        case .sendMessage, .replyThread, .editMessage, .deleteMessage, .addReaction, .removeReaction, .sendTyping:
            return .confirmedWrite
        }
    }

    var requiresSendConfirmation: Bool {
        switch self {
        case .sendMessage, .replyThread, .editMessage, .deleteMessage, .addReaction, .removeReaction, .sendTyping:
            return true
        case .diagnostics, .listSpaces, .listRooms, .readMessages, .readThread, .searchMessages, .draftMessage:
            return false
        }
    }

    var providerNeutralConstraints: [String] {
        switch self {
        case .diagnostics:
            return ["redact_secrets"]
        case .listSpaces:
            return ["provider_credentials"]
        case .listRooms:
            return ["provider_credentials", "space_allowlist"]
        case .readMessages, .readThread, .searchMessages:
            return ["provider_credentials", "read_room_allowlist"]
        case .draftMessage:
            return ["write_room_allowlist", "no_provider_write"]
        case .sendMessage, .replyThread, .editMessage, .deleteMessage, .addReaction, .removeReaction, .sendTyping:
            return ["write_enabled", "write_room_allowlist", "confirm_send_true"]
        }
    }
}

struct AgentChannelSecretReference: Codable, Equatable, Sendable {
    var name: String
    var keychainId: String

    var normalized: AgentChannelSecretReference {
        AgentChannelSecretReference(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            keychainId: keychainId.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct AgentChannelCustomHTTPAction: Codable, Equatable, Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var bodyTemplate: String?
    var successStatusCodes: [Int]
    var responseMapping: AgentChannelCustomHTTPResponseMapping
    var idempotency: AgentChannelCustomHTTPIdempotency?
    var timeoutSeconds: Double?
    var maxResponseBytes: Int?

    init(
        method: String = "GET",
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        bodyTemplate: String? = nil,
        successStatusCodes: [Int] = Array(200 ... 299),
        responseMapping: AgentChannelCustomHTTPResponseMapping = AgentChannelCustomHTTPResponseMapping(),
        idempotency: AgentChannelCustomHTTPIdempotency? = nil,
        timeoutSeconds: Double? = nil,
        maxResponseBytes: Int? = nil
    ) {
        self.method = method.uppercased()
        self.path = path
        self.query = query
        self.headers = headers
        self.bodyTemplate = bodyTemplate
        self.successStatusCodes = Self.normalizedStatusCodes(successStatusCodes)
        self.responseMapping = responseMapping.normalized
        self.idempotency = idempotency?.normalized
        self.timeoutSeconds = timeoutSeconds.map(Self.clampTimeout)
        self.maxResponseBytes = maxResponseBytes.map(Self.clampResponseBytes)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decodeIfPresent(String.self, forKey: .method)?.uppercased() ?? "GET"
        path = try container.decode(String.self, forKey: .path)
        query = try container.decodeIfPresent([String: String].self, forKey: .query) ?? [:]
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        bodyTemplate = try container.decodeIfPresent(String.self, forKey: .bodyTemplate)
        successStatusCodes = Self.normalizedStatusCodes(
            try container.decodeIfPresent([Int].self, forKey: .successStatusCodes) ?? Array(200 ... 299)
        )
        responseMapping =
            try container.decodeIfPresent(AgentChannelCustomHTTPResponseMapping.self, forKey: .responseMapping)?
            .normalized ?? AgentChannelCustomHTTPResponseMapping()
        idempotency =
            try container.decodeIfPresent(AgentChannelCustomHTTPIdempotency.self, forKey: .idempotency)?
            .normalized
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds).map(Self.clampTimeout)
        maxResponseBytes = try container.decodeIfPresent(Int.self, forKey: .maxResponseBytes)
            .map(Self.clampResponseBytes)
    }

    var normalized: AgentChannelCustomHTTPAction {
        AgentChannelCustomHTTPAction(
            method: method,
            path: path,
            query: query,
            headers: headers,
            bodyTemplate: bodyTemplate,
            successStatusCodes: successStatusCodes,
            responseMapping: responseMapping,
            idempotency: idempotency,
            timeoutSeconds: timeoutSeconds,
            maxResponseBytes: maxResponseBytes
        )
    }

    static func normalizedStatusCodes(_ codes: [Int]) -> [Int] {
        var seen = Set<Int>()
        let filtered = codes.filter { (100 ... 599).contains($0) && seen.insert($0).inserted }
        return filtered.isEmpty ? Array(200 ... 299) : filtered
    }

    static func clampTimeout(_ value: Double) -> Double {
        min(max(value, 1), 30)
    }

    static func clampResponseBytes(_ value: Int) -> Int {
        min(max(value, 1_024), 1_048_576)
    }
}

struct AgentChannelCustomHTTPConfiguration: Codable, Equatable, Sendable {
    var baseURL: String
    var allowedHosts: [String]
    var allowedMethods: [String]
    var allowInsecureHTTP: Bool
    var timeoutSeconds: Double
    var maxResponseBytes: Int
    var actions: [String: AgentChannelCustomHTTPAction]

    init(
        baseURL: String,
        allowedHosts: [String] = [],
        allowedMethods: [String] = ["GET", "POST"],
        allowInsecureHTTP: Bool = false,
        timeoutSeconds: Double = 15,
        maxResponseBytes: Int = 131_072,
        actions: [String: AgentChannelCustomHTTPAction] = [:]
    ) {
        self.baseURL = baseURL
        self.allowedHosts = Self.normalizedHosts(allowedHosts)
        self.allowedMethods = Self.normalizedMethods(allowedMethods)
        self.allowInsecureHTTP = allowInsecureHTTP
        self.timeoutSeconds = AgentChannelCustomHTTPAction.clampTimeout(timeoutSeconds)
        self.maxResponseBytes = AgentChannelCustomHTTPAction.clampResponseBytes(maxResponseBytes)
        self.actions = Self.normalizedActions(actions)
    }

    init(baseURL: String, actions: [AgentChannelAction: AgentChannelCustomHTTPAction]) {
        self.init(
            baseURL: baseURL,
            actions: Dictionary(uniqueKeysWithValues: actions.map { ($0.rawValue, $1) })
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        allowedHosts = Self.normalizedHosts(try container.decodeIfPresent([String].self, forKey: .allowedHosts) ?? [])
        allowedMethods = Self.normalizedMethods(
            try container.decodeIfPresent([String].self, forKey: .allowedMethods) ?? ["GET", "POST"]
        )
        allowInsecureHTTP = try container.decodeIfPresent(Bool.self, forKey: .allowInsecureHTTP) ?? false
        timeoutSeconds = AgentChannelCustomHTTPAction.clampTimeout(
            try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 15
        )
        maxResponseBytes = AgentChannelCustomHTTPAction.clampResponseBytes(
            try container.decodeIfPresent(Int.self, forKey: .maxResponseBytes) ?? 131_072
        )
        actions = Self.normalizedActions(
            try container.decodeIfPresent([String: AgentChannelCustomHTTPAction].self, forKey: .actions) ?? [:]
        )
    }

    var normalized: AgentChannelCustomHTTPConfiguration {
        AgentChannelCustomHTTPConfiguration(
            baseURL: baseURL,
            allowedHosts: allowedHosts,
            allowedMethods: allowedMethods,
            allowInsecureHTTP: allowInsecureHTTP,
            timeoutSeconds: timeoutSeconds,
            maxResponseBytes: maxResponseBytes,
            actions: actions
        )
    }

    static func normalizedHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .lowercased()
        }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func normalizedMethods(_ methods: [String]) -> [String] {
        var seen = Set<String>()
        let normalized = methods.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
        return normalized.isEmpty ? ["GET", "POST"] : normalized
    }

    static func normalizedActions(
        _ actions: [String: AgentChannelCustomHTTPAction]
    ) -> [String: AgentChannelCustomHTTPAction] {
        var normalized: [String: AgentChannelCustomHTTPAction] = [:]
        for (key, action) in actions {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { continue }
            normalized[trimmedKey] = action.normalized
        }
        return normalized
    }
}

struct AgentChannelConnection: Codable, Equatable, Identifiable, Sendable {
    static let nativeDiscordConnectionId = "discord"
    static let nativeSlackConnectionId = "slack"
    static let nativeTelegramConnectionId = "telegram"
    static let nativeIMessageConnectionId = "imessage"

    var id: String
    var name: String
    var kind: AgentChannelKind
    var enabled: Bool
    var supportedActions: [AgentChannelAction]
    var spaceAllowlist: [String]
    var readRoomAllowlist: [String]
    var writeRoomAllowlist: [String]
    var writeEnabled: Bool
    var defaultReadLimit: Int
    var secrets: [AgentChannelSecretReference]
    var customHTTP: AgentChannelCustomHTTPConfiguration?
    var inboundAuthorization: AgentChannelInboundAuthorizationPolicy

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case enabled
        case supportedActions
        case spaceAllowlist
        case readRoomAllowlist
        case writeRoomAllowlist
        case writeEnabled
        case defaultReadLimit
        case secrets
        case customHTTP
        case inboundAuthorization
    }

    init(
        id: String,
        name: String,
        kind: AgentChannelKind,
        enabled: Bool = true,
        supportedActions: [AgentChannelAction] = AgentChannelAction.allCases,
        spaceAllowlist: [String] = [],
        readRoomAllowlist: [String] = [],
        writeRoomAllowlist: [String] = [],
        writeEnabled: Bool = false,
        defaultReadLimit: Int = 50,
        secrets: [AgentChannelSecretReference] = [],
        customHTTP: AgentChannelCustomHTTPConfiguration? = nil,
        inboundAuthorization: AgentChannelInboundAuthorizationPolicy = AgentChannelInboundAuthorizationPolicy()
    ) {
        self.id = Self.normalizedId(id)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.enabled = enabled
        self.supportedActions = Self.normalizedActions(supportedActions)
        self.spaceAllowlist = Self.normalizedIds(spaceAllowlist)
        self.readRoomAllowlist = Self.normalizedIds(readRoomAllowlist)
        self.writeRoomAllowlist = Self.normalizedIds(writeRoomAllowlist)
        self.writeEnabled = writeEnabled
        self.defaultReadLimit = Self.clampReadLimit(defaultReadLimit)
        self.secrets = secrets.map(\.normalized)
        self.customHTTP = customHTTP
        self.inboundAuthorization = inboundAuthorization.normalized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            kind: try container.decode(AgentChannelKind.self, forKey: .kind),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            supportedActions: try container.decodeIfPresent(
                [AgentChannelAction].self,
                forKey: .supportedActions
            ) ?? AgentChannelAction.allCases,
            spaceAllowlist: try container.decodeIfPresent([String].self, forKey: .spaceAllowlist) ?? [],
            readRoomAllowlist: try container.decodeIfPresent([String].self, forKey: .readRoomAllowlist) ?? [],
            writeRoomAllowlist: try container.decodeIfPresent([String].self, forKey: .writeRoomAllowlist) ?? [],
            writeEnabled: try container.decodeIfPresent(Bool.self, forKey: .writeEnabled) ?? false,
            defaultReadLimit: try container.decodeIfPresent(Int.self, forKey: .defaultReadLimit) ?? 50,
            secrets: try container.decodeIfPresent([AgentChannelSecretReference].self, forKey: .secrets) ?? [],
            customHTTP: try container.decodeIfPresent(
                AgentChannelCustomHTTPConfiguration.self,
                forKey: .customHTTP
            ),
            inboundAuthorization: try container.decodeIfPresent(
                AgentChannelInboundAuthorizationPolicy.self,
                forKey: .inboundAuthorization
            ) ?? AgentChannelInboundAuthorizationPolicy()
        )
    }

    var normalized: AgentChannelConnection {
        AgentChannelConnection(
            id: id,
            name: name,
            kind: kind,
            enabled: enabled,
            supportedActions: supportedActions,
            spaceAllowlist: spaceAllowlist,
            readRoomAllowlist: readRoomAllowlist,
            writeRoomAllowlist: writeRoomAllowlist,
            writeEnabled: writeEnabled,
            defaultReadLimit: defaultReadLimit,
            secrets: secrets,
            customHTTP: customHTTP?.normalized,
            inboundAuthorization: inboundAuthorization
        )
    }

    static func normalizedId(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return
            ids
            .map(normalizedId)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func normalizedActions(_ actions: [AgentChannelAction]) -> [AgentChannelAction] {
        var seen = Set<AgentChannelAction>()
        return actions.filter { seen.insert($0).inserted }
    }

    static func clampReadLimit(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }
}

// MARK: - Proactive outbound bindings

/// Outbound behavior of one agent→destination binding. This is the
/// per-destination policy that decides what `agent_channel_publish` may do:
/// `off` refuses, `draft` records a local draft with no provider I/O,
/// `confirm` requires an interactive approval (or queues a pending outbound
/// item on unattended runs), and `autonomous` sends without a prompt while
/// still passing every host gate (allowlists, rate policy, kill switch).
enum AgentChannelBindingOutboundMode: String, Codable, CaseIterable, Sendable {
    case off
    case draft
    case confirm
    case autonomous
}

/// Run provenance a binding may be used from. Deliberately narrower than
/// `SessionSource`: plugin/HTTP/channel-triggered runs are external or
/// lateral surfaces and can never publish proactively, so they have no
/// representation here.
enum AgentChannelBindingRunSource: String, Codable, CaseIterable, Sendable {
    case chat
    case schedule
    case watcher
    case selfSchedule = "self_schedule"

    /// Map a session source onto the binding vocabulary. Returns nil for
    /// sources that are never allowed to publish proactively (plugin,
    /// HTTP, inbound channel dispatch).
    init?(sessionSource: SessionSource) {
        switch sessionSource {
        case .chat: self = .chat
        case .schedule: self = .schedule
        case .watcher: self = .watcher
        case .selfSchedule: self = .selfSchedule
        case .plugin, .http, .channel, .imported: return nil
        }
    }
}

/// Simple per-binding outbound rate policy, enforced against the durable
/// outbound-intent ledger at send time.
struct AgentChannelBindingRatePolicy: Codable, Equatable, Sendable {
    static let defaultMaxSendsPerHour = 10
    static let defaultMinSecondsBetweenSends = 30

    var maxSendsPerHour: Int
    var minSecondsBetweenSends: Int

    init(
        maxSendsPerHour: Int = Self.defaultMaxSendsPerHour,
        minSecondsBetweenSends: Int = Self.defaultMinSecondsBetweenSends
    ) {
        self.maxSendsPerHour = min(max(maxSendsPerHour, 1), 120)
        self.minSecondsBetweenSends = min(max(minSecondsBetweenSends, 0), 3_600)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxSendsPerHour: try container.decodeIfPresent(Int.self, forKey: .maxSendsPerHour)
                ?? Self.defaultMaxSendsPerHour,
            minSecondsBetweenSends: try container.decodeIfPresent(
                Int.self,
                forKey: .minSecondsBetweenSends
            ) ?? Self.defaultMinSecondsBetweenSends
        )
    }
}

/// One approved agent→destination route for proactive publishing.
///
/// The model never supplies a raw connection/room pair for proactive sends;
/// it references a binding by id and the host resolves (and re-validates)
/// the destination. Bindings are provider-neutral: `connectionId` may point
/// at a native connection (`discord`/`slack`/`telegram`) or a custom
/// connection from `agent-channels.json`. Credentials and transport
/// settings stay in their existing stores.
struct AgentChannelBinding: Codable, Equatable, Identifiable, Sendable {
    /// Cap for the operator-authored "when to use" guidance surfaced to the
    /// model. Past this the guidance is prompt bloat, not routing signal.
    static let maxGuidanceLength = 500
    static let maxLabelLength = 80

    /// Stable operator-chosen identifier (slug-like, trimmed + lowercased).
    /// Surfaced to the model as `binding_id`.
    var id: String
    var agentId: UUID
    var connectionId: String
    var roomId: String
    /// Optional provider thread to publish into (thread reply instead of a
    /// room message).
    var threadId: String?
    var label: String
    /// Operator-facing "when to use" guidance, injected into the agent's
    /// prompt context. Bounded at `maxGuidanceLength`.
    var guidance: String
    /// Run sources this binding may be used from. Empty decodes/normalizes
    /// to the safe default of `[.chat]`.
    var allowedSources: [AgentChannelBindingRunSource]
    var outboundMode: AgentChannelBindingOutboundMode
    var ratePolicy: AgentChannelBindingRatePolicy
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case agentId
        case connectionId
        case roomId
        case threadId
        case label
        case guidance
        case allowedSources
        case outboundMode
        case ratePolicy
        case enabled
    }

    init(
        id: String,
        agentId: UUID,
        connectionId: String,
        roomId: String,
        threadId: String? = nil,
        label: String = "",
        guidance: String = "",
        allowedSources: [AgentChannelBindingRunSource] = [.chat],
        outboundMode: AgentChannelBindingOutboundMode = .off,
        ratePolicy: AgentChannelBindingRatePolicy = AgentChannelBindingRatePolicy(),
        enabled: Bool = true
    ) {
        self.id = Self.normalizedBindingId(id)
        self.agentId = agentId
        self.connectionId = AgentChannelConnection.normalizedId(connectionId)
        self.roomId = AgentChannelConnection.normalizedId(roomId)
        let trimmedThread = threadId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.threadId = (trimmedThread?.isEmpty ?? true) ? nil : trimmedThread
        self.label = String(
            label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLabelLength)
        )
        self.guidance = String(
            guidance.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxGuidanceLength)
        )
        let sources = Self.normalizedSources(allowedSources)
        self.allowedSources = sources.isEmpty ? [.chat] : sources
        self.outboundMode = outboundMode
        self.ratePolicy = ratePolicy
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            agentId: try container.decode(UUID.self, forKey: .agentId),
            connectionId: try container.decode(String.self, forKey: .connectionId),
            roomId: try container.decode(String.self, forKey: .roomId),
            threadId: try container.decodeIfPresent(String.self, forKey: .threadId),
            label: try container.decodeIfPresent(String.self, forKey: .label) ?? "",
            guidance: try container.decodeIfPresent(String.self, forKey: .guidance) ?? "",
            allowedSources: try container.decodeIfPresent(
                [AgentChannelBindingRunSource].self,
                forKey: .allowedSources
            ) ?? [.chat],
            outboundMode: try container.decodeIfPresent(
                AgentChannelBindingOutboundMode.self,
                forKey: .outboundMode
            ) ?? .off,
            ratePolicy: try container.decodeIfPresent(
                AgentChannelBindingRatePolicy.self,
                forKey: .ratePolicy
            ) ?? AgentChannelBindingRatePolicy(),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        )
    }

    var normalized: AgentChannelBinding {
        AgentChannelBinding(
            id: id,
            agentId: agentId,
            connectionId: connectionId,
            roomId: roomId,
            threadId: threadId,
            label: label,
            guidance: guidance,
            allowedSources: allowedSources,
            outboundMode: outboundMode,
            ratePolicy: ratePolicy,
            enabled: enabled
        )
    }

    /// Display label with a deterministic fallback so UI and prompt rows
    /// never render blank.
    var displayLabel: String {
        label.isEmpty ? "\(connectionId) · \(roomId)" : label
    }

    /// Whether this binding can be surfaced to (and used by) an agent run:
    /// enabled and not switched off.
    var isUsable: Bool {
        enabled && outboundMode != .off
    }

    func allows(source: AgentChannelBindingRunSource) -> Bool {
        allowedSources.contains(source)
    }

    static func normalizedBindingId(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizedSources(
        _ sources: [AgentChannelBindingRunSource]
    ) -> [AgentChannelBindingRunSource] {
        var seen = Set<AgentChannelBindingRunSource>()
        return sources.filter { seen.insert($0).inserted }
    }
}

struct AgentChannelConfiguration: Codable, Equatable, Sendable {
    /// v1: connections only. v2: adds top-level `bindings` (proactive
    /// outbound destinations). Decoding is additive — a v1 file decodes with
    /// empty bindings, so existing installs remain proactive-off by default.
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var connections: [AgentChannelConnection]
    var bindings: [AgentChannelBinding]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case connections
        case bindings
    }

    init(
        schemaVersion: Int = AgentChannelConfiguration.currentSchemaVersion,
        connections: [AgentChannelConnection] = [],
        bindings: [AgentChannelBinding] = []
    ) {
        self.schemaVersion = schemaVersion
        self.connections = Self.normalizedConnections(connections)
        self.bindings = Self.normalizedBindings(bindings)
    }

    init(from decoder: Decoder) throws {
        // Assign raw arrays WITHOUT the memberwise init's normalization:
        // decoding must preserve duplicates so import validation can REJECT
        // a file with duplicate connection/binding ids instead of silently
        // dropping the extras. Normalization happens at the load/save
        // boundaries via `.normalized`.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        connections =
            try container.decodeIfPresent(
                [AgentChannelConnection].self,
                forKey: .connections
            ) ?? []
        bindings =
            try container.decodeIfPresent(
                [AgentChannelBinding].self,
                forKey: .bindings
            ) ?? []
    }

    var normalized: AgentChannelConfiguration {
        AgentChannelConfiguration(
            schemaVersion: max(schemaVersion, Self.currentSchemaVersion),
            connections: connections,
            bindings: bindings
        )
    }

    func connection(id: String) -> AgentChannelConnection? {
        let normalized = AgentChannelConnection.normalizedId(id)
        return connections.first { $0.id == normalized }
    }

    func binding(id: String) -> AgentChannelBinding? {
        let normalized = AgentChannelBinding.normalizedBindingId(id)
        return bindings.first { $0.id == normalized }
    }

    /// All bindings owned by `agentId`, regardless of enablement/mode.
    func bindings(agentId: UUID) -> [AgentChannelBinding] {
        bindings.filter { $0.agentId == agentId }
    }

    /// Bindings the agent can actually surface/use (enabled, mode != off).
    func usableBindings(agentId: UUID) -> [AgentChannelBinding] {
        bindings(agentId: agentId).filter(\.isUsable)
    }

    private static func normalizedConnections(
        _ connections: [AgentChannelConnection]
    ) -> [AgentChannelConnection] {
        var seen = Set<String>()
        return
            connections
            .map(\.normalized)
            .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    private static func normalizedBindings(
        _ bindings: [AgentChannelBinding]
    ) -> [AgentChannelBinding] {
        var seen = Set<String>()
        return
            bindings
            .map(\.normalized)
            .filter { !$0.id.isEmpty && !$0.connectionId.isEmpty && !$0.roomId.isEmpty
                && seen.insert($0.id).inserted
            }
    }
}

extension Notification.Name {
    /// Posted after every successful `AgentChannelConfigurationStore.save`.
    /// Connection/binding edits rewrite the channel-destinations prompt
    /// section (a dynamic section, invisible to the static-prefix hash), so
    /// open chat windows subscribe to re-price their context preview and
    /// invalidate a warm-up prefilled with the old destination bytes.
    static let agentChannelConfigurationChanged =
        Notification.Name("AgentChannelConfigurationChanged")
}

enum AgentChannelConfigurationStore {
    nonisolated(unsafe) static var overrideDirectory: URL?

    private static let fileName = "agent-channels.json"

    static func load() -> AgentChannelConfiguration {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AgentChannelConfiguration()
        }
        do {
            return try JSONDecoder()
                .decode(AgentChannelConfiguration.self, from: Data(contentsOf: url))
                .normalized
        } catch {
            NSLog("[AgentChannels] Failed to load channel configuration: \(error.localizedDescription)")
            return AgentChannelConfiguration()
        }
    }

    static func save(_ configuration: AgentChannelConfiguration) throws {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration.normalized).write(to: url, options: [.atomic])
        // Deliver on main: subscribers (ChatSession's budget-signal pipeline)
        // attach MainActor-isolated closures that Combine invokes synchronously
        // on the posting thread, and runtime isolation checks SIGTRAP the
        // process when a background save (publish service, tests) posts
        // directly. Every other signal in that pipeline is main-posted.
        if Thread.isMainThread {
            NotificationCenter.default.post(
                name: .agentChannelConfigurationChanged,
                object: nil
            )
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .agentChannelConfigurationChanged,
                    object: nil
                )
            }
        }
    }

    static func configurationFileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent(fileName)
        }
        return OsaurusPaths.config().appendingPathComponent(fileName)
    }
}
