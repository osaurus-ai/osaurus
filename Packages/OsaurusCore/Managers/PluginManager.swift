//
//  PluginManager.swift
//  osaurus
//
//  Manages loading and lifecycle of external plugins.
//

import Foundation
import Darwin
import CryptoKit
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
    }

    private(set) var plugins: [LoadedPlugin] = []
    private var loadedPluginPaths: Set<String> = []

    /// Plugins that failed to load, keyed by plugin ID
    private(set) var failedPlugins: [String: FailedPlugin] = [:]

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
    func loadAll() async {
        Self.ensureToolsDirectoryExists()

        // Clear previous failures before scanning
        failedPlugins.removeAll()

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
                // Unregister tools
                let names = loaded.tools.map { $0.name }
                ToolRegistry.shared.unregister(names: names)

                // Unregister plugin skills
                if !loaded.skills.isEmpty {
                    SkillManager.shared.unregisterPluginSkills(pluginId: loaded.plugin.id)
                }

                // Tear down v2 host context (closes DB, removes from registry)
                PluginHostContext.contexts[loaded.plugin.id]?.teardown()

                // dlclose happens here
                dlclose(loaded.handle)
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
                    ToolRegistry.shared.register(tool)
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
            await MCPServerManager.shared.notifyToolsListChanged()
            NotificationCenter.default.post(name: .toolsListChanged, object: nil)
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
            loadResults.append((url: url, result: loadPluginWithError(at: url)))
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
            var hostAPI = ctx.buildHostAPI()
            let entryFn = unsafeBitCast(v2sym, to: osr_plugin_entry_v2_t.self)
            let apiRawPtr = withUnsafePointer(to: &hostAPI) { hostPtr in
                entryFn(UnsafeRawPointer(hostPtr))
            }
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

            PluginHostContext.contexts[preliminaryId] = ctx
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

        guard let ctx = initFn() else {
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
            PluginHostContext.contexts.removeValue(forKey: hc.pluginId)
            PluginHostContext.contexts[manifest.plugin_id] = hc
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

    // MARK: - Tools directory helpers
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

    /// Returns dylib URLs to load and a dictionary of verification failures (pluginId -> error message)
    nonisolated static func toolsDirectoryURLsWithFailures() -> (urls: [URL], failures: [String: String]) {
        let fm = FileManager.default
        let root = toolsRootDirectory()
        var dylibURLs: [URL] = []
        var failures: [String: String] = [:]

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

    /// Verifies a dylib before loading, returning success or an error message
    nonisolated private static func verifyDylibBeforeLoadWithError(_ dylibURL: URL) -> Result<Void, PluginLoadError> {
        let fm = FileManager.default
        let receiptURL = dylibURL.deletingLastPathComponent().appendingPathComponent("receipt.json", isDirectory: false)

        // Development mode: if no receipt, allow it
        guard fm.fileExists(atPath: receiptURL.path) else { return .success(()) }

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
                PluginLoadError(message: "Checksum verification failed - plugin file may be corrupted or tampered with")
            )
        }

        return .success(())
    }
}
