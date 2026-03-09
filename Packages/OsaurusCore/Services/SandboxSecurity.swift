//
//  SandboxSecurity.swift
//  osaurus
//
//  Security hardening for the sandbox environment.
//  - Network allowlist enforcement during setup
//  - Host API rate limiting per agent
//  - Per-turn exec command limiting
//  - File path sanitization
//  - Auto-created plugin restrictions
//

import Foundation

// MARK: - Setup Network Allowlist

public enum SandboxNetworkPolicy {
    /// Domains allowed during plugin setup (package registries only)
    public static let setupAllowlist: Set<String> = [
        "dl-cdn.alpinelinux.org",  // Alpine APK repos
        "pypi.org",  // PyPI
        "files.pythonhosted.org",  // PyPI downloads
        "registry.npmjs.org",  // npm
        "github.com",  // GitHub releases
        "objects.githubusercontent.com",  // GitHub downloads
        "crates.io",  // Rust crates
        "static.crates.io",
    ]

    /// Validates that a plugin's setup command doesn't attempt to reach
    /// non-allowed domains. Returns a list of violations.
    public static func validateSetupCommand(_ command: String) -> [String] {
        var violations: [String] = []
        // Check for curl/wget with non-allowed hosts
        let urlPattern = /https?:\/\/([^\/\s:]+)/
        let matches = command.matches(of: urlPattern)
        for match in matches {
            let host = String(match.1)
            if !setupAllowlist.contains(host) {
                violations.append("Setup references non-allowed host: \(host)")
            }
        }
        return violations
    }
}

// MARK: - Rate Limiter

/// Per-agent rate limiter for Host API calls.
public final class SandboxRateLimiter: @unchecked Sendable {
    public static let shared = SandboxRateLimiter()

    public struct Limits: Sendable {
        public var inferencePerMinute: Int = 60
        public var httpPerMinute: Int = 120
        public var dispatchPerMinute: Int = 10
    }

    private let lock = NSLock()
    /// agentId:service -> [timestamps]
    private var windows: [String: [Date]] = [:]
    private var limits = Limits()

    private init() {}

    public func configure(_ limits: Limits) {
        lock.withLock { self.limits = limits }
    }

    /// Check if a request is allowed. Returns true if within limits.
    public func checkLimit(agent: String, service: String) -> Bool {
        let key = "\(agent):\(service)"
        let now = Date()
        let windowStart = now.addingTimeInterval(-60)

        return lock.withLock {
            var timestamps = windows[key] ?? []
            timestamps = timestamps.filter { $0 > windowStart }

            let limit: Int
            switch service {
            case "inference": limit = limits.inferencePerMinute
            case "http": limit = limits.httpPerMinute
            case "dispatch": limit = limits.dispatchPerMinute
            default: limit = 120
            }

            guard timestamps.count < limit else { return false }
            timestamps.append(now)
            windows[key] = timestamps
            return true
        }
    }

    public func reset() {
        lock.withLock { windows.removeAll() }
    }
}

// MARK: - File Path Sanitizer

public enum SandboxPathSanitizer {
    /// Validates and sanitizes a file path for use in the container.
    /// Returns nil if the path is unsafe.
    public static func sanitize(_ path: String, agentHome: String) -> String? {
        // Reject empty paths
        guard !path.isEmpty else { return nil }

        // Reject obvious traversal attempts
        if path.contains("..") { return nil }

        // Reject null bytes
        if path.contains("\0") { return nil }

        // Reject shell metacharacters in path (includes quotes to prevent
        // breaking out of single-quoted shell arguments)
        let dangerous: Set<Character> = [";", "|", "&", "$", "`", "(", ")", "{", "}", "'", "\"", "\\"]
        if path.contains(where: { dangerous.contains($0) }) { return nil }

        if path.hasPrefix("/") {
            // Absolute path: must be within allowed prefixes
            let allowedPrefixes = [
                agentHome,
                "/workspace/shared",
                "/output",
            ]
            guard allowedPrefixes.contains(where: { path.hasPrefix($0) }) else { return nil }
            return path
        }

        // Relative path: resolve against agent home
        return "\(agentHome)/\(path)"
    }

