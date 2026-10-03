//
//  SandboxToolRegistrar.swift
//  osaurus
//
//  Bridges the sandbox infrastructure with the ToolRegistry by
//  registering/unregistering sandbox tools in response to plugin
//  installs, and container lifecycle events.
//
//  Plugin tools are registered globally (agent-agnostic). Agent
//  identity is resolved at execution time via ChatExecutionContext.
//  Builtin sandbox tools remain per-agent.
//

import AppKit
import Combine
import Foundation

@MainActor
public final class SandboxToolRegistrar {
    public static let shared = SandboxToolRegistrar()

    private var observers: [NSObjectProtocol] = []
    private var statusCancellable: AnyCancellable?
    var provisionAgentOverride: ((UUID) async throws -> Void)?
    /// Test seam for `attemptRuntimeRecovery`'s guest liveness probe so the
    /// classification of a `bootstrapExec` failure can be exercised without
    /// a VM (and without the recovery path booting one).
    var runtimeProbeOverride: (() async -> Bool)?
    /// Test seam for the coalesced container start so the runtime-recovery
    /// re-boot (and its success / failure attribution) can be pinned in the
    /// SwiftPM harness, which has no VM entitlement.
    var containerStartOverride: (() async throws -> Void)?

    /// Set by `prepareForTermination()`. Once the app is quitting, no
    /// registration may start or re-start the container.
    private(set) var isTerminating = false

