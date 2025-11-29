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

    struct LoadedPlugin {
        let plugin: ExternalPlugin
        let handle: UnsafeMutableRawPointer
        let tools: [ExternalTool]  // Keep track of tools to unregister later
    }

    /// Represents a plugin that failed to load
    struct FailedPlugin: Sendable {
        let pluginId: String
        let error: String
    }

    /// Error type for plugin loading failures
    struct PluginLoadError: Error, CustomStringConvertible {
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

    /// Scans the tools directory and loads all plugins found.
    func loadAll() {
        Self.ensureToolsDirectoryExists()

        // Clear previous failures before scanning
        failedPlugins.removeAll()

        // Get dylib URLs and track verification failures
        let (urls, verificationFailures) = Self.toolsDirectoryURLsWithFailures()
        for (pluginId, error) in verificationFailures {
            failedPlugins[pluginId] = FailedPlugin(pluginId: pluginId, error: error)
        }

        let currentPaths = Set(urls.map { $0.path })

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

                // dlclose happens here
                dlclose(loaded.handle)
                loadedPluginPaths.remove(loaded.plugin.bundlePath)
                removedSomething = true
            }
        }
        plugins = remaining

        // Load new plugins
        var loadedNew = false
        for url in urls {
            if loadedPluginPaths.contains(url.path) { continue }

            let result = loadPluginWithError(at: url)
            switch result {
            case .success(let loaded):
                plugins.append(loaded)
                loadedPluginPaths.insert(url.path)
                loadedNew = true

                // Register tools
                for tool in loaded.tools {
                    ToolRegistry.shared.register(tool)
                }

                // Clear any previous failure for this plugin
                failedPlugins.removeValue(forKey: loaded.plugin.id)

            case .failure(let error):
                let pluginId = Self.extractPluginId(from: url)
                failedPlugins[pluginId] = FailedPlugin(pluginId: pluginId, error: error.message)
            }
        }

        if loadedNew || removedSomething || !failedPlugins.isEmpty {
            Task { @MainActor in
                await MCPServerManager.shared.notifyToolsListChanged()
                NotificationCenter.default.post(name: .toolsListChanged, object: nil)
            }
        }
    }

    /// Extracts the plugin ID from a dylib URL path
    /// Expected path: .../Tools/{pluginId}/{version}/plugin.dylib
    private static func extractPluginId(from url: URL) -> String {
        // Go up from dylib -> version dir -> plugin dir
        let versionDir = url.deletingLastPathComponent()
        let pluginDir = versionDir.deletingLastPathComponent()
        return pluginDir.lastPathComponent
    }

    private func loadPluginWithError(at url: URL) -> Result<LoadedPlugin, PluginLoadError> {
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

        // Look for the entry point
        guard let sym = dlsym(handle, "osaurus_plugin_entry") else {
            let errorMsg = "Missing plugin entry point (osaurus_plugin_entry)"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }

        let entryFn = unsafeBitCast(sym, to: osr_plugin_entry_t.self)
        guard let apiRawPtr = entryFn() else {
            let errorMsg = "Plugin entry returned null API"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }

        let apiPtr = apiRawPtr.assumingMemoryBound(to: osr_plugin_api.self)
        let api = apiPtr.pointee

        // Initialize Plugin
        guard let initFn = api.`init` else {
            let errorMsg = "Plugin missing init function"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }

        guard let ctx = initFn() else {
            let errorMsg = "Plugin initialization failed"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }

        // Get Manifest
        guard let getManifest = api.get_manifest, let jsonPtr = getManifest(ctx) else {
            let errorMsg = "Plugin failed to return manifest"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            api.destroy?(ctx)
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
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }

        // Create ExternalPlugin wrapper
        let plugin = ExternalPlugin(handle: handle, api: api, ctx: ctx, manifest: manifest, path: url.path)

        // Create Tools
        var tools: [ExternalTool] = []
        if let toolSpecs = manifest.capabilities.tools {
            for spec in toolSpecs {
                let tool = ExternalTool(plugin: plugin, spec: spec)
                tools.append(tool)
            }
        }

        return .success(LoadedPlugin(plugin: plugin, handle: handle, tools: tools))
    }

    // MARK: - Tools directory helpers
    static func toolsRootDirectory() -> URL {
        return ToolsPaths.toolsRootDirectory()
    }

    static func ensureToolsDirectoryExists() {
        let root = toolsRootDirectory()
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    static func toolsDirectoryURLs() -> [URL] {
        return toolsDirectoryURLsWithFailures().urls
    }

    /// Returns dylib URLs to load and a dictionary of verification failures (pluginId -> error message)
    static func toolsDirectoryURLsWithFailures() -> (urls: [URL], failures: [String: String]) {
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
    private static func verifyDylibBeforeLoadWithError(_ dylibURL: URL) -> Result<Void, PluginLoadError> {
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

        let sha: String
        if #available(macOS 10.15, *) {
            let digest = CryptoKit.SHA256.hash(data: dylibData)
            sha = Data(digest).map { String(format: "%02x", $0) }.joined()
        } else {
            return .failure(PluginLoadError(message: "SHA256 verification requires macOS 10.15+"))
        }

        if sha.lowercased() != receipt.dylib_sha256.lowercased() {
            return .failure(
                PluginLoadError(message: "Checksum verification failed - plugin file may be corrupted or tampered with")
            )
        }

        return .success(())
    }
}