    /// Validate the `files` dictionary of a sandbox plugin.
    public static func validatePluginFiles(_ files: [String: String]?) -> [String] {
        guard let files = files else { return [] }
        var errors: [String] = []
        for path in files.keys {
            if path.contains("..") {
                errors.append("Path contains '..': \(path)")
            }
            if path.hasPrefix("/") {
                errors.append("Absolute path not allowed: \(path)")
            }
            if path.isEmpty {
                errors.append("Empty path")
            }
            if path.contains("\0") {
                errors.append("Path contains null byte: \(path)")
            }
        }
        return errors
    }
}

// MARK: - Auto-Created Plugin Restrictions

public enum SandboxPluginDefaults {
    /// Apply restricted defaults to agent-created plugins.
    public static func applyRestrictedDefaults(_ plugin: inout SandboxPlugin) {
        // No network during setup (prevents exfiltration)
        if plugin.permissions == nil {
            plugin.permissions = SandboxPermissions()
        }
        plugin.permissions?.network = "none"
        plugin.permissions?.inference = false

        // No secrets allowed
        plugin.secrets = nil
    }
}

// MARK: - Per-Turn Exec Limiter

/// Enforces `maxCommandsPerTurn` for sandbox exec tools.
/// Counts commands per agent and auto-resets after an idle gap, which
/// naturally aligns with turn boundaries (new LLM response cycles).
public final class SandboxExecLimiter: @unchecked Sendable {
    public static let shared = SandboxExecLimiter()

    private let lock = NSLock()
    /// agentName -> (count, lastExecTime)
    private var counters: [String: (count: Int, lastExec: Date)] = [:]
    private static let idleResetInterval: TimeInterval = 15

    /// Check whether the agent is allowed to execute another command.
    /// Returns true if within the limit, false if the limit is exceeded.
    public func checkAndIncrement(agentName: String, limit: Int) -> Bool {
        let now = Date()
        return lock.withLock {
            var entry = counters[agentName] ?? (count: 0, lastExec: .distantPast)

            if now.timeIntervalSince(entry.lastExec) > Self.idleResetInterval {
                entry = (count: 0, lastExec: now)
            }

            entry.count += 1
            entry.lastExec = now
            counters[agentName] = entry

            return entry.count <= limit
        }
    }

    public func reset(agentName: String) {
        lock.withLock { _ = counters.removeValue(forKey: agentName) }
    }

    public func resetAll() {
        lock.withLock { counters.removeAll() }
    }
}

// MARK: - Daemon Backoff

/// Tracks daemon restart attempts for backoff enforcement.
public actor SandboxDaemonMonitor {
    public static let shared = SandboxDaemonMonitor()

    private struct DaemonState {
        var restartTimes: [Date] = []
        var isBlocked: Bool = false
    }

    /// pluginId -> state
    private var daemons: [String: DaemonState] = [:]

    private static let maxRestarts = 5
    private static let windowSeconds: TimeInterval = 300  // 5 minutes

    /// Record a daemon restart. Returns false if the daemon should be blocked.
    public func recordRestart(pluginId: String) -> Bool {
        var state = daemons[pluginId] ?? DaemonState()
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.windowSeconds)

        state.restartTimes = state.restartTimes.filter { $0 > cutoff }
        state.restartTimes.append(now)

        if state.restartTimes.count > Self.maxRestarts {
            state.isBlocked = true
            daemons[pluginId] = state
            NSLog("[SandboxDaemon] Plugin \(pluginId) blocked: exceeded \(Self.maxRestarts) restarts in 5 minutes")
            return false
        }

        daemons[pluginId] = state
        return true
    }

    /// Reset the blocked state for a daemon.
    public func unblock(pluginId: String) {
        daemons[pluginId]?.isBlocked = false
        daemons[pluginId]?.restartTimes = []
    }

    /// Check if a daemon is currently blocked.
    public func isBlocked(pluginId: String) -> Bool {
        daemons[pluginId]?.isBlocked ?? false
    }
}
