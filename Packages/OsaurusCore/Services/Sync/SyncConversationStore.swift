//
//  SyncConversationStore.swift
//  osaurus
//
//  Conversation storage on the sync core. Each Osaurus session is one sync
//  conversation (synced for chats, device-local for headless runs) and each
//  turn one message. Saves are diffs: only turns whose content or app data
//  changed produce events, since synced history only grows.
//

import Foundation
import OsaurusSync
import os

enum SyncConversationStoreError: Error {
    case notOpen
}

final class SyncConversationStore: ConversationStore, @unchecked Sendable {
    static let shared = SyncConversationStore()

    /// Posted on the main queue when blobs a loaded session was missing have
    /// arrived; `userInfo["sessionId"]` is the session's UUID.
    static let didFetchMissingContentNotification = Notification.Name("SyncConversationStore.didFetchMissingContent")

    private static let log = Logger(subsystem: "ai.osaurus", category: "sync.store")
    private static let pageSize: UInt32 = 500
    private static let blobReadTimeout: TimeInterval = 10

    /// What was last written for one turn.
    struct MessageRef {
        var messageId: String
        var contentHash: String
        var appDataHash: String
        /// Fields another writer stored in the turn's app data.
        var extras: JSONObject
        /// Some of the turn's blobs weren't on this device when it was read,
        /// so its app data must not be rewritten from that copy.
        var incomplete: Bool
        /// Attachments the message carries natively. A message's files can't
        /// change after it is sent, so a turn that gains one is sent again.
        var attachmentIds: Set<UUID>
        /// This device wrote the message, so it alone writes its turn detail.
        var authoredHere = true
        var detailHash: String?
    }

    /// One session's messages, in order.
    struct SessionIndex {
        var order: [UUID] = []
        var refs: [UUID: MessageRef] = [:]
        /// Messages repeating a turn another message carries; the next save removes them.
        var repeated: Set<String> = []
    }

    private let lock = NSLock()
    /// Writes run here, in order. Reads wait behind them, so a caller reads
    /// back what it just saved.
    private let queue = DispatchQueue(label: "ai.osaurus.sync.store", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private var coreIdentity: ObjectIdentifier?
    private var scopes: [UUID: String] = [:]
    private var indexes: [UUID: SessionIndex] = [:]
    /// Turns each session's caller has seen, through a load or a save. A save
    /// deletes a stored turn it leaves out only when it saw that turn, so it
    /// can't remove what another device added meanwhile, and doesn't re-send
    /// a seen turn that another device removed.
    private var known: [UUID: Set<UUID>] = [:]
    /// Turns this device's own saves removed, so putting one back re-sends it.
    private var removedHere: [UUID: Set<UUID>] = [:]
    /// Sessions with no turns. They get a conversation once they have content.
    private var drafts: [UUID: ChatSessionData] = [:]
    private var lastLocalWrite: [String: Date] = [:]
    private var fetching: Set<String> = []
    /// The agent this device's replies in a session are sent as, by session.
    private var agentSenders: [UUID: String] = [:]
    /// What a failed save was compared against, kept for its retry.
    private var droppedSeen: [UUID: Seen] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        queue.setSpecific(key: queueKey, value: ())
        observer = NotificationCenter.default.addObserver(
            forName: SyncService.didReplaceIdentityNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidateCaches()
        }
    }

    // MARK: - Lifecycle

    func open() throws {
        try SyncService.shared.open()
    }

    var isOpenNonBlocking: Bool { SyncService.shared.isOpen }

