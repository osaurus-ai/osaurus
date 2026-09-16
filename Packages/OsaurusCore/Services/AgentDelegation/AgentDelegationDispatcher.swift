//
//  AgentDelegationDispatcher.swift
//  OsaurusCore — Agent delegation
//
//  True delegation for agent-targeted spawns. Instead of the ephemeral,
//  budget-capped `AgentSubagentRunner` mini-loop, an agent target runs as a
//  REAL dispatched `ChatSession` via `BackgroundTaskManager.dispatchChat`:
//
//   • the child retains the TARGET agent's tools, temperature and memory;
//     its model is the exact identity resolved by spawn admission (including
//     an explicit launcher override), and delegated budgets tighten its caps;
//   • one persisted session per delegation call (`source: .delegation`),
//     visible in the target agent's chat history; a follow-up call with
//     `continue: <session_id>` reattaches to that same session so the worker
//     keeps its context (`externalSessionKey` = `delegation:<session id>`);
//   • the dispatched run is a real background task, so the Activity row's
//     "Open Chat" opens the live child chat mid-run.
//
//  The caller (`TextSubagentKind.run`) still owns the full host lifecycle:
//  the spawn allow-list, permission gate, recursion guard, process-wide
//  admission, and the local-model residency handoff all ran before this
//  dispatcher is reached. The launcher's `maxElapsedSeconds` also bounds
//  the awaited run's wall-clock execution time.
//
//  CAPABILITY SURFACE CONTRACT — the delegated child IS the target agent:
//  it carries the target agent's full direct-chat tool surface, including
//  its single-level subagent kinds (image, computer use, AppleScript) when
//  the target enables them, with per-tool permission gates applying exactly
//  as in a direct chat with that agent. This is deliberately BROADER than
//  the legacy bounded child (which intersected with the audited toolset and
//  excluded all subagent-capability tools) — the user vouched for the
//  target by adding it to the spawn allow-list. Exactly two tools are
//  stripped by the composer for `.delegation` sessions, both structural:
//    * every spawn tool — fan-out/recursion is prevented in the schema, and
//    * `clarify` — the child's requester is the orchestrator model, so a
//      user question would strand the run until its wall-clock budget.
//  The built-in Default agent is never a valid target (`resolveAgentTarget`
//  denies it) — its orchestrator/configure surface must not run under
//  model-generated input. Tested in `AgentDelegationDispatcherTests`.
//
//  ARTIFACT PASS-THROUGH — the child's `share_artifact` runs the normal
//  direct-chat path, so its artifacts land in the CHILD session's store and
//  transcript. After the run reaches ANY terminal state, the dispatcher
//  harvests them, copies the files into the PARENT session's store, and
//  deposits typed `SharedArtifact`s in `SpawnArtifactCollector` — the same
//  collector the parent chat loop drains after every spawn tool return —
//  so the cards appear in the parent conversation and survive the child
//  session's deletion. The spawn payload carries only an `artifacts_shared`
//  count; no artifact bytes enter model-visible JSON.
//

import Foundation

/// A working folder handed to a delegated child (the target's own or the
/// requester's, inherited for the task).
struct DelegatedWorkingFolder: Sendable, Equatable {
    let bookmark: Data?
    let path: String?
}

/// Terminal outcome of one delegated child chat run.
struct AgentDelegationOutcome: Sendable {
    /// The persisted child session id (== the background task id).
    let sessionId: UUID
    /// The final assistant turn's visible text (or the child's `complete`
    /// tool summary when the run ended through the loop intercept with no
    /// trailing prose).
    let finalText: String
    /// Assistant turns the child produced (a rough "iterations" analogue
    /// for the parent's result payload).
    let assistantTurns: Int
    let elapsed: TimeInterval
    /// Measured completion tokens summed over the child's assistant turns
    /// (GPU-timed for MLX, UI-estimated for remote). Nil when the child
    /// recorded none.
    let completionTokens: Int?
    /// Generation throughput derived from the child's per-turn token counts
    /// and generation wall clock. Nil when timing wasn't recorded.
    let tokensPerSecond: Double?
    /// Estimated size of the child's full transcript (all roles + thinking),
    /// the delegated analogue of the ephemeral path's `worker_tokens` — what
    /// the parent's context is spared by receiving only the digest.
    let transcriptTokenEstimate: Int
    /// Artifacts the child shared that were adopted into the parent
    /// session's store and deposited for the parent's drain. Grounds the
    /// spawn payload's `artifacts_shared` count. Zero when the child shared
    /// nothing (or no parent session was supplied).
    var artifactsShared: Int = 0
    /// True when the child ended its turn asking the requester for input
    /// (its final message starts with the `needsInputMarker`). The parent
    /// answers with `spawn_agent(continue: session_id, input: …)`.
    var needsInput: Bool {
        AgentDelegationDispatcher.isNeedsInput(finalText)
    }
}

