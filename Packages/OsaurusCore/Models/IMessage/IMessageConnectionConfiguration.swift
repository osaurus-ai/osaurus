//
//  IMessageConnectionConfiguration.swift
//  osaurus
//
//  Non-secret configuration for the native iMessage connection.
//
//  iMessage has no bot token: the channel drives a local, bundled `imsg`
//  helper that talks to Messages.app and `chat.db` on this Mac. Authorization
//  is therefore entirely local — chat/sender allowlists, a write kill switch,
//  attachment-root fencing, and capability-gated advanced (private-API)
//  actions. Everything defaults to the safest state (writes off, attachment
//  ingestion off, advanced actions off).
//

import Foundation

struct IMessageConnectionConfiguration: Codable, Equatable, Sendable {
    /// Advanced (private-API) actions the operator has individually enabled.
    /// Each maps to an `imsg` RPC method/selector that only works when the
    /// bridge dylib is injected into Messages.app (SIP + Library Validation
    /// disabled by the operator). Stored as stable string keys so the set is
    /// forward-compatible with new advanced actions.
    enum AdvancedAction: String, Codable, CaseIterable, Sendable {
        case reply
        case edit
        case unsend
        case tapback
        case typing
        case sendAttachment = "send_attachment"
        case sendEffect = "send_effect"
        case poll
        case groupManagement = "group_management"
    }

    var readableChatIds: [String]
    var writableChatIds: [String]
    var senderAllowlist: [String]
    var writeEnabled: Bool
    var defaultReadLimit: Int
    var ignoreSelfMessages: Bool
    var receiveStorageEnabled: Bool
    var receivePollingEnabled: Bool
    var pollIntervalSeconds: Int
    var attachmentIngestionEnabled: Bool
    var allowedAttachmentRoots: [String]
    var maxAttachmentBytes: Int
    /// Master gate: even individually-enabled advanced actions stay off unless
    /// this is true. Turning it on requires the operator to acknowledge the
    /// SIP/Library-Validation security warning in the setup UI.
    var advancedActionsEnabled: Bool
    var enabledAdvancedActions: [AdvancedAction]
    var inboundDispatch: AgentChannelInboundDispatchConfiguration

    enum CodingKeys: String, CodingKey {
        case readableChatIds
        case writableChatIds
        case senderAllowlist
        case writeEnabled
        case defaultReadLimit
        case ignoreSelfMessages
        case receiveStorageEnabled
        case receivePollingEnabled
        case pollIntervalSeconds
        case attachmentIngestionEnabled
        case allowedAttachmentRoots
        case maxAttachmentBytes
        case advancedActionsEnabled
        case enabledAdvancedActions
        case inboundDispatch
    }

    static let defaultMaxAttachmentBytes = 25 * 1_024 * 1_024