    /// Waits for queued writes, up to `timeout` seconds.
    func drain(timeout: TimeInterval) {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    func invalidateCaches() {
        lock.withLock {
            scopes.removeAll()
            indexes.removeAll()
            known.removeAll()
            removedHere.removeAll()
            droppedSeen.removeAll()
            agentSenders.removeAll()
            coreIdentity = nil
        }
    }

    /// Sends the session's assistant and tool turns as `agent` (an agent id
    /// assigned to the conversation and hosted here), or as this device when nil.
    func setAgentSender(_ agent: String?, forSession id: UUID) {
        lock.withLock { agentSenders[id] = agent }
    }

    func agentSender(forSession id: UUID) -> String? {
        lock.withLock { agentSenders[id] }
    }

    /// Another device changed the session: re-read its messages before the
    /// next save diffs against them.
    func invalidate(sessionId: UUID) {
        queue.async { [self] in
            lock.withLock { indexes[sessionId] = nil }
        }
    }

    private func currentCore() -> SyncCore? {
        guard let core = SyncService.shared.core else { return nil }
        let identity = ObjectIdentifier(core)
        lock.withLock {
            if coreIdentity != identity {
                scopes.removeAll()
                indexes.removeAll()
                known.removeAll()
                removedHere.removeAll()
                coreIdentity = identity
            }
        }
        return core
    }

    private func requireCore() throws -> SyncCore {
        guard let core = currentCore() else { throw SyncConversationStoreError.notOpen }
        return core
    }

    /// True when this device wrote to `scope` in the last `window` seconds.
    func wroteLocally(scope: String, within window: TimeInterval) -> Bool {
        lock.withLock {
            guard let date = lastLocalWrite[scope] else { return false }
            return Date().timeIntervalSince(date) < window
        }
    }

    private func noteLocalWrite(_ scope: String) {
        lock.withLock { lastLocalWrite[scope] = Date() }
    }

    // MARK: - Scope lookup

    func scope(forSession id: UUID) -> String? {
        guard let core = currentCore() else { return nil }
        return scope(for: id, core: core)
    }

    func sessionId(forScope scope: String) -> UUID? {
        if let id = lock.withLock({ scopes.first { $0.value == scope }?.key }) { return id }
        guard let core = currentCore(), let conversation = try? core.conversation(scope: scope),
            !SyncConversationMapper.isAppInternal(conversation)
        else { return nil }
        let id = SyncConversationMapper.sessionId(of: conversation)
        lock.withLock { scopes[id] = scope }
        return id
    }

    /// The conversation is gone from the core: drops what was cached for it
    /// and returns its session id, if it was known.
    func forget(scope: String) -> UUID? {
        lock.withLock {
            guard let id = scopes.first(where: { $0.value == scope })?.key else { return nil }
            scopes[id] = nil
            indexes[id] = nil
            known[id] = nil
            removedHere[id] = nil
            return id
        }
    }

    private func scope(for id: UUID, core: SyncCore) -> String? {
        if let cached = lock.withLock({ scopes[id] }) { return cached }
        // Tag filters match exactly. This Mac writes lowercase; a client
        // using Swift's `uuidString` as is writes uppercase.
        for value in [id.uuidString.lowercased(), id.uuidString.uppercased()] {
            let filter = ConversationFilter(
                tags: [Tag(key: SyncConversationMapper.TagKey.session, value: value)],
                limit: 1
            )
            if let match = try? core.conversationsFiltered(filter: filter).first {
                lock.withLock { scopes[id] = match.scope }
                return match.scope
            }
        }
        // Conversations from clients that don't tag them carry a derived id.
        for conversation in (try? core.conversations()) ?? []
        where conversation.kind == .conversation && conversation.tag(SyncConversationMapper.TagKey.session) == nil
            && !SyncConversationMapper.isAppInternal(conversation)
        {
            let derived = SyncConversationMapper.sessionId(of: conversation)
            lock.withLock { scopes[derived] = conversation.scope }
            if derived == id { return conversation.scope }
        }
        return nil
    }

    // MARK: - Saving

    func saveSession(_ session: ChatSessionData) throws {
        let seen = noteSeen(session)
        let trace = Self.callerTrace()
        try queue.sync {
            Self.currentSaveTrace = trace
            defer { Self.currentSaveTrace = nil }
            try save(session, seen: seen)
        }
    }

    func saveSessionAsync(
        _ session: ChatSessionData,
        onSaved: (@Sendable () -> Void)? = nil,
        onDropped: (@Sendable (ChatSessionData) -> Void)? = nil
    ) {
        enqueueSave(session, seen: noteSeen(session), onSaved: onSaved, onDropped: onDropped)
    }

    /// A failed save tried again. It's compared against what the store had
    /// seen when it was first handed over, not now: turns stored since then
    /// (another device's prompt, a reply the Mac wrote meanwhile) arrived
    /// from elsewhere and are kept. Compared against now, the old snapshot
    /// deleted them as if this Mac had removed them.
    func retrySessionSaveAsync(
        _ session: ChatSessionData,
        onSaved: (@Sendable () -> Void)? = nil,
        onDropped: (@Sendable (ChatSessionData) -> Void)? = nil
    ) {
        let original = lock.withLock { droppedSeen.removeValue(forKey: session.id) }
        let seen = noteSeen(session)
        enqueueSave(session, seen: original ?? seen, onSaved: onSaved, onDropped: onDropped)
    }

    /// Keeps what a save of `session` compares against now, as a failed save
    /// keeps it for its retry. For tests, which can't make a save fail.
    func keepRetryBasis(for session: ChatSessionData) {
        guard let seen = noteSeen(session) else { return }
        lock.withLock { droppedSeen[session.id] = seen }
    }

    private func enqueueSave(
        _ session: ChatSessionData,
        seen: Seen?,
        onSaved: (@Sendable () -> Void)?,
        onDropped: (@Sendable (ChatSessionData) -> Void)?
    ) {
        let trace = Self.callerTrace()
        queue.async { [self] in
            Self.currentSaveTrace = trace
            defer { Self.currentSaveTrace = nil }
            do {
                try save(session, seen: seen)
                onSaved?()
            } catch {
                Self.log.error("save failed for \(session.id, privacy: .public): \(Self.describe(error), privacy: .public)")
                #if DEBUG
                    print("[SyncStore] save failed for \(session.id): \(Self.describe(error))")
                #endif
                // Kept for its retry, which compares as of this first try.
                if let seen { lock.withLock { droppedSeen[session.id] = droppedSeen[session.id] ?? seen } }
                onDropped?(session)
            }
        }
    }

    /// What the caller knew when it handed over a session.
    private struct Seen {
        /// Turns it had loaded or saved before.
        var before: Set<UUID>
        /// Those plus the turns it's saving now.
        var all: Set<UUID>
    }

    /// Nil before any load or save of the session this launch.
    private func noteSeen(_ session: ChatSessionData) -> Seen? {
        lock.withLock {
            guard let before = known[session.id] else { return nil }
            let all = before.union(session.turns.map(\.id))
            known[session.id] = all
            return Seen(before: before, all: all)
        }
    }

    /// Runs on `queue`.
    private func save(_ session: ChatSessionData, seen: Seen?) throws {
        let core = try requireCore()
        let existingScope = scope(for: session.id, core: core)
        guard !session.turns.isEmpty else {
            if let existingScope {
                try updateMetadata(of: session, scope: existingScope, core: core)
            } else {
                lock.withLock { drafts[session.id] = session }
            }
            return
        }
        lock.withLock { drafts[session.id] = nil }

        let encoded = try session.turns.map { turn in
            try SyncConversationMapper.encode(
                turn: turn,
                toolName: SyncConversationMapper.toolName(for: turn, in: session.turns),
                existing: lock.withLock { indexes[session.id]?.refs[turn.id]?.extras }
            )
        }
        var overflow: [UUID: JSONObject] = [:]
        for (turn, encodedTurn) in zip(session.turns, encoded) where !encodedTurn.overflow.isEmpty {
            overflow[turn.id] = encodedTurn.overflow
        }

        if let existingScope {
            try updateMetadata(of: session, scope: existingScope, core: core)
            try saveTurns(of: session, encoded: encoded, seen: seen, scope: existingScope, core: core)
        } else {
            try create(session, encoded: encoded, core: core)
        }
        SyncLocalSessionStore.save(SyncLocalSessionStore.state(for: session, overflow: overflow), for: session.id)
    }

    private func create(_ session: ChatSessionData, encoded: [SyncConversationMapper.EncodedTurn], core: SyncCore)
        throws
    {
        let files = TemporaryFiles()
        defer { files.removeAll() }
        var clockMs = UInt64(max(0, session.createdAt.timeIntervalSince1970 * 1000))
        var messages: [LegacyMessage] = []
        for (turn, encodedTurn) in zip(session.turns, encoded) {
            // Imported messages sort by their timestamps, so they must not go backwards.
            if let created = turn.createdAt {
                clockMs = max(clockMs, UInt64(max(0, created.timeIntervalSince1970 * 1000)))
            }
            messages.append(
                LegacyMessage(
                    role: encodedTurn.role,
                    content: encodedTurn.content,
                    createdMs: clockMs,
                    attachments: try files.attachments(for: encodedTurn),
                    toolCallId: encodedTurn.toolCallId,
                    toolName: encodedTurn.toolName,
                    appData: try files.appDataWrites(for: encodedTurn)
                )
            )
        }
        let conversation = LegacyConversation(
            title: session.title,
            createdMs: UInt64(max(0, session.createdAt.timeIntervalSince1970 * 1000)),
            replication: SyncConversationMapper.replication(for: session.source),
            pinned: session.pinned,
            archived: session.archived,
            tags: Self.withServedBy(SyncConversationMapper.tags(for: session), for: session, core: core),
            appData: [
                AppDataEntry(
                    namespace: SyncConversationMapper.sessionNamespace,
                    bytes: try SyncConversationMapper.sessionAppData(for: session)
                )
            ]
        )
        let scope = try core.importLegacyConversation(conversation: conversation, messages: messages)
        noteLocalWrite(scope)
        lock.withLock {
            scopes[session.id] = scope
            known[session.id] = Set(session.turns.map(\.id))
        }
        _ = try index(for: session.id, scope: scope, core: core, reload: true)
    }

    private func saveTurns(
        of session: ChatSessionData,
        encoded: [SyncConversationMapper.EncodedTurn],
        seen: Seen?,
        scope: String,
        core: SyncCore
    ) throws {
        var index = try index(for: session.id, scope: scope, core: core)
        for messageId in index.repeated {
            try ignoringNotFound { try core.deleteMessage(id: messageId) }
        }
        index.repeated = []
        // Stored turns the caller never saw arrived from another device; turns
        // it saw before that are no longer stored were removed by one.
        let arrived = Set(index.order.filter { id in seen.map { !$0.all.contains(id) } ?? false })
        let ownRemovals = lock.withLock { removedHere[session.id] ?? [] }
        let removedElsewhere = Set(
            session.turns.map(\.id).filter {
                seen?.before.contains($0) == true && index.refs[$0] == nil && !ownRemovals.contains($0)
            })
        let turns = zip(session.turns, encoded).filter { !removedElsewhere.contains($0.0.id) }
        let desired = turns.map(\.0.id)
        let desiredSet = Set(desired)

        // Turns that keep their message: those already stored, in stored order,
        // up to the first one whose position changed or that a new turn precedes.
        var kept: Set<UUID> = []
        var storedPosition = 0
        let stored = index.order.filter { desiredSet.contains($0) }
        let attachmentIds = Dictionary(turns.map { ($0.0.id, Set($0.0.attachments.map(\.id))) }) { first, _ in first }
        for id in desired {
            guard let ref = index.refs[id] else { break }
            guard storedPosition < stored.count, stored[storedPosition] == id else { break }
            guard attachmentIds[id, default: []].isSubset(of: ref.attachmentIds) else { break }
            kept.insert(id)
            storedPosition += 1
        }

        var dropped: Set<UUID> = []
        for id in index.order where !kept.contains(id) && !arrived.contains(id) {
            guard let ref = index.refs[id] else { continue }
            Self.noteDeletion(
                of: id, message: ref.messageId, session: session, desired: desired, stored: index.order,
                seen: seen, rewritten: desiredSet.contains(id))
            try ignoringNotFound { try core.deleteMessage(id: ref.messageId) }
            index.refs[id] = nil
            if !desiredSet.contains(id) { dropped.insert(id) }
        }
        index.order.removeAll { !kept.contains($0) && !arrived.contains($0) }

        let files = TemporaryFiles()
        defer { files.removeAll() }
        var agent = agentSender(forSession: session.id)
        for (turn, encodedTurn) in turns {
            let contentHash = SyncConversationMapper.sha256Hex(Data(encodedTurn.content.utf8))
            let appDataHash = SyncConversationMapper.sha256Hex(encodedTurn.appData)
            if kept.contains(turn.id), var ref = index.refs[turn.id] {
                // Only the author may change a message (`only the author can set a
                // message's app data`): one another device wrote, an iPhone's prompt
                // in a hosted chat say, stays as it wrote it. Trying failed the whole
                // save, and its retry looped every 2 seconds.
                if ref.authoredHere, turn.role != .tool, ref.contentHash != contentHash {
                    try core.editMessage(id: ref.messageId, content: encodedTurn.content)
                    ref.contentHash = contentHash
                }
                if ref.authoredHere, ref.appDataHash != appDataHash, !ref.incomplete {
                    try core.setMessageAppData(id: ref.messageId, appData: [try files.appDataWrite(for: encodedTurn)])
                    ref.appDataHash = appDataHash
                }
                if ref.authoredHere, let detail = encodedTurn.detail {
                    let detailHash = SyncConversationMapper.sha256Hex(detail.bytes)
                    if ref.detailHash != detailHash {
                        try core.setMessageAppData(id: ref.messageId, appData: [try files.detailWrite(detail)])
                        ref.detailHash = detailHash
                    }
                }
                index.refs[turn.id] = ref
                continue
            }
            var message = OutgoingMessage(
                role: encodedTurn.role,
                content: encodedTurn.content,
                attachments: try files.attachments(for: encodedTurn),
                replyTo: nil,
                asAgent: turn.role == .user ? nil : agent,
                toolCallId: encodedTurn.toolCallId,
                toolName: encodedTurn.toolName,
                appData: try files.appDataWrites(for: encodedTurn)
            )
            let messageId: String
            do {
                messageId = try core.sendMessage(scope: scope, message: message)
            } catch let error as SyncError where error.code == SyncErrorCode.permissionDenied && message.asAgent != nil {
                // The agent's assignment lapsed: the turn goes out as this device.
                Self.log.notice("agent sender refused, sending as this device: \(Self.describe(error), privacy: .public)")
                agent = nil
                setAgentSender(nil, forSession: session.id)
                message.asAgent = nil
                messageId = try core.sendMessage(scope: scope, message: message)
            }
            index.order.append(turn.id)
            index.refs[turn.id] = MessageRef(
                messageId: messageId,
                contentHash: contentHash,
                appDataHash: appDataHash,
                extras: [:],
                incomplete: false,
                attachmentIds: Set(turn.attachments.map(\.id)),
                detailHash: encodedTurn.detail.map { SyncConversationMapper.sha256Hex($0.bytes) }
            )
        }
        noteLocalWrite(scope)
        let finalIndex = index
        lock.withLock {
            indexes[session.id] = finalIndex
            known[session.id] = (known[session.id] ?? []).union(desired).subtracting(dropped)
            removedHere[session.id] = ownRemovals.subtracting(desired).union(dropped)
        }
    }

    private func updateMetadata(of session: ChatSessionData, scope: String, core: SyncCore) throws {
        guard let conversation = try core.conversation(scope: scope) else { return }
        var wrote = false
        if conversation.title != session.title {
            try core.renameConversation(scope: scope, title: session.title)
            wrote = true
        }
        if conversation.pinned != session.pinned {
            try core.setPinned(scope: scope, pinned: session.pinned)
            wrote = true
        }
        if conversation.archived != session.archived {
            try core.setArchived(scope: scope, archived: session.archived)
            wrote = true
        }
        var tags = SyncConversationMapper.tags(for: session, existing: conversation.tags)
        if conversation.replication == .deviceLocal {
            tags = Self.withServedBy(tags, for: session, core: core)
        }
        if conversation.tags.sorted(by: { $0.key < $1.key }) != tags {
            try core.setConversationTags(scope: scope, tags: tags)
            wrote = true
        }
        let existing = SyncConversationMapper.parseObject(conversation.appData(SyncConversationMapper.sessionNamespace))
        let bytes = try SyncConversationMapper.sessionAppData(for: session, existing: existing)
        if !sessionAppDataMatches(existing: existing, new: bytes) {
            try core.setConversationAppData(scope: scope, namespace: SyncConversationMapper.sessionNamespace, bytes: bytes)
            wrote = true
        }
        if session.source.syncsAcrossDevices, conversation.replication == .deviceLocal {
            try core.promoteToSynced(scope: scope)
            wrote = true
        }
        if wrote { noteLocalWrite(scope) }
    }

    /// Adds this device as the server of a `.workspace` chat that has none.
    /// Only creating or promoting the conversation does this, so a chat
    /// another Mac served keeps that Mac.
    static func withServedBy(_ tags: [Tag], for session: ChatSessionData, core: SyncCore) -> [Tag] {
        let key = SyncConversationMapper.TagKey.servedBy
        guard session.source == .workspace, !tags.contains(where: { $0.key == key }) else { return tags }
        return (tags + [Tag(key: key, value: core.deviceKey())]).sorted { $0.key < $1.key }
    }

    /// `updatedAt` alone moving doesn't need a write: the last message's time
    /// already orders the list.
    private func sessionAppDataMatches(existing: JSONObject?, new: Data) -> Bool {
        guard var old = existing, var fresh = SyncConversationMapper.parseObject(new) else { return false }
        old.removeValue(forKey: "updatedAt")
        fresh.removeValue(forKey: "updatedAt")
        guard let a = try? SyncConversationMapper.serialize(old), let b = try? SyncConversationMapper.serialize(fresh)
        else { return false }
        return a == b
    }

    // MARK: - Targeted updates

    func updateSessionTitleAsync(id: UUID, title: String, updatedAt: Date? = nil) {
        queue.async { [self] in
            if lock.withLock({ drafts[id] != nil }) {
                lock.withLock { drafts[id]?.title = title }
                return
            }
            guard let core = currentCore(), let scope = scope(for: id, core: core) else { return }
            perform("rename") {
                try core.renameConversation(scope: scope, title: title)
                if let updatedAt { try self.patchSessionAppData(scope: scope, core: core) { $0["updatedAt"] = Self.ms(updatedAt) } }
            }
            noteLocalWrite(scope)
        }
    }

    func updateSessionProjectAsync(id: UUID, projectId: UUID?) {
        queue.async { [self] in
            if lock.withLock({ drafts[id] != nil }) {
                lock.withLock { drafts[id]?.projectId = projectId }
                return
            }
            guard let core = currentCore(), let scope = scope(for: id, core: core) else { return }
            perform("project") { try self.setProject(projectId, scope: scope, core: core) }
        }
    }

    func clearProjectAsync(projectId: UUID) {
        queue.async { [self] in
            lock.withLock {
                for (id, draft) in drafts where draft.projectId == projectId { drafts[id]?.projectId = nil }
            }
            guard let core = currentCore() else { return }
            let filter = ConversationFilter(
                tags: [Tag(key: SyncConversationMapper.TagKey.projectId, value: projectId.uuidString.lowercased())]
            )
            for conversation in (try? core.conversationsFiltered(filter: filter)) ?? [] {
                perform("clear project") { try self.setProject(nil, scope: conversation.scope, core: core) }
            }
        }
    }

    private func setProject(_ projectId: UUID?, scope: String, core: SyncCore) throws {
        guard let conversation = try core.conversation(scope: scope) else { return }
        var tags = conversation.tags.filter { $0.key != SyncConversationMapper.TagKey.projectId }
        if let projectId {
            tags.append(Tag(key: SyncConversationMapper.TagKey.projectId, value: projectId.uuidString.lowercased()))
        }
        try core.setConversationTags(scope: scope, tags: tags.sorted { $0.key < $1.key })
        try patchSessionAppData(scope: scope, core: core) { object in
            if let projectId {
                object["projectId"] = projectId.uuidString.lowercased()
            } else {
                object.removeValue(forKey: "projectId")
            }
        }
        noteLocalWrite(scope)
    }

    func updateSessionArchivedAsync(id: UUID, archived: Bool) {
        queue.async { [self] in
            if lock.withLock({ drafts[id] != nil }) {
                lock.withLock { drafts[id]?.archived = archived }
                return
            }
            guard let core = currentCore(), let scope = scope(for: id, core: core) else { return }
            perform("archive") { try core.setArchived(scope: scope, archived: archived) }
            noteLocalWrite(scope)
        }
    }

    func updateSessionPinnedAsync(id: UUID, pinned: Bool) {
        queue.async { [self] in
            if lock.withLock({ drafts[id] != nil }) {
                lock.withLock { drafts[id]?.pinned = pinned }
                return
            }
            guard let core = currentCore(), let scope = scope(for: id, core: core) else { return }
            perform("pin") { try core.setPinned(scope: scope, pinned: pinned) }
            noteLocalWrite(scope)
        }
    }

    private func patchSessionAppData(scope: String, core: SyncCore, _ change: (inout JSONObject) -> Void) throws {
        guard let conversation = try core.conversation(scope: scope) else { return }
        var object = SyncConversationMapper.parseObject(conversation.appData(SyncConversationMapper.sessionNamespace)) ?? [:]
        object["v"] = 1
        change(&object)
        try core.setConversationAppData(
            scope: scope,
            namespace: SyncConversationMapper.sessionNamespace,
            bytes: try SyncConversationMapper.serialize(object)
        )
    }

    /// Commits a streamed turn as its message, in order with the session's
    /// saves: the save that follows finds it already written. A copy a save
    /// wrote before the stream opened is removed.
    func finishStream(_ stream: OutgoingStream, sessionId: UUID, turn: ChatTurnData) {
        queue.async { [self] in
            do {
                let encoded = try SyncConversationMapper.encode(turn: turn, toolName: nil)
                let files = TemporaryFiles()
                defer { files.removeAll() }
                let messageId = try stream.finish(content: encoded.content, appData: try files.appDataWrites(for: encoded))
                if let saved = lock.withLock({ indexes[sessionId]?.refs[turn.id] }), let core = currentCore() {
                    try ignoringNotFound { try core.deleteMessage(id: saved.messageId) }
                }
                lock.withLock {
                    known[sessionId, default: []].insert(turn.id)
                    // Uncached, the next use reads the index from the core, this message included.
                    guard var index = indexes[sessionId] else { return }
                    index.order.removeAll { $0 == turn.id }
                    index.order.append(turn.id)
                    index.refs[turn.id] = MessageRef(
                        messageId: messageId,
                        contentHash: SyncConversationMapper.sha256Hex(Data(encoded.content.utf8)),
                        appDataHash: SyncConversationMapper.sha256Hex(encoded.appData),
                        extras: [:],
                        incomplete: false,
                        attachmentIds: Set(encoded.attachments.map(\.id)),
                        detailHash: encoded.detail.map { SyncConversationMapper.sha256Hex($0.bytes) }
                    )
                    indexes[sessionId] = index
                }
                if let scope = lock.withLock({ scopes[sessionId] }) { noteLocalWrite(scope) }
            } catch {
                stream.abort()
                Self.log.error("stream finish failed: \(Self.describe(error), privacy: .public)")
            }
        }
    }

    /// Runs `body` on the write queue, after any queued saves.
    func performWrite<T>(_ body: (SyncCore) throws -> T) throws -> T {
        try queue.sync { try body(try requireCore()) }
    }

    // MARK: - Index

    /// The stored order and hashes of a session's messages, read from the core
    /// on first use.
    private func index(for sessionId: UUID, scope: String, core: SyncCore, reload: Bool = false) throws -> SessionIndex {
        if !reload, let cached = lock.withLock({ indexes[sessionId] }) { return cached }
        let messages = try allMessages(scope: scope, core: core)
        var index = SessionIndex(repeated: Self.repeatedMessages(messages))
        for message in messages where !index.repeated.contains(message.id) {
            let appData = message.appData(SyncConversationMapper.turnNamespace)
            var object = SyncConversationMapper.parseObject(appData?.bytes) ?? [:]
            let id =
                (object["id"] as? String).flatMap(UUID.init(uuidString:))
                ?? SyncConversationMapper.derivedUUID(from: message.id)
            var extras = object.filter { !SyncConversationMapper.turnOwnedKeys.contains($0.key) }
            var incomplete = false
            if let appData, !extras.isEmpty {
                extras =
                    SyncConversationMapper.resolveBlobReferences(in: extras, blobs: appData.blobs) { blob in
                        let data = self.readBlob(blob, scope: scope, core: core, sessionId: sessionId)
                        if data == nil { incomplete = true }
                        return data
                    } as? JSONObject ?? extras
            }
            let attachmentIds = SyncConversationMapper.nativeAttachmentIds(of: message, object: object)
            object.removeAll()
            index.order.append(id)
            index.refs[id] = MessageRef(
                messageId: message.id,
                contentHash: SyncConversationMapper.sha256Hex(Data(message.content.utf8)),
                appDataHash: SyncConversationMapper.sha256Hex(appData?.bytes ?? Data()),
                extras: extras,
                incomplete: incomplete || appData?.blobs.contains(where: { !$0.available }) == true,
                attachmentIds: attachmentIds,
                authoredHere: message.authorDevice == core.deviceKey(),
                detailHash: Self.detailHash(of: message)
            )
        }
        let finalIndex = index
        lock.withLock { indexes[sessionId] = finalIndex }
        return index
    }

    private func allMessages(scope: String, core: SyncCore) throws -> [SyncMessage] {
        var pages: [[SyncMessage]] = []
        var cursor: PageCursor?
        repeat {
            let page = try core.messages(scope: scope, before: cursor, limit: Self.pageSize)
            pages.append(page.messages)
            cursor = page.nextCursor
        } while cursor != nil
        return pages.reversed().flatMap { $0 }
    }

    // MARK: - Loading

    private func afterQueuedWrites<T>(_ read: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) != nil ? read() : queue.sync(execute: read)
    }

