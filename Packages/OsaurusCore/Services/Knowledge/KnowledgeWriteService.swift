//
//  KnowledgeWriteService.swift
//  OsaurusCore — Knowledge
//
//  Applies and reverts mutations to a knowledge collection folder.
//
//  This is the write half of `KnowledgeCurationService.approve` lifted out
//  from behind the proposal queue. The mutation mechanics were never the
//  problem — path confinement, atomic write, incremental re-index — only the
//  queue in front of them was, because a tool that returns "pending" can never
//  tell the calling agent what actually happened (osaurus#2439). Consent moves
//  to the call-time permission modal; this service is what runs once the user
//  allows the call.
//
//  Every mutation records what it replaced in `knowledge_writes` BEFORE
//  touching the file, so a change is revertable even if the process dies
//  mid-write. Reversibility is what makes call-time approval safe: nobody
//  reliably catches fabricated reference material by skimming a diff, but
//  anyone can revert once search starts returning nonsense.
//

import CryptoKit
import Foundation

public enum KnowledgeWriteError: Error, LocalizedError {
    case collectionUnavailable(String)
    case pathEscapesCollection(String)
    case nonMarkdownTarget(String)
    case documentNotFound(String)
    case writeFailed(String)
    case recordNotFound(Int)
    case alreadyReverted(Int)
    case changedSinceWrite(String)

    public var errorDescription: String? {
        switch self {
        case .collectionUnavailable(let name):
            return "Collection \(name) is unavailable (deleted, disabled, or its folder is missing)."
        case .pathEscapesCollection(let path):
            return "Path \(path) resolves outside the collection folder."
        case .nonMarkdownTarget(let path):
            return "Path \(path) is not a markdown document; only markdown documents can be written."
        case .documentNotFound(let path):
            return "No document at \(path) in this collection."
        case .writeFailed(let msg):
            return "Could not write the document: \(msg)"
        case .recordNotFound(let id):
            return "Write #\(id) was not found."
        case .alreadyReverted(let id):
            return "Write #\(id) has already been reverted."
        case .changedSinceWrite(let path):
            return "\(path) changed after this write, so reverting would discard newer content."
        }
    }
}

/// One applied mutation, returned so the caller can report per-document
/// outcomes rather than a single all-or-nothing result.
public struct KnowledgeWriteOutcome: Sendable, Equatable {
    public var relPath: String
    public var operation: KnowledgeWriteOperation
    /// Row id in `knowledge_writes`, for a targeted revert.
    public var recordId: Int
}

