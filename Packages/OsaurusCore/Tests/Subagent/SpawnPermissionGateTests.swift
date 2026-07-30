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

private actor BatchAuthorityProbe {
    private var preparationCount = 0
    private var runCount = 0

    func nextPreparation() -> Int {
        preparationCount += 1
        return preparationCount
    }

    func recordRun() {
        runCount += 1
    }

    func snapshot() -> (preparations: Int, runs: Int) {
        (preparationCount, runCount)
    }
}

private final class BatchAuthorityKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapability(
        id: "batch-authority-test",
        toolNames: ["spawn_batch"],
        gate: .delegation
    )

    private let probe: BatchAuthorityProbe
    private let onPreparation:
        (@Sendable (_ ordinal: Int) async -> Void)?

    init(
        probe: BatchAuthorityProbe,
        onPreparation:
            (@Sendable (_ ordinal: Int) async -> Void)? = nil
    ) {
        self.probe = probe
        self.onPreparation = onPreparation
    }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let ordinal = await probe.nextPreparation()
        await onPreparation?(ordinal)
        return ResolvedModel(name: "batch-authority/remote", isLocal: false)
    }

    func permission(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel
    ) async -> SubagentDecision {
        .allow
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        await probe.recordRun()
        return SubagentResult(payload: ["summary": "ran"])
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

    private static func remoteAdmissionPlan(
        jobs: Int = 1
    ) -> SubagentBatchAdmissionPlan {
        SubagentBatchAdmissionPlanner.plan(
            SubagentBatchAdmissionInput(
                localJobCount: 0,
                remoteJobCount: jobs,
                agentParallelLimit: jobs,
                engineParallelLimit: 1,
                continuousBatchingEnabled: false,
                ramSafetyEnabled: true,
                failClosedWhenEstimateUnknown: true,
                memory: nil
            )
        )
    }

    private static func batchArguments(
        targetType: String = "model",
        target: String = "allowed/model"
    ) -> String {
        """
        {"jobs":[{"id":"one","target_type":"\(targetType)","target":"\(target)","input":"Do one bounded task"}]}
        """
    }

    private static func installServerBatchLimit(
        _ value: Int,
        in sandbox: URL
    ) -> URL? {
        let previousDirectory = ServerRuntimeSettingsStore.overrideDirectory
        ServerRuntimeSettingsStore.overrideDirectory = sandbox
        ServerRuntimeSettingsStore.invalidateSnapshot()
        var settings = ServerRuntimeSettingsStore.snapshot()
        settings.concurrency.maxConcurrentSequences = value
        ServerRuntimeSettingsStore.save(settings)
        return previousDirectory
    }

    private static func restoreServerRuntimeDirectory(_ directory: URL?) {
        ServerRuntimeSettingsStore.overrideDirectory = directory
        ServerRuntimeSettingsStore.invalidateSnapshot()
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

    @Test("agent Spawn authority generations are scoped and ABA-safe")
    @MainActor
    func agentSpawnAuthorityGenerationsAreScoped() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "osaurus-spawn-agent-authority-revisions-\(UUID().uuidString)",
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

            let original = Agent(
                name: "ScopedAuthority",
                description: "before",
                systemPrompt: "stable"
            )
            AgentStore.save(original)
            AgentManager.shared.refresh()
            let baseline = AgentManager.shared.spawnAuthoritySnapshot(
                for: original.id
            ).revisions

            var presentationOnly = original
            presentationOnly.description = "after"
            AgentManager.shared.update(presentationOnly)
            let afterPresentation = AgentManager.shared
                .spawnAuthoritySnapshot(for: original.id).revisions
            #expect(afterPresentation == baseline)

            var launcherChanged = presentationOnly
            launcherChanged.settings.spawnDelegationEnabled = true
            AgentManager.shared.update(launcherChanged)
            AgentManager.shared.update(presentationOnly)
            let afterLauncherABA = AgentManager.shared
                .spawnAuthoritySnapshot(for: original.id).revisions
            #expect(afterLauncherABA.launcher == baseline.launcher + 2)
            #expect(afterLauncherABA.permission == baseline.permission)
            #expect(afterLauncherABA.target == baseline.target)

            var denied = presentationOnly
            denied.settings.subagentPermissions.setPolicy(
                .deny,
                for: SubagentCapabilityRegistry.spawn.id
            )
            AgentManager.shared.update(denied)
            AgentManager.shared.update(presentationOnly)
            let afterPermissionABA = AgentManager.shared
                .spawnAuthoritySnapshot(for: original.id).revisions
            #expect(afterPermissionABA.launcher == afterLauncherABA.launcher)
            #expect(afterPermissionABA.permission == baseline.permission + 2)
            #expect(afterPermissionABA.target == baseline.target)

            var targetChanged = presentationOnly
            targetChanged.systemPrompt = "transient"
            AgentManager.shared.update(targetChanged)
            AgentManager.shared.update(presentationOnly)
            let afterTargetABA = AgentManager.shared
                .spawnAuthoritySnapshot(for: original.id).revisions
            #expect(afterTargetABA.launcher == afterLauncherABA.launcher)
            #expect(afterTargetABA.permission == afterPermissionABA.permission)
            #expect(afterTargetABA.target == baseline.target + 2)
        }
    }

    @Test("direct spawn revalidates Ask authority and execution authority")
    @MainActor
    func directSpawnRevalidatesMutableAuthority() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "osaurus-direct-spawn-authority-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            let lease = await acquireSubagentStoreSandbox(
                "direct-spawn-authority"
            )
            defer {
                lease.release()
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            let target = Agent(
                name: "DirectAuthorityTarget",
                description: "unchanged"
            )
            AgentStore.save(target)
            AgentManager.shared.refresh()

            var askPermissions = SubagentPermissionDefaults()
            askPermissions.setPolicy(
                .ask,
                for: SubagentCapabilityRegistry.spawn.id
            )
            let immutableAskPermissions = askPermissions
            let askConfig = SubagentConfiguration(
                spawnableAgentIDs: [target.id],
                permissionDefaults: immutableAskPermissions,
                budgets: SubagentBudgets(maxParallelSpawns: 2)
            )
            SubagentConfigurationStore.save(askConfig)

            let scope = SubagentScope(
                sessionId: "direct-authority",
                toolCallId: "direct-authority",
                agentId: Agent.defaultId
            )
            let changedDuringAsk = await SpawnPermissionGate.$promptOverride
                .withValue(
                    { _ in
                        SubagentConfigurationStore.save(
                            SubagentConfiguration(
                                spawnableAgentIDs: [],
                                permissionDefaults: immutableAskPermissions,
                                budgets: SubagentBudgets(maxParallelSpawns: 2)
                            )
                        )
                        return .allowOnce
                    }
                ) {
                    await SubagentSession.prepare(
                        TextSubagentKind(
                            agentID: target.id,
                            input: "Return one bounded result.",
                            modelOverride: "eval/direct-authority"
                        ),
                        tool: SubagentCapabilityRegistry.spawnAgentToolName,
                        scope: scope
                    )
                }
            guard case .failure(let changedEnvelope) = changedDuringAsk else {
                Issue.record("Expected mutation during Ask to reject")
                return
            }
            #expect(ToolEnvelope.isError(changedEnvelope))
            #expect(
                ToolEnvelope.failureMessage(changedEnvelope).contains(
                    "changed while approval was open"
                )
            )

            // A target edit followed by a value-identical restore is still an
            // authority change. The prepared run must not accept the restored
            // final value after observing an intermediate target generation.
            SubagentConfigurationStore.save(askConfig)
            let targetABA = await SpawnPermissionGate.$promptOverride
                .withValue(
                    { _ in
                        await MainActor.run {
                            var transient = target
                            transient.systemPrompt = "transient"
                            AgentManager.shared.update(transient)
                            AgentManager.shared.update(target)
                        }
                        return .allowOnce
                    }
                ) {
                    await SubagentSession.prepare(
                        TextSubagentKind(
                            agentID: target.id,
                            input: "Return one bounded result.",
                            modelOverride: "eval/direct-authority"
                        ),
                        tool: SubagentCapabilityRegistry.spawnAgentToolName,
                        scope: scope
                    )
                }
            guard case .failure(let targetABAEnvelope) = targetABA else {
                Issue.record("Expected target edit-and-restore during Ask to reject")
                return
            }
            #expect(ToolEnvelope.isError(targetABAEnvelope))
            #expect(
                ToolEnvelope.failureMessage(targetABAEnvelope).contains(
                    "changed while approval was open"
                )
            )

            // Image and AppleScript share the same persisted configuration
            // document but cannot alter this Spawn target, budget, model, or
            // permission. Their editor save must not invalidate the approval.
            SubagentConfigurationStore.save(askConfig)
            let unrelatedApproval = await SpawnPermissionGate.$promptOverride
                .withValue(
                    { _ in
                        var unrelated = askConfig
                        unrelated.imageDelegationEnabled = true
                        unrelated.defaultImageGenerationModelId =
                            "image/unrelated"
                        unrelated.appleScriptDelegationEnabled = true
                        unrelated.defaultAppleScriptModelId =
                            "applescript/unrelated"
                        SubagentConfigurationStore.save(unrelated)
                        return .allowOnce
                    }
                ) {
                    await SubagentSession.prepare(
                        TextSubagentKind(
                            agentID: target.id,
                            input: "Return one bounded result.",
                            modelOverride: "eval/direct-authority"
                        ),
                        tool: SubagentCapabilityRegistry.spawnAgentToolName,
                        scope: scope
                    )
                }
            guard case .ready = unrelatedApproval else {
                Issue.record(
                    "Expected unrelated Image/AppleScript save to retain direct Spawn approval"
                )
                return
            }

            // The permission panel's own Ask → Always Allow persistence is an
            // expected write and must not be mistaken for an authority change.
            SubagentConfigurationStore.save(askConfig)
            let legitimateApproval = await SpawnPermissionGate.$promptOverride
                .withValue({ _ in .alwaysAllow }) {
                    await SubagentSession.prepare(
                        TextSubagentKind(
                            agentID: target.id,
                            input: "Return one bounded result.",
                            modelOverride: "eval/direct-authority"
                        ),
                        tool: SubagentCapabilityRegistry.spawnAgentToolName,
                        scope: scope
                    )
                }
            guard case .ready(let prepared) = legitimateApproval else {
                Issue.record("Expected legitimate Always Allow write to prepare")
                return
            }

            // A settings edit after prepare but before admission/model loading
            // must fail at the final execution boundary.
            var changedBudget = askConfig
            changedBudget.budgets = SubagentBudgets(
                maxDelegateTokens: 4_096,
                maxParallelSpawns: 2
            )
            SubagentConfigurationStore.save(changedBudget)
            let executionResult = await SubagentSession.runPrepared(prepared)
            #expect(ToolEnvelope.isError(executionResult))
            #expect(
                ToolEnvelope.failureMessage(executionResult).contains(
                    "changed before execution"
                )
            )
        }
    }

    @Test("direct spawn rejects a stale self target before approval")
    func directSpawnRejectsSelfTarget() async {
        let lease = await acquireSubagentStoreSandbox(
            "direct-spawn-self-target"
        )
        defer { lease.release() }

        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(
            .alwaysAllow,
            for: SubagentCapabilityRegistry.spawn.id
        )
        SubagentConfigurationStore.save(
            SubagentConfiguration(
                spawnableAgentIDs: [Agent.defaultId],
                permissionDefaults: permissions
            )
        )
        let result = await SubagentSession.prepare(
            TextSubagentKind(
                agentID: Agent.defaultId,
                input: "Return one bounded result.",
                modelOverride: "eval/self-target"
            ),
            tool: SubagentCapabilityRegistry.spawnAgentToolName,
            scope: defaultScope
        )
        guard case .failure(let envelope) = result else {
            Issue.record("Expected self-spawn to reject")
            return
        }
        #expect(ToolEnvelope.isError(envelope))
        #expect(
            ToolEnvelope.failureMessage(envelope).contains(
                "cannot spawn itself"
            )
        )
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
            let target = Agent(name: "SpawnPermissionTarget")
            settings.spawnDelegationEnabled = true
            settings.spawnableAgentIDs = [target.id]
            let agent = Agent(
                name: "SpawnPermissionCustom",
                agentAddress: "spawn-permission-\(UUID().uuidString)",
                settings: settings
            )
            AgentStore.save(target)
            AgentStore.save(agent)
            AgentManager.shared.refresh()

            let scope = SubagentScope(
                sessionId: "custom-agent-permission",
                toolCallId: "custom-agent-permission",
                agentId: agent.id
            )
            let probe = SpawnPromptProbe()
            let preparation = await SpawnPermissionGate.$promptOverride
                .withValue(
                    { request in
                        await probe.record(
                            request,
                            returning: .alwaysAllow
                        )
                    }
                ) {
                    await SubagentSession.prepare(
                        TextSubagentKind(
                            agentID: target.id,
                            input: "Return one bounded result.",
                            modelOverride: "eval/custom-always-allow"
                        ),
                        tool: SubagentCapabilityRegistry.spawnAgentToolName,
                        scope: scope
                    )
                }
            guard case .ready = preparation else {
                Issue.record(
                    "Expected custom Always Allow persistence to remain authorized"
                )
                return
            }
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
        let previousRuntimeDirectory = Self.installServerBatchLimit(2, in: lease.sandbox)
        defer {
            Self.restoreServerRuntimeDirectory(previousRuntimeDirectory)
            lease.release()
        }

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
        let previousRuntimeDirectory = Self.installServerBatchLimit(2, in: lease.sandbox)
        defer {
            Self.restoreServerRuntimeDirectory(previousRuntimeDirectory)
            lease.release()
        }

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

    @Test("unchanged post-Ask authority asks once, prepares twice, and runs once")
    func batchRevalidatesStableAuthorityExactlyOnce() async throws {
        let lease = await acquireSubagentStoreSandbox(
            "spawn-permission-batch-stable-authority"
        )
        defer { lease.release() }

        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(.ask, for: SubagentCapabilityRegistry.spawn.id)
        SubagentConfigurationStore.save(
            SubagentConfiguration(
                permissionDefaults: permissions,
                budgets: SubagentBudgets(maxParallelSpawns: 1),
                spawnableModelNames: ["allowed/model"]
            )
        )

        let probe = BatchAuthorityProbe()
        let prompt = SpawnPromptProbe()
        let overrides = SpawnBatchTool.EvaluationOverrides(
            kindForJob: { _ in BatchAuthorityKind(probe: probe) },
            maxParallel: 1,
            localParallelism: 1,
            localAdmissionPlan: Self.remoteAdmissionPlan()
        )
        let callID = "spawn-batch-stable-authority-\(UUID().uuidString)"
        let result = try await ChatExecutionContext.$currentSessionId.withValue(
            "spawn-batch-stable-authority"
        ) {
            try await ChatExecutionContext.$currentToolCallId.withValue(callID) {
                try await ChatExecutionContext.$currentAgentId.withValue(
                    Agent.defaultId
                ) {
                    try await SpawnBatchTool.$evaluationOverrides.withValue(
                        overrides
                    ) {
                        try await SpawnPermissionGate.$promptOverride.withValue(
                            { request in
                                await prompt.record(
                                    request,
                                    returning: .allowOnce
                                )
                            }
                        ) {
                            try await SpawnBatchTool().execute(
                                argumentsJSON: Self.batchArguments()
                            )
                        }
                    }
                }
            }
        }
        SubagentFeedRegistry.shared.removeNow(toolCallId: callID)

        let execution = await probe.snapshot()
        #expect((await prompt.snapshot()).requests.count == 1)
        #expect(execution.preparations == 2)
        #expect(execution.runs == 1)
        #expect(!ToolEnvelope.isError(result))
    }

    @Test("batch rejects authority mutation while Ask is open before re-preparing")
    func batchRejectsAuthorityMutationDuringAsk() async throws {
        let lease = await acquireSubagentStoreSandbox(
            "spawn-permission-batch-panel-authority"
        )
        defer { lease.release() }

        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(.ask, for: SubagentCapabilityRegistry.spawn.id)
        let configuration = SubagentConfiguration(
            permissionDefaults: permissions,
            budgets: SubagentBudgets(maxParallelSpawns: 1),
            spawnableModelNames: ["allowed/model"]
        )
        SubagentConfigurationStore.save(configuration)

        let probe = BatchAuthorityProbe()
        let prompt = SpawnPromptProbe()
        let overrides = SpawnBatchTool.EvaluationOverrides(
            kindForJob: { _ in BatchAuthorityKind(probe: probe) },
            maxParallel: 1,
            localParallelism: 1,
            localAdmissionPlan: Self.remoteAdmissionPlan()
        )
        let callID =
            "spawn-batch-panel-authority-\(UUID().uuidString)"
        let result = try await ChatExecutionContext.$currentSessionId.withValue(
            "spawn-batch-panel-authority"
        ) {
            try await ChatExecutionContext.$currentToolCallId.withValue(callID) {
                try await ChatExecutionContext.$currentAgentId.withValue(
                    Agent.defaultId
                ) {
                    try await SpawnBatchTool.$evaluationOverrides.withValue(
                        overrides
                    ) {
                        try await SpawnPermissionGate.$promptOverride.withValue(
                            { request in
                                let choice = await prompt.record(
                                    request,
                                    returning: .allowOnce
                                )
                                var changed = configuration
                                changed.budgets = SubagentBudgets(
                                    maxDelegateTokens: 4_096,
                                    maxParallelSpawns: 1
                                )
                                SubagentConfigurationStore.save(changed)
                                return choice
                            }
                        ) {
                            try await SpawnBatchTool().execute(
                                argumentsJSON: Self.batchArguments()
                            )
                        }
                    }
                }
            }
        }
        SubagentFeedRegistry.shared.removeNow(toolCallId: callID)

        let execution = await probe.snapshot()
        #expect((await prompt.snapshot()).requests.count == 1)
        #expect(execution.preparations == 1)
        #expect(execution.runs == 0)
        #expect(ToolEnvelope.isError(result))
        #expect(
            ToolEnvelope.failureMessage(result).contains(
                "changed while approval was open"
            )
        )
        let root = try #require(
            JSONSerialization.jsonObject(
                with: Data(result.utf8)
            ) as? [String: Any]
        )
        #expect(root["kind"] as? String == "rejected")
    }

    @Test("batch ignores unrelated Image and AppleScript saves during Ask")
    func batchAllowsUnrelatedConfigurationSaveDuringAsk() async throws {
        let lease = await acquireSubagentStoreSandbox(
            "spawn-permission-batch-unrelated-authority"
        )
        defer { lease.release() }

        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(.ask, for: SubagentCapabilityRegistry.spawn.id)
        let configuration = SubagentConfiguration(
            permissionDefaults: permissions,
            budgets: SubagentBudgets(maxParallelSpawns: 1),
            spawnableModelNames: ["allowed/model"]
        )
        SubagentConfigurationStore.save(configuration)

        let probe = BatchAuthorityProbe()
        let prompt = SpawnPromptProbe()
        let overrides = SpawnBatchTool.EvaluationOverrides(
            kindForJob: { _ in BatchAuthorityKind(probe: probe) },
            maxParallel: 1,
            localParallelism: 1,
            localAdmissionPlan: Self.remoteAdmissionPlan()
        )
        let callID =
            "spawn-batch-unrelated-authority-\(UUID().uuidString)"
        let result = try await ChatExecutionContext.$currentSessionId.withValue(
            "spawn-batch-unrelated-authority"
        ) {
            try await ChatExecutionContext.$currentToolCallId.withValue(callID) {
                try await ChatExecutionContext.$currentAgentId.withValue(
                    Agent.defaultId
                ) {
                    try await SpawnBatchTool.$evaluationOverrides.withValue(
                        overrides
                    ) {
                        try await SpawnPermissionGate.$promptOverride.withValue(
                            { request in
                                let choice = await prompt.record(
                                    request,
                                    returning: .allowOnce
                                )
                                var unrelated = configuration
                                unrelated.imageDelegationEnabled = true
                                unrelated.defaultImageGenerationModelId =
                                    "image/unrelated"
                                unrelated.appleScriptDelegationEnabled = true
                                unrelated.defaultAppleScriptModelId =
                                    "applescript/unrelated"
                                SubagentConfigurationStore.save(unrelated)
                                return choice
                            }
                        ) {
                            try await SpawnBatchTool().execute(
                                argumentsJSON: Self.batchArguments()
                            )
                        }
                    }
                }
            }
        }
        SubagentFeedRegistry.shared.removeNow(toolCallId: callID)

        let execution = await probe.snapshot()
        #expect((await prompt.snapshot()).requests.count == 1)
        #expect(execution.preparations == 2)
        #expect(execution.runs == 1)
        #expect(!ToolEnvelope.isError(result))
    }

    @Test("batch accepts its own Ask to Always Allow persistence once")
    func batchAcceptsAlwaysAllowPersistence() async throws {
        let lease = await acquireSubagentStoreSandbox(
            "spawn-permission-batch-always-allow"
        )
        defer { lease.release() }

        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(.ask, for: SubagentCapabilityRegistry.spawn.id)
        SubagentConfigurationStore.save(
            SubagentConfiguration(
                permissionDefaults: permissions,
                budgets: SubagentBudgets(maxParallelSpawns: 1),
                spawnableModelNames: ["allowed/model"]
            )
        )
        let revisionBefore = SubagentConfigurationStore.revision()

        let probe = BatchAuthorityProbe()
        let prompt = SpawnPromptProbe()
        let overrides = SpawnBatchTool.EvaluationOverrides(
            kindForJob: { _ in BatchAuthorityKind(probe: probe) },
            maxParallel: 1,
            localParallelism: 1,
            localAdmissionPlan: Self.remoteAdmissionPlan()
        )
        let callID =
            "spawn-batch-always-allow-\(UUID().uuidString)"
        let result = try await ChatExecutionContext.$currentSessionId.withValue(
            "spawn-batch-always-allow"
        ) {
            try await ChatExecutionContext.$currentToolCallId.withValue(callID) {
                try await ChatExecutionContext.$currentAgentId.withValue(
                    Agent.defaultId
                ) {
                    try await SpawnBatchTool.$evaluationOverrides.withValue(
                        overrides
                    ) {
                        try await SpawnPermissionGate.$promptOverride.withValue(
                            { request in
                                await prompt.record(
                                    request,
                                    returning: .alwaysAllow
                                )
                            }
                        ) {
                            try await SpawnBatchTool().execute(
                                argumentsJSON: Self.batchArguments()
                            )
                        }
                    }
                }
            }
        }
        SubagentFeedRegistry.shared.removeNow(toolCallId: callID)

        let execution = await probe.snapshot()
        let live = SubagentConfigurationStore.snapshot()
        #expect((await prompt.snapshot()).requests.count == 1)
        #expect(execution.preparations == 2)
        #expect(execution.runs == 1)
        #expect(!ToolEnvelope.isError(result))
        #expect(
            live.permissionDefaults.policy(
                for: SubagentCapabilityRegistry.spawn.id
            ) == .alwaysAllow
        )
        #expect(
            SubagentConfigurationStore.revision()
                == revisionBefore &+ 1
        )
    }

    @Test("custom batch accepts its own Ask to Always Allow agent persistence")
    @MainActor
    func batchAcceptsCustomAlwaysAllowPersistence() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "osaurus-custom-batch-always-allow-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            let lease = await acquireSubagentStoreSandbox(
                "custom-batch-always-allow"
            )
            defer {
                lease.release()
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            let target = Agent(
                name: "CustomAlwaysAllowTarget",
                defaultModel: "target/model"
            )
            var permissions = SubagentPermissionDefaults()
            permissions.setPolicy(
                .ask,
                for: SubagentCapabilityRegistry.spawn.id
            )
            var launcherSettings = AgentSettings.defaultDisabled
            launcherSettings.spawnDelegationEnabled = true
            launcherSettings.spawnableAgentIDs = [target.id]
            launcherSettings.subagentPermissions = permissions
            launcherSettings.subagentBudgets = SubagentBudgets(
                maxParallelSpawns: 1
            )
            let launcher = Agent(
                name: "CustomAlwaysAllowLauncher",
                settings: launcherSettings
            )
            AgentStore.save(target)
            AgentStore.save(launcher)
            AgentManager.shared.refresh()
            let revisionBefore = SubagentConfigurationStore.revision()

            let probe = BatchAuthorityProbe()
            let prompt = SpawnPromptProbe()
            let overrides = SpawnBatchTool.EvaluationOverrides(
                kindForJob: { _ in BatchAuthorityKind(probe: probe) },
                maxParallel: 1,
                localParallelism: 1,
                localAdmissionPlan: Self.remoteAdmissionPlan()
            )
            let callID =
                "custom-batch-always-allow-\(UUID().uuidString)"
            let result = try await ChatExecutionContext.$currentSessionId
                .withValue("custom-batch-always-allow") {
                    try await ChatExecutionContext.$currentToolCallId.withValue(
                        callID
                    ) {
                        try await ChatExecutionContext.$currentAgentId.withValue(
                            launcher.id
                        ) {
                            try await SpawnBatchTool.$evaluationOverrides
                                .withValue(overrides) {
                                    try await SpawnPermissionGate.$promptOverride
                                        .withValue(
                                            { request in
                                                await prompt.record(
                                                    request,
                                                    returning: .alwaysAllow
                                                )
                                            }
                                        ) {
                                            try await SpawnBatchTool().execute(
                                                argumentsJSON:
                                                    Self.batchArguments(
                                                        targetType: "agent",
                                                        target:
                                                            target.id.uuidString
                                                    )
                                            )
                                        }
                                }
                        }
                    }
                }
            SubagentFeedRegistry.shared.removeNow(toolCallId: callID)

            let execution = await probe.snapshot()
            let live = try #require(
                AgentManager.shared.agent(for: launcher.id)
            )
            #expect((await prompt.snapshot()).requests.count == 1)
            #expect(execution.preparations == 2)
            #expect(execution.runs == 1)
            #expect(!ToolEnvelope.isError(result))
            #expect(
                live.settings.subagentPermissions.policy(
                    for: SubagentCapabilityRegistry.spawn.id
                ) == .alwaysAllow
            )
            #expect(
                SubagentConfigurationStore.revision() == revisionBefore
            )
        }
    }

    @Test("an ABA config save during post-Ask preparation rejects before every run")
    func batchRejectsABAAuthorityChangeDuringRevalidation() async throws {
        let lease = await acquireSubagentStoreSandbox(
            "spawn-permission-batch-aba-authority"
        )
        defer { lease.release() }

        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(.ask, for: SubagentCapabilityRegistry.spawn.id)
        let configuration = SubagentConfiguration(
            permissionDefaults: permissions,
            budgets: SubagentBudgets(maxParallelSpawns: 1),
            spawnableModelNames: ["allowed/model"]
        )
        SubagentConfigurationStore.save(configuration)
        let revisionBefore = SubagentConfigurationStore.revision()

        let probe = BatchAuthorityProbe()
        let prompt = SpawnPromptProbe()
        let overrides = SpawnBatchTool.EvaluationOverrides(
            kindForJob: { _ in
                BatchAuthorityKind(
                    probe: probe,
                    onPreparation: { ordinal in
                        guard ordinal == 2 else { return }
                        // Change and restore Spawn-relevant authority while the
                        // second preparation is in flight. Final value equality
                        // cannot detect this ABA; the scoped monotonic Spawn
                        // revision must.
                        var changed = configuration
                        changed.budgets = SubagentBudgets(
                            maxDelegateTokens: 4_096,
                            maxParallelSpawns: 1
                        )
                        SubagentConfigurationStore.save(changed)
                        SubagentConfigurationStore.save(configuration)
                    }
                )
            },
            maxParallel: 1,
            localParallelism: 1,
            localAdmissionPlan: Self.remoteAdmissionPlan()
        )
        let callID = "spawn-batch-aba-authority-\(UUID().uuidString)"
        let result = try await ChatExecutionContext.$currentSessionId.withValue(
            "spawn-batch-aba-authority"
        ) {
            try await ChatExecutionContext.$currentToolCallId.withValue(callID) {
                try await ChatExecutionContext.$currentAgentId.withValue(
                    Agent.defaultId
                ) {
                    try await SpawnBatchTool.$evaluationOverrides.withValue(
                        overrides
                    ) {
                        try await SpawnPermissionGate.$promptOverride.withValue(
                            { request in
                                await prompt.record(
                                    request,
                                    returning: .allowOnce
                                )
                            }
                        ) {
                            try await SpawnBatchTool().execute(
                                argumentsJSON: Self.batchArguments()
                            )
                        }
                    }
                }
            }
        }
        SubagentFeedRegistry.shared.removeNow(toolCallId: callID)

        let execution = await probe.snapshot()
        #expect((await prompt.snapshot()).requests.count == 1)
        #expect(execution.preparations == 2)
        #expect(execution.runs == 0)
        #expect(SubagentConfigurationStore.revision() > revisionBefore)
        #expect(ToolEnvelope.isError(result))
        #expect(
            ToolEnvelope.failureMessage(result).contains(
                "changed after approval"
            )
        )
        let root = try #require(
            JSONSerialization.jsonObject(
                with: Data(result.utf8)
            ) as? [String: Any]
        )
        #expect(root["kind"] as? String == "rejected")
    }

    @Test("custom launcher disabled during Ask is denied with its target UUID retained")
    @MainActor
    func batchRejectsLauncherDisabledDuringApproval() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "osaurus-spawn-batch-launcher-revocation-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            let lease = await acquireSubagentStoreSandbox(
                "spawn-batch-launcher-revocation"
            )
            defer {
                lease.release()
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            let target = Agent(
                name: "RetainedTarget",
                defaultModel: "target/model"
            )
            var permissions = SubagentPermissionDefaults()
            permissions.setPolicy(
                .ask,
                for: SubagentCapabilityRegistry.spawn.id
            )
            var launcherSettings = AgentSettings.defaultDisabled
            launcherSettings.spawnDelegationEnabled = true
            launcherSettings.spawnableAgentIDs = [target.id]
            launcherSettings.subagentPermissions = permissions
            launcherSettings.subagentBudgets = SubagentBudgets(
                maxParallelSpawns: 1
            )
            let launcher = Agent(
                name: "RevokedLauncher",
                settings: launcherSettings
            )
            AgentStore.save(target)
            AgentStore.save(launcher)
            AgentManager.shared.refresh()

            let prompt = SpawnPromptProbe()
            let callID =
                "spawn-batch-launcher-revocation-\(UUID().uuidString)"
            let result = try await ChatExecutionContext.$currentSessionId
                .withValue("spawn-batch-launcher-revocation") {
                    try await ChatExecutionContext.$currentToolCallId.withValue(
                        callID
                    ) {
                        try await ChatExecutionContext.$currentAgentId.withValue(
                            launcher.id
                        ) {
                            try await SpawnBatchTool.$modelOverrideForTests
                                .withValue("test/forced-model") {
                                    try await SpawnPermissionGate.$promptOverride
                                        .withValue(
                                            { request in
                                                _ = await prompt.record(
                                                    request,
                                                    returning: .allowOnce
                                                )
                                                await MainActor.run {
                                                    guard var current =
                                                        AgentManager.shared.agent(
                                                            for: launcher.id
                                                        )
                                                    else { return }
                                                    current.settings
                                                        .spawnDelegationEnabled =
                                                        false
                                                    // Deliberately retain the
                                                    // UUID: the enable gate,
                                                    // not list membership, is
                                                    // the revoked authority.
                                                    current.settings
                                                        .spawnableAgentIDs = [
                                                            target.id
                                                        ]
                                                    AgentManager.shared.update(
                                                        current
                                                    )
                                                }
                                                return .allowOnce
                                            }
                                        ) {
                                            try await SpawnBatchTool().execute(
                                                argumentsJSON: Self.batchArguments(
                                                    targetType: "agent",
                                                    target: target.id.uuidString
                                                )
                                            )
                                        }
                                }
                        }
                    }
                }
            SubagentFeedRegistry.shared.removeNow(toolCallId: callID)

            let live = try #require(
                AgentManager.shared.agent(for: launcher.id)
            )
            #expect((await prompt.snapshot()).requests.count == 1)
            #expect(!live.settings.spawnDelegationEnabled)
            #expect(live.settings.spawnableAgentIDs == [target.id])
            #expect(ToolEnvelope.isError(result))
            #expect(
                ToolEnvelope.failureMessage(result).contains(
                    "changed while approval was open"
                )
            )
        }
    }

    @Test("target-agent edit and restore during post-Ask preparation rejects before run")
    @MainActor
    func batchRejectsTargetABADuringRevalidation() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "osaurus-spawn-batch-target-edit-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            let lease = await acquireSubagentStoreSandbox(
                "spawn-batch-target-edit"
            )
            defer {
                lease.release()
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }

            let target = Agent(
                name: "EditedTarget",
                description: "before"
            )
            AgentStore.save(target)
            AgentManager.shared.refresh()

            var permissions = SubagentPermissionDefaults()
            permissions.setPolicy(
                .ask,
                for: SubagentCapabilityRegistry.spawn.id
            )
            SubagentConfigurationStore.save(
                SubagentConfiguration(
                    spawnableAgentIDs: [target.id],
                    permissionDefaults: permissions,
                    budgets: SubagentBudgets(maxParallelSpawns: 1)
                )
            )

            let probe = BatchAuthorityProbe()
            let prompt = SpawnPromptProbe()
            let overrides = SpawnBatchTool.EvaluationOverrides(
                kindForJob: { _ in
                    BatchAuthorityKind(
                        probe: probe,
                        onPreparation: { ordinal in
                            guard ordinal == 2 else { return }
                            await MainActor.run {
                                guard var current =
                                    AgentManager.shared.agent(for: target.id)
                                else { return }
                                current.systemPrompt = "after"
                                AgentManager.shared.update(current)
                                AgentManager.shared.update(target)
                            }
                        }
                    )
                },
                maxParallel: 1,
                localParallelism: 1,
                localAdmissionPlan: Self.remoteAdmissionPlan()
            )
            let callID = "spawn-batch-target-edit-\(UUID().uuidString)"
            let result = try await ChatExecutionContext.$currentSessionId
                .withValue("spawn-batch-target-edit") {
                    try await ChatExecutionContext.$currentToolCallId.withValue(
                        callID
                    ) {
                        try await ChatExecutionContext.$currentAgentId.withValue(
                            Agent.defaultId
                        ) {
                            try await SpawnBatchTool.$evaluationOverrides
                                .withValue(overrides) {
                                    try await SpawnPermissionGate.$promptOverride
                                        .withValue(
                                            { request in
                                                await prompt.record(
                                                    request,
                                                    returning: .allowOnce
                                                )
                                            }
                                        ) {
                                            try await SpawnBatchTool().execute(
                                                argumentsJSON: Self.batchArguments(
                                                    targetType: "agent",
                                                    target: target.id.uuidString
                                                )
                                            )
                                        }
                                }
                        }
                    }
                }
            SubagentFeedRegistry.shared.removeNow(toolCallId: callID)

            let execution = await probe.snapshot()
            #expect((await prompt.snapshot()).requests.count == 1)
            #expect(execution.preparations == 2)
            #expect(execution.runs == 0)
            #expect(
                AgentManager.shared.agent(for: target.id)?.systemPrompt
                    == target.systemPrompt
            )
            #expect(ToolEnvelope.isError(result))
            #expect(
                ToolEnvelope.failureMessage(result).contains(
                    "changed after approval"
                )
            )
        }
    }

    @Test("batch Stop cancels and drains its one prompt after target validation")
    func batchStopCancelsPromptWithoutLoading() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-permission-batch-stop")
        let previousRuntimeDirectory = Self.installServerBatchLimit(2, in: lease.sandbox)
        defer {
            Self.restoreServerRuntimeDirectory(previousRuntimeDirectory)
            lease.release()
        }

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
        #expect(result.contains(#""cancelled":true"#))
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
        #expect(ToolEnvelope.failureMessage(result).contains("authorization"))
        #expect(result.contains(#""cancelled":true"#))
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
