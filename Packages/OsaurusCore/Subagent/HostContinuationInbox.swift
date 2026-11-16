//
//  HostContinuationInbox.swift
//  OsaurusCore — Subagent framework
//
//  Results that come back to a chat no longer loaded on this Mac. A
//  background helper's report is delivered into the live `ChatSession`
//  that launched it (`SubagentReportBack.deliver`), but a chat run for the
//  phone, an automation or a closed window is released shortly after its
//  reply, and the report used to be dropped. It is kept here instead, on
//  disk so a relaunch still delivers it, and the saved chat is continued
//  with it: the same host-authored turn the live path sends, run headless.
//
//  A chat another of the user's devices sees goes through `SyncHostRunner`,
//  so the reply goes out as the agent and approvals reach those devices.
//  Every other chat continues through `BackgroundTaskManager.dispatchChat`.
//

import Foundation
import os

@MainActor
final class HostContinuationInbox {
    static let shared = HostContinuationInbox()

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "host.inbox")

    /// One result waiting for its chat.
    struct Entry: Codable, Equatable, Sendable {
        var id: UUID
        var sessionId: UUID
        var agentId: UUID?
        /// The host-authored turn, as `SubagentReportBack.message` writes it.
        var text: String
        var createdMs: Int64
        /// Continuations this entry's chat has had in a row from the inbox,
        /// counting this one; see `maxChain`.
        var chain: Int
    }

    struct State: Codable, Equatable, Sendable {
        var entries: [Entry] = []
        /// Session id (lowercased) → continuations from the inbox in a row,
        /// reset when the chat gets a turn from anywhere else.
        var chains: [String: Int] = [:]
    }

    /// A chat continued this many times in a row from the inbox, with no
    /// user turn between, gets no more: two helpers can't keep waking it.
    nonisolated static let maxChain = 3
    /// Results older than this are dropped undelivered.
    nonisolated static let maxAgeMs: Int64 = 7 * 24 * 3600 * 1000
    /// How often a waiting result is retried while its chat is busy.
    nonisolated static let retryInterval: Duration = .seconds(30)

    private var state = State()
    private var started = false
    private var draining = false
    private var retryTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        state = Store.load()
        prune()
        observers.append(
            NotificationCenter.default.addObserver(
                forName: SyncService.didOpenNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { HostContinuationInbox.shared.drain() }
            })
        drain()
    }

    // MARK: - Adding

    /// Keeps `text` for the chat `sessionId` and continues it as soon as
    /// nothing else is running it.
    func add(text: String, sessionId: UUID, agentId: UUID?) {
        let key = sessionId.uuidString.lowercased()
        let chain = (state.chains[key] ?? 0) + 1
        guard chain <= Self.maxChain else {
            Self.log.notice("dropped a result for \(key, privacy: .public): \(chain - 1) continuations in a row")
            return
        }
        let entry = Entry(
            id: UUID(),
            sessionId: sessionId,
            agentId: agentId,
            text: text,
            createdMs: Self.nowMs(),
            chain: chain
        )
        state.entries.append(entry)
        Store.save(state)
        Self.log.info("kept a result for \(key, privacy: .public)")
        drain()
    }

    /// The user (or any surface other than the inbox) gave the chat a turn:
    /// its chain starts over.
    func noteTurn(sessionId: UUID) {
        let key = sessionId.uuidString.lowercased()
        guard state.chains.removeValue(forKey: key) != nil else { return }
        Store.save(state)
    }

    // MARK: - Delivering

    private func drain() {
        guard !draining, !state.entries.isEmpty else { return }
        draining = true
        Task { @MainActor in
            defer { draining = false }
            prune()
            // One at a time, oldest first; a chat with two results gets the
            // second once the first's run has ended.
            var waiting: [Entry] = []
            var busy: Set<UUID> = []
            for entry in state.entries {
                if busy.contains(entry.sessionId) {
                    waiting.append(entry)
                    continue
                }
                if await deliver(entry) {
                    let key = entry.sessionId.uuidString.lowercased()
                    state.chains[key] = entry.chain
                    busy.insert(entry.sessionId)
                } else {
                    waiting.append(entry)
                    busy.insert(entry.sessionId)
                }
            }
            state.entries = waiting
            Store.save(state)
            scheduleRetry()
        }
    }

    /// Continues the entry's chat with its text. False when the chat can't
    /// take it now (busy, or storage not open yet); true once it is done
    /// with, delivered or dropped for good.
    private func deliver(_ entry: Entry) async -> Bool {
        // Loaded again meanwhile (the user opened it): the live path applies.
        if let live = LiveChatSessionRegistry.shared.liveSession(for: entry.sessionId)
            ?? ChatWindowManager.shared.session(forSessionId: entry.sessionId)
        {
            guard !live.isStreaming, live.awaitingClarify == nil else { return false }
            live.send(entry.text, taskIntent: .hostContinuation)
            Self.log.info("delivered to the open chat \(entry.sessionId, privacy: .public)")
            return true
        }
        switch await SyncHostRunner.shared.continueWithHostText(entry.text, sessionId: entry.sessionId) {
        case .started:
            Self.log.info("continued the synced chat \(entry.sessionId, privacy: .public)")
            return true
        case .busy:
            return false
        case .refused:
            // Its agent is gone from this Mac: nothing will ever take it.
            Self.log.notice("dropped a result for \(entry.sessionId, privacy: .public): its chat can't continue here")
            return true
        case .notSynced:
            break
        }
        let request = DispatchRequest(
            prompt: entry.text,
            agentId: entry.agentId,
            showToast: false,
            source: .chat,
            continueSessionId: entry.sessionId,
            taskIntent: .hostContinuation
        )
        guard await BackgroundTaskManager.shared.dispatchChat(request) != nil else { return false }
        Self.log.info("continued the chat \(entry.sessionId, privacy: .public)")
        return true
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        guard !state.entries.isEmpty else {
            retryTask = nil
            return
        }
        retryTask = Task { @MainActor in
            try? await Task.sleep(for: Self.retryInterval)
            guard !Task.isCancelled else { return }
            HostContinuationInbox.shared.drain()
        }
    }

    private func prune() {
        let cutoff = Self.nowMs() - Self.maxAgeMs
        let before = state.entries.count
        state.entries.removeAll { $0.createdMs < cutoff }
        if state.entries.count != before {
            Self.log.notice("dropped \(before - self.state.entries.count) results older than 7 days")
            Store.save(state)
        }
    }

    nonisolated static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - Storage

    enum Store {
        static var url: URL { OsaurusPaths.chatHistory().appendingPathComponent("host-continuations.json") }

        static func load() -> State {
            guard let data = try? EncryptedFileStore.readPolicyAware(plaintextURL: url),
                let state = try? JSONDecoder().decode(State.self, from: data)
            else { return State() }
            return state
        }

        static func save(_ state: State) {
            do {
                try FileManager.default.createDirectory(
                    at: OsaurusPaths.chatHistory(),
                    withIntermediateDirectories: true
                )
                try EncryptedFileStore.writePolicyAware(JSONEncoder().encode(state), toPlaintextURL: url)
            } catch {
                HostContinuationInbox.log.error("save failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
