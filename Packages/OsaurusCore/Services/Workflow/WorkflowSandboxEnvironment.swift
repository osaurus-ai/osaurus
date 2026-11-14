//
//  WorkflowSandboxEnvironment.swift
//  osaurus
//
//  A workflow's own sandbox environment: the Linux user, home, venv, and
//  npm workspace its shell steps run with, under the same layout as an
//  agent's (`agent-wf-<uuid>` / `/workspace/agents/wf-<uuid>`) so every
//  sandbox primitive (exec, PATH injection, install lock, recovery) works
//  unchanged. The setup wizard installs the template's declared
//  dependencies here once and verifies the binaries they promise; the
//  manifest in the environment's home records what was installed so the
//  setup checker can answer without booting the VM.
//
//  Environments are keyed by **template id** (`environmentID`), not by
//  the installed workflow or draft id: a template installs at most once
//  per Mac, an Architect draft's template id is the draft id, and the
//  install wizard runs before an `InstalledWorkflow` exists. One key
//  therefore follows a workflow from its first test run in the Architect
//  through install, setup, update, and every run.
//

import Foundation

/// What is installed in a workflow's environment, persisted on the host.
public struct WorkflowSandboxManifest: Codable, Equatable, Sendable {
    public struct Installed: Codable, Equatable, Sendable {
        public var manager: WorkflowDependency.Manager
        public var packages: [String]
        public var binaries: [String]
    }

    /// `virtualMachine` or `seatbelt`; a manifest from the other backend
    /// does not count.
    public var backend: String
    /// Pinned image the install ran against. After a container reset or
    /// image change `apk` packages are gone, so the manifest is stale.
    public var imageDigest: String
    public var installed: [Installed]
    public var installedAt: Date
    /// Entries whose packages lived in a rootfs clone that was evicted
    /// (apk). They were installed once with the user's consent, so the
    /// next run reinstalls them instead of sending the workflow back to
    /// setup.
    public var evicted: [Installed]?

    enum CodingKeys: String, CodingKey {
        case backend, installed, evicted
        case imageDigest = "image_digest"
        case installedAt = "installed_at"
    }

    public init(
        backend: String, imageDigest: String, installed: [Installed], installedAt: Date, evicted: [Installed]? = nil
    ) {
        self.backend = backend
        self.imageDigest = imageDigest
        self.installed = installed
        self.installedAt = installedAt
        self.evicted = evicted
    }

    /// Whether `dependency` is covered: same manager, every package and
    /// binary present.
    public func covers(_ dependency: WorkflowDependency) -> Bool {
        Self.entries(installed, cover: dependency)
    }

    /// Whether `dependency` was installed and then lost to an eviction.
    public func evictedCovers(_ dependency: WorkflowDependency) -> Bool {
        Self.entries(evicted ?? [], cover: dependency)
    }

    private static func entries(_ entries: [Installed], cover dependency: WorkflowDependency) -> Bool {
        guard let entry = entries.first(where: { $0.manager == dependency.manager }) else { return false }
        let packages = Set(entry.packages.map { $0.lowercased() })
        let binaries = Set(entry.binaries.map { $0.lowercased() })
        return dependency.packages.allSatisfy { packages.contains($0.lowercased()) }
            && dependency.binaries.allSatisfy { binaries.contains($0.lowercased()) }
    }

    /// The manifest after the environment's rootfs clone was discarded:
    /// apk entries move to `evicted`; pip and npm live on the host share
    /// and stay installed.
    public func afterRootfsEviction() -> WorkflowSandboxManifest {
        var copy = self
        let lost = installed.filter { $0.manager.requiresLinuxVM }
        guard !lost.isEmpty else { return copy }
        copy.installed.removeAll { $0.manager.requiresLinuxVM }
        var evicted = copy.evicted ?? []
        evicted.removeAll { entry in lost.contains { $0.manager == entry.manager } }
        copy.evicted = evicted + lost
        return copy
    }
}

