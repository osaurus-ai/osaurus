//
//  ExternalPlugin.swift
//  osaurus
//
//  Represents a loaded plugin instance using the generic C ABI.
//

import Foundation

// MARK: - C ABI Mirror

typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

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

struct osr_plugin_api {
    var free_string: osr_free_string_t?
    var `init`: osr_init_t?
    var destroy: osr_destroy_t?
    var get_manifest: osr_get_manifest_t?
    var invoke: osr_invoke_t?
}

// Entry point type. We use an opaque raw pointer here to keep the C function
// type Objective-C representable, and rebind it to `osr_plugin_api` in Swift.
typealias osr_plugin_entry_t = @convention(c) () -> UnsafeRawPointer?

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
        // Future: providers, apps, etc.
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
}

final class ExternalPlugin: @unchecked Sendable {
    let id: String
    let manifest: PluginManifest
    let bundlePath: String

    private let handle: UnsafeMutableRawPointer
    private let api: osr_plugin_api
    private let ctx: osr_plugin_ctx_t

    init(
        handle: UnsafeMutableRawPointer,
        api: osr_plugin_api,
        ctx: osr_plugin_ctx_t,
        manifest: PluginManifest,
        path: String
    ) {
        self.handle = handle
        self.api = api
        self.ctx = ctx
        self.manifest = manifest
        self.bundlePath = path
        self.id = manifest.plugin_id
    }

    deinit {
        api.destroy?(ctx)
        // Handle is managed by PluginManager usually.
    }

    func invoke(type: String, id: String, payload: String) throws -> String {
        guard let invokeFn = api.invoke else {
            throw NSError(
                domain: "ExternalPlugin",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invoke not implemented"]
            )
        }

        let resPtr = type.withCString { typePtr in
            id.withCString { idPtr in
                payload.withCString { payloadPtr in
                    invokeFn(ctx, typePtr, idPtr, payloadPtr)
                }
            }
        }

        guard let resPtr = resPtr else {
            // Null return might mean error or empty?
            // ABI says generic invocation returns JSON string response.
            // If it returns NULL, maybe we assume empty object or error?
            // Let's assume empty JSON object for now or throw.
            throw NSError(
                domain: "ExternalPlugin",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Plugin returned NULL response"]
            )
        }

        defer {
            api.free_string?(resPtr)
        }

        return String(cString: resPtr)
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
