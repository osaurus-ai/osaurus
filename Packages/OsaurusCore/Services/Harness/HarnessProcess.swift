//
//  HarnessProcess.swift
//  osaurus
//
//  One long-lived harness child: JSONL out on stdout, JSONL in on stdin.
//  Protocol-agnostic — adapters decide what the lines mean.
//

import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Splits a byte stream into JSONL records on LF only.
///
/// Both supported protocols require this: JSON string escaping guarantees a
/// raw LF never appears inside a record, while U+2028/U+2029 legitimately can
/// (they are valid unescaped in JSON), so a Unicode-aware line splitter would
/// tear records apart.
struct HarnessLineFramer: Sendable {
    private var buffer = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<index]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...index)
        }
        return lines
    }

    /// A final record with no trailing LF.
    mutating func flush() -> Data? {
        defer { buffer.removeAll() }
        var line = buffer
        if line.last == 0x0D { line = line.dropLast() }
        return line.isEmpty ? nil : Data(line)
    }
}

/// Every live harness or Claude Code control child, so app quit can't orphan
/// one. Registration is synchronous: an actor hop could lose a child launched
/// in the same instant the app starts quitting.
final class HarnessProcessRegistry: @unchecked Sendable {
    static let shared = HarnessProcessRegistry()

    private let lock = NSLock()
    private var live: [UUID: ProcessTerminator] = [:]

    func register(_ id: UUID, terminator: ProcessTerminator) {
        lock.lock()
        live[id] = terminator
        lock.unlock()
    }

    func unregister(_ id: UUID) {
        lock.lock()
        live[id] = nil
        lock.unlock()
    }

    func liveCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return live.count
    }

    /// App-quit teardown: SIGTERM everything, short grace, then SIGKILL
    /// synchronously so nothing depends on a detached escalation that would
    /// never run once the app is gone.
    func terminateAll() async {
        let terminators = takeAll()
        for terminator in terminators { terminator.terminate() }
        guard !terminators.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 500_000_000)
        for terminator in terminators { terminator.forceKillIfRunning() }
    }

    private func takeAll() -> [ProcessTerminator] {
        lock.lock()
        defer { lock.unlock() }
        let terminators = Array(live.values)
        live.removeAll()
        return terminators
    }
}

/// Non-blocking reader for one pipe. `FileHandle.availableData` blocks until
/// EOF, and EOF never comes while a grandchild (a background shell a harness
/// tool started) still holds the write end — so the exit drain must not use it.
private final class HarnessPipeReader: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var cancelled = false

    init(
        handle: FileHandle,
        queue: DispatchQueue,
        onData: @escaping @Sendable (Data) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    onData(Data(buffer[0..<count]))
                    continue
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { return }
                }
                self.cancel()
                onEOF()
                return
            }
        }
        // The fd belongs to the `Pipe`'s FileHandle, which closes it.
        source.resume()
    }

    deinit { cancel() }

    func cancel() {
        lock.lock()
        let shouldCancel = !cancelled
        cancelled = true
        lock.unlock()
        if shouldCancel { source.cancel() }
    }
}

