//
//  PluginRepositoryService.swift
//  osaurus
//
//  Manages plugin repository state, background refresh, and version comparison for updates.
//

import Combine
import Foundation
import OsaurusRepository

/// Represents a plugin's installation state and available updates
struct PluginState: Identifiable, Equatable {
    var id: String { spec.plugin_id }
    let spec: PluginSpec
    var installedVersion: SemanticVersion?
    var latestVersion: SemanticVersion?
    var isInstalling: Bool = false
    /// Error message if the plugin failed to load (installed but not functional)
    var loadError: String?

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

    /// Interval for background refresh (4 hours)
    private let refreshInterval: TimeInterval = 4 * 60 * 60

    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Listen for tools list changes to update installed state
        NotificationCenter.default.publisher(for: .toolsListChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateInstalledState()
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Start the background refresh timer
    func startBackgroundRefresh() {
        // Initial refresh
        Task {
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

        // Run git operations on background thread
        await Task.detached(priority: .utility) {
            CentralRepositoryManager.shared.refresh()
        }.value

        // Parse specs on background thread
        let specs = await Task.detached(priority: .utility) {
            CentralRepositoryManager.shared.listAllSpecs()
        }.value

        // Update state (already on main actor)
        updatePlugins(from: specs)
        lastRefreshed = Date()
        isRefreshing = false

        // Check for updates and notify if any
        if updatesAvailableCount > 0 {
            let outdatedNames = plugins.filter { $0.hasUpdate }.map { $0.spec.name ?? $0.spec.plugin_id }
            NotificationService.shared.postPluginUpdatesAvailable(
                count: updatesAvailableCount,
                pluginNames: outdatedNames
            )
        }
    }

    /// Install a plugin by ID
    func install(pluginId: String) async throws {
        guard let index = plugins.firstIndex(where: { $0.spec.plugin_id == pluginId }) else {
            throw PluginInstallError.specNotFound(pluginId)
        }

        plugins[index].isInstalling = true

        do {
            let result = try await PluginInstallManager.shared.install(pluginId: pluginId)
            plugins[index].installedVersion = result.receipt.version
            plugins[index].isInstalling = false

            // Reload plugins in the app
            PluginManager.shared.loadAll()

            // Update load error state from PluginManager
            plugins[index].loadError = PluginManager.shared.loadError(for: pluginId)

            // Post notification synchronously to ensure all views update
            NotificationCenter.default.post(name: .toolsListChanged, object: nil)

            updateUpdatesCount()
        } catch {
            plugins[index].isInstalling = false
            throw error
        }
    }

    /// Upgrade a plugin to the latest version
    func upgrade(pluginId: String) async throws {
        guard let index = plugins.firstIndex(where: { $0.spec.plugin_id == pluginId }),
            let latestVersion = plugins[index].latestVersion
        else {
            throw PluginInstallError.specNotFound(pluginId)
        }

        plugins[index].isInstalling = true

        do {
            let result = try await PluginInstallManager.shared.install(
                pluginId: pluginId,
                preferredVersion: latestVersion
            )
            plugins[index].installedVersion = result.receipt.version
            plugins[index].isInstalling = false

            // Reload plugins in the app
            PluginManager.shared.loadAll()

            // Update load error state from PluginManager
            plugins[index].loadError = PluginManager.shared.loadError(for: pluginId)

            // Post notification synchronously to ensure all views update
            NotificationCenter.default.post(name: .toolsListChanged, object: nil)

            updateUpdatesCount()
        } catch {
            plugins[index].isInstalling = false
            throw error
        }
    }

    /// Uninstall a plugin by ID
    func uninstall(pluginId: String) throws {
        let fm = FileManager.default
        let pluginDir = PluginInstallManager.toolsPluginDirectory(pluginId: pluginId)

        if fm.fileExists(atPath: pluginDir.path) {
            try fm.removeItem(at: pluginDir)
        }

        // Update state to ensure UI reflects uninstallation immediately
        if let index = plugins.firstIndex(where: { $0.spec.plugin_id == pluginId }) {
            plugins[index].installedVersion = nil
            plugins[index].loadError = nil
        }

        // Reload plugins (this will unregister tools from ToolRegistry)
        PluginManager.shared.loadAll()

        // Post notification synchronously to ensure all views update
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)

        updateUpdatesCount()
    }

    // MARK: - Private Helpers

    private func updatePlugins(from specs: [PluginSpec]) {
        plugins = specs.map { spec in
            let installedVersion = InstalledPluginsStore.shared.latestInstalledVersion(pluginId: spec.plugin_id)
            let latestVersion = spec.versions.map(\.version).sorted(by: >).first
            let loadError = PluginManager.shared.loadError(for: spec.plugin_id)

            return PluginState(
                spec: spec,
                installedVersion: installedVersion,
                latestVersion: latestVersion,
                isInstalling: false,
                loadError: loadError
            )
        }.sorted { ($0.spec.name ?? $0.spec.plugin_id) < ($1.spec.name ?? $1.spec.plugin_id) }

        updateUpdatesCount()
    }

    private func updateInstalledState() {
        for i in plugins.indices {
            let pluginId = plugins[i].spec.plugin_id
            plugins[i].installedVersion = InstalledPluginsStore.shared.latestInstalledVersion(pluginId: pluginId)
            plugins[i].loadError = PluginManager.shared.loadError(for: pluginId)
        }
        updateUpdatesCount()
    }

    private func updateUpdatesCount() {
        updatesAvailableCount = plugins.filter { $0.hasUpdate }.count
    }
}
