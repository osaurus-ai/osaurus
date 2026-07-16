//
//  KnowledgeCurationTools.swift
//  osaurus
//
//  Curation-loop tools over knowledge collections:
//    `flag_knowledge_stale`     — file a staleness ticket (annotation
//                                 only; available to any agent with
//                                 knowledge grants)
//    `list_knowledge_tickets`   — browse tickets in the granted scope
//    `propose_knowledge_update` — draft a replacement document as a
//                                 pending proposal (curator agents only,
//                                 `.ask` policy). The corpus is NEVER
//                                 written by a tool: proposals wait for
//                                 human approval in the Knowledge tab.
//
//  Scoping matches the retrieval tools: grants resolve from the calling
//  agent at execution time via `KnowledgeToolScope`.
//

import Foundation

extension Notification.Name {
    /// Posted after a ticket or proposal mutation so the Knowledge tab
    /// review UI can refresh.
    public static let knowledgeCurationChanged = Notification.Name("knowledgeCurationChanged")
}

private func postCurationChanged() {
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .knowledgeCurationChanged, object: nil)
    }
}

// MARK: - flag_knowledge_stale

final class FlagKnowledgeStaleTool: OsaurusTool, @unchecked Sendable {
    let name = "flag_knowledge_stale"
    // NOTE: compact-prompt models only see the FIRST sentence of this
    // description (`oneLineToolDescription`, ≤180 chars) — the routing
    // rule ("update request ⇒ file a ticket") must live there, not in a
    // follow-up sentence (live-observed miss with Ornith-1.0-9B).
    let description =
        "File a staleness ticket to start an update to a knowledge document "
        + "— the required first step for ANY update request, since "
        + "collection files cannot be edited directly. Use it when the user "
        + "reports a change or asks for an update, and when you discover "
        + "outdated content yourself (changed APIs, superseded practices, "
        + "broken references). It only records the report; a curator "
        + "follows up on open tickets."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Document path relative to its collection, e.g. `wordpress/plugins.md`."),
            ]),
            "reason": .object([
                "type": .string("string"),
                "description": .string("Why the document appears stale, in one or two sentences."),
            ]),
            "evidence": .object([
                "type": .string("string"),
                "description": .string("Optional: what you observed (error output, release notes, contradicting source)."),
            ]),
            "collection": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional: the collection name. Required only when the same path exists in more than one granted collection."
                ),
            ]),
        ]),
        "required": .array([.string("path"), .string("reason")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(args, "path", expected: "collection-relative document path", tool: name)
        guard case .value(let pathRaw) = pathReq else { return pathReq.failureEnvelope ?? "" }
        let relPath = pathRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let envelope = KnowledgeCurationToolSupport.validateRelPath(relPath, tool: name) {
            return envelope
        }

        let reasonReq = requireString(args, "reason", expected: "short explanation of the suspected drift", tool: name)
        guard case .value(let reasonRaw) = reasonReq else { return reasonReq.failureEnvelope ?? "" }
        let reason = reasonRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `reason` must not be whitespace-only.",
                field: "reason",
                expected: "short explanation of the suspected drift",
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

        // The ticket must target a real, granted document.
        let located = KnowledgeCurationToolSupport.locateDocument(
            relPath: relPath,
            in: collections,
            tool: name
        )
        guard case .success(let match) = located else {
            if case .failure(let envelope) = located { return envelope }
            return ""
        }
        let collectionId = match.collection.id.uuidString

        // Dedupe: one open ticket per document is enough signal.
        if let existing = try? KnowledgeDatabase.shared.openTicket(
            collectionId: collectionId,
            relPath: relPath
        ) {
            return ToolEnvelope.success(
                tool: name,
                text:
                    "Ticket #\(existing.id) is already open for `\(relPath)` "
                    + "(reason: \(existing.reason)). No duplicate filed."
            )
        }

        let evidence = ((args["evidence"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let createdBy = ChatExecutionContext.knowledgeAgentId?.uuidString ?? ""
        do {
            let ticketId = try KnowledgeDatabase.shared.createTicket(
                collectionId: collectionId,
                relPath: relPath,
                reason: reason,
                evidence: evidence,
                createdBy: createdBy
            )
            postCurationChanged()
            return ToolEnvelope.success(
                tool: name,
                text:
                    "Filed ticket #\(ticketId) against [\(match.collection.name)] \(relPath). "
                    + "A curator will review it; the document is unchanged."
            )
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Could not file the ticket: \(error.localizedDescription)",
                tool: name,
                retryable: true
            )
        }
    }
}

// MARK: - list_knowledge_tickets

final class ListKnowledgeTicketsTool: OsaurusTool, @unchecked Sendable {
    let name = "list_knowledge_tickets"
    let description =
        "List staleness tickets for the agent's granted knowledge "
        + "collections. Check `open` tickets before flagging (duplicates "
        + "are rejected) or when working a curation queue."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "collection": .object([
                "type": .string("string"),
                "description": .string("Optional: restrict to one granted collection by name."),
            ]),
            "status": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("open"),
                    .string("in_progress"),
                    .string("proposed"),
                    .string("resolved"),
                    .string("dismissed"),
                ]),
                "description": .string("Optional: filter by ticket status (default: open)."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Maximum tickets to return (default 25, max 100)."),
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

        let statusRaw = ((args["status"] as? String) ?? "open").lowercased()
        guard let status = KnowledgeTicketStatus(rawValue: statusRaw) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Unknown status `\(statusRaw)`.",
                field: "status",
                expected: "one of open|in_progress|proposed|resolved|dismissed",
                tool: name
            )
        }
        let limit = max(1, min(100, ArgumentCoercion.int(args["limit"]) ?? 25))

        let tickets =
            (try? KnowledgeDatabase.shared.listTickets(
                collectionIds: collections.map { $0.id.uuidString },
                status: status,
                limit: limit
            )) ?? []

        if tickets.isEmpty {
            return ToolEnvelope.success(
                tool: name,
                text: "No \(status.rawValue) knowledge tickets in the granted collections."
            )
        }

        let nameById = KnowledgeToolScope.namesById(collections)
        var out = "Found \(tickets.count) \(status.rawValue) ticket(s):\n\n"
        for ticket in tickets {
            let collectionName = nameById[ticket.collectionId] ?? ticket.collectionId
            out += "#\(ticket.id) [\(collectionName)] \(ticket.relPath)\n"
            out += "  reason: \(ticket.reason)\n"
            if !ticket.evidence.isEmpty {
                let preview = ticket.evidence.prefix(200)
                out += "  evidence: \(preview)\(ticket.evidence.count > 200 ? "…" : "")\n"
            }
            out += "  filed: \(ticket.createdAt.prefix(10))\n\n"
        }
        return ToolEnvelope.success(tool: name, text: out)
    }
}

