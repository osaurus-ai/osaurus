//
//  KnowledgeTools.swift
//  osaurus
//
//  Retrieval tools over knowledge collections: `search_knowledge`
//  (hybrid BM25 + vector), `read_knowledge` (full/section document
//  read from the markdown source of truth), and `list_knowledge`
//  (facet browsing).
//
//  Scoping: every call resolves the ACTIVE agent's granted collections
//  via `ChatExecutionContext.currentAgentId` at execution time. The
//  schema strip in `SystemPromptComposer` only hides the tools; the
//  grant list here is the boundary — an agent can never reach a
//  collection it wasn't granted, even via crafted arguments.
//
//  All three tools are read-only: knowledge is human-curated, so no
//  write path is exposed to the model.
//

import Foundation

// MARK: - Shared scope resolution

enum KnowledgeToolScope {
    /// Outcome of resolving the calling agent's grant scope: either the
    /// granted collections or a ready-to-return failure envelope.
    enum Resolution {
        case granted([KnowledgeCollection])
        case failure(envelope: String)
    }

    /// Granted, enabled collections for the calling agent, optionally
    /// narrowed to a named collection. Returns a failure envelope
    /// when the call has no agent context, no grants, or names a
    /// collection outside its grant.
    static func resolve(
        tool: String,
        collectionName: String?
    ) async -> Resolution {
        guard let agentId = ChatExecutionContext.knowledgeAgentId else {
            return .failure(
                envelope: ToolEnvelope.failure(
                    kind: .rejected,
                    message: "Knowledge tools require an active agent context.",
                    tool: tool
                )
            )
        }

        let granted = await MainActor.run {
            AgentManager.shared.effectiveKnowledgeCollections(for: agentId)
        }
        guard !granted.isEmpty else {
            return .failure(
                envelope: ToolEnvelope.failure(
                    kind: .rejected,
                    message: "This agent has no knowledge collections granted.",
                    tool: tool
                )
            )
        }

        guard let collectionName, !collectionName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .granted(granted)
        }

        let trimmed = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = granted.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return .granted([match])
        }
        let names = granted.map(\.name).joined(separator: ", ")
        return .failure(
            envelope: ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Unknown collection `\(trimmed)`. Granted collections: \(names).",
                field: "collection",
                expected: "one of the agent's granted collection names",
                tool: tool
            )
        )
    }

    /// Collection display names keyed by id string, for result formatting.
    static func namesById(_ collections: [KnowledgeCollection]) -> [String: String] {
        var names: [String: String] = [:]
        for collection in collections {
            names[collection.id.uuidString] = collection.name
        }
        return names
    }

    /// The knowledge index opens lazily; a tool call can arrive before
    /// any indexing pass ran. Best-effort open, then report readiness.
    static func ensureDatabaseOpen(tool: String) -> String? {
        if KnowledgeDatabase.shared.isOpen { return nil }
        try? KnowledgeDatabase.shared.open()
        guard KnowledgeDatabase.shared.isOpen else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "Knowledge index is not available.",
                tool: tool,
                retryable: true
            )
        }
        return nil
    }

    /// Case-insensitive ANY-match tag filter against a hit's tag list.
    static func matchesTags(_ tagsCSV: String, filter: [String]) -> Bool {
        guard !filter.isEmpty else { return true }
        let tags = Set(
            tagsCSV.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
        )
        return filter.contains { tags.contains($0.lowercased()) }
    }
}

// MARK: - search_knowledge

