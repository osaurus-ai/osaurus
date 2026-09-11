//
//  SpawnWaveGate.swift
//  OsaurusCore
//
//  N `spawn_agent` / `spawn_model` calls emitted in ONE model message are one
//  fan-out wave: the same thing `spawn_batch(jobs)` spells out as a job list.
//  This gate makes the implicit shape behave like the explicit one at the two
//  places where per-call execution would otherwise diverge:
//
//  - one approval card for the whole wave instead of N identical cards, and
//  - one local/remote fan-out limit check across the siblings, rejecting the
//    extras in model order with a typed, retryable result.
//
//  Everything else stays per call: each sibling keeps its own live feed row,
//  Stop control, admission, residency handoff, and result envelope, so the
//  model receives exactly one digest per call it made.
//
//  Lifecycle: `AgentToolLoop.runBatchInParallel` binds a `SpawnWaveContext`
//  task-local naming the sibling call ids, and closes the wave when the batch
//  returns. Each spawn tool `settle`s its call id in a `defer`, so a sibling
//  that fails argument validation (or is denied elsewhere) never leaves the
//  rendezvous waiting on it. The permission gate `join`s and suspends until
//  every expected id has joined or settled; a safety deadline then decides
//  for whoever arrived, and any latecomer falls back to its own card.
//

import Foundation

/// Bound by `AgentToolLoop.runBatchInParallel` for a parallel wave that
/// carries at least two foreground `spawn_agent` / `spawn_model` calls.
public struct SpawnWaveContext: Sendable, Equatable {
    public let waveId: UUID
    /// Sibling call ids in model order. Only these ids may join the wave.
    public let expectedCallIds: [String]

    public init(waveId: UUID = UUID(), expectedCallIds: [String]) {
        self.waveId = waveId
        self.expectedCallIds = expectedCallIds
    }

    static let waveToolNames: Set<String> = [
        SubagentCapabilityRegistry.spawnAgentToolName,
        SubagentCapabilityRegistry.spawnModelToolName,
    ]

    /// A wave exists when two or more calls in the batch are foreground
    /// spawn calls. `background: true` calls return immediately and prompt
    /// through their own dispatch path, so they are not members.
    static func make(
        for calls: [(invocation: ServiceToolInvocation, callId: String)]
    ) -> SpawnWaveContext? {
        let members = calls.filter { isForegroundSpawnCall($0.invocation) }.map(\.callId)
        guard members.count >= 2 else { return nil }
        return SpawnWaveContext(expectedCallIds: members)
    }

    static func isForegroundSpawnCall(_ invocation: ServiceToolInvocation) -> Bool {
        guard waveToolNames.contains(invocation.toolName) else { return false }
        guard let data = invocation.jsonArguments.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return true }
        return ArgumentCoercion.bool(object["background"]) != true
    }
}

extension ChatExecutionContext {
    /// The sibling spawn wave the current tool call belongs to, if any.
    @TaskLocal public static var spawnWave: SpawnWaveContext?
}

