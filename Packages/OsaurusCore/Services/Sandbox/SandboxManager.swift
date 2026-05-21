//
//  SandboxManager.swift
//  osaurus
//
//  Manages the shared Linux container lifecycle via apple/containerization.
//  Uses Virtualization.framework directly -- no CLI, no XPC daemon.
//  All container operations are serialized through this actor.
//
//  Networking: VmnetNetwork (vmnet-backed NAT) for outbound internet,
//  vsock Unix socket relay for the host API bridge.
//

#if os(macOS)

    import Containerization
    import ContainerizationExtras
    import CryptoKit
    import Foundation

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

        /// Expected SHA-256 of the Kata kernel tarball. Verified after
        /// download, mismatch is fail-closed (the file is deleted and
        /// provisioning aborts). Update alongside `kernelDownloadURLs` when
        /// bumping the Kata version.
        private static let kernelDownloadURLs: [DownloadSource] = [
            DownloadSource(
                url:
                    "https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz",
                expectedSHA256: "647c7612e6edf789d5e14698c48c99d8bac15ad139ffaa1c8bb7d229f748d181"
            )
        ]

        /// Expected SHA-256 of the initfs blob. Verified after download.
        /// The blob lives on R2 (mutable bucket) so digest verification is
        /// the only thing standing between a CDN compromise and an
        /// attacker-chosen guest filesystem. Update this constant when the
        /// blob is intentionally rotated.
        private static let initfsDownloadURLs: [DownloadSource] = [
            // "https://github.com/osaurus-ai/osaurus/releases/latest/download/init.ext4"
            DownloadSource(
                url: "https://pub-5f3c2bf70e93411790bbcd6419d2f8fa.r2.dev/init.ext4",
                expectedSHA256: "fa08b6993e3682d88bfb964e02bdf4ca234df616bac047f24cec6a4548a42aea"
            )
        ]

        /// Bound the cost of hashing — well above either current artifact
        /// (Kata tarball ~30 MB, initfs ~100 MB) but stops a runaway
        /// download from silently growing into a multi-GB hash job.
        private static let maxArtifactDownloadBytes: Int = 512 * 1024 * 1024

        /// Host-side Unix socket path for the bridge server (relayed into guest via vsock)
        private static var bridgeSocketPath: String {
            OsaurusPaths.container().appendingPathComponent("bridge.sock").path
        }
        /// Where the bridge socket appears inside the guest container
        private static let guestBridgeSocketPath = "/tmp/osaurus-bridge.sock"

        /// In-guest directory holding per-agent bridge auth tokens.
        /// Each file is `<linuxName>.token`, mode 0600, owned by that user.
        /// The directory itself is mode 0711 so users can open their own
        /// file by known name without enumerating siblings.
        fileprivate static let bridgeTokenDir = "/run/osaurus"

        private var _status: ContainerStatus = .notProvisioned
        private var _availability: SandboxAvailability?
        private var containerManager: ContainerManager?
        private var linuxContainer: LinuxContainer?
        private var _removedByUser = false

        /// Coalesces concurrent `startContainer()` calls. Without this,
        /// AppDelegate's auto-start, `SandboxToolRegistrar.start`,
        /// `SandboxAgentProvisioner.ensureProvisioned`, and the Sandbox
        /// settings panel's "Start" button can all fire near-simultaneously
        /// at launch and queue several full provision attempts (each one
        /// thrashing vmnet / the bridge socket). With coalescing, the first
        /// caller drives a single attempt and every other caller awaits the
        /// same task.
        private var inFlightStartTask: Task<Void, Error>?

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
            /// Mirror of `SandboxToolRegistrar.unavailabilityReason(for:)`
            /// for the currently active agent. Lets SwiftUI views (e.g. the
            /// sandbox chip) observe failures without coupling to the
            /// registrar singleton's internal `[UUID: …]` map. `nil` means
            /// "no failure recorded for the active agent".
            @Published public var activeAgentUnavailability: SandboxToolRegistrar.UnavailabilityReason?

            private static var initialAvailability: SandboxAvailability {
                let osVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
                return osVersion >= 26
                    ? .available
                    : .unavailable(reason: "Requires macOS 26 or later")
            }
        }

        // MARK: - Availability

        public func checkAvailability() async -> SandboxAvailability {
            if let cached = _availability { return cached }
            return await refreshAvailability()
        }

        public func refreshAvailability() async -> SandboxAvailability {
            _availability = nil

            let osVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            guard osVersion >= 26 else {
                let result = SandboxAvailability.unavailable(reason: "Requires macOS 26 or later")
                _availability = result
                await MainActor.run { State.shared.availability = result }
                return result
            }

            let result = SandboxAvailability.available
            _availability = result
            await MainActor.run { State.shared.availability = result }
            return result
        }

        // MARK: - Container Status

        public func status() -> ContainerStatus {
            return _status
        }

        var staleContainerDir: URL {
            OsaurusPaths.container().appendingPathComponent("containers/\(Self.containerID)")
        }

        private var hasRequiredAssets: Bool {
            let fm = FileManager.default
            return fm.fileExists(atPath: OsaurusPaths.containerKernelFile().path)
                && fm.fileExists(atPath: OsaurusPaths.containerInitFSFile().path)
        }

        public func refreshStatus() async -> ContainerStatus {
            if linuxContainer != nil {
                _status = .running
            } else if FileManager.default.fileExists(atPath: staleContainerDir.path) {
                // Auto-clean stale container state from a previous session.
                // forciblyRemove walks the tree so a stuck FUSE mount or
                // locked socket file from a crashed run can't keep the
                // directory around to confuse `manager.create` later.
                // Runs off-actor so a slow tree walk doesn't pin the
                // executor for every other queued sandbox call.
                debugLog("[Sandbox] Cleaning up stale container state from previous session")
                try? await Self.forciblyRemoveAsync(at: staleContainerDir)
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

        public func provision() async throws {
            guard _availability?.isAvailable == true else {
                throw SandboxError.unavailable
            }
            _removedByUser = false

            let config = SandboxConfigurationStore.load()
            let isRestart = hasRequiredAssets
            let hasPlugins = await Self.installedPluginsRequireVerify()

            // Begin a fresh journey. On warm restart the kernel / initfs
            // / extract steps are pre-marked `.skipped` so the UI shows
            // checkmarks immediately rather than misleading spinners.
            let planned = plannedSteps(isRestart: isRestart, hasPlugins: hasPlugins)
            await beginJourney(steps: planned)

            do {
                // Download (or load) the kernel + initfs concurrently. Both
                // functions short-circuit on `fileExists`, so the warm path
                // pays only two stat()s before falling through. The cold
                // path runs both URLSession downloads in parallel: each
                // `await session.download(...)` suspends the actor, which
                // lets the other task make progress at the same time.
                // `ensureKernel` / `ensureInitFS` drive the journey
                // themselves (start → end) so the UI shows accurate per-
                // file progress on the cold path.
                async let kernelFuture = ensureKernel()
                async let initfsFuture = ensureInitFS()
                let (kernel, initfs) = try await (kernelFuture, initfsFuture)

                try ensureHostDirectories()

                // Clean up stale container state from a previous crash.
                // Use `try` (not `try?`) so a real cleanup failure surfaces
                // here as a clear error instead of bubbling up later as the
                // misleading "file already exists" from `manager.create`.
                if FileManager.default.fileExists(atPath: staleContainerDir.path) {
                    debugLog("[Sandbox] Cleaning up stale container state")
                    try await Self.forciblyRemoveAsync(at: staleContainerDir)
                }

                if #available(macOS 26, *) {
                    // Kick off the NIO bridge bootstrap concurrently with
                    // VmnetNetwork + ContainerManager setup and the rootfs
                    // image pull/unpack. Both paths are independent — the
                    // bridge only needs to be listening before
                    // `container.start()` because that's when the guest
                    // tries to attach the relayed socket. Awaiting it
                    // there (instead of immediately after `start()`) lets
                    // the slower of the two (usually the image work) hide
                    // the bridge cost entirely.
                    await startStep(.startBridge, detail: "Binding host socket")
                    async let bridgeStarted: Void = HostAPIBridgeServer.shared.start(
                        socketPath: Self.bridgeSocketPath
                    )

                    let network = try VmnetNetwork()
                    var manager = try ContainerManager(
                        kernel: kernel,
                        initfs: initfs,
                        root: OsaurusPaths.container(),
                        network: network
                    )

                    let workspace = OsaurusPaths.containerWorkspace().path
                    let bridgeSocketPath = Self.bridgeSocketPath
                    let guestBridgeSocketPath = Self.guestBridgeSocketPath

                    await startStep(
                        .createContainer,
                        detail: isRestart ? "Loading cached image" : "Pulling image layers"
                    )
                    // Fold the SDK's `ProgressEvent` stream into our
                    // active createContainer step. The SDK fires items
                    // *and* sizes; size-based progress is the most
                    // user-meaningful so we drive the journey off that
                    // and use the items totals only to enrich the
                    // activity subtitle.
                    let progressTracker = Self.makeContainerCreateProgressHandler(stepID: .createContainer)
                    let container: LinuxContainer
                    do {
                        container = try await manager.create(
                            Self.containerID,
                            reference: Self.containerImage,
                            rootfsSizeInBytes: 8.gib(),
                            networking: true,
                            progress: progressTracker
                        ) { cfg in
                            cfg.cpus = config.cpus
                            cfg.memoryInBytes = UInt64(config.memoryGB).gib()
                            cfg.process.arguments = ["sleep", "infinity"]
                            cfg.process.workingDirectory = "/"

                            let bridgeRelay = UnixSocketConfiguration(
                                source: URL(fileURLWithPath: bridgeSocketPath),
                                destination: URL(fileURLWithPath: guestBridgeSocketPath),
                                direction: .into
                            )
                            cfg.sockets = [bridgeRelay]
                            cfg.mounts.append(.share(source: workspace, destination: "/workspace"))
                        }
                    } catch {
                        await endStep(.createContainer, status: .failed)
                        // Don't leave an orphaned bridge listening if the
                        // container create fails — `cleanupAfterFailure`
                        // will also stop it, but completing the structured
                        // task locally keeps the actor's state coherent.
                        _ = try? await bridgeStarted
                        await endStep(.startBridge, status: .failed)
                        throw error
                    }
                    await endStep(.createContainer, status: .completed)

                    // Assign to self IMMEDIATELY so cleanupAfterFailure() can
                    // see and tear down the SDK objects if container.create()
                    // or container.start() throws below. Previously these
                    // fields were only set after a successful start, so a
                    // partial-provision failure left the container registered
                    // inside the SDK and on disk — the source of subsequent
                    // "file already exists" errors on the next attempt.
                    self.containerManager = manager
                    self.linuxContainer = container

                    await startStep(.startContainer, detail: "Booting Linux VM")
                    try await container.create()
                    // Guarantee the bridge is bound before the VM tries to
                    // attach the relayed socket. In the common case the
                    // bridge was already up before `manager.create` returned.
                    try await bridgeStarted
                    await endStep(.startBridge, status: .completed)
                    try await container.start()
                    await endStep(.startContainer, status: .completed)
                }

                await startStep(.configureSandbox, detail: "Installing in-guest shim")
                try await configureSandbox()
                await endStep(.configureSandbox, status: .completed)

                _status = .running
                syncStatus()

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
                if configChanged {
                    SandboxConfigurationStore.save(savedConfig)
                }

                // Bring the dashboard back immediately. When plugins
                // need verifying we keep the journey alive (the
                // verifyPlugins step is `.inProgress`) so the post-start
                // tasks card can render it; the legacy `isProvisioning`
                // flag is still flipped to `false` via
                // `concludeProvisioningPhase` so the fullscreen progress
                // view drops out and the dashboard takes over.
                if hasPlugins {
                    await startStep(.verifyPlugins, detail: "Restoring plugin dependencies")
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
            guard _availability?.isAvailable == true else {
                throw SandboxError.unavailable
            }
            guard !_removedByUser else { return }

            switch await refreshStatus() {
            case .running, .starting:
                return
            case .error:
                // Recover from a prior failed attempt by tearing down any
                // SDK / on-disk state before re-provisioning.
                await cleanupAfterFailure()
                fallthrough
            case .stopped, .notProvisioned:
                _status = .starting
                syncStatus()
                do {
                    try await provision()
                } catch {
                    _status = .stopped
                    syncStatus()
                    throw Self.friendlyError(from: error)
                }
            }
        }

        public func stopContainer() async throws {
            if let container = linuxContainer {
                try await container.stop()
            }
            if var manager = containerManager {
                try? manager.delete(Self.containerID)
            }
            linuxContainer = nil
            containerManager = nil
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
            // Drop any in-memory bridge tokens — the next container start
            // mints fresh ones. Leaving stale tokens in memory could falsely
            // authenticate a request to a guest that no longer exists.
            await SandboxBridgeTokenStore.shared.revokeAll()
            _status = .stopped
            syncStatus()
            // Drop the cached metrics so the UI doesn't keep showing
            // stale CPU/memory/uptime numbers for a container that's no
            // longer running.
            await MainActor.run { State.shared.containerInfo = nil }
        }

        public func removeContainer() async throws {
            try await stopContainer()

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

            _status = .notProvisioned
            _removedByUser = true
            syncStatus()
            await MainActor.run { Self.resetProvisioningState() }

            var config = SandboxConfigurationStore.load()
            config.setupComplete = false
            SandboxConfigurationStore.save(config)

            if !warnings.isEmpty {
                throw SandboxError.removeFailed(warnings.joined(separator: "; "))
            }
        }

        public func resetContainer() async throws {
            try await removeContainer()
            try await provision()
        }

        // MARK: - Exec

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
            onProcessStarted: (@Sendable (ProcessHandle) -> Void)? = nil
        ) async throws -> ContainerExecResult {
            guard linuxContainer != nil else {
                throw SandboxError.containerNotRunning
            }

            let shellCommand = cwd.map { "cd \($0) && \(command)" } ?? command
            let args: [String]
            if let user {
                args = ["su", "-s", "/bin/bash", user, "-c", shellCommand]
            } else {
                args = ["sh", "-c", shellCommand]
            }

            return try await execViaAgent(
                args: args,
                env: env,
                timeout: timeout,
                streamToLogs: streamToLogs,
                logSource: logSource,
                stdoutTee: stdoutTee,
                stderrTee: stderrTee,
                onProcessStarted: onProcessStarted
            )
        }

        public func execAsRoot(
            command: String,
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
                onProcessStarted: onProcessStarted
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
            stderr: any Writer
        ) async throws -> LinuxProcess {
            guard let container = linuxContainer else {
                throw SandboxError.containerNotRunning
            }

            let shellCommand = cwd.map { "cd \($0) && \(command)" } ?? command
            let args: [String]
            if let user {
                args = ["su", "-s", "/bin/bash", user, "-c", shellCommand]
            } else {
                args = ["sh", "-c", shellCommand]
            }

            var mergedEnv = env
            if mergedEnv["PATH"] == nil {
                mergedEnv["PATH"] = LinuxProcessConfiguration.defaultPath
            }
            let environ = mergedEnv.map { "\($0.key)=\($0.value)" }

            let process = try await container.exec(UUID().uuidString) { config in
                config.arguments = args
                config.environmentVariables = environ
                config.stdin = stdin
                config.stdout = stdout
                config.stderr = stderr
            }
            try await process.start()
            return process
        }

        // MARK: - Agent User Management

        public func ensureAgentUser(_ agentName: String) async throws {
            let checkResult = try await exec(command: "id agent-\(agentName) 2>/dev/null")
            if checkResult.succeeded { return }

            let homeDir = OsaurusPaths.inContainerAgentHome(agentName)
            let addResult = try await execAsRoot(command: "adduser -D -h \(homeDir) agent-\(agentName)")
            guard addResult.succeeded else {
                throw SandboxError.userCreationFailed(addResult.stderr)
            }

            let chmodResult = try await execAsRoot(command: "chmod 700 \(homeDir)")
            guard chmodResult.succeeded else {
                throw SandboxError.userCreationFailed("chmod failed: \(chmodResult.stderr)")
            }

            let pluginsDir = "\(homeDir)/plugins"
            _ = try await exec(
                user: "agent-\(agentName)",
                command: "mkdir -p \(pluginsDir)"
            )
        }

        public func removeAgentUser(_ agentName: String) async throws -> Bool {
            let linuxUser = "agent-\(agentName)"
            let checkResult = try await exec(command: "id \(linuxUser) 2>/dev/null")
            guard checkResult.succeeded else { return false }

            // Drop the per-agent bridge token before removing the user so
            // any in-flight bridge calls from this agent fail closed.
            await SandboxBridgeTokenStore.shared.revoke(linuxName: linuxUser)
            _ = try? await execAsRoot(
                command: "rm -f \(Self.bridgeTokenDir)/\(linuxUser).token"
            )

            let homeDir = OsaurusPaths.inContainerAgentHome(agentName)
            let removeResult = try await execAsRoot(
                command:
                    "pkill -u \(linuxUser) >/dev/null 2>&1 || true; deluser \(linuxUser) >/dev/null 2>&1 || true; rm -rf '\(homeDir)'"
            )
            guard removeResult.succeeded else {
                throw SandboxError.removeFailed(
                    removeResult.stderr.isEmpty
                        ? "Failed to remove \(linuxUser)"
                        : removeResult.stderr
                )
            }

            let verifyResult = try await exec(command: "id \(linuxUser) 2>/dev/null")
            guard !verifyResult.succeeded else {
                throw SandboxError.removeFailed("User \(linuxUser) still exists after cleanup")
            }

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
            guard linuxContainer != nil else { return }

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
            let result = try await execAsRoot(command: script)
            guard result.succeeded else {
                throw SandboxError.provisionFailed(
                    "Failed to write bridge token for \(linuxName): \(result.stderr)"
                )
            }
        }

        /// Drop in-memory and on-disk traces of the bridge token for `linuxName`.
        public func revokeBridgeToken(linuxName: String) async {
            await SandboxBridgeTokenStore.shared.revoke(linuxName: linuxName)
            if linuxContainer != nil {
                _ = try? await execAsRoot(
                    command: "rm -f \(Self.bridgeTokenDir)/\(linuxName).token"
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
            // container (e.g. linuxContainer became nil).
            let currentStatus: ContainerStatus
            if _status == .running && linuxContainer != nil {
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

            return await collectRunningContainerInfo(status: currentStatus)
        }

        /// Single round-trip metric collection for the running container.
        /// Previously this method issued six sequential `exec` calls, each
        /// paying the full vsock + agent round-trip cost. The settings
        /// dashboard refreshes every 5 s while the user is on the Sandbox
        /// tab, so the cumulative cost was meaningful. We now emit one
        /// `KEY=value` blob and parse on the host.
        ///
        /// Output contract (one line per field, terminated by `\n`):
        /// ```
        /// USERS=agent-a,agent-b
        /// DISK=4.0K
        /// UPTIME=123 seconds
        /// MEM=128MB / 512MB
        /// CPU=0.10 0.05 0.01
        /// PROCS=42
        /// ```
        /// Any individual field may be absent or empty if its underlying
        /// /proc / awk pipeline failed — the host treats missing fields as
        /// `nil`, exactly like the prior per-call try-fail semantics.
        private func collectRunningContainerInfo(status: ContainerStatus) async -> ContainerInfo {
            let script = """
                printf 'USERS=%s\\n' "$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd 2>/dev/null | paste -sd, -)"
                printf 'DISK=%s\\n' "$(du -sh /workspace 2>/dev/null | cut -f1)"
                printf 'UPTIME=%s\\n' "$(awk '{printf "%.0f seconds", $1}' /proc/uptime 2>/dev/null)"
                printf 'MEM=%s\\n' "$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{if (t>0) printf "%dMB / %dMB", (t-a)/1024, t/1024}' /proc/meminfo 2>/dev/null)"
                printf 'CPU=%s\\n' "$(awk '{printf "%s %s %s", $1, $2, $3}' /proc/loadavg 2>/dev/null)"
                printf 'PROCS=%s\\n' "$(ls -1 /proc 2>/dev/null | grep -c '^[0-9]')"
                """

            var users: [String] = []
            var disk: String? = nil
            var uptime: String? = nil
            var memoryUsage: String? = nil
            var cpuLoad: String? = nil
            var processCount: Int? = nil

            if let result = try? await exec(command: script, timeout: 5) {
                for rawLine in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = String(rawLine)
                    guard let eq = line.firstIndex(of: "=") else { continue }
                    let key = String(line[..<eq])
                    let value = String(line[line.index(after: eq)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if value.isEmpty { continue }
                    switch key {
                    case "USERS":
                        users = value.split(separator: ",").map(String.init)
                    case "DISK":
                        disk = value
                    case "UPTIME":
                        uptime = value
                    case "MEM":
                        memoryUsage = value
                    case "CPU":
                        cpuLoad = value
                    case "PROCS":
                        processCount = Int(value)
                    default:
                        continue
                    }
                }
            }

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

        /// Run a suite of checks to verify exec, NAT networking, agent users, and the vsock bridge.
        ///
        /// All five checks are independent (the agent-user check creates its
        /// own `agent-diag` user but doesn't conflict with the others), so
        /// they run concurrently. Each `exec` suspends the actor while the
        /// guest works, which lets the other tasks make progress at the same
        /// time. Wall time drops from sum-of-checks to max-of-checks; the
        /// returned array preserves the original UI ordering.
        public func runDiagnostics() async -> [DiagnosticResult] {
            async let execD = diagnose("exec") {
                let r = try await self.exec(command: "echo hello from sandbox")
                let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard out == "hello from sandbox" else {
                    throw SandboxError.execFailed("expected 'hello from sandbox', got '\(out)'")
                }
                return out
            }

            async let natD = diagnose("nat-networking") {
                let r = try await self.exec(
                    command: "wget -qO- http://example.com 2>/dev/null | head -5",
                    timeout: 15
                )
                let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !out.isEmpty else {
                    throw SandboxError.execFailed("empty response (stderr: \(r.stderr))")
                }
                return String(out.prefix(80))
            }

            async let userD = diagnose("agent-user") {
                try await self.ensureAgentUser("diag")
                let r = try await self.exec(user: "agent-diag", command: "whoami")
                let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard out == "agent-diag" else {
                    throw SandboxError.execFailed("expected 'agent-diag', got '\(out)'")
                }
                return out
            }

            async let apkD = diagnose("apk-install") {
                _ = await self.awaitNetworkReady()
                let r = try await self.execAsRoot(command: "apk add --no-cache jq 2>&1", timeout: 60)
                guard r.succeeded else {
                    throw SandboxError.execFailed(r.stderr)
                }
                return "exit \(r.exitCode)"
            }

            async let vsockD = diagnose("vsock-bridge") {
                let r = try await self.exec(
                    command: "curl -sf --unix-socket /tmp/osaurus-bridge.sock http://localhost/api/log "
                        + "-X POST -d '{\"level\":\"info\",\"message\":\"diag ping\"}'"
                )
                guard r.succeeded else {
                    throw SandboxError.execFailed("exit \(r.exitCode): \(r.stderr)")
                }
                return "bridge responded OK"
            }

            let results: [DiagnosticResult] = await [execD, natD, userD, apkD, vsockD]

            return results
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

        // MARK: - Private: InitFS Management

        private func ensureInitFS() async throws -> Containerization.Mount {
            let stagedPath = OsaurusPaths.containerInitFSFile()

            if !FileManager.default.fileExists(atPath: stagedPath.path) {
                await startStep(.downloadInitFS, detail: "Resolving CDN mirror")
                try OsaurusPaths.ensureExists(OsaurusPaths.container())
                do {
                    try await downloadFile(
                        from: Self.initfsDownloadURLs,
                        to: stagedPath,
                        stepID: .downloadInitFS
                    )
                } catch {
                    await endStep(.downloadInitFS, status: .failed)
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

        // MARK: - Private: Kernel Management

        private func ensureKernel() async throws -> Kernel {
            let kernelPath = OsaurusPaths.containerKernelFile()

            if FileManager.default.fileExists(atPath: kernelPath.path) {
                return Kernel(path: kernelPath, platform: .linuxArm)
            }

            await startStep(.downloadKernel, detail: "Resolving GitHub mirror")

            let kernelDir = OsaurusPaths.containerKernelDir()
            try OsaurusPaths.ensureExists(kernelDir)

            let stableTarball = kernelDir.appendingPathComponent("kata.tar.xz")
            do {
                try await downloadFile(
                    from: Self.kernelDownloadURLs,
                    to: stableTarball,
                    stepID: .downloadKernel
                )
            } catch {
                await endStep(.downloadKernel, status: .failed)
                throw error
            }
            await endStep(.downloadKernel, status: .completed)
            defer { try? FileManager.default.removeItem(at: stableTarball) }

            await startStep(.extractKernel, detail: "Untarring archive")

            // Hand the sync `tar` + `find` + `copyItem` work to a detached
            // task so `Process.waitUntilExit()` doesn't pin the actor's
            // executor while extraction runs (tens to hundreds of ms on
            // fast disks, longer on slow ones). The actor is then free to
            // service queued calls — e.g. the SandboxView's polling
            // `info()` or a concurrent `ensureInitFS()` finishing up.
            do {
                try await Self.extractKernel(
                    from: stableTarball,
                    installTo: kernelPath
                )
            } catch {
                await endStep(.extractKernel, status: .failed)
                throw error
            }
            await endStep(.extractKernel, status: .completed)

            debugLog("[Sandbox] Kernel installed at \(kernelPath.path)")
            return Kernel(path: kernelPath, platform: .linuxArm)
        }

        /// Sync extraction of a Kata tarball into `installTo`. Runs as a
        /// `static nonisolated` helper invoked from a detached task so the
        /// `Process.waitUntilExit()` calls don't block the actor executor.
        private static func extractKernel(from tarball: URL, installTo kernelPath: URL) async throws {
            try await Task.detached(priority: .userInitiated) {
                let extractDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "osaurus-kernel-\(UUID().uuidString)"
                )
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: extractDir) }

                let tarProcess = Process()
                tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tarProcess.arguments = [
                    "-xf", tarball.path, "-C", extractDir.path, "--strip-components=1",
                ]
                let tarStderr = Pipe()
                tarProcess.standardOutput = FileHandle.nullDevice
                tarProcess.standardError = tarStderr
                try tarProcess.run()
                tarProcess.waitUntilExit()

                let tarErrOutput =
                    String(data: tarStderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog(
                    "[SandboxManager] tar exit: \(tarProcess.terminationStatus), stderr: \(tarErrOutput.prefix(200))"
                )

                // vmlinux.container is a symlink → vmlinux-X.Y.Z-N in the Kata tarball.
                // Resolve it by copying (which follows symlinks) rather than moving.
                let expectedPath =
                    extractDir
                    .appendingPathComponent("opt/kata/share/kata-containers/vmlinux.container")

                let extractedKernel: URL
                if FileManager.default.fileExists(atPath: expectedPath.path) {
                    extractedKernel = expectedPath
                } else {
                    let findProcess = Process()
                    findProcess.executableURL = URL(fileURLWithPath: "/usr/bin/find")
                    findProcess.arguments = [
                        extractDir.path, "-name", "vmlinux*", "!", "-name", "vmlinuz*", "!", "-name", "*.container",
                    ]
                    let findPipe = Pipe()
                    findProcess.standardOutput = findPipe
                    findProcess.standardError = FileHandle.nullDevice
                    try findProcess.run()
                    findProcess.waitUntilExit()

                    let findOutput =
                        String(data: findPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let foundPaths = findOutput.split(separator: "\n").map(String.init)

                    guard let firstPath = foundPaths.first, !firstPath.isEmpty else {
                        throw SandboxError.provisionFailed("No vmlinux kernel found in Kata tarball")
                    }
                    extractedKernel = URL(fileURLWithPath: firstPath)
                }

                let resolvedKernel = extractedKernel.resolvingSymlinksInPath()
                try? FileManager.default.removeItem(at: kernelPath)
                try FileManager.default.copyItem(at: resolvedKernel, to: kernelPath)
            }.value
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
        /// `stepID` is the journey step the byte counters should attach
        /// to. Passing `nil` keeps backward-compatible behaviour for any
        /// caller that doesn't care about the structured progress
        /// surface (none in production today; tests only).
        private func downloadFile(
            from sources: [DownloadSource],
            to destination: URL,
            stepID: ProvisioningStepID? = nil
        ) async throws {
            let delegate = DownloadProgressDelegate { bytes, total in
                if let stepID {
                    Task { await SandboxManager.shared.reportStepBytes(stepID: stepID, bytes: bytes, total: total) }
                } else if total > 0 {
                    Task { @MainActor in
                        State.shared.provisioningProgress = min(Double(bytes) / Double(total), 1.0)
                    }
                }
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }

            var lastError: Error?
            for source in sources {
                guard let url = URL(string: source.url) else { continue }
                do {
                    debugLog("[Sandbox] Downloading from \(source.url)...")
                    let (tempURL, response) = try await session.download(from: url)
                    guard let httpResponse = response as? HTTPURLResponse,
                        (200 ... 299).contains(httpResponse.statusCode)
                    else {
                        NSLog(
                            "[SandboxManager] HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) from \(source.url)"
                        )
                        // Drop the temp file so we don't leak it into /tmp.
                        try? FileManager.default.removeItem(at: tempURL)
                        continue
                    }

                    // Verify integrity *before* installing. If the digest
                    // doesn't match, the temp file is removed and we never
                    // touch the destination. Run the chunked SHA-256 in a
                    // detached task so the hash of a ~100 MiB initfs doesn't
                    // block the actor's executor for its entire duration —
                    // other queued sandbox calls keep flowing in parallel.
                    do {
                        try await Self.verifySHA256Async(
                            of: tempURL,
                            expected: source.expectedSHA256,
                            maxBytes: Self.maxArtifactDownloadBytes
                        )
                    } catch {
                        try? FileManager.default.removeItem(at: tempURL)
                        // Don't try other mirrors on integrity failure —
                        // a real upstream compromise affects all of them
                        // and silent fallback would hide it.
                        throw error
                    }

                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    debugLog("[Sandbox] Downloaded + verified to \(destination.path)")
                    return
                } catch let err as SandboxError {
                    // Fail-closed on integrity errors.
                    throw err
                } catch {
                    lastError = error
                    debugLog("[Sandbox] Download failed from \(source.url): \(error)")
                }
            }

            throw SandboxError.provisionFailed(
                "Download failed: \(lastError?.localizedDescription ?? "all URLs failed")"
            )
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

            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == normalized else {
                throw SandboxError.integrityCheckFailed(
                    "SHA-256 mismatch: expected \(normalized), got \(actual)"
                )
            }
        }

        // MARK: - Private: Exec via VM Agent

        private func execViaAgent(
            args: [String],
            env: [String: String],
            timeout: TimeInterval?,
            streamToLogs: Bool = false,
            logSource: String? = nil,
            stdoutTee: (any Writer)? = nil,
            stderrTee: (any Writer)? = nil,
            onProcessStarted: (@Sendable (ProcessHandle) -> Void)? = nil
        ) async throws -> ContainerExecResult {
            guard let container = linuxContainer else {
                throw SandboxError.containerNotRunning
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
            let process = try await container.exec(UUID().uuidString) { config in
                config.arguments = args
                config.environmentVariables = environ
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
                    try await process.kill(signal)
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
                    exitCode: exitStatus.exitCode
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

        // MARK: - Helpers

        func cleanupAfterFailure() async {
            if let container = linuxContainer { try? await container.stop() }
            if var mgr = containerManager { try? mgr.delete(Self.containerID) }
            linuxContainer = nil
            containerManager = nil
            networkReadyTask?.cancel()
            networkReadyTask = nil
            networkReady = false
            postStartVerifyTask?.cancel()
            postStartVerifyTask = nil
            try? await Self.forciblyRemoveAsync(at: staleContainerDir)
            await HostAPIBridgeServer.shared.stop()
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

        private func configureSandbox() async throws {
            _ = try? await exec(command: "mount -o remount,hidepid=2 /proc 2>/dev/null || true")

            // None of the steps below depend on outbound network — the shim
            // copy + bridge-token dir are pure in-guest filesystem ops. So we
            // kick the wget readiness probe off in the background and only
            // wait on it lazily from the first network-using caller (plugin
            // `apk add`, diagnostics, etc). In most environments the network
            // is up well before anyone asks, so the wait becomes a no-op.
            startNetworkReadinessProbe()

            let shimScript = Self.osaurusHostShimScript
            let shimStagingPath = OsaurusPaths.containerWorkspace().appendingPathComponent(".osaurus-host-shim")
            try shimScript.write(to: shimStagingPath, atomically: true, encoding: .utf8)
            _ = try await execAsRoot(
                command:
                    "cp /workspace/.osaurus-host-shim /usr/local/bin/osaurus-host && chmod 555 /usr/local/bin/osaurus-host && rm /workspace/.osaurus-host-shim"
            )

            // Bridge token directory: each agent user's token file lives here as
            // mode 0600. Mode 0711 on the directory lets users stat their own
            // file (which they know by name == their own $USER) without being
            // able to enumerate or read sibling token files.
            _ = try await execAsRoot(
                command: "mkdir -p \(Self.bridgeTokenDir) && chmod 0711 \(Self.bridgeTokenDir)"
            )
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
                    timeout: 5
                )
                if result?.stdout.contains("ok") == true {
                    debugLog("[Sandbox] Network ready after \(attempt) attempt(s)")
                    return true
                }
                debugLog("[Sandbox] Network not ready yet (attempt \(attempt))")
                try? await Task.sleep(nanoseconds: sleepNanos)
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
                ],
                substrings: [
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
                return SandboxError.startFailed(message)
            }
            if nsError.domain == NSPOSIXErrorDomain,
                let message = startFailureHints.posix[Int32(nsError.code)]
            {
                return SandboxError.startFailed(message)
            }
            let desc = String(describing: error)
            if let hit = startFailureHints.substrings.first(where: { desc.contains($0.needle) }) {
                return SandboxError.startFailed(hit.message)
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
            case .downloadKernel: return "Downloading Linux kernel"
            case .downloadInitFS: return "Downloading init filesystem"
            case .extractKernel: return "Extracting kernel"
            case .createContainer: return "Pulling sandbox image"
            case .startBridge: return "Starting host API bridge"
            case .startContainer: return "Booting container"
            case .configureSandbox: return "Configuring sandbox"
            case .verifyPlugins: return "Restoring plugins"
            }
        }

        /// Build the ordered step list a fresh `provision()` will go
        /// through. On warm restarts (`isRestart == true`), the cached
        /// kernel + initfs steps are pre-marked `.skipped` so the UI
        /// renders them as completed checkmarks instead of indeterminate
        /// spinners that never tick.
        private func plannedSteps(isRestart: Bool, hasPlugins: Bool) -> [ProvisioningStepState] {
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
            steps.append(base(.createContainer))
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
                if let detail {
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
                    if journey.currentStepID == id { journey.currentStepID = nil }
                }
            }
        }

        /// Update the current "now doing" subtitle that floats under the
        /// active step in the UI. Cheap and idempotent so the SDK
        /// `ProgressHandler` and the download delegate can call it on
        /// every event without thrashing SwiftUI.
        private func setActivity(_ text: String?) async {
            await MainActor.run {
                State.shared.currentActivity = text
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
        private func applyByteProgress(
            stepID: ProvisioningStepID,
            bytes: Int64,
            total: Int64,
            detail: String? = nil
        ) async {
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
                    journey.currentStepID = stepID

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
                if let activityLine { State.shared.currentActivity = activityLine }
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
            if let step = activeStep {
                State.shared.provisioningPhase = step.label + "…"
                State.shared.provisioningProgress = step.progress
            } else if journey.finishedAt != nil {
                State.shared.provisioningPhase = nil
                State.shared.provisioningProgress = nil
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

    // MARK: - Errors

    public enum SandboxError: Error, LocalizedError {
        case unavailable
        case containerNotRunning
        case provisionFailed(String)
        case startFailed(String)
        case stopFailed(String)
        case removeFailed(String)
        case userCreationFailed(String)
        case execFailed(String)
        case timeout
        /// A downloaded artifact failed SHA-256 verification — fail-closed.
        /// Don't dress this up: if the kernel/initfs we just pulled doesn't
        /// match the expected digest, refuse to boot it.
        case integrityCheckFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable: L("Sandbox is not available on this system")
            case .containerNotRunning: "Container is not running"
            case .provisionFailed(let msg): "Provisioning failed: \(msg)"
            case .startFailed(let msg): "Container start failed: \(msg)"
            case .stopFailed(let msg): "Container stop failed: \(msg)"
            case .removeFailed(let msg): "Container removal failed: \(msg)"
            case .userCreationFailed(let msg): "User creation failed: \(msg)"
            case .execFailed(let msg): "Execution failed: \(msg)"
            case .timeout: "Command timed out"
            case .integrityCheckFailed(let msg): "Sandbox artifact integrity check failed: \(msg)"
            }
        }
    }

    // MARK: - Data Writer

    private protocol DataWriterReadable: AnyObject, Sendable {
        var data: Data { get }
        var string: String { get }
        var lastWriteTime: Date? { get }
    }

    /// Collects data written from a container process's stdout/stderr into memory.
    /// Implements the Containerization `Writer` protocol.
    private final class DataWriter: Writer, DataWriterReadable, @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var _lastWriteTime: Date?

        func write(_ data: Data) throws {
            lock.withLock {
                buffer.append(data)
                _lastWriteTime = Date()
            }
        }

        func close() throws {}

        var data: Data {
            lock.withLock { buffer }
        }

        var string: String {
            String(data: data, encoding: .utf8) ?? ""
        }

        var lastWriteTime: Date? {
            lock.withLock { _lastWriteTime }
        }
    }

    // MARK: - Logging Data Writer

    /// Like DataWriter but also streams each complete line to SandboxLogBuffer
    /// in real-time. Uses a single lock scope per write and debounced MainActor
    /// dispatch to avoid flooding the main thread under high-throughput output.
    private final class LoggingDataWriter: Writer, DataWriterReadable, @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var lineBuffer = Data()
        private var pendingLines: [String] = []
        private var flushScheduled = false
        private var _lastWriteTime: Date?
        private let source: String
        private let level: SandboxLogBuffer.Entry.Level

        init(source: String, level: SandboxLogBuffer.Entry.Level) {
            self.source = source
            self.level = level
        }

        func write(_ data: Data) throws {
            let shouldSchedule: Bool = lock.withLock {
                buffer.append(data)
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
                    pendingLines.append(s)
                }
                lineBuffer.removeAll()
                return drainPendingLines()
            }
            sendToLogBuffer(lines)
        }

        var data: Data { lock.withLock { buffer } }

        var string: String { String(data: data, encoding: .utf8) ?? "" }

        var lastWriteTime: Date? { lock.withLock { _lastWriteTime } }

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
                    pendingLines.append(line)
                }
                start = lineBuffer.index(after: i)
            }
            if start > lineBuffer.startIndex {
                lineBuffer = Data(lineBuffer[start...])
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

    // MARK: - Download Progress Delegate

    private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (_ bytesWritten: Int64, _ totalBytesExpected: Int64) -> Void

        init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(
            _: URLSession,
            downloadTask _: URLSessionDownloadTask,
            didWriteData _: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            onProgress(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
        }

        func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo _: URL) {}
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