final class SearchKnowledgeTool: OsaurusTool, @unchecked Sendable {
    let name = "search_knowledge"
    let description =
        "Search the agent's granted knowledge collections (curated reference "
        + "material: guides, templates, standards). Returns the most relevant "
        + "document excerpts; follow up with `read_knowledge` for a full "
        + "document. Use this when a task needs project/team reference "
        + "material rather than conversation memory."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Natural-language query."),
            ]),
            "collection": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional: restrict to one granted collection by name. Omit to search all granted collections."
                ),
            ]),
            "tags": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Optional: only return documents carrying at least one of these tags."),
            ]),
            "top_k": .object([
                "type": .string("integer"),
                "description": .string("Maximum results to return (default 5, max 25)."),
            ]),
        ]),
        "required": .array([.string("query")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let queryReq = requireString(
            args,
            "query",
            expected: "non-empty natural-language query string",
            tool: name
        )
        guard case .value(let queryRaw) = queryReq else { return queryReq.failureEnvelope ?? "" }
        let query = queryRaw.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `query` must not be whitespace-only.",
                field: "query",
                expected: "non-empty natural-language query string",
                tool: name
            )
        }

        let scope = await KnowledgeToolScope.resolve(
            tool: name,
            collectionName: args["collection"] as? String
        )
        guard case .granted(let collections) = scope else {
            if case .failure(let envelope) = scope { return envelope }
            return ""
        }
        if let envelope = KnowledgeToolScope.ensureDatabaseOpen(tool: name) { return envelope }

        let tagFilter = ((args["tags"] as? [Any]) ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Default 5: enough recall from OR-ranked hits without flooding a
        // small local model's context. Callers can raise it up to 25.
        let topK = max(1, min(25, ArgumentCoercion.int(args["top_k"]) ?? 5))

        // Over-fetch when a tag filter will drop hits post-search.
        let fetchCount = tagFilter.isEmpty ? topK : topK * 3
        let collectionIds = collections.map { $0.id.uuidString }
        let nameById = KnowledgeToolScope.namesById(collections)

        var hits = await KnowledgeSearchService.shared.search(
            query: query,
            collectionIds: collectionIds,
            topK: fetchCount
        )
        if !tagFilter.isEmpty {
            hits = hits.filter { KnowledgeToolScope.matchesTags($0.tagsCSV, filter: tagFilter) }
        }
        hits = Array(hits.prefix(topK))

        if hits.isEmpty {
            let scopeNote = collections.count == 1 ? " in collection '\(collections[0].name)'" : ""
            return ToolEnvelope.success(
                tool: name,
                text: "No knowledge documents match '\(query)'\(scopeNote)."
            )
        }

        var out = "Found \(hits.count) knowledge excerpt(s):\n\n"
        for hit in hits {
            let collectionName = nameById[hit.collectionId] ?? hit.collectionId
            out += "[\(collectionName)] \(hit.relPath)"
            if !hit.title.isEmpty { out += " — \(hit.title)" }
            if !hit.docType.isEmpty { out += " (type: \(hit.docType))" }
            out += "\n"
            if !hit.headingPath.isEmpty { out += "  section: \(hit.headingPath)\n" }
            let preview = hit.content.prefix(400)
            out += "\(preview)\(hit.content.count > 400 ? "…" : "")\n\n"
        }
        out += "Use read_knowledge with a document path for full content."
        return ToolEnvelope.success(tool: name, text: out)
    }
}

// MARK: - read_knowledge

final class ReadKnowledgeTool: OsaurusTool, @unchecked Sendable {
    let name = "read_knowledge"
    let description =
        "Read a document from the agent's granted knowledge collections by "
        + "its relative path (as returned by `search_knowledge` / "
        + "`list_knowledge`). Works for any indexed format — markdown, plain "
        + "text, code, PDF, Word, Excel, PowerPoint, CSV — returning extracted "
        + "text for binary documents. Optionally narrow to one section by heading."

