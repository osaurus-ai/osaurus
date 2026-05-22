//
//  SandboxPluginManager.swift
//  osaurus
//
//  Manages installation, setup, and lifecycle of sandbox plugins
//  that run inside the shared Linux container.
//

import Foundation
import Combine

@MainActor
public final class SandboxPluginManager: ObservableObject {
    public static let shared = SandboxPluginManager()

    /// agentId -> list of installed sandbox plugins
    @Published public var installedPlugins: [String: [InstalledSandboxPlugin]] = [:]
    @Published public var installProgress: [String: InstallProgress] = [:]

    /// Per-launch tracking of agents whose `apk` deps have been bulk-seeded
    /// by `batchInstallDependencies`. Lets `installSystemDependencies` skip
    /// the per-plugin `apk add` round-trip during the post-start repair
    /// pass when the same packages were already installed in one batch.
    /// Cleared when the container restarts so we re-seed after a fresh boot.
    private var agentsWithSeededDeps: Set<String> = []

    public struct InstallProgress: Sendable {
        public let pluginName: String
        public let phase: String
        public let agentId: String
    }

    private init() {
        loadAllInstalled()
    }

    // MARK: - Install

    public func install(plugin: SandboxPlugin, for agentId: String) async throws {
        let errors = plugin.validateFilePaths()
        guard errors.isEmpty else {
            throw SandboxPluginError.invalidPlugin(errors.joined(separator: "; "))
        }

        let agentName = SandboxAgentProvisioner.linuxName(for: agentId)
        let key = progressKey(plugin: plugin.id, agent: agentId)

        setProgress(
            key: key,
            InstallProgress(
                pluginName: plugin.name,
                phase: "Preparing...",
                agentId: agentId
            )
        )

        var installed = InstalledSandboxPlugin(
            plugin: plugin,
            agentId: agentId,
            status: .installing,
            sourceContentHash: plugin.contentHash
        )

        updateInstalled(installed, for: agentId)

        do {
            setProgress(
                key: key,
                InstallProgress(
                    pluginName: plugin.name,
                    phase: "Provisioning agent sandbox...",
                    agentId: agentId
                )
            )
            try await SandboxAgentProvisioner.shared.ensureProvisioned(agentId: agentId)

            if plugin.dependencies != nil {
                setProgress(
                    key: key,
                    InstallProgress(
                        pluginName: plugin.name,
                        phase: "Installing system packages...",
                        agentId: agentId
                    )
                )
            }
            try await installSystemDependencies(for: plugin, agentName: agentName)

            setProgress(
                key: key,
                InstallProgress(
                    pluginName: plugin.name,
                    phase: "Creating plugin directory...",
                    agentId: agentId
                )
            )
            let pluginDir = OsaurusPaths.inContainerPluginDir(agentName, plugin.id)
            let mkdirResult = try await SandboxManager.shared.execAsAgent(
                agentName,
                command: "mkdir -p \(pluginDir)"
            )
            guard mkdirResult.succeeded else {
                throw SandboxPluginError.setupFailed("mkdir failed: \(mkdirResult.stderr)")
            }

            if let files = plugin.files {
                setProgress(
                    key: key,
                    InstallProgress(
                        pluginName: plugin.name,
                        phase: "Seeding files...",
                        agentId: agentId
                    )
                )
                let hostPluginDir = self.hostPluginDir(agentName: agentName, pluginId: plugin.id)
                for (path, content) in files {
                    let fullPath = hostPluginDir.appendingPathComponent(path)
                    let dir = fullPath.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try content.write(to: fullPath, atomically: true, encoding: .utf8)
                }
                // Fix ownership inside the container so the agent user can access the files
                _ = try await SandboxManager.shared.execAsRoot(
                    command: "chown -R agent-\(agentName):agent-\(agentName) \(pluginDir)"
                )
            }

            if plugin.setup != nil {
                setProgress(
                    key: key,
                    InstallProgress(
                        pluginName: plugin.name,
                        phase: "Running setup...",
                        agentId: agentId
                    )
                )
            }
            try await runSetupCommand(for: plugin, agentName: agentName, agentId: agentId)

            installed.status = .ready
            updateInstalled(installed, for: agentId)
            saveInstalled(for: agentId)
            clearProgress(key: key)

            NotificationCenter.default.post(
                name: .sandboxPluginInstalled,
                object: nil,
                userInfo: [
                    "pluginId": plugin.id,
                    "agentId": agentId,
                ]
            )

        } catch {
            installed.status = .failed
            updateInstalled(installed, for: agentId)
            saveInstalled(for: agentId)
            clearProgress(key: key)
            throw error
        }
    }