/// How one dependency stands on this Mac.
public enum WorkflowDependencyStatus: Equatable, Sendable {
    case installed
    case notInstalled
    /// The manifest says installed but it was made for another sandbox
    /// backend or image (a reset or an app update replaced the rootfs).
    case stale
    /// `apk` on the Seatbelt backend.
    case unsupportedHere
    /// Installed once, then lost when the sandbox evicted this workflow's
    /// environment to make room; the next run installs it again.
    case reinstallOnRun
}

/// The sandbox a workflow run's shell steps execute in, bound on
/// `ChatExecutionContext.workflowSandbox` for every node attempt.
public struct WorkflowSandboxContext: Sendable, Equatable {
    public let environmentID: UUID
    /// Identity `shell_run` bridges to.
    public let bridge: SandboxReadBridge
    /// The run workspace as the VM sees it; the cwd of every shell step.
    public let inVMWorkingDirectory: String

    public init(environmentID: UUID, bridge: SandboxReadBridge, inVMWorkingDirectory: String) {
        self.environmentID = environmentID
        self.bridge = bridge
        self.inVMWorkingDirectory = inVMWorkingDirectory
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.environmentID == rhs.environmentID && lhs.inVMWorkingDirectory == rhs.inVMWorkingDirectory
            && lhs.bridge.agentName == rhs.bridge.agentName
    }

    /// The context for one run of `environmentID`.
    public static func forRun(environmentID: UUID, runID: UUID) -> WorkflowSandboxContext {
        WorkflowSandboxContext(
            environmentID: environmentID,
            bridge: WorkflowSandboxEnvironment.identity(for: environmentID).bridge,
            inVMWorkingDirectory: OsaurusPaths.workflowSandboxRunWorkspaceInContainer(
                environmentID: environmentID, runID: runID))
    }
}

public struct WorkflowSandboxInstallFailure: Error, LocalizedError, Equatable, Sendable {
    public var manager: WorkflowDependency.Manager
    public var message: String
    public var errorDescription: String? { message }
}

@MainActor
public final class WorkflowSandboxEnvironment {
    public static let shared = WorkflowSandboxEnvironment()

    /// Identity a workflow's sandbox commands run as.
    public struct Identity: Sendable, Equatable {
        public let environmentID: UUID
        public var agentName: String { OsaurusPaths.workflowSandboxAgentName(environmentID: environmentID) }
        /// The agent-id string sandbox helpers take. Not a UUID on purpose:
        /// agent-keyed stores (secrets, the per-agent package manifest)
        /// then stay untouched.
        public var agentId: String { agentName }
        public var home: String { OsaurusPaths.inContainerAgentHome(agentName) }
        public var hostHome: URL { OsaurusPaths.containerAgentDir(agentName) }

        var bridge: SandboxReadBridge {
            SandboxReadBridge(agentId: agentId, agentName: agentName, home: home, backgroundEnabled: false)
        }
    }

    /// Install progress, one line at a time, for the wizard's log.
    public typealias Progress = @Sendable (String) -> Void

    private var manifests: [UUID: WorkflowSandboxManifest?] = [:]
    private var inFlight: [UUID: Task<Void, Error>] = [:]
    /// Injectable for tests: the install and exec bodies.
    var installer: @Sendable (WorkflowDependency.Manager, [String], Identity) async throws -> String = {
        manager, packages, identity in
        try await SandboxPackageInstaller.install(
            manager: manager, packages: packages, agentId: identity.agentId, agentName: identity.agentName,
            home: identity.home)
    }
    var runAsIdentity: @Sendable (String, Identity) async throws -> ContainerExecResult = { command, identity in
        try await SandboxToolCommandRunnerRegistry.shared.execAsAgent(
            identity.agentName, command: command,
            env: SandboxPackageInstaller.shellEnvironment(agentId: identity.agentId, home: identity.home),
            timeout: 30)
    }
    var provisionIdentity: @Sendable (Identity) async throws -> Void = { identity in
        await SandboxManager.shared.requestMembership(agentName: identity.agentName)
        try await SandboxManager.shared.startContainer()
        try FileManager.default.createDirectory(
            at: identity.hostHome.appendingPathComponent("plugins", isDirectory: true),
            withIntermediateDirectories: true)
        try await SandboxManager.shared.bootstrapAgent(agentName: identity.agentName, agentId: nil, soulSeedBody: nil)
    }

    private init() {}

