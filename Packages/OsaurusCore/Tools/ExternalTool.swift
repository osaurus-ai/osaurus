//
//  ExternalTool.swift
//  osaurus
//
//  Wrapper around an external plugin tool exposed via the C ABI.
//

import Foundation
import Darwin

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

// Entry returns raw pointer to vtable; we cast after calling
typealias osaurus_plugin_entry_v1_t = @convention(c) () -> UnsafeRawPointer?

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
        guard let sym = dlsym(handle, "osaurus_plugin_entry_v1") else {
            print("[Osaurus] Missing osaurus_plugin_entry_v1 in \(url.lastPathComponent)")
            dlclose(handle)
            return nil
        }
        let entry = unsafeBitCast(sym, to: osaurus_plugin_entry_v1_t.self)
        guard let apiRawPtr = entry() else {
            print("[Osaurus] Plugin entry returned null in \(url.lastPathComponent)")
            dlclose(handle)
            return nil
        }
        let apiPtr = apiRawPtr.assumingMemoryBound(to: osr_plugin_api_v1.self)
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

    // MARK: - Tools directory
    static func toolsRootDirectory() -> URL {
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        return supportDir.appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
    }

    static func ensureToolsDirectoryExists() {
        let root = toolsRootDirectory()
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    /// Returns URLs of dylibs within Tools/* subdirectories.
    static func toolsDirectoryURLs() -> [URL] {
        let root = toolsRootDirectory()
        var urls: [URL] = []
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return urls
        }
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "dylib" {
                urls.append(fileURL)
            }
        }
        return urls
    }
}
