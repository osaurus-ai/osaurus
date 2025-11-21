//
//  ExternalTool.swift
//  osaurus
//
//  Wrapper around an external plugin tool exposed via the C ABI.
//

import Foundation
import Darwin
import CryptoKit
import OsaurusRepository

// C ABI mirror types
struct osr_tool_spec_v1 {
    var name: UnsafePointer<CChar>?
    var description: UnsafePointer<CChar>?
    var parameters_json: UnsafePointer<CChar>?
    var requirements_json: UnsafePointer<CChar>?
    var permission_policy: UnsafePointer<CChar>?
}

typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_tool_count_t = @convention(c) () -> Int32
// Use raw pointer to avoid Swift struct in @convention(c) signature
typealias osr_get_tool_spec_t = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Int32
typealias osr_execute_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

struct osr_plugin_api_v1 {
    var free_string: osr_free_string_t?
    var tool_count: osr_tool_count_t?
    var get_tool_spec: osr_get_tool_spec_t?
    var execute: osr_execute_t?
}

// v2 API extends v1 with an additional manifest function (prefix layout compatible)
typealias osr_get_plugin_manifest_json_t = @convention(c) () -> UnsafePointer<CChar>?
struct osr_plugin_api_v2 {
    var free_string: osr_free_string_t?
    var tool_count: osr_tool_count_t?
    var get_tool_spec: osr_get_tool_spec_t?
    var execute: osr_execute_t?
    // New in v2
    var get_plugin_manifest_json: osr_get_plugin_manifest_json_t?
}

// Entry returns raw pointer to vtable; we cast after calling
typealias osaurus_plugin_entry_v1_t = @convention(c) () -> UnsafeRawPointer?
typealias osaurus_plugin_entry_v2_t = @convention(c) () -> UnsafeRawPointer?

final class ExternalTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name: String
    let description: String
    let parameters: JSONValue?
    let requirements: [String]
    let defaultPermissionPolicy: ToolPermissionPolicy

    // Plugin call surface
    private let api: osr_plugin_api_v1

    init?(
        apiPtr: UnsafePointer<osr_plugin_api_v1>,
        spec: osr_tool_spec_v1
    ) {
        self.api = apiPtr.pointee

        guard let namePtr = spec.name, let descPtr = spec.description else { return nil }
        self.name = String(cString: namePtr)
        self.description = String(cString: descPtr)

        // parameters
        if let paramsPtr = spec.parameters_json {
            let jsonString = String(cString: paramsPtr)
            if let data = jsonString.data(using: .utf8) {
                self.parameters = try? JSONDecoder().decode(JSONValue.self, from: data)
            } else {
                self.parameters = nil
            }
        } else {
            self.parameters = nil
        }

        // requirements
        if let reqPtr = spec.requirements_json {
            let jsonString = String(cString: reqPtr)
            if let data = jsonString.data(using: .utf8),
                let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
            {
                self.requirements = arr
            } else {
                self.requirements = []
            }
        } else {
            self.requirements = []
        }

        // default policy
        if let polPtr = spec.permission_policy {
            let s = String(cString: polPtr).lowercased()
            switch s {
            case "auto": self.defaultPermissionPolicy = .auto
            case "deny": self.defaultPermissionPolicy = .deny
            default: self.defaultPermissionPolicy = .ask
            }
        } else {
            self.defaultPermissionPolicy = .ask
        }
    }

    deinit {
        // Note: pluginHandle is owned by PluginManager and closed there
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let exec = api.execute else {
            throw NSError(
                domain: "ExternalTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Plugin execute unavailable"]
            )
        }
        let resultPtr = argumentsJSON.withCString { argsPtr in
            self.name.withCString { toolNamePtr in
                exec(toolNamePtr, argsPtr)
            }
        }
        guard let cstr = resultPtr else {
            throw NSError(
                domain: "ExternalTool",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Plugin returned null result"]
            )
        }
        let result = String(cString: cstr)
        // Free memory via plugin
        api.free_string?(cstr)
        return result
    }
}

// MARK: - Plugin Manager

@MainActor
final class PluginManager {
    static let shared = PluginManager()

    struct PluginBundle {
        let path: String
        let handle: UnsafeMutableRawPointer
        let apiPtr: UnsafePointer<osr_plugin_api_v1>
        let tools: [ExternalTool]
    }

    private(set) var plugins: [PluginBundle] = []
    private var loadedPluginPaths: Set<String> = []

    private init() {}

