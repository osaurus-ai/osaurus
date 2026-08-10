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
    /// "outbound" (default, unrestricted NAT), "proxy" (host-only vmnet +
    /// filtering egress proxy, domains in `allowedDomains`), or "none".
    public var network: String
    /// Egress domain allowlist for `network == "proxy"`. Mirrors the
    /// provisioning agent's `sandboxAllowedDomains` at boot the same way
    /// `network` mirrors `sandboxNetworkEnabled`.
    public var allowedDomains: [String]?
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
    /// Runtime format version (`SandboxRuntimeAssets.runtimeFormatVersion`)
    /// of the last successful boot. The warm-restart key is the pair
    /// (image digest, runtime format): a Containerization SDK or initfs
    /// delivery change invalidates the cached rootfs/initfs *before* a
    /// doomed warm boot is attempted, instead of failing into the cold
    /// rebuild at runtime. `nil` for installs that pre-date this field —
    /// treated as a mismatch so the first boot after upgrade is cold.
    public var lastRuntimeFormatVersion: String?
    /// Staged-rollout flag for per-agent copy-on-write rootfs environments.
    /// `false` (default) keeps today's single shared mutable `rootfs.ext4`.
    /// `true` boots the VM from the provisioning agent's own CoW clone of
    /// the immutable base template (`SandboxRootfsTemplateStore`), giving
    /// each agent persistent system-package state without sharing a
    /// globally mutable root filesystem. Rollback is turning this off —
    /// the shared-rootfs path is untouched.
    public var perAgentEnvironments: Bool
    /// LRU bound on retained per-agent environment clones. Least recently
    /// used clones beyond this are evicted after each successful boot (they
    /// re-clone from the template on next use). Only meaningful when
    /// `perAgentEnvironments` is on.
    public var maxAgentEnvironments: Int

    public static let `default` = SandboxConfiguration(
        cpus: 2,
        memoryGB: 2,
        network: "outbound",
        allowedDomains: nil,
        autoStart: true,
        setupComplete: false,
        lastProvisionedAppVersion: nil,
        lastBootDurations: nil,
        lastBootedImageDigest: nil,
        lastRuntimeFormatVersion: nil,
        perAgentEnvironments: false,
        maxAgentEnvironments: 3
    )

    public init(
        cpus: Int = 2,
        memoryGB: Int = 2,
        network: String = "outbound",
        allowedDomains: [String]? = nil,
        autoStart: Bool = true,
        setupComplete: Bool = false,
        lastProvisionedAppVersion: String? = nil,
        lastBootDurations: [String: Double]? = nil,
        lastBootedImageDigest: String? = nil,
        lastRuntimeFormatVersion: String? = nil,
        perAgentEnvironments: Bool = false,
        maxAgentEnvironments: Int = 3
    ) {
        self.cpus = cpus
        self.memoryGB = memoryGB
        self.network = network
        self.allowedDomains = allowedDomains
        self.autoStart = autoStart
        self.setupComplete = setupComplete
        self.lastProvisionedAppVersion = lastProvisionedAppVersion
        self.lastBootDurations = lastBootDurations
        self.lastBootedImageDigest = lastBootedImageDigest
        self.lastRuntimeFormatVersion = lastRuntimeFormatVersion
        self.perAgentEnvironments = perAgentEnvironments
        self.maxAgentEnvironments = maxAgentEnvironments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpus = try container.decode(Int.self, forKey: .cpus)
        memoryGB = try container.decode(Int.self, forKey: .memoryGB)
        network = try container.decode(String.self, forKey: .network)
        allowedDomains = try container.decodeIfPresent([String].self, forKey: .allowedDomains)
        autoStart = try container.decode(Bool.self, forKey: .autoStart)
        setupComplete = try container.decodeIfPresent(Bool.self, forKey: .setupComplete) ?? true
        lastProvisionedAppVersion =
            try container.decodeIfPresent(String.self, forKey: .lastProvisionedAppVersion)
        lastBootDurations =
            try container.decodeIfPresent([String: Double].self, forKey: .lastBootDurations)
        lastBootedImageDigest =
            try container.decodeIfPresent(String.self, forKey: .lastBootedImageDigest)
        lastRuntimeFormatVersion =
            try container.decodeIfPresent(String.self, forKey: .lastRuntimeFormatVersion)
        perAgentEnvironments =
            try container.decodeIfPresent(Bool.self, forKey: .perAgentEnvironments) ?? false
        maxAgentEnvironments =
            try container.decodeIfPresent(Int.self, forKey: .maxAgentEnvironments) ?? 3
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

    /// Persist without blocking the caller. The in-memory cache updates
    /// synchronously so `load()` stays coherent; the encode + atomic write
    /// happen on a background serial queue (mirrors `ToolConfigurationStore`),
    /// so a save from the main actor never stalls the UI on `rename(2)`.
    /// Rapid bursts coalesce to a single last-writer-wins write.
    public static func save(_ config: SandboxConfiguration) {
        cacheLock.lock()
        cachedValue = config
        cacheLock.unlock()
        let url = configURL
        writeQueue.async {
            OsaurusPaths.ensureExistsSilent(OsaurusPaths.config())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try encoder.encode(config)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[SandboxConfig] Failed to save: \(error)")
            }
        }
    }

    /// Synchronously drain any pending background write. Call before process
    /// exit so a save made moments before quitting still lands on disk.
    public static func flushPendingWrites(timeout: TimeInterval = 1.5) {
        let done = DispatchSemaphore(value: 0)
        writeQueue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    private static let writeQueue = DispatchQueue(
        label: "com.osaurus.sandboxconfig.write", qos: .utility)

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