    /// Default attachment root: Messages stores inbound attachments under the
    /// user's Library. Ingestion stays off by default; when enabled, only
    /// files under an allowlisted root of this shape are readable.
    static var defaultAttachmentRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/Library/Messages/Attachments"]
    }

    init(
        readableChatIds: [String] = [],
        writableChatIds: [String] = [],
        senderAllowlist: [String] = [],
        writeEnabled: Bool = false,
        defaultReadLimit: Int = 50,
        ignoreSelfMessages: Bool = true,
        receiveStorageEnabled: Bool = true,
        receivePollingEnabled: Bool = false,
        pollIntervalSeconds: Int = 3,
        attachmentIngestionEnabled: Bool = false,
        allowedAttachmentRoots: [String]? = nil,
        maxAttachmentBytes: Int = IMessageConnectionConfiguration.defaultMaxAttachmentBytes,
        advancedActionsEnabled: Bool = false,
        enabledAdvancedActions: [AdvancedAction] = [],
        inboundDispatch: AgentChannelInboundDispatchConfiguration = AgentChannelInboundDispatchConfiguration(
            requireMention: false
        )
    ) {
        self.readableChatIds = Self.normalizedIds(readableChatIds)
        self.writableChatIds = Self.normalizedIds(writableChatIds)
        self.senderAllowlist = Self.normalizedIds(senderAllowlist)
        self.writeEnabled = writeEnabled
        self.defaultReadLimit = Self.clampReadLimit(defaultReadLimit)
        self.ignoreSelfMessages = ignoreSelfMessages
        self.receiveStorageEnabled = receiveStorageEnabled
        self.receivePollingEnabled = receivePollingEnabled
        self.pollIntervalSeconds = Self.clampPollInterval(pollIntervalSeconds)
        self.attachmentIngestionEnabled = attachmentIngestionEnabled
        self.allowedAttachmentRoots = Self.normalizedRoots(
            allowedAttachmentRoots ?? Self.defaultAttachmentRoots
        )
        self.maxAttachmentBytes = Self.clampAttachmentBytes(maxAttachmentBytes)
        self.advancedActionsEnabled = advancedActionsEnabled
        self.enabledAdvancedActions = Self.normalizedAdvancedActions(enabledAdvancedActions)
        self.inboundDispatch = inboundDispatch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            readableChatIds: try container.decodeIfPresent([String].self, forKey: .readableChatIds) ?? [],
            writableChatIds: try container.decodeIfPresent([String].self, forKey: .writableChatIds) ?? [],
            senderAllowlist: try container.decodeIfPresent([String].self, forKey: .senderAllowlist) ?? [],
            writeEnabled: try container.decodeIfPresent(Bool.self, forKey: .writeEnabled) ?? false,
            defaultReadLimit: try container.decodeIfPresent(Int.self, forKey: .defaultReadLimit) ?? 50,
            ignoreSelfMessages: try container.decodeIfPresent(Bool.self, forKey: .ignoreSelfMessages) ?? true,
            receiveStorageEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .receiveStorageEnabled
            ) ?? true,
            receivePollingEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .receivePollingEnabled
            ) ?? false,
            pollIntervalSeconds: try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 3,
            attachmentIngestionEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .attachmentIngestionEnabled
            ) ?? false,
            allowedAttachmentRoots: try container.decodeIfPresent(
                [String].self,
                forKey: .allowedAttachmentRoots
            ),
            maxAttachmentBytes: try container.decodeIfPresent(
                Int.self,
                forKey: .maxAttachmentBytes
            ) ?? Self.defaultMaxAttachmentBytes,
            advancedActionsEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .advancedActionsEnabled
            ) ?? false,
            enabledAdvancedActions: try container.decodeIfPresent(
                [AdvancedAction].self,
                forKey: .enabledAdvancedActions
            ) ?? [],
            inboundDispatch: try container.decodeIfPresent(
                AgentChannelInboundDispatchConfiguration.self,
                forKey: .inboundDispatch
            ) ?? AgentChannelInboundDispatchConfiguration(requireMention: false)
        )
    }

    var normalized: IMessageConnectionConfiguration {
        IMessageConnectionConfiguration(
            readableChatIds: readableChatIds,
            writableChatIds: writableChatIds,
            senderAllowlist: senderAllowlist,
            writeEnabled: writeEnabled,
            defaultReadLimit: defaultReadLimit,
            ignoreSelfMessages: ignoreSelfMessages,
            receiveStorageEnabled: receiveStorageEnabled,
            receivePollingEnabled: receivePollingEnabled,
            pollIntervalSeconds: pollIntervalSeconds,
            attachmentIngestionEnabled: attachmentIngestionEnabled,
            allowedAttachmentRoots: allowedAttachmentRoots,
            maxAttachmentBytes: maxAttachmentBytes,
            advancedActionsEnabled: advancedActionsEnabled,
            enabledAdvancedActions: enabledAdvancedActions,
            inboundDispatch: inboundDispatch
        )
    }

    func canRead(chatId: String) -> Bool {
        readableChatIds.contains(Self.normalizedId(chatId))
    }

    func canWrite(chatId: String) -> Bool {
        writeEnabled && writableChatIds.contains(Self.normalizedId(chatId))
    }

    var configuredChatIds: [String] {
        Self.normalizedIds(readableChatIds + writableChatIds)
    }

    /// Advanced action is usable only when the master gate is on and the
    /// specific action is individually enabled.
    func isAdvancedActionEnabled(_ action: AdvancedAction) -> Bool {
        advancedActionsEnabled && enabledAdvancedActions.contains(action)
    }

    /// Whether the local desktop receive loop should run.
    func canStartReceive() -> Bool {
        receiveStorageEnabled
            && receivePollingEnabled
            && !readableChatIds.isEmpty
            && !senderAllowlist.isEmpty
    }

    /// True when a candidate attachment path is inside an allowlisted root
    /// and contains no traversal escape. Symlinks are resolved on both the
    /// candidate and the roots before the containment check, so a link
    /// planted inside an allowlisted root cannot smuggle a file from
    /// outside it (and `/tmp` vs `/private/tmp` style prefixes compare
    /// consistently).
    func isAttachmentPathAllowed(_ path: String) -> Bool {
        guard attachmentIngestionEnabled else { return false }
        let standardized = (path as NSString).standardizingPath
        guard !standardized.contains("..") else { return false }
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        return allowedAttachmentRoots.contains { root in
            let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            return resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/")
        }
    }

    static func normalizedIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return
            ids
            .map(normalizedId)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// iMessage identifiers are case-sensitive GUIDs (chat rowids / service
    /// GUIDs) or handles (phone numbers, emails). Trim whitespace; lowercase
    /// email handles only so allowlist matching is stable without corrupting
    /// GUIDs.
    static func normalizedId(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") && !trimmed.contains(";") {
            return trimmed.lowercased()
        }
        return trimmed
    }

    static func isValidChatId(_ id: String) -> Bool {
        !normalizedId(id).isEmpty
    }

    static func normalizedRoots(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        return
            roots
            .map { ($0.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).standardizingPath }
            .filter { !$0.isEmpty && !$0.contains("..") && seen.insert($0).inserted }
    }

    static func normalizedAdvancedActions(_ actions: [AdvancedAction]) -> [AdvancedAction] {
        var seen = Set<AdvancedAction>()
        return actions.filter { seen.insert($0).inserted }
    }

    static func clampReadLimit(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }

    static func clampPollInterval(_ value: Int) -> Int {
        min(max(value, 1), 60)
    }

    static func clampAttachmentBytes(_ value: Int) -> Int {
        min(max(value, 1_024), 100 * 1_024 * 1_024)
    }
}

enum IMessageConnectionConfigurationStore {
    nonisolated(unsafe) static var overrideDirectory: URL?

    private static let fileName = "imessage.json"

    static func load() -> IMessageConnectionConfiguration {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return IMessageConnectionConfiguration()
        }
        do {
            return try JSONDecoder()
                .decode(IMessageConnectionConfiguration.self, from: Data(contentsOf: url))
                .normalized
        } catch {
            NSLog("[iMessage] Failed to load iMessage configuration: \(error.localizedDescription)")
            return IMessageConnectionConfiguration()
        }
    }

    static func save(_ configuration: IMessageConnectionConfiguration) throws {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration.normalized).write(to: url, options: [.atomic])
    }

    static func configurationFileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent(fileName)
        }
        return OsaurusPaths.config().appendingPathComponent(fileName)
    }
}
