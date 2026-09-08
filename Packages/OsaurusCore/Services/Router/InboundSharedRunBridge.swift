//
//  InboundSharedRunBridge.swift
//  osaurus
//
//  Host-side presence for shared-agent runs: when a remote caller — a
//  workspace teammate or an invite-link peer — drives one of this instance's
//  shared agents over `/agents/{id}/run`, the run is a stateless HTTP agent
//  loop with no `ChatSession` of its own. This bridge gives it one.
//
//  Each inbound run is hosted as a real, session-backed `BackgroundTaskState`
//  (`isInboundRun`) whose `ChatSession` is a read-only live transcript:
//
//  - the history row is written the moment the run starts (title
//    "Alice → Research Agent", `source == .workspace`, caller context), so
//    the conversation is in History from the first turn;
//  - `registerInboundRun` sends the ordinary `taskRegistered` signal, so the
//    run opens as a tab of the shared agent in the frontmost window without
//    stealing focus, rings `.working`, and exposes Stop;
//  - the HTTP loop's hooks push the current step and every message the host
//    produces (assistant text, tool calls, tool results) into the session,
//    which saves after each step;
//  - on finish the task is terminal and retained across relaunch like any
//    other background run; closing the tab dismisses it.
//
//  A follow-up remote turn on the same conversation (same caller +
//  `session_id`) reuses the same row / task / tab instead of starting a new
//  one. Stop is routed back through the run's registered stop closure
//  (closing the SSE channel cancels the exact request task on the host).
//

import Foundation

@MainActor
final class InboundSharedRunBridge {
    static let shared = InboundSharedRunBridge()

    /// Opaque handle the HTTP handler holds for the run's lifetime.
    struct Handle: Sendable, Equatable {
        /// Unique per request (request id).
        let runKey: String
        /// Registry task id — also the persisted session id.
        let taskId: UUID
        let agentId: UUID
        let token: InterruptToken

        static func == (lhs: Handle, rhs: Handle) -> Bool {
            lhs.runKey == rhs.runKey && lhs.taskId == rhs.taskId
        }
    }

    private struct Live {
        let handle: Handle
        let context: WorkspaceSessionContext
        let stop: @Sendable () -> Void
    }

    private var live: [String: Live] = [:]
    /// Live run keys per hosted task, so a task with two overlapping runs on
    /// the same conversation only finishes when its last run ends.
    private var runsByTask: [UUID: Set<String>] = [:]
    private let manager: BackgroundTaskManager
    private let monitor: SessionActivityMonitor
    private let sessions: ChatSessionsManager

    init(
        manager: BackgroundTaskManager = .shared,
        monitor: SessionActivityMonitor = .shared,
        sessions: ChatSessionsManager = .shared
    ) {
        self.manager = manager
        self.monitor = monitor
        self.sessions = sessions
    }

    /// Number of inbound runs currently hosted.
    var liveCount: Int { live.count }

    /// Whether the run identified by `runKey` is still live.
    func isLive(runKey: String) -> Bool { live[runKey] != nil }

    // MARK: - Lifecycle

    /// Host an inbound run: resolve (or create) its conversation, register the
    /// session-backed task, and mark the session working.
    /// - Parameters:
    ///   - runKey: unique per request (request id).
    ///   - agentId: the shared agent being driven.
    ///   - context: caller + workspace identity stamped on the row
    ///     (`callerWallet` set → served-for-caller, read-only here).
    ///   - externalKey: stable grouping key for the conversation
    ///     (`caller:session_id`); repeat runs with the same key reuse the row.
    ///   - requestMessages: caller-supplied context. An unchanged prefix
    ///     extends the conversation; edits or overlaps create a separate row.
    ///   - stop: closure that ends the run (writes a stop error and closes
    ///     the SSE channel). Invoked from the main actor.
    @discardableResult
    func begin(
        runKey: String,
        agentId: UUID,
        context: WorkspaceSessionContext,
        externalKey: String,
        requestMessages: [ChatMessage],
        stop: @escaping @Sendable () -> Void
    ) -> Handle {
        let agentName = AgentManager.shared.agent(for: agentId)?.name ?? "Shared agent"
        let callerName = context.callerLabel ?? "Teammate"
        let title = "\(callerName) → \(agentName)"
        let turns = ChatHistoryWriter.turns(from: requestMessages)

        let (taskId, session) = resolveHostedSession(
            agentId: agentId,
            context: context,
            externalKey: externalKey,
            title: title,
            turns: turns
        )

        let token = InterruptToken()
        SubagentInterruptCenter.shared.register(token, for: runKey)
        let handle = Handle(runKey: runKey, taskId: taskId, agentId: agentId, token: token)
        live[runKey] = Live(handle: handle, context: context, stop: stop)
        runsByTask[taskId, default: []].insert(runKey)
        if let sessionId = session.sessionId {
            monitor.reportSession(sessionId, status: .working)
        }
        return handle
    }

