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
    import Foundation

    public actor SandboxManager {
        public static let shared = SandboxManager()

        private static let containerID = "osaurus-sandbox"
        private static let containerImage = "ghcr.io/osaurus-ai/sandbox:latest"
        private static let kernelDownloadURLs = [
            "https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz"
        ]
        private static let initfsDownloadURLs = [
            // "https://github.com/osaurus-ai/osaurus/releases/latest/download/init.ext4"
            "https://pub-5f3c2bf70e93411790bbcd6419d2f8fa.r2.dev/init.ext4"
        ]

        /// Host-side Unix socket path for the bridge server (relayed into guest via vsock)
        private static var bridgeSocketPath: String {
            OsaurusPaths.container().appendingPathComponent("bridge.sock").path
        }
        /// Where the bridge socket appears inside the guest container
        private static let guestBridgeSocketPath = "/tmp/osaurus-bridge.sock"

        private var _status: ContainerStatus = .notProvisioned
        private var _availability: SandboxAvailability?
        private var containerManager: ContainerManager?
        private var linuxContainer: LinuxContainer?
        private var _removedByUser = false

        // MARK: - Observable State (MainActor bridge)

        @MainActor
        public final class State: ObservableObject {
            public static let shared = State()
            @Published public var availability: SandboxAvailability = .unavailable(reason: "Not checked yet")
            @Published public var status: ContainerStatus = .notProvisioned
            @Published public var provisioningPhase: String?
            @Published public var provisioningProgress: Double?
            @Published public var isProvisioning: Bool = false
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

        public func refreshStatus() -> ContainerStatus {
            if linuxContainer != nil {
                _status = .running
            } else if FileManager.default.fileExists(atPath: staleContainerDir.path) {
                // Auto-clean stale container state from a previous session
                NSLog("[SandboxManager] Cleaning up stale container state from previous session")
                try? FileManager.default.removeItem(at: staleContainerDir)
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

            do {
                let config = SandboxConfigurationStore.load()
                let isRestart = hasRequiredAssets

                let kernel = try await ensureKernel()
                let initfs = try await ensureInitFS()

                await setProvisioningPhase(isRestart ? "Preparing sandbox..." : "Pulling Alpine image...")
                try ensureHostDirectories()

                // Clean up stale container state from a previous crash
                if FileManager.default.fileExists(atPath: staleContainerDir.path) {
                    NSLog("[SandboxManager] Cleaning up stale container state")
                    try? FileManager.default.removeItem(at: staleContainerDir)
                }

                if #available(macOS 26, *) {
                    await setProvisioningPhase(isRestart ? "Starting sandbox..." : "Starting host API bridge...")
                    try await HostAPIBridgeServer.shared.start(socketPath: Self.bridgeSocketPath)

                    let network = try VmnetNetwork()
                    var manager = try ContainerManager(
                        kernel: kernel,
                        initfs: initfs,
                        root: OsaurusPaths.container(),
                        network: network
                    )

                    await setProvisioningPhase(isRestart ? "Booting container..." : "Creating container...")
                    let workspace = OsaurusPaths.containerWorkspace().path
                    let bridgeSocketPath = Self.bridgeSocketPath
                    let guestBridgeSocketPath = Self.guestBridgeSocketPath

                    let container = try await manager.create(
                        Self.containerID,
                        reference: Self.containerImage,
                        rootfsSizeInBytes: 8.gib(),
                        networking: true
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

                    await setProvisioningPhase("Starting container...")
                    try await container.create()
                    try await container.start()

                    self.containerManager = manager
                    self.linuxContainer = container
                }

                await setProvisioningPhase(isRestart ? "Finishing up..." : "Configuring sandbox...")
                try await configureSandbox()

                _status = .running
                syncStatus()
                await setProvisioningPhase(nil)

                var savedConfig = SandboxConfigurationStore.load()
                if !savedConfig.setupComplete {
                    savedConfig.setupComplete = true
                    SandboxConfigurationStore.save(savedConfig)
                }
            } catch {
                NSLog("[SandboxManager] Provision failed: \(error)")
                await setProvisioningPhase(nil)
                await cleanupAfterFailure()
                throw error
            }
        }

        // MARK: - Start / Stop

        public func startContainer() async throws {
            guard _availability?.isAvailable == true else {
                throw SandboxError.unavailable
            }
            guard !_removedByUser else { return }

            let current = refreshStatus()
            switch current {
            case .running, .starting:
                return
            case .error:
                try? FileManager.default.removeItem(at: staleContainerDir)
                linuxContainer = nil
                containerManager = nil
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
            await HostAPIBridgeServer.shared.stop()
            _status = .stopped
            syncStatus()
        }

        public func removeContainer() async throws {
            try await stopContainer()
            let containerDir = OsaurusPaths.container()
            try? FileManager.default.removeItem(at: containerDir.appendingPathComponent("containers"))
            try? FileManager.default.removeItem(at: OsaurusPaths.containerKernelFile())
            try? FileManager.default.removeItem(at: OsaurusPaths.containerInitFSFile())
            _status = .notProvisioned
            _removedByUser = true
            syncStatus()
            await setProvisioningPhase(nil)

            var config = SandboxConfigurationStore.load()
            config.setupComplete = false
            SandboxConfigurationStore.save(config)
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
            timeout: TimeInterval = 30,
            streamToLogs: Bool = false,
            logSource: String? = nil
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
                logSource: logSource
            )
        }

        public func execAsRoot(
            command: String,
            timeout: TimeInterval = 60,
            streamToLogs: Bool = false,
            logSource: String? = nil
        ) async throws -> ContainerExecResult {
            try await exec(
                command: command,
                timeout: timeout,
                streamToLogs: streamToLogs,
                logSource: logSource
            )
        }

        public func execAsAgent(
            _ agentName: String,
            command: String,
            pluginName: String? = nil,
            env: [String: String] = [:],
            timeout: TimeInterval = 30,
            streamToLogs: Bool = false,
            logSource: String? = nil
        ) async throws -> ContainerExecResult {
            let cwd = pluginName.map { OsaurusPaths.inContainerPluginDir(agentName, $0) }
            return try await exec(
                user: "agent-\(agentName)",
                command: command,
                env: env,
                cwd: cwd,
                timeout: timeout,
                streamToLogs: streamToLogs,
                logSource: logSource
            )
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
            let currentStatus = refreshStatus()
            var users: [String] = []
            var disk: String? = nil
            var uptime: String? = nil
            var memoryUsage: String? = nil
            var cpuLoad: String? = nil
            var processCount: Int? = nil

            if currentStatus.isRunning {
                if let result = try? await exec(command: "awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd") {
                    users = result.stdout.split(separator: "\n").map(String.init)
                }
                if let result = try? await exec(command: "du -sh /workspace 2>/dev/null | cut -f1") {
                    disk = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let result = try? await exec(command: "cat /proc/uptime | awk '{printf \"%.0f seconds\", $1}'") {
                    uptime = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let result = try? await exec(
                    command:
                        "awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf \"%dMB / %dMB\", (t-a)/1024, t/1024}' /proc/meminfo"
                ) {
                    let mem = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !mem.isEmpty { memoryUsage = mem }
                }
                if let result = try? await exec(command: "awk '{printf \"%s %s %s\", $1, $2, $3}' /proc/loadavg") {
                    let load = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !load.isEmpty { cpuLoad = load }
                }
                if let result = try? await exec(command: "ls -1 /proc | grep -c '^[0-9]'") {
                    let count = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    processCount = Int(count)
                }
            }

            return ContainerInfo(
                status: currentStatus,
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
        public func runDiagnostics() async -> [DiagnosticResult] {
            var results: [DiagnosticResult] = []

            results.append(
                await diagnose("exec") {
                    let r = try await exec(command: "echo hello from sandbox")
                    let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard out == "hello from sandbox" else {
                        throw SandboxError.execFailed("expected 'hello from sandbox', got '\(out)'")
                    }
                    return out
                }
            )

            results.append(
                await diagnose("nat-networking") {
                    let r = try await exec(command: "wget -qO- http://example.com 2>/dev/null | head -5", timeout: 15)
                    let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !out.isEmpty else {
                        throw SandboxError.execFailed("empty response (stderr: \(r.stderr))")
                    }
                    return String(out.prefix(80))
                }
            )

            results.append(
                await diagnose("agent-user") {
                    try await ensureAgentUser("diag")
                    let r = try await exec(user: "agent-diag", command: "whoami")
                    let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard out == "agent-diag" else {
                        throw SandboxError.execFailed("expected 'agent-diag', got '\(out)'")
                    }
                    return out
                }
            )

            results.append(
                await diagnose("apk-install") {
                    let r = try await execAsRoot(command: "apk add --no-cache jq 2>&1", timeout: 60)
                    guard r.succeeded else {
                        throw SandboxError.execFailed(r.stderr)
                    }
                    return "exit \(r.exitCode)"
                }
            )

            results.append(
                await diagnose("vsock-bridge") {
                    let r = try await exec(
                        command: "curl -sf --unix-socket /tmp/osaurus-bridge.sock http://localhost/api/log "
                            + "-X POST -d '{\"level\":\"info\",\"message\":\"diag ping\"}'"
                    )
                    guard r.succeeded else {
                        throw SandboxError.execFailed("exit \(r.exitCode): \(r.stderr)")
                    }
                    return "bridge responded OK"
                }
            )

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
                await setProvisioningPhase("Downloading init filesystem...")
                try OsaurusPaths.ensureExists(OsaurusPaths.container())
                try await downloadFile(from: Self.initfsDownloadURLs, to: stagedPath)
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

            await setProvisioningPhase("Downloading Linux kernel...")

            let kernelDir = OsaurusPaths.containerKernelDir()
            try OsaurusPaths.ensureExists(kernelDir)

            let stableTarball = kernelDir.appendingPathComponent("kata.tar.xz")
            try await downloadFile(from: Self.kernelDownloadURLs, to: stableTarball)
            defer { try? FileManager.default.removeItem(at: stableTarball) }

            await setProvisioningPhase("Extracting kernel...")

            let extractDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-kernel-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: extractDir) }

            let tarProcess = Process()
            tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tarProcess.arguments = ["-xf", stableTarball.path, "-C", extractDir.path, "--strip-components=1"]
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

            NSLog("[SandboxManager] Kernel installed at \(kernelPath.path)")
            return Kernel(path: kernelPath, platform: .linuxArm)
        }

        // MARK: - Private: Asset Download

        /// Downloads a file from the first successful URL in the list to the given destination,
        /// reporting byte-level download progress to the UI.
        private func downloadFile(from urls: [String], to destination: URL) async throws {
            let delegate = DownloadProgressDelegate { progress in
                Task { @MainActor in
                    State.shared.provisioningProgress = progress
                }
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }

            var lastError: Error?
            for urlString in urls {
                guard let url = URL(string: urlString) else { continue }
                do {
                    NSLog("[SandboxManager] Downloading from \(urlString)...")
                    let (tempURL, response) = try await session.download(from: url)
                    guard let httpResponse = response as? HTTPURLResponse,
                        (200 ... 299).contains(httpResponse.statusCode)
                    else {
                        NSLog(
                            "[SandboxManager] HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) from \(urlString)"
                        )
                        continue
                    }

                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    NSLog("[SandboxManager] Downloaded to \(destination.path)")
                    return
                } catch {
                    lastError = error
                    NSLog("[SandboxManager] Download failed from \(urlString): \(error)")
                }
            }

            throw SandboxError.provisionFailed(
                "Download failed: \(lastError?.localizedDescription ?? "all URLs failed")"
            )
        }

        // MARK: - Private: Exec via VM Agent

        private func execViaAgent(
            args: [String],
            env: [String: String],
            timeout: TimeInterval,
            streamToLogs: Bool = false,
            logSource: String? = nil
        ) async throws -> ContainerExecResult {
            guard let container = linuxContainer else {
                throw SandboxError.containerNotRunning
            }

            let source = logSource ?? "exec"
            let stdout: any Writer & DataWriterReadable
            let stderr: any Writer & DataWriterReadable
            if streamToLogs {
                stdout = LoggingDataWriter(source: source, level: .stdout)
                stderr = LoggingDataWriter(source: source, level: .error)
            } else {
                stdout = DataWriter()
                stderr = DataWriter()
            }

            var mergedEnv = env
            if mergedEnv["PATH"] == nil {
                mergedEnv["PATH"] = LinuxProcessConfiguration.defaultPath
            }
            let environ = mergedEnv.map { "\($0.key)=\($0.value)" }
            let process = try await container.exec(UUID().uuidString) { config in
                config.arguments = args
                config.environmentVariables = environ
                config.stdout = stdout
                config.stderr = stderr
            }

            try await process.start()

            do {
                let exitStatus = try await waitWithInactivityTimeout(
                    process: process,
                    stdout: stdout,
                    stderr: stderr,
                    timeout: timeout
                )
                try await process.delete()
                return ContainerExecResult(
                    stdout: stdout.string,
                    stderr: stderr.string,
                    exitCode: exitStatus.exitCode
                )
            } catch {
                try? await process.delete()
                throw error
            }
        }

        /// Waits for a process to exit, using an inactivity-based timeout that
        /// resets whenever stdout or stderr receives data. Only kills the process
        /// if no output arrives for `timeout` seconds.
        private func waitWithInactivityTimeout(
            process: LinuxProcess,
            stdout: any DataWriterReadable,
            stderr: any DataWriterReadable,
            timeout: TimeInterval
        ) async throws -> ExitStatus {
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
            try? FileManager.default.removeItem(at: staleContainerDir)
            await HostAPIBridgeServer.shared.stop()
        }

        private func ensureHostDirectories() throws {
            try OsaurusPaths.ensureExists(OsaurusPaths.container())
            try OsaurusPaths.ensureExists(OsaurusPaths.containerWorkspace())
            try OsaurusPaths.ensureExists(OsaurusPaths.containerAgentsDir())
            try OsaurusPaths.ensureExists(OsaurusPaths.containerSharedDir())
        }

        private func configureSandbox() async throws {
            _ = try? await exec(command: "mount -o remount,hidepid=2 /proc 2>/dev/null || true")
            await waitForNetwork()

            let shimScript = Self.osaurusHostShimScript
            let shimStagingPath = OsaurusPaths.containerWorkspace().appendingPathComponent(".osaurus-host-shim")
            try shimScript.write(to: shimStagingPath, atomically: true, encoding: .utf8)
            _ = try await execAsRoot(
                command:
                    "cp /workspace/.osaurus-host-shim /usr/local/bin/osaurus-host && chmod 555 /usr/local/bin/osaurus-host && rm /workspace/.osaurus-host-shim"
            )
        }

        /// Polls until the guest can reach the Alpine CDN, so plugins that
        /// run `apk add` right after provisioning don't hit DNS failures.
        private func waitForNetwork() async {
            for attempt in 1 ... 5 {
                let result = try? await exec(
                    command: "wget -q --spider http://dl-cdn.alpinelinux.org 2>/dev/null && echo ok",
                    timeout: 5
                )
                if result?.stdout.contains("ok") == true { return }
                NSLog("[SandboxManager] Network not ready yet (attempt \(attempt)/5)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        // MARK: - osaurus-host Shell Shim

        private static let osaurusHostShimScript = """
            #!/bin/sh
            # osaurus-host — Host API bridge shim for sandbox plugins.
            # Translates CLI commands to HTTP calls over a vsock-relayed Unix socket.
            SOCK="/tmp/osaurus-bridge.sock"
            API="http://localhost/api"
            USER=$(whoami)
            PLUGIN="${OSAURUS_PLUGIN:-$(basename "$(pwd)")}"
            H="-H X-Osaurus-User:$USER -H X-Osaurus-Plugin:$PLUGIN"

            _call() {
              _tmp=$(mktemp)
              _code=$(curl -s -o "$_tmp" -w '%{http_code}' --unix-socket "$SOCK" "$@")
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
                  get) _call $H "$API/secrets/$3" | jq -r '.value // empty' ;;
                  *) echo "Usage: osaurus-host secrets get <name>" >&2; exit 1 ;;
                esac ;;
              config)
                case "$2" in
                  get) _call $H "$API/config/$3" | jq -r '.value // empty' ;;
                  set) _call -X POST $H "$API/config/$3" -d "{\\"value\\":\\"$4\\"}" > /dev/null ;;
                  *) echo "Usage: osaurus-host config get|set <key> [value]" >&2; exit 1 ;;
                esac ;;
              inference)
                case "$2" in
                  chat)
                    shift 2; MSG=""
                    while [ $# -gt 0 ]; do case "$1" in -m) shift; MSG="$1" ;; esac; shift; done
                    _call -X POST $H "$API/inference/chat" \
                      -d "{\\"messages\\":[{\\"role\\":\\"user\\",\\"content\\":\\"$MSG\\"}]}" | jq -r '.content // empty' ;;
                  *) echo "Usage: osaurus-host inference chat -m <message>" >&2; exit 1 ;;
                esac ;;
              agent)
                case "$2" in
                  dispatch) _call -X POST $H "$API/agent/dispatch" -d "{\\"agent_id\\":\\"$3\\",\\"task\\":\\"$4\\"}" ;;
                  memory)
                    case "$3" in
                      query) _call -X POST $H "$API/agent/memory/query" -d "{\\"query\\":\\"$4\\"}" ;;
                      store) _call -X POST $H "$API/agent/memory/store" -d "{\\"content\\":\\"$4\\"}" ;;
                      *) echo "Usage: osaurus-host agent memory query|store <text>" >&2; exit 1 ;;
                    esac ;;
                  *) echo "Usage: osaurus-host agent dispatch|memory ..." >&2; exit 1 ;;
                esac ;;
              events)
                case "$2" in
                  emit) _call -X POST $H "$API/events/emit" -d "{\\"type\\":\\"$3\\",\\"payload\\":${4:-{}}}" > /dev/null ;;
                  *) echo "Usage: osaurus-host events emit <type> [payload]" >&2; exit 1 ;;
                esac ;;
              plugin)
                case "$2" in
                  create) cat | _call -X POST $H "$API/plugin/create" -d @- ;;
                  *) echo "Usage: osaurus-host plugin create < plugin.json" >&2; exit 1 ;;
                esac ;;
              log)
                curl -sf --unix-socket "$SOCK" -X POST -H "X-Osaurus-User:$USER" "$API/log" \
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

        private static func friendlyError(from error: Error) -> Error {
            let desc = String(describing: error)
            if desc.contains("GRPC") {
                return SandboxError.startFailed(
                    "Container failed to start (VM error). Try resetting the container."
                )
            }
            if desc.contains("vmnet") {
                return SandboxError.startFailed(
                    "Container networking failed. Ensure no other VMs are using conflicting network resources."
                )
            }
            return error
        }

        private func setProvisioningPhase(_ phase: String?) async {
            await MainActor.run {
                State.shared.provisioningPhase = phase
                State.shared.provisioningProgress = nil
                State.shared.isProvisioning = phase != nil
                if let phase = phase {
                    SandboxLogBuffer.shared.append(
                        level: .info,
                        message: phase,
                        source: "setup"
                    )
                }
            }
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

        public var errorDescription: String? {
            switch self {
            case .unavailable: "Sandbox is not available on this system"
            case .containerNotRunning: "Container is not running"
            case .provisionFailed(let msg): "Provisioning failed: \(msg)"
            case .startFailed(let msg): "Container start failed: \(msg)"
            case .stopFailed(let msg): "Container stop failed: \(msg)"
            case .removeFailed(let msg): "Container removal failed: \(msg)"
            case .userCreationFailed(let msg): "User creation failed: \(msg)"
            case .execFailed(let msg): "Execution failed: \(msg)"
            case .timeout: "Command timed out"
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
        private let onProgress: @Sendable (Double) -> Void

        init(onProgress: @escaping @Sendable (Double) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(
            _: URLSession,
            downloadTask _: URLSessionDownloadTask,
            didWriteData _: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1.0))
        }

        func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo _: URL) {}
    }

#endif
