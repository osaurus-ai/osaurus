//
//  ClaudeCodeProcessRunner.swift
//  osaurus
//
//  Spawns one `claude --print --output-format stream-json` turn and streams
//  its decoded events. One runner == one turn == one child process.
//
//  Shaped after `MCPStdioHostRunner` (spawn slot, SIGTERM → grace → SIGKILL)
//  and `ShellRunTool` (readabilityHandler pumping without a Task per chunk).
//

import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Tracks live Claude Code children so app quit can't orphan them.
///
/// Deliberately *not* `LiveExecRegistry`: that registry drives the sandbox
/// shell tool's live terminal card, and every inference turn does not want a
/// terminal pane in the chat. This only needs kill-on-quit.
actor ClaudeCodeProcessRegistry {
    static let shared = ClaudeCodeProcessRegistry()

    private var live: [UUID: @Sendable () -> Void] = [:]

    func register(_ id: UUID, terminate: @escaping @Sendable () -> Void) {
        live[id] = terminate
    }

    func unregister(_ id: UUID) {
        live[id] = nil
    }

    /// Called from the app-quit teardown. Terminates every live child.
    func terminateAll() {
        for terminate in live.values { terminate() }
        live.removeAll()
    }

    func liveCount() -> Int { live.count }
}

/// Lock-guarded decoder + stderr tail shared between Foundation's IO queue
/// (which fires `readabilityHandler`) and the awaiting task.
///
/// `@unchecked Sendable` with an explicit lock rather than an actor, for the
/// same reason `ShellRunOutputCollector` is: an actor would force a `Task { }`
/// per pipe chunk, and on a chatty stream that swamps the cooperative pool.
private final class ClaudeCodeStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = ClaudeCodeStreamDecoder()
    private var lineParser = OpenAICompatibleStreamFramer.SSELineParser()
    private var stderrTail = Data()
    private var sawAnyEvent = false
    private var reportedFailure: String?

    /// Feed stdout bytes; returns the events they completed.
    func ingestStdout(_ chunk: Data) -> [ClaudeCodeStreamEvent] {
        lock.lock()
        defer { lock.unlock() }
        lineParser.append(chunk)
        var events: [ClaudeCodeStreamEvent] = []
        while let line = lineParser.nextLine() {
            events.append(contentsOf: decoder.decode(line: line))
        }
        record(events)
        return events
    }

    /// Flush a trailing line with no terminator (the CLI does not always end
    /// its last frame with a newline).
    func finishStdout() -> [ClaudeCodeStreamEvent] {
        lock.lock()
        defer { lock.unlock() }
        lineParser.flushPending()
        var events: [ClaudeCodeStreamEvent] = []
        while let line = lineParser.nextLine() {
            events.append(contentsOf: decoder.decode(line: line))
        }
        record(events)
        return events
    }

    func appendStderr(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        stderrTail.append(chunk)
        // Bounded tail — enough for an error message, never a transcript.
        if stderrTail.count > 8192 {
            stderrTail.removeFirst(stderrTail.count - 8192)
        }
    }

    func stderrText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrTail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func producedOutput() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawAnyEvent
    }

    func failureDetail() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return reportedFailure
    }

    private func record(_ events: [ClaudeCodeStreamEvent]) {
        if !events.isEmpty { sawAnyEvent = true }
        for case .failure(let detail) in events {
            reportedFailure = detail
        }
    }
}

struct ClaudeCodeCommandResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: Data
    let stderr: String
    let timedOut: Bool
}

/// Bounded output collector for short-lived CLI control commands.
private final class ClaudeCodeCommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var timedOut = false

    func appendStdout(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        stdout.append(chunk)
        if stdout.count > 64 * 1024 {
            stdout.removeFirst(stdout.count - (64 * 1024))
        }
    }

    func appendStderr(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        stderr.append(chunk)
        if stderr.count > 8 * 1024 {
            stderr.removeFirst(stderr.count - (8 * 1024))
        }
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    func result(exitCode: Int32) -> ClaudeCodeCommandResult {
        lock.lock()
        defer { lock.unlock() }
        return ClaudeCodeCommandResult(
            exitCode: exitCode,
            stdout: stdout,
            stderr: String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            timedOut: timedOut
        )
    }
}

