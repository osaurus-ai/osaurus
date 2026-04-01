//
//  PluginManager.swift
//  osaurus
//
//  Manages loading and lifecycle of external plugins.
//

import Foundation
import Darwin
import Combine
import CryptoKit
import Security
import OsaurusRepository

@MainActor
final class PluginManager {
    static let shared = PluginManager()

    struct LoadedPlugin: @unchecked Sendable {
        let plugin: ExternalPlugin
        let handle: UnsafeMutableRawPointer
        let tools: [ExternalTool]
        let skills: [Skill]
        let routes: [PluginManifest.RouteSpec]
        let webConfig: PluginManifest.WebSpec?
        let readmePath: URL?
        let changelogPath: URL?
    }

    /// Represents a plugin that failed to load
    struct FailedPlugin: Sendable {
        let pluginId: String
        let error: String
    }

    /// Error type for plugin loading failures
    struct PluginLoadError: Error, CustomStringConvertible, Sendable {
        let message: String
        var description: String { message }

        static let consentRequiredPrefix = "consent_required:"
    }

    private(set) var plugins: [LoadedPlugin] = []
    private var loadedPluginPaths: Set<String> = []

    /// Plugins that failed to load, keyed by plugin ID
    private(set) var failedPlugins: [String: FailedPlugin] = [:]

    private var tunnelObserver: AnyCancellable?

    /// Serializes reload operations to prevent concurrent `performPluginScan`
    /// calls from overwriting and deallocating each other's host contexts.
    private var activeReloadTask: Task<Void, Never>?

    private init() {}

    /// Returns the load error for a specific plugin, if any
    func loadError(for pluginId: String) -> String? {
        return failedPlugins[pluginId]?.error
    }

    /// Look up a loaded plugin by its ID (used by HTTP route dispatch)
    func loadedPlugin(for pluginId: String) -> LoadedPlugin? {
        return plugins.first { $0.plugin.id == pluginId }
    }

    // MARK: - Loading

    /// Result of heavy plugin scanning performed on a background thread.
    private struct PluginScanResult: @unchecked Sendable {
        let allURLs: [URL]
        let verificationFailures: [String: String]
        let loadResults: [(url: URL, result: Result<LoadedPlugin, PluginLoadError>)]
    }

    /// Scans the tools directory and loads all plugins found.
    /// Heavy work (filesystem scanning, SHA256 verification, dlopen) runs on a background thread.
    /// When `forceReload` is true, all existing plugins are unloaded first so every
    /// dylib is re-opened from disk (used by the `toolsReload` notification for hot-reload).
    func loadAll(forceReload: Bool = false) async {
        if let task = activeReloadTask {
            await task.value
            if !forceReload { return }
            // If another task was queued by a concurrent caller while we waited,
            // just wait for that one to finish instead of starting a third.
            if let newTask = activeReloadTask {
                await newTask.value
                return
            }
        }

        let task = Task {
            await _loadAll(forceReload: forceReload)
        }
        activeReloadTask = task
        await task.value

        if activeReloadTask == task {
            activeReloadTask = nil
        }
    }