public actor KnowledgeWriteService {
    public static let shared = KnowledgeWriteService()

    private init() {}

    /// Open the write log on first use, mirroring how the knowledge tools
    /// open the index lazily rather than at app start. Called before every
    /// operation; `open()` is a no-op once the handle exists.
    private func ensureLogOpen() throws {
        guard !KnowledgeWriteLogDatabase.shared.isOpen else { return }
        try KnowledgeWriteLogDatabase.shared.open()
    }

    // MARK: - Apply

    /// Create or replace one document, logging what it replaced.
    ///
    /// `runId` groups the writes of one agent run so a bad bulk import can be
    /// reverted as a unit. Callers that have no run identity may pass "".
    public func write(
        collection: KnowledgeCollection,
        relPath: String,
        content: String,
        runId: String,
        createdBy: String,
        rationale: String
    ) async throws -> KnowledgeWriteOutcome {
        try ensureLogOpen()
        let fileURL = try Self.resolvedURL(collection: collection, relPath: relPath)

        let priorData = FileManager.default.contents(atPath: fileURL.path)
        let priorContent = priorData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let existed = priorData != nil
        let operation: KnowledgeWriteOperation = existed ? .replace : .create

        // Log BEFORE mutating: a crash between the log and the write leaves a
        // recoverable record, whereas the reverse order loses the prior
        // content permanently.
        let recordId = try KnowledgeWriteLogDatabase.shared.insert(
            collectionId: collection.id.uuidString,
            relPath: relPath,
            operation: operation,
            priorContent: priorContent,
            priorContentHash: existed ? Self.sha256Hex(priorContent) : "",
            resultContentHash: Self.sha256Hex(content),
            runId: runId,
            createdBy: createdBy,
            rationale: rationale,
            createdAt: Self.iso8601Now()
        )

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: fileURL, options: [.atomic])
        } catch {
            throw KnowledgeWriteError.writeFailed(error.localizedDescription)
        }

        await Self.reindexAndAnnounce(collection)
        KnowledgeLogger.index.info(
            "\(operation.rawValue, privacy: .public) \(collection.name, privacy: .public)/\(relPath, privacy: .public)"
        )
        return KnowledgeWriteOutcome(relPath: relPath, operation: operation, recordId: recordId)
    }

    /// Remove one document, logging its content so the delete can be undone.
    public func delete(
        collection: KnowledgeCollection,
        relPath: String,
        runId: String,
        createdBy: String,
        rationale: String
    ) async throws -> KnowledgeWriteOutcome {
        try ensureLogOpen()
        let fileURL = try Self.resolvedURL(collection: collection, relPath: relPath)
        guard let priorData = FileManager.default.contents(atPath: fileURL.path) else {
            throw KnowledgeWriteError.documentNotFound(relPath)
        }
        let priorContent = String(data: priorData, encoding: .utf8) ?? ""

        let recordId = try KnowledgeWriteLogDatabase.shared.insert(
            collectionId: collection.id.uuidString,
            relPath: relPath,
            operation: .delete,
            priorContent: priorContent,
            priorContentHash: Self.sha256Hex(priorContent),
            // A delete leaves nothing on disk.
            resultContentHash: "",
            runId: runId,
            createdBy: createdBy,
            rationale: rationale,
            createdAt: Self.iso8601Now()
        )

        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw KnowledgeWriteError.writeFailed(error.localizedDescription)
        }

        // The index still holds the deleted document's rows; drop them so a
        // removed document stops answering searches immediately rather than
        // waiting for the folder watcher.
        _ = try? KnowledgeDatabase.shared.deleteDocument(
            collectionId: collection.id.uuidString,
            relPath: relPath
        )
        await Self.reindexAndAnnounce(collection)
        KnowledgeLogger.index.info(
            "delete \(collection.name, privacy: .public)/\(relPath, privacy: .public)"
        )
        return KnowledgeWriteOutcome(relPath: relPath, operation: .delete, recordId: recordId)
    }

    // MARK: - Revert

    /// Undo one logged write.
    ///
    /// `force` skips the "changed since the write" guard. Without it a revert
    /// refuses to discard content that arrived after the agent's change,
    /// whether from the user, another agent, or a folder sync.
    public func revert(recordId: Int, force: Bool = false) async throws {
        try ensureLogOpen()
        guard let record = try KnowledgeWriteLogDatabase.shared.record(id: recordId) else {
            throw KnowledgeWriteError.recordNotFound(recordId)
        }
        guard !record.isReverted else {
            throw KnowledgeWriteError.alreadyReverted(recordId)
        }
        try await apply(revertOf: record, force: force)
        try KnowledgeWriteLogDatabase.shared.markReverted(
            id: recordId,
            revertedAt: Self.iso8601Now()
        )
        if let collection = await Self.collection(for: record.collectionId) {
            await Self.reindexAndAnnounce(collection)
        }
    }

    /// Undo every un-reverted write from one agent run.
    ///
    /// This is the affordance that matters after a bad bulk import, so it is
    /// best-effort per record: one path that cannot be restored must not strip
    /// the caller of the other sixty-one. Returns the records that failed,
    /// paired with why.
    @discardableResult
    public func revertRun(runId: String, force: Bool = false) async -> [(
        record: KnowledgeWriteRecord, error: Error
    )] {
        try? ensureLogOpen()
        // Newest first (the query's order): reverting in reverse application
        // order is the only sequence that restores correctly when one run
        // wrote the same path more than once.
        let records = (try? KnowledgeWriteLogDatabase.shared.records(runId: runId)) ?? []
        var failures: [(record: KnowledgeWriteRecord, error: Error)] = []
        var touched: [String: KnowledgeCollection] = [:]

        for record in records {
            do {
                try await apply(revertOf: record, force: force)
                try KnowledgeWriteLogDatabase.shared.markReverted(
                    id: record.id,
                    revertedAt: Self.iso8601Now()
                )
                if touched[record.collectionId] == nil,
                    let collection = await Self.collection(for: record.collectionId)
                {
                    touched[record.collectionId] = collection
                }
            } catch {
                failures.append((record, error))
            }
        }

        // One re-index per affected collection, not one per document.
        for collection in touched.values {
            await Self.reindexAndAnnounce(collection)
        }
        KnowledgeLogger.index.info(
            "Reverted run \(runId, privacy: .public): \(records.count - failures.count)/\(records.count) restored"
        )
        return failures
    }

    /// Put the file back the way the record says it was. Does not touch the
    /// database or re-index; callers own both so a batch can do them once.
    private func apply(revertOf record: KnowledgeWriteRecord, force: Bool) async throws {
        guard let collection = await Self.collection(for: record.collectionId) else {
            throw KnowledgeWriteError.collectionUnavailable(record.collectionId)
        }
        let fileURL = try Self.resolvedURL(collection: collection, relPath: record.relPath)

        let currentData = FileManager.default.contents(atPath: fileURL.path)
        let currentContent = currentData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        // "" for an absent file, which is exactly what a delete recorded as
        // its result, so the comparison is uniform across all three operations.
        let currentHash = currentData == nil ? "" : Self.sha256Hex(currentContent)

        // Refuse to discard anything that arrived after the agent's write,
        // whether from the user, another agent, or a folder sync. Undoing an
        // agent must never quietly undo a human.
        guard force || currentHash == record.resultContentHash else {
            // Already back to the prior state (a manual revert, or the same
            // path reverted twice through different records) is a no-op, not
            // a conflict.
            if currentHash == record.priorContentHash { return }
            throw KnowledgeWriteError.changedSinceWrite(record.relPath)
        }

        switch record.operation {
        case .create:
            // Nothing existed before, so reverting removes the file.
            guard currentData != nil else { return }
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                throw KnowledgeWriteError.writeFailed(error.localizedDescription)
            }
            _ = try? KnowledgeDatabase.shared.deleteDocument(
                collectionId: record.collectionId,
                relPath: record.relPath
            )

        case .replace, .delete:
            try Self.restore(record.priorContent, to: fileURL)
        }
    }

    // MARK: - Shared helpers

    private static func restore(_ content: String, to fileURL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: fileURL, options: [.atomic])
        } catch {
            throw KnowledgeWriteError.writeFailed(error.localizedDescription)
        }
    }

    /// Resolve a collection-relative path to an absolute URL, refusing
    /// anything that escapes the collection folder or targets a format whose
    /// text is adapter-extracted.
    ///
    /// Confinement is re-checked HERE rather than trusted from the tool layer,
    /// because this is the code that actually writes. Carried over verbatim
    /// from `KnowledgeCurationService.approve`, including the trailing-slash
    /// prefix comparison that stops `/docs-evil` matching `/docs`.
    static func resolvedURL(collection: KnowledgeCollection, relPath: String) throws -> URL {
        guard !relPath.isEmpty, !relPath.hasPrefix("/"), !relPath.hasPrefix("~"),
            !relPath.components(separatedBy: "/").contains("..")
        else {
            throw KnowledgeWriteError.pathEscapesCollection(relPath)
        }
        let folderURL = collection.folderURL.standardizedFileURL
        let fileURL = folderURL.appendingPathComponent(relPath).standardizedFileURL
        let folderPrefix = folderURL.path.hasSuffix("/") ? folderURL.path : folderURL.path + "/"
        guard fileURL.path.hasPrefix(folderPrefix) else {
            throw KnowledgeWriteError.pathEscapesCollection(relPath)
        }
        // Writing plain text onto an adapter-extracted format (pdf, docx, …)
        // would destroy the binary source of truth.
        guard KnowledgeIndexService.isMarkdown(fileURL) else {
            throw KnowledgeWriteError.nonMarkdownTarget(relPath)
        }
        return fileURL
    }

    /// Resolve a live, usable collection by id string.
    static func collection(for collectionId: String) async -> KnowledgeCollection? {
        guard let uuid = UUID(uuidString: collectionId) else { return nil }
        return await MainActor.run {
            guard let collection = KnowledgeManager.shared.collection(for: uuid),
                collection.isEnabled, collection.folderExists
            else { return nil }
            return collection
        }
    }

    /// Announce the change first so the UI updates immediately, then run the
    /// incremental index pass (hash skip covers everything unchanged) so the
    /// write is searchable without waiting on the folder watcher.
    private static func reindexAndAnnounce(_ collection: KnowledgeCollection) async {
        postWritesChanged()
        await KnowledgeIndexService.shared.indexCollection(collection)
        postWritesChanged()
    }

    private static func postWritesChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .knowledgeWritesChanged, object: nil)
        }
    }

    static func sha256Hex(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

extension Notification.Name {
    /// Posted when the knowledge write log changes (a write applied, or a
    /// write reverted), so history views can refresh.
    public static let knowledgeWritesChanged = Notification.Name("knowledgeWritesChanged")
}
