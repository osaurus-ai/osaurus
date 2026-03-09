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

    public static let `default` = SandboxConfiguration(
        cpus: 2,
        memoryGB: 2,
        network: "outbound",
        autoStart: true
    )

    public init(
        cpus: Int = 2,
        memoryGB: Int = 2,
        network: String = "outbound",
        autoStart: Bool = true
    ) {
        self.cpus = cpus
        self.memoryGB = memoryGB
        self.network = network
        self.autoStart = autoStart
    }
}

// MARK: - Store

public struct SandboxConfigurationStore {
    private static var configURL: URL {
        OsaurusPaths.sandboxConfigFile()
    }

    public static func load() -> SandboxConfiguration {
        guard let data = try? Data(contentsOf: configURL) else {
            return .default
        }
        return (try? JSONDecoder().decode(SandboxConfiguration.self, from: data)) ?? .default
    }

    public static func save(_ config: SandboxConfiguration) {
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.config())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            NSLog("[SandboxConfig] Failed to save: \(error)")
        }
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
        case .notProvisioned: "Not Provisioned"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .error(let msg): "Error: \(msg)"
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
