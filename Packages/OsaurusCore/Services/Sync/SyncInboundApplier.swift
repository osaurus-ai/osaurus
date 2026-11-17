//
//  SyncInboundApplier.swift
//  osaurus
//
//  Brings changes other devices made into the app: the conversation list
//  into `ChatSessionsManager`, and the messages of open chats into their
//  `ChatSession`. This device's own writes come back through the same
//  subscriptions and are recognized and skipped.
//

import Foundation
import OsaurusSync
import os

@MainActor
final class SyncInboundApplier {
    static let shared = SyncInboundApplier()

    /// A list change this soon after a local write to the same conversation
    /// is taken to be that write coming back.
    static let echoWindow: TimeInterval = 2
    private static let debounce: Duration = .milliseconds(250)
    private static let retryInterval: Duration = .seconds(2)
    private static let log = Logger(subsystem: "ai.osaurus", category: "sync.inbound")

    private struct ScopeWatch {
        var scope: String
        var subscription: Subscription
    }

    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var listSubscription: Subscription?
    /// Open chats, counted per session: two surfaces can show one chat.
    private var watchers: [UUID: Int] = [:]
    private var scopeWatches: [UUID: ScopeWatch] = [:]
    /// Chats whose subscription is being made off the main thread (`subscribeScope`).
    private var subscribing: Set<UUID> = []

    private var changedScopes: Set<String> = []
    private var removedScopes: Set<String> = []
    /// Open chats another device changed, not yet applied.
    private var staleSessions: Set<UUID> = []
    private var flushTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    private static let streamRenderInterval: Duration = .milliseconds(100)
    private static let committedMessageWait: Duration = .seconds(10)
    private static let committedMessageMaxWait: Duration = .seconds(120)