public enum ClaudeCodeProcessRunner {
    /// Run a bounded control command without blocking the caller's executor.
    ///
    /// Authentication probes and browser sign-in can be initiated from
    /// `@MainActor` SwiftUI tasks. Pipe readability handlers keep those tasks
    /// responsive while the child runs, and cancellation follows the same
    /// SIGTERM → SIGKILL path as generation.
    static func capture(
        executable: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval
    ) async -> ClaudeCodeCommandResult? {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let state = ClaudeCodeCommandState()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            state.appendStdout(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            state.appendStderr(chunk)
        }

        let terminator = ProcessTerminator(process: process)
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let timeoutTask = Task {
            let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, process.isRunning else { return }
            state.markTimedOut()
            terminator.terminate()
        }
        defer { timeoutTask.cancel() }

        await withTaskCancellationHandler {
            await terminator.waitUntilExit()
        } onCancel: {
            terminator.terminate()
        }

        let residualOut = stdoutPipe.fileHandleForReading.availableData
        if !residualOut.isEmpty { state.appendStdout(residualOut) }
        let residualErr = stderrPipe.fileHandleForReading.availableData
        if !residualErr.isEmpty { state.appendStderr(residualErr) }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        return state.result(exitCode: process.terminationStatus)
    }

    /// Run one turn and stream its decoded events.
    ///
    /// - Parameters:
    ///   - executable: absolute path from `ClaudeCodeConfiguration.resolveExecutable`.
    ///   - arguments: from `ClaudeCodeConfiguration.arguments`.
    ///   - prompt: the rendered conversation, passed as the trailing prompt argument.
    ///   - workingDirectory: the chat's working folder, or a temp dir.
    static func stream(
        executable: String,
        arguments: [String],
        prompt: String,
        workingDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AsyncThrowingStream<ClaudeCodeStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ClaudeCodeStreamEvent, Error>.makeStream()

        let state = ClaudeCodeStreamState()
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let runId = UUID()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments + [prompt]
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Without an explicit stdin the CLI waits 3s for piped input on every
        // single turn before proceeding ("no stdin data received in 3s").
        process.standardInput = FileHandle.nullDevice

        // Non-blocking, synchronous pumps. `continuation.yield` is cheap and
        // Sendable-safe, so no Task per chunk (see ShellRunTool's note).
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for event in state.ingestStdout(chunk) {
                continuation.yield(event)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            state.appendStderr(chunk)
        }

        let terminator = ProcessTerminator(process: process)

        let producerTask = Task {
            await ClaudeCodeProcessRegistry.shared.register(runId) { terminator.terminate() }
            defer {
                Task { await ClaudeCodeProcessRegistry.shared.unregister(runId) }
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish(
                    throwing: ClaudeCodeError.launchFailed(error.localizedDescription)
                )
                return
            }

            await withTaskCancellationHandler {
                await terminator.waitUntilExit()
            } onCancel: {
                terminator.terminate()
            }

            // Drain whatever Foundation had buffered but not yet delivered,
            // THEN detach the handlers — the other order loses the last frame
            // and leaks the FileHandle.
            let residualOut = stdoutPipe.fileHandleForReading.availableData
            if !residualOut.isEmpty {
                for event in state.ingestStdout(residualOut) { continuation.yield(event) }
            }
            let residualErr = stderrPipe.fileHandleForReading.availableData
            if !residualErr.isEmpty { state.appendStderr(residualErr) }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            for event in state.finishStdout() { continuation.yield(event) }

            if Task.isCancelled {
                continuation.finish()
                return
            }

            let status = terminator.terminationStatus()
            if status != 0 {
                let tail = state.stderrText()
                continuation.finish(throwing: Self.error(forExitCode: status, stderrTail: tail))
                return
            }
            if let detail = state.failureDetail() {
                continuation.finish(throwing: Self.error(forFailureDetail: detail))
                return
            }
            if !state.producedOutput() {
                continuation.finish(
                    throwing: ClaudeCodeError.exited(code: status, stderrTail: state.stderrText())
                )
                return
            }
            continuation.finish()
        }

        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
            // Cancelling the Task alone would leave the child running until it
            // finished its own turn; the user pressing Stop must kill it.
            terminator.terminate()
        }