    /// Find the task + session hosting this conversation, reviving or
    /// creating as needed, with the transcript synced to `turns`.
    private func resolveHostedSession(
        agentId: UUID,
        context: WorkspaceSessionContext,
        externalKey: String,
        title: String,
        turns: [ChatTurnData]
    ) -> (UUID, ChatSession) {
        // Reuse only an idle, same-scope conversation whose observed history
        // is an exact prefix of the request. Edits, truncation and overlapping
        // runs create independent rows; caller input never rewrites evidence.
        let candidate =
            sessions.sessions.first { row in
            guard row.sourcePluginId == ChatHistoryWriter.workspacePseudoPluginId,
                row.externalSessionKey == externalKey, row.agentId == agentId,
                row.workspace?.workspaceId == context.workspaceId,
                row.workspace?.callerWallet?.lowercased() == context.callerWallet?.lowercased(),
                runsByTask[row.id]?.isEmpty != false
            else { return false }
            let observed =
                manager.taskState(for: row.id)?.chatSession?.toSessionData()
                ?? ChatSessionStore.load(id: row.id)
            return observed.map { Self.isUnchangedPrefix($0.turns, of: turns) } ?? false
        }
        let existingRowId = candidate?.id
        if let rowId = existingRowId, let task = manager.taskState(for: rowId), task.isInboundRun,
            let session = manager.reviveInboundRun(task.id)
        {
            session.appendHostedTurns(Array(turns.dropFirst(session.turns.count)))
            session.save()
            return (task.id, session)
        }

        // 2. A history row without a task (tab dismissed, or app relaunched
        //    with the run already retained-and-dismissed). Reattach to it so
        //    the conversation stays one row; a window already showing it
        //    lends its live instance so that tab keeps updating.
        var data: ChatSessionData
        if let rowId = existingRowId, let stored = ChatSessionStore.load(id: rowId) {
            data = stored
            data.title = stored.title == "New Chat" ? title : stored.title
        } else {
            data = ChatSessionData(
                id: UUID(),
                title: title,
                agentId: agentId,
                source: .workspace,
                sourcePluginId: ChatHistoryWriter.workspacePseudoPluginId,
                externalSessionKey: externalKey,
                workspace: context
            )
        }
        data.source = .workspace
        data.sourcePluginId = ChatHistoryWriter.workspacePseudoPluginId
        data.externalSessionKey = externalKey
        data.workspace = context
        data.turns.append(contentsOf: turns.dropFirst(data.turns.count))
        data.updatedAt = Date()
        data.capabilities = SessionCapability.derive(from: turns)

        let executionContext: ExecutionContext
        if let shown = ChatWindowManager.shared.session(forSessionId: data.id) {
            shown.load(from: data)
            executionContext = ExecutionContext(adopting: shown)
        } else {
            executionContext = ExecutionContext(reattaching: data)
        }
        let session = executionContext.chatSession
        // The session id must equal the task id for retained-tab hydration.
        session.sessionId = data.id
        session.save()

        let state = BackgroundTaskState(
            inboundRunId: data.id,
            taskTitle: data.title,
            agentId: agentId,
            chatSession: session,
            executionContext: executionContext,
            // Surfaces as the "for Alice" prefix on the task's step line.
            externalSessionKey: context.callerLabel
        )
        manager.registerInboundRun(state)
        return (data.id, session)
    }

