//
//  SubagentOperationCancellationTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Owned subagent operation cancellation")
struct SubagentOperationCancellationTests {
    @Test("interrupt requests abort and drains the owned operation before returning")
    func interruptAbortsAndDrains() async {
        let probe = CancellationProbe()
        let interrupt = AtomicCancellationFlag()
        let operation = OwnedSubagentOperation {
            try await probe.run()
        }

        await waitUntil { await probe.started }
        interrupt.set()

        do {
            _ = try await operation.value(
                cancellationRequested: { interrupt.value },
                pollInterval: .milliseconds(1)
            )
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await probe.sawCancellation)
        #expect(await probe.finished)
    }

    @Test("parent task cancellation aborts and drains the owned operation")
    func parentCancellationAbortsAndDrains() async {
        let probe = CancellationProbe()
        let operation = OwnedSubagentOperation {
            try await probe.run()
        }
        let waiter = Task {
            try await operation.value(pollInterval: .milliseconds(1))
        }

        await waitUntil { await probe.started }
        waiter.cancel()
        _ = await waiter.result

        #expect(await probe.sawCancellation)
        #expect(await probe.finished)
    }

    @Test("target preparation interrupt owns and drains model resolution")
    func preparationInterruptDrainsResolution() async {
        let probe = CancellationProbe()
        let interrupt = InterruptToken()
        let kind = BlockingResolutionKind(probe: probe)
        let preparation = Task {
            await SubagentSession.prepare(
                kind,
                tool: "blocking_resolution",
                scope: SubagentScope.current(),
                interrupt: interrupt
            )
        }

        await waitUntil { await probe.started }
        interrupt.interrupt()
        let result = await preparation.value

        guard case .failure(let envelope) = result else {
            Issue.record("Expected cancelled preparation failure")
            return
        }
        #expect(ToolEnvelope.failureMessage(envelope).contains("resolution"))
        #expect(await probe.sawCancellation)
        #expect(await probe.finished)
    }

    @Test("different-local Stop restores the parent outside cancelled task state")
    func differentLocalStopRestoresParentOutsideCancellation() async {
        let probe = ResidencyRestoreProbe()
        let handoff = ResidencyHandoff(
            plan: { _ in ResidencyPlan(shouldUnload: true) },
            preflight: { _, _, _ in },
            unload: { _, _, _ in
                ChatResidencyLease(unloadedModelNames: ["parent-local"])
            },
            restore: { lease, _ in
                await probe.recordRestore(
                    lease: lease,
                    taskWasCancelled: Task.isCancelled
                )
                return lease.unloadedModelNames
            }
        )
        let feed = SubagentFeed(
            toolCallId: "different-local-stop",
            kindId: "spawn",
            title: "Different local child"
        )
        let scope = SubagentScope(
            sessionId: "session",
            toolCallId: "different-local-stop",
            agentId: UUID()
        )
        let execution = Task {
            do {
                _ = try await handoff.around(
                    scope: scope,
                    resolved: ResolvedModel(name: "child-local", id: "child", isLocal: true),
                    feed: feed
                ) {
                    await probe.markChildStarted()
                    try await Task.sleep(for: .seconds(300))
                    return SubagentResult(payload: ["unexpected": true])
                }
                Issue.record("Expected cancellation")
            } catch is CancellationError {
                // Expected after the parent presses Stop.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }

        await waitUntil { await probe.childStarted }
        execution.cancel()
        await execution.value

        #expect(await probe.restoredModels == ["parent-local"])
        #expect(await probe.restoreTaskWasCancelled == false)
    }

    @Test("post-stream Stop cannot promote buffered text to a final answer")
    func postStreamStopRejectsBufferedPartialAnswer() {
        #expect(throws: (any Error).self) {
            try AgentSubagentRunner.rejectTerminalCancellation { .userInterrupt }
        }
        do {
            try AgentSubagentRunner.rejectTerminalCancellation { nil }
        } catch {
            Issue.record("A non-cancelled terminal boundary must remain valid: \(error)")
        }
    }

    @Test("spawned registry dispatch rejects a non-abortable tool before execution")
    @MainActor
    func spawnedRegistryRejectsUnsupportedToolBeforeExecution() async throws {
        let probe = RegistryToolProbe()
        let tool = UnsupportedRegistryTool(probe: probe)
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        let result = try await ToolRegistry.shared.execute(
            name: tool.name,
            argumentsJSON: "{}",
            permissionGateResolved: true,
            ownsExecutionUntilTermination: true
        )

        #expect(ToolEnvelope.isError(result))
        #expect(ToolEnvelope.failureMessage(result).contains("does not expose cooperative"))
        #expect(!(await probe.started))
    }

    @Test("spawned registry dispatch cancellation drains a cooperative tool")
    @MainActor
    func spawnedRegistryCancellationDrainsCooperativeTool() async {
        let probe = RegistryToolProbe()
        let tool = CooperativeRegistryTool(probe: probe)
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        let operation = OwnedSubagentOperation {
            try await ToolRegistry.shared.execute(
                name: tool.name,
                argumentsJSON: "{}",
                permissionGateResolved: true,
                ownsExecutionUntilTermination: true
            )
        }

        await waitUntil { await probe.started }
        await operation.abortAndWait()

        #expect(await probe.sawCancellation)
        #expect(await probe.finished)
    }

    @Test("spawned schemas omit tools without audited cancellation ownership")
    @MainActor
    func spawnedSchemasOmitUnsupportedTools() {
        let probe = RegistryToolProbe()
        let unsupported = UnsupportedRegistryTool(probe: probe)
        let cooperative = CooperativeRegistryTool(probe: probe)
        ToolRegistry.shared.register(unsupported)
        ToolRegistry.shared.register(cooperative)
        defer {
            ToolRegistry.shared.unregister(names: [unsupported.name, cooperative.name])
        }

        let names = ToolRegistry.shared.specsForSpawnedOperations(
            forTools: [unsupported.name, cooperative.name]
        ).map(\.function.name)

        #expect(names == [cooperative.name])
    }

    @Test("spawned folder tools opt in only for audited host-file paths")
    func spawnedFolderToolCancellationClassification() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "needle\n".write(
            to: root.appendingPathComponent("plain.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: root.appendingPathComponent("document.docx"))

        let read = FileReadTool(rootPath: root)
        #expect(
            read.spawnedOperationCancellationSupport(
                argumentsJSON: #"{"path":"plain.txt"}"#
            ) == .cooperative
        )
        #expect(
            read.spawnedOperationCancellationSupport(
                argumentsJSON: #"{"path":"document.docx"}"#
            ) == .unsupported
        )
        #expect(
            read.spawnedOperationCancellationSupport(
                argumentsJSON: #"{"path":"/workspace/plain.txt"}"#
            ) == .unsupported
        )

