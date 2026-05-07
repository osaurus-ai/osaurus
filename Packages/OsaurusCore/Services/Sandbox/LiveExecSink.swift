//
//  LiveExecSink.swift
//  osaurus
//
//  Streaming sink for the foreground `sandbox_exec` / `shell_run` exec
//  paths. Implements `Containerization.Writer` so it can be wired in as
//  the secondary side of a `TeeWriter`, and maintains a rolling
//  buffered snapshot so a UI row that mounts mid-stream can replay the
//  output before subscribing to live updates.
//
//  Tracks a "termination reason" that the consuming tool body checks
//  after the process exits to decide whether to surface
//  `killed_by: "user"` in the result envelope. The actual process kill
//  is owned by the tool body (foreground sandbox_exec captures the
//  ProcessHandle from the runner's `onProcessStarted` callback);
//  the sink just records intent.
//
//  Lifecycle (foreground exec):
//    1. tool body creates a sink + ProcessHandleBox + LiveExecRegistry
//       entry whose `terminate` closure does:
//         sink.requestTerminate()  // mark the killed_by reason
//         processBox.kill(15)      // SIGTERM the underlying process
//         …grace…
//         processBox.kill(9)       // SIGKILL
//    2. tool body invokes the runner with `stdoutTee: sink` so every
//       chunk lands in the rolling buffer AND fires `outputPublisher`
//    3. after the runner returns, `terminationReason == .user` ⇒ the
//       envelope gets `killed_by: "user"`
//

import Combine
import Containerization
import Foundation

public final class LiveExecSink: @unchecked Sendable {

    public enum TerminationReason: Sendable, Equatable {
        case none
        case user
    }

    private let lock = NSLock()
    private var buffer = Data()
    private var _terminationReason: TerminationReason = .none

    private let outputSubject = PassthroughSubject<Data, Never>()
    /// `nonisolated(unsafe)` so the `currentStatus()` accessor below
    /// can read `value` without an actor hop. `CurrentValueSubject` is
    /// thread-safe internally.
    private nonisolated(unsafe) let statusSubject =
        CurrentValueSubject<LiveExecRegistry.LiveExecStatus, Never>(.running)

    /// Cap on the in-memory seed buffer. 1 MB is enough to render most
    /// long-running command output for a row that mounts mid-stream.
    /// Beyond that, we drop from the head — late binders see the most
    /// recent 1 MB. The model still gets the full stdout/stderr from
    /// the collector at exit (which has its own truncation cap inside
    /// `truncateForModel`).
    private static let seedCap = 1_000_000

    public init() {}

    public var outputPublisher: AnyPublisher<Data, Never> {
        outputSubject.eraseToAnyPublisher()
    }

    public var statusPublisher: AnyPublisher<LiveExecRegistry.LiveExecStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    /// Synchronous read of the current status — used by the chat UI
    /// to decide whether the live pane is worth mounting at all.
    public var currentStatus: LiveExecRegistry.LiveExecStatus {
        statusSubject.value
    }

    /// Snapshot of the buffered tail. Async to keep the LiveExecRegistry
    /// `seed` closure shape consistent across sources (some sources, like
    /// `LogFileTailer`, do real I/O on snapshot).
    public func bufferedSnapshot() async -> Data {
        lock.withLock { buffer }
    }

    public var terminationReason: TerminationReason {
        lock.withLock { _terminationReason }
    }

    /// Mark this exec as user-terminated. Idempotent: subsequent calls
    /// are no-ops. Called by the LiveExecRegistry entry's `terminate`
    /// closure (the chat-card terminate button) right before issuing
    /// the actual signal.
    public func requestTerminate() {
        lock.withLock {
            if _terminationReason == .none { _terminationReason = .user }
        }
    }

    /// Mark the exec as exited with the given code. The status
    /// transition is one-way: if `requestTerminate()` already fired,
    /// we surface `.killed(reason: "user")` instead of `.exited(code)`
    /// so the chat card's status pill matches the envelope's
    /// `killed_by: "user"` stamp.
    public func markExited(code: Int32) {
        let userTerminated = lock.withLock { _terminationReason == .user }
        statusSubject.send(userTerminated ? .killed(reason: "user") : .exited(code))
    }

    // MARK: - Writer

    public func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        lock.withLock {
            buffer.append(data)
            if buffer.count > Self.seedCap {
                // Drop from the head — late binders see the recent tail.
                buffer.removeFirst(buffer.count - Self.seedCap)
            }
        }
        outputSubject.send(data)
    }

    public func close() throws {
        // No-op: the status transition is owned by `markExited`. The
        // publisher stays open so late subscribers can still observe the
        // last-published status from `statusSubject`'s buffered value.
    }
}

extension LiveExecSink: Writer {}
