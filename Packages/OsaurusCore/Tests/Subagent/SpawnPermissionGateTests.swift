//
//  SpawnPermissionGateTests.swift
//  OsaurusCoreTests
//
//  Model-free security and cancellation coverage for spawn_agent,
//  spawn_model, and spawn_batch permission ownership.
//

import Foundation
import Testing

@testable import OsaurusCore

private actor SpawnPromptProbe {
    private var requests: [SpawnPermissionGate.PromptRequest] = []
    private var started = false
    private var sawCancellation = false
    private var finished = false

    func record(
        _ request: SpawnPermissionGate.PromptRequest,
        returning choice: SpawnPermissionGate.PromptChoice
    ) -> SpawnPermissionGate.PromptChoice {
        requests.append(request)
        return choice
    }

    func suspendUntilCancelled(
        _ request: SpawnPermissionGate.PromptRequest
    ) async throws -> SpawnPermissionGate.PromptChoice {
        requests.append(request)
        started = true
        do {
            try await Task.sleep(for: .seconds(300))
        } catch {
            sawCancellation = true
            finished = true
            throw error
        }
        finished = true
        return .allowOnce
    }

    func snapshot() -> (
        requests: [SpawnPermissionGate.PromptRequest],
        started: Bool,
        sawCancellation: Bool,
        finished: Bool
    ) {
        (requests, started, sawCancellation, finished)
    }
}

private actor DirectPermissionProbe {
    private var permissionStarted = false
    private var permissionCancelled = false
    private var permissionFinished = false
    private var runCount = 0

    func waitForPermissionCancellation() async -> SubagentDecision {
        permissionStarted = true
        do {
            try await Task.sleep(for: .seconds(300))
        } catch {
            permissionCancelled = true
        }
        permissionFinished = true
        return .allow
    }

    func recordRun() {
        runCount += 1
    }

    func snapshot() -> (
        permissionStarted: Bool,
        permissionCancelled: Bool,
        permissionFinished: Bool,
        runCount: Int
    ) {
        (
            permissionStarted,
            permissionCancelled,
            permissionFinished,
            runCount
        )
    }
}

private final class DirectPermissionKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapability(
        id: "direct-permission-test",
        toolNames: ["direct_permission_test"],
        gate: .delegation
    )
    let probe: DirectPermissionProbe

    init(probe: DirectPermissionProbe) {
        self.probe = probe
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        ResolvedModel(name: "model-free", isLocal: false)
    }

    func permission(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel
    ) async -> SubagentDecision {
        await probe.waitForPermissionCancellation()
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        await probe.recordRun()
        return SubagentResult(payload: ["summary": "unexpected"])
    }
}

@Suite("Spawn permission gate", .serialized)
struct SpawnPermissionGateTests {
    private let defaultScope = SubagentScope(
        sessionId: "spawn-permission-tests",
        toolCallId: "spawn-permission-tests",
        agentId: Agent.defaultId
    )

    private func authorize(
        scope: SubagentScope? = nil,
        policy: SubagentPermissionPolicy,
        probe: SpawnPromptProbe,
        choice: SpawnPermissionGate.PromptChoice
    ) async -> SubagentDecision {
        await SpawnPermissionGate.$promptOverride.withValue(
            { request in
                await probe.record(request, returning: choice)
            }
        ) {
            await SpawnPermissionGate.authorize(
                scope: scope ?? defaultScope,
                policy: policy,
                toolName: SubagentCapabilityRegistry.spawnAgentToolName,
                description: "Allow one bounded subagent?",
                argumentsJSON: #"{"agent":"Worker","input":"Do one task"}"#
            )
        }
    }

    @Test("ask supports allow once and deny without persisting")
    func askSupportsAllowOnceAndDeny() async {
        let allowProbe = SpawnPromptProbe()
        let allow = await authorize(
            policy: .ask,
            probe: allowProbe,
            choice: .allowOnce
        )
        #expect(allow == .allow)
        #expect((await allowProbe.snapshot()).requests.count == 1)

        let denyProbe = SpawnPromptProbe()
        let deny = await authorize(
            policy: .ask,
            probe: denyProbe,
            choice: .deny
        )
        guard case .userDenied(let reason) = deny else {
            Issue.record("Expected explicit user denial")
            return
        }
        #expect(reason.contains("denied"))
        #expect((await denyProbe.snapshot()).requests.count == 1)
    }

