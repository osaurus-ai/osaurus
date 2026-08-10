//
//  WhatsAppConnectionConfiguration.swift
//  osaurus
//
//  Non-secret configuration for the native WhatsApp connection.
//
//  WhatsApp has no bot token: the channel drives a local `osaurus-wa` helper
//  (a whatsmeow-based WhatsApp Web bridge) linked to the user's own WhatsApp
//  account via QR code. The linked session lives in the helper's store
//  directory; authorization here is entirely local — chat/sender allowlists,
//  a write kill switch, and inbound dispatch settings. Everything defaults
//  to the safest state (writes off, receive off).
//

import Foundation

struct WhatsAppConnectionConfiguration: Codable, Equatable, Sendable {
    /// Chats (E.164 phone numbers or WhatsApp JIDs like `12065551234@s.whatsapp.net`
    /// / `1203630...@g.us`) whose messages may be read/stored.
    var readableChatIds: [String]
    var writableChatIds: [String]
    /// Senders (E.164 phone numbers or user JIDs) authorized for inbound
    /// dispatch. Empty means receive stays off.
    var senderAllowlist: [String]
    var writeEnabled: Bool
    var defaultReadLimit: Int
    /// Drop messages sent from the linked account itself (including other
    /// linked devices). Turning this off is the single-device test loop.
    var ignoreSelfMessages: Bool
    /// Master receive gate: the watch transport only runs when this is on.
    var receiveEnabled: Bool
    /// Mark allowlisted inbound messages as read on WhatsApp (blue ticks)
    /// after they are stored. Off by default: read receipts are visible to
    /// the other party.
    var sendReadReceipts: Bool
    /// Download inbound media (images, video, audio, documents, stickers)
    /// into the local media directory and record it as attachments. Also
    /// gates outbound attachment sends (the path fence below).
    var attachmentIngestionEnabled: Bool
    /// Roots the outbound attachment sender may read from. Inbound media is
    /// always written inside the default media directory.
    var allowedAttachmentRoots: [String]
    var maxAttachmentBytes: Int
    var inboundDispatch: AgentChannelInboundDispatchConfiguration

    enum CodingKeys: String, CodingKey {
        case readableChatIds
        case writableChatIds
        case senderAllowlist
        case writeEnabled
        case defaultReadLimit
        case ignoreSelfMessages
        case receiveEnabled
        case sendReadReceipts
        case attachmentIngestionEnabled
        case allowedAttachmentRoots
        case maxAttachmentBytes
        case inboundDispatch
    }

    static let defaultMaxAttachmentBytes = 25 * 1_024 * 1_024

    /// Media the helper downloads lands here; it is also the default root
    /// the outbound attachment sender may read from (so re-sharing received
    /// media works without extra configuration).
    static func mediaDirectoryURL() -> URL {
        OsaurusPaths.root()
            .appendingPathComponent("whatsapp")
            .appendingPathComponent("media")
    }

    static var defaultAttachmentRoots: [String] {
        [mediaDirectoryURL().path]
    }

