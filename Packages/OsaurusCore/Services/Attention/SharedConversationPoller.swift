//
//  SharedConversationPoller.swift
//  osaurus
//
//  While a chat with a teammate's shared agent is open, collect what the
//  agent's owner says in it between runs (`GET /conversations/{id}/events`,
//  docs/MOBILE_PROTOCOL.md §21.4). A live run carries those messages
//  inline, so nothing is polled while one streams. Quiet conversations
//  back off to one poll every two minutes; a message or a finished run
//  brings the pace back up.
//

import Foundation

@MainActor
final class SharedConversationPoller {
    static let shared = SharedConversationPoller()

    nonisolated static let fastInterval: TimeInterval = 5
    nonisolated static let maxInterval: TimeInterval = 120

    private final class Watch {
        weak var session: ChatSession?
        let providerId: UUID
        var task: Task<Void, Never>?
        /// Per conversation, the host's sequence to resume after.
        var cursors: [String: Int] = [:]

        init(session: ChatSession, providerId: UUID) {
            self.session = session
            self.providerId = providerId
        }
    }

    private var watches: [ObjectIdentifier: Watch] = [:]

    /// Start (or re-point) polling for `session`'s shared-agent conversation.
    func watch(_ session: ChatSession, providerId: UUID) {
        let key = ObjectIdentifier(session)
        if let existing = watches[key], existing.providerId == providerId, existing.task != nil { return }
        watches[key]?.task?.cancel()
        let watch = Watch(session: session, providerId: providerId)
        watches[key] = watch
        watch.task = Task { [weak self] in
            await self?.run(watch, key: key)
        }
    }

    func stop(_ session: ChatSession) {
        watches.removeValue(forKey: ObjectIdentifier(session))?.task?.cancel()
    }

    var watchCount: Int { watches.count }

    /// The wait before the next poll. Pure, for tests.
    nonisolated static func nextInterval(after current: TimeInterval, gotMessages: Bool, runJustEnded: Bool)
        -> TimeInterval
    {
        if gotMessages || runJustEnded { return fastInterval }
        return min(maxInterval, max(fastInterval, current * 2))
    }

    private func run(_ watch: Watch, key: ObjectIdentifier) async {
        var interval = Self.fastInterval
        var wasStreaming = false
        defer { if watches[key] === watch { watches[key] = nil } }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let session = watch.session,
                session.remoteAgentProviderId == watch.providerId
            else { return }
            if session.isStreaming {
                wasStreaming = true
                interval = Self.fastInterval
                continue
            }
            let runJustEnded = wasStreaming
            wasStreaming = false
            guard RemotePeerFeatures.supports(RemotePeerFeatures.conversationEvents, providerId: watch.providerId),
                let sessionId = session.sessionId?.uuidString,
                let provider = RemoteProviderManager.shared.configuration.providers.first(where: {
                    $0.id == watch.providerId
                })
            else {
                interval = Self.nextInterval(after: interval, gotMessages: false, runJustEnded: runJustEnded)
                continue
            }
            let after = watch.cursors[sessionId] ?? 0
            let page = await RemoteProviderService.fetchConversationEvents(
                from: provider, sessionId: sessionId, after: after)
            guard !Task.isCancelled, let page else {
                interval = Self.nextInterval(after: interval, gotMessages: false, runJustEnded: false)
                continue
            }
            watch.cursors[sessionId] = page.next
            if let current = watch.session, current.sessionId?.uuidString == sessionId, !page.messages.isEmpty {
                current.appendRemoteParticipantMessages(page.messages)
                RemoteAgentRunLog.client("mailbox collected count=\(page.messages.count)")
            }
            interval = Self.nextInterval(
                after: interval, gotMessages: !page.messages.isEmpty, runJustEnded: runJustEnded)
        }
    }
}
