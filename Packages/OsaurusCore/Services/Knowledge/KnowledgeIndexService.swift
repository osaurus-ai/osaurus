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
    /// Adapter-extracted formats (pdf, docx, xlsx, …) are legitimately
    /// larger than curated markdown; parity with `DocumentLimits.maxFileSize`.
    /// Shared with `read_knowledge`, which extracts through the same adapters.
    static let maxAdapterFileBytes = 10 * 1024 * 1024
    /// Claimed by the plaintext adapter but never indexed: a searchable
    /// index is the wrong place for secrets.
    private static let excludedExtensions: Set<String> = ["env"]
    /// Hard cap on files per collection so a mispointed folder (e.g. a
    /// home directory) can't stall indexing for minutes. Overflow is
    /// logged, never silent.
    private static let maxFilesPerCollection = 5000

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

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

        DocumentAdaptersBootstrap.registerBuiltIns()
        let files = scanIndexableFiles(in: folderURL)
        let existingHashes = (try? KnowledgeDatabase.shared.documentHashes(collectionId: collectionId)) ?? [:]
        // Existing rows' categories, for backfilling inference on the skip
        // path: rows indexed before inference existed have an unchanged
        // content hash, so the full upsert never revisits them.
        let existingDocuments =
            (try? KnowledgeDatabase.shared.listDocuments(
                collectionIds: [collectionId],
                limit: Self.maxFilesPerCollection
            )) ?? []
        var typesByPath: [String: (docType: String, inferredType: String)] = [:]
        for document in existingDocuments {
            typesByPath[document.relPath] = (document.docType, document.inferredType)
        }
        var seenPaths: Set<String> = []

        for file in files {
            let relPath = relativePath(of: file, under: folderURL)
            guard !relPath.isEmpty else { continue }
            seenPaths.insert(relPath)

            // Hash raw bytes so binary formats work too; for valid UTF-8
            // markdown this matches the previous text hash byte-for-byte,
            // so existing indexes are not invalidated.
            guard let data = try? Data(contentsOf: file) else {
                summary.failed += 1
                KnowledgeLogger.index.warning("Unreadable file skipped: \(relPath, privacy: .public)")
                continue
            }

            let hash = Self.sha256Hex(data)
            if !force, existingHashes[relPath] == hash {
                if let types = typesByPath[relPath], types.docType.isEmpty {
                    let inferred = KnowledgeTypeInference.infer(relPath: relPath)
                    if inferred != types.inferredType {
                        try? KnowledgeDatabase.shared.updateInferredType(
                            collectionId: collectionId,
                            relPath: relPath,
                            inferredType: inferred
                        )
                    }
                }
                summary.skipped += 1
                continue
            }

            do {
                let (frontmatter, body) = try await extractDocument(file: file, data: data)
                try await indexDocument(
                    collectionId: collectionId,
                    relPath: relPath,
                    fileURL: file,
                    frontmatter: frontmatter,
                    body: body,
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
        // Adapter-extracted formats (pdf, code, …) carry no frontmatter
        // at all, so the conformance check only applies to markdown.
        let reserved: Set<String> = ["index.md", "log.md"]
        return documents
            .filter { document in
                document.docType.isEmpty
                    && !reserved.contains(document.relPath.lowercased())
                    && Self.markdownExtensions.contains(
                        (document.relPath as NSString).pathExtension.lowercased())
            }
            .map(\.relPath)
    }

    /// Documents with no category at all — no explicit frontmatter
    /// `type` and nothing the indexer could infer. This is what the UI
    /// badge reports; `okfNonconformingDocuments` (explicit type only)
    /// remains the strict OKF conformance check.
    public func uncategorizedDocuments(collectionId: String) -> [String] {
        guard openDatabaseIfNeeded() else { return [] }
        let documents =
            (try? KnowledgeDatabase.shared.listDocuments(
                collectionIds: [collectionId],
                limit: Self.maxFilesPerCollection
            )) ?? []
        let reserved: Set<String> = ["index.md", "log.md"]
        return documents
            .filter { document in
                document.effectiveType.isEmpty
                    && !reserved.contains(document.relPath.lowercased())
                    && Self.markdownExtensions.contains(
                        (document.relPath as NSString).pathExtension.lowercased())
            }
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

    private enum ExtractionError: Error {
        case notUTF8
        case noAdapter
    }

    /// Markdown parses in place (frontmatter + body); everything else
    /// goes through its registered document adapter and indexes the
    /// extracted plain text with empty facets.
    private func extractDocument(
        file: URL,
        data: Data
    ) async throws -> (frontmatter: KnowledgeFrontmatter, body: String) {
        if Self.isMarkdown(file) {
            guard let content = String(data: data, encoding: .utf8) else {
                throw ExtractionError.notUTF8
            }
            return KnowledgeDocumentParser.parse(markdown: content)
        }
        guard let adapter = DocumentFormatRegistry.shared.adapter(for: file) else {
            throw ExtractionError.noAdapter
        }
        let document = try await adapter.parse(
            url: file,
            sizeLimit: Int64(Self.maxAdapterFileBytes)
        )
        return (KnowledgeFrontmatter(), document.textFallback)
    }

    private func indexDocument(
        collectionId: String,
        relPath: String,
        fileURL: URL,
        frontmatter: KnowledgeFrontmatter,
        body: String,
        contentHash: String
    ) async throws {
        let title = KnowledgeDocumentParser.resolveTitle(
            frontmatter: frontmatter,
            body: body,
            relPath: relPath
        )
        let chunks = KnowledgeDocumentParser.chunk(body: body)

        // No explicit frontmatter `type` → infer one from the folder
        // structure so the collection stays type-filterable without the
        // user editing files. Explicit frontmatter always wins.
        let inferredType =
            frontmatter.docType.isEmpty
            ? KnowledgeTypeInference.infer(relPath: relPath) : ""
        let effectiveType = frontmatter.docType.isEmpty ? inferredType : frontmatter.docType

        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = values?.contentModificationDate.map {
            ISO8601DateFormatter().string(from: $0)
        } ?? ""
        let sizeBytes = values?.fileSize ?? body.utf8.count

        let documentId = try KnowledgeDatabase.shared.upsertDocument(
            collectionId: collectionId,
            relPath: relPath,
            title: title,
            docType: frontmatter.docType,
            inferredType: inferredType,
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
                docType: effectiveType,
                tagsCSV: frontmatter.tagsCSV
            )
        }
        await KnowledgeSearchService.shared.indexChunks(hits)
    }

    // MARK: - Folder scanning

    /// Enumerate indexable files under the collection folder: markdown,
    /// plus anything a registered document adapter claims (plain text,
    /// code, pdf, docx, xlsx, …). Hidden entries are skipped by the
    /// enumerator; symlinks are skipped explicitly so a link out of the
    /// folder can't smuggle external content into the index.
    private func scanIndexableFiles(in folderURL: URL) -> [URL] {
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
            let ext = url.pathExtension.lowercased()
            if Self.excludedExtensions.contains(ext) { continue }
            let isMarkdown = Self.markdownExtensions.contains(ext)
            guard isMarkdown || DocumentFormatRegistry.shared.adapter(for: url) != nil else {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            let maxBytes = isMarkdown ? Self.maxFileBytes : Self.maxAdapterFileBytes
            if let size = values.fileSize, size > maxBytes {
                KnowledgeLogger.index.warning(
                    "Oversized file skipped (\(size) bytes): \(url.lastPathComponent, privacy: .public)"
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
                "Collection exceeds \(Self.maxFilesPerCollection) indexable files; \(overflow) files not indexed"
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

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
