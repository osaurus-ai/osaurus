//
//  ResidencyHandoffTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Model-free coverage of the single residency handoff middleware via injected
//  operations (no ModelRuntime). Pins the contract every model-swapping kind
//  relies on: refuse-before-evict (a preflight failure aborts BEFORE any
//  unload), unload is skipped when the plan says so, and restore ALWAYS runs
//  after an unload — on the success path and the throwing path.
//

import Foundation
import Testing

@testable import OsaurusCore

private struct PreflightRefused: Error {}
private struct BodyBlewUp: Error {}

/// Thread-safe ordered log of which residency operations ran.
private final class OpLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    func add(_ s: String) {
        lock.lock()
        steps.append(s)
        lock.unlock()
    }
    var value: [String] {
        lock.lock()
        defer { lock.unlock() }
        return steps
    }
}

private func makeHandoff(
    log: OpLog,
    plan: ResidencyPlan,
    preflightThrows: Bool = false
) -> ResidencyHandoff {
    ResidencyHandoff(
        plan: { _ in plan },
        preflight: { _, _, _ in
            log.add("preflight")
            if preflightThrows { throw PreflightRefused() }
        },
        unload: { _, _ in
            log.add("unload")
            return ChatResidencyLease(unloadedModelNames: ["chat-model"])
        },
        restore: { lease, _ in
            log.add("restore")
            return lease.unloadedModelNames
        }
    )
}

private let scope = SubagentScope(sessionId: "s", toolCallId: "t", agentId: Agent.defaultId)
private let resolved = ResolvedModel(name: "m", id: "m", isLocal: true)
private func feed() -> SubagentFeed { SubagentFeed(toolCallId: "t", kindId: "k", title: "x") }

@Suite("Residency handoff middleware")
struct ResidencyHandoffTests {

    @Test("unload path: preflight → unload → body → restore, in order")
    func unloadPathOrder() async throws {
        let log = OpLog()
        let handoff = makeHandoff(log: log, plan: ResidencyPlan(shouldUnload: true))
        let result = try await handoff.around(scope: scope, resolved: resolved, feed: feed()) {
            log.add("body")
            return SubagentResult(payload: ["kind": "k", "summary": "ok"], summary: "ok")
        }
        #expect(result.summary == "ok")
        #expect(log.value == ["preflight", "unload", "body", "restore"])
    }

    @Test("refuse-before-evict: a preflight failure aborts BEFORE any unload")
    func refuseBeforeEvict() async {
        let log = OpLog()
        let handoff = makeHandoff(
            log: log,
            plan: ResidencyPlan(shouldUnload: true, ramSafetyEnabled: true),
            preflightThrows: true
        )
        await #expect(throws: PreflightRefused.self) {
            _ = try await handoff.around(scope: scope, resolved: resolved, feed: feed()) {
                log.add("body")
                return SubagentResult(payload: [:])
            }
        }
        // Nothing unloaded, body never ran, nothing to restore.
        #expect(log.value == ["preflight"])
    }

    @Test("no-unload plan runs the body directly with no residency change")
    func skipsUnloadWhenPlanSaysSo() async throws {
        let log = OpLog()
        let handoff = makeHandoff(log: log, plan: ResidencyPlan(shouldUnload: false))
        let result = try await handoff.around(scope: scope, resolved: resolved, feed: feed()) {
            log.add("body")
            return SubagentResult(payload: ["summary": "done"], summary: "done")
        }
        #expect(result.summary == "done")
        #expect(log.value == ["preflight", "body"])
    }

    @Test("restore ALWAYS runs after an unload, even when the body throws")
    func restoreOnThrow() async {
        let log = OpLog()
        let handoff = makeHandoff(log: log, plan: ResidencyPlan(shouldUnload: true))
        await #expect(throws: BodyBlewUp.self) {
            _ = try await handoff.around(scope: scope, resolved: resolved, feed: feed()) {
                log.add("body")
                throw BodyBlewUp()
            }
        }
        #expect(log.value == ["preflight", "unload", "body", "restore"])
    }
}
