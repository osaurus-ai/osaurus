//
//  FileChangeJournal+Revert.swift
//  osaurus
//
//  Queries, reverts, purge, and retention for the file history journal.
//
//  Every revert is planned first (target state + the state history expects
//  to be live), preflighted against disk, and then applied under its own
//  precise capture, so the revert is recorded as a `userRevert` set that
//  can itself be reverted. Paths whose live state diverged from history are
//  conflicts: skipped unless the user forces them, and a forced overwrite
//  is still captured first, so nothing is ever lost.
//

import Darwin
import Foundation

public struct FileHistoryRetention: Codable, Equatable, Sendable {
    /// Delete sets older than this many days; nil keeps them until the
    /// chat is deleted.
    public var maxAgeDays: Int?
    /// Trim the oldest sets while stored history exceeds this; nil = no cap.
    public var maxBytes: Int64?

    public init(maxAgeDays: Int? = nil, maxBytes: Int64? = nil) {
        self.maxAgeDays = maxAgeDays
        self.maxBytes = maxBytes
    }

    public static let keepUntilChatDeleted = FileHistoryRetention()
}

extension FileChangeJournal {

    // MARK: - Scopes

    public enum RevertScope: Sendable, Equatable {
        /// Undo one change set.
        case set(UUID)
        /// Return one path to its state before the session touched it.
        case file(FilePathKey)
        /// Undo a change set and everything recorded after it.
        case rollback(fromSet: UUID)
        /// Undo every change the session made.
        case all
    }

    struct RestoreItem: Sendable {
        let key: FilePathKey
        let target: FilePathState?
        let expected: FilePathState?
        let entryIds: Set<UUID>
    }

    struct RevertError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Queries

    /// Every set of the session, oldest first.
    public func changeSets(for sessionId: String) -> [FileChangeSet] {
        ensureRecovered()
        loadIfNeeded(sessionId)
        return cache[sessionId] ?? []
    }

    public func changeSet(id: UUID, sessionId: String) -> FileChangeSet? {
        changeSets(for: sessionId).first { $0.id == id }
    }

    /// The set a tool call produced (inline cards key off the call id).
    public func changeSet(forToolCallId toolCallId: String, sessionId: String) -> FileChangeSet? {
        changeSets(for: sessionId).last { $0.toolCallId == toolCallId && $0.origin != .userRevert }
    }

    /// Net per-path view: state before the session vs latest recorded.
    public func netChanges(for sessionId: String) -> [FileNetChange] {
        struct Acc {
            var original: FilePathState?
            var latest: FilePathState?
            var setIds: [UUID]
            var lastAt: Date
            var lastTool: String
        }
        var order: [FilePathKey] = []
        var acc: [FilePathKey: Acc] = [:]
        for set in changeSets(for: sessionId) {
            for entry in set.entries.sorted(by: { $0.ordinal < $1.ordinal }) {
                let key = entry.pathKey
                if var a = acc[key] {
                    a.latest = entry.after
                    if a.setIds.last != set.id { a.setIds.append(set.id) }
                    a.lastAt = set.createdAt
                    a.lastTool = set.toolName
                    acc[key] = a
                } else {
                    order.append(key)
                    acc[key] = Acc(
                        original: entry.before, latest: entry.after, setIds: [set.id],
                        lastAt: set.createdAt, lastTool: set.toolName)
                }
            }
        }
        return order.compactMap { key in
            guard let a = acc[key], !Self.sameContent(a.original, a.latest) else { return nil }
            return FileNetChange(
                key: key, original: a.original, latest: a.latest, setIds: a.setIds,
                lastChangedAt: a.lastAt, lastTool: a.lastTool)
        }
        .sorted { $0.key.displayPath < $1.key.displayPath }
    }

    public func outstandingCount(for sessionId: String) -> Int {
        netChanges(for: sessionId).count
    }

    /// Sidebar summaries for every session with history.
    public func sessionSummaries() -> [String: FileChangeSessionSummary] {
        ensureRecovered()
        guard database.isOpen else { return [:] }
        flushPending()
        return database.fileChangeSessionSummaries()
    }