    /// Compare wire-visible content, preserving IDs, timestamps and host-only
    /// metadata on already observed turns. Reasoning need not be replayed by
    /// the caller, so it is never used to replace the owner's reasoning.
    static func isUnchangedPrefix(_ observed: [ChatTurnData], of incoming: [ChatTurnData]) -> Bool {
        guard observed.count <= incoming.count else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return zip(observed, incoming).allSatisfy { old, new in
            old.role == new.role && old.content == new.content
                && old.toolCallId == new.toolCallId
                && (try? encoder.encode(old.toolCalls)) == (try? encoder.encode(new.toolCalls))
                && (try? encoder.encode(old.attachments)) == (try? encoder.encode(new.attachments))
        }
    }

    private var streamingTurns: [String: UUID] = [:]
    private var lastStreamSave: [String: Date] = [:]

    /// Awaited by the request loop: content is visible immediately and partial
    /// output is checkpointed throughout generation, including reasoning.
    func streamDelta(_ handle: Handle, content: String = "", reasoning: String = "") {
        guard live[handle.runKey] != nil,
            let session = manager.taskState(for: handle.taskId)?.chatSession
        else { return }
        if streamingTurns[handle.runKey] == nil {
            let turn = ChatTurnData(role: .assistant, content: "", createdAt: Date())
            streamingTurns[handle.runKey] = turn.id
            session.appendHostedTurns([turn])
        }
        guard let turn = session.turns.first(where: { $0.id == streamingTurns[handle.runKey] }) else { return }
        turn.appendContent(content)
        turn.appendThinking(reasoning)
        turn.lastOutputAt = Date()
        turn.notifyContentChanged()
        session.markHostedTranscriptChanged()
        if Date().timeIntervalSince(lastStreamSave[handle.runKey] ?? .distantPast) >= 0.25 {
            session.save()
            lastStreamSave[handle.runKey] = Date()
        }
    }

    /// Update the run's one-line current step.
    func step(_ handle: Handle, _ text: String) {
        guard live[handle.runKey] != nil else { return }
        manager.updateInboundRunStep(handle.taskId, step: text)
    }

    func toolStarted(_ handle: Handle, toolName: String) {
        guard live[handle.runKey] != nil else { return }
        let label = ToolDisplayName.friendly(for: toolName, running: true)
        manager.updateInboundRunStep(handle.taskId, step: label)
        manager.appendInboundRunActivity(handle.taskId, kind: .tool, title: label)
    }

    func toolFinished(_ handle: Handle, toolName: String, isError: Bool) {
        guard live[handle.runKey] != nil else { return }
        let label = ToolDisplayName.friendly(for: toolName, running: false, failed: isError)
        manager.appendInboundRunActivity(
            handle.taskId,
            kind: isError ? .error : .success,
            title: label
        )
        manager.updateInboundRunStep(handle.taskId, step: "Thinking…")
    }

    /// Mirror messages the host just produced (an assistant step, its tool
    /// calls, and the tool results) into the hosted transcript and persist.
    func appendMessages(_ handle: Handle, _ messages: [ChatMessage]) {
        guard live[handle.runKey] != nil,
            let session = manager.taskState(for: handle.taskId)?.chatSession
        else { return }
        var turns = ChatHistoryWriter.turns(from: messages)
        guard !turns.isEmpty else { return }
        if let id = streamingTurns[handle.runKey], turns.first?.role == .assistant,
            let streamed = session.turns.first(where: { $0.id == id })
        {
            // The completed message adds tool calls; its text has already
            // arrived as deltas. Keep the streamed turn and its reasoning.
            if let completed = turns.first, completed.content == streamed.content {
                turns.removeFirst()
                streamed.toolCalls = completed.toolCalls
                streamed.completedAt = Date()
            }
            streamed.notifyContentChanged()
            streamingTurns.removeValue(forKey: handle.runKey)
            lastStreamSave.removeValue(forKey: handle.runKey)
        }
        session.appendHostedTurns(turns)
        session.markHostedTranscriptChanged()
        session.save()
    }

