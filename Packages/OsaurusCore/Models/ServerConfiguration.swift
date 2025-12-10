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
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
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

    /// Appearance mode (system, light, or dark)
    public var appearanceMode: AppearanceMode

    /// Number of threads for the event loop group
    public let numberOfThreads: Int

    /// Server backlog size
    public let backlog: Int32

    // MARK: - Generation Settings (UI adjustable)
    /// Default top-p sampling for generation (can be overridden per request)
    public var genTopP: Float
    /// KV cache quantization bits (nil to disable)
    public var genKVBits: Int?
    /// KV cache quantization group size
    public var genKVGroupSize: Int
    /// Token offset to begin quantizing KV cache
    public var genQuantizedKVStart: Int
    /// Maximum KV cache size (tokens); nil for unlimited
    public var genMaxKVSize: Int?
    /// Prefill step size (tokens per prefill chunk)
    public var genPrefillStepSize: Int

    /// List of allowed origins for CORS. Empty disables CORS. Use "*" to allow any origin.
    public var allowedOrigins: [String]

    private enum CodingKeys: String, CodingKey {
        case port
        case exposeToNetwork
        case startAtLogin
        case appearanceMode
        case numberOfThreads
        case backlog
        case genTopP
        case genKVBits
        case genKVGroupSize
        case genQuantizedKVStart
        case genMaxKVSize
        case genPrefillStepSize
        case allowedOrigins
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerConfiguration.default
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        self.exposeToNetwork =
            try container.decodeIfPresent(Bool.self, forKey: .exposeToNetwork) ?? defaults.exposeToNetwork
        self.startAtLogin =
            try container.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? defaults.startAtLogin
        self.appearanceMode =
            try container.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode) ?? defaults.appearanceMode
        self.numberOfThreads =
            try container.decodeIfPresent(Int.self, forKey: .numberOfThreads) ?? defaults.numberOfThreads
        self.backlog = try container.decodeIfPresent(Int32.self, forKey: .backlog) ?? defaults.backlog
        self.genTopP = try container.decodeIfPresent(Float.self, forKey: .genTopP) ?? defaults.genTopP
        self.genKVBits = try container.decodeIfPresent(Int.self, forKey: .genKVBits)
        self.genKVGroupSize =
            try container.decodeIfPresent(Int.self, forKey: .genKVGroupSize) ?? defaults.genKVGroupSize
        self.genQuantizedKVStart =
            try container.decodeIfPresent(Int.self, forKey: .genQuantizedKVStart)
            ?? defaults.genQuantizedKVStart
        self.genMaxKVSize = try container.decodeIfPresent(Int.self, forKey: .genMaxKVSize)
        self.genPrefillStepSize =
            try container.decodeIfPresent(Int.self, forKey: .genPrefillStepSize)
            ?? defaults.genPrefillStepSize
        self.allowedOrigins =
            try container.decodeIfPresent([String].self, forKey: .allowedOrigins)
            ?? defaults.allowedOrigins
    }

    public init(
        port: Int,
        exposeToNetwork: Bool,
        startAtLogin: Bool,
        appearanceMode: AppearanceMode = .system,
        numberOfThreads: Int,
        backlog: Int32,
        genTopP: Float,
        genKVBits: Int?,
        genKVGroupSize: Int,
        genQuantizedKVStart: Int,
        genMaxKVSize: Int?,
        genPrefillStepSize: Int,
        allowedOrigins: [String] = []
    ) {
        self.port = port
        self.exposeToNetwork = exposeToNetwork
        self.startAtLogin = startAtLogin
        self.appearanceMode = appearanceMode
        self.numberOfThreads = numberOfThreads
        self.backlog = backlog
        self.genTopP = genTopP
        self.genKVBits = genKVBits
        self.genKVGroupSize = genKVGroupSize
        self.genQuantizedKVStart = genQuantizedKVStart
        self.genMaxKVSize = genMaxKVSize
        self.genPrefillStepSize = genPrefillStepSize
        self.allowedOrigins = allowedOrigins
    }

    /// Default configuration
    public static var `default`: ServerConfiguration {
        ServerConfiguration(
            port: 1337,
            exposeToNetwork: false,  // Default to false (localhost)
            startAtLogin: false,
            appearanceMode: .system,  // Default to system appearance
            numberOfThreads: ProcessInfo.processInfo.activeProcessorCount,
            backlog: 256,
            genTopP: 1.0,
            genKVBits: nil,
            genKVGroupSize: 64,
            genQuantizedKVStart: 0,
            genMaxKVSize: nil,
            genPrefillStepSize: 512,
            allowedOrigins: []
        )
    }

    /// Validates if the port is in valid range
    public var isValidPort: Bool {
        (1 ..< 65536).contains(port)
    }
}