// MARK: - update_knowledge_ticket

final class UpdateKnowledgeTicketTool: OsaurusTool, @unchecked Sendable {
    let name = "update_knowledge_ticket"
    let description =
        "Claim or release a staleness ticket while working a curation "
        + "queue. Set `in_progress` before researching a ticket so other "
        + "scheduled runs skip it, or `open` to release one you cannot finish. "
        + "Curator agents only; resolution happens via proposal approval, "
        + "not this tool."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "ticket_id": .object([
                "type": .string("integer"),
                "description": .string("The ticket to update."),
            ]),
            "status": .object([
                "type": .string("string"),
                "enum": .array([.string("in_progress"), .string("open")]),
                "description": .string("`in_progress` to claim, `open` to release."),
            ]),
        ]),
        "required": .array([.string("ticket_id"), .string("status")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        guard let ticketId = ArgumentCoercion.int(args["ticket_id"]) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `ticket_id` must be an integer.",
                field: "ticket_id",
                expected: "an existing ticket id",
                tool: name
            )
        }
        let statusRaw = ((args["status"] as? String) ?? "").lowercased()
        guard let newStatus = KnowledgeTicketStatus(rawValue: statusRaw),
            newStatus == .inProgress || newStatus == .open
        else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `status` must be `in_progress` or `open`.",
                field: "status",
                expected: "in_progress|open",
                tool: name
            )
        }

        // Curator gate at execution time, same as propose.
        guard let agentId = ChatExecutionContext.knowledgeAgentId else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Knowledge tools require an active agent context.",
                tool: name
            )
        }
        let isCurator = await MainActor.run {
            AgentManager.shared.effectiveCapabilities(for: agentId).knowledgeCuratorEnabled
        }
        guard isCurator else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "This agent is not a knowledge curator.",
                tool: name
            )
        }

        let scope = await KnowledgeToolScope.resolve(tool: name, collectionName: nil)
        guard case .granted(let collections) = scope else {
            if case .failure(let envelope) = scope { return envelope }
            return ""
        }
        if let envelope = KnowledgeToolScope.ensureDatabaseOpen(tool: name) { return envelope }

        guard let ticket = try? KnowledgeDatabase.shared.getTicket(id: ticketId),
            collections.contains(where: { $0.id.uuidString == ticket.collectionId })
        else {
            return ToolEnvelope.failure(
                kind: .notFound,
                message: "No ticket #\(ticketId) in the granted collections.",
                field: "ticket_id",
                tool: name
            )
        }

        // Only the open ↔ in_progress transitions are agent-drivable;
        // proposed/resolved/dismissed belong to the review flow.
        let allowed: Bool =
            (ticket.status == .open && newStatus == .inProgress)
            || (ticket.status == .inProgress && newStatus == .open)
        guard allowed else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "Ticket #\(ticketId) is `\(ticket.status.rawValue)`; only open tickets can be claimed and only in_progress tickets released.",
                tool: name
            )
        }

        do {
            try KnowledgeDatabase.shared.updateTicketStatus(id: ticketId, status: newStatus)
            postCurationChanged()
            let verb = newStatus == .inProgress ? "claimed" : "released"
            return ToolEnvelope.success(tool: name, text: "Ticket #\(ticketId) \(verb).")
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Could not update the ticket: \(error.localizedDescription)",
                tool: name,
                retryable: true
            )
        }
    }
}

