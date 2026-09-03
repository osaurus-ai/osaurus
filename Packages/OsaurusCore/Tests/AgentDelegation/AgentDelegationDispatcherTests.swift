//
//  AgentDelegationDispatcherTests.swift
//  OsaurusCoreTests — Agent delegation
//
//  Model-free guardrails for TRUE agent delegation: the dispatcher's
//  request/harvest contract, the `.delegation` session source, the
//  spawn-tool strip inside a delegated child, the delegation gating on
//  `TextSubagentKind` (production agent targets delegate; the eval seam
//  and bare-model spawns keep the in-memory runner), and the feed's
//  notch-mirror suppression + child-session link.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentDelegationDispatcherTests {

    // MARK: - Dispatcher: title + harvest

    @Test func sessionTitleUsesFirstLineWithPrefixAndCap() {
        #expect(
            AgentDelegationDispatcher.sessionTitle(for: "Summarize the Q3 report")
                == "Delegated: Summarize the Q3 report"
        )
        // Only the first line rides into the title.
        #expect(
            AgentDelegationDispatcher.sessionTitle(for: "Fix the bug\nwith full detail below")
                == "Delegated: Fix the bug"
        )
        // Long first lines are capped with an ellipsis.
        let long = String(repeating: "a", count: 100)
        let title = AgentDelegationDispatcher.sessionTitle(for: long)
        #expect(title.hasPrefix("Delegated: "))
        #expect(title.hasSuffix("…"))
        #expect(title.count < long.count)
        // Empty input still yields a usable title.
        #expect(AgentDelegationDispatcher.sessionTitle(for: "   ") == "Delegated: task")
    }

    @Test func delegatedPromptAppendsTheDeliveryContract() {
        let input = "Build a Three.js endless runner game."
        let prompt = AgentDelegationDispatcher.delegatedPrompt(input: input)
        // The task leads; the contract rides after it.
        #expect(prompt.hasPrefix(input))
        #expect(prompt.contains("[Delegated task]"))
        // The child must learn that only its FINAL message returns (so it
        // never ends the run on intermediate commentary) and that files go
        // through share_artifact instead of being pasted into the size-capped
        // digest.
        #expect(prompt.contains("ONLY your final message"))
        #expect(prompt.contains("`share_artifact`"))
        #expect(prompt.contains("artifact card"))
        #expect(prompt.contains("do NOT paste their content again"))
        // Degrades gracefully for children without the tool.
        #expect(prompt.contains("Only when `share_artifact` is unavailable"))

        // The dispatcher must actually dispatch the contract-carrying prompt
        // (while the session title stays derived from the raw input).
        let source = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // AgentDelegation/
                .deletingLastPathComponent()  // Tests/
                .deletingLastPathComponent()  // OsaurusCore/
                .appendingPathComponent(
                    "Services/AgentDelegation/AgentDelegationDispatcher.swift"),
            encoding: .utf8
        )
        #expect(source?.contains("prompt: delegatedPrompt(input: input)") == true)
        #expect(source?.contains("title: sessionTitle(for: input)") == true)
    }

    @Test func outcomeHarvestsFinalNonEmptyAssistantTurn() {
        let session = ChatSessionData(
            id: UUID(),
            turns: [
                ChatTurnData(role: .user, content: "task"),
                ChatTurnData(role: .assistant, content: "intermediate step"),
                ChatTurnData(role: .tool, content: "{\"ok\":true}"),
                ChatTurnData(role: .assistant, content: "  Final answer.  "),
                // A trailing empty assistant turn (cancel artifact) must not
                // shadow the real final answer.
                ChatTurnData(role: .assistant, content: "   "),
            ],
            source: .delegation
        )
        let outcome = AgentDelegationDispatcher.outcome(from: session, elapsed: 1.5)
        #expect(outcome?.finalText == "Final answer.")
        #expect(outcome?.assistantTurns == 3)
        #expect(outcome?.sessionId == session.id)
    }

    @Test func outcomeIsNilWithoutAnAssistantAnswer() {
        let empty = ChatSessionData(
            turns: [
                ChatTurnData(role: .user, content: "task"),
                ChatTurnData(role: .assistant, content: "   "),
            ],
            source: .delegation
        )
        #expect(AgentDelegationDispatcher.outcome(from: empty, elapsed: 0) == nil)
        #expect(
            AgentDelegationDispatcher.outcome(
                from: ChatSessionData(turns: [], source: .delegation),
                elapsed: 0
            ) == nil
        )
    }

    /// A child that ends through the `complete` loop intercept may carry its
    /// whole answer in the tool call's `summary` and no trailing assistant
    /// prose — that run SUCCEEDED and must harvest the summary, not fail
    /// "without producing a result". Visible assistant text still wins when
    /// both exist.
    @Test func outcomeFallsBackToTheCompleteSummary() {
        let summary = "Compared both options and verified the totals against the CSV."
        let completeCall = ToolCall(
            id: "call-1",
            type: "function",
            function: ToolCallFunction(
                name: "complete",
                arguments: "{\"summary\":\"\(summary)\"}"
            )
        )
        let session = ChatSessionData(
            id: UUID(),
            turns: [
                ChatTurnData(role: .user, content: "task"),
                ChatTurnData(role: .assistant, content: "", toolCalls: [completeCall]),
                ChatTurnData(role: .tool, content: "{\"ok\":true}", toolCallId: "call-1"),
            ],
            source: .delegation
        )
        let outcome = AgentDelegationDispatcher.outcome(from: session, elapsed: 1)
        #expect(outcome?.finalText == summary)

        // Precedence: real assistant prose shadows the intercept summary.
        var withProse = session
        withProse.turns.append(ChatTurnData(role: .assistant, content: "Final prose."))
        #expect(
            AgentDelegationDispatcher.outcome(from: withProse, elapsed: 1)?.finalText
                == "Final prose."
        )

        // Malformed/empty summaries don't rescue an answerless transcript.
        let malformed = ChatSessionData(
            turns: [
                ChatTurnData(role: .user, content: "task"),
                ChatTurnData(
                    role: .assistant,
                    content: "",
                    toolCalls: [
                        ToolCall(
                            id: "call-2",
                            type: "function",
                            function: ToolCallFunction(name: "complete", arguments: "{\"summary\":\"  \"}")
                        )
                    ]
                ),
            ],
            source: .delegation
        )
        #expect(AgentDelegationDispatcher.outcome(from: malformed, elapsed: 0) == nil)
    }

    /// Usage rollup: completion tokens and throughput are MEASURED from the
    /// child's per-turn counts + generation wall clock; the transcript size
    /// is an estimate. Missing counts surface as nil, never as zeros.
    @Test func usageAccountingAggregatesMeasuredTokens() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let turns = [
            ChatTurnData(role: .user, content: "please research this topic thoroughly"),
            ChatTurnData(
                role: .assistant,
                content: "step one",
                createdAt: t0,
                completedAt: t0.addingTimeInterval(2),
                generationTokenCount: 100
            ),
            ChatTurnData(role: .tool, content: "{\"ok\":true,\"result\":\"data\"}"),
            ChatTurnData(
                role: .assistant,
                content: "final",
                createdAt: t0.addingTimeInterval(3),
                completedAt: t0.addingTimeInterval(4),
                generationTokenCount: 50
            ),
        ]
        let usage = AgentDelegationDispatcher.usageAccounting(for: turns)
        #expect(usage.completionTokens == 150)
        let tps = try #require(usage.tokensPerSecond)
        #expect(abs(tps - 50.0) < 0.001, "150 tokens over 3 timed seconds")
        #expect(usage.transcriptTokenEstimate > 0)

        // No recorded counts → nil, not zero (a missing measurement must be
        // visible, per the runtime proof rules).
        let unmeasured = AgentDelegationDispatcher.usageAccounting(for: [
            ChatTurnData(role: .user, content: "task"),
            ChatTurnData(role: .assistant, content: "answer"),
        ])
        #expect(unmeasured.completionTokens == nil)
        #expect(unmeasured.tokensPerSecond == nil)
        #expect(unmeasured.transcriptTokenEstimate > 0)

        // Tokens without timing still sum, but never fabricate a tok/s.
        let untimed = AgentDelegationDispatcher.usageAccounting(for: [
            ChatTurnData(role: .assistant, content: "answer", generationTokenCount: 42)
        ])
        #expect(untimed.completionTokens == 42)
        #expect(untimed.tokensPerSecond == nil)
    }

    /// Queue grace: proportional to the run budget, floored at 60s so a tiny
    /// budget still tolerates a brief burst of concurrent tasks.
    @Test func queueGraceFloorsAt60AndTracksTheRunBudget() {
        #expect(AgentDelegationDispatcher.queueGraceSeconds(runBudget: 1) == 60)
        #expect(AgentDelegationDispatcher.queueGraceSeconds(runBudget: 59) == 60)
        #expect(AgentDelegationDispatcher.queueGraceSeconds(runBudget: 60) == 60)
        #expect(AgentDelegationDispatcher.queueGraceSeconds(runBudget: 600) == 600)
    }

    // MARK: - Session source contract

    @Test func delegationSourceContract() {
        // Persisted raw value is stable (rows survive schema evolution).
        #expect(SessionSource.delegation.rawValue == "delegation")
        // Chat-owned inference provenance: the parent's residency-handoff
        // restore must be able to reclaim the helper's model afterwards.
        #expect(SessionSource.delegation.inferenceSource == .chatUI)
        // Sidebar/notch decoration.
        #expect(SessionSource.delegation.originLabel() == "delegated")
        #expect(SessionSource.delegation.shortLabel == "Delegated")
        #expect(!SessionSource.delegation.iconName.isEmpty)
    }

    @Test func dispatchRequestDerivesDelegationFlagFromSource() {
        let delegated = DispatchRequest(
            prompt: "task",
            agentId: UUID(),
            source: .delegation
        )
        #expect(delegated.isDelegatedRun)
        // A fresh session per call: delegation never sets a grouping key.
        #expect(delegated.externalSessionKey == nil)

        let plain = DispatchRequest(prompt: "task", agentId: UUID(), source: .chat)
        #expect(!plain.isDelegatedRun)
        let scheduled = DispatchRequest(prompt: "task", agentId: UUID(), source: .schedule)
        #expect(!scheduled.isDelegatedRun)
    }

    /// The cross-window "one local generation at a time" send refusal must
    /// not apply to delegated child sessions: their orchestrating parent is
    /// itself a chat run whose `isStreaming` stays true through the spawn
    /// tool call that awaits this child, so the guard would silently no-op
    /// every delegated send (the child task then idles until its wall-clock
    /// deadline cancels it). Every other source keeps the refusal.
    @Test func delegatedSessionsBypassTheLocalBusySendRefusal() async {
        await MainActor.run {
            #expect(
                ChatSession.refusesLocalBusySend(
                    source: .delegation,
                    localModelBusyInOtherWindow: true
                ) == false
            )
            for source in SessionSource.allCases where source != .delegation {
                #expect(
                    ChatSession.refusesLocalBusySend(
                        source: source,
                        localModelBusyInOtherWindow: true
                    ),
                    "\(source) must keep the busy refusal"
                )
                #expect(
                    ChatSession.refusesLocalBusySend(
                        source: source,
                        localModelBusyInOtherWindow: false
                    ) == false
                )
            }
        }
    }

    // MARK: - Delegation gating on TextSubagentKind

    @Test func agentTargetsDelegateOnlyWithoutTheEvalSeam() {
        // Production agent target → true delegation (and no duplicate notch
        // mirror: the dispatched run registers its own background task).
        let production = TextSubagentKind(agentID: UUID(), input: "x")
        #expect(production.isDelegatedAgentTarget)
        #expect(production.suppressNotchMirror)

        // The eval seam forces the deterministic in-memory runner.
        let eval = TextSubagentKind(
            agentID: UUID(),
            input: "x",
            modelOverride: "eval/forced-model"
        )
        #expect(!eval.isDelegatedAgentTarget)
        #expect(!eval.suppressNotchMirror)

        // Bare-model spawns keep the ephemeral flow unchanged.
        let model = TextSubagentKind(model: "some-model", input: "x")
        #expect(!model.isDelegatedAgentTarget)
        #expect(!model.suppressNotchMirror)
    }

    // MARK: - Feed: mirror suppression + child session link

    @Test func feedCarriesSuppressionFlagAndDelegatedSessionId() {
        let plain = SubagentFeed(toolCallId: "t1", kindId: "spawn", title: "spawn → Helper")
        #expect(!plain.suppressNotchMirror)

        let suppressed = SubagentFeed(
            toolCallId: "t2",
            kindId: "spawn",
            title: "spawn → Helper",
            suppressNotchMirror: true
        )
        #expect(suppressed.suppressNotchMirror)

        // The delegated child's session id lands on the feed (thread-safe
        // one-shot) so the in-chat card can link to the chat, and setting it
        // republishes the event snapshot so bound rows refresh.
        #expect(suppressed.delegatedSessionId == nil)
        let sessionId = UUID().uuidString
        let republished = ProbeBox()
        let cancellable = suppressed.eventsPublisher.sink { _ in
            republished.increment()
        }
        let before = republished.count
        suppressed.setDelegatedSessionId(sessionId)
        #expect(suppressed.delegatedSessionId == sessionId)
        #expect(republished.count > before)
        cancellable.cancel()
    }

    // MARK: - Spawn-tool strip in a delegated child

    /// A `.delegation`-sourced session IS a spawned child: even when the
    /// (target) agent's own configuration would expose spawn tools in its
    /// direct chat, the composed schema for a delegated run must not carry
    /// any of them — that is the structural recursion guard.
    @Test @MainActor func delegatedSessionsStripSpawnToolsFromTheSchema() async throws {
        let lease = await acquireSubagentStoreSandbox("delegation-spawn-strip")
        defer { lease.release() }
        // Give the Default agent a non-empty spawn pool so `spawn_agent`
        // resolves into its direct-chat schema — the baseline the strip is
        // measured against.
        SubagentConfigurationStore.save(
            SubagentConfiguration(
                spawnableAgentIDs: [UUID()],
                spawnableModelNames: ["some-model"]
            )
        )

        let spawnNames = Set(SubagentCapabilityRegistry.spawn.toolNames)

        let direct = await ChatExecutionContext.$currentSessionSource.withValue(.chat) {
            SystemPromptComposer.resolveTools(
                agentId: Agent.defaultId,
                executionMode: .none
            )
        }
        let directNames = Set(direct.map { $0.function.name })
        #expect(
            !directNames.isDisjoint(with: spawnNames),
            "baseline: a non-empty spawn pool must expose spawn tools in direct chat"
        )

        let delegated = await ChatExecutionContext.$currentSessionSource.withValue(.delegation) {
            SystemPromptComposer.resolveTools(
                agentId: Agent.defaultId,
                executionMode: .none
            )
        }
        let delegatedNames = Set(delegated.map { $0.function.name })
        #expect(
            delegatedNames.isDisjoint(with: spawnNames),
            "a delegated child must never carry spawn tools: \(delegatedNames.intersection(spawnNames))"
        )

        // `clarify` asks the USER a question; a delegated child's requester
        // is the orchestrator model, so the tool would strand the run on
        // `.waitingForInput` until its wall-clock budget expires.
        #expect(directNames.contains("clarify"), "baseline: direct chat carries clarify")
        #expect(!delegatedNames.contains("clarify"), "a delegated child must not carry clarify")

        // CAPABILITY SURFACE CONTRACT: exactly the two structural strips
        // above — everything else the target agent sees in direct chat, the
        // delegated child sees too (the child IS the agent).
        let expected = directNames.subtracting(spawnNames).subtracting(["clarify"])
        #expect(
            delegatedNames == expected,
            "delegated surface must be direct-chat minus spawn+clarify; missing: \(expected.subtracting(delegatedNames)), extra: \(delegatedNames.subtracting(expected))"
        )
    }

    // MARK: - Default agent is never a delegation target

    /// The built-in Default agent owns the orchestrator/configure surface
    /// (`osaurus_*` writes) and is barred from external
    /// dispatch. A delegated child running AS the Default agent would hand
    /// that surface to model-generated input — denied before any allow-list
    /// or residency work, regardless of configuration edits.
    @Test @MainActor func defaultAgentIsNeverASpawnTarget() async throws {
        let lease = await acquireSubagentStoreSandbox("delegation-default-target")
        defer { lease.release() }
        let kind = TextSubagentKind(agentID: Agent.defaultId, input: "x")
        let scope = SubagentScope(
            sessionId: "s",
            toolCallId: "t",
            agentId: UUID()  // a custom launcher, so the self-spawn guard passes
        )
        do {
            _ = try await kind.resolveModel(scope)
            Issue.record("resolving the Default agent as a spawn target must throw")
        } catch let error as SubagentError {
            guard case .denied(let message) = error else {
                Issue.record("expected .denied, got \(error)")
                return
            }
            #expect(message.contains("Default agent"))
        }
    }
}

/// Tiny thread-safe counter for publisher-tick probes.
private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    func increment() {
        lock.lock()
        _count += 1
        lock.unlock()
    }
}