    /// Look up a set by id alone (inline cards know only the id).
    public func changeSet(id: UUID) -> FileChangeSet? {
        ensureRecovered()
        for sets in cache.values {
            if let set = sets.first(where: { $0.id == id }) { return set }
        }
        guard database.isOpen else { return nil }
        flushPending()
        guard let sessionId = database.fileChangeSessionId(forSetId: id.uuidString) else { return nil }
        return changeSet(id: id, sessionId: sessionId)
    }

    /// The set a tool call produced, from any session (row chips know only
    /// the call id).
    public func changeSet(forToolCallId toolCallId: String) -> FileChangeSet? {
        ensureRecovered()
        for sets in cache.values {
            if let set = sets.last(where: { $0.toolCallId == toolCallId && $0.origin != .userRevert }) {
                return set
            }
        }
        guard database.isOpen else { return nil }
        flushPending()
        guard let sessionId = database.fileChangeSessionId(forToolCallId: toolCallId) else { return nil }
        return changeSet(forToolCallId: toolCallId, sessionId: sessionId)
    }

    /// What one assistant turn changed, for the end-of-turn summary row:
    /// distinct paths touched by the turn's agent sets, and the first set
    /// (to focus the panel on). Nil when the turn recorded nothing.
    public func turnSummary(turnId: UUID) -> FileChangeTurnSummary? {
        ensureRecovered()
        var sets = cache.values.flatMap { $0.filter { $0.turnId == turnId && $0.origin == .agent } }
        if sets.isEmpty, database.isOpen {
            flushPending()
            guard let sessionId = database.fileChangeSessionId(forTurnId: turnId.uuidString) else { return nil }
            sets = changeSets(for: sessionId).filter { $0.turnId == turnId && $0.origin == .agent }
        }
        guard let first = sets.min(by: { $0.createdAt < $1.createdAt }) else { return nil }
        let paths = Set(sets.flatMap { $0.entries.map(\.pathKey) })
        guard !paths.isEmpty else { return nil }
        let allReverted = sets.allSatisfy { $0.status == .reverted }
        return FileChangeTurnSummary(
            sessionId: first.sessionId, firstSetId: first.id, fileCount: paths.count,
            setCount: sets.count, allReverted: allReverted)
    }

    /// The live revert that undid `setId` (so a card can offer Undo).
    public func activeRevert(of setId: UUID, sessionId: String) -> FileChangeSet? {
        changeSets(for: sessionId).last {
            $0.origin == .userRevert && $0.revertsSetId == setId && $0.status != .reverted
        }
    }

    /// The most recent agent-made set that still has something to undo.
    public func latestRevertibleAgentSet(sessionId: String) -> FileChangeSet? {
        changeSets(for: sessionId).last {
            $0.origin != .userRevert && $0.isRevertible && $0.status != .reverted
        }
    }

    // MARK: - Planning

    func plan(_ scope: RevertScope, sessionId: String) -> [RestoreItem] {
        let sets = changeSets(for: sessionId)
        func netItems(_ entries: [FileChangeEntry]) -> [RestoreItem] {
            var order: [FilePathKey] = []
            var first: [FilePathKey: FileChangeEntry] = [:]
            var last: [FilePathKey: FileChangeEntry] = [:]
            var ids: [FilePathKey: Set<UUID>] = [:]
            for entry in entries {
                let key = entry.pathKey
                if first[key] == nil {
                    first[key] = entry
                    order.append(key)
                }
                last[key] = entry
                ids[key, default: []].insert(entry.id)
            }
            return order.compactMap { key in
                guard let f = first[key], let l = last[key] else { return nil }
                if Self.sameContent(f.before, l.after) { return nil }
                return RestoreItem(key: key, target: f.before, expected: l.after, entryIds: ids[key] ?? [])
            }
        }
        func ordered(_ sets: [FileChangeSet]) -> [FileChangeEntry] {
            sets.flatMap { $0.entries.sorted { $0.ordinal < $1.ordinal } }
        }
        switch scope {
        case .set(let id):
            guard let set = sets.first(where: { $0.id == id }) else { return [] }
            return set.entries
                .filter { $0.state != .reverted }
                .sorted { $0.ordinal < $1.ordinal }
                .map { RestoreItem(key: $0.pathKey, target: $0.before, expected: $0.after, entryIds: [$0.id]) }
        case .file(let key):
            return netItems(ordered(sets).filter { $0.pathKey == key })
        case .rollback(let id):
            guard let index = sets.firstIndex(where: { $0.id == id }) else { return [] }
            return netItems(ordered(Array(sets[index...])))
        case .all:
            return netItems(ordered(sets))
        }
    }

