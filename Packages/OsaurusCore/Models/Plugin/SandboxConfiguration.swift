//
//  SandboxConfiguration.swift
//  osaurus
//
//  Persisted configuration for the shared Linux container.
//  Stored at ~/.osaurus/config/sandbox.json.
//

import Foundation

// MARK: - Configuration

public struct SandboxConfiguration: Codable, Sendable, Equatable {
    public var cpus: Int
    public var memoryGB: Int
    /// "outbound" (default) or "none"
    public var network: String
    public var autoStart: Bool
    /// True once the user has completed initial sandbox setup at least once.
    public var setupComplete: Bool
    /// `CFBundleShortVersionString` of the binary that last successfully
    /// provisioned this container. Used by the migration banner to tell the
    /// user when a security update needs them to restart the sandbox so the
    /// new shim and per-agent token files can be written into the guest.
    /// `nil` for installs that pre-date this field; treated as "needs
    /// restart" by `needsBridgeMigrationRestart`.
    public var lastProvisionedAppVersion: String?
    /// Per-step wall-clock duration (seconds) of the most recent
    /// *successful* provision. Keyed by `ProvisioningStepID.rawValue`
    /// so the model layer can stay free of the enum dependency in this
    /// header. Seeded on every `finishJourney(success: true)`; used to
    /// pre-populate the UI's ETA for inherently indeterminate steps
    /// (`configureSandbox`, `startContainer`) on subsequent boots.
    /// `nil` for installs that pre-date this field — the UI then shows
    /// "—" until the first successful run is recorded.
    public var lastBootDurations: [String: Double]?
    /// Image reference (`name@sha256:digest`) of the last container that
    /// booted successfully. Compared against the currently pinned image
    /// in `SandboxManager.provision()` to decide whether the on-disk
    /// `rootfs.ext4` can be reused (warm restart) or must be re-unpacked
    /// (cold restart after app update). `nil` for installs that pre-date
    /// this field — treated as "cold" so we conservatively re-unpack
    /// once after upgrade and then stamp the digest for future warm boots.
    public var lastBootedImageDigest: String?

    public static let `default` = SandboxConfiguration(
        cpus: 2,
        memoryGB: 2,
        network: "outbound",
        autoStart: true,
        setupComplete: false,
        lastProvisionedAppVersion: nil,
        lastBootDurations: nil,
        lastBootedImageDigest: nil
    )

    public init(
        cpus: Int = 2,
        memoryGB: Int = 2,
        network: String = "outbound",
        autoStart: Bool = true,
        setupComplete: Bool = false,
        lastProvisionedAppVersion: String? = nil,
        lastBootDurations: [String: Double]? = nil,
        lastBootedImageDigest: String? = nil
    ) {
        self.cpus = cpus
        self.memoryGB = memoryGB
        self.network = network
        self.autoStart = autoStart
        self.setupComplete = setupComplete
        self.lastProvisionedAppVersion = lastProvisionedAppVersion
        self.lastBootDurations = lastBootDurations
        self.lastBootedImageDigest = lastBootedImageDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpus = try container.decode(Int.self, forKey: .cpus)
        memoryGB = try container.decode(Int.self, forKey: .memoryGB)
        network = try container.decode(String.self, forKey: .network)
        autoStart = try container.decode(Bool.self, forKey: .autoStart)
        setupComplete = try container.decodeIfPresent(Bool.self, forKey: .setupComplete) ?? true
        lastProvisionedAppVersion =
            try container.decodeIfPresent(String.self, forKey: .lastProvisionedAppVersion)
        lastBootDurations =
            try container.decodeIfPresent([String: Double].self, forKey: .lastBootDurations)
        lastBootedImageDigest =
            try container.decodeIfPresent(String.self, forKey: .lastBootedImageDigest)
    }
}

// MARK: - Store

public struct SandboxConfigurationStore {
    private static var configURL: URL {
        OsaurusPaths.sandboxConfigFile()
    }

    /// Lock-guarded in-memory cache. `SandboxView` is destroyed and
    /// rebuilt every time the user clicks the Sandbox sidebar tab
    /// (`SidebarNavigation` uses `.id(selection)`), and the migration-flag
    /// helper plus `SandboxManager` also call `load()` from several other
    /// code paths. Without a cache each of those is a synchronous JSON
    /// disk read on the main thread. Save() writes through so any in-app
    /// mutation stays coherent. Osaurus never modifies sandbox.json from
    /// outside its own process, so we don't need invalidate-on-mtime.
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cachedValue: SandboxConfiguration?

    public static func load() -> SandboxConfiguration {
        cacheLock.lock()
        if let cached = cachedValue {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let loaded = readFromDisk()

        cacheLock.lock()
        if cachedValue == nil {
            cachedValue = loaded
        }
        let result = cachedValue ?? loaded
        cacheLock.unlock()
        return result
    }

    public static func save(_ config: SandboxConfiguration) {
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.config())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
            cacheLock.lock()
            cachedValue = config
            cacheLock.unlock()
        } catch {
            NSLog("[SandboxConfig] Failed to save: \(error)")
        }
    }

    private static func readFromDisk() -> SandboxConfiguration {
        guard let data = try? Data(contentsOf: configURL) else {
            return .default
        }
        return (try? JSONDecoder().decode(SandboxConfiguration.self, from: data)) ?? .default
    }
}

// MARK: - Availability

public enum SandboxAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

// MARK: - Container Status

public enum ContainerStatus: Sendable, Equatable {
    case notProvisioned
    case stopped
    case starting
    case running
    case error(String)

    public var label: String {
        switch self {
        case .notProvisioned: L("Not Provisioned")
        case .stopped: L("Stopped")
        case .starting: L("Starting")
        case .running: L("Running")
        case .error(let msg): L("Error: \(msg)")
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - Exec Result

public struct ContainerExecResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public var succeeded: Bool { exitCode == 0 }

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}