// MARK: - propose_knowledge_update

final class ProposeKnowledgeUpdateTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name = "propose_knowledge_update"
    let description =
        "Draft a full replacement for a knowledge document (or a new "
        + "document) as a PENDING proposal. The collection is never "
        + "modified directly — the user reviews and approves proposals in "
        + "the Knowledge tab. Curator agents only. Pass the complete new "
        + "markdown, not a diff. Keep the document's existing frontmatter "
        + "(type, title, tags) unless the change is specifically about it."

    /// Proposals are drafts, but they queue a corpus mutation for
    /// approval — keep the human in the loop at call time too.
    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }

    /// Hard cap on proposal content, aligned with the indexer's
    /// oversized-file skip so an approved proposal stays indexable.
    private static let maxContentBytes = 2 * 1024 * 1024

    /// A curator that *read* the document first received it wrapped in
    /// `read_knowledge`'s framing header — a `[Collection] path` line followed
    /// by optional `title:`/`type:`/`tags:` lines and a blank separator. Weaker
    /// models copy that header verbatim into their replacement content, which an
    /// approval would then persist above the real body. Strip a leading framing
    /// block so the leaked preamble never reaches disk. Conservative: only fires
    /// when the first non-blank line is a bracketed name followed by ` ` (real
    /// document bodies open with `#`, `---`, or prose, not `[name] …`).
    static func strippingReadPreamble(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        var start = 0
        while start < lines.count, lines[start].trimmingCharacters(in: .whitespaces).isEmpty {
            start += 1
        }
        guard start < lines.count else { return content }
        let header = lines[start]
        guard header.hasPrefix("["), let close = header.firstIndex(of: "]") else { return content }
        let inside = header[header.index(after: header.startIndex)..<close]
        let afterClose = header.index(after: close)
        guard !inside.trimmingCharacters(in: .whitespaces).isEmpty,
            afterClose < header.endIndex, header[afterClose] == " "
        else { return content }
        var i = start + 1
        while i < lines.count,
            lines[i].hasPrefix("title: ") || lines[i].hasPrefix("type: ") || lines[i].hasPrefix("tags: ")
        {
            i += 1
        }
        if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            i += 1
        }
        lines.removeSubrange(0..<i)
        return lines.joined(separator: "\n")
    }

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Document path relative to its collection. May be a new path to propose a new document."
                ),
            ]),
            "new_content": .object([
                "type": .string("string"),
                "description": .string("The complete replacement markdown, including frontmatter if any."),
            ]),
            "rationale": .object([
                "type": .string("string"),
                "description": .string("Why this update is needed and what changed."),
            ]),
            "ticket_id": .object([
                "type": .string("integer"),
                "description": .string("Optional: the staleness ticket this proposal answers."),
            ]),
            "collection": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional: the collection name. Required for a new path when more than one collection is granted."
                ),
            ]),
        ]),
        "required": .array([.string("path"), .string("new_content"), .string("rationale")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        // Resolve an optional linked ticket up front. It is the authoritative
        // source for the target path (and a usable rationale) when a weak model
        // fumbles those arguments but still passes the `ticket_id` it is
        // answering — a common failure mode with small local models that mangle
        // tool-call JSON.
        let ticketArg = ArgumentCoercion.int(args["ticket_id"])
        var linkedTicket: KnowledgeTicket?
        if let ticketArg {
            try? KnowledgeDatabase.shared.open()
            linkedTicket = try? KnowledgeDatabase.shared.getTicket(id: ticketArg)
        }

        // `path`: prefer the argument; fall back to the linked ticket's target.
        let pathArg = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let relPath = (pathArg?.isEmpty == false ? pathArg : linkedTicket?.relPath) ?? ""
        guard !relPath.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Missing required property: path. Pass the collection-relative .md path, "
                    + "or a `ticket_id` whose document should be updated.",
                field: "path",
                expected: "a collection-relative .md path",
                tool: name
            )
        }
        if let envelope = KnowledgeCurationToolSupport.validateRelPath(relPath, tool: name) {
            return envelope
        }
        let relPathExtension = (relPath as NSString).pathExtension.lowercased()
        guard KnowledgeIndexService.markdownExtensions.contains(relPathExtension) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Proposals must target a markdown document (`.md`).",
                field: "path",
                expected: "a path ending in .md",
                tool: name
            )
        }

        let contentReq = requireString(args, "new_content", expected: "complete replacement markdown", tool: name)
        guard case .value(let newContent) = contentReq else { return contentReq.failureEnvelope ?? "" }
        guard !newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `new_content` must not be empty. To remove a document, say so in a ticket instead.",
                field: "new_content",
                expected: "complete replacement markdown",
                tool: name
            )
        }
        guard newContent.utf8.count <= Self.maxContentBytes else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Proposal content exceeds \(Self.maxContentBytes) bytes.",
                field: "new_content",
                tool: name
            )
        }

        // `rationale`: prefer the argument; fall back to the ticket's reason so a
        // proposal answering a ticket still records why, even when the model
        // dropped the field.
        let rationaleArg = (args["rationale"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rationale: String
        if let rationaleArg, !rationaleArg.isEmpty {
            rationale = rationaleArg
        } else if let linkedTicket {
            rationale = "Addresses ticket #\(linkedTicket.id): \(linkedTicket.reason)"
        } else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Missing required property: rationale. Explain why this update is needed, "
                    + "or pass a `ticket_id` to inherit its reason.",
                field: "rationale",
                expected: "why this update is needed",
                tool: name
            )
        }

        // Curator gate at execution time — the schema strip is not the boundary.
        guard let agentId = ChatExecutionContext.knowledgeAgentId else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "Knowledge tools require an active agent context.",
                tool: name
            )
        }
        let isCurator = await MainActor.run {
            AgentManager.shared.effectiveCapabilities(for: agentId).knowledgeCuratorEnabled
        }
        guard isCurator else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "This agent is not a knowledge curator. Use flag_knowledge_stale to report drift instead.",
                tool: name
            )
        }

        // Resolve to the FULL granted set. The `collection` argument is not
        // applied at this stage: for an existing document the `path` pins the
        // collection, so a mismatched hint — e.g. the model passing the doc's
        // human title ("Acme Knowledge Base") instead of the collection name
        // ("Sample Knowledge") — must not hard-fail the call and cost a wasted
        // approval + retry. The hint is validated below, only where it can
        // actually disambiguate (a new or path-ambiguous document).
        let scope = await KnowledgeToolScope.resolve(tool: name, collectionName: nil)
        guard case .granted(let collections) = scope else {
            if case .failure(let envelope) = scope { return envelope }
            return ""
        }
        if let envelope = KnowledgeToolScope.ensureDatabaseOpen(tool: name) { return envelope }

        let collectionHint = (args["collection"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Resolve the target collection: an existing document pins it; a
        // new or ambiguous path falls back to the `collection` hint.
        // Drop any read_knowledge framing header the model copied into the
        // draft before it becomes the proposal body.
        let cleanContent = Self.strippingReadPreamble(newContent)
        let collectionId: String
        let collectionName: String
        var proposalContent = cleanContent
        switch KnowledgeCurationToolSupport.locateDocument(relPath: relPath, in: collections, tool: name) {
        case .success(let match):
            collectionId = match.collection.id.uuidString
            collectionName = match.collection.name
            // Guard against a rewrite silently dropping the document's
            // frontmatter (type/title/tags): if the draft carries none but the
            // existing document has it, re-attach the original block so an
            // approved curation can't degrade the doc's OKF classification. A
            // draft that DOES carry frontmatter is left as-is, so an intentional
            // metadata change still applies.
            let draftHasFrontmatter =
                Skill.splitFrontmatter(cleanContent)?.frontmatterLines.isEmpty == false
            if !draftHasFrontmatter {
                let fileURL = match.collection.folderURL.appendingPathComponent(relPath)
                if let existing = try? String(contentsOf: fileURL, encoding: .utf8),
                    let split = Skill.splitFrontmatter(existing),
                    !split.frontmatterLines.isEmpty
                {
                    proposalContent =
                        "---\n" + split.frontmatterLines.joined(separator: "\n") + "\n---\n\n"
                        + cleanContent
                }
            }
        case .failure(let envelope):
            // Not a single existing doc. Narrow by the hint when given; an
            // unknown hint is a real error here since it can't pin anything.
            let candidates: [KnowledgeCollection]
            if let collectionHint, !collectionHint.isEmpty {
                guard
                    let match = collections.first(where: {
                        $0.name.caseInsensitiveCompare(collectionHint) == .orderedSame
                    })
                else {
                    let names = collections.map(\.name).joined(separator: ", ")
                    return ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "Unknown collection `\(collectionHint)`. Granted collections: \(names).",
                        field: "collection",
                        expected: "one of the agent's granted collection names",
                        tool: name
                    )
                }
                candidates = [match]
            } else {
                candidates = collections
            }

            if candidates.count == 1 {
                // New document in the single resolved collection.
                collectionId = candidates[0].id.uuidString
                collectionName = candidates[0].name
            } else if envelope.contains("multiple collections") {
                return envelope
            } else {
                let names = candidates.map(\.name).joined(separator: ", ")
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "`\(relPath)` is a new document and multiple collections are granted (\(names)). Pass `collection` to pick one.",
                    field: "collection",
                    expected: "one of: \(names)",
                    tool: name
                )
            }
        }

        // Optional ticket link: must exist and belong to the resolved
        // collection. Reuses the ticket fetched up front for the path/rationale
        // fallback.
        var ticketId: Int?
        if let ticketArg {
            guard let ticket = linkedTicket, ticket.collectionId == collectionId else {
                return ToolEnvelope.failure(
                    kind: .notFound,
                    message: "No ticket #\(ticketArg) in collection `\(collectionName)`.",
                    field: "ticket_id",
                    tool: name
                )
            }
            ticketId = ticketArg
        } else if let openMatch = (try? KnowledgeDatabase.shared.listTickets(
            collectionIds: [collectionId], status: .open))?
            .first(where: { $0.relPath == relPath })
        {
            // Model omitted `ticket_id` (a common local-model miss): auto-link an
            // open ticket targeting this same document so approving the proposal
            // resolves the drift report instead of leaving it stranded.
            ticketId = openMatch.id
        }

        do {
            let proposalId = try KnowledgeDatabase.shared.createProposal(
                ticketId: ticketId,
                collectionId: collectionId,
                relPath: relPath,
                newContent: proposalContent,
                rationale: rationale,
                createdBy: agentId.uuidString
            )
            if let ticketId {
                try? KnowledgeDatabase.shared.updateTicketStatus(id: ticketId, status: .proposed)
            }
            postCurationChanged()
            var text =
                "Created proposal #\(proposalId) for [\(collectionName)] \(relPath). "
                + "It is pending review in the Knowledge tab; the document is unchanged until approved."
            if let ticketId { text += " Ticket #\(ticketId) moved to proposed." }
            return ToolEnvelope.success(tool: name, text: text)
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Could not create the proposal: \(error.localizedDescription)",
                tool: name,
                retryable: true
            )
        }
    }
}