    // MARK: - Preview

    public func previewRevert(_ scope: RevertScope, sessionId: String) -> FileRevertPreview {
        let items = plan(scope, sessionId: sessionId).map { item -> FileRevertPreviewItem in
            let live = objects.liveSignature(at: url(for: item.key))
            let alreadyThere = Self.sameContent(live, item.target)
            return FileRevertPreviewItem(
                key: item.key,
                target: item.target,
                expected: item.expected,
                isConflict: !alreadyThere && !Self.sameContent(live, item.expected),
                isUnrestorable: !alreadyThere && item.target.map { !canRestore($0) } == true,
                isTruncated: truncatedPaths(sessionId: sessionId).contains(item.key)
            )
        }
        return FileRevertPreview(items: items)
    }

    // MARK: - Revert

    /// Apply a revert. Conflicted paths are skipped unless `force`.
    public func revert(_ scope: RevertScope, sessionId: String, force: Bool = false) async
        -> FileRevertSummary
    {
        var summary = FileRevertSummary()
        guard !hasActiveBackgroundJobs(sessionId: sessionId) else {
            summary.blockedReason = L("A background job from this chat is still running.")
            return summary
        }
        // A tool call in this chat is mid-flight: its capture would record
        // the revert's writes as its own, and it may overwrite them next.
        guard !hasActiveCaptures(sessionId: sessionId) else {
            summary.blockedReason = L("The chat is still running a command — revert is paused until it finishes.")
            return summary
        }
        let items = plan(scope, sessionId: sessionId)
        guard !items.isEmpty else { return summary }

        var restoredIds: Set<UUID> = []
        var conflictedIds: Set<UUID> = []
        var restoredKeys: Set<FilePathKey> = []
        var toApply: [RestoreItem] = []
        for item in items {
            let live = objects.liveSignature(at: url(for: item.key))
            if Self.sameContent(live, item.target) {
                summary.restored += 1
                restoredIds.formUnion(item.entryIds)
                restoredKeys.insert(item.key)
                continue
            }
            if let target = item.target, !canRestore(target) {
                summary.failed += 1
                summary.failures.append(
                    "\(item.key.filename): "
                        + (target.isRestorable
                            ? L("its saved copy is missing from history") : L("too large to keep in history")))
                continue
            }
            if !force, !Self.sameContent(live, item.expected) {
                summary.conflicted += 1
                conflictedIds.formUnion(item.entryIds)
                continue
            }
            toApply.append(item)
        }

        if !toApply.isEmpty {
            var byRoot: [String: (SandboxWorkspaceRootKind, String, [String])] = [:]
            for item in toApply {
                let rootKey = item.key.rootKind.rawValue + "|" + item.key.rootId
                byRoot[rootKey, default: (item.key.rootKind, item.key.rootId, [])].2.append(item.key.path)
            }
            let token = beginCapture(
                sessionId: sessionId,
                toolName: "revert",
                origin: .userRevert,
                revertsSetId: Self.anchorSetId(scope, sets: changeSets(for: sessionId)),
                note: Self.describe(scope, sets: changeSets(for: sessionId)),
                targets: byRoot.values.map {
                    RootTarget(kind: $0.0, rootId: $0.1, declaredPaths: $0.2)
                }
            )
            let restores = toApply.filter { $0.target != nil }
                .sorted { Self.depth($0.key.path) < Self.depth($1.key.path) }
            let removals = toApply.filter { $0.target == nil }
                .sorted { Self.depth($0.key.path) > Self.depth($1.key.path) }
            for item in restores + removals {
                do {
                    try apply(item)
                    summary.restored += 1
                    restoredIds.formUnion(item.entryIds)
                    restoredKeys.insert(item.key)
                } catch {
                    summary.failed += 1
                    summary.failures.append("\(item.key.filename): \(error.localizedDescription)")
                }
            }
            summary.revertSetId = await endCapture(token)?.id
        }

        summary.restoredPaths = items.map(\.key).filter(restoredKeys.contains)
        markEntries(
            sessionId: sessionId, restored: restoredIds, conflicted: conflictedIds,
            redoScope: scope, restoredKeys: restoredKeys)
        notify(sessionId)
        return summary
    }

