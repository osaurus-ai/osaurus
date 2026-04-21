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

    /// Per-agent record of why sandbox tools are not currently available.
    /// Used by `SystemPromptComposer` to inject a "sandbox unavailable" notice
    /// into the system prompt so the model doesn't hallucinate sandbox calls.
    public struct UnavailabilityReason: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case containerUnavailable
            case provisioningFailed
            case startupFailed
        }
        public let kind: Kind
        public let message: String
    }

    private var unavailability: [UUID: UnavailabilityReason] = [:]

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

    /// Delay before the single auto-retry on `provisioningFailed`. Kept
    /// short because most provisioning failures are transient (container
    /// settling state, brief lock during user creation) and fail fast on
    /// the second attempt or succeed.
    private static let provisioningRetryDelay: TimeInterval = 5

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
            await registerTools(for: AgentManager.shared.activeAgent.id)
        }
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
        guard config.autoStart, config.setupComplete else { return }
        do {
            try await SandboxManager.shared.startContainer()
        } catch {
            debugLog("[Sandbox] Auto-start during launch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Plugin Tools (Global)

    /// Register all sandbox plugin tools globally (agent-agnostic).
    /// Plugin tools are available to any agent and resolved at execution time.
    public func registerAllPluginTools() {
        let allPlugins = SandboxPluginManager.shared.allUniquePlugins()
        for plugin in allPlugins {
            ToolRegistry.shared.registerSandboxPluginTools(plugin: plugin)
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
    public func registerTools(for agentId: UUID) async {
        ToolRegistry.shared.unregisterAllBuiltinSandboxTools()

        let agent = AgentManager.shared.agent(for: agentId) ?? Agent.default
        let agentIdStr = agent.id.uuidString
        let agentName = SandboxAgentProvisioner.linuxName(for: agentIdStr)
        let execConfig = AgentManager.shared.effectiveAutonomousExec(for: agent.id)
        let autonomousEnabled = execConfig?.enabled == true
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
                BuiltinSandboxTools.registerInitPending()
            }
        }

        let containerStatus = SandboxManager.State.shared.status
        if containerStatus != .running {
            // Without autonomous execution there's no expectation of sandbox
            // tools — clear any prior unavailability and bail.
            guard autonomousEnabled else {
                unavailability.removeValue(forKey: agent.id)
                publishActiveAgentUnavailability(for: agent.id, reason: nil)
                return
            }

            let preStartKind = unavailabilityKind(for: containerStatus)

            // After `maxStartupFailures` give up entirely until the user
            // takes explicit action (toggling autonomous off/on, restarting
            // the app, or hitting "Start" in the Sandbox settings panel).
            if startupFailureCount >= Self.maxStartupFailures {
                if unavailability[agent.id] == nil {
                    recordUnavailability(
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
            if let retryAfter = nextStartupRetryAfter, retryAfter > Date() {
                if unavailability[agent.id] == nil {
                    recordUnavailability(
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
                await recordStartupFailure(
                    for: agent.id,
                    kind: preStartKind,
                    message: "Sandbox container could not be started: \(error.localizedDescription)"
                )
                return
            }

            guard SandboxManager.State.shared.status == .running else {
                await recordStartupFailure(
                    for: agent.id,
                    kind: .startupFailed,
                    message: "Sandbox container did not reach running state"
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
                recordUnavailability(
                    for: agent.id,
                    kind: .provisioningFailed,
                    message: "Failed to provision agent sandbox: \(error.localizedDescription)"
                )
                scheduleProvisioningAutoRetry(for: agent.id)
                return
            }
        }

        unavailability.removeValue(forKey: agent.id)
        provisioningRetryScheduled.remove(agent.id)
        publishActiveAgentUnavailability(for: agent.id, reason: nil)
        BuiltinSandboxTools.register(
            agentId: agentIdStr,
            agentName: agentName,
            config: execConfig
        )
        realToolsRegistered = true
    }

    private func recordUnavailability(
        for agentId: UUID,
        kind: UnavailabilityReason.Kind,
        message: String
    ) {
        // Only log when this is a NEW failure (kind+message changed). Without
        // this, every chat send / work iteration produces another identical
        // line in the system log.
        let prev = unavailability[agentId]
        let next = UnavailabilityReason(kind: kind, message: message)
        unavailability[agentId] = next
        if prev != next {
            debugLog("[Sandbox] \(message)")
        }
        publishActiveAgentUnavailability(for: agentId, reason: next)
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
        message: String
    ) async {
        startupFailureCount += 1
        nextStartupRetryAfter = Date().addingTimeInterval(Self.startupRetryCooldown)
        await SandboxManager.shared.cleanupAfterFailure()
        recordUnavailability(for: agentId, kind: kind, message: message)
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
        let task = Task<Void, Error> {
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
            await self.registerTools(for: agentId)
        }
    }

    // MARK: - Event Handlers

    private func handleAgentChanged() async {
        let newId = AgentManager.shared.activeAgent.id
        // Sync the published unavailability mirror immediately to the new
        // agent's state so the sandbox chip doesn't briefly show the prior
        // agent's failure while `registerTools` runs.
        publishActiveAgentUnavailability(for: newId, reason: unavailability[newId])
        await registerTools(for: newId)
    }

    private func handleAgentUpdated(agentId: UUID?) async {
        guard agentId == nil || agentId == AgentManager.shared.activeAgent.id else { return }
        await registerTools(for: AgentManager.shared.activeAgent.id)
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
        await registerTools(for: AgentManager.shared.activeAgent.id)
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
}