        return stream
    }

    /// Map a non-zero exit onto a typed error, promoting the two failures a
    /// user can actually act on.
    private static func error(forExitCode code: Int32, stderrTail: String) -> ClaudeCodeError {
        let lowered = stderrTail.lowercased()
        if lowered.contains("not logged in") || lowered.contains("please run `claude login`")
            || lowered.contains("authentication") || lowered.contains("unauthorized")
        {
            return .notAuthenticated(detail: stderrTail)
        }
        if lowered.contains("rate limit") || lowered.contains("usage limit") {
            return .rateLimited(detail: stderrTail)
        }
        return .exited(code: code, stderrTail: stderrTail)
    }

    static func error(forFailureDetail detail: String) -> ClaudeCodeError {
        let lowered = detail.lowercased()
        if lowered.contains("not logged in") || lowered.contains("sign in")
            || lowered.contains("authentication") || lowered.contains("unauthorized")
        {
            return .notAuthenticated(detail: detail)
        }
        if lowered.contains("rate limit") || lowered.contains("usage limit") {
            return .rateLimited(detail: detail)
        }
        return .turnFailed(detail)
    }
}

/// Idempotent SIGTERM → grace → SIGKILL handle around a `Process`.
///
/// Separate from the runner so the cancellation closure can capture just this
/// and not the whole streaming context.
final class ProcessTerminator: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var didTerminate = false

    init(process: Process) {
        self.process = process
    }

    /// One-shot claim shared by the two paths that can resume the exit
    /// continuation. Deliberately a standalone box rather than state on the
    /// terminator: capturing `self` strongly in `terminationHandler` would
    /// retain-cycle through `process`, and capturing it weakly could drop the
    /// only resume and hang the caller forever.
    private final class ExitClaim: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    func waitUntilExit() async {
        let claim = ExitClaim()
        await withCheckedContinuation { continuation in
            // The handler runs on Foundation's queue and can land in the
            // window between being installed and the `isRunning` check below.
            // Resuming a checked continuation twice traps, so exactly one of
            // these two paths may win.
            process.terminationHandler = { _ in
                guard claim.claim() else { return }
                continuation.resume()
            }
            // A process that already exited before the handler was installed
            // would never call it back.
            if !process.isRunning, claim.claim() {
                continuation.resume()
            }
        }
        // Break the process → handler → continuation retain chain now that the
        // wait is over.
        process.terminationHandler = nil
    }

    func terminationStatus() -> Int32 {
        process.isRunning ? 0 : process.terminationStatus
    }

    func terminate() {
        lock.lock()
        // A stream can be cancelled in the tiny window before `process.run()`.
        // Do not consume the one-shot termination claim until there is a live
        // child to signal; the already-cancelled producer will call again when
        // it enters its cancellation handler after launch.
        let shouldTerminate = !didTerminate && process.isRunning
        if shouldTerminate { didTerminate = true }
        lock.unlock()
        guard shouldTerminate else { return }

        process.terminate()

        // Escalate if it ignores SIGTERM. Detached because `terminate()` is
        // called from cancellation contexts that must not block.
        let pid = process.processIdentifier
        Task.detached {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            #if canImport(Darwin)
                if pid > 0 { kill(pid, SIGKILL) }
            #endif
        }
    }
}