/// Mutable state shared between the process object and the callbacks
/// Foundation and Dispatch fire on their own queues.
private final class HarnessProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdinClosed = false
    private var exitStatus: Int32?
    private var exitWaiters: [UUID: CheckedContinuation<Int32?, Never>] = [:]
    private var stderrTail = Data()

    /// Returns true when this call is the one that closed stdin.
    func claimStdinClose() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stdinClosed { return false }
        stdinClosed = true
        return true
    }

    var isStdinClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stdinClosed
    }

    var exitCode: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus
    }

    func recordExit(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let waiters = exitWaiters.values
        exitWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: status) }
    }

    func waitForExit() async -> Int32 {
        while true {
            if let status = await waitForExit(timeout: nil) { return status }
        }
    }

    /// The exit status, or nil if `timeout` passed first. The deadline
    /// resumes the waiter itself, so the caller never waits on the child.
    func waitForExit(timeout: TimeInterval?) async -> Int32? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
                return
            }
            exitWaiters[id] = continuation
            lock.unlock()
            guard let timeout else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout)) {
                self.lock.lock()
                let waiter = self.exitWaiters.removeValue(forKey: id)
                self.lock.unlock()
                waiter?.resume(returning: nil)
            }
        }
    }

    func appendStderr(_ chunk: Data) {
        lock.lock()
        stderrTail.append(chunk)
        if stderrTail.count > 8192 { stderrTail.removeFirst(stderrTail.count - 8192) }
        lock.unlock()
    }

    func stderrText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class HarnessProcess: @unchecked Sendable {
    struct LaunchSpec: Sendable, Equatable {
        /// As configured: a bare command (looked up on the child's PATH) or a
        /// path, `~` allowed.
        var executable: String
        var arguments: [String]
        /// Applied over the inherited environment. Wins over everything,
        /// including the computed PATH.
        var environment: [String: String]
        /// Inherited variables the child must not see.
        var removingEnvironment: Set<String>
        var workingDirectory: URL
        /// Display name for errors.
        var runtimeName: String
    }

    let id: UUID
    let spec: LaunchSpec
    let resolvedExecutable: String
    let pid: Int32
    /// stdout records, in order. Finishes after the child has exited and its
    /// output is drained, so `exitCode` is always set by then.
    let lines: AsyncStream<Data>

    private let process: Process
    private let terminator: ProcessTerminator
    private let stdinHandle: FileHandle
    private let writeQueue = DispatchQueue(label: "ai.osaurus.harness.stdin")
    private let state: HarnessProcessState
    private let pipes: [Pipe]
    private let stdoutReader: HarnessPipeReader
    private let stderrReader: HarnessPipeReader

    /// Resolve the login-shell PATH off the caller's executor, then launch.
    static func launch(_ spec: LaunchSpec) async throws -> HarnessProcess {
        let entries = await LoginShellPath.shared.entries()
        return try HarnessProcess(spec: spec, loginShellEntries: entries)
    }

    init(
        spec: LaunchSpec,
        loginShellEntries: [String]?,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: spec.workingDirectory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw HarnessError.workingFolderUnavailable(path: spec.workingDirectory.path)
        }

        var environment = Self.childEnvironment(
            inherited: inheritedEnvironment,
            loginShellEntries: loginShellEntries,
            overlay: spec.environment,
            removing: spec.removingEnvironment
        )
        guard let executable = ExecutableLocator.resolve(command: spec.executable, env: environment),
            FileManager.default.isExecutableFile(atPath: executable)
        else {
            throw HarnessError.executableNotFound(
                command: spec.executable,
                searchedPath: environment["PATH"] ?? ""
            )
        }
        if spec.environment["PATH"] == nil {
            environment["PATH"] = Self.prependingShebangSibling(of: executable, to: environment["PATH"] ?? "")
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = spec.arguments
        process.environment = environment
        process.currentDirectoryURL = spec.workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        #if canImport(Darwin)
            // A write after the child died must fail with EPIPE, not kill
            // Osaurus (test hosts don't ignore SIGPIPE the way the app does).
            _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif

        let state = HarnessProcessState()
        let (lines, linesContinuation) = AsyncStream<Data>.makeStream()
        let drain = HarnessDrainGate(continuation: linesContinuation)
        let framer = HarnessFramerBox()
        let processId = UUID()
        let terminator = ProcessTerminator(process: process)

        // Installed before launch so an instant exit can't be missed.
        process.terminationHandler = { finished in
            state.recordExit(finished.terminationStatus)
            HarnessProcessRegistry.shared.unregister(processId)
            drain.markExited()
        }

        let readQueue = DispatchQueue(label: "ai.osaurus.harness.stdout")
        do {
            try process.run()
        } catch {
            throw HarnessError.launchFailed(runtime: spec.runtimeName, detail: error.localizedDescription)
        }
        HarnessProcessRegistry.shared.register(processId, terminator: terminator)

        self.id = processId
        self.spec = spec
        self.resolvedExecutable = executable
        self.pid = process.processIdentifier
        self.lines = lines
        self.process = process
        self.terminator = terminator
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.state = state
        self.pipes = [stdinPipe, stdoutPipe, stderrPipe]
        self.stdoutReader = HarnessPipeReader(
            handle: stdoutPipe.fileHandleForReading,
            queue: readQueue,
            onData: { chunk in
                for line in framer.append(chunk) { drain.yield(line) }
            },
            onEOF: {
                if let tail = framer.flush() { drain.yield(tail) }
                drain.markEOF()
            }
        )
        self.stderrReader = HarnessPipeReader(
            handle: stderrPipe.fileHandleForReading,
            queue: readQueue,
            onData: { state.appendStderr($0) },
            onEOF: {}
        )
    }

    deinit {
        stdoutReader.cancel()
        stderrReader.cancel()
    }

    // MARK: - stdin

    /// Write one JSONL record (a trailing LF is added). Completes once the
    /// bytes are in the pipe, so a slow reader applies backpressure.
    func send(_ record: Data) async throws {
        var payload = record
        payload.append(0x0A)
        let handle = stdinHandle
        let state = state
        let runtimeName = spec.runtimeName
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                guard !state.isStdinClosed, state.exitCode == nil else {
                    continuation.resume(
                        throwing: HarnessError.exited(
                            runtime: runtimeName,
                            code: state.exitCode ?? -1,
                            stderrTail: state.stderrText()
                        )
                    )
                    return
                }
                do {
                    try handle.write(contentsOf: payload)
                    continuation.resume()
                } catch {
                    continuation.resume(
                        throwing: HarnessError.exited(
                            runtime: runtimeName,
                            code: state.exitCode ?? -1,
                            stderrTail: state.stderrText()
                        )
                    )
                }
            }
        }
    }

    /// Signals end of input — the documented shutdown for both protocols.
    /// Queued behind any pending writes.
    func closeStdin() {
        let handle = stdinHandle
        let state = state
        writeQueue.async {
            if state.claimStdinClose() { try? handle.close() }
        }
    }

    // MARK: - Lifecycle

    var isRunning: Bool { state.exitCode == nil }

    var exitCode: Int32? { state.exitCode }

    func waitForExit() async -> Int32 {
        await state.waitForExit()
    }

    /// Whether the child exited within `timeout`.
    func waitForExit(timeout: TimeInterval) async -> Bool {
        await state.waitForExit(timeout: timeout) != nil
    }

    /// Close stdin and give the child `grace` to exit on its own, then
    /// SIGTERM → SIGKILL.
    func shutdown(grace: TimeInterval = 5) async {
        closeStdin()
        if await waitForExit(timeout: grace) { return }
        terminator.terminate()
        if await waitForExit(timeout: 3) { return }
        terminator.forceKillIfRunning()
    }

    /// Immediate SIGTERM, escalating to SIGKILL.
    func kill() {
        terminator.terminate()
    }

    func stderrText() -> String {
        state.stderrText()
    }

    // MARK: - Environment

    static func childEnvironment(
        inherited: [String: String],
        loginShellEntries: [String]?,
        overlay: [String: String],
        removing: Set<String>
    ) -> [String: String] {
        var env = inherited
        for key in removing { env[key] = nil }
        env["PATH"] = ExecutableLocator.childPath(inherited: env, loginShellEntries: loginShellEntries)
        for (key, value) in overlay { env[key] = value }
        return env
    }

    /// `#!/usr/bin/env node` scripts (npm-installed `claude`, `pi`) need their
    /// interpreter on the child's PATH, and the copy beside the script is the
    /// one the user's version manager picked.
    static func prependingShebangSibling(of executable: String, to path: String) -> String {
        guard let sibling = ExecutableLocator.envShebangSiblingDirectory(executable: executable) else { return path }
        let rest = path.split(separator: ":").map(String.init).filter { $0 != sibling }
        return ([sibling] + rest).joined(separator: ":")
    }
}

private final class HarnessFramerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var framer = HarnessLineFramer()

    func append(_ chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return framer.append(chunk)
    }

    func flush() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return framer.flush()
    }
}

/// Finishes the line stream once stdout hit EOF and the process exited — or
/// shortly after exit when EOF never arrives.
private final class HarnessDrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<Data>.Continuation
    private var sawEOF = false
    private var exited = false
    private var finished = false

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ line: Data) {
        lock.lock()
        let open = !finished
        lock.unlock()
        if open { continuation.yield(line) }
    }

    func markEOF() {
        lock.lock()
        sawEOF = true
        let done = exited
        lock.unlock()
        if done { finish() }
    }

    func markExited() {
        lock.lock()
        exited = true
        let done = sawEOF
        lock.unlock()
        if done {
            finish()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.finish() }
        }
    }

    private func finish() {
        lock.lock()
        let shouldFinish = !finished
        finished = true
        lock.unlock()
        if shouldFinish { continuation.finish() }
    }
}