    /// Hard cap on returned content, below the registry's universal cap so
    /// the truncation note survives intact.
    private static let maxContentChars = 24000

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Document path relative to its collection, e.g. `wordpress/plugins.md` or `guides/pricing.pdf`."),
            ]),
            "collection": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional: the collection name. Required only when the same path exists in more than one granted collection."
                ),
            ]),
            "section": .object([
                "type": .string("string"),
                "description": .string("Optional: return only sections whose heading matches this text."),
            ]),
        ]),
        "required": .array([.string("path")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(args, "path", expected: "collection-relative document path", tool: name)
        guard case .value(let pathRaw) = pathReq else { return pathReq.failureEnvelope ?? "" }
        let relPath = pathRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Confinement: the path must stay inside the collection folder.
        guard !relPath.isEmpty, !relPath.hasPrefix("/"), !relPath.hasPrefix("~"),
            !relPath.components(separatedBy: "/").contains("..")
        else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `path` must be a collection-relative path without `..` components.",
                field: "path",
                expected: "relative path inside the collection, e.g. `guides/setup.md`",
                tool: name
            )
        }

        let scope = await KnowledgeToolScope.resolve(
            tool: name,
            collectionName: args["collection"] as? String
        )
        guard case .granted(let collections) = scope else {
            if case .failure(let envelope) = scope { return envelope }
            return ""
        }
        if let envelope = KnowledgeToolScope.ensureDatabaseOpen(tool: name) { return envelope }

        // Locate the document among granted collections via the index.
        var matches: [(collection: KnowledgeCollection, document: KnowledgeDocument)] = []
        for collection in collections {
            if let document = try? KnowledgeDatabase.shared.getDocument(
                collectionId: collection.id.uuidString,
                relPath: relPath
            ) {
                matches.append((collection, document))
            }
        }
        guard let match = matches.first else {
            return ToolEnvelope.failure(
                kind: .notFound,
                message: "No knowledge document at `\(relPath)` in the granted collections.",
                tool: name
            )
        }
        if matches.count > 1 {
            let names = matches.map(\.collection.name).joined(separator: ", ")
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Path `\(relPath)` exists in multiple collections (\(names)). Pass `collection` to disambiguate.",
                field: "collection",
                expected: "one of: \(names)",
                tool: name
            )
        }

        // Read the source of truth from disk, re-checking that the
        // resolved location is inside the collection folder. Markdown is
        // read verbatim; other formats extract through the same document
        // adapters the indexer used.
        let folderURL = match.collection.folderURL.standardizedFileURL
        let fileURL = folderURL.appendingPathComponent(relPath).standardizedFileURL
        let folderPrefix = folderURL.path.hasSuffix("/") ? folderURL.path : folderURL.path + "/"
        guard fileURL.path.hasPrefix(folderPrefix) else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Resolved path escapes the collection folder.",
                tool: name
            )
        }
        let body: String
        if KnowledgeIndexService.isMarkdown(fileURL) {
            guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: "Document `\(relPath)` is indexed but its file is not readable (moved or unmounted?). Re-index the collection.",
                    tool: name,
                    retryable: true
                )
            }
            body = KnowledgeDocumentParser.parse(markdown: raw).body
        } else {
            DocumentAdaptersBootstrap.registerBuiltIns()
            guard let adapter = DocumentFormatRegistry.shared.adapter(for: fileURL),
                let document = try? await adapter.parse(
                    url: fileURL,
                    sizeLimit: Int64(KnowledgeIndexService.maxAdapterFileBytes)
                )
            else {
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: "Document `\(relPath)` is indexed but could not be extracted (moved, unmounted, or corrupted?). Re-index the collection.",
                    tool: name,
                    retryable: true
                )
            }
            body = document.textFallback
        }
        var content = body
        var sectionNote = ""
        if let section = (args["section"] as? String)?.trimmingCharacters(in: .whitespaces),
            !section.isEmpty
        {
            let chunks = KnowledgeDocumentParser.chunk(body: body)
            let matching = chunks.filter {
                $0.headingPath.range(of: section, options: .caseInsensitive) != nil
            }
            guard !matching.isEmpty else {
                let sections = Set(chunks.map(\.headingPath).filter { !$0.isEmpty })
                    .sorted().prefix(30).joined(separator: "; ")
                return ToolEnvelope.failure(
                    kind: .notFound,
                    message: "No section matching `\(section)` in `\(relPath)`. Sections: \(sections)",
                    tool: name
                )
            }
            content = matching.map { "## \($0.headingPath)\n\($0.content)" }.joined(separator: "\n\n")
            sectionNote = " (section: \(section))"
        }

        var truncated = false
        if content.count > Self.maxContentChars {
            content = String(content.prefix(Self.maxContentChars))
            truncated = true
        }

        let document = match.document
        var out = "[\(match.collection.name)] \(relPath)\(sectionNote)\n"
        if !document.title.isEmpty { out += "title: \(document.title)\n" }
        if !document.docType.isEmpty { out += "type: \(document.docType)\n" }
        if !document.tagsCSV.isEmpty { out += "tags: \(document.tagsCSV)\n" }
        out += "\n" + content
        if truncated {
            out += "\n\n[Truncated at \(Self.maxContentChars) characters — use `section` to read a specific part.]"
        }
        return ToolEnvelope.success(tool: name, text: out)
    }
}

