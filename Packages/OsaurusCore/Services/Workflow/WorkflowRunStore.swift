//
//  WorkflowRunStore.swift
//  osaurus
//
//  Live and persisted workflow runs. The runner publishes every state
//  change here; views (workflow tabs, the Architect run view, history
//  lists) observe `live`. Each change is written through to
//  `WorkflowRunDatabase`, so a run's record survives relaunch.
//

import Combine
import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "workflow.runs")

@MainActor
public final class WorkflowRunStore: ObservableObject {
    public static let shared = WorkflowRunStore()

    /// Runs updated during this launch, by id.
    @Published public private(set) var live: [UUID: WorkflowRun] = [:]

    private let database: WorkflowRunDatabase
    private var opened = false
    /// Every pending write's run is also in `live`, so reads that lay `live`
    /// over the database need no flush; reads that skip `live` flush first.
    private nonisolated let writer: WorkflowRunDiskWriter

    private nonisolated static let sharedWriter = WorkflowRunDiskWriter(database: .shared)

    init(database: WorkflowRunDatabase = .shared) {
        self.database = database
        writer = database === WorkflowRunDatabase.shared ? Self.sharedWriter : WorkflowRunDiskWriter(database: database)
        writer.onPruned = { [weak self] in
            Task { @MainActor in self?.applyPrunedRuns() }
        }
    }

    /// Blocks until every run recorded so far is written, bounded by
    /// `timeout`. Called at quit, where `_exit` would skip a pending write.
    nonisolated public static func flushPendingWrites(timeout: TimeInterval = 3.0) {
        sharedWriter.flush(timeout: timeout)
    }

    /// Writes every pending run now and drops runs retention pushed out.
    func flushPendingWrites() {
        writer.flush()
        applyPrunedRuns()
    }

    private func applyPrunedRuns() {
        for batch in writer.takePruned() {
            for id in batch.ids where live[id]?.status.isTerminal != false {
                live[id] = nil
                finishedRecords[id] = nil
                removeFiles(workflowID: batch.workflowID, templateID: batch.templateID, runID: id)
            }
        }
    }

    private func ensureOpen() -> Bool {
        if opened || database.isOpen {
            opened = true
            return true
        }
        do {
            // Test processes swap `OsaurusPaths` roots per test. An on-disk
            // open registers a maintenance handle that outlives its root, and
            // storage converge would reopen it inside another test's root.
            if RuntimeEnvironment.isUnderTests {
                try database.openInMemory()
            } else {
                try database.open()
            }
            opened = true
        } catch {
            logger.error("Workflow run database unavailable: \(error.localizedDescription, privacy: .public)")
        }
        return opened
    }

    public func record(_ run: WorkflowRun) {
        var run = run
        // The runner records from its own copy, which does not see replies
        // counted here since its last write (or before a relaunch).
        let known = live[run.id] ?? (ensureOpen() ? try? database.run(id: run.id) : nil)
        if let known, known.channelReplyCount > run.channelReplyCount {
            run.channelReplyCount = known.channelReplyCount
        }
        // Republishing an identical run would re-render every observer.
        if live[run.id] == run { return }
        live[run.id] = run
        guard ensureOpen() else { return }
        // The record carries every node's input, output and streamed text;
        // encoding and writing it here stalled the UI while a step streamed.
        writer.save(run)
        if run.status.isTerminal { pruneWorkspaces(around: run) }
    }

    /// Deletes these runs and their files. A run still going is kept.
    public func deleteRuns(ids: [UUID]) {
        for id in ids {
            guard let run = run(id: id), run.status.isTerminal else { continue }
            live[id] = nil
            finishedRecords[id] = nil
            recentPersisted = recentPersisted?.filter { $0.id != id }
            if ensureOpen() { writer.delete(id: id) }
            removeFiles(workflowID: run.workflowID, templateID: run.templateID, runID: id)
        }
    }

    private func removeFiles(workflowID: UUID, templateID: UUID, runID: UUID) {
        let fm = FileManager.default
        try? fm.removeItem(at: OsaurusPaths.workflowRunArtifacts(workflowID: workflowID, runID: runID))
        try? fm.removeItem(at: OsaurusPaths.workflowRunWorkspace(workflowID: workflowID, runID: runID))
        try? fm.removeItem(at: OsaurusPaths.workflowSandboxRunWorkspace(environmentID: templateID, runID: runID))
    }

    /// Scratch workspaces kept per workflow. Run records (and the artifacts
    /// they show) keep `WorkflowRunDatabase.retentionPerWorkflow`; a
    /// workspace only matters to a retry, so only the newest few stay.
    static let workspaceRetentionPerWorkflow = 20