enum AgentDelegationDispatcher {
    /// Prefix a delegated child uses to hand a question back to the
    /// requester instead of guessing (the child has no `clarify` tool —
    /// its requester is the orchestrator model, not the user).
    static let needsInputMarker = "NEEDS INPUT:"

    /// The stable reattach key for a delegated child session, so a
    /// `continue` call finds the same persisted row.
    static func externalSessionKey(for sessionId: UUID) -> String {
        "delegation:" + sessionId.uuidString
    }

    /// Whether a child's final message is a request for input.
    static func isNeedsInput(_ finalText: String) -> Bool {
        finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .hasPrefix(needsInputMarker)
    }

    /// Title prefix for delegated child sessions in the target agent's
    /// chat history sidebar.
    static let titlePrefix = "Delegated: "

    /// The tool result a parent reads when a shared (workspace) agent could
    /// not be dispatched: the typed reason (offline, unshared, router off…)
    /// plus the re-plan instruction. Pure; the workspace eval lane pins it.
    static func workspaceRefusal(reason: String) -> String {
        reason + " Pick a different agent for this task, or report that it is unavailable."
    }

    /// How long a dispatched child may sit `.queued` (dispatch capacity
    /// saturated) before the delegation gives up. Separate from the run
    /// budget — queue wait must not eat execution time — but proportional to
    /// it, floored so a tiny budget still tolerates a brief burst of
    /// concurrent tasks. Pure, for unit tests.
    static func queueGraceSeconds(runBudget: TimeInterval) -> TimeInterval {
        max(60, runBudget)
    }

    /// The dispatched child's user prompt: the spawn `input` plus a delivery
    /// contract. The child is a REAL chat session of the target agent, so
    /// nothing else tells it that only its final message returns to the
    /// requester (as a size-capped digest) or that `share_artifact` shares
    /// pass through to the requesting conversation. Without the contract,
    /// workers paste whole files into their answer (truncated by the digest
    /// cap) or end the run on intermediate commentary that becomes the
    /// digest. When the local target agent has a configured Working Folder
    /// (`workingFolderPath`), the contract also names it: the dispatched run
    /// mounts that folder (`BackgroundTaskManager.resolveDispatchFolder`), so
    /// the child's file tools can write there — the only on-disk delivery
    /// path a delegation has (issue #2703). Pure, for unit tests.
    static func delegatedPrompt(
        input: String,
        remote: Bool = false,
        workingFolderPath: String? = nil,
        resuming: Bool = false
    ) -> String {
        if resuming {
            return input + "\n\n" + followUpContract
        }
        let contract: String
        if remote {
            contract = remoteDeliveryContract
        } else if let folder = workingFolderPath, !folder.isEmpty {
            contract = workingFolderDeliveryContract(folderPath: folder)
        } else {
            contract = deliveryContract
        }
        return input + "\n\n" + contract
    }

    /// Shared framing every local contract opens with: the requester sees
    /// only the final message, and questions go back as `NEEDS INPUT:`.
    static let requesterFraming: String =
        "[Delegated task]\n"
        + "You are running as a delegated subtask for another agent. The requester "
        + "sees ONLY your final message, returned as a compact size-capped digest — "
        + "intermediate commentary is lost, so finish with a message that stands "
        + "alone as the result.\n"
        + "If you cannot proceed without an answer from the requester, end your turn "
        + "with a message that starts with `\(needsInputMarker)` followed by the exact "
        + "question; the requester will reply in this same conversation. Otherwise "
        + "state reasonable assumptions and finish the work.\n"

    /// Delivery contract for a local child that has a working folder (its
    /// own, or the requester's folder inherited for this task). Deliverables
    /// go on disk under it; the final message names the paths so the
    /// requester can read them with `file_read` instead of paying for the
    /// content twice. `share_artifact` stays the path for content the
    /// REQUESTER should receive as a card. If the folder failed to mount,
    /// `ExecutionContext` already prefixed the prompt with an explicit
    /// folder-unreadable preamble, so this text never asks the child to
    /// invent a location.
    static func workingFolderDeliveryContract(folderPath: String) -> String {
        requesterFraming
            + "Your working folder is `\(folderPath)`. Your file tools operate on it with "
            + "paths relative to that folder. Write deliverables (code, documents, data, "
            + "reports) there with `file_write` / `file_edit`, and end with a SHORT summary "
            + "that lists the exact relative paths you wrote plus the key findings — do NOT "
            + "paste file contents into the final message. Use `share_artifact` only when "
            + "the task asks for a file to be returned to the requester rather than saved "
            + "in the working folder. Never write outside the working folder or invent a "
            + "different location.\n"
            + "[/Delegated task]"
    }

