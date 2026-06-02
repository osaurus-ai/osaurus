//
//  LiveExecRegistry.swift
//  osaurus
//
//  Single source of truth for live-streaming tool calls (`sandbox_exec`,
//  `shell_run`, including `background:true` jobs). Tools register an
//  `Entry` keyed by tool-call-id when they start; the chat UI observes
//  the registry and binds each row's `TerminalDisplayView` to the matching
//  entry's publishers. The registry itself never routes bytes — it just
//  hands out the per-call publishers + the `terminate` closure.
//
//  Lifecycle:
//   - On entry register, `entriesPublisher` emits the new map.
//   - On `unregister`, the entry is kept for 3 s as a "grace tail" so a
//     row that scrolls in just after a fast command finishes can still
//     bind, see the seeded output, and then notice `.exited`. Was 60 s
//     in earlier iterations — dropped to 3 s once `TerminalDisplayView`
//     learned to render from the envelope-shaped `TerminalSnapshot`,
//     so completed rendering no longer depends on the registry holding
//     the entry around.
//   - `clearAll()` drops every entry immediately (used by integration
//     tests; production only ever calls `unregister`).
//

import Combine
import Foundation

public actor LiveExecRegistry {
    public static let shared = LiveExecRegistry()

    /// Status of a live exec. `.running` is the initial state; one of
    /// `.exited` / `.killed` is terminal and is the last value the
    /// `statusPublisher` ever emits before completing.
    public enum LiveExecStatus: Sendable, Equatable {
        case running
        case exited(Int32)
        case killed(reason: String)  // "user" | "timeout" | "signal:NN"
    }

    /// Per-tool-call streaming handle. Holds the publishers + terminate
    /// closure but no state of its own — the producing tool body owns
    /// the underlying `PassthroughSubject` / cancellation handle and is
    /// responsible for emitting the terminal status before unregistering.
    ///
    /// `@unchecked Sendable` because `AnyPublisher` isn't formally
    /// Sendable in Combine even when its `Output` / `Failure` are. The
    /// types we route (`Data`, `LiveExecStatus`) are both Sendable, so
    /// the marker is safe in practice.
    public struct Entry: @unchecked Sendable {
        public let toolCallId: String
        public let pid: String  // "" for foreground until known
        public let command: String
        public let startedAt: Date
        public let outputPublisher: AnyPublisher<Data, Never>
        public let statusPublisher: AnyPublisher<LiveExecStatus, Never>
        /// Synchronous read of the most recent status. Lets the chat
        /// UI decide "show live pane vs. static result" without waiting
        /// for a publisher tick — important for the fast-command case
        /// where the tool exits in the same runloop tick the entry is
        /// registered in.
        public let currentStatus: @Sendable () -> LiveExecStatus
        /// Buffered tail for late binders. Returns whatever bytes have
        /// accumulated so far so a row that scrolls in mid-stream
        /// renders the full context before subscribing to live updates.
        public let seed: @Sendable () async -> Data
        /// Send SIGTERM, then SIGKILL after `graceSeconds`. Idempotent —
        /// callers that race (model + UI) should both end up at the
        /// same exit signal.
        public let terminate: @Sendable (_ graceSeconds: Int) async -> Void
        /// Best-effort resource cleanup invoked exactly once when the entry
        /// leaves the registry (grace drop, `clearAll`, `terminateAll`).
        /// Background jobs use it to cancel their detached pid-poll task and
        /// stop the log tailer so neither outlives the entry. Must be
        /// idempotent and non-blocking. `nil` for entries (foreground tools)
        /// that own no detached resources.
        public let onDrop: (@Sendable () -> Void)?

        public init(
            toolCallId: String,
            pid: String,
            command: String,
            startedAt: Date,
            outputPublisher: AnyPublisher<Data, Never>,
            statusPublisher: AnyPublisher<LiveExecStatus, Never>,
            currentStatus: @escaping @Sendable () -> LiveExecStatus,
            seed: @escaping @Sendable () async -> Data,
            terminate: @escaping @Sendable (_ graceSeconds: Int) async -> Void,
            onDrop: (@Sendable () -> Void)? = nil
        ) {
            self.toolCallId = toolCallId
            self.pid = pid
            self.command = command
            self.startedAt = startedAt
            self.outputPublisher = outputPublisher
            self.statusPublisher = statusPublisher
            self.currentStatus = currentStatus
            self.seed = seed
            self.terminate = terminate
            self.onDrop = onDrop
        }
    }

    private var entries: [String: Entry] = [:]
    /// Per-call cleanup task scheduled by `unregister`. We keep a handle
    /// so a re-`register` of the same id (extremely rare; only tests
    /// would do this) cancels the pending drop.
    private var pendingDrops: [String: Task<Void, Never>] = [:]

    /// `CurrentValueSubject` is thread-safe; `nonisolated(unsafe)` is
    /// the standard pattern for letting both the actor's mutating
    /// methods AND the `nonisolated` accessor below touch it.
    private nonisolated(unsafe) let entriesSubject = CurrentValueSubject<[String: Entry], Never>([:])

    /// Live snapshot of every registered entry. The chat layer
    /// subscribes once and on each emission walks current tool-call
    /// items, attaching matching entries by `toolCallId`.
    public nonisolated var entriesPublisher: AnyPublisher<[String: Entry], Never> {
        entriesSubject.eraseToAnyPublisher()
    }

    /// Synchronous snapshot of the current entries. Lets a tool-call
    /// cell decide "live or static?" inline during `configure(item:)`
    /// without an actor hop. The underlying subject is thread-safe.
    public nonisolated func currentEntries() -> [String: Entry] {
        entriesSubject.value
    }

    /// Grace window between a tool's `unregister` and the entry being
    /// dropped from the live snapshot. Lets a row that mounts a few
    /// seconds after a fast command finishes still bind, replay the
    /// seed, and notice `.exited` via the publisher. 3 s is enough
    /// for the row's `bind → seed → applyStatus` round trip to settle
    /// without holding stale entries around for a full minute — the
    /// snapshot-based completed render owns the long-tail case.
    private static let dropGrace: TimeInterval = 3

    /// Register a fresh entry. Replaces any existing entry under the
    /// same id (and cancels the pending drop, if one is in flight).
    public func register(_ entry: Entry) {
        pendingDrops.removeValue(forKey: entry.toolCallId)?.cancel()
        entries[entry.toolCallId] = entry
        entriesSubject.send(entries)
    }

    /// Look up an entry by tool-call-id. Returns nil if no entry has
    /// ever been registered for that id, OR if the entry's grace
    /// window already elapsed and it was dropped.
    public func handle(toolCallId: String) -> Entry? {
        entries[toolCallId]
    }

    /// Mark the entry as eligible for cleanup. Drops it from the live
    /// snapshot after `dropGrace` seconds so late-mounting UI rows
    /// still see the seed + terminal status.
    public func unregister(toolCallId: String) {
        // Cancel any prior pending drop for this id, then schedule a fresh one.
        pendingDrops.removeValue(forKey: toolCallId)?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.dropGrace * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.dropAfterGrace(toolCallId: toolCallId)
        }
        pendingDrops[toolCallId] = task
    }

    /// Test-only escape hatch. Drops everything immediately and
    /// cancels every pending grace task.
    public func clearAll() {
        for (_, task) in pendingDrops { task.cancel() }
        pendingDrops.removeAll()
        let dropped = Array(entries.values)
        entries.removeAll()
        entriesSubject.send(entries)
        for entry in dropped { entry.onDrop?() }
    }

    /// Quit-path teardown: SIGKILL every still-running live exec (background
    /// `shell_run` / `sandbox_exec` jobs) then drop all entries. `clearAll()`
    /// alone only clears the UI snapshot — it leaves the underlying child
    /// processes to be reaped by the OS, which can orphan them briefly after
    /// a force-quit. `graceSeconds: 0` sends SIGKILL immediately.
    public func terminateAll(graceSeconds: Int = 0) async {
        let live = Array(entries.values)
        for entry in live {
            await entry.terminate(graceSeconds)
        }
        clearAll()
    }

    private func dropAfterGrace(toolCallId: String) {
        pendingDrops.removeValue(forKey: toolCallId)
        guard let dropped = entries.removeValue(forKey: toolCallId) else { return }
        entriesSubject.send(entries)
        dropped.onDrop?()
    }
}
