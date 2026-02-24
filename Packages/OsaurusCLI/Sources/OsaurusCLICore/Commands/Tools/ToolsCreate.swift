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
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let sources = dir.appendingPathComponent("Sources", isDirectory: true)
        // Use plugin name as module name to avoid duplicate Objective-C class names across plugins
        let moduleName = name.replacingOccurrences(of: "-", with: "_")
        // Generate display name from plugin name (capitalize words, replace hyphens with spaces)
        let displayName = name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(
            separator: " "
        )
        let pluginDir = sources.appendingPathComponent(moduleName, isDirectory: true)
        try? fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        // Package.swift
        let packageSwift = """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "\(name)",
                platforms: [.macOS(.v15)],
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

            // MARK: - Osaurus Injected Context

            /// Folder context injected by Osaurus when a working directory is selected.
            /// Use this to resolve relative file paths in your tools.
            private struct FolderContext: Decodable {
                let working_directory: String
            }

            // MARK: - Tool Implementation

            private struct HelloTool {
                let name = "hello_world"
                let description = "Return a friendly greeting"
                let parameters = "{\\"type\\":\\"object\\",\\"properties\\":{\\"name\\":{\\"type\\":\\"string\\"}},\\"required\\":[\\"name\\"]}"
                
                func run(args: String) -> String {
                    struct Args: Decodable {
                        let name: String
                        let _secrets: [String: String]?   // Secrets injected by Osaurus
                        let _context: FolderContext?      // Folder context injected by Osaurus
                    }
                    guard let data = args.data(using: .utf8),
                          let input = try? JSONDecoder().decode(Args.self, from: data)
                    else {
                        return "{\\"error\\": \\"Invalid arguments\\"}"
                    }
                    
                    // Example: Access a configured secret (if your plugin declares secrets in manifest)
                    // let apiKey = input._secrets?["api_key"] ?? "no-key"
                    
                    // Example: Resolve a relative path using the working directory
                    // if let workingDir = input._context?.working_directory {
                    //     let absolutePath = "\\(workingDir)/\\(relativePath)"
                    // }
                    
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
                    // NOTE: To require API keys or other secrets, add a "secrets" array at the top level.
                    // Example:
                    //   "secrets": [
                    //     {"id": "api_key", "label": "API Key", "description": "Your API key", "required": true, "url": "https://example.com/api"}
                    //   ],
                    // Secrets are injected into tool payloads under the "_secrets" key.
                    // Folder context (working_directory) is injected under the "_context" key when active.
                    let manifest = \"\"\"
                    {
                      "plugin_id": "dev.example.\(name)",
                      "name": "\(displayName)",
                      "version": "0.1.0",
                      "description": "An example plugin",
                      "license": "MIT",
                      "authors": [],
                      "min_macos": "15.0",
                      "min_osaurus": "0.5.0",
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

        // .github/workflows/release.yml
        let githubDir = dir.appendingPathComponent(".github", isDirectory: true)
        let workflowsDir = githubDir.appendingPathComponent("workflows", isDirectory: true)
        try? fm.createDirectory(at: workflowsDir, withIntermediateDirectories: true)

        let releaseYml = """
            name: Release

            on:
              push:
                tags: ['v*', '[0-9]+.[0-9]+.[0-9]+']

            permissions:
              contents: write

            jobs:
              release:
                uses: osaurus-ai/osaurus-tools/.github/workflows/build-plugin.yml@master
                secrets: inherit
            """
        try? releaseYml.write(to: workflowsDir.appendingPathComponent("release.yml"), atomically: true, encoding: .utf8)

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

            2. Extract manifest (to verify):
               ```bash
               osaurus manifest extract .build/release/lib\(name).dylib
               ```
               
            3. Package (for distribution):
               ```bash
               osaurus tools package dev.example.\(name) 0.1.0
               ```
               This creates `dev.example.\(name)-0.1.0.zip`.
               
            4. Install locally:
               ```bash
               osaurus tools install ./dev.example.\(name)-0.1.0.zip
               ```
               
            ## Publishing

            This project includes a GitHub Actions workflow (`.github/workflows/release.yml`) that
            automatically builds and releases the plugin when you push a version tag.

            To release:
            ```bash
            git tag v0.1.0
            git push origin v0.1.0
            ```

            For manual publishing:

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
            - CI extracts the manifest from the built dylib automatically
            """
        try? readme.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        // CLAUDE.md (AI agent guidance)
        createClaudeMd(name: name, displayName: displayName, dir: dir, language: "swift")
    }

    private static func createRustPlugin(name: String) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let readme = """
            # \(name)

            This is a placeholder for a Rust-based Osaurus plugin. Build a cdylib exposing
            `osaurus_plugin_entry` that returns the generic ABI table.
            """
        try? readme.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        // Generate display name for CLAUDE.md
        let displayName = name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(
            separator: " "
        )
        createClaudeMd(name: name, displayName: displayName, dir: dir, language: "rust")
    }

    // MARK: - AI Agent Guidance

    private static func createClaudeMd(name: String, displayName: String, dir: URL, language: String) {
        let moduleName = name.replacingOccurrences(of: "-", with: "_")
        let isSwift = language == "swift"

        let claudeMd = """
            # \(displayName) - Osaurus Plugin

            This is an Osaurus plugin project. Use this guide to develop, test, and submit the plugin.

            ## Project Structure

            ```
            \(name)/
            \(isSwift ? """
            ├── Package.swift              # Swift Package Manager configuration
            ├── Sources/
            │   └── \(moduleName)/
            │       └── Plugin.swift       # Main plugin implementation
            """ : """
            ├── Cargo.toml                 # Rust package configuration
            ├── src/
            │   └── lib.rs                 # Main plugin implementation
            """)
            ├── README.md                  # User-facing documentation
            ├── CLAUDE.md                  # This file (AI guidance)
            └── .github/
                └── workflows/
                    └── release.yml        # CI/CD for releases
            ```

            ## Architecture Overview

            Osaurus plugins use a C ABI interface. The plugin exports a single entry point (`osaurus_plugin_entry`) that returns a function table with:

            - `init()` - Initialize plugin, return context pointer
            - `destroy(ctx)` - Clean up resources
            - `get_manifest(ctx)` - Return JSON describing plugin capabilities
            - `invoke(ctx, type, id, payload)` - Execute a tool with JSON payload
            - `free_string(s)` - Free strings returned to host

            ## Adding New Tools

            ### Step 1: Define the Tool Structure

            \(isSwift ? """
            ```swift
            private struct MyTool {
                let name = "my_tool"  // Must match manifest id
                let description = "What this tool does"
                
                struct Args: Decodable {
                    let inputParam: String
                    let optionalParam: String?
                }
                
                func run(args: String) -> String {
                    // 1. Parse JSON input
                    guard let data = args.data(using: .utf8),
                          let input = try? JSONDecoder().decode(Args.self, from: data) else {
                        return "{\\"error\\": \\"Invalid arguments\\"}"
                    }
                    
                    // 2. Execute tool logic
                    let result = processInput(input.inputParam)
                    
                    // 3. Return JSON response
                    return "{\\"result\\": \\"\\(result)\\"}"
                }
            }
            ```
            """ : """
            ```rust
            struct MyTool;

            impl MyTool {
                fn run(&self, args: &str) -> String {
                    // 1. Parse JSON input
                    let input: serde_json::Value = match serde_json::from_str(args) {
                        Ok(v) => v,
                        Err(_) => return r#"{"error": "Invalid arguments"}"#.to_string(),
                    };
                    
                    // 2. Execute tool logic
                    let result = self.process_input(&input);
                    
                    // 3. Return JSON response
                    format!(r#"{{"result": "{}"}}"#, result)
                }
            }
            ```
            """)

            ### Step 2: Add Tool to PluginContext

            \(isSwift ? """
            ```swift
            private class PluginContext {
                let helloTool = HelloTool()
                let myTool = MyTool()  // Add your new tool
            }
            ```
            """ : """
            ```rust
            struct PluginContext {
                hello_tool: HelloTool,
                my_tool: MyTool,  // Add your new tool
            }
            ```
            """)

            ### Step 3: Register in Manifest

            Add the tool to the `capabilities.tools` array in `get_manifest()`:

            ```json
            {
              "id": "my_tool",
              "description": "What this tool does (shown to users)",
              "parameters": {
                "type": "object",
                "properties": {
                  "inputParam": {
                    "type": "string",
                    "description": "Description of this parameter"
                  },
                  "optionalParam": {
                    "type": "string",
                    "description": "Optional parameter"
                  }
                },
                "required": ["inputParam"]
              },
              "requirements": [],
              "permission_policy": "ask"
            }
            ```

            ### Step 4: Handle in invoke()

            \(isSwift ? """
            ```swift
            api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
                // ... existing code ...
                
                if type == "tool" {
                    switch id {
                    case ctx.helloTool.name:
                        return makeCString(ctx.helloTool.run(args: payload))
                    case ctx.myTool.name:
                        return makeCString(ctx.myTool.run(args: payload))
                    default:
                        return makeCString("{\\"error\\": \\"Unknown tool\\"}")
                    }
                }
                
                return makeCString("{\\"error\\": \\"Unknown capability\\"}")
            }
            ```
            """ : """
            ```rust
            extern "C" fn invoke(ctx: *mut c_void, type_ptr: *const c_char, id_ptr: *const c_char, payload_ptr: *const c_char) -> *const c_char {
                // ... existing code ...
                
                if type_str == "tool" {
                    match id_str {
                        "hello_world" => make_c_string(&ctx.hello_tool.run(payload)),
                        "my_tool" => make_c_string(&ctx.my_tool.run(payload)),
                        _ => make_c_string(r#"{"error": "Unknown tool"}"#),
                    }
                } else {
                    make_c_string(r#"{"error": "Unknown capability"}"#)
                }
            }
            ```
            """)

            ## Using Secrets (API Keys)

            If your plugin needs API keys or other credentials, declare them in the manifest and access them via the `_secrets` key in the payload.

            ### Step 1: Declare Secrets in Manifest

            Add a `secrets` array at the top level of your manifest:

            ```json
            {
              "plugin_id": "dev.example.\(name)",
              "name": "\(displayName)",
              "version": "0.1.0",
              "secrets": [
                {
                  "id": "api_key",
                  "label": "API Key",
                  "description": "Get your key from [Example](https://example.com/api)",
                  "required": true,
                  "url": "https://example.com/api"
                }
              ],
              "capabilities": { ... }
            }
            ```

            ### Step 2: Access Secrets in Your Tool

            \(isSwift ? """
            ```swift
            private struct MyAPITool {
                let name = "call_api"
                
                struct Args: Decodable {
                    let query: String
                    let _secrets: [String: String]?  // Secrets injected by Osaurus
                }
                
                func run(args: String) -> String {
                    guard let data = args.data(using: .utf8),
                          let input = try? JSONDecoder().decode(Args.self, from: data)
                    else {
                        return "{\\"error\\": \\"Invalid arguments\\"}"
                    }
                    
                    // Get the API key
                    guard let apiKey = input._secrets?["api_key"] else {
                        return "{\\"error\\": \\"API key not configured\\"}"
                    }
                    
                    // Use the API key in your request
                    let result = makeAPICall(apiKey: apiKey, query: input.query)
                    return "{\\"result\\": \\"\\(result)\\"}"
                }
            }
            ```
            """ : """
            ```rust
            fn run(&self, args: &str) -> String {
                #[derive(Deserialize)]
                struct Args {
                    query: String,
                    _secrets: Option<HashMap<String, String>>,
                }
                
                let input: Args = match serde_json::from_str(args) {
                    Ok(v) => v,
                    Err(_) => return r#"{"error": "Invalid arguments"}"#.to_string(),
                };
                
                // Get the API key
                let api_key = match input._secrets.as_ref().and_then(|s| s.get("api_key")) {
                    Some(key) => key,
                    None => return r#"{"error": "API key not configured"}"#.to_string(),
                };
                
                // Use the API key
                let result = self.make_api_call(api_key, &input.query);
                format!(r#"{{"result": "{}"}}"#, result)
            }
            ```
            """)

            ### Secret Fields

            | Field | Type | Required | Description |
            |-------|------|----------|-------------|
            | `id` | string | Yes | Unique key (e.g., "api_key") |
            | `label` | string | Yes | Display name in UI |
            | `description` | string | No | Help text (supports markdown links) |
            | `required` | boolean | Yes | Whether the secret is required |
            | `url` | string | No | Link to get the secret |

            ### User Experience

            - Users are prompted to configure secrets when installing plugins that require them
            - A "Needs API Key" badge appears if required secrets are missing
            - Users can edit secrets anytime via the plugin menu
            - Secrets are stored securely in the macOS Keychain

            ## Using Folder Context (Working Directory)

            When a user has a working directory selected in Work Mode, Osaurus automatically injects the folder context into tool payloads. This allows your plugin to resolve relative file paths.

            ### Automatic Injection

            When a folder context is active, every tool invocation receives a `_context` object:

            ```json
            {
              "input_path": "Screenshots/image.png",
              "_context": {
                "working_directory": "/Users/foo/project"
              }
            }
            ```

            ### Accessing Folder Context in Your Tool

            \(isSwift ? """
            ```swift
            private struct MyFileTool {
                let name = "process_file"
                
                struct FolderContext: Decodable {
                    let working_directory: String
                }
                
                struct Args: Decodable {
                    let path: String
                    let _context: FolderContext?  // Folder context injected by Osaurus
                }
                
                func run(args: String) -> String {
                    guard let data = args.data(using: .utf8),
                          let input = try? JSONDecoder().decode(Args.self, from: data)
                    else {
                        return "{\\"error\\": \\"Invalid arguments\\"}"
                    }
                    
                    // Resolve relative path using working directory
                    let absolutePath: String
                    if let workingDir = input._context?.working_directory {
                        absolutePath = "\\(workingDir)/\\(input.path)"
                    } else {
                        // No folder context - assume absolute path or return error
                        absolutePath = input.path
                    }
                    
                    // SECURITY: Validate path stays within working directory
                    if let workingDir = input._context?.working_directory {
                        let resolvedPath = URL(fileURLWithPath: absolutePath).standardized.path
                        guard resolvedPath.hasPrefix(workingDir) else {
                            return "{\\"error\\": \\"Path outside working directory\\"}"
                        }
                    }
                    
                    // Process the file at absolutePath...
                    return "{\\"success\\": true}"
                }
            }
            ```
            """ : """
            ```rust
            fn run(&self, args: &str) -> String {
                #[derive(Deserialize)]
                struct FolderContext {
                    working_directory: String,
                }
                
                #[derive(Deserialize)]
                struct Args {
                    path: String,
                    _context: Option<FolderContext>,
                }
                
                let input: Args = match serde_json::from_str(args) {
                    Ok(v) => v,
                    Err(_) => return r#"{"error": "Invalid arguments"}"#.to_string(),
                };
                
                // Resolve relative path
                let absolute_path = match &input._context {
                    Some(ctx) => format!("{}/{}", ctx.working_directory, input.path),
                    None => input.path.clone(),
                };
                
                // SECURITY: Validate path stays within working directory
                if let Some(ctx) = &input._context {
                    let resolved = std::path::Path::new(&absolute_path).canonicalize();
                    if let Ok(resolved) = resolved {
                        if !resolved.starts_with(&ctx.working_directory) {
                            return r#"{"error": "Path outside working directory"}"#.to_string();
                        }
                    }
                }
                
                // Process the file...
                r#"{"success": true}"#.to_string()
            }
            ```
            """)

            ### Security Considerations

            - **Always validate paths** stay within `working_directory` to prevent directory traversal
            - The LLM is instructed to use relative paths for file operations
            - Reject paths that attempt to escape (e.g., `../../../etc/passwd`)
            - If `_context` is absent, decide whether to require it or accept absolute paths

            ### Context Fields

            | Field | Type | Description |
            |-------|------|-------------|
            | `working_directory` | string | Absolute path to the user's selected folder |

            ## Porting Existing Tools

            ### From MCP (Model Context Protocol)

            MCP tools map directly to Osaurus tools:

            | MCP Concept | Osaurus Equivalent |
            |-------------|-------------------|
            | Tool name | `id` in manifest |
            | Input schema | `parameters` (JSON Schema) |
            | Tool handler | `run()` method in tool struct |
            | Response | JSON string return value |

            Example MCP tool conversion:
            ```json
            // MCP tool definition
            {
              "name": "get_weather",
              "description": "Get weather for a location",
              "inputSchema": {
                "type": "object",
                "properties": {
                  "location": { "type": "string" }
                },
                "required": ["location"]
              }
            }
            ```

            Becomes this Osaurus manifest entry:
            ```json
            {
              "id": "get_weather",
              "description": "Get weather for a location",
              "parameters": {
                "type": "object",
                "properties": {
                  "location": { "type": "string" }
                },
                "required": ["location"]
              },
              "requirements": [],
              "permission_policy": "ask"
            }
            ```

            ### From CLI Tools

            Wrap command-line tools using Process/subprocess:

            \(isSwift ? """
            ```swift
            func run(args: String) -> String {
                guard let input = parseArgs(args) else {
                    return "{\\"error\\": \\"Invalid arguments\\"}"
                }
                
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/some-cli")
                process.arguments = [input.flag, input.value]
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    
                    if process.terminationStatus == 0 {
                        return "{\\"output\\": \\"\\(output.escapedForJSON)\\"}"
                    } else {
                        return "{\\"error\\": \\"Command failed: \\(output.escapedForJSON)\\"}"
                    }
                } catch {
                    return "{\\"error\\": \\"\\(error.localizedDescription)\\"}"
                }
            }
            ```
            """ : """
            ```rust
            fn run(&self, args: &str) -> String {
                let input: Args = match serde_json::from_str(args) {
                    Ok(v) => v,
                    Err(_) => return r#"{"error": "Invalid arguments"}"#.to_string(),
                };
                
                let output = std::process::Command::new("/usr/bin/some-cli")
                    .args(&[&input.flag, &input.value])
                    .output();
                
                match output {
                    Ok(out) if out.status.success() => {
                        let stdout = String::from_utf8_lossy(&out.stdout);
                        format!(r#"{{"output": "{}"}}"#, escape_json(&stdout))
                    }
                    Ok(out) => {
                        let stderr = String::from_utf8_lossy(&out.stderr);
                        format!(r#"{{"error": "{}"}}"#, escape_json(&stderr))
                    }
                    Err(e) => format!(r#"{{"error": "{}"}}"#, e),
                }
            }
            ```
            """)

            ### From Web APIs

            Make HTTP requests to wrap external APIs:

            \(isSwift ? """
            ```swift
            func run(args: String) -> String {
                guard let input = parseArgs(args) else {
                    return "{\\"error\\": \\"Invalid arguments\\"}"
                }
                
                // Use synchronous URLSession for plugin context
                let semaphore = DispatchSemaphore(value: 0)
                var result = "{\\"error\\": \\"Request failed\\"}"
                
                let url = URL(string: "https://api.example.com/endpoint")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONEncoder().encode(input)
                
                URLSession.shared.dataTask(with: request) { data, response, error in
                    defer { semaphore.signal() }
                    
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) {
                        result = String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
                    }
                }.resume()
                
                semaphore.wait()
                return result
            }
            ```
            """ : """
            ```rust
            fn run(&self, args: &str) -> String {
                let input: Args = match serde_json::from_str(args) {
                    Ok(v) => v,
                    Err(_) => return r#"{"error": "Invalid arguments"}"#.to_string(),
                };
                
                // Use blocking HTTP client (reqwest with blocking feature)
                let client = reqwest::blocking::Client::new();
                let response = client
                    .post("https://api.example.com/endpoint")
                    .json(&input)
                    .send();
                
                match response {
                    Ok(resp) => match resp.json::<serde_json::Value>() {
                        Ok(json) => json.to_string(),
                        Err(e) => format!(r#"{{"error": "{}"}}"#, e),
                    },
                    Err(e) => format!(r#"{{"error": "{}"}}"#, e),
                }
            }
            ```
            """)

            ## Testing Workflow

            ### 1. Build the Plugin

            \(isSwift ? """
            ```bash
            swift build -c release
            ```
            """ : """
            ```bash
            cargo build --release
            ```
            """)

            ### 2. Verify Manifest

            Extract and validate the manifest JSON:

            ```bash
            osaurus manifest extract .build/release/lib\(name).dylib
            ```

            Check for:
            - Valid JSON structure
            - All tools have unique `id` values
            - Parameters use valid JSON Schema
            - Version follows semver (e.g., "0.1.0")

            ### 3. Test Locally

            Package and install for local testing:

            ```bash
            # Package the plugin
            osaurus tools package dev.example.\(name) 0.1.0

            # Install locally
            osaurus tools install ./dev.example.\(name)-0.1.0.zip

            # Verify installation
            osaurus tools verify
            ```

            ### 4. Test in Osaurus

            1. Open Osaurus app
            2. Go to Tools settings (Cmd+Shift+M → Tools)
            3. Verify your plugin appears
            4. Test each tool by asking the AI to use it

            ### 5. Iterate

            After making changes:
            ```bash
            swift build -c release && osaurus tools package dev.example.\(name) 0.1.0 && osaurus tools install ./dev.example.\(name)-0.1.0.zip
            ```

            ## Best Practices

            ### JSON Schema for Parameters

            - Always specify `type` for each property
            - Use `description` to help the AI understand parameter purpose
            - Mark truly required fields in `required` array
            - Use appropriate types: `string`, `number`, `integer`, `boolean`, `array`, `object`

            ```json
            {
              "type": "object",
              "properties": {
                "query": {
                  "type": "string",
                  "description": "Search query text"
                },
                "limit": {
                  "type": "integer",
                  "description": "Maximum results to return",
                  "default": 10
                },
                "filters": {
                  "type": "array",
                  "items": { "type": "string" },
                  "description": "Optional filter tags"
                }
              },
              "required": ["query"]
            }
            ```

            ### Error Handling

            Always return valid JSON, even for errors:

            ```json
            {"error": "Clear description of what went wrong"}
            ```

            For detailed errors:
            ```json
            {"error": "Validation failed", "details": {"field": "query", "message": "Cannot be empty"}}
            ```

            ### Tool Naming

            - Use `snake_case` for tool IDs: `get_weather`, `search_files`
            - Be descriptive but concise
            - Prefix related tools: `github_create_issue`, `github_list_repos`

            ### Permission Policies

            | Policy | When to Use |
            |--------|-------------|
            | `ask` | Default. User confirms each execution |
            | `auto` | Safe, read-only operations |
            | `deny` | Dangerous operations (use sparingly) |

            ### System Requirements

            Add to `requirements` array when your tool needs:

            | Requirement | Use Case |
            |-------------|----------|
            | `automation` | AppleScript, controlling other apps |
            | `accessibility` | UI automation, input simulation |
            | `calendar` | Reading/writing calendar events |
            | `contacts` | Accessing contact information |
            | `location` | Getting user's location |
            | `disk` | Full disk access (Messages, Safari data) |
            | `reminders` | Reading/writing reminders |
            | `notes` | Accessing Notes app |
            | `maps` | Controlling Maps app |

            ## Submission Checklist

            Before submitting to the Osaurus plugin registry:

            - [ ] Plugin builds without warnings
            - [ ] `osaurus manifest extract` returns valid JSON
            - [ ] All tools have clear descriptions
            - [ ] Parameters use proper JSON Schema
            - [ ] Error cases return valid JSON errors
            - [ ] Version follows semver (X.Y.Z)
            - [ ] plugin_id follows reverse-domain format (com.yourname.pluginname)
            - [ ] README.md documents all tools
            - [ ] Code is signed with Developer ID (for distribution)

            ### Code Signing (Required for Distribution)

            ```bash
            codesign --force --options runtime --timestamp \\
              --sign "Developer ID Application: Your Name (TEAMID)" \\
              .build/release/lib\(name).dylib
            ```

            ### Registry Submission

            1. Fork the [osaurus-tools](https://github.com/osaurus-ai/osaurus-tools) repository
            2. Add `plugins/<your-plugin-id>.json` with metadata
            3. Submit a pull request

            ## Common Issues

            ### Plugin not loading

            - Check `osaurus manifest extract` for errors
            - Verify the dylib is properly signed
            - Check Console.app for loading errors

            ### Tool not appearing

            - Ensure tool is in manifest `capabilities.tools` array
            - Verify `invoke()` handles the tool ID
            - Check tool ID matches exactly (case-sensitive)

            ### JSON parsing errors

            - Validate JSON escaping in strings
            - Use proper encoding for special characters
            - Test with `echo '{"param":"value"}' | osaurus manifest extract ...`
            """
        try? claudeMd.write(to: dir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
    }
}
