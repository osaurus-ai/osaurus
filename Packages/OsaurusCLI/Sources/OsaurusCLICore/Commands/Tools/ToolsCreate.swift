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
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        scaffoldPlugin(name: name, language: language, rootDirectory: root)
        print("Created plugin scaffold at ./\(name)")
        exit(EXIT_SUCCESS)
    }

    // MARK: - Testable Entry Point

    static func scaffoldPlugin(name: String, language: String, rootDirectory: URL) {
        switch language {
        case "rust":
            createRustPlugin(name: name, rootDirectory: rootDirectory)
        default:
            createSwiftPlugin(name: name, rootDirectory: rootDirectory)
        }
    }

    // MARK: - Shared Helpers

    static func moduleName(from name: String) -> String {
        name.replacingOccurrences(of: "-", with: "_")
    }

    static func displayName(from name: String) -> String {
        name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func createWebPlaceholder(dir: URL, displayName: String) {
        let webDir = dir.appendingPathComponent("web", isDirectory: true)
        try? FileManager.default.createDirectory(at: webDir, withIntermediateDirectories: true)
        let indexHtml = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>\(displayName)</title>
            </head>
            <body>
                <h1>\(displayName)</h1>
                <p>Plugin web UI placeholder.</p>
            </body>
            </html>
            """
        try? indexHtml.write(to: webDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    private static func createReleaseWorkflow(dir: URL) {
        let workflowsDir =
            dir
            .appendingPathComponent(".github", isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
        try? FileManager.default.createDirectory(at: workflowsDir, withIntermediateDirectories: true)
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
        try? releaseYml.write(
            to: workflowsDir.appendingPathComponent("release.yml"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func createSwiftPlugin(name: String, rootDirectory: URL) {
        let fm = FileManager.default
        let dir = rootDirectory.appendingPathComponent(name, isDirectory: true)
        let sources = dir.appendingPathComponent("Sources", isDirectory: true)
        let moduleName = moduleName(from: name)
        let displayName = displayName(from: name)
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

        // Plugin.swift (v2 ABI)
        let pluginSwift = """
            import Foundation

            // MARK: - Osaurus Injected Context

            private struct FolderContext: Decodable {
                let working_directory: String
            }

            // MARK: - Tool Implementation

            private struct HelloTool {
                let name = "hello_world"
                let description = "Return a friendly greeting"
                
                func run(args: String) -> String {
                    struct Args: Decodable {
                        let name: String
                        let _secrets: [String: String]?
                        let _context: FolderContext?
                    }
                    guard let data = args.data(using: .utf8),
                          let input = try? JSONDecoder().decode(Args.self, from: data)
                    else {
                        return "{\\"error\\": \\"Invalid arguments\\"}"
                    }
                    return "{\\"message\\": \\"Hello, \\(input.name)!\\"}"
                }
            }

            // MARK: - C ABI Surface (v2)

            private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

            private typealias osr_config_get_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
            private typealias osr_config_set_fn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
            private typealias osr_config_delete_fn = @convention(c) (UnsafePointer<CChar>?) -> Void
            private typealias osr_db_exec_fn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
            private typealias osr_db_query_fn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
            private typealias osr_log_fn = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

            private struct osr_host_api {
                var version: UInt32
                var config_get: osr_config_get_fn?
                var config_set: osr_config_set_fn?
                var config_delete: osr_config_delete_fn?
                var db_exec: osr_db_exec_fn?
                var db_query: osr_db_query_fn?
                var log: osr_log_fn?
            }

            private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
            private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
            private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
            private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
            private typealias osr_invoke_t = @convention(c) (
                osr_plugin_ctx_t?,
                UnsafePointer<CChar>?,
                UnsafePointer<CChar>?,
                UnsafePointer<CChar>?
            ) -> UnsafePointer<CChar>?
            private typealias osr_handle_route_t = @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
            private typealias osr_on_config_changed_t = @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

            private struct osr_plugin_api {
                var free_string: osr_free_string_t?
                var `init`: osr_init_t?
                var destroy: osr_destroy_t?
                var get_manifest: osr_get_manifest_t?
                var invoke: osr_invoke_t?
                var version: UInt32
                var handle_route: osr_handle_route_t?
                var on_config_changed: osr_on_config_changed_t?
            }

            private var hostAPI: UnsafePointer<osr_host_api>?

            private class PluginContext {
                let tool = HelloTool()
            }

            private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
                return strdup(s)
            }

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
                    let manifest = \\"\\"\\"
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
                        ],
                        "routes": [
                          {
                            "id": "health",
                            "path": "/health",
                            "methods": ["GET"],
                            "description": "Health check endpoint",
                            "auth": "none"
                          }
                        ]
                      }
                    }
                    \\"\\"\\"
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
                
                api.version = 2
                
                api.handle_route = { ctxPtr, requestJsonPtr in
                    guard let requestJsonPtr = requestJsonPtr else { return nil }
                    let requestJson = String(cString: requestJsonPtr)
                    
                    struct RouteRequest: Decodable { let route_id: String }
                    guard let data = requestJson.data(using: .utf8),
                          let req = try? JSONDecoder().decode(RouteRequest.self, from: data)
                    else {
                        return makeCString("{\\"status\\":400}")
                    }
                    
                    switch req.route_id {
                    case "health":
                        let body: [String: Any] = ["ok": true]
                        let bodyData = try? JSONSerialization.data(withJSONObject: body)
                        let bodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        let resp: [String: Any] = [
                            "status": 200,
                            "headers": ["Content-Type": "application/json"],
                            "body": bodyStr,
                        ]
                        if let respData = try? JSONSerialization.data(withJSONObject: resp),
                           let respStr = String(data: respData, encoding: .utf8) {
                            return makeCString(respStr)
                        }
                        return makeCString("{\\"status\\":500}")
                    default:
                        return makeCString("{\\"status\\":404}")
                    }
                }
                
                api.on_config_changed = { _, _, _ in }
                
                return api
            }()

            @_cdecl("osaurus_plugin_entry_v2")
            public func osaurus_plugin_entry_v2(_ host: UnsafePointer<osr_host_api>?) -> UnsafeRawPointer? {
                hostAPI = host
                return UnsafeRawPointer(&api)
            }

            @_cdecl("osaurus_plugin_entry")
            public func osaurus_plugin_entry() -> UnsafeRawPointer? {
                return UnsafeRawPointer(&api)
            }
            """
        try? pluginSwift.write(to: pluginDir.appendingPathComponent("Plugin.swift"), atomically: true, encoding: .utf8)

        createWebPlaceholder(dir: dir, displayName: displayName)
        createReleaseWorkflow(dir: dir)

        let readme = """
            # \(name)

            An Osaurus plugin (v2 ABI).

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
               This creates `dev.example.\(name)-0.1.0.zip` including the dylib,
               `web/` directory, `README.md`, and any other companion files.
               
            4. Install locally:
               ```bash
               osaurus tools install ./dev.example.\(name)-0.1.0.zip
               ```

            5. Dev mode (hot reload):
               ```bash
               osaurus tools dev dev.example.\(name)
               # With web proxy for frontend HMR:
               osaurus tools dev dev.example.\(name) --web-proxy http://localhost:5173
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

            ## Plugin Structure

            This plugin uses the **v2 ABI** which supports:
            - **Tools** - AI-callable functions
            - **Routes** - HTTP endpoints (OAuth, webhooks, APIs)
            - **Config** - Persistent key-value storage via `host.config_get/set/delete`
            - **Database** - Per-plugin SQLite via `host.db_exec/db_query`
            - **Web** - Static frontend assets served from `web/`
            - **Logging** - Structured logging via `host.log`

            ## Important Notes

            - Plugin metadata is defined in `get_manifest()` in Plugin.swift
            - The zip filename determines the plugin_id and version during installation
            - Ensure the version in `get_manifest()` matches your zip filename
            - CI extracts the manifest from the built dylib automatically
            """
        try? readme.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        createClaudeMd(name: name, displayName: displayName, dir: dir, language: "swift")
    }

    private static func createRustPlugin(name: String, rootDirectory: URL) {
        let fm = FileManager.default
        let dir = rootDirectory.appendingPathComponent(name, isDirectory: true)
        let moduleName = moduleName(from: name)
        let displayName = displayName(from: name)

        // src/ directory
        let srcDir = dir.appendingPathComponent("src", isDirectory: true)
        try? fm.createDirectory(at: srcDir, withIntermediateDirectories: true)

        // Cargo.toml
        let cargoToml = """
            [package]
            name = "\(moduleName)"
            version = "0.1.0"
            edition = "2021"

            [lib]
            crate-type = ["cdylib"]

            [dependencies]
            serde = { version = "1", features = ["derive"] }
            serde_json = "1"
            """
        try? cargoToml.write(to: dir.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)

        // src/lib.rs (v2 ABI)
        let libRs = """
            use serde::Deserialize;
            use std::ffi::{c_char, c_void, CStr, CString};
            use std::ptr;

            // ── Host API (provided by Osaurus at init) ──

            type OsrConfigGetFn = unsafe extern "C" fn(*const c_char) -> *const c_char;
            type OsrConfigSetFn = unsafe extern "C" fn(*const c_char, *const c_char);
            type OsrConfigDeleteFn = unsafe extern "C" fn(*const c_char);
            type OsrDbExecFn = unsafe extern "C" fn(*const c_char, *const c_char) -> *const c_char;
            type OsrDbQueryFn = unsafe extern "C" fn(*const c_char, *const c_char) -> *const c_char;
            type OsrLogFn = unsafe extern "C" fn(i32, *const c_char);

            #[repr(C)]
            struct OsrHostApi {
                version: u32,
                config_get: Option<OsrConfigGetFn>,
                config_set: Option<OsrConfigSetFn>,
                config_delete: Option<OsrConfigDeleteFn>,
                db_exec: Option<OsrDbExecFn>,
                db_query: Option<OsrDbQueryFn>,
                log: Option<OsrLogFn>,
            }

            // ── Plugin API (returned to Osaurus) ──

            #[repr(C)]
            struct OsrPluginApi {
                free_string: Option<unsafe extern "C" fn(*const c_char)>,
                init: Option<unsafe extern "C" fn() -> *mut c_void>,
                destroy: Option<unsafe extern "C" fn(*mut c_void)>,
                get_manifest: Option<unsafe extern "C" fn(*mut c_void) -> *const c_char>,
                invoke: Option<unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char, *const c_char) -> *const c_char>,
                version: u32,
                handle_route: Option<unsafe extern "C" fn(*mut c_void, *const c_char) -> *const c_char>,
                on_config_changed: Option<unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char)>,
            }

            unsafe impl Sync for OsrPluginApi {}

            static mut HOST_API: *const OsrHostApi = ptr::null();

            static mut PLUGIN_API: OsrPluginApi = OsrPluginApi {
                free_string: Some(plugin_free_string),
                init: Some(plugin_init),
                destroy: Some(plugin_destroy),
                get_manifest: Some(plugin_get_manifest),
                invoke: Some(plugin_invoke),
                version: 2,
                handle_route: Some(plugin_handle_route),
                on_config_changed: Some(plugin_on_config_changed),
            };

            struct PluginContext;

            fn make_c_string(s: &str) -> *const c_char {
                CString::new(s)
                    .map(|cs| cs.into_raw() as *const c_char)
                    .unwrap_or(ptr::null())
            }

            unsafe fn read_c_str(ptr: *const c_char) -> String {
                if ptr.is_null() {
                    return String::new();
                }
                CStr::from_ptr(ptr).to_string_lossy().into_owned()
            }

            // ── Plugin API Implementation ──

            unsafe extern "C" fn plugin_free_string(s: *const c_char) {
                if !s.is_null() {
                    drop(CString::from_raw(s as *mut c_char));
                }
            }

            unsafe extern "C" fn plugin_init() -> *mut c_void {
                let ctx = Box::new(PluginContext);
                Box::into_raw(ctx) as *mut c_void
            }

            unsafe extern "C" fn plugin_destroy(ctx: *mut c_void) {
                if !ctx.is_null() {
                    drop(Box::from_raw(ctx as *mut PluginContext));
                }
            }

            unsafe extern "C" fn plugin_get_manifest(_ctx: *mut c_void) -> *const c_char {
                let manifest = r#"{
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
                ],
                "routes": [
                  {
                    "id": "health",
                    "path": "/health",
                    "methods": ["GET"],
                    "description": "Health check endpoint",
                    "auth": "none"
                  }
                ]
              }
            }"#;
                make_c_string(manifest)
            }

            unsafe extern "C" fn plugin_invoke(
                _ctx: *mut c_void,
                type_ptr: *const c_char,
                id_ptr: *const c_char,
                payload_ptr: *const c_char,
            ) -> *const c_char {
                let type_str = read_c_str(type_ptr);
                let id_str = read_c_str(id_ptr);
                let payload = read_c_str(payload_ptr);

                if type_str == "tool" && id_str == "hello_world" {
                    #[derive(Deserialize)]
                    struct Args {
                        name: String,
                    }
                    match serde_json::from_str::<Args>(&payload) {
                        Ok(args) => {
                            let resp = serde_json::json!({ "message": format!("Hello, {}!", args.name) });
                            return make_c_string(&resp.to_string());
                        }
                        Err(_) => return make_c_string(r#"{"error":"Invalid arguments"}"#),
                    }
                }

                make_c_string(r#"{"error":"Unknown capability"}"#)
            }

            unsafe extern "C" fn plugin_handle_route(
                _ctx: *mut c_void,
                request_json: *const c_char,
            ) -> *const c_char {
                let json_str = read_c_str(request_json);

                #[derive(Deserialize)]
                struct RouteRequest {
                    route_id: String,
                }

                let req: RouteRequest = match serde_json::from_str(&json_str) {
                    Ok(r) => r,
                    Err(_) => return make_c_string(r#"{"status":400}"#),
                };

                match req.route_id.as_str() {
                    "health" => {
                        let resp = serde_json::json!({
                            "status": 200,
                            "headers": { "Content-Type": "application/json" },
                            "body": r#"{"ok":true}"#,
                        });
                        make_c_string(&resp.to_string())
                    }
                    _ => make_c_string(r#"{"status":404}"#),
                }
            }

            unsafe extern "C" fn plugin_on_config_changed(
                _ctx: *mut c_void,
                _key: *const c_char,
                _value: *const c_char,
            ) {
            }

            // ── Entry Points ──

            #[no_mangle]
            pub unsafe extern "C" fn osaurus_plugin_entry_v2(
                host: *const OsrHostApi,
            ) -> *const OsrPluginApi {
                HOST_API = host;
                &raw const PLUGIN_API
            }

            #[no_mangle]
            pub unsafe extern "C" fn osaurus_plugin_entry() -> *const OsrPluginApi {
                &raw const PLUGIN_API
            }
            """
        try? libRs.write(to: srcDir.appendingPathComponent("lib.rs"), atomically: true, encoding: .utf8)

        createWebPlaceholder(dir: dir, displayName: displayName)
        createReleaseWorkflow(dir: dir)

        let readme = """
            # \(name)

            An Osaurus plugin (v2 ABI) written in Rust.

            ## Development

            1. Build:
               ```bash
               cargo build --release
               cp target/release/lib\(moduleName).dylib ./lib\(moduleName).dylib
               ```

            2. Extract manifest (to verify):
               ```bash
               osaurus manifest extract target/release/lib\(moduleName).dylib
               ```

            3. Package (for distribution):
               ```bash
               osaurus tools package dev.example.\(name) 0.1.0
               ```
               This creates `dev.example.\(name)-0.1.0.zip` including the dylib,
               `web/` directory, `README.md`, and any other companion files.

            4. Install locally:
               ```bash
               osaurus tools install ./dev.example.\(name)-0.1.0.zip
               ```

            5. Dev mode (hot reload):
               ```bash
               osaurus tools dev dev.example.\(name)
               ```

            ## Publishing

            This project includes a GitHub Actions workflow (`.github/workflows/release.yml`) that
            automatically builds and releases the plugin when you push a version tag.

            To release:
            ```bash
            git tag v0.1.0
            git push origin v0.1.0
            ```

            ## Plugin Structure

            This plugin uses the **v2 ABI** which supports:
            - **Tools** - AI-callable functions
            - **Routes** - HTTP endpoints (OAuth, webhooks, APIs)
            - **Config** - Persistent key-value storage via `host.config_get/set/delete`
            - **Database** - Per-plugin SQLite via `host.db_exec/db_query`
            - **Web** - Static frontend assets served from `web/`
            - **Logging** - Structured logging via `host.log`
            """
        try? readme.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        createClaudeMd(name: name, displayName: displayName, dir: dir, language: "rust")
    }

    // MARK: - AI Agent Guidance

    private static func createClaudeMd(name: String, displayName: String, dir: URL, language: String) {
        let moduleName = moduleName(from: name)
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
            ├── web/                       # Static frontend assets (v2)
            │   └── index.html
            ├── README.md                  # User-facing documentation
            ├── CLAUDE.md                  # This file (AI guidance)
            └── .github/
                └── workflows/
                    └── release.yml        # CI/CD for releases
            ```

            ## Architecture Overview

            Osaurus plugins use a C ABI interface (v2). The plugin exports `osaurus_plugin_entry_v2(host)` which receives
            host callbacks and returns a function table. A v1 fallback (`osaurus_plugin_entry`) is also exported for
            compatibility with older Osaurus versions.

            **Plugin API (returned to host):**
            - `init()` - Initialize plugin, return context pointer
            - `destroy(ctx)` - Clean up resources
            - `get_manifest(ctx)` - Return JSON describing plugin capabilities
            - `invoke(ctx, type, id, payload)` - Execute a tool with JSON payload
            - `handle_route(ctx, request_json)` - Handle HTTP route requests (v2)
            - `on_config_changed(ctx, key, value)` - React to config changes (v2)
            - `free_string(s)` - Free strings returned to host
            - `version` - Set to `2` for v2 plugins

            **Host API (provided to plugin at init):**
            - `config_get(key)` / `config_set(key, value)` / `config_delete(key)` - Keychain-backed config
            - `db_exec(sql, params_json)` / `db_query(sql, params_json)` - Per-plugin SQLite
            - `log(level, message)` - Structured logging

            ## Adding HTTP Routes

            v2 plugins can handle HTTP requests at `/plugins/<plugin_id>/<subpath>`.

            ### Step 1: Declare Routes in Manifest

            Add routes to `capabilities.routes` in `get_manifest()`:

            ```json
            "routes": [
              {
                "id": "webhook",
                "path": "/events",
                "methods": ["POST"],
                "description": "Incoming webhook handler",
                "auth": "verify"
              },
              {
                "id": "app",
                "path": "/app/*",
                "methods": ["GET"],
                "description": "Web UI",
                "auth": "owner"
              }
            ]
            ```

            Route auth levels: `none` (public), `verify` (rate-limited), `owner` (requires logged-in user).

            ### Step 2: Handle in handle_route()

            The host calls `handle_route(ctx, request_json)` with a JSON-encoded request containing
            `route_id`, `method`, `path`, `query`, `headers`, `body`, and `plugin_id`.

            Return a JSON-encoded response with `status`, `headers`, and `body`.

            ## Using Host Storage

            v2 plugins receive host callbacks for persistent storage:

            \(isSwift ? """
            ```swift
            // Read config (Keychain-backed)
            if let getValue = hostAPI?.pointee.config_get {
                let result = getValue(makeCString("my_setting"))
                // result is a C string or nil
            }

            // Write config
            if let setValue = hostAPI?.pointee.config_set {
                setValue(makeCString("my_setting"), makeCString("value"))
            }

            // Query per-plugin SQLite database
            if let dbQuery = hostAPI?.pointee.db_query {
                let result = dbQuery(makeCString("SELECT * FROM items"), makeCString("[]"))
                // result is JSON string
            }

            // Structured logging
            if let log = hostAPI?.pointee.log {
                log(0, makeCString("Plugin initialized"))  // 0=debug, 1=info, 2=warn, 3=error
            }
            ```
            """ : """
            ```rust
            unsafe {
                // Read config (Keychain-backed)
                if let Some(config_get) = (*HOST_API).config_get {
                    let result = config_get(make_c_string("my_setting"));
                    // result is a C string or null
                }

                // Write config
                if let Some(config_set) = (*HOST_API).config_set {
                    config_set(make_c_string("my_setting"), make_c_string("value"));
                }

                // Query per-plugin SQLite database
                if let Some(db_query) = (*HOST_API).db_query {
                    let result = db_query(make_c_string("SELECT * FROM items"), make_c_string("[]"));
                    // result is JSON string
                }

                // Structured logging
                if let Some(log) = (*HOST_API).log {
                    log(0, make_c_string("Plugin initialized"));  // 0=debug, 1=info, 2=warn, 3=error
                }
            }
            ```
            """)

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