    nonisolated public static func identity(for environmentID: UUID) -> Identity { Identity(environmentID: environmentID) }

    // MARK: - Status

    /// The sandbox backend this process runs, as the manifest records it.
    nonisolated static var currentBackendName: String {
        SandboxBackend.current == .virtualMachine ? "virtualMachine" : "seatbelt"
    }

    nonisolated static var currentImageDigest: String {
        SandboxBackend.current == .virtualMachine ? SandboxManager.pinnedContainerImageForTesting : "host"
    }

    public func manifest(for environmentID: UUID) -> WorkflowSandboxManifest? {
        if let cached = manifests[environmentID] { return cached }
        let loaded = Self.loadManifest(environmentID: environmentID)
        manifests[environmentID] = .some(loaded)
        return loaded
    }

    nonisolated static func loadManifest(environmentID: UUID) -> WorkflowSandboxManifest? {
        let url = OsaurusPaths.workflowSandboxManifestFile(environmentID: environmentID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WorkflowSandboxManifest.self, from: data)
    }

    /// Pure status for one dependency given a manifest and the current
    /// backend; `check(_:)` and tests both use it.
    nonisolated static func status(
        of dependency: WorkflowDependency, manifest: WorkflowSandboxManifest?,
        backend: String = currentBackendName, imageDigest: String = currentImageDigest
    ) -> WorkflowDependencyStatus {
        if dependency.manager.requiresLinuxVM, backend != "virtualMachine" { return .unsupportedHere }
        guard let manifest else { return .notInstalled }
        let sameSandbox = manifest.backend == backend && manifest.imageDigest == imageDigest
        if manifest.covers(dependency) { return sameSandbox ? .installed : .stale }
        if sameSandbox, manifest.evictedCovers(dependency) { return .reinstallOnRun }
        return .notInstalled
    }

    public func status(of dependency: WorkflowDependency, environmentID: UUID) -> WorkflowDependencyStatus {
        Self.status(of: dependency, manifest: manifest(for: environmentID))
    }

    // MARK: - Install

    /// Provision the environment and install every dependency, verifying
    /// the binaries each promises. Throws on the first failing manager
    /// after recording the ones that succeeded, so a retry only redoes
    /// what is missing.
    public func install(
        _ dependencies: [WorkflowDependency], environmentID: UUID, progress: Progress? = nil
    ) async throws {
        if let existing = inFlight[environmentID] {
            try await existing.value
            return
        }
        let identity = Identity(environmentID: environmentID)
        let installer = self.installer
        let run = self.runAsIdentity
        let provision = self.provisionIdentity
        let previous = manifest(for: environmentID)
        let task = Task<Void, Error> { [weak self] in
            progress?(L("Starting the sandbox…"))
            try await provision(identity)
            var manifest = WorkflowSandboxManifest(
                backend: Self.currentBackendName, imageDigest: Self.currentImageDigest,
                installed: [], installedAt: Date())
            // Keep entries from a current manifest for managers not being
            // reinstalled, so a partial retry does not lose them.
            if let previous, previous.backend == manifest.backend, previous.imageDigest == manifest.imageDigest {
                manifest.installed = previous.installed.filter { entry in
                    !dependencies.contains { $0.manager == entry.manager }
                }
                let stillEvicted = (previous.evicted ?? []).filter { entry in
                    !dependencies.contains { $0.manager == entry.manager }
                }
                manifest.evicted = stillEvicted.isEmpty ? nil : stillEvicted
            }
            for dependency in dependencies {
                try Task.checkCancellation()
                progress?(L("Installing \(dependency.packages.joined(separator: ", ")) (\(dependency.manager.rawValue))…"))
                let envelope = try await installer(dependency.manager, dependency.packages, identity)
                if ToolEnvelope.isError(envelope) {
                    let message = ToolEnvelope.failureMessage(envelope)
                    progress?(message)
                    await self?.persist(manifest, environmentID: environmentID)
                    throw WorkflowSandboxInstallFailure(manager: dependency.manager, message: message)
                }
                for binary in dependency.binaries {
                    progress?(L("Checking \(binary)…"))
                    let result = try await run("command -v \(SandboxPackageRequest.shellQuote(binary))", identity)
                    guard result.succeeded else {
                        let message = L(
                            "\(dependency.packages.joined(separator: ", ")) installed, but `\(binary)` is not on the sandbox PATH. Check the package name or the binary it provides.")
                        progress?(message)
                        await self?.persist(manifest, environmentID: environmentID)
                        throw WorkflowSandboxInstallFailure(manager: dependency.manager, message: message)
                    }
                }
                manifest.installed.append(
                    .init(manager: dependency.manager, packages: dependency.packages, binaries: dependency.binaries))
                await self?.persist(manifest, environmentID: environmentID)
            }
            progress?(L("Done."))
        }
        inFlight[environmentID] = task
        defer { inFlight[environmentID] = nil }
        try await task.value
    }

