//
//  ExternalPlugin.swift
//  osaurus
//
//  Represents a loaded plugin instance using the generic C ABI.
//

import Foundation

// MARK: - C ABI Mirror

typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

// v1 function types
typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?

typealias osr_invoke_t =
    @convention(c) (
        osr_plugin_ctx_t?,  // ctx
        UnsafePointer<CChar>?,  // type
        UnsafePointer<CChar>?,  // id
        UnsafePointer<CChar>?  // payload
    ) -> UnsafePointer<CChar>?  // returns JSON string directly

// v2 function types
typealias osr_handle_route_t =
    @convention(c) (
        osr_plugin_ctx_t?,  // ctx
        UnsafePointer<CChar>?  // request_json
    ) -> UnsafePointer<CChar>?  // returns response JSON

typealias osr_on_config_changed_t =
    @convention(c) (
        osr_plugin_ctx_t?,  // ctx
        UnsafePointer<CChar>?,  // key
        UnsafePointer<CChar>?  // value
    ) -> Void

// Host API callback types (host → plugin, injected at init for v2)
typealias osr_config_get_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_config_set_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_config_delete_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_db_exec_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_db_query_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_log_t = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

struct osr_host_api {
    var version: UInt32
    var config_get: osr_config_get_t?
    var config_set: osr_config_set_t?
    var config_delete: osr_config_delete_t?
    var db_exec: osr_db_exec_t?
    var db_query: osr_db_query_t?
    var log: osr_log_t?
}

struct osr_plugin_api {
    // v1 fields
    var free_string: osr_free_string_t?
    var `init`: osr_init_t?
    var destroy: osr_destroy_t?
    var get_manifest: osr_get_manifest_t?
    var invoke: osr_invoke_t?
    // v2 fields (zeroed for v1 plugins)
    var version: UInt32
    var handle_route: osr_handle_route_t?
    var on_config_changed: osr_on_config_changed_t?
}

// Entry point types
typealias osr_plugin_entry_t = @convention(c) () -> UnsafeRawPointer?
typealias osr_plugin_entry_v2_t = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?

// MARK: - Swift Wrapper

public struct PluginManifest: Decodable, Sendable {
    public let plugin_id: String
    public let description: String?
    public let capabilities: Capabilities

    // Optional fields for registry
    public let name: String?
    public let version: String?
    public let license: String?
    public let authors: [String]?
    public let min_macos: String?
    public let min_osaurus: String?

    public struct Capabilities: Decodable, Sendable {
        public let tools: [ToolSpec]?
        public let routes: [RouteSpec]?
        public let config: ConfigSpec?
        public let web: WebSpec?
    }

    public struct ToolSpec: Decodable, Sendable {
        public let id: String
        public let description: String
        public let parameters: JSONValue?
        public let requirements: [String]?
        public let permission_policy: String?
    }

    /// Specification for a secret that a plugin requires (e.g., API key)
    public struct SecretSpec: Decodable, Sendable {
        /// Unique identifier for the secret (e.g., "api_key")
        public let id: String
        /// Display label for the secret (e.g., "API Key")
        public let label: String
        /// Rich text description with markdown links (e.g., "Get your key from [Example](https://example.com)")
        public let description: String?
        /// Whether this secret is required for the plugin to function
        public let required: Bool
        /// Optional URL to the settings page where users can obtain the secret
        public let url: String?

        public init(id: String, label: String, description: String? = nil, required: Bool = true, url: String? = nil) {
            self.id = id
            self.label = label
            self.description = description
            self.required = required
            self.url = url
        }
    }

    /// Plugin-level secrets (e.g., API keys, tokens)
    public let secrets: [SecretSpec]?

    /// Plugin documentation references
    public let docs: DocsSpec?

    // MARK: - Route Spec

    public enum RouteAuth: String, Decodable, Sendable {
        case none
        case verify
        case owner
    }

    public struct RouteSpec: Decodable, Sendable {
        public let id: String
        public let path: String
        public let methods: [String]
        public let description: String?
        public let auth: RouteAuth

        public init(id: String, path: String, methods: [String], description: String? = nil, auth: RouteAuth = .owner) {
            self.id = id
            self.path = path
            self.methods = methods
            self.description = description
            self.auth = auth
        }
    }

