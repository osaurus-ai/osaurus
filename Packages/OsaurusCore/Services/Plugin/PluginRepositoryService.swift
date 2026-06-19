//
//  PluginRepositoryService.swift
//  osaurus
//
//  Manages plugin repository state, background refresh, and version comparison for updates.
//

import Combine
import Foundation
import OsaurusRepository

/// Represents a plugin's display metadata, installation state, and available updates.
/// Self-contained -- views use properties directly without reaching into PluginSpec.
struct PluginState: Identifiable, Equatable {
    let pluginId: String
    var id: String { pluginId }

    // Display metadata (resolved from repo spec or loaded plugin manifest)
    let name: String?
    let pluginDescription: String?
    let authors: [String]?
    let license: String?
    let capabilities: RegistryCapabilities?

    // Installation & update state
    var installedVersion: SemanticVersion?
    var latestVersion: SemanticVersion?
    var isInstalling: Bool = false
    /// Error message if the plugin failed to load (installed but not functional)
    var loadError: String?

    /// Display name, falling back to the plugin ID.
    var displayName: String { name ?? pluginId }

    var hasUpdate: Bool {
        guard let installed = installedVersion, let latest = latestVersion else { return false }
        return latest > installed
    }

    var isInstalled: Bool {
        installedVersion != nil
    }

    /// Returns true if the plugin is installed but failed to load
    var hasLoadError: Bool {
        isInstalled && loadError != nil
    }
}

@MainActor
final class PluginRepositoryService: ObservableObject {
    static let shared = PluginRepositoryService()

    /// All plugins from the repository with their installation state
    @Published private(set) var plugins: [PluginState] = []

    /// Whether a refresh is currently in progress
    @Published private(set) var isRefreshing: Bool = false

    /// Last refresh timestamp
    @Published private(set) var lastRefreshed: Date?

    /// Number of plugins with available updates
    @Published private(set) var updatesAvailableCount: Int = 0

    /// Error from last refresh attempt
    @Published private(set) var lastError: String?

    /// Plugin ID that needs secrets configuration after installation (triggers secrets sheet in UI)
    @Published var pendingSecretsPlugin: String?

