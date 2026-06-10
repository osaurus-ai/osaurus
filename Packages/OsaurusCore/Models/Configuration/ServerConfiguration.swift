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
    public static let defaultModelLoadRAMSoftThreshold = 0.70
    public static let defaultModelLoadRAMHardThreshold = 0.90

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

    // KV cache quantization (kvBits, kvGroupSize, quantizedKVStart, turboQuant)
    // and prefill step sizing are owned by the vmlx-swift package.

    /// List of allowed origins for CORS. Empty disables CORS. Use "*" to allow any origin.
    public var allowedOrigins: [String]

    /// Optional validated proxy endpoint used by outbound URLSession traffic.
    public var globalProxyURL: String?

    /// Memory management policy for loaded models
    public var modelEvictionPolicy: ModelEvictionPolicy

    /// Idle memory residency policy for loaded local models.
    public var modelIdleResidencyPolicy: ModelIdleResidencyPolicy

    /// Projected physical-memory fraction above which a model load is marked tight.
    public var modelLoadRAMSoftThreshold: Double

    /// Projected physical-memory fraction above which a model load is marked
    /// very tight. This is advisory telemetry, not a load/download block.
    public var modelLoadRAMHardThreshold: Double

    /// Maximum HTTP request body size, in bytes, accepted by the public
    /// server before it returns `413 Payload Too Large`. Caps memory
    /// pressure from unauthenticated clients sending oversized bodies.
    /// Default: 32 MiB (generous for multimodal chat completions).
    public var maxRequestBodyBytes: Int

    /// Tighter ceiling for `POST /pair`, which is unauthenticated and
    /// only ever carries a small JSON envelope. A 64 KiB cap is several
    /// orders of magnitude more than a real pairing request needs.
    public var maxPairingBodyBytes: Int

    private enum CodingKeys: String, CodingKey {
        case port
        case exposeToNetwork
        case startAtLogin
        case hideDockIcon
        case appearanceMode
        case numberOfThreads
        case backlog
        case genTopP
        case allowedOrigins
        case globalProxyURL
        case modelEvictionPolicy
        case modelIdleResidencyPolicy
        case modelLoadRAMSoftThreshold
        case modelLoadRAMHardThreshold
        case maxRequestBodyBytes
        case maxPairingBodyBytes
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
        self.allowedOrigins =
            try container.decodeIfPresent([String].self, forKey: .allowedOrigins)
            ?? defaults.allowedOrigins
        self.globalProxyURL = try container.decodeIfPresent(String.self, forKey: .globalProxyURL)
        self.modelEvictionPolicy =
            try container.decodeIfPresent(ModelEvictionPolicy.self, forKey: .modelEvictionPolicy)
            ?? defaults.modelEvictionPolicy
        self.modelIdleResidencyPolicy =
            (try? container.decodeIfPresent(ModelIdleResidencyPolicy.self, forKey: .modelIdleResidencyPolicy))
            ?? defaults.modelIdleResidencyPolicy
        let decodedSoft =
            try container.decodeIfPresent(Double.self, forKey: .modelLoadRAMSoftThreshold)
            ?? defaults.modelLoadRAMSoftThreshold
        let decodedHard =
            try container.decodeIfPresent(Double.self, forKey: .modelLoadRAMHardThreshold)
            ?? defaults.modelLoadRAMHardThreshold
        let normalized = Self.normalizedModelLoadRAMThresholds(
            soft: decodedSoft,
            hard: decodedHard
        )
        self.modelLoadRAMSoftThreshold = normalized.soft
        self.modelLoadRAMHardThreshold = normalized.hard
        self.maxRequestBodyBytes =
            try container.decodeIfPresent(Int.self, forKey: .maxRequestBodyBytes)
            ?? defaults.maxRequestBodyBytes
        self.maxPairingBodyBytes =
            try container.decodeIfPresent(Int.self, forKey: .maxPairingBodyBytes)
            ?? defaults.maxPairingBodyBytes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(port, forKey: .port)
        try container.encode(exposeToNetwork, forKey: .exposeToNetwork)
        try container.encode(startAtLogin, forKey: .startAtLogin)
        try container.encode(hideDockIcon, forKey: .hideDockIcon)
        try container.encode(appearanceMode, forKey: .appearanceMode)
        try container.encode(numberOfThreads, forKey: .numberOfThreads)
        try container.encode(backlog, forKey: .backlog)
        try container.encode(genTopP, forKey: .genTopP)
        try container.encode(allowedOrigins, forKey: .allowedOrigins)
        try container.encodeIfPresent(globalProxyURL, forKey: .globalProxyURL)
        try container.encode(modelEvictionPolicy, forKey: .modelEvictionPolicy)
        try container.encode(modelIdleResidencyPolicy, forKey: .modelIdleResidencyPolicy)
        try container.encode(modelLoadRAMSoftThreshold, forKey: .modelLoadRAMSoftThreshold)
        try container.encode(modelLoadRAMHardThreshold, forKey: .modelLoadRAMHardThreshold)
        try container.encode(maxRequestBodyBytes, forKey: .maxRequestBodyBytes)
        try container.encode(maxPairingBodyBytes, forKey: .maxPairingBodyBytes)
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
        allowedOrigins: [String] = [],
        globalProxyURL: String? = nil,
        modelEvictionPolicy: ModelEvictionPolicy = .strictSingleModel,
        modelIdleResidencyPolicy: ModelIdleResidencyPolicy = .defaultWarm,
        modelLoadRAMSoftThreshold: Double = Self.defaultModelLoadRAMSoftThreshold,
        modelLoadRAMHardThreshold: Double = Self.defaultModelLoadRAMHardThreshold,
        maxRequestBodyBytes: Int = 32 * 1024 * 1024,
        maxPairingBodyBytes: Int = 64 * 1024
    ) {
        self.port = port
        self.exposeToNetwork = exposeToNetwork
        self.startAtLogin = startAtLogin
        self.hideDockIcon = hideDockIcon
        self.appearanceMode = appearanceMode
        self.numberOfThreads = numberOfThreads
        self.backlog = backlog
        self.genTopP = genTopP
        self.allowedOrigins = allowedOrigins
        self.globalProxyURL = globalProxyURL
        self.modelEvictionPolicy = modelEvictionPolicy
        self.modelIdleResidencyPolicy = modelIdleResidencyPolicy
        let normalized = Self.normalizedModelLoadRAMThresholds(
            soft: modelLoadRAMSoftThreshold,
            hard: modelLoadRAMHardThreshold
        )
        self.modelLoadRAMSoftThreshold = normalized.soft
        self.modelLoadRAMHardThreshold = normalized.hard
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.maxPairingBodyBytes = maxPairingBodyBytes
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
            allowedOrigins: [],
            globalProxyURL: nil,
            modelEvictionPolicy: .strictSingleModel,
            modelIdleResidencyPolicy: .defaultWarm,
            modelLoadRAMSoftThreshold: Self.defaultModelLoadRAMSoftThreshold,
            modelLoadRAMHardThreshold: Self.defaultModelLoadRAMHardThreshold,
            maxRequestBodyBytes: 32 * 1024 * 1024,
            maxPairingBodyBytes: 64 * 1024
        )
    }

    public static func normalizedModelLoadRAMThresholds(
        soft: Double,
        hard: Double
    ) -> (soft: Double, hard: Double) {
        let safeSoft = soft.isFinite ? soft : Self.defaultModelLoadRAMSoftThreshold
        let safeHard = hard.isFinite ? hard : Self.defaultModelLoadRAMHardThreshold
        let clampedSoft = min(max(safeSoft, 0.0), 1.0)
        let clampedHard = min(max(safeHard, 0.0), 1.0)
        return (min(clampedSoft, clampedHard), max(clampedSoft, clampedHard))
    }

    /// Validates if the port is in valid range
    public var isValidPort: Bool {
        (1 ..< 65536).contains(port)
    }
}

