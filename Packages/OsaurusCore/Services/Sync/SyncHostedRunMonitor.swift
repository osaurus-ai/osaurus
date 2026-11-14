//
//  SyncHostedRunMonitor.swift
//  osaurus
//
//  The caller's view of chats another of the user's Macs hosts: whether
//  that Mac is connected, its run state and approval cards for open chats,
//  and this device's stop requests and answers.
//

import Combine
import Foundation
import OsaurusSync
import os

@MainActor
final class SyncHostedRunMonitor: ObservableObject {
    static let shared = SyncHostedRunMonitor()

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.hosted")

    /// The user's devices this one is connected to right now.
    @Published private(set) var connectedDevices: Set<String> = []

    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var listSubscription: OsaurusSync.Subscription?
    private var watchers = 0

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        SyncStatusModel.shared.$peers
            .map { Set($0.filter(\.connected).map(\.device)) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { devices in MainActor.assumeIsolated { SyncHostedRunMonitor.shared.connectedDevices = devices } }
            .store(in: &cancellables)
        observers += SyncService.shared.observeCore(
            attach: { SyncHostedRunMonitor.shared.subscribe($0) },
            detach: { SyncHostedRunMonitor.shared.detach() })
    }

    private func detach() {
        listSubscription?.cancel()
        listSubscription = nil
    }

    private func subscribe(_ core: SyncCore) {
        listSubscription?.cancel()
        listSubscription = core.subscribeConversations { changes in
            let hosted: [Conversation] = changes.compactMap { change in
                guard case .changed(let conversation) = change,
                    conversation.tag(SyncConversationMapper.TagKey.hostDevice) != nil
                else { return nil }
                return conversation
            }
            guard !hosted.isEmpty else { return }
            Task { @MainActor in
                for conversation in hosted { SyncHostedRunMonitor.shared.apply(conversation) }
            }
        }
    }

    // MARK: - Presence

    func isConnected(_ device: String) -> Bool {
        connectedDevices.contains(device)
    }

    func hostName(_ device: String) -> String {
        SyncAgentDirectory.shared.host(device: device)?.name
            ?? SyncService.shared.deviceName(forKey: device)
            ?? L("your other Mac")
    }

    /// A hosted chat is on screen: keep connection state fresh.
    func beginWatching() {
        start()
        watchers += 1
        if watchers == 1 { SyncStatusModel.shared.beginWatching() }
    }

    func endWatching() {
        guard watchers > 0 else { return }
        watchers -= 1
        if watchers == 0 { SyncStatusModel.shared.endWatching() }
    }

    func syncSoon() {
        guard let core = SyncService.shared.core else { return }
        Task.detached(priority: .userInitiated) { core.syncNow() }
    }

    // MARK: - Host state into open chats

    /// Reads the host's state for `session`'s conversation now, for a chat
    /// that just opened.
    func refresh(_ session: ChatSession) {
        start()
        guard session.hostDeviceElsewhere != nil, let sessionId = session.sessionId,
            let core = SyncService.shared.core
        else { return }
        Task { @MainActor in
            let conversation = await Task.detached(priority: .userInitiated) { () -> Conversation? in
                guard let scope = SyncConversationStore.shared.scope(forSession: sessionId) else { return nil }
                return try? core.conversation(scope: scope)
            }.value
            if let conversation { apply(conversation) }
        }
    }

    private func apply(_ conversation: Conversation) {
        let sessionId = SyncConversationMapper.sessionId(of: conversation)
        let live = Self.liveSessions(for: sessionId).filter { $0.hostDeviceElsewhere != nil }
        guard !live.isEmpty else { return }
        let state = SyncHostedRunContract.read(
            SyncHostedRunContract.HostRun.self,
            SyncHostedRunContract.hostRunNamespace,
            from: conversation
        )
        let pending =
            SyncHostedRunContract.read(
                SyncHostedRunContract.Approvals.self,
                SyncHostedRunContract.approvalNamespace,
                from: conversation
            )?.pending ?? []
        let answered = Set(
            SyncHostedRunContract.read(
                SyncHostedRunContract.ApprovalAnswers.self,
                SyncHostedRunContract.approvalAnswerNamespace,
                from: conversation
            )?.answers.keys.map { $0 } ?? []
        )
        let waiting = pending.filter { !answered.contains($0.id) }
        let prompts = Self.unansweredPrompts(in: conversation)
        for session in live {
            if session.hostRunState != state { session.hostRunState = state }
            if session.hostApprovals != waiting { session.hostApprovals = waiting }
            if session.hostPrompts != prompts { session.hostPrompts = prompts }
        }
    }

    // MARK: - Writes

    func requestStop(sessionId: UUID, turnId: UUID) {
        let control = SyncHostedRunContract.RunControl(
            stop: turnId.uuidString.lowercased(),
            stopMs: SyncHostedRunContract.nowMs()
        )
        write(sessionId: sessionId, what: "stop") { core, scope, _ in
            try core.setConversationAppData(
                scope: scope,
                namespace: SyncHostedRunContract.runNamespace,
                bytes: try SyncHostedRunContract.encode(control)
            )
        }
    }

