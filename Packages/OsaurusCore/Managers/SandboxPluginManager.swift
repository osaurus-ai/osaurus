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

        let agentName = agentLinuxName(for: agentId)
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
                    phase: "Ensuring container is running...",
                    agentId: agentId
                )
            )
            try await SandboxManager.shared.startContainer()

            setProgress(
                key: key,
                InstallProgress(
                    pluginName: plugin.name,
                    phase: "Creating agent user...",
                    agentId: agentId
                )
            )
            try await SandboxManager.shared.ensureAgentUser(agentName)
            SandboxAgentMap.register(linuxName: "agent-\(agentName)", agentId: agentId)

            if let deps = plugin.dependencies, !deps.isEmpty {
                setProgress(
                    key: key,
                    InstallProgress(
                        pluginName: plugin.name,
                        phase: "Installing system packages...",
                        agentId: agentId
                    )
                )
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
                // Write directly to the VirtioFS host mount — instant visibility in the container
                let hostPluginDir = OsaurusPaths.containerWorkspace()
                    .appendingPathComponent("agents/\(agentName)/plugins/\(plugin.id)")
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

            if let secrets = plugin.secrets, !secrets.isEmpty {
                setProgress(
                    key: key,
                    InstallProgress(
                        pluginName: plugin.name,
                        phase: "Configuring secrets...",
                        agentId: agentId
                    )
                )
                // Secrets are prompted in the UI and stored in Keychain.
                // They'll be injected as env vars at exec time via ToolSecretsKeychain.
            }

            if let setup = plugin.setup {
                setProgress(
                    key: key,
                    InstallProgress(
                        pluginName: plugin.name,
                        phase: "Running setup...",
                        agentId: agentId
                    )
                )
                let result = try await SandboxManager.shared.execAsAgent(
                    agentName,
                    command: setup,
                    pluginName: plugin.id,
                    timeout: 300,
                    streamToLogs: true,
                    logSource: plugin.id
                )
                guard result.succeeded else {
                    throw SandboxPluginError.setupFailed(result.stderr)
                }
            }

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

        let agentName = agentLinuxName(for: agentId)
        let pluginDir = OsaurusPaths.inContainerPluginDir(agentName, pluginId)

        if await SandboxManager.shared.status().isRunning {
            _ = try? await SandboxManager.shared.execAsAgent(
                agentName,
                command: "rm -rf '\(pluginDir)'"
            )
        }

        let hostDir = OsaurusPaths.containerAgentDir(agentName)
            .appendingPathComponent("plugins/\(pluginId)", isDirectory: true)
        try? FileManager.default.removeItem(at: hostDir)

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

    private func progressKey(plugin: String, agent: String) -> String {
        "\(agent):\(plugin)"
    }

    private func setProgress(key: String, _ progress: InstallProgress) {
        installProgress[key] = progress
    }

    private func clearProgress(key: String) {
        installProgress.removeValue(forKey: key)
    }

    private func agentLinuxName(for agentId: String) -> String {
        let name =
            agentId
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return name.isEmpty ? "agent" : name
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