// MARK: - Shared helpers

enum KnowledgeCurationToolSupport {
    /// Same confinement contract as `read_knowledge`: relative, no
    /// escapes. Returns a failure envelope on violation.
    static func validateRelPath(_ relPath: String, tool: String) -> String? {
        guard !relPath.isEmpty, !relPath.hasPrefix("/"), !relPath.hasPrefix("~"),
            !relPath.components(separatedBy: "/").contains("..")
        else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `path` must be a collection-relative path without `..` components.",
                field: "path",
                expected: "relative path inside the collection, e.g. `guides/setup.md`",
                tool: tool
            )
        }
        return nil
    }

    enum Located {
        case success((collection: KnowledgeCollection, document: KnowledgeDocument))
        case failure(String)
    }

    /// Find an indexed document among the granted collections; ambiguity
    /// and misses return ready-to-return failure envelopes.
    static func locateDocument(
        relPath: String,
        in collections: [KnowledgeCollection],
        tool: String
    ) -> Located {
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
            return .failure(
                ToolEnvelope.failure(
                    kind: .notFound,
                    message: "No knowledge document at `\(relPath)` in the granted collections.",
                    tool: tool
                )
            )
        }
        if matches.count > 1 {
            let names = matches.map(\.collection.name).joined(separator: ", ")
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "Path `\(relPath)` exists in multiple collections (\(names)). Pass `collection` to disambiguate.",
                    field: "collection",
                    expected: "one of: \(names)",
                    tool: tool
                )
            )
        }
        return .success(match)
    }
}
