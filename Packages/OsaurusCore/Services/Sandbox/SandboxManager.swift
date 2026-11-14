//
//  SandboxManager.swift
//  osaurus
//
//  Manages the sandbox VM lifecycle via apple/containerization.
//  Uses Virtualization.framework directly -- no CLI, no XPC daemon.
//  All container operations are serialized through this actor.
//
//  The VM is a LinuxPod: one container per agent (own rootfs, mount and
//  PID namespaces, only its own home and `shared/` mounted) plus a system
//  container for VM-wide work. See `SandboxPodLayout`.
//
//  Networking: VmnetNetwork (vmnet-backed NAT) for outbound internet,
//  one vsock-relayed Unix socket per container for the host API bridge.
//

#if os(macOS)

    import Containerization
    import ContainerizationArchive
    import ContainerizationError
    import ContainerizationExtras
    import ContainerizationOCI
    import CryptoKit
    import Darwin
    import Foundation
    import SystemPackage
    import vmnet

    public actor SandboxManager {
        public static let shared = SandboxManager()

        private static let containerID = "osaurus-sandbox"

        /// GHCR image reference, pinned by content digest so a registry
        /// compromise (or `:latest` mutating under us) cannot silently
        /// rewrite the trust boundary the sandbox enforces. Update this
        /// digest when bumping the sandbox image — never roll back to a
        /// floating tag.
        ///
        /// Runtimes guaranteed in this image (see `sandbox/Dockerfile`):
        ///   bash, python3, pip, node, npm, uv, uvx, git, curl, jq,
        ///   ripgrep, sqlite, build-base. Stdio MCP servers shipped as
        ///   `uvx <server>` or `npx -y <server>` work out of the box.
        ///
        /// To rotate: `crane digest ghcr.io/osaurus-ai/sandbox:latest`
        /// or `docker buildx imagetools inspect ghcr.io/osaurus-ai/sandbox:latest`
        /// and paste the multi-arch index digest here.
        private static let containerImage =
            "ghcr.io/osaurus-ai/sandbox@sha256:f4216228d7f2d26b1a0e2a99501f6812f1298ee06a0477c508b3e75db74b8a2f"

        /// Internal visibility of the pinned image reference so the
        /// warm-boot cache-key contract can be unit-tested.
        nonisolated static var pinnedContainerImageForTesting: String { containerImage }

        /// Fallback source for the guest kernel: the full Kata tarball,
        /// verified by digest before extraction. Release builds bundle the
        /// extracted ~18 MiB `vmlinux` in the signed app instead (see
        /// `SandboxRuntimeAssets`), so this ~665 MiB download only runs for
        /// dev builds or bundles stripped of the resource. Mismatch is
        /// fail-closed (the file is deleted and provisioning aborts).
        private static let kernelDownloadURLs: [DownloadSource] = [
            DownloadSource(
                url: SandboxRuntimeAssets.kernelTarballURL,
                expectedSHA256: SandboxRuntimeAssets.kernelTarballSHA256
            )
        ]

        /// Bound the cost of hashing — well above either current artifact
        /// (Kata tarball ~665 MiB, initfs ~100 MiB) but stops a runaway
        /// download from silently growing into a multi-GB hash job.
        private static let maxArtifactDownloadBytes: Int = 768 * 1024 * 1024

        /// How long a membership restart waits for other agents' in-flight
        /// commands and background jobs before restarting anyway.
        static let membershipRestartMaxWait: TimeInterval = 120

        /// In-guest directory holding per-agent bridge auth tokens.
        /// Each file is `<linuxName>.token`, mode 0600, owned by that user.
        /// The directory itself is mode 0711 so users can open their own
        /// file by known name without enumerating siblings.
        fileprivate static let bridgeTokenDir = "/run/osaurus"

        private var _status: ContainerStatus = .notProvisioned
        private var _availability: SandboxAvailability?
        private var pod: LinuxPod?
        private var podNetwork: (any Network)?
        private var bootNetwork: SandboxPodNetwork?
        /// Agents with a container in the running pod. Fixed for the life
        /// of the VM: VZ has no hotplug, so joining means a restart.
        private var podMembers: [String] = []
        /// Agents whose environment was cloned fresh for the running pod,
        /// so their system packages (apk) must be reinstalled.
        private var freshEnvironments: Set<String> = []
        /// Agents that asked for the sandbox this session, most recent
        /// first. Drives pod membership on the next boot.
        private var requestedMembers: [String] = []
        /// Foreground execs in flight per container id.
        private var inFlightExecs: [String: Int] = [:]
        /// Long-lived interactive processes (stdio MCP servers) by process
        /// id. One counts as running work only while a request is open.
        private var interactiveProcesses: [String: (containerID: String, activity: SandboxInteractiveActivity?)] = [:]
        /// Bumped on every pod teardown, so a stdio runner whose process
        /// exits can tell a restart from a crash.
        private var _podGeneration = 0
        public var podGeneration: Int { _podGeneration }
        /// Agent and workflow execs running at once, across every container.
        /// The rest wait in order, so a workflow map fan-out can't start tens
        /// of processes on a couple of vCPUs. Root/system execs are exempt so
        /// provisioning and health checks never queue behind user work.
        private var userExecLimit = SandboxManager.userExecLimit(cpus: SandboxConfiguration.default.cpus)
        private var userExecsRunning = 0
        private var userExecWaiters: [CheckedContinuation<Void, Never>] = []
        /// Last time an exec or interactive process started or ended; the
        /// idle shutdown measures from here.
        private var lastActivityAt = Date()
        private var idleWatchTask: Task<Void, Never>?
        /// Agents removed while their container was running; their
        /// environment clones are discarded before the next boot.
        private var pendingEnvironmentResets: Set<String> = []
        private var _removedByUser = false
        /// `true` from a public `stopContainer()` (Sandbox tab Stop, quit
        /// chain) until the next start. Lets `SandboxToolRegistrar` tell a
        /// deliberate stop apart from a VM that died: only the latter is a
        /// warm-restart candidate when the `.stopped` status edge arrives.
        private var _stoppedExplicitly = false
        public var stoppedExplicitly: Bool { _stoppedExplicitly }
        /// Test seam: the singleton outlives each test, and only a real
        /// container start clears the flag.
        func resetExplicitStopForTests() { _stoppedExplicitly = false }
        /// Agents in the running pod, and which of them booted from a
        /// fresh environment clone. `SandboxPluginManager` repairs plugins
        /// only for members, and reinstalls apk dependencies only for the
        /// fresh ones; the rest kept their packages on disk.
        public var podMemberNames: [String] { podMembers }
        public var freshlyClonedMembers: Set<String> { freshEnvironments }

        /// Wall-clock time the last successful provision reached
        /// `.running`. Read by `SandboxAgentProvisioner` to derive the
        /// boot → first-agent-ready phase for the local startup metrics.
        private var _lastBootReadyAt: Date?

        public var lastBootReadyAt: Date? { _lastBootReadyAt }

        /// Gateway host + port of the egress proxy while the VM has a
        /// network; `nil` with no network or when an open pod's proxy
        /// could not bind. Exec paths read this to inject `http_proxy` env
        /// into guest processes.
        private var egressProxyEndpoint: (host: String, port: Int)?

        /// Proxy credentials minted for one step's commands
        /// (`SandboxStepScope`), mapped to that step's hosts. Revoked
        /// when the exec returns.
        private var stepEgressGrants: [String: [String]] = [:]

        /// Proxy-only credentials for open members without a bridge token
        /// (workflow environments), so they keep the network in a filtered
        /// pod without gaining bridge access.
        private var openMemberEgressTokens: [String: String] = [:]

        /// Host-minted credential for root/system guest processes (apk
        /// dependency installs, the network readiness probe). Scoped to
        /// the package-registry allowlist only — it never widens an
        /// agent's own domain policy.
        private var systemEgressToken: String?

        /// Coalesces concurrent `startContainer()` calls. Without this,
        /// AppDelegate's auto-start, `SandboxToolRegistrar.start`,
        /// `SandboxAgentProvisioner.ensureProvisioned`, and the Sandbox
        /// settings panel's "Start" button can all fire near-simultaneously
        /// at launch and queue several full provision attempts (each one
        /// thrashing vmnet / the bridge socket). With coalescing, the first
        /// caller drives a single attempt and every other caller awaits the
        /// same task.
        private var inFlightStartTask: Task<Void, Error>?
        /// Cross-process vmnet ownership. Held for the complete VM lifetime,
        /// including warm running state, and released on stop or failed boot.
        private var vmOwnershipLease: SandboxVMOwnershipLease?

        /// True once the guest has confirmed outbound network reachability
        /// after the most recent boot. Cleared on every `stopContainer` /
        /// `cleanupAfterFailure` so the next boot re-verifies.
        private var networkReady: Bool = false

        /// In-flight readiness probe coalescing multiple `awaitNetworkReady`
        /// callers behind a single set of wget polls. Kicked off in the
        /// background by `configureSandbox` so the network is almost always
        /// already verified by the time anything actually needs it.
        private var networkReadyTask: Task<Bool, Never>?

        /// Background observer that watches `SandboxPluginManager.installProgress`
        /// after the container is up and drives the journey's
        /// `verifyPlugins` step (current activity + completion). Cancelled
        /// on `stopContainer` / `cleanupAfterFailure` so a torn-down
        /// container can't keep updating the journey of a future one.
        private var postStartVerifyTask: Task<Void, Never>?

        /// In-flight background runtime-asset prefetch (see
        /// `prefetchRuntimeAssetsInBackground`). Cancelled by
        /// `provision()` before it starts its own asset resolution so the
        /// two can't write the same partial files concurrently — the
        /// resumable download state carries over, so nothing is lost.
        private var prefetchTask: Task<Void, Never>?

        // MARK: - Observable State (MainActor bridge)

        @MainActor
        public final class State: ObservableObject {
            public static let shared = State()
            // Seed `availability` synchronously from the OS version so the
            // sandbox UI chip is visible from the very first frame on
            // macOS 26+. `refreshAvailability()` later re-asserts the same
            // value (or downgrades on older OSes); SwiftUI's @Published
            // diff makes the re-assignment a no-op when nothing changed.
            @Published public var availability: SandboxAvailability = State.initialAvailability
            @Published public var status: ContainerStatus = .notProvisioned
            /// Legacy: short human-readable label for the active step. Kept
            /// in lock-step with `journey?.steps[currentStep].label` so
            /// non-sandbox views that subscribe (chat booting badge,
            /// `NativeBlockViews`, the splash-shown migration overlay) keep
            /// working without code changes. Prefer reading `journey`
            /// when you need step granularity or progress.
            @Published public var provisioningPhase: String?
            /// Legacy: 0…1 indicator for the active step. Mirrors
            /// `journey?.steps[currentStep].progress` so existing observers
            /// (progress bars driven by the old single-line view) don't
            /// flatline now that journey is the source of truth.
            @Published public var provisioningProgress: Double?
            /// True while *any* fullscreen "Setting up sandbox" UI should
            /// be visible. The post-start `verifyPlugins` step intentionally
            /// flips this back to false even though the journey isn't yet
            /// `finished`, so the user gets the regular dashboard back as
            /// soon as the container is `.running`.
            @Published public var isProvisioning: Bool = false
            /// Structured journey snapshot — ordered step list with live
            /// per-step status, byte counters, rate, ETA. Republished on
            /// every step transition so SwiftUI sees stable `.equatable`
            /// diffs instead of a tangle of individual scalars.
            @Published public var journey: ProvisioningJourney?
            /// One-line "now doing" text the UI shows under the active
            /// step. Driven by download byte deltas, SDK `ProgressEvent`s,
            /// and (post-start) the current plugin's `InstallProgress`.
            @Published public var currentActivity: String?
            /// Most-recent container metrics snapshot. Lives here (instead
            /// of inside `SandboxView`'s `@State`) because
            /// `SidebarNavigation`'s `.id(selection)` destroys the view
            /// on every tab switch, which would otherwise wipe the
            /// cached metric tiles back to "nil" and flicker an empty
            /// dashboard until the next `info()` poll returned.
            @Published public var containerInfo: ContainerInfo?
            /// The running VM's composed network; nil when stopped.
            @Published public var podNetwork: SandboxPodNetwork?
            /// Mirror of `SandboxToolRegistrar.unavailabilityReason(for:)`
            /// for the currently active agent. Lets SwiftUI views (e.g. the
            /// sandbox chip) observe failures without coupling to the
            /// registrar singleton's internal `[UUID: …]` map. `nil` means
            /// "no failure recorded for the active agent".
            @Published public var activeAgentUnavailability: SandboxToolRegistrar.UnavailabilityReason?
            /// True while a consent-gated background prefetch of the
            /// runtime assets (kernel / initfs / sandbox image) is in
            /// flight. Distinct from `isProvisioning`: prefetch never
            /// boots the VM and never takes over the UI — the Sandbox
            /// settings panel can surface it as a passive indicator.
            @Published public var isPrefetchingRuntime: Bool = false

            private static var initialAvailability: SandboxAvailability {
                SandboxManager.resolveAvailability()
            }
        }

        // MARK: - Availability

        public func checkAvailability() async -> SandboxAvailability {
            if let cached = _availability { return cached }
            return await refreshAvailability()
        }

        /// Imported stdio MCP servers run only inside the VM sandbox; the
        /// Seatbelt fallback confines shell tools, not long-lived servers.
        public func supportsSandboxedStdio() async -> Bool {
            guard SandboxBackend.current == .virtualMachine else { return false }
            return await checkAvailability().isAvailable
        }

        /// Resolve the backend before an operation gates on availability.
        ///
        /// `State.shared.availability` is seeded synchronously for the UI,
        /// while the actor-local cache starts empty. A first-run Setup action
        /// can therefore reach `provision()` before another subsystem has
        /// called `checkAvailability()`. Gating directly on `_availability`
        /// rejects that legitimate first action even on a supported host.
        func requireAvailabilityForOperation() async throws {
            guard (await checkAvailability()).isAvailable else {
                throw SandboxError.unavailable
            }
        }

        public func refreshAvailability() async -> SandboxAvailability {
            _availability = nil

            let result = Self.resolveAvailability()
            _availability = result
            await MainActor.run { State.shared.availability = result }
            return result
        }

        /// Availability by backend. macOS 26+ always uses the VM. Older
        /// systems fall back to Seatbelt (`sandbox-exec`) host confinement
        /// when the binary is present — the fallback is never selected on
        /// macOS 26+ (see `SandboxBackend.current`).
        static func resolveAvailability() -> SandboxAvailability {
            switch SandboxBackend.current {
            case .virtualMachine:
                return .available
            case .seatbelt:
                return SeatbeltSandbox.isSupported
                    ? .available
                    : .unavailable(
                        reason:
                            "Requires macOS 26 or later (and no sandbox-exec fallback was found)"
                    )
            }
        }

        // MARK: - Container Status

        public func status() -> ContainerStatus {
            return _status
        }

        var staleContainerDir: URL {
            OsaurusPaths.container().appendingPathComponent("containers/\(SandboxPodLayout.podID)")
        }

        /// The shared mutable rootfs earlier versions booted every agent
        /// from. Deleted after the first pod boot: it holds every agent's
        /// leftovers, so no agent container may boot from it.
        private var legacySharedRootfs: URL {
            staleContainerDir.appendingPathComponent("rootfs.ext4")
        }

        private var hasRequiredAssets: Bool {
            let fm = FileManager.default
            return fm.fileExists(atPath: OsaurusPaths.containerKernelFile().path)
                && fm.fileExists(atPath: OsaurusPaths.containerInitFSFile().path)
        }

        /// Cache key for the immutable rootfs base template and the agent
        /// environments cloned from it: (image digest, rootfs format).
        nonisolated static var rootfsTemplateKey: String {
            SandboxRootfsTemplateStore.templateKey(
                imageReference: containerImage,
                runtimeFormatVersion: SandboxRuntimeAssets.rootfsFormatVersion
            )
        }

        /// Linux user name of the active agent, a pod member on every boot.
        /// Linux names of the agents whose sandbox is on, and the active
        /// agent's when it is one of them. Built-in agents never are.
        private static func sandboxAgentLinuxNames() async -> (active: String?, all: Set<String>) {
            await MainActor.run {
                let manager = AgentManager.shared
                let names = Set(
                    manager.agents.compactMap { agent -> String? in
                        guard manager.effectiveAutonomousExec(for: agent.id)?.enabled == true else { return nil }
                        return SandboxAgentProvisioner.linuxName(for: agent.id.uuidString)
                    }
                )
                let active = SandboxAgentProvisioner.linuxName(for: manager.activeAgent.id.uuidString)
                return (names.contains(active) ? active : nil, names)
            }
        }

        // MARK: - Pod membership

        /// Members for the next boot: the most recent requester (or the
        /// active agent, when its sandbox is on), then other recently used
        /// sandbox agents, up to the configured number of agents kept warm.
        private func selectPodMembers(cap: Int, excluding removed: Set<String> = []) async -> [String] {
            let sandboxAgents = await Self.sandboxAgentLinuxNames()
            let requester = requestedMembers.first ?? sandboxAgents.active
            let recentEnvironments = SandboxPodLayout.eligibleFillers(
                SandboxRootfsTemplateStore.listEnvironments().reversed().map(\.name),
                sandboxAgents: sandboxAgents.all
            )
            return SandboxPodLayout.selectMembers(
                requester: requester,
                recentFirst: (requestedMembers + podMembers + recentEnvironments).filter { !removed.contains($0) },
                cap: cap
            )
        }

        private func noteRequested(_ agentName: String) {
            requestedMembers.removeAll { $0 == agentName }
            requestedMembers.insert(agentName, at: 0)
            SandboxRootfsTemplateStore.touchEnvironment(agentName: agentName)
        }

        /// Make sure `agentName` has a container in the running pod. Pod
        /// membership is fixed at boot, so a newcomer joins through a
        /// restart: it waits for other agents' in-flight commands and
        /// background jobs (up to `membershipRestartMaxWait`), then reboots
        /// warm with the newcomer included. Coalesced with every other
        /// start through `inFlightStartTask`.
        private func ensureMember(_ agentName: String) async throws {
            guard SandboxBackend.current == .virtualMachine,
                SandboxPodLayout.isAgentName(agentName)
            else { return }
            noteRequested(agentName)
            if podMembers.contains(agentName) { return }
            if let existing = inFlightStartTask {
                try await existing.value
                if podMembers.contains(agentName) { return }
            }
            guard pod != nil else {
                try await startContainer()
                guard podMembers.contains(agentName) else {
                    throw SandboxError.containerNotRunning
                }
                return
            }
            let task = Task<Void, Error> { try await self.performMembershipRestart(joining: agentName) }
            inFlightStartTask = task
            defer { inFlightStartTask = nil }
            try await task.value
            guard podMembers.contains(agentName) else {
                throw SandboxError.provisionFailed("Sandbox restarted without a container for this agent")
            }
        }

        /// Wait (up to `membershipRestartMaxWait`) for running commands,
        /// background jobs, and open MCP requests to finish. Returns the
        /// wait and the containers still busy when it ended (empty when
        /// the pod went idle).
        private func waitForRunningWork() async throws -> (waited: TimeInterval, busy: [String]) {
            let waitStart = Date()
            await setActivity(L("Waiting for other agents to finish before preparing the sandbox"))
            while Date().timeIntervalSince(waitStart) < Self.membershipRestartMaxWait {
                if await activeWorkHolders().isEmpty { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let busy = await activeWorkHolders()
            await setActivity(nil)
            return (Date().timeIntervalSince(waitStart), busy)
        }

        /// A network restart deferred because the pod was busy.
        private var deferredNetworkRestart: Task<Void, Never>?

        /// Re-check the VM's network after an agent's Sandbox settings
        /// changed. When the running pod's composed network no longer
        /// matches its members' policies, restart it (after running work
        /// finishes); otherwise the proxy already reads policies live.
        public func networkPolicyChanged() async {
            guard SandboxBackend.current == .virtualMachine, pod != nil, inFlightStartTask == nil,
                let running = bootNetwork
            else { return }
            let desired = await Self.podNetwork(forMembers: podMembers)
            guard desired != running, pod != nil, inFlightStartTask == nil else { return }
            let task = Task<Void, Error> {
                let (waited, busy) = try await self.waitForRunningWork()
                guard busy.isEmpty else {
                    debugLog(
                        "[Sandbox] Network restart \(running.rawValue) -> \(desired.rawValue) deferred after \(String(format: "%.1f", waited))s; busy: \(busy.joined(separator: ", "))"
                    )
                    await self.scheduleDeferredNetworkRestart()
                    return
                }
                debugLog(
                    "[Sandbox] Network restart \(running.rawValue) -> \(desired.rawValue) after waiting \(String(format: "%.1f", waited))s"
                )
                try await self.performRestart()
            }
            inFlightStartTask = task
            defer { inFlightStartTask = nil }
            do {
                try await task.value
            } catch {
                debugLog("[Sandbox] Network restart failed: \(error)")
            }
        }

        private func setBootNetwork(_ network: SandboxPodNetwork?) {
            bootNetwork = network
            Task { @MainActor in State.shared.podNetwork = network }
        }

        private func scheduleDeferredNetworkRestart() {
            guard deferredNetworkRestart == nil else { return }
            deferredNetworkRestart = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                await self.clearDeferredNetworkRestart()
                await self.networkPolicyChanged()
            }
        }

        private func clearDeferredNetworkRestart() { deferredNetworkRestart = nil }

        /// Joining restarts the VM, which would stop every other
        /// container's work. Running work is never interrupted: when it is
        /// still running after the wait, the newcomer fails with `.busy`
        /// and stays first in line for the next boot.
        private func performMembershipRestart(joining agentName: String) async throws {
            let (waited, busy) = try await waitForRunningWork()
            let bucket = SandboxStartupMetricsStore.latencyBucket(waited)
            await MainActor.run {
                FeatureTelemetry.sandboxMembershipRestart(waitBucket: bucket, interruptedWork: false)
            }
            guard busy.isEmpty else {
                debugLog(
                    "[Sandbox] Membership restart for \(agentName) refused after \(String(format: "%.1f", waited))s; busy: \(busy.joined(separator: ", "))"
                )
                throw SandboxError.busy(holders: busy)
            }
            debugLog(
                "[Sandbox] Membership restart for \(agentName) after waiting \(String(format: "%.1f", waited))s"
            )
            try await performRestart()
        }

        /// Pod members with running work: a foreground exec, a live
        /// background job, or an MCP server with a request open.
        func activeWorkHolders() async -> [String] {
            var holders: Set<String> = []
            for (containerID, count) in inFlightExecs where count > 0 {
                holders.insert(Self.memberName(forContainerID: containerID))
            }
            for entry in interactiveProcesses.values where entry.activity?.isBusy == true {
                holders.insert(Self.memberName(forContainerID: entry.containerID))
            }
            for (agentName, pids) in await SandboxBackgroundJobs.shared.allJobs()
            where podMembers.contains(agentName) && !holders.contains(agentName) {
                for pid in pids where await BackgroundExecLiveness.isPidAlive(pid: pid, agentName: agentName) {
                    holders.insert(agentName)
                    break
                }
            }
            return holders.sorted()
        }

        nonisolated static func memberName(forContainerID containerID: String) -> String {
            containerID.hasPrefix("agent-") ? String(containerID.dropFirst("agent-".count)) : containerID
        }

        /// The stdio runner reports its process gone (stop or exit).
        public func interactiveProcessEnded(processID: String) {
            interactiveProcesses[processID] = nil
            lastActivityAt = Date()
            publishOccupancy()
        }

        // MARK: - Occupancy for task admission

        /// Members with a live background job as of the last check.
        private var backgroundHolders: Set<String> = []
        private var occupancyVersion = 0

        /// Mirrors who holds the VM to `SandboxPodOccupancy` without running
        /// anything in the guest; background jobs come from the last
        /// `refreshOccupancy`.
        private func publishOccupancy() {
            var holders = backgroundHolders.intersection(podMembers)
            for (containerID, count) in inFlightExecs where count > 0 {
                holders.insert(Self.memberName(forContainerID: containerID))
            }
            for entry in interactiveProcesses.values where entry.activity?.isBusy == true {
                holders.insert(Self.memberName(forContainerID: entry.containerID))
            }
            let snapshot = SandboxPodSnapshot(
                isRunning: pod != nil && _status.isRunning, members: Set(podMembers), busyHolders: holders)
            occupancyVersion += 1
            let version = occupancyVersion
            Task { @MainActor in SandboxPodOccupancy.shared.publish(snapshot, version: version) }
        }

        /// Re-checks which background jobs are still alive, then publishes.
        /// The task scheduler calls this while work waits on `sandbox_busy`.
        public func refreshOccupancy() async {
            var live: Set<String> = []
            if pod != nil {
                for (agentName, pids) in await SandboxBackgroundJobs.shared.allJobs()
                where podMembers.contains(agentName) {
                    for pid in pids where await BackgroundExecLiveness.isPidAlive(pid: pid, agentName: agentName) {
                        live.insert(agentName)
                        break
                    }
                }
            }
            backgroundHolders = live
            publishOccupancy()
        }

        /// A background job started for `agentName`.
        public func backgroundJobStarted(agentName: String) {
            backgroundHolders.insert(agentName)
            publishOccupancy()
        }

        // MARK: - Exec concurrency

        /// Concurrent agent/workflow execs for a VM with `cpus` vCPUs.
        nonisolated static func userExecLimit(cpus: Int) -> Int {
            max(4, cpus * 3)
        }

        private func acquireUserExecSlot() async throws {
            if userExecsRunning < userExecLimit {
                userExecsRunning += 1
            } else {
                // `releaseUserExecSlot` hands its slot straight to the
                // first waiter, so the count stays put.
                await withCheckedContinuation { userExecWaiters.append($0) }
            }
            if Task.isCancelled {
                releaseUserExecSlot()
                throw CancellationError()
            }
        }

        private func releaseUserExecSlot() {
            if userExecWaiters.isEmpty {
                userExecsRunning = max(0, userExecsRunning - 1)
            } else {
                userExecWaiters.removeFirst().resume()
            }
        }

        // MARK: - Idle shutdown

        /// Whether a running VM has sat idle long enough to stop. Any
        /// interactive process (a connected sandboxed MCP server) keeps it
        /// up, since stopping would disconnect it.
        nonisolated static func shouldStopWhenIdle(
            idleMinutes: Int, lastActivity: Date, now: Date,
            runningExecs: Int, interactiveProcesses: Int, workHolders: Int
        ) -> Bool {
            guard idleMinutes > 0, runningExecs == 0, interactiveProcesses == 0, workHolders == 0 else {
                return false
            }
            return now.timeIntervalSince(lastActivity) >= TimeInterval(idleMinutes * 60)
        }

        private func startIdleWatch() {
            idleWatchTask?.cancel()
            lastActivityAt = Date()
            idleWatchTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    if await self.stopIfIdle() { return }
                }
            }
        }

        /// Stops the VM when Stop When Idle applies. The stop counts as
        /// deliberate, so the status edge doesn't boot it straight back;
        /// the next agent or workflow that needs the sandbox starts it.
        /// Returns true once the watch has nothing left to do: the VM is no
        /// longer running (the next boot starts a fresh watch) or it stopped.
        private func stopIfIdle() async -> Bool {
            guard _status.isRunning, pod != nil else { return true }
            let minutes = SandboxConfigurationStore.load().idleShutdownMinutes
            guard minutes > 0, inFlightStartTask == nil else { return false }
            let running = inFlightExecs.values.reduce(0, +)
            guard
                Self.shouldStopWhenIdle(
                    idleMinutes: minutes, lastActivity: lastActivityAt, now: Date(),
                    runningExecs: running, interactiveProcesses: interactiveProcesses.count, workHolders: 0)
            else { return false }
            let holders = await activeWorkHolders()
            guard holders.isEmpty, interactiveProcesses.isEmpty, inFlightExecs.isEmpty else { return false }
            debugLog("[Sandbox] Stopping after \(minutes) idle minute(s)")
            do {
                try await stopContainer()
                return true
            } catch {
                debugLog("[Sandbox] Idle stop failed: \(error)")
                return false
            }
        }

        /// Drop cached runtime artifacts produced under an older runtime
        /// format. The initfs is rebuilt from the pinned `vminit` OCI
        /// artifact (or the raw-blob fallback) on the next provision.
        /// Idempotent and cheap when the stamp matches.
        private func invalidateStaleRuntimeArtifacts() {
            let config = SandboxConfigurationStore.load()
            guard config.lastRuntimeFormatVersion != SandboxRuntimeAssets.runtimeFormatVersion
            else { return }
            let initfs = OsaurusPaths.containerInitFSFile()
            if FileManager.default.fileExists(atPath: initfs.path) {
                debugLog(
                    "[Sandbox] Runtime format changed (\(config.lastRuntimeFormatVersion ?? "nil") -> \(SandboxRuntimeAssets.runtimeFormatVersion)); rebuilding initfs"
                )
                try? FileManager.default.removeItem(at: initfs)
            }
        }

        public func refreshStatus() async -> ContainerStatus {
            if SandboxBackend.current == .seatbelt {
                // No VM or on-disk assets to inspect — the Seatbelt backend
                // is "running" purely by virtue of having been provisioned
                // this session. `notProvisioned` is still meaningful:
                // it's what drives the first-run "Set Up Sandbox" flow and
                // keeps a user-removed sandbox removed until re-setup.
                if _status.isRunning {
                    _status = .running
                } else if _removedByUser || !SandboxConfigurationStore.load().setupComplete {
                    _status = .notProvisioned
                } else {
                    _status = .stopped
                }
                syncStatus()
                return _status
            }
            if case .error = _status {
                // `markRuntimeLost` flagged a dead VM whose SDK handle is
                // still held. Keep `.error` so `_performStartContainer`
                // takes its cleanup-then-reprovision branch instead of
                // trusting the stale handle as `.running`.
                syncStatus()
                return _status
            }
            if pod != nil {
                _status = .running
            } else if FileManager.default.fileExists(atPath: staleContainerDir.path) {
                // Container dir exists from a previous boot. With persistent
                // rootfs this is the normal case — the next provision picks
                // the warm path. `provision()` owns the wipe-vs-reuse
                // decision via `canWarmRestart`; if the rootfs turns out to
                // be corrupt the warm-path do/catch in `provision()` falls
                // back to a full cold rebuild.
                _status = .stopped
            } else if hasRequiredAssets {
                _status = .stopped
            } else {
                _status = .notProvisioned
            }
            syncStatus()
            return _status
        }

        // MARK: - Provisioning

        /// Configuration values threaded through the warm / cold create
        /// helpers so each helper has a single argument bundle instead of
        /// six positional parameters.
        private struct BootInputs {
            let workspace: URL
            let cpus: Int
            let memoryGB: Int
            /// Whether the pod attaches to the host network. Maps from
            /// `SandboxConfiguration.network` ("none" => no egress), which in
            /// turn mirrors the provisioning agent's
            /// `AutonomousExecConfig.sandboxNetworkEnabled`. Cutting egress
            /// is the network leg of the combined-mode exfiltration defense.
            let networkEnabled: Bool
        }

        /// The host workspace whose agent homes and `shared/` are mounted
        /// into the pod's containers. Centralised + guarded so the combined sandbox +
        /// host-read mode invariant cannot regress: no chat's selected
        /// folder is EVER a sandbox mount source. Combined mode reads
        /// the host folder through host-side tools only (`file_read`
        /// etc.); the sandbox has no mount of it, which is the entire
        /// security argument for the mode. Folder ownership is per chat
        /// session now, so the check runs against every live chat folder
        /// root in the process, not one global folder. If a future change
        /// ever wires a folder root in as the workspace, the precondition
        /// trips loudly instead of silently opening a hole. `nonisolated`
        /// so the regression test can exercise it without the actor hop.
        nonisolated static func validatedWorkspaceMountSource(
            workspace: String,
            folderRoots: [String]
        ) -> String {
            let normalizedWorkspace = URL(fileURLWithPath: workspace).standardized.path
            for folderRoot in folderRoots {
                let normalizedFolder = URL(fileURLWithPath: folderRoot).standardized.path
                precondition(
                    normalizedWorkspace != normalizedFolder,
                    "Sandbox workspace mount must never be a chat's host folder root — "
                        + "combined mode reads the host via host-side tools, never a bind mount."
                )
            }
            return workspace
        }

        /// An agent's own egress policy from its Sandbox settings.
        @MainActor static func egressMode(forAgentId id: UUID) -> SandboxEgressMode {
            let exec = AgentManager.shared.effectiveAutonomousExec(for: id)
            return SandboxEgressPolicy.mode(
                networkEnabled: exec?.sandboxNetworkEnabled ?? true,
                allowedDomains: exec?.sandboxAllowedDomains
            )
        }

        /// A pod member's policy. Agent members are named by their agent id;
        /// workflow environments and diagnostics have no agent and are open.
        @MainActor static func egressMode(forMember agentName: String) -> SandboxEgressMode {
            guard let id = UUID(uuidString: agentName) else { return .open }
            return egressMode(forAgentId: id)
        }

        static func podNetwork(forMembers members: [String]) async -> SandboxPodNetwork {
            await MainActor.run {
                SandboxEgressPolicy.podNetwork(for: members.map { egressMode(forMember: $0) })
            }
        }

        /// Seatbelt confines each exec separately, so it applies the caller's
        /// own policy. It has no proxy, so a domain allowlist fails closed to
        /// no network. System execs (setup, diagnostics) keep the network.
        @MainActor static func seatbeltNetwork(forUser user: String?) -> SeatbeltSandbox.NetworkPolicy {
            guard let user, user.hasPrefix("agent-") else { return .allowed }
            return seatbeltNetwork(for: egressMode(forMember: String(user.dropFirst("agent-".count))))
        }

        nonisolated static func seatbeltNetwork(for mode: SandboxEgressMode) -> SeatbeltSandbox.NetworkPolicy {
            mode == .open ? .allowed : .denied
        }

        /// Seatbelt cannot filter by host, so a step scope with no hosts
        /// takes the network away and one with hosts keeps the caller's.
        nonisolated static func seatbeltNetwork(
            _ caller: SeatbeltSandbox.NetworkPolicy, stepHosts: [String]?
        ) -> SeatbeltSandbox.NetworkPolicy {
            guard let stepHosts else { return caller }
            return SandboxEgressPolicy.normalizedAllowlist(stepHosts).isEmpty ? .denied : caller
        }

        /// VM size for a boot. Since Containerization 0.54 the VM is sized
        /// only by `VMResources` (default 4 vCPU / 1 GiB) and the
        /// configuration's `cpus` / `memoryInBytes` are just cgroup limits,
        /// so the configured size must be passed explicitly. One spare vCPU
        /// and `guestMemoryOverhead` for the guest kernel and vminitd match
        /// the sizing earlier SDKs applied implicitly.
        nonisolated static func vmResources(cpus: Int, memoryGB: Int) -> VMResources {
            VMResources(
                cpus: cpus + 1,
                memoryInBytes: UInt64(memoryGB).gib() + VMResources.guestMemoryOverhead
            )
        }

        /// Apply the same explicit process boundary to init and every exec
        /// path. Kept as a pure seam so the capability contract can be tested
        /// without booting a VM.
        nonisolated static func applyProcessRestrictions(
            to config: inout LinuxProcessConfiguration
        ) {
            config.capabilities = .defaultOCICapabilities
            config.noNewPrivileges = true
        }

        /// SDK default container mounts with `/proc` mounted `hidepid=2`, so
        /// an agent user sees only its own processes. Root in the container
        /// can't remount it (no `CAP_SYS_ADMIN`), so it must be set here.
        nonisolated static func containerBaseMounts() -> [Containerization.Mount] {
            LinuxContainer.defaultMounts().map { mount in
                guard mount.type == "proc", mount.destination == "/proc" else { return mount }
                var proc = mount
                proc.options += ["nosuid", "noexec", "nodev", "hidepid=2"]
                return proc
            }
        }

        /// Limits for commands run as an agent user (not root setup execs):
        /// a fork bomb or descriptor leak stops at the agent's own UID, and
        /// crashes don't write core files into the agent's environment.
        nonisolated static let agentRLimits: [LinuxRLimit] = [
            LinuxRLimit(kind: .numberOfProcesses, limit: 4096),
            LinuxRLimit(kind: .openFiles, limit: 65536),
            LinuxRLimit(kind: .coreFileSize, limit: 0),
        ]

        /// Cold path: unpack the pinned image (8 GiB ext4) straight into the
        /// immutable base template every pod container is cloned from.
        /// Drives the `.createContainer` step start → end.
        private func unpackTemplate(
            image: Containerization.Image,
            templateKey: String,
            detail: String
        ) async throws {
            await startStep(.createContainer, detail: detail)
            let staging = SandboxRootfsTemplateStore.stagingFile(key: templateKey)
            do {
                try OsaurusPaths.ensureExists(staging.deletingLastPathComponent())
                if FileManager.default.fileExists(atPath: staging.path) {
                    try FileManager.default.removeItem(at: staging)
                }
                _ = try await EXT4Unpacker(capacityInBytes: 8.gib()).unpack(
                    image,
                    for: .current,
                    at: staging,
                    progress: Self.makeContainerCreateProgressHandler(stepID: .createContainer)
                )
                try SandboxRootfsTemplateStore.installTemplate(key: templateKey)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                await endStep(.createContainer, status: .failed)
                throw error
            }
            await endStep(.createContainer, status: .completed)
        }

        /// Write the host-bridge shim into its own directory. A file mount
        /// shares the file's parent directory with the VM, so nothing else
        /// may live next to it.
        private func stageShim() throws {
            let file = SandboxPodLayout.shimFile(containerRoot: OsaurusPaths.container())
            let dir = file.deletingLastPathComponent()
            let fm = FileManager.default
            if fm.fileExists(atPath: dir.path) {
                for entry in try fm.contentsOfDirectory(atPath: dir.path) where entry != file.lastPathComponent {
                    try fm.removeItem(at: dir.appendingPathComponent(entry))
                }
            }
            try OsaurusPaths.ensureExists(dir)
            if fm.fileExists(atPath: file.path) {
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            }
            try Data(Self.osaurusHostShimScript.utf8).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: file.path)
        }

        /// Assemble the pod: the system container plus one container per
        /// member, each booting its own environment clone of the template
        /// with only its own mounts and bridge socket. Records which
        /// environments had to be cloned fresh.
        private func buildPod(
            kernel: Kernel,
            initfs: Containerization.Mount,
            inputs: BootInputs,
            specs: [SandboxPodLayout.ContainerSpec],
            templateKey: String
        ) async throws -> LinuxPod {
            var fresh: Set<String> = []
            var rootfsByID: [String: URL] = [:]
            for spec in specs {
                if !SandboxRootfsTemplateStore.environmentIsValid(agentName: spec.environmentName, key: templateKey) {
                    fresh.insert(spec.environmentName)
                }
                rootfsByID[spec.id] = try SandboxRootfsTemplateStore.ensureEnvironment(
                    agentName: spec.environmentName,
                    key: templateKey
                )
                for mount in spec.mounts where !mount.readOnly {
                    try OsaurusPaths.ensureExists(URL(fileURLWithPath: mount.source))
                }
            }
            SandboxRootfsTemplateStore.excludeFromBackups()
            freshEnvironments = fresh.subtracting([SandboxPodLayout.systemEnvironmentName])
            WorkflowSandboxEnvironment.environmentsReset(freshEnvironments)

            try OsaurusPaths.ensureExists(staleContainerDir)
            let bootLog = BootLog.file(path: staleContainerDir.appendingPathComponent("bootlog.log"))
            var interface: (any Interface)?
            if inputs.networkEnabled, var network = podNetwork {
                interface = try network.createInterface(SandboxPodLayout.podID)
                podNetwork = network
            }
            let vmm = VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs)
            let pod = try LinuxPod(
                SandboxPodLayout.podID,
                vmm: vmm,
                vm: Self.vmResources(cpus: inputs.cpus, memoryGB: inputs.memoryGB)
            ) { config in
                config.shareProcessNamespace = false
                config.bootLog = bootLog
                if let interface {
                    config.interfaces = [interface]
                    if let gateway = interface.ipv4Gateway {
                        config.dns = DNS(nameservers: [gateway.description])
                    }
                }
            }

            let containerRoot = OsaurusPaths.container()
            let cpus = inputs.cpus
            let memory = UInt64(inputs.memoryGB).gib()
            for spec in specs {
                guard let rootfsURL = rootfsByID[spec.id] else { continue }
                let rootfs = Containerization.Mount.block(
                    format: "ext4",
                    source: rootfsURL.absolutePath(),
                    destination: "/",
                    options: []
                )
                let mounts = spec.mounts
                let socketPath = SandboxPodLayout.bridgeSocketPath(
                    linuxName: spec.bridgeLinuxName,
                    containerRoot: containerRoot
                )
                try await pod.addContainer(spec.id, rootfs: rootfs) { config in
                    // cgroup limits only; the VM itself is sized by `vmResources`.
                    config.cpus = cpus
                    config.memoryInBytes = memory
                    config.process.arguments = ["sleep", "infinity"]
                    config.process.workingDirectory = "/"
                    config.mounts = Self.containerBaseMounts()
                    // Pin the security boundary explicitly instead of
                    // inheriting SDK defaults. Pod execs inherit this config.
                    Self.applyProcessRestrictions(to: &config.process)
                    config.mounts += mounts.map {
                        .share(source: $0.source, destination: $0.destination, options: $0.readOnly ? ["ro"] : [])
                    }
                    // Without explicit permissions the guest socket is mode
                    // 0000 and only root could reach the bridge.
                    config.sockets = [
                        UnixSocketConfiguration(
                            source: URL(fileURLWithPath: socketPath),
                            destination: URL(fileURLWithPath: SandboxPodLayout.guestBridgeSocketPath),
                            permissions: FilePermissions(rawValue: 0o666),
                            direction: .into
                        )
                    ]
                }
            }
            return pod
        }

        /// Resolve the pinned sandbox image, pulling it when the local
        /// content store doesn't have it yet. Runs concurrently with
        /// kernel/initfs resolution in `provision()` so the three network
        /// fetches overlap instead of serializing — image work no longer
        /// waits for kernel/initfs completion. When `reportProgress` is
        /// set (cold path), pull bytes stream into the `.createContainer`
        /// journey step; the warm path leaves its pre-skipped step alone.
        private func fetchSandboxImage(
            store: ImageStore,
            reportProgress: Bool
        ) async throws -> Containerization.Image {
            if let local = try? await store.get(reference: Self.containerImage) {
                return local
            }
            if reportProgress {
                await startStep(.createContainer, detail: L("Pulling sandbox image"))
            }
            let progress =
                reportProgress
                ? Self.makeContainerCreateProgressHandler(stepID: .createContainer)
                : nil
            do {
                return try await store.pull(
                    reference: Self.containerImage,
                    progress: progress,
                    maxConcurrentDownloads: 4
                )
            } catch {
                if reportProgress {
                    await failOrResetStep(.createContainer, after: error)
                }
                throw error
            }
        }

        private func fetchSandboxImageIfNeeded(
            store: ImageStore,
            needed: Bool
        ) async throws -> Containerization.Image? {
            guard needed else { return nil }
            return try await fetchSandboxImage(store: store, reportProgress: true)
        }

        /// One-time move from the pre-pod layout, where the whole workspace
        /// was mounted: no container mounts the workspace root any more, so
        /// loose files there move to `shared/` (or
        /// `shared/legacy-workspace-root/` on a name collision), and the old
        /// shim staging file is dropped.
        nonisolated static func migrateWorkspaceRoot(_ workspace: URL) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(atPath: workspace.path) else { return }
            let shared = workspace.appendingPathComponent("shared", isDirectory: true)
            for name in entries where name != "agents" && name != "shared" {
                let source = workspace.appendingPathComponent(name)
                if name == ".osaurus-host-shim" || name == ".DS_Store" {
                    try? fm.removeItem(at: source)
                    continue
                }
                var destination = shared.appendingPathComponent(name)
                if fm.fileExists(atPath: destination.path) {
                    let legacy = shared.appendingPathComponent("legacy-workspace-root", isDirectory: true)
                    try? fm.createDirectory(at: legacy, withIntermediateDirectories: true)
                    destination = legacy.appendingPathComponent(name)
                    if fm.fileExists(atPath: destination.path) { continue }
                }
                try? fm.moveItem(at: source, to: destination)
            }
        }

        private struct ProxyGateway {
            let address: String
            let required: Bool
        }

        /// Boot the pod: VM create → bridge ready → container starts.
        /// Drives the `.startContainer` and `.startBridge` journey steps.
        /// Throws on any SDK failure; caller is responsible for cleanup.
        private func bootPod(
            _ pod: LinuxPod,
            containerIDs: [String],
            bridge: Task<Void, Error>,
            proxyGateway: ProxyGateway?
        ) async throws {
            await startStep(.startContainer, detail: L("Booting Linux VM"))
            try await pod.create()
            // The gateway address exists on the host only once the VM's
            // interface is up, so the proxy binds here. A filtered pod fails
            // closed: no container (and so no agent process) starts without
            // it. An open pod boots anyway; step-scoped execs then get a
            // proxy address nothing listens on.
            if let proxyGateway {
                do {
                    try await startEgressProxy(gateway: proxyGateway.address)
                } catch where !proxyGateway.required {
                    debugLog("[Sandbox] Egress proxy unavailable in the open pod: \(error)")
                }
            }
            // Bridges must be bound before the containers start — that's
            // when the guest attaches the relayed sockets.
            try await bridge.value
            await endStep(.startBridge, status: .completed)
            for id in containerIDs {
                try await pod.startContainer(id)
            }
            await endStep(.startContainer, status: .completed)
        }

        /// Resolve the `.startBridge` step into its final status by
        /// inspecting whether the bridge Task itself succeeded. Used
        /// from cold-create's catch path where the create failure may
        /// or may not be the bridge's fault.
        private func resolveBridgeStep(bridge: Task<Void, Error>) async {
            do {
                try await bridge.value
                await endStep(.startBridge, status: .completed)
            } catch {
                await endStep(.startBridge, status: .failed)
            }
        }

        /// Stop the pod (if any) and release its vmnet interface.
        private func teardownPod() async {
            if let pod {
                try? await pod.stop()
            }
            pod = nil
            SandboxMemoryReservation.vmStopped()
            backgroundHolders = []
            podMembers = []
            inFlightExecs = [:]
            interactiveProcesses = [:]
            _podGeneration += 1
            publishOccupancy()
            if var network = podNetwork {
                try? network.releaseInterface(SandboxPodLayout.podID)
            }
            podNetwork = nil
            setBootNetwork(nil)
        }

        /// "Provision" the Seatbelt fallback: no VM, no image download —
        /// just make sure the host workspace tree exists and flip status
        /// to running. Instant, so none of the journey/progress UI runs.
        private func provisionSeatbelt() throws {
            guard SeatbeltSandbox.isSupported else {
                throw SandboxError.provisionFailed(
                    "sandbox-exec not found at \(SeatbeltSandbox.sandboxExecPath)")
            }
            let fm = FileManager.default
            for dir in [
                OsaurusPaths.containerWorkspace(),
                OsaurusPaths.containerAgentsDir(),
                OsaurusPaths.containerSharedDir(),
            ] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            var config = SandboxConfigurationStore.load()
            if !config.setupComplete {
                config.setupComplete = true
                SandboxConfigurationStore.save(config)
            }
            _status = .running
            _lastBootReadyAt = Date()
            syncStatus()
            let workspacePath = OsaurusPaths.containerWorkspace().path
            Task { @MainActor in
                SandboxLogBuffer.shared.append(
                    level: .info,
                    message:
                        "Seatbelt backend ready — commands run under sandbox-exec confinement (workspace: \(workspacePath))",
                    source: "seatbelt"
                )
            }
        }

        /// Provision and boot through the coalesced start path, which holds
        /// the VM ownership lease for the whole boot.
        public func provision() async throws {
            _removedByUser = false
            try await startContainer()
        }

        /// Callers must hold the VM ownership lease (`startContainer`,
        /// `performRestart`).
        private func performProvision() async throws {
            try await requireAvailabilityForOperation()
            _removedByUser = false

            if SandboxBackend.current == .seatbelt {
                try provisionSeatbelt()
                return
            }

            // Take over from any in-flight background prefetch. The
            // journey-driven asset resolution below resumes whatever
            // partial state the prefetch persisted, so cancelling here
            // discards no bytes.
            if let prefetch = prefetchTask {
                prefetch.cancel()
                await prefetch.value
                prefetchTask = nil
            }

            // A runtime-format change (SDK upgrade, initfs delivery change)
            // must invalidate the cached initfs BEFORE `hasRequiredAssets`
            // decides which journey steps to plan.
            invalidateStaleRuntimeArtifacts()

            let config = SandboxConfigurationStore.load()
            let isRestart = hasRequiredAssets
            let templateKey = Self.rootfsTemplateKey
            for agentName in pendingEnvironmentResets {
                try? SandboxRootfsTemplateStore.resetEnvironment(agentName: agentName)
            }
            let removedAgents = pendingEnvironmentResets.subtracting(requestedMembers)
            pendingEnvironmentResets = []
            let members = await selectPodMembers(
                cap: config.maxAgentEnvironments,
                excluding: removedAgents
            )
            let workspace = URL(
                fileURLWithPath: Self.validatedWorkspaceMountSource(
                    workspace: OsaurusPaths.containerWorkspace().path,
                    folderRoots: ChatFolderState.liveRootPaths
                )
            )
            let specs = SandboxPodLayout.containers(
                members: members,
                workspace: workspace,
                containerRoot: OsaurusPaths.container()
            )
            let hasTemplate = SandboxRootfsTemplateStore.hasTemplate(key: templateKey)
            let allEnvironmentsValid = specs.allSatisfy {
                SandboxRootfsTemplateStore.environmentIsValid(agentName: $0.environmentName, key: templateKey)
            }
            let hasPlugins = await Self.installedPluginsRequireVerify()

            // Pre-mark cached steps `.skipped` so the UI shows checkmarks
            // rather than spinners that never tick. With a template on disk
            // the image unpack is skipped too (environment clones are
            // milliseconds).
            let planned = plannedSteps(
                isRestart: isRestart,
                isWarmRestart: hasTemplate,
                hasPlugins: hasPlugins
            )
            await beginJourney(steps: planned)

            // Local phase clocks (see `SandboxStartupMetrics`). Full
            // fidelity is persisted locally; telemetry sees only a
            // coarse bucket + warm/cold kind.
            let provisionStart = Date()
            var assetSeconds: Double?
            var createSeconds: Double?
            var vmBootSeconds: Double?
            var configureSeconds: Double?
            var bootKind: SandboxBootSample.BootKind =
                hasTemplate ? (allEnvironmentsValid ? .warm : .template) : .cold

            do {
                // Resolve kernel + initfs (+ the sandbox image when there is
                // no template to clone) concurrently. Each short-circuits
                // when already cached, and on the cold path the network
                // fetches overlap instead of serializing. Each future drives
                // its own journey step so the UI shows per-asset progress.
                let imageStore = try ImageStore(path: OsaurusPaths.container())
                async let kernelFuture = ensureKernel()
                async let initfsFuture = ensureInitFS(store: imageStore)
                async let imageFuture = fetchSandboxImageIfNeeded(
                    store: imageStore,
                    needed: !hasTemplate
                )
                let (kernel, initfs, prefetchedImage) = try await (kernelFuture, initfsFuture, imageFuture)
                assetSeconds = Date().timeIntervalSince(provisionStart)

                try ensureHostDirectories()
                Self.migrateWorkspaceRoot(workspace)
                try stageShim()

                if #available(macOS 26, *) {
                    // Bring up one host bridge listener per container
                    // concurrently with the rootfs work. Each only needs to
                    // be listening by the time its container starts (that's
                    // when the guest attaches the relayed socket), and each
                    // accepts only its own container's agent identity.
                    await startStep(.startBridge, detail: L("Binding host socket"))
                    let containerRoot = OsaurusPaths.container()
                    let bindings = specs.map {
                        HostAPIBridgeServer.SocketBinding(
                            path: SandboxPodLayout.bridgeSocketPath(
                                linuxName: $0.bridgeLinuxName,
                                containerRoot: containerRoot
                            ),
                            linuxName: $0.bridgeLinuxName
                        )
                    }
                    let bridgeStarted = Task {
                        try await HostAPIBridgeServer.shared.start(bindings: bindings)
                    }

                    // The network is composed from the members' own
                    // policies. Filtered boots on a host-only vmnet: the
                    // guest reaches only the gateway, where the proxy
                    // applies each caller's policy. NAT is every member
                    // open; no network creates no vmnet at all.
                    let network = await Self.podNetwork(forMembers: members)
                    setBootNetwork(network)
                    let networkEnabled = network != .none
                    var proxyGateway: ProxyGateway?
                    await teardownEgressProxy()
                    if networkEnabled {
                        let vmnet: VmnetNetwork
                        if network == .filtered {
                            vmnet = try VmnetNetwork(mode: .VMNET_HOST_MODE)
                            proxyGateway = ProxyGateway(address: vmnet.ipv4Gateway.description, required: true)
                        } else {
                            vmnet = try VmnetNetwork()
                            proxyGateway = ProxyGateway(address: vmnet.ipv4Gateway.description, required: false)
                        }
                        podNetwork = vmnet
                    }

                    let inputs = BootInputs(
                        workspace: workspace,
                        cpus: config.cpus,
                        memoryGB: config.memoryGB,
                        networkEnabled: networkEnabled
                    )
                    let containerIDs = specs.map(\.id)

                    if !hasTemplate, let prefetchedImage {
                        // Cold path. Layers were already pulled (or found
                        // locally) by the concurrent fetch, so this only
                        // unpacks the image into the base template.
                        let createStart = Date()
                        do {
                            try await unpackTemplate(
                                image: prefetchedImage,
                                templateKey: templateKey,
                                detail: L("Unpacking sandbox image")
                            )
                        } catch {
                            await resolveBridgeStep(bridge: bridgeStarted)
                            throw error
                        }
                        createSeconds = Date().timeIntervalSince(createStart)
                    }

                    do {
                        let createStart = Date()
                        let built = try await buildPod(
                            kernel: kernel,
                            initfs: initfs,
                            inputs: inputs,
                            specs: specs,
                            templateKey: templateKey
                        )
                        if createSeconds == nil {
                            createSeconds = Date().timeIntervalSince(createStart)
                        }
                        // Publish so `cleanupAfterFailure` can tear down
                        // partial state if the boot throws.
                        self.pod = built
                        let bootStart = Date()
                        try await bootPod(
                            built, containerIDs: containerIDs, bridge: bridgeStarted, proxyGateway: proxyGateway)
                        vmBootSeconds = Date().timeIntervalSince(bootStart)
                    } catch where hasTemplate {
                        // A clone that won't boot means the template lineage
                        // can't be trusted: drop the template and every
                        // member's clone, unpack fresh, and retry once.
                        debugLog(
                            "[Sandbox] Pod boot from template failed (\(error.localizedDescription)), falling back to full unpack"
                        )
                        bootKind = .warmFallback
                        if let pod { try? await pod.stop() }
                        pod = nil
                        // The rebuild allocates the pod's interface again.
                        if var network = podNetwork {
                            try? network.releaseInterface(SandboxPodLayout.podID)
                            podNetwork = network
                        }
                        await resetStepStatus(.createContainer, to: .pending)
                        await resetStepStatus(.startContainer, to: .pending)
                        SandboxRootfsTemplateStore.invalidateTemplate(key: templateKey)
                        for spec in specs {
                            try? SandboxRootfsTemplateStore.resetEnvironment(agentName: spec.environmentName)
                        }
                        let image = try await fetchSandboxImage(store: imageStore, reportProgress: true)
                        let createStart = Date()
                        try await unpackTemplate(
                            image: image,
                            templateKey: templateKey,
                            detail: L("Unpacking cached image")
                        )
                        let rebuilt = try await buildPod(
                            kernel: kernel,
                            initfs: initfs,
                            inputs: inputs,
                            specs: specs,
                            templateKey: templateKey
                        )
                        createSeconds = Date().timeIntervalSince(createStart)
                        self.pod = rebuilt
                        let bootStart = Date()
                        try await bootPod(
                            rebuilt, containerIDs: containerIDs, bridge: bridgeStarted, proxyGateway: proxyGateway)
                        vmBootSeconds = Date().timeIntervalSince(bootStart)
                    }
                    podMembers = members
                    SandboxMemoryReservation.vmStarted(
                        bytes: Self.vmResources(cpus: inputs.cpus, memoryGB: inputs.memoryGB).memoryInBytes)
                } else {
                    throw SandboxError.provisionFailed("The sandbox VM requires macOS 26 or later")
                }

                await startStep(.configureSandbox, detail: L("Installing in-guest shim"))
                let configureStart = Date()
                try await configureSandbox()
                configureSeconds = Date().timeIntervalSince(configureStart)
                await endStep(.configureSandbox, status: .completed)

                _status = .running
                syncStatus()
                userExecLimit = Self.userExecLimit(cpus: config.cpus)
                startIdleWatch()
                publishOccupancy()

                // Persist full-fidelity phase timings locally and emit a
                // coarse consent-gated bucket. The first-agent-ready field
                // is stamped later by `SandboxAgentProvisioner`.
                let totalToRunning = Date().timeIntervalSince(provisionStart)
                _lastBootReadyAt = Date()
                let bootSample = SandboxBootSample(
                    kind: bootKind,
                    startedAt: provisionStart,
                    assetResolution: assetSeconds,
                    containerCreate: createSeconds,
                    vmBoot: vmBootSeconds,
                    configure: configureSeconds,
                    totalToRunning: totalToRunning
                )
                SandboxStartupMetricsStore.record(bootSample)
                let bootKindToken = bootKind.rawValue
                let bootBucket = SandboxStartupMetricsStore.latencyBucket(totalToRunning)
                let dominantPhase = bootSample.dominantPhase
                await MainActor.run {
                    FeatureTelemetry.sandboxBoot(
                        kind: bootKindToken, durationBucket: bootBucket, dominantPhase: dominantPhase)
                }

                var savedConfig = SandboxConfigurationStore.load()
                let currentVersion = SandboxBridgeMigrationFlag.currentAppVersion
                var configChanged = false
                if !savedConfig.setupComplete {
                    savedConfig.setupComplete = true
                    configChanged = true
                }
                // Stamp the binary version that just succeeded a provision so
                // the Sandbox settings banner can detect when an upgraded
                // binary still hasn't restarted the container — the
                // post-#950 token migration is lazy on container restart.
                if savedConfig.lastProvisionedAppVersion != currentVersion {
                    savedConfig.lastProvisionedAppVersion = currentVersion
                    configChanged = true
                }
                // Stamp the image reference this boot ran against so the
                // next `provision()` knows whether `rootfs.ext4` is reusable.
                // An app update that bumps the pinned digest invalidates
                // the warm path automatically.
                if savedConfig.lastBootedImageDigest != Self.containerImage {
                    savedConfig.lastBootedImageDigest = Self.containerImage
                    configChanged = true
                }
                // Stamp the runtime format (SDK/initfs pair, keys the
                // initfs) and the rootfs format (keys the warm rootfs with
                // the image digest).
                if savedConfig.lastRuntimeFormatVersion != SandboxRuntimeAssets.runtimeFormatVersion {
                    savedConfig.lastRuntimeFormatVersion = SandboxRuntimeAssets.runtimeFormatVersion
                    configChanged = true
                }
                if savedConfig.lastRootfsFormatVersion != SandboxRuntimeAssets.rootfsFormatVersion {
                    savedConfig.lastRootfsFormatVersion = SandboxRuntimeAssets.rootfsFormatVersion
                    configChanged = true
                }
                if configChanged {
                    SandboxConfigurationStore.save(savedConfig)
                }

                // The shared rootfs of the pre-pod layout is unreachable
                // now; reclaim its 8 GiB.
                if FileManager.default.fileExists(atPath: legacySharedRootfs.path) {
                    try? FileManager.default.removeItem(at: legacySharedRootfs)
                }

                // Bound the environment pool: stale clones (old template
                // key) and least-recently-used clones beyond the cap are
                // evicted. The running pod's environments are protected.
                let evicted = SandboxRootfsTemplateStore.enforceLimit(
                    max: config.effectiveRetainedEnvironments,
                    currentKey: templateKey,
                    protecting: Set(specs.map(\.environmentName))
                )
                if !evicted.isEmpty {
                    debugLog("[Sandbox] Evicted agent environments: \(evicted.joined(separator: ", "))")
                    WorkflowSandboxEnvironment.environmentsReset(evicted)
                }

                // Bring the dashboard back immediately. When plugins
                // need verifying we keep the journey alive (the
                // verifyPlugins step is `.inProgress`) so the post-start
                // tasks card can render it; the legacy `isProvisioning`
                // flag is still flipped to `false` via
                // `concludeProvisioningPhase` so the fullscreen progress
                // view drops out and the dashboard takes over.
                if hasPlugins {
                    await startStep(.verifyPlugins, detail: L("Restoring plugin dependencies"))
                    await concludeProvisioningPhase()
                    startPostStartVerifyObserver()
                } else {
                    await finishJourney(success: true)
                }
            } catch {
                debugLog("[Sandbox] Provision failed: \(error)")
                // Mark the active step failed so the UI's last visible
                // row turns red instead of stuck "in progress".
                await markActiveStepFailed()
                await finishJourney(success: false)
                await cleanupAfterFailure()
                throw error
            }
        }

        // MARK: - Background Runtime Prefetch

        /// Background download of every runtime asset the next provision
        /// needs — bundled-kernel install, `vminit` OCI initfs, and the
        /// pinned sandbox image — WITHOUT booting the VM or taking over the
        /// UI. Runs once onboarding has finished on VM-capable Macs, so the
        /// first sandboxed command boots from cache.
        ///
        /// Idempotent and cheap when everything is cached. All downloads
        /// are resumable, so an app quit mid-prefetch loses nothing.
        /// `provision()` cancels an in-flight prefetch before starting
        /// its own (journey-visible) asset resolution.
        public func prefetchRuntimeAssetsInBackground() {
            guard prefetchTask == nil else { return }
            guard inFlightStartTask == nil, pod == nil else { return }
            prefetchTask = Task { [weak self] in
                await self?.runRuntimePrefetch()
            }
        }

        private func runRuntimePrefetch() async {
            defer {
                prefetchTask = nil
                Task { @MainActor in State.shared.isPrefetchingRuntime = false }
            }
            // Seatbelt hosts run no VM and have no kernel/initfs/image to fetch.
            guard SandboxBackend.current == .virtualMachine else { return }
            guard (await checkAvailability()).isAvailable else { return }
            await MainActor.run { State.shared.isPrefetchingRuntime = true }

            invalidateStaleRuntimeArtifacts()
            do {
                let imageStore = try ImageStore(path: OsaurusPaths.container())
                async let kernelFuture: Kernel = ensureKernel()
                async let initfsFuture: Containerization.Mount = ensureInitFS(store: imageStore)
                async let imageFuture: Containerization.Image = fetchSandboxImage(
                    store: imageStore,
                    reportProgress: false
                )
                _ = try await (kernelFuture, initfsFuture, imageFuture)
                debugLog("[Sandbox] Runtime prefetch complete — next provision boots from cache")
            } catch is CancellationError {
                debugLog("[Sandbox] Runtime prefetch handed off (cancelled)")
            } catch {
                // Best-effort: the next provision retries with the full
                // journey UI and real error surfacing.
                debugLog("[Sandbox] Runtime prefetch failed: \(error.localizedDescription)")
            }
        }

        /// MainActor helper — counts installed `.ready` plugins so
        /// `plannedSteps` knows whether to include a `verifyPlugins`
        /// step. Lightweight; avoids a full registry walk on every boot.
        @MainActor
        private static func installedPluginsRequireVerify() -> Bool {
            for (_, plugins) in SandboxPluginManager.shared.installedPlugins
            where plugins.contains(where: { $0.status == .ready }) {
                return true
            }
            return false
        }

        /// Flip the journey's currently-active step to `.failed` so the
        /// user sees which step is responsible for the error message we
        /// surface from `provision()`. Walks the steps in case a callee
        /// left `currentStepID` unset (e.g. an SDK throw that bypassed
        /// our `endStep`).
        @MainActor
        private func markActiveStepFailed() {
            guard var journey = State.shared.journey else { return }
            // The step that threw already marked itself; with concurrent
            // asset steps, `currentStepID` may name an innocent sibling.
            if journey.steps.contains(where: { $0.status == .failed }) { return }
            let target = journey.currentStepID
            if let target,
                let index = journey.steps.firstIndex(where: { $0.id == target })
            {
                journey.steps[index].status = .failed
                journey.steps[index].finishedAt = Date()
                State.shared.journey = journey
                return
            }
            if let index = journey.steps.firstIndex(where: { $0.status == .inProgress }) {
                journey.steps[index].status = .failed
                journey.steps[index].finishedAt = Date()
                State.shared.journey = journey
            }
        }

        // MARK: - Start / Stop

        public func startContainer() async throws {
            // Reuse an in-flight attempt instead of queuing another one.
            // Multiple call sites (AppDelegate auto-start, SandboxView,
            // SandboxToolRegistrar, SandboxAgentProvisioner) can race here
            // at launch. The actor singleton lives forever, so a strong
            // capture in the spawned task is fine.
            if let existing = inFlightStartTask {
                try await existing.value
                return
            }
            let task = Task<Void, Error> { try await self._performStartContainer() }
            inFlightStartTask = task
            defer { inFlightStartTask = nil }
            try await task.value
        }

        private func _performStartContainer() async throws {
            try await requireAvailabilityForOperation()
            guard !_removedByUser else { return }
            _stoppedExplicitly = false

            switch await refreshStatus() {
            case .running, .starting:
                return
            case .error:
                // Recover from a prior failed attempt by tearing down any
                // SDK / on-disk state before re-provisioning.
                await cleanupAfterFailure()
                fallthrough
            case .stopped, .notProvisioned:
                try await acquireVMOwnershipIfNeeded()
                _status = .starting
                syncStatus()
                do {
                    try await performProvision()
                } catch {
                    releaseVMOwnership()
                    _status = .stopped
                    syncStatus()
                    throw Self.startError(from: error)
                }
            }
        }

        public func stopContainer() async throws {
            // Mark before the status edge is published so the registrar's
            // status sink observes the flag when it reacts to `.stopped`.
            _stoppedExplicitly = true
            try await stopContainer(publishStoppedStatus: true)
        }

        /// Stop the VM and release its transient resources while preserving
        /// the on-disk rootfs, base template, and per-agent environments.
        ///
        /// `publishStoppedStatus` is false during an in-place restart so the
        /// UI moves directly from running to starting instead of briefly
        /// rendering the stopped dashboard between lifecycle phases.
        private func stopContainer(publishStoppedStatus: Bool, keepingLease: Bool = false) async throws {
            if SandboxBackend.current == .seatbelt {
                // Nothing persistent to tear down — Seatbelt confinement
                // is per-exec; stopping just gates future execs.
                _status = .stopped
                if publishStoppedStatus { syncStatus() }
                return
            }
            // Stop the pod and release its network interface. The template
            // and every agent's environment clone stay on disk, so the next
            // boot is warm and each agent keeps its apk packages.
            await teardownPod()
            // Drop network readiness; the next boot must re-verify.
            networkReadyTask?.cancel()
            networkReadyTask = nil
            networkReady = false
            // The post-start verify observer (if still running) is
            // bound to *this* container's plugin-restore pass — cancel
            // it so a torn-down container can't keep mutating the
            // journey of a future boot.
            postStartVerifyTask?.cancel()
            postStartVerifyTask = nil
            await HostAPIBridgeServer.shared.stop()
            // The filtering proxy is bound to this boot's vmnet gateway —
            // stop it with the container so a stale listener can't accept
            // connections against a dead allowlist.
            await teardownEgressProxy()
            // Drop any in-memory bridge tokens — the next container start
            // mints fresh ones. Leaving stale tokens in memory could falsely
            // authenticate a request to a guest that no longer exists.
            await SandboxBridgeTokenStore.shared.revokeAll()
            if !keepingLease { releaseVMOwnership() }
            if publishStoppedStatus {
                _status = .stopped
                syncStatus()
            }
            // Drop the cached metrics so the UI doesn't keep showing
            // stale CPU/memory/uptime numbers for a container that's no
            // longer running.
            await MainActor.run { State.shared.containerInfo = nil }
        }

        /// Apply boot-time configuration (and pod membership) without the
        /// destructive reset path. Runtime downloads, the immutable CoW
        /// template, and existing agent environments all survive.
        public func restartContainer() async throws {
            // Let an in-flight start finish so this restart applies on top
            // of it, then share any restart that another caller began.
            if let existing = inFlightStartTask { try? await existing.value }
            if let existing = inFlightStartTask {
                try await existing.value
                return
            }
            let task = Task<Void, Error> { try await self.performRestart() }
            inFlightStartTask = task
            defer { inFlightStartTask = nil }
            try await task.value
        }

        /// Restart without coalescing; the caller owns `inFlightStartTask`.
        /// The lease is held from stop through boot so another process can't
        /// take the VM in between.
        private func performRestart(beforeBoot: (() throws -> Void)? = nil) async throws {
            try await stopContainer(publishStoppedStatus: false, keepingLease: true)
            _removedByUser = false
            _stoppedExplicitly = false
            try await acquireVMOwnershipIfNeeded()
            _status = .starting
            syncStatus()
            do {
                try beforeBoot?()
                try await performProvision()
            } catch {
                releaseVMOwnership()
                _status = .stopped
                syncStatus()
                throw Self.startError(from: error)
            }
        }

        /// Cancel an in-flight start: the journey's Cancel, or chat Stop
        /// during first-time setup. Downloads resume on the next start.
        public func cancelStart() {
            guard let task = inFlightStartTask else { return }
            _stoppedExplicitly = true
            task.cancel()
        }

        /// A cancelled start surfaces as `CancellationError` whatever the
        /// interrupted step threw, so callers can tell it from a failure.
        private static func startError(from error: Error) -> Error {
            if Task.isCancelled || error is CancellationError { return CancellationError() }
            return friendlyError(from: error)
        }

        public func removeContainer() async throws {
            _stoppedExplicitly = true
            try await stopContainer(publishStoppedStatus: true, keepingLease: true)
            // Another Osaurus app on this data root may be running a VM
            // from these files; only the lease holder may delete them.
            try await acquireVMOwnershipIfNeeded()
            defer { releaseVMOwnership() }

            // Collect cleanup failures so the user-initiated full-remove
            // surfaces partial failures (orphan mounts, locked files, etc.)
            // instead of silently leaving state behind and reporting success.
            // Kernel / initfs removal is best-effort — they redownload on
            // next provision, so a leftover doesn't block startup.
            var warnings: [String] = []
            let containersRoot = OsaurusPaths.container().appendingPathComponent("containers")
            do {
                try await Self.forciblyRemoveAsync(at: containersRoot)
            } catch {
                warnings.append("containers/: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: OsaurusPaths.containerKernelFile())
            try? FileManager.default.removeItem(at: OsaurusPaths.containerInitFSFile())
            // Base template + per-agent clones go too — "Remove" must
            // actually reclaim the disk.
            SandboxRootfsTemplateStore.removeAll()
            // Workflow environments lose their Linux users and apk packages
            // with the rootfs; their manifests must not claim otherwise.
            WorkflowSandboxEnvironment.invalidateAll()

            _status = .notProvisioned
            _removedByUser = true
            syncStatus()
            await MainActor.run { Self.resetProvisioningState() }

            var config = SandboxConfigurationStore.load()
            config.setupComplete = false
            // Invalidate the warm-restart stamps now that the rootfs is gone.
            config.lastBootedImageDigest = nil
            config.lastRuntimeFormatVersion = nil
            config.lastRootfsFormatVersion = nil
            SandboxConfigurationStore.save(config)

            if !warnings.isEmpty {
                throw SandboxError.removeFailed(warnings.joined(separator: "; "))
            }
        }

        public func resetContainer() async throws {
            try await removeContainer()
            try await provision()
        }

        /// Discard one agent's copy-on-write environment so its next boot
        /// re-clones a pristine rootfs from the base template. Refuses while
        /// that agent's container is running on it.
        public func resetAgentEnvironment(agentName: String) async throws {
            guard !(pod != nil && podMembers.contains(agentName)) else {
                throw SandboxError.provisionFailed(
                    "Stop the sandbox before resetting an agent environment"
                )
            }
            try SandboxRootfsTemplateStore.resetEnvironment(agentName: agentName)
        }

        /// Reset one agent's environment from the Sandbox page. When its
        /// container is running, the sandbox restarts around the reset
        /// once running commands finish.
        public func resetAgentEnvironmentNow(agentName: String) async throws {
            if let existing = inFlightStartTask { try? await existing.value }
            guard pod != nil, podMembers.contains(agentName) else {
                try SandboxRootfsTemplateStore.resetEnvironment(agentName: agentName)
                return
            }
            let task = Task<Void, Error> {
                _ = try await self.waitForRunningWork()
                try await self.performRestart {
                    try SandboxRootfsTemplateStore.resetEnvironment(agentName: agentName)
                }
            }
            inFlightStartTask = task
            defer { inFlightStartTask = nil }
            try await task.value
        }

        // MARK: - Egress Proxy Lifecycle

        /// Start the filtering egress proxy on the host-only vmnet gateway.
        /// Per-connection enforcement resolves the caller's bridge token to
        /// the union of the agent's own `sandboxAllowedDomains` and the
        /// domain lists declared by that agent's installed plugins; the
        /// host-minted system token maps to the package-registry setup
        /// allowlist for root execs (apk installs, readiness probe).
        ///
        /// An open pod runs the proxy too, for workflow steps whose network
        /// is scoped to declared hosts; open agents there are not proxied.
        private func startEgressProxy(gateway: String) async throws {
            let systemToken = Self.mintEgressToken()
            systemEgressToken = systemToken
            let setupDomains = SandboxNetworkPolicy.setupAllowlist.sorted()

            // Read live per connection, so a policy change that keeps the
            // VM filtered applies without a restart.
            let resolver: SandboxEgressProxy.AllowlistResolver = { [self] token in
                if token == systemToken { return .domains(setupDomains) }
                if let grant = await self.scopedEgressGrant(forToken: token) { return grant }
                guard let identity = await SandboxBridgeTokenStore.shared.resolve(token: token)
                else { return nil }
                return await MainActor.run {
                    let pluginPermissions = SandboxPluginManager.shared
                        .plugins(for: identity.agentId.uuidString)
                        .map { $0.plugin.permissions?.network }
                    return SandboxEgressPolicy.proxyGrant(
                        for: Self.egressMode(forAgentId: identity.agentId),
                        pluginNetworkPermissions: pluginPermissions
                    )
                }
            }
            let port = try await SandboxEgressProxy.shared.start(
                host: gateway,
                resolver: resolver
            )
            egressProxyEndpoint = (host: gateway, port: port)
            debugLog("[Sandbox] Egress proxy enforcing allowlists at \(gateway):\(port)")
        }

        private func teardownEgressProxy() async {
            if await SandboxEgressProxy.shared.isRunning {
                await SandboxEgressProxy.shared.stop()
            }
            egressProxyEndpoint = nil
            systemEgressToken = nil
            stepEgressGrants = [:]
            openMemberEgressTokens = [:]
        }

        nonisolated static func mintEgressToken() -> String {
            SymmetricKey(size: .bits256).withUnsafeBytes {
                Data($0).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
        }

        private func scopedEgressGrant(forToken token: String) -> SandboxProxyGrant? {
            if let hosts = stepEgressGrants[token] { return .domains(hosts) }
            if openMemberEgressTokens.values.contains(token) { return .anyPublicHost }
            return nil
        }

        /// Proxy environment for a guest process, plus the step credential
        /// to revoke when the process ends.
        ///
        /// A step scope (`stepHosts`) always gets a proxy that reaches only
        /// those hosts; with no proxy running, an address nothing listens
        /// on, so proxy-aware clients fail rather than go direct. Outside a
        /// step, the env is empty unless the pod is filtered. There the
        /// credential is the caller's own bridge token (root/system
        /// processes get the registry-scoped system token, open members
        /// without a bridge token a proxy-only one), so the proxy enforces
        /// the right allowlist per connection — nothing the guest claims is
        /// trusted.
        struct EgressEnvironment {
            var env: [String: String] = [:]
            /// The step credential to revoke when the process ends.
            var stepToken: String?
            /// The credential in the proxy URL, scrubbed from output.
            var credential: String?
        }

        func egressProxyEnvironment(
            forLinuxUser user: String?,
            stepHosts: [String]? = nil
        ) async -> EgressEnvironment {
            if user != nil, let stepHosts {
                guard let endpoint = egressProxyEndpoint else {
                    return EgressEnvironment(env: Self.proxyEnvironment(url: "http://127.0.0.1:9"))
                }
                let token = Self.mintEgressToken()
                stepEgressGrants[token] = SandboxEgressPolicy.normalizedAllowlist(stepHosts)
                return EgressEnvironment(
                    env: Self.proxyEnvironment(url: "http://\(token):@\(endpoint.host):\(endpoint.port)"),
                    stepToken: token, credential: token)
            }
            guard bootNetwork == .filtered, let endpoint = egressProxyEndpoint else { return EgressEnvironment() }
            let token: String?
            if let user {
                token = await openMemberEgressToken(forLinuxUser: user)
            } else {
                token = systemEgressToken
            }
            guard let token else { return EgressEnvironment() }
            return EgressEnvironment(
                env: Self.proxyEnvironment(url: "http://\(token):@\(endpoint.host):\(endpoint.port)"),
                credential: token)
        }

        /// Credentials a guest process can read from its own environment or
        /// token file, which never belong in tool output or logs.
        private func credentialSecrets(forLinuxUser user: String?, egress: EgressEnvironment) async -> [String: String] {
            var secrets: [String: String] = [:]
            if let credential = egress.credential { secrets["OSAURUS_PROXY_TOKEN"] = credential }
            if let user, let bridge = await SandboxBridgeTokenStore.shared.token(forLinuxName: user) {
                secrets["OSAURUS_BRIDGE_TOKEN"] = bridge
            }
            return secrets
        }

        private func openMemberEgressToken(forLinuxUser user: String) async -> String? {
            if let token = await SandboxBridgeTokenStore.shared.token(forLinuxName: user) { return token }
            if let token = openMemberEgressTokens[user] { return token }
            let member = user.hasPrefix("agent-") ? String(user.dropFirst("agent-".count)) : user
            guard await MainActor.run(body: { Self.egressMode(forMember: member) }) == .open else { return nil }
            let token = Self.mintEgressToken()
            openMemberEgressTokens[user] = token
            return token
        }

        nonisolated static func proxyEnvironment(url: String) -> [String: String] {
            let noProxy = "localhost,127.0.0.1"
            return [
                "http_proxy": url,
                "https_proxy": url,
                "HTTP_PROXY": url,
                "HTTPS_PROXY": url,
                "no_proxy": noProxy,
                "NO_PROXY": noProxy,
            ]
        }

        /// The env a guest process runs with. Proxy keys override the
        /// caller's, so a caller-supplied `http_proxy` can't replace the
        /// filtering proxy.
        nonisolated static func mergedExecEnvironment(
            caller env: [String: String], proxy: [String: String]
        ) -> [String: String] {
            env.merging(proxy) { _, proxy in proxy }
        }

        // MARK: - Exec

        /// Record that `agentName` wants the sandbox, so the next boot gives
        /// it a container. Call before `startContainer()` when the VM is
        /// started on an agent's behalf; avoids a second boot to join.
        public func requestMembership(agentName: String) {
            guard SandboxPodLayout.isAgentName(agentName) else { return }
            noteRequested(agentName)
        }

        /// Container an exec with no explicit target runs in: agent users
        /// (`agent-<name>`) run in their own container, everything else in
        /// the system container. The diagnostics user lives in the system
        /// container.
        nonisolated static func target(forLinuxName linuxName: String?) -> SandboxExecTarget {
            let target = SandboxExecTarget.implied(byUser: linuxName)
            if case .agent(SandboxPodLayout.diagnosticsAgentName) = target { return .system }
            return target
        }

        /// Run `command` in the pod. `target` picks the container (default:
        /// the one implied by `user`); an agent that isn't in the running
        /// pod joins it first (see `ensureMember`).
        public func exec(
            user: String? = nil,
            command: String,
            env: [String: String] = [:],
            cwd: String? = nil,
            timeout: TimeInterval? = 30,
            streamToLogs: Bool = false,
            logSource: String? = nil,
            stdoutTee: (any Writer)? = nil,
            stderrTee: (any Writer)? = nil,
            onProcessStarted: (@Sendable (ProcessHandle) -> Void)? = nil,
            target: SandboxExecTarget? = nil
        ) async throws -> ContainerExecResult {
            let limited = user != nil
            if limited { try await acquireUserExecSlot() }
            defer { if limited { releaseUserExecSlot() } }
            if SandboxBackend.current == .seatbelt {
                // Host confinement has no per-user separation; the Seatbelt
                // profile is the isolation boundary, scoped to `user`'s
                // home plus the shared directory.
                return try await execViaSeatbelt(
                    user: user,
                    command: command,
                    env: env,
                    cwd: cwd,
                    timeout: timeout,
                    stdoutTee: stdoutTee,
                    stderrTee: stderrTee,
                    onProcessStarted: onProcessStarted
                )
            }

            let target = target ?? Self.target(forLinuxName: user)
            let containerID = try await runningContainerID(for: target)
            let args = Self.execArguments(user: user, command: command, cwd: cwd)

            // In a filtered pod every guest process gets `http_proxy` env
            // carrying its own credential, and a step-scoped exec gets one
            // in any pod.
            let egress = await egressProxyEnvironment(forLinuxUser: user, stepHosts: SandboxStepScope.hosts)
            defer { if let token = egress.stepToken { stepEgressGrants[token] = nil } }
            let mergedEnv = Self.mergedExecEnvironment(caller: env, proxy: egress.env)
            let credentials = await credentialSecrets(forLinuxUser: user, egress: egress)

            let result = try await SandboxLogScrubbing.$secrets.withValue(
                SandboxLogScrubbing.secrets.merging(credentials) { existing, _ in existing }
            ) {
                try await execViaAgent(
                    containerID: containerID,
                    args: args,
                    rlimits: user == nil ? [] : Self.agentRLimits,
                    env: mergedEnv,
                    timeout: timeout,
                    streamToLogs: streamToLogs,
                    logSource: logSource,
                    stdoutTee: stdoutTee,
                    stderrTee: stderrTee,
                    onProcessStarted: onProcessStarted
                )
            }
            return result.scrubbed(credentials)
        }

        /// argv for a guest exec: `su` into `user` when given, else a root
        /// shell. `cwd` is quoted so a path with spaces or metacharacters
        /// can't split or inject into the command.
        nonisolated static func execArguments(user: String?, command: String, cwd: String?) -> [String] {
            let shellCommand =
                cwd.map { "cd \(SandboxPackageRequest.shellQuote($0)) && \(command)" } ?? command
            if let user {
                return ["su", "-s", "/bin/bash", user, "-c", shellCommand]
            }
            return ["sh", "-c", shellCommand]
        }

        /// Container id to exec in for `target`, joining the agent to the
        /// pod first when needed. Waits out an in-flight boot.
        private func runningContainerID(for target: SandboxExecTarget) async throws -> String {
            switch target {
            case .agent(let name):
                try await ensureMember(name)
            case .system:
                if pod == nil, let starting = inFlightStartTask {
                    try await starting.value
                }
            }
            guard pod != nil else { throw SandboxError.containerNotRunning }
            return SandboxPodLayout.containerID(for: target)
        }

        /// Seatbelt-backend exec: run the command as a host process under
        /// `sandbox-exec` confinement. Guest-style `/workspace/…` paths in
        /// the command, cwd, and env are rewritten to the host workspace
        /// so the model-facing path contract matches the VM backend.
        private func execViaSeatbelt(
            user: String?,
            command: String,
            env: [String: String],
            cwd: String?,
            timeout: TimeInterval?,
            stdoutTee: (any Writer)?,
            stderrTee: (any Writer)?,
            onProcessStarted: (@Sendable (ProcessHandle) -> Void)?
        ) async throws -> ContainerExecResult {
            guard _status.isRunning else {
                throw SandboxError.containerNotRunning
            }
            let root = OsaurusPaths.containerWorkspace().path
            let network = Self.seatbeltNetwork(
                await MainActor.run { Self.seatbeltNetwork(forUser: user) }, stepHosts: SandboxStepScope.hosts)
            // Agent execs (`agent-<name>`) reach only their own home and the
            // shared directory; system execs (no user) keep the workspace.
            let agentName = user.flatMap { $0.hasPrefix("agent-") ? String($0.dropFirst("agent-".count)) : nil }
            let scope = agentName.map { SandboxAgentPathScope(agentName: $0) }
            scope?.ensureRootsExist()
            let scratch = agentName.map { SeatbeltSandbox.scratchDir(forAgent: $0) } ?? SeatbeltSandbox.scratchDir
            let profile = SeatbeltSandbox.profile(
                workspaceRoot: root,
                tempDir: scratch,
                network: network,
                writableRoots: scope.map { $0.hostRoots.map(\.path) }
            )
            let mappedCwd = cwd.map { SeatbeltPathMapper.mapToHost($0, workspaceRoot: root) }
            let netLabel = network == .allowed ? "allowed" : "denied"
            let commandPreview = String(command.prefix(160))
            Task { @MainActor in
                SandboxLogBuffer.shared.append(
                    level: .debug,
                    message: "sandbox-exec [net:\(netLabel)] $ \(commandPreview)",
                    source: "seatbelt"
                )
            }
            return try await SeatbeltExecutor.run(
                SeatbeltExecutor.Request(
                    command: SeatbeltPathMapper.mapToHost(command, workspaceRoot: root),
                    env: SeatbeltPathMapper.mapEnvToHost(env, workspaceRoot: root),
                    cwd: mappedCwd ?? scope?.hostHome.path ?? root,
                    timeout: timeout,
                    profile: profile,
                    stdoutTee: stdoutTee,
                    stderrTee: stderrTee,
                    onProcessStarted: onProcessStarted,
                    scratchDir: scratch
                ))
        }

        /// Root exec in `target`'s container. The target is required: with
        /// one container per agent there is no single guest any more, and
        /// root work on an agent's files or packages must run where that
        /// agent's filesystem is mounted.
        public func execAsRoot(
            command: String,
            target: SandboxExecTarget,
            timeout: TimeInterval? = 60,
            streamToLogs: Bool = false,
            logSource: String? = nil,
            stdoutTee: (any Writer)? = nil,
            stderrTee: (any Writer)? = nil,
            onProcessStarted: (@Sendable (ProcessHandle) -> Void)? = nil
        ) async throws -> ContainerExecResult {
            try await exec(
                command: command,
                timeout: timeout,
                streamToLogs: streamToLogs,
                logSource: logSource,
                stdoutTee: stdoutTee,
                stderrTee: stderrTee,
                onProcessStarted: onProcessStarted,
                target: target
            )
        }

        public func execAsAgent(
            _ agentName: String,
            command: String,
            pluginName: String? = nil,
            env: [String: String] = [:],
            timeout: TimeInterval? = 30,
            streamToLogs: Bool = false,
            logSource: String? = nil,
            stdoutTee: (any Writer)? = nil,
            stderrTee: (any Writer)? = nil,
            onProcessStarted: (@Sendable (ProcessHandle) -> Void)? = nil
        ) async throws -> ContainerExecResult {
            let cwd = pluginName.map { OsaurusPaths.inContainerPluginDir(agentName, $0) }
            return try await exec(
                user: "agent-\(agentName)",
                command: command,
                env: env,
                cwd: cwd,
                timeout: timeout,
                streamToLogs: streamToLogs,
                logSource: logSource,
                stdoutTee: stdoutTee,
                stderrTee: stderrTee,
                onProcessStarted: onProcessStarted
            )
        }

        // MARK: - Interactive (streaming) Exec

        /// Spawn a long-running container process with bidirectional stdio.
        /// Unlike `exec(...)`, this returns *before* the process exits and
        /// hands the caller a `LinuxProcess` they can `kill` / `delete`.
        ///
        /// Used by `SandboxStdioRunner` to wire an MCP stdio server's stdin /
        /// stdout to the host-side `MCP.Client`. Plain `exec()` is unsuitable
        /// because it accumulates output into a buffer and waits for the
        /// process to exit; stdio MCP servers are intentionally long-lived.
        ///
        /// - Parameters:
        ///   - stdin / stdout / stderr: Streaming I/O hooks supplied by the
        ///     caller. The caller owns lifecycle (e.g. flushing on stop).
        public func execInteractive(
            user: String? = nil,
            command: String,
            env: [String: String] = [:],
            cwd: String? = nil,
            stdin: any ReaderStream,
            stdout: any Writer,
            stderr: any Writer,
            activity: SandboxInteractiveActivity? = nil
        ) async throws -> LinuxProcess {
            if SandboxBackend.current == .seatbelt {
                // Long-lived bidirectional-stdio processes (stdio MCP
                // servers) are VM-only for now — the return type is the
                // SDK's LinuxProcess, which has no host equivalent.
                throw SandboxError.execFailed(
                    "Interactive sandbox processes require the VM backend (macOS 26 or later)")
            }
            let containerID = try await runningContainerID(for: Self.target(forLinuxName: user))
            guard let pod else { throw SandboxError.containerNotRunning }
            let args = Self.execArguments(user: user, command: command, cwd: cwd)

            // Long-lived processes (stdio MCP servers) need the proxy env
            // too — they make their own outbound calls in allowlist mode.
            let proxyEnv = await egressProxyEnvironment(forLinuxUser: user).env
            var mergedEnv = Self.mergedExecEnvironment(caller: env, proxy: proxyEnv)
            if mergedEnv["PATH"] == nil {
                mergedEnv["PATH"] = LinuxProcessConfiguration.defaultPath
            }
            let environ = mergedEnv.map { "\($0.key)=\($0.value)" }

            let processID = UUID().uuidString
            let process = try await pod.execInContainer(containerID, processID: processID) { config in
                config.arguments = args
                config.environmentVariables = environ
                Self.applyProcessRestrictions(to: &config)
                if user != nil { config.rlimits = Self.agentRLimits }
                config.stdin = stdin
                config.stdout = stdout
                config.stderr = stderr
            }
            try await process.start()
            interactiveProcesses[process.id] = (containerID, activity)
            lastActivityAt = Date()
            publishOccupancy()
            return process
        }

        // MARK: - Agent User Management

        /// One-exec, idempotent per-agent bootstrap: user + home, plugins
        /// dir, bridge-token dir + token file, and the first-run SOUL seed
        /// — everything `ensureAgentUser` + `provisionBridgeToken` +
        /// `seedSoulIfMissing` used to do across four to six sequential
        /// vsock exec round-trips, batched into a single guest script.
        /// The script is idempotent (guards on `id`, `test -f`) so
        /// re-provisions are safe and cheap.
        ///
        /// `soulSeedBody` is written only when `~/SOUL.md` doesn't exist,
        /// preserving agent edits. Pass `nil` to skip seeding (diagnostic
        /// users). `agentId == nil` skips the token file the same way.
        public func bootstrapAgent(
            agentName: String,
            agentId: UUID?,
            soulSeedBody: String?
        ) async throws {
            if SandboxBackend.current == .seatbelt {
                // No guest, no Linux users, no bridge shim — bootstrap is
                // just the host-side directory tree plus the first-run
                // SOUL seed. Bridge tokens are skipped: the vsock shim
                // that consumes them doesn't exist on this backend.
                try Self.bootstrapAgentOnHost(agentName: agentName, soulSeedBody: soulSeedBody)
                return
            }
            let linuxName = "agent-\(agentName)"
            let target = Self.target(forLinuxName: linuxName)
            // Join the pod before minting: a membership restart revokes every
            // bridge token, so the token written below must outlive it.
            if case .agent(let member) = target {
                try await ensureMember(member)
            }
            var token: String?
            if let agentId {
                token = await SandboxBridgeTokenStore.shared.register(
                    agentId: agentId,
                    linuxName: linuxName
                )
            }
            let script = Self.agentBootstrapScript(
                agentName: agentName,
                homeDir: OsaurusPaths.inContainerAgentHome(agentName),
                bridgeTokenDir: Self.bridgeTokenDir,
                token: token,
                soulSeedBody: soulSeedBody,
                uid: SandboxAgentUIDs.uid(for: linuxName)
            )
            let result = try await serializingUserAdmin(on: target) {
                try await self.execAsRoot(command: script, target: target)
            }
            guard result.succeeded else {
                throw SandboxError.userCreationFailed(
                    result.stderr.isEmpty
                        ? "agent bootstrap failed for \(linuxName)"
                        : Self.userAdminFailureMessage(result.stderr, hostFreeBytes: Self.hostFreeBytes())
                )
            }
        }

        /// One chain per container for user administration: `adduser` and
        /// `deluser` rewrite `/etc/passwd` through an exclusive
        /// `/etc/passwd+`, so two runs in one container race and the loser
        /// fails with "File exists".
        private var userAdminTails: [SandboxExecTarget: Task<Void, Never>] = [:]

        private func serializingUserAdmin<T: Sendable>(
            on target: SandboxExecTarget,
            _ body: @escaping @Sendable () async throws -> T
        ) async throws -> T {
            let previous = userAdminTails[target]
            let task = Task<T, Error> {
                await previous?.value
                return try await body()
            }
            userAdminTails[target] = Task { _ = try? await task.value }
            return try await task.value
        }

        /// Free space on the volume holding the sandbox data, or nil.
        nonisolated static func hostFreeBytes() -> Int64? {
            let values = try? OsaurusPaths.container().resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }

        /// Actionable text for the user-admin failures we can name. The
        /// bootstrap step marker lines are kept so the failed step can still
        /// be attributed; the raw stderr follows for diagnosis.
        nonisolated static func userAdminFailureMessage(_ stderr: String, hostFreeBytes: Int64?) -> String {
            let lowered = stderr.lowercased()
            let hint: String?
            if lowered.contains("no space left on device") {
                if let hostFreeBytes, hostFreeBytes < 1 << 30 {
                    hint = L("Your Mac is out of disk space, so the sandbox can't set up this agent. Free up space and try again.")
                } else {
                    hint = L(
                        "This agent's sandbox environment is full. Remove packages it no longer needs, or reset its environment in Settings → Developer Tools → Sandbox."
                    )
                }
            } else if ["/etc/passwd+", "/etc/group+", "/etc/shadow+"].contains(where: stderr.contains) {
                hint = L("An earlier change to this agent's sandbox users was interrupted. Restart the sandbox to clear it.")
            } else {
                hint = nil
            }
            guard let hint else { return stderr }
            return hint + "\n" + stderr
        }

        /// Build the batched per-agent bootstrap script. Static so unit
        /// tests can pin the guards (adduser `id` check, `umask 0077`
        /// token write, `test -f` SOUL seed) without booting a container.
        ///
        /// Runs as root inside the guest with `set -e`, so any failed
        /// step surfaces as a non-zero exit instead of a silent partial
        /// bootstrap. The SOUL heredoc uses a quoted delimiter
        /// (`'SOUL_EOF'`) so the body lands byte-exact with no `$` /
        /// backtick expansion.
        static func agentBootstrapScript(
            agentName: String,
            homeDir: String,
            bridgeTokenDir: String,
            token: String?,
            soulSeedBody: String?,
            uid: UInt32? = nil
        ) -> String {
            let linuxName = "agent-\(agentName)"
            typealias Step = SandboxProvisionStepError.BootstrapStep
            func step(_ step: Step) -> String { "STEP=\(step.rawValue)" }
            var lines: [String] = [
                "set -e",
                step(.adduser),
                "trap 'rc=$?; [ \"$rc\" -eq 0 ] || echo \"\(SandboxProvisionStepError.bootstrapStepMarker)$STEP\" >&2' EXIT",
            ]
            lines += userCreationLines(linuxName: linuxName, homeDir: homeDir, uid: uid)
            lines += [
                step(.chmodHome),
                "mkdir -p '\(homeDir)'",
                // A member's home is its own VirtioFS mount, whose root
                // refuses chown/chmod; only the diag home lives on ext4.
                "mountpoint -q '\(homeDir)' || { chown \(linuxName):\(linuxName) '\(homeDir)'; chmod 700 '\(homeDir)'; }",
                step(.pluginsDir),
                "install -d -o \(linuxName) -g \(linuxName) '\(homeDir)/plugins'",
                step(.tokenDir),
                "mkdir -p \(bridgeTokenDir)",
                "chmod 0711 \(bridgeTokenDir)",
            ]
            if let token {
                // `umask 0077` creates the token file mode 0600 directly —
                // no transient world-readable window; `printf %s` keeps
                // the token byte-exact (no trailing newline).
                lines.append(contentsOf: [
                    step(.tokenWrite),
                    "( umask 0077 && printf %s '\(token)' > \(bridgeTokenDir)/\(linuxName).token )",
                    step(.tokenChown),
                    "chown \(linuxName):\(linuxName) \(bridgeTokenDir)/\(linuxName).token",
                ])
            }
            if let soulSeedBody {
                lines.append(contentsOf: [
                    step(.soulSeed),
                    "if [ ! -f '\(homeDir)/SOUL.md' ]; then",
                    "cat > '\(homeDir)/SOUL.md' <<'SOUL_EOF'",
                    soulSeedBody,
                    "SOUL_EOF",
                    "chown \(linuxName):\(linuxName) '\(homeDir)/SOUL.md'",
                    "fi",
                ])
            }
            return lines.joined(separator: "\n")
        }

        /// Create `linuxName` with `uid`, re-creating it when an older
        /// environment clone gave it a different UID (its home is a
        /// VirtioFS mount, so no files keep the old owner).
        static func userCreationLines(linuxName: String, homeDir: String, uid: UInt32?) -> [String] {
            let add = "adduser -D -H\(uid.map { " -u \($0)" } ?? "") -h '\(homeDir)' \(linuxName)"
            var lines = [
                "if ! id \(linuxName) >/dev/null 2>&1; then",
                "  \(add)",
            ]
            if let uid {
                lines += [
                    "elif [ \"$(id -u \(linuxName))\" != \"\(uid)\" ]; then",
                    "  deluser \(linuxName)",
                    "  delgroup \(linuxName) >/dev/null 2>&1 || true",
                    "  \(add)",
                ]
            }
            lines.append("fi")
            return lines
        }

        /// Host-side equivalent of the guest bootstrap script, used by the
        /// Seatbelt backend. Static so it's testable without the actor.
        static func bootstrapAgentOnHost(agentName: String, soulSeedBody: String?) throws {
            let root = OsaurusPaths.containerWorkspace().path
            let home = SeatbeltPathMapper.mapToHost(
                OsaurusPaths.inContainerAgentHome(agentName), workspaceRoot: root)
            let fm = FileManager.default
            try fm.createDirectory(
                atPath: home + "/plugins",
                withIntermediateDirectories: true,
                attributes: nil
            )
            // chmod 700, mirroring the guest script — other host users
            // (not other agents) are kept out.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home)
            if let soulSeedBody {
                let soulPath = home + "/SOUL.md"
                if !fm.fileExists(atPath: soulPath) {
                    try soulSeedBody.write(toFile: soulPath, atomically: true, encoding: .utf8)
                }
            }
        }

        public func ensureAgentUser(_ agentName: String) async throws {
            if SandboxBackend.current == .seatbelt {
                try Self.bootstrapAgentOnHost(agentName: agentName, soulSeedBody: nil)
                return
            }
            let linuxName = "agent-\(agentName)"
            let target = Self.target(forLinuxName: linuxName)
            let checkResult = try await exec(command: "id \(linuxName) 2>/dev/null", target: target)
            if checkResult.succeeded { return }

            let homeDir = OsaurusPaths.inContainerAgentHome(agentName)
            let command = (
                ["set -e"]
                    + Self.userCreationLines(
                        linuxName: linuxName, homeDir: homeDir, uid: SandboxAgentUIDs.uid(for: linuxName))
                    + [
                        "mkdir -p '\(homeDir)'",
                        "mountpoint -q '\(homeDir)' || chown \(linuxName):\(linuxName) '\(homeDir)'",
                        "install -d -o \(linuxName) -g \(linuxName) '\(homeDir)/plugins'",
                    ]
            ).joined(separator: "\n")
            let addResult = try await serializingUserAdmin(on: target) {
                try await self.execAsRoot(command: command, target: target)
            }
            guard addResult.succeeded else {
                throw SandboxError.userCreationFailed(
                    Self.userAdminFailureMessage(addResult.stderr, hostFreeBytes: Self.hostFreeBytes()))
            }
        }

        public func removeAgentUser(_ agentName: String) async throws -> Bool {
            if SandboxBackend.current == .seatbelt {
                // No Linux user exists — remove the host-side agent home.
                let root = OsaurusPaths.containerWorkspace().path
                let home = SeatbeltPathMapper.mapToHost(
                    OsaurusPaths.inContainerAgentHome(agentName), workspaceRoot: root)
                let fm = FileManager.default
                guard fm.fileExists(atPath: home) else { return false }
                try fm.removeItem(atPath: home)
                return true
            }
            let linuxUser = "agent-\(agentName)"
            requestedMembers.removeAll { $0 == agentName }
            // Drop the per-agent bridge token first so any in-flight bridge
            // calls from this agent fail closed.
            await SandboxBridgeTokenStore.shared.revoke(linuxName: linuxUser)

            guard pod != nil, podMembers.contains(agentName) else {
                // No running container: the user, its packages, and its
                // token file all live in the agent's environment clone.
                let existed = FileManager.default.fileExists(
                    atPath: SandboxRootfsTemplateStore.environmentDir(agentName: agentName).path
                )
                try SandboxRootfsTemplateStore.resetEnvironment(agentName: agentName)
                return existed
            }

            let target = SandboxExecTarget.agent(agentName)
            let checkResult = try await exec(command: "id \(linuxUser) 2>/dev/null", target: target)
            guard checkResult.succeeded else { return false }
            let removeCommand =
                "rm -f \(Self.bridgeTokenDir)/\(linuxUser).token; pkill -u \(linuxUser) >/dev/null 2>&1 || true; deluser \(linuxUser) >/dev/null 2>&1 || true"
            let removeResult = try await serializingUserAdmin(on: target) {
                try await self.execAsRoot(command: removeCommand, target: target)
            }
            guard removeResult.succeeded else {
                throw SandboxError.removeFailed(
                    removeResult.stderr.isEmpty
                        ? "Failed to remove \(linuxUser)"
                        : removeResult.stderr
                )
            }
            let verifyResult = try await exec(command: "id \(linuxUser) 2>/dev/null", target: target)
            guard !verifyResult.succeeded else {
                throw SandboxError.removeFailed("User \(linuxUser) still exists after cleanup")
            }
            // The running container still boots from the clone; discard it
            // (and the agent's packages) on the next boot.
            pendingEnvironmentResets.insert(agentName)
            return true
        }

        // MARK: - Bridge Token Provisioning

        /// Mint (or look up) a bridge auth token for `linuxName` and write it
        /// to `/run/osaurus/<linuxName>.token` inside the guest with mode 0600
        /// owned by that user. Idempotent — safe to call repeatedly. Should be
        /// invoked after `ensureAgentUser` for the same `linuxName` so the
        /// chown target exists.
        ///
        /// `agentId` ties the token to a specific Osaurus agent so the bridge
        /// server can derive identity from the token alone, without trusting
        /// any caller-supplied header.
        public func provisionBridgeToken(linuxName: String, agentId: UUID) async throws {
            // Guest must be running to host the token file.
            guard pod != nil else { return }

            let token = await SandboxBridgeTokenStore.shared.register(
                agentId: agentId,
                linuxName: linuxName
            )
            let tokenPath = "\(Self.bridgeTokenDir)/\(linuxName).token"

            // `umask 0077` so the redirect creates the file mode 0600 directly
            // — no transient world-readable window between create and chmod.
            // `printf %s` (no trailing newline) keeps the token byte-exact for
            // the shim's `cat` read.
            let script = """
                mkdir -p \(Self.bridgeTokenDir) && chmod 0711 \(Self.bridgeTokenDir) && \
                ( umask 0077 && printf %s '\(token)' > \(tokenPath) ) && \
                chown \(linuxName):\(linuxName) \(tokenPath)
                """
            let result = try await execAsRoot(command: script, target: Self.target(forLinuxName: linuxName))
            guard result.succeeded else {
                throw SandboxError.provisionFailed(
                    "Failed to write bridge token for \(linuxName): \(result.stderr)"
                )
            }
        }

        /// Drop in-memory and on-disk traces of the bridge token for `linuxName`.
        public func revokeBridgeToken(linuxName: String) async {
            await SandboxBridgeTokenStore.shared.revoke(linuxName: linuxName)
            let target = Self.target(forLinuxName: linuxName)
            let isRunningThere: Bool
            switch target {
            case .system: isRunningThere = pod != nil
            case .agent(let name): isRunningThere = pod != nil && podMembers.contains(name)
            }
            if isRunningThere {
                _ = try? await execAsRoot(
                    command: "rm -f \(Self.bridgeTokenDir)/\(linuxName).token",
                    target: target
                )
            }
        }

        // MARK: - Container Info

        public struct ContainerInfo: Sendable {
            public let status: ContainerStatus
            public let agentUsers: [String]
            public let diskUsage: String?
            public let uptime: String?
            public let memoryUsage: String?
            public let cpuLoad: String?
            public let processCount: Int?
        }

        public func info() async -> ContainerInfo {
            let result = await computeInfo()
            // Publish the latest metrics to the MainActor mirror so any
            // SwiftUI view that subscribes (`SandboxView`'s status
            // dashboard) sees the freshest values immediately, even
            // across tab destruction / recreation cycles.
            await MainActor.run { State.shared.containerInfo = result }
            return result
        }

        private func computeInfo() async -> ContainerInfo {
            // Avoid a heavy `refreshStatus()` filesystem walk when the
            // caller really just wants the metrics during normal running.
            // If a start is in flight, or we already know we're not
            // running, short-circuit before doing any exec.
            if inFlightStartTask != nil {
                return ContainerInfo(
                    status: _status,
                    agentUsers: [],
                    diskUsage: nil,
                    uptime: nil,
                    memoryUsage: nil,
                    cpuLoad: nil,
                    processCount: nil
                )
            }

            // Fast path: if our in-memory status already says "running",
            // trust it and skip the stat() / stale-dir-cleanup pass
            // inside `refreshStatus()`. Only fall back to the full
            // status walk when we genuinely might have lost the
            // container (e.g. the pod became nil).
            let currentStatus: ContainerStatus
            if _status == .running && pod != nil {
                currentStatus = .running
            } else {
                currentStatus = await refreshStatus()
            }

            guard currentStatus.isRunning else {
                return ContainerInfo(
                    status: currentStatus,
                    agentUsers: [],
                    diskUsage: nil,
                    uptime: nil,
                    memoryUsage: nil,
                    cpuLoad: nil,
                    processCount: nil
                )
            }

            if SandboxBackend.current == .seatbelt {
                return await collectSeatbeltInfo(status: currentStatus)
            }
            return await collectRunningContainerInfo(status: currentStatus)
        }

        /// Seatbelt backend metrics. There is no guest `/proc` to read and
        /// no VM to have an uptime, CPU, or memory budget — the meaningful
        /// numbers are the host-side ones: agent homes under
        /// `workspace/agents`, workspace disk usage, and time since the
        /// backend was marked ready. The VM-only fields stay `nil` so the
        /// dashboard simply omits those tiles.
        private func collectSeatbeltInfo(status: ContainerStatus) async -> ContainerInfo {
            let fm = FileManager.default
            let agentsDir = OsaurusPaths.containerAgentsDir()
            let users =
                ((try? fm.contentsOfDirectory(atPath: agentsDir.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted()

            var uptime: String? = nil
            if let ready = _lastBootReadyAt {
                uptime = "\(Int(Date().timeIntervalSince(ready))) seconds"
            }

            var disk: String? = nil
            if let r = try? await exec(command: "du -sh /workspace 2>/dev/null | cut -f1", timeout: 5) {
                let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !out.isEmpty { disk = out }
            }

            return ContainerInfo(
                status: status,
                agentUsers: users,
                diskUsage: disk,
                uptime: uptime,
                memoryUsage: nil,
                cpuLoad: nil,
                processCount: nil
            )
        }

        /// Metric collection for the running pod. VM-wide numbers (uptime,
        /// memory, load) come from one system-container exec; the process
        /// count sums every container's cgroup; agent users are the pod's
        /// members; disk usage is measured on the host, since no container
        /// mounts the whole workspace.
        ///
        /// Exec output contract (one line per field):
        /// ```
        /// UPTIME=123 seconds
        /// MEM=128MB / 512MB
        /// CPU=0.10 0.05 0.01
        /// ```
        /// Any field may be absent or empty if its /proc read failed — the
        /// host treats missing fields as `nil`.
        private func collectRunningContainerInfo(status: ContainerStatus) async -> ContainerInfo {
            let script = """
                printf 'UPTIME=%s\\n' "$(awk '{printf "%.0f seconds", $1}' /proc/uptime 2>/dev/null)"
                printf 'MEM=%s\\n' "$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{if (t>0) printf "%dMB / %dMB", (t-a)/1024, t/1024}' /proc/meminfo 2>/dev/null)"
                printf 'CPU=%s\\n' "$(awk '{printf "%s %s %s", $1, $2, $3}' /proc/loadavg 2>/dev/null)"
                """

            let users = podMembers.map { "agent-\($0)" }
            var uptime: String? = nil
            var memoryUsage: String? = nil
            var cpuLoad: String? = nil
            var processCount: Int? = nil

            if let result = try? await exec(command: script, timeout: 5, target: .system) {
                for rawLine in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = String(rawLine)
                    guard let eq = line.firstIndex(of: "=") else { continue }
                    let key = String(line[..<eq])
                    let value = String(line[line.index(after: eq)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if value.isEmpty { continue }
                    switch key {
                    case "UPTIME": uptime = value
                    case "MEM": memoryUsage = value
                    case "CPU": cpuLoad = value
                    default: continue
                    }
                }
            }
            if let pod, let stats = try? await pod.statistics(categories: .process) {
                processCount = Int(stats.compactMap { $0.process?.current }.reduce(0, +))
            }

            let workspace = OsaurusPaths.containerWorkspace()
            let bytes = await Task.detached(priority: .utility) {
                OsaurusPaths.directorySize(at: workspace)
            }.value
            let disk = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)

            return ContainerInfo(
                status: status,
                agentUsers: users,
                diskUsage: disk,
                uptime: uptime,
                memoryUsage: memoryUsage,
                cpuLoad: cpuLoad,
                processCount: processCount
            )
        }

        // MARK: - Diagnostics

        public struct DiagnosticResult: Sendable {
            public let name: String
            public let passed: Bool
            public let detail: String
        }

        /// Stable synthetic agent identity used only by the `vsock-bridge`
        /// diagnostic round-trip below. The bridge derives the log source from
        /// the token-bound Linux user name, so any fixed UUID works here;
        /// keeping it constant avoids accumulating distinct token-store entries
        /// across repeated diagnostic runs.
        private static let diagAgentId = UUID(uuidString: "00000000-0000-0000-0000-0000000D1A60")!

        /// Run a suite of checks to verify exec, NAT networking, agent users,
        /// apk install, and the vsock host-API bridge.
        ///
        /// `exec`, `nat-networking`, and `apk-install` are mutually independent
        /// and run concurrently. `agent-user` and `vsock-bridge` both rely on
        /// the `agent-diag` Linux user, so they run as an ordered pair: the
        /// bridge check provisions a per-user bridge token and then exercises
        /// the real `osaurus-host` shim path the way a plugin would, which means
        /// it must not race `ensureAgentUser`'s non-atomic check-then-create.
        /// Each `exec` suspends the actor while the guest works, so the three
        /// concurrent checks still overlap with the sequential pair. The
        /// returned array preserves the UI ordering.
        public func runDiagnostics() async -> [DiagnosticResult] {
            if SandboxBackend.current == .seatbelt {
                return await runSeatbeltDiagnostics()
            }
            async let execD = diagnose("exec") {
                let r = try await self.exec(command: "echo hello from sandbox", target: .system)
                let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard out == "hello from sandbox" else {
                    throw SandboxError.execFailed("expected 'hello from sandbox', got '\(out)'")
                }
                return out
            }

            let bootNetwork = self.bootNetwork
            async let natD = diagnose("nat-networking") {
                if bootNetwork == SandboxPodNetwork.none {
                    return "network is off for every agent in the sandbox"
                }
                // Filtered: system processes reach only the setup hosts,
                // through the proxy.
                let url =
                    bootNetwork == .filtered
                    ? "http://dl-cdn.alpinelinux.org/alpine/" : "http://example.com"
                let r = try await self.exec(
                    command: "wget -qO- \(url) 2>/dev/null | head -5",
                    timeout: 15,
                    target: .system
                )
                let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !out.isEmpty else {
                    throw SandboxError.execFailed(
                        Self.sandboxDiagnosticHint(
                            check: "nat-networking",
                            exitCode: r.exitCode,
                            stderr: r.stderr
                        )
                    )
                }
                return String(out.prefix(80))
            }

            async let apkD = diagnose("apk-install") {
                _ = await self.awaitNetworkReady()
                let r = try await self.execAsRoot(command: "apk add --no-cache jq 2>&1", target: .system, timeout: 60)
                guard r.succeeded else {
                    throw SandboxError.execFailed(
                        Self.sandboxDiagnosticHint(
                            check: "apk-install",
                            exitCode: r.exitCode,
                            stderr: r.stderr
                        )
                    )
                }
                return "exit \(r.exitCode)"
            }

            // `agent-user` and `vsock-bridge` share the `agent-diag` user, so
            // run them sequentially — after kicking off the concurrent checks
            // above — to avoid two tasks racing inside `ensureAgentUser`.
            let userResult = await diagnose("agent-user") {
                try await self.ensureAgentUser("diag")
                let r = try await self.exec(user: "agent-diag", command: "whoami")
                let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard out == "agent-diag" else {
                    throw SandboxError.execFailed("expected 'agent-diag', got '\(out)'")
                }
                return out
            }

            let vsockResult = await diagnose("vsock-bridge") {
                // Exercise the real plugin path end to end: provision a
                // per-user bridge token, then invoke the in-guest `osaurus-host`
                // shim as `agent-diag` so the bearer token is attached exactly
                // the way a plugin would. The bridge fails closed with HTTP 401
                // when no token is presented, so a token-less request can never
                // pass — authenticating here is what makes the check meaningful.
                try await self.ensureAgentUser("diag")
                try await self.provisionBridgeToken(
                    linuxName: "agent-diag",
                    agentId: Self.diagAgentId
                )
                let r: ContainerExecResult
                do {
                    r = try await self.execAsAgent(
                        "diag",
                        command: "osaurus-host log info diag-ping"
                    )
                } catch {
                    // Best-effort cleanup so a failed exec doesn't leave a
                    // standing diag credential in the token store / token file.
                    await self.revokeBridgeToken(linuxName: "agent-diag")
                    throw error
                }
                await self.revokeBridgeToken(linuxName: "agent-diag")
                guard r.succeeded else {
                    throw SandboxError.execFailed(
                        Self.sandboxDiagnosticHint(
                            check: "vsock-bridge",
                            exitCode: r.exitCode,
                            stderr: r.stderr
                        )
                    )
                }
                return "bridge responded OK"
            }

            let (execResult, natResult, apkResult) = await (execD, natD, apkD)
            let results: [DiagnosticResult] = [
                execResult,
                natResult,
                userResult,
                apkResult,
                vsockResult,
            ]

            return results
        }

        /// Seatbelt diagnostics. The VM suite's NAT / apk / agent-user /
        /// vsock-bridge checks have no equivalent here — instead verify the
        /// properties this backend actually promises: commands execute,
        /// the workspace is read-write, the profile blocks writes OUTSIDE
        /// the workspace, and network access matches the configured mode.
        private func runSeatbeltDiagnostics() async -> [DiagnosticResult] {
            let execResult = await diagnose("exec") {
                let r = try await self.exec(command: "echo hello from sandbox")
                let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard out == "hello from sandbox" else {
                    throw SandboxError.execFailed("expected 'hello from sandbox', got '\(out)'")
                }
                return out
            }

            let writeResult = await diagnose("workspace-rw") {
                let r = try await self.exec(
                    command: "f=/workspace/.osaurus-diag-$$; echo ok > \"$f\" && cat \"$f\" && rm -f \"$f\""
                )
                guard r.succeeded, r.stdout.contains("ok") else {
                    throw SandboxError.execFailed(
                        "workspace write failed (exit \(r.exitCode)): \(r.stderr)")
                }
                return "workspace read/write OK"
            }

            let confinementResult = await diagnose("confinement") {
                // A write outside the workspace MUST be denied by the
                // profile. The app itself is not confined, so checking the
                // host filesystem afterwards is authoritative.
                let escapePath = "/private/tmp/osaurus-seatbelt-escape"
                _ = try await self.exec(command: "touch \(escapePath) 2>/dev/null")
                if FileManager.default.fileExists(atPath: escapePath) {
                    try? FileManager.default.removeItem(atPath: escapePath)
                    throw SandboxError.execFailed(
                        "a write outside the workspace succeeded — the sandbox profile is not being enforced"
                    )
                }
                return "writes outside the workspace are blocked"
            }

            let networkAllowed = await MainActor.run { Self.seatbeltNetwork(forUser: nil) } == .allowed
            let networkResult = await diagnose("network") {
                let r = try await self.exec(
                    command: "curl -s -m 10 https://example.com | head -5",
                    timeout: 15
                )
                let gotResponse = !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if networkAllowed {
                    guard gotResponse else {
                        throw SandboxError.execFailed(
                            Self.sandboxDiagnosticHint(
                                check: "nat-networking",
                                exitCode: r.exitCode,
                                stderr: r.stderr
                            )
                        )
                    }
                    return "outbound network OK"
                } else {
                    guard !gotResponse else {
                        throw SandboxError.execFailed(
                            "network is configured off but an outbound request succeeded — the sandbox profile is not being enforced"
                        )
                    }
                    return "outbound network blocked as configured"
                }
            }

            return [execResult, writeResult, confinementResult, networkResult]
        }

        private func diagnose(_ name: String, _ block: () async throws -> String) async -> DiagnosticResult {
            do {
                let detail = try await block()
                NSLog("[SandboxDiag] PASS  %@: %@", name, detail)
                return DiagnosticResult(name: name, passed: true, detail: detail)
            } catch {
                NSLog("[SandboxDiag] FAIL  %@: %@", name, error.localizedDescription)
                return DiagnosticResult(name: name, passed: false, detail: error.localizedDescription)
            }
        }

        /// Translate a terse failed exec result into an actionable, human
        /// readable diagnostic detail. Pure and side-effect free (a `static`
        /// member is outside the actor's isolation domain) so it can be
        /// unit-tested without a running guest. `stderr` is the raw guest
        /// output (shim / curl / wget / apk); when present it is appended after
        /// the explanation so a power user still sees the underlying message.
        static func sandboxDiagnosticHint(check: String, exitCode: Int32, stderr: String) -> String {
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()

            // Lead with the plain-language explanation, then attach the raw
            // exit code (when non-zero) and stderr (when present) in parens.
            func decorate(_ hint: String) -> String {
                var suffix = exitCode != 0 ? "exit \(exitCode)" : ""
                if !trimmed.isEmpty {
                    suffix = suffix.isEmpty ? trimmed : "\(suffix): \(trimmed)"
                }
                return suffix.isEmpty ? hint : "\(hint) (\(suffix))"
            }

            switch check {
            case "vsock-bridge":
                // Order matters: a 401 from the bridge can also mention
                // "token", so classify the authenticated rejection first and
                // fall back to the shim's local "token missing" message.
                if lower.contains("401") || lower.contains("unauthor") || lower.contains("unrecogni") {
                    return decorate("host bridge rejected the request: authentication failed")
                }
                if lower.contains("token") {
                    return decorate("host bridge token not provisioned for this agent")
                }
                if exitCode == 7 || lower.contains("couldn't connect") || lower.contains("could not connect")
                    || lower.contains("connection refused")
                {
                    return decorate(
                        "host bridge socket unreachable; the host API bridge may not be running"
                    )
                }
                if exitCode == 127 || lower.contains("not found") || lower.contains("no such file") {
                    return decorate("osaurus-host shim missing in the guest")
                }
                return decorate("host bridge round-trip failed")
            case "nat-networking":
                return decorate(
                    "no outbound network response; check the Network Access setting and your connection"
                )
            case "apk-install":
                return decorate(
                    "package install failed; check the Network Access setting and your connection"
                )
            default:
                return decorate("check failed")
            }
        }

        // MARK: - Private: InitFS Management

        /// Resolve the guest initfs from the digest-pinned `vminit` OCI
        /// artifact (~64 MiB compressed, pulled with the SDK's concurrent
        /// layer downloader). Do not fall back to the legacy mutable raw-ext4
        /// mirror: it carries the 0.35 protocol and is incompatible with the
        /// 0.41 SDK. A registry failure is surfaced and can be retried.
        private func ensureInitFS(store: ImageStore) async throws -> Containerization.Mount {
            let stagedPath = OsaurusPaths.containerInitFSFile()
            let digestPath = Self.initFSDigestFile(for: stagedPath)

            // The staged block is built locally, so its digest is recorded
            // when it is built and checked before every boot. A block with
            // no record (staged by an older build) or a different digest is
            // rebuilt from the digest-verified content store.
            if FileManager.default.fileExists(atPath: stagedPath.path),
                await !Self.stagedAssetMatchesRecord(stagedPath, record: digestPath)
            {
                debugLog("[Sandbox] Staged initfs does not match its recorded digest; rebuilding")
                try? FileManager.default.removeItem(at: stagedPath)
                try? FileManager.default.removeItem(at: digestPath)
            }

            if !FileManager.default.fileExists(atPath: stagedPath.path) {
                await startStep(.downloadInitFS, detail: L("Pulling init filesystem"))
                try OsaurusPaths.ensureExists(OsaurusPaths.container())
                do {
                    try await Self.buildInitFSFromOCI(store: store, at: stagedPath)
                    try await Self.recordAssetDigest(of: stagedPath, to: digestPath)
                } catch {
                    await failOrResetStep(.downloadInitFS, after: error)
                    throw error
                }
                await endStep(.downloadInitFS, status: .completed)
            }

            return .block(
                format: "ext4",
                source: stagedPath.path,
                destination: "/",
                options: ["ro"]
            )
        }

        /// Pull the pinned `vminit` OCI artifact into `store` and unpack
        /// it as an ext4 block at `path`. The reference is digest-pinned
        /// (`SandboxRuntimeAssets.initfsReference`), so the registry
        /// cannot substitute contents; the SDK verifies each blob digest
        /// as it lands in the content store.
        private static func buildInitFSFromOCI(store: ImageStore, at path: URL) async throws {
            let progress = Self.makeContainerCreateProgressHandler(stepID: .downloadInitFS)
            let initImage = try await store.getInitImage(
                reference: SandboxRuntimeAssets.initfsReference,
                progress: progress
            )
            do {
                _ = try await initImage.initBlock(at: path, for: .linuxArm)
            } catch let err as ContainerizationError where err.code == .exists {
                // Another provision attempt already unpacked it.
            }
        }

        nonisolated static func initFSDigestFile(for staged: URL) -> URL {
            staged.appendingPathExtension("sha256")
        }

        /// Whether `asset` hashes to the digest stored at `record`. A
        /// missing or unreadable record is a mismatch.
        nonisolated static func stagedAssetMatchesRecord(_ asset: URL, record: URL) async -> Bool {
            guard let recorded = try? String(contentsOf: record, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            else { return false }
            return (try? await verifySHA256Async(of: asset, expected: recorded, maxBytes: maxArtifactDownloadBytes))
                != nil
        }

        nonisolated static func recordAssetDigest(of asset: URL, to record: URL) async throws {
            let digest = try await Task.detached(priority: .userInitiated) {
                try Self.sha256Hex(of: asset, maxBytes: Self.maxArtifactDownloadBytes)
            }.value
            try Data(digest.utf8).write(to: record, options: .atomic)
        }

        // MARK: - Private: Kernel Management

        private func ensureKernel() async throws -> Kernel {
            let kernelPath = OsaurusPaths.containerKernelFile()

            if FileManager.default.fileExists(atPath: kernelPath.path) {
                do {
                    try await Self.verifySHA256Async(
                        of: kernelPath,
                        expected: SandboxRuntimeAssets.kernelSHA256,
                        maxBytes: Self.maxArtifactDownloadBytes
                    )
                    return Kernel(path: kernelPath, platform: .linuxArm)
                } catch {
                    debugLog(
                        "[Sandbox] Installed kernel failed verification (\(error.localizedDescription)); reinstalling"
                    )
                    try? FileManager.default.removeItem(at: kernelPath)
                }
            }

            let kernelDir = OsaurusPaths.containerKernelDir()
            try OsaurusPaths.ensureExists(kernelDir)

            // Preferred path: install the kernel bundled in the signed app
            // (release builds stage the extracted, digest-verified production
            // vmlinux in Resources/SandboxRuntime). Near-instant: one hash +
            // one copy instead of a ~665 MiB download.
            if let bundled = SandboxRuntimeAssets.bundledKernelURL() {
                await startStep(.downloadKernel, detail: L("Installing bundled kernel"))
                do {
                    try await Self.verifySHA256Async(
                        of: bundled,
                        expected: SandboxRuntimeAssets.kernelSHA256,
                        maxBytes: Self.maxArtifactDownloadBytes
                    )
                    try? FileManager.default.removeItem(at: kernelPath)
                    try FileManager.default.copyItem(at: bundled, to: kernelPath)
                    await endStep(.downloadKernel, status: .completed)
                    await endStep(.extractKernel, status: .skipped)
                    debugLog("[Sandbox] Bundled kernel installed at \(kernelPath.path)")
                    return Kernel(path: kernelPath, platform: .linuxArm)
                } catch {
                    // A bundled kernel that fails verification is treated
                    // as absent (fail-closed for the bytes, fail-open for
                    // the flow): the digest-verified download path below
                    // still guarantees kernel integrity.
                    debugLog(
                        "[Sandbox] Bundled kernel rejected (\(error.localizedDescription)); falling back to download"
                    )
                }
            }

            await startStep(.downloadKernel, detail: L("Resolving GitHub mirror"))

            let stableTarball = kernelDir.appendingPathComponent("kata.tar.zst")
            do {
                try await downloadFile(
                    from: Self.kernelDownloadURLs,
                    to: stableTarball,
                    stepID: .downloadKernel
                )
            } catch {
                await failOrResetStep(.downloadKernel, after: error)
                throw error
            }
            await endStep(.downloadKernel, status: .completed)
            defer { try? FileManager.default.removeItem(at: stableTarball) }

            await startStep(.extractKernel, detail: L("Untarring archive"))

            do {
                try await Self.extractKernel(
                    from: stableTarball,
                    installTo: kernelPath
                )
            } catch {
                await failOrResetStep(.extractKernel, after: error)
                throw error
            }
            await endStep(.extractKernel, status: .completed)

            debugLog("[Sandbox] Kernel installed at \(kernelPath.path)")
            return Kernel(path: kernelPath, platform: .linuxArm)
        }

        /// Pull the production `vmlinux` out of the digest-verified Kata
        /// tarball into `kernelPath`. Decompression runs in-process: the
        /// system `/usr/bin/tar` is built without zstd and the app's PATH
        /// has no external `zstd`, so shelling out fails on stock macOS.
        /// Detached so the decompress + hash don't pin the actor executor.
        private static func extractKernel(from tarball: URL, installTo kernelPath: URL) async throws {
            try await Task.detached(priority: .userInitiated) {
                let staged = kernelPath.appendingPathExtension("partial")
                defer { try? FileManager.default.removeItem(at: staged) }
                do {
                    try extractArchiveMember(
                        SandboxRuntimeAssets.kernelArchivePath,
                        from: tarball,
                        to: staged
                    )
                } catch {
                    throw SandboxError.provisionFailed(
                        "Could not extract kernel \(SandboxRuntimeAssets.kernelVersion) from the Kata archive: \(error.localizedDescription)"
                    )
                }

                // The tarball is digest-verified before extraction, but pin
                // the extracted binary too so the bundled-kernel path and
                // the download path install byte-identical kernels.
                try Self.verifySHA256(
                    of: staged,
                    expected: SandboxRuntimeAssets.kernelSHA256,
                    maxBytes: Self.maxArtifactDownloadBytes
                )
                try? FileManager.default.removeItem(at: kernelPath)
                try FileManager.default.moveItem(at: staged, to: kernelPath)
            }.value
        }

        /// Write one member of a (possibly zstd-compressed) tar archive to
        /// `destination`. `memberPath` matches with or without a leading
        /// `./`. Throws when the member is absent or the stream is corrupt.
        nonisolated static func extractArchiveMember(
            _ memberPath: String,
            from archive: URL,
            to destination: URL
        ) throws {
            let reader = try ArchiveReader(file: archive)
            let (_, data) = try reader.extractFile(path: memberPath)
            try data.write(to: destination, options: .atomic)
        }

        // MARK: - Private: Asset Download

        /// One mirror plus the SHA-256 the bytes must match. Identity of the
        /// downloaded artifact comes from the digest, not the URL — a CDN or
        /// release-host compromise that returns the wrong bytes is rejected
        /// before they touch the on-disk container store.
        struct DownloadSource: Sendable {
            let url: String
            let expectedSHA256: String
        }

        /// Downloads a file from the first successful URL in the list to the
        /// given destination, reporting byte-level download progress to the
        /// UI, and verifies the SHA-256 of the bytes against the expected
        /// digest. A digest mismatch is **fail-closed**: the file is deleted
        /// and provisioning aborts. This is the only thing standing between
        /// an upstream compromise and an attacker-chosen guest kernel/initfs.
        ///
        /// Downloads are resumable: an interrupted transfer (app quit,
        /// dropped connection) persists its partial bytes + validator and
        /// continues from that offset on the next attempt instead of
        /// throwing away hundreds of megabytes. See
        /// `SandboxResumableDownloader`.
        ///
        /// `stepID` is the journey step the byte counters should attach
        /// to. Passing `nil` keeps backward-compatible behaviour for any
        /// caller that doesn't care about the structured progress
        /// surface (none in production today; tests only).
        private func downloadFile(
            from sources: [DownloadSource],
            to destination: URL,
            stepID: ProvisioningStepID? = nil
        ) async throws {
            let downloader = SandboxResumableDownloader(maxBytes: Self.maxArtifactDownloadBytes)
            let resumableSources = sources.map {
                SandboxResumableDownloader.Source(url: $0.url, expectedSHA256: $0.expectedSHA256)
            }
            do {
                try await downloader.download(from: resumableSources, to: destination) { bytes, total in
                    if let stepID {
                        Task {
                            await SandboxManager.shared.reportStepBytes(
                                stepID: stepID, bytes: bytes, total: total
                            )
                        }
                    } else if total > 0 {
                        Task { @MainActor in
                            State.shared.provisioningProgress = min(Double(bytes) / Double(total), 1.0)
                        }
                    }
                }
                debugLog("[Sandbox] Downloaded + verified to \(destination.path)")
            } catch let err as SandboxResumableDownloader.DownloadError {
                switch err {
                case .integrityMismatch(let expected, let actual):
                    throw SandboxError.integrityCheckFailed(
                        "SHA-256 mismatch: expected \(expected), got \(actual)"
                    )
                case .sizeCapExceeded(let bytes, let cap):
                    throw SandboxError.integrityCheckFailed(
                        "Downloaded artifact exceeds size cap (\(bytes) > \(cap) bytes)"
                    )
                default:
                    throw SandboxError.provisionFailed(
                        err.errorDescription ?? "Download failed"
                    )
                }
            }
        }

        /// `verifySHA256` wrapped in a detached task. Lets actor-isolated
        /// callers run the hash off the actor executor without forcing the
        /// (synchronous, test-friendly) `verifySHA256` API to become async.
        static func verifySHA256Async(of url: URL, expected: String, maxBytes: Int) async throws {
            try await Task.detached(priority: .userInitiated) {
                try Self.verifySHA256(of: url, expected: expected, maxBytes: maxBytes)
            }.value
        }

        /// Hash the file at `url` with SHA-256 in 1 MiB chunks (so hashing
        /// the ~100 MiB initfs doesn't peak at 100 MiB of memory) and check
        /// it against the lower-cased hex `expected` digest. Throws
        /// `SandboxError.integrityCheckFailed` if the file exceeds
        /// `maxBytes` or the digest doesn't match.
        ///
        /// Internal so tests can drive it directly without a full container
        /// provisioning cycle.
        static func verifySHA256(of url: URL, expected: String, maxBytes: Int) throws {
            let normalized = expected.lowercased()
            // Cheap structural check: 64 lower-case hex chars.
            guard normalized.count == 64,
                normalized.allSatisfy({ $0.isHexDigit })
            else {
                throw SandboxError.integrityCheckFailed(
                    "Expected SHA-256 is malformed (got \(expected.count) chars)"
                )
            }

            let actual = try sha256Hex(of: url, maxBytes: maxBytes)
            guard actual == normalized else {
                throw SandboxError.integrityCheckFailed(
                    "SHA-256 mismatch: expected \(normalized), got \(actual)"
                )
            }
        }

        /// Lower-case hex SHA-256 of the file at `url`, read in 1 MiB chunks.
        static func sha256Hex(of url: URL, maxBytes: Int) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var hasher = SHA256()
            var totalRead = 0
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                totalRead += chunk.count
                if totalRead > maxBytes {
                    throw SandboxError.integrityCheckFailed(
                        "Downloaded artifact exceeds size cap (\(totalRead) > \(maxBytes) bytes)"
                    )
                }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        // MARK: - Private: Exec via VM Agent

        private func execViaAgent(
            containerID: String,
            args: [String],
            rlimits: [LinuxRLimit],
            env: [String: String],
            timeout: TimeInterval?,
            streamToLogs: Bool = false,
            logSource: String? = nil,
            stdoutTee: (any Writer)? = nil,
            stderrTee: (any Writer)? = nil,
            onProcessStarted: (@Sendable (ProcessHandle) -> Void)? = nil
        ) async throws -> ContainerExecResult {
            guard let pod else {
                throw SandboxError.containerNotRunning
            }
            inFlightExecs[containerID, default: 0] += 1
            lastActivityAt = Date()
            publishOccupancy()
            defer {
                if let count = inFlightExecs[containerID] {
                    inFlightExecs[containerID] = count > 1 ? count - 1 : nil
                }
                lastActivityAt = Date()
                publishOccupancy()
            }

            let source = logSource ?? "exec"
            // Authoritative collection for the model's final result envelope.
            let stdoutCollector: any Writer & DataWriterReadable
            let stderrCollector: any Writer & DataWriterReadable
            if streamToLogs {
                stdoutCollector = LoggingDataWriter(source: source, level: .stdout)
                stderrCollector = LoggingDataWriter(source: source, level: .error)
            } else {
                stdoutCollector = DataWriter()
                stderrCollector = DataWriter()
            }
            // Optionally fan out every byte to a live observer (chat-side
            // streaming tail). The collector stays the source of truth for
            // the model's `{stdout, stderr, exit_code}`; the tee is purely
            // a side-channel for the UI.
            let stdoutWire: any Writer =
                stdoutTee.map {
                    TeeWriter(primary: stdoutCollector, secondary: $0)
                } ?? stdoutCollector
            let stderrWire: any Writer =
                stderrTee.map {
                    TeeWriter(primary: stderrCollector, secondary: $0)
                } ?? stderrCollector

            var mergedEnv = env
            if mergedEnv["PATH"] == nil {
                mergedEnv["PATH"] = LinuxProcessConfiguration.defaultPath
            }
            let environ = mergedEnv.map { "\($0.key)=\($0.value)" }
            let process = try await pod.execInContainer(containerID, processID: UUID().uuidString) { config in
                config.arguments = args
                config.environmentVariables = environ
                Self.applyProcessRestrictions(to: &config)
                config.rlimits = rlimits
                config.stdout = stdoutWire
                config.stderr = stderrWire
            }

            try await process.start()

            // Hand the kill handle to the caller before we start
            // waiting. The user's [Terminate] button uses this to
            // signal the live exec without us needing to hold a
            // separate process registry.
            if let onProcessStarted {
                let handle = ProcessHandle(pid: process.pid) { signal in
                    try await process.kill(Signal(rawValue: signal))
                }
                onProcessStarted(handle)
            }

            do {
                let exitStatus = try await waitWithInactivityTimeout(
                    process: process,
                    stdout: stdoutCollector,
                    stderr: stderrCollector,
                    timeout: timeout
                )
                try await process.delete()
                return ContainerExecResult(
                    stdout: stdoutCollector.string,
                    stderr: stderrCollector.string,
                    exitCode: exitStatus.exitCode,
                    outputTruncated: stdoutCollector.truncated || stderrCollector.truncated
                )
            } catch {
                try? await process.delete()
                throw error
            }
        }

        /// Waits for a process to exit, using an inactivity-based timeout
        /// that resets whenever stdout or stderr receives data. Only kills
        /// the process if no output arrives for `timeout` seconds.
        ///
        /// `timeout: nil` means "no idle check" — we just await
        /// `process.wait()` straight, with no per-poll wakeup. Used by the
        /// streaming exec path where the user terminate button + container
        /// resource limits are the safety net.
        private func waitWithInactivityTimeout(
            process: LinuxProcess,
            stdout: any DataWriterReadable,
            stderr: any DataWriterReadable,
            timeout: TimeInterval?
        ) async throws -> ExitStatus {
            guard let timeout else {
                return try await process.wait()
            }
            let startTime = Date()
            return try await withThrowingTaskGroup(of: ExitStatus?.self) { group in
                group.addTask {
                    try await process.wait()
                }
                group.addTask {
                    let pollInterval: UInt64 = 2_000_000_000
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: pollInterval)
                        let lastActivity = max(
                            stdout.lastWriteTime ?? startTime,
                            stderr.lastWriteTime ?? startTime
                        )
                        if Date().timeIntervalSince(lastActivity) >= timeout {
                            return nil
                        }
                    }
                    return nil
                }

                guard let first = try await group.next() else {
                    throw SandboxError.timeout
                }
                group.cancelAll()

                if let status = first {
                    return status
                }

                try? await process.kill(15)
                throw SandboxError.timeout
            }
        }

        // MARK: - Runtime liveness

        /// Cheap guest liveness check used when a provisioning exec failed
        /// while the cached status still says `.running`. Returns `false`
        /// when the VM object is gone or a trivial root exec cannot complete
        /// within a short window — the post-sleep "VM died silently" case.
        /// Seatbelt has no guest and is always considered alive.
        public func probeRuntimeAlive() async -> Bool {
            if SandboxBackend.current == .seatbelt { return _status.isRunning }
            guard pod != nil else { return false }
            do {
                let result = try await exec(command: "true", timeout: 10, target: .system)
                return result.succeeded
            } catch {
                return false
            }
        }

        /// Record that the running VM has been lost underneath us. Moves the
        /// status to `.error` so the next `startContainer()` takes the
        /// recovery branch (`cleanupAfterFailure` + fresh provision) instead
        /// of short-circuiting on a cached `.running`.
        public func markRuntimeLost(reason: String) async {
            guard SandboxBackend.current == .virtualMachine else { return }
            debugLog("[Sandbox] Runtime lost: \(reason)")
            _status = .error(reason)
            syncStatus()
            await MainActor.run { State.shared.containerInfo = nil }
        }

        // MARK: - Helpers

        func cleanupAfterFailure() async {
            // A half-written unpack never becomes the template (it stays at
            // the staging path), so the template and environments survive.
            await teardownPod()
            networkReadyTask?.cancel()
            networkReadyTask = nil
            networkReady = false
            postStartVerifyTask?.cancel()
            postStartVerifyTask = nil
            let containerDir = staleContainerDir
            try? await Task.detached(priority: .userInitiated) {
                try Self.removeContainerStateKeepingLegacyRootfs(at: containerDir)
            }.value
            await HostAPIBridgeServer.shared.stop()
            await teardownEgressProxy()
            releaseVMOwnership()
        }

        private func acquireVMOwnershipIfNeeded() async throws {
            guard SandboxBackend.current == .virtualMachine, vmOwnershipLease == nil else {
                return
            }
            do {
                vmOwnershipLease = try await SandboxVMOwnershipLease.acquire(
                    waitingUpTo: SandboxVMOwnershipLease.defaultOwnerExitWait
                )
            } catch let conflict as SandboxVMOwnershipLease.OwnershipConflict {
                throw SandboxError.ownershipConflict(
                    conflict.errorDescription ?? "Sandbox VM is owned by another process"
                )
            }
        }

        private func releaseVMOwnership() {
            vmOwnershipLease?.release()
            vmOwnershipLease = nil
        }

        /// `forciblyRemove` wrapped in a detached task. Lets actor-isolated
        /// callers run the tree walk off the actor executor so a slow disk
        /// or a stuck FUSE mount can't stall every other queued sandbox
        /// call while cleanup grinds through.
        nonisolated static func forciblyRemoveAsync(at url: URL) async throws {
            try await Task.detached(priority: .userInitiated) {
                try Self.forciblyRemove(at: url)
            }.value
        }

        /// Clears the pod's state directory but keeps a pre-pod
        /// `rootfs.ext4`. Until a pod boot succeeds (which deletes it) that
        /// disk is the only copy of the old shared sandbox, and an earlier
        /// version still boots from it.
        nonisolated static func removeContainerStateKeepingLegacyRootfs(at dir: URL) throws {
            let fm = FileManager.default
            let legacy = dir.appendingPathComponent("rootfs.ext4")
            guard fm.fileExists(atPath: legacy.path) else {
                try forciblyRemove(at: dir)
                return
            }
            let parked = dir.deletingLastPathComponent()
                .appendingPathComponent(".\(dir.lastPathComponent)-legacy-rootfs.ext4")
            try? fm.removeItem(at: parked)
            try fm.moveItem(at: legacy, to: parked)
            defer {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? fm.moveItem(at: parked, to: legacy)
            }
            try forciblyRemove(at: dir)
        }

        /// Robust container-state cleanup. A plain `removeItem` can fail and
        /// leave the directory behind when the previous run left files in
        /// use (FUSE / 9p mounts, locked sockets, POSIX ACLs). When that
        /// happens, `manager.create()` later fails with the misleading
        /// "file already exists" error. This walks the tree first so each
        /// child is removed individually before retrying the parent, and
        /// surfaces the underlying error if anything is still stuck.
        nonisolated static func forciblyRemove(at url: URL) throws {
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else { return }

            do {
                try fm.removeItem(at: url)
                return
            } catch {
                // Walk + best-effort delete each child, then retry the parent.
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: []) {
                    for case let child as URL in enumerator {
                        try? fm.removeItem(at: child)
                    }
                }
                do {
                    try fm.removeItem(at: url)
                } catch {
                    NSLog(
                        "[SandboxManager] Failed to clean stale container state at \(url.path): \(error.localizedDescription). Run `rm -rf \(url.path)` manually if startup keeps failing."
                    )
                    throw error
                }
            }
        }

        private func ensureHostDirectories() throws {
            try OsaurusPaths.ensureExists(OsaurusPaths.container())
            try OsaurusPaths.ensureExists(OsaurusPaths.containerWorkspace())
            try OsaurusPaths.ensureExists(OsaurusPaths.containerAgentsDir())
            try OsaurusPaths.ensureExists(OsaurusPaths.containerSharedDir())
        }

        /// Per-boot guest setup, once per container (each has its own
        /// `/proc`, `/run`, and `/etc`):
        ///  - stale `adduser`/`deluser` lock files from a run killed
        ///    mid-write (no user admin can be running yet),
        ///  - a check that `/proc` is mounted `hidepid=2`
        ///    (`containerBaseMounts`); boot fails if it isn't,
        ///  - the bridge-token directory (token files are mode 0600;
        ///    0711 on the dir lets the user stat its own file without
        ///    enumerating; `/run` is tmpfs so this re-runs every boot).
        /// The shim needs no step: it is a read-only file mount.
        static var perBootSetupScript: String {
            """
            set -e
            rm -f /etc/passwd+ /etc/group+ /etc/shadow+
            grep -Eq '^proc /proc proc .*hidepid=(2|invisible)' /proc/mounts || { echo "/proc is not mounted hidepid=2" >&2; exit 1; }
            mkdir -p \(Self.bridgeTokenDir)
            chmod 0711 \(Self.bridgeTokenDir)
            """
        }

        private func configureSandbox() async throws {
            // None of the steps below depend on outbound network — the shim
            // copy + bridge-token dir are pure in-guest filesystem ops. So we
            // kick the wget readiness probe off in the background and only
            // wait on it lazily from the first network-using caller (plugin
            // `apk add`, diagnostics, etc). In most environments the network
            // is up well before anyone asks, so the wait becomes a no-op.
            startNetworkReadinessProbe()

            let setup = Self.perBootSetupScript
            let targets: [SandboxExecTarget] = [.system] + podMembers.map { .agent($0) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for target in targets {
                    group.addTask {
                        let result = try await self.execAsRoot(command: setup, target: target)
                        guard result.succeeded else {
                            throw SandboxError.provisionFailed(
                                "Guest bootstrap failed in \(SandboxPodLayout.containerID(for: target)): \(result.stderr)"
                            )
                        }
                    }
                }
                try await group.waitForAll()
            }
        }

        /// Spawn (or no-op join to) a background task that polls the guest
        /// until it can resolve+reach the Alpine CDN. Idempotent — repeated
        /// calls after a successful probe return instantly via `networkReady`.
        private func startNetworkReadinessProbe() {
            if networkReady { return }
            if networkReadyTask != nil { return }
            networkReadyTask = Task { [weak self] in
                guard let self else { return false }
                let ok = await self.runNetworkReadinessProbe()
                await self.setNetworkReady(ok)
                return ok
            }
        }

        private func setNetworkReady(_ ready: Bool) {
            networkReady = ready
            networkReadyTask = nil
        }

        /// Public hook used by paths that genuinely need outbound network —
        /// `installSystemDependencies`, `runDiagnostics` apk check, etc.
        /// Returns `true` as soon as the readiness probe sees a healthy
        /// response, `false` if the deadline elapses first. Callers may
        /// still attempt their operation on `false` and let it fail with
        /// the real error (e.g. wget's DNS error), preserving today's
        /// behavior where `waitForNetwork()` was best-effort.
        @discardableResult
        public func awaitNetworkReady() async -> Bool {
            if networkReady { return true }
            startNetworkReadinessProbe()
            guard let task = networkReadyTask else { return networkReady }
            return await task.value
        }

        /// Polls until the guest can reach the Alpine CDN, so plugins that
        /// run `apk add` right after provisioning don't hit DNS failures.
        /// Exponential backoff (250 ms → 500 ms → 1 s) keeps the common
        /// case (network up within a second of boot) snappy without
        /// hammering the guest, while a 20 s ceiling avoids hanging the
        /// first network-using caller forever on a misconfigured host.
        private func runNetworkReadinessProbe() async -> Bool {
            let deadline = Date().addingTimeInterval(20)
            var sleepNanos: UInt64 = 250_000_000
            var attempt = 0
            while Date() < deadline {
                attempt += 1
                let result = try? await exec(
                    command: "wget -q --spider http://dl-cdn.alpinelinux.org 2>/dev/null && echo ok",
                    timeout: 5,
                    target: .system
                )
                if result?.stdout.contains("ok") == true {
                    debugLog("[Sandbox] Network ready after \(attempt) attempt(s)")
                    return true
                }
                debugLog("[Sandbox] Network not ready yet (attempt \(attempt))")
                try? await Task.sleep(nanoseconds: sleepNanos)
                // `stopContainer` cancels this probe. A cancelled task's
                // `exec` and `Task.sleep` both return immediately, which
                // turned the remainder of the 20 s window into a hot loop
                // (thousands of attempts per second in the quit chain).
                if Task.isCancelled {
                    debugLog("[Sandbox] Network readiness probe cancelled after \(attempt) attempt(s)")
                    return false
                }
                sleepNanos = min(sleepNanos * 2, 1_000_000_000)
            }
            debugLog("[Sandbox] Network readiness probe timed out after 20 s")
            return false
        }

        // MARK: - osaurus-host Shell Shim

        private static let osaurusHostShimScript = """
            #!/bin/sh
            # osaurus-host — Host API bridge shim for sandbox plugins.
            # Translates CLI commands to HTTP calls over a vsock-relayed Unix socket.
            #
            # Identity is bound to the calling Linux user via a per-user bridge
            # token at /run/osaurus/$USER.token (mode 0600, owned by that user).
            # The host bridge derives the agent identity from the token alone —
            # caller-supplied X-Osaurus-User headers are no longer trusted.
            SOCK="/tmp/osaurus-bridge.sock"
            API="http://localhost/api"
            USER=$(id -un)
            PLUGIN="${OSAURUS_PLUGIN:-$(basename "$(pwd)")}"
            TOKEN_FILE="/run/osaurus/$USER.token"
            if [ ! -r "$TOKEN_FILE" ]; then
              echo "osaurus-host: bridge token for $USER missing (host has not provisioned this agent yet)" >&2
              exit 1
            fi
            TOKEN=$(cat "$TOKEN_FILE")
            if [ -z "$TOKEN" ]; then
              echo "osaurus-host: bridge token for $USER is empty" >&2
              exit 1
            fi

            # Always invoke curl through this helper so the bearer token and
            # plugin header are attached as quoted headers (no word-splitting
            # surprises around the space in "Bearer <token>").
            _call() {
              _tmp=$(mktemp)
              _code=$(curl -s -o "$_tmp" -w '%{http_code}' \
                --unix-socket "$SOCK" \
                -H "Authorization: Bearer $TOKEN" \
                -H "X-Osaurus-Plugin: $PLUGIN" \
                "$@")
              if [ "$_code" -ge 400 ] 2>/dev/null || [ -z "$_code" ]; then
                _err=$(jq -r '.error // empty' < "$_tmp" 2>/dev/null)
                rm -f "$_tmp"
                echo "osaurus-host: error ${_code:-000}: ${_err:-request failed}" >&2
                exit 1
              fi
              cat "$_tmp"
              rm -f "$_tmp"
            }

            case "$1" in
              secrets)
                case "$2" in
                  get) _call "$API/secrets/$3" | jq -r '.value // empty' ;;
                  *) echo "Usage: osaurus-host secrets get <name>" >&2; exit 1 ;;
                esac ;;
              config)
                case "$2" in
                  get) _call "$API/config/$3" | jq -r '.value // empty' ;;
                  set) _call -X POST "$API/config/$3" -d "{\\"value\\":\\"$4\\"}" > /dev/null ;;
                  *) echo "Usage: osaurus-host config get|set <key> [value]" >&2; exit 1 ;;
                esac ;;
              inference)
                case "$2" in
                  chat)
                    shift 2; MSG=""
                    while [ $# -gt 0 ]; do case "$1" in -m) shift; MSG="$1" ;; esac; shift; done
                    _call -X POST "$API/inference/chat" \
                      -d "{\\"messages\\":[{\\"role\\":\\"user\\",\\"content\\":\\"$MSG\\"}]}" | jq -r '.content // empty' ;;
                  *) echo "Usage: osaurus-host inference chat -m <message>" >&2; exit 1 ;;
                esac ;;
              agent)
                case "$2" in
                  dispatch)
                    # The host bridge ignores the body's agent_id and uses the
                    # token-bound identity. We still send it for backwards
                    # compatibility with older bridges, but it must match.
                    _call -X POST "$API/agent/dispatch" -d "{\\"agent_id\\":\\"$3\\",\\"task\\":\\"$4\\"}" ;;
                  memory)
                    case "$3" in
                      query) _call -X POST "$API/agent/memory/query" -d "{\\"query\\":\\"$4\\"}" ;;
                      store) _call -X POST "$API/agent/memory/store" -d "{\\"content\\":\\"$4\\"}" ;;
                      *) echo "Usage: osaurus-host agent memory query|store <text>" >&2; exit 1 ;;
                    esac ;;
                  *) echo "Usage: osaurus-host agent dispatch|memory ..." >&2; exit 1 ;;
                esac ;;
              events)
                case "$2" in
                  emit) _call -X POST "$API/events/emit" -d "{\\"type\\":\\"$3\\",\\"payload\\":${4:-{}}}" > /dev/null ;;
                  *) echo "Usage: osaurus-host events emit <type> [payload]" >&2; exit 1 ;;
                esac ;;
              plugin)
                case "$2" in
                  create) cat | _call -X POST "$API/plugin/create" -d @- ;;
                  *) echo "Usage: osaurus-host plugin create < plugin.json" >&2; exit 1 ;;
                esac ;;
              log)
                _call -X POST "$API/log" \
                  -d "{\\"level\\":\\"$2\\",\\"message\\":\\"$3\\"}" > /dev/null ;;
              *) echo "Usage: osaurus-host <secrets|config|inference|agent|events|plugin|log> ..." >&2; exit 1 ;;
            esac
            """

        private func syncStatus() {
            let status = _status
            Task { @MainActor in
                State.shared.status = status
                NotificationCenter.default.post(name: .toolsListChanged, object: nil)
            }
        }

        /// Centralised actionable messages for the most common sandbox start
        /// failures. Lookups happen against (NSCocoaErrorDomain, code),
        /// (NSPOSIXErrorDomain, code), and substrings of `String(describing:)`
        /// for SDK-internal errors that don't bridge cleanly to NSError.
        private static let startFailureHints:
            (
                cocoa: [Int: String],
                posix: [Int32: String],
                substrings: [(needle: String, message: String)]
            ) = (
                cocoa: [
                    NSFileWriteFileExistsError:
                        "Stale sandbox state on disk. Run `rm -rf ~/.osaurus/container/containers/osaurus-sandbox` and try again.",
                    NSFileWriteOutOfSpaceError:
                        "Not enough disk space to start the sandbox container.",
                ],
                posix: [
                    EEXIST:
                        "Stale sandbox state on disk. Run `rm -rf ~/.osaurus/container/containers/osaurus-sandbox` and try again.",
                    EBUSY:
                        "A sandbox file or mount is in use by another process. Try restarting the app.",
                    EADDRINUSE:
                        "Sandbox network port is already in use. Another VM may be running.",
                    EACCES:
                        "Sandbox start denied by macOS — check that osaurus has the required entitlements.",
                    EPERM:
                        "Sandbox start denied by macOS — check that osaurus has the required entitlements.",
                    ENOSPC:
                        "Not enough disk space to start the sandbox. Free up a few GB and try again.",
                ],
                substrings: [
                    (
                        "No space left on device",
                        "Not enough disk space to start the sandbox. Free up a few GB and try again."
                    ),
                    ("GRPC", "Container failed to start (VM error). Try resetting the container."),
                    (
                        "vmnet",
                        "Container networking failed. Ensure no other VMs are using conflicting network resources."
                    ),
                ]
            )

        private static func friendlyError(from error: Error) -> Error {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
                let message = startFailureHints.cocoa[nsError.code]
            {
                return SandboxError.startFailed(message, underlying: error)
            }
            if nsError.domain == NSPOSIXErrorDomain,
                let message = startFailureHints.posix[Int32(nsError.code)]
            {
                return SandboxError.startFailed(message, underlying: error)
            }
            let desc = String(describing: error)
            if let hit = startFailureHints.substrings.first(where: { desc.contains($0.needle) }) {
                return SandboxError.startFailed(hit.message, underlying: error)
            }
            return error
        }

        // MARK: - Provisioning Journey

        /// Wipe every published provisioning surface back to "no work in
        /// flight". Used after `removeContainer` (and any future full
        /// reset) so a stale finished `journey` from a previous boot
        /// can't bleed into the next provision UI.
        @MainActor
        private static func resetProvisioningState() {
            State.shared.journey = nil
            State.shared.currentActivity = nil
            clearLegacyProvisioningScalars()
        }

        /// Static label table — kept here (instead of inside
        /// `ProvisioningStepID`) so the model layer doesn't have to know
        /// about end-user copy. Re-using these for both the journey and
        /// the legacy `provisioningPhase` keeps the two surfaces in sync.
        static func defaultStepLabel(_ id: ProvisioningStepID) -> String {
            switch id {
            case .downloadKernel: return L("Downloading Linux kernel")
            case .downloadInitFS: return L("Downloading init filesystem")
            case .extractKernel: return L("Extracting kernel")
            case .createContainer: return L("Pulling sandbox image")
            case .startBridge: return L("Starting host API bridge")
            case .startContainer: return L("Booting container")
            case .configureSandbox: return L("Configuring sandbox")
            case .verifyPlugins: return L("Restoring plugins")
            }
        }

        /// Build the ordered step list a fresh `provision()` will go
        /// through. On warm restarts (`isRestart == true`), the cached
        /// kernel + initfs steps are pre-marked `.skipped` so the UI
        /// renders them as completed checkmarks instead of indeterminate
        /// spinners that never tick. On a *fully* warm boot
        /// (`isWarmRestart == true`), the `createContainer` step — which
        /// normally unpacks the 8 GiB rootfs from cached OCI layers — is
        /// also `.skipped` because the persisted `rootfs.ext4` is reused
        /// directly via the third `ContainerManager.create` overload.
        private func plannedSteps(
            isRestart: Bool,
            isWarmRestart: Bool,
            hasPlugins: Bool
        ) -> [ProvisioningStepState] {
            let seeds = SandboxConfigurationStore.load().lastBootDurations ?? [:]
            func eta(_ id: ProvisioningStepID) -> Double? { seeds[id.rawValue] }

            func base(_ id: ProvisioningStepID, status: ProvisioningStepStatus = .pending) -> ProvisioningStepState {
                ProvisioningStepState(
                    id: id,
                    label: Self.defaultStepLabel(id),
                    status: status,
                    etaSeconds: eta(id)
                )
            }

            var steps: [ProvisioningStepState] = []
            steps.append(base(.downloadKernel, status: isRestart ? .skipped : .pending))
            steps.append(base(.downloadInitFS, status: isRestart ? .skipped : .pending))
            steps.append(base(.extractKernel, status: isRestart ? .skipped : .pending))
            steps.append(base(.startBridge))
            steps.append(base(.createContainer, status: isWarmRestart ? .skipped : .pending))
            steps.append(base(.startContainer))
            steps.append(base(.configureSandbox))
            if hasPlugins {
                steps.append(base(.verifyPlugins))
            }
            return steps
        }

        /// Begin a fresh journey, replacing any prior one. Also stamps the
        /// legacy `isProvisioning` flag so existing observers flip to the
        /// progress UI on first tick.
        private func beginJourney(steps: [ProvisioningStepState]) async {
            let journey = ProvisioningJourney(
                steps: steps,
                startedAt: Date()
            )
            await MainActor.run {
                Self.resetProvisioningState()
                State.shared.journey = journey
                State.shared.isProvisioning = true
            }
        }

        /// Single MainActor write path for journey mutations. Locates the
        /// step matching `id`, hands it (along with the parent journey)
        /// to `mutate`, republishes the journey, and syncs the legacy
        /// scalar shims. Every step helper below routes through here so
        /// the "look up index → guard → write back → sync" boilerplate
        /// lives in exactly one place.
        @MainActor
        private static func mutateJourney(
            stepID: ProvisioningStepID,
            _ mutate: (inout ProvisioningJourney, inout ProvisioningStepState) -> Void
        ) {
            guard var journey = State.shared.journey,
                let index = journey.steps.firstIndex(where: { $0.id == stepID })
            else { return }
            var step = journey.steps[index]
            mutate(&journey, &step)
            journey.steps[index] = step
            State.shared.journey = journey
            syncLegacyPhase(from: journey)
        }

        /// Apply a transition to a single step. `mutate` runs against an
        /// inout copy of the existing step state so callers can change
        /// just the fields they care about (status, bytes, progress,
        /// detail) without rebuilding the whole struct.
        private func updateStep(
            _ id: ProvisioningStepID,
            _ mutate: @MainActor @Sendable (inout ProvisioningStepState) -> Void
        ) async {
            await MainActor.run {
                Self.mutateJourney(stepID: id) { _, step in mutate(&step) }
            }
        }

        /// Mark a step as `.inProgress`, stamping `startedAt` and
        /// promoting it to `currentStepID`. Idempotent — re-entering an
        /// already-active step leaves its start time alone.
        private func startStep(_ id: ProvisioningStepID, detail: String? = nil) async {
            await MainActor.run {
                Self.mutateJourney(stepID: id) { journey, step in
                    if step.status != .inProgress {
                        step.status = .inProgress
                        step.startedAt = step.startedAt ?? Date()
                        step.finishedAt = nil
                    }
                    if let detail { step.detail = detail }
                    journey.currentStepID = id
                }
                // Journey-less callers (background prefetch) must not
                // leak activity text into a UI that isn't provisioning.
                if let detail, State.shared.journey != nil {
                    State.shared.currentActivity = detail
                }
            }
        }

        /// Mark a step as `.completed` / `.skipped` / `.failed`, stamping
        /// `finishedAt` and forcing the progress display to 100% so the
        /// SwiftUI bar lands fully filled rather than hanging at e.g. 99%.
        private func endStep(_ id: ProvisioningStepID, status: ProvisioningStepStatus) async {
            await MainActor.run {
                Self.mutateJourney(stepID: id) { journey, step in
                    step.status = status
                    step.finishedAt = Date()
                    if status == .completed || status == .skipped {
                        step.progress = 1.0
                        step.etaSeconds = 0
                    }
                    Self.handOffCurrentStep(from: id, in: &journey)
                }
                Self.syncActivityToCurrentStep()
            }
        }

        /// Asset steps run concurrently, so when the current step leaves
        /// `.inProgress` the most recently started sibling still running
        /// takes over instead of leaving the journey with no current step.
        private static func handOffCurrentStep(from id: ProvisioningStepID, in journey: inout ProvisioningJourney) {
            guard journey.currentStepID == id else { return }
            journey.currentStepID =
                journey.steps
                .filter { $0.id != id && $0.status == .inProgress }
                .max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }?
                .id
        }

        /// Point the "now doing" line at the current step after a hand-off.
        /// Leaves the last line in place when nothing is running.
        @MainActor
        private static func syncActivityToCurrentStep() {
            guard let journey = State.shared.journey,
                let id = journey.currentStepID,
                let step = journey.step(id)
            else { return }
            let line: String?
            if let total = step.bytesTotal, total > 0 {
                line = step.detail ?? formatByteActivity(
                    bytes: step.bytesProcessed ?? 0,
                    total: total,
                    bytesPerSecond: step.bytesPerSecond
                )
            } else {
                line = step.detail
            }
            if let line, State.shared.currentActivity != line {
                State.shared.currentActivity = line
            }
        }

        /// Close out an asset step whose work threw. A sibling asset failing
        /// cancels the others; those return to `.pending` rather than
        /// showing a failure of their own.
        private func failOrResetStep(_ id: ProvisioningStepID, after error: Error) async {
            if error is CancellationError || Task.isCancelled {
                await resetStepStatus(id, to: .pending)
            } else {
                await endStep(id, status: .failed)
            }
        }

        /// Roll a journey step back to a clean status (typically `.pending`)
        /// without finalizing it. Used by the warm-restart fallback in
        /// `provision()`: after the warm attempt's `bootContainer` fails,
        /// the `.startContainer` step may be `.inProgress`, but we're about
        /// to drive it again via the cold rebuild and need `startStep` to
        /// re-enter the in-progress state with fresh timestamps. Without
        /// this reset, `startStep`'s idempotent guard would leave the row
        /// stuck on the warm attempt's `startedAt`.
        private func resetStepStatus(_ id: ProvisioningStepID, to status: ProvisioningStepStatus) async {
            await MainActor.run {
                Self.mutateJourney(stepID: id) { journey, step in
                    step.status = status
                    step.startedAt = nil
                    step.finishedAt = nil
                    step.progress = nil
                    step.detail = nil
                    step.bytesProcessed = nil
                    step.bytesTotal = nil
                    step.bytesPerSecond = nil
                    Self.handOffCurrentStep(from: id, in: &journey)
                }
                Self.syncActivityToCurrentStep()
            }
        }

        /// Update the current "now doing" subtitle that floats under the
        /// active step in the UI. Cheap and idempotent so the SDK
        /// `ProgressHandler` and the download delegate can call it on
        /// every event without thrashing SwiftUI.
        private func setActivity(_ text: String?) async {
            await MainActor.run {
                if State.shared.currentActivity != text {
                    State.shared.currentActivity = text
                }
            }
        }

        /// Pure rate / ETA recompute for the active byte-based step.
        /// Called from the download delegate on every progress event and
        /// from the SDK `ProgressHandler` for image pull / unpack.
        ///
        /// Uses a simple instantaneous rate (bytes / elapsed since start)
        /// rather than a windowed EWMA — the underlying source already
        /// emits steady ~10–30 Hz updates, and the noisier full-history
        /// rate makes the ETA decay more predictably than a windowed
        /// estimate spiking near the tail of the download.
        /// Last time a byte-progress event for each step was reflected into
        /// the published journey. Byte callbacks arrive per network chunk —
        /// far faster than the UI can meaningfully display — and every
        /// publish re-renders every provisioning observer (the settings
        /// journey view, the composer's sandbox chip), which surfaced as
        /// visible flicker during runtime downloads. Coalesced to 10 Hz;
        /// a step's first event and its terminal event always pass.
        private var lastByteProgressPublish: [ProvisioningStepID: Date] = [:]

        private func applyByteProgress(
            stepID: ProvisioningStepID,
            bytes: Int64,
            total: Int64,
            detail: String? = nil
        ) async {
            let now = Date()
            let isTerminal = total > 0 && bytes >= total
            if !isTerminal,
                let last = lastByteProgressPublish[stepID],
                now.timeIntervalSince(last) < 0.1
            {
                return
            }
            lastByteProgressPublish[stepID] = now
            await MainActor.run {
                var activityLine: String?
                Self.mutateJourney(stepID: stepID) { journey, step in
                    // First byte event also serves as the step start
                    // signal — defense in depth for any path that
                    // forgot to call `startStep`.
                    if step.status != .inProgress {
                        step.status = .inProgress
                        step.startedAt = step.startedAt ?? Date()
                    }
                    step.bytesProcessed = bytes
                    if total > 0 {
                        step.bytesTotal = total
                        step.progress = min(max(Double(bytes) / Double(total), 0), 1)
                    }
                    let (rate, eta) = Self.computeByteRateETA(
                        bytes: bytes,
                        total: total,
                        elapsed: step.elapsedSeconds
                    )
                    if let rate { step.bytesPerSecond = rate }
                    if let eta { step.etaSeconds = eta }
                    if let detail { step.detail = detail }
                    // Concurrent downloads all report bytes; letting each
                    // event claim the current step made the UI bounce
                    // between rows. Only an idle journey is claimed here.
                    if journey.currentStepID == nil { journey.currentStepID = stepID }
                    guard journey.currentStepID == stepID else { return }

                    if let detail {
                        activityLine = detail
                    } else if total > 0 {
                        activityLine = Self.formatByteActivity(
                            bytes: bytes,
                            total: total,
                            bytesPerSecond: step.bytesPerSecond
                        )
                    }
                }
                if let activityLine, State.shared.currentActivity != activityLine {
                    State.shared.currentActivity = activityLine
                }
            }
        }

        /// Clear the three legacy provisioning scalars that pre-date the
        /// `journey` model. Used at every "we're done with the fullscreen
        /// UI" hand-off (soft-conclude, full finish, full reset).
        @MainActor
        private static func clearLegacyProvisioningScalars() {
            State.shared.isProvisioning = false
            State.shared.provisioningPhase = nil
            State.shared.provisioningProgress = nil
        }

        /// Soft-conclude the provisioning surface without finalizing the
        /// journey. Flips the legacy `isProvisioning` flag back to
        /// `false` so SwiftUI swaps from the fullscreen progress view
        /// to the regular dashboard, but keeps the journey alive so
        /// remaining work (`verifyPlugins`) can still render in the
        /// post-start tasks card. The matching `finishJourney(success:)`
        /// is called later by the post-start observer.
        private func concludeProvisioningPhase() async {
            await MainActor.run { Self.clearLegacyProvisioningScalars() }
        }

        /// Finalize the journey on success: stamp `finishedAt`, persist
        /// per-step durations into `SandboxConfiguration.lastBootDurations`
        /// for future ETA seeding, and clear the legacy provisioning flag.
        private func finishJourney(success: Bool) async {
            await MainActor.run {
                guard var journey = State.shared.journey else { return }
                let now = Date()
                journey.finishedAt = now
                journey.failed = !success
                journey.currentStepID = nil
                if success {
                    // Force any still-pending steps (the rare case where
                    // we exited the happy path before the last step
                    // touched them — e.g. no plugins to verify) to a
                    // completed terminal so the UI doesn't show pending
                    // checkmarks after the dashboard is back.
                    for i in journey.steps.indices where journey.steps[i].status == .pending {
                        journey.steps[i].status = .skipped
                        journey.steps[i].finishedAt = journey.steps[i].finishedAt ?? now
                        journey.steps[i].progress = 1.0
                        journey.steps[i].etaSeconds = 0
                    }
                }
                State.shared.journey = journey
                Self.clearLegacyProvisioningScalars()
                State.shared.currentActivity = nil

                if success {
                    Self.persistLearnedDurations(from: journey)
                }
            }
        }

        /// Write each `.completed` step's elapsed time into
        /// `SandboxConfiguration.lastBootDurations` so the next provision
        /// can seed ETAs from real history. Coalesces on the existing
        /// map so unrelated keys aren't blown away, and only re-saves
        /// when the map actually changed.
        @MainActor
        private static func persistLearnedDurations(from journey: ProvisioningJourney) {
            var config = SandboxConfigurationStore.load()
            var durations = config.lastBootDurations ?? [:]
            for step in journey.steps {
                guard let start = step.startedAt,
                    let end = step.finishedAt,
                    step.status == .completed
                else { continue }
                durations[step.id.rawValue] = max(0.1, end.timeIntervalSince(start))
            }
            guard durations != config.lastBootDurations else { return }
            config.lastBootDurations = durations
            SandboxConfigurationStore.save(config)
        }

        /// Reflect the current step's label + progress into the legacy
        /// `provisioningPhase` / `provisioningProgress` scalars. Must be
        /// called from the MainActor (already guaranteed by the helpers
        /// above that all use `MainActor.run`). `internal` so tests can
        /// assert the shim mapping without driving a real provision.
        @MainActor
        static func syncLegacyPhase(from journey: ProvisioningJourney) {
            let activeStep: ProvisioningStepState? = {
                if let current = journey.currentStepID,
                    let step = journey.steps.first(where: { $0.id == current })
                {
                    return step
                }
                return journey.steps.first { $0.status == .inProgress }
            }()
            // Skip equal writes: `@Published` fires `objectWillChange` on
            // every assignment, and re-setting the same phase string on each
            // byte event re-rendered every provisioning observer.
            if let step = activeStep {
                let phase = step.label + "…"
                if State.shared.provisioningPhase != phase {
                    State.shared.provisioningPhase = phase
                }
                if State.shared.provisioningProgress != step.progress {
                    State.shared.provisioningProgress = step.progress
                }
            } else if journey.finishedAt != nil {
                if State.shared.provisioningPhase != nil {
                    State.shared.provisioningPhase = nil
                }
                if State.shared.provisioningProgress != nil {
                    State.shared.provisioningProgress = nil
                }
            }
        }

        /// Compose a one-line "45.1 MB / 98.0 MB · 8.2 MB/s" string from
        /// the most recent byte event. Falls back to omitting the rate
        /// when we don't yet have a stable measurement (first ~250 ms).
        static func formatByteActivity(
            bytes: Int64,
            total: Int64,
            bytesPerSecond: Double?
        ) -> String {
            let processedStr = Self.formatBytes(bytes)
            let totalStr = Self.formatBytes(total)
            if let rate = bytesPerSecond, rate > 0 {
                let rateStr = Self.formatBytes(Int64(rate)) + "/s"
                return "\(processedStr) / \(totalStr) · \(rateStr)"
            }
            return "\(processedStr) / \(totalStr)"
        }

        /// Pure rate + ETA math used by `applyByteProgress`. Returns
        /// `(rate, eta)`:
        ///   * `rate`: observed bytes/second since `startedAt`, or `nil`
        ///     when the sample window is too short (< 250 ms) for a
        ///     stable number.
        ///   * `eta`: seconds remaining when both `total > bytes` and
        ///     `rate > 0`; `0` when we've already streamed everything
        ///     (`total == bytes`); `nil` otherwise.
        ///
        /// Extracted from the actor body so tests can drive it without
        /// having to fake out the MainActor journey state.
        nonisolated static func computeByteRateETA(
            bytes: Int64,
            total: Int64,
            elapsed: Double
        ) -> (rate: Double?, eta: Double?) {
            guard elapsed > 0.25, bytes > 0 else { return (nil, nil) }
            let rate = Double(bytes) / elapsed
            if total > bytes, rate > 0 {
                return (rate, Double(total - bytes) / rate)
            }
            if total > 0, total == bytes {
                return (rate, 0)
            }
            return (rate, nil)
        }

        /// Human-readable byte size formatter. Kept module-local (and
        /// not a `ByteCountFormatter`) so we get consistent units across
        /// the rate + total + processed fields in a single line.
        static func formatBytes(_ bytes: Int64) -> String {
            let n = Double(max(bytes, 0))
            if n >= 1024 * 1024 * 1024 {
                return String(format: "%.1f GB", n / (1024 * 1024 * 1024))
            }
            if n >= 1024 * 1024 {
                return String(format: "%.1f MB", n / (1024 * 1024))
            }
            if n >= 1024 {
                return String(format: "%.1f KB", n / 1024)
            }
            return "\(Int(n)) B"
        }

        // MARK: - Public progress bridge

        /// Non-actor → actor bridge used by the URLSession download
        /// delegate and the Containerization SDK's `ProgressHandler` to
        /// push byte-level progress into the journey's active step.
        public func reportStepBytes(
            stepID: ProvisioningStepID,
            bytes: Int64,
            total: Int64,
            detail: String? = nil
        ) async {
            await applyByteProgress(stepID: stepID, bytes: bytes, total: total, detail: detail)
        }

        // MARK: - SDK ProgressHandler

        /// Build a `ProgressHandler` closure that folds the SDK's
        /// delta-based `ProgressEvent` stream into the journey's
        /// `stepID` step. The accumulator is captured by the closure so
        /// each per-call instance starts from zero (the SDK may call
        /// `addTotalSize` mid-stream as new layers are discovered).
        nonisolated static func makeContainerCreateProgressHandler(
            stepID: ProvisioningStepID
        ) -> ProgressHandler {
            let accumulator = ProgressAccumulator()
            return { events in
                let sums = accumulator.apply(events)
                let detail: String?
                if sums.totalItems > 0 {
                    detail = "Image layers: \(sums.items)/\(sums.totalItems)"
                } else if sums.items > 0 {
                    detail = "Image layers: \(sums.items)"
                } else {
                    detail = nil
                }
                await SandboxManager.shared.reportStepBytes(
                    stepID: stepID,
                    bytes: sums.bytes,
                    total: sums.totalBytes,
                    detail: detail
                )
            }
        }

        // MARK: - Post-start verify observer

        /// Spawn a background task that mirrors
        /// `SandboxPluginManager.installProgress` into the journey's
        /// `verifyPlugins` step. Idempotent — replaces any in-flight
        /// observer (e.g. from a previous boot that was cancelled).
        private func startPostStartVerifyObserver() {
            postStartVerifyTask?.cancel()
            postStartVerifyTask = Task { [weak self] in
                await self?.runPostStartVerifyObserver()
            }
        }

        /// Polling-based observer (250 ms cadence) that walks the live
        /// `installProgress` dictionary and surfaces the most-recent
        /// repair phase as the active activity line. Bounded by a hard
        /// deadline so we always release the journey even if a plugin
        /// repair gets wedged.
        ///
        /// We avoid `objectWillChange.sink` here because the actor-side
        /// observer would need a longer-lived Combine subscription
        /// that's harder to cancel cleanly across boots; a simple
        /// polling loop with a sentinel-empty-tick counter is plenty
        /// for the few-second window verify usually runs in.
        private func runPostStartVerifyObserver() async {
            let deadline = Date().addingTimeInterval(120)
            var sawActivity = false
            var stableEmptyTicks = 0

            while !Task.isCancelled, Date() < deadline {
                let snapshot: (hasWork: Bool, activity: String?) = await MainActor.run {
                    let progress = SandboxPluginManager.shared.installProgress
                    if let first = progress.values.first {
                        return (true, "\(first.pluginName) · \(first.phase)")
                    }
                    return (false, nil)
                }

                if snapshot.hasWork {
                    sawActivity = true
                    stableEmptyTicks = 0
                    await updateStep(.verifyPlugins) { step in
                        if step.status != .inProgress {
                            step.status = .inProgress
                            step.startedAt = step.startedAt ?? Date()
                            step.finishedAt = nil
                        }
                        step.detail = snapshot.activity
                    }
                    await setActivity(snapshot.activity)
                } else if sawActivity {
                    // Empty for a few ticks in a row after we saw work
                    // → verify pass has drained.
                    stableEmptyTicks += 1
                    if stableEmptyTicks >= 3 { break }
                } else {
                    // No sign of life — the verify pass either
                    // short-circuited (no plugins actually .ready) or
                    // hasn't started yet. Give it 2 seconds, then bail.
                    stableEmptyTicks += 1
                    if stableEmptyTicks >= 8 { break }
                }

                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            await endStep(.verifyPlugins, status: .completed)
            await setActivity(nil)
            await finishJourney(success: true)
        }

    }

    // MARK: - Cross-process VM ownership

    /// A process-lifetime advisory lock around the single vmnet-backed
    /// sandbox. The app and eval CLI can use different Osaurus data roots, so
    /// the lock lives in the per-user temporary directory. Owner metadata
    /// makes contention actionable before vmnet is touched.
    final class SandboxVMOwnershipLease: @unchecked Sendable {
        struct Owner: Sendable, Codable, Equatable {
            let pid: Int32
            let processName: String
            let executablePath: String?
            let acquiredAt: String
            /// Set by an owner that has started quitting, so a contender
            /// (typically the relaunched app) waits for it instead of failing.
            var quittingSince: String? = nil

            var diagnostic: String {
                var value = "PID \(pid) (\(processName))"
                if let executablePath, !executablePath.isEmpty {
                    value += " at \(executablePath)"
                }
                return value
            }
        }

        struct OwnershipConflict: Error, LocalizedError, Sendable, Equatable {
            let owner: Owner?

            var errorDescription: String? {
                if let owner {
                    return
                        "Sandbox VM is already owned by \(owner.diagnostic). "
                        + "Stop that Osaurus app or eval process before starting another vmnet sandbox."
                }
                return
                    "Sandbox VM is already owned by another process. "
                    + "Stop other Osaurus app or eval processes before starting vmnet."
            }
        }

        private let descriptor: Int32
        private let lock = NSLock()
        private var released = false

        static var defaultURL: URL {
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-sandbox-vmnet-\(getuid()).lock"
            )
        }

        static func acquire(at url: URL = defaultURL) throws -> SandboxVMOwnershipLease {
            // Close-on-exec: a child spawned while the VM runs (MCP server,
            // plugin host, shell tool) must not inherit the lock and keep
            // it held after this process exits.
            let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let owner = readOwner(at: url)
                Darwin.close(descriptor)
                throw OwnershipConflict(owner: owner)
            }

            let lease = SandboxVMOwnershipLease(descriptor: descriptor)
            do {
                try lease.publishCurrentOwner()
                return lease
            } catch {
                lease.release()
                throw error
            }
        }

        static func readOwner(at url: URL = defaultURL) -> Owner? {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            return try? JSONDecoder().decode(Owner.self, from: data)
        }

        /// Closed telemetry token for who holds a conflicting lease.
        enum OwnerState: String, CaseIterable, Sendable {
            /// This process: a lock fd leaked without `release()`.
            case current = "self"
            case osaurusAlive = "osaurus_alive"
            /// The lock file is open in a non-Osaurus process, e.g. a child
            /// that inherited the descriptor.
            case otherAlive = "other_alive"
            case ownerDeadLockHeld = "owner_dead_lock_held"
            case unknown
        }

        /// A process with the lease file open.
        struct Holder: Sendable, Equatable {
            let pid: Int32
            let path: String

            var isOsaurus: Bool {
                URL(fileURLWithPath: path).lastPathComponent.lowercased().contains("osaurus")
            }

            /// Local-only diagnostic; never sent.
            var diagnostic: String { "\(pid) \(path)" }
        }

        static func holders(of url: URL = defaultURL) -> [Holder] {
            var pids = [Int32](repeating: 0, count: 256)
            let bytes = pids.withUnsafeMutableBytes { buffer in
                proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, url.path, 0, buffer.baseAddress, Int32(buffer.count))
            }
            guard bytes > 0 else { return [] }
            return pids.prefix(Int(bytes) / MemoryLayout<Int32>.size).filter { $0 > 0 }.map { pid in
                var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                let length = proc_pidpath(pid, &path, UInt32(path.count))
                return Holder(pid: pid, path: length > 0 ? String(cString: path) : "")
            }
        }

        static func ownerState(
            owner: Owner?,
            holders: [Holder],
            currentPID: Int32 = getpid(),
            isProcessAlive: (Int32) -> Bool = defaultIsProcessAlive
        ) -> OwnerState {
            if owner?.pid == currentPID || holders.contains(where: { $0.pid == currentPID }) {
                return .current
            }
            if !holders.isEmpty {
                return holders.contains(where: \.isOsaurus) ? .osaurusAlive : .otherAlive
            }
            guard let owner else { return .unknown }
            return isProcessAlive(owner.pid) ? .osaurusAlive : .ownerDeadLockHeld
        }

        /// Classify the current holder of a conflicting lease.
        static func classifyConflict(at url: URL = defaultURL) -> (state: OwnerState, holders: [Holder]) {
            let holders = holders(of: url)
            return (ownerState(owner: readOwner(at: url), holders: holders), holders)
        }

        /// How long `acquire(waitingUpTo:)` is willing to wait for a live
        /// owner to exit. Sized for the app-update relaunch window: the
        /// outgoing process's quit chain gives `stopContainer` 3 s and the
        /// rest of its teardown a few more, and Sparkle can have the new
        /// binary running before the old one has closed its lock fd.
        static let defaultOwnerExitWait: TimeInterval = 8

        /// How long to wait for an owner that has marked itself quitting:
        /// its quit chain stops the VM within a few seconds, but a slow
        /// teardown (busy model unload, wedged audio) can stretch it.
        static let quittingOwnerExitWait: TimeInterval = 30

        /// Non-blocking probe: true when no process holds the lease.
        static func isAvailable(at url: URL = defaultURL) -> Bool {
            let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return errno == ENOENT }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
            _ = flock(descriptor, LOCK_UN)
            return true
        }

        /// Called at the start of app quit: mark this process's owner record
        /// as quitting. No-op when another process owns the lease.
        static func markCurrentOwnerQuitting(at url: URL = defaultURL) {
            guard var owner = readOwner(at: url), owner.pid == getpid() else { return }
            owner.quittingSince = ISO8601DateFormatter().string(from: Date())
            guard let data = try? JSONEncoder().encode(owner) else { return }
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }
            guard ftruncate(descriptor, 0) == 0 else { return }
            _ = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        }

        /// `kill(pid, 0)` liveness: `true` unless the kernel says no such
        /// process. EPERM means it exists but is not ours — still alive.
        static func defaultIsProcessAlive(_ pid: Int32) -> Bool {
            guard pid > 0 else { return false }
            if kill(pid, 0) == 0 { return true }
            return errno != ESRCH
        }

        /// Acquire, tolerating a previous owner that is on its way out.
        ///
        /// flock is released by the kernel the moment the owning process
        /// exits, so a conflict whose owner is *dead* resolves on the next
        /// attempt, and one whose owner is *alive* may resolve within a
        /// few seconds if that process is mid-quit (the typical
        /// update-relaunch race). Poll until `deadline` elapses, then
        /// surface the conflict with the owner diagnostic. An owner that is
        /// this very process (lock fd leaked without release) is never
        /// waited on — that is a bug to surface, not a race.
        static func acquire(
            at url: URL = defaultURL,
            waitingUpTo deadline: TimeInterval,
            pollInterval: TimeInterval = 0.25,
            isProcessAlive: (Int32) -> Bool = defaultIsProcessAlive
        ) async throws -> SandboxVMOwnershipLease {
            let start = Date()
            var attempts = 0
            while true {
                attempts += 1
                do {
                    let lease = try acquire(at: url)
                    if attempts > 1 {
                        let elapsed = Date().timeIntervalSince(start)
                        debugLog(
                            "[Sandbox] vmnet lease acquired after \(attempts) attempts / "
                                + String(format: "%.2fs", elapsed) + " (previous owner exited)"
                        )
                    }
                    return lease
                } catch let conflict as OwnershipConflict {
                    if let owner = conflict.owner, owner.pid == getpid() {
                        throw conflict
                    }
                    let elapsed = Date().timeIntervalSince(start)
                    let ownerQuitting = conflict.owner?.quittingSince != nil
                    guard elapsed < (ownerQuitting ? max(deadline, quittingOwnerExitWait) : deadline) else {
                        if attempts > 1 {
                            debugLog(
                                "[Sandbox] vmnet lease still held after \(attempts) attempts / \(Int(elapsed))s"
                            )
                        }
                        throw conflict
                    }
                    // A dead owner means the kernel has (or is about to have)
                    // dropped the lock — the recorded owner may simply be
                    // stale metadata from a process that just exited. Poll
                    // fast in that case; otherwise give a live owner time to
                    // finish quitting.
                    let ownerAlive = conflict.owner.map { isProcessAlive($0.pid) } ?? true
                    let sleep = ownerAlive ? pollInterval : min(pollInterval, 0.05)
                    try await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
                }
            }
        }

        private init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit {
            release()
        }

        func release() {
            lock.withLock {
                guard !released else { return }
                released = true
                _ = flock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            }
        }

        private func publishCurrentOwner() throws {
            let owner = Owner(
                pid: getpid(),
                processName: ProcessInfo.processInfo.processName,
                executablePath: Bundle.main.executableURL?.path,
                acquiredAt: ISO8601DateFormatter().string(from: Date())
            )
            let data = try JSONEncoder().encode(owner)
            guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress, bytes.count)
            }
            guard written == data.count else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            _ = fsync(descriptor)
        }
    }

    // MARK: - Errors

    public enum SandboxError: Error, LocalizedError {
        case unavailable
        case containerNotRunning
        case provisionFailed(String)
        /// A start failure rewritten with an actionable hint by
        /// `friendlyError`. `underlying` keeps the original SDK/POSIX error
        /// so telemetry can classify it (EEXIST vs EADDRINUSE vs GRPC) —
        /// the hint string alone would collapse them all.
        case startFailed(String, underlying: (any Error)? = nil)
        case stopFailed(String)
        case removeFailed(String)
        case userCreationFailed(String)
        case execFailed(String)
        case timeout
        /// Another Osaurus process owns the single vmnet-backed VM.
        case ownershipConflict(String)
        /// A downloaded artifact failed SHA-256 verification — fail-closed.
        /// Don't dress this up: if the kernel/initfs we just pulled doesn't
        /// match the expected digest, refuse to boot it.
        case integrityCheckFailed(String)
        /// Joining needs a VM restart, and these agents or workflows still
        /// have work running in it.
        case busy(holders: [String])

        public var errorDescription: String? {
            switch self {
            case .unavailable: L("Sandbox is not available on this system")
            case .containerNotRunning: "Container is not running"
            case .provisionFailed(let msg): "Provisioning failed: \(msg)"
            case .startFailed(let msg, _): "Container start failed: \(msg)"
            case .stopFailed(let msg): "Container stop failed: \(msg)"
            case .removeFailed(let msg): "Container removal failed: \(msg)"
            case .userCreationFailed(let msg): "User creation failed: \(msg)"
            case .execFailed(let msg): "Execution failed: \(msg)"
            case .timeout: "Command timed out"
            case .ownershipConflict(let msg): msg
            case .integrityCheckFailed(let msg): "Sandbox artifact integrity check failed: \(msg)"
            case .busy(let holders):
                L(
                    "The sandbox is busy: joining needs a restart, and work is still running for \(SandboxError.holderLabel(holders)). Try again when it finishes."
                )
            }
        }

        /// Readable names for pod members (`wf-<id>` is a workflow).
        static func holderLabel(_ holders: [String]) -> String {
            holders.map { name in
                if name.hasPrefix("wf-") { return L("a workflow") + " (\(name))" }
                return name
            }.joined(separator: ", ")
        }
    }

    // MARK: - Data Writer

    private protocol DataWriterReadable: AnyObject, Sendable {
        var data: Data { get }
        var string: String { get }
        var lastWriteTime: Date? { get }
        var truncated: Bool { get }
    }

    /// Collects data written from a container process's stdout/stderr into memory.
    /// Implements the Containerization `Writer` protocol.
    private final class DataWriter: Writer, DataWriterReadable, @unchecked Sendable {
        private let lock = NSLock()
        private var capture = ExecOutputCapture()
        private var _lastWriteTime: Date?

        func write(_ data: Data) throws {
            lock.withLock {
                capture.append(data)
                _lastWriteTime = Date()
            }
        }

        func close() throws {}

        var data: Data {
            lock.withLock { capture.buffer }
        }

        var string: String {
            lock.withLock { capture.string }
        }

        var lastWriteTime: Date? {
            lock.withLock { _lastWriteTime }
        }

        var truncated: Bool {
            lock.withLock { capture.truncated }
        }
    }

    // MARK: - Logging Data Writer

    /// Like DataWriter but also streams each complete line to SandboxLogBuffer
    /// in real-time. Uses a single lock scope per write and debounced MainActor
    /// dispatch to avoid flooding the main thread under high-throughput output.
    private final class LoggingDataWriter: Writer, DataWriterReadable, @unchecked Sendable {
        /// A run of output with no newline is logged in pieces this long.
        static let maxLineBytes = 64 * 1024

        private let lock = NSLock()
        private var capture = ExecOutputCapture()
        private var lineBuffer = Data()
        private var pendingLines: [String] = []
        private var flushScheduled = false
        private var _lastWriteTime: Date?
        private let source: String
        private let level: SandboxLogBuffer.Entry.Level
        private let secrets = SandboxLogScrubbing.secrets

        init(source: String, level: SandboxLogBuffer.Entry.Level) {
            self.source = source
            self.level = level
        }

        func write(_ data: Data) throws {
            let shouldSchedule: Bool = lock.withLock {
                capture.append(data)
                _lastWriteTime = Date()
                lineBuffer.append(data)
                extractLines()
                guard !pendingLines.isEmpty, !flushScheduled else { return false }
                flushScheduled = true
                return true
            }
            if shouldSchedule {
                dispatchFlush()
            }
        }

        func close() throws {
            let lines = lock.withLock {
                if !lineBuffer.isEmpty,
                    let s = String(data: lineBuffer, encoding: .utf8),
                    !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    pendingLines.append(SecretScrubber.scrub(s, secrets: secrets))
                }
                lineBuffer.removeAll()
                return drainPendingLines()
            }
            sendToLogBuffer(lines)
        }

        var data: Data { lock.withLock { capture.buffer } }

        var string: String { lock.withLock { capture.string } }

        var lastWriteTime: Date? { lock.withLock { _lastWriteTime } }

        var truncated: Bool { lock.withLock { capture.truncated } }

        // MARK: Private

        /// Split lineBuffer on newlines, appending complete lines to pendingLines.
        /// Must be called inside the lock.
        private func extractLines() {
            let newline = UInt8(ascii: "\n")
            var start = lineBuffer.startIndex
            for i in lineBuffer.indices where lineBuffer[i] == newline {
                if i > start,
                    let line = String(data: lineBuffer[start ..< i], encoding: .utf8)
                {
                    pendingLines.append(SecretScrubber.scrub(line, secrets: secrets))
                }
                start = lineBuffer.index(after: i)
            }
            if start > lineBuffer.startIndex {
                lineBuffer = Data(lineBuffer[start...])
            }
            if lineBuffer.count > Self.maxLineBytes {
                let piece = String(decoding: lineBuffer, as: UTF8.self)
                pendingLines.append(SecretScrubber.scrub(piece, secrets: secrets))
                lineBuffer.removeAll(keepingCapacity: true)
            }
        }

        /// Move all pendingLines out and reset the flush flag. Must be called inside the lock.
        private func drainPendingLines() -> [String] {
            let result = pendingLines
            pendingLines.removeAll(keepingCapacity: true)
            flushScheduled = false
            return result
        }

        private func dispatchFlush() {
            let src = source
            let lvl = level
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                let lines = self.lock.withLock { self.drainPendingLines() }
                guard !lines.isEmpty else { return }
                SandboxLogBuffer.shared.appendBatch(lines.map { (lvl, $0, src) })
            }
        }

        private func sendToLogBuffer(_ lines: [String]) {
            guard !lines.isEmpty else { return }
            let src = source
            let lvl = level
            Task { @MainActor in
                SandboxLogBuffer.shared.appendBatch(lines.map { (lvl, $0, src) })
            }
        }
    }

    // MARK: - SDK Progress Accumulator

    /// Folds the Containerization SDK's delta-based `ProgressEvent`
    /// stream into running totals. Used by the closure built in
    /// `SandboxManager.makeContainerCreateProgressHandler`; each
    /// `ProgressHandler` invocation gets its own accumulator so totals
    /// reset between provision attempts.
    ///
    /// `@unchecked Sendable` because the lock guards every access;
    /// callers (the SDK) hop tasks freely so we can't rely on actor
    /// isolation for the closure body.
    private final class ProgressAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64 = 0
        private var totalBytes: Int64 = 0
        private var items: Int = 0
        private var totalItems: Int = 0

        func apply(_ events: [ProgressEvent]) -> (bytes: Int64, totalBytes: Int64, items: Int, totalItems: Int) {
            lock.lock()
            defer { lock.unlock() }
            for event in events {
                switch event {
                case .addSize(let v): bytes += v
                case .addTotalSize(let v): totalBytes += v
                case .addItems(let v): items += v
                case .addTotalItems(let v): totalItems += v
                }
            }
            return (bytes, totalBytes, items, totalItems)
        }
    }

#endif