    /// Update entry states + set statuses after a revert, then persist the
    /// sets that changed. Reverting a revert ("redo") flips the entries it
    /// had undone back to applied.
    private func markEntries(
        sessionId: String,
        restored: Set<UUID>,
        conflicted: Set<UUID>,
        redoScope: RevertScope,
        restoredKeys: Set<FilePathKey>
    ) {
        guard var sets = cache[sessionId] else { return }
        // A file-scoped revert has no anchor: every earlier agent set is in range.
        var redoRange: ClosedRange<Date>?
        if case .set(let id) = redoScope,
            let revertSet = sets.first(where: { $0.id == id }), revertSet.origin == .userRevert
        {
            let anchor = revertSet.revertsSetId.flatMap { anchorId in sets.first { $0.id == anchorId } }
            redoRange = (anchor?.createdAt ?? .distantPast)...revertSet.createdAt
        }
        for i in sets.indices {
            var changed = false
            let isRedoTarget =
                sets[i].origin != .userRevert
                && (redoRange.map { $0.contains(sets[i].createdAt) } ?? false)
            for j in sets[i].entries.indices {
                let entry = sets[i].entries[j]
                if restored.contains(entry.id), entry.state != .reverted {
                    sets[i].entries[j].state = .reverted
                    changed = true
                } else if conflicted.contains(entry.id), entry.state == .applied {
                    sets[i].entries[j].state = .conflicted
                    changed = true
                } else if isRedoTarget, entry.state == .reverted, restoredKeys.contains(entry.pathKey) {
                    sets[i].entries[j].state = .applied
                    changed = true
                }
            }
            if changed {
                sets[i].status = Self.recomputedStatus(sets[i])
                persist(sets[i])
            }
        }
        cache[sessionId] = sets
    }

    static func recomputedStatus(_ set: FileChangeSet) -> FileChangeSetStatus {
        if set.status == .untracked { return .untracked }
        let reverted = set.entries.filter { $0.state == .reverted }.count
        if reverted == 0 { return .applied }
        return reverted == set.entries.count ? .reverted : .partiallyReverted
    }

    static func anchorSetId(_ scope: RevertScope, sets: [FileChangeSet]) -> UUID? {
        switch scope {
        case .set(let id), .rollback(let id): return id
        case .file: return nil
        case .all: return sets.first?.id
        }
    }

    static func describe(_ scope: RevertScope, sets: [FileChangeSet]) -> String {
        switch scope {
        case .set(let id):
            guard let set = sets.first(where: { $0.id == id }) else { return L("Reverted a change") }
            if set.origin == .userRevert { return L("Undid a revert") }
            return L("Reverted “\(set.displayTitle)”")
        case .file(let key):
            return L("Restored \(key.filename)")
        case .rollback:
            return L("Rolled back")
        case .all:
            return L("Reverted all changes")
        }
    }

    // MARK: - Apply

    /// Whether `state` can be recreated: restorable in principle and, for
    /// files, its snapshot blob is still in the store.
    func canRestore(_ state: FilePathState) -> Bool {
        guard state.isRestorable else { return false }
        return state.objectHash.map { objects.contains(hash: $0) } ?? true
    }