    /// Per-agent record of why sandbox tools are not currently available.
    /// Used by `SystemPromptComposer` to inject a "sandbox unavailable" notice
    /// into the system prompt so the model doesn't hallucinate sandbox calls.
    public struct UnavailabilityReason: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case containerUnavailable
            case provisioningFailed
            case startupFailed
            case vmnetOwnedByOtherProcess
        }
        public let kind: Kind
        public let message: String
    }

    private var unavailability: [UUID: UnavailabilityReason] = [:]

    /// Why `registerTools` ran. Emitted as a closed telemetry token so a
    /// failure can be tied to launch auto-start vs first-use provisioning
    /// vs agent switching without any free-form context.
    public enum RegistrationTrigger: String, Sendable, Equatable, CaseIterable {
        case launch = "launch_autostart"
        case onDemand = "on_demand"
        case agentSwitch = "agent_switch"
        case agentUpdated = "agent_updated"
        case statusChange = "status_change"
        case autoRetry = "auto_retry"
        case runtimeRecovery = "runtime_recovery"
        /// Chat send / warm-up / plugin host / eval runner callers.
        case external
    }

    /// Bounded context attached to a recorded failure. Only closed tokens
    /// derived from it ever leave the machine; the `error` is used to derive
    /// an `error_class` token and is never serialized.
    struct FailureContext {
        var trigger: RegistrationTrigger
        var coldStart: Bool
        var error: Error?
        var provisionStep: SandboxProvisionStepError.Step?
    }

    /// Agents for which a single runtime-recovery attempt (VM believed
    /// running but the guest exec transport is dead) has been spent. Cleared
    /// on the next successful registration so a genuine later loss can
    /// recover again.
    private var runtimeRecoveryAttempted: Set<UUID> = []

    /// Coalesces concurrent `startContainer()` attempts so multiple Work
    /// sessions / Chat sends don't pile up duplicate provision tasks (which
    /// caused vmnet "address already in use" thrashing).
    private var startupTask: Task<Void, Error>?

    /// Earliest wall-clock time at which a fresh `startContainer()` retry is
    /// allowed after a failed attempt. We back off so a misconfigured host
    /// (vmnet collision, port conflict, missing entitlement) doesn't generate
    /// log spam on every chat send.
    private var nextStartupRetryAfter: Date?

    /// Number of `startContainer()` attempts since process launch that have
    /// failed. After `maxStartupFailures` we stop trying entirely until the
    /// user takes explicit action (toggling autonomous off/on, restarting
    /// the app, or hitting "Start" in the Sandbox settings panel).
    private var startupFailureCount: Int = 0

    /// Cool-down between failed `startContainer()` attempts.
    private static let startupRetryCooldown: TimeInterval = 120

    /// Hard cap on automatic startup attempts per app launch.
    private static let maxStartupFailures: Int = 3

    /// Per-agent record of whether a `provisioningFailed` retry has already
    /// been scheduled. We only auto-retry once per failure event — further
    /// recoveries require explicit user action (toggling autonomous off/on,
    /// hitting "Retry" on the chip) to avoid silent loops.
    private var provisioningRetryScheduled: Set<UUID> = []

    /// Coalesces explicit first-use provisioning kicks (`provisionOnDemand`)
    /// so the model hammering the `sandbox_init_pending` placeholder while the
    /// cold download runs doesn't queue a fresh `registerTools` per call.
    private var onDemandProvisionTask:
        (agentId: UUID, token: UUID, task: Task<Void, Error>)?

    public struct OnDemandProvisionError: LocalizedError, Sendable {
        public let reason: UnavailabilityReason

        public var errorDescription: String? { reason.message }
    }

    /// Delay before the single auto-retry on `provisioningFailed`. Kept
    /// short because most provisioning failures are transient (container
    /// settling state, brief lock during user creation) and fail fast on
    /// the second attempt or succeed.
    private static let provisioningRetryDelay: TimeInterval = 5

    /// Memo of the last SUCCESSFUL builtin registration (agent + effective
    /// exec config). Backs the idempotent fast path in `registerTools`:
    /// warmups and sends call `registerTools` on every turn, and the slow
    /// path tears the sandbox tools out of the registry, then suspends for
    /// container work (provision + SOUL seed + package reconcile) before
    /// re-registering them. Any prompt composition that lands in that
    /// window — the budget preview, another window's warm-up payload —
    /// resolves a schema WITHOUT the sandbox tools, which flaps the
    /// composed shape, invalidates the warm KV fingerprint, and schedules
    /// yet another warm-up whose `registerTools` punches the next hole
    /// (observed as an endless 17–22 s re-prefill loop). When nothing
    /// changed since the last successful registration, skip the cycle
    /// entirely so the registry never transitions through the empty state.
    private var registeredBuiltins: (agentId: UUID, config: AutonomousExecConfig?)?

    /// Returns the current unavailability reason for an agent, if any.
    public func unavailabilityReason(for agentId: UUID) -> UnavailabilityReason? {
        unavailability[agentId]
    }

    private init() {}

    // MARK: - Lifecycle

    /// Call once at app startup (after sandbox auto-start attempt).
    /// Sets up all notification observers and performs initial registration.
    public func start() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .activeAgentChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in await self?.handleAgentChanged() } }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .sandboxPluginInstalled,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let pluginId = note.userInfo?["pluginId"] as? String
                Task { @MainActor in await self?.handlePluginInstalled(pluginId: pluginId) }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .sandboxPluginUninstalled,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let pluginId = note.userInfo?["pluginId"] as? String
                Task { @MainActor in await self?.handlePluginUninstalled(pluginId: pluginId) }
            }
        )

        statusCancellable = SandboxManager.State.shared.$status
            .removeDuplicates()
            .sink { [weak self] newStatus in
                Task { @MainActor in await self?.handleContainerStatusChanged(newStatus) }
            }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .agentUpdated,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let agentId = note.object as? UUID
                Task { @MainActor in await self?.handleAgentUpdated(agentId: agentId) }
            }
        )

        // After macOS sleep / fast user-switch / dock-hide-and-return, the
        // container can transition `.running -> .stopped -> .running` while
        // `lastSeenStatus` already holds `.running`, so the status sink
        // would short-circuit on the next change. Reset on foreground so
        // we re-evaluate registration whenever the user returns.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleAppDidBecomeActive() }
            }
        )

        Task { @MainActor in
            registerAllPluginTools()
            await autoStartContainerIfConfigured()
            await registerTools(for: AgentManager.shared.activeAgent.id, trigger: .launch)
        }
    }

    /// Stop reacting to container lifecycle events because the app is
    /// quitting. Must run before the quit chain calls `stopContainer()`:
    /// the resulting `.running -> .stopped` status edge would otherwise
    /// re-enter `registerTools`, which treats an already set-up sandbox as
    /// warm-restartable and re-acquires the vmnet lease + re-boots the VM
    /// while the process is exiting. That re-boot is what a relaunched
    /// Osaurus (Sparkle update, manual restart) collides with as
    /// `vmnet_in_use`.
    public func prepareForTermination() {
        isTerminating = true
        statusCancellable?.cancel()
        statusCancellable = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Test seam: undo `prepareForTermination()`'s flag (the process-wide
    /// singleton outlives each test). Does not re-install observers.
    func resetTerminationForTests() {
        isTerminating = false
    }

    /// Refresh availability and, when the user has opted into auto-start,
    /// boot the container BEFORE the initial `registerTools` call so the
    /// first compose sees real sandbox tools instead of the placeholder.
    /// Eliminates the launch race where `registerTools` ran with the
    /// container still `.notProvisioned`, set unavailability, and armed
    /// the 120 s cool-down before the auto-start fired.
    ///
    /// `startContainer` is coalesced inside `SandboxManager`, so this
    /// does not double-fire if some other path already kicked a start.
    /// Failures are tolerated — the status publisher re-triggers
    /// `registerTools` when the container comes up later, and
    /// `unavailability` carries the failure reason through to the system
    /// prompt + UI.
    private func autoStartContainerIfConfigured() async {
        let availability = await SandboxManager.shared.refreshAvailability()
        guard availability.isAvailable else { return }
        let config = SandboxConfigurationStore.load()
        guard config.autoStart, config.setupComplete else {
            // The user consented to sandbox setup before (`setupComplete`)
            // but isn't auto-booting the VM. Warm the runtime asset cache
            // in the background — resumable, silent, no VM — so a later
            // manual start (or an app update that rotated the pinned
            // image/initfs) boots from cache instead of a cold download.
            if config.setupComplete {
                await SandboxManager.shared.prefetchRuntimeAssetsInBackground()
            }
            return
        }
        do {
            try await SandboxManager.shared.startContainer()
        } catch {
            debugLog("[Sandbox] Auto-start during launch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Plugin Tools (Global)

    /// Unregister a single plugin's sandbox tools from the registry.
    /// Used by the eval runner's post-case cleanup — the eval CLI never
    /// calls `start()`, so the uninstall notification alone won't reach
    /// the registry in that process.
    public func unregisterPluginTools(pluginId: String) {
        ToolRegistry.shared.unregisterSandboxPluginTools(pluginId: pluginId)
    }

    /// Register all sandbox plugin tools globally (agent-agnostic).
    /// Plugin tools are available to any agent and resolved at execution time.
    public func registerAllPluginTools() {
        registerAllPluginTools(
            libraryPlugins: SandboxPluginLibrary.shared.plugins
        )
    }

    func registerAllPluginTools(libraryPlugins: [SandboxPlugin]) {
        // Library recipes are intentionally decoupled from per-agent installs:
        // `SandboxPluginTool.execute` performs the first-use install. Loading
        // only `.ready` installed plugins creates a startup deadlock for tools
        // authored in Settings — the schema is absent, so no agent can make
        // the call that would install it. The library is also the availability
        // source of truth: deleting a recipe must not let a stale per-agent
        // install resurrect its schema on the next launch.
        var pluginsById: [String: SandboxPlugin] = [:]
        for plugin in libraryPlugins {
            pluginsById[plugin.id] = plugin
        }
        for pluginId in pluginsById.keys.sorted() {
            if let plugin = pluginsById[pluginId] {
                ToolRegistry.shared.registerSandboxPluginTools(plugin: plugin)
            }
        }
    }

    /// Publish a Settings-created/imported library recipe immediately.
    /// Replacing always unregisters the old prefix first so removed tools and
    /// renamed plugin IDs cannot remain callable as stale schemas.
    @discardableResult
    public func activateLibraryPlugin(
        _ plugin: SandboxPlugin,
        replacing previousPluginId: String? = nil
    ) -> Task<Void, Never> {
        ToolRegistry.shared.unregisterSandboxPluginTools(
            pluginId: previousPluginId ?? plugin.id
        )
        if let previousPluginId, previousPluginId != plugin.id {
            ToolRegistry.shared.unregisterSandboxPluginTools(pluginId: plugin.id)
        }
        ToolRegistry.shared.registerSandboxPluginTools(plugin: plugin)

        // Existing chats freeze their capability manifest at first compose for
        // KV-cache stability. A Settings catalog edit is an explicit, rare
        // surface change, so discard those snapshots; otherwise an already-open
        // chat cannot discover the newly published recipe until it is recreated.
        return Task {
            await SessionToolStateStore.shared.invalidateAll()
        }
    }

    /// Remove a Settings library recipe from the live catalog and refresh
    /// frozen capability manifests in already-open chats.
    @discardableResult
    public func deactivateLibraryPlugin(pluginId: String) -> Task<Void, Never> {
        ToolRegistry.shared.unregisterSandboxPluginTools(pluginId: pluginId)
        return Task {
            await SessionToolStateStore.shared.invalidateAll()
        }
    }

    // MARK: - Builtin Tools (Per-Agent)

    /// Re-register builtin sandbox tools for a specific agent.
    /// This is the per-agent concern: provisioning + builtin tool registration.
    ///
    /// When the agent has autonomous execution enabled but the container is
    /// not running, this method will attempt to start the container before
    /// provisioning. Failures are recorded in `unavailability[agentId]` so the
    /// system prompt can surface a clear message to the model instead of the
    /// model silently losing access to its sandbox tools.
    public func registerTools(
        for agentId: UUID,
        forceStart: Bool = false,
        trigger: RegistrationTrigger = .external
    ) async {
        // Quitting: the container is being torn down on purpose; never
        // start (or re-start) it from here.
        guard !isTerminating else { return }
        let agent = AgentManager.shared.agent(for: agentId) ?? Agent.default
        let agentIdStr = agent.id.uuidString
        let agentName = SandboxAgentProvisioner.linuxName(for: agentIdStr)
        let execConfig = AgentManager.shared.effectiveAutonomousExec(for: agent.id)
        let autonomousEnabled = execConfig?.enabled == true
        // Read once: `setupComplete == false` means any start below is a
        // first-run cold provision (multi-GB download) rather than a warm
        // restart — the single most useful split for failure telemetry.
        let setupComplete = SandboxConfigurationStore.load().setupComplete
        var failureContext = FailureContext(
            trigger: trigger,
            coldStart: !setupComplete,
            error: nil,
            provisionStep: nil
        )

        // Idempotent fast path (see `registeredBuiltins`): the desired end
        // state is already installed — same agent, same effective config,
        // container still running, no recorded failure, and the real
        // builtin tools actually present in the registry (the registry
        // check guards against out-of-band teardowns like the eval
        // runner's `unregisterAllBuiltinSandboxTools`). Return without
        // unregistering so concurrent composes never observe a schema
        // with the sandbox tools missing. Restricted to the autonomous
        // case: a matching memo then proves `ensureProvisioned` already
        // succeeded for this agent, whereas with autonomous off a plugin
        // that became ready since the memo was taken still needs its
        // provisioning pass on the slow path.
        if !forceStart,
            autonomousEnabled,
            let memo = registeredBuiltins,
            memo.agentId == agent.id,
            memo.config == execConfig,
            SandboxManager.State.shared.status == .running,
            unavailability[agent.id] == nil,
            ToolRegistry.shared.builtInSandboxToolNamesSnapshot.contains("sandbox_read_file")
        {
            return
        }

        let needsProvisioning =
            autonomousEnabled
            || SandboxPluginManager.shared.plugins(for: agentIdStr).contains { $0.status == .ready }

        // Whenever autonomous is on but we leave this method without
        // registering the real sandbox tools, drop the placeholder into
        // the schema so the model has *something* sandbox-shaped to call
        // (it'll get a "still initialising" envelope back). The success
        // path flips `realToolsRegistered` so the defer skips it.
        var realToolsRegistered = false
        defer {
            if autonomousEnabled && !realToolsRegistered {
                BuiltinSandboxTools.registerInitPending(agentId: agent.id)
            }
        }

        let containerStatus = SandboxManager.State.shared.status
        if containerStatus != .running {
            // Container availability is process-wide. Clear the canonical
            // runtime surface only when the backend is actually unavailable,
            // not whenever another agent refreshes its own configuration.
            ToolRegistry.shared.unregisterAllBuiltinSandboxTools()
            registeredBuiltins = nil

            // Without autonomous execution there's no expectation of sandbox
            // tools — clear any prior unavailability and bail.
            guard autonomousEnabled else {
                unavailability.removeValue(forKey: agent.id)
                publishActiveAgentUnavailability(for: agent.id, reason: nil)
                return
            }

            // The chip defaults ON for the Default agent and new agents, but a
            // default-ON sandbox that was never set up must NOT cold-provision
            // (multi-GB download) just because `registerTools` runs at launch,
            // on agent switch, or on a status change. Defer until explicit
            // first use: the `sandbox_init_pending` placeholder (registered by
            // the `defer` above) calls `provisionOnDemand`, or the user starts
            // it from the Sandbox tab. `forceStart` is that explicit opt-in;
            // `setupComplete` allows warm restarts of an already-provisioned
            // sandbox (no download) — except right after the user (or the
            // quit chain) stopped it on purpose: the `.running -> .stopped`
            // edge from that stop lands here, and re-booting would turn
            // "Stop" into a restart. Explicit first use (`forceStart`) and
            // the Sandbox tab's Start button still bring it back.
            let stoppedOnPurpose = await SandboxManager.shared.stoppedExplicitly
            let mayColdStart = forceStart || (setupComplete && !stoppedOnPurpose)
            guard mayColdStart else {
                unavailability.removeValue(forKey: agent.id)
                publishActiveAgentUnavailability(for: agent.id, reason: nil)
                return
            }

            let preStartKind = unavailabilityKind(for: containerStatus)

            // After `maxStartupFailures` give up entirely until the user
            // takes explicit action (toggling autonomous off/on, restarting
            // the app, or hitting "Start" in the Sandbox settings panel).
            //
            // Local-only: the underlying failure was already recorded (and
            // emitted) by `recordStartupFailure`. Re-emitting here — which
            // happens whenever a *different* agent registers during the
            // lockout — double counted one boot failure per agent.
            if startupFailureCount >= Self.maxStartupFailures {
                if unavailability[agent.id] == nil {
                    noteUnavailability(
                        for: agent.id,
                        kind: preStartKind,
                        message:
                            "Sandbox start has failed \(startupFailureCount) times this session — automatic retries disabled. Open the Sandbox settings panel to start it manually or check ~/.osaurus/container/containers/osaurus-sandbox for stale state."
                    )
                }
                return
            }

            // Honor the failure cool-down so a misconfigured host (vmnet
            // collision, port-in-use, missing entitlement) doesn't get
            // hammered with a fresh provision attempt on every chat/work
            // send. The previous failure reason stays in `unavailability`
            // so the model gets the same notice without us re-trying.
            // Local-only for the same reason as the lockout branch above.
            if let retryAfter = nextStartupRetryAfter, retryAfter > Date() {
                if unavailability[agent.id] == nil {
                    noteUnavailability(
                        for: agent.id,
                        kind: preStartKind,
                        message: "Sandbox container start is in cool-down after a recent failure"
                    )
                }
                return
            }

            do {
                try await ensureContainerStartedCoalesced()
            } catch {
                failureContext.error = error
                if let sandboxError = error as? SandboxError,
                    case .ownershipConflict = sandboxError
                {
                    // This is an actionable cross-process blocker, not a
                    // failed boot. Do not increment attempts, arm cool-down,
                    // or scrub another process's shared sandbox state.
                    recordUnavailability(
                        for: agent.id,
                        kind: .vmnetOwnedByOtherProcess,
                        message: error.localizedDescription,
                        context: failureContext
                    )
                    return
                }
                await recordStartupFailure(
                    for: agent.id,
                    kind: preStartKind,
                    message: "Sandbox container could not be started: \(error.localizedDescription)",
                    context: failureContext
                )
                return
            }

            guard SandboxManager.State.shared.status == .running else {
                await recordStartupFailure(
                    for: agent.id,
                    kind: .startupFailed,
                    message: "Sandbox container did not reach running state",
                    context: failureContext
                )
                return
            }

            // Successful start resets failure tracking.
            nextStartupRetryAfter = nil
            startupFailureCount = 0
        }

        if needsProvisioning {
            do {
                try await ensureProvisioned(agentId: agent.id)
            } catch {
                let stepError = error as? SandboxProvisionStepError
                let underlying = stepError?.underlying ?? error
                failureContext.error = underlying
                failureContext.provisionStep = stepError?.step

                switch stepError?.step {
                case .startReentry:
                    // The provision path re-entered `startContainer()` and
                    // it failed: the container was NOT actually usable even
                    // though the cached status said so. Attribute this as a
                    // runtime start failure, not an agent provision failure.
                    if let sandboxError = underlying as? SandboxError,
                        case .ownershipConflict = sandboxError
                    {
                        recordUnavailability(
                            for: agent.id,
                            kind: .vmnetOwnedByOtherProcess,
                            message: underlying.localizedDescription,
                            context: failureContext
                        )
                        return
                    }
                    await recordStartupFailure(
                        for: agent.id,
                        kind: .startupFailed,
                        message:
                            "Sandbox container could not be started: \(underlying.localizedDescription)",
                        context: failureContext
                    )
                    return

                case .bootstrapExec:
                    // The exec transport failed while the cached status
                    // still says `.running` — classic post-sleep / VM-died
                    // symptom. Probe the guest once; if it is really gone,
                    // mark the runtime lost and take the startup path (which
                    // cleans up and re-boots) exactly once per agent.
                    if await attemptRuntimeRecovery(for: agent.id, trigger: trigger) {
                        return
                    }

                default:
                    break
                }

                recordUnavailability(
                    for: agent.id,
                    kind: .provisioningFailed,
                    message: "Failed to provision agent sandbox: \(underlying.localizedDescription)",
                    context: failureContext
                )
                scheduleProvisioningAutoRetry(for: agent.id)
                return
            }
        }

        unavailability.removeValue(forKey: agent.id)
        provisioningRetryScheduled.remove(agent.id)
        runtimeRecoveryAttempted.remove(agent.id)
        publishActiveAgentUnavailability(for: agent.id, reason: nil)
        BuiltinSandboxTools.register(
            agentId: agentIdStr,
            agentName: agentName,
            config: execConfig
        )
        registeredBuiltins = (agent.id, execConfig)
        realToolsRegistered = true
    }

    /// When a guest exec failed but the cached container status is still
    /// `.running`, decide whether the VM is actually gone. Returns `true`
    /// when a recovery attempt was made (the recursive `registerTools` call
    /// has already recorded any outcome); `false` when the caller should
    /// record the original failure as a provision failure.
    ///
    /// Only the VM backend has a runtime that can die underneath us; the
    /// Seatbelt backend has no guest, so its exec failures are real.
    private func attemptRuntimeRecovery(
        for agentId: UUID,
        trigger: RegistrationTrigger
    ) async -> Bool {
        guard SandboxBackend.current == .virtualMachine else { return false }
        guard SandboxManager.State.shared.status == .running else { return false }
        guard !runtimeRecoveryAttempted.contains(agentId) else { return false }
        let alive: Bool
        if let runtimeProbeOverride {
            alive = await runtimeProbeOverride()
        } else {
            alive = await SandboxManager.shared.probeRuntimeAlive()
        }
        guard !alive else { return false }

        runtimeRecoveryAttempted.insert(agentId)
        debugLog("[Sandbox] Guest exec transport is dead while status is running — recovering runtime")
        await SandboxManager.shared.markRuntimeLost(
            reason: "Guest stopped responding to exec"
        )
        // Recovery bypasses the cool-down: the previous failure (if any)
        // was for a different boot, and the user has done nothing wrong.
        nextStartupRetryAfter = nil
        await registerTools(for: agentId, trigger: trigger == .runtimeRecovery ? trigger : .runtimeRecovery)
        return true
    }

    /// Update the per-agent unavailability record and the UI mirror WITHOUT
    /// emitting a metrics sample or telemetry event. Used by the cool-down
    /// and lockout branches, whose underlying failure was already recorded
    /// once by `recordStartupFailure`.
    private func noteUnavailability(
        for agentId: UUID,
        kind: UnavailabilityReason.Kind,
        message: String
    ) {
        let prev = unavailability[agentId]
        let next = UnavailabilityReason(kind: kind, message: message)
        unavailability[agentId] = next
        if prev != next {
            debugLog("[Sandbox] \(message)")
        }
        publishActiveAgentUnavailability(for: agentId, reason: next)
    }

    private func recordUnavailability(
        for agentId: UUID,
        kind: UnavailabilityReason.Kind,
        message: String,
        context: FailureContext
    ) {
        // Only log when this is a NEW failure (kind+message changed). Without
        // this, every chat send / work iteration produces another identical
        // line in the system log.
        let prev = unavailability[agentId]
        let next = UnavailabilityReason(kind: kind, message: message)
        unavailability[agentId] = next
        if prev != next {
            debugLog("[Sandbox] \(message)")
            let tokens = Self.failureTelemetryTokens(
                kind: kind,
                backend: SandboxBackend.current,
                provisionStep: context.provisionStep
            )
            let errorClass = Self.failureErrorClass(for: context.error)
            SandboxStartupMetricsStore.recordFailure(
                SandboxStartupFailureSample(
                    category: tokens.category,
                    backend: tokens.backend,
                    phase: tokens.phase,
                    errorClass: errorClass,
                    trigger: context.trigger.rawValue,
                    coldStart: context.coldStart
                )
            )
            FeatureTelemetry.sandboxProvisionFailure(
                category: tokens.category,
                backend: tokens.backend,
                phase: tokens.phase,
                errorClass: errorClass,
                trigger: context.trigger.rawValue,
                coldStart: context.coldStart
            )
        }
        publishActiveAgentUnavailability(for: agentId, reason: next)
    }

    /// Convert internal failures to a privacy-safe, bounded telemetry
    /// vocabulary. The detailed user-facing message stays local.
    ///
    /// `provisionStep` refines the `agent_provision` phase into which step
    /// of the per-agent bootstrap failed; it is ignored for other kinds.
    nonisolated static func failureTelemetryTokens(
        kind: UnavailabilityReason.Kind,
        backend: SandboxBackend,
        provisionStep: SandboxProvisionStepError.Step? = nil
    ) -> (category: String, backend: String, phase: String) {
        let backendToken = backend == .virtualMachine ? "vm" : "seatbelt"
        switch kind {
        case .containerUnavailable:
            return ("container_unavailable", backendToken, "availability")
        case .provisioningFailed:
            let phase = provisionStep.map { "agent_provision.\($0.rawValue)" } ?? "agent_provision"
            return ("agent_provision_failed", backendToken, phase)
        case .startupFailed:
            return ("runtime_start_failed", backendToken, "runtime_start")
        case .vmnetOwnedByOtherProcess:
            return ("vmnet_in_use", backendToken, "vm_ownership")
        }
    }

    /// Every value this can return. Kept as an explicit list so tests can
    /// prove the telemetry dimension stays closed.
    nonisolated static let failureErrorClasses: [String] = [
        "none",
        "sandbox_unavailable",
        "sandbox_container_not_running",
        "sandbox_provision_failed",
        "sandbox_start_failed",
        "sandbox_stop_failed",
        "sandbox_remove_failed",
        "sandbox_user_creation_failed",
        "sandbox_exec_failed",
        "sandbox_timeout",
        "sandbox_ownership_conflict",
        "sandbox_integrity_check_failed",
        "cancelled",
        "url_offline",
        "url_timeout",
        "url_dns",
        "url_other",
        "posix_eexist",
        "posix_ebusy",
        "posix_eaddrinuse",
        "posix_eacces",
        "posix_eperm",
        "posix_enospc",
        "posix_other",
        "cocoa_file_exists",
        "cocoa_out_of_space",
        "cocoa_no_permission",
        "cocoa_other",
        "sdk_grpc",
        "sdk_vmnet",
        "other",
    ]

    /// Map an arbitrary error to one closed `error_class` token. Never
    /// includes the message, a path, a host, or any other free text.
    nonisolated static func failureErrorClass(for error: Error?) -> String {
        guard let error else { return "none" }
        if let sandboxError = error as? SandboxError {
            switch sandboxError {
            case .unavailable: return "sandbox_unavailable"
            case .containerNotRunning: return "sandbox_container_not_running"
            case .provisionFailed: return "sandbox_provision_failed"
            case .startFailed(_, let underlying):
                // `friendlyError` wrapped a POSIX/Cocoa/SDK error with a
                // hint; classify the original so EEXIST, EADDRINUSE, GRPC
                // and vmnet stay distinguishable.
                if let underlying { return failureErrorClass(for: underlying) }
                return "sandbox_start_failed"
            case .stopFailed: return "sandbox_stop_failed"
            case .removeFailed: return "sandbox_remove_failed"
            case .userCreationFailed: return "sandbox_user_creation_failed"
            case .execFailed: return "sandbox_exec_failed"
            case .timeout: return "sandbox_timeout"
            case .ownershipConflict: return "sandbox_ownership_conflict"
            case .integrityCheckFailed: return "sandbox_integrity_check_failed"
            }
        }
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                .internationalRoamingOff, .callIsActive:
                return "url_offline"
            case .timedOut: return "url_timeout"
            case .cannotFindHost, .dnsLookupFailed: return "url_dns"
            default: return "url_other"
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch Int32(nsError.code) {
            case EEXIST: return "posix_eexist"
            case EBUSY: return "posix_ebusy"
            case EADDRINUSE: return "posix_eaddrinuse"
            case EACCES: return "posix_eacces"
            case EPERM: return "posix_eperm"
            case ENOSPC: return "posix_enospc"
            default: return "posix_other"
            }
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteFileExistsError: return "cocoa_file_exists"
            case NSFileWriteOutOfSpaceError: return "cocoa_out_of_space"
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "cocoa_no_permission"
            default: return "cocoa_other"
            }
        }
        // SDK-internal errors don't bridge to a stable domain; classify
        // by type description the same way `friendlyError` does.
        let description = String(describing: error)
        if description.contains("GRPC") { return "sdk_grpc" }
        if description.lowercased().contains("vmnet") { return "sdk_vmnet" }
        return "other"
    }

    /// Mirror per-agent unavailability into `SandboxManager.State.shared`
    /// so SwiftUI views (the sandbox chip + its tooltip) can react without
    /// reaching into the registrar's `[UUID: …]` map.
    private func publishActiveAgentUnavailability(
        for agentId: UUID,
        reason: UnavailabilityReason?
    ) {
        guard agentId == AgentManager.shared.activeAgent.id else { return }
        SandboxManager.State.shared.activeAgentUnavailability = reason
    }

    /// Bumps the failure counter, arms the cool-down, scrubs any leftover
    /// container/bridge state, and records the unavailability reason. The
    /// SDK's own cleanup occasionally leaves the on-disk container directory
    /// behind, which surfaces as the misleading "file already exists" error
    /// on the next attempt — `cleanupAfterFailure()` makes the next start
    /// idempotent.
    private func recordStartupFailure(
        for agentId: UUID,
        kind: UnavailabilityReason.Kind,
        message: String,
        context: FailureContext
    ) async {
        startupFailureCount += 1
        nextStartupRetryAfter = Date().addingTimeInterval(Self.startupRetryCooldown)
        await SandboxManager.shared.cleanupAfterFailure()
        recordUnavailability(for: agentId, kind: kind, message: message, context: context)
    }

    private func unavailabilityKind(for status: ContainerStatus) -> UnavailabilityReason.Kind {
        status == .notProvisioned ? .containerUnavailable : .startupFailed
    }

    /// Coalesce concurrent `startContainer()` attempts so multiple sessions
    /// firing `registerTools` in parallel share one provision task instead
    /// of racing each other into "address already in use" / vmnet failures.
    private func ensureContainerStartedCoalesced() async throws {
        if let inFlight = startupTask {
            try await inFlight.value
            return
        }
        let startOverride = containerStartOverride
        let task = Task<Void, Error> {
            if let startOverride {
                try await startOverride()
                return
            }
            try await SandboxManager.shared.startContainer()
        }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
    }

    private func ensureProvisioned(agentId: UUID) async throws {
        if let provisionAgentOverride {
            try await provisionAgentOverride(agentId)
            return
        }
        try await SandboxAgentProvisioner.shared.ensureProvisioned(agentId: agentId)
    }

    /// Schedule a single deferred retry of `registerTools` after a
    /// `provisioningFailed` outcome. Bounded: only one retry per failure
    /// event, cleared when the next call succeeds (so a real recovery
    /// re-arms the auto-retry for the next time it's needed).
    private func scheduleProvisioningAutoRetry(for agentId: UUID) {
        guard !provisioningRetryScheduled.contains(agentId) else { return }
        provisioningRetryScheduled.insert(agentId)
        let delay = Self.provisioningRetryDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            // Only retry if the failure record is still present; if a status
            // change or the user already kicked a retry, skip.
            guard self.unavailability[agentId]?.kind == .provisioningFailed else {
                self.provisioningRetryScheduled.remove(agentId)
                return
            }
            debugLog("[Sandbox] Auto-retrying provisioning for agent \(agentId)")
            await self.registerTools(for: agentId, trigger: .autoRetry)
        }
    }

    // MARK: - Event Handlers

    private func handleAgentChanged() async {
        let newId = AgentManager.shared.activeAgent.id
        // Sync the published unavailability mirror immediately to the new
        // agent's state so the sandbox chip doesn't briefly show the prior
        // agent's failure while `registerTools` runs.
        publishActiveAgentUnavailability(for: newId, reason: unavailability[newId])
        await registerTools(for: newId, trigger: .agentSwitch)
    }

    private func handleAgentUpdated(agentId: UUID?) async {
        guard agentId == nil || agentId == AgentManager.shared.activeAgent.id else { return }
        await registerTools(for: AgentManager.shared.activeAgent.id, trigger: .agentUpdated)
    }

    private func handlePluginInstalled(pluginId: String?) async {
        guard let pluginId else { return }
        guard let plugin = SandboxPluginLibrary.shared.plugin(id: pluginId) else { return }
        ToolRegistry.shared.registerSandboxPluginTools(plugin: plugin)
    }

    private func handlePluginUninstalled(pluginId: String?) async {
        guard let pluginId else { return }
        ToolRegistry.shared.unregisterSandboxPluginTools(pluginId: pluginId)
    }

    /// On app foreground, drop the cached container status so the status
    /// publisher re-fires `handleContainerStatusChanged` even if the
    /// running/not-running bit hasn't flipped from our perspective. Catches
    /// silent transitions during sleep / fast user-switch.
    private func handleAppDidBecomeActive() {
        lastSeenStatus = nil
    }

    private var lastSeenStatus: ContainerStatus?

    private func handleContainerStatusChanged(_ newStatus: ContainerStatus) async {
        // Tool registration only depends on whether the container is running.
        // Skip the heavy plugin-verify + registerTools work for intermediate
        // transitions (e.g. `.notProvisioned → .starting → .stopped` from a
        // failing autostart) so flapping doesn't churn the registry. The
        // very first event (lastSeenStatus == nil) always runs so launch-
        // time registration still happens.
        let prev = lastSeenStatus
        lastSeenStatus = newStatus
        let runningChanged = prev?.isRunning != newStatus.isRunning
        guard prev == nil || runningChanged else { return }

        if newStatus.isRunning {
            // Someone (UI, autoStart, agent provisioner) successfully
            // started the container — clear any prior failure tracking so
            // future hiccups can retry from scratch.
            startupFailureCount = 0
            nextStartupRetryAfter = nil
            await SandboxPluginManager.shared.verifyAndRepairAllPlugins()
        }
        registerAllPluginTools()
        await registerTools(for: AgentManager.shared.activeAgent.id, trigger: .statusChange)
    }

    /// Reset the failure tracking so the next `registerTools` call is
    /// allowed to attempt startup again. Called when the user takes an
    /// explicit action that should bypass the cool-down: toggling
    /// autonomous execution off/on, or hitting "Start" in the Sandbox
    /// settings panel.
    public func resetStartupFailures() {
        startupFailureCount = 0
        nextStartupRetryAfter = nil
    }

    /// Boot the sandbox for an agent on explicit first use, bypassing the
    /// `setupComplete` cold-start gate in `registerTools`.
    ///
    /// This is the "boots on first sandboxed run" path: the chip defaults ON
    /// (where supported), but a fresh, never-set-up sandbox stays un-booted at
    /// launch so there's no surprise multi-GB download. When the model first
    /// reaches for a sandbox tool it hits the `sandbox_init_pending`
    /// placeholder, which awaits this start (and cold provision) before
    /// returning. `AgentManager.updateAutonomousExec` also awaits it on an
    /// explicit OFF→ON toggle. Coalesced via `onDemandProvisionTask` so
    /// repeated placeholder calls during the download share one result.
    public func provisionOnDemand(for agentId: UUID) async throws {
        if let inFlight = onDemandProvisionTask {
            try await withTaskCancellationHandler {
                try await inFlight.task.value
            } onCancel: {
                inFlight.task.cancel()
            }
            if inFlight.agentId == agentId { return }
        }

        resetStartupFailures()
        let token = UUID()
        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try Task.checkCancellation()
            await self.registerTools(for: agentId, forceStart: true, trigger: .onDemand)
            try Task.checkCancellation()

            let hasRealTools =
                self.registeredBuiltins?.agentId == agentId
                && ToolRegistry.shared.builtInSandboxToolNamesSnapshot
                    .contains("sandbox_exec")
            guard hasRealTools else {
                let reason =
                    self.unavailability[agentId]
                    ?? UnavailabilityReason(
                        kind: .containerUnavailable,
                        message:
                            "Sandbox provisioning completed without registering its runtime tools."
                    )
                throw OnDemandProvisionError(reason: reason)
            }
        }
        onDemandProvisionTask = (agentId, token, task)

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if onDemandProvisionTask?.token == token {
                onDemandProvisionTask = nil
            }
        } catch {
            if onDemandProvisionTask?.token == token {
                onDemandProvisionTask = nil
            }
            throw error
        }
    }
}