    func loadSession(id: UUID) -> ChatSessionData? {
        afterQueuedWrites { loadSessionNow(id: id) }
    }

    private func loadSessionNow(id: UUID) -> ChatSessionData? {
        if let draft = lock.withLock({ drafts[id] }) { return draft }
        guard let core = currentCore(), let scope = scope(for: id, core: core),
            let conversation = try? core.conversation(scope: scope)
        else { return nil }
        let local = SyncLocalSessionStore.load(id)
        var session = SyncConversationMapper.session(from: conversation, local: local)
        guard let messages = try? allMessages(scope: scope, core: core) else { return session }

        var index = SessionIndex(repeated: Self.repeatedMessages(messages))
        var turns: [ChatTurnData] = []
        var missing = false
        for message in messages where !index.repeated.contains(message.id) {
            var incomplete = false
            let readBlob: SyncConversationMapper.BlobReader = { blob in
                let data = self.readBlob(blob, scope: scope, core: core, sessionId: id)
                if data == nil { incomplete = true }
                return data
            }
            let materialize: SyncConversationMapper.AttachmentMaterializer = { blob, sha256, inlineLimit in
                self.materialize(blob, sha256: sha256, inlineLimit: inlineLimit, scope: scope, core: core, sessionId: id)
            }
            let provisionalId = Self.turnId(of: message)
            var decoded = SyncConversationMapper.turn(
                from: message,
                readBlob: readBlob,
                materialize: materialize,
                overflow: local?.overflowObject(forTurn: provisionalId)
            )
            if let logs = local?.toolCallLogs[decoded.turn.id.uuidString.lowercased()] {
                decoded.turn.toolCallLogs = logs
            }
            missing = missing || incomplete
            turns.append(decoded.turn)
            index.order.append(decoded.turn.id)
            let appData = message.appData(SyncConversationMapper.turnNamespace)
            index.refs[decoded.turn.id] = MessageRef(
                messageId: message.id,
                contentHash: SyncConversationMapper.sha256Hex(Data(message.content.utf8)),
                appDataHash: SyncConversationMapper.sha256Hex(appData?.bytes ?? Data()),
                extras: decoded.extras,
                incomplete: incomplete || appData?.blobs.contains(where: { !$0.available }) == true,
                attachmentIds: SyncConversationMapper.nativeAttachmentIds(
                    of: message, object: SyncConversationMapper.parseObject(appData?.bytes) ?? [:]),
                authoredHere: message.authorDevice == core.deviceKey(),
                detailHash: Self.detailHash(of: message)
            )
        }
        if missing {
            Self.log.info("session \(id, privacy: .public) has content still arriving")
        }
        let finalIndex = index
        lock.withLock {
            indexes[id] = finalIndex
            known[id, default: []].formUnion(finalIndex.order)
        }
        session.turns = turns
        return session
    }

