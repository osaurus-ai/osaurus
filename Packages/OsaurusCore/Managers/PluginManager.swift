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

    private(set) var plugins: [LoadedPlugin] = []
    private var loadedPluginPaths: Set<String> = []

    private init() {}

    /// Scans the tools directory and loads all plugins found.
    func loadAll() {
        Self.ensureToolsDirectoryExists()
        let urls = Self.toolsDirectoryURLs()
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

            if let loaded = loadPlugin(at: url) {
                plugins.append(loaded)
                loadedPluginPaths.insert(url.path)
                loadedNew = true

                // Register tools
                for tool in loaded.tools {
                    ToolRegistry.shared.register(tool)
                }
            }
        }

        if loadedNew || removedSomething {
            Task { @MainActor in
                await MCPServerManager.shared.notifyToolsListChanged()
                NotificationCenter.default.post(name: .toolsListChanged, object: nil)
            }
        }
    }

    private func loadPlugin(at url: URL) -> LoadedPlugin? {
        let flags = RTLD_NOW | RTLD_LOCAL
        guard let handle = dlopen(url.path, Int32(flags)) else {
            if let err = dlerror() {
                print("[Osaurus] dlopen failed: \(String(cString: err)) for \(url.path)")
            }
            return nil
        }

        // Look for the entry point
        guard let sym = dlsym(handle, "osaurus_plugin_entry") else {
            print("[Osaurus] Missing osaurus_plugin_entry in \(url.lastPathComponent)")
            dlclose(handle)
            return nil
        }

        let entryFn = unsafeBitCast(sym, to: osr_plugin_entry_t.self)
        guard let apiRawPtr = entryFn() else {
            print("[Osaurus] Plugin entry returned null API in \(url.lastPathComponent)")
            dlclose(handle)
            return nil
        }

        let apiPtr = apiRawPtr.assumingMemoryBound(to: osr_plugin_api.self)
        let api = apiPtr.pointee

        // Initialize Plugin
        guard let initFn = api.`init` else {
            print("[Osaurus] Plugin missing init function in \(url.lastPathComponent)")
            dlclose(handle)
            return nil
        }

        guard let ctx = initFn() else {
            print("[Osaurus] Plugin init returned null context in \(url.lastPathComponent)")
            dlclose(handle)
            return nil
        }

        // Get Manifest
        guard let getManifest = api.get_manifest, let jsonPtr = getManifest(ctx) else {
            print("[Osaurus] Plugin failed to return manifest in \(url.lastPathComponent)")
            // cleanup
            api.destroy?(ctx)
            dlclose(handle)
            return nil
        }
        let jsonString = String(cString: jsonPtr)
        api.free_string?(jsonPtr)

        // Parse Manifest
        guard let data = jsonString.data(using: String.Encoding.utf8),
            let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
        else {
            print("[Osaurus] Failed to parse manifest in \(url.lastPathComponent)")
            api.destroy?(ctx)
            dlclose(handle)
            return nil
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

        return LoadedPlugin(plugin: plugin, handle: handle, tools: tools)
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
        let fm = FileManager.default
        let root = toolsRootDirectory()
        var dylibURLs: [URL] = []

        guard
            let pluginDirs = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return dylibURLs
        }

        for pluginDir in pluginDirs where pluginDir.hasDirectoryPath {
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

            guard let vdir = versionDir else { continue }

            if let enumerator = fm.enumerator(
                at: vdir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension == "dylib" {
                        if verifyDylibBeforeLoad(fileURL) {
                            dylibURLs.append(fileURL)
                        }
                    }
                }
            }
        }
        return dylibURLs
    }

    private static func verifyDylibBeforeLoad(_ dylibURL: URL) -> Bool {
        let fm = FileManager.default
        let receiptURL = dylibURL.deletingLastPathComponent().appendingPathComponent("receipt.json", isDirectory: false)

        // Development mode: if no receipt, allow it
        guard fm.fileExists(atPath: receiptURL.path) else { return true }

        guard let data = try? Data(contentsOf: receiptURL),
            let receipt = try? JSONDecoder().decode(PluginReceipt.self, from: data),
            let dylibData = try? Data(contentsOf: dylibURL)
        else { return false }

        let sha: String
        if #available(macOS 10.15, *) {
            let digest = CryptoKit.SHA256.hash(data: dylibData)
            sha = Data(digest).map { String(format: "%02x", $0) }.joined()
        } else {
            sha = ""
        }

        return !sha.isEmpty && sha.lowercased() == receipt.dylib_sha256.lowercased()
    }
}