/// User policy for keeping local model weights resident after the last stream
/// releases its lease.
public enum ModelIdleResidencyPolicy: Codable, Equatable, Hashable, Sendable {
    case immediately
    case afterSeconds(Int)
    case never

    private enum Mode: String, Codable {
        case immediately
        case afterSeconds = "after_seconds"
        case never
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case seconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(Mode.self, forKey: .mode)
        switch mode {
        case .immediately:
            self = .immediately
        case .afterSeconds:
            let decodedSeconds = try container.decode(Int.self, forKey: .seconds)
            self = .afterSeconds(Self.clampPersistedSeconds(decodedSeconds))
        case .never:
            self = .never
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .immediately:
            try container.encode(Mode.immediately, forKey: .mode)
        case .afterSeconds(let seconds):
            try container.encode(Mode.afterSeconds, forKey: .mode)
            try container.encode(Self.clampPersistedSeconds(seconds), forKey: .seconds)
        case .never:
            try container.encode(Mode.never, forKey: .mode)
        }
    }

    /// Default warm residency keeps local chat/API follow-up turns from paying
    /// a full cold load and losing per-model cache/coordinator state after
    /// every response. Immediate unload remains available as an explicit
    /// low-memory setting.
    public static let defaultWarm: ModelIdleResidencyPolicy = .afterSeconds(900)

    /// Settings picker presets.
    public static let presets: [ModelIdleResidencyPolicy] = [
        .afterSeconds(300),
        .defaultWarm,
        .afterSeconds(1_800),
        .afterSeconds(3_600),
        .immediately,
        .never,
    ]

    public var displayName: String {
        switch self {
        case .immediately:
            return L("Immediately")
        case .afterSeconds(300):
            return L("5 minutes")
        case .afterSeconds(900):
            return L("15 minutes")
        case .afterSeconds(1_800):
            return L("30 minutes")
        case .afterSeconds(3_600):
            return L("1 hour")
        case .afterSeconds(let seconds):
            let minutes = max(1, seconds / 60)
            return String(format: L("%d minutes"), minutes)
        case .never:
            return L("Never")
        }
    }

    public var description: String {
        switch self {
        case .immediately:
            return L("Unloads model memory as soon as no active chat window or generation lease keeps it warm.")
        case .afterSeconds(let seconds):
            return String(
                format: L("Keeps model memory resident for %d minutes after the last generation finishes."),
                max(1, seconds / 60)
            )
        case .never:
            return L("Keeps model memory resident until manual unload, model switch, memory cleanup, or quit.")
        }
    }

    public var seconds: Int? {
        switch self {
        case .immediately:
            return 0
        case .afterSeconds(let seconds):
            return seconds
        case .never:
            return nil
        }
    }

    private static func clampPersistedSeconds(_ seconds: Int) -> Int {
        min(max(seconds, 30), 86_400)
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