    func answer(sessionId: UUID, approvalId: String, answer: SyncHostedRunContract.Answer) {
        write(sessionId: sessionId, what: "approval answer") { core, scope, conversation in
            let pending = Set(
                SyncHostedRunContract.read(
                    SyncHostedRunContract.Approvals.self,
                    SyncHostedRunContract.approvalNamespace,
                    from: conversation
                )?.pending.map(\.id) ?? []
            )
            var answers =
                SyncHostedRunContract.read(
                    SyncHostedRunContract.ApprovalAnswers.self,
                    SyncHostedRunContract.approvalAnswerNamespace,
                    from: conversation
                )?.answers ?? [:]
            answers = answers.filter { pending.contains($0.key) }
            answers[approvalId] = answer
            try core.setConversationAppData(
                scope: scope,
                namespace: SyncHostedRunContract.approvalAnswerNamespace,
                bytes: try SyncHostedRunContract.encode(SyncHostedRunContract.ApprovalAnswers(answers: answers))
            )
        }
    }

    nonisolated static func unansweredPrompts(in conversation: Conversation) -> [SyncHostedRunContract.PendingPrompt] {
        let pending =
            SyncHostedRunContract.read(
                SyncHostedRunContract.Prompts.self,
                SyncHostedRunContract.promptNamespace,
                from: conversation
            )?.pending ?? []
        let answered = Set(
            SyncHostedRunContract.read(
                SyncHostedRunContract.PromptAnswers.self,
                SyncHostedRunContract.promptAnswerNamespace,
                from: conversation
            )?.answers.keys.map { $0 } ?? []
        )
        return pending.filter { !answered.contains($0.id) }
    }

    /// Seals `value` to the host's prompt key and writes it, or declines
    /// when `value` is nil. The value is never written unsealed.
    func answer(sessionId: UUID, prompt: SyncHostedRunContract.PendingPrompt, value: String?) {
        let answer: SyncHostedRunContract.PromptAnswer
        if let value {
            do {
                let sealed = try PairingKeyEnvelope.seal(
                    secret: value,
                    recipientPublicKeyBase64url: prompt.sealKey,
                    info: SyncHostedRunContract.promptSealInfo(prompt.id)
                )
                answer = SyncHostedRunContract.PromptAnswer(sealed: sealed)
            } catch {
                Self.log.error("sealing a secret failed: \(String(describing: error), privacy: .public)")
                answer = SyncHostedRunContract.PromptAnswer(cancel: true)
            }
        } else {
            answer = SyncHostedRunContract.PromptAnswer(cancel: true)
        }
        write(sessionId: sessionId, what: "prompt answer") { core, scope, conversation in
            try Self.writePromptAnswer(answer, id: prompt.id, core: core, scope: scope, conversation: conversation)
        }
    }

    /// Adds one answer, dropping answers to prompts the host no longer lists.
    nonisolated static func writePromptAnswer(
        _ answer: SyncHostedRunContract.PromptAnswer,
        id: String,
        core: SyncCore,
        scope: String,
        conversation: Conversation
    ) throws {
        let pending = Set(
            SyncHostedRunContract.read(
                SyncHostedRunContract.Prompts.self,
                SyncHostedRunContract.promptNamespace,
                from: conversation
            )?.pending.map(\.id) ?? []
        )
        var answers =
            SyncHostedRunContract.read(
                SyncHostedRunContract.PromptAnswers.self,
                SyncHostedRunContract.promptAnswerNamespace,
                from: conversation
            )?.answers ?? [:]
        answers = answers.filter { pending.contains($0.key) }
        answers[id] = answer
        try core.setConversationAppData(
            scope: scope,
            namespace: SyncHostedRunContract.promptAnswerNamespace,
            bytes: try SyncHostedRunContract.encode(SyncHostedRunContract.PromptAnswers(answers: answers))
        )
    }

    private func write(
        sessionId: UUID,
        what: String,
        _ body: @escaping @Sendable (SyncCore, String, Conversation) throws -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            do {
                try SyncConversationStore.shared.performWrite { core in
                    guard let scope = SyncConversationStore.shared.scope(forSession: sessionId),
                        let conversation = try core.conversation(scope: scope)
                    else { return }
                    try body(core, scope, conversation)
                    core.syncNow()
                }
            } catch {
                Self.log.error("\(what, privacy: .public) failed: \(error.syncLogDetail, privacy: .public)")
            }
        }
    }

    static func liveSessions(for id: UUID) -> [ChatSession] {
        var sessions: [ChatSession] = []
        if let registered = LiveChatSessionRegistry.shared.liveSession(for: id) { sessions.append(registered) }
        for session in ChatWindowManager.shared.sessions(forSessionId: id)
        where !sessions.contains(where: { $0 === session }) {
            sessions.append(session)
        }
        return sessions
    }

    #if DEBUG
        var _isAttachedForTesting: Bool { listSubscription != nil }

        func _resetForTesting() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            cancellables.removeAll()
            detach()
            started = false
        }
    #endif
}