    /// Interval for background refresh (4 hours)
    private let refreshInterval: TimeInterval = 4 * 60 * 60

    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Listen for tools list changes to update installed state
        NotificationCenter.default.publisher(for: .toolsListChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.updateInstalledState()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Start the background refresh timer
    func startBackgroundRefresh() {
        // Populate installed plugins from disk before any network call, then refresh.
        Task {
            await loadInstalledPluginsFromDisk()
            await refresh()
        }

        // Schedule periodic refresh
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    /// Stop the background refresh timer
    func stopBackgroundRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Manually refresh the repository
    func refresh() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        lastError = nil

        // Ensure installed plugins are visible immediately, before any network call
        if plugins.isEmpty {
            await loadInstalledPluginsFromDisk()
        }

        // Run git operations on background thread
        let gitSuccess = await Task.detached(priority: .utility) {
            CentralRepositoryManager.shared.refresh()
        }.value

        if !gitSuccess {
            lastError = "Unable to reach plugin repository"
        }

        // Parse specs and resolve installed state on background threads (both read
        // from local cache / disk even if git failed).
        let specs = await Task.detached(priority: .utility) {
            CentralRepositoryManager.shared.listAllSpecs()
        }.value
        let snapshot = await Task.detached(priority: .utility) {
            InstalledPluginsStore.shared.snapshot()
        }.value

        // Update state (already on main actor), merging with installed plugins
        updatePlugins(from: specs, snapshot: snapshot)
        lastRefreshed = Date()
        isRefreshing = false

        // Check for updates and notify if any
        if updatesAvailableCount > 0 {
            let outdatedNames = plugins.filter { $0.hasUpdate }.map { $0.displayName }
            NotificationService.shared.postPluginUpdatesAvailable(
                count: updatesAvailableCount,
                pluginNames: outdatedNames
            )
        }
    }

    /// Install a plugin by ID
    func install(pluginId: String) async throws {
        try await performInstall(pluginId: pluginId)
        checkForPendingSecrets(pluginId: pluginId)
    }

    /// Upgrade a plugin to the latest version
    func upgrade(pluginId: String) async throws {
        guard let latestVersion = plugins.first(where: { $0.pluginId == pluginId })?.latestVersion else {
            throw PluginInstallError.specNotFound(pluginId)
        }
        try await performInstall(pluginId: pluginId, version: latestVersion)
    }

    /// Uninstall a plugin by ID
    func uninstall(pluginId: String) async throws {
        let pluginDir = PluginInstallManager.toolsPluginDirectory(pluginId: pluginId)
        // Recursive directory deletion is synchronous file I/O that can block for
        // seconds on a large plugin or a busy filesystem. Run it off the main
        // actor so the uninstall doesn't hang the UI.
        try await Task.detached(priority: .userInitiated) {
            if FileManager.default.fileExists(atPath: pluginDir.path) {
                try FileManager.default.removeItem(at: pluginDir)
            }
        }.value

        ToolSecretsKeychain.deleteAllSecretsAllAgents(for: pluginId)
        ToolSecretsKeychain.deleteAllSecrets(for: pluginId)
        await SkillManager.shared.unregisterPluginSkills(pluginId: pluginId)

        // Update state immediately so the UI reflects uninstallation
        if let index = plugins.firstIndex(where: { $0.pluginId == pluginId }) {
            plugins[index].installedVersion = nil
            plugins[index].loadError = nil
        }

        // Reload plugins (unregisters tools from ToolRegistry, posts .toolsListChanged)
        await PluginManager.shared.loadAll()
        updateUpdatesCount()
    }

    // MARK: - Install / Upgrade Helpers

    /// Safely mutate the PluginState for a given ID.
    /// Re-looks up the index each time, which is necessary because the `plugins` array
    /// can be reordered by `updateInstalledState()` during `await` suspension points.
    private func updatePlugin(id: String, _ mutate: (inout PluginState) -> Void) {
        guard let index = plugins.firstIndex(where: { $0.pluginId == id }) else { return }
        mutate(&plugins[index])
    }

    /// Shared implementation for install and upgrade.
    /// Downloads the plugin, reloads the plugin manager, and updates local state.
    private func performInstall(pluginId: String, version: SemanticVersion? = nil) async throws {
        guard plugins.contains(where: { $0.pluginId == pluginId }) else {
            throw PluginInstallError.specNotFound(pluginId)
        }

        updatePlugin(id: pluginId) { $0.isInstalling = true }

        do {
            let result = try await PluginInstallManager.shared.install(
                pluginId: pluginId,
                preferredVersion: version
            )

            // Re-lookup after await -- the array may have been reordered during suspension
            updatePlugin(id: pluginId) {
                $0.installedVersion = result.receipt.version
                $0.isInstalling = false
            }

            // Reload plugins (heavy work runs on background thread, posts .toolsListChanged)
            await PluginManager.shared.loadAll()

            // Re-lookup again after second await
            updatePlugin(id: pluginId) {
                $0.loadError = PluginManager.shared.loadError(for: pluginId)
            }
            updateUpdatesCount()
        } catch {
            updatePlugin(id: pluginId) { $0.isInstalling = false }
            throw error
        }
    }

    // MARK: - State Construction

    /// Creates a PluginState from a repository spec, enriched with local install state.
    /// `installedVersion` is resolved off the main actor by the caller (see
    /// `InstalledPluginsStore.snapshot()`) so this stays free of file I/O.
    private static func makeState(
        from spec: PluginSpec,
        installedVersion: SemanticVersion?
    ) -> PluginState {
        PluginState(
            pluginId: spec.plugin_id,
            name: spec.name,
            pluginDescription: spec.description,
            authors: spec.authors,
            license: spec.license,
            capabilities: spec.capabilities,
            installedVersion: installedVersion,
            latestVersion: spec.versions.map(\.version).sorted(by: >).first,
            loadError: PluginManager.shared.loadError(for: spec.plugin_id)
        )
    }

    /// Creates a PluginState for a locally installed plugin using manifest data.
    /// Used when no repo spec is available (offline / plugin not in repository).
    private static func makeInstalledState(
        for pluginId: String,
        installedVersion: SemanticVersion?
    ) -> PluginState {
        var name: String?
        var desc: String?
        var authors: [String]?
        var license: String?
        var capabilities: RegistryCapabilities?

        if let loaded = PluginManager.shared.plugins.first(where: { $0.plugin.id == pluginId }) {
            let manifest = loaded.plugin.manifest
            name = manifest.name
            desc = manifest.description
            authors = manifest.authors
            license = manifest.license
            capabilities = RegistryCapabilities(
                tools: manifest.capabilities.tools?.map {
                    RegistryCapabilities.ToolSummary(name: $0.id, description: $0.description)
                },
                skills: loaded.skills.isEmpty
                    ? nil
                    : loaded.skills.map {
                        RegistryCapabilities.SkillSummary(name: $0.name, description: $0.description)
                    }
            )
        }

        return PluginState(
            pluginId: pluginId,
            name: name,
            pluginDescription: desc,
            authors: authors,
            license: license,
            capabilities: capabilities,
            installedVersion: installedVersion,
            loadError: PluginManager.shared.loadError(for: pluginId)
        )
    }

    // MARK: - State Updates

    /// Populates the plugins list from locally installed plugins on disk.
    /// Called eagerly before any network operation so the Installed tab is always available.
    private func loadInstalledPluginsFromDisk() async {
        // Symlink repair and the per-plugin disk scan are synchronous file I/O
        // (directory listings, `readlink`) that has hung the UI when run on the
        // main thread. Do both off the main actor and assemble state from the
        // resulting snapshot.
        let snapshot = await Task.detached(priority: .utility) {
            // Self-heal: repoint or remove any dangling `current` symlinks left behind
            // by a crashed install or pre-fix TOFU key rotation. Idempotent and cheap.
            PluginInstallManager.repairDanglingCurrentSymlinks()
            return InstalledPluginsStore.shared.snapshot()
        }.value

        guard !snapshot.installedIds.isEmpty else { return }

        let installingIds = Set(plugins.filter { $0.isInstalling }.map { $0.id })

        plugins = snapshot.installedIds.map { pluginId in
            var state = Self.makeInstalledState(
                for: pluginId,
                installedVersion: snapshot.latestVersion(for: pluginId)
            )
            state.isInstalling = installingIds.contains(pluginId)
            return state
        }.sorted { $0.displayName < $1.displayName }

        updateUpdatesCount()
    }

    /// Merges repo specs with locally installed plugins into a single list.
    /// `snapshot` carries the off-actor-resolved install state so this performs
    /// no file I/O on the main actor.
    private func updatePlugins(from specs: [PluginSpec], snapshot: InstalledPluginsStore.Snapshot) {
        var specPluginIds = Set<String>()
        var result: [PluginState] = specs.map { spec in
            specPluginIds.insert(spec.plugin_id)
            return Self.makeState(
                from: spec,
                installedVersion: snapshot.latestVersion(for: spec.plugin_id)
            )
        }

        // Append installed plugins that have no matching repo spec
        for pluginId in snapshot.installedIds where !specPluginIds.contains(pluginId) {
            result.append(
                Self.makeInstalledState(
                    for: pluginId,
                    installedVersion: snapshot.latestVersion(for: pluginId)
                )
            )
        }

        plugins = result.sorted { $0.displayName < $1.displayName }
        updateUpdatesCount()
    }

    /// Refreshes install/error state and picks up newly installed plugins.
    private func updateInstalledState() async {
        // Resolve install state off the main actor; the per-plugin version probes
        // do synchronous `readlink`/directory I/O that has hung the UI.
        let snapshot = await Task.detached(priority: .utility) {
            InstalledPluginsStore.shared.snapshot()
        }.value

        let currentIds = Set(plugins.map { $0.id })

        for pluginId in snapshot.installedIds where !currentIds.contains(pluginId) {
            plugins.append(
                Self.makeInstalledState(
                    for: pluginId,
                    installedVersion: snapshot.latestVersion(for: pluginId)
                )
            )
        }

        for i in plugins.indices {
            let pluginId = plugins[i].pluginId
            plugins[i].installedVersion = snapshot.latestVersion(for: pluginId)
            plugins[i].loadError = PluginManager.shared.loadError(for: pluginId)
        }

        plugins.sort { $0.displayName < $1.displayName }
        updateUpdatesCount()
    }

    private func updateUpdatesCount() {
        updatesAvailableCount = plugins.filter { $0.hasUpdate }.count
    }

    /// Check if a newly installed plugin requires secrets and set pendingSecretsPlugin if needed
    private func checkForPendingSecrets(pluginId: String) {
        // Get the loaded plugin to check for secrets
        guard let loaded = PluginManager.shared.plugins.first(where: { $0.plugin.id == pluginId }),
            let secrets = loaded.plugin.manifest.secrets,
            !secrets.isEmpty
        else {
            return
        }

        let missingRequired = secrets.filter { spec in
            spec.required && !ToolSecretsKeychain.hasSecret(id: spec.id, for: pluginId, agentId: Agent.defaultId)
        }

        if !missingRequired.isEmpty {
            // Set pending secrets plugin to trigger the secrets sheet in UI
            pendingSecretsPlugin = pluginId
        }
    }
}