    /// Put one path into its target state. Files are materialized as a
    /// sibling temp and renamed over the live path (atomic replace).
    func apply(_ item: RestoreItem) throws {
        let fm = FileManager.default
        let root = hostRoot(item.key.rootKind, item.key.rootId)
        let url = root.appendingPathComponent(item.key.path)
        guard Self.isContained(url, in: root) else {
            throw RevertError(message: "path resolves outside its folder")
        }
        let liveType = (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType

        func removeLive() throws {
            guard let liveType else { return }
            if liveType == .typeDirectory {
                let contents = try fm.contentsOfDirectory(atPath: url.path)
                guard contents.isEmpty else {
                    throw RevertError(message: "folder isn't empty (it holds files this chat didn't create)")
                }
            }
            try fm.removeItem(at: url)
        }

        guard let target = item.target else {
            try removeLive()
            return
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch target.type {
        case .directory:
            if liveType != nil, liveType != .typeDirectory { try removeLive() }
            if liveType != .typeDirectory {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
            }
            if let mode = target.mode {
                try? fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
            }
        case .symlink:
            try removeLive()
            try fm.createSymbolicLink(
                atPath: url.path, withDestinationPath: String(target.signature.dropFirst("link:".count)))
        case .file:
            guard let hash = target.objectHash else {
                throw RevertError(
                    message: target.signature.hasPrefix("big:")
                        ? L("too large to keep in history") : L("no saved copy of the earlier version"))
            }
            if liveType == .typeDirectory || liveType == .typeSymbolicLink { try removeLive() }
            let temp = try objects.materializeTemp(hash: hash, besides: url, mode: target.mode)
            if Darwin.rename(temp.path, url.path) != 0 {
                let code = errno
                try? fm.removeItem(at: temp)
                throw RevertError(message: String(cString: strerror(code)))
            }
        }
    }

    /// The deepest existing ancestor of `url`'s parent must resolve inside
    /// `root`, so a symlinked directory can never redirect a restore.
    static func isContained(_ url: URL, in root: URL) -> Bool {
        let fm = FileManager.default
        let rootReal = root.resolvingSymlinksInPath().standardizedFileURL.path
        var probe = url.deletingLastPathComponent()
        while !fm.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        let real = probe.resolvingSymlinksInPath().standardizedFileURL.path
        return real == rootReal || real.hasPrefix(rootReal + "/")
    }

    // MARK: - Purge / GC / retention

    /// Drop every set of a deleted/cleared chat, then collect its blobs.
    public func purgeSession(_ sessionId: String) {
        cache[sessionId] = nil
        loadedSessions.remove(sessionId)
        pendingUpserts = pendingUpserts.filter { $0.value.sessionId != sessionId }
        if database.isOpen { try? database.deleteFileChanges(sessionId: sessionId) }
        // Captures still running for a purged chat would come back as
        // orphan sets on the next flush; drop them instead.
        dropActiveCaptures(sessionId: sessionId)
        clearTruncation(sessionId: sessionId)
        collectGarbage()
        pruneShadows()
        notify(sessionId)
    }

    // MARK: - Truncation markers

    private var truncationURL: URL { storeRoot.appendingPathComponent("truncated.json") }

    private func loadTruncation() -> [String: Set<FilePathKey>] {
        if let cached = truncatedPathsCache { return cached }
        let loaded =
            (try? Data(contentsOf: truncationURL)).flatMap { try? JSONDecoder().decode([String: Set<FilePathKey>].self, from: $0) }
            ?? [:]
        truncatedPathsCache = loaded
        return loaded
    }

    private func storeTruncation(_ value: [String: Set<FilePathKey>]) {
        truncatedPathsCache = value
        if value.isEmpty {
            try? FileManager.default.removeItem(at: truncationURL)
            return
        }
        if let data = try? JSONEncoder().encode(value) {
            try? FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
            try? data.write(to: truncationURL, options: .atomic)
        }
    }

    /// Paths in `sessionId` whose earliest history was trimmed by
    /// retention: a file-scope revert restores them to the earliest change
    /// still kept, not to "before this chat".
    public func truncatedPaths(sessionId: String) -> Set<FilePathKey> {
        loadTruncation()[sessionId] ?? []
    }

    func recordTruncation(sessionId: String, keys: Set<FilePathKey>) {
        guard !keys.isEmpty else { return }
        var all = loadTruncation()
        all[sessionId, default: []].formUnion(keys)
        storeTruncation(all)
    }

    func clearTruncation(sessionId: String) {
        var all = loadTruncation()
        guard all.removeValue(forKey: sessionId) != nil else { return }
        storeTruncation(all)
    }

    /// Delete blobs no entry (persisted, deferred, or in-flight) references.
    /// Skipped (returns 0) whenever the root set can't be trusted: a failed
    /// query, or a database that reports entries but no signatures. Keeping
    /// unreferenced blobs a while longer is harmless; deleting referenced
    /// ones would make every snapshot "missing".
    @discardableResult
    public func collectGarbage() -> Int64 {
        // Unrecovered pending records still reference their pre-state blobs.
        ensureRecovered()
        guard database.isOpen else { return 0 }
        flushPending()
        let referenced: (signatures: Set<String>, entryCount: Int)
        do {
            referenced = try database.fileChangeReferencedSignatures()
        } catch {
            Self.log.error("GC skipped: reference query failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        if referenced.signatures.isEmpty, referenced.entryCount > 0 {
            Self.log.error("GC skipped: \(referenced.entryCount) entries but no signatures")
            return 0
        }
        var sigs = referenced.signatures
        sigs.formUnion(activeSignatures())
        for set in pendingUpserts.values {
            for e in set.entries {
                if let s = e.before?.signature { sigs.insert(s) }
                if let s = e.after?.signature { sigs.insert(s) }
            }
        }
        let hashes = Set(sigs.compactMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil })
        return objects.collectGarbage(keeping: hashes)
    }

    /// Bytes held by file history: every before/after snapshot plus the
    /// shadow clones kept for opaque captures.
    public func storedBytes() -> Int64 {
        objects.totalBytes() + shadowBytes()
    }

    /// Periodic upkeep: enforce `policy`, drop blobs nothing references
    /// (e.g. left behind by a crash mid-capture), and prune shadows.
    public func performMaintenance(_ policy: FileHistoryRetention) {
        applyRetention(policy)
        collectGarbage()
        pruneShadows()
    }

    /// Enforce the retention policy. Sessions with an in-flight capture are
    /// never trimmed. Returns the number of sets deleted.
    @discardableResult
    public func applyRetention(_ policy: FileHistoryRetention, now: Date = Date()) -> Int {
        ensureRecovered()
        guard database.isOpen, policy.maxAgeDays != nil || policy.maxBytes != nil else { return 0 }
        flushPending()
        let protected = Set(activeSessionIds())
        var index = database.fileChangeSetIndex().filter { !protected.contains($0.sessionId) }
        var doomed: [UUID] = []
        var touched: Set<String> = []
        if let days = policy.maxAgeDays {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            let old = index.filter { $0.createdAt < cutoff }
            doomed += old.map(\.id)
            touched.formUnion(old.map(\.sessionId))
            index.removeAll { $0.createdAt < cutoff }
        }
        if !doomed.isEmpty {
            markTruncated(deleting: Set(doomed), remaining: index)
            try? database.deleteFileChangeSets(ids: doomed)
            collectGarbage()
        }
        var deleted = doomed.count
        if let maxBytes = policy.maxBytes {
            // Oldest first, sized from the average set so a small history
            // isn't wiped in one pass. The newest set is always kept so the
            // latest change stays revertible even when it alone exceeds the cap.
            while case let total = objects.totalBytes(), total > maxBytes, index.count > 1 {
                let average = max(1, total / Int64(index.count))
                let needed = Int(((total - maxBytes) + average - 1) / average)
                let batch = Array(index.prefix(min(25, max(1, needed), index.count - 1)))
                index.removeFirst(batch.count)
                markTruncated(deleting: Set(batch.map(\.id)), remaining: index)
                try? database.deleteFileChangeSets(ids: batch.map(\.id))
                touched.formUnion(batch.map(\.sessionId))
                deleted += batch.count
                collectGarbage()
            }
        }
        for sessionId in touched {
            cache[sessionId] = nil
            loadedSessions.remove(sessionId)
        }
        if deleted > 0 {
            pruneShadows(now: now)
            notify(nil)
        }
        return deleted
    }

    /// Before retention deletes `ids`: for every session that keeps other
    /// sets, remember which paths lose their earliest history. Sessions
    /// losing everything need no marker (there's nothing left to revert).
    private func markTruncated(deleting ids: Set<UUID>, remaining: [(id: UUID, sessionId: String, createdAt: Date)]) {
        let survivors = Set(remaining.map(\.sessionId))
        var bySession: [String: Set<FilePathKey>] = [:]
        for sessionId in survivors {
            let doomed = changeSets(for: sessionId).filter { ids.contains($0.id) }
            guard !doomed.isEmpty else { continue }
            bySession[sessionId] = Set(doomed.flatMap { $0.entries.map(\.pathKey) })
        }
        for (sessionId, keys) in bySession { recordTruncation(sessionId: sessionId, keys: keys) }
        // Sessions that lost every set: forget any older marker too.
        let gone = Set(ids.compactMap { id in cache.first { $0.value.contains { $0.id == id } }?.key }).subtracting(survivors)
        for sessionId in gone { clearTruncation(sessionId: sessionId) }
    }
}
