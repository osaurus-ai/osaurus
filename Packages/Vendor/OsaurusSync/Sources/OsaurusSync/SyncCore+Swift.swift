import Foundation

/// Stable numeric codes carried by every `SyncError`.
public enum SyncErrorCode {
    public static let storage: UInt32 = 100
    public static let invalidInput: UInt32 = 101
    public static let notFound: UInt32 = 102
    public static let permissionDenied: UInt32 = 103
    public static let crypto: UInt32 = 104
    public static let malformed: UInt32 = 105
    public static let alreadyOpen: UInt32 = 106
    public static let deviceRevoked: UInt32 = 107
    public static let noKey: UInt32 = 108
    public static let network: UInt32 = 109
    public static let incompatibleVersion: UInt32 = 110
    public static let pairing: UInt32 = 111
    public static let closed: UInt32 = 112
    public static let keyStore: UInt32 = 113
    public static let corrupt: UInt32 = 114
    public static let newerDatabase: UInt32 = 115
    public static let internalError: UInt32 = 199
}

extension SyncError {
    public var code: UInt32 {
        switch self {
        case let .Storage(code, _), let .InvalidInput(code, _), let .NotFound(code, _),
             let .PermissionDenied(code, _), let .Crypto(code, _), let .Malformed(code, _),
             let .AlreadyOpen(code, _), let .DeviceRevoked(code, _), let .NoKey(code, _),
             let .Network(code, _), let .IncompatibleVersion(code, _), let .Pairing(code, _),
             let .Closed(code, _), let .KeyStore(code, _), let .Internal(code, _),
             let .Corrupt(code, _), let .NewerDatabase(code, _):
            return code
        }
    }
}

extension Platform {
    public static var current: Platform {
        #if os(iOS)
        return .ios
        #elseif os(macOS)
        return .macOs
        #else
        return .other
        #endif
    }
}

extension SyncCore {
    /// Opens the core with the bindings' API version filled in.
    ///
    /// `history` nil picks the platform default: the last 90 days on iOS with older ranges on
    /// demand, everything on macOS. `maxAppDataBytes` nil keeps the 64 KiB default.
    public static func open(
        dataDirectory: URL,
        deviceName: String,
        platform: Platform = .current,
        history: HistoryMode? = nil,
        network: NetworkConfig = defaultNetworkConfig(),
        maxAppDataBytes: UInt32? = nil,
        keyStore: KeyStore = KeychainKeyStore()
    ) throws -> SyncCore {
        let config = CoreConfig(
            dataDir: dataDirectory.path,
            deviceName: deviceName,
            platform: platform,
            history: history,
            network: network,
            maxAppDataBytes: maxAppDataBytes,
            apiVersion: OsaurusSync.apiVersion()
        )
        return try SyncCore.open(config: config, keyStore: keyStore)
    }

    /// Subscribes with a closure. Keep the returned subscription alive.
    public func subscribe(scope: String, _ onChanges: @escaping @Sendable ([ScopeChange]) -> Void) throws -> Subscription {
        try subscribe(scope: scope, listener: ClosureScopeListener(onChanges))
    }

    public func subscribeConversations(_ onChanges: @escaping @Sendable ([ConversationChange]) -> Void) -> Subscription {
        subscribeConversations(listener: ClosureConversationListener(onChanges))
    }

    public func setListener(_ onEvent: @escaping @Sendable (CoreEvent) -> Void) {
        setListener(listener: ClosureCoreListener(onEvent))
    }

    /// Creates a conversation that syncs with this user's other devices.
    public func createConversation(title: String) throws -> String {
        try createConversation(title: title, replication: .synced)
    }

    /// Conversations carrying every given tag, in list order.
    public func conversations(tagged tags: [String: String]) throws -> [Conversation] {
        try conversationsFiltered(filter: ConversationFilter(tags: tags.sorted { $0.key < $1.key }.map { Tag(key: $0.key, value: $0.value) }))
    }
}

extension Conversation {
    /// The value of tag `key`, if set.
    public func tag(_ key: String) -> String? {
        tags.first { $0.key == key }?.value
    }

    /// Conversation-level app data under `namespace`.
    public func appData(_ namespace: String) -> Data? {
        appData.first { $0.namespace == namespace }?.bytes
    }
}

extension Message {
    /// This message's app data under `namespace`.
    public func appData(_ namespace: String) -> AppData? {
        appData.first { $0.namespace == namespace }
    }
}

extension AppDataWrite {
    public init(namespace: String, bytes: Data) {
        self.init(namespace: namespace, bytes: bytes, attachments: [])
    }
}

extension OutgoingStream {
    /// Commits the streamed text (or `content`) with no app data.
    @discardableResult
    public func finish(content: String? = nil) throws -> String {
        try finish(content: content, appData: [])
    }
}

extension LegacyConversation {
    public init(title: String, createdMs: UInt64, replication: Replication = .synced) {
        self.init(title: title, createdMs: createdMs, replication: replication, pinned: false, archived: false, tags: [], appData: [])
    }
}

extension LegacyMessage {
    public static func text(_ content: String, role: MessageRole = .user, createdMs: UInt64) -> LegacyMessage {
        LegacyMessage(role: role, content: content, createdMs: createdMs, attachments: [], toolCallId: nil, toolName: nil, appData: [])
    }
}

extension OutgoingMessage {
    public static func text(_ content: String, role: MessageRole = .user) -> OutgoingMessage {
        OutgoingMessage(role: role, content: content, attachments: [], replyTo: nil, asAgent: nil, toolCallId: nil, toolName: nil, appData: [])
    }
}

final class ClosureScopeListener: ScopeListener, @unchecked Sendable {
    let f: @Sendable ([ScopeChange]) -> Void
    init(_ f: @escaping @Sendable ([ScopeChange]) -> Void) { self.f = f }
    func onChanges(changes: [ScopeChange]) { f(changes) }
}

final class ClosureConversationListener: ConversationListener, @unchecked Sendable {
    let f: @Sendable ([ConversationChange]) -> Void
    init(_ f: @escaping @Sendable ([ConversationChange]) -> Void) { self.f = f }
    func onChanges(changes: [ConversationChange]) { f(changes) }
}

final class ClosureCoreListener: CoreListener, @unchecked Sendable {
    let f: @Sendable (CoreEvent) -> Void
    init(_ f: @escaping @Sendable (CoreEvent) -> Void) { self.f = f }
    func onEvent(event: CoreEvent) { f(event) }
}