    @Test("deny rejects and always allow skips the prompt")
    func storedPoliciesSkipPrompt() async {
        let probe = SpawnPromptProbe()
        let denied = await authorize(
            policy: .deny,
            probe: probe,
            choice: .allowOnce
        )
        guard case .denied(let reason) = denied else {
            Issue.record("Expected policy denial")
            return
        }
        #expect(reason.contains("permission settings"))

        let allowed = await authorize(
            policy: .alwaysAllow,
            probe: probe,
            choice: .deny
        )
        #expect(allowed == .allow)
        #expect((await probe.snapshot()).requests.isEmpty)
    }

    @Test("headless auto approval skips the prompt without persisting")
    func autoApprovalSkipsPrompt() async {
        let lease = await acquireSubagentStoreSandbox("spawn-permission-autoapprove")
        defer { lease.release() }

        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(.ask, for: SubagentCapabilityRegistry.spawn.id)
        SubagentConfigurationStore.save(
            SubagentConfiguration(permissionDefaults: permissions)
        )

        let probe = SpawnPromptProbe()
        let decision = await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
            await authorize(
                policy: .ask,
                probe: probe,
                choice: .deny
            )
        }

        #expect(decision == .allow)
        #expect((await probe.snapshot()).requests.isEmpty)
        #expect(
            SubagentConfigurationStore.snapshot().permissionDefaults.policy(
                for: SubagentCapabilityRegistry.spawn.id
            ) == .ask
        )
    }

    @Test("always allow persists in the default agent subagent store")
    func defaultAlwaysAllowPersists() async {
        let lease = await acquireSubagentStoreSandbox("spawn-permission-default-always")
        defer { lease.release() }

        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(.ask, for: SubagentCapabilityRegistry.spawn.id)
        SubagentConfigurationStore.save(
            SubagentConfiguration(permissionDefaults: permissions)
        )

        let probe = SpawnPromptProbe()
        let decision = await authorize(
            policy: .ask,
            probe: probe,
            choice: .alwaysAllow
        )
        #expect(decision == .allow)
        #expect((await probe.snapshot()).requests.count == 1)

        SubagentConfigurationStore.flushPendingWrites()
        SubagentConfigurationStore.invalidateSnapshot()
        #expect(
            SubagentConfigurationStore.snapshot().permissionDefaults.policy(
                for: SubagentCapabilityRegistry.spawn.id
            ) == .alwaysAllow
        )
    }

    @Test("always allow persists in the launching custom agent")
    @MainActor
    func customAgentAlwaysAllowPersists() async {
        await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "osaurus-spawn-permission-custom-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            var settings = AgentSettings.defaultDisabled
            var permissions = SubagentPermissionDefaults()
            permissions.setPolicy(.ask, for: SubagentCapabilityRegistry.spawn.id)
            settings.subagentPermissions = permissions
            let agent = Agent(
                name: "SpawnPermissionCustom",
                agentAddress: "spawn-permission-\(UUID().uuidString)",
                settings: settings
            )
            AgentStore.save(agent)
            AgentManager.shared.refresh()

            let scope = SubagentScope(
                sessionId: "custom-agent-permission",
                toolCallId: "custom-agent-permission",
                agentId: agent.id
            )
            let probe = SpawnPromptProbe()
            let decision = await authorize(
                scope: scope,
                policy: .ask,
                probe: probe,
                choice: .alwaysAllow
            )
            #expect(decision == .allow)
            #expect(
                AgentManager.shared.agent(for: agent.id)?
                    .settings.subagentPermissions.policy(
                        for: SubagentCapabilityRegistry.spawn.id
                    ) == .alwaysAllow
            )

            // Simulate an AgentDetailView that loaded before the prompt and
            // later saves an unrelated description edit. Its permission field
            // is still the original `.ask`; the three-way editor merge must
            // retain the live `.alwaysAllow` value persisted above.
            guard var unrelatedSave = AgentManager.shared.agent(for: agent.id) else {
                Issue.record("Expected live custom agent after Always Allow")
                return
            }
            unrelatedSave.description = "Unrelated editor change"
            unrelatedSave.settings.subagentPermissions =
                SubagentPermissionDefaults.mergingEditorSnapshot(
                    permissions,
                    loadedBaseline: permissions,
                    live: unrelatedSave.settings.subagentPermissions
                )
            AgentManager.shared.update(unrelatedSave)

            AgentManager.shared.refresh()
            #expect(
                AgentStore.load(id: agent.id)?
                    .settings.subagentPermissions.policy(
                        for: SubagentCapabilityRegistry.spawn.id
                    ) == .alwaysAllow
            )
            #expect(AgentStore.load(id: agent.id)?.description == "Unrelated editor change")

            // A deliberate editor permission change is not masked by the
            // reconciliation logic: editor changes since the baseline win.
            var deliberatelyEdited = permissions
            deliberatelyEdited.setPolicy(
                .deny,
                for: SubagentCapabilityRegistry.spawn.id
            )
            let deliberateMerge = SubagentPermissionDefaults.mergingEditorSnapshot(
                deliberatelyEdited,
                loadedBaseline: permissions,
                live: unrelatedSave.settings.subagentPermissions
            )
            #expect(
                deliberateMerge.policy(for: SubagentCapabilityRegistry.spawn.id) == .deny
            )
        }
    }

    @Test("spawn batch rejects invalid targets without prompting")
    func batchRejectsInvalidTargetsBeforePrompt() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-permission-one-batch-prompt")
        defer { lease.release() }

        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(.ask, for: SubagentCapabilityRegistry.spawn.id)
        SubagentConfigurationStore.save(
            SubagentConfiguration(
                permissionDefaults: permissions,
                budgets: SubagentBudgets(maxParallelSpawns: 2),
                spawnableModelNames: [
                    "missing/model-a",
                    "missing/model-b",
                ]
            )
        )

        let callID = "spawn-permission-batch-once-\(UUID().uuidString)"
        let arguments =
            #"{"jobs":[{"id":"a","target_type":"model","target":"missing/model-a","input":"A"},{"id":"b","target_type":"model","target":"missing/model-b","input":"B"}]}"#
        let residentsBefore = await ModelRuntime.shared.residentModelNames().sorted()
        let probe = SpawnPromptProbe()
        let result = try await ChatExecutionContext.$currentSessionId.withValue(
            "spawn-permission-batch"
        ) {
            try await ChatExecutionContext.$currentToolCallId.withValue(callID) {
                try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
                    try await SpawnPermissionGate.$promptOverride.withValue(
                        { request in
                            await probe.record(request, returning: .allowOnce)
                        }
                    ) {
                        try await SpawnBatchTool().execute(argumentsJSON: arguments)
                    }
                }
            }
        }
        SubagentFeedRegistry.shared.removeNow(toolCallId: callID)

        #expect((await probe.snapshot()).requests.isEmpty)
        #expect(ToolEnvelope.isError(result))
        #expect(
            ToolEnvelope.failureMessage(result).contains(
                "No batch jobs were started because target validation failed"
            )
        )
        #expect(await ModelRuntime.shared.residentModelNames().sorted() == residentsBefore)
    }

    @Test("spawn batch asks exactly once after all targets validate")
    func batchAsksExactlyOnceAfterValidation() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-permission-batch-one-prompt")
        defer { lease.release() }

        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(.ask, for: SubagentCapabilityRegistry.spawn.id)
        SubagentConfigurationStore.save(
            SubagentConfiguration(
                permissionDefaults: permissions,
                budgets: SubagentBudgets(maxParallelSpawns: 2),
                spawnableModelNames: [
                    "allowed/model-a",
                    "allowed/model-b",
                ]
            )
        )

        let callID = "spawn-permission-batch-one-prompt-\(UUID().uuidString)"
        let arguments =
            #"{"jobs":[{"id":"a","target_type":"model","target":"allowed/model-a","input":"A"},{"id":"b","target_type":"model","target":"allowed/model-b","input":"B"}]}"#
        let residentsBefore = await ModelRuntime.shared.residentModelNames().sorted()
        let probe = SpawnPromptProbe()
        let result = try await ChatExecutionContext.$currentSessionId.withValue(
            "spawn-permission-batch-one-prompt"
        ) {
            try await ChatExecutionContext.$currentToolCallId.withValue(callID) {
                try await ChatExecutionContext.$currentAgentId.withValue(
                    Agent.defaultId
                ) {
                    try await SpawnBatchTool.$modelOverrideForTests.withValue(
                        "test/forced-model"
                    ) {
                        try await SpawnPermissionGate.$promptOverride.withValue(
                            { request in
                                await probe.record(request, returning: .deny)
                            }
                        ) {
                            try await SpawnBatchTool().execute(
                                argumentsJSON: arguments
                            )
                        }
                    }
                }
            }
        }
        SubagentFeedRegistry.shared.removeNow(toolCallId: callID)

        #expect((await probe.snapshot()).requests.count == 1)
        #expect(ToolEnvelope.isError(result))
        #expect(ToolEnvelope.failureMessage(result).contains("denied"))
        #expect(await ModelRuntime.shared.residentModelNames().sorted() == residentsBefore)
    }

    @Test("batch Stop cancels and drains its one prompt after target validation")
    func batchStopCancelsPromptWithoutLoading() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-permission-batch-stop")
        defer { lease.release() }

        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(.ask, for: SubagentCapabilityRegistry.spawn.id)
        SubagentConfigurationStore.save(
            SubagentConfiguration(
                permissionDefaults: permissions,
                budgets: SubagentBudgets(maxParallelSpawns: 2),
                spawnableModelNames: [
                    "allowed/model-a",
                    "allowed/model-b",
                ]
            )
        )

        let callID = "spawn-permission-batch-stop-\(UUID().uuidString)"
        let arguments =
            #"{"jobs":[{"id":"a","target_type":"model","target":"allowed/model-a","input":"A"},{"id":"b","target_type":"model","target":"allowed/model-b","input":"B"}]}"#
        let residentsBefore = await ModelRuntime.shared.residentModelNames().sorted()
        let probe = SpawnPromptProbe()
        let execution = Task {
            try await ChatExecutionContext.$currentSessionId.withValue(
                "spawn-permission-batch-stop"
            ) {
                try await ChatExecutionContext.$currentToolCallId.withValue(callID) {
                    try await ChatExecutionContext.$currentAgentId.withValue(
                        Agent.defaultId
                    ) {
                        try await SpawnBatchTool.$modelOverrideForTests.withValue(
                            "test/forced-model"
                        ) {
                            try await SpawnPermissionGate.$promptOverride.withValue(
                                { request in
                                    try await probe.suspendUntilCancelled(request)
                                }
                            ) {
                                try await SpawnBatchTool().execute(
                                    argumentsJSON: arguments
                                )
                            }
                        }
                    }
                }
            }
        }

        await waitUntil { (await probe.snapshot()).started }
        #expect(SubagentInterruptCenter.shared.interrupt(callID))
        let result = try await execution.value
        SubagentFeedRegistry.shared.removeNow(toolCallId: callID)

        let snapshot = await probe.snapshot()
        #expect(snapshot.requests.count == 1)
        #expect(snapshot.sawCancellation)
        #expect(snapshot.finished)
        #expect(ToolEnvelope.isError(result))
        #expect(ToolEnvelope.failureMessage(result).contains("cancelled"))
        #expect(await ModelRuntime.shared.residentModelNames().sorted() == residentsBefore)
    }

    @Test("direct Stop cancels permission and never enters the subagent body")
    func directStopCancelsPermission() async {
        let callID = "spawn-permission-direct-stop-\(UUID().uuidString)"
        let probe = DirectPermissionProbe()
        let execution = Task {
            await ChatExecutionContext.$currentSessionId.withValue(
                "spawn-permission-direct-stop"
            ) {
                await ChatExecutionContext.$currentToolCallId.withValue(callID) {
                    await ChatExecutionContext.$currentAgentId.withValue(
                        Agent.defaultId
                    ) {
                        await SubagentSession.runWithVisiblePreparation(
                            DirectPermissionKind(probe: probe),
                            tool: "direct_permission_test"
                        )
                    }
                }
            }
        }

        await waitUntil { (await probe.snapshot()).permissionStarted }
        #expect(SubagentInterruptCenter.shared.interrupt(callID))
        let result = await execution.value
        SubagentFeedRegistry.shared.removeNow(toolCallId: callID)

        let snapshot = await probe.snapshot()
        #expect(snapshot.permissionCancelled)
        #expect(snapshot.permissionFinished)
        #expect(snapshot.runCount == 0)
        #expect(ToolEnvelope.isError(result))
        #expect(ToolEnvelope.failureMessage(result).contains("authorizing"))
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for asynchronous test condition")
    }
}
