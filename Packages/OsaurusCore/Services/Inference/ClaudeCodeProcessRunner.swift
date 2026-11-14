//
//  ClaudeCodeProcessRunner.swift
//  osaurus
//
//  Bounded one-shot `claude` control commands (`--version`, `auth status`,
//  `auth login`). Chat turns run through `HarnessProcess`.
//

import Foundation

#if canImport(Darwin)
    import Darwin
#endif

struct ClaudeCodeCommandResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: Data
    let stderr: String
    let timedOut: Bool
}

/// Owns pipe reads through delivery, including the final process-exit drain.
/// Locking only the decoder is insufficient: a callback can already own bytes
/// that the exit task can no longer read, but has not delivered them yet.
final class ClaudeCodePipePump: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let consume: @Sendable (Data) -> Void
    private var finished = false

    init(handle: FileHandle, consume: @escaping @Sendable (Data) -> Void) {
        self.handle = handle
        self.consume = consume
    }

    func start() {
        handle.readabilityHandler = { [weak self] _ in self?.readAvailable() }
    }

    private func readAvailable() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
        } else {
            consume(chunk)
        }
    }

    /// Call after child exit. Waits for any callback's read AND delivery before
    /// claiming remaining bytes. Queued callbacks become harmless no-ops.
    func finish() {
        lock.lock()
        if !finished {
            let remaining = handle.availableData
            if !remaining.isEmpty { consume(remaining) }
            finished = true
        }
        lock.unlock()
        handle.readabilityHandler = nil
    }

    /// Launch failure has no child output to drain.
    func stop() {
        lock.lock()
        finished = true
        lock.unlock()
        handle.readabilityHandler = nil
    }
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
        let runId = UUID()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutPump = ClaudeCodePipePump(handle: stdoutPipe.fileHandleForReading) {
            state.appendStdout($0)
        }
        let stderrPump = ClaudeCodePipePump(handle: stderrPipe.fileHandleForReading) {
            state.appendStderr($0)
        }
        stdoutPump.start()
        stderrPump.start()

        let terminator = ProcessTerminator(process: process)
        do {
            try process.run()
        } catch {
            stdoutPump.stop()
            stderrPump.stop()
            return nil
        }
        HarnessProcessRegistry.shared.register(runId, terminator: terminator)
        defer { HarnessProcessRegistry.shared.unregister(runId) }

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

        stdoutPump.finish()
        stderrPump.finish()

        return state.result(exitCode: process.terminationStatus)
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

    func forceKillIfRunning() {
        #if canImport(Darwin)
            let pid = process.processIdentifier
            if process.isRunning, pid > 0 {
                kill(pid, SIGKILL)
            }
        #endif
    }
}
