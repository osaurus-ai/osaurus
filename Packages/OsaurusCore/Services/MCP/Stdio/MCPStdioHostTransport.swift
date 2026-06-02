//
//  MCPStdioHostTransport.swift
//  osaurus
//
//  Host-resident stdio transport for MCP servers added directly by the user.
//
//  This file is intentionally a thin wrapper around `MCP.StdioTransport`:
//    - We spawn the configured `command + args` as a child `Process`.
//    - We connect its `stdin` / `stdout` to two pipes that we own.
//    - We hand the pipe file descriptors to `MCP.StdioTransport`, which
//      already knows how to do the JSON-RPC framing.
//
//  This transport is **only** used when the provider's `executionHost == .host`.
//  Imported plugins force `.sandbox`, which goes through `MCPStdioSandboxTransport`
//  / `SandboxStdioRunner` instead. The UI surfaces a clear warning before a user
//  manually switches a provider to `.host`.
//

#if canImport(Darwin)

    import Foundation
    import MCP
    import System

    /// Spawn-and-pipe wrapper that ends up holding (a) the running `Process`
    /// and (b) the `MCP.StdioTransport` connected to its stdio. Callers
    /// retain the runner; killing it shuts down the subprocess.
    public actor MCPStdioHostRunner {
        public let providerId: UUID
        public let command: String
        public let args: [String]

        private let process: Process
        private let stdinPipe: Pipe
        private let stdoutPipe: Pipe

        /// The transport object the `MCP.Client` connects to. Owned by the
        /// runner so its file descriptors stay alive for the subprocess's
        /// lifetime.
        public let transport: StdioTransport

        public init(provider: MCPProvider) throws {
            guard !provider.command.isEmpty else {
                throw MCPStdioTransportError.missingCommand
            }
            self.providerId = provider.id
            self.command = provider.command
            self.args = provider.args

            let mergedEnv = Self.buildEnv(provider: provider)
            let executablePath = try Self.resolveExecutablePath(
                command: provider.command,
                env: mergedEnv
            )

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = provider.args
            process.environment = mergedEnv
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            // Inherit stderr — MCP servers tend to log diagnostic JSON there
            // and we surface it in the host logs (which the user can tail).
            process.standardError = FileHandle.standardError
            if let cwd = provider.workingDirectory, !cwd.isEmpty {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }

            self.process = process
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe

            // Wrap the pipe FDs in `MCP.StdioTransport`. The transport reads
            // from the subprocess's stdout (our `stdoutPipe.fileHandleForReading`)
            // and writes to its stdin (our `stdinPipe.fileHandleForWriting`).
            let readFD = FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor)
            let writeFD = FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
            self.transport = StdioTransport(input: readFD, output: writeFD)
        }

        /// Process env = inherited app env merged with the provider's
        /// own env (plain + Keychain-resolved secrets). Provider entries
        /// win on key conflicts.
        private static func buildEnv(provider: MCPProvider) -> [String: String] {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in provider.resolvedEnv() {
                env[key] = value
            }
            return env
        }

        /// Resolve `command` to an absolute path the kernel can exec.
        /// For absolute / relative paths we trust the caller; for bare
        /// names we walk the provider's `PATH` ourselves and surface a
        /// typed `commandNotFound` error if nothing matches. Going
        /// through `/usr/bin/env` would hide ENOENT inside the env exec
        /// (env itself spawns fine, then exits non-zero), which is why
        /// we'd previously never see a useful error for nvm / asdf users.
        private static func resolveExecutablePath(
            command: String,
            env: [String: String]
        ) throws -> String {
            if command.contains("/") {
                return command
            }
            let searchPath = env["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
            guard let found = resolveOnPath(command, path: searchPath) else {
                throw MCPStdioTransportError.commandNotFound(
                    command: command,
                    searchedPath: searchPath
                )
            }
            return found
        }

        /// Set once a global spawn slot is held so `stop()` releases exactly
        /// one slot even if called twice.
        private var spawnSlotHeld = false

        /// Start the subprocess. Must be called before connecting `MCP.Client`
        /// to `transport`. Reserves a global MCP child-spawn slot first so a
        /// reconnect/launch storm can't exhaust PIDs/FDs.
        public func start() async throws {
            try await MCPChildSpawnLimiter.shared.acquire()
            spawnSlotHeld = true
            do {
                try process.run()
            } catch {
                // Release the slot we just reserved — the child never launched.
                await MCPChildSpawnLimiter.shared.release()
                spawnSlotHeld = false
                throw MCPStdioTransportError.processSpawnFailed(error.localizedDescription)
            }
        }

        /// Tear down the subprocess. Idempotent — safe to call from
        /// `disconnect()` paths even if `start()` failed.
        public func stop() async {
            await transport.disconnect()
            if process.isRunning {
                process.terminate()
            }
            if spawnSlotHeld {
                spawnSlotHeld = false
                await MCPChildSpawnLimiter.shared.release()
            }
        }

        public func isRunning() -> Bool {
            process.isRunning
        }

        /// Walk the colon-separated `path` looking for an executable named
        /// `command`. Returns the first hit's absolute path, or nil. Mirrors
        /// `/usr/bin/env`'s lookup just enough to give us a useful error
        /// before we hand off to `Process.run()`.
        private static func resolveOnPath(_ command: String, path: String) -> String? {
            let fm = FileManager.default
            for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
                let candidate = "\(dir)/\(command)"
                if fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
            return nil
        }
    }

    /// Errors specific to the host stdio path. Sandbox-path errors are
    /// emitted by `SandboxStdioRunner` so the two surfaces stay distinct.
    public enum MCPStdioTransportError: LocalizedError, Sendable, Equatable {
        case missingCommand
        case processSpawnFailed(String)
        case sandboxUnavailable
        /// Bare-name command (e.g. `npx`) wasn't on `PATH`. `searchedPath`
        /// is the colon-separated string we actually walked — useful for
        /// nvm / asdf users whose Node lives under their home dir but is
        /// invisible to a GUI app launched outside the shell.
        case commandNotFound(command: String, searchedPath: String?)

        /// Stable substring embedded in `commandNotFound`'s
        /// `errorDescription`. Errors flow through the UI as plain
        /// strings (`MCPProviderState.lastError`), so the card's "wrench
        /// + Edit" hint pattern-matches on this marker. Keeping the
        /// constant on the type means the description and the matcher
        /// can't drift independently.
        public static let commandNotFoundMarker = "not found on this app's PATH"

        public var errorDescription: String? {
            switch self {
            case .missingCommand:
                return "Stdio MCP provider is missing a `command`."
            case .processSpawnFailed(let detail):
                return "Couldn't launch stdio MCP subprocess: \(detail)"
            case .sandboxUnavailable:
                return
                    "This provider is configured to run in the Osaurus sandbox, but the sandbox runtime is not currently available."
            case .commandNotFound(let command, _):
                return
                    "`\(command)` was \(Self.commandNotFoundMarker). Use a full path (e.g. /opt/homebrew/bin/npx) or switch to Sandbox."
            }
        }

        /// True when `message` originated from `commandNotFound`. The
        /// caller has already lost the typed error (it round-tripped
        /// through `MCPProviderState.lastError: String?`) so we match by
        /// marker rather than re-introducing a typed error channel.
        public static func isCommandNotFoundMessage(_ message: String) -> Bool {
            message.contains(commandNotFoundMarker)
        }
    }

#endif