    private static func detailHash(of message: SyncMessage) -> String? {
        message.appData(SyncConversationMapper.turnDetailNamespace).map { SyncConversationMapper.sha256Hex($0.bytes) }
    }

    /// Copies of a turn beyond the first: a reply both a save and its stream
    /// wrote. Every device keeps the same copy, so their removals agree.
    private static func repeatedMessages(_ messages: [SyncMessage]) -> Set<String> {
        var kept: [UUID: String] = [:]
        var repeated: Set<String> = []
        for message in messages {
            let id = turnId(of: message)
            guard let other = kept[id] else {
                kept[id] = message.id
                continue
            }
            repeated.insert(max(other, message.id))
            kept[id] = min(other, message.id)
        }
        return repeated
    }

    private static func turnId(of message: SyncMessage) -> UUID {
        let object = SyncConversationMapper.parseObject(message.appData(SyncConversationMapper.turnNamespace)?.bytes)
        return (object?["id"] as? String).flatMap(UUID.init(uuidString:))
            ?? SyncConversationMapper.derivedUUID(from: message.id)
    }

    func loadAllMetadata() -> [ChatSessionData] {
        afterQueuedWrites { loadAllMetadataNow() }
    }

    private func loadAllMetadataNow() -> [ChatSessionData] {
        var sessions = conversationSessions(nil)
        let pending = lock.withLock { Array(drafts.values) }
        let ids = Set(sessions.map(\.id))
        sessions.append(contentsOf: pending.filter { !ids.contains($0.id) })
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadMetadata(forAgent agentId: UUID?, source: SessionSource?) -> [ChatSessionData] {
        loadAllMetadata().filter { session in
            (agentId == nil || session.agentId == agentId) && (source == nil || session.source == source)
        }
    }

    func loadMetadata(ids: [UUID]) -> [ChatSessionData] {
        afterQueuedWrites { loadMetadataNow(ids: ids) }
    }

    private func loadMetadataNow(ids: [UUID]) -> [ChatSessionData] {
        guard !ids.isEmpty else { return [] }
        guard let core = currentCore() else { return lock.withLock { ids.compactMap { drafts[$0] } } }
        return ids.compactMap { id in
            if let draft = lock.withLock({ drafts[id] }) { return draft }
            guard let scope = scope(for: id, core: core), let conversation = try? core.conversation(scope: scope)
            else { return nil }
            return SyncConversationMapper.session(from: conversation)
        }
    }

    func turnCounts(forAgent agentId: UUID?) -> [UUID: Int] {
        afterQueuedWrites { turnCountsNow(forAgent: agentId) }
    }

    private func turnCountsNow(forAgent agentId: UUID?) -> [UUID: Int] {
        guard let core = currentCore() else { return [:] }
        var counts: [UUID: Int] = [:]
        for conversation in (try? core.conversations()) ?? []
        where conversation.kind == .conversation && !SyncConversationMapper.isAppInternal(conversation) {
            if let agentId,
                conversation.tag(SyncConversationMapper.TagKey.agentId) != agentId.uuidString.lowercased()
            {
                continue
            }
            counts[SyncConversationMapper.sessionId(of: conversation)] = Int(conversation.messageCount)
        }
        return counts
    }

    func sessionIds(withContentContaining text: String) -> Set<UUID> {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let core = currentCore() else { return [] }
        let results = afterQueuedWrites { (try? core.search(query: query, limit: 1000)) ?? [] }
        var ids: Set<UUID> = []
        for scope in Set(results.map(\.scope)) {
            if let id = sessionId(forScope: scope) { ids.insert(id) }
        }
        return ids
    }

    func findSession(source: SessionSource, externalKey: String, agentId: UUID?) -> ChatSessionData? {
        findSession(externalKey: externalKey, agentId: agentId) { $0.source == source }
    }

    func findSession(pluginId: String, externalKey: String, agentId: UUID?) -> ChatSessionData? {
        findSession(externalKey: externalKey, agentId: agentId) { $0.sourcePluginId == pluginId }
    }

    private func findSession(
        externalKey: String,
        agentId: UUID?,
        where matches: (ChatSessionData) -> Bool
    ) -> ChatSessionData? {
        afterQueuedWrites { findSessionNow(externalKey: externalKey, agentId: agentId, where: matches) }
    }

    private func findSessionNow(
        externalKey: String,
        agentId: UUID?,
        where matches: (ChatSessionData) -> Bool
    ) -> ChatSessionData? {
        guard let core = currentCore() else { return nil }
        let filter = ConversationFilter(
            tags: [Tag(key: SyncConversationMapper.TagKey.externalSessionKey, value: externalKey)]
        )
        let candidates = ((try? core.conversationsFiltered(filter: filter)) ?? []).filter { conversation in
            conversation.tag(SyncConversationMapper.TagKey.agentId) == agentId?.uuidString.lowercased()
        }
        let sessions = candidates.map { conversation -> ChatSessionData in
            let session = SyncConversationMapper.session(from: conversation)
            lock.withLock { scopes[session.id] = conversation.scope }
            return session
        }
        return sessions.filter(matches).max { $0.updatedAt < $1.updatedAt }
    }

    /// Sessions for every conversation, optionally filtered.
    private func conversationSessions(_ filter: ConversationFilter?) -> [ChatSessionData] {
        guard let core = currentCore() else { return [] }
        let conversations: [Conversation]
        if let filter {
            conversations = (try? core.conversationsFiltered(filter: filter)) ?? []
        } else {
            conversations = (try? core.conversations()) ?? []
        }
        var found: [UUID: String] = [:]
        let chats = conversations.filter { $0.kind == .conversation && !SyncConversationMapper.isAppInternal($0) }
        let sessions = chats.map { conversation -> ChatSessionData in
            let session = SyncConversationMapper.session(from: conversation)
            found[session.id] = conversation.scope
            return session
        }
        lock.withLock { scopes.merge(found) { _, new in new } }
        return sessions
    }

    // MARK: - Deleting

    func deleteSession(id: UUID) throws {
        try queue.sync { try delete(id) }
    }

    func deleteSessionsAsync(
        ids: [UUID],
        onDropped: (@Sendable ([UUID]) -> Void)? = nil,
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard !ids.isEmpty else {
            completion?()
            return
        }
        queue.async { [self] in
            defer { completion?() }
            var dropped: [UUID] = []
            for id in ids {
                do {
                    try delete(id)
                } catch {
                    dropped.append(id)
                }
            }
            if !dropped.isEmpty { onDropped?(dropped) }
        }
    }

    /// Runs on `queue`. Synced conversations are left (they disappear from the
    /// user's other devices too); device-local ones are deleted outright.
    private func delete(_ id: UUID) throws {
        lock.withLock { drafts[id] = nil }
        let core = try requireCore()
        if let scope = scope(for: id, core: core) {
            let cachedHashes = attachmentHashes(scope: scope, core: core)
            let conversation = try core.conversation(scope: scope)
            try ignoringNotFound {
                if conversation?.replication == .deviceLocal {
                    try core.deleteLocalConversation(scope: scope)
                } else {
                    try core.leaveConversation(scope: scope)
                }
            }
            for hash in cachedHashes { AttachmentBlobStore.delete(hash) }
        }
        lock.withLock {
            scopes[id] = nil
            indexes[id] = nil
            known[id] = nil
            removedHere[id] = nil
        }
        SyncLocalSessionStore.delete(id)
        // The pre-sync copy and the session's file-change rows go too: a
        // deleted chat mustn't linger in the old database.
        let legacy = ChatHistoryDatabase.shared
        if !legacy.isOpenNonBlocking,
            FileManager.default.fileExists(atPath: OsaurusPaths.chatHistoryDatabaseFile().path),
            StorageKeyManager.shared.isStorageReadyForWrites
        {
            try? legacy.open()
        }
        if legacy.isOpenNonBlocking {
            try? legacy.deleteSession(id: id)
        }
    }

    private func attachmentHashes(scope: String, core: SyncCore) -> Set<String> {
        var hashes: Set<String> = []
        for message in (try? allMessages(scope: scope, core: core)) ?? [] {
            let object = SyncConversationMapper.parseObject(message.appData(SyncConversationMapper.turnNamespace)?.bytes)
            for entry in (object?["attachments"] as? [JSONObject]) ?? [] {
                if let hash = entry["sha256"] as? String { hashes.insert(hash) }
            }
        }
        return hashes
    }

    // MARK: - Blobs

    /// The bytes behind `blob` when they are on this device. Otherwise starts
    /// fetching them from a peer and returns nil.
    private func readBlob(_ blob: Blob, scope: String, core: SyncCore, sessionId: UUID) -> Data? {
        guard blob.available else {
            fetchInBackground(blob, sha256: nil, scope: scope, core: core, sessionId: sessionId)
            return nil
        }
        let hash = blob.hash
        guard case .success(let data)? = SyncService.blocking(timeout: Self.blobReadTimeout, {
            try await core.readAttachment(scope: scope, hash: hash)
        }) else { return nil }
        return data
    }

    private func materialize(
        _ blob: Blob,
        sha256: String?,
        inlineLimit: Int,
        scope: String,
        core: SyncCore,
        sessionId: UUID
    ) -> SyncConversationMapper.MaterializedAttachment? {
        if let sha256, AttachmentBlobStore.exists(sha256) {
            if Int(blob.size) >= inlineLimit { return .cached(hash: sha256, byteCount: Int(blob.size)) }
            if let data = try? AttachmentBlobStore.read(sha256) { return .inline(data) }
        }
        guard blob.available else {
            fetchInBackground(blob, sha256: sha256, scope: scope, core: core, sessionId: sessionId)
            // Keep the attachment so a save can't drop it while it downloads.
            return sha256.map { .cached(hash: $0, byteCount: Int(blob.size)) }
        }
        guard let data = readBlob(blob, scope: scope, core: core, sessionId: sessionId) else {
            return sha256.map { .cached(hash: $0, byteCount: Int(blob.size)) }
        }
        if data.count < inlineLimit { return .inline(data) }
        guard let hash = try? AttachmentBlobStore.write(data) else { return .inline(data) }
        return .cached(hash: hash, byteCount: data.count)
    }

    private func fetchInBackground(_ blob: Blob, sha256: String?, scope: String, core: SyncCore, sessionId: UUID) {
        let key = "\(scope)/\(blob.hash)"
        let start = lock.withLock { fetching.insert(key).inserted }
        guard start else { return }
        let hash = blob.hash
        Task.detached(priority: .utility) { [self] in
            defer { lock.withLock { _ = fetching.remove(key) } }
            do {
                let data = try await core.readAttachment(scope: scope, hash: hash)
                if sha256 != nil { _ = try? AttachmentBlobStore.write(data) }
                lock.withLock { indexes[sessionId] = nil }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Self.didFetchMissingContentNotification,
                        object: nil,
                        userInfo: ["sessionId": sessionId]
                    )
                }
            } catch {
                Self.log.info("blob fetch failed: \(Self.describe(error), privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    private static func ms(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private func perform(_ what: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            Self.log.error("\(what, privacy: .public) failed: \(Self.describe(error), privacy: .public)")
        }
    }

    /// Debug builds: the stack of the caller that handed over the save
    /// running on `queue`, for `noteDeletion`. Only touched on `queue`.
    nonisolated(unsafe) private static var currentSaveTrace: String?

    private static func callerTrace() -> String? {
        #if DEBUG
            return Thread.callStackSymbols.dropFirst(2).prefix(16).joined(separator: "\n")
        #else
            return nil
        #endif
    }

    /// Says which save deleted a stored turn and why, so a turn another
    /// device wrote that vanishes can be traced: the iPhone saw its prompt
    /// and the reply to it removed by this Mac after an edit or a stop.
    /// `rewritten` turns are written again further on; the others go.
    private static func noteDeletion(
        of id: UUID,
        message: String,
        session: ChatSessionData,
        desired: [UUID],
        stored: [UUID],
        seen: Seen?,
        rewritten: Bool
    ) {
        func short(_ ids: [UUID]) -> String {
            ids.map { String($0.uuidString.lowercased().prefix(8)) }.joined(separator: ",")
        }
        let role = session.turns.first { $0.id == id }?.role.rawValue ?? "not in session"
        let line =
            "[SyncStore] save of \(session.id.uuidString.lowercased().prefix(8)) deletes turn "
            + "\(id.uuidString.lowercased().prefix(8)) (\(role), message \(message), "
            + "\(rewritten ? "rewritten" : "removed")); saving [\(short(desired))] over stored "
            + "[\(short(stored))]; seen before: \(seen.map { $0.before.contains(id) ? "yes" : "no" } ?? "nothing")"
        log.notice("\(line, privacy: .public)")
        #if DEBUG
            print(line)
            // Who saved: the store's queue runs the save, so the caller that
            // handed it over is in `saveTrace`, taken when it was queued.
            if let trace = currentSaveTrace { print("[SyncStore] saved by:\n\(trace)") }
        #endif
    }

    private func ignoringNotFound(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as SyncError where error.code == SyncErrorCode.notFound {
            return
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? SyncError)?.logDetail ?? "\(error)"
    }

    #if DEBUG
        func _resetForTesting() {
            drain(timeout: 5)
            lock.withLock {
                scopes.removeAll()
                indexes.removeAll()
                known.removeAll()
                removedHere.removeAll()
                drafts.removeAll()
                lastLocalWrite.removeAll()
                agentSenders.removeAll()
                coreIdentity = nil
            }
        }
    #endif
}

/// Files handed to the core for one write, removed once it has copied them.
private final class TemporaryFiles {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("osaurus-sync-out-\(UUID().uuidString)", isDirectory: true)
    private var created = false

