//
//  SandboxWorkspaceChangeTracker.swift
//  osaurus
//
//  Tracks net sandbox-workspace file changes per chat session and provides
//  conflict-aware undo.
//
//  Mechanism: the first time a session mutates an agent's workspace, the
//  host-side VirtioFS root (agent home / shared) is cloned into a per-session
//  baseline directory (APFS clones via FileManager.copyItem, so the snapshot
//  is cheap and byte-exact for binary files). Every mutation-capable tool
//  call is wrapped in a begin/end checkpoint pair: a cheap manifest scan
//  (type + size + mtime) before and after bounds the set of paths the call
//  touched, and each touched path is re-diffed against the baseline clone to
//  produce ONE outstanding net change per path (created / modified /
//  deleted). Background jobs record their pre-manifest at spawn and are
//  reconciled when the job exits (or on app relaunch for jobs that died with
//  the previous run's VM).
//
//  Change rows persist in ChatHistoryDatabase (`sandbox_changes`, migration
//  v9); baseline bytes persist as the clone directory, so both the Changes
//  list and undo survive app relaunch. Undo restores from the baseline clone
//  only when the live file still matches the last state this chat recorded —
//  anything changed afterwards by another chat, a background process, or the
//  user is marked `conflicted` and never overwritten.
//

import CryptoKit
import Foundation
import os

// MARK: - Notifications

extension Notification.Name {
    /// Posted (on main) whenever tracked sandbox changes for a session are
    /// added, coalesced away, undone, or marked conflicted. `userInfo` carries
    /// `"sessionId"` (uuid string).
    public static let sandboxWorkspaceChangesDidChange = Notification.Name(
        "sandboxWorkspaceChangesDidChange")
}

// MARK: - Undo result

public enum SandboxUndoResult: Sendable, Equatable {
    case undone
    /// The live path no longer matches the last state this chat recorded;
    /// the row is retained and flagged instead of overwriting newer work.
    case conflicted
    /// A background job spawned by this session is still running.
    case blockedByActiveJob
    case failed(String)
}

/// Aggregate outcome of an Undo All.
public struct SandboxUndoSummary: Sendable, Equatable {
    public var undone: Int = 0
    public var conflicted: Int = 0
    public var failed: Int = 0
}

// MARK: - Change diff

/// Baseline-vs-live diff for one tracked change, rendered in the Changes
/// sheet. `unavailable` covers directories, symlinks, and unreadable files.
public enum SandboxChangeDiffResult: Sendable, Equatable {
    /// Unified-diff text in the `WorkspaceWriteSafety.unifiedDiffText` format
    /// (parseable by `FileDiff.fromUnifiedDiff`).
    case diff(String)
    case binary
    case tooLarge
    case unavailable
}

// MARK: - Tracker