    // MARK: - Config Spec

    public struct ConfigSpec: Decodable, Sendable {
        public let title: String?
        public let sections: [ConfigSection]
    }

    public struct ConfigSection: Decodable, Sendable {
        public let title: String
        public let fields: [ConfigField]
    }

    public enum ConfigFieldType: String, Decodable, Sendable {
        case text
        case secret
        case toggle
        case select
        case multiselect
        case number
        case readonly
        case status
    }

    public struct ConfigFieldOption: Decodable, Sendable {
        public let value: String
        public let label: String
    }

    public struct ConnectAction: Decodable, Sendable {
        public let type: String?
        public let url_route: String?
    }

    public struct DisconnectAction: Decodable, Sendable {
        public let clear_keys: [String]?
    }

    public struct ValidationSpec: Decodable, Sendable {
        public let required: Bool?
        public let pattern: String?
        public let pattern_hint: String?
        public let min: Double?
        public let max: Double?
        public let min_length: Int?
        public let max_length: Int?
    }

    public struct ConfigField: Decodable, Sendable {
        public let key: String
        public let type: ConfigFieldType
        public let label: String
        public let placeholder: String?
        public let `default`: ConfigDefault?
        public let options: [ConfigFieldOption]?
        public let validation: ValidationSpec?
        public let connected_when: String?
        public let connect_action: ConnectAction?
        public let disconnect_action: DisconnectAction?
        public let value_template: String?
        public let copyable: Bool?
    }

    public enum ConfigDefault: Decodable, Sendable {
        case string(String)
        case bool(Bool)
        case number(Double)
        case stringArray([String])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let b = try? container.decode(Bool.self) { self = .bool(b); return }
            if let n = try? container.decode(Double.self) { self = .number(n); return }
            if let s = try? container.decode(String.self) { self = .string(s); return }
            if let a = try? container.decode([String].self) { self = .stringArray(a); return }
            throw DecodingError.typeMismatch(
                ConfigDefault.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported default value type")
            )
        }

        public var stringValue: String {
            switch self {
            case .string(let s): return s
            case .bool(let b): return b ? "true" : "false"
            case .number(let n): return String(n)
            case .stringArray(let a):
                let data = (try? JSONSerialization.data(withJSONObject: a)) ?? Data()
                return String(data: data, encoding: .utf8) ?? "[]"
            }
        }
    }

    // MARK: - Web Spec

    public struct WebSpec: Decodable, Sendable {
        public let static_dir: String
        public let entry: String
        public let mount: String
        public let auth: RouteAuth
    }

    // MARK: - Docs Spec

    public struct DocLink: Decodable, Sendable {
        public let label: String
        public let url: String
    }

    public struct DocsSpec: Decodable, Sendable {
        public let readme: String?
        public let changelog: String?
        public let links: [DocLink]?
    }

    // MARK: - Route Matching

    /// Finds the best matching route for a given HTTP method and subpath.
    /// The subpath is relative to the plugin's namespace (e.g., "/callback").
    public func matchRoute(method: String, subpath: String) -> RouteSpec? {
        guard let routes = capabilities.routes else { return nil }
        let normalizedMethod = method.uppercased()
        let normalizedPath = subpath.hasPrefix("/") ? subpath : "/\(subpath)"

        for route in routes {
            guard route.methods.contains(where: { $0.uppercased() == normalizedMethod }) else { continue }

            let routePath = route.path.hasPrefix("/") ? route.path : "/\(route.path)"
            if routePath.hasSuffix("/*") {
                let prefix = String(routePath.dropLast(2))
                if normalizedPath == prefix || normalizedPath.hasPrefix(prefix + "/") {
                    return route
                }
            } else if routePath == normalizedPath {
                return route
            }
        }
        return nil
    }
}

final class ExternalPlugin: @unchecked Sendable {
    let id: String
    let manifest: PluginManifest
    let bundlePath: String
    let abiVersion: UInt32

    private let handle: UnsafeMutableRawPointer
    private let api: osr_plugin_api
    private let ctx: osr_plugin_ctx_t