// MARK: - list_knowledge

final class ListKnowledgeTool: OsaurusTool, @unchecked Sendable {
    let name = "list_knowledge"
    let description =
        "Browse the agent's granted knowledge collections: list documents "
        + "with their type and tags, optionally filtered. Use to discover "
        + "what reference material exists before searching or reading."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "collection": .object([
                "type": .string("string"),
                "description": .string("Optional: restrict to one granted collection by name."),
            ]),
            "type": .object([
                "type": .string("string"),
                "description": .string("Optional: only documents whose frontmatter `type` matches."),
            ]),
            "tag": .object([
                "type": .string("string"),
                "description": .string("Optional: only documents carrying this tag."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Maximum documents to return (default 50, max 200)."),
            ]),
        ]),
        "required": .array([]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let scope = await KnowledgeToolScope.resolve(
            tool: name,
            collectionName: args["collection"] as? String
        )
        guard case .granted(let collections) = scope else {
            if case .failure(let envelope) = scope { return envelope }
            return ""
        }
        if let envelope = KnowledgeToolScope.ensureDatabaseOpen(tool: name) { return envelope }

        let docType = (args["type"] as? String)?.trimmingCharacters(in: .whitespaces)
        let tag = (args["tag"] as? String)?.trimmingCharacters(in: .whitespaces)
        let limit = max(1, min(200, ArgumentCoercion.int(args["limit"]) ?? 50))

        let documents =
            (try? KnowledgeDatabase.shared.listDocuments(
                collectionIds: collections.map { $0.id.uuidString },
                docType: (docType?.isEmpty == false) ? docType : nil,
                tag: (tag?.isEmpty == false) ? tag : nil,
                limit: limit
            )) ?? []

        if documents.isEmpty {
            return ToolEnvelope.success(
                tool: name,
                text: "No knowledge documents match the filter. The collection may still be indexing."
            )
        }

        let nameById = KnowledgeToolScope.namesById(collections)
        var out = "Found \(documents.count) knowledge document(s):\n\n"
        var currentCollection = ""
        for document in documents {
            let collectionName = nameById[document.collectionId] ?? document.collectionId
            if collectionName != currentCollection {
                currentCollection = collectionName
                out += "Collection: \(collectionName)\n"
            }
            out += "- \(document.relPath)"
            if !document.title.isEmpty { out += " — \(document.title)" }
            var facets: [String] = []
            if !document.docType.isEmpty { facets.append("type: \(document.docType)") }
            if !document.tagsCSV.isEmpty { facets.append("tags: \(document.tagsCSV)") }
            if !facets.isEmpty { out += " (\(facets.joined(separator: "; ")))" }
            out += "\n"
        }
        if documents.count == limit {
            out += "\n[Listing capped at \(limit) — narrow with `type`, `tag`, or `collection`.]"
        }
        return ToolEnvelope.success(tool: name, text: out)
    }
}
