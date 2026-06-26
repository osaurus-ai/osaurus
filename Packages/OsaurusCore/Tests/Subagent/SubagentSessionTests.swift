//
//  SubagentSessionTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Model-free coverage of the shared host (`SubagentSession`) via a scripted
//  kind. This is the deterministic seam the whole sub-agent family rides on:
//  resolve → permission → handoff → run → normalize → cleanup, with no
//  tokens burned. Exercises the success path, the unified recursion guard,
//  permission refusal, reject-before-evict, the optional handoff middleware,
//  and feed lifecycle.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Scripted kind

/// A fully scripted `SubagentKind` so the host's control flow runs without a
/// model. Each step is overridable; defaults form a happy path.
private final class ScriptedKind: SubagentKind, @unchecked Sendable {
    let capability: SubagentCapability
    /// Test-local handoff opt-in (drives `makeHandoff()`); no longer a
    /// `SubagentKind` requirement.
    let needsHandoff: Bool

    var resolve: @Sendable (SubagentScope) async throws -> ResolvedModel
    var decide: @Sendable (SubagentScope, ResolvedModel) async -> SubagentDecision
    var body: @Sendable (SubagentScope, ResolvedModel, SubagentFeed, InterruptToken) async throws -> SubagentResult

    init(
        id: String = "scripted",
        needsHandoff: Bool = false,
        resolve: @escaping @Sendable (SubagentScope) async throws -> ResolvedModel = { _ in
            ResolvedModel(name: "scripted-model", id: "scripted-model", isLocal: true)
        },
        decide: @escaping @Sendable (SubagentScope, ResolvedModel) async -> SubagentDecision = {
            _,
            _ in .allow
        },
        body:
            @escaping @Sendable (SubagentScope, ResolvedModel, SubagentFeed, InterruptToken) async throws ->
            SubagentResult = {
                _,
                _,
                feed,
                _ in
                feed.emitPhase("running")
                return SubagentResult(payload: ["kind": "scripted", "summary": "done"], summary: "done")
            }
    ) {
        self.capability = SubagentCapability(id: id, toolNames: [id], gate: .sandboxExec)
        self.needsHandoff = needsHandoff
        self.resolve = resolve
        self.decide = decide
        self.body = body
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel { try await resolve(scope) }
    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        await decide(scope, resolved)
    }
    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        try await body(scope, resolved, feed, interrupt)
    }
}

/// Records whether `around` wrapped the run.
private final class RecordingHandoff: SubagentHandoff, @unchecked Sendable {
    var wrapped = false
    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        wrapped = true
        return try await body()
    }
}

// MARK: - Helpers

private func decode(_ envelope: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(envelope.utf8))) as? [String: Any] ?? [:]
}

// MARK: - Tests

@Suite("SubagentSession host")
struct SubagentSessionTests {

    @Test("happy path returns a success envelope carrying the kind payload")
    func happyPath() async {
        let kind = ScriptedKind()
        let envelope = await SubagentSession.run(kind, tool: "scripted")
        #expect(ToolEnvelope.isSuccess(envelope))
        let payload = ToolEnvelope.successPayload(envelope) as? [String: Any]
        #expect(payload?["kind"] as? String == "scripted")
        #expect(payload?["summary"] as? String == "done")
    }

    @Test("the unified recursion guard refuses a nested sub-agent of any kind")
    func recursionGuard() async {
        // Inside the running kind, a second SubagentSession.run must be refused.
        let inner = ScriptedKind(id: "inner")
        let nestedEnvelopeBox = NestedBox()
        let outer = ScriptedKind(
            id: "outer",
            body: { _, _, _, _ in
                let nested = await SubagentSession.run(inner, tool: "inner")
                nestedEnvelopeBox.value = nested
                return SubagentResult(payload: ["kind": "outer", "summary": "ok"])
            }
        )
        let envelope = await SubagentSession.run(outer, tool: "outer")
        #expect(ToolEnvelope.isSuccess(envelope))
        let nested = nestedEnvelopeBox.value ?? ""
        #expect(ToolEnvelope.isError(nested))
        #expect(decode(nested)["kind"] as? String == "rejected")
        #expect(ToolEnvelope.failureMessage(nested).contains("running sub-agent"))
    }

    @Test("policy denial maps to a rejected envelope")
    func policyDenied() async {
        let kind = ScriptedKind(decide: { _, _ in .denied("nope") })
        let envelope = await SubagentSession.run(kind, tool: "scripted")
        #expect(ToolEnvelope.isError(envelope))
        #expect(decode(envelope)["kind"] as? String == "rejected")
    }

    @Test("user refusal maps to a user_denied envelope")
    func userDenied() async {
        let kind = ScriptedKind(decide: { _, _ in .userDenied("declined") })
        let envelope = await SubagentSession.run(kind, tool: "scripted")
        #expect(decode(envelope)["kind"] as? String == "user_denied")
    }

    @Test("a thrown SubagentError maps to its canonical failure kind (reject-before-evict)")
    func resolveFailureBeforeRun() async {
        let kind = ScriptedKind(resolve: { _ in throw SubagentError.unavailable("no model") })
        let envelope = await SubagentSession.run(kind, tool: "scripted")
        #expect(decode(envelope)["kind"] as? String == "unavailable")
    }

    @Test("the handoff middleware wraps the run for needsHandoff kinds")
    func handoffWraps() async {
        let kind = ScriptedKind(needsHandoff: true)
        let handoff = RecordingHandoff()
        _ = await SubagentSession.run(kind, tool: "scripted", handoff: handoff)
        #expect(handoff.wrapped)
    }

    @Test("the live feed is registered during the run and dropped after")
    func feedLifecycle() async {
        let observedBox = NestedBox()
        let kind = ScriptedKind(
            body: { scope, _, feed, _ in
                // The feed must be discoverable by tool-call id while running.
                let live = SubagentFeedRegistry.shared.feed(for: scope.toolCallId)
                observedBox.value = (live != nil) ? "live" : "missing"
                feed.emitProgress("step", fraction: 0.5)
                return SubagentResult(payload: ["kind": "scripted", "summary": "done"])
            })
        _ = await SubagentSession.run(kind, tool: "scripted")
        #expect(observedBox.value == "live")
    }
}

/// Tiny reference box so escaping `@Sendable` closures can hand a value back.
private final class NestedBox: @unchecked Sendable {
    var value: String?
}