    /// Replies other devices are streaming into open chats, by session.
    private var remoteStreams: [UUID: StreamUpdate] = [:]
    private var renderTasks: [UUID: Task<Void, Never>] = [:]
    /// Pending-delivery lookups in flight, by session. The lookup calls into
    /// the sync core, which can block, so it never runs on the main actor.
    private var pendingDeliveryTasks: [UUID: Task<Void, Never>] = [:]
    /// Sessions whose sync status changed while a lookup was in flight.
    private var pendingDeliveryRerun: Set<UUID> = []
    /// Chats whose streamed reply's message has arrived: the next reload
    /// swaps the bubble for it.
    private var committedReplies: Set<UUID> = []

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: SyncService.didReplaceIdentityNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SyncInboundApplier.shared.identityReplaced() }
            })
        observers += SyncService.shared.observeCore(
            attach: { SyncInboundApplier.shared.subscribe($0) },
            detach: { SyncInboundApplier.shared.detach() })
        observers.append(
            center.addObserver(
                forName: SyncConversationStore.didFetchMissingContentNotification,
                object: nil,
                queue: .main
            ) { note in
                let id = note.userInfo?["sessionId"] as? UUID
                MainActor.assumeIsolated {
                    guard let id else { return }
                    SyncInboundApplier.shared.markStale(id)
                }
            })
    }

    /// Subscribes against `core`, replacing the previous core's subscriptions.
    private func subscribe(_ core: SyncCore) {
        listSubscription?.cancel()
        listSubscription = core.subscribeConversations { changes in
            Task { @MainActor in SyncInboundApplier.shared.receive(changes) }
        }
        for watch in scopeWatches.values { watch.subscription.cancel() }
        scopeWatches.removeAll()
        for id in watchers.keys { startSubscribing(id, core: core) }
    }

    private func detach() {
        listSubscription?.cancel()
        listSubscription = nil
        cancelPendingDeliveryRefreshes()
        for watch in scopeWatches.values { watch.subscription.cancel() }
        scopeWatches.removeAll()
    }

    private func identityReplaced() {
        cancelPendingDeliveryRefreshes()
        for watch in scopeWatches.values { watch.subscription.cancel() }
        scopeWatches.removeAll()
        for id in Array(remoteStreams.keys) { endRemoteReply(id) }
        staleSessions.formUnion(watchers.keys)
        scheduleFlush()
    }

    // MARK: - Open chats

    /// An open chat shows `sessionId`; its messages are followed until `unwatch`.
    func watch(_ sessionId: UUID) {
        watchers[sessionId, default: 0] += 1
        guard watchers[sessionId] == 1, let core = SyncService.shared.core else { return }
        startSubscribing(sessionId, core: core)
    }

    func unwatch(_ sessionId: UUID) {
        guard let count = watchers[sessionId] else { return }
        if count > 1 {
            watchers[sessionId] = count - 1
            return
        }
        watchers[sessionId] = nil
        scopeWatches.removeValue(forKey: sessionId)?.subscription.cancel()
        staleSessions.remove(sessionId)
        committedReplies.remove(sessionId)
        remoteStreams[sessionId] = nil
        renderTasks.removeValue(forKey: sessionId)?.cancel()
        pendingDeliveryTasks.removeValue(forKey: sessionId)?.cancel()
        pendingDeliveryRerun.remove(sessionId)
    }

    /// A chat that's still a draft has no conversation yet; it's subscribed
    /// once its first save creates one.
    ///
    /// The scope lookup and the subscription run off the main thread (KEEP): both wait on the core's lock,
    /// which it holds for seconds while it takes in a device's catch-up (2026-11-17, a Mac hang).
    private func subscribeScope(for sessionId: UUID, core: SyncCore) async {
        guard scopeWatches[sessionId] == nil, subscribing.insert(sessionId).inserted else { return }
        defer { subscribing.remove(sessionId) }
        let made = await Task.detached(priority: .userInitiated) { () -> Result<(String, Subscription), Error>? in
            guard let scope = SyncConversationStore.shared.scope(forSession: sessionId) else { return nil }
            do {
                let subscription = try core.subscribe(scope: scope) { changes in
                    Task { @MainActor in SyncInboundApplier.shared.receive(changes, sessionId: sessionId) }
                }
                return .success((scope, subscription))
            } catch {
                return .failure(error)
            }
        }.value
        switch made {
        case .success(let (scope, subscription)):
            // Unwatched, or the core replaced, while it was being made.
            guard watchers[sessionId] != nil, scopeWatches[sessionId] == nil, SyncService.shared.core === core else {
                subscription.cancel()
                return
            }
            scopeWatches[sessionId] = ScopeWatch(scope: scope, subscription: subscription)
            refreshPendingDelivery(sessionId)
        case .failure(let error):
            Self.log.error("subscribe failed: \(error.syncLogDetail, privacy: .public)")
        case nil:
            break
        }
    }

    private func startSubscribing(_ sessionId: UUID, core: SyncCore) {
        Task { @MainActor [weak self] in await self?.subscribeScope(for: sessionId, core: core) }
    }

    // MARK: - Changes

    private func receive(_ changes: [ConversationChange]) {
        for change in changes {
            switch change {
            case .changed(let conversation):
                changedScopes.insert(conversation.scope)
            case .removed(let scope):
                removedScopes.insert(scope)
            }
        }
        scheduleFlush()
    }

    private func receive(_ changes: [ScopeChange], sessionId: UUID) {
        guard watchers[sessionId] != nil, let core = SyncService.shared.core else { return }
        let me = core.deviceKey()
        for change in changes {
            switch change {
            case .messageAdded(let message), .messageChanged(let message):
                if message.id == remoteStreams[sessionId]?.messageId { committedReplies.insert(sessionId) }
                if message.authorDevice != me { markStale(sessionId) }
            case .messageRemoved:
                // Removals carry no author; reloading an unchanged chat is a no-op.
                if let scope = scopeWatches[sessionId]?.scope,
                    !SyncConversationStore.shared.wroteLocally(scope: scope, within: Self.echoWindow)
                {
                    markStale(sessionId)
                }
            case .reset:
                markStale(sessionId)
            case .stream(let update):
                applyStream(update, sessionId: sessionId, me: me)
            case .syncStatusChanged:
                refreshPendingDelivery(sessionId)
            case .liveState:
                break
            }
        }
    }

    private func applyStream(_ update: StreamUpdate, sessionId: UUID, me: String) {
        guard update.host != me else { return }
        switch update.state {
        case .streaming:
            remoteStreams[sessionId] = update
            scheduleStreamRender(sessionId)
        case .finished:
            // The bubble stays until the committed message arrives with the same id.
            remoteStreams[sessionId] = update
            scheduleStreamRender(sessionId)
            scheduleAbandonCheck(sessionId, messageId: update.messageId, host: update.host)
        case .interrupted:
            endRemoteReply(sessionId)
            markStale(sessionId)
        }
    }

    /// How many of the chat's messages haven't reached another device yet.
    ///
    /// `syncStatus` is a blocking call into the sync core (it can wait on the
    /// core's internal locks while sync is busy, e.g. right after launch), so
    /// it runs off the main actor and the count is applied when it returns.
    private func refreshPendingDelivery(_ sessionId: UUID) {
        guard let scope = scopeWatches[sessionId]?.scope, let core = SyncService.shared.core else { return }
        guard pendingDeliveryTasks[sessionId] == nil else {
            pendingDeliveryRerun.insert(sessionId)
            return
        }
        pendingDeliveryTasks[sessionId] = Task { @MainActor [weak self] in
            let result: Result<Int, any Error> = await Task.detached(priority: .utility) {
                do {
                    return .success(Int(try core.syncStatus(scope: scope).pendingOutbox))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.pendingDeliveryTasks[sessionId] = nil
            // The chat was closed or now follows another conversation.
            guard self.watchers[sessionId] != nil, self.scopeWatches[sessionId]?.scope == scope else {
                self.pendingDeliveryRerun.remove(sessionId)
                return
            }
            let pending: Int
            switch result {
            case .success(let count):
                pending = count
            case .failure(let error):
                Self.log.error("sync status failed: \(error.syncLogDetail, privacy: .public)")
                pending = 0
            }
            for session in Self.liveSessions(for: sessionId) where session.syncPendingCount != pending {
                session.syncPendingCount = pending
            }
            if self.pendingDeliveryRerun.remove(sessionId) != nil {
                self.refreshPendingDelivery(sessionId)
            }
        }
    }

    private func cancelPendingDeliveryRefreshes() {
        for task in pendingDeliveryTasks.values { task.cancel() }
        pendingDeliveryTasks.removeAll()
        pendingDeliveryRerun.removeAll()
    }

    private func scheduleStreamRender(_ sessionId: UUID) {
        guard renderTasks[sessionId] == nil else { return }
        renderTasks[sessionId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.streamRenderInterval)
            guard let self else { return }
            self.renderTasks[sessionId] = nil
            guard let update = self.remoteStreams[sessionId] else { return }
            let deviceName =
                SyncService.shared.deviceName(forKey: update.host)
                ?? String(localized: "another device", bundle: .module)
            let reply = ChatSession.RemoteReply(messageId: update.messageId, deviceName: deviceName, text: update.text)
            for session in Self.liveSessions(for: sessionId) { session.showRemoteReply(reply) }
        }
    }

    /// A finished stream whose message never arrives (the writer went
    /// offline before it synced) stops showing as a reply. While the writer
    /// stays connected the message is still on its way over a slow link, so
    /// the bubble waits up to `committedMessageMaxWait`.
    private func scheduleAbandonCheck(_ sessionId: UUID, messageId: String, host: String, waited: Duration = .zero) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.committedMessageWait)
            guard let self, self.remoteStreams[sessionId]?.messageId == messageId else { return }
            let waited = waited + Self.committedMessageWait
            let connected = await Task.detached(priority: .utility) { Self.isConnected(host) }.value
            guard self.remoteStreams[sessionId]?.messageId == messageId else { return }
            if waited < Self.committedMessageMaxWait, connected {
                self.scheduleAbandonCheck(sessionId, messageId: messageId, host: host, waited: waited)
                return
            }
            self.endRemoteReply(sessionId)
            self.markStale(sessionId)
        }
    }

    /// Off the main thread only: `diagnostics` waits on the core's lock.
    nonisolated private static func isConnected(_ device: String) -> Bool {
        SyncService.shared.core?.diagnostics().peers.contains { $0.device == device && $0.connected } ?? false
    }

    private func endRemoteReply(_ sessionId: UUID) {
        remoteStreams[sessionId] = nil
        renderTasks.removeValue(forKey: sessionId)?.cancel()
        for session in Self.liveSessions(for: sessionId) { session.endRemoteReply() }
    }

    private func markStale(_ sessionId: UUID) {
        SyncConversationStore.shared.invalidate(sessionId: sessionId)
        staleSessions.insert(sessionId)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard let self else { return }
            await self.flush()
            self.flushTask = nil
            // Changes that came in while it ran.
            if !self.changedScopes.isEmpty || !self.removedScopes.isEmpty { self.scheduleFlush() }
        }
    }

    /// What `flush` reads off the main thread.
    private struct Flushed: Sendable {
        var changedIds: [UUID] = []
        var metadata: [ChatSessionData] = []
        var removedIds: [UUID] = []
        var removedUnknown = false
    }

    /// KEEP the reads off the main thread: the scope lookups and `loadMetadata` wait on the store's queue and
    /// the core's lock, which the core holds for seconds while it takes in another device's catch-up. Read on
    /// main, they hung the Mac (2026-11-17, bt in osaurus/tmp/bt-all.txt).
    private func flush() async {
        let store = SyncConversationStore.shared
        let changed = changedScopes
        let removed = removedScopes
        changedScopes.removeAll()
        removedScopes.removeAll()

        let echoWindow = Self.echoWindow
        let found = await Task.detached(priority: .userInitiated) { () -> Flushed in
            var found = Flushed()
            for scope in changed where !store.wroteLocally(scope: scope, within: echoWindow) {
                guard let id = store.sessionId(forScope: scope) else { continue }
                found.changedIds.append(id)
                store.invalidate(sessionId: id)
            }
            if !found.changedIds.isEmpty { found.metadata = store.loadMetadata(ids: found.changedIds) }
            found.removedIds = removed.compactMap { store.forget(scope: $0) }
            found.removedUnknown = found.removedIds.count < removed.count
            return found
        }.value

        for id in found.changedIds where watchers[id] != nil { staleSessions.insert(id) }
        if !found.metadata.isEmpty {
            for session in found.metadata {
                for live in Self.liveSessions(for: session.id) { live.applyRemoteMetadata(from: session) }
            }
            ChatSessionsManager.shared.applyRemote(found.metadata)
        }
        // Like a delete from the phone: open tabs move off the chat, or
        // their next save would bring it back.
        for id in found.removedIds { ChatWindowManager.shared.deleteSession(id: id) }
        if found.removedUnknown {
            // A conversation this launch never looked up: only a full read finds its row (off main).
            ChatSessionsManager.shared.refreshInBackground()
        }

        // Chats that just got their conversation start following it.
        if let core = SyncService.shared.core {
            for id in watchers.keys where scopeWatches[id] == nil { await subscribeScope(for: id, core: core) }
        }
        await applyStaleSessions()
    }

    /// Reloads each changed open chat that's idle. Busy ones are retried: a
    /// load now would count turns as seen that the busy copy doesn't have.
    /// Each chat is read off the main thread (`loadAsync`, KEEP), then checked again: it may have got busy since.
    private func applyStaleSessions() async {
        var busy: Set<UUID> = []
        let stale = staleSessions
        staleSessions.subtract(stale)
        for id in stale {
            guard !Self.liveSessions(for: id).isEmpty else { continue }
            guard Self.liveSessions(for: id).allSatisfy(\.canApplyRemoteChanges) else {
                busy.insert(id)
                continue
            }
            guard let data = await ChatSessionStore.loadAsync(id: id) else { continue }
            let live = Self.liveSessions(for: id)
            guard live.allSatisfy(\.canApplyRemoteChanges) else {
                busy.insert(id)
                continue
            }
            if committedReplies.remove(id) != nil {
                remoteStreams[id] = nil
                renderTasks.removeValue(forKey: id)?.cancel()
                for session in live { session.endRemoteReply() }
            }
            for session in live { session.applyRemoteChanges(from: data) }
            var metadata = data
            metadata.turns = []
            ChatSessionsManager.shared.applyRemote([metadata])
        }
        staleSessions.formUnion(busy)
        retryTask?.cancel()
        retryTask = nil
        guard !busy.isEmpty else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.retryInterval)
            guard !Task.isCancelled else { return }
            await self?.applyStaleSessions()
        }
    }

    private static func liveSessions(for id: UUID) -> [ChatSession] {
        var sessions: [ChatSession] = []
        if let registered = LiveChatSessionRegistry.shared.liveSession(for: id) { sessions.append(registered) }
        for session in ChatWindowManager.shared.sessions(forSessionId: id)
        where !sessions.contains(where: { $0 === session }) {
            sessions.append(session)
        }
        return sessions
    }

    #if DEBUG
        /// Runs the debounced work now.
        func _flushForTesting() async {
            flushTask?.cancel()
            flushTask = nil
            await flush()
        }

        func _receiveForTesting(_ changes: [ScopeChange], sessionId: UUID) {
            receive(changes, sessionId: sessionId)
        }

        func _receiveForTesting(_ changes: [ConversationChange]) {
            receive(changes)
        }

        var _isAttachedForTesting: Bool { listSubscription != nil }

        func _resetForTesting() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            started = false
            detach()
            watchers.removeAll()
            changedScopes.removeAll()
            removedScopes.removeAll()
            staleSessions.removeAll()
            remoteStreams.removeAll()
            committedReplies.removeAll()
            for task in renderTasks.values { task.cancel() }
            renderTasks.removeAll()
            flushTask?.cancel()
            flushTask = nil
            retryTask?.cancel()
            retryTask = nil
        }
    #endif
}