        let search = FileSearchTool(rootPath: root)
        #expect(
            search.spawnedOperationCancellationSupport(
                argumentsJSON: #"{"pattern":"needle","path":"."}"#
            ) == .cooperative
        )
        #expect(
            search.spawnedOperationCancellationSupport(
                argumentsJSON: #"{"pattern":"needle","path":"/workspace"}"#
            ) == .unsupported
        )
    }

    @Test("spawned file search cancellation drains a mid-content read")
    func spawnedFileSearchCancellationDrainsMidRead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-search-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "needle\n".write(
            to: root.appendingPathComponent("plain.txt"),
            atomically: true,
            encoding: .utf8
        )

        let probe = CancellationProbe()
        let search = FileSearchTool(
            rootPath: root,
            contentReader: { _ in
                try await probe.run()
            }
        )
        let operation = OwnedSubagentOperation {
            try await search.execute(
                argumentsJSON: #"{"pattern":"needle","target":"content","path":"plain.txt"}"#
            )
        }

        await waitUntil { await probe.started }
        await operation.abortAndWait()

        #expect(await probe.sawCancellation)
        #expect(await probe.finished)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await predicate())
    }
}

private actor CancellationProbe {
    private(set) var started = false
    private(set) var sawCancellation = false
    private(set) var finished = false

    func run() async throws -> String {
        started = true
        do {
            try await Task.sleep(for: .seconds(300))
            finished = true
            return "late"
        } catch {
            sawCancellation = true
            finished = true
            throw error
        }
    }
}

private final class AtomicCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var state = false

    var value: Bool { lock.withLock { state } }
    func set() { lock.withLock { state = true } }
}

private final class BlockingResolutionKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapability(
        id: "blocking_resolution",
        toolNames: ["blocking_resolution"],
        gate: .sandboxExec
    )
    private let probe: CancellationProbe

    init(probe: CancellationProbe) {
        self.probe = probe
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        _ = try await probe.run()
        return ResolvedModel(name: "never", id: "never", isLocal: true)
    }

    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        .allow
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        SubagentResult(payload: ["unexpected": true])
    }
}

private actor RegistryToolProbe {
    private(set) var started = false
    private(set) var sawCancellation = false
    private(set) var finished = false

    func run() async throws -> String {
        started = true
        do {
            try await Task.sleep(for: .seconds(300))
            finished = true
            return "late"
        } catch {
            sawCancellation = true
            finished = true
            throw error
        }
    }
}

private actor ResidencyRestoreProbe {
    private(set) var childStarted = false
    private(set) var restoredModels: [String] = []
    private(set) var restoreTaskWasCancelled: Bool?

    func markChildStarted() {
        childStarted = true
    }

    func recordRestore(lease: ChatResidencyLease, taskWasCancelled: Bool) {
        restoredModels = lease.unloadedModelNames
        restoreTaskWasCancelled = taskWasCancelled
    }
}

private struct UnsupportedRegistryTool: OsaurusTool {
    let name = "test_spawned_unsupported_operation_\(UUID().uuidString.prefix(12))"
    let description = "Cancellation ownership rejection fixture."
    let parameters: JSONValue? = .object(["type": .string("object")])
    let probe: RegistryToolProbe

    func execute(argumentsJSON _: String) async throws -> String {
        try await probe.run()
    }
}

private struct CooperativeRegistryTool: OsaurusTool {
    let name = "test_spawned_cooperative_operation_\(UUID().uuidString.prefix(12))"
    let description = "Cancellation ownership drain fixture."
    let parameters: JSONValue? = .object(["type": .string("object")])
    let probe: RegistryToolProbe

    var canExposeToSpawnedOperation: Bool { true }

    func spawnedOperationCancellationSupport(
        argumentsJSON _: String
    ) -> SpawnedOperationCancellationSupport {
        .cooperative
    }

    func execute(argumentsJSON _: String) async throws -> String {
        try await probe.run()
    }
}