    // MARK: - Uninstall

    public func uninstall(pluginId: String, from agentId: String) async throws {
        guard var list = installedPlugins[agentId],
            let index = list.firstIndex(where: { $0.id == pluginId })
        else { return }

        list[index].status = .uninstalling
        installedPlugins[agentId] = list

        let agentName = SandboxAgentProvisioner.linuxName(for: agentId)
        let pluginDir = OsaurusPaths.inContainerPluginDir(agentName, pluginId)

        if await SandboxManager.shared.status().isRunning {
            _ = try? await SandboxManager.shared.execAsAgent(
                agentName,
                command: "rm -rf '\(pluginDir)'"
            )
        }

        try? FileManager.default.removeItem(at: hostPluginDir(agentName: agentName, pluginId: pluginId))

        list.remove(at: index)
        installedPlugins[agentId] = list
        saveInstalled(for: agentId)

        NotificationCenter.default.post(
            name: .sandboxPluginUninstalled,
            object: nil,
            userInfo: [
                "pluginId": pluginId,
                "agentId": agentId,
            ]
        )
    }

    // MARK: - Reinstall

    public func reinstall(plugin: SandboxPlugin, for agentId: String) async throws {
        try await uninstall(pluginId: plugin.id, from: agentId)
        try await install(plugin: plugin, for: agentId)
    }

    // MARK: - Verify & Repair

    /// Re-installs ephemeral dependencies and re-runs setup for all `.ready`
    /// plugins across all agents. Call after the container restarts so that
    /// system packages and setup side effects lost with the rootfs are restored.
    ///
    /// Strategy:
    /// 1. Dedupe `apk add` packages across each agent's plugins and run a
    ///    single batched install per agent (apk's container-wide lock makes
    ///    splitting it pointless anyway).
    /// 2. After deps are seeded, run per-plugin setup commands concurrently
    ///    behind a small in-flight cap. `SandboxAgentProvisioner` is already
    ///    coalesced per-agent, so concurrent repairs for the same agent
    ///    naturally share its provision task.
    public func verifyAndRepairAllPlugins() async {
        guard await SandboxManager.shared.status().isRunning else { return }

        let snapshot = installedPlugins.flatMap { agentId, plugins in
            plugins.filter { $0.status == .ready }.map { (agentId, $0.plugin) }
        }
        guard !snapshot.isEmpty else { return }

        NSLog("[SandboxPluginManager] Verifying \(snapshot.count) installed plugin(s) after container start")

        // Warm restart: the in-guest apk db from the previous boot is
        // still on disk, so every previously-installed system package is
        // already present. Skip `batchInstallDependencies` and seed
        // `agentsWithSeededDeps` so per-plugin repair also short-circuits
        // `installSystemDependencies`. Per-plugin verify still runs to
        // catch app-version changes, but for unchanged plugins it's just
        // a few hundred ms of bridge stat()s.
        let isWarmBoot = await SandboxManager.shared.wasLastBootWarm

        if isWarmBoot {
            agentsWithSeededDeps = Set(
                snapshot.compactMap { (agentId, plugin) -> String? in
                    plugin.dependencies?.isEmpty == false ? agentId : nil
                }
            )
        } else {
            // Cold boot: reset the per-launch "deps seeded" set so each
            // post-start pass re-seeds for the freshly booted rootfs.
            // `apk` is sequential per agent because it acquires a
            // container-wide lock — parallel calls would just serialize
            // inside the guest while burning extra exec round-trips.
            agentsWithSeededDeps.removeAll()
            await batchInstallDependencies(snapshot)
        }

        await runRepairsConcurrently(snapshot, maxConcurrent: 4)
    }