    /// Drops the oldest scratch workspaces of `run`'s workflow, on the host
    /// and in its sandbox home, never one an unfinished run still uses.
    private func pruneWorkspaces(around run: WorkflowRun) {
        var inUse = Set<String>()
        for other in live.values where !other.status.isTerminal {
            inUse.insert(other.id.uuidString.lowercased())
            if let shared = other.workspaceRunID { inUse.insert(shared.uuidString.lowercased()) }
        }
        let parents = [
            OsaurusPaths.workflowRunWorkspace(workflowID: run.workflowID, runID: run.id).deletingLastPathComponent(),
            OsaurusPaths.workflowSandboxRunWorkspace(environmentID: run.templateID, runID: run.id)
                .deletingLastPathComponent(),
        ]
        let keep = Self.workspaceRetentionPerWorkflow
        Task.detached(priority: .utility) {
            for parent in parents {
                for stale in Self.staleWorkspaces(in: parent, keep: keep, inUse: inUse) {
                    try? FileManager.default.removeItem(at: stale)
                }
            }
        }
    }

    /// Run folders under `parent` beyond the newest `keep`, oldest last
    /// touched first, leaving out `inUse` names.
    nonisolated static func staleWorkspaces(in parent: URL, keep: Int, inUse: Set<String>) -> [URL] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        let folders = entries.compactMap { url -> (url: URL, modified: Date)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true, UUID(uuidString: url.lastPathComponent) != nil else { return nil }
            return (url, values?.contentModificationDate ?? .distantPast)
        }
        guard folders.count > keep else { return [] }
        return folders.sorted { $0.modified > $1.modified }
            .dropFirst(keep)
            .filter { !inUse.contains($0.url.lastPathComponent.lowercased()) }
            .map(\.url)
    }

    public func run(id: UUID) -> WorkflowRun? {
        if let run = live[id] { return run }
        if let run = finishedRecords[id] { return run }
        guard ensureOpen(), let run = try? database.run(id: id) else { return nil }
        if run.status.isTerminal {
            if finishedRecords.count >= Self.finishedRecordLimit { finishedRecords.removeAll() }
            finishedRecords[id] = run
        }
        return run
    }

    /// Finished runs read back from the database. Views ask for the same
    /// few (a draft's latest test) on every redraw; a finished record only
    /// changes through `record`, which `live` already shadows.
    private var finishedRecords: [UUID: WorkflowRun] = [:]
    private static let finishedRecordLimit = 64

    /// Counts one channel reply for `runID` and persists it. Returns the
    /// new count, or nil for a run with no record.
    @discardableResult
    func noteChannelReply(runID: UUID) -> Int? {
        guard var run = run(id: runID) else { return nil }
        run.channelReplyCount += 1
        record(run)
        return run.channelReplyCount
    }

    /// Newest first: live runs merged over persisted ones. Pass
    /// `includeTests: false` for what the workflow did for people and
    /// agents, leaving out Architect test runs and eval runs.
    public func runs(workflowID: UUID, limit: Int = 50, includeTests: Bool = true) -> [WorkflowRun] {
        var byID: [UUID: WorkflowRun] = [:]
        if ensureOpen() {
            for run in (try? database.runs(workflowID: workflowID, limit: limit, includeTests: includeTests)) ?? [] {
                byID[run.id] = run
            }
        }
        for run in live.values where run.workflowID == workflowID && (includeTests || !run.isTest) {
            byID[run.id] = run
        }
        return byID.values.sorted { $0.startedAt > $1.startedAt }.prefix(limit).map { $0 }
    }

    /// One workflow's persisted runs, newest first, decoded off the main
    /// actor. Live runs are not merged in.
    public func loadRuns(workflowID: UUID, limit: Int = 50, includeTests: Bool = true) async -> [WorkflowRun] {
        guard ensureOpen() else { return [] }
        let database = database
        let writer = writer
        return await Task.detached(priority: .userInitiated) {
            writer.flush()
            return (try? database.runs(workflowID: workflowID, limit: limit, includeTests: includeTests)) ?? []
        }.value
    }

    /// Every workflow's newest persisted runs (tests left out) as of the
    /// first load this launch; nil until then. Runs recorded since are in
    /// `live`, so one load is enough.
    @Published public private(set) var recentPersisted: [WorkflowRun]?
    private var isLoadingRecent = false

    /// Fills `recentPersisted` once. Records carry every node's input and
    /// output, so they are decoded off the main actor.
    public func loadRecentRunsIfNeeded(limit: Int = 200) async {
        guard recentPersisted == nil, !isLoadingRecent else { return }
        guard ensureOpen() else {
            recentPersisted = []
            return
        }
        isLoadingRecent = true
        defer { isLoadingRecent = false }
        let database = database
        recentPersisted = await Task.detached(priority: .userInitiated) {
            (try? database.recentRuns(limit: limit)) ?? []
        }.value
    }

    /// `recentPersisted` with this launch's runs (tests left out) laid
    /// over it, newest first. Wrapper and ephemeral runs are left out:
    /// they belong to no installed workflow.
    public func recentRuns(limit: Int = 200) -> [WorkflowRun] {
        var byID: [UUID: WorkflowRun] = [:]
        for run in recentPersisted ?? [] where !run.isDerived { byID[run.id] = run }
        for run in live.values where !run.isTest && !run.isDerived { byID[run.id] = run }
        return byID.values.sorted { $0.startedAt > $1.startedAt }.prefix(limit).map { $0 }
    }

    public func deleteRuns(workflowID: UUID) {
        live = live.filter { $0.value.workflowID != workflowID }
        finishedRecords = finishedRecords.filter { $0.value.workflowID != workflowID }
        recentPersisted = recentPersisted?.filter { $0.workflowID != workflowID }
        if ensureOpen() { writer.deleteRuns(workflowID: workflowID) }
        for folder in ["runs", "artifacts"] {
            try? FileManager.default.removeItem(
                at: OsaurusPaths.workflowDirectory(workflowID).appendingPathComponent(folder, isDirectory: true))
        }
    }

    /// Runs a previous launch left running or awaiting the user, oldest
    /// first: persisted as open and not touched this launch.
    /// `WorkflowRunService.resumeAbandonedRuns` picks them up at startup.
    public func abandonedRuns() -> [WorkflowRun] {
        guard ensureOpen() else { return [] }
        flushPendingWrites()
        return ((try? database.openRuns()) ?? []).filter { live[$0.id] == nil }
    }

    /// Closes an abandoned run that cannot be picked up again. Published
    /// to `live` so workflow tabs restored before this ran update.
    public func closeAbandonedRun(_ run: WorkflowRun, reason: String) {
        var closed = run
        closed.status = .cancelled
        closed.error = WorkflowRunError(reason: reason)
        closed.finishedAt = Date()
        for node in closed.nodes
        where node.status == .pending || node.status == .running || node.status == .awaitingUser {
            closed.update(node.nodeID) {
                $0.status = .skipped
                if $0.finishedAt == nil, $0.startedAt != nil { $0.finishedAt = Date() }
            }
        }
        record(closed)
    }

    func resetForTesting() {
        flushPendingWrites()
        live = [:]
        finishedRecords = [:]
        recentPersisted = nil
    }
}

