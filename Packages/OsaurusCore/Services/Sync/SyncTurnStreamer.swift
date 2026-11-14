//
//  SyncTurnStreamer.swift
//  osaurus
//
//  Streams a chat's reply to the user's other devices while it generates.
//  The tokens are never stored; finishing commits the turn as its message.
//  Until then the chat's saves leave the turn out, and a save that would
//  write a later turn commits it first.
//

import Foundation
import OsaurusSync
import os

@MainActor
final class SyncTurnStreamer {
    private static let interval: Duration = .milliseconds(150)
    private static let log = Logger(subsystem: "ai.osaurus", category: "sync.stream")

    private weak var session: ChatSession?
    /// The one reply to stream, when the caller names it; otherwise the last turn.
    private weak var pinned: ChatTurn?
    private var ticker: Task<Void, Never>?
    private var stream: OutgoingStream?
    private weak var turn: ChatTurn?
    /// The reply last committed; never streamed again.
    private weak var committed: ChatTurn?
    private var sessionId: UUID?
    private var pushed = ""
    private var pushedRevision: UInt64?
    private let progress = SyncRunProgressPublisher()

    /// The reply streaming now, which the chat's saves must leave out.
    var streamingTurnId: UUID? { stream == nil ? nil : turn?.id }

    /// Whether `session`'s replies can stream to other devices right now.
    static func canStream(_ session: ChatSession) -> Bool {
        guard session.source.syncsAcrossDevices, SyncService.shared.hasOtherDevices, SyncService.shared.core != nil,
            let sessionId = session.sessionId
        else { return false }
        return SyncConversationStore.shared.scope(forSession: sessionId) != nil
    }

    func runStarted(_ session: ChatSession, streaming turn: ChatTurn? = nil) {
        self.session = session
        pinned = turn
        committed = nil
        progress.runStarted()
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// The run ended (finished, stopped or failed): commits what streamed.
    func runEnded() {
        ticker?.cancel()
        ticker = nil
        tick()
        finish()
        if let session { progress.runEnded(session) }
        pinned = nil
    }

    /// Commits the reply once a later turn follows it, so a save writing that
    /// turn lands after the reply rather than ahead of it.
    func commitIfSuperseded() {
        guard let turn, let session, session.turns.last !== turn else { return }
        finish()
    }

    private func tick() {
        guard let session else { return }
        progress.update(session)
        let last = pinned ?? session.turns.last
        if let turn, turn !== last || session.turns.last !== turn { finish() }
        guard let last, last.role == .assistant, !last.isRemotePreview, last !== committed, !last.contentIsEmpty
        else { return }
        if stream == nil {
            guard open(for: last, in: session) else { return }
        }
        guard pushedRevision != last.contentRevision else { return }
        let text = last.content
        guard text.hasPrefix(pushed) else {
            // Rewritten rather than extended (leak trimming): start over.
            stream?.abort()
            reset()
            return
        }
        let delta = String(text.dropFirst(pushed.count))
        pushedRevision = last.contentRevision
        guard !delta.isEmpty else { return }
        do {
            try stream?.push(delta: delta)
            pushed = text
        } catch {
            Self.log.error("stream push failed: \(error.syncLogDetail, privacy: .public)")
            stream?.abort()
            reset()
        }
    }

    private func open(for turn: ChatTurn, in session: ChatSession) -> Bool {
        // An image or video turn's text is a progress line rewritten each
        // step; its steps go in run progress and its result in the saved turn.
        guard !session.generatesMedia else { return false }
        guard Self.canStream(session), let core = SyncService.shared.core, let sessionId = session.sessionId,
            // Nil until the save carrying the user's turn has created the conversation.
            let scope = SyncConversationStore.shared.scope(forSession: sessionId)
        else { return false }
        do {
            stream = try core.openStream(
                scope: scope,
                role: .assistant,
                asAgent: SyncConversationStore.shared.agentSender(forSession: sessionId)
            )
            self.turn = turn
            self.sessionId = sessionId
            pushed = ""
            pushedRevision = nil
            session.syncStream = self
            return true
        } catch {
            Self.log.error("stream open failed: \(error.syncLogDetail, privacy: .public)")
            return false
        }
    }

    private func finish() {
        defer { reset() }
        guard let stream, let sessionId else { return }
        guard let turn, !turn.contentIsEmpty, session?.sessionId == sessionId else {
            stream.abort()
            return
        }
        SyncConversationStore.shared.finishStream(stream, sessionId: sessionId, turn: ChatTurnData(from: turn))
        committed = turn
    }

    private func reset() {
        if session?.syncStream === self { session?.syncStream = nil }
        stream = nil
        turn = nil
        sessionId = nil
        pushed = ""
        pushedRevision = nil
    }
}