    func attachments(for turn: SyncConversationMapper.EncodedTurn) throws -> [AttachmentFile] {
        try turn.attachments.compactMap { attachment in
            guard let file = SyncConversationMapper.nativeFile(for: attachment) else { return nil }
            return AttachmentFile(path: try write(file.bytes, name: file.name).path, mediaType: file.mediaType, name: file.name)
        }
    }

    func appDataWrite(for turn: SyncConversationMapper.EncodedTurn) throws -> AppDataWrite {
        let files = try turn.appDataBlobs.map { blob in
            AttachmentFile(path: try write(blob.bytes, name: "\(blob.name).json").path, mediaType: "application/json", name: blob.name)
        }
        return AppDataWrite(namespace: SyncConversationMapper.turnNamespace, bytes: turn.appData, attachments: files)
    }

    /// The turn's app data plus, when it has any, its detail.
    func appDataWrites(for turn: SyncConversationMapper.EncodedTurn) throws -> [AppDataWrite] {
        var writes = [try appDataWrite(for: turn)]
        if let detail = turn.detail { writes.append(try detailWrite(detail)) }
        return writes
    }

    func detailWrite(_ detail: SyncConversationMapper.DetailWrite) throws -> AppDataWrite {
        let files = try detail.blobs.map { blob in
            AttachmentFile(path: try copy(blob.url, name: blob.name).path, mediaType: blob.mediaType, name: blob.name)
        }
        return AppDataWrite(namespace: SyncConversationMapper.turnDetailNamespace, bytes: detail.bytes, attachments: files)
    }

    private func copy(_ source: URL, name: String) throws -> URL {
        let target = try write(Data(), name: name)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    private func write(_ data: Data, name: String) throws -> URL {
        if !created {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            created = true
        }
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent(safe.isEmpty ? "file" : safe)
        try data.write(to: file)
        return file
    }

    func removeAll() {
        if created { try? FileManager.default.removeItem(at: directory) }
    }
}