/// Writes run records off the main actor. Pending writes of one run collapse
/// to its latest state; a streaming run is written at most every
/// `streamingWriteDelay`, a finished one right away. Writes and deletes run
/// in order on one queue.
final class WorkflowRunDiskWriter: @unchecked Sendable {
    struct PrunedBatch {
        let ids: [UUID]
        let workflowID: UUID
        let templateID: UUID
    }

    static let streamingWriteDelay: TimeInterval = 0.25

    private let database: WorkflowRunDatabase
    private let queue = DispatchQueue(label: "ai.osaurus.workflow.runs.write", qos: .utility)
    private let lock = NSLock()
    private var pending: [UUID: WorkflowRun] = [:]
    private var drainScheduled = false
    private var pruned: [PrunedBatch] = []
    /// Runs already in the table. Only the first write of a run inserts a
    /// row, and only an insert can push an older run past retention.
    /// Touched only on `queue`.
    private var written: Set<UUID> = []
    /// Called on the write queue after a write dropped older runs; collect
    /// them with `takePruned()`. Set once, before the first save.
    var onPruned: (@Sendable () -> Void)?

    init(database: WorkflowRunDatabase) {
        self.database = database
    }

    func save(_ run: WorkflowRun) {
        let immediate = run.status.isTerminal || run.status == .awaitingUser
        let schedule = lock.withLock {
            pending[run.id] = run
            guard immediate || !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
        guard schedule else { return }
        if immediate {
            queue.async { self.drain() }
        } else {
            queue.asyncAfter(deadline: .now() + Self.streamingWriteDelay) { self.drain() }
        }
    }

    /// Deletes synchronously: callers read the table right after.
    func delete(id: UUID) {
        lock.withLock { pending[id] = nil }
        queue.sync {
            try? database.deleteRun(id: id)
            written.remove(id)
        }
    }

    func deleteRuns(workflowID: UUID) {
        lock.withLock { pending = pending.filter { $0.value.workflowID != workflowID } }
        queue.sync {
            try? database.deleteRuns(workflowID: workflowID)
            written.removeAll()
        }
    }

    /// Writes everything pending; with a `timeout`, waits at most that long.
    func flush(timeout: TimeInterval? = nil) {
        guard let timeout else { return queue.sync { drain() } }
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.drain()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    func takePruned() -> [PrunedBatch] {
        lock.withLock {
            defer { pruned.removeAll() }
            return pruned
        }
    }

    private func drain() {
        let runs = lock.withLock {
            drainScheduled = false
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        var droppedAny = false
        for run in runs.sorted(by: { $0.startedAt < $1.startedAt }) {
            do {
                let dropped = try database.upsert(run, pruneOlder: !written.contains(run.id))
                written.insert(run.id)
                guard !dropped.isEmpty else { continue }
                droppedAny = true
                let batch = PrunedBatch(ids: dropped, workflowID: run.workflowID, templateID: run.templateID)
                lock.withLock { pruned.append(batch) }
            } catch {
                logger.error("Failed to save run \(run.id): \(error.localizedDescription, privacy: .public)")
            }
        }
        if droppedAny { onPruned?() }
    }
}