    /// Group `snapshot` by agent, dedupe the union of `plugin.dependencies`,
    /// and run one `apk add --no-cache <deduped>` per agent. Marks each
    /// agent as "deps seeded" for this process so per-plugin
    /// `installSystemDependencies` can short-circuit during the repair
    /// pass that follows.
    private func batchInstallDependencies(_ snapshot: [(String, SandboxPlugin)]) async {
        var depsByAgent: [String: Set<String>] = [:]
        for (agentId, plugin) in snapshot {
            guard let deps = plugin.dependencies, !deps.isEmpty else { continue }
            depsByAgent[agentId, default: []].formUnion(deps)
        }
        guard !depsByAgent.isEmpty else { return }

        // Awaiting network here once is cheaper than letting every plugin's
        // installSystemDependencies await it independently — the readiness
        // probe is coalesced anyway, but this also lets us skip touching
        // `apk add` at all if the network never comes up.
        _ = await SandboxManager.shared.awaitNetworkReady()

        for (agentId, deps) in depsByAgent {
            let sortedDeps = deps.sorted().joined(separator: " ")
            do {
                let result = try await SandboxManager.shared.execAsRoot(
                    command: "apk add --no-cache \(sortedDeps)",
                    timeout: 300,
                    streamToLogs: true,
                    logSource: "plugin-repair:\(agentId)"
                )
                if result.succeeded {
                    agentsWithSeededDeps.insert(agentId)
                } else {
                    NSLog(
                        "[SandboxPluginManager] Batched apk add for agent \(agentId) returned exit \(result.exitCode): \(result.stderr.prefix(200))"
                    )
                }
            } catch {
                NSLog(
                    "[SandboxPluginManager] Batched apk add for agent \(agentId) threw: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Concurrency-capped scheduler used by `verifyAndRepairAllPlugins`.
    /// Factored out so each `group.addTask` site captures simple immutable
    /// `Sendable` values without confusing Swift 6.x's region-based
    /// isolation checker.
    private func runRepairsConcurrently(
        _ snapshot: [(String, SandboxPlugin)],
        maxConcurrent: Int
    ) async {
        await withTaskGroup(of: Void.self) { group in
            let cap = min(maxConcurrent, snapshot.count)
            for i in 0 ..< cap {
                scheduleRepair(in: &group, snapshot: snapshot, at: i)
            }
            var next = cap
            while await group.next() != nil {
                if next < snapshot.count {
                    scheduleRepair(in: &group, snapshot: snapshot, at: next)
                    next += 1
                }
            }
        }
    }

    /// Single, well-shaped scheduling site for repair tasks. Keeps the
    /// captured values local + Sendable so the isolation checker is happy.
    /// `repairPlugin` is `@MainActor`-isolated, so the awaited call hops
    /// to MainActor automatically — no need to pin the task itself.
    private nonisolated func scheduleRepair(
        in group: inout TaskGroup<Void>,
        snapshot: [(String, SandboxPlugin)],
        at index: Int
    ) {
        let agentId = snapshot[index].0
        let plugin = snapshot[index].1
        group.addTask { [weak self] in
            guard let self else { return }
            _ = await self.repairPlugin(plugin, for: agentId)
        }
    }

    /// Re-installs system dependencies and re-runs the setup command for a
    /// single plugin. If VirtioFS files are intact, only restores ephemeral
    /// deps. If files are missing, does a full reinstall.
    ///
    /// Short-circuit: when `hostFilesIntact == true` AND the plugin was
    /// last successfully verified by this same app version, skip the
    /// dep install + setup command entirely. The plugin's host files and
    /// the container's apk db are both stable across restarts of the
    /// same binary, so re-running everything is just wasted exec time.
    @discardableResult
    public func repairPlugin(_ plugin: SandboxPlugin, for agentId: String) async -> Bool {
        let agentName = SandboxAgentProvisioner.linuxName(for: agentId)
        let key = progressKey(plugin: plugin.id, agent: agentId)

        setProgress(
            key: key,
            InstallProgress(pluginName: plugin.name, phase: "Verifying plugin...", agentId: agentId)
        )
        defer { clearProgress(key: key) }

        guard hostFilesIntact(plugin: plugin, agentName: agentName) else {
            NSLog("[SandboxPluginManager] Plugin files missing for '\(plugin.id)' (agent \(agentId)), reinstalling")
            do {
                try await reinstall(plugin: plugin, for: agentId)
                stampVerified(pluginId: plugin.id, for: agentId)
                return true
            } catch {
                NSLog("[SandboxPluginManager] Reinstall failed for '\(plugin.id)': \(error.localizedDescription)")
                markPluginFailed(plugin.id, for: agentId)
                return false
            }
        }

        let currentVersion = Self.currentAppVersion
        if let installed = self.plugin(id: plugin.id, for: agentId),
            installed.lastVerifiedAppVersion == currentVersion
        {
            return true
        }

        do {
            try await SandboxAgentProvisioner.shared.ensureProvisioned(agentId: agentId)

            if plugin.dependencies != nil && !agentsWithSeededDeps.contains(agentId) {
                setProgress(
                    key: key,
                    InstallProgress(pluginName: plugin.name, phase: "Restoring system packages...", agentId: agentId)
                )
            }
            try await installSystemDependencies(for: plugin, agentName: agentName, agentId: agentId)

            if plugin.setup != nil {
                setProgress(
                    key: key,
                    InstallProgress(pluginName: plugin.name, phase: "Re-running setup...", agentId: agentId)
                )
            }
            try await runSetupCommand(for: plugin, agentName: agentName, agentId: agentId)

            stampVerified(pluginId: plugin.id, for: agentId)
            return true
        } catch {
            NSLog("[SandboxPluginManager] Repair failed for '\(plugin.id)': \(error.localizedDescription)")
            markPluginFailed(plugin.id, for: agentId)
            return false
        }
    }

    /// Persist the "verified under this app version" stamp for `pluginId`
    /// so the next post-start repair pass can short-circuit when nothing
    /// has changed since this successful verification.
    private func stampVerified(pluginId: String, for agentId: String) {
        guard var list = installedPlugins[agentId],
            let index = list.firstIndex(where: { $0.id == pluginId })
        else { return }
        let current = Self.currentAppVersion
        if list[index].lastVerifiedAppVersion == current { return }
        list[index].lastVerifiedAppVersion = current
        installedPlugins[agentId] = list
        saveInstalled(for: agentId)
    }

    private static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func markPluginFailed(_ pluginId: String, for agentId: String) {
        guard var list = installedPlugins[agentId],
            let index = list.firstIndex(where: { $0.id == pluginId })
        else { return }
        list[index].status = .failed
        installedPlugins[agentId] = list
        saveInstalled(for: agentId)
    }

    // MARK: - Outdated Detection

    public func isOutdated(pluginId: String, agentId: String) -> Bool {
        guard let installed = plugin(id: pluginId, for: agentId),
            let libraryPlugin = SandboxPluginLibrary.shared.plugin(id: pluginId)
        else { return false }
        return installed.sourceContentHash != libraryPlugin.contentHash
    }

    public func hasAnyOutdated(pluginId: String, validAgentIds: Set<String>) -> Bool {
        installedPlugins.contains { agentId, plugins in
            validAgentIds.contains(agentId)
                && plugins.contains { $0.id == pluginId }
                && isOutdated(pluginId: pluginId, agentId: agentId)
        }
    }

    // MARK: - On-Demand Provisioning

    /// Ensures a plugin is installed and ready for a given agent.
    /// Verifies host-side files are intact (fast local FS check). If anything
    /// is missing — directory, files, or metadata — does a full reinstall.
    public func ensureReady(pluginId: String, plugin: SandboxPlugin, for agentId: String) async -> Bool {
        let agentName = SandboxAgentProvisioner.linuxName(for: agentId)
        let existing = self.plugin(id: pluginId, for: agentId)

        if existing?.status == .ready,
            hostFilesIntact(plugin: plugin, agentName: agentName)
        {
            return true
        }

        do {
            if existing != nil {
                NSLog("[SandboxPluginManager] Plugin '\(pluginId)' stale — reinstalling")
                try await uninstall(pluginId: pluginId, from: agentId)
            }
            try await install(plugin: plugin, for: agentId)
            return true
        } catch {
            NSLog("[SandboxPluginManager] On-demand provision failed for '\(pluginId)': \(error.localizedDescription)")
            return false
        }
    }

    private func hostFilesIntact(plugin: SandboxPlugin, agentName: String) -> Bool {
        let dir = hostPluginDir(agentName: agentName, pluginId: plugin.id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return false }
        guard let files = plugin.files, !files.isEmpty else { return true }
        return files.allSatisfy { (path, _) in
            fm.fileExists(atPath: dir.appendingPathComponent(path).path)
        }
    }

    // MARK: - Global Plugin Listing

    /// Returns deduplicated plugin definitions across all agents (by plugin ID).
    public func allUniquePlugins() -> [SandboxPlugin] {
        var seen = Set<String>()
        return installedPlugins.values.flatMap { $0 }
            .filter { $0.status == .ready }
            .compactMap { installed in
                guard seen.insert(installed.plugin.id).inserted else { return nil }
                return installed.plugin
            }
    }

    // MARK: - Query

    public func plugins(for agentId: String) -> [InstalledSandboxPlugin] {
        installedPlugins[agentId] ?? []
    }

    public func plugin(id: String, for agentId: String) -> InstalledSandboxPlugin? {
        installedPlugins[agentId]?.first { $0.id == id }
    }

    // MARK: - Persistence & Cleanup

    /// Remove installed-plugin records for agents that no longer exist.
    public func purgeStaleAgents(validAgentIds: Set<String>) {
        let stale = Set(installedPlugins.keys).subtracting(validAgentIds)
        guard !stale.isEmpty else { return }
        for agentId in stale {
            installedPlugins.removeValue(forKey: agentId)
            try? FileManager.default.removeItem(at: storeFile(for: agentId))
        }
    }

    @discardableResult
    public func removeAgentState(for agentId: String) -> Bool {
        let agentName = SandboxAgentProvisioner.linuxName(for: agentId)
        let storeDir = storeDirectory(for: agentId)
        let hostPluginsDir = OsaurusPaths.containerAgentDir(agentName)
            .appendingPathComponent("plugins", isDirectory: true)

        let hadInstalledState = installedPlugins.removeValue(forKey: agentId) != nil
        let progressKeys = installProgress.keys.filter { $0.hasPrefix("\(agentId):") }
        for key in progressKeys {
            installProgress.removeValue(forKey: key)
        }

        let fm = FileManager.default
        let hadStoreDir = fm.fileExists(atPath: storeDir.path)
        let hadHostPluginsDir = fm.fileExists(atPath: hostPluginsDir.path)
        if hadStoreDir {
            try? fm.removeItem(at: storeDir)
        }
        if hadHostPluginsDir {
            try? fm.removeItem(at: hostPluginsDir)
        }

        return hadInstalledState || hadStoreDir || hadHostPluginsDir || !progressKeys.isEmpty
    }

    private func storeDirectory(for agentId: String) -> URL {
        OsaurusPaths.agents()
            .appendingPathComponent(agentId, isDirectory: true)
            .appendingPathComponent("sandbox-plugins", isDirectory: true)
    }

    private func storeFile(for agentId: String) -> URL {
        storeDirectory(for: agentId).appendingPathComponent("installed.json")
    }

    private func loadAllInstalled() {
        let fm = FileManager.default
        let agentsDir = OsaurusPaths.agents()
        guard
            let agentDirs = try? fm.contentsOfDirectory(
                at: agentsDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for dir in agentDirs {
            let agentId = dir.lastPathComponent
            let file = storeFile(for: agentId)
            guard let data = try? Data(contentsOf: file),
                let plugins = try? decoder.decode([InstalledSandboxPlugin].self, from: data)
            else { continue }
            installedPlugins[agentId] = plugins
        }
    }

    private func saveInstalled(for agentId: String) {
        let dir = storeDirectory(for: agentId)
        OsaurusPaths.ensureExistsSilent(dir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let plugins = installedPlugins[agentId] ?? []
        guard let data = try? encoder.encode(plugins) else { return }
        try? data.write(to: storeFile(for: agentId), options: .atomic)
    }

    // MARK: - Helpers

    private func updateInstalled(_ plugin: InstalledSandboxPlugin, for agentId: String) {
        var list = installedPlugins[agentId] ?? []
        if let index = list.firstIndex(where: { $0.id == plugin.id }) {
            list[index] = plugin
        } else {
            list.append(plugin)
        }
        installedPlugins[agentId] = list
    }

    private func installSystemDependencies(for plugin: SandboxPlugin, agentName: String) async throws {
        try await installSystemDependencies(for: plugin, agentName: agentName, agentId: nil)
    }

    /// `installSystemDependencies` variant that knows the caller's `agentId`
    /// so it can short-circuit when `batchInstallDependencies` already
    /// seeded the deps for that agent during the post-start repair pass.
    private func installSystemDependencies(
        for plugin: SandboxPlugin,
        agentName: String,
        agentId: String?
    ) async throws {
        guard let deps = plugin.dependencies, !deps.isEmpty else { return }
        if let agentId, agentsWithSeededDeps.contains(agentId) {
            return
        }
        // `apk add` needs the Alpine CDN to resolve. The container's
        // network readiness probe normally finishes before any plugin
        // path reaches here, so this typically falls through immediately;
        // the awaited form just guards against the rare race where a
        // plugin install runs before the post-boot probe is done.
        _ = await SandboxManager.shared.awaitNetworkReady()
        let depList = deps.joined(separator: " ")
        let result = try await SandboxManager.shared.execAsRoot(
            command: "apk add --no-cache \(depList)",
            timeout: 300,
            streamToLogs: true,
            logSource: plugin.id
        )
        guard result.succeeded else {
            throw SandboxPluginError.dependencyInstallFailed(result.stderr)
        }
    }

    private func runSetupCommand(for plugin: SandboxPlugin, agentName: String, agentId: String) async throws {
        guard let setup = plugin.setup else { return }
        let env = secretsEnvironment(agentId: agentId, pluginId: plugin.id)
        let result = try await SandboxManager.shared.execAsAgent(
            agentName,
            command: setup,
            pluginName: plugin.id,
            env: env,
            timeout: 300,
            streamToLogs: true,
            logSource: plugin.id
        )
        guard result.succeeded else {
            throw SandboxPluginError.setupFailed(result.stderr)
        }
    }

    private func secretsEnvironment(agentId: String, pluginId: String) -> [String: String] {
        guard let uuid = UUID(uuidString: agentId) else { return [:] }
        return AgentSecretsKeychain.mergedSecretsEnvironment(agentId: uuid, pluginId: pluginId)
    }

    private func hostPluginDir(agentName: String, pluginId: String) -> URL {
        OsaurusPaths.containerWorkspace()
            .appendingPathComponent("agents/\(agentName)/plugins/\(pluginId)")
    }

    private func progressKey(plugin: String, agent: String) -> String {
        "\(agent):\(plugin)"
    }

    private func setProgress(key: String, _ progress: InstallProgress) {
        installProgress[key] = progress
    }

    private func clearProgress(key: String) {
        installProgress.removeValue(forKey: key)
    }

}

// MARK: - Notifications

extension Notification.Name {
    static let sandboxPluginInstalled = Notification.Name("SandboxPluginInstalled")
    static let sandboxPluginUninstalled = Notification.Name("SandboxPluginUninstalled")
}

// MARK: - Errors

public enum SandboxPluginError: Error, LocalizedError {
    case invalidPlugin(String)
    case dependencyInstallFailed(String)
    case setupFailed(String)
    case notInstalled

    public var errorDescription: String? {
        switch self {
        case .invalidPlugin(let msg): "Invalid plugin: \(msg)"
        case .dependencyInstallFailed(let msg): "Dependency install failed: \(msg)"
        case .setupFailed(let msg): "Setup failed: \(msg)"
        case .notInstalled: "Plugin is not installed"
        }
    }
}