    private func persist(_ manifest: WorkflowSandboxManifest, environmentID: UUID) {
        manifests[environmentID] = .some(manifest)
        let url = OsaurusPaths.workflowSandboxManifestFile(environmentID: environmentID)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(manifest) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: - Run-time

    /// Make sure the environment exists before a run (a container restart
    /// loses Linux users; the bootstrap is idempotent). pip and npm
    /// packages live on the host share and survive; apk packages lost to
    /// an eviction are installed again here, from the same declared list
    /// the user approved in setup.
    public func ensureProvisioned(
        environmentID: UUID, dependencies: [WorkflowDependency] = [], progress: Progress? = nil
    ) async throws {
        try await provisionIdentity(Identity(environmentID: environmentID))
        let reinstall = dependencies.filter { status(of: $0, environmentID: environmentID) == .reinstallOnRun }
        guard !reinstall.isEmpty else { return }
        try await install(reinstall, environmentID: environmentID, progress: progress)
    }

    // MARK: - Removal

    /// Forget the environment of an uninstalled workflow or deleted draft:
    /// its manifest, host home (venv, npm workspace, run scratch), and
    /// Linux user when the sandbox is up.
    public func remove(environmentID: UUID) async {
        let identity = Identity(environmentID: environmentID)
        manifests[environmentID] = .some(nil)
        try? FileManager.default.removeItem(at: OsaurusPaths.workflowSandboxManifestFile(environmentID: environmentID))
        try? FileManager.default.removeItem(at: identity.hostHome)
        await SandboxInstallLock.shared.clear(agentName: identity.agentName)
        if await SandboxManager.shared.status().isRunning {
            _ = try? await SandboxManager.shared.removeAgentUser(identity.agentName)
        }
    }

    /// After a sandbox reset or removal every manifest is stale: the
    /// rootfs (and with it `apk` packages and Linux users) is gone. Drops
    /// them all so each workflow reads **Needs setup** until it installs
    /// again. Safe off the main actor; the in-memory cache is cleared on it.
    nonisolated public static func invalidateAll() {
        let fm = FileManager.default
        let agents = OsaurusPaths.containerAgentsDir()
        if let dirs = try? fm.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil) {
            for dir in dirs where dir.lastPathComponent.hasPrefix("wf-") {
                try? fm.removeItem(at: dir.appendingPathComponent(".osaurus-environment.json"))
            }
        }
        Task { @MainActor in shared.manifests.removeAll() }
    }

    /// Workflow environments whose rootfs clone was evicted lost their
    /// Linux user and apk packages. Their manifests keep pip and npm
    /// (on the host share) and mark apk for reinstall on the next run.
    nonisolated public static func environmentsReset(_ agentNames: some Sequence<String>) {
        let workflowNames = agentNames.filter { $0.hasPrefix("wf-") }
        guard !workflowNames.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        for name in workflowNames {
            let url = OsaurusPaths.containerAgentDir(name).appendingPathComponent(".osaurus-environment.json")
            guard let data = try? Data(contentsOf: url),
                let manifest = try? decoder.decode(WorkflowSandboxManifest.self, from: data),
                let updated = try? encoder.encode(manifest.afterRootfsEviction())
            else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            try? updated.write(to: url, options: .atomic)
        }
        Task { @MainActor in shared.manifests.removeAll() }
    }

    /// Drop cached manifests (tests, after external edits).
    func resetCache() { manifests.removeAll() }
}