    /// Scans the tools directory and loads all plugins found.
    func loadAll() {
        Self.ensureToolsDirectoryExists()
        let urls = Self.toolsDirectoryURLs()
        let currentPaths = Set(urls.map { $0.path })

        // Unload removed plugins
        var removedSomething = false
        var remaining: [PluginBundle] = []
        for bundle in plugins {
            if currentPaths.contains(bundle.path) {
                remaining.append(bundle)
            } else {
                // Unregister tools and close handle
                let names = bundle.tools.map { $0.name }
                ToolRegistry.shared.unregister(names: names)
                dlclose(bundle.handle)
                loadedPluginPaths.remove(bundle.path)
                removedSomething = true
            }
        }
        plugins = remaining

        // Load new plugins
        var loadedNew = false
        for url in urls {
            if loadedPluginPaths.contains(url.path) { continue }
            if let bundle = loadPlugin(at: url) {
                plugins.append(bundle)
                loadedPluginPaths.insert(url.path)
                loadedNew = true
                // Register tools with the registry
                for tool in bundle.tools {
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

    /// Attempts to load a single plugin dylib URL.
    private func loadPlugin(at url: URL) -> PluginBundle? {
        let flags = RTLD_NOW | RTLD_LOCAL
        guard let handle = dlopen(url.path, Int32(flags)) else {
            if let err = dlerror() {
                let s = String(cString: err)
                print("[Osaurus] dlopen failed: \(s) for \(url.path)")
            }
            return nil
        }
        defer {
            // We keep the handle open for the lifetime of the process.
        }
        // Prefer v2, fallback to v1
        var apiPtrV1: UnsafePointer<osr_plugin_api_v1>?
        if let symV2 = dlsym(handle, "osaurus_plugin_entry_v2") {
            let entryV2 = unsafeBitCast(symV2, to: osaurus_plugin_entry_v2_t.self)
            if let apiRawPtr = entryV2() {
                // Optional: read manifest for cross-check
                let apiPtrV2 = apiRawPtr.assumingMemoryBound(to: osr_plugin_api_v2.self)
                if let getManifest = apiPtrV2.pointee.get_plugin_manifest_json,
                    let cstr = getManifest()
                {
                    let json = String(cString: cstr)
                    apiPtrV2.pointee.free_string?(cstr)
                    // Best-effort validation (matches directory layout)
                    validateRuntimeManifest(json: json, pluginURL: url)
                }
                apiPtrV1 = apiRawPtr.assumingMemoryBound(to: osr_plugin_api_v1.self)
            }
        } else if let symV1 = dlsym(handle, "osaurus_plugin_entry_v1") {
            let entryV1 = unsafeBitCast(symV1, to: osaurus_plugin_entry_v1_t.self)
            if let apiRawPtr = entryV1() {
                apiPtrV1 = apiRawPtr.assumingMemoryBound(to: osr_plugin_api_v1.self)
            }
        }
        guard let apiPtr = apiPtrV1 else {
            print("[Osaurus] Missing osaurus_plugin_entry_v2/v1 in \(url.lastPathComponent)")
            dlclose(handle)
            return nil
        }
        let api = apiPtr.pointee
        guard let countFn = api.tool_count, let getSpec = api.get_tool_spec else {
            print("[Osaurus] Plugin missing required functions in \(url.lastPathComponent)")
            dlclose(handle)
            return nil
        }
        let count = Int(countFn())
        var tools: [ExternalTool] = []
        tools.reserveCapacity(max(0, count))
        for i in 0 ..< count {
            var spec = osr_tool_spec_v1()
            let ok = withUnsafeMutablePointer(to: &spec) { ptr in
                getSpec(Int32(i), UnsafeMutableRawPointer(ptr))
            }
            if ok == 0, let tool = ExternalTool(apiPtr: apiPtr, spec: spec) {
                tools.append(tool)
            }
        }
        return PluginBundle(path: url.path, handle: handle, apiPtr: apiPtr, tools: tools)
    }

    private func validateRuntimeManifest(json: String, pluginURL: URL) {
        // Compare manifest-reported plugin_id/version with directory names if present.
        struct Manifest: Decodable {
            let plugin_id: String?
            let version: String?
            let abi: Int?
        }
        guard let data = json.data(using: .utf8),
            let m = try? JSONDecoder().decode(Manifest.self, from: data)
        else {
            return
        }
        let versionDir = pluginURL.deletingLastPathComponent()
        let pluginDir = versionDir.deletingLastPathComponent()
        if let pid = m.plugin_id, pid != pluginDir.lastPathComponent {
            print("[Osaurus] Warning: plugin_id mismatch (manifest \(pid) vs dir \(pluginDir.lastPathComponent))")
        }
        if let ver = m.version, ver != versionDir.lastPathComponent {
            print("[Osaurus] Warning: version mismatch (manifest \(ver) vs dir \(versionDir.lastPathComponent))")
        }
    }

    // MARK: - Tools directory
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

    /// Returns URLs of dylibs within versioned plugin directories, preferring `current` symlink.
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
                // Fallback: pick highest SemVer directory name
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
                    if let best = versions.sorted(by: { $0.0 > $1.0 }).first {
                        versionDir = best.1
                    }
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
                        // Only include dylibs that pass local receipt verification
                        if verifyDylibBeforeLoad(fileURL) {
                            dylibURLs.append(fileURL)
                        } else {
                            print("[Osaurus] Skipping plugin (verification failed): \(fileURL.path)")
                        }
                    }
                }
            }
        }
        return dylibURLs
    }

    /// Verifies a dylib against its adjacent receipt.json (sha256). Returns true if OK or if no receipt exists (best-effort).
    private static func verifyDylibBeforeLoad(_ dylibURL: URL) -> Bool {
        let fm = FileManager.default
        let receiptURL = dylibURL.deletingLastPathComponent().appendingPathComponent("receipt.json", isDirectory: false)
        guard fm.fileExists(atPath: receiptURL.path),
            let data = try? Data(contentsOf: receiptURL),
            let receipt = try? JSONDecoder().decode(PluginReceipt.self, from: data),
            let dylibData = try? Data(contentsOf: dylibURL)
        else {
            // If we cannot verify, allow load for now (useful during development)
            return true
        }
        // Compute SHA256
        let sha: String
        if #available(macOS 10.15, *) {
            let digest = CryptoKit.SHA256.hash(data: dylibData)
            sha = Data(digest).map { String(format: "%02x", $0) }.joined()
        } else {
            // Fallback: naive mismatch since CryptoKit unavailable
            sha = ""
        }
        return !sha.isEmpty && sha.lowercased() == receipt.dylib_sha256.lowercased()
    }
}
