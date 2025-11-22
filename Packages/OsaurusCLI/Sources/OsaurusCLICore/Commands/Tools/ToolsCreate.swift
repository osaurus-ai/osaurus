//
//  ToolsCreate.swift
//  osaurus
//
//  Command to scaffold a new plugin project with Swift or Rust template code and manifest.json.
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
        let pluginDir = sources.appendingPathComponent("Plugin", isDirectory: true)
        try? fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        // Package.swift
        let packageSwift = """
            // swift-tools-version: 5.9
            import PackageDescription

            let package = Package(
                name: "\(name)",
                platforms: [.macOS(.v13)],
                products: [
                    .library(name: "\(name)", type: .dynamic, targets: ["Plugin"])
                ],
                targets: [
                    .target(
                        name: "Plugin",
                        path: "Sources/Plugin"
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
                let parameters: String = "{\\"type\\":\\"object\\",\\"properties\\":{\\"name\\":{\\"type\\":\\"string\\"}},\\"required\\":[\\"name\\"]}"
                let requirements: String = "[]"
                let policy: String = "ask"
            }

            // MARK: - C ABI surface
            private struct osr_tool_spec_v1 {
                var name: UnsafePointer<CChar>?
                var description: UnsafePointer<CChar>?
                var parameters_json: UnsafePointer<CChar>?
                var requirements_json: UnsafePointer<CChar>?
                var permission_policy: UnsafePointer<CChar>?
            }
            private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
            private typealias osr_tool_count_t = @convention(c) () -> Int32
            private typealias osr_get_tool_spec_t = @convention(c) (Int32, UnsafeMutableRawPointer?) -> Int32
            private typealias osr_execute_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

            private struct osr_plugin_api_v1 {
                var free_string: osr_free_string_t?
                var tool_count: osr_tool_count_t?
                var get_tool_spec: osr_get_tool_spec_t?
                var execute: osr_execute_t?
            }

            private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
                return (s as NSString).utf8String
            }

            // Persistent toolkit
            private let tool = HelloTool()
            private var api: osr_plugin_api_v1 = {
                var api = osr_plugin_api_v1()
                api.free_string = { ptr in if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) } }
                api.tool_count = { 1 }
                api.get_tool_spec = { (index: Int32, outPtr: UnsafeMutableRawPointer?) -> Int32 in
                    guard index == 0, let outPtr else { return 1 }
                    let out = outPtr.assumingMemoryBound(to: osr_tool_spec_v1.self)
                    out.pointee = osr_tool_spec_v1(
                        name: makeCString(tool.name),
                        description: makeCString(tool.description),
                        parameters_json: makeCString(tool.parameters),
                        requirements_json: makeCString(tool.requirements),
                        permission_policy: makeCString(tool.policy)
                    )
                    return 0
                }
                api.execute = { toolNamePtr, argsPtr in
                    guard let argsPtr else { return nil }
                    let args = String(cString: argsPtr)
                    let name = (try? JSONSerialization.jsonObject(with: args.data(using: .utf8) ?? Data())) as? [String: Any]
                    let who = (name?["name"] as? String) ?? "world"
                    let summary = "Hello, \\(who)!"
                    let payload = "{\\"message\\":\\"\\(summary)\\"}"
                    let combined = summary + "\\n" + payload
                    let buf = strdup(combined)
                    return UnsafePointer<CChar>(buf)
                }
                return api
            }()

            @_cdecl("osaurus_plugin_entry_v1")
            public func osaurus_plugin_entry_v1() -> UnsafeRawPointer? {
                return UnsafeRawPointer(&api)
            }
            """
        try? pluginSwift.write(to: pluginDir.appendingPathComponent("Plugin.swift"), atomically: true, encoding: .utf8)

        // manifest.json (example)
        let manifest = """
            {
              "id": "dev.example.\(name)",
              "name": "\(name)",
              "version": "0.1.0",
              "min_osaurus": "0.9.0",
              "dylib": "lib\(name).dylib",
              "tools": [
                {
                  "name": "hello_world",
                  "description": "Return a friendly greeting",
                  "parameters": {"type":"object","properties":{"name":{"type":"string"}},"required":["name"]},
                  "requirements": [],
                  "permissionPolicy": "ask"
                }
              ]
            }
            """
        try? manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    }

    private static func createRustPlugin(name: String) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let readme = """
            # \(name)

            This is a placeholder for a Rust-based Osaurus plugin. Build a cdylib exposing
            `osaurus_plugin_entry_v1` that returns the C ABI v1 table.
            """
        try? readme.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }
}
