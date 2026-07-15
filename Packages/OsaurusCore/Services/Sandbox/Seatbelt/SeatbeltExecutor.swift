//
//  SeatbeltExecutor.swift
//  osaurus
//
//  Runs one command on the host under `sandbox-exec` confinement and
//  returns the same `ContainerExecResult` envelope the VM path produces,
//  so callers behind `SandboxManager.exec(...)` cannot tell the backends
//  apart. Mirrors the VM path's semantics: buffered stdout/stderr
//  collection, optional live tee writers, an inactivity timeout that
//  resets on output, and a `ProcessHandle` for the UI's Terminate button.
//

import Containerization
import Foundation

enum SeatbeltExecutor {

    struct Request {
        /// Shell command, already host-path-mapped by the caller.
        let command: String
        let env: [String: String]
        /// Host cwd, already mapped. `nil` runs in the workspace root.
        let cwd: String?
        /// Inactivity timeout (seconds); resets whenever the process
        /// emits output. `nil` waits indefinitely.
        let timeout: TimeInterval?
        let profile: String
        let stdoutTee: (any Writer)?
        let stderrTee: (any Writer)?
        let onProcessStarted: (@Sendable (ProcessHandle) -> Void)?
    }

    /// Bytes collected from one pipe plus the last-output clock the
    /// inactivity timeout reads. `@unchecked Sendable` — all state is
    /// behind the lock.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let tee: (any Writer)?
        private let touch: @Sendable () -> Void

        init(tee: (any Writer)?, touch: @escaping @Sendable () -> Void) {
            self.tee = tee
            self.touch = touch
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
            touch()
            // Observer failures never disturb collection (same
            // contract as TeeWriter's secondary).
            try? tee?.write(chunk)
        }

        var string: String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private final class ActivityClock: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        func touch() {
            lock.lock()
            last = Date()
            lock.unlock()
        }
        var secondsIdle: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return Date().timeIntervalSince(last)
        }
    }

    static func run(_ request: Request) async throws -> ContainerExecResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SeatbeltSandbox.sandboxExecPath)
        process.arguments = ["-p", request.profile, "/bin/sh", "-c", request.command]

        var env = request.env
        if env["PATH"] == nil {
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        // Point tools' scratch writes at a directory the profile
        // actually allows, instead of the user's default $TMPDIR
        // (which is deny-listed).
        let scratch = SeatbeltSandbox.scratchDir
        try? FileManager.default.createDirectory(
            atPath: scratch, withIntermediateDirectories: true)
        if env["TMPDIR"] == nil { env["TMPDIR"] = scratch }
        if env["HOME"] == nil { env["HOME"] = request.cwd ?? scratch }
        process.environment = env

        if let cwd = request.cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let clock = ActivityClock()
        let stdoutCollector = Collector(tee: request.stdoutTee) { clock.touch() }
        let stderrCollector = Collector(tee: request.stderrTee) { clock.touch() }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            throw SandboxError.execFailed(
                "sandbox-exec launch failed: \(error.localizedDescription)")
        }

        let pid = process.processIdentifier
        request.onProcessStarted?(
            ProcessHandle(pid: pid) { signal in
                // ESRCH (already exited) is a no-op, matching the VM
                // handle's idempotent-kill contract.
                _ = Darwin.kill(pid, signal)
            })

        // Wait off the main thread with an inactivity timeout that
        // resets on output — the same semantics as the VM path's
        // `waitWithInactivityTimeout`.
        var timedOut = false
        while process.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let timeout = request.timeout, clock.secondsIdle > timeout {
                timedOut = true
                process.terminate()
                // Grace period, then hard kill.
                for _ in 0..<20 where process.isRunning {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
                break
            }
        }
        process.waitUntilExit()

        // Drain any bytes still buffered in the pipes, then detach the
        // handlers so the file handles can close.
        stdoutCollector.append(stdoutPipe.fileHandleForReading.availableData)
        stderrCollector.append(stderrPipe.fileHandleForReading.availableData)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        if timedOut {
            throw SandboxError.timeout
        }

        return ContainerExecResult(
            stdout: stdoutCollector.string,
            stderr: stderrCollector.string,
            exitCode: process.terminationStatus
        )
    }
}

