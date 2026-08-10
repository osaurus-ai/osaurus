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
private struct BodyBlewUp: Error, LocalizedError {
    var errorDescription: String? { "body failed" }
}
private struct RestoreBlewUp: Error, LocalizedError {
    var errorDescription: String? { "restore failed" }
}

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
    preflightThrows: Bool = false,
    restoreThrows: Bool = false
) -> ResidencyHandoff {
    ResidencyHandoff(
        plan: { _ in plan },
        preflight: { _, _, _ in
            log.add("preflight")
            if preflightThrows { throw PreflightRefused() }
        },
        unload: { _, _, _ in
            log.add("unload")
            return ChatResidencyLease(unloadedModelNames: ["chat-model"])
        },
        restore: { lease, _ in
            log.add("restore")
            if restoreThrows { throw RestoreBlewUp() }
            return lease.unloadedModelNames
        }
    )
}

private let scope = SubagentScope(
    sessionId: "s",
    toolCallId: "t",
    agentId: Agent.defaultId,
    parentModelName: "exact-parent"
)
private let resolved = ResolvedModel(name: "m", id: "m", isLocal: true)
private func feed() -> SubagentFeed { SubagentFeed(toolCallId: "t", kindId: "k", title: "x") }

@Suite("Residency handoff middleware")
struct ResidencyHandoffTests {

    @Test("unload path: preflight → unload → body → restore, in order")
    func unloadPathOrder() async throws {
        let log = OpLog()
        let token = ModelResidencyOwnershipToken()
        let handoff = ResidencyHandoff(
            plan: { _ in ResidencyPlan(shouldUnload: true) },
            preflight: { _, _, _ in log.add("preflight") },
            unload: { parent, _, _ in
                #expect(parent == "exact-parent")
                log.add("unload")
                return ChatResidencyLease(
                    unloadedModelNames: ["chat-model"],
                    childOwnershipToken: token
                )
            },
            restore: { lease, _ in
                #expect(lease.childOwnershipToken == token)
                log.add("restore")
                return lease.unloadedModelNames
            }
        )
        let result = try await handoff.around(scope: scope, resolved: resolved, feed: feed()) {
            #expect(ModelResidencyOwnershipContext.childOwnershipToken == token)
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

    @Test("successful child is not reported as success when parent restore fails")
    func restoreFailureAfterSuccessPropagates() async {
        let log = OpLog()
        let handoff = makeHandoff(
            log: log,
            plan: ResidencyPlan(shouldUnload: true),
            restoreThrows: true
        )

        await #expect(throws: RestoreBlewUp.self) {
            _ = try await handoff.around(scope: scope, resolved: resolved, feed: feed()) {
                log.add("body")
                return SubagentResult(payload: ["summary": "child succeeded"])
            }
        }
        #expect(log.value == ["preflight", "unload", "body", "restore"])
    }

    @Test("body and restore failures preserve both failure contexts")
    func bodyAndRestoreFailurePreservesBothContexts() async {
        let log = OpLog()
        let handoff = makeHandoff(
            log: log,
            plan: ResidencyPlan(shouldUnload: true),
            restoreThrows: true
        )

        do {
            _ = try await handoff.around(scope: scope, resolved: resolved, feed: feed()) {
                log.add("body")
                throw BodyBlewUp()
            }
            Issue.record("handoff should have failed")
        } catch let error as ResidencyHandoffFailure {
            guard case .bodyAndRestoreFailed(let body, let restore) = error else {
                Issue.record("unexpected residency handoff failure: \(error)")
                return
            }
            #expect(body.contains("BodyBlewUp"))
            #expect(body.contains("body failed"))
            #expect(restore.contains("RestoreBlewUp"))
            #expect(restore.contains("restore failed"))
            #expect(error.localizedDescription.contains("Subagent failure"))
            #expect(error.localizedDescription.contains("Restore failure"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(log.value == ["preflight", "unload", "body", "restore"])
    }

    @Test("cancelled child restores the parent from an uncancelled cleanup task")
    func restoreEscapesChildCancellation() async {
        let log = OpLog()
        let handoff = ResidencyHandoff(
            plan: { _ in ResidencyPlan(shouldUnload: true) },
            preflight: { _, _, _ in log.add("preflight") },
            unload: { _, _, _ in
                log.add("unload")
                return ChatResidencyLease(unloadedModelNames: ["chat-model"])
            },
            restore: { lease, _ in
                log.add("restore-cancelled=\(Task.isCancelled)")
                return lease.unloadedModelNames
            }
        )

        let task = Task {
            try await handoff.around(
                scope: scope,
                resolved: resolved,
                feed: feed()
            ) {
                log.add("body")
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }
        }
        _ = try? await task.value

        #expect(
            log.value
                == [
                    "preflight",
                    "unload",
                    "body",
                    "restore-cancelled=false",
                ]
        )
    }

    @Test("nested ownership wrapper preserves and restores the outer token")
    func nestedOwnershipWrapperPreservesOuterToken() async throws {
        let outer = ModelResidencyOwnershipToken()
        let inner = ModelResidencyOwnershipToken()
        let handoff = ResidencyOwnershipHandoff(
            wrapping: PassthroughHandoff(),
            ownershipToken: inner
        )

        #expect(ModelResidencyOwnershipContext.childOwnershipToken == nil)
        try await ModelResidencyOwnershipContext.$childOwnershipToken.withValue(outer) {
            #expect(ModelResidencyOwnershipContext.childOwnershipToken == outer)

            let result = try await handoff.around(
                scope: scope,
                resolved: resolved,
                feed: feed()
            ) {
                #expect(ModelResidencyOwnershipContext.childOwnershipToken == outer)
                #expect(ModelResidencyOwnershipContext.childOwnershipToken != inner)
                return SubagentResult(payload: ["summary": "owned"], summary: "owned")
            }

            #expect(result.summary == "owned")
            #expect(ModelResidencyOwnershipContext.childOwnershipToken == outer)
        }
        #expect(ModelResidencyOwnershipContext.childOwnershipToken == nil)
    }
}