    init(
        readableChatIds: [String] = [],
        writableChatIds: [String] = [],
        senderAllowlist: [String] = [],
        writeEnabled: Bool = false,
        defaultReadLimit: Int = 50,
        ignoreSelfMessages: Bool = true,
        receiveEnabled: Bool = false,
        sendReadReceipts: Bool = false,
        attachmentIngestionEnabled: Bool = false,
        allowedAttachmentRoots: [String]? = nil,
        maxAttachmentBytes: Int = WhatsAppConnectionConfiguration.defaultMaxAttachmentBytes,
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
        self.receiveEnabled = receiveEnabled
        self.sendReadReceipts = sendReadReceipts
        self.attachmentIngestionEnabled = attachmentIngestionEnabled
        self.allowedAttachmentRoots = Self.normalizedRoots(
            allowedAttachmentRoots ?? Self.defaultAttachmentRoots
        )
        self.maxAttachmentBytes = Self.clampAttachmentBytes(maxAttachmentBytes)
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
            receiveEnabled: try container.decodeIfPresent(Bool.self, forKey: .receiveEnabled) ?? false,
            sendReadReceipts: try container.decodeIfPresent(Bool.self, forKey: .sendReadReceipts)
                ?? false,
            attachmentIngestionEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .attachmentIngestionEnabled
            ) ?? false,
            allowedAttachmentRoots: try container.decodeIfPresent(
                [String].self,
                forKey: .allowedAttachmentRoots
            ),
            maxAttachmentBytes: try container.decodeIfPresent(Int.self, forKey: .maxAttachmentBytes)
                ?? Self.defaultMaxAttachmentBytes,
            inboundDispatch: try container.decodeIfPresent(
                AgentChannelInboundDispatchConfiguration.self,
                forKey: .inboundDispatch
            ) ?? AgentChannelInboundDispatchConfiguration(requireMention: false)
        )
    }

    var normalized: WhatsAppConnectionConfiguration {
        WhatsAppConnectionConfiguration(
            readableChatIds: readableChatIds,
            writableChatIds: writableChatIds,
            senderAllowlist: senderAllowlist,
            writeEnabled: writeEnabled,
            defaultReadLimit: defaultReadLimit,
            ignoreSelfMessages: ignoreSelfMessages,
            receiveEnabled: receiveEnabled,
            sendReadReceipts: sendReadReceipts,
            attachmentIngestionEnabled: attachmentIngestionEnabled,
            allowedAttachmentRoots: allowedAttachmentRoots,
            maxAttachmentBytes: maxAttachmentBytes,
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

    /// Whether the watch receive loop should run (given a linked helper).
    func canStartReceive() -> Bool {
        receiveEnabled
            && !readableChatIds.isEmpty
            && !senderAllowlist.isEmpty
    }

    /// True when a candidate attachment path is inside an allowlisted root
    /// and contains no traversal escape. Symlinks are resolved on both the
    /// candidate and the roots before the containment check (same fence as
    /// the iMessage channel).
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

    static func normalizedRoots(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        return
            roots
            .map { ($0 as NSString).standardizingPath }
            .filter { !$0.isEmpty && $0 != "/" && seen.insert($0).inserted }
    }

    static func clampAttachmentBytes(_ value: Int) -> Int {
        min(max(value, 64 * 1_024), 100 * 1_024 * 1_024)
    }

    /// WhatsApp identifiers are JIDs (`<user>@s.whatsapp.net`, `<id>@g.us`)
    /// or phone numbers. Direct-chat JIDs (`<phone>[.agent][:device]@s.whatsapp.net`,
    /// as the watch stream and whatsmeow store report them) normalize to the
    /// canonical `+digits` phone form so watch rows, sends, and allowlists
    /// share one id space; other JIDs (groups `@g.us`, lids) lowercase;
    /// phone numbers reduce to `+digits` so `+1 (206) 555-1234` and
    /// `12065551234` match.
    static func normalizedId(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") {
            let lowered = trimmed.lowercased()
            if lowered.hasSuffix("@s.whatsapp.net") {
                let phone = lowered.prefix(while: \.isNumber)
                if !phone.isEmpty { return "+" + phone }
            }
            return lowered
        }
        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        return "+" + digits
    }

    static func isValidChatId(_ id: String) -> Bool {
        !normalizedId(id).isEmpty
    }

    static func clampReadLimit(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }
}

enum WhatsAppConnectionConfigurationStore {
    nonisolated(unsafe) static var overrideDirectory: URL?

    private static let fileName = "whatsapp.json"

    static func load() -> WhatsAppConnectionConfiguration {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return WhatsAppConnectionConfiguration()
        }
        do {
            return try JSONDecoder()
                .decode(WhatsAppConnectionConfiguration.self, from: Data(contentsOf: url))
                .normalized
        } catch {
            NSLog("[WhatsApp] Failed to load WhatsApp configuration: \(error.localizedDescription)")
            return WhatsAppConnectionConfiguration()
        }
    }

    static func save(_ configuration: WhatsAppConnectionConfiguration) throws {
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