    /// Contract for a workspace (Mode 2) child: the host runs its own agent
    /// loop and only the final visible answer streams back, so files
    /// written or shared on the host stay on the host — unless the host
    /// attaches small artifacts to the final envelope, which the requester's
    /// Osaurus promotes to artifact cards.
    static let remoteDeliveryContract: String =
        "[Delegated task]\n"
        + "You are running as a delegated subtask for another agent on a teammate's "
        + "Osaurus. The requester sees ONLY your final message, returned as a compact "
        + "size-capped digest — intermediate commentary is lost, so finish with a "
        + "message that stands alone as the result. Include deliverable content "
        + "directly in that final message, or share files with `share_artifact`: small "
        + "files (a few MB in total) reach the requester as cards with your final message; "
        + "larger ones and plain files written to disk stay on this Mac — say so, and "
        + "summarise their content instead.\n"
        + "If you cannot proceed without an answer from the requester, end your turn "
        + "with a message that starts with `\(needsInputMarker)` followed by the exact "
        + "question.\n"
        + "[/Delegated task]"

    /// Appended to every delegated child prompt that has no working folder
    /// (see `delegatedPrompt`).
    static let deliveryContract: String =
        requesterFraming
        + "File deliverables (code files, documents, pages, data): when a "
        + "`share_artifact` tool is available, share each file with it "
        + "(`content` + `filename`) — shared files reach the requesting "
        + "conversation directly as artifact cards. After sharing, keep your "
        + "final message a short summary that names the shared file(s); do NOT "
        + "paste their content again. Only when `share_artifact` is unavailable, "
        + "include the complete deliverable in your final message.\n"
        + "[/Delegated task]"

    /// Short reminder appended to a `continue` follow-up: the session
    /// already carries the full contract in its first turn.
    static let followUpContract: String =
        "[Delegated follow-up]\n"
        + "Same rules as before: the requester sees only your final message; write "
        + "deliverables to your working folder (or `share_artifact`) and name them; "
        + "start with `\(needsInputMarker)` if you are blocked on a question.\n"
        + "[/Delegated follow-up]"

    /// Compact one-line child session title derived from the spawn input.
    static func sessionTitle(for input: String) -> String {
        let firstLine =
            input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first ?? ""
        let capped =
            firstLine.count > 60
            ? String(firstLine.prefix(60)) + "…"
            : firstLine
        return titlePrefix + (capped.isEmpty ? "task" : capped)
    }

    /// Why the awaited child run was cancelled by this dispatcher (as
    /// opposed to failing or completing on its own).
    private enum CancelReason: Sendable {
        /// The spawn card / Activity Stop button tripped the interrupt token.
        case interrupt
        /// The launcher's wall-clock budget (`maxElapsedSeconds`) expired
        /// while the child was actually executing.
        case deadline
        /// The child never left the background task queue within the queue
        /// grace window (dispatch capacity saturated).
        case queueTimeout
        /// The orchestrator turn's task tree was cancelled.
        case parentTask
    }

    /// Coarse child lifecycle as the parent's spawn card narrates it.
    /// Tracked so the watcher emits one feed phase per TRANSITION, not one
    /// per poll tick.
    private enum ObservedPhase: Equatable {
        case queued
        case running
        case waitingForInput
    }

    /// One-slot box recording the FIRST cancel reason. Written by the
    /// watcher/cancellation paths before `cancelTask` fires, read after
    /// `awaitCompletion` resumes — a happens-before ordering via the lock.
    private final class CancelReasonBox: @unchecked Sendable {
        private let lock = NSLock()
        private var reason: CancelReason?

        /// Record `reason` unless one was already recorded. Returns whether
        /// this call won the slot (the winner triggers the actual cancel).
        func record(_ new: CancelReason) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard reason == nil else { return false }
            reason = new
            return true
        }