    /// Finish the run. Idempotent. The hosted task only goes terminal once
    /// its last live run ends; a run stopped from the tab finishing later is
    /// a no-op on the (already cancelled) task.
    func finish(_ handle: Handle, success: Bool, summary: String) {
        guard live.removeValue(forKey: handle.runKey) != nil else { return }
        manager.taskState(for: handle.taskId)?.chatSession?.save()
        streamingTurns.removeValue(forKey: handle.runKey)
        lastStreamSave.removeValue(forKey: handle.runKey)
        SubagentInterruptCenter.shared.unregister(handle.runKey)
        var remaining = runsByTask[handle.taskId] ?? []
        remaining.remove(handle.runKey)
        if remaining.isEmpty {
            runsByTask.removeValue(forKey: handle.taskId)
            manager.finishInboundRun(handle.taskId, success: success, summary: summary)
            monitor.reportSession(handle.taskId, status: nil)
        } else {
            runsByTask[handle.taskId] = remaining
        }
    }

    /// Cancel only runs in the affected authorization scope. A nil scope
    /// means all workspace runs (verification connection lost), never direct invites.
    func stopWorkspaceRuns(workspaceId: String? = nil, agentAddress: String? = nil, callerWallet: String? = nil) {
        let affected = live.values.filter { entry in
            !entry.context.workspaceId.isEmpty
                && (workspaceId == nil || entry.context.workspaceId == workspaceId)
                && (agentAddress == nil || entry.context.agentAddress.lowercased() == agentAddress?.lowercased())
                && (callerWallet == nil || entry.context.callerWallet?.lowercased() == callerWallet?.lowercased())
        }
        for entry in affected { stopRequested(runKey: entry.handle.runKey) }
    }

    /// Called by `BackgroundTaskManager.cancelTask` for inbound-run tasks:
    /// trips every live run's interrupt token and stop closure so the host
    /// actually ends the run(s), and clears the session's activity.
    func stopRequested(taskId: UUID) {
        guard let keys = runsByTask[taskId] else { return }
        for key in keys {
            guard let entry = live[key] else { continue }
            entry.handle.token.interrupt()
            entry.stop()
        }
        monitor.reportSession(taskId, status: nil)
    }

    /// Stop a single run by key (owner-side Stop on one request).
    func stopRequested(runKey: String) {
        guard let entry = live[runKey] else { return }
        entry.handle.token.interrupt()
        entry.stop()
        monitor.reportSession(entry.handle.taskId, status: nil)
    }
}

/// Per-request bundle the HTTP agent-run handler carries for an inbound
/// shared-agent run: the persisted caller context, the live handle, and the
/// stable history grouping key (`caller:session_id`).
struct InboundSharedRun: Sendable {
    let context: WorkspaceSessionContext
    let handle: InboundSharedRunBridge.Handle
    let externalKey: String

    /// Mutable terminal outcome recorded by the handler before its `defer`
    /// finishes the run. Defaults to a failed/stopped row so an early
    /// bail-out never leaves the tab spinning or reads as success.
    final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var _success = false
        private var _summary = "Stopped"
        private var _toolNames: [String] = []
        private var _toolErrorCount = 0

        init() {}

        var success: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _success
        }

        /// Tool names executed during the run, in completion order (audit
        /// trail metadata — names only, never arguments or results).
        var toolNames: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _toolNames
        }

        var toolErrorCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _toolErrorCount
        }

        func recordTools(_ finished: [(name: String, isError: Bool)]) {
            lock.lock()
            defer { lock.unlock() }
            for item in finished {
                _toolNames.append(item.name)
                if item.isError { _toolErrorCount += 1 }
            }
        }

        var summary: String {
            lock.lock()
            defer { lock.unlock() }
            return _summary
        }

        func record(exit: AgentToolLoop.Exit, cancelled: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                _success = false
                _summary = "Stopped"
                return
            }
            switch exit {
            case .finalResponse, .endedBySurface, .iterationCapReached:
                _success = true
                _summary = "Completed"
            case .overBudget:
                _success = false
                _summary = "Context window exceeded"
            case .emptyResponseExhausted, .lengthExhausted, .oversizedToolCallExhausted,
                .truncatedToolCallExhausted, .repetitionLoopExhausted,
                .incompleteReasoningExhausted:
                _success = false
                _summary = "No final answer"
            case .toolRejected:
                _success = false
                _summary = "Tool rejected"
            case .cancelled:
                _success = false
                _summary = "Stopped"
            }
        }

        func record(error: Error, cancelled: Bool) {
            lock.lock()
            defer { lock.unlock() }
            _success = false
            _summary =
                cancelled || error is CancellationError
                ? "Stopped"
                : "Failed: \(error.localizedDescription)"
        }
    }
}