    /// Dedicated queue for plugin C ABI calls. Uses `.userInitiated` QoS to
    /// match the caller's priority and avoid priority inversions when the
    /// cooperative thread pool waits on the blocking C invocation.
    private static let invokeQueue = DispatchQueue(
        label: "com.osaurus.plugin.invoke",
        qos: .userInitiated
    )

    init(
        handle: UnsafeMutableRawPointer,
        api: osr_plugin_api,
        ctx: osr_plugin_ctx_t,
        manifest: PluginManifest,
        path: String,
        abiVersion: UInt32 = 1
    ) {
        self.handle = handle
        self.api = api
        self.ctx = ctx
        self.manifest = manifest
        self.bundlePath = path
        self.id = manifest.plugin_id
        self.abiVersion = abiVersion
    }

    var hasRouteHandler: Bool { abiVersion >= 2 && api.handle_route != nil }

    deinit {
        api.destroy?(ctx)
    }

    func invoke(type: String, id: String, payload: String) async throws -> String {
        guard let invokeFn = api.invoke else {
            throw NSError(
                domain: "ExternalPlugin",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invoke not implemented"]
            )
        }

        let freeString = api.free_string
        nonisolated(unsafe) let ctx = self.ctx
        let pluginId = self.id

        return try await withCheckedThrowingContinuation { continuation in
            ExternalPlugin.invokeQueue.async {
                PluginHostContext.setActivePlugin(pluginId)
                defer { PluginHostContext.clearActivePlugin() }

                let resPtr = type.withCString { typePtr in
                    id.withCString { idPtr in
                        payload.withCString { payloadPtr in
                            invokeFn(ctx, typePtr, idPtr, payloadPtr)
                        }
                    }
                }

                guard let resPtr else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "ExternalPlugin",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Plugin returned NULL response"]
                        )
                    )
                    return
                }

                let result = String(cString: resPtr)
                freeString?(resPtr)
                continuation.resume(returning: result)
            }
        }
    }

    func handleRoute(requestJSON: String) async throws -> String {
        guard abiVersion >= 2, let routeFn = api.handle_route else {
            throw NSError(
                domain: "ExternalPlugin",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Route handler not available (ABI v\(abiVersion))"]
            )
        }

        let freeString = api.free_string
        nonisolated(unsafe) let ctx = self.ctx
        let pluginId = self.id

        return try await withCheckedThrowingContinuation { continuation in
            ExternalPlugin.invokeQueue.async {
                PluginHostContext.setActivePlugin(pluginId)
                defer { PluginHostContext.clearActivePlugin() }

                let resPtr = requestJSON.withCString { reqPtr in
                    routeFn(ctx, reqPtr)
                }

                guard let resPtr else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "ExternalPlugin",
                            code: 4,
                            userInfo: [NSLocalizedDescriptionKey: "Plugin route handler returned NULL"]
                        )
                    )
                    return
                }

                let result = String(cString: resPtr)
                freeString?(resPtr)
                continuation.resume(returning: result)
            }
        }
    }

    func notifyConfigChanged(key: String, value: String) {
        guard abiVersion >= 2, let configFn = api.on_config_changed else { return }
        nonisolated(unsafe) let ctx = self.ctx
        let pluginId = self.id

        ExternalPlugin.invokeQueue.async {
            PluginHostContext.setActivePlugin(pluginId)
            defer { PluginHostContext.clearActivePlugin() }

            key.withCString { keyPtr in
                value.withCString { valuePtr in
                    configFn(ctx, keyPtr, valuePtr)
                }
            }
        }
    }

    /// Returns all configured secrets for this plugin from the Keychain
    /// - Returns: Dictionary mapping secret IDs to their values
    func resolvedSecrets() -> [String: String] {
        return ToolSecretsKeychain.getAllSecrets(for: manifest.plugin_id)
    }

    /// Checks if all required secrets are configured
    /// - Returns: True if all required secrets have values in the Keychain
    func hasAllRequiredSecrets() -> Bool {
        guard let specs = manifest.secrets else { return true }
        return ToolSecretsKeychain.hasAllRequiredSecrets(specs: specs, for: manifest.plugin_id)
    }
}
