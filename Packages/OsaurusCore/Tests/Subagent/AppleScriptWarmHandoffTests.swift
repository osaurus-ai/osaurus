import Foundation
import Testing

@testable import OsaurusCore

private enum WarmFailure: Error { case restore, body }

private actor WarmLog {
    var entries: [String] = []
    var failRestore = false
    func record(_ entry: String) { entries.append(entry) }
    func setFailRestore(_ value: Bool) { failRestore = value }
    func restore(_ lease: ChatResidencyLease) throws {
        entries.append("restore:\(lease.restoreModelNames.joined(separator: ","))")
        #expect(!Task.isCancelled)
        if failRestore { throw WarmFailure.restore }
    }
}

private actor WarmLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@Suite("AppleScript warm handoff ownership and restoration")
struct AppleScriptWarmHandoffTests {
    private let scope = SubagentScope(
        sessionId: "parent-session",
        toolCallId: "call",
        agentId: Agent.defaultId,
        parentModelName: "parent"
    )
    private let resolved = ResolvedModel(name: "script-model", id: "script-model", isLocal: true)
    private var owner: AppleScriptWarmResidencyOwner { AppleScriptWarmResidencyOwner(scope: scope) }
    private let parked: @Sendable (Int) async -> Void = { _ in try? await Task.sleep(for: .seconds(100)) }
    private func feed() -> SubagentFeed { SubagentFeed(toolCallId: "call", kindId: "applescript", title: "test") }

    @Test("cold and adopted bodies use their own lease token, not an inherited outer token", arguments: [false, true])
    func ownTokenAcrossReuse(hasOuterToken: Bool) async throws {
        let log = WarmLog()
        let lease = ChatResidencyLease(unloadedModelNames: ["parent"])
        let coordinator = AppleScriptWarmResidencyCoordinator(
            restore: { try await log.restore($0) },
            canAdopt: { _, _ in true },
            sleep: parked
        )
        let handoff = AppleScriptWarmResidencyHandoff(
            plan: ResidencyPlan(shouldUnload: true),
            model: resolved.name,
            keepWarmSeconds: 90,
            coordinator: coordinator,
            preflight: { _, _, _ in await log.record("preflight") },
            unload: { parent, _, _ in
                #expect(parent == "parent")
                await log.record("unload")
                return lease
            }
        )
        let outer = hasOuterToken ? ModelResidencyOwnershipToken() : nil
        try await ModelResidencyOwnershipContext.$childOwnershipToken.withValue(outer) {
            for _ in 0 ..< 2 {
                _ = try await handoff.around(scope: scope, resolved: resolved, feed: feed()) {
                    #expect(ModelResidencyOwnershipContext.childOwnershipToken == lease.childOwnershipToken)
                    await log.record("body")
                    return SubagentResult(payload: [:])
                }
                #expect(ModelResidencyOwnershipContext.childOwnershipToken == outer)
            }
        }
        try await coordinator.flush()
        #expect(await log.entries == ["preflight", "unload", "body", "body", "restore:parent"])
    }