    private func _loadAll(forceReload: Bool = false) async {
        Self.ensureToolsDirectoryExists()

        // Clear previous failures before scanning
        failedPlugins.removeAll()

        if forceReload {
            for loaded in plugins {
                ToolRegistry.shared.unregister(names: loaded.tools.map { $0.name })
                if !loaded.skills.isEmpty {
                    SkillManager.shared.unregisterPluginSkills(pluginId: loaded.plugin.id)
                }
                await loaded.plugin.shutdown()
                PluginHostContext.getContext(for: loaded.plugin.id)?.teardown()
                // Do not dlclose here. The plugin is already unloaded from the
                // registry, but dlclose on macOS ARM64 causes stale PAC
                // signatures if the same path is ever reloaded.
            }
            plugins.removeAll()
            loadedPluginPaths.removeAll()
        }

        // Capture current state needed for background work
        let alreadyLoadedPaths = self.loadedPluginPaths

        // Heavy work on background thread: filesystem scan, SHA256 verify, dlopen, plugin init
        let scanResult = await Task.detached(priority: .userInitiated) {
            Self.performPluginScan(alreadyLoadedPaths: alreadyLoadedPaths)
        }.value

        // --- Everything below runs on main thread (registry & state mutations) ---

        for (pluginId, error) in scanResult.verificationFailures {
            failedPlugins[pluginId] = FailedPlugin(pluginId: pluginId, error: error)
        }

        let currentPaths = Set(scanResult.allURLs.map { $0.path })

        // Unload removed plugins
        var remaining: [LoadedPlugin] = []
        var removedSomething = false

        for loaded in plugins {
            if currentPaths.contains(loaded.plugin.bundlePath) {
                remaining.append(loaded)
            } else {
                ToolRegistry.shared.unregister(names: loaded.tools.map { $0.name })
                if !loaded.skills.isEmpty {
                    SkillManager.shared.unregisterPluginSkills(pluginId: loaded.plugin.id)
                }
                await loaded.plugin.shutdown()
                PluginHostContext.getContext(for: loaded.plugin.id)?.teardown()
                // Do not dlclose here. The plugin is already unloaded from the
                // registry, but dlclose on macOS ARM64 causes stale PAC
                // signatures if the same path is ever reloaded.
                loadedPluginPaths.remove(loaded.plugin.bundlePath)
                removedSomething = true
            }
        }
        plugins = remaining

        // Register newly loaded plugins
        var loadedNew = false
        for entry in scanResult.loadResults {
            switch entry.result {
            case .success(let loaded):
                plugins.append(loaded)
                loadedPluginPaths.insert(entry.url.path)
                loadedNew = true

                // Register tools
                for tool in loaded.tools {
                    ToolRegistry.shared.registerPluginTool(tool)
                }

                // Register plugin skills
                for skill in loaded.skills {
                    SkillManager.shared.registerPluginSkill(skill)
                }

                // Clear any previous failure for this plugin
                failedPlugins.removeValue(forKey: loaded.plugin.id)

            case .failure(let error):
                let pluginId = Self.extractPluginId(from: entry.url)
                failedPlugins[pluginId] = FailedPlugin(pluginId: pluginId, error: error.message)
            }
        }

        if loadedNew || removedSomething || !failedPlugins.isEmpty {
            NotificationCenter.default.post(name: .toolsListChanged, object: nil)
        }

        migrateGlobalConfigToPerAgent()
        notifyNewPluginsWithAgentConfig(from: scanResult)
        observeTunnelStatus()
        sendCurrentTunnelURLToNewPlugins(from: scanResult)
    }

    /// For each newly loaded plugin, re-deliver its config for every agent.
    /// `initPlugin` runs before any agent is wired up, so `configGet` falls
    /// back to `Agent.defaultId` and misses secrets stored under custom agents.
    /// Sending the batch here (for all agents) corrects that.
    private func notifyNewPluginsWithAgentConfig(from scanResult: PluginScanResult) {
        let agents = AgentManager.shared.agents

        for entry in scanResult.loadResults {
            guard case .success(let loaded) = entry.result else { continue }
            let pluginId = loaded.plugin.id
            guard let configSpec = loaded.plugin.manifest.capabilities.config,
                PluginHostContext.getContext(for: pluginId) != nil
            else { continue }

            let allFieldKeys = Set(configSpec.sections.flatMap { $0.fields.map { $0.key } })

            for agent in agents {
                let agentId = agent.id
                var values = ToolSecretsKeychain.getAllSecrets(for: pluginId, agentId: agentId)

                for section in configSpec.sections {
                    for field in section.fields {
                        if values[field.key] == nil, field.type != .readonly, field.type != .status,
                            let val = ToolSecretsKeychain.getSecret(id: field.key, for: pluginId, agentId: agentId)
                        {
                            values[field.key] = val
                        }
                        if values[field.key] == nil, let def = field.default {
                            values[field.key] = def.stringValue
                        }
                        if let connKey = field.connected_when, values[connKey] == nil,
                            let val = ToolSecretsKeychain.getSecret(id: connKey, for: pluginId, agentId: agentId)
                        {
                            values[connKey] = val
                        }
                    }
                }

                let changes: [(key: String, value: String)] = values.compactMap { key, value in
                    allFieldKeys.contains(key) ? (key: key, value: value) : nil
                }
                guard !changes.isEmpty else { continue }
                loaded.plugin.notifyConfigBatch(changes, agentId: agentId)
            }
        }
    }

    // MARK: - One-Time Migration (global config → per-agent)

    private static var hasMigrated = false

