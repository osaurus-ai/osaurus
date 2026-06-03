//
//  MCPChildSpawnLimiter.swift
//  osaurus
//
//  Process-wide cap on the number of concurrently-live MCP child processes
//  (both host-resident `MCPStdioHostRunner` and sandboxed `SandboxStdioRunner`
//  share this ceiling). Without a global cap, a misconfigured client or a
//  reconnect storm could spawn an unbounded number of `npx` / `uvx` / python
//  MCP servers and exhaust file descriptors, RAM, and PIDs. Each runner
//  acquires a slot before exec and releases it on teardown.
//

import Foundation

/// Thrown when a new MCP child would exceed the global concurrency cap.
public enum MCPChildSpawnError: LocalizedError, Sendable, Equatable {
    case tooManyChildren(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .tooManyChildren(let limit):
            return
                "Too many MCP servers are already running (limit: \(limit)). Stop an existing server before starting another."
        }
    }
}

/// Global gate for live MCP child processes. `acquire()` reserves a slot or
/// throws; `release()` returns it. Idempotent-safe at the call site via a
/// per-runner "slot held" flag so a double `stop()` can't under-count.
public actor MCPChildSpawnLimiter {
    public static let shared = MCPChildSpawnLimiter()

    /// Maximum number of concurrently-live MCP child processes across host
    /// and sandbox transports. Generous enough for normal multi-server
    /// setups, low enough to stop a launch storm.
    public static let maxConcurrentChildren = 32

    private var live = 0

    private init() {}

    /// Reserve a spawn slot. Throws `MCPChildSpawnError.tooManyChildren`
    /// when the global cap is already reached.
    public func acquire() throws {
        guard live < Self.maxConcurrentChildren else {
            throw MCPChildSpawnError.tooManyChildren(limit: Self.maxConcurrentChildren)
        }
        live += 1
    }

    /// Return a previously-acquired slot. Floors at zero defensively; callers
    /// guard against double-release with their own "slot held" flag.
    public func release() {
        if live > 0 { live -= 1 }
    }

    /// Current count of live MCP children. For diagnostics / `/health`.
    public func liveCount() -> Int { live }
}
