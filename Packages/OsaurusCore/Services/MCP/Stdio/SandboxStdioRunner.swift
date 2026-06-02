//
//  SandboxStdioRunner.swift
//  osaurus
//
//  Owns a single stdio MCP subprocess running inside the Osaurus sandbox.
//  One runner per provider: it spawns the linux process via
//  `SandboxManager.execInteractive`, holds the stdin/stdout/stderr
//  bridges, and vends an `MCPStdioSandboxTransport` for `MCP.Client`.
//  From the client's perspective there is no difference between a
//  host-resident stdio server and a sandbox-resident one.
//

#if os(macOS)

    import Containerization
    import Foundation
    import Logging
    @preconcurrency import MCP

    /// Runner that owns the sandbox-side lifecycle for a single stdio MCP
    /// provider. One runner per provider; the manager keeps a map keyed by
    /// `MCPProvider.id`.
    public actor SandboxStdioRunner {
        public let providerId: UUID
        public let providerName: String

        private let agentUser: String
        private let command: String
        private let env: [String: String]
        private let cwd: String?

        // Owned I/O bridges.
        private let stdinBridge: SandboxStdioInputStream
        private let stdoutWriter: SandboxStdioWriter
        private let stderrWriter: SandboxStdioWriter

        /// Public transport the `MCP.Client` connects to. Created upfront so
        /// callers can hold onto it before `start()` resolves.
        public let transport: MCPStdioSandboxTransport

        /// Linux process handle once `start()` has run. Used to terminate the
        /// subprocess on `stop()`.
        private var process: LinuxProcess?

        public init(provider: MCPProvider) throws {
            guard provider.transport == .stdio else {
                throw MCPStdioTransportError.missingCommand
            }
            guard !provider.command.isEmpty else {
                throw MCPStdioTransportError.missingCommand
            }
            self.providerId = provider.id
            self.providerName = provider.name
            // Re-use the "default" agent user namespace so the subprocess
            // lands in the same sandboxed UID class our plugins do, even if
            // we haven't pre-created a per-provider agent. A future
            // enhancement could mint per-provider users.
            self.agentUser = "agent-default"
            self.command = SandboxStdioRunner.buildShellCommand(
                command: provider.command,
                args: provider.args
            )
            self.env = provider.resolvedEnv()
            self.cwd = provider.workingDirectory

            let stdinBridge = SandboxStdioInputStream()
            let stdoutWriter = SandboxStdioWriter()
            let stderrWriter = SandboxStdioWriter(discard: true)
            self.stdinBridge = stdinBridge
            self.stdoutWriter = stdoutWriter
            self.stderrWriter = stderrWriter
            self.transport = MCPStdioSandboxTransport(
                stdinBridge: stdinBridge,
                stdoutStream: stdoutWriter.makeOutputStream()
            )
        }

        /// Set once a global spawn slot is held so `stop()` releases exactly
        /// one slot even if called twice.
        private var spawnSlotHeld = false

        public func start() async throws {
            // Reserve a global MCP child-spawn slot (shared with the host
            // transport) before doing any container work, so a launch storm
            // can't exhaust resources.
            try await MCPChildSpawnLimiter.shared.acquire()
            spawnSlotHeld = true

            // Ensure the default agent user exists before we exec as it.
            try? await SandboxManager.shared.ensureAgentUser("default")

            do {
                self.process = try await SandboxManager.shared.execInteractive(
                    user: agentUser,
                    command: command,
                    env: env,
                    cwd: cwd,
                    stdin: stdinBridge,
                    stdout: stdoutWriter,
                    stderr: stderrWriter
                )
            } catch {
                await MCPChildSpawnLimiter.shared.release()
                spawnSlotHeld = false
                throw MCPStdioTransportError.processSpawnFailed(
                    error.localizedDescription
                )
            }
        }

        public func stop() async {
            await transport.disconnect()
            stdinBridge.finish()
            try? stdoutWriter.close()
            try? stderrWriter.close()
            if let proc = process {
                try? await proc.kill(SIGTERM)
                try? await proc.delete()
                self.process = nil
            }
            if spawnSlotHeld {
                spawnSlotHeld = false
                await MCPChildSpawnLimiter.shared.release()
            }
        }

        public func isRunning() -> Bool {
            process != nil
        }

        // MARK: - Helpers

        /// Quote command + args into a single shell string. The container
        /// exec runs via `sh -c`, so we have to compose ourselves rather
        /// than passing argv.
        private static func buildShellCommand(command: String, args: [String]) -> String {
            ShellArgs.join([command] + args)
        }
    }

    // MARK: - I/O Bridges

    /// Thread-safe one-producer / one-consumer byte channel that buffers
    /// writes until a consumer attaches via `subscribe()`. Stdin and stdout
    /// share this implementation; their `Containerization` protocols differ
    /// but the underlying buffering semantics are identical.
    final class SandboxStdioByteChannel: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<Data>.Continuation?
        private var pending: [Data] = []
        private var finished = false

        func subscribe() -> AsyncStream<Data> {
            AsyncStream { continuation in
                lock.lock()
                self.continuation = continuation
                // Drain anything buffered before the consumer arrived.
                for data in pending { continuation.yield(data) }
                pending.removeAll()
                let isFinished = finished
                lock.unlock()
                if isFinished { continuation.finish() }
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.lock.lock()
                    self.continuation = nil
                    self.lock.unlock()
                }
            }
        }

        func push(_ data: Data) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            if let continuation {
                lock.unlock()
                continuation.yield(data)
                return
            }
            pending.append(data)
            lock.unlock()
        }

        func finish() {
            lock.lock()
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.finish()
        }
    }

    /// `ReaderStream` adapter that lets the host push bytes into the
    /// container subprocess's stdin via `feed(_:)`.
    final class SandboxStdioInputStream: ReaderStream, @unchecked Sendable {
        private let channel = SandboxStdioByteChannel()

        func stream() -> AsyncStream<Data> { channel.subscribe() }
        func feed(_ data: Data) { channel.push(data) }
        func finish() { channel.finish() }
    }

    /// `Writer` adapter that fans every chunk out to an `AsyncStream<Data>`
    /// the MCP transport consumes. `discard == true` is the stderr branch:
    /// MCP clients don't read stderr so we drop bytes on the floor.
    final class SandboxStdioWriter: Writer, @unchecked Sendable {
        private let channel = SandboxStdioByteChannel()
        private let discard: Bool

        init(discard: Bool = false) { self.discard = discard }

        func makeOutputStream() -> AsyncStream<Data> { channel.subscribe() }

        func write(_ data: Data) throws {
            guard !discard else { return }
            channel.push(data)
        }

        func close() throws { channel.finish() }
    }

    // MARK: - MCP Transport

    /// `MCP.Transport` implementation that bridges to a sandbox-resident
    /// stdio subprocess via `SandboxStdioInputStream` (stdin) and an
    /// `AsyncStream<Data>` of stdout chunks.
    ///
    /// Mirrors the JSON-RPC newline framing used by `MCP.StdioTransport`:
    /// inbound chunks are accumulated and split on `\n` so partial reads
    /// from the container don't yield mid-message frames.
    public actor MCPStdioSandboxTransport: MCP.Transport {
        private let stdinBridge: SandboxStdioInputStream
        private let stdoutStream: AsyncStream<Data>

        private var isConnected = false
        private var pumpTask: Task<Void, Never>?
        private var lineBuffer = Data()

        private let messageStream: AsyncThrowingStream<Data, Swift.Error>
        private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

        public nonisolated let logger: Logger

        init(
            stdinBridge: SandboxStdioInputStream,
            stdoutStream: AsyncStream<Data>
        ) {
            self.stdinBridge = stdinBridge
            self.stdoutStream = stdoutStream
            self.logger = Logger(
                label: "mcp.transport.sandbox.stdio",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )

            var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
            self.messageStream = AsyncThrowingStream { continuation = $0 }
            self.messageContinuation = continuation
        }

        public func connect() async throws {
            guard !isConnected else { return }
            isConnected = true
            pumpTask = Task { [weak self] in
                await self?.pumpStdout()
            }
        }

        public func disconnect() async {
            guard isConnected else { return }
            isConnected = false
            pumpTask?.cancel()
            pumpTask = nil
            messageContinuation.finish()
        }

        public func send(_ data: Data) async throws {
            guard isConnected else {
                throw MCPStdioTransportError.processSpawnFailed("transport not connected")
            }
            var framed = data
            if framed.last != 0x0A {
                framed.append(0x0A)
            }
            stdinBridge.feed(framed)
        }

        public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
            messageStream
        }

        /// Pull bytes off the container's stdout stream, split on newlines,
        /// and forward each complete JSON-RPC frame to `messageContinuation`.
        /// The MCP spec mandates one JSON object per line over stdio, so
        /// anything else is a protocol violation we'd surface as a parse
        /// error downstream regardless.
        private func pumpStdout() async {
            for await chunk in stdoutStream {
                lineBuffer.append(chunk)
                while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
                    let line = lineBuffer[..<newlineIndex]
                    if !line.isEmpty {
                        messageContinuation.yield(Data(line))
                    }
                    lineBuffer.removeSubrange(...newlineIndex)
                }
                if Task.isCancelled { break }
            }
            messageContinuation.finish()
        }
    }

#endif
