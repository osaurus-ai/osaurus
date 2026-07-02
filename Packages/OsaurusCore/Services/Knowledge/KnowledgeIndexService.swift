//
//  KnowledgeIndexService.swift
//  osaurus
//
//  Scans knowledge collection folders and maintains the derived index:
//  frontmatter facets + heading-aware chunks in knowledge.sqlite, and
//  chunk vectors in the per-collection VecturaKit buckets.
//
//  Incremental by content hash: unchanged files are skipped, changed
//  files re-chunked and re-embedded, deleted files pruned. The folder
//  is read-only to this service — indexing never mutates the corpus.
//

import CryptoKit
import Foundation

/// Outcome counts of one collection indexing pass.
public struct KnowledgeIndexSummary: Sendable, Equatable {
    public var indexed: Int = 0
    public var skipped: Int = 0
    public var pruned: Int = 0
    public var failed: Int = 0

    public init() {}
}

public actor KnowledgeIndexService {
    public static let shared = KnowledgeIndexService()

    /// Files larger than this are skipped (and logged) — a multi-megabyte
    /// "markdown" file is almost never curated knowledge.
    private static let maxFileBytes = 2 * 1024 * 1024
    /// Hard cap on files per collection so a mispointed folder (e.g. a
    /// home directory) can't stall indexing for minutes. Overflow is
    /// logged, never silent.
    private static let maxFilesPerCollection = 5000

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]

    private var databaseOpened = false

    private init() {}

    // MARK: - Indexing

    /// Index every enabled collection. Used at startup and after bulk
    /// registry changes.
    public func indexAll(_ collections: [KnowledgeCollection]) async {
        for collection in collections where collection.isEnabled {
            await indexCollection(collection)
        }
    }

    /// Incrementally index one collection. `force` re-indexes every file
    /// regardless of content hash (manual "Rebuild index").
    @discardableResult
    public func indexCollection(_ collection: KnowledgeCollection, force: Bool = false) async -> KnowledgeIndexSummary {
        var summary = KnowledgeIndexSummary()
        guard collection.isEnabled else { return summary }
        guard openDatabaseIfNeeded() else { return summary }

        let collectionId = collection.id.uuidString
        let folderURL = collection.folderURL.standardizedFileURL
        guard collection.folderExists else {
            KnowledgeLogger.index.warning(
                "Collection folder missing for \(collection.name, privacy: .public); keeping existing index"
            )
            return summary
        }

        let files = scanMarkdownFiles(in: folderURL)
        let existingHashes = (try? KnowledgeDatabase.shared.documentHashes(collectionId: collectionId)) ?? [:]
        var seenPaths: Set<String> = []

        for file in files {
            let relPath = relativePath(of: file, under: folderURL)
            guard !relPath.isEmpty else { continue }
            seenPaths.insert(relPath)

            guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                summary.failed += 1
                KnowledgeLogger.index.warning("Unreadable markdown skipped: \(relPath, privacy: .public)")
                continue
            }

            let hash = Self.sha256Hex(content)
            if !force, existingHashes[relPath] == hash {
                summary.skipped += 1
                continue
            }

            do {
                try await indexDocument(
                    collectionId: collectionId,
                    relPath: relPath,
                    fileURL: file,
                    content: content,
                    contentHash: hash
                )
                summary.indexed += 1
            } catch {
                summary.failed += 1
                KnowledgeLogger.index.error(
                    "Indexing failed for \(relPath, privacy: .public): \(error)"
                )
            }
        }

        // Prune documents whose files were deleted or renamed away.
        for (relPath, _) in existingHashes where !seenPaths.contains(relPath) {
            let removedChunks =
                (try? KnowledgeDatabase.shared.deleteDocument(collectionId: collectionId, relPath: relPath)) ?? 0
            await KnowledgeSearchService.shared.removeChunks(
                collectionId: collectionId,
                relPath: relPath,
                chunkCount: removedChunks
            )
            summary.pruned += 1
        }

        KnowledgeLogger.index.info(
            "Indexed collection \(collection.name, privacy: .public): \(summary.indexed) indexed, \(summary.skipped) unchanged, \(summary.pruned) pruned, \(summary.failed) failed"
        )
        return summary
    }

    /// OKF conformance check over the indexed documents: every
    /// non-reserved document must carry a non-empty frontmatter `type`.
    /// Returns the relative paths that fail; empty means conformant.
    /// Reads the index (not the disk), so run after an indexing pass.
    public func okfNonconformingDocuments(collectionId: String) -> [String] {
        guard openDatabaseIfNeeded() else { return [] }
        let documents =
            (try? KnowledgeDatabase.shared.listDocuments(
                collectionIds: [collectionId],
                limit: Self.maxFilesPerCollection
            )) ?? []
        // OKF reserves index.md / log.md (no frontmatter requirements).
        let reserved: Set<String> = ["index.md", "log.md"]
        return documents
            .filter { $0.docType.isEmpty && !reserved.contains($0.relPath.lowercased()) }
            .map(\.relPath)
    }

    /// Purge every derived artifact of a deleted collection (SQLite rows
    /// + vector directory). The user's folder is untouched.
    public func removeCollectionArtifacts(collectionId: UUID) async {
        guard openDatabaseIfNeeded() else { return }
        try? KnowledgeDatabase.shared.deleteCollection(collectionId: collectionId.uuidString)
        await KnowledgeSearchService.shared.removeCollection(collectionId: collectionId.uuidString)
    }

    // MARK: - Per-document pass

    private func indexDocument(
        collectionId: String,
        relPath: String,
        fileURL: URL,
        content: String,
        contentHash: String
    ) async throws {
        let (frontmatter, body) = KnowledgeDocumentParser.parse(markdown: content)
        let title = KnowledgeDocumentParser.resolveTitle(
            frontmatter: frontmatter,
            body: body,
            relPath: relPath
        )
        let chunks = KnowledgeDocumentParser.chunk(body: body)

        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = values?.contentModificationDate.map {
            ISO8601DateFormatter().string(from: $0)
        } ?? ""
        let sizeBytes = values?.fileSize ?? content.utf8.count

        let documentId = try KnowledgeDatabase.shared.upsertDocument(
            collectionId: collectionId,
            relPath: relPath,
            title: title,
            docType: frontmatter.docType,
            summary: frontmatter.summary,
            tagsCSV: frontmatter.tagsCSV,
            contentHash: contentHash,
            sizeBytes: sizeBytes,
            modifiedAt: modifiedAt
        )
        let previousChunkCount = try KnowledgeDatabase.shared.replaceChunks(
            documentId: documentId,
            chunks: chunks
        )

        // Drop stale trailing vectors when the document shrank, then
        // (re-)index the current chunks. Vector ids are deterministic, so
        // overlapping indexes overwrite in place.
        if previousChunkCount > chunks.count {
            await KnowledgeSearchService.shared.removeChunks(
                collectionId: collectionId,
                relPath: relPath,
                chunkCount: previousChunkCount
            )
        }
        let hits = chunks.enumerated().map { index, chunk in
            KnowledgeChunkHit(
                documentId: documentId,
                chunkIndex: index,
                headingPath: chunk.headingPath,
                content: chunk.content,
                collectionId: collectionId,
                relPath: relPath,
                title: title,
                docType: frontmatter.docType,
                tagsCSV: frontmatter.tagsCSV
            )
        }
        await KnowledgeSearchService.shared.indexChunks(hits)
    }

    // MARK: - Folder scanning

    /// Enumerate markdown files under the collection folder. Hidden
    /// entries are skipped by the enumerator; symlinks are skipped
    /// explicitly so a link out of the folder can't smuggle external
    /// content into the index.
    private func scanMarkdownFiles(in folderURL: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: folderURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return [] }

        var files: [URL] = []
        var overflow = 0
        for case let url as URL in enumerator {
            guard Self.markdownExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            if let size = values.fileSize, size > Self.maxFileBytes {
                KnowledgeLogger.index.warning(
                    "Oversized markdown skipped (\(size) bytes): \(url.lastPathComponent, privacy: .public)"
                )
                continue
            }
            if files.count >= Self.maxFilesPerCollection {
                overflow += 1
                continue
            }
            files.append(url)
        }
        if overflow > 0 {
            KnowledgeLogger.index.warning(
                "Collection exceeds \(Self.maxFilesPerCollection) markdown files; \(overflow) files not indexed"
            )
        }
        return files.sorted { $0.path < $1.path }
    }

    private func relativePath(of file: URL, under folderURL: URL) -> String {
        let filePath = file.standardizedFileURL.path
        let folderPath = folderURL.path.hasSuffix("/") ? folderURL.path : folderURL.path + "/"
        guard filePath.hasPrefix(folderPath) else { return "" }
        return String(filePath.dropFirst(folderPath.count))
    }

    private func openDatabaseIfNeeded() -> Bool {
        if databaseOpened { return true }
        do {
            try KnowledgeDatabase.shared.open()
            databaseOpened = true
            return true
        } catch {
            KnowledgeLogger.index.error("Knowledge database open failed: \(error)")
            return false
        }
    }

    // MARK: - Hashing

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
