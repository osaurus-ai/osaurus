//
//  ServerConfiguration.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation

/// Appearance mode setting for the app
public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var displayName: String {
        switch self {
        case .system: return L("System")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }
}

/// Configuration settings for the server
public struct ServerConfiguration: Codable, Equatable, Sendable {
    /// Server port (1-65535)
    public var port: Int

    /// Expose the server to the local network (0.0.0.0) or keep it on localhost (127.0.0.1)
    public var exposeToNetwork: Bool

    /// Start Osaurus automatically at login
    public var startAtLogin: Bool

    /// Hide the dock icon (run as accessory app)
    public var hideDockIcon: Bool

    /// Appearance mode (system, light, or dark)
    public var appearanceMode: AppearanceMode

    /// Number of threads for the event loop group
    public let numberOfThreads: Int

    /// Server backlog size
    public let backlog: Int32

    // MARK: - Generation Settings (UI adjustable)
    /// Default top-p sampling for generation (can be overridden per request)
    public var genTopP: Float

    /// Legacy: maximum KV cache size in tokens.
    ///
    /// No longer applied at runtime — vmlx-swift-lm's `CacheCoordinator` owns
    /// KV cache sizing per model (sliding-window vs global vs SSM layers each
    /// have their own per-layer cache geometry). Forcing a global rotating
    /// window from osaurus historically caused broadcast crashes on
    /// sliding-window models like Gemma-4. The field is decoded for backward
    /// compatibility with existing config files but the Settings UI no longer
    /// exposes it; new configs should leave it `nil`.
    public var genMaxKVSize: Int?

    // KV cache quantization (kvBits, kvGroupSize, quantizedKVStart, turboQuant)
    // and prefill step sizing are owned by the vmlx-swift-lm package.

    /// List of allowed origins for CORS. Empty disables CORS. Use "*" to allow any origin.
    public var allowedOrigins: [String]

    /// Memory management policy for loaded models
    public var modelEvictionPolicy: ModelEvictionPolicy

    private enum CodingKeys: String, CodingKey {
        case port
        case exposeToNetwork
        case startAtLogin
        case hideDockIcon
        case appearanceMode
        case numberOfThreads
        case backlog
        case genTopP
        case genMaxKVSize
        case allowedOrigins
        case modelEvictionPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerConfiguration.default
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        self.exposeToNetwork =
            try container.decodeIfPresent(Bool.self, forKey: .exposeToNetwork) ?? defaults.exposeToNetwork
        self.startAtLogin =
            try container.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? defaults.startAtLogin
        self.hideDockIcon =
            try container.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? defaults.hideDockIcon
        self.appearanceMode =
            try container.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode) ?? defaults.appearanceMode
        self.numberOfThreads =
            try container.decodeIfPresent(Int.self, forKey: .numberOfThreads) ?? defaults.numberOfThreads
        self.backlog = try container.decodeIfPresent(Int32.self, forKey: .backlog) ?? defaults.backlog
        self.genTopP = try container.decodeIfPresent(Float.self, forKey: .genTopP) ?? defaults.genTopP
        self.genMaxKVSize = try container.decodeIfPresent(Int.self, forKey: .genMaxKVSize)
        self.allowedOrigins =
            try container.decodeIfPresent([String].self, forKey: .allowedOrigins)
            ?? defaults.allowedOrigins
        self.modelEvictionPolicy =
            try container.decodeIfPresent(ModelEvictionPolicy.self, forKey: .modelEvictionPolicy)
            ?? defaults.modelEvictionPolicy
    }

    public init(
        port: Int,
        exposeToNetwork: Bool,
        startAtLogin: Bool,
        hideDockIcon: Bool = false,
        appearanceMode: AppearanceMode = .system,
        numberOfThreads: Int,
        backlog: Int32,
        genTopP: Float,
        genMaxKVSize: Int?,
        allowedOrigins: [String] = [],
        modelEvictionPolicy: ModelEvictionPolicy = .strictSingleModel
    ) {
        self.port = port
        self.exposeToNetwork = exposeToNetwork
        self.startAtLogin = startAtLogin
        self.hideDockIcon = hideDockIcon
        self.appearanceMode = appearanceMode
        self.numberOfThreads = numberOfThreads
        self.backlog = backlog
        self.genTopP = genTopP
        self.genMaxKVSize = genMaxKVSize
        self.allowedOrigins = allowedOrigins
        self.modelEvictionPolicy = modelEvictionPolicy
    }

    /// Default configuration
    public static var `default`: ServerConfiguration {
        ServerConfiguration(
            port: 1337,
            exposeToNetwork: false,
            startAtLogin: false,
            hideDockIcon: false,
            appearanceMode: .system,
            numberOfThreads: ProcessInfo.processInfo.activeProcessorCount,
            backlog: 256,
            genTopP: 1.0,
            genMaxKVSize: nil,
            allowedOrigins: [],
            modelEvictionPolicy: .strictSingleModel
        )
    }

    /// Validates if the port is in valid range
    public var isValidPort: Bool {
        (1 ..< 65536).contains(port)
    }
}

/// Policy for managing model eviction from memory
public enum ModelEvictionPolicy: String, Codable, CaseIterable, Sendable {
    /// Strictly keep only one model loaded at a time (safest for memory)
    case strictSingleModel = "Strict (One Model)"
    /// Allow multiple models (best for high RAM systems or rapid switching)
    case manualMultiModel = "Flexible (Multi Model)"

    public var displayName: String {
        switch self {
        case .strictSingleModel: return L("Strict (One Model)")
        case .manualMultiModel: return L("Flexible (Multi Model)")
        }
    }

    public var description: String {
        switch self {
        case .strictSingleModel:
            return L("Automatically unloads other models. Recommended for standard use.")
        case .manualMultiModel:
            return L("Keeps models loaded until manually unloaded. Requires 32GB+ RAM.")
        }
    }
}
