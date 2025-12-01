//
//  ToolsCreate.swift
//  osaurus
//
//  Command to scaffold a new plugin project with Swift or Rust template code.
//

import Foundation

public struct ToolsCreate {
    public static func execute(args: [String]) {
        guard let name = args.first, !name.isEmpty else {
            fputs("Usage: osaurus tools create <name> [--language swift|rust]\n", stderr)
            exit(EXIT_FAILURE)
        }
        var language = "swift"
        if let idx = args.firstIndex(of: "--language"), idx + 1 < args.count {
            let lang = args[idx + 1].lowercased()
            if lang == "rust" { language = "rust" }
        }
        switch language {
        case "swift":
            createSwiftPlugin(name: name)
        case "rust":
            createRustPlugin(name: name)
        default:
            createSwiftPlugin(name: name)
        }
        print("Created plugin scaffold at ./\(name)")
        exit(EXIT_SUCCESS)
    }

    private static func createSwiftPlugin(name: String) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let sources = dir.appendingPathComponent("Sources", isDirectory: true)
        // Use plugin name as module name to avoid duplicate Objective-C class names across plugins
        let moduleName = name.replacingOccurrences(of: "-", with: "_")
        let pluginDir = sources.appendingPathComponent(moduleName, isDirectory: true)
        try? fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        // Package.swift
        let packageSwift = """
            // swift-tools-version: 5.9
            import PackageDescription

            let package = Package(
                name: "\(name)",
                platforms: [.macOS(.v13)],
                products: [
                    .library(name: "\(name)", type: .dynamic, targets: ["\(moduleName)"])
                ],
                targets: [
                    .target(
                        name: "\(moduleName)",
                        path: "Sources/\(moduleName)"
                    )
                ]
            )
            """
        try? packageSwift.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        // Plugin.swift
        let pluginSwift = """
            import Foundation

            // MARK: - Minimal tool implementation
            private struct HelloTool {
                let name = "hello_world"
                let description = "Return a friendly greeting"
                let parameters = "{\\"type\\":\\"object\\",\\"properties\\":{\\"name\\":{\\"type\\":\\"string\\"}},\\"required\\":[\\"name\\"]}"
                
                func run(args: String) -> String {
                    struct Args: Decodable {
                        let name: String
                    }
                    guard let data = args.data(using: .utf8),
                          let input = try? JSONDecoder().decode(Args.self, from: data)
                    else {
                        return "{\\"error\\": \\"Invalid arguments\\"}"
                    }
                    return "{\\"message\\": \\"Hello, \\(input.name)!\\"}"
                }
            }

            // MARK: - C ABI surface

            // Opaque context
            private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

            // Function pointers
            private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
            private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
            private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
            private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
            private typealias osr_invoke_t = @convention(c) (
                osr_plugin_ctx_t?,
                UnsafePointer<CChar>?,  // type
                UnsafePointer<CChar>?,  // id
                UnsafePointer<CChar>?   // payload
            ) -> UnsafePointer<CChar>?

            private struct osr_plugin_api {
                var free_string: osr_free_string_t?
                var `init`: osr_init_t?
                var destroy: osr_destroy_t?
                var get_manifest: osr_get_manifest_t?
                var invoke: osr_invoke_t?
            }

            // Context state (simple wrapper class to hold state)
            private class PluginContext {
                let tool = HelloTool()
            }

            // Helper to return C strings
            private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
                return strdup(s)
            }

            // API Implementation
            private var api: osr_plugin_api = {
                var api = osr_plugin_api()
                
                api.free_string = { ptr in
                    if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
                }
                
                api.`init` = {
                    let ctx = PluginContext()
                    return Unmanaged.passRetained(ctx).toOpaque()
                }
                
                api.destroy = { ctxPtr in
                    guard let ctxPtr = ctxPtr else { return }
                    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
                }
                
                api.get_manifest = { ctxPtr in
                    // Manifest JSON matching new spec
                    let manifest = \"\"\"
                    {
                      "plugin_id": "dev.example.\(name)",
                      "version": "0.1.0",
                      "description": "An example plugin",
                      "capabilities": {
                        "tools": [
                          {
                            "id": "hello_world",
                            "description": "Return a friendly greeting",
                            "parameters": {"type":"object","properties":{"name":{"type":"string"}},"required":["name"]},
                            "requirements": [],
                            "permission_policy": "ask"
                          }
                        ]
                      }
                    }
                    \"\"\"
                    return makeCString(manifest)
                }
                
                api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
                    guard let ctxPtr = ctxPtr,
                          let typePtr = typePtr,
                          let idPtr = idPtr,
                          let payloadPtr = payloadPtr else { return nil }
                    
                    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
                    let type = String(cString: typePtr)
                    let id = String(cString: idPtr)
                    let payload = String(cString: payloadPtr)
                    
                    if type == "tool" && id == ctx.tool.name {
                         let result = ctx.tool.run(args: payload)
                         return makeCString(result)
                    }
                    
                    return makeCString("{\\"error\\": \\"Unknown capability\\"}")
                }
                
                return api
            }()

            @_cdecl("osaurus_plugin_entry")
            public func osaurus_plugin_entry() -> UnsafeRawPointer? {
                return UnsafeRawPointer(&api)
            }
            """
        try? pluginSwift.write(to: pluginDir.appendingPathComponent("Plugin.swift"), atomically: true, encoding: .utf8)

        // README.md (with publishing instructions)
        let readme = """
            # \(name)

            An Osaurus plugin.

            ## Development

            1. Build:
               ```bash
               swift build -c release
               cp .build/release/lib\(name).dylib ./lib\(name).dylib
               ```
               
            2. Package (for distribution):
               ```bash
               osaurus tools package dev.example.\(name) 0.1.0
               ```
               This creates `dev.example.\(name)-0.1.0.zip`.
               
            3. Install locally:
               ```bash
               osaurus tools install ./dev.example.\(name)-0.1.0.zip
               ```
               
            ## Publishing

            To publish this plugin to the central registry:

            1. Package it with the correct naming convention:
               ```bash
               osaurus tools package <plugin_id> <version>
               ```
               The zip file MUST be named `<plugin_id>-<version>.zip`.
               
            2. Host the zip file (e.g. GitHub Releases).

            3. Create a registry entry JSON file for the central repository.

            ## Important Notes

            - Plugin metadata (id, version, capabilities) is defined in `get_manifest()` in Plugin.swift
            - The zip filename determines the plugin_id and version during installation
            - Ensure the version in `get_manifest()` matches your zip filename
            """
        try? readme.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    private static func createRustPlugin(name: String) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let readme = """
            # \(name)

            This is a placeholder for a Rust-based Osaurus plugin. Build a cdylib exposing
            `osaurus_plugin_entry` that returns the generic ABI table.
            """
        try? readme.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }
}