public actor SandboxWorkspaceChangeTracker {
    public static let shared = SandboxWorkspaceChangeTracker()

    // MARK: Types

    struct ManifestEntry: Codable, Equatable, Sendable {
        let type: SandboxChangeEntryType
        let size: Int64
        let mtimeNs: Int64
        let linkTarget: String?
    }

    typealias Manifest = [String: ManifestEntry]

    /// Opaque handle returned by `beginCheckpoint`, consumed by `endCheckpoint`.
    public struct CheckpointToken: Sendable {
        let sessionId: String
        let agentName: String
        let sourceTool: String
        fileprivate let preManifests: [SandboxWorkspaceRootKind: Manifest]
    }

    /// Persisted record for a background job whose mutations land after the
    /// launching tool call returned. Reconciled on job exit or app relaunch.
    struct PendingJobRecord: Codable, Sendable {
        let sessionId: String
        let agentName: String
        let pid: String
        let sourceTool: String
        let registeredAt: Date
        /// Root raw value → manifest at spawn time.
        let preManifests: [String: Manifest]
    }

    // MARK: State

    private let database: ChatHistoryDatabase
    private let baselinesRoot: URL
    private let hostRootProvider: @Sendable (String, SandboxWorkspaceRootKind) -> URL
    /// Whether undo fixes container-side ownership afterwards (disabled in tests).
    private let ownershipRepairEnabled: Bool

    /// sessionId → outstanding rows. In-process source of truth; the DB is
    /// the durable mirror.
    private var cache: [String: [SandboxWorkspaceChange]] = [:]
    private var loadedSessions: Set<String> = []
    /// Writes deferred while the chat-history DB is closed (key rotation /
    /// early launch); flushed on the next persistence touch.
    private var pendingUpserts: [UUID: SandboxWorkspaceChange] = [:]
    private var pendingRowDeletes: Set<UUID> = []
    /// (agentName|pid) → pending background-job record.
    private var pendingJobs: [String: PendingJobRecord] = [:]
    private var recovered = false

    private static let log = Logger(subsystem: "ai.osaurus", category: "sandbox.changes")

    /// Directory-name components excluded from tracking anywhere in a path:
    /// dependency/build caches whose churn would flood the list, VCS
    /// internals, and the runtime's own edit scratch dir.
    static let excludedDirectoryNames: Set<String> = [
        ".venv", "node_modules", "__pycache__", ".cache", ".npm", ".git", ".tmp",
    ]

    /// Roots with more entries than this are skipped for a checkpoint rather
    /// than stalling every tool call on a giant scan.
    private static let maxTrackedEntries = 25_000
    /// Files above this hash by size+mtime instead of content.
    private static let maxHashBytes: Int64 = 64 * 1024 * 1024

    // MARK: Init

    public init() {
        self.database = ChatHistoryDatabase.shared
        self.baselinesRoot = OsaurusPaths.root().appendingPathComponent(
            "sandbox-baselines", isDirectory: true)
        self.hostRootProvider = { agentName, root in root.hostURL(agentName: agentName) }
        self.ownershipRepairEnabled = true
    }

    /// Test entry point: isolated DB, baselines dir, and workspace roots.
    init(
        database: ChatHistoryDatabase,
        baselinesRoot: URL,
        hostRootProvider: @escaping @Sendable (String, SandboxWorkspaceRootKind) -> URL,
        ownershipRepairEnabled: Bool = false
    ) {
        self.database = database
        self.baselinesRoot = baselinesRoot
        self.hostRootProvider = hostRootProvider
        self.ownershipRepairEnabled = ownershipRepairEnabled
    }

    // MARK: - Checkpoints

    /// Snapshot the workspace before a mutation-capable tool runs. Creates
    /// the session baseline clone on first use and captures a manifest that
    /// bounds which paths the call touched.
    public func beginCheckpoint(
        sessionId: String,
        agentName: String,
        sourceTool: String
    ) -> CheckpointToken {
        ensureRecovered()
        var pre: [SandboxWorkspaceRootKind: Manifest] = [:]
        for root in SandboxWorkspaceRootKind.sandboxRoots {
            guard ensureBaseline(sessionId: sessionId, agentName: agentName, root: root) != nil
            else { continue }
            guard let manifest = scanManifest(root: hostRoot(agentName: agentName, root: root))
            else { continue }
            pre[root] = manifest
        }
        return CheckpointToken(
            sessionId: sessionId,
            agentName: agentName,
            sourceTool: sourceTool,
            preManifests: pre
        )
    }

    /// Snapshot the user-selected host folder before a mutation-capable
    /// folder tool runs. Same lifecycle as `beginCheckpoint`, but over a
    /// single `.hostFolder` root whose identity is the folder's absolute
    /// path (carried in the token's `agentName` slot).
    ///
    /// Order matters here: the manifest is scanned BEFORE the baseline is
    /// cloned. A user-selected folder can be arbitrarily large, and the scan
    /// is the cheap size gate — if it bails (> `maxTrackedEntries`), no
    /// baseline clone is attempted and tracking is skipped for the call.
    public func beginHostCheckpoint(
        sessionId: String,
        folderPath: String,
        sourceTool: String
    ) -> CheckpointToken {
        ensureRecovered()
        var pre: [SandboxWorkspaceRootKind: Manifest] = [:]
        let root = SandboxWorkspaceRootKind.hostFolder
        if let manifest = scanManifest(root: hostRoot(agentName: folderPath, root: root)),
            ensureBaseline(sessionId: sessionId, agentName: folderPath, root: root) != nil
        {
            pre[root] = manifest
        }
        return CheckpointToken(
            sessionId: sessionId,
            agentName: folderPath,
            sourceTool: sourceTool,
            preManifests: pre
        )
    }

    /// Diff the workspace after the tool ran and fold touched paths into the
    /// session's net change set.
    public func endCheckpoint(_ token: CheckpointToken) async {
        var didChange = false
        for (root, pre) in token.preManifests {
            guard let post = scanManifest(root: hostRoot(agentName: token.agentName, root: root))
            else { continue }
            let touched = Self.touchedPaths(pre: pre, post: post)
            guard !touched.isEmpty else { continue }
            if applyNetChanges(
                touched: touched,
                sessionId: token.sessionId,
                agentName: token.agentName,
                root: root,
                sourceTool: token.sourceTool
            ) {
                didChange = true
            }
        }
        if didChange { notify(sessionId: token.sessionId) }
    }

    // MARK: - Background jobs

    /// Record a spawned background job so its later mutations can still be
    /// attributed to the launching session. Persisted to disk so a job that
    /// outlives the app run is reconciled on next launch.
    public func registerBackgroundJob(
        sessionId: String,
        agentName: String,
        pid: String,
        sourceTool: String
    ) {
        ensureRecovered()
        var manifests: [String: Manifest] = [:]
        for root in SandboxWorkspaceRootKind.sandboxRoots {
            guard ensureBaseline(sessionId: sessionId, agentName: agentName, root: root) != nil
            else { continue }
            guard let manifest = scanManifest(root: hostRoot(agentName: agentName, root: root))
            else { continue }
            manifests[root.rawValue] = manifest
        }
        let record = PendingJobRecord(
            sessionId: sessionId,
            agentName: agentName,
            pid: pid,
            sourceTool: sourceTool,
            registeredAt: Date(),
            preManifests: manifests
        )
        pendingJobs[Self.jobKey(agentName: agentName, pid: pid)] = record
        persistPendingJob(record)
        // Presence of an active job flips the UI into "job running" mode.
        notify(sessionId: sessionId)
    }

    /// Reconcile a background job's mutations after it exited or was killed.
    /// Safe to call multiple times / for unknown jobs.
    public func finalizeBackgroundJob(agentName: String, pid: String) async {
        ensureRecovered()
        let key = Self.jobKey(agentName: agentName, pid: pid)
        guard let record = pendingJobs.removeValue(forKey: key) else { return }
        removePendingJobFile(record)
        finalize(record)
    }

    /// True while a background job spawned by this session may still be
    /// mutating the workspace (undo is hidden/disabled meanwhile).
    public func hasActiveBackgroundJobs(sessionId: String) -> Bool {
        ensureRecovered()
        return pendingJobs.values.contains { $0.sessionId == sessionId }
    }

    private func finalize(_ record: PendingJobRecord) {
        var didChange = false
        for root in SandboxWorkspaceRootKind.sandboxRoots {
            guard let pre = record.preManifests[root.rawValue] else { continue }
            let baseline = baselineDir(
                sessionId: record.sessionId, agentName: record.agentName, root: root)
            guard FileManager.default.fileExists(atPath: baseline.path) else { continue }
            guard let post = scanManifest(root: hostRoot(agentName: record.agentName, root: root))
            else { continue }
            let touched = Self.touchedPaths(pre: pre, post: post)
            guard !touched.isEmpty else { continue }
            if applyNetChanges(
                touched: touched,
                sessionId: record.sessionId,
                agentName: record.agentName,
                root: root,
                sourceTool: record.sourceTool
            ) {
                didChange = true
            }
        }
        // Always notify: even a no-change exit clears the "job running"
        // state the UI keys off `hasActiveBackgroundJobs`.
        _ = didChange
        notify(sessionId: record.sessionId)
    }

    // MARK: - Queries

    public func changes(for sessionId: String) -> [SandboxWorkspaceChange] {
        ensureRecovered()
        loadIfNeeded(sessionId)
        return (cache[sessionId] ?? []).sorted {
            ($0.agentName, $0.root.rawValue, $0.relativePath)
                < ($1.agentName, $1.root.rawValue, $1.relativePath)
        }
    }

    public func changeCount(for sessionId: String) -> Int {
        ensureRecovered()
        loadIfNeeded(sessionId)
        return cache[sessionId]?.count ?? 0
    }

    /// Unified diff of the session's pre-chat baseline vs the live file for
    /// one tracked change. Text files only; both sides are size-capped so a
    /// huge artifact can't stall the UI.
    public func diffText(for id: UUID, sessionId: String) -> SandboxChangeDiffResult {
        ensureRecovered()
        loadIfNeeded(sessionId)
        guard let change = cache[sessionId]?.first(where: { $0.id == id }),
            change.entryType == .file
        else { return .unavailable }

        let baselineURL = baselineDir(
            sessionId: change.sessionId,
            agentName: change.agentName,
            root: change.root
        ).appendingPathComponent(change.relativePath)
        let liveURL = hostRoot(agentName: change.agentName, root: change.root)
            .appendingPathComponent(change.relativePath)

        // `created` has no baseline side; `deleted` has no live side. A
        // missing file on the expected side means the state moved under us —
        // report unavailable rather than diffing against the wrong content.
        let old: String?
        switch readTextSide(at: baselineURL, expected: change.kind != .created) {
        case .text(let s): old = s
        case .absent: old = nil
        case .binary: return .binary
        case .tooLarge: return .tooLarge
        case .unreadable: return .unavailable
        }
        let new: String?
        switch readTextSide(at: liveURL, expected: change.kind != .deleted) {
        case .text(let s): new = s
        case .absent: new = nil
        case .binary: return .binary
        case .tooLarge: return .tooLarge
        case .unreadable: return .unavailable
        }
        guard old != nil || new != nil else { return .unavailable }

        let text = WorkspaceWriteSafety.unifiedDiffText(
            old: old ?? "",
            new: new ?? "",
            path: change.displayPath,
            existed: old != nil
        ).text
        return .diff(text)
    }

    private enum TextSide {
        case text(String)
        case absent
        case binary
        case tooLarge
        case unreadable
    }

    /// Max bytes per side fed into the line diff (the diff itself is further
    /// capped by `WorkspaceWriteSafety`).
    private static let maxDiffSideBytes = 1_000_000

    private func readTextSide(at url: URL, expected: Bool) -> TextSide {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
            (attrs[.type] as? FileAttributeType) == .typeRegular
        else { return expected ? .unreadable : .absent }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxDiffSideBytes else { return .tooLarge }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        // NUL byte is the standard "this is binary" heuristic (same as git's).
        guard !data.contains(0) else { return .binary }
        guard let text = String(data: data, encoding: .utf8) else { return .binary }
        return .text(text)
    }

    // MARK: - Undo

    /// Undo a single change. Refuses (without modifying anything) when a
    /// background job from this session is still running or the live path
    /// diverged from the last tracked state.
    public func undoChange(id: UUID, sessionId: String) async -> SandboxUndoResult {
        ensureRecovered()
        loadIfNeeded(sessionId)
        guard !hasActiveBackgroundJobs(sessionId: sessionId) else { return .blockedByActiveJob }
        guard var rows = cache[sessionId], let idx = rows.firstIndex(where: { $0.id == id })
        else { return .failed("Change not found") }
        let change = rows[idx]
        let result = performUndo(change)
        switch result {
        case .undone:
            rows.remove(at: idx)
            cache[sessionId] = rows
            persistDelete(id: change.id)
            gcBaselineIfDone(sessionId: sessionId)
            await repairOwnership(for: [change])
        case .conflicted:
            var updated = change
            updated.state = .conflicted
            rows[idx] = updated
            cache[sessionId] = rows
            persistUpsert(updated)
        case .failed, .blockedByActiveJob:
            break
        }
        notify(sessionId: sessionId)
        return result
    }

    /// Undo every outstanding change for the session, best-effort. Failed
    /// and conflicted entries are retained (and reported) rather than
    /// silently dropped.
    public func undoAll(sessionId: String) async -> SandboxUndoSummary {
        ensureRecovered()
        loadIfNeeded(sessionId)
        guard !hasActiveBackgroundJobs(sessionId: sessionId) else {
            var summary = SandboxUndoSummary()
            summary.failed = cache[sessionId]?.count ?? 0
            return summary
        }
        var rows = cache[sessionId] ?? []
        guard !rows.isEmpty else { return SandboxUndoSummary() }

        // Restore deleted/modified entries parents-first, then remove created
        // entries children-first so a created directory is empty by the time
        // its own row is processed.
        let restoreOrder = rows.filter { $0.kind != .created }
            .sorted { Self.depth($0.relativePath) < Self.depth($1.relativePath) }
        let removeOrder = rows.filter { $0.kind == .created }
            .sorted { Self.depth($0.relativePath) > Self.depth($1.relativePath) }

        var summary = SandboxUndoSummary()
        var undoneChanges: [SandboxWorkspaceChange] = []
        for change in restoreOrder + removeOrder {
            switch performUndo(change) {
            case .undone:
                summary.undone += 1
                undoneChanges.append(change)
                rows.removeAll { $0.id == change.id }
                persistDelete(id: change.id)
            case .conflicted:
                summary.conflicted += 1
                if let idx = rows.firstIndex(where: { $0.id == change.id }) {
                    rows[idx].state = .conflicted
                    persistUpsert(rows[idx])
                }
            case .failed, .blockedByActiveJob:
                summary.failed += 1
            }
        }
        cache[sessionId] = rows
        gcBaselineIfDone(sessionId: sessionId)
        await repairOwnership(for: undoneChanges)
        notify(sessionId: sessionId)
        return summary
    }

    private func performUndo(_ change: SandboxWorkspaceChange) -> SandboxUndoResult {
        let liveURL = hostRoot(agentName: change.agentName, root: change.root)
            .appendingPathComponent(change.relativePath)
        let live = liveState(at: liveURL)

        // Conflict gate: the live path must still match the last state this
        // chat recorded for it.
        switch change.kind {
        case .created, .modified:
            guard live?.signature == change.currentSignature else { return .conflicted }
        case .deleted:
            guard live == nil else { return .conflicted }
        }

        let fm = FileManager.default
        do {
            switch change.kind {
            case .created:
                if change.entryType == .directory {
                    let contents = (try? fm.contentsOfDirectory(atPath: liveURL.path)) ?? []
                    guard contents.isEmpty else {
                        return .failed("Directory \(change.displayPath) is not empty")
                    }
                }
                if live != nil { try fm.removeItem(at: liveURL) }

            case .modified, .deleted:
                if change.entryType == .directory {
                    // Directory rows only exist for whole-directory
                    // create/delete; children restore via their own rows.
                    try fm.createDirectory(at: liveURL, withIntermediateDirectories: true)
                } else {
                    let baselineURL = baselineDir(
                        sessionId: change.sessionId,
                        agentName: change.agentName,
                        root: change.root
                    ).appendingPathComponent(change.relativePath)
                    guard liveState(at: baselineURL) != nil else {
                        return .failed("Baseline copy for \(change.displayPath) is missing")
                    }
                    if live != nil { try fm.removeItem(at: liveURL) }
                    try fm.createDirectory(
                        at: liveURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    // copyItem preserves bytes, permissions, and copies
                    // symlinks as symlinks (APFS clone when possible).
                    try fm.copyItem(at: baselineURL, to: liveURL)
                }
            }
        } catch {
            return .failed(error.localizedDescription)
        }
        return .undone
    }

    /// Restored files are written host-side, which can leave them owned by
    /// the wrong Unix user inside the container. Best-effort chown of the
    /// restored paths as root when the sandbox is running.
    private func repairOwnership(for changes: [SandboxWorkspaceChange]) async {
        guard ownershipRepairEnabled, !changes.isEmpty else { return }
        // Host-folder rows live outside the container; chown-in-container
        // makes no sense there (and `agentName` isn't an agent name).
        let restored = changes.filter { $0.kind != .created && $0.root != .hostFolder }
            .prefix(100)
        guard !restored.isEmpty else { return }
        var commandsByAgent: [String: [String]] = [:]
        for change in restored {
            let path = change.displayPath.replacingOccurrences(of: "'", with: "'\\''")
            commandsByAgent[change.agentName, default: []].append(
                "chown agent-\(change.agentName):agent-\(change.agentName) '\(path)'")
        }
        for (_, commands) in commandsByAgent {
            _ = try? await SandboxToolCommandRunnerRegistry.shared.execAsRoot(
                command: commands.joined(separator: "; ") + " 2>/dev/null || true",
                timeout: 10
            )
        }
    }

    // MARK: - Session lifecycle

    /// Drop everything tracked for a deleted/cleared session: rows, pending
    /// job records, and the baseline clone.
    public func purgeSession(_ sessionId: String) {
        ensureRecovered()
        cache[sessionId] = nil
        loadedSessions.remove(sessionId)
        if database.isOpen {
            try? database.deleteSandboxChanges(sessionId: sessionId)
        }
        for (key, record) in pendingJobs where record.sessionId == sessionId {
            pendingJobs.removeValue(forKey: key)
            removePendingJobFile(record)
        }
        try? FileManager.default.removeItem(
            at: baselinesRoot.appendingPathComponent(sessionId, isDirectory: true))
        notify(sessionId: sessionId)
    }

    // MARK: - Net change application

    @discardableResult
    private func applyNetChanges(
        touched: Set<String>,
        sessionId: String,
        agentName: String,
        root: SandboxWorkspaceRootKind,
        sourceTool: String
    ) -> Bool {
        loadIfNeeded(sessionId)
        var rows = cache[sessionId] ?? []
        var didChange = false
        let baselineRoot = baselineDir(sessionId: sessionId, agentName: agentName, root: root)
        let liveRoot = hostRoot(agentName: agentName, root: root)

        for rel in touched {
            let baseline = liveState(at: baselineRoot.appendingPathComponent(rel))
            let current = liveState(at: liveRoot.appendingPathComponent(rel))
            let idx = rows.firstIndex {
                $0.agentName == agentName && $0.root == root && $0.relativePath == rel
            }

            if baseline?.signature == current?.signature {
                // Net no-op vs the pre-chat baseline (e.g. created then
                // deleted, or reverted content) — drop any outstanding row.
                if let idx {
                    persistDelete(id: rows[idx].id)
                    rows.remove(at: idx)
                    didChange = true
                }
                continue
            }

            let kind: SandboxChangeKind =
                baseline == nil ? .created : (current == nil ? .deleted : .modified)
            let entryType = current?.type ?? baseline?.type ?? .file
            if let idx {
                var row = rows[idx]
                row.kind = kind
                row.entryType = entryType
                row.baselineSignature = baseline?.signature
                row.currentSignature = current?.signature
                row.state = .pending
                row.sourceTool = sourceTool
                row.lastChangedAt = Date()
                rows[idx] = row
                persistUpsert(row)
            } else {
                let row = SandboxWorkspaceChange(
                    sessionId: sessionId,
                    agentName: agentName,
                    root: root,
                    relativePath: rel,
                    entryType: entryType,
                    kind: kind,
                    baselineSignature: baseline?.signature,
                    currentSignature: current?.signature,
                    sourceTool: sourceTool
                )
                rows.append(row)
                persistUpsert(row)
            }
            didChange = true
        }
        cache[sessionId] = rows
        return didChange
    }

    // MARK: - Baseline snapshots

    private func hostRoot(agentName: String, root: SandboxWorkspaceRootKind) -> URL {
        hostRootProvider(agentName, root)
    }

    private func baselineDir(
        sessionId: String,
        agentName: String,
        root: SandboxWorkspaceRootKind
    ) -> URL {
        // `.hostFolder` carries an absolute path (with slashes) in the
        // agentName slot — flatten it into a filesystem-safe key so the
        // baseline lives one level deep like sandbox baselines do.
        let agentComponent = root == .hostFolder ? Self.hostFolderKey(agentName) : agentName
        return baselinesRoot
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent(agentComponent, isDirectory: true)
            .appendingPathComponent(root.rawValue, isDirectory: true)
    }

    /// Stable filesystem-safe identity for a host folder path.
    static func hostFolderKey(_ folderPath: String) -> String {
        let digest = SHA256.hash(data: Data(folderPath.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return "host-\(hex)"
    }

    /// Clone the live root into the session baseline on first use. Returns
    /// nil when no baseline could be captured (tracking is skipped rather
    /// than recording changes we could never restore).
    private func ensureBaseline(
        sessionId: String,
        agentName: String,
        root: SandboxWorkspaceRootKind
    ) -> URL? {
        let dest = baselineDir(sessionId: sessionId, agentName: agentName, root: root)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { return dest }

        let src = hostRoot(agentName: agentName, root: root)
        var isDir: ObjCBool = false
        do {
            try fm.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue {
                // FileManager.copyItem uses APFS clonefile when the volume
                // supports it, falling back to a real copy otherwise.
                try fm.copyItem(at: src, to: dest)
            } else {
                // Root not provisioned yet — the baseline is legitimately empty.
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            }
            return dest
        } catch {
            // Never keep a half-copied baseline: a partial snapshot would
            // "restore" files to a state that never existed.
            try? fm.removeItem(at: dest)
            Self.log.error(
                "baseline snapshot failed for \(agentName, privacy: .public)/\(root.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Remove the session's baseline clone once nothing is left to undo.
    private func gcBaselineIfDone(sessionId: String) {
        guard (cache[sessionId] ?? []).isEmpty,
            !pendingJobs.values.contains(where: { $0.sessionId == sessionId })
        else { return }
        try? FileManager.default.removeItem(
            at: baselinesRoot.appendingPathComponent(sessionId, isDirectory: true))
    }

    // MARK: - Scanning / diffing

    /// Cheap full-tree manifest of a workspace root. Returns nil when the
    /// tree is too large to track per-call.
    ///
    /// Uses the path-based enumerator: it yields root-relative paths
    /// directly (no `/var` vs `/private/var` prefix mismatches) and never
    /// traverses symlinks, so a link is recorded as itself.
    func scanManifest(root: URL) -> Manifest? {
        let fm = FileManager.default
        let rootPath = root.path
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else {
            return [:]
        }
        guard let enumerator = fm.enumerator(atPath: rootPath) else { return [:] }

        var manifest: Manifest = [:]
        while let rel = enumerator.nextObject() as? String {
            let attrs = enumerator.fileAttributes
            let type = attrs?[.type] as? FileAttributeType
            if Self.isExcluded(relativePath: rel) {
                if type == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            switch type {
            case .typeSymbolicLink:
                let target =
                    (try? fm.destinationOfSymbolicLink(atPath: rootPath + "/" + rel)) ?? ""
                manifest[rel] = ManifestEntry(type: .symlink, size: 0, mtimeNs: 0, linkTarget: target)
            case .typeDirectory:
                manifest[rel] = ManifestEntry(type: .directory, size: 0, mtimeNs: 0, linkTarget: nil)
            default:
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                manifest[rel] = ManifestEntry(
                    type: .file, size: size, mtimeNs: Int64(mtime * 1_000_000_000), linkTarget: nil)
            }
            if manifest.count > Self.maxTrackedEntries {
                Self.log.warning(
                    "skipping change tracking for \(rootPath, privacy: .public): more than \(Self.maxTrackedEntries) entries"
                )
                return nil
            }
        }
        return manifest
    }

    static func touchedPaths(pre: Manifest, post: Manifest) -> Set<String> {
        var touched: Set<String> = []
        for (path, entry) in post where pre[path] != entry { touched.insert(path) }
        for path in pre.keys where post[path] == nil { touched.insert(path) }
        return touched
    }

    static func isExcluded(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/")
        for component in components where excludedDirectoryNames.contains(String(component)) {
            return true
        }
        // Top-level background-job logs are runtime-owned, not user content.
        if components.count == 1, let name = components.first.map(String.init),
            name.hasPrefix("bg-"), name.hasSuffix(".log")
        {
            return true
        }
        return false
    }

    /// Type + content signature of a path (nil when it doesn't exist).
    /// Symlinks are inspected, never followed.
    private func liveState(at url: URL) -> (type: SandboxChangeEntryType, signature: String)? {
        let fm = FileManager.default
        // attributesOfItem does not traverse symlinks.
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
            let type = attrs[.type] as? FileAttributeType
        else { return nil }
        switch type {
        case .typeSymbolicLink:
            let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return (.symlink, "link:\(target)")
        case .typeDirectory:
            return (.directory, "dir")
        default:
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            if size > Self.maxHashBytes {
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                return (.file, "big:\(size):\(Int64(mtime * 1_000_000_000))")
            }
            guard let hash = Self.sha256(of: url) else {
                return (.file, "unreadable:\(size)")
            }
            return (.file, "sha256:\(hash)")
        }
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func depth(_ relativePath: String) -> Int {
        relativePath.reduce(into: 0) { if $1 == "/" { $0 += 1 } }
    }

    private static func jobKey(agentName: String, pid: String) -> String {
        "\(agentName)|\(pid)"
    }

    // MARK: - Persistence

    private func loadIfNeeded(_ sessionId: String) {
        guard !loadedSessions.contains(sessionId) else { return }
        // Only mark loaded once the DB could actually answer, so rows from a
        // previous run aren't permanently missed behind a deferred open.
        guard database.isOpen else { return }
        loadedSessions.insert(sessionId)
        let rows = database.loadSandboxChanges(sessionId: sessionId)
        var merged = cache[sessionId] ?? []
        let liveKeys = Set(merged.map { "\($0.agentName)|\($0.root.rawValue)|\($0.relativePath)" })
        for row in rows
        where !liveKeys.contains("\(row.agentName)|\(row.root.rawValue)|\(row.relativePath)") {
            merged.append(row)
        }
        cache[sessionId] = merged
    }

    private func persistUpsert(_ change: SandboxWorkspaceChange) {
        guard database.isOpen else {
            pendingRowDeletes.remove(change.id)
            pendingUpserts[change.id] = change
            return
        }
        flushPendingPersistence()
        do {
            try database.upsertSandboxChange(change)
        } catch {
            pendingUpserts[change.id] = change
        }
    }

    private func persistDelete(id: UUID) {
        pendingUpserts.removeValue(forKey: id)
        guard database.isOpen else {
            pendingRowDeletes.insert(id)
            return
        }
        flushPendingPersistence()
        do {
            try database.deleteSandboxChange(id: id)
        } catch {
            pendingRowDeletes.insert(id)
        }
    }

    private func flushPendingPersistence() {
        guard database.isOpen, !pendingUpserts.isEmpty || !pendingRowDeletes.isEmpty else { return }
        let upserts = pendingUpserts
        pendingUpserts.removeAll()
        for (_, change) in upserts {
            do { try database.upsertSandboxChange(change) } catch {
                pendingUpserts[change.id] = change
            }
        }
        let deletes = pendingRowDeletes
        pendingRowDeletes.removeAll()
        for id in deletes {
            do { try database.deleteSandboxChange(id: id) } catch {
                pendingRowDeletes.insert(id)
            }
        }
    }

    // MARK: - Pending-job persistence / recovery

    private var pendingJobsDir: URL {
        baselinesRoot.appendingPathComponent("pending-jobs", isDirectory: true)
    }

    private func pendingJobFile(_ record: PendingJobRecord) -> URL {
        // pid + agent name are filesystem-safe (numeric / sanitized linux name).
        pendingJobsDir.appendingPathComponent("\(record.agentName)-\(record.pid).json")
    }

    private func persistPendingJob(_ record: PendingJobRecord) {
        do {
            try FileManager.default.createDirectory(
                at: pendingJobsDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(record)
            try data.write(to: pendingJobFile(record), options: .atomic)
        } catch {
            Self.log.error(
                "failed to persist pending job record: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removePendingJobFile(_ record: PendingJobRecord) {
        try? FileManager.default.removeItem(at: pendingJobFile(record))
    }

    /// Finalize job records left over from a previous app run. The sandbox
    /// VM dies with the app, so any record on disk at launch belongs to a
    /// job that can no longer be running — diff and fold in its changes now.
    private func ensureRecovered() {
        guard !recovered else { return }
        recovered = true
        let fm = FileManager.default
        guard
            let files = try? fm.contentsOfDirectory(
                at: pendingJobsDir, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
                let record = try? JSONDecoder().decode(PendingJobRecord.self, from: data)
            {
                finalize(record)
            }
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Notification

    private func notify(sessionId: String) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .sandboxWorkspaceChangesDidChange,
                object: nil,
                userInfo: ["sessionId": sessionId]
            )
        }
    }
}
