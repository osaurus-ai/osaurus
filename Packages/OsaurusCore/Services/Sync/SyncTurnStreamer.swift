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
    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.stream")
    /// Opening, pushing to and ending the stream, in order, off the main thread (KEEP): each takes the core's
    /// lock, which the core holds for seconds while it takes in another device's catch-up (2026-11-17).
    nonisolated private static let queue = DispatchQueue(label: "ai.osaurus.sync.turn-stream", qos: .userInitiated)
    /// A stream being opened on `queue`.
    private var opening = false
    /// The reply and chat a stream is being opened for, kept here: they don't cross to `queue`.
    private weak var openingTurn: ChatTurn?
    private weak var openingSession: ChatSession?
    /// Between `runStarted` and `runEnded`: a stream that finishes opening after the run ended is dropped.
    private var running = false

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
        // Known scopes only: a lookup waits on the core. A miss is looked up off main for the next call.
        return SyncConversationStore.shared.cachedScope(forSession: sessionId) != nil
    }

    func runStarted(_ session: ChatSession, streaming turn: ChatTurn? = nil) {
        self.session = session
        pinned = turn
        committed = nil
        running = true
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
        running = false
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
            // Opened off the main thread; the next tick pushes.
            open(for: last, in: session)
            return
        }
        guard pushedRevision != last.contentRevision else { return }
        let text = last.content
        guard let stream, text.hasPrefix(pushed) else {
            // Rewritten rather than extended (leak trimming): start over.
            let rewritten = stream
            Self.queue.async { rewritten?.abort() }
            reset()
            return
        }
        let delta = String(text.dropFirst(pushed.count))
        pushedRevision = last.contentRevision
        guard !delta.isEmpty else { return }
        pushed = text
        Self.queue.async {
            do {
                try stream.push(delta: delta)
            } catch {
                Self.log.error("stream push failed: \(error.syncLogDetail, privacy: .public)")
                stream.abort()
                Task { @MainActor [weak self] in
                    guard let self, self.stream === stream else { return }
                    self.reset()
                }
            }
        }
    }

    private func open(for turn: ChatTurn, in session: ChatSession) {
        // An image or video turn's text is a progress line rewritten each
        // step; its steps go in run progress and its result in the saved turn.
        guard !opening, !session.generatesMedia else { return }
        guard Self.canStream(session), let core = SyncService.shared.core, let sessionId = session.sessionId,
            // Nil until the save carrying the user's turn has created the conversation.
            let scope = SyncConversationStore.shared.cachedScope(forSession: sessionId)
        else { return }
        let asAgent = SyncConversationStore.shared.agentSender(forSession: sessionId)
        opening = true
        openingTurn = turn
        openingSession = session
        Self.queue.async {
            let made = Result { try core.openStream(scope: scope, role: .assistant, asAgent: asAgent) }
            Task { @MainActor [weak self] in
                guard let self else {
                    if case .success(let stream) = made { Self.queue.async { stream.abort() } }
                    return
                }
                self.opening = false
                let turn = self.openingTurn
                let session = self.openingSession
                self.openingTurn = nil
                self.openingSession = nil
                switch made {
                case .success(let stream):
                    // The run moved on (ended, or another turn) while it opened.
                    guard self.running, self.stream == nil, let turn, let session, self.session === session,
                        turn !== self.committed, (self.pinned ?? session.turns.last) === turn
                    else {
                        Self.queue.async { stream.abort() }
                        return
                    }
                    self.stream = stream
                    self.turn = turn
                    self.sessionId = sessionId
                    self.pushed = ""
                    self.pushedRevision = nil
                    session.syncStream = self
                case .failure(let error):
                    Self.log.error("stream open failed: \(error.syncLogDetail, privacy: .public)")
                }
            }
        }
    }

    private func finish() {
        defer { reset() }
        guard let stream, let sessionId else { return }
        guard let turn, !turn.contentIsEmpty, session?.sessionId == sessionId else {
            Self.queue.async { stream.abort() }
            return
        }
        // After the pushes queued ahead of it.
        let data = ChatTurnData(from: turn)
        Self.queue.async { SyncConversationStore.shared.finishStream(stream, sessionId: sessionId, turn: data) }
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
