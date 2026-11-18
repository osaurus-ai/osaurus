//
//  SandboxToolRegistrarAttributionTests.swift
//  OsaurusCoreTests
//
//  Pins how `SandboxToolRegistrar` attributes provisioning failures to the
//  closed telemetry vocabulary:
//
//   * A `startReentry` step failure (the container was NOT usable even
//     though the cached status said `.running`) is recorded as a runtime
//     start failure, never as `agent_provision_failed`.
//   * Bootstrap step failures refine the `agent_provision` phase and carry
//     the error class of the underlying throw.
//   * The cool-down branch that other agents hit after a startup failure
//     records unavailability locally but does not emit a second sample.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SandboxToolRegistrarAttributionTests {

    private struct Fixture {
        let agent: Agent
        let originalActiveAgentId: UUID
        let originalStatus: ContainerStatus
        let originalSandboxConfig: SandboxConfiguration
        let originalProvisionOverride: ((UUID) async throws -> Void)?
        let originalProbeOverride: (() async -> Bool)?
        let originalStartOverride: (() async throws -> Void)?
    }

    private func clearFailureStore() {
        try? FileManager.default.removeItem(
            at: OsaurusPaths.container().appendingPathComponent("startup-failures.json")
        )
    }

    private func makeFixture(name: String) -> Fixture {
        let manager = AgentManager.shared
        let registrar = SandboxToolRegistrar.shared
        let fixture = Fixture(
            agent: Agent(
                name: "\(name) \(UUID().uuidString)",
                agentAddress: "test-attrib-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: true)
            ),
            originalActiveAgentId: manager.activeAgentId,
            originalStatus: SandboxManager.State.shared.status,
            originalSandboxConfig: SandboxConfigurationStore.load(),
            originalProvisionOverride: registrar.provisionAgentOverride,
            originalProbeOverride: registrar.runtimeProbeOverride,
            originalStartOverride: registrar.containerStartOverride
        )
        manager.add(fixture.agent)
        // A previously set-up sandbox: warm restarts allowed, cold_start=false.
        var config = SandboxConfiguration.default
        config.setupComplete = true
        SandboxConfigurationStore.save(config)
        SandboxManager.State.shared.status = .running
        registrar.resetStartupFailures()
        ToolRegistry.shared.unregisterAllBuiltinSandboxTools()
        clearFailureStore()
        return fixture
    }

    /// Clear the agent's failure record by letting one registration succeed,
    /// so the registrar's 5 s provisioning auto-retry (armed by a
    /// `provisioningFailed` outcome) finds nothing to retry after the test
    /// has restored the real provisioner.
    private func settle(_ fixture: Fixture) async {
        let registrar = SandboxToolRegistrar.shared
        registrar.provisionAgentOverride = { @MainActor _ in }
        SandboxManager.State.shared.status = .running
        await registrar.registerTools(for: fixture.agent.id)
        #expect(registrar.unavailabilityReason(for: fixture.agent.id) == nil)
    }

    private func tearDown(_ fixture: Fixture) async {
        let registrar = SandboxToolRegistrar.shared
        ToolRegistry.shared.unregisterAllSandboxTools()
        registrar.provisionAgentOverride = fixture.originalProvisionOverride
        registrar.runtimeProbeOverride = fixture.originalProbeOverride
        registrar.containerStartOverride = fixture.originalStartOverride
        registrar.resetStartupFailures()
        SandboxManager.State.shared.status = fixture.originalStatus
        SandboxConfigurationStore.save(fixture.originalSandboxConfig)
        AgentManager.shared.setActiveAgent(fixture.originalActiveAgentId)
        _ = await AgentManager.shared.delete(id: fixture.agent.id)
        clearFailureStore()
    }

    // MARK: - startReentry reroute + cool-down dedupe

    @Test
    func startReentryFailure_isAttributedAsRuntimeStart_andCoolDownDoesNotReemit() async {
        await SandboxTestLock.runWithStoragePaths {
            let registrar = SandboxToolRegistrar.shared
            let fixture = makeFixture(name: "Reentry")

            registrar.provisionAgentOverride = { @MainActor _ in
                throw SandboxProvisionStepError(
                    step: .startReentry,
                    underlying: SandboxError.startFailed(
                        "Stale sandbox state on disk",
                        underlying: POSIXError(.EEXIST)
                    )
                )
            }

            await registrar.registerTools(for: fixture.agent.id, trigger: .onDemand)

            let reason = registrar.unavailabilityReason(for: fixture.agent.id)
            #expect(reason?.kind == .startupFailed)
            #expect(reason?.message.contains("could not be started") == true)

            let samples = SandboxStartupMetricsStore.loadFailures()
            #expect(samples.count == 1)
            #expect(samples.last?.category == "runtime_start_failed")
            #expect(samples.last?.phase == "runtime_start")
            #expect(samples.last?.errorClass == "posix_eexist")
            #expect(samples.last?.trigger == "on_demand")
            #expect(samples.last?.coldStart == false)

            // A second agent registering while the cool-down is armed gets
            // its own unavailability record for the UI/prompt, but the
            // underlying boot failure was already counted once.
            let bystander = Agent(
                name: "Bystander \(UUID().uuidString)",
                agentAddress: "test-attrib-bystander-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: true)
            )
            AgentManager.shared.add(bystander)
            SandboxManager.State.shared.status = .stopped
            await registrar.registerTools(for: bystander.id, trigger: .agentSwitch)

            #expect(registrar.unavailabilityReason(for: bystander.id)?.kind == .startupFailed)
            #expect(
                registrar.unavailabilityReason(for: bystander.id)?.message.contains("cool-down")
                    == true
            )
            #expect(SandboxStartupMetricsStore.loadFailures().count == 1)

            _ = await AgentManager.shared.delete(id: bystander.id)
            // The startup failure armed the cool-down; reset so `settle`
            // can reach the provision path again.
            registrar.resetStartupFailures()
            await settle(fixture)
            await tearDown(fixture)
        }
    }

    // MARK: - Cancellation

    @Test
    func cancelledStart_isNotRecordedAsAFailure() async {
        await SandboxTestLock.runWithStoragePaths {
            let registrar = SandboxToolRegistrar.shared
            let fixture = makeFixture(name: "CancelledStart")

            registrar.containerStartOverride = { throw CancellationError() }
            SandboxManager.State.shared.status = .stopped
            await registrar.registerTools(for: fixture.agent.id, trigger: .onDemand)

            #expect(registrar.unavailabilityReason(for: fixture.agent.id) == nil)
            #expect(SandboxStartupMetricsStore.loadFailures().isEmpty)

            registrar.containerStartOverride = fixture.originalStartOverride
            await settle(fixture)
            await tearDown(fixture)
        }
    }

    @Test
    func cancelledProvision_isNotRecordedAsAFailure() async {
        await SandboxTestLock.runWithStoragePaths {
            let registrar = SandboxToolRegistrar.shared
            let fixture = makeFixture(name: "CancelledProvision")

            registrar.provisionAgentOverride = { @MainActor _ in
                throw SandboxProvisionStepError(step: .startReentry, underlying: CancellationError())
            }
            await registrar.registerTools(for: fixture.agent.id, trigger: .onDemand)

            #expect(registrar.unavailabilityReason(for: fixture.agent.id) == nil)
            #expect(SandboxStartupMetricsStore.loadFailures().isEmpty)

            await settle(fixture)
            await tearDown(fixture)
        }
    }

    // MARK: - Bootstrap step refinement

    @Test
    func bootstrapScriptFailure_refinesPhaseAndErrorClass() async {
        await SandboxTestLock.runWithStoragePaths {
            let registrar = SandboxToolRegistrar.shared
            let fixture = makeFixture(name: "Script")

            registrar.provisionAgentOverride = { @MainActor _ in
                throw SandboxProvisionStepError(
                    step: .bootstrapScript,
                    underlying: SandboxError.userCreationFailed("adduser: user exists")
                )
            }

            await registrar.registerTools(for: fixture.agent.id, trigger: .agentSwitch)

            let reason = registrar.unavailabilityReason(for: fixture.agent.id)
            #expect(reason?.kind == .provisioningFailed)
            #expect(reason?.message.contains("adduser: user exists") == true)

            let samples = SandboxStartupMetricsStore.loadFailures()
            #expect(samples.count == 1)
            #expect(samples.last?.category == "agent_provision_failed")
            #expect(samples.last?.phase == "agent_provision.bootstrap_script")
            #expect(samples.last?.errorClass == "sandbox_user_creation_failed")
            #expect(samples.last?.trigger == "agent_switch")

            await settle(fixture)
            await tearDown(fixture)
        }
    }

    @Test
    func bootstrapTimeout_refinesPhase() async {
        await SandboxTestLock.runWithStoragePaths {
            let registrar = SandboxToolRegistrar.shared
            let fixture = makeFixture(name: "Timeout")

            registrar.provisionAgentOverride = { @MainActor _ in
                throw SandboxProvisionStepError(step: .bootstrapTimeout, underlying: SandboxError.timeout)
            }

            await registrar.registerTools(for: fixture.agent.id)

            #expect(registrar.unavailabilityReason(for: fixture.agent.id)?.kind == .provisioningFailed)
            let samples = SandboxStartupMetricsStore.loadFailures()
            #expect(samples.last?.phase == "agent_provision.bootstrap_timeout")
            #expect(samples.last?.errorClass == "sandbox_timeout")
            #expect(samples.last?.trigger == "external")

            await settle(fixture)
            await tearDown(fixture)
        }
    }

    @Test
    func bootstrapExecFailure_withLiveGuest_isAProvisionFailureNotARecovery() async {
        await SandboxTestLock.runWithStoragePaths {
            let registrar = SandboxToolRegistrar.shared
            let fixture = makeFixture(name: "Exec")

            final class Counter: @unchecked Sendable {
                var provisionCalls = 0
                var probeCalls = 0
            }
            let counter = Counter()
            registrar.provisionAgentOverride = { @MainActor _ in
                counter.provisionCalls += 1
                throw SandboxProvisionStepError(
                    step: .bootstrapExec,
                    underlying: SandboxError.containerNotRunning
                )
            }
            // Guest answers the liveness probe: the exec failure is real,
            // so no runtime recovery (which would re-boot) must be attempted.
            registrar.runtimeProbeOverride = {
                counter.probeCalls += 1
                return true
            }

            await registrar.registerTools(for: fixture.agent.id)

            #expect(counter.provisionCalls == 1)
            #expect(registrar.unavailabilityReason(for: fixture.agent.id)?.kind == .provisioningFailed)
            let samples = SandboxStartupMetricsStore.loadFailures()
            #expect(samples.count == 1)
            #expect(samples.last?.phase == "agent_provision.bootstrap_exec")
            #expect(samples.last?.errorClass == "sandbox_container_not_running")
            // Recovery is a VM-backend concern; on a Seatbelt host the probe
            // is never consulted.
            if SandboxBackend.current == .virtualMachine {
                #expect(counter.probeCalls == 1)
            } else {
                #expect(counter.probeCalls == 0)
            }

            await settle(fixture)
            await tearDown(fixture)
        }
    }

    // MARK: - Dead guest behind a cached `.running` status

    /// The VM died (sleep/wake, crash) but `State.shared.status` still says
    /// `.running`. Before this fix the failed bootstrap exec landed in
    /// `agent_provision_failed`; now the registrar probes the guest, marks
    /// the runtime lost, re-boots once, and provisions on the fresh runtime
    /// without recording any failure.
    @Test
    func bootstrapExecFailure_withDeadGuest_rebootsOnceAndRecovers() async {
        await SandboxTestLock.runWithStoragePaths {
            guard SandboxBackend.current == .virtualMachine else { return }
            let registrar = SandboxToolRegistrar.shared
            let fixture = makeFixture(name: "DeadGuest")

            final class Counter: @unchecked Sendable {
                var provisionCalls = 0
                var probeCalls = 0
                var startCalls = 0
                var statusAtStart: ContainerStatus?
            }
            let counter = Counter()
            registrar.provisionAgentOverride = { @MainActor _ in
                counter.provisionCalls += 1
                if counter.provisionCalls == 1 {
                    throw SandboxProvisionStepError(
                        step: .bootstrapExec,
                        underlying: SandboxError.containerNotRunning
                    )
                }
            }
            registrar.runtimeProbeOverride = {
                counter.probeCalls += 1
                return false
            }
            registrar.containerStartOverride = { @MainActor in
                counter.startCalls += 1
                counter.statusAtStart = SandboxManager.State.shared.status
                SandboxManager.State.shared.status = .running
            }

            await registrar.registerTools(for: fixture.agent.id)

            #expect(counter.probeCalls == 1)
            #expect(counter.startCalls == 1)
            // `markRuntimeLost` must have flipped the cached status before the
            // startup path ran, otherwise the re-boot would be skipped.
            if case .error = counter.statusAtStart {
            } else {
                Issue.record("expected .error before re-boot, got \(String(describing: counter.statusAtStart))")
            }
            #expect(counter.provisionCalls == 2)
            #expect(registrar.unavailabilityReason(for: fixture.agent.id) == nil)
            #expect(SandboxStartupMetricsStore.loadFailures().isEmpty)
            #expect(ToolRegistry.shared.builtInSandboxToolNamesSnapshot.contains("sandbox_read_file"))

            await tearDown(fixture)
        }
    }

    /// Same dead guest, but the re-boot fails too: the outcome is a runtime
    /// start failure attributed to the recovery trigger — still never
    /// `agent_provision_failed` — and the registrar does not loop.
    @Test
    func bootstrapExecFailure_withDeadGuest_failedRebootIsARuntimeStartFailure() async {
        await SandboxTestLock.runWithStoragePaths {
            guard SandboxBackend.current == .virtualMachine else { return }
            let registrar = SandboxToolRegistrar.shared
            let fixture = makeFixture(name: "DeadGuestReboot")

            final class Counter: @unchecked Sendable {
                var provisionCalls = 0
                var probeCalls = 0
                var startCalls = 0
            }
            let counter = Counter()
            registrar.provisionAgentOverride = { @MainActor _ in
                counter.provisionCalls += 1
                throw SandboxProvisionStepError(
                    step: .bootstrapExec,
                    underlying: SandboxError.containerNotRunning
                )
            }
            registrar.runtimeProbeOverride = {
                counter.probeCalls += 1
                return false
            }
            registrar.containerStartOverride = {
                counter.startCalls += 1
                throw SandboxError.startFailed(
                    "boot failed",
                    underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
                )
            }

            await registrar.registerTools(for: fixture.agent.id)

            #expect(counter.probeCalls == 1)
            #expect(counter.startCalls == 1)
            #expect(counter.provisionCalls == 1)
            #expect(registrar.unavailabilityReason(for: fixture.agent.id)?.kind == .startupFailed)
            let samples = SandboxStartupMetricsStore.loadFailures()
            #expect(samples.count == 1)
            #expect(samples.last?.category == "runtime_start_failed")
            #expect(samples.last?.trigger == "runtime_recovery")
            #expect(samples.last?.errorClass == "posix_ebusy")
            #expect(samples.last?.coldStart == false)

            await settle(fixture)
            await tearDown(fixture)
        }
    }

    // MARK: - Deliberate stops must not turn into restarts

    /// The `.running -> .stopped` edge published by a user Stop (or the
    /// quit chain's `stopContainer`) re-enters `registerTools`. A set-up
    /// sandbox used to count as warm-restartable there, so "Stop" silently
    /// re-booted the VM — and at quit, re-acquired the vmnet lease inside
    /// the exit window (the `vmnet_in_use` relaunch collision).
    @Test
    func explicitStop_isNotAWarmRestartLicense_butForceStartStillIs() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let registrar = SandboxToolRegistrar.shared
            let fixture = makeFixture(name: "ExplicitStop")

            final class Counter: @unchecked Sendable {
                var startCalls = 0
                var provisionCalls = 0
            }
            let counter = Counter()
            registrar.containerStartOverride = { @MainActor in
                counter.startCalls += 1
                SandboxManager.State.shared.status = .running
            }
            registrar.provisionAgentOverride = { @MainActor _ in counter.provisionCalls += 1 }

            // A real public stop: sets the explicit-stop flag and publishes
            // `.stopped` (no VM is running in the harness, so this is just
            // bookkeeping + bridge teardown).
            try await SandboxManager.shared.stopContainer()
            #expect(await SandboxManager.shared.stoppedExplicitly)
            SandboxManager.State.shared.status = .stopped

            await registrar.registerTools(for: fixture.agent.id, trigger: .statusChange)

            #expect(counter.startCalls == 0)
            #expect(counter.provisionCalls == 0)
            #expect(registrar.unavailabilityReason(for: fixture.agent.id) == nil)
            #expect(SandboxStartupMetricsStore.loadFailures().isEmpty)
            // The model still gets the placeholder so first use can bring it back.
            #expect(
                ToolRegistry.shared.builtInSandboxToolNamesSnapshot
                    .contains(BuiltinSandboxTools.initPendingToolName)
            )

            // Explicit first use (placeholder call) is the opt-in that may boot.
            await registrar.registerTools(for: fixture.agent.id, forceStart: true, trigger: .onDemand)
            #expect(counter.startCalls == 1)
            #expect(counter.provisionCalls == 1)

            await SandboxManager.shared.resetExplicitStopForTests()
            await tearDown(fixture)
        }
    }

    @Test
    func prepareForTermination_blocksAnyContainerStart() async {
        await SandboxTestLock.runWithStoragePaths {
            let registrar = SandboxToolRegistrar.shared
            let fixture = makeFixture(name: "Terminating")
            defer { registrar.resetTerminationForTests() }

            final class Counter: @unchecked Sendable {
                var startCalls = 0
                var provisionCalls = 0
            }
            let counter = Counter()
            registrar.containerStartOverride = { counter.startCalls += 1 }
            registrar.provisionAgentOverride = { @MainActor _ in counter.provisionCalls += 1 }
            SandboxManager.State.shared.status = .stopped

            registrar.prepareForTermination()
            #expect(registrar.isTerminating)

            await registrar.registerTools(for: fixture.agent.id, forceStart: true, trigger: .statusChange)
            await registrar.registerTools(for: fixture.agent.id, trigger: .launch)

            #expect(counter.startCalls == 0)
            #expect(counter.provisionCalls == 0)
            #expect(SandboxStartupMetricsStore.loadFailures().isEmpty)

            await tearDown(fixture)
        }
    }

    @Test
    func untypedProvisionFailure_keepsGenericPhase() async {
        await SandboxTestLock.runWithStoragePaths {
            struct Opaque: Error {}
            let registrar = SandboxToolRegistrar.shared
            let fixture = makeFixture(name: "Untyped")

            registrar.provisionAgentOverride = { @MainActor _ in throw Opaque() }

            await registrar.registerTools(for: fixture.agent.id)

            let samples = SandboxStartupMetricsStore.loadFailures()
            #expect(samples.last?.category == "agent_provision_failed")
            #expect(samples.last?.phase == "agent_provision")
            #expect(samples.last?.errorClass == "other")

            await settle(fixture)
            await tearDown(fixture)
        }
    }

    // MARK: - Lease conflict episodes

    /// A VM lease conflict is not a failed boot: it never arms the startup
    /// cool-down or counts toward the lockout, carries the classified owner
    /// for the chip's resolver, and is recorded once per episode however
    /// many registrations hit it.
    @Test
    func leaseConflict_recordsOncePerEpisodeWithOwner_andNeverArmsTheLockout() async {
        await SandboxTestLock.runWithStoragePaths {
            let registrar = SandboxToolRegistrar.shared
            let fixture = makeFixture(name: "Lease")
            SandboxManager.State.shared.status = .stopped
            var starts = 0
            registrar.containerStartOverride = { @MainActor in
                starts += 1
                throw SandboxError.ownershipConflict("Sandbox VM is already owned by PID 1 (osaurus)")
            }

            // One more than the startup-failure lockout (3).
            for _ in 0..<4 {
                await registrar.registerTools(for: fixture.agent.id, trigger: .external)
            }

            let reason = registrar.unavailabilityReason(for: fixture.agent.id)
            #expect(reason?.kind == .vmnetOwnedByOtherProcess)
            #expect(reason?.leaseOwner != nil)
            #expect(reason?.message.contains("cool-down") == false)
            #expect(reason?.message.contains("automatic retries disabled") == false)
            #expect(starts >= 1)
            #expect(registrar.hasLeaseWatcherForTests)
            let samples = SandboxStartupMetricsStore.loadFailures()
            #expect(samples.count == 1)
            #expect(samples.last?.category == "vmnet_in_use")
            #expect(
                SandboxVMOwnershipLease.OwnerState.allCases.map(\.rawValue).contains(samples.last?.ownerState ?? ""))
            #expect(samples.last?.lockHolders != nil)

            registrar.resetLeaseConflictForTests()
            #expect(!registrar.hasLeaseWatcherForTests)
            registrar.containerStartOverride = { @MainActor in
                SandboxManager.State.shared.status = .running
            }
            registrar.provisionAgentOverride = { @MainActor _ in }
            await registrar.registerTools(for: fixture.agent.id, trigger: .external)
            #expect(registrar.unavailabilityReason(for: fixture.agent.id) == nil)
            await tearDown(fixture)
        }
    }

    /// A custom agent's chat turn during a lease conflict tells the model who
    /// holds the VM and does not offer the host folder picker in its place.
    @Test
    func leaseConflict_customAgentChatGetsNoticeAndNoHostPicker() async {
        await SandboxTestLock.runWithStoragePaths {
            let registrar = SandboxToolRegistrar.shared
            let fixture = makeFixture(name: "LeaseChat")
            let previousAvailability = SandboxManager.State.shared.availability
            SandboxManager.State.shared.availability = .available
            defer { SandboxManager.State.shared.availability = previousAvailability }
            SandboxManager.State.shared.status = .stopped
            registrar.containerStartOverride = { @MainActor in
                throw SandboxError.ownershipConflict("Sandbox VM is already owned by PID 1 (osaurus)")
            }
            await registrar.registerTools(for: fixture.agent.id, trigger: .external)
            #expect(registrar.unavailabilityReason(for: fixture.agent.id)?.kind == .vmnetOwnedByOtherProcess)

            let ctx = await ChatExecutionContext.$currentSessionSource.withValue(.chat) {
                await SystemPromptComposer.composeChatContext(
                    agentId: fixture.agent.id,
                    executionMode: .none,
                    model: "gpt-5"
                )
            }
            #expect(ctx.manifest.sections.map(\.id).last == "sandboxUnavailable")
            #expect(ctx.prompt.contains("owned by another Osaurus process"))
            #expect(ctx.prompt.contains("already owned by PID 1"))
            #expect(!ctx.tools.map(\.function.name).contains(PromptWorkingFolderTool.toolName))

            // A guessed workspace tool names the sandbox, not a host folder.
            let refused = try? await ChatExecutionContext.$currentAgentId.withValue(fixture.agent.id) {
                try await ChatExecutionContext.$toolExecutionScope.withValue(ToolExecutionScope(exposed: [])) {
                    try await ToolRegistry.shared.execute(name: "shell_run", argumentsJSON: "{}")
                }
            }
            #expect(refused?.contains("runs in this agent's sandbox, which is not available") == true)
            #expect(refused?.contains("already owned by PID 1") == true)
            #expect(refused?.contains("Folder chip") == false)
            let loadRefused = await ChatExecutionContext.$currentAgentId.withValue(fixture.agent.id) {
                try? await CapabilitiesLoadTool().execute(argumentsJSON: #"{"ids":["tool/file_write"]}"#)
            }
            #expect(loadRefused?.contains("runs in this agent's sandbox") == true)
            #expect(loadRefused?.contains("Folder chip") == false)

            registrar.resetLeaseConflictForTests()
            await settle(fixture)
            await tearDown(fixture)
        }
    }

    @Test
    func sandboxNotReadyRefusal_pointsAtStartupOrTheBlocker() async {
        await SandboxTestLock.runWithStoragePaths {
            let fixture = makeFixture(name: "NotReady")
            let previousAvailability = SandboxManager.State.shared.availability
            defer { SandboxManager.State.shared.availability = previousAvailability }

            SandboxManager.State.shared.availability = .available
            let pending = ToolRegistry.sandboxNotReadyRefusal(tool: "file_write", agentId: fixture.agent.id)
            #expect(pending?.message.contains(BuiltinSandboxTools.initPendingToolName) == true)
            #expect(pending?.retryable == true)
            // No sandbox on this host, or no agent: the folder guidance applies.
            SandboxManager.State.shared.availability = .unavailable(reason: "test")
            #expect(ToolRegistry.sandboxNotReadyRefusal(tool: "file_write", agentId: fixture.agent.id) == nil)
            #expect(ToolRegistry.sandboxNotReadyRefusal(tool: "file_write", agentId: nil) == nil)

            await tearDown(fixture)
        }
    }

    @Test
    func leaseConflictBackoff_doublesFromFifteenSecondsToFiveMinutes() {
        var delays: [TimeInterval] = []
        var delay: TimeInterval?
        for _ in 0..<7 {
            delay = SandboxToolRegistrar.nextLeaseConflictBackoff(after: delay)
            delays.append(delay!)
        }
        #expect(delays == [15, 30, 60, 120, 240, 300, 300])
    }

    @Test
    func autoStartOff_onlyASendOrExplicitStartBootsTheSandbox() {
        typealias Trigger = SandboxToolRegistrar.RegistrationTrigger
        let background: [Trigger] = [.launch, .statusChange, .agentSwitch, .agentUpdated]
        for trigger in Trigger.allCases {
            #expect(SandboxToolRegistrar.mayWarmStart(on: trigger, autoStart: true))
            #expect(SandboxToolRegistrar.mayWarmStart(on: trigger, autoStart: false) == !background.contains(trigger))
        }
    }

    @Test
    func leaseConflictResolver_offersTheFixThatMatchesTheHolder() {
        typealias Lease = SandboxVMOwnershipLease
        let owner = Lease.Owner(pid: 4242, processName: "osaurus", executablePath: nil, acquiredAt: "")
        let app = Lease.Holder(pid: 4242, path: "/Applications/Osaurus.app/Contents/MacOS/osaurus")
        let evals = Lease.Holder(pid: 5151, path: "/repo/.build/debug/osaurus-evals")
        let node = Lease.Holder(pid: 6161, path: "/usr/local/bin/node")
        let names: (Int32) -> String? = { $0 == 4242 ? "Osaurus" : nil }
        func action(_ state: Lease.OwnerState, _ owner: Lease.Owner?, _ holders: [Lease.Holder]) -> SandboxLeaseConflictResolver.Action {
            SandboxLeaseConflictResolver.action(
                for: .init(state: state, owner: owner, holders: holders), appName: names)
        }

        #expect(action(.osaurusAlive, owner, [app]) == .quitApp(pid: 4242, name: "Osaurus"))
        #expect(action(.osaurusAlive, nil, [evals]) == .endProcess(pid: 5151, name: "osaurus-evals"))
        #expect(action(.otherAlive, owner, [node]) == .endOrphans([node]))
        #expect(action(.ownerDeadLockHeld, owner, [node, evals]) == .endOrphans([node]))
        #expect(action(.ownerDeadLockHeld, owner, []) == .retry)
        #expect(action(.unknown, nil, []) == .retry)
        #expect(action(.current, owner, [app]) == .retry)
    }

    @Test
    func leaseConflictExplanation_namesTheHolderAndTheFix() {
        typealias Resolver = SandboxLeaseConflictResolver
        let node = SandboxVMOwnershipLease.Holder(pid: 6161, path: "/usr/local/bin/node")
        #expect(Resolver.explanation(for: .quitApp(pid: 4242, name: "Osaurus")).contains("Quit Osaurus (process 4242)"))
        #expect(Resolver.explanation(for: .endProcess(pid: 5151, name: "osaurus-evals")).contains("osaurus-evals (process 5151)"))
        #expect(Resolver.explanation(for: .endOrphans([node])).contains("node (6161)"))
        #expect(Resolver.explanation(for: .retry).contains("retries automatically"))
    }
}
