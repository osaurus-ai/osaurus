import Foundation
import Testing

@testable import OsaurusCore

private enum RetentionFailure: Error { case body, cleanup }

private actor RetentionLog {
    var entries: [String] = []
    func record(_ value: String) { entries.append(value) }
}

@Suite("Scoped parent residency retention")
struct ParentResidencyRetentionTests {
    private let parent = ModelResidencyIdentity(modelName: "parent", generation: UUID())

    @Test("multiple children hold one exact parent until the last release")
    func overlappingHolds() throws {
        var registry = ParentResidencyRetentions()
        let first = registry.begin(targetModelName: "child-b", parentModelName: "parent", parentIdentity: parent)
        let second = registry.begin(targetModelName: "child-c", parentModelName: "parent", parentIdentity: parent)
        #expect(first.childOwnershipToken != second.childOwnershipToken)
        #expect(registry.holds(parent))
        try registry.validate(first, targetModelName: "CHILD-B", currentParentIdentity: parent)
        let endedFirst = registry.end(first)
        let endedFirstAgain = registry.end(first)
        #expect(endedFirst)
        #expect(!endedFirstAgain)
        #expect(registry.holds(parent))
        #expect(throws: ParentResidencyRetentionError.self) {
            try registry.validate(first, targetModelName: "child-b", currentParentIdentity: parent)
        }
        let endedSecond = registry.end(second)
        #expect(endedSecond)
        #expect(!registry.holds(parent))
    }

    @Test("wrong target, unloaded parent and same-name replacement invalidate authority")
    func exactIdentityAndTarget() throws {
        var registry = ParentResidencyRetentions()
        let lease = registry.begin(targetModelName: "child", parentModelName: "parent", parentIdentity: parent)
        let replacement = ModelResidencyIdentity(modelName: "parent", generation: UUID())
        for identity in [nil, replacement] {
            #expect(throws: ParentResidencyRetentionError.self) {
                try registry.validate(lease, targetModelName: "child", currentParentIdentity: identity)
            }
        }
        #expect(!registry.holds(replacement))
        #expect(throws: ParentResidencyRetentionError.self) {
            try registry.validate(lease, targetModelName: "unapproved", currentParentIdentity: parent)
        }
    }

    @Test("an absent-parent permit cannot adopt a newly resident generation")
    func absentParentCannotAcquireAuthority() throws {
        var registry = ParentResidencyRetentions()
        let lease = registry.begin(targetModelName: "child", parentModelName: "parent", parentIdentity: nil)
        try registry.validate(lease, targetModelName: "child", currentParentIdentity: nil)
        #expect(!registry.holds(nil))
        #expect(throws: ParentResidencyRetentionError.self) {
            try registry.validate(lease, targetModelName: "child", currentParentIdentity: parent)
        }
    }

    @Test("body authority is scoped; cleanup runs exactly once on success or error", arguments: [false, true])
    func handoffCleanup(bodyFails: Bool) async throws {
        var registry = ParentResidencyRetentions()
        let lease = registry.begin(targetModelName: "child", parentModelName: "parent", parentIdentity: parent)
        let log = RetentionLog()
        let handoff = CoexistenceHandoff(
            maxElapsedSeconds: 30,
            waitForIdle: { _ in
                await log.record("idle"); return true
            },
            retain: { scope, resolved in
                #expect(scope.parentModelName == "parent")
                #expect(resolved.name == "child")
                await log.record("retain")
                return lease
            },
            finish: { actual in
                #expect(actual == lease)
                #expect(!Task.isCancelled)
                #expect(ParentResidencyRetentionContext.current == nil)
                await log.record("cleanup")
            }
        )
        do {
            _ = try await handoff.around(scope: scope, resolved: resolved, feed: feed()) {
                #expect(ParentResidencyRetentionContext.current == lease)
                #expect(ModelResidencyOwnershipContext.childOwnershipToken == lease.childOwnershipToken)
                await log.record("body")
                if bodyFails { throw RetentionFailure.body }
                return SubagentResult(payload: [:])
            }
            #expect(!bodyFails)
        } catch RetentionFailure.body { #expect(bodyFails) }
        #expect(ParentResidencyRetentionContext.current == nil)
        #expect(await log.entries == ["idle", "retain", "body", "cleanup"])
    }

    @Test("cancelled body cannot cancel owned cleanup")
    func cancellationDrainsCleanup() async throws {
        var registry = ParentResidencyRetentions()
        let lease = registry.begin(targetModelName: "child", parentModelName: "parent", parentIdentity: parent)
        let log = RetentionLog()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let handoff = CoexistenceHandoff(
            maxElapsedSeconds: 30,
            waitForIdle: { _ in true },
            retain: { _, _ in lease },
            finish: { _ in
                #expect(!Task.isCancelled)
                try await Task.sleep(for: .milliseconds(1))
                await log.record("cleanup")
            }
        )
        let task = Task {
            try await handoff.around(scope: scope, resolved: resolved, feed: feed()) {
                continuation.yield(())
                continuation.finish()
                try await Task.sleep(for: .seconds(60))
                return SubagentResult(payload: [:])
            }
        }
        for await _ in started { break }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        #expect(await log.entries == ["cleanup"])
    }

    @Test("cleanup failure is surfaced, preserving a simultaneous body failure", arguments: [false, true])
    func cleanupFailure(bodyFails: Bool) async throws {
        var registry = ParentResidencyRetentions()
        let lease = registry.begin(targetModelName: "child", parentModelName: "parent", parentIdentity: parent)
        let log = RetentionLog()
        let handoff = CoexistenceHandoff(
            maxElapsedSeconds: 30,
            waitForIdle: { _ in true },
            retain: { _, _ in lease },
            finish: { _ in
                await log.record("cleanup")
                throw RetentionFailure.cleanup
            }
        )
        do {
            _ = try await handoff.around(scope: scope, resolved: resolved, feed: feed()) {
                if bodyFails { throw RetentionFailure.body }
                return SubagentResult(payload: [:])
            }
            Issue.record("Cleanup failure must not be reported as success")
        } catch let failure as ResidencyHandoffFailure {
            #expect(bodyFails)
            #expect(failure == .bodyAndRestoreFailed(
                body: RetentionFailure.body.localizedDescription,
                restore: RetentionFailure.cleanup.localizedDescription
            ))
        } catch RetentionFailure.cleanup {
            #expect(!bodyFails)
        }
        #expect(await log.entries == ["cleanup"])
    }

    @Test("deferred dispatch retains its own context; unrelated sources get none", arguments: SessionSource.allCases)
    @MainActor
    func deferredDispatch(source: SessionSource) async {
        var registry = ParentResidencyRetentions()
        let lease = registry.begin(targetModelName: "child", parentModelName: "parent", parentIdentity: parent)
        let admission = SubagentAdmissionLease(
            controller: SubagentAdmission(), admissionClass: .localInPlace,
            modelKey: "parent", slots: 1, parentInterrupt: InterruptToken()
        )
        let context = ParentResidencyRetentionContext.$current.withValue(lease) {
            ModelResidencyOwnershipContext.$childOwnershipToken.withValue(lease.childOwnershipToken) {
                SubagentSession.$inheritedAdmissionLease.withValue(admission) {
                    DelegationResidencyContext.capture(source: source)
                }
            }
        }
        // Run later under a different dispatcher task's authority. A closure
        // that only reads task locals at execution would borrow this token.
        let unrelated = ModelResidencyOwnershipToken()
        let unrelatedAdmission = SubagentAdmissionLease(
            controller: SubagentAdmission(), admissionClass: .localExclusive,
            modelKey: "unrelated", slots: 0, parentInterrupt: InterruptToken()
        )
        await ModelResidencyOwnershipContext.$childOwnershipToken.withValue(unrelated) {
            await SubagentSession.$inheritedAdmissionLease.withValue(unrelatedAdmission) {
                await context.run {
                    #expect(ParentResidencyRetentionContext.current == (source == .delegation ? lease : nil))
                    #expect(
                        ModelResidencyOwnershipContext.childOwnershipToken
                            == (source == .delegation ? lease.childOwnershipToken : nil)
                    )
                    #expect(SubagentSession.inheritedAdmissionLease === (source == .delegation ? admission : nil))
                }
                #expect(SubagentSession.inheritedAdmissionLease === unrelatedAdmission)
            }
            #expect(ModelResidencyOwnershipContext.childOwnershipToken == unrelated)
        }
    }

    @Test("runtime validates before and after cold-load suspension and before publication")
    func loaderWiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let runtime = try String(
            contentsOf: root.appendingPathComponent("Services/ModelRuntime.swift"),
            encoding: .utf8
        )
        #expect(
            runtime.components(separatedBy: "try validateParentRetention(parentRetention, target: name)").count == 7
        )
        // All three load return paths (both coalesced waiters and the cold
        // owner) revalidate their own capability after publication/warm-up.
        #expect(runtime.components(separatedBy: "let published = try await finishLoadedContainer(").count == 4)
        #expect(runtime.components(separatedBy: "return published").count == 4)
        #expect(runtime.contains("validateParentRetention(loadingRecord.parentRetention, target: name)"))
        #expect(runtime.components(separatedBy: "policy == .strictSingleModel, parentRetention == nil").count == 3)
        #expect(runtime.contains("intent: parentRetention == nil ? intent : .background"))
        #expect(runtime.contains("|| parentRetentions.holds(residentMetadata[modelName]?.identity)"))
        let dispatch = try String(
            contentsOf: root.appendingPathComponent("Managers/BackgroundTaskManager.swift"),
            encoding: .utf8
        )
        let capture = try #require(
            dispatch.range(of: "let residencyContext = DelegationResidencyContext.capture(source: request.source)")
        )
        let deferred = try #require(dispatch.range(of: "let startWork:"))
        #expect(capture.lowerBound < deferred.lowerBound)
        #expect(dispatch.contains("await residencyContext.run {"))
    }

    private var scope: SubagentScope {
        SubagentScope(sessionId: "session", toolCallId: "call", agentId: Agent.defaultId, parentModelName: "parent")
    }
    private var resolved: ResolvedModel { ResolvedModel(name: "child", id: "child", isLocal: true) }
    private func feed() -> SubagentFeed { SubagentFeed(toolCallId: "call", kindId: "spawn", title: "test") }
}
