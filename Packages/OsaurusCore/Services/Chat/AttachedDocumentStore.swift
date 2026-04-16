//
//  AttachedDocumentStore.swift
//  osaurus
//
//  Session-scoped registry for document attachments so local models can
//  search and page through full document contents via tools instead of
//  forcing the entire raw document into a single prompt prefill.
//

import Foundation

struct AttachedDocumentReference: Sendable, Equatable {
    let attachmentId: String
    let filename: String
    let characterCount: Int
    let chunkCount: Int
    let preview: String
}

struct AttachedDocumentSearchHit: Sendable, Equatable {
    let attachmentId: String
    let filename: String
    let chunkIndex: Int
    let chunkCount: Int
    let excerpt: String
    let score: Int
}

struct AttachedDocumentChunkRead: Sendable, Equatable {
    let attachmentId: String
    let filename: String
    let chunkIndex: Int
    let chunkCount: Int
    let content: String
}

actor AttachedDocumentStore {
    static let shared = AttachedDocumentStore()

    private struct StoredDocument: Sendable {
        let attachmentId: String
        let filename: String
        let content: String
        let chunks: [String]
        let looksLikeMultiProfile: Bool
        let updatedAt: Date
        var chunkEmbeddings: [[Float]]?
    }

    private static let previewLength = 240
    private static let chunkSize = 2_400
    private static let chunkOverlap = 240
    private static let maxRegisteredDocuments = 512
    private static let minimumSemanticScore: Float = 0.10
    private static let ignoredQueryTokens: Set<String> = [
        "a", "an", "and", "are", "at", "be", "by", "can", "describe", "do", "for", "from", "how", "i",
        "in", "is", "it", "me", "my", "of", "on", "or", "see", "that", "the", "there", "this", "to",
        "what", "where", "who", "why", "you", "your",
    ]

    private var documents: [String: StoredDocument] = [:]

    func register(attachments: [Attachment]) -> [AttachedDocumentReference] {
        var references: [AttachedDocumentReference] = []

        for attachment in attachments where attachment.isDocument {
            guard let filename = attachment.filename, let content = attachment.documentContent else { continue }
            let attachmentId = attachment.id.uuidString
            let chunks = Self.chunk(content)
            let document = StoredDocument(
                attachmentId: attachmentId,
                filename: filename,
                content: content,
                chunks: chunks,
                looksLikeMultiProfile: Self.looksLikeMultiProfileDocument(content),
                updatedAt: Date(),
                chunkEmbeddings: nil
            )
            documents[attachmentId] = document
            references.append(
                AttachedDocumentReference(
                    attachmentId: attachmentId,
                    filename: filename,
                    characterCount: content.count,
                    chunkCount: chunks.count,
                    preview: Self.preview(for: content)
                )
            )
        }

        trimIfNeeded()

        return references.sorted { lhs, rhs in
            lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
        }
    }

    func search(
        attachmentIds: [String],
        query: String,
        maxResults: Int
    ) async -> [AttachedDocumentSearchHit] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAttachmentIds = Self.sanitizeAttachmentIds(attachmentIds)
        guard !normalizedAttachmentIds.isEmpty, !trimmedQuery.isEmpty else { return [] }

        let limit = max(1, min(maxResults, 8))
        let lexicalHits = lexicalSearch(
            attachmentIds: normalizedAttachmentIds,
            query: trimmedQuery
        )
        if !lexicalHits.isEmpty {
            return Array(lexicalHits.prefix(limit))
        }

        return await semanticSearch(
            attachmentIds: normalizedAttachmentIds,
            query: trimmedQuery,
            maxResults: limit
        )
    }

    func read(attachmentId: String, chunkIndex: Int) -> AttachedDocumentChunkRead? {
        let normalizedAttachmentId = Self.sanitizeAttachmentIds([attachmentId]).first ?? attachmentId
        guard let document = documents[normalizedAttachmentId] else { return nil }
        let normalizedIndex = max(1, chunkIndex)
        guard normalizedIndex <= document.chunks.count else { return nil }

        return AttachedDocumentChunkRead(
            attachmentId: document.attachmentId,
            filename: document.filename,
            chunkIndex: normalizedIndex,
            chunkCount: document.chunks.count,
            content: document.chunks[normalizedIndex - 1]
        )
    }

    func buildPromptContext(
        attachmentIds: [String],
        query: String,
        maxResults: Int,
        maxTotalCharacters: Int,
        allowFallback: Bool = false
    ) async -> String {
        let normalizedAttachmentIds = Self.sanitizeAttachmentIds(attachmentIds)
        guard !normalizedAttachmentIds.isEmpty else { return "" }

        let requestedHits = await search(
            attachmentIds: normalizedAttachmentIds,
            query: query,
            maxResults: maxResults
        )
        let canUseFallback =
            allowFallback
            && !normalizedAttachmentIds.contains { attachmentId in
                documents[attachmentId]?.looksLikeMultiProfile == true
            }
        let hits =
            requestedHits.isEmpty && canUseFallback
            ? fallbackPromptHits(attachmentIds: normalizedAttachmentIds, maxResults: maxResults)
            : requestedHits
        guard !hits.isEmpty else { return "" }

        var lines = [
            "<attached_document_context>",
            requestedHits.isEmpty
                ? "Representative excerpts from the attached documents are included below because no strong direct match was found for the current request."
                : "These excerpts were selected from the attached documents for the current user request.",
        ]

        var remainingCharacters = max(1_024, maxTotalCharacters)
        for hit in hits {
            guard let document = documents[hit.attachmentId] else { continue }
            let chunkOffset = hit.chunkIndex - 1
            guard document.chunks.indices.contains(chunkOffset) else { continue }

            let excerptBudget = min(1_400, max(420, remainingCharacters))
            let excerpt = Self.preview(for: document.chunks[chunkOffset], maxCharacters: excerptBudget)
            guard !excerpt.isEmpty else { continue }

            lines.append(
                "<attached_document_excerpt id=\"\(hit.attachmentId)\" name=\"\(hit.filename)\" chunk=\"\(hit.chunkIndex)/\(hit.chunkCount)\" score=\"\(hit.score)\">"
            )
            lines.append(excerpt)
            lines.append("</attached_document_excerpt>")

            remainingCharacters -= excerpt.count
            if remainingCharacters <= 420 {
                break
            }
        }

        lines.append("</attached_document_context>")
        return lines.joined(separator: "\n")
    }

    private func trimIfNeeded() {
        guard documents.count > Self.maxRegisteredDocuments else { return }

        let overflow = documents.count - Self.maxRegisteredDocuments
        let oldestIds = documents.values
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(overflow)
            .map(\.attachmentId)

        for id in oldestIds {
            documents.removeValue(forKey: id)
        }
    }

    private static func preview(for text: String, maxCharacters: Int = previewLength) -> String {
        let squashed = squashWhitespace(text)
        guard squashed.count > maxCharacters else { return squashed }
        return String(squashed.prefix(maxCharacters)) + "..."
    }

    private static func looksLikeMultiProfileDocument(_ text: String) -> Bool {
        let normalized = text.lowercased()

        let repeatedHeadingSignals = [
            "executive summary",
            "relevant experience",
            "areas of expertise",
            "role and responsibilities",
            "languages",
            "education",
        ]
        .reduce(into: 0) { count, heading in
            if occurrenceCount(of: heading, in: normalized) >= 3 {
                count += 1
            }
        }

        let structuralSignals = [
            occurrenceCount(of: "volver", in: normalized) >= 2,
            occurrenceCount(of: "los azules ·", in: normalized) >= 3,
        ]
        .filter { $0 }
        .count

        return repeatedHeadingSignals >= 2 || (repeatedHeadingSignals >= 1 && structuralSignals >= 1)
    }

    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }

        var count = 0
        var searchRange: Range<String.Index>? = haystack.startIndex ..< haystack.endIndex
        while let range = haystack.range(of: needle, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound ..< haystack.endIndex
        }
        return count
    }

    private func lexicalSearch(
        attachmentIds: [String],
        query: String
    ) -> [AttachedDocumentSearchHit] {
        let normalizedQuery = query.lowercased()
        let queryTokens = Self.meaningfulQueryTokens(from: query)

        var hits: [AttachedDocumentSearchHit] = []
        for attachmentId in attachmentIds {
            guard let document = documents[attachmentId] else { continue }

            for (chunkIndex, chunk) in document.chunks.enumerated() {
                let score = Self.score(chunk: chunk, normalizedQuery: normalizedQuery, queryTokens: queryTokens)
                guard score > 0 else { continue }

                hits.append(
                    AttachedDocumentSearchHit(
                        attachmentId: document.attachmentId,
                        filename: document.filename,
                        chunkIndex: chunkIndex + 1,
                        chunkCount: document.chunks.count,
                        excerpt: Self.excerpt(
                            from: chunk,
                            query: normalizedQuery,
                            queryTokens: queryTokens,
                            maxCharacters: 420
                        ),
                        score: score
                    )
                )
            }
        }

        return hits.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.filename != rhs.filename {
                return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
            }
            return lhs.chunkIndex < rhs.chunkIndex
        }
    }

    private static func score(
        chunk: String,
        normalizedQuery: String,
        queryTokens: [String]
    ) -> Int {
        let normalizedChunk = chunk.lowercased()
        var score = 0

        if normalizedChunk.contains(normalizedQuery) {
            score += 12
        }

        for token in queryTokens {
            if normalizedChunk.contains(token) {
                score += 3
            }
        }

        return score
    }

    private static func meaningfulQueryTokens(from query: String) -> [String] {
        Array(Set(SearchService.tokenize(query))).filter { token in
            token.count >= 3 && !ignoredQueryTokens.contains(token)
        }
    }

    private func semanticSearch(
        attachmentIds: [String],
        query: String,
        maxResults: Int
    ) async -> [AttachedDocumentSearchHit] {
        guard let queryEmbedding = try? await EmbeddingService.shared.embed(texts: [query]).first else {
            return []
        }

        let normalizedQuery = query.lowercased()
        let queryTokens = Self.meaningfulQueryTokens(from: query)
        var hits: [AttachedDocumentSearchHit] = []

        for attachmentId in attachmentIds {
            guard var document = documents[attachmentId] else { continue }
            let embeddings = await ensureChunkEmbeddings(for: &document)
            documents[attachmentId] = document

            for (chunkIndex, chunk) in document.chunks.enumerated() {
                guard embeddings.indices.contains(chunkIndex) else { continue }
                let cosineScore = Self.cosineSimilarity(queryEmbedding, embeddings[chunkIndex])
                guard cosineScore >= Self.minimumSemanticScore else { continue }

                let lexicalScore = Self.score(
                    chunk: chunk,
                    normalizedQuery: normalizedQuery,
                    queryTokens: queryTokens
                )
                let combinedScore = Int((cosineScore * 1_000).rounded()) + (lexicalScore * 25)

                hits.append(
                    AttachedDocumentSearchHit(
                        attachmentId: document.attachmentId,
                        filename: document.filename,
                        chunkIndex: chunkIndex + 1,
                        chunkCount: document.chunks.count,
                        excerpt: Self.excerpt(
                            from: chunk,
                            query: normalizedQuery,
                            queryTokens: queryTokens,
                            maxCharacters: 420
                        ),
                        score: combinedScore
                    )
                )
            }
        }

        return
            hits
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.filename != rhs.filename {
                    return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
                }
                return lhs.chunkIndex < rhs.chunkIndex
            }
            .prefix(maxResults)
            .map { $0 }
    }

    private func ensureChunkEmbeddings(for document: inout StoredDocument) async -> [[Float]] {
        if let cachedEmbeddings = document.chunkEmbeddings, cachedEmbeddings.count == document.chunks.count {
            return cachedEmbeddings
        }

        guard let embeddings = try? await EmbeddingService.shared.embed(texts: document.chunks),
            embeddings.count == document.chunks.count
        else {
            document.chunkEmbeddings = []
            return []
        }

        document.chunkEmbeddings = embeddings
        return embeddings
    }

    private func fallbackPromptHits(
        attachmentIds: [String],
        maxResults: Int
    ) -> [AttachedDocumentSearchHit] {
        var hits: [AttachedDocumentSearchHit] = []

        for attachmentId in attachmentIds {
            guard let document = documents[attachmentId], !document.chunks.isEmpty else { continue }

            let firstIndex = 0
            let middleIndex = document.chunks.count > 2 ? document.chunks.count / 2 : nil
            let lastIndex = document.chunks.count - 1
            let candidateIndices = [firstIndex, middleIndex, lastIndex]
                .compactMap { $0 }
                .reduce(into: [Int]()) { indices, index in
                    if !indices.contains(index) {
                        indices.append(index)
                    }
                }

            for chunkIndex in candidateIndices {
                let chunk = document.chunks[chunkIndex]
                hits.append(
                    AttachedDocumentSearchHit(
                        attachmentId: document.attachmentId,
                        filename: document.filename,
                        chunkIndex: chunkIndex + 1,
                        chunkCount: document.chunks.count,
                        excerpt: Self.preview(for: chunk, maxCharacters: 420),
                        score: 1
                    )
                )
            }
        }

        return hits.prefix(maxResults).map { $0 }
    }

    private static func chunk(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        let characters = Array(text)
        var chunks: [String] = []
        var start = 0

        while start < characters.count {
            let hardEnd = min(characters.count, start + chunkSize)
            var end = hardEnd

            if hardEnd < characters.count,
                let newlineIndex = characters[start ..< hardEnd].lastIndex(where: { $0 == "\n" })
            {
                let candidateEnd = newlineIndex + 1
                if candidateEnd > start + (chunkSize / 2) {
                    end = candidateEnd
                }
            }

            let chunk = String(characters[start ..< end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }

            guard end < characters.count else { break }
            start = max(end - chunkOverlap, start + 1)
        }

        return chunks.isEmpty ? [text] : chunks
    }

    private static func squashWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    private static func excerpt(
        from text: String,
        query: String,
        queryTokens: [String],
        maxCharacters: Int
    ) -> String {
        let squashed = squashWhitespace(text)
        guard squashed.count > maxCharacters else { return squashed }

        let lowered = squashed.lowercased()
        let candidates = [query].filter { !$0.isEmpty } + queryTokens

        for candidate in candidates {
            guard let range = lowered.range(of: candidate) else { continue }
            let matchStart = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
            let matchEnd = lowered.distance(from: lowered.startIndex, to: range.upperBound)
            let matchCenter = (matchStart + matchEnd) / 2
            let halfWindow = maxCharacters / 2
            let start = max(0, matchCenter - halfWindow)
            let end = min(squashed.count, start + maxCharacters)
            let excerptStart = squashed.index(squashed.startIndex, offsetBy: start)
            let excerptEnd = squashed.index(squashed.startIndex, offsetBy: end)
            let prefix = start > 0 ? "..." : ""
            let suffix = end < squashed.count ? "..." : ""
            let excerpt = String(squashed[excerptStart ..< excerptEnd])
            return prefix + excerpt + suffix
        }

        return preview(for: squashed, maxCharacters: maxCharacters)
    }

    private static func sanitizeAttachmentIds(_ rawIds: [String]) -> [String] {
        var sanitized: [String] = []
        var seen = Set<String>()

        for rawId in rawIds {
            let trimmed = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let data = trimmed.data(using: .utf8),
                let parsed = try? JSONSerialization.jsonObject(with: data) as? [String]
            {
                for nestedId in sanitizeAttachmentIds(parsed) where seen.insert(nestedId).inserted {
                    sanitized.append(nestedId)
                }
                continue
            }

            let matches = trimmed.matches(
                of: /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
            )
            if !matches.isEmpty {
                for match in matches.map(\.output) {
                    let id = String(match)
                    if seen.insert(id).inserted {
                        sanitized.append(id)
                    }
                }
                continue
            }

            let cleaned =
                trimmed
                .replacingOccurrences(of: "<|\\\"|>", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]\"' "))
            if !cleaned.isEmpty, seen.insert(cleaned).inserted {
                sanitized.append(cleaned)
            }
        }

        return sanitized
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }

        var dot: Float = 0
        var lhsMagnitude: Float = 0
        var rhsMagnitude: Float = 0

        for index in lhs.indices {
            let left = lhs[index]
            let right = rhs[index]
            dot += left * right
            lhsMagnitude += left * left
            rhsMagnitude += right * right
        }

        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return dot / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
    }
}