    @Test("toggle OFF settles a previous warm swap and never unloads or parks a new lease")
    func disabledDoesNotAdopt() async throws {
        let log = WarmLog()
        let coordinator = AppleScriptWarmResidencyCoordinator(
            restore: { try await log.restore($0) },
            canAdopt: { _, _ in true },
            sleep: parked
        )
        try await coordinator.endRun(
            lease: ChatResidencyLease(unloadedModelNames: ["parent"]),
            model: resolved.name,
            owner: owner,
            keepWarmSeconds: 90
        )
        let handoff = AppleScriptWarmResidencyHandoff(
            plan: ResidencyPlan(shouldUnload: false),
            model: resolved.name,
            keepWarmSeconds: 90,
            coordinator: coordinator,
            preflight: { _, enabled, _ in #expect(!enabled) },
            unload: { _, _, _ in
                Issue.record("OFF must not unload"); return .empty
            }
        )
        _ = try await handoff.around(scope: scope, resolved: resolved, feed: feed()) {
            await log.record("body")
            return SubagentResult(payload: [:])
        }
        #expect(await log.entries == ["restore:parent", "body"])
        #expect(await coordinator.heldModelForTesting() == nil)
    }

    @Test("another parent or session cannot adopt a warm lease", arguments: [false, true])
    func ownerChangesRestoreFirst(changeSession: Bool) async throws {
        let log = WarmLog()
        let coordinator = AppleScriptWarmResidencyCoordinator(
            restore: { try await log.restore($0) },
            canAdopt: { _, _ in true },
            sleep: parked
        )
        try await coordinator.endRun(
            lease: ChatResidencyLease(unloadedModelNames: ["parent"]),
            model: resolved.name,
            owner: owner,
            keepWarmSeconds: 90
        )
        let changed = AppleScriptWarmResidencyOwner(
            scope: SubagentScope(
                sessionId: changeSession ? "another-session" : scope.sessionId,
                toolCallId: "next",
                agentId: scope.agentId,
                parentModelName: changeSession ? "parent" : "another-parent"
            )
        )
        let adopted = try await coordinator.beginRun(model: resolved.name, owner: changed, allowAdoption: true)
        #expect(adopted == nil)
        #expect(await log.entries == ["restore:parent"])
    }

    @Test("a child that is no longer owned cannot be adopted, even if its name matches")
    func replacedChildCannotBeAdopted() async throws {
        let log = WarmLog()
        let coordinator = AppleScriptWarmResidencyCoordinator(
            restore: { try await log.restore($0) },
            canAdopt: { _, _ in false },
            sleep: parked
        )
        try await coordinator.endRun(
            lease: ChatResidencyLease(unloadedModelNames: ["parent"]),
            model: resolved.name,
            owner: owner,
            keepWarmSeconds: 90
        )
        #expect(try await coordinator.beginRun(model: resolved.name, owner: owner, allowAdoption: true) == nil)
        #expect(await log.entries == ["restore:parent"])
    }

    @Test("failed restore retains its receipt and retries before admitting another child")
    func failedRestoreRemainsRecoverable() async throws {
        let log = WarmLog()
        let coordinator = AppleScriptWarmResidencyCoordinator(
            restore: { try await log.restore($0) },
            canAdopt: { _, _ in true },
            sleep: parked
        )
        let lease = ChatResidencyLease(unloadedModelNames: ["parent"])
        await log.setFailRestore(true)
        await #expect(throws: WarmFailure.self) {
            try await coordinator.endRun(lease: lease, model: resolved.name, owner: owner, keepWarmSeconds: 0)
        }
        #expect(await coordinator.heldModelForTesting() == resolved.name)
        await #expect(throws: WarmFailure.self) {
            _ = try await coordinator.beginRun(model: resolved.name, owner: owner, allowAdoption: true)
        }
        await log.setFailRestore(false)
        #expect(try await coordinator.beginRun(model: resolved.name, owner: owner, allowAdoption: true) == nil)
        #expect(await coordinator.heldModelForTesting() == nil)
        #expect(await log.entries.count == 3)
    }

    @Test("deferred restore and a new run join one cleanup rather than lose the lease")
    func joinsInFlightRestore() async throws {
        let started = WarmLatch()
        let release = WarmLatch()
        let log = WarmLog()
        let coordinator = AppleScriptWarmResidencyCoordinator(
            restore: { lease in
                await started.open()
                await release.wait()
                try await log.restore(lease)
            },
            canAdopt: { _, _ in true },
            sleep: { _ in }
        )
        try await coordinator.endRun(
            lease: ChatResidencyLease(unloadedModelNames: ["parent"]),
            model: resolved.name,
            owner: owner,
            keepWarmSeconds: 90
        )
        await started.wait()
        let next = Task { try await coordinator.beginRun(model: resolved.name, owner: owner, allowAdoption: true) }
        await release.open()
        #expect(try await next.value == nil)
        #expect(await log.entries == ["restore:parent"])
        #expect(await coordinator.heldModelForTesting() == nil)
    }

    @Test("Stop restores a restore-only parent outside the cancelled task")
    func cancellationRestoresUnloadedParent() async throws {
        let log = WarmLog()
        let started = WarmLatch()
        let coordinator = AppleScriptWarmResidencyCoordinator(
            restore: { try await log.restore($0) },
            sleep: parked
        )
        let handoff = AppleScriptWarmResidencyHandoff(
            plan: ResidencyPlan(shouldUnload: true),
            model: resolved.name,
            keepWarmSeconds: 90,
            coordinator: coordinator,
            preflight: { _, _, _ in },
            unload: { parent, _, _ in
                #expect(parent == "parent")
                return ChatResidencyLease(unloadedModelNames: [], restoreModelNames: ["parent"])
            }
        )
        let run = Task {
            try await handoff.around(scope: scope, resolved: resolved, feed: feed()) {
                await started.open()
                try await Task.sleep(for: .seconds(100))
                return SubagentResult(payload: [:])
            }
        }
        await started.wait()
        run.cancel()
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(await log.entries == ["restore:parent"])
        #expect(await coordinator.heldModelForTesting() == nil)
    }

    @Test("body and restore failures are both surfaced; failed lease is not discarded")
    func bodyAndRestoreFailure() async throws {
        let log = WarmLog()
        await log.setFailRestore(true)
        let coordinator = AppleScriptWarmResidencyCoordinator(restore: { try await log.restore($0) }, sleep: parked)
        let handoff = AppleScriptWarmResidencyHandoff(
            plan: ResidencyPlan(shouldUnload: true),
            model: resolved.name,
            keepWarmSeconds: 90,
            coordinator: coordinator,
            preflight: { _, _, _ in },
            unload: { _, _, _ in ChatResidencyLease(unloadedModelNames: ["parent"]) }
        )
        await #expect(throws: ResidencyHandoffFailure.self) {
            _ = try await handoff.around(scope: scope, resolved: resolved, feed: feed()) { throw WarmFailure.body }
        }
        #expect(await coordinator.heldModelForTesting() == resolved.name)
        await log.setFailRestore(false)
        try await coordinator.flush()
    }
}