actor SpawnWaveGate {
    static let shared = SpawnWaveGate()

    /// How long the first joiner waits for its siblings before the gate
    /// decides for whoever has arrived. Siblings normally join within
    /// milliseconds of each other (model resolution is the only work ahead of
    /// the permission step); the deadline exists so an unexpected stall in
    /// one sibling can never hold the others' approval hostage.
    static let rendezvousDeadline: Duration = .seconds(10)

    struct Member: Sendable {
        let callId: String
        let toolName: String
        let scope: SubagentScope
        /// Per-call approval arguments (the same JSON the single card shows).
        let argumentsJSON: String
        let isLocal: Bool
    }

    /// Verdicts a completed wave hands to its members, keyed by call id.
    struct Outcome: Sendable, Equatable {
        let verdicts: [String: SubagentDecision]
    }

    private struct Wave {
        let context: SpawnWaveContext
        var joined: [Member] = []
        var settled: Set<String> = []
        var waiters: [String: CheckedContinuation<SubagentDecision?, Never>] = [:]
        var limits: SpawnFanOutLimits?
        var deadlineTask: Task<Void, Never>?
        var decisionTask: Task<Void, Never>?
        var decided = false

        var expected: Set<String> { Set(context.expectedCallIds) }

        var isReady: Bool {
            let accounted = Set(joined.map(\.callId)).union(settled.intersection(expected))
            return accounted.isSuperset(of: expected)
        }
    }

    private var waves: [UUID: Wave] = [:]

    /// Test seam: replaces the wave's single approval prompt. Bound by the
    /// test around the batch; the decision task inherits it from the joiner
    /// whose arrival completed the rendezvous.
    @TaskLocal
    static var authorizeOverrideForTests:
        (@Sendable (_ members: [Member], _ leader: Member) async -> SubagentDecision)?

    // MARK: - Lifecycle

    /// The batch executor opens the wave before any sibling runs, so a
    /// sibling that settles before another joins is remembered, and a settle
    /// that lands after `close` is a no-op instead of a leaked entry.
    func open(_ context: SpawnWaveContext) {
        guard waves[context.waveId] == nil else { return }
        waves[context.waveId] = Wave(context: context)
    }

    /// The batch that owned this wave has returned: nothing can join or
    /// settle any more. Release every handle.
    func close(waveId: UUID) {
        guard var wave = waves.removeValue(forKey: waveId) else { return }
        wave.deadlineTask?.cancel()
        wave.decisionTask?.cancel()
        for (_, continuation) in wave.waiters {
            continuation.resume(returning: .userDenied("Spawn permission was cancelled."))
        }
        wave.waiters.removeAll()
    }

    /// Called from a spawn tool's `defer`: the current call id will not (or no
    /// longer) take part in the rendezvous. Reads the task-locals bound by the
    /// batch executor; a call outside any wave is a no-op.
    nonisolated static func settleCurrentCall() {
        guard let wave = ChatExecutionContext.spawnWave,
            let callId = ChatExecutionContext.currentToolCallId
        else { return }
        Task { await SpawnWaveGate.shared.settle(waveId: wave.waveId, callId: callId) }
    }

    // MARK: - Membership

    /// Join the wave and suspend until it decides. Returns nil when this call
    /// is not a member (or arrived after the wave already decided or closed),
    /// in which case the caller runs its own per-call permission path.
    func join(
        _ member: Member,
        wave context: SpawnWaveContext,
        limits: SpawnFanOutLimits
    ) async -> SubagentDecision? {
        guard context.expectedCallIds.contains(member.callId),
            var wave = waves[context.waveId],
            !wave.decided,
            !wave.joined.contains(where: { $0.callId == member.callId })
        else { return nil }
        wave.joined.append(member)
        if wave.limits == nil { wave.limits = limits }
        waves[context.waveId] = wave

        let waveId = context.waveId
        let callId = member.callId
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SubagentDecision?, Never>) in
                guard var current = waves[waveId], !current.decided else {
                    // Decided between the guard above and this suspension
                    // (cannot happen on the actor, but never strand a waiter).
                    continuation.resume(returning: nil)
                    return
                }
                current.waiters[callId] = continuation
                waves[waveId] = current
                evaluateReadiness(waveId)
            }
        } onCancel: {
            Task { await self.cancelWaiter(waveId: waveId, callId: callId) }
        }
    }

    /// This call id will not (or no longer) take part in the rendezvous, so a
    /// sibling that never reaches the permission step (argument failure,
    /// unknown target, recursion guard) still lets the others proceed.
    func settle(waveId: UUID, callId: String) {
        guard var wave = waves[waveId] else { return }
        wave.settled.insert(callId)
        waves[waveId] = wave
        evaluateReadiness(waveId)
    }

    // MARK: - Test seams

    var openWaveCountForTesting: Int { waves.count }

    // MARK: - Decision

    private func evaluateReadiness(_ waveId: UUID) {
        guard var wave = waves[waveId], !wave.decided else { return }
        if wave.isReady {
            if !wave.joined.isEmpty {
                waves[waveId] = wave
                decide(waveId)
            }
            return
        }
        if wave.deadlineTask == nil, !wave.joined.isEmpty {
            wave.deadlineTask = Task { [weak self] in
                try? await Task.sleep(for: Self.rendezvousDeadline)
                guard !Task.isCancelled else { return }
                await self?.deadlineFired(waveId)
            }
            waves[waveId] = wave
        }
    }

    private func deadlineFired(_ waveId: UUID) {
        guard let wave = waves[waveId], !wave.decided, !wave.joined.isEmpty else { return }
        decide(waveId)
    }

    private func decide(_ waveId: UUID) {
        guard var wave = waves[waveId], !wave.decided else { return }
        wave.decided = true
        wave.deadlineTask?.cancel()
        wave.deadlineTask = nil
        let order = wave.context.expectedCallIds
        let members = wave.joined.sorted {
            (order.firstIndex(of: $0.callId) ?? .max) < (order.firstIndex(of: $1.callId) ?? .max)
        }
        let limits = wave.limits ?? SpawnFanOutLimits(local: 1, remote: 1)
        // The decision runs in its own task so a cancelled sibling cannot
        // take the shared prompt down with it. When every member is gone the
        // task is cancelled explicitly (see `cancelWaiter`).
        wave.decisionTask = Task { [weak self] in
            let decision = await Self.authorizeWave(members)
            await self?.complete(waveId: waveId, members: members, limits: limits, decision: decision)
        }
        waves[waveId] = wave
    }

    private func complete(
        waveId: UUID,
        members: [Member],
        limits: SpawnFanOutLimits,
        decision: SubagentDecision
    ) {
        guard var wave = waves[waveId] else { return }
        let outcome = Self.outcome(for: members, limits: limits, decision: decision)
        for (callId, continuation) in wave.waiters {
            continuation.resume(returning: outcome.verdicts[callId] ?? decision)
        }
        wave.waiters.removeAll()
        wave.decisionTask = nil
        waves[waveId] = wave
    }

    private func cancelWaiter(waveId: UUID, callId: String) {
        guard var wave = waves[waveId] else { return }
        if let continuation = wave.waiters.removeValue(forKey: callId) {
            continuation.resume(returning: .userDenied("Spawn permission was cancelled."))
        }
        // Count the cancelled sibling as accounted for so the survivors do
        // not wait out the deadline on its behalf, and drop it from the
        // members list so a card decided later does not name it.
        wave.settled.insert(callId)
        if !wave.decided {
            wave.joined.removeAll { $0.callId == callId }
        }
        if wave.waiters.isEmpty, let decisionTask = wave.decisionTask {
            // Nobody is left to receive the shared decision: dismiss the card.
            decisionTask.cancel()
            wave.decisionTask = nil
        }
        waves[waveId] = wave
        evaluateReadiness(waveId)
    }

    // MARK: - Pure policy

    /// Per-member verdicts for one wave decision. An approved wave still
    /// enforces the launcher's local and remote fan-out limits: members are
    /// admitted in model order and the extras receive a retryable
    /// `unavailable` verdict naming the limit that applied.
    static func outcome(
        for members: [Member],
        limits: SpawnFanOutLimits,
        decision: SubagentDecision
    ) -> Outcome {
        guard case .allow = decision else {
            return Outcome(verdicts: Dictionary(uniqueKeysWithValues: members.map { ($0.callId, decision) }))
        }
        let localRequested = members.filter(\.isLocal).count
        let remoteRequested = members.count - localRequested
        var localAdmitted = 0
        var remoteAdmitted = 0
        var verdicts: [String: SubagentDecision] = [:]
        for member in members {
            if member.isLocal {
                if localAdmitted < limits.local {
                    localAdmitted += 1
                    verdicts[member.callId] = .allow
                } else {
                    verdicts[member.callId] = .unavailable(
                        SpawnBatchTool.fanOutLimitMessage(
                            requested: localRequested,
                            limit: limits.local,
                            kind: "local"
                        )
                    )
                }
            } else {
                if remoteAdmitted < limits.remote {
                    remoteAdmitted += 1
                    verdicts[member.callId] = .allow
                } else {
                    verdicts[member.callId] = .unavailable(
                        SpawnBatchTool.fanOutLimitMessage(
                            requested: remoteRequested,
                            limit: limits.remote,
                            kind: "remote"
                        )
                    )
                }
            }
        }
        return Outcome(verdicts: verdicts)
    }

    /// The wave's one approval. Reads the launcher's policy fresh (a sibling
    /// card in an earlier wave may have persisted Always Allow) and presents
    /// one card listing every member.
    private static func authorizeWave(_ members: [Member]) async -> SubagentDecision {
        guard let leader = members.first else { return .allow }
        if let override = authorizeOverrideForTests {
            return await override(members, leader)
        }
        let policy = await SpawnPermissionGate.effectivePolicy(for: leader.scope)
        return await SpawnPermissionGate.authorize(
            scope: leader.scope,
            policy: policy,
            toolName: cardToolName(for: members),
            description: cardDescription(count: members.count),
            argumentsJSON: cardArgumentsJSON(for: members)
        )
    }

    static func cardToolName(for members: [Member]) -> String {
        let names = Set(members.map(\.toolName))
        if names.count == 1, let only = names.first { return only }
        return SubagentCapabilityRegistry.spawnAgentToolName
            + " / " + SubagentCapabilityRegistry.spawnModelToolName
    }

    static func cardDescription(count: Int) -> String {
        "Allow this agent to spawn \(count) bounded subagents in parallel?"
    }

    /// One JSON document listing each sibling's approval arguments in model
    /// order, so the card shows exactly what N single cards would have.
    static func cardArgumentsJSON(for members: [Member]) -> String {
        let entries: [[String: Any]] = members.map { member in
            var entry: [String: Any] = ["tool": member.toolName]
            if let data = member.argumentsJSON.data(using: .utf8),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            {
                for (key, value) in object { entry[key] = value }
            } else {
                entry["arguments"] = member.argumentsJSON
            }
            return entry
        }
        let payload: [String: Any] = [
            "parallel_subagents": entries.count,
            "subagents": entries,
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