    /// Copies legacy global keychain entries (`{pluginId}.{key}`) into
    /// agent-scoped entries (`{agentId}.{pluginId}.{key}`) for every agent
    /// that has the plugin enabled, then removes the legacy entries.
    private func migrateGlobalConfigToPerAgent() {
        guard !Self.hasMigrated else { return }
        Self.hasMigrated = true

        let agents = AgentManager.shared.agents
        let pluginIds = plugins.map { $0.plugin.id }

        for pluginId in pluginIds {
            let legacySecrets = ToolSecretsKeychain.legacySecrets(for: pluginId)
            guard !legacySecrets.isEmpty else { continue }

            let destinations = agents.map { $0.id }

            for agentId in destinations {
                for (key, value) in legacySecrets {
                    // Only copy if the agent doesn't already have a value for this key.
                    if ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: agentId) == nil {
                        ToolSecretsKeychain.saveSecret(value, id: key, for: pluginId, agentId: agentId)
                    }
                }
            }

            ToolSecretsKeychain.deleteLegacySecrets(for: pluginId)
        }
    }

    // MARK: - Tunnel URL Propagation

    /// Observes relay tunnel status changes and propagates the tunnel URL
    /// to plugins that declare routes, so they can register webhooks with
    /// external services (e.g. Telegram).
    private func observeTunnelStatus() {
        guard tunnelObserver == nil else { return }
        tunnelObserver = RelayTunnelManager.shared.$agentStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses in
                self?.handleTunnelStatusChange(statuses)
            }
    }

    private func handleTunnelStatusChange(_ statuses: [UUID: AgentRelayStatus]) {
        for loaded in plugins where !loaded.routes.isEmpty {
            for (agentId, status) in statuses {
                let tunnelURL: String? = if case .connected(let url) = status { url } else { nil }

                let storedValue = ToolSecretsKeychain.getSecret(
                    id: "tunnel_url",
                    for: loaded.plugin.id,
                    agentId: agentId
                )
                guard storedValue != tunnelURL else { continue }

                pushTunnelURL(tunnelURL, to: loaded, agentId: agentId)
            }
        }
    }

    /// Delivers the current tunnel URL to freshly loaded plugins that declare
    /// routes, bypassing the keychain dedup so that newly-loaded plugins
    /// always receive the URL when the relay is already connected.
    private func sendCurrentTunnelURLToNewPlugins(from scanResult: PluginScanResult) {
        let statuses = RelayTunnelManager.shared.agentStatuses

        for entry in scanResult.loadResults {
            guard case .success(let loaded) = entry.result, !loaded.routes.isEmpty else { continue }

            for (agentId, status) in statuses {
                guard case .connected(let url) = status else { continue }
                pushTunnelURL(url, to: loaded, agentId: agentId)
            }
        }
    }

    private func pushTunnelURL(_ url: String?, to loaded: LoadedPlugin, agentId: UUID) {
        let pluginId = loaded.plugin.id

        if let url {
            ToolSecretsKeychain.saveSecret(url, id: "tunnel_url", for: pluginId, agentId: agentId)
        } else {
            ToolSecretsKeychain.deleteSecret(id: "tunnel_url", for: pluginId, agentId: agentId)
        }

        NotificationCenter.default.post(
            name: .pluginConfigDidChange,
            object: nil,
            userInfo: ["pluginId": pluginId, "key": "tunnel_url", "value": url ?? ""]
        )

        loaded.plugin.notifyConfigChanged(
            key: "tunnel_url",
            value: url ?? "",
            agentId: agentId
        )
    }

    // MARK: - Artifact Handler Notifications

    /// Notifies all plugins that declared `artifact_handler: true` about a shared artifact.
    /// Each plugin is invoked asynchronously so no single handler blocks the caller or others.
    func notifyArtifactHandlers(artifact: SharedArtifact) {
        let payload = PluginHostContext.serializeArtifactEvent(artifact: artifact)
        for loaded in plugins {
            guard loaded.plugin.manifest.capabilities.artifact_handler == true else { continue }
            guard loaded.plugin.abiVersion >= 2 else { continue }
            Task {
                _ = try? await loaded.plugin.invoke(
                    type: "artifact",
                    id: "share",
                    payload: payload
                )
            }
        }
    }

    // MARK: - Background Scanning & Loading (nonisolated)

    /// Performs the heavy plugin scanning work on a background thread.
    /// Scans filesystem for dylibs, verifies checksums, loads plugins via dlopen.
    nonisolated private static func performPluginScan(
        alreadyLoadedPaths: Set<String>
    ) -> PluginScanResult {
        let (urls, verificationFailures) = toolsDirectoryURLsWithFailures()

        var loadResults: [(url: URL, result: Result<LoadedPlugin, PluginLoadError>)] = []
        for url in urls {
            if alreadyLoadedPaths.contains(url.path) { continue }
            let pluginId = extractPluginId(from: url)
            writeLoadingMarker(pluginId: pluginId)
            let result = loadPluginWithError(at: url)
            clearLoadingMarker()
            loadResults.append((url: url, result: result))
        }

        return PluginScanResult(
            allURLs: urls,
            verificationFailures: verificationFailures,
            loadResults: loadResults
        )
    }

    /// Extracts the plugin ID from a dylib URL path
    /// Expected path: .../Tools/{pluginId}/{version}/plugin.dylib
    nonisolated private static func extractPluginId(from url: URL) -> String {
        // Go up from dylib -> version dir -> plugin dir
        let versionDir = url.deletingLastPathComponent()
        let pluginDir = versionDir.deletingLastPathComponent()
        return pluginDir.lastPathComponent
    }

    /// Loads a single plugin from a dylib URL via dlopen + C ABI handshake.
    /// Tries v2 entry point first (with host API injection), then falls back to v1.
    nonisolated private static func loadPluginWithError(at url: URL) -> Result<LoadedPlugin, PluginLoadError> {
        let flags = RTLD_NOW | RTLD_LOCAL
        guard let handle = dlopen(url.path, Int32(flags)) else {
            let errorMsg: String
            if let err = dlerror() {
                errorMsg = "Failed to load library: \(String(cString: err))"
            } else {
                errorMsg = "Failed to load library (unknown error)"
            }
            print("[Osaurus] dlopen failed for \(url.path): \(errorMsg)")
            return .failure(PluginLoadError(message: errorMsg))
        }

        // Try v2 entry point first, then fall back to v1
        let api: osr_plugin_api
        let abiVersion: UInt32
        var hostContext: PluginHostContext?

        if let v2sym = dlsym(handle, "osaurus_plugin_entry_v2") {
            // v2 path: create host context and pass to plugin
            // We need the plugin ID to scope the host context. We'll use the
            // directory name as a preliminary ID, then confirm from the manifest.
            let preliminaryId = extractPluginId(from: url)

            let ctx: PluginHostContext
            do {
                ctx = try PluginHostContext(pluginId: preliminaryId)
            } catch {
                let errorMsg = "Failed to create host context: \(error.localizedDescription)"
                print("[Osaurus] \(errorMsg) for \(url.lastPathComponent)")
                dlclose(handle)
                return .failure(PluginLoadError(message: errorMsg))
            }

            PluginHostContext.currentContext = ctx
            PluginHostContext.setActivePlugin(preliminaryId)
            let hostAPIPtr = ctx.buildHostAPI()
            let entryFn = unsafeBitCast(v2sym, to: osr_plugin_entry_v2_t.self)
            let apiRawPtr = entryFn(UnsafeRawPointer(hostAPIPtr))
            PluginHostContext.clearActivePlugin()
            PluginHostContext.currentContext = nil

            guard let apiRawPtr else {
                let errorMsg = "Plugin v2 entry returned null API"
                print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
                ctx.teardown()
                dlclose(handle)
                return .failure(PluginLoadError(message: errorMsg))
            }

            let apiPtr = apiRawPtr.assumingMemoryBound(to: osr_plugin_api.self)
            api = apiPtr.pointee
            abiVersion = max(api.version, 2)
            hostContext = ctx

            PluginHostContext.setContext(ctx, for: preliminaryId)
            print("[Osaurus] Loaded v2 plugin from \(url.lastPathComponent)")
        } else if let v1sym = dlsym(handle, "osaurus_plugin_entry") {
            // v1 path: no host API
            let entryFn = unsafeBitCast(v1sym, to: osr_plugin_entry_t.self)
            guard let apiRawPtr = entryFn() else {
                let errorMsg = "Plugin entry returned null API"
                print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
                dlclose(handle)
                return .failure(PluginLoadError(message: errorMsg))
            }

            let apiPtr = apiRawPtr.assumingMemoryBound(to: osr_plugin_api.self)
            api = apiPtr.pointee
            abiVersion = 1
        } else {
            let errorMsg = "Missing plugin entry point (osaurus_plugin_entry or osaurus_plugin_entry_v2)"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }

        // Initialize Plugin
        guard let initFn = api.`init` else {
            let errorMsg = "Plugin missing init function"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            hostContext?.teardown()
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }

        if let hostContext {
            PluginHostContext.currentContext = hostContext
            PluginHostContext.setActivePlugin(hostContext.pluginId)
        }
        defer {
            PluginHostContext.clearActivePlugin()
            PluginHostContext.currentContext = nil
        }
        let ctx = initFn()

        guard let ctx else {
            let errorMsg = "Plugin initialization failed"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            hostContext?.teardown()
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }

        // Get Manifest
        guard let getManifest = api.get_manifest, let jsonPtr = getManifest(ctx) else {
            let errorMsg = "Plugin failed to return manifest"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            api.destroy?(ctx)
            hostContext?.teardown()
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }
        let jsonString = String(cString: jsonPtr)
        api.free_string?(jsonPtr)

        // Parse Manifest
        guard let data = jsonString.data(using: String.Encoding.utf8),
            let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
        else {
            let errorMsg = "Failed to parse plugin manifest"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            api.destroy?(ctx)
            hostContext?.teardown()
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }

        // If the manifest plugin_id differs from the directory-derived ID,
        // re-register the host context under the canonical ID.
        if let hc = hostContext, manifest.plugin_id != hc.pluginId {
            PluginHostContext.rekeyContext(from: hc.pluginId, to: manifest.plugin_id)
        }

        let plugin = ExternalPlugin(
            handle: handle,
            api: api,
            ctx: ctx,
            manifest: manifest,
            path: url.path,
            abiVersion: abiVersion
        )
        let tools = (manifest.capabilities.tools ?? []).map { ExternalTool(plugin: plugin, spec: $0) }
        let skills = loadPluginSkills(from: url, pluginId: manifest.plugin_id)
        let routes = manifest.capabilities.routes ?? []
        let webConfig = manifest.capabilities.web

        let versionDir = url.deletingLastPathComponent()
        let readmePath = resolveDocFile(named: "README.md", in: versionDir)
        let changelogPath = resolveDocFile(named: "CHANGELOG.md", in: versionDir)

        return .success(
            LoadedPlugin(
                plugin: plugin,
                handle: handle,
                tools: tools,
                skills: skills,
                routes: routes,
                webConfig: webConfig,
                readmePath: readmePath,
                changelogPath: changelogPath
            )
        )
    }

    /// Finds a documentation file (case-insensitive) in the plugin's version directory.
    nonisolated private static func resolveDocFile(named filename: String, in directory: URL) -> URL? {
        let path = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: path.path) {
            return path
        }
        let lower = directory.appendingPathComponent(filename.lowercased())
        if FileManager.default.fileExists(atPath: lower.path) {
            return lower
        }
        return nil
    }

    /// Scans the plugin install directory for SKILL.md files and parses them into Skills
    nonisolated private static func loadPluginSkills(from dylibURL: URL, pluginId: String) -> [Skill] {
        let versionDir = dylibURL.deletingLastPathComponent()
        let skillsDir = versionDir.appendingPathComponent("skills", isDirectory: true)

        var results: [Skill] = []

        // Check for skills/ directory
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: skillsDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return results
        }

        guard
            let files = try? fm.contentsOfDirectory(
                at: skillsDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return results
        }

        for file in files {
            guard file.lastPathComponent.uppercased().hasSuffix("SKILL.MD") else { continue }
            do {
                let content = try String(contentsOf: file, encoding: .utf8)
                var skill = try Skill.parseAnyFormat(from: content)
                // Set the pluginId to link the skill to its plugin
                skill = Skill(
                    id: skill.id,
                    name: skill.name,
                    description: skill.description,
                    version: skill.version,
                    author: skill.author,
                    category: skill.category,
                    enabled: skill.enabled,
                    instructions: skill.instructions,
                    isBuiltIn: false,
                    createdAt: skill.createdAt,
                    updatedAt: skill.updatedAt,
                    references: skill.references,
                    assets: skill.assets,
                    directoryName: skill.directoryName,
                    pluginId: pluginId
                )
                results.append(skill)
                NSLog("[Osaurus] Loaded skill '\(skill.name)' from plugin \(pluginId)")
            } catch {
                NSLog("[Osaurus] Failed to parse SKILL.md from plugin \(pluginId): \(error)")
            }
        }

        return results
    }

    // MARK: - Consent management

    /// Plugin IDs that failed to load because the user has not yet consented.
    var pluginsAwaitingConsent: [String] {
        failedPlugins.values
            .filter { $0.error.hasPrefix(PluginLoadError.consentRequiredPrefix) }
            .map { $0.pluginId }
    }

    /// Grants user consent for a plugin, allowing it to load on the next scan.
    /// Writes a `.user_consent` marker to the plugin's current version directory.
    func grantConsent(pluginId: String) throws {
        guard let versionDir = Self.resolveCurrentVersionDir(pluginId: pluginId) else {
            throw PluginLoadError(message: "No version directory found for \(pluginId)")
        }
        let consentURL = versionDir.appendingPathComponent(".user_consent", isDirectory: false)
        try Data().write(to: consentURL)
    }

    // MARK: - Tools directory helpers

    /// Resolves the current version directory for a plugin via the "current" symlink
    /// or by picking the highest installed semver.
    nonisolated private static func resolveCurrentVersionDir(pluginId: String) -> URL? {
        let fm = FileManager.default
        let pluginDir = toolsRootDirectory().appendingPathComponent(pluginId, isDirectory: true)
        let currentLink = pluginDir.appendingPathComponent("current", isDirectory: false)

        if let dest = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) {
            return pluginDir.appendingPathComponent(dest, isDirectory: true)
        }
        guard
            let entries = try? fm.contentsOfDirectory(
                at: pluginDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }
        return
            entries
            .compactMap { url -> (SemanticVersion, URL)? in
                guard url.hasDirectoryPath, let v = SemanticVersion.parse(url.lastPathComponent) else { return nil }
                return (v, url)
            }
            .sorted { $0.0 > $1.0 }
            .first?.1
    }

    nonisolated static func toolsRootDirectory() -> URL {
        return ToolsPaths.toolsRootDirectory()
    }

    nonisolated static func ensureToolsDirectoryExists() {
        let root = toolsRootDirectory()
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    nonisolated static func toolsDirectoryURLs() -> [URL] {
        return toolsDirectoryURLsWithFailures().urls
    }

    // MARK: - Plugin Quarantine

    private nonisolated static func currentlyLoadingURL() -> URL {
        toolsRootDirectory().appendingPathComponent(".currently_loading", isDirectory: false)
    }

    private nonisolated static func quarantineURL() -> URL {
        toolsRootDirectory().appendingPathComponent(".quarantine", isDirectory: false)
    }

    nonisolated static func quarantinedPluginIds() -> Set<String> {
        guard let data = try? Data(contentsOf: quarantineURL()),
            let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(ids)
    }

    private nonisolated static func addToQuarantine(_ pluginId: String) {
        var ids = quarantinedPluginIds()
        ids.insert(pluginId)
        if let data = try? JSONEncoder().encode(Array(ids)) {
            try? data.write(to: quarantineURL())
        }
        NSLog("[Osaurus] Quarantined plugin '%@' after crash during load", pluginId)
    }

    nonisolated static func clearQuarantine() {
        try? FileManager.default.removeItem(at: quarantineURL())
        try? FileManager.default.removeItem(at: currentlyLoadingURL())
    }

    /// If a `.currently_loading` marker was left behind by a crash during
    /// dlopen/init, quarantine that plugin so it is skipped on future launches.
    private nonisolated static func promoteStaleLoadingMarker() {
        let markerURL = currentlyLoadingURL()
        guard let data = try? Data(contentsOf: markerURL),
            let pluginId = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !pluginId.isEmpty
        else { return }
        addToQuarantine(pluginId)
        try? FileManager.default.removeItem(at: markerURL)
    }

    private nonisolated static func writeLoadingMarker(pluginId: String) {
        try? pluginId.data(using: .utf8)?.write(to: currentlyLoadingURL())
    }

    private nonisolated static func clearLoadingMarker() {
        try? FileManager.default.removeItem(at: currentlyLoadingURL())
    }

    /// Returns dylib URLs to load and a dictionary of verification failures (pluginId -> error message)
    nonisolated static func toolsDirectoryURLsWithFailures() -> (urls: [URL], failures: [String: String]) {
        promoteStaleLoadingMarker()

        let fm = FileManager.default
        let root = toolsRootDirectory()
        var dylibURLs: [URL] = []
        var failures: [String: String] = [:]
        let quarantined = quarantinedPluginIds()

        guard
            let pluginDirs = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return (dylibURLs, failures)
        }

        for pluginDir in pluginDirs where pluginDir.hasDirectoryPath {
            let pluginId = pluginDir.lastPathComponent

            if quarantined.contains(pluginId) {
                failures[pluginId] = "Plugin quarantined after a crash during load — run `osaurus tools reset` to retry"
                continue
            }

            let currentLink = pluginDir.appendingPathComponent("current", isDirectory: false)
            var versionDir: URL?
            if let dest = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) {
                versionDir = pluginDir.appendingPathComponent(dest, isDirectory: true)
            } else {
                // Fallback: pick highest SemVer
                if let entries = try? fm.contentsOfDirectory(
                    at: pluginDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    let versions: [(SemanticVersion, URL)] = entries.compactMap { url in
                        guard url.hasDirectoryPath else { return nil }
                        guard let v = SemanticVersion.parse(url.lastPathComponent) else { return nil }
                        return (v, url)
                    }
                    versionDir = versions.sorted(by: { $0.0 > $1.0 }).first?.1
                }
            }

            guard let vdir = versionDir else {
                // No valid version directory found
                failures[pluginId] = "No valid version directory found"
                continue
            }

            var foundDylib = false
            if let enumerator = fm.enumerator(
                at: vdir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension == "dylib" {
                        foundDylib = true
                        let verifyResult = verifyDylibBeforeLoadWithError(fileURL)
                        switch verifyResult {
                        case .success:
                            dylibURLs.append(fileURL)
                        case .failure(let error):
                            failures[pluginId] = error.message
                        }
                    }
                }
            }

            if !foundDylib {
                failures[pluginId] = "No dylib file found in plugin directory"
            }
        }
        return (dylibURLs, failures)
    }

    /// Verifies a dylib's integrity, code signature (release only), and user consent
    /// before allowing it to load. DEBUG builds skip all verification for dev convenience.
    nonisolated private static func verifyDylibBeforeLoadWithError(_ dylibURL: URL) -> Result<Void, PluginLoadError> {
        #if DEBUG
            return .success(())
        #else
            let fm = FileManager.default
            let versionDir = dylibURL.deletingLastPathComponent()
            let receiptURL = versionDir.appendingPathComponent("receipt.json", isDirectory: false)

            guard fm.fileExists(atPath: receiptURL.path) else {
                return .failure(PluginLoadError(message: "Missing receipt.json - plugin cannot be verified"))
            }

            guard let data = try? Data(contentsOf: receiptURL) else {
                return .failure(PluginLoadError(message: "Failed to read receipt.json"))
            }

            guard let receipt = try? JSONDecoder().decode(PluginReceipt.self, from: data) else {
                return .failure(PluginLoadError(message: "Failed to parse receipt.json"))
            }

            guard let dylibData = try? Data(contentsOf: dylibURL) else {
                return .failure(PluginLoadError(message: "Failed to read plugin library file"))
            }

            let digest = CryptoKit.SHA256.hash(data: dylibData)
            let sha = Data(digest).map { String(format: "%02x", $0) }.joined()

            if sha.lowercased() != receipt.dylib_sha256.lowercased() {
                return .failure(
                    PluginLoadError(
                        message: "Checksum verification failed - plugin file may be corrupted or tampered with"
                    )
                )
            }

            if let codesignError = verifyCodeSignature(of: dylibURL) {
                return .failure(codesignError)
            }

            let consentURL = versionDir.appendingPathComponent(".user_consent", isDirectory: false)
            guard fm.fileExists(atPath: consentURL.path) else {
                return .failure(
                    PluginLoadError(
                        message: "\(PluginLoadError.consentRequiredPrefix) Plugin has not been approved for loading"
                    )
                )
            }

            return .success(())
        #endif
    }

    /// Checks the Apple code signature of a dylib using the Security framework.
    /// Returns nil on success or a PluginLoadError describing the failure.
    nonisolated private static func verifyCodeSignature(of url: URL) -> PluginLoadError? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return PluginLoadError(
                message: "Failed to create code reference for signature verification (OSStatus \(createStatus))"
            )
        }

        let checkStatus = SecStaticCodeCheckValidity(code, SecCSFlags(), nil)
        guard checkStatus == errSecSuccess else {
            return PluginLoadError(
                message:
                    "Plugin code signature is invalid or missing - plugins must be signed with a Developer ID (OSStatus \(checkStatus))"
            )
        }

        return nil
    }
}