        var value: CancelReason? {
            lock.lock()
            defer { lock.unlock() }
            return reason
        }
    }

    /// Dispatch the delegated child chat and await its terminal state.
    ///
    /// Cancellation contract: the spawn interrupt token, the launcher's
    /// wall-clock deadline, and parent-task cancellation each stop the child
    /// via `BackgroundTaskManager.cancelTask` (which stops the live stream
    /// and resumes the awaited completion), then surface as distinct
    /// `SubagentError`s so a user Stop is never reported as a timeout.
    static func run(
        targetAgentId: UUID,
        targetAgentName: String,
        input: String,
        maxElapsedSeconds: Int,
        maxResponseTokens: Int? = nil,
        maxAssistantTurns: Int? = nil,
        maxContextPositions: Int? = nil,
        model: String,
        feed: SubagentFeed,
        interrupt: InterruptToken,
        parentSessionId: String? = nil,
        launcherWorkingFolder: DelegatedWorkingFolder? = nil,
        continueSessionId: UUID? = nil
    ) async throws -> AgentDelegationOutcome {
        try await run(
            target: .local(targetAgentId),
            targetAgentName: targetAgentName,
            input: input,
            maxElapsedSeconds: maxElapsedSeconds,
            maxResponseTokens: maxResponseTokens,
            maxAssistantTurns: maxAssistantTurns,
            maxContextPositions: maxContextPositions,
            model: model,
            feed: feed,
            interrupt: interrupt,
            parentSessionId: parentSessionId,
            launcherWorkingFolder: launcherWorkingFolder,
            continueSessionId: continueSessionId
        )
    }

    /// Pick the folder a local child runs in: the target agent's own Working
    /// Folder wins; otherwise the requester's folder is inherited for this
    /// task so a folder-less worker still has somewhere to read inputs and
    /// write deliverables. Pure, for unit tests.
    static func resolveChildWorkingFolder(
        targetFolder: DelegatedWorkingFolder?,
        launcherFolder: DelegatedWorkingFolder?
    ) -> (folder: DelegatedWorkingFolder?, inherited: Bool) {
        if let targetFolder, targetFolder.path?.isEmpty == false || targetFolder.bookmark != nil {
            return (targetFolder, false)
        }
        if let launcherFolder, launcherFolder.path?.isEmpty == false || launcherFolder.bookmark != nil {
            return (launcherFolder, true)
        }
        return (nil, false)
    }

    /// Validate a `continue` target before dispatch: the session must exist,
    /// be a delegated child of the same target, and not be running right
    /// now. Returns the persisted row (turns not needed).
    @MainActor
    static func validateResumeSession(
        _ sessionId: UUID,
        target: AgentDispatchTarget,
        targetAgentName: String
    ) throws -> ChatSessionData {
        if let live = BackgroundTaskManager.shared.taskState(for: sessionId), live.status.isActive {
            throw SubagentError.unavailable(
                "Worker session \(sessionId.uuidString) for '\(targetAgentName)' is still running; "
                    + "wait for its result before continuing it."
            )
        }
        let db = ChatHistoryDatabase.shared
        if !db.isOpen { try? db.open() }
        guard let session = db.loadSession(id: sessionId) else {
            throw SubagentError.unavailable(
                "No delegated worker session \(sessionId.uuidString) exists to continue. "
                    + "Start a new task instead (omit `continue`)."
            )
        }
        guard session.source == .delegation else {
            throw SubagentError.denied(
                "Session \(sessionId.uuidString) is not a delegated worker session; only "
                    + "`session_id` values returned by spawn_agent can be continued."
            )
        }
        switch target {
        case .local(let agentId):
            guard session.agentId == agentId else {
                throw SubagentError.denied(
                    "Session \(sessionId.uuidString) belongs to a different agent than "
                        + "'\(targetAgentName)'. Continue it with the agent that produced it."
                )
            }
        case .workspace(let ref):
            guard let stamped = session.workspace,
                stamped.agentAddress.caseInsensitiveCompare(ref.agentAddress) == .orderedSame
            else {
                throw SubagentError.denied(
                    "Session \(sessionId.uuidString) was not produced by workspace agent "
                        + "'\(targetAgentName)'."
                )
            }
        }
        guard session.externalSessionKey == externalSessionKey(for: sessionId) else {
            throw SubagentError.unavailable(
                "Session \(sessionId.uuidString) predates resumable delegation and cannot be "
                    + "continued. Start a new task instead."
            )
        }
        return session
    }

    /// `run` for any `AgentDispatchTarget`. A `.workspace` target is a Mode 2 run on
    /// the teammate's Mac: `BackgroundTaskManager.dispatchChat` probes the
    /// host's liveness and connects before registering the task, and a
    /// refusal (offline, lapsed key, unshared) surfaces here as
    /// `SubagentError.unavailable` with the exact reason — the parent model
    /// re-plans from the tool result; nothing in the prompt changes.
    static func run(
        target: AgentDispatchTarget,
        targetAgentName: String,
        input: String,
        maxElapsedSeconds: Int,
        maxResponseTokens: Int? = nil,
        maxAssistantTurns: Int? = nil,
        maxContextPositions: Int? = nil,
        model: String? = nil,
        feed: SubagentFeed,
        interrupt: InterruptToken,
        parentSessionId: String? = nil,
        launcherWorkingFolder: DelegatedWorkingFolder? = nil,
        continueSessionId: UUID? = nil
    ) async throws -> AgentDelegationOutcome {
        let started = Date()
        // The folder the child will actually run in: the target agent's
        // configured Working Folder, else the requester's folder inherited
        // for this task. The request carries the resolved folder explicitly
        // so `resolveDispatchFolder` mounts exactly what the contract names.
        let childFolder: (folder: DelegatedWorkingFolder?, inherited: Bool) = await MainActor.run {
            guard case .local(let agentId) = target else { return (nil, false) }
            let own = AgentManager.shared.workingFolder(for: agentId)
            return resolveChildWorkingFolder(
                targetFolder: own.map { DelegatedWorkingFolder(bookmark: $0.bookmark, path: $0.path) },
                launcherFolder: launcherWorkingFolder
            )
        }
        if let continueSessionId {
            _ = try await MainActor.run {
                try validateResumeSession(
                    continueSessionId,
                    target: target,
                    targetAgentName: targetAgentName
                )
            }
        }
        let sessionId = continueSessionId ?? UUID()
        let request = DispatchRequest(
            id: sessionId,
            prompt: delegatedPrompt(
                input: input,
                remote: target.isWorkspace,
                workingFolderPath: childFolder.folder?.path,
                resuming: continueSessionId != nil
            ),
            target: target,
            title: sessionTitle(for: input),
            folderPath: target.isWorkspace ? nil : childFolder.folder?.path,
            folderBookmark: target.isWorkspace ? nil : childFolder.folder?.bookmark,
            source: .delegation,
            // Every delegated session is keyed by its own id so a later
            // `continue` reattaches to it; a fresh call never collides
            // because its id is new.
            externalSessionKey: externalSessionKey(for: sessionId),
            // The orchestrator turn is synchronously waiting on this run
            // (or awaiting its report-back), so its model load carries
            // interactive intent.
            loadIntent: .interactive,
            // Enforced delegation budget: the chat surface clamps its
            // per-generation max tokens and tool-loop turns to these, and
            // RAM admission prices the child from the SAME values.
            delegationResponseTokenCap: maxResponseTokens,
            delegationContextPositionCap: maxContextPositions,
            delegationAssistantTurnCap: maxAssistantTurns,
            delegationModel: target.isWorkspace ? nil : model
        )

        // The child is a REAL chat session of the target agent, not a
        // nested subagent loop: clear the family recursion guard so the
        // dispatched session's own turns (which inherit task-locals from
        // this call at `Task` creation inside `ChatSession.send`) don't
        // refuse the target agent's ordinary single-level subagent kinds.
        // Fan-out is prevented structurally instead: the composer strips
        // every spawn tool from `.delegation`-sourced sessions, and the
        // execution scope rejects tools outside the composed schema.
        if target.isWorkspace {
            feed.emitPhase("checking", detail: "confirming '\(targetAgentName)' is online")
        }
        let handle = await SubagentSession.$activeKindId.withValue(nil) {
            await BackgroundTaskManager.shared.dispatchChat(request)
        }
        guard let handle else {
            if let ref = target.workspaceRef,
                let reason = await MainActor.run(body: {
                    BackgroundTaskManager.shared.consumeWorkspaceDispatchRefusal(for: ref)
                })
            {
                throw SubagentError.unavailable(workspaceRefusal(reason: reason))
            }
            throw SubagentError.unavailable(
                "Agent '\(targetAgentName)' could not be dispatched as a delegated chat session."
            )
        }
        let taskId = handle.id
        feed.setDelegatedSessionId(taskId.uuidString)
        let resumedNote = continueSessionId != nil ? " (continuing worker session)" : ""
        let folderNote = childFolder.inherited ? " in the requester's folder" : ""
        feed.emitPhase(
            "delegated",
            detail: target.isWorkspace
                ? "running on '\(targetAgentName)' via workspace relay\(resumedNote)"
                : "running as a chat session of '\(targetAgentName)'\(folderNote)\(resumedNote)"
        )

        let reasonBox = CancelReasonBox()
        let cancelChild: @Sendable (CancelReason) -> Void = { reason in
            guard reasonBox.record(reason) else { return }
            Task { @MainActor in
                BackgroundTaskManager.shared.cancelTask(taskId)
            }
        }

        // Watch the interrupt token, the child's lifecycle, and the wall
        // clock while the completion await is suspended. The launcher's
        // `maxElapsedSeconds` is the only surviving launcher budget for
        // agent delegations — and it is QUEUE-AWARE: the budget clock starts
        // when the child actually leaves `.queued`, so a saturated dispatch
        // queue can't silently eat the child's execution time. A separate
        // queue grace bounds the wait for a slot so a never-promoted task
        // still terminates. Status transitions (queued / waiting for input)
        // are narrated to the parent's spawn card, so a child paused on a
        // secret / permission prompt explains itself instead of dying as a
        // silent timeout.
        let runBudget = TimeInterval(max(1, maxElapsedSeconds))
        let queueGrace = queueGraceSeconds(runBudget: runBudget)
        let watcher = Task {
            var runStartedAt: Date?
            var observed: ObservedPhase?
            var mirroredActivityIds = Set<UUID>()
            var lastTokensOut = 0
            while !Task.isCancelled {
                if interrupt.isInterrupted {
                    cancelChild(.interrupt)
                    return
                }
                let snapshot = await MainActor.run {
                    () -> (
                        status: BackgroundTaskStatus,
                        activity: [BackgroundTaskActivityItem],
                        tokensOut: Int
                    )? in
                    guard
                        let state = BackgroundTaskManager.shared.taskState(for: taskId)
                    else { return nil }
                    return (state.status, state.activityFeed, state.tokensOut)
                }

                // Live progress: mirror the child's tool calls and its token
                // counter onto the parent's spawn card, so a long delegated
                // run visibly advances instead of freezing on one phase line
                // until the final answer. The activity feed is bounded (40)
                // and id-stable, so an id set is a safe new-item cursor.
                if let snapshot {
                    for item in snapshot.activity
                    where item.kind == .tool && !mirroredActivityIds.contains(item.id) {
                        feed.emit(
                            SubagentActivityEvent(
                                kind: .act,
                                title: item.detail ?? item.title
                            )
                        )
                    }
                    mirroredActivityIds = Set(snapshot.activity.map(\.id))
                    if snapshot.tokensOut > lastTokensOut {
                        lastTokensOut = snapshot.tokensOut
                        feed.emitProgress(
                            "generating",
                            detail: "\(snapshot.tokensOut) tokens"
                        )
                    }
                }

                let now = Date()
                switch snapshot?.status {
                case .queued:
                    if observed != .queued {
                        observed = .queued
                        feed.emitPhase(
                            "queued",
                            detail: "waiting for a background task slot"
                        )
                    }
                    if now.timeIntervalSince(started) >= queueGrace {
                        cancelChild(.queueTimeout)
                        return
                    }
                case .waitingForInput:
                    if runStartedAt == nil { runStartedAt = now }
                    if observed != .waitingForInput {
                        observed = .waitingForInput
                        feed.emitPhase(
                            "waiting for input",
                            detail:
                                "'\(targetAgentName)' needs a user response — open the child chat to answer"
                        )
                    }
                    if let runStartedAt,
                        now.timeIntervalSince(runStartedAt) >= runBudget
                    {
                        cancelChild(.deadline)
                        return
                    }
                case .running, .completed, .failed, .cancelled, nil:
                    // `nil` (task finalized/removed) and terminal states end
                    // via `awaitCompletion`; treat them like running so the
                    // budget clock keeps a single start point.
                    if runStartedAt == nil { runStartedAt = now }
                    if observed == .queued || observed == .waitingForInput {
                        feed.emitPhase(
                            "delegated",
                            detail: "running as a chat session of '\(targetAgentName)'"
                        )
                    }
                    observed = .running
                    if let runStartedAt,
                        now.timeIntervalSince(runStartedAt) >= runBudget
                    {
                        cancelChild(.deadline)
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watcher.cancel() }

        // The watcher owns queue grace + run budget, so the manager's own
        // watchdog only backstops a cancel that never reaches a terminal
        // state.
        let watchdogSeconds = UInt64(queueGrace + runBudget) + 120
        let result = await withTaskCancellationHandler {
            await BackgroundTaskManager.shared.awaitCompletion(
                taskId,
                timeoutSeconds: watchdogSeconds
            )
        } onCancel: {
            cancelChild(.parentTask)
        }
        let elapsed = Date().timeIntervalSince(started)

        // Artifact pass-through for EVERY terminal state: whatever the child
        // shared before completing, failing, or being cancelled is adopted
        // into the parent session's store and deposited for the parent's
        // drain (the parent chat drains after failure envelopes too, so a
        // cancelled child's artifacts still reach the user).
        let artifactsShared = await adoptChildArtifacts(
            childSessionId: taskId,
            parentSessionId: parentSessionId
        )

        switch result {
        case .completed:
            guard var outcome = await harvestOutcome(sessionId: taskId, elapsed: elapsed) else {
                throw SubagentError.executionFailed(
                    message:
                        "Delegated agent '\(targetAgentName)' finished without producing a result.",
                    retryable: true
                )
            }
            outcome.artifactsShared = artifactsShared
            return outcome
        case .cancelled:
            switch reasonBox.value {
            case .interrupt:
                throw SubagentError.userDenied(
                    "Delegated run for '\(targetAgentName)' was stopped by the user."
                )
            case .deadline:
                throw SubagentError.timedOut(
                    "Delegated run for '\(targetAgentName)' hit its \(maxElapsedSeconds)s time budget."
                )
            case .queueTimeout:
                throw SubagentError.timedOut(
                    "Delegated run for '\(targetAgentName)' waited \(Int(queueGrace))s "
                        + "for a background task slot without starting. "
                        + "Retry when fewer background tasks are running."
                )
            case .parentTask:
                throw SubagentError.executionFailed(
                    message: "Delegated run for '\(targetAgentName)' was cancelled with the parent run.",
                    retryable: false
                )
            case .none:
                // Cancelled from outside this dispatcher (Activity Stop on the
                // child task itself, app shutdown).
                throw SubagentError.userDenied(
                    "Delegated run for '\(targetAgentName)' was stopped."
                )
            }
        case .failed(let message):
            throw SubagentError.executionFailed(
                message: "Delegated agent '\(targetAgentName)' failed: \(message)",
                retryable: true
            )
        }
    }

    /// Read the persisted child session (saved by `markCompleted` before the
    /// completion continuation resumes) and extract the final assistant
    /// turn's visible text. Nil when the transcript carries no non-empty
    /// assistant answer.
    @MainActor
    static func harvestOutcome(
        sessionId: UUID,
        elapsed: TimeInterval
    ) -> AgentDelegationOutcome? {
        // Prefer the LIVE session still retained by the background task:
        // persistence goes through `saveAsync` (an off-main write queue), so
        // a store load right at the completion signal can read a snapshot
        // that predates the final turn's stats (token counts, completedAt) —
        // which silently drops the `usage` block from the spawn payload.
        if let live = BackgroundTaskManager.shared.taskState(for: sessionId)?
            .executionContext?.chatSession,
            live.sessionId == sessionId
        {
            return outcome(from: live.toSessionData(), elapsed: elapsed)
        }
        guard let session = ChatSessionStore.load(id: sessionId) else { return nil }
        return outcome(from: session, elapsed: elapsed)
    }

    /// Adopt every artifact the child session shared into the PARENT
    /// session's artifact store and deposit them in `SpawnArtifactCollector`
    /// for the parent chat loop's post-spawn drain. Returns how many were
    /// deposited. No-op without a parent session (HTTP/eval parents have no
    /// drain — anything deposited would be discarded by their run loop
    /// anyway, matching the ephemeral worker path's semantics).
    @MainActor
    static func adoptChildArtifacts(
        childSessionId: UUID,
        parentSessionId: String?
    ) -> Int {
        guard let parentSessionId, !parentSessionId.isEmpty else { return 0 }
        // Same live-session preference as `harvestOutcome`: the persisted
        // snapshot can trail the just-finished turn.
        let turns: [ChatTurnData]
        if let live = BackgroundTaskManager.shared.taskState(for: childSessionId)?
            .executionContext?.chatSession,
            live.sessionId == childSessionId
        {
            turns = live.toSessionData().turns
        } else if let session = ChatSessionStore.load(id: childSessionId) {
            turns = session.turns
        } else {
            return 0
        }
        var adopted = 0
        for artifact in harvestArtifacts(from: turns) {
            guard
                let rekeyed = SharedArtifact.adoptIntoContext(
                    artifact,
                    contextId: parentSessionId,
                    sourceRootContextId: childSessionId.uuidString
                )
            else { continue }
            SpawnArtifactCollector.deposit(rekeyed, sessionId: parentSessionId)
            adopted += 1
        }
        return adopted
    }

    /// Every artifact the child transcript carries, in turn order: typed
    /// `sharedArtifacts` attachments (generated media promotions) plus
    /// enriched `share_artifact` tool results. Deduped by backing file so a
    /// result that was both enriched AND promoted adopts once. Pure.
    static func harvestArtifacts(from turns: [ChatTurnData]) -> [SharedArtifact] {
        var seen = Set<String>()
        var artifacts: [SharedArtifact] = []
        func add(_ artifact: SharedArtifact) {
            // `fromEnrichedToolResult` mints a fresh `id` per parse, so the
            // stable dedupe key is the backing file (falling back to the
            // filename for inline-only artifacts).
            let key = artifact.hostPath.isEmpty ? "name:\(artifact.filename)" : artifact.hostPath
            guard seen.insert(key).inserted else { return }
            artifacts.append(artifact)
        }
        for turn in turns {
            for artifact in turn.sharedArtifacts {
                add(artifact)
            }
            for callId in turn.toolResults.keys.sorted() {
                // Cheap pre-filter WITHOUT the marker's trailing newline: in
                // a stored `ToolEnvelope` the marker sits inside a JSON
                // string, so its newline is escaped.
                guard let result = turn.toolResults[callId],
                    result.contains("---SHARED_ARTIFACT_START---"),
                    let artifact = SharedArtifact.fromEnrichedToolResult(result)
                else { continue }
                add(artifact)
            }
        }
        return artifacts
    }

    /// Pure harvest step, unit-testable with a synthetic `ChatSessionData`.
    static func outcome(
        from session: ChatSessionData,
        elapsed: TimeInterval
    ) -> AgentDelegationOutcome? {
        let assistantTurns = session.turns.filter { $0.role == .assistant }
        let finalText =
            assistantTurns
            .reversed()
            .lazy
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            // A child that finished through the `complete` loop intercept may
            // carry its entire answer in the tool call's `summary` with no
            // trailing assistant prose — that run SUCCEEDED, so harvest the
            // summary instead of failing "without producing a result".
            ?? completeSummary(from: assistantTurns)
        guard let finalText, !finalText.isEmpty else { return nil }
        let usage = usageAccounting(for: session.turns)
        return AgentDelegationOutcome(
            sessionId: session.id,
            finalText: finalText,
            assistantTurns: assistantTurns.count,
            elapsed: elapsed,
            completionTokens: usage.completionTokens,
            tokensPerSecond: usage.tokensPerSecond,
            transcriptTokenEstimate: usage.transcriptTokenEstimate
        )
    }

    /// The most recent `complete(...)` call's parsed summary in the child
    /// transcript, or nil when the child never called the intercept (or its
    /// arguments were malformed/empty).
    static func completeSummary(from assistantTurns: [ChatTurnData]) -> String? {
        for turn in assistantTurns.reversed() {
            guard let calls = turn.toolCalls else { continue }
            for call in calls.reversed() where call.function.name == "complete" {
                if let summary = CompleteTool.parseSummary(from: call.function.arguments) {
                    return summary
                }
            }
        }
        return nil
    }

    /// Usage rollup from the child's persisted turns. Completion tokens and
    /// throughput are MEASURED (per-turn `generationTokenCount` + generation
    /// wall clock); the transcript size is an ESTIMATE (`TokenEstimator`)
    /// standing in for the ephemeral path's engine-reported worker tokens.
    static func usageAccounting(
        for turns: [ChatTurnData]
    ) -> (completionTokens: Int?, tokensPerSecond: Double?, transcriptTokenEstimate: Int) {
        var completionTokens = 0
        var sawTokenCount = false
        var timedTokens = 0
        var generationSeconds: TimeInterval = 0
        for turn in turns where turn.role == .assistant {
            guard let tokens = turn.generationTokenCount, tokens > 0 else { continue }
            completionTokens += tokens
            sawTokenCount = true
            if let createdAt = turn.createdAt, let completedAt = turn.completedAt {
                let duration = completedAt.timeIntervalSince(createdAt)
                if duration > 0 {
                    timedTokens += tokens
                    generationSeconds += duration
                }
            }
        }
        let tokensPerSecond: Double? =
            generationSeconds > 0 && timedTokens > 0
            ? Double(timedTokens) / generationSeconds
            : nil
        let transcript = turns.reduce(0) { total, turn in
            total + TokenEstimator.estimate(turn.content)
                + (turn.thinking.isEmpty ? 0 : TokenEstimator.estimate(turn.thinking))
        }
        return (sawTokenCount ? completionTokens : nil, tokensPerSecond, transcript)
    }
}
