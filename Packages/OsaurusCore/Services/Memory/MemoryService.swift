//
//  MemoryService.swift
//  osaurus
//
//  v2 write pipeline: deferred, debounced, single-call distillation.
//
//  Public entry points:
//    - bufferTurn(...)           — no LLM; just persists a pending signal and
//                                  re-arms the per-conversation debounce
//    - flushSession(...)         — forces immediate distillation for a session
//                                  (used by chat nav-away and HTTP `flush=true`)
//    - syncNow()                 — distills every pending conversation
//    - recoverOrphanedSignals()  — startup hook; same as syncNow with a guard
//
//  Distillation is one LLM call per session, not per turn. The prompt is
//  schema-constrained: episode digest + entities + identity delta + pinned
//  candidates, all in a single response.
//

import Foundation
import os

public actor MemoryService {
    public static let shared = MemoryService()

    private let db = MemoryDatabase.shared

    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private static func iso8601Now() -> String {
        iso8601Formatter.string(from: Date())
    }

    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var activeConversation: [String: String] = [:]
    private var conversationSessionDates: [String: String] = [:]

    /// Reset on every process launch — see `BufferTurnTelemetry`.
    private var telemetry = BufferTurnTelemetry()

    public func bufferTelemetry() -> BufferTurnTelemetry {
        telemetry
    }

    private init() {}

    // MARK: - Buffer Turn (no LLM)

    /// Buffer a conversation turn for later distillation. This is the hot
    /// path for every chat turn — no LLM call, no extraction, no scoring.
    /// The debounce timer is (re)armed; if no new turn arrives within
    /// `summaryDebounceSeconds`, the session is distilled. Switching to a
    /// different conversation flushes the previous session immediately.
    public func bufferTurn(
        userMessage: String,
        assistantMessage: String?,
        agentId: String,
        conversationId: String,
        sessionDate: String? = nil
    ) async {
        // Telemetry intentionally precedes the early-return guards so
        // "attempts" reflects every caller invocation. The diagnostics
        // panel uses (attempts == 0) to localise "the chat code never
        // even called bufferTurn" vs "called but bailed early".
        telemetry.attempts += 1
        telemetry.lastAttemptAt = Date()

        guard !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            telemetry.earlyReturnsEmptyMessage += 1
            return
        }

        let config = MemoryConfigurationStore.load()
        guard config.enabled else {
            telemetry.earlyReturnsDisabled += 1
            return
        }

        do {
            try db.insertPendingSignal(
                PendingSignal(
                    agentId: agentId,
                    conversationId: conversationId,
                    userMessage: userMessage,
                    assistantMessage: assistantMessage
                )
            )
            telemetry.insertSuccesses += 1
            telemetry.lastSuccessAt = Date()
            telemetry.lastError = nil
        } catch {
            telemetry.insertFailures += 1
            telemetry.lastError = error.localizedDescription
            MemoryLogger.service.error("Failed to buffer turn: \(error)")
            return
        }

        if let sessionDate, !sessionDate.isEmpty {
            conversationSessionDates[conversationId] = sessionDate
        }

        // Session change → flush the previous conversation.
        let previous = activeConversation[agentId]
        activeConversation[agentId] = conversationId
        if let prev = previous, prev != conversationId {
            debounceTasks[prev]?.cancel()
            debounceTasks[prev] = nil
            let prevDate = conversationSessionDates[prev]
            Task { await self.distillSession(agentId: agentId, conversationId: prev, sessionDate: prevDate) }
        }

        guard config.extractionMode == .sessionEnd else { return }

        // Re-arm debounce for this session.
        debounceTasks[conversationId]?.cancel()
        let debounceSeconds = config.summaryDebounceSeconds
        let capturedDate = conversationSessionDates[conversationId]
        debounceTasks[conversationId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(debounceSeconds))
            guard !Task.isCancelled else { return }
            await self?.distillSession(
                agentId: agentId,
                conversationId: conversationId,
                sessionDate: capturedDate
            )
        }
    }

    /// Force immediate distillation for a session. Called from the chat UI
    /// when the user navigates away. Fire-and-forget: the caller doesn't
    /// wait for (or learn) the outcome. For the request/response path
    /// (`POST /memory/ingest`) use `flushSessionAndWait` instead.
    public func flushSession(agentId: String, conversationId: String) {
        debounceTasks[conversationId]?.cancel()
        debounceTasks[conversationId] = Task { [weak self] in
            await self?.distillSession(agentId: agentId, conversationId: conversationId)
        }
    }

    /// Force immediate distillation for a session and await the outcome.
    ///
    /// Used by `POST /memory/ingest` so the HTTP response can report
    /// whether an episode was actually written (issue #1632) instead of
    /// returning a blind `{"status":"ok"}` while the coordinator silently
    /// skipped a heavy, non-resident core model. Forces
    /// `requireResident: false` so the cold load happens on demand
    /// (matching the user-driven "Distill pending" / backfill semantics).
    /// The load still routes through the gated `load:<model>` path, so it
    /// stays GPU-safe.
    @discardableResult
    public func flushSessionAndWait(
        agentId: String,
        conversationId: String,
        sessionDate: String? = nil
    ) async -> DistillOutcome {
        // Cancel any armed debounce so we don't double-distill this
        // session; we drive the distill directly below and await it.
        debounceTasks[conversationId]?.cancel()
        debounceTasks[conversationId] = nil
        return await distillSession(
            agentId: agentId,
            conversationId: conversationId,
            sessionDate: sessionDate,
            requireResident: false
        )
    }

    /// Distill every pending conversation and run identity regeneration if needed.
    ///
    /// `force = false` (the default) means background paths
    /// (`recoverOrphanedSignals` at launch, the per-turn debounced
    /// flow indirectly): skip when the core model would require an
    /// expensive cold load — pending signals stay pending. `force =
    /// true` is the user-driven path (the "Distill pending" button,
    /// the chat-history backfill) where the user has explicitly opted
    /// into the cold load.
    ///
    /// Either way, each `distillSession` still routes through
    /// `DistillationCoordinator`, so the calls inside this loop are
    /// *guaranteed serial across the whole app* and yield to live
    /// chat. Pre-coordinator, three windows going idle simultaneously
    /// could still produce three concurrent reentries here.
    public func syncNow(force: Bool = false) async {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }
        guard await hasCoreModel() else {
            // Promoted from .info to .warning — the diagnostics panel
            // surfaces this elsewhere, but the Console log is the
            // fallback for support. Background consolidation has no
            // per-turn chat model to fall back to, so it stays opt-in
            // via Settings → Core Model.
            MemoryLogger.service.warning(
                "syncNow: no core model configured; memory consolidation skipped (configure one in Settings → Core Model)"
            )
            return
        }
        if !force, !(await canDistillCheaply()) {
            MemoryLogger.service.info(
                "syncNow: deferring — core model not resident or too large to cold-load (use force=true to override)"
            )
            return
        }

        let conversations: [(agentId: String, conversationId: String)]
        do { conversations = try db.pendingConversations() } catch {
            MemoryLogger.service.error("syncNow: failed to load pending conversations: \(error)")
            return
        }

        for conv in conversations {
            // `requireResident: !force` — match the same gate at the
            // coordinator layer so a force-sync still proceeds while a
            // background-sync skips per-conversation if the residency
            // status changes mid-loop (e.g. the model gets evicted by
            // a chat closing its lease while we're partway through).
            await distillSession(
                agentId: conv.agentId,
                conversationId: conv.conversationId,
                requireResident: !force
            )
        }
    }

    /// Startup hook: drain anything that didn't get distilled before the
    /// previous launch was killed. The `canDistillCheaply` guard inside
    /// `syncNow(force: false)` is the same gate that used to live here
    /// — kept the wrapper for callsite clarity at the AppDelegate.
    public func recoverOrphanedSignals() async {
        await syncNow(force: false)
    }

    /// Best-effort flush of every armed debounce task at app quit. Cancels
    /// each pending sleep so distillation runs immediately, then awaits up
    /// to `timeoutSeconds` for them to finish before returning. Callers
    /// (specifically `applicationShouldTerminate`) should invoke this
    /// BEFORE tearing down MLX / NIO / SQLCipher — otherwise the in-flight
    /// distillation calls hit a closed database or a freed model runtime.
    ///
    /// The pre-fix behaviour was: if the user closed the chat window /
    /// quit the app inside the 60s debounce window, the pending signal
    /// stayed in the database forever until the next launch, AND
    /// `recoverOrphanedSignals` self-defers when the core model isn't
    /// resident. This converts that case into "distilled now".
    public func flushAllPending(timeoutSeconds: TimeInterval = 5) async {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return }

        // Snapshot the dictionary so we can safely cancel + iterate even
        // if more debounce tasks land while we're flushing.
        let armed = debounceTasks
        debounceTasks.removeAll(keepingCapacity: false)

        // Conversations the actor may still have buffered but never armed
        // a debounce for (e.g. .manual extractionMode, or an in-flight
        // `bufferTurn` that hasn't reached the debounce-arm step).
        let pendingFromDb: [(agentId: String, conversationId: String)] =
            (try? db.pendingConversations()) ?? []
        let armedConvIds = Set(armed.keys)
        let extras = pendingFromDb.filter { !armedConvIds.contains($0.conversationId) }

        guard !armed.isEmpty || !extras.isEmpty else { return }

        MemoryLogger.service.info(
            "flushAllPending: draining \(armed.count) armed + \(extras.count) extra conversation(s) (timeout=\(timeoutSeconds)s)"
        )

        // Cancel every armed sleep so the per-debounce Task wakes up
        // and exits immediately. We don't run distillation through
        // those cancelled tasks (they'd see Task.isCancelled and
        // return) — we drive performDistillSession directly below.
        for (_, task) in armed { task.cancel() }

        // Build the full drain list. `extras` already have their
        // agent ids; for the armed conversations, look up the agent
        // via the actor's `activeConversation` map first (set by the
        // most recent `bufferTurn`), then fall back to the DB row in
        // case the map is stale.
        let pendingByConvId = Dictionary(
            pendingFromDb.map { ($0.conversationId, $0.agentId) },
            uniquingKeysWith: { first, _ in first }
        )
        let agentByConv: (String) -> String? = { [activeConversation] convId in
            if let agentId = activeConversation.first(where: { $0.value == convId })?.key {
                return agentId
            }
            return pendingByConvId[convId]
        }
        let armedDrain: [(agentId: String, conversationId: String)] = armed.keys.compactMap { convId in
            guard let agentId = agentByConv(convId) else { return nil }
            return (agentId: agentId, conversationId: convId)
        }
        let toDrain = extras + armedDrain

        // Serial drain bounded by a wallclock deadline. Pre-fix this
        // ran every distill in parallel via a `withTaskGroup` — at
        // app quit, exactly when MLX/NIO/SQLCipher are being torn
        // down. Multiple concurrent prefills against unified memory
        // at the worst possible moment was the documented OOM /
        // jetsam-kill class on heavy MLX core models. Sequential
        // execution against a deadline trades "drain everything" for
        // "drain what we safely can"; whatever doesn't fit gets
        // recovered next launch via `recoverOrphanedSignals`.
        //
        // We bypass the DistillationCoordinator on purpose here —
        // shutdown can't afford to wait for chat-idle, and there
        // shouldn't be a live chat at this point anyway because
        // ChatWindowManager.stopAllSessions ran before us in the
        // applicationShouldTerminate sequence.
        let started = Date()
        let deadline = started.addingTimeInterval(timeoutSeconds)
        var drained = 0
        for conv in toDrain {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            // Per-session cap on the *remaining* budget. The coarse
            // between-sessions check above isn't enough: a single
            // `performDistillSession` that stalls in MLX prefill during
            // teardown would otherwise blow the whole quit budget with no
            // way to bail. If a session exceeds the remaining time we
            // abandon it (cooperatively cancelled) and stop draining —
            // whatever's left is recovered next launch via
            // `recoverOrphanedSignals`.
            let finished = await runWithDeadline(seconds: remaining) { [weak self] in
                await self?.performDistillSession(
                    agentId: conv.agentId,
                    conversationId: conv.conversationId
                )
            }
            if finished {
                drained += 1
            } else {
                MemoryLogger.service.info(
                    "flushAllPending: session for conv=\(conv.conversationId, privacy: .public) exceeded remaining budget; abandoning drain"
                )
                break
            }
        }

        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        MemoryLogger.service.info(
            "flushAllPending: drained \(drained)/\(toDrain.count) in \(elapsed)ms"
        )
    }

    /// Foundation/remote: always cheap. Local MLX: cheap iff already
    /// cached or small (<= `coldLoadParamBudgetBillions`). Unknown
    /// param count is treated as large.
    ///
    /// Internal (not private) so `DistillationCoordinator` can use it
    /// as the residency gate before yielding to chat-idle. Both live
    /// under `Services/Memory/` so the coupling is intentional.
    func canDistillCheaply() async -> Bool {
        // Resolve via the router first. The pre-fix code matched the raw
        // `coreModelIdentifier` against `discoverLocalModels()` and returned
        // `true` on a *miss* — so an unroutable core model (deleted MLX
        // model, Foundation on pre-26 macOS, disconnected remote) reported
        // "cheap", the coordinator proceeded, and `generate` threw
        // `modelUnavailable` on every attempt → endless `error` rows
        // (issue #1632 D3). Routing through `resolveStatus()` makes an
        // unroutable / unset / breaker-open model report "not cheap" so the
        // background path skips it (signals stay pending) instead of looping.
        let status = await CoreModelService.shared.resolveStatus()
        switch status {
        case .unset, .unavailable, .breakerOpen:
            return false
        case .available(let modelId, _, let effectiveModel):
            // Only locally-hosted MLX models carry a cold-load cost. A
            // routable model that isn't a discoverable local model
            // (Foundation, remote provider) is cheap — no load required.
            guard
                let local = ModelManager.discoverLocalModels()
                    .first(where: {
                        $0.id.caseInsensitiveCompare(modelId) == .orderedSame
                            || $0.name.caseInsensitiveCompare(modelId) == .orderedSame
                            || $0.id.caseInsensitiveCompare(effectiveModel) == .orderedSame
                            || $0.name.caseInsensitiveCompare(effectiveModel) == .orderedSame
                    })
            else { return true }

            if await ModelRuntime.shared.isResident(name: local.name) { return true }
            if let params = local.parameterCountBillions, params <= Self.coldLoadParamBudgetBillions {
                return true
            }
            return false
        }
    }

    private static let coldLoadParamBudgetBillions: Double = 2.0

    // MARK: - Chat-history Backfill

    /// Walk every session in `chat_history.db`, buffer its turns into
    /// `pending_signals`, then drain everything via `syncNow()` so each
    /// session becomes an episode.
    ///
    /// Idempotent: skips sessions whose `(agent_id, conversation_id)`
    /// already has an active episode, and skips conversations that
    /// already have buffered signals waiting (so re-running after a
    /// partial run doesn't double-buffer).
    ///
    /// Why this exists: prior to v7 of `MemoryDatabase` the
    /// `pending_signals` table had an orphan `signal_type NOT NULL`
    /// column from a pre-shipping schema iteration. Every `bufferTurn`
    /// hit `SQLITE_CONSTRAINT_NOTNULL` (extended 1299) and the silent
    /// `executeUpdate` swallowed the failure, so for affected installs
    /// the entire chat history accumulated in `chat_history.db` without
    /// ever reaching the memory pipeline. This backfill closes the gap.
    ///
    /// - Parameters:
    ///   - distillAfterBuffering: when true (default), runs `syncNow()`
    ///     after all sessions are buffered. Set to false if the caller
    ///     wants to drive distillation explicitly (e.g. via the
    ///     "Distill pending" button) so the user can scrub a giant
    ///     backfill into the foreground or background as they like.
    ///   - progress: callback fired on the MainActor whenever the
    ///     buffering phase advances by one session AND on stage
    ///     transitions. The diagnostics panel uses this to render a
    ///     live progress UI without polling.
    /// - Returns: a final `MemoryBackfillProgress` summarising what got
    ///   buffered. The `stage` will be `.done` on success or
    ///   `.cancelled` when the parent task is cancelled mid-flight.
    @discardableResult
    public func backfillFromChatHistory(
        distillAfterBuffering: Bool = true,
        progress: @escaping @Sendable @MainActor (MemoryBackfillProgress) -> Void
    ) async -> MemoryBackfillProgress {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else {
            let snapshot = MemoryBackfillProgress(stage: .done)
            await MainActor.run { progress(snapshot) }
            return snapshot
        }

        // Gather candidate sessions on the MainActor (ChatSessionStore
        // / ChatHistoryDatabase are MainActor-anchored on entry, but
        // their queue.sync internals are Sendable).
        let sessionMetadata: [ChatSessionData] = await MainActor.run {
            ChatHistoryDatabase.shared.loadAllMetadata()
        }

        // Pre-compute dedupe sets so we don't pay one DB round-trip
        // per session.
        let alreadyDistilled =
            (try? MemoryDatabase.shared.distilledConversationIds()) ?? []
        let alreadyBuffered =
            (try? MemoryDatabase.shared.bufferedConversationIds()) ?? []

        var snapshot = MemoryBackfillProgress(
            stage: .buffering,
            sessionsTotal: sessionMetadata.count,
            sessionsProcessed: 0,
            sessionsSkipped: 0,
            turnsBuffered: 0,
            lastSessionTitle: nil
        )
        let initial = snapshot
        await MainActor.run { progress(initial) }

        for meta in sessionMetadata {
            if Task.isCancelled {
                snapshot.stage = .cancelled
                let final = snapshot
                await MainActor.run { progress(final) }
                return snapshot
            }

            let convId = meta.id.uuidString
            if alreadyDistilled.contains(convId) || alreadyBuffered.contains(convId) {
                snapshot.sessionsSkipped += 1
                snapshot.lastSessionTitle = meta.title
                let snap = snapshot
                await MainActor.run { progress(snap) }
                continue
            }

            // Hydrate turns for this session. `loadSession(id:)` opens
            // the database queue once per call, which is fine — the
            // backfill is a one-shot UX action, not a hot path.
            guard
                let full = await MainActor.run(body: {
                    ChatHistoryDatabase.shared.loadSession(id: meta.id)
                })
            else {
                snapshot.sessionsSkipped += 1
                continue
            }

            let pairs = Self.pairTurnsForBackfill(full.turns)
            guard !pairs.isEmpty else {
                snapshot.sessionsSkipped += 1
                continue
            }

            let agentId = (full.agentId ?? Agent.defaultId).uuidString
            let sessionDate = Self.iso8601Formatter.string(from: full.createdAt)

            var bufferedThisSession = 0
            for pair in pairs {
                do {
                    try MemoryDatabase.shared.insertPendingSignal(
                        PendingSignal(
                            agentId: agentId,
                            conversationId: convId,
                            userMessage: pair.user,
                            assistantMessage: pair.assistant,
                            createdAt: sessionDate
                        )
                    )
                    bufferedThisSession += 1
                } catch {
                    MemoryLogger.service.error(
                        "backfill: insertPendingSignal failed for \(convId): \(error)"
                    )
                }
            }

            // Cache the session date so distillSession's resolved-date
            // logic picks up the original conversation timestamp instead
            // of "now". Matches what bufferTurn does on the live path.
            if bufferedThisSession > 0 {
                conversationSessionDates[convId] = sessionDate
            }

            snapshot.sessionsProcessed += 1
            snapshot.turnsBuffered += bufferedThisSession
            snapshot.lastSessionTitle = meta.title
            let snap = snapshot
            await MainActor.run { progress(snap) }
        }

        guard distillAfterBuffering else {
            snapshot.stage = .done
            let final = snapshot
            await MainActor.run { progress(final) }
            return snapshot
        }

        snapshot.stage = .distilling
        let beforeDistill = snapshot
        await MainActor.run { progress(beforeDistill) }

        // `force: true` because the user explicitly clicked Backfill;
        // they've opted into the cold load if the core model isn't
        // resident. The coordinator's chat-idle wait still applies
        // per-distill, so backfill yields to live chat regardless.
        await syncNow(force: true)

        snapshot.stage = .done
        let final = snapshot
        await MainActor.run { progress(final) }
        return snapshot
    }

    /// Walk a session's turns in seq order and produce `(user, assistant?)`
    /// pairs in the same shape `bufferTurn` would have buffered them
    /// during a live conversation:
    ///
    /// - A `user` turn opens a new pair.
    /// - The next `assistant` turn closes the current pair.
    /// - Non-text turns (tool, system) are skipped — they don't belong
    ///   in the distillation prompt.
    /// - Empty `content` turns are skipped.
    ///
    /// If the session ends with an unmatched `user` turn (assistant
    /// response was never produced), we still emit it with
    /// `assistantMessage = nil` so the user's message participates in
    /// the episode.
    nonisolated static func pairTurnsForBackfill(
        _ turns: [ChatTurnData]
    ) -> [(user: String, assistant: String?)] {
        var pairs: [(user: String, assistant: String?)] = []
        var pendingUser: String?

        for turn in turns {
            let trimmed = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            switch turn.role {
            case .user:
                // Two user turns in a row: emit the previous one with
                // no assistant before opening the new pair.
                if let prev = pendingUser {
                    pairs.append((user: prev, assistant: nil))
                }
                pendingUser = trimmed
            case .assistant:
                if let user = pendingUser {
                    pairs.append((user: user, assistant: trimmed))
                    pendingUser = nil
                }
            // System and tool turns don't carry conversational content.
            case .system, .tool:
                continue
            }
        }

        if let trailing = pendingUser {
            pairs.append((user: trailing, assistant: nil))
        }

        return pairs
    }

    // MARK: - Distillation (one LLM call per session)

    /// Public entry point. Routes through `DistillationCoordinator` so
    /// every distill trigger (per-turn debounce, syncNow, backfill,
    /// recoverOrphanedSignals) shares a single-flight queue and yields
    /// to live chat. The actual work is in `performDistillSession`,
    /// which the quit-time `flushAllPending` drain calls *directly* to
    /// bypass the coordinator's chat-idle wait (shutdown can't block
    /// on an active chat stream).
    ///
    /// `requireResident` controls the coordinator's residency gate:
    ///   * `true` (default) — the per-turn debounced flow + background
    ///     recovery: skip when a heavy MLX core model isn't already
    ///     loaded. Pending signals stay pending; they'll get picked up
    ///     next launch or after the model becomes resident.
    ///   * `false` — user explicitly asked (the "Distill pending"
    ///     button + the chat-history backfill): proceed regardless;
    ///     the user has opted into the cold load.
    @discardableResult
    private func distillSession(
        agentId: String,
        conversationId: String,
        sessionDate: String? = nil,
        requireResident: Bool = true
    ) async -> DistillOutcome {
        // Quick global gate before queuing — signals stale-by-the-time-
        // we-run is not an issue because `performDistillSession`
        // re-reads from `pending_signals` inside the coordinator body.
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return .skipped(reason: "memory_disabled") }

        let outcome = await DistillationCoordinator.shared.runReturning(
            requireResident: requireResident
        ) { [weak self] () -> DistillOutcome in
            guard let self else { return .error("service_released") }
            return await self.performDistillSession(
                agentId: agentId,
                conversationId: conversationId,
                sessionDate: sessionDate
            )
        }
        // `nil` means the coordinator's residency gate short-circuited the
        // run (`requireResident && !canDistillCheaply`); signals stay
        // pending and recover next launch / once the model is resident.
        return outcome ?? .skipped(reason: "not_resident")
    }

    /// The actual distillation body. Holds every cheap pre-LLM gate
    /// (hasCoreModel, signals empty, low novelty) AND the LLM call —
    /// re-loading signals fresh so we don't miss turns that were
    /// buffered while the call was queued behind another distill.
    ///
    /// Called via `DistillationCoordinator` by `distillSession` and
    /// directly (no coordinator) by `flushAllPending` at app quit.
    @discardableResult
    private func performDistillSession(
        agentId: String,
        conversationId: String,
        sessionDate: String? = nil
    ) async -> DistillOutcome {
        let config = MemoryConfigurationStore.load()
        guard config.enabled else { return .skipped(reason: "memory_disabled") }
        guard await hasCoreModel() else {
            // Pre-fix this was an `.info` log, which meant the user
            // had no UI affordance to see why distillation was silently
            // disabled. Now we both warn AND write a `skipped` row to
            // `processing_log` so the diagnostics panel can surface it.
            // Signals stay pending intentionally (no model yet) and this
            // does NOT count toward the dead-letter cap.
            MemoryLogger.service.warning(
                "distill: no core model configured; signals stay pending (configure one in Settings → Core Model)"
            )
            logProcessing(
                agentId: agentId,
                taskType: "distill",
                model: "none",
                status: "skipped",
                details: "core_model_unset"
            )
            return .skipped(reason: "core_model_unset")
        }

        let coreModelId = await coreModelIdentifier()
        let startTime = Date()

        let signals: [PendingSignal]
        do { signals = try db.loadPendingSignals(conversationId: conversationId) } catch {
            MemoryLogger.service.error("distill: failed to load signals for \(conversationId): \(error)")
            return .error(error.localizedDescription)
        }
        guard !signals.isEmpty else { return .noSignals }
        // Snapshot the ids so we only ever mark *these* signals processed —
        // turns buffered while the LLM call is in flight stay pending (D2).
        let signalIds = signals.map(\.id)

        // Cheap pre-LLM gate: combined char count must clear novelty floor.
        let combinedChars = signals.reduce(0) {
            $0 + $1.userMessage.count + ($1.assistantMessage?.count ?? 0)
        }
        guard combinedChars >= MemoryConfiguration.distillNoveltyMinChars else {
            // Terminal + non-retryable: clear exactly these signals
            // (id-scoped) so a low-novelty session can't loop forever.
            try? db.markSignals(ids: signalIds, status: "processed")
            MemoryLogger.service.warning(
                "distill: skipping low-novelty session \(conversationId) (\(combinedChars) chars)"
            )
            logProcessing(
                agentId: agentId,
                taskType: "distill",
                model: coreModelId,
                status: "skipped",
                details: "low_novelty:\(combinedChars)chars"
            )
            debounceTasks[conversationId] = nil
            return .skipped(reason: "low_novelty:\(combinedChars)chars")
        }

        let identity = (try? db.loadIdentity()) ?? Identity()
        let recentEpisodes =
            (try? db.loadEpisodes(agentId: agentId, days: 90, limit: MemoryConfiguration.distillContextEpisodeCount))
            ?? []

        let resolvedDate: String = {
            if let sessionDate, !sessionDate.isEmpty { return sessionDate }
            return Self.iso8601Now()
        }()

        let prompt = buildDistillPrompt(
            signals: signals,
            identity: identity,
            recentEpisodes: recentEpisodes,
            sessionDate: resolvedDate
        )

        do {
            let response = try await CoreModelService.shared.generate(
                prompt: prompt,
                systemPrompt: distillSystemPrompt
            )
            let parsed = parseDistillResponse(response)
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

            guard let episode = parsed.episode else {
                // Terminal: the model ran but produced no usable episode.
                // Mark these signals processed (id-scoped) so an unparseable
                // session is not retried on every launch/ingest forever (D1).
                try? db.markSignals(ids: signalIds, status: "processed")
                MemoryLogger.service.warning("distill: no episode produced for \(conversationId)")
                logProcessing(
                    agentId: agentId,
                    taskType: "distill",
                    model: coreModelId,
                    status: "empty",
                    durationMs: durationMs,
                    details: "no_episode"
                )
                debounceTasks[conversationId] = nil
                return .empty(reason: "no_episode")
            }

            let summaryText = stripPreamble(episode.summary)
            guard !summaryText.isEmpty else {
                try? db.markSignals(ids: signalIds, status: "processed")
                MemoryLogger.service.warning("distill: empty summary for \(conversationId)")
                logProcessing(
                    agentId: agentId,
                    taskType: "distill",
                    model: coreModelId,
                    status: "empty",
                    durationMs: durationMs,
                    details: "empty_summary"
                )
                debounceTasks[conversationId] = nil
                return .empty(reason: "empty_summary")
            }

            let tokenCount = max(1, summaryText.count / MemoryConfiguration.charsPerToken)
            let entitiesCSV = parsed.entities.joined(separator: ", ")
            let topicsCSV = episode.topics.joined(separator: ", ")
            let decisions = episode.decisions.joined(separator: "\n")
            let actionItems = episode.actionItems.joined(separator: "\n")
            let salience = max(0, min(1, episode.salience ?? 0.5))

            let ep = Episode(
                agentId: agentId,
                conversationId: conversationId,
                summary: summaryText,
                topicsCSV: topicsCSV,
                entitiesCSV: entitiesCSV,
                decisions: decisions,
                actionItems: actionItems,
                salience: salience,
                tokenCount: tokenCount,
                model: coreModelId,
                conversationAt: resolvedDate
            )

            let episodeId: Int
            do {
                // Id-scoped marking (D2): only the snapshotted ids are
                // cleared inside the same transaction as the episode insert.
                episodeId = try db.insertEpisodeAndMarkProcessed(ep, signalIds: signalIds)
            } catch {
                MemoryLogger.service.error("distill: failed to insert episode for \(conversationId): \(error)")
                return recordRetryableDistillFailure(
                    message: "episode_insert_failed: \(error.localizedDescription)",
                    agentId: agentId,
                    conversationId: conversationId,
                    coreModelId: coreModelId,
                    signalIds: signalIds,
                    durationMs: durationMs
                )
            }

            // Index the episode for search.
            var stored = ep
            stored.id = episodeId
            await MemorySearchService.shared.indexEpisode(stored)

            // Promote pinned candidates that are explicit, novel, and not already represented.
            let storedPinned = await persistPinnedCandidates(
                parsed.pinnedCandidates,
                agentId: agentId,
                episodeId: episodeId
            )

            // Apply identity delta: the distillation may declare new
            // identity-grade facts. We append them to overrides only when the
            // model marked them as identity-relevant.
            if !parsed.identityFacts.isEmpty {
                applyIdentityDelta(
                    facts: parsed.identityFacts,
                    currentIdentity: identity,
                    model: coreModelId
                )
            }

            logProcessing(
                agentId: agentId,
                taskType: "distill",
                model: coreModelId,
                status: "success",
                inputTokens: prompt.count / MemoryConfiguration.charsPerToken,
                outputTokens: response.count / MemoryConfiguration.charsPerToken,
                durationMs: durationMs
            )
            MemoryLogger.service.info(
                "distill: \(conversationId) → episode #\(episodeId), \(storedPinned) pinned, \(parsed.identityFacts.count) identity facts (\(durationMs)ms)"
            )

            await MemoryContextAssembler.shared.invalidateCache(agentId: agentId)
            debounceTasks[conversationId] = nil
            return .distilled(
                episodeId: episodeId,
                pinned: storedPinned,
                identityFacts: parsed.identityFacts.count
            )
        } catch is CancellationError {
            // Interrupted (app quitting, caller walked away). Not an error
            // and NOT counted toward the dead-letter cap — signals stay
            // pending and recover next launch. Logged as `skipped` so a
            // mid-flight teardown stops masquerading as a hard `error` row.
            MemoryLogger.service.info("distill: cancelled for \(conversationId)")
            logProcessing(
                agentId: agentId,
                taskType: "distill",
                model: coreModelId,
                status: "skipped",
                durationMs: Int(Date().timeIntervalSince(startTime) * 1000),
                details: "cancelled"
            )
            debounceTasks[conversationId] = nil
            return .skipped(reason: "cancelled")
        } catch let coreErr as CoreModelError {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            switch coreErr {
            case .modelUnavailable, .circuitBreakerOpen:
                // Config-level / transient backend state. Stay pending and
                // recover once the model resolves or the breaker closes; do
                // NOT count toward the cap (a misconfig shouldn't permanently
                // lose the user's turns).
                let reason = (coreErr == .circuitBreakerOpen) ? "breaker_open" : "core_model_unavailable"
                MemoryLogger.service.warning("distill: \(reason) for \(conversationId)")
                logProcessing(
                    agentId: agentId,
                    taskType: "distill",
                    model: coreModelId,
                    status: "skipped",
                    durationMs: durationMs,
                    details: reason
                )
                debounceTasks[conversationId] = nil
                return .skipped(reason: reason)
            case .timedOut:
                // A persistently-too-slow session DOES count toward the cap so
                // it eventually dead-letters instead of timing out forever.
                MemoryLogger.service.error("distill: timed out for \(conversationId)")
                return recordRetryableDistillFailure(
                    message: "timed_out",
                    agentId: agentId,
                    conversationId: conversationId,
                    coreModelId: coreModelId,
                    signalIds: signalIds,
                    durationMs: durationMs
                )
            }
        } catch {
            MemoryLogger.service.error("distill: failed for \(conversationId): \(error)")
            return recordRetryableDistillFailure(
                message: error.localizedDescription,
                agentId: agentId,
                conversationId: conversationId,
                coreModelId: coreModelId,
                signalIds: signalIds,
                durationMs: Int(Date().timeIntervalSince(startTime) * 1000)
            )
        }
    }

    /// Record one retryable distillation failure and dead-letter the
    /// session's signals once they exceed `distillMaxAttempts` (D1). Writes
    /// the matching `processing_log` row (`error` or `dead_letter`) and
    /// returns the corresponding `DistillOutcome`.
    private func recordRetryableDistillFailure(
        message: String,
        agentId: String,
        conversationId: String,
        coreModelId: String,
        signalIds: [Int],
        durationMs: Int
    ) -> DistillOutcome {
        let failure =
            (try? db.recordDistillFailure(
                ids: signalIds,
                maxAttempts: MemoryConfiguration.distillMaxAttempts
            )) ?? (attempts: 0, deadLettered: false)
        logProcessing(
            agentId: agentId,
            taskType: "distill",
            model: coreModelId,
            status: failure.deadLettered ? "dead_letter" : "error",
            durationMs: durationMs,
            details: failure.deadLettered
                ? "dead_letter_after_\(failure.attempts)_attempts: \(message)"
                : message
        )
        debounceTasks[conversationId] = nil
        return failure.deadLettered
            ? .deadLettered(attempts: failure.attempts)
            : .error(message)
    }

    // MARK: - Pinned Candidates

    /// Persist pinned candidates that pass the dedup check. Uses Jaccard
    /// against existing pinned facts (cheap, deterministic) — the
    /// consolidator handles deeper merging later.
    private func persistPinnedCandidates(
        _ candidates: [DistillResult.PinnedCandidate],
        agentId: String,
        episodeId: Int
    ) async -> Int {
        guard !candidates.isEmpty else { return 0 }

        let existing = (try? db.loadPinnedFacts(agentId: agentId, limit: 200)) ?? []
        let existingTokens = existing.map { TextSimilarity.tokenize($0.content) }

        var stored = 0
        for candidate in candidates {
            let trimmed = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 5 else { continue }

            let candTokens = TextSimilarity.tokenize(trimmed)
            let isDuplicate = existing.enumerated().contains { (i, _) in
                TextSimilarity.jaccardTokenized(existingTokens[i], candTokens) > 0.6
            }
            if isDuplicate {
                MemoryLogger.service.debug("pinned: skip dup '\(trimmed.prefix(60))'")
                continue
            }

            let salience = max(0, min(1, candidate.salience ?? 0.6))
            let fact = PinnedFact(
                agentId: agentId,
                content: trimmed,
                salience: salience,
                sourceCount: 1,
                sourceEpisodeId: episodeId,
                tagsCSV: candidate.tags.isEmpty ? nil : candidate.tags.joined(separator: ", ")
            )
            do {
                try db.insertPinnedFact(fact)
                await MemorySearchService.shared.indexPinnedFact(fact)
                stored += 1
            } catch {
                MemoryLogger.service.error("pinned: insert failed: \(error)")
            }
        }
        return stored
    }

    // MARK: - Identity Delta

    private func applyIdentityDelta(
        facts: [String],
        currentIdentity: Identity,
        model: String
    ) {
        let existing = Set(currentIdentity.overrides.map { $0.lowercased() })
        var updated = currentIdentity
        var added = 0
        for raw in facts {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !existing.contains(trimmed.lowercased()) else { continue }
            updated.overrides.append(trimmed)
            added += 1
        }
        guard added > 0 else { return }
        updated.model = model
        updated.generatedAt = Self.iso8601Now()
        do { try db.saveIdentity(updated) } catch {
            MemoryLogger.service.error("identity: save failed: \(error)")
        }
        MemoryLogger.service.info("identity: appended \(added) new fact(s)")
    }

    // MARK: - Core Model Identifier

    private func coreModelIdentifier() async -> String {
        await MainActor.run { ChatConfigurationStore.load().coreModelIdentifier ?? "none" }
    }

    private func hasCoreModel() async -> Bool {
        await MainActor.run { ChatConfigurationStore.load().coreModelIdentifier != nil }
    }

    // MARK: - Prompt Building

    private let distillSystemPrompt = """
        You distill a chat session into a structured digest. \
        Respond ONLY with a valid JSON object (no preamble, no code fences, no commentary). \
        The JSON must have these top-level keys: \
        "episode" (object with "summary" string, "topics" string array, "decisions" string array, \
        "action_items" string array, "salience" number 0-1), \
        "entities" (string array of person/project/place/tool names mentioned), \
        "pinned_candidates" (array of {"content": string, "salience": number 0-1, "tags": string array} for \
        facts worth remembering long-term: explicit user identity facts, strong preferences, decisions the \
        user clearly committed to. Be conservative — most sessions yield 0-2 candidates.), \
        "identity_facts" (string array of facts that should appear in the user's identity profile, e.g. \
        "User's name is X" or "User works at Y". Empty when nothing identity-relevant came up.). \
        Salience scoring: 0.9+ = critical identity/decision, 0.6-0.8 = clear preference, \
        0.3-0.5 = casual mention, <0.3 = transient chitchat. \
        Do NOT invent facts. Use only what the conversation actually contains.
        """

    private func buildDistillPrompt(
        signals: [PendingSignal],
        identity: Identity,
        recentEpisodes: [Episode],
        sessionDate: String
    ) -> String {
        var prompt = "Conversation date: \(sessionDate)\n\n"

        if !identity.content.isEmpty {
            prompt += "What we already know about the user:\n\(identity.content)\n\n"
        }

        if !recentEpisodes.isEmpty {
            prompt += "Recent past sessions (for cross-session continuity):\n"
            for ep in recentEpisodes {
                prompt += "- [\(ep.conversationAt.prefix(10))] \(ep.summary.prefix(160))\n"
            }
            prompt += "\n"
        }

        // I4 — input caps. A session is one LLM call, so an unbounded
        // concatenation of every buffered turn (bulk LoCoMo imports, giant
        // pastes) can overflow a small core model's context and get stuck
        // erroring on every retry. Clamp the turn count (keeping the
        // identity-bearing opening head + the most-recent tail) and clamp
        // each individual message, with explicit truncation markers so the
        // model knows the transcript was trimmed.
        let maxTurns = MemoryConfiguration.distillMaxTurns
        let headCount = max(1, maxTurns / 4)
        let included: [PendingSignal]
        let omittedCount: Int
        if signals.count > maxTurns {
            let tailCount = maxTurns - headCount
            included = Array(signals.prefix(headCount)) + Array(signals.suffix(tailCount))
            omittedCount = signals.count - included.count
        } else {
            included = signals
            omittedCount = 0
        }

        prompt += "Conversation turns:\n"
        for (i, signal) in included.enumerated() {
            if omittedCount > 0, i == headCount {
                prompt += "\n[... \(omittedCount) middle turn(s) omitted to fit the core model's context ...]\n"
            }
            prompt += "\nUser: \(Self.clampTurnText(signal.userMessage))"
            if let asst = signal.assistantMessage {
                prompt += "\nAssistant: \(Self.clampTurnText(asst))"
            }
        }

        prompt += "\n\nDistill this session into the JSON digest."
        return prompt
    }

    /// Clamp a single turn's text to `MemoryConfiguration.distillMaxTurnChars`,
    /// appending a marker when truncated so the model doesn't mistake the cut
    /// for the end of the message.
    private static func clampTurnText(_ text: String) -> String {
        let limit = MemoryConfiguration.distillMaxTurnChars
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + " …[truncated \(text.count - limit) chars]"
    }

    // MARK: - Response Parsing

    struct DistillResult {
        struct EpisodeData {
            var summary: String
            var topics: [String]
            var decisions: [String]
            var actionItems: [String]
            var salience: Double?
        }
        struct PinnedCandidate {
            var content: String
            var salience: Double?
            var tags: [String]
        }

        var episode: EpisodeData?
        var entities: [String] = []
        var pinnedCandidates: [PinnedCandidate] = []
        var identityFacts: [String] = []
    }

    nonisolated func extractJSON(from response: String) -> Data? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = trimmed.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            return data
        }

        let fencePattern = #"```(?:json)?\s*\n?([\s\S]*?)```"#
        if let regex = try? NSRegularExpression(pattern: fencePattern),
            let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            let contentRange = Range(match.range(at: 1), in: trimmed)
        {
            let jsonStr = String(trimmed[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = jsonStr.data(using: .utf8),
                (try? JSONSerialization.jsonObject(with: data)) != nil
            {
                return data
            }
        }

        if let openIdx = trimmed.firstIndex(of: "{"),
            let closeIdx = trimmed.lastIndex(of: "}"), closeIdx > openIdx
        {
            let jsonStr = String(trimmed[openIdx ... closeIdx])
            if let data = jsonStr.data(using: .utf8),
                (try? JSONSerialization.jsonObject(with: data)) != nil
            {
                return data
            }
        }

        return nil
    }

    nonisolated func parseDistillResponse(_ response: String) -> DistillResult {
        guard let data = extractJSON(from: response),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            MemoryLogger.service.error(
                "distill parse: no JSON in response: \(response.prefix(200))"
            )
            return DistillResult()
        }

        var result = DistillResult()

        if let epDict = dict["episode"] as? [String: Any] {
            let summary = (epDict["summary"] as? String) ?? ""
            let topics = (epDict["topics"] as? [String]) ?? []
            let decisions = (epDict["decisions"] as? [String]) ?? []
            let actions = (epDict["action_items"] as? [String]) ?? []
            let salience: Double? =
                (epDict["salience"] as? Double)
                ?? (epDict["salience"] as? String).flatMap(Double.init)
            if !summary.isEmpty {
                result.episode = DistillResult.EpisodeData(
                    summary: summary,
                    topics: topics,
                    decisions: decisions,
                    actionItems: actions,
                    salience: salience
                )
            }
        }

        if let entities = dict["entities"] as? [String] {
            result.entities = entities.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        if let pinned = dict["pinned_candidates"] as? [[String: Any]] {
            result.pinnedCandidates = pinned.compactMap { obj in
                guard let content = obj["content"] as? String, !content.isEmpty else { return nil }
                let salience: Double? =
                    (obj["salience"] as? Double)
                    ?? (obj["salience"] as? String).flatMap(Double.init)
                let tags: [String]
                if let arr = obj["tags"] as? [String] {
                    tags = arr
                } else if let single = obj["tags"] as? String {
                    tags = [single]
                } else {
                    tags = []
                }
                return DistillResult.PinnedCandidate(
                    content: content,
                    salience: salience,
                    tags: tags
                )
            }
        }

        if let facts = dict["identity_facts"] as? [String] {
            result.identityFacts = facts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        return result
    }

    nonisolated func stripPreamble(_ response: String) -> String {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)

        let preamblePatterns = [
            #"^(?:certainly|sure|of course|here(?:'s| is| are))[!.,:]?\s*"#,
            #"^here is (?:a |the )?(?:profile|description|summary)[^:]*:\s*"#,
        ]
        for pattern in preamblePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.firstMatch(in: text, range: range) {
                    let matchEnd = Range(match.range, in: text)!.upperBound
                    text = String(text[matchEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return text
    }

    // MARK: - Processing Log Helper

    private func logProcessing(
        agentId: String,
        taskType: String,
        model: String,
        status: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        durationMs: Int = 0,
        details: String? = nil
    ) {
        do {
            try db.insertProcessingLog(
                agentId: agentId,
                taskType: taskType,
                model: model,
                status: status,
                details: details,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                durationMs: durationMs
            )
        } catch {
            MemoryLogger.service.warning("Failed to write processing log: \(error)")
        }
    }
}
