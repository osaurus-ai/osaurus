//
//  FileChangeJournal.swift
//  osaurus
//
//  Durable, git-like file history per chat session. Every mutating tool
//  call is wrapped in a capture that yields one `FileChangeSet` with exact
//  before/after content for each touched path.
//
//  Two capture strategies:
//    - Precise: tools that name their targets (`file_write`, `file_edit`,
//      `file_copy`, `sandbox_write_file`, reverts, ...) snapshot exactly
//      those paths before the call. No tree scan, so any folder size works.
//    - Shadow: opaque tools (`shell_run`, `sandbox_exec`, background jobs)
//      diff a cheap manifest (type + size + mtime) before/after. Pre-images
//      come from a rolling shadow clone of the root that is re-synced to the
//      live tree at every capture start and advanced at every capture end,
//      so each set gets its own exact before bytes.
//
//  Crash safety: a capture's pre-state is persisted to `pending/` before the
//  tool body runs; captures left behind by a crash are finalized on the next
//  launch against whatever is on disk.
//
//  No silent gaps: when neither strategy can snapshot a root (tree over
//  budget, no parseable targets), `beginCapture` reports it so the caller
//  asks the user before running, and the set is recorded as `untracked`.
//

import CryptoKit
import Foundation
import os

public actor FileChangeJournal {
    public static let shared = FileChangeJournal()

    // MARK: - Types

    struct ManifestEntry: Codable, Equatable, Sendable {
        let type: SandboxChangeEntryType
        let size: Int64
        let mtimeNs: Int64
        let linkTarget: String?
    }

    typealias Manifest = [String: ManifestEntry]

    /// One root a capture observes.
    public struct RootTarget: Sendable, Codable, Hashable {
        public let kind: SandboxWorkspaceRootKind
        /// Sandbox agent name, or the host folder's absolute path.
        public let rootId: String
        /// Root-relative paths the tool will mutate; nil = opaque (shadow).
        public let declaredPaths: [String]?
        /// Precise targets to use when a shadow can't be kept for this root.
        public let fallbackPaths: [String]?

        public init(
            kind: SandboxWorkspaceRootKind,
            rootId: String,
            declaredPaths: [String]? = nil,
            fallbackPaths: [String]? = nil
        ) {
            self.kind = kind
            self.rootId = rootId
            self.declaredPaths = declaredPaths
            self.fallbackPaths = fallbackPaths
        }
    }

    struct PreState: Codable, Sendable {
        let state: FilePathState?
    }

    enum RootMode: String, Codable, Sendable {
        case precise
        case shadow
        case untracked
    }

    struct RootCapture: Codable, Sendable {
        let kind: SandboxWorkspaceRootKind
        let rootId: String
        var mode: RootMode
        /// Precise: declared top-level targets (directories expand).
        var declared: [String]
        /// Precise: root-relative path → pre-state (includes subtrees and
        /// missing ancestors of declared paths).
        var pre: [String: PreState]
        /// Shadow: live manifest at capture start.
        var preManifest: Manifest?
        var untrackedReason: String?
    }

    struct CaptureRecord: Codable, Sendable {
        let id: UUID
        let sessionId: String
        let toolName: String
        let toolCallId: String?
        let turnId: UUID?
        let origin: FileChangeOrigin
        let revertsSetId: UUID?
        let note: String?
        let createdAt: Date
        var roots: [RootCapture]
        /// Background job key (`agent|pid`) when this capture tracks a job.
        var jobKey: String?
    }

    /// Opaque handle returned by `beginCapture`.
    public struct CaptureToken: Sendable {
        public let setId: UUID
        /// Human-readable reasons for roots that could not be snapshotted.
        public let untrackedReasons: [String]
        public var isFullyTracked: Bool { untrackedReasons.isEmpty }
    }

    // MARK: - Limits

    /// Directory names never tracked by shadow scans: dependency/build
    /// caches whose churn would flood the history, VCS internals, and the
    /// runtime's own scratch dirs.
    static let excludedDirectoryNames: Set<String> = [
        ".venv", "node_modules", "__pycache__", ".cache", ".npm", ".git", ".tmp",
    ]
    /// Roots with more entries than this can't keep a shadow.
    static let maxShadowEntries = 50_000
    /// Byte budget for a shadow on a volume that can't APFS-clone into the
    /// store (a physical copy of a huge tree would stall every tool call).
    static let maxCopiedShadowBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// Directory targets of a precise capture expand to at most this many
    /// entries; beyond it the root falls back to a shadow scan.
    static let maxPreciseEntries = 5_000

    // MARK: - State

    let database: ChatHistoryDatabase
    let storeRoot: URL
    public nonisolated let objects: FileObjectStore
    private let hostRootProvider: @Sendable (String, SandboxWorkspaceRootKind) -> URL
    let ownershipRepairEnabled: Bool
    /// Entry cap for a shadow-tracked root (lowered in tests).
    let shadowEntryLimit: Int
    private let legacyBaselinesRoot: URL?

    /// sessionId → sets (oldest first). The DB is the durable mirror.
    var cache: [String: [FileChangeSet]] = [:]
    var loadedSessions: Set<String> = []
    /// Writes deferred while the chat-history DB is closed.
    var pendingUpserts: [UUID: FileChangeSet] = [:]
    var pendingDeletes: Set<UUID> = []
    private var active: [UUID: CaptureRecord] = [:]
    private var jobCaptures: [String: UUID] = [:]
    private var shadowManifests: [String: Manifest] = [:]
    /// Shadow key → captures currently relying on that shadow's bytes. The
    /// tree is only re-synced to the live root when this drops to zero, so
    /// an overlapping capture (background job, parallel tool call, second
    /// chat on the same folder) can't overwrite another's pre-images.
    private var shadowUsers: [String: Int] = [:]
    /// Session → paths whose earliest sets were trimmed by retention, so a
    /// file-scope revert no longer reaches "before this chat". Loaded from
    /// `truncated.json` on first use.
    var truncatedPathsCache: [String: Set<FilePathKey>]?
    /// Shadows idle longer than this are dropped even when their root still
    /// has history (they hold full copies of the root, `.env` included).
    static let maxShadowIdleDays = 14
    /// Shadow key → path → outcome another capture recorded while this
    /// shadow was shared. A long-lived opaque capture (background job)
    /// would otherwise re-attribute those writes to itself and undo them
    /// on revert. Cleared when the shadow stops being shared.
    private var settledWhileShared: [String: [String: (at: Date, after: String?)]] = [:]
    private var recovered = false
    private var legacyImported = false

    static let log = Logger(subsystem: "ai.osaurus", category: "file-history")

    // MARK: - Init

    public init() {
        self.database = ChatHistoryDatabase.shared
        self.storeRoot = OsaurusPaths.root().appendingPathComponent("file-history", isDirectory: true)
        self.objects = FileObjectStore(root: storeRoot)
        self.hostRootProvider = { rootId, kind in kind.hostURL(agentName: rootId) }
        self.ownershipRepairEnabled = true
        self.shadowEntryLimit = Self.maxShadowEntries
        self.legacyBaselinesRoot = OsaurusPaths.root().appendingPathComponent(
            "sandbox-baselines", isDirectory: true)
    }

    /// Test entry point: isolated DB, store, and workspace roots.
    init(
        database: ChatHistoryDatabase,
        storeRoot: URL,
        hostRootProvider: @escaping @Sendable (String, SandboxWorkspaceRootKind) -> URL,
        legacyBaselinesRoot: URL? = nil,
        ownershipRepairEnabled: Bool = false,
        shadowEntryLimit: Int = FileChangeJournal.maxShadowEntries
    ) {
        self.database = database
        self.storeRoot = storeRoot
        self.objects = FileObjectStore(root: storeRoot)
        self.hostRootProvider = hostRootProvider
        self.legacyBaselinesRoot = legacyBaselinesRoot
        self.ownershipRepairEnabled = ownershipRepairEnabled
        self.shadowEntryLimit = shadowEntryLimit
    }

    func hostRoot(_ kind: SandboxWorkspaceRootKind, _ rootId: String) -> URL {
        hostRootProvider(rootId, kind)
    }

    func url(for key: FilePathKey) -> URL {
        hostRoot(key.rootKind, key.rootId).appendingPathComponent(key.path)
    }

    // MARK: - Capture

    /// Snapshot every target root before a mutating call runs.
    public func beginCapture(
        sessionId: String,
        toolName: String,
        toolCallId: String? = nil,
        turnId: UUID? = nil,
        origin: FileChangeOrigin = .agent,
        revertsSetId: UUID? = nil,
        note: String? = nil,
        targets: [RootTarget]
    ) -> CaptureToken {
        ensureRecovered()
        var roots: [RootCapture] = []
        var reasons: [String] = []
        for target in Self.dedupe(targets) {
            let capture = prepareRoot(target)
            if capture.mode == .untracked, let reason = capture.untrackedReason {
                reasons.append(reason)
            }
            roots.append(capture)
        }
        let record = CaptureRecord(
            id: UUID(),
            sessionId: sessionId,
            toolName: toolName,
            toolCallId: toolCallId,
            turnId: turnId,
            origin: origin,
            revertsSetId: revertsSetId,
            note: note,
            createdAt: Date(),
            roots: roots,
            jobKey: nil
        )
        active[record.id] = record
        persistPending(record)
        // The panel pauses reverts while an agent capture is in flight.
        if origin != .userRevert { notify(sessionId) }
        return CaptureToken(setId: record.id, untrackedReasons: reasons)
    }

    /// Drop a capture without recording anything (the call never ran).
    public func abandonCapture(_ token: CaptureToken) {
        guard let record = active.removeValue(forKey: token.setId) else { return }
        for root in record.roots where root.mode == .shadow {
            releaseShadow(kind: root.kind, rootId: root.rootId, post: nil)
        }
        removePending(record)
    }

    /// Diff every captured root after the call and record the set. Returns
    /// nil when the call changed nothing observable.
    @discardableResult
    public func endCapture(_ token: CaptureToken) async -> FileChangeSet? {
        guard let record = active.removeValue(forKey: token.setId) else { return nil }
        let set = finalize(record)
        // Record first, then drop the write-ahead file: a crash in between
        // leaves a pending record that recovery finalizes again, which is
        // harmless because `recordSet` upserts by id. The other order would
        // lose the set (and let GC take its blobs).
        if let set { recordSet(set) }
        // While the DB is closed the set exists only in memory; keep the
        // write-ahead file until `flushPending` lands it.
        if set == nil || pendingUpserts[record.id] == nil { removePending(record) }
        if let set, set.origin == .userRevert { await repairOwnership(for: set.entries) }
        // A no-op call still ends the "running" state the panel shows.
        if set == nil { notify(record.sessionId) }
        return set
    }

    private static func dedupe(_ targets: [RootTarget]) -> [RootTarget] {
        var merged: [String: RootTarget] = [:]
        var order: [String] = []
        for t in targets {
            let key = t.kind.rawValue + "|" + t.rootId
            if let existing = merged[key] {
                // Opaque wins over precise: one shadow covers everything.
                let declared: [String]? =
                    (existing.declaredPaths == nil || t.declaredPaths == nil)
                    ? nil : (existing.declaredPaths ?? []) + (t.declaredPaths ?? [])
                merged[key] = RootTarget(
                    kind: t.kind, rootId: t.rootId, declaredPaths: declared,
                    fallbackPaths: existing.fallbackPaths ?? t.fallbackPaths)
            } else {
                merged[key] = t
                order.append(key)
            }
        }
        return order.compactMap { merged[$0] }
    }

    private func prepareRoot(_ target: RootTarget) -> RootCapture {
        var capture = RootCapture(
            kind: target.kind, rootId: target.rootId, mode: .precise, declared: [], pre: [:],
            preManifest: nil, untrackedReason: nil)
        if let declared = target.declaredPaths,
            let pre = preciseSnapshot(kind: target.kind, rootId: target.rootId, paths: declared)
        {
            capture.declared = declared
            capture.pre = pre
            return capture
        }
        if let manifest = prepareShadow(kind: target.kind, rootId: target.rootId) {
            capture.mode = .shadow
            capture.preManifest = manifest
            let key = shadowKey(target.kind, target.rootId)
            shadowUsers[key, default: 0] += 1
            return capture
        }
        if let fallback = target.fallbackPaths,
            let pre = preciseSnapshot(kind: target.kind, rootId: target.rootId, paths: fallback)
        {
            capture.declared = fallback
            capture.pre = pre
            return capture
        }
        capture.mode = .untracked
        capture.untrackedReason =
            "\(target.kind.containerPrefix(agentName: target.rootId)) is too large to snapshot"
        return capture
    }

    // MARK: Precise snapshots

    /// Pre-state for declared paths: each path, its subtree when it is a
    /// directory, and every missing ancestor (so created parents are
    /// recorded and removed on revert). Nil when a subtree is too large.
    private func preciseSnapshot(
        kind: SandboxWorkspaceRootKind, rootId: String, paths: [String]
    ) -> [String: PreState]? {
        let root = hostRoot(kind, rootId)
        var pre: [String: PreState] = [:]
        var budget = Self.maxPreciseEntries
        for raw in paths {
            let rel = Self.normalize(raw)
            guard !rel.isEmpty else { return nil }
            // Missing ancestors.
            var ancestor = (rel as NSString).deletingLastPathComponent
            while !ancestor.isEmpty, ancestor != "/", ancestor != "." {
                if pre[ancestor] == nil {
                    let url = root.appendingPathComponent(ancestor)
                    if FileManager.default.fileExists(atPath: url.path) { break }
                    pre[ancestor] = PreState(state: nil)
                }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            guard
                let expanded = expandSubtree(root: root, rel: rel, budget: &budget)
            else { return nil }
            for path in expanded where pre[path] == nil {
                pre[path] = PreState(state: objects.captureState(at: root.appendingPathComponent(path)))
            }
            if pre[rel] == nil { pre[rel] = PreState(state: nil) }
        }
        return pre
    }

    /// `rel` plus every descendant when it is a real directory (never
    /// following links). Nil when the budget is exhausted.
    private func expandSubtree(root: URL, rel: String, budget: inout Int) -> [String]? {
        let fm = FileManager.default
        let url = root.appendingPathComponent(rel)
        var result = [rel]
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
            (attrs[.type] as? FileAttributeType) == .typeDirectory
        else { return result }
        guard let enumerator = fm.enumerator(atPath: url.path) else { return result }
        while let child = enumerator.nextObject() as? String {
            budget -= 1
            if budget < 0 { return nil }
            result.append(rel + "/" + child)
        }
        return result
    }

    /// Root-relative form of a declared path; empty when it could escape
    /// the root (callers treat that as "can't capture precisely").
    static func normalize(_ path: String) -> String {
        var p = path
        while p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        if p.split(separator: "/").contains("..") { return "" }
        return p
    }

    // MARK: Finalize

    private func finalize(_ record: CaptureRecord) -> FileChangeSet? {
        var entries: [FileChangeEntry] = []
        var untracked: [String] = []
        for capture in record.roots {
            switch capture.mode {
            case .precise:
                entries += preciseEntries(capture, record: record, ordinalBase: entries.count)
            case .shadow:
                entries += shadowEntries(capture, record: record, ordinalBase: entries.count)
            case .untracked:
                if let reason = capture.untrackedReason { untracked.append(reason) }
            }
        }
        guard !entries.isEmpty || !untracked.isEmpty else { return nil }
        Self.detectRenames(&entries)
        var note = record.note
        var status: FileChangeSetStatus = .applied
        if !untracked.isEmpty {
            status = entries.isEmpty ? .untracked : .applied
            let line = "Not tracked: " + untracked.joined(separator: "; ")
            note = note.map { $0 + " · " + line } ?? line
        }
        return FileChangeSet(
            id: record.id,
            sessionId: record.sessionId,
            toolName: record.toolName,
            toolCallId: record.toolCallId,
            turnId: record.turnId,
            origin: record.origin,
            status: status,
            revertsSetId: record.revertsSetId,
            note: note,
            createdAt: record.createdAt,
            entries: entries
        )
    }

    private func preciseEntries(
        _ capture: RootCapture, record: CaptureRecord, ordinalBase: Int
    ) -> [FileChangeEntry] {
        let root = hostRoot(capture.kind, capture.rootId)
        var paths = Set(capture.pre.keys)
        // Declared directories may have gained descendants.
        var budget = Self.maxPreciseEntries * 4
        for rel in capture.declared.map(Self.normalize) {
            if let expanded = expandSubtree(root: root, rel: rel, budget: &budget) {
                paths.formUnion(expanded)
            }
        }
        var entries: [FileChangeEntry] = []
        for rel in paths.sorted() {
            let before = capture.pre[rel]?.state ?? nil
            let url = root.appendingPathComponent(rel)
            let live = objects.liveSignature(at: url)
            if Self.sameContent(before, live) { continue }
            let after = live == nil ? nil : objects.captureState(at: url)
            guard let entry = makeEntry(
                record: record, kind: capture.kind, rootId: capture.rootId, path: rel,
                before: before, after: after, ordinal: ordinalBase + entries.count)
            else { continue }
            entries.append(entry)
        }
        noteSettled(entries, kind: capture.kind, rootId: capture.rootId)
        return entries
    }

    /// Remember outcomes recorded while this root's shadow is shared with
    /// another (still running) capture, so that capture doesn't claim them.
    private func noteSettled(_ entries: [FileChangeEntry], kind: SandboxWorkspaceRootKind, rootId: String) {
        let key = shadowKey(kind, rootId)
        guard (shadowUsers[key] ?? 0) > 0, !entries.isEmpty else { return }
        let now = Date()
        for entry in entries {
            settledWhileShared[key, default: [:]][entry.path] = (now, entry.after?.signature)
        }
    }

    /// True when another capture already recorded `live` as the outcome for
    /// `rel` after this capture began: the write belongs to that set.
    private func settledByAnotherCapture(
        key: String, rel: String, live: FilePathState?, since: Date
    ) -> Bool {
        guard let settled = settledWhileShared[key]?[rel], settled.at > since else { return false }
        return settled.after == live?.signature
    }

    private func shadowEntries(
        _ capture: RootCapture, record: CaptureRecord, ordinalBase: Int
    ) -> [FileChangeEntry] {
        guard let pre = capture.preManifest else { return [] }
        let root = hostRoot(capture.kind, capture.rootId)
        let post = scanManifest(root: root)
        defer { releaseShadow(kind: capture.kind, rootId: capture.rootId, post: post) }
        guard let post else {
            Self.log.warning("post-scan exceeded budget for \(capture.kind.rawValue, privacy: .public)")
            return []
        }
        let touched = Self.touchedPaths(pre: pre, post: post)
        guard !touched.isEmpty else { return [] }
        let shadow = shadowTree(capture.kind, capture.rootId)
        let key = shadowKey(capture.kind, capture.rootId)
        var entries: [FileChangeEntry] = []
        for rel in touched.sorted() {
            let before = objects.captureState(at: shadow.appendingPathComponent(rel))
            let liveURL = root.appendingPathComponent(rel)
            let live = objects.liveSignature(at: liveURL)
            if settledByAnotherCapture(key: key, rel: rel, live: live, since: record.createdAt) { continue }
            if !Self.sameContent(before, live) {
                let after = live == nil ? nil : objects.captureState(at: liveURL)
                if let entry = makeEntry(
                    record: record, kind: capture.kind, rootId: capture.rootId, path: rel,
                    before: before, after: after, ordinal: ordinalBase + entries.count)
                {
                    entries.append(entry)
                }
            }
        }
        noteSettled(entries, kind: capture.kind, rootId: capture.rootId)
        return entries
    }

    /// One capture stopped using this root's shadow. When it was the last,
    /// bring the tree and its manifest in line with the live root (`post`,
    /// or a fresh scan) so the next capture starts from exact bytes.
    private func releaseShadow(kind: SandboxWorkspaceRootKind, rootId: String, post: Manifest?) {
        let key = shadowKey(kind, rootId)
        let remaining = max(0, (shadowUsers[key] ?? 0) - 1)
        shadowUsers[key] = remaining
        guard remaining == 0 else { return }
        settledWhileShared[key] = nil
        guard let live = post ?? scanManifest(root: hostRoot(kind, rootId)) else { return }
        let stored = shadowManifests[key] ?? loadShadowManifest(kind: kind, rootId: rootId) ?? [:]
        let drift = Self.touchedPaths(pre: stored, post: live)
        if !drift.isEmpty { syncShadow(kind: kind, rootId: rootId, paths: drift) }
        storeShadowManifest(live, kind: kind, rootId: rootId)
    }

    private func makeEntry(
        record: CaptureRecord,
        kind: SandboxWorkspaceRootKind,
        rootId: String,
        path: String,
        before: FilePathState?,
        after: FilePathState?,
        ordinal: Int
    ) -> FileChangeEntry? {
        // Directory mtime churn is not a change.
        if before?.type == .directory, after?.type == .directory { return nil }
        let entryKind: FileChangeEntryKind =
            before == nil ? .created : (after == nil ? .deleted : .modified)
        return FileChangeEntry(
            setId: record.id,
            sessionId: record.sessionId,
            rootKind: kind,
            rootId: rootId,
            path: path,
            kind: entryKind,
            before: before,
            after: after,
            ordinal: ordinal
        )
    }

    static func sameContent(_ a: FilePathState?, _ b: FilePathState?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.type == b.type && a.signature == b.signature && (a.mode ?? 0) == (b.mode ?? 0)
    }

    /// Mark a create carrying exactly the bytes a delete in the same set
    /// removed as a rename (display only; revert still handles both rows).
    static func detectRenames(_ entries: inout [FileChangeEntry]) {
        var deletedBySig: [String: String] = [:]
        for e in entries where e.kind == .deleted {
            if let sig = e.before?.signature, e.before?.type == .file { deletedBySig[sig] = e.path }
        }
        guard !deletedBySig.isEmpty else { return }
        for i in entries.indices where entries[i].kind == .created {
            if let sig = entries[i].after?.signature, let from = deletedBySig[sig] {
                entries[i].fromPath = from
            }
        }
    }

    // MARK: - Background jobs

    /// Start tracking a background job whose writes land after its
    /// launching call returned. Finalized on job exit or next launch.
    public func beginBackgroundJob(
        sessionId: String, agentName: String, pid: String, toolName: String
    ) {
        let token = beginCapture(
            sessionId: sessionId,
            toolName: toolName,
            origin: .externalJob,
            targets: SandboxWorkspaceRootKind.sandboxRoots.map {
                RootTarget(kind: $0, rootId: agentName)
            }
        )
        let key = Self.jobKey(agentName: agentName, pid: pid)
        jobCaptures[key] = token.setId
        active[token.setId]?.jobKey = key
        if let record = active[token.setId] { persistPending(record) }
        notify(sessionId)
    }

    public func finalizeBackgroundJob(agentName: String, pid: String) async {
        ensureRecovered()
        let key = Self.jobKey(agentName: agentName, pid: pid)
        guard let id = jobCaptures.removeValue(forKey: key), let record = active[id] else { return }
        _ = await endCapture(CaptureToken(setId: id, untrackedReasons: []))
        notify(record.sessionId)
    }

    /// Any capture (foreground tool call or background job) in flight for
    /// this chat.
    public func hasActiveCaptures(sessionId: String) -> Bool {
        ensureRecovered()
        return active.values.contains { $0.sessionId == sessionId }
    }

    /// Forget in-flight captures of a purged chat without recording them.
    /// Shadows they held are released (and re-synced) as usual.
    func dropActiveCaptures(sessionId: String) {
        for (id, record) in active where record.sessionId == sessionId {
            active[id] = nil
            if let key = record.jobKey { jobCaptures[key] = nil }
            for root in record.roots where root.mode == .shadow {
                releaseShadow(kind: root.kind, rootId: root.rootId, post: nil)
            }
            removePending(record)
        }
    }

    public func hasActiveBackgroundJobs(sessionId: String) -> Bool {
        ensureRecovered()
        return active.values.contains { $0.sessionId == sessionId && $0.jobKey != nil }
    }

    private static func jobKey(agentName: String, pid: String) -> String { "\(agentName)|\(pid)" }

    // MARK: - Shadow trees

    /// Bytes held by shadow clones (logical size; APFS clones share blocks
    /// with the live root until either side changes).
    func shadowBytes() -> Int64 {
        let base = storeRoot.appendingPathComponent("shadows", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(atPath: base.path) else { return 0 }
        var total: Int64 = 0
        while enumerator.nextObject() != nil {
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular,
                let size = enumerator.fileAttributes?[.size] as? NSNumber
            {
                total += size.int64Value
            }
        }
        return total
    }

    /// Drop shadow clones that no capture is using and that either belong
    /// to a root with no remaining history or have sat idle for
    /// `maxShadowIdleDays`. A pruned shadow is simply re-cloned on the
    /// root's next opaque capture.
    func pruneShadows(now: Date = Date()) {
        let fm = FileManager.default
        let base = storeRoot.appendingPathComponent("shadows", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { return }
        var inUse: Set<String> = []
        for record in active.values {
            for root in record.roots { inUse.insert(shadowKey(root.kind, root.rootId)) }
        }
        for (key, users) in shadowUsers where users > 0 { inUse.insert(key) }
        var referenced: Set<String> = []
        if database.isOpen {
            do {
                for root in try database.fileChangeReferencedRoots() {
                    referenced.insert(shadowKey(root.kind, root.rootId))
                }
            } catch {
                Self.log.error("shadow prune skipped: root query failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        } else {
            return
        }
        for set in pendingUpserts.values {
            for entry in set.entries { referenced.insert(shadowKey(entry.pathKey.rootKind, entry.pathKey.rootId)) }
        }
        let idleCutoff = now.addingTimeInterval(-Double(Self.maxShadowIdleDays) * 86_400)
        for name in names where !inUse.contains(name) {
            let dir = base.appendingPathComponent(name, isDirectory: true)
            let manifest = dir.appendingPathComponent("manifest.json")
            let lastUsed = (try? fm.attributesOfItem(atPath: manifest.path))?[.modificationDate] as? Date
            let idle = lastUsed.map { $0 < idleCutoff } ?? true
            guard !referenced.contains(name) || idle else { continue }
            try? fm.removeItem(at: dir)
            shadowManifests[name] = nil
        }
    }

    func shadowKey(_ kind: SandboxWorkspaceRootKind, _ rootId: String) -> String {
        let digest = SHA256.hash(data: Data(rootId.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return "\(kind.rawValue)-\(hex)"
    }

    private func shadowBase(_ kind: SandboxWorkspaceRootKind, _ rootId: String) -> URL {
        storeRoot.appendingPathComponent("shadows", isDirectory: true)
            .appendingPathComponent(shadowKey(kind, rootId), isDirectory: true)
    }

    private func shadowTree(_ kind: SandboxWorkspaceRootKind, _ rootId: String) -> URL {
        shadowBase(kind, rootId).appendingPathComponent("tree", isDirectory: true)
    }

    private func shadowManifestURL(_ kind: SandboxWorkspaceRootKind, _ rootId: String) -> URL {
        shadowBase(kind, rootId).appendingPathComponent("manifest.json")
    }

    /// Bring the shadow in line with the live root and return the live
    /// manifest (the capture's pre-state). Nil when over budget.
    private func prepareShadow(kind: SandboxWorkspaceRootKind, rootId: String) -> Manifest? {
        let live = hostRoot(kind, rootId)
        guard let manifest = scanManifest(root: live) else { return nil }
        let bytes = manifest.values.reduce(Int64(0)) { $0 + $1.size }
        if bytes > Self.maxCopiedShadowBytes,
            !FileObjectStore.canClone(from: live, to: storeRoot)
        {
            Self.log.warning(
                "no shadow for \(kind.rawValue, privacy: .public): \(bytes) bytes on a non-clone volume")
            return nil
        }
        let key = shadowKey(kind, rootId)
        let tree = shadowTree(kind, rootId)
        let fm = FileManager.default
        let last = shadowManifests[key] ?? loadShadowManifest(kind: kind, rootId: rootId)
        if let last, fm.fileExists(atPath: tree.path) {
            if (shadowUsers[key] ?? 0) > 0 {
                // Another capture is reading this shadow's bytes: leave the
                // tree (and its manifest) alone. Files this capture touches
                // that nobody else changed still have exact pre-images; the
                // tree catches up when the last capture ends.
                return manifest
            }
            let drift = Self.touchedPaths(pre: last, post: manifest)
            if !drift.isEmpty { syncShadow(kind: kind, rootId: rootId, paths: drift) }
        } else {
            do {
                try? fm.removeItem(at: tree)
                try fm.createDirectory(
                    at: tree.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try Self.cloneTree(from: live, to: tree)
            } catch {
                try? fm.removeItem(at: tree)
                Self.log.error("shadow clone failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        storeShadowManifest(manifest, kind: kind, rootId: rootId)
        return manifest
    }

    /// Make the shadow match the live root for `paths`. Parents first for
    /// creation; a removed directory takes its (also-touched) children.
    private func syncShadow(kind: SandboxWorkspaceRootKind, rootId: String, paths: Set<String>) {
        let fm = FileManager.default
        let live = hostRoot(kind, rootId)
        let tree = shadowTree(kind, rootId)
        for rel in paths.sorted(by: { Self.depth($0) < Self.depth($1) }) {
            let src = live.appendingPathComponent(rel)
            let dst = tree.appendingPathComponent(rel)
            let srcType = (try? fm.attributesOfItem(atPath: src.path))?[.type] as? FileAttributeType
            let dstType = (try? fm.attributesOfItem(atPath: dst.path))?[.type] as? FileAttributeType
            if srcType == .typeDirectory {
                if dstType != nil, dstType != .typeDirectory { try? fm.removeItem(at: dst) }
                try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
                continue
            }
            if dstType != nil { try? fm.removeItem(at: dst) }
            guard srcType != nil else { continue }
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try FileObjectStore.cloneOrCopy(from: src, to: dst)
            } catch {
                Self.log.error("shadow sync failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func storeShadowManifest(_ manifest: Manifest, kind: SandboxWorkspaceRootKind, rootId: String) {
        shadowManifests[shadowKey(kind, rootId)] = manifest
        let url = shadowManifestURL(kind, rootId)
        if let data = try? JSONEncoder().encode(manifest) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadShadowManifest(kind: SandboxWorkspaceRootKind, rootId: String) -> Manifest? {
        guard let data = try? Data(contentsOf: shadowManifestURL(kind, rootId)),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        shadowManifests[shadowKey(kind, rootId)] = manifest
        return manifest
    }

    static func cloneTree(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue,
            let enumerator = fm.enumerator(atPath: src.path)
        else { return }
        while let rel = enumerator.nextObject() as? String {
            let type = enumerator.fileAttributes?[.type] as? FileAttributeType
            if isExcluded(relativePath: rel) {
                if type == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            let target = dest.appendingPathComponent(rel)
            if type == .typeDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try FileObjectStore.cloneOrCopy(from: src.appendingPathComponent(rel), to: target)
            }
        }
    }

    /// Cheap full-tree manifest. Nil when the tree exceeds the entry cap.
    func scanManifest(root: URL) -> Manifest? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
            let enumerator = fm.enumerator(atPath: root.path)
        else { return [:] }
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
                let target = (try? fm.destinationOfSymbolicLink(atPath: root.path + "/" + rel)) ?? ""
                manifest[rel] = ManifestEntry(type: .symlink, size: 0, mtimeNs: 0, linkTarget: target)
            case .typeDirectory:
                manifest[rel] = ManifestEntry(type: .directory, size: 0, mtimeNs: 0, linkTarget: nil)
            default:
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let mode = (attrs?[.posixPermissions] as? NSNumber)?.int64Value ?? 0
                // Mode is folded into the mtime field so a chmod registers.
                manifest[rel] = ManifestEntry(
                    type: .file, size: size, mtimeNs: Int64(mtime * 1_000_000_000) &+ mode,
                    linkTarget: nil)
            }
            if manifest.count > shadowEntryLimit { return nil }
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

    static func depth(_ path: String) -> Int {
        path.reduce(into: 0) { if $1 == "/" { $0 += 1 } }
    }

    // MARK: - Pending persistence / recovery

    private var pendingDir: URL { storeRoot.appendingPathComponent("pending", isDirectory: true) }

    private func persistPending(_ record: CaptureRecord) {
        do {
            try FileManager.default.createDirectory(
                at: pendingDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(record)
            try data.write(to: pendingDir.appendingPathComponent("\(record.id.uuidString).json"), options: .atomic)
        } catch {
            Self.log.error("pending persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removePending(_ record: CaptureRecord) {
        removePending(id: record.id)
    }

    func removePending(id: UUID) {
        try? FileManager.default.removeItem(
            at: pendingDir.appendingPathComponent("\(id.uuidString).json"))
    }

    /// Captures on disk at first use belong to a previous run that died
    /// mid-call (or a job whose VM died with the app): diff them now.
    func ensureRecovered() {
        importLegacyIfNeeded()
        guard !recovered else { return }
        recovered = true
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
                let record = try? JSONDecoder().decode(CaptureRecord.self, from: data),
                active[record.id] == nil
            {
                // Already durable (crash between persist and unlink): the
                // recorded set is exact; re-diffing now could fold in edits
                // made since. Just drop the write-ahead file.
                let alreadyRecorded =
                    database.isOpen && database.fileChangeSessionId(forSetId: record.id.uuidString) != nil
                if !alreadyRecorded, let set = finalize(record) { recordSet(set) }
            }
            try? fm.removeItem(at: file)
        }
    }

    func activeSessionIds() -> [String] { active.values.map(\.sessionId) }

    /// Pre-state signatures of in-flight captures (GC roots).
    func activeSignatures() -> Set<String> {
        var sigs: Set<String> = []
        for record in active.values {
            for root in record.roots {
                for pre in root.pre.values { if let s = pre.state?.signature { sigs.insert(s) } }
            }
        }
        return sigs
    }

    // MARK: - Legacy import

    /// Carry `sandbox_changes` rows (net change vs a session-start
    /// baseline clone) into one "imported" set per session so everything
    /// that was undoable before the upgrade stays undoable.
    private func importLegacyIfNeeded() {
        guard !legacyImported, database.isOpen else { return }
        legacyImported = true
        let sessions = database.sandboxChangeSessionIds()
        for sessionId in sessions {
            let rows = database.loadSandboxChanges(sessionId: sessionId)
            guard !rows.isEmpty else { continue }
            let setId = UUID()
            var entries: [FileChangeEntry] = []
            for row in rows {
                var before: FilePathState?
                if row.kind != .created, let baseline = legacyBaselineURL(row) {
                    before = objects.captureState(at: baseline)
                    if before == nil, let sig = row.baselineSignature {
                        before = FilePathState(type: row.entryType, signature: sig)
                    }
                    // The old tracker said this file existed before; without
                    // its bytes we keep a non-restorable placeholder rather
                    // than calling it "created" (which a revert would delete).
                    if before == nil {
                        before = FilePathState(type: row.entryType, signature: "unknown")
                    }
                }
                var after: FilePathState?
                if row.kind != .deleted {
                    let liveURL = hostRoot(row.root, row.agentName).appendingPathComponent(row.relativePath)
                    if let live = objects.liveSignature(at: liveURL),
                        live.signature == row.currentSignature
                    {
                        after = objects.captureState(at: liveURL)
                    } else if let sig = row.currentSignature {
                        after = FilePathState(type: row.entryType, signature: sig)
                    }
                }
                let kind: FileChangeEntryKind =
                    before == nil ? .created : (after == nil ? .deleted : .modified)
                entries.append(
                    FileChangeEntry(
                        setId: setId, sessionId: sessionId, rootKind: row.root, rootId: row.agentName,
                        path: row.relativePath, kind: kind, before: before, after: after,
                        ordinal: entries.count))
            }
            let createdAt = rows.map(\.firstChangedAt).min() ?? Date()
            let set = FileChangeSet(
                id: setId, sessionId: sessionId, toolName: "earlier_changes", origin: .imported,
                note: "Changes recorded before file history was upgraded", createdAt: createdAt,
                entries: entries)
            do {
                try database.upsertFileChangeSet(set)
                try database.deleteSandboxChanges(sessionId: sessionId)
                if let legacyBaselinesRoot {
                    try? FileManager.default.removeItem(
                        at: legacyBaselinesRoot.appendingPathComponent(sessionId, isDirectory: true))
                }
            } catch {
                Self.log.error("legacy import failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let legacyBaselinesRoot {
            try? FileManager.default.removeItem(
                at: legacyBaselinesRoot.appendingPathComponent("pending-jobs", isDirectory: true))
        }
    }

    private func legacyBaselineURL(_ row: SandboxWorkspaceChange) -> URL? {
        guard let legacyBaselinesRoot else { return nil }
        let component: String
        if row.root == .hostFolder {
            let digest = SHA256.hash(data: Data(row.agentName.utf8))
            component = "host-" + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        } else {
            component = row.agentName
        }
        return legacyBaselinesRoot
            .appendingPathComponent(row.sessionId, isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
            .appendingPathComponent(row.root.rawValue, isDirectory: true)
            .appendingPathComponent(row.relativePath)
    }

    // MARK: - Persistence

    func loadIfNeeded(_ sessionId: String) {
        guard !loadedSessions.contains(sessionId), database.isOpen else { return }
        loadedSessions.insert(sessionId)
        let rows = database.loadFileChangeSets(sessionId: sessionId)
        let known = Set((cache[sessionId] ?? []).map(\.id))
        cache[sessionId] = (rows.filter { !known.contains($0.id) } + (cache[sessionId] ?? []))
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Add a new set to the cache + DB and notify.
    private func recordSet(_ set: FileChangeSet) {
        loadIfNeeded(set.sessionId)
        cache[set.sessionId, default: []].append(set)
        persist(set)
        notify(set.sessionId)
    }

    func persist(_ set: FileChangeSet) {
        guard database.isOpen else {
            pendingUpserts[set.id] = set
            return
        }
        flushPending()
        do { try database.upsertFileChangeSet(set) } catch { pendingUpserts[set.id] = set }
    }

    func flushPending() {
        guard database.isOpen, !pendingUpserts.isEmpty || !pendingDeletes.isEmpty else { return }
        let upserts = pendingUpserts
        pendingUpserts.removeAll()
        for (_, set) in upserts {
            do {
                try database.upsertFileChangeSet(set)
                removePending(id: set.id)
            } catch {
                pendingUpserts[set.id] = set
            }
        }
        let deletes = Array(pendingDeletes)
        pendingDeletes.removeAll()
        do { try database.deleteFileChangeSets(ids: deletes) } catch { pendingDeletes.formUnion(deletes) }
    }

    func notify(_ sessionId: String?) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .fileChangesDidChange,
                object: nil,
                userInfo: sessionId.map { ["sessionId": $0] }
            )
        }
    }

    // MARK: - Sandbox ownership

    /// Files written host-side can land owned by the wrong Unix user inside
    /// the container; best-effort chown as root when the sandbox runs.
    func repairOwnership(for entries: [FileChangeEntry]) async {
        guard ownershipRepairEnabled else { return }
        let restored = entries.filter { $0.after != nil && $0.rootKind != .hostFolder }.prefix(100)
        guard !restored.isEmpty else { return }
        var commands: [String] = []
        for entry in restored {
            let path = entry.displayPath.replacingOccurrences(of: "'", with: "'\\''")
            commands.append("chown agent-\(entry.rootId):agent-\(entry.rootId) '\(path)'")
        }
        _ = try? await SandboxToolCommandRunnerRegistry.shared.execAsRoot(
            command: commands.joined(separator: "; ") + " 2>/dev/null || true",
            timeout: 10
        )
    }
}
