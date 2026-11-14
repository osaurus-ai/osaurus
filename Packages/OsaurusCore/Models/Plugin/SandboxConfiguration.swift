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
    /// Legacy VM-wide network switch, kept so older files decode. Unused:
    /// each boot composes the network from the pod members' own Sandbox
    /// settings (`SandboxEgressPolicy.podNetwork(for:)`).
    public var network: String
    /// Legacy, unused; see `network`.
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
    /// Rootfs format (`SandboxRuntimeAssets.rootfsFormatVersion`) of the
    /// last successful boot; with the image digest, the warm-restart key.
    /// `nil` for installs that pre-date the split: their
    /// `lastRuntimeFormatVersion` was the rootfs key then, so it stands in.
    public var lastRootfsFormatVersion: String?
    /// Agents kept warm: how many agents and workflows get a container in
    /// the sandbox pod at once. Each container is cheap (tens of MB of
    /// host memory for a light workload); the VM's Memory is the real cap.
    public var maxAgentEnvironments: Int
    /// Environment clones (an agent's or workflow's rootfs with its apk
    /// packages) kept on disk. Least recently used clones beyond this are
    /// evicted after each successful boot and re-cloned on next use. Never
    /// below `maxAgentEnvironments`.
    public var maxRetainedEnvironments: Int
    /// Minutes the VM may run with no work before it stops; 0 = never.
    public var idleShutdownMinutes: Int

    /// The pre-split default for `maxAgentEnvironments`. A file written
    /// before `maxRetainedEnvironments` existed with this value was never
    /// changed by the user, so it moves to the RAM-scaled default.
    static let legacyDefaultContainersPerBoot = 3
    public static let defaultRetainedEnvironments = 16
    public static let retainedEnvironmentsRange = 1 ... 64

    /// Containers per boot scaled to this Mac's memory.
    public static func defaultContainersPerBoot(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        let gib = physicalMemory / (1 << 30)
        switch gib {
        case ..<16: return 4
        case ..<32: return 6
        default: return 8
        }
    }

    /// Clones actually kept: never fewer than the containers one boot uses.
    public var effectiveRetainedEnvironments: Int {
        Swift.max(maxRetainedEnvironments, maxAgentEnvironments, 1)
    }

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
        lastRootfsFormatVersion: nil,
        maxAgentEnvironments: defaultContainersPerBoot()
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
        lastRootfsFormatVersion: String? = nil,
        maxAgentEnvironments: Int = SandboxConfiguration.defaultContainersPerBoot(),
        maxRetainedEnvironments: Int = SandboxConfiguration.defaultRetainedEnvironments,
        idleShutdownMinutes: Int = 0
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
        self.lastRootfsFormatVersion = lastRootfsFormatVersion
        self.maxAgentEnvironments = maxAgentEnvironments
        self.maxRetainedEnvironments = maxRetainedEnvironments
        self.idleShutdownMinutes = idleShutdownMinutes
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
        lastRootfsFormatVersion =
            try container.decodeIfPresent(String.self, forKey: .lastRootfsFormatVersion)
        let retained = try container.decodeIfPresent(Int.self, forKey: .maxRetainedEnvironments)
        let containers = try container.decodeIfPresent(Int.self, forKey: .maxAgentEnvironments)
        if let containers, !(retained == nil && containers == Self.legacyDefaultContainersPerBoot) {
            maxAgentEnvironments = containers
        } else {
            maxAgentEnvironments = Self.defaultContainersPerBoot()
        }
        maxRetainedEnvironments = retained ?? Self.defaultRetainedEnvironments
        idleShutdownMinutes = try container.decodeIfPresent(Int.self, forKey: .idleShutdownMinutes) ?? 0
    }
}

// MARK: - Store

public struct SandboxConfigurationStore {
    private static var configURL: URL {
        OsaurusPaths.sandboxConfigFile()
    }

    /// Sandbox fields Osaurus Classic drops when it saves `sandbox.json`.
    static let classicUnknownFields: [ClassicResaveRecovery.FieldPath] = [
        ["lastRootfsFormatVersion"],
        ["maxRetainedEnvironments"],
        ["idleShutdownMinutes"],
    ]

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
                ClassicResaveRecovery.recordWrite(data, to: url)
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

    static func resetCacheForTests() {
        cacheLock.lock()
        cachedValue = nil
        cacheLock.unlock()
    }

    private static func readFromDisk() -> SandboxConfiguration {
        guard let data = try? Data(contentsOf: configURL) else {
            return .default
        }
        let restored = ClassicResaveRecovery.restoring(data, at: configURL, fields: classicUnknownFields)
        return (try? JSONDecoder().decode(SandboxConfiguration.self, from: restored)) ?? .default
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
    /// Bytes of each stream an exec collects in app memory. Far above any
    /// model-facing cap, so file reads through exec stay whole; past it the
    /// rest is dropped and `outputTruncated` is set.
    public static let collectedStreamCapBytes = 32 << 20

    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    /// Some output passed `collectedStreamCapBytes` and was dropped. A caller
    /// that needs the exact bytes (reading a file to edit it) must refuse.
    public let outputTruncated: Bool

    public var succeeded: Bool { exitCode == 0 }

    public init(stdout: String, stderr: String, exitCode: Int32, outputTruncated: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.outputTruncated = outputTruncated
    }

    /// The result with each secret value replaced in both streams.
    func scrubbed(_ secrets: [String: String]) -> ContainerExecResult {
        guard !secrets.isEmpty else { return self }
        return ContainerExecResult(
            stdout: SecretScrubber.scrub(stdout, secrets: secrets),
            stderr: SecretScrubber.scrub(stderr, secrets: secrets),
            exitCode: exitCode, outputTruncated: outputTruncated)
    }
}

/// An exec stream's in-memory copy, bounded so a process that prints
/// forever can't grow the app without limit.
struct ExecOutputCapture {
    let cap: Int
    private(set) var buffer = Data()
    private(set) var truncated = false

    init(cap: Int = ContainerExecResult.collectedStreamCapBytes) {
        self.cap = cap
    }

    mutating func append(_ data: Data) {
        let room = cap - buffer.count
        if data.count <= room {
            buffer.append(data)
        } else {
            if room > 0 { buffer.append(data.prefix(room)) }
            truncated = true
        }
    }

    /// UTF-8 text of the capture. A cut can split a multi-byte sequence, so
    /// a truncated capture decodes leniently.
    var string: String {
        if let text = String(data: buffer, encoding: .utf8) { return text }
        return truncated ? String(decoding: buffer, as: UTF8.self) : ""
    }
}
