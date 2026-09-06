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
        /// `note` is set when the `collection` argument resolved through an
        /// alias rather than an exact name, so the tool can tell the model
        /// what it actually searched.
        case granted([KnowledgeCollection], note: String? = nil)
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

        // Agent grants, unioned with the active session's project
        // collections. Project knowledge is deliberately independent of the
        // agent's own knowledge opt-in: it belongs to the conversation's
        // project, whichever agent runs it. The grant/union computed here
        // remains the access boundary either way.
        let projectId = ChatExecutionContext.currentProjectId
        let granted = await MainActor.run {
            var collections = AgentManager.shared.effectiveKnowledgeCollections(for: agentId)
            if let projectId,
                let project = ProjectManager.shared.project(for: projectId)
            {
                let known = Set(collections.map(\.id))
                collections += KnowledgeManager.shared
                    .enabledCollections(withIds: project.knowledgeCollectionIds)
                    .filter { !known.contains($0.id) }
            }
            return collections
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
        switch match(collectionName: trimmed, in: granted) {
        case .all:
            let names = granted.map(\.name).joined(separator: ", ")
            return .granted(
                granted,
                note: "`collection: \(trimmed)` is not a collection name; searched all granted "
                    + "collections instead (\(names))."
            )
        case .one(let collection):
            if collection.name.caseInsensitiveCompare(trimmed) == .orderedSame {
                return .granted([collection])
            }
            return .granted(
                [collection],
                note: "`collection: \(trimmed)` resolved to the granted collection "
                    + "`\(collection.name)`; use that exact name in later calls."
            )
        case .unmatched:
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
    }

    /// How a `collection` argument resolved against the granted set.
    enum CollectionMatch: Equatable {
        /// A generic alias that means "the knowledge I was granted" — all
        /// granted collections, exactly as omitting the argument would.
        case all
        case one(KnowledgeCollection)
        case unmatched
    }

    /// Names a model uses for "the knowledge base" when it has not read the
    /// collection's display name off the manifest. Observed live (0.24.7,
    /// Discord): an agent with one granted collection, "Obsidian Vault",
    /// called `list_knowledge {"collection":"knowledge","limit":"20"}` —
    /// `knowledge` is the tool-name stem and the prompt section heading, so
    /// it is the obvious guess. Rejecting it gave the model an error it
    /// answered around with invented counts. None of these can name a real
    /// collection more specifically than "everything I was granted", so
    /// treating them as the omitted argument never widens access: the grant
    /// list computed in `resolve` stays the boundary.
    static let genericCollectionAliases: Set<String> = [
        "knowledge", "knowledge_base", "knowledge-base", "knowledgebase", "knowledge base",
        "kb", "default", "all", "*", "any", "collection", "collections", "granted",
        "project", "docs", "documents", "vault", "library",
    ]

    /// Pure resolution of a `collection` argument against the granted
    /// collections, most specific rule first:
    ///
    /// 1. Exact display-name match (case-insensitive) — the documented form.
    /// 2. A generic alias (`knowledge`, `default`, …) — all granted.
    /// 3. Punctuation/whitespace-insensitive match (`obsidian_vault`,
    ///    `ObsidianVault` → "Obsidian Vault"): models routinely snake-case a
    ///    display name they read off the manifest.
    /// 4. Exactly one collection whose name contains the argument, or vice
    ///    versa (`vault notes` → "Obsidian Vault"), when that is unambiguous.
    /// 5. Exactly one collection granted at all — whatever the model called
    ///    it, this is the only thing it can mean.
    ///
    /// Only rule 1 can ever be the answer when several grants tie, so an
    /// ambiguous name still fails and the failure envelope lists the names.
    static func match(
        collectionName: String,
        in granted: [KnowledgeCollection]
    ) -> CollectionMatch {
        let trimmed = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .all }
        if let exact = granted.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return .one(exact)
        }
        if genericCollectionAliases.contains(trimmed.lowercased()) {
            return .all
        }
        let wanted = normalizedCollectionKey(trimmed)
        if !wanted.isEmpty {
            let normalized = granted.filter { normalizedCollectionKey($0.name) == wanted }
            if normalized.count == 1 { return .one(normalized[0]) }
            let partial = granted.filter {
                let key = normalizedCollectionKey($0.name)
                return !key.isEmpty && (key.contains(wanted) || wanted.contains(key))
            }
            if partial.count == 1 { return .one(partial[0]) }
        }
        if granted.count == 1 { return .one(granted[0]) }
        return .unmatched
    }

    /// Lowercased alphanumerics only, so `Obsidian Vault`, `obsidian_vault`,
    /// `obsidian-vault` and `ObsidianVault` all key the same.
    static func normalizedCollectionKey(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
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

    /// Cancellation audit: the body is bounded local retrieval — one query
    /// embedding plus a hybrid Vectura/SQLite lookup capped at `top_k` — with
    /// no external processes or detached work; it terminates promptly on its
    /// own, so an owning spawned run drains it within that bounded window.
    var canExposeToSpawnedOperation: Bool { true }

    func spawnedOperationCancellationSupport(
        argumentsJSON _: String
    ) -> SpawnedOperationCancellationSupport {
        .cooperative
    }

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

        KnowledgeDebugLog.log("search_knowledge", "ENTER query=\(query.prefix(80))")
        let t0 = KnowledgeDebugLog.now()

        KnowledgeDebugLog.log("search_knowledge", "resolving agent grant scope")
        let scope = await KnowledgeToolScope.resolve(
            tool: name,
            collectionName: args["collection"] as? String
        )
        guard case .granted(let collections, let aliasNote) = scope else {
            KnowledgeDebugLog.log("search_knowledge", "scope resolution failed/rejected; returning")
            if case .failure(let envelope) = scope { return envelope }
            return ""
        }
        KnowledgeDebugLog.log(
            "search_knowledge",
            "scope granted: \(collections.count) collection(s) in \(KnowledgeDebugLog.ms(since: t0))ms"
        )
        KnowledgeDebugLog.log("search_knowledge", "ensureDatabaseOpen")
        if let envelope = KnowledgeToolScope.ensureDatabaseOpen(tool: name) {
            KnowledgeDebugLog.log("search_knowledge", "database unavailable; returning")
            return envelope
        }

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

        KnowledgeDebugLog.log(
            "search_knowledge",
            "calling KnowledgeSearchService.search topK=\(fetchCount) collections=\(collectionIds.count)"
        )
        let tSearch = KnowledgeDebugLog.now()
        var hits = await KnowledgeSearchService.shared.search(
            query: query,
            collectionIds: collectionIds,
            topK: fetchCount
        )
        KnowledgeDebugLog.log(
            "search_knowledge",
            "search returned \(hits.count) hit(s) in \(KnowledgeDebugLog.ms(since: tSearch))ms "
                + "(total \(KnowledgeDebugLog.ms(since: t0))ms)"
        )
        if !tagFilter.isEmpty {
            hits = hits.filter { KnowledgeToolScope.matchesTags($0.tagsCSV, filter: tagFilter) }
        }
        hits = Array(hits.prefix(topK))

        if hits.isEmpty {
            let scopeNote = collections.count == 1 ? " in collection '\(collections[0].name)'" : ""
            // A collection mid-index has an incomplete corpus, so an empty
            // result may be transient. Tell the model to retry rather than
            // conclude the material doesn't exist.
            let indexing = await MainActor.run {
                collections.contains { KnowledgeManager.shared.indexingCollectionIds.contains($0.id) }
            }
            if indexing {
                return ToolEnvelope.success(
                    tool: name,
                    text: "No matches for '\(query)' yet\(scopeNote) — this collection is still "
                        + "indexing, so its content is not fully searchable. Retry in a moment."
                )
            }
            return ToolEnvelope.success(
                tool: name,
                text: "No knowledge documents match '\(query)'\(scopeNote).",
                warnings: aliasNote.map { [$0] }
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
        return ToolEnvelope.success(tool: name, text: out, warnings: aliasNote.map { [$0] })
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

    /// Cancellation audit: bounded local reads — SQLite index lookups plus
    /// one capped (`maxContentChars`) file/extracted-text read inside the
    /// collection folder. No network, no external processes, no detached
    /// work; the body terminates promptly and drains trivially.
    var canExposeToSpawnedOperation: Bool { true }

    func spawnedOperationCancellationSupport(
        argumentsJSON _: String
    ) -> SpawnedOperationCancellationSupport {
        .cooperative
    }

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
        guard case .granted(let collections, let aliasNote) = scope else {
            if case .failure(let envelope) = scope { return envelope }
            return ""
        }
        if let envelope = KnowledgeToolScope.ensureDatabaseOpen(tool: name) { return envelope }

        // Locate the document among granted collections via the index.
        var matches: [(collection: KnowledgeCollection, document: KnowledgeDocument)] = []
        var effectivePath = relPath
        for collection in collections {
            if let document = try? KnowledgeDatabase.shared.getDocument(
                collectionId: collection.id.uuidString,
                relPath: relPath
            ) {
                matches.append((collection, document))
            }
        }
        // Search/list results are printed as `[Collection Name] path`, so
        // models routinely join them into `Collection Name/path`. Accept that
        // form: when the exact path missed and its first segment names a
        // granted collection, retry the remainder inside that collection
        // (#2279 — small models retried the joined form five times and never
        // recovered from the bare not-found).
        if matches.isEmpty, let slash = relPath.firstIndex(of: "/") {
            let head = String(relPath[..<slash]).trimmingCharacters(in: .whitespaces)
            let rest = String(relPath[relPath.index(after: slash)...])
                .trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty,
                let collection = collections.first(where: {
                    $0.name.caseInsensitiveCompare(head) == .orderedSame
                }),
                let document = try? KnowledgeDatabase.shared.getDocument(
                    collectionId: collection.id.uuidString,
                    relPath: rest
                )
            {
                matches.append((collection, document))
                effectivePath = rest
            }
        }
        guard let match = matches.first else {
            let granted = collections.map(\.name).joined(separator: ", ")
            return ToolEnvelope.failure(
                kind: .notFound,
                message:
                    "No knowledge document at `\(relPath)` in the granted collections. "
                    + "`path` is relative to a collection (do not prefix the collection name); "
                    + "pass the collection separately via `collection`. "
                    + "Granted collections: \(granted). Use list_knowledge to see document paths.",
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
        let fileURL = folderURL.appendingPathComponent(effectivePath).standardizedFileURL
        let folderPrefix = folderURL.path.hasSuffix("/") ? folderURL.path : folderURL.path + "/"
        guard fileURL.path.hasPrefix(folderPrefix) else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Resolved path escapes the collection folder.",
                tool: name
            )
        }
        let body: String
        var extraFields: [KnowledgeFrontmatterField] = []
        if KnowledgeIndexService.isMarkdown(fileURL) {
            guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: "Document `\(relPath)` is indexed but its file is not readable (moved or unmounted?). Re-index the collection.",
                    tool: name,
                    retryable: true
                )
            }
            let parsed = KnowledgeDocumentParser.parse(markdown: raw)
            body = parsed.body
            extraFields = parsed.frontmatter.extras
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
                let sectionList = Set(chunks.map(\.headingPath).filter { !$0.isEmpty })
                    .sorted().prefix(30).joined(separator: "; ")
                // A document with no headings at all (e.g. source code or a
                // flat text file) can never match a section. Say so and tell
                // the model to drop `section` — otherwise it loops re-issuing
                // the same doomed call against an empty section list.
                guard !sectionList.isEmpty else {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "`\(relPath)` has no headings, so it can't be filtered by "
                            + "`section`. Re-read it without the `section` argument to get "
                            + "the full document.",
                        field: "section",
                        expected: "omit `section` for documents without headings",
                        tool: name
                    )
                }
                return ToolEnvelope.failure(
                    kind: .notFound,
                    message: "No section matching `\(section)` in `\(relPath)`. Sections: \(sectionList)",
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
        var out = "[\(match.collection.name)] \(effectivePath)\(sectionNote)\n"
        if !document.title.isEmpty { out += "title: \(document.title)\n" }
        if !document.effectiveType.isEmpty {
            out += "type: \(document.effectiveType)\(document.isTypeInferred ? " (inferred)" : "")\n"
        }
        if !document.tagsCSV.isEmpty { out += "tags: \(document.tagsCSV)\n" }
        // Non-reserved frontmatter (e.g. `status`, `sensitivity`) is not
        // indexed, but is passed through so agents can read and honor it.
        for field in extraFields {
            out += "\(field.key): \(field.value.replacingOccurrences(of: "\n", with: "\n  "))\n"
        }
        out += "\n" + content
        if truncated {
            out += "\n\n[Truncated at \(Self.maxContentChars) characters — use `section` to read a specific part.]"
        }
        return ToolEnvelope.success(tool: name, text: out, warnings: aliasNote.map { [$0] })
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
                "description": .string(
                    "Maximum documents to return per call (default \(ListKnowledgeTool.defaultLimit), "
                        + "max \(ListKnowledgeTool.maxLimit)). The result reports the TOTAL matching "
                        + "count and a `next_offset` when more remain."
                ),
            ]),
            "offset": .object([
                "type": .string("integer"),
                "description": .string(
                    "Skip this many documents (default 0). Pass the previous result's "
                        + "`next_offset` to page through a listing larger than `limit`."
                ),
            ]),
        ]),
        "required": .array([]),
    ])

    /// Default page size. Raised from 50: a model asked to summarise a
    /// collection needs the whole listing, and at ~80 characters a row 100
    /// entries is ~8KB (~2K tokens) — well under the registry's 100K-char
    /// universal cap, and the same order as one `file_read`. Larger
    /// collections page via `offset`.
    static let defaultLimit = 100
    /// Hard per-call ceiling, matching `ToolOutputCaps.searchMaxResults`
    /// (`file_search`). Rows past it are reachable through `offset`, never
    /// silently dropped.
    static let maxLimit = ToolOutputCaps.searchMaxResults

    /// Effective page size for a raw `limit` argument: coerced from a
    /// numeric string (quantized models send `"20"`), defaulted, clamped.
    static func effectiveLimit(_ raw: Any?) -> Int {
        max(1, min(maxLimit, ArgumentCoercion.int(raw) ?? defaultLimit))
    }

    /// Effective start row for a raw `offset` argument: coerced, default 0,
    /// never negative, never past what the SQLite OFFSET binding can carry
    /// (`Int32.max`; a larger value used to narrow with "Not enough bits").
    static func effectiveOffset(_ raw: Any?) -> Int {
        min(max(0, ArgumentCoercion.int(raw) ?? 0), Int(Int32.max))
    }

    /// Cancellation audit: one capped (`limit` ≤ `maxLimit`) SQLite listing over the
    /// granted collections — no network, no external processes, no detached
    /// work; the body terminates promptly and drains trivially.
    var canExposeToSpawnedOperation: Bool { true }

    func spawnedOperationCancellationSupport(
        argumentsJSON _: String
    ) -> SpawnedOperationCancellationSupport {
        .cooperative
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let scope = await KnowledgeToolScope.resolve(
            tool: name,
            collectionName: args["collection"] as? String
        )
        guard case .granted(let collections, let aliasNote) = scope else {
            if case .failure(let envelope) = scope { return envelope }
            return ""
        }
        if let envelope = KnowledgeToolScope.ensureDatabaseOpen(tool: name) { return envelope }

        let docType = (args["type"] as? String)?.trimmingCharacters(in: .whitespaces)
        let tag = (args["tag"] as? String)?.trimmingCharacters(in: .whitespaces)
        let limit = Self.effectiveLimit(args["limit"])
        let offset = Self.effectiveOffset(args["offset"])
        let collectionIds = collections.map { $0.id.uuidString }
        let effectiveType = (docType?.isEmpty == false) ? docType : nil
        let effectiveTag = (tag?.isEmpty == false) ? tag : nil

        // Total BEFORE the page, so a capped page can still state how many
        // documents exist (the old "[Listing capped at N]" footer gave the
        // model no total and no way to fetch the rest, so a summary of a
        // 300-note vault silently became a summary of its first 50 rows).
        let total =
            (try? KnowledgeDatabase.shared.countDocuments(
                collectionIds: collectionIds,
                docType: effectiveType,
                tag: effectiveTag
            )) ?? 0
        let documents =
            (try? KnowledgeDatabase.shared.listDocuments(
                collectionIds: collectionIds,
                docType: effectiveType,
                tag: effectiveTag,
                limit: limit,
                offset: offset
            )) ?? []

        if documents.isEmpty, offset > 0, total > 0 {
            return ToolEnvelope.success(
                tool: name,
                text: "No documents at offset \(offset): the listing has \(total) document(s) "
                    + "in total (offsets 0–\(total - 1)). Re-issue with a smaller `offset`.",
                warnings: aliasNote.map { [$0] }
            )
        }

        if documents.isEmpty {
            // The old text blamed indexing unconditionally. That is a lie in
            // the common case and an expensive one: in osaurus#2439 an agent
            // read "may still be indexing" off a collection that was simply
            // empty and waited on it for forty minutes, re-running the same
            // listing. Only claim indexing when the collection really is
            // mid-index — the check `search_knowledge` already makes.
            let scopeNote = collections.count == 1 ? " in collection '\(collections[0].name)'" : ""
            let indexing = await MainActor.run {
                collections.contains { KnowledgeManager.shared.indexingCollectionIds.contains($0.id) }
            }
            if indexing {
                return ToolEnvelope.success(
                    tool: name,
                    text: "No knowledge documents listed yet\(scopeNote) — this collection is still "
                        + "indexing, so its contents are incomplete. Retry in a moment.",
                    warnings: aliasNote.map { [$0] }
                )
            }
            let hasFilter = (docType?.isEmpty == false) || (tag?.isEmpty == false)
            if hasFilter {
                var facets: [String] = []
                if let docType, !docType.isEmpty { facets.append("type '\(docType)'") }
                if let tag, !tag.isEmpty { facets.append("tag '\(tag)'") }
                return ToolEnvelope.success(
                    tool: name,
                    text: "No knowledge documents match \(facets.joined(separator: " and "))"
                        + "\(scopeNote). Other documents may exist; list without the filter to see them.",
                    warnings: aliasNote.map { [$0] }
                )
            }
            let subject =
                collections.count == 1
                ? "Collection '\(collections[0].name)' is empty" : "These collections are empty"
            return ToolEnvelope.success(
                tool: name,
                // Naming the real write path matters as much as denying the
                // indexing excuse: an agent told only "this is empty" with no
                // route forward is what invented `<agent home>/knowledge/`.
                text: "\(subject) — no documents at all. This is not an indexing delay, so "
                    + "waiting will not change it. Add documents with `write_knowledge`; writing "
                    + "files to a path never puts them in a collection.",
                warnings: aliasNote.map { [$0] }
            )
        }

        let nameById = KnowledgeToolScope.namesById(collections)
        var out = Self.listingHeader(total: total, returned: documents.count, offset: offset) + "\n\n"
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
            if !document.effectiveType.isEmpty {
                facets.append(
                    "type: \(document.effectiveType)\(document.isTypeInferred ? " (inferred)" : "")")
            }
            if !document.tagsCSV.isEmpty { facets.append("tags: \(document.tagsCSV)") }
            if !facets.isEmpty { out += " (\(facets.joined(separator: "; ")))" }
            out += "\n"
        }
        if let footer = Self.listingFooter(
            total: total, returned: documents.count, offset: offset, limit: limit
        ) {
            out += "\n" + footer
        }
        return ToolEnvelope.success(tool: name, text: out, warnings: aliasNote.map { [$0] })
    }

    /// "Found 312 knowledge document(s); showing 1–100" — the total is
    /// stated up front so a model summarising the collection never mistakes
    /// one page for the whole.
    static func listingHeader(total: Int, returned: Int, offset: Int) -> String {
        guard total > returned || offset > 0 else {
            return "Found \(total) knowledge document(s):"
        }
        let first = offset + 1
        let last = offset + returned
        return "Found \(total) knowledge document(s) in total; showing \(first)–\(last) (offset \(offset)):"
    }

    /// Paging footer, or nil when the page held everything. Names the exact
    /// `offset` for the next call so the model can page without arithmetic.
    static func listingFooter(total: Int, returned: Int, offset: Int, limit: Int) -> String? {
        let next = offset + returned
        guard next < total else { return nil }
        let remaining = total - next
        return "[total=\(total), returned=\(returned), next_offset=\(next) — \(remaining) more document(s). "
            + "Call list_knowledge again with `offset: \(next)` (and the same `limit`/filters) to continue, "
            + "or narrow with `type`, `tag`, or `collection`.]"
    }
}
